#!/bin/bash
set +e
#
# Verification tests for ComfyUI Lumina2 axes_lens RoPE implementation.
#
# Scoring (total = 1.00):
#   T1:  0.03  model.py parses
#   P2P: 0.10  EmbedND + flux still importable, NextDiT still defined and instantiable
#   T2:  0.05  new class with axes_lens kwarg + forward (structural discovery)
#   T3:  0.05  NextDiT wires the new class with axes_lens (structural)
#   T4:  0.07  NextDiT instantiates with config A (behavioral)
#   T5:  0.05  NextDiT instantiates with config B (behavioral)
#   T6:  0.08  rope_embedder.forward returns expected shape & finite values
#   T7:  0.20  numerical match to reference Lumina rope on sequential ids within range
#   T8:  0.15  numerical match on non-sequential ids within range
#   T9:  0.07  axes_lens influences setup (different lens => either different state or
#              produces same numerical output for in-range ids)
#   T10: 0.07  forward is deterministic & does not mutate ids
#   T11: 0.05  batched input correctness
#   T12: 0.03  uses precomputed lookup table (preferred impl) -- bonus structural

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0
WS="/workspace/ComfyUI"
MODEL_PY="$WS/comfy/ldm/lumina/model.py"

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
PY=python3
command -v $PY >/dev/null 2>&1 || PY=python

if [ ! -f "$MODEL_PY" ]; then
    echo "0.0" > "$REWARD_FILE"
    echo "model.py missing at $MODEL_PY"
    exit 0
fi

# Patch model_management.py for CPU-only environments (idempotent)
sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    "$WS/comfy/model_management.py" 2>/dev/null || true

