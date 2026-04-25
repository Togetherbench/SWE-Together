#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0
WS="/workspace/ComfyUI"
MODEL_PY="$WS/comfy/ldm/lumina/model.py"

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
PY=python3
command -v $PY >/dev/null 2>&1 || PY=python

finalize() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

if [ ! -f "$MODEL_PY" ]; then
    finalize
fi

# Patch model_management.py for CPU-only environments (idempotent)
sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    "$WS/comfy/model_management.py" 2>/dev/null || true

add_reward() {
    REWARD=$($PY -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ---- Shared bootstrap ----
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

cat > /tmp/_ref.py << 'REFEOF'
import torch
from comfy.ldm.flux.math import rope as _flux_rope

def reference_lumina_rope(ids, axes_dim, theta):
    n_axes = ids.shape[-1]
    parts = []
    for i in range(n_axes):
        pos = ids[..., i].float()
        emb_i = _flux_rope(pos, axes_dim[i], theta)
        parts.append(emb_i)
    emb = torch.cat(parts, dim=-3)
    return emb.unsqueeze(1)
REFEOF

# ====================================================================
# GATE G1: model.py parses (no reward; gate only)
# ====================================================================
$PY - << PYEOF
import ast, sys
try:
    ast.parse(open("$MODEL_PY").read())
except Exception as e:
    print("PARSE FAIL", e); sys.exit(1)
PYEOF
if [ $? -ne 0 ]; then
    echo "Gate G1 failed: model.py does not parse"
    finalize
fi

# ====================================================================
# GATE G2: P2P — flux EmbedND still importable & NextDiT still instantiable
# This passes on the buggy base AND on a correct fix. Gate only.
# ====================================================================
$PY - << 'PYEOF'
exec(open("/tmp/_boot.py").read())
import sys, torch
try:
    from comfy.ldm.flux.layers import EmbedND
    from comfy.ldm.flux.math import rope, apply_rope
    import comfy.ldm.lumina.model as lm
    assert hasattr(lm, "NextDiT")
    e = EmbedND(dim=64, theta=10000, axes_dim=[16,16,16,16])
    ids = torch.zeros(1, 4, 4, dtype=torch.long)
    out = e(ids)
    assert torch.isfinite(out).all()
    m = lm.NextDiT(
        patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
        n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
        axes_dims=[16,16,16], axes_lens=[300, 512, 512],
    )
    assert hasattr(m, "rope_embedder")
except Exception as ex:
    import traceback; traceback.print_exc()
    sys.exit(1)
PYEOF
if [ $? -ne 0 ]; then
    echo "Gate G2 failed: regression in upstream/NextDiT instantiation"
    finalize
fi

# ====================================================================
# F2P checks below. These all FAIL on the unmodified buggy base
# (where rope_embedder is a plain EmbedND with no axes_lens), and PASS
# on a correct LuminaRopeEmbedder-style fix.
# ====================================================================

# Build common discovery / probe state once and write outcomes to a file.
cat > /tmp/_probe.py << 'PROBEEOF'
import sys, json, inspect, traceback
exec(open("/tmp/_boot.py").read())

results = {
    "rope_embedder_has_axes_lens": False,
    "rope_embedder_class_name": None,
    "rope_embedder_not_embednd": False,
    "forward_shape_finite": False,
    "match_sequential": False,
    "match_nonsequential": False,
    "axes_lens_influences": False,
    "deterministic_no_mutation": False,
    "batched_correct": False,
}

try:
    import torch
    import comfy.ldm.lumina.model as lm
    from comfy.ldm.flux.layers import EmbedND
    from comfy.ldm.flux.math import rope as flux_rope

    axes_dims = [16, 16, 16]
    axes_lens = [128, 64, 64]
    theta = 10000

    m = lm.NextDiT(
        patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
        n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
        axes_dims=axes_dims, axes_lens=axes_lens,
    )
    emb = m.rope_embedder
    cls = type(emb)
    results["rope_embedder_class_name"] = cls.__name__

    # F2P-1: rope_embedder must NOT be plain EmbedND (the bug)
    if cls is not EmbedND:
        results["rope_embedder_not_embednd"] = True

    # F2P-2: rope_embedder.__init__ accepts axes_lens (or instance has it)
    has_axes_lens = False
    try:
        sig = inspect.signature(cls.__init__)
        if "axes_lens" in sig.parameters:
            has_axes_lens = True
    except Exception:
        pass
    if not has_axes_lens and hasattr(emb, "axes_lens"):
        has_axes_lens = True
    results["rope_embedder_has_axes_lens"] = has_axes_lens

    # Build reference using flux rope on raw integer ids
    def ref_rope(ids):
        parts = []
        for i in range(ids.shape[-1]):
            pos = ids[..., i].float()
            parts.append(flux_rope(pos, axes_dims[i], theta))
        return torch.cat(parts, dim=-3).unsqueeze(1)

    # F2P-3: forward returns finite tensor with right rank and seq dim
    B, N = 1, 8
    ids_seq = torch.zeros(B, N, 3, dtype=torch.long)
    ids_seq[..., 0] = torch.arange(N)            # within axes_lens[0]=128
    ids_seq[..., 1] = torch.arange(N) % axes_lens[1]
    ids_seq[..., 2] = torch.arange(N) % axes_lens[2]

    out = emb(ids_seq)
    if torch.is_tensor(out) and torch.isfinite(out).all() and out.dim() >= 4 and out.shape[-4] == B:
        # We expect shape (B, 1, N, d/2, 2, 2) or similar with N somewhere
        if N in out.shape:
            results["forward_shape_finite"] = True

    # F2P-4: numerical match on sequential ids (within axes_lens range)
    try:
        ref = ref_rope(ids_seq)
        if out.shape == ref.shape and torch.allclose(out.float(), ref.float(), atol=1e-4, rtol=1e-4):
            results["match_sequential"] = True
    except Exception:
        traceback.print_exc()

    # F2P-5: numerical match on non-sequential ids (still within range)
    try:
        torch.manual_seed(0)
        ids_rand = torch.stack([
            torch.randint(0, axes_lens[0], (B, N)),
            torch.randint(0, axes_lens[1], (B, N)),
            torch.randint(0, axes_lens[2], (B, N)),
        ], dim=-1)
        out_r = emb(ids_rand)
        ref_r = ref_rope(ids_rand)
        if out_r.shape == ref_r.shape and torch.allclose(out_r.float(), ref_r.float(), atol=1e-4, rtol=1e-4):
            results["match_nonsequential"] = True
    except Exception:
        traceback.print_exc()

    # F2P-6: axes_lens influences setup. Build a second model with
    # different axes_lens; the rope_embedder should reflect this either
    # by storing a different value or by exposing different precomputed state.
    try:
        m2 = lm.NextDiT(
            patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
            n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
            axes_dims=axes_dims, axes_lens=[256, 128, 128],
        )
        emb2 = m2.rope_embedder
        differs = False
        # Compare stored axes_lens attribute
        if hasattr(emb, "axes_lens") and hasattr(emb2, "axes_lens"):
            try:
                if list(emb.axes_lens) != list(emb2.axes_lens):
                    differs = True
            except Exception:
                pass
        # Compare buffers (precomputed tables)
        if not differs:
            bufs1 = {n: t for n, t in emb.named_buffers()}
            bufs2 = {n: t for n, t in emb2.named_buffers()}
            for k in bufs1:
                if k in bufs2 and bufs1[k].shape != bufs2[k].shape:
                    differs = True
                    break
        # Or check that for in-range ids both still match reference (correctness across configs)
        if not differs:
            ids_small = torch.zeros(1, 4, 3, dtype=torch.long)
            ids_small[..., 0] = torch.arange(4)
            o1 = emb(ids_small)
            o2 = emb2(ids_small)
            r = ref_rope(ids_small)
            if (torch.allclose(o1.float(), r.float(), atol=1e-4, rtol=1e-4) and
                torch.allclose(o2.float(), r.float(), atol=1e-4, rtol=1e-4)):
                differs = True
        results["axes_lens_influences"] = differs
    except Exception:
        traceback.print_exc()

    # F2P-7: deterministic and does not mutate ids
    try:
        ids_copy = ids_seq.clone()
        o_a = emb(ids_seq)
        o_b = emb(ids_seq)
        same = torch.equal(o_a, o_b) and torch.equal(ids_seq, ids_copy)
        results["deterministic_no_mutation"] = bool(same)
    except Exception:
        traceback.print_exc()

    # F2P-8: batched correctness
    try:
        B2 = 3
        torch.manual_seed(1)
        ids_b = torch.stack([
            torch.randint(0, axes_lens[0], (B2, N)),
            torch.randint(0, axes_lens[1], (B2, N)),
            torch.randint(0, axes_lens[2], (B2, N)),
        ], dim=-1)
        o_b = emb(ids_b)
        r_b = ref_rope(ids_b)
        if o_b.shape == r_b.shape and torch.allclose(o_b.float(), r_b.float(), atol=1e-4, rtol=1e-4):
            # Also verify per-sample equals batched-slice
            ok = True
            for k in range(B2):
                ok_k = torch.allclose(emb(ids_b[k:k+1]).float(), o_b[k:k+1].float(), atol=1e-4, rtol=1e-4)
                if not ok_k:
                    ok = False
                    break
            results["batched_correct"] = ok
    except Exception:
        traceback.print_exc()

except Exception:
    traceback.print_exc()

with open("/tmp/_probe_results.json", "w") as f:
    json.dump(results, f)
print(json.dumps(results))
PROBEEOF

$PY /tmp/_probe.py > /tmp/_probe.out 2>&1
cat /tmp/_probe.out

get_flag() {
    $PY -c "import json; d=json.load(open('/tmp/_probe_results.json')); print('1' if d.get('$1') else '0')" 2>/dev/null
}

if [ ! -f /tmp/_probe_results.json ]; then
    finalize
fi

# Weights (sum = 1.00). Each is F2P: fails on buggy base (plain EmbedND, no axes_lens).
# F2P-A: rope_embedder is not the plain EmbedND  -> 0.10
# F2P-B: rope_embedder accepts/stores axes_lens  -> 0.10
# F2P-C: forward returns finite tensor of right rank -> 0.10
# F2P-D: numerical match on sequential ids       -> 0.20
# F2P-E: numerical match on non-sequential ids   -> 0.20
# F2P-F: axes_lens influences setup              -> 0.10
# F2P-G: deterministic, no mutation              -> 0.10
# F2P-H: batched correctness                     -> 0.10

[ "$(get_flag rope_embedder_not_embednd)" = "1" ]    && add_reward 0.10 && echo "F2P-A +0.10"
[ "$(get_flag rope_embedder_has_axes_lens)" = "1" ]  && add_reward 0.10 && echo "F2P-B +0.10"
[ "$(get_flag forward_shape_finite)" = "1" ]         && add_reward 0.10 && echo "F2P-C +0.10"
[ "$(get_flag match_sequential)" = "1" ]             && add_reward 0.20 && echo "F2P-D +0.20"
[ "$(get_flag match_nonsequential)" = "1" ]          && add_reward 0.20 && echo "F2P-E +0.20"
[ "$(get_flag axes_lens_influences)" = "1" ]         && add_reward 0.10 && echo "F2P-F +0.10"
[ "$(get_flag deterministic_no_mutation)" = "1" ]    && add_reward 0.10 && echo "F2P-G +0.10"
[ "$(get_flag batched_correct)" = "1" ]              && add_reward 0.10 && echo "F2P-H +0.10"

echo "Final reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt