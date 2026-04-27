#!/bin/bash
set +e
# [v041-fix] torch/CUDA infra probe
mkdir -p /logs/verifier
if ! python3 -c "import torch; assert torch.cuda.is_available() if False else True" 2>/dev/null; then
    echo "INFRA: torch / CUDA unavailable - marking infra_fault and exiting"
    echo "1" > /logs/verifier/infra_fault
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi


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

add_reward() {
    REWARD=$($PY -c "print(min(1.0, round($REWARD + $1, 4)))")
}

if [ ! -f "$MODEL_PY" ]; then
    finalize
fi

# CPU patch (idempotent)
sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    "$WS/comfy/model_management.py" 2>/dev/null || true

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

# ====================================================================
# GATE G1: model.py parses
# ====================================================================
$PY - << PYEOF
import ast, sys
try:
    ast.parse(open("$MODEL_PY").read())
except Exception as e:
    print("PARSE FAIL", e); sys.exit(1)
PYEOF
if [ $? -ne 0 ]; then
    finalize
fi

# ====================================================================
# GATE G2: P2P — flux EmbedND still works, NextDiT still instantiable
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
    finalize
fi

# ====================================================================
# Run probe and write outcomes to JSON
# ====================================================================
cat > /tmp/_probe.py << 'PROBEEOF'
import sys, json, inspect, traceback
exec(open("/tmp/_boot.py").read())

