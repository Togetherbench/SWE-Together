#!/bin/bash
set +e
#
# Verification tests for fp8_scaled implementation for the Lumina model in sd-scripts.
#
# Scoring (total = 1.0):
#   Structural (0.20):
#     S1 (0.05): FP8_OPTIMIZATION_TARGET_KEYS contains "layers"
#     S2 (0.05): FP8_OPTIMIZATION_EXCLUDE_KEYS defined (modulation OR norm OK)
#     S3 (0.05): load_lumina_model accepts fp8_scaled and calls apply_fp8_monkey_patch
#     S4 (0.05): --fp8_scaled CLI argument registered
#
#   Behavioral - F2P (0.65):
#     B1 (0.08): Modified fp8_linear_forward_patch importable & runs (per-tensor bf16)
#     B2 (0.08): Numerical accuracy per-tensor scale=2.0 (bf16)
#     B3 (0.08): Numerical accuracy per-channel (bf16)
#     B4 (0.08): Numerical accuracy block-wise (bf16)
#     B5 (0.07): Output dtype preserved across input dtypes (bf16/float32)
#     B6 (0.07): 3D batched input shape correctness
#     B7 (0.07): Different shapes / scales (wide->narrow, narrow->wide)
#     B8 (0.06): apply_fp8_monkey_patch works on a real Lumina-like module
#         (using FP8_OPTIMIZATION_TARGET/EXCLUDE_KEYS exported by sd-scripts)
#     B9 (0.06): Train-network arg parser accepts --fp8_scaled (real argparse run)
#
#   P2P (0.15):
#     P1 (0.05): Existing fp8_linear_forward_patch original-weight (non-scale_weight) path still works
#     P2 (0.05): Library imports succeed (no syntax errors / circular imports introduced)
#     P3 (0.05): adaLN_modulation OR norm modules are NOT picked up by FP8 quant target
#

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

REPO=/workspace/sd-scripts
if [ ! -d "$REPO" ]; then
    echo "REPO PATH MISSING: $REPO"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ───────────────────────────────────────────────
# Common mock-init for behavioral tests
# ───────────────────────────────────────────────
cat > /tmp/_vfp8mock.py << 'MOCKINIT'
import sys
from unittest.mock import MagicMock

_MODS = [
    "cv2", "PIL", "PIL.Image", "PIL.ImageFilter", "PIL.ImageOps",
    "einops", "einops.layers", "einops.layers.torch",
    "diffusers", "diffusers.schedulers",
    "diffusers.schedulers.scheduling_euler_ancestral_discrete",
    "diffusers.schedulers.scheduling_euler_discrete",
    "diffusers.schedulers.scheduling_flow_match_euler_discrete",
    "diffusers.configuration_utils", "diffusers.models",
    "diffusers.models.attention_processor", "diffusers.loaders",
    "diffusers.utils",
    "flash_attn", "flash_attn.flash_attn_interface", "flash_attn.bert_padding",
    "sageattention",
    "apex", "apex.normalization", "apex.optimizers",
    "xformers", "xformers.ops", "triton",
    "bitsandbytes", "bitsandbytes.nn", "quanto",
    "lycoris", "lycoris.config", "lycoris.modules", "peft",
    "gradio", "wandb", "tensorboard", "tensorboardX",
    "voluptuous", "open_clip", "open_clip.tokenizer",
]
for _m in _MODS:
    if _m not in sys.modules:
        _mo = MagicMock()
        _mo.__spec__ = MagicMock()
        _mo.__all__ = []
        sys.modules[_m] = _mo

sys.path.insert(0, "/workspace/sd-scripts")
MOCKINIT


# ═══════════════════════════════════════════════════════════════════
# STRUCTURAL CHECKS (0.20)
# ═══════════════════════════════════════════════════════════════════