add_reward() {
    REWARD=$($PY -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ---- Shared bootstrap for CPU + comfy imports ----
cat > /tmp/_boot.py << 'BOOTEOF'
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass
mm = types.ModuleType("comfy.model_management")
mm.get_torch_device = lambda: torch.device("cpu")
mm.is_device_mps = lambda d=None: False
mm.is_intel_xpu = lambda: False
mm.is_directml_enabled = lambda: False
mm.is_nvidia = lambda: False
mm.xformers_enabled = lambda: False
mm.pytorch_attention_enabled = lambda: True
mm.flash_attention_enabled = lambda: False
mm.sage_attention_enabled = lambda: False
mm.force_upcast_attention_dtype = lambda: None
mm.OOM_EXCEPTION = Exception
mm.soft_empty_cache = lambda *a, **kw: None
mm.get_free_memory = lambda *a, **kw: 4 * 1024**3
mm.throw_exception_if_processing_interrupted = lambda: None
mm.total_vram = 0
mm.total_ram = 8192
mm.cast_to = None
mm.unet_offload_device = lambda: torch.device("cpu")
mm.unet_inital_load_device = lambda *a: torch.device("cpu")
sys.modules["comfy.model_management"] = mm
import comfy
comfy.model_management = mm
BOOTEOF

# ---- Reference Lumina rope (matches Alpha-VLLM/Lumina-Image-2.0) ----
cat > /tmp/_ref.py << 'REFEOF'
import torch
from comfy.ldm.flux.math import rope as _flux_rope

def reference_lumina_rope(ids, axes_dim, theta):
    """Reference: rope(ids[...,i], axes_dim[i], theta) per axis, concat on dim -3.
    For integer ids in [0, axes_lens[i]), this matches the precomputed-table impl.
    """
    n_axes = ids.shape[-1]
    parts = []
    for i in range(n_axes):
        pos = ids[..., i].float()
        emb_i = _flux_rope(pos, axes_dim[i], theta)
        parts.append(emb_i)
    emb = torch.cat(parts, dim=-3)
    return emb.unsqueeze(1)
REFEOF

# ---- Discovery helper: find the new RoPE class ----
cat > /tmp/_discover.py << 'DISCEOF'
import inspect, torch.nn as nn
import comfy.ldm.lumina.model as _lm
SKIP = {"NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation","RMSNorm","Attention"}
_cls = None
_cls_name = None
for _n, _o in inspect.getmembers(_lm, inspect.isclass):
    if _n in SKIP:
        continue
    if not isinstance(_o, type):
        continue
    try:
        sig = inspect.signature(_o.__init__)
    except (TypeError, ValueError):
        continue
    if "axes_lens" in sig.parameters and hasattr(_o, "forward"):
        _cls = _o
        _cls_name = _n
        break
DISCEOF

# ---- Helper: build rope embedder via NextDiT or directly ----
cat > /tmp/_buildemb.py << 'BUILDEOF'
import torch
import comfy.ldm.lumina.model as lm

def build_via_nextdit(axes_dims, axes_lens, dim_per_head=64, theta=10000):
    n_heads = 1
    dim = sum(axes_dims) * n_heads
    # NextDiT requires dim = sum(axes_dims) * n_heads
    try:
        m = lm.NextDiT(
            patch_size=2,
            in_channels=4,
            dim=dim,
            n_layers=1,
            n_heads=n_heads,
            n_kv_heads=1,
            qk_norm=True,
            cap_feat_dim=16,
            axes_dims=list(axes_dims),
            axes_lens=list(axes_lens),
        )
        return m.rope_embedder
    except Exception:
        return None

def build_direct(cls, axes_dims, axes_lens, dim_per_head=None, theta=10000):
    import inspect
    sig = inspect.signature(cls.__init__)
    params = sig.parameters
    kwargs = {}
    if "axes_dim" in params:
        kwargs["axes_dim"] = list(axes_dims)
    elif "axes_dims" in params:
        kwargs["axes_dims"] = list(axes_dims)
    if "axes_lens" in params:
        kwargs["axes_lens"] = list(axes_lens)
    if "theta" in params:
        kwargs["theta"] = theta
    if "dim" in params:
        kwargs["dim"] = sum(axes_dims)
    try:
        return cls(**kwargs)
    except Exception as e:
        return None
BUILDEOF

# ====================================================================
# T1: parse
# ====================================================================
echo "=== T1: model.py parses ==="
$PY - << PYEOF
import ast, sys
try:
    ast.parse(open("$MODEL_PY").read())
    print("PASS")
except Exception as e:
    print("FAIL", e); sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then add_reward 0.03; echo "  +0.03"; fi

# ====================================================================
# P2P: upstream still works
# ====================================================================
echo "=== P2P: upstream imports + NextDiT instantiable ==="
$PY - << 'PYEOF'
exec(open("/tmp/_boot.py").read())
import sys, torch
try:
    from comfy.ldm.flux.layers import EmbedND
    from comfy.ldm.flux.math import rope, apply_rope
    import comfy.ldm.lumina.model as lm
    assert hasattr(lm, "NextDiT"), "NextDiT missing"
    e = EmbedND(dim=64, theta=10000, axes_dim=[16,16,16,16])
    ids = torch.zeros(1, 4, 4, dtype=torch.long)
    out = e(ids)
    assert torch.isfinite(out).all()
    # NextDiT must instantiate
    m = lm.NextDiT(
        patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
        n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
        axes_dims=[16,16,16], axes_lens=[300, 512, 512],
    )
    assert hasattr(m, "rope_embedder")
    print("PASS")
except Exception as ex:
    import traceback; traceback.print_exc()
    print("FAIL", ex); sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then add_reward 0.10; echo "  +0.10"; fi

# ====================================================================
# T2: new class with axes_lens kwarg + forward
# ====================================================================
echo "=== T2: new class with axes_lens ==="
$PY - << 'PYEOF'
import sys
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL: no class with axes_lens kwarg found"); sys.exit(1)
print(f"PASS: {_cls_name}")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.05; echo "  +0.05"; fi

# ====================================================================
# T3: NextDiT wires new class with axes_lens (not EmbedND)
# ====================================================================
echo "=== T3: NextDiT wires new class with axes_lens ==="
$PY - << 'PYEOF'
import sys, re
exec(open("/tmp/_boot.py").read())
src = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
m = re.search(r"self\.rope_embedder\s*=\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*\((.*?)\)", src, re.DOTALL)
if not m:
    print("FAIL: rope_embedder assignment not found"); sys.exit(1)
clsname, args = m.group(1), m.group(2)
if clsname.split(".")[-1] == "EmbedND":
    print("FAIL: still uses EmbedND"); sys.exit(1)
if "axes_lens" not in args:
    print("FAIL: axes_lens not passed to", clsname); sys.exit(1)
# Confirm at runtime
import comfy.ldm.lumina.model as lm
m2 = lm.NextDiT(
    patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
    n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
    axes_dims=[16,16,16], axes_lens=[300, 512, 512],
)
emb = m2.rope_embedder
if type(emb).__name__ == "EmbedND":
    print("FAIL: runtime rope_embedder is EmbedND"); sys.exit(1)
print(f"PASS: NextDiT uses {type(emb).__name__} with axes_lens")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.05; echo "  +0.05"; fi

# ====================================================================
# T4: NextDiT instantiates with config A
# ====================================================================
echo "=== T4: NextDiT config A ==="
$PY - << 'PYEOF'
import sys
exec(open("/tmp/_boot.py").read())
import comfy.ldm.lumina.model as lm
try:
    m = lm.NextDiT(
        patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
        n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
        axes_dims=[16,16,16], axes_lens=[300, 512, 512],
    )
    assert hasattr(m, "rope_embedder")
    print("PASS")
except Exception as e:
    import traceback; traceback.print_exc()
    print("FAIL", e); sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then add_reward 0.07; echo "  +0.07"; fi

# ====================================================================
# T5: NextDiT instantiates with config B (different axes/lens)
# ====================================================================
echo "=== T5: NextDiT config B ==="
$PY - << 'PYEOF'
import sys
exec(open("/tmp/_boot.py").read())
import comfy.ldm.lumina.model as lm
try:
    m = lm.NextDiT(
        patch_size=2, in_channels=4, dim=64, n_layers=1, n_heads=1,
        n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
        axes_dims=[32, 16, 16], axes_lens=[100, 256, 256],
    )
    assert hasattr(m, "rope_embedder")
    print("PASS")
except Exception as e:
    import traceback; traceback.print_exc()
    print("FAIL", e); sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then add_reward 0.05; echo "  +0.05"; fi

# ====================================================================
# T6: rope_embedder.forward returns expected shape & finite values
# ====================================================================
echo "=== T6: forward shape + finite ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
axes_dims = [16, 16, 16]
axes_lens = [64, 64, 64]
emb = build_via_nextdit(axes_dims, axes_lens)
if emb is None:
    print("FAIL: cannot build"); sys.exit(1)
ids = torch.zeros(2, 8, 3, dtype=torch.long)
ids[..., 0] = torch.arange(8).unsqueeze(0).expand(2, 8) % axes_lens[0]
ids[..., 1] = torch.arange(8).unsqueeze(0).expand(2, 8) % axes_lens[1]
ids[..., 2] = torch.arange(8).unsqueeze(0).expand(2, 8) % axes_lens[2]
with torch.no_grad():
    out = emb(ids)
total_dim = sum(axes_dims)
# Expected shape per Lumina/flux: (..., 1, seq, total_dim/2, 2, 2) -- last 3 dims fixed
if out.dim() < 4:
    print("FAIL: too few dims:", out.shape); sys.exit(1)
if out.shape[-3] != total_dim // 2 or out.shape[-2] != 2 or out.shape[-1] != 2:
    print("FAIL: unexpected shape", out.shape); sys.exit(1)
if not torch.isfinite(out).all():
    print("FAIL: non-finite output"); sys.exit(1)
print("PASS shape:", tuple(out.shape))
PYEOF
if [ $? -eq 0 ]; then add_reward 0.08; echo "  +0.08"; fi

# ====================================================================
# T7: numerical match to reference on sequential ids within range
# ====================================================================
echo "=== T7: numerical match (sequential ids) ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
sys.path.insert(0, "/tmp")
exec(open("/tmp/_ref.py").read())

axes_dims = [16, 16, 16]
axes_lens = [128, 128, 128]
theta = 10000
emb = build_via_nextdit(axes_dims, axes_lens, theta=theta)
if emb is None:
    print("FAIL: cannot build"); sys.exit(1)

# Use ids strictly within [0, axes_lens[i])
B, S = 1, 16
ids = torch.zeros(B, S, 3, dtype=torch.long)
for i in range(3):
    ids[..., i] = torch.arange(S) % axes_lens[i]

with torch.no_grad():
    out = emb(ids)
ref = reference_lumina_rope(ids, axes_dims, theta)

# Shapes must match
if out.shape != ref.shape:
    # Some impls may return (..., 1, S, d, 2, 2) shape variants. Try squeezing.
    if out.squeeze().shape != ref.squeeze().shape:
        print("FAIL shape mismatch:", out.shape, "vs", ref.shape); sys.exit(1)
    out_c = out.squeeze()
    ref_c = ref.squeeze()
else:
    out_c = out
    ref_c = ref

diff = (out_c - ref_c).abs().max().item()
print(f"max_abs_diff = {diff:.6e}")
if diff > 1e-3:
    print("FAIL: numerical mismatch"); sys.exit(1)
print("PASS")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.20; echo "  +0.20"; fi

# ====================================================================
# T8: numerical match on non-sequential ids within range
# ====================================================================
echo "=== T8: numerical match (non-sequential ids) ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
exec(open("/tmp/_ref.py").read())

torch.manual_seed(0)
axes_dims = [16, 16, 16]
axes_lens = [200, 256, 256]
theta = 10000
emb = build_via_nextdit(axes_dims, axes_lens, theta=theta)
if emb is None:
    print("FAIL: cannot build"); sys.exit(1)

B, S = 2, 12
ids = torch.zeros(B, S, 3, dtype=torch.long)
for i in range(3):
    ids[..., i] = torch.randint(0, axes_lens[i], (B, S))

with torch.no_grad():
    out = emb(ids)
ref = reference_lumina_rope(ids, axes_dims, theta)

if out.shape != ref.shape:
    if out.squeeze().shape != ref.squeeze().shape:
        print("FAIL shape:", out.shape, "vs", ref.shape); sys.exit(1)
    out_c = out.squeeze(); ref_c = ref.squeeze()
else:
    out_c = out; ref_c = ref

diff = (out_c - ref_c).abs().max().item()
print(f"max_abs_diff = {diff:.6e}")
if diff > 1e-3:
    print("FAIL: numerical mismatch"); sys.exit(1)
print("PASS")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.15; echo "  +0.15"; fi

# ====================================================================
# T9: axes_lens influences setup (sanity: different lens still produces
# correct in-range output, AND the embedder reflects axes_lens)
# ====================================================================
echo "=== T9: axes_lens affects embedder ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
exec(open("/tmp/_ref.py").read())

axes_dims = [16, 16, 16]
theta = 10000
emb_a = build_via_nextdit(axes_dims, [64, 64, 64], theta=theta)
emb_b = build_via_nextdit(axes_dims, [256, 256, 256], theta=theta)
if emb_a is None or emb_b is None:
    print("FAIL build"); sys.exit(1)

# Both should give same numerical output for ids strictly within both ranges.
B, S = 1, 8
ids = torch.zeros(B, S, 3, dtype=torch.long)
for i in range(3):
    ids[..., i] = torch.arange(S) % 32

with torch.no_grad():
    out_a = emb_a(ids)
    out_b = emb_b(ids)
ref = reference_lumina_rope(ids, axes_dims, theta)

def squeeze_match(x, r):
    if x.shape == r.shape:
        return x, r
    return x.squeeze(), r.squeeze()

oa, r1 = squeeze_match(out_a, ref)
ob, r2 = squeeze_match(out_b, ref)
da = (oa - r1).abs().max().item()
db = (ob - r2).abs().max().item()
print(f"diff_a={da:.3e} diff_b={db:.3e}")
if da > 1e-3 or db > 1e-3:
    print("FAIL: axes_lens variants don't both match reference"); sys.exit(1)

# Also check that axes_lens is recorded somewhere on the embedder OR that
# state_dict / parameters differ when axes_lens differs (precompute table).
sd_a = dict(emb_a.state_dict())
sd_b = dict(emb_b.state_dict())
attr_lens_a = getattr(emb_a, "axes_lens", None)
attr_lens_b = getattr(emb_b, "axes_lens", None)
table_diff = False
for k in sd_a.keys() & sd_b.keys():
    if sd_a[k].shape != sd_b[k].shape:
        table_diff = True; break
if not table_diff and (attr_lens_a is None or list(attr_lens_a) == list(attr_lens_b or [])):
    # axes_lens neither stored nor changed buffers - weak but acceptable if numerics match
    print("WARN: axes_lens not reflected in state, but numerics OK")
print("PASS")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.07; echo "  +0.07"; fi

# ====================================================================
# T10: forward is deterministic & does not mutate ids
# ====================================================================
echo "=== T10: deterministic + no mutation ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
axes_dims = [16, 16, 16]
axes_lens = [128, 128, 128]
emb = build_via_nextdit(axes_dims, axes_lens)
if emb is None:
    print("FAIL build"); sys.exit(1)
torch.manual_seed(1)
ids = torch.randint(0, 100, (1, 8, 3), dtype=torch.long)
ids_orig = ids.clone()
with torch.no_grad():
    o1 = emb(ids)
    o2 = emb(ids)
if not torch.equal(ids, ids_orig):
    print("FAIL: ids mutated"); sys.exit(1)
if not torch.allclose(o1, o2):
    print("FAIL: non-deterministic"); sys.exit(1)
print("PASS")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.07; echo "  +0.07"; fi

# ====================================================================
# T11: batched correctness
# ====================================================================
echo "=== T11: batched correctness ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
exec(open("/tmp/_ref.py").read())
axes_dims = [16, 16, 16]
axes_lens = [128, 128, 128]
theta = 10000
emb = build_via_nextdit(axes_dims, axes_lens, theta=theta)
if emb is None:
    print("FAIL build"); sys.exit(1)
torch.manual_seed(2)
B, S = 3, 10
ids = torch.zeros(B, S, 3, dtype=torch.long)
for i in range(3):
    ids[..., i] = torch.randint(0, axes_lens[i], (B, S))
with torch.no_grad():
    out_full = emb(ids)
# Per-sample
per = []
for b in range(B):
    with torch.no_grad():
        per.append(emb(ids[b:b+1]))
out_cat = torch.cat(per, dim=0)
if out_full.shape != out_cat.shape:
    print("FAIL shape", out_full.shape, out_cat.shape); sys.exit(1)
diff = (out_full - out_cat).abs().max().item()
print(f"batch_diff = {diff:.3e}")
if diff > 1e-4:
    print("FAIL: batched != per-sample"); sys.exit(1)
# Also vs reference
ref = reference_lumina_rope(ids, axes_dims, theta)
out_c = out_full if out_full.shape == ref.shape else out_full.squeeze()
ref_c = ref if out_full.shape == ref.shape else ref.squeeze()
diff_ref = (out_c - ref_c).abs().max().item()
if diff_ref > 1e-3:
    print("FAIL: batch vs reference", diff_ref); sys.exit(1)
print("PASS")
PYEOF
if [ $? -eq 0 ]; then add_reward 0.05; echo "  +0.05"; fi

# ====================================================================
# T12: bonus -- precomputed lookup table style (preferred)
# ====================================================================
echo "=== T12: precomputed table style (bonus) ==="
$PY - << 'PYEOF'
import sys, torch
exec(open("/tmp/_boot.py").read())
exec(open("/tmp/_buildemb.py").read())
axes_dims = [16, 16, 16]
axes_lens = [64, 64, 64]
emb = build_via_nextdit(axes_dims, axes_lens)
if emb is None:
    print("FAIL build"); sys.exit(1)
sd = dict(emb.state_dict())
# Look for buffers whose first dim matches axes_lens[i]
matched = 0
for k, v in sd.items():
    if v.dim() >= 1 and v.shape[0] in axes_lens:
        matched += 1
buffer_names = list(emb._buffers.keys()) if hasattr(emb, "_buffers") else []
buffer_count = sum(1 for n in buffer_names if emb._buffers[n] is not None)
if matched >= 1 or buffer_count >= 1:
    print(f"PASS: precomputed buffers detected ({matched} matched, {buffer_count} buffers)")
else:
    print("FAIL: no precomputed table buffers found"); sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then add_reward 0.03; echo "  +0.03"; fi

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"
exit 0