results = {
    "not_embednd": False,             # 0.10  — structural: not the original buggy class
    "accepts_axes_lens": False,       # 0.15  — accepts axes_lens argument or stores it
    "forward_runs_finite": False,     # 0.10  — forward returns finite tensor
    "match_sequential": False,        # 0.20  — matches reference for in-range integer ids
    "match_random_inrange": False,    # 0.15  — matches reference for arbitrary ids in range
    "axes_lens_respected": False,     # 0.15  — large ids are clamped/wrapped to axes_lens range
    "deterministic_no_mutation": False, # 0.05 — repeated calls don't mutate ids
    "batched_correct": False,         # 0.10  — works on batched inputs
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

    # Gate 1: not plain EmbedND
    if cls is not EmbedND:
        results["not_embednd"] = True

    # Gate 2: accepts axes_lens (signature or stored attr referencing axes_lens values)
    has_axes_lens = False
    try:
        sig = inspect.signature(cls.__init__)
        if "axes_lens" in sig.parameters:
            has_axes_lens = True
    except Exception:
        pass
    if not has_axes_lens:
        # check instance attr
        for attr in ("axes_lens", "axes_len"):
            if hasattr(emb, attr):
                v = getattr(emb, attr)
                try:
                    if list(v) == axes_lens:
                        has_axes_lens = True
                        break
                except Exception:
                    pass
        # check buffers freqs_0 sized to axes_lens[0]
        for i, l in enumerate(axes_lens):
            if hasattr(emb, f"freqs_{i}"):
                buf = getattr(emb, f"freqs_{i}")
                if buf.shape[0] == l:
                    has_axes_lens = True
                    break
    results["accepts_axes_lens"] = has_axes_lens

    # Reference rope using flux_rope on raw integer positions
    def ref_rope(ids):
        parts = []
        for i in range(ids.shape[-1]):
            pos = ids[..., i].float()
            parts.append(flux_rope(pos, axes_dims[i], theta))
        return torch.cat(parts, dim=-3).unsqueeze(1)

    # Gate 3: forward runs and returns finite
    B, N = 1, 8
    ids_seq = torch.zeros(B, N, 3, dtype=torch.long)
    ids_seq[..., 0] = torch.arange(N)
    ids_seq[..., 1] = torch.arange(N) % axes_lens[1]
    ids_seq[..., 2] = torch.arange(N) % axes_lens[2]

    out = None
    try:
        out = emb(ids_seq)
        if torch.is_tensor(out) and torch.isfinite(out).all():
            results["forward_runs_finite"] = True
    except Exception:
        traceback.print_exc()

    # Gate 4: numeric match on sequential in-range ids
    try:
        if out is not None:
            ref = ref_rope(ids_seq)
            if out.shape == ref.shape and torch.allclose(out.float(), ref.float(), atol=1e-3, rtol=1e-3):
                results["match_sequential"] = True
    except Exception:
        traceback.print_exc()

    # Gate 5: numeric match on random in-range ids
    try:
        torch.manual_seed(42)
        ids_rand = torch.zeros(1, 6, 3, dtype=torch.long)
        ids_rand[..., 0] = torch.randint(0, axes_lens[0], (1, 6))
        ids_rand[..., 1] = torch.randint(0, axes_lens[1], (1, 6))
        ids_rand[..., 2] = torch.randint(0, axes_lens[2], (1, 6))
        out_r = emb(ids_rand)
        ref_r = ref_rope(ids_rand)
        if out_r.shape == ref_r.shape and torch.allclose(out_r.float(), ref_r.float(), atol=1e-3, rtol=1e-3):
            results["match_random_inrange"] = True
    except Exception:
        traceback.print_exc()

    # Gate 6: deterministic — calling twice gives same output and doesn't mutate ids
    try:
        ids_a = ids_seq.clone()
        ids_a_pre = ids_a.clone()
        o1 = emb(ids_a)
        o2 = emb(ids_a)
        if torch.equal(ids_a, ids_a_pre) and torch.allclose(o1.float(), o2.float(), atol=1e-6):
            results["deterministic_no_mutation"] = True
    except Exception:
        traceback.print_exc()

    # Gate 7: axes_lens respected — using id == axes_lens[i] - 1 (max in range) works,
    # AND constructing with smaller axes_lens produces buffers/behavior consistent with that.
    # We test this by: build a model with small axes_lens and check that an in-range id
    # matches reference; AND check that the embedder either has freqs buffers sized to
    # axes_lens, or stores axes_lens.
    try:
        small_lens = [16, 8, 8]
        m2 = lm.NextDiT(
            patch_size=2, in_channels=4, dim=48, n_layers=1, n_heads=1,
            n_kv_heads=1, qk_norm=True, cap_feat_dim=16,
            axes_dims=axes_dims, axes_lens=small_lens,
        )
        emb2 = m2.rope_embedder
        # check buffers OR axes_lens attr matches small_lens
        ok = False
        if hasattr(emb2, "axes_lens"):
            try:
                if list(emb2.axes_lens) == small_lens:
                    ok = True
            except Exception:
                pass
        if not ok:
            # check freq buffers
            buf_ok = True
            for i, l in enumerate(small_lens):
                if hasattr(emb2, f"freqs_{i}"):
                    buf = getattr(emb2, f"freqs_{i}")
                    if buf.shape[0] != l:
                        buf_ok = False
                        break
                else:
                    buf_ok = False
                    break
            if buf_ok:
                ok = True
        # Also functional: in-range max id should produce finite output matching reference
        ids_max = torch.zeros(1, 4, 3, dtype=torch.long)
        ids_max[..., 0] = torch.tensor([0, 5, 10, small_lens[0]-1])
        ids_max[..., 1] = torch.tensor([0, 1, 3, small_lens[1]-1])
        ids_max[..., 2] = torch.tensor([0, 2, 4, small_lens[2]-1])
        out_max = emb2(ids_max)
        # reference using axes_dims (same)
        def ref_rope2(ids):
            parts = []
            for i in range(ids.shape[-1]):
                parts.append(flux_rope(ids[..., i].float(), axes_dims[i], theta))
            return torch.cat(parts, dim=-3).unsqueeze(1)
        ref_max = ref_rope2(ids_max)
        func_ok = out_max.shape == ref_max.shape and torch.allclose(out_max.float(), ref_max.float(), atol=1e-3, rtol=1e-3)
        if ok and func_ok:
            results["axes_lens_respected"] = True
    except Exception:
        traceback.print_exc()

    # Gate 8: batched correct
    try:
        B2 = 3
        ids_b = torch.zeros(B2, 5, 3, dtype=torch.long)
        for b in range(B2):
            ids_b[b, :, 0] = torch.arange(5) + b
            ids_b[b, :, 1] = (torch.arange(5) * 2 + b) % axes_lens[1]
            ids_b[b, :, 2] = (torch.arange(5) + 3 * b) % axes_lens[2]
        out_b = emb(ids_b)
        ref_b = ref_rope(ids_b)
        if out_b.shape == ref_b.shape and torch.allclose(out_b.float(), ref_b.float(), atol=1e-3, rtol=1e-3):
            results["batched_correct"] = True
    except Exception:
        traceback.print_exc()

except Exception:
    traceback.print_exc()

with open("/tmp/_probe_results.json", "w") as f:
    json.dump(results, f)
print(json.dumps(results, indent=2))
PROBEEOF

$PY /tmp/_probe.py
if [ ! -f /tmp/_probe_results.json ]; then
    finalize
fi

# ====================================================================
# Score gates
# ====================================================================
get_flag() {
    $PY -c "import json; r=json.load(open('/tmp/_probe_results.json')); print('1' if r.get('$1', False) else '0')"
}

# Weights (sum = 1.00)
# not_embednd:               0.10
# accepts_axes_lens:         0.15
# forward_runs_finite:       0.10
# match_sequential:          0.20
# match_random_inrange:      0.15
# axes_lens_respected:       0.15
# deterministic_no_mutation: 0.05
# batched_correct:           0.10

[ "$(get_flag not_embednd)" = "1" ]                && add_reward 0.10
[ "$(get_flag accepts_axes_lens)" = "1" ]          && add_reward 0.15
[ "$(get_flag forward_runs_finite)" = "1" ]        && add_reward 0.10
[ "$(get_flag match_sequential)" = "1" ]           && add_reward 0.20
[ "$(get_flag match_random_inrange)" = "1" ]       && add_reward 0.15
[ "$(get_flag axes_lens_respected)" = "1" ]        && add_reward 0.15
[ "$(get_flag deterministic_no_mutation)" = "1" ]  && add_reward 0.05
[ "$(get_flag batched_correct)" = "1" ]            && add_reward 0.10

echo "$REWARD" > "$REWARD_FILE"