echo "=== S1: FP8_OPTIMIZATION_TARGET_KEYS contains 'layers' ==="
S1=$(python3 << 'PYEOF' | tail -1
import re
found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and re.search(r'["\']layers[\.\'"]', m.group(1)):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  Result: $S1"
[ "$S1" = "PASS" ] && add_reward 0.05

echo ""
echo "=== S2: FP8_OPTIMIZATION_EXCLUDE_KEYS defined ==="
S2=$(python3 << 'PYEOF' | tail -1
import re
found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and ("modulation" in m.group(1) or "norm" in m.group(1)):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  Result: $S2"
[ "$S2" = "PASS" ] && add_reward 0.05

echo ""
echo "=== S3: load_lumina_model has fp8_scaled param + apply_fp8_monkey_patch ==="
S3=$(python3 << 'PYEOF' | tail -1
import ast
try:
    src = open("/workspace/sd-scripts/library/lumina_util.py").read()
    tree = ast.parse(src)
except Exception as e:
    print("FAIL")
    raise SystemExit(0)

score = 0
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_lumina_model":
        args = [a.arg for a in node.args.args + node.args.kwonlyargs]
        if "fp8_scaled" in args:
            score += 1
        end = getattr(node, "end_lineno", None)
        if end:
            body = "\n".join(src.split("\n")[node.lineno - 1: end])
            if "apply_fp8_monkey_patch" in body:
                score += 1
        break

if score == 2:
    print("PASS")
elif score == 1:
    print("PARTIAL")
else:
    print("FAIL")
PYEOF
)
echo "  Result: $S3"
if [ "$S3" = "PASS" ]; then add_reward 0.05
elif [ "$S3" = "PARTIAL" ]; then add_reward 0.025
fi

echo ""
echo "=== S4: --fp8_scaled CLI argument registered ==="
S4=$(python3 << 'PYEOF' | tail -1
import re, glob
candidates = [
    "/workspace/sd-scripts/library/lumina_train_util.py",
    "/workspace/sd-scripts/lumina_train_network.py",
    "/workspace/sd-scripts/lumina_train.py",
    "/workspace/sd-scripts/lumina_minimal_inference.py",
]
found = False
for p in candidates:
    try:
        src = open(p).read()
    except FileNotFoundError:
        continue
    if re.search(r'add_argument\(\s*["\']--fp8_scaled["\']', src):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  Result: $S4"
[ "$S4" = "PASS" ] && add_reward 0.05


# ═══════════════════════════════════════════════════════════════════
# BEHAVIORAL CHECKS (0.65)
# ═══════════════════════════════════════════════════════════════════

# Helper to run a behavioral test script and emit PASS/FAIL.
run_behavioral() {
    local label="$1"
    local script_file="$2"
    python3 "$script_file" 2>&1 | tail -3
}

# ---------------- B1: modified forward patch importable & runs ----------------
echo ""
echo "=== B1: fp8_linear_forward_patch import and runs (bf16, per-tensor) ==="
cat > /tmp/_b1.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

torch.manual_seed(0)
lin = nn.Linear(16, 8, bias=False)
# Simulate fp8 scaled state.
W = lin.weight.detach().clone()
scale = torch.tensor(W.abs().max() / 448.0, dtype=torch.bfloat16) if False else torch.tensor(2.0, dtype=torch.bfloat16)
fp8_w = (W / scale.float()).clamp(-448, 448).to(torch.float8_e4m3fn)
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = scale
lin.fp8_matmul_enabled = False
x = torch.randn(3, 16, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)); sys.exit(0)
if y.shape != (3, 8):
    print("FAIL:shape:" + str(tuple(y.shape))); sys.exit(0)
if y.dtype not in (torch.bfloat16, torch.float32):
    print("FAIL:dtype:" + str(y.dtype)); sys.exit(0)
if torch.isnan(y).any() or torch.isinf(y).any():
    print("FAIL:nan"); sys.exit(0)
print("PASS")
PYEOF
B1=$(python3 /tmp/_b1.py 2>&1 | tail -1)
echo "  Result: $B1"
[ "$B1" = "PASS" ] && add_reward 0.08


# ---------------- B2: numerical accuracy per-tensor scale=2.0 (bf16) ----------------
echo ""
echo "=== B2: numerical accuracy per-tensor (bf16, scale=2.0) ==="
cat > /tmp/_b2.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

torch.manual_seed(1)
lin = nn.Linear(16, 8, bias=False)
W = lin.weight.detach().clone()
scale_val = 2.0
fp8_w = (W / scale_val).to(torch.float8_e4m3fn)
recon = fp8_w.to(torch.float32) * scale_val
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = torch.tensor(scale_val, dtype=torch.bfloat16)
lin.fp8_matmul_enabled = False
x = torch.randn(4, 16, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)); sys.exit(0)
expected = torch.nn.functional.linear(x.float(), recon)
err = (y.float() - expected).abs().max().item()
ref = expected.abs().max().item() + 1e-6
if err / ref > 0.15:
    print("FAIL:err=" + str(err / ref)); sys.exit(0)
print("PASS")
PYEOF
B2=$(python3 /tmp/_b2.py 2>&1 | tail -1)
echo "  Result: $B2"
[ "$B2" = "PASS" ] && add_reward 0.08


# ---------------- B3: numerical accuracy per-channel ----------------
echo ""
echo "=== B3: numerical accuracy per-channel (bf16) ==="
cat > /tmp/_b3.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

torch.manual_seed(2)
lin = nn.Linear(16, 8, bias=False)
W = lin.weight.detach().clone()
scales = torch.linspace(0.5, 3.0, 8).view(8, 1)
fp8_w = (W / scales).to(torch.float8_e4m3fn)
recon = fp8_w.to(torch.float32) * scales
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = scales.to(torch.bfloat16)
lin.fp8_matmul_enabled = False
x = torch.randn(4, 16, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)); sys.exit(0)
expected = torch.nn.functional.linear(x.float(), recon)
err = (y.float() - expected).abs().max().item()
ref = expected.abs().max().item() + 1e-6
if err / ref > 0.15:
    print("FAIL:err=" + str(err / ref)); sys.exit(0)
print("PASS")
PYEOF
B3=$(python3 /tmp/_b3.py 2>&1 | tail -1)
echo "  Result: $B3"
[ "$B3" = "PASS" ] && add_reward 0.08


# ---------------- B4: numerical accuracy block-wise ----------------
echo ""
echo "=== B4: numerical accuracy block-wise (bf16) ==="
cat > /tmp/_b4.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

torch.manual_seed(3)
out_features, in_features = 8, 32
block_size = 8
num_blocks = in_features // block_size
lin = nn.Linear(in_features, out_features, bias=False)
W = lin.weight.detach().clone()
W_blk = W.view(out_features, num_blocks, block_size)
scales = torch.empty(out_features, num_blocks, 1).uniform_(0.5, 2.0)
fp8_blk = (W_blk / scales).to(torch.float8_e4m3fn)
fp8_w = fp8_blk.view(out_features, in_features)
recon = (fp8_blk.to(torch.float32) * scales).view(out_features, in_features)
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = scales.squeeze(-1).unsqueeze(-1).to(torch.bfloat16)  # (out, num_blocks, 1)
lin.fp8_matmul_enabled = False
x = torch.randn(4, in_features, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)); sys.exit(0)
expected = torch.nn.functional.linear(x.float(), recon)
err = (y.float() - expected).abs().max().item()
ref = expected.abs().max().item() + 1e-6
if err / ref > 0.20:
    print("FAIL:err=" + str(err / ref)); sys.exit(0)
print("PASS")
PYEOF
B4=$(python3 /tmp/_b4.py 2>&1 | tail -1)
echo "  Result: $B4"
[ "$B4" = "PASS" ] && add_reward 0.08


# ---------------- B5: output dtype preservation ----------------
echo ""
echo "=== B5: output dtype preserved (bf16, float32) ==="
cat > /tmp/_b5.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

torch.manual_seed(4)
ok = True
for in_dtype in (torch.bfloat16, torch.float32):
    lin = nn.Linear(16, 8, bias=False)
    W = lin.weight.detach().clone()
    scale = 2.0
    fp8_w = (W / scale).to(torch.float8_e4m3fn)
    lin.weight = nn.Parameter(fp8_w, requires_grad=False)
    lin.scale_weight = torch.tensor(scale, dtype=in_dtype)
    lin.fp8_matmul_enabled = False
    x = torch.randn(2, 16, dtype=in_dtype)
    try:
        y = fp8_linear_forward_patch(lin, x, False, 0)
    except Exception as e:
        print("FAIL:" + str(in_dtype) + ":" + repr(e)); sys.exit(0)
    if y.shape != (2, 8):
        ok = False; break
    if torch.isnan(y).any() or torch.isinf(y).any():
        ok = False; break
print("PASS" if ok else "FAIL")
PYEOF
B5=$(python3 /tmp/_b5.py 2>&1 | tail -1)
echo "  Result: $B5"
[ "$B5" = "PASS" ] && add_reward 0.07


# ---------------- B6: 3D batched input ----------------
echo ""
echo "=== B6: 3D batched input shape (2,4,16)->(2,4,8) ==="
cat > /tmp/_b6.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)
torch.manual_seed(5)
lin = nn.Linear(16, 8, bias=False)
W = lin.weight.detach().clone()
fp8_w = (W / 2.0).to(torch.float8_e4m3fn)
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = torch.tensor(2.0, dtype=torch.bfloat16)
lin.fp8_matmul_enabled = False
x = torch.randn(2, 4, 16, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)); sys.exit(0)
print("PASS" if y.shape == (2, 4, 8) else "FAIL:" + str(tuple(y.shape)))
PYEOF
B6=$(python3 /tmp/_b6.py 2>&1 | tail -1)
echo "  Result: $B6"
[ "$B6" = "PASS" ] && add_reward 0.07


# ---------------- B7: different shapes / scales ----------------
echo ""
echo "=== B7: different shapes (32->4 scale=128) and (24->12) ==="
cat > /tmp/_b7.py << 'PYEOF'
import sys
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)
torch.manual_seed(6)

def run(in_f, out_f, scale_v, dtype):
    lin = nn.Linear(in_f, out_f, bias=False)
    W = lin.weight.detach().clone()
    fp8_w = (W / scale_v).clamp(-448, 448).to(torch.float8_e4m3fn)
    recon = fp8_w.to(torch.float32) * scale_v
    lin.weight = nn.Parameter(fp8_w, requires_grad=False)
    lin.scale_weight = torch.tensor(scale_v, dtype=dtype)
    lin.fp8_matmul_enabled = False
    x = torch.randn(2, in_f, dtype=dtype)
    y = fp8_linear_forward_patch(lin, x, False, 0)
    if y.shape != (2, out_f): return False
    expected = torch.nn.functional.linear(x.float(), recon)
    err = (y.float() - expected).abs().max().item()
    ref = expected.abs().max().item() + 1e-6
    return err / ref < 0.20

ok = True
try:
    if not run(32, 4, 128.0, torch.bfloat16): ok = False
    if not run(24, 12, 0.75, torch.float32): ok = False
    if not run(64, 32, 0.5, torch.bfloat16): ok = False
except Exception as e:
    print("FAIL:" + repr(e)); sys.exit(0)
print("PASS" if ok else "FAIL")
PYEOF