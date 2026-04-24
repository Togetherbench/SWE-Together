#!/usr/bin/env bash
#
# Verification tests for fp8_scaled implementation for the Lumina model in sd-scripts.
#
# The agent must:
#   1. library/lumina_util.py (or lumina_models.py): Add FP8_OPTIMIZATION_TARGET_KEYS
#      containing "layers" and FP8_OPTIMIZATION_EXCLUDE_KEYS containing "modulation"
#   2. library/lumina_util.py: Modify load_lumina_model to accept fp8_scaled and
#      call apply_fp8_monkey_patch
#   3. library/fp8_optimization_utils.py: Fix fp8_linear_forward_patch to cast
#      scale_weight to x.dtype (not fp8) before dequantization multiply
#   4. Add --fp8_scaled CLI argument (lumina_train_util.py or lumina_train_network.py)
#
# Scoring breakdown (structural=10%, behavioral=90%):
#   T1:  0.03  TARGET_KEYS contains "layers" [structural]
#   T2:  0.03  EXCLUDE_KEYS contains "modulation" [structural]
#   T3:  0.02  load_lumina_model: fp8_scaled param + apply_fp8_monkey_patch [structural]
#   T4:  0.02  --fp8_scaled CLI argument [structural]
#   T5:  0.09  fp8 forward: bf16 + scalar fp8 scale (16->8) [behavioral]
#   T6:  0.08  fp8 forward: float32 + scalar fp8 scale (16->8) [behavioral]
#   T7:  0.09  fp8 forward: bf16 + per-channel fp8 scale (16->8) [behavioral]
#   T8:  0.08  fp8 forward: dtype preservation bf16+float32 [behavioral]
#   T9:  0.07  fp8 forward: 3D batched input (2,4,16)->(2,4,8) [behavioral]
#   T10: 0.09  fp8 forward: numerical accuracy per-tensor scale=2.0 [behavioral]
#   T11: 0.09  fp8 forward: numerical accuracy per-channel [behavioral]
#   T12: 0.08  fp8 forward: different dims (64->32) + scale=0.5 [behavioral]
#   T13: 0.08  fp8 forward: wide->narrow (32->4) + scale=128.0 [behavioral]
#   T14: 0.07  fp8 forward: non-unit scale (24->12) + float32 [behavioral]
#   T15: 0.08  P2P: upstream CPU-safe tests [behavioral]
#   T16: 0.02  TARGET_KEYS grounded in real NextDiT self.<attr> [audit-T2 hardening]
#   T17: 0.02  adaLN_modulation behaviorally excluded from fp8 quant [audit-T6 hardening]
#
# (T16+T17 add 0.04 above the original 1.00 ceiling; the add_reward min(1.0,...)
# clamp keeps the final reward at 1.0 — these checks target audit-flagged
# gameability gaps without changing the existing PASS/FAIL gates.)
#
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ═══════════════════════════════════════════════════════════════════
# Write comprehensive mock setup to temp file (used by behavioral tests).
# Mocks ALL external dependencies that sd-scripts modules may import
# transitively, so that importing fp8_optimization_utils succeeds
# even when optional packages (cv2, diffusers, flash_attn, etc.)
# are not installed.
# ═══════════════════════════════════════════════════════════════════
cat > /tmp/_vfp8mock.py << 'MOCKINIT'
import sys
from unittest.mock import MagicMock

_MODS = [
    # Image / vision
    "cv2", "PIL", "PIL.Image", "PIL.ImageFilter", "PIL.ImageOps",
    # Tensor manipulation
    "einops", "einops.layers", "einops.layers.torch",
    # Diffusers framework
    "diffusers", "diffusers.schedulers",
    "diffusers.schedulers.scheduling_euler_ancestral_discrete",
    "diffusers.schedulers.scheduling_euler_discrete",
    "diffusers.schedulers.scheduling_flow_match_euler_discrete",
    "diffusers.configuration_utils", "diffusers.models",
    "diffusers.models.attention_processor", "diffusers.loaders",
    "diffusers.utils",
    # Attention backends
    "flash_attn", "flash_attn.flash_attn_interface", "flash_attn.bert_padding",
    "sageattention",
    # NVIDIA / acceleration
    "apex", "apex.normalization", "apex.optimizers",
    "xformers", "xformers.ops", "triton",
    # Quantization
    "bitsandbytes", "bitsandbytes.nn", "quanto",
    # LoRA / fine-tuning
    "lycoris", "lycoris.config", "lycoris.modules", "peft",
    # UI / logging
    "gradio", "wandb", "tensorboard", "tensorboardX",
    # Misc
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
# STRUCTURAL TESTS (T1-T4, total = 0.10)
# All use source-file parsing (AST / regex) — no imports needed.
# ═══════════════════════════════════════════════════════════════════

# --- T1 (0.03): TARGET_KEYS contains "layers" ---
echo "=== Test 1/15: FP8_OPTIMIZATION_TARGET_KEYS contains 'layers' [structural] ==="
T1=$(python3 << 'PYEOF' | tail -1
import re, sys

found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        with open(path) as f:
            src = f.read()
    except FileNotFoundError:
        continue
    if "FP8_OPTIMIZATION_TARGET_KEYS" not in src:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and ("'layers'" in m.group(1) or '"layers"' in m.group(1)):
        found = True
        break

print("PASS" if found else "FAIL:not_found")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.03; fi


# --- T2 (0.03): EXCLUDE_KEYS contains "modulation" ---
echo ""
echo "=== Test 2/15: FP8_OPTIMIZATION_EXCLUDE_KEYS contains 'modulation' [structural] ==="
T2=$(python3 << 'PYEOF' | tail -1
import re, sys

found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        with open(path) as f:
            src = f.read()
    except FileNotFoundError:
        continue
    if "FP8_OPTIMIZATION_EXCLUDE_KEYS" not in src:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and "modulation" in m.group(1):
        found = True
        break

print("PASS" if found else "FAIL:no_modulation")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.03; fi


# --- T3 (0.02): load_lumina_model: fp8_scaled param + apply_fp8_monkey_patch ---
echo ""
echo "=== Test 3/15: load_lumina_model fp8_scaled + apply_fp8_monkey_patch [structural] ==="
T3=$(python3 << 'PYEOF' | tail -1
import ast, sys

try:
    with open("/workspace/sd-scripts/library/lumina_util.py") as f:
        source = f.read()
    tree = ast.parse(source)
except (FileNotFoundError, SyntaxError) as e:
    print("FAIL:" + str(e))
    sys.exit(0)

score = 0
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_lumina_model":
        # Sub-check A: fp8_scaled parameter
        args = [a.arg for a in node.args.args + node.args.kwonlyargs]
        if "fp8_scaled" in args:
            score += 1
        # Sub-check B: apply_fp8_monkey_patch in function body
        end = getattr(node, "end_lineno", None)
        if end:
            func_src = "\n".join(source.split("\n")[node.lineno - 1 : end])
            if "apply_fp8_monkey_patch" in func_src:
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
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then
    add_reward 0.02
elif [ "$T3" = "PARTIAL" ]; then
    add_reward 0.01
fi


# --- T4 (0.02): --fp8_scaled CLI argument ---
echo ""
echo "=== Test 4/15: --fp8_scaled CLI argument [structural] ==="
T4=$(python3 << 'PYEOF' | tail -1
import ast, sys

found = False
for path in ["/workspace/sd-scripts/library/lumina_train_util.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        with open(path) as f:
            tree = ast.parse(f.read())
    except (FileNotFoundError, SyntaxError):
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr == "add_argument":
                for arg in node.args:
                    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                        if "fp8_scaled" in arg.value:
                            found = True
                            break
                if not found:
                    for kw in node.keywords:
                        if kw.arg == "dest" and isinstance(kw.value, ast.Constant):
                            if "fp8_scaled" in str(kw.value.value):
                                found = True
                                break
        if found:
            break
    if found:
        break

print("PASS" if found else "FAIL:not_found")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.02; fi


# ═══════════════════════════════════════════════════════════════════
# BEHAVIORAL TESTS (T5-T15, total = 0.90)
# Each test imports fp8_linear_forward_patch via comprehensive mocking,
# then exercises it with specific inputs to verify the core bug fix
# (fp8 scale_weight multiply) and correct behavior.
# ═══════════════════════════════════════════════════════════════════

# --- T5 (0.09): bf16 + scalar fp8 scale (16->8) — core bug test ---
echo ""
echo "=== Test 5/15: fp8 forward: bf16 + scalar fp8 scale 16->8 [behavioral] ==="
T5=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    linear = nn.Linear(16, 8, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([1.0], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(2, 16, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, 8):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print("FAIL:fp8_output")
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.09; fi


# --- T6 (0.08): float32 + scalar fp8 scale (16->8) — dtype generalization ---
echo ""
echo "=== Test 6/15: fp8 forward: float32 + scalar fp8 scale 16->8 [behavioral] ==="
T6=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    linear = nn.Linear(16, 8, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([1.0], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(2, 16, dtype=torch.float32)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, 8):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print("FAIL:fp8_output")
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.08; fi


# --- T7 (0.09): bf16 + per-channel fp8 scale (16->8) — 2D scale path ---
echo ""
echo "=== Test 7/15: fp8 forward: bf16 + per-channel fp8 scale 16->8 [behavioral] ==="
T7=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    in_f, out_f = 16, 8
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.ones(out_f, 1, dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(2, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, out_f):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print("FAIL:fp8_output")
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.09; fi


# --- T8 (0.08): dtype preservation — bf16 + float32 sub-checks ---
echo ""
echo "=== Test 8/15: fp8 forward: output dtype matches input dtype [behavioral] ==="
T8=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

def make_fp8_linear(in_f, out_f):
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([1.0], dtype=torch.float32).to(torch.float8_e4m3fn))
    return linear

passed = 0

# Sub-test A: bf16 in -> bf16 out
try:
    out = fp8_linear_forward_patch(
        make_fp8_linear(16, 8),
        torch.randn(2, 16, dtype=torch.bfloat16),
        use_scaled_mm=False)
    if out is not None and out.dtype == torch.bfloat16:
        passed += 1
except Exception:
    pass

# Sub-test B: float32 in -> float32 out
try:
    out = fp8_linear_forward_patch(
        make_fp8_linear(16, 8),
        torch.randn(2, 16, dtype=torch.float32),
        use_scaled_mm=False)
    if out is not None and out.dtype == torch.float32:
        passed += 1
except Exception:
    pass

if passed == 2:
    print("PASS")
elif passed == 1:
    print("PARTIAL:1/2")
else:
    print("FAIL:no_dtype_match")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then
    add_reward 0.08
elif [[ "$T8" == PARTIAL* ]]; then
    add_reward 0.04
fi


# --- T9 (0.07): 3D batched input (2,4,16) -> (2,4,8) ---
echo ""
echo "=== Test 9/15: fp8 forward: 3D batched input (2,4,16)->(2,4,8) [behavioral] ==="
T9=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    in_f, out_f = 16, 8
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([1.0], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(2, 4, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, 4, out_f):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype != torch.bfloat16:
        print("FAIL:dtype:" + str(out.dtype))
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.07; fi


# --- T10 (0.09): numerical accuracy per-tensor scale=2.0 ---
echo ""
echo "=== Test 10/15: fp8 forward: numerical accuracy per-tensor scale=2.0 [behavioral] ==="
T10=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn
import torch.nn.functional as F

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    torch.manual_seed(42)
    in_f, out_f = 16, 8
    W = torch.randn(out_f, in_f)
    W_fp8 = W.clamp(-448, 448).to(torch.float8_e4m3fn)
    scale_val = 2.0
    scale_fp8 = torch.tensor([scale_val], dtype=torch.float32).to(torch.float8_e4m3fn)

    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(W_fp8, requires_grad=False)
    linear.register_buffer("scale_weight", scale_fp8)

    x = torch.randn(3, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    # Manual reference dequantization
    W_deq = W_fp8.to(torch.bfloat16) * torch.tensor([scale_val], dtype=torch.bfloat16)
    ref = F.linear(x, W_deq)

    if out is None:
        print("FAIL:returns_none")
    elif not torch.allclose(out.float(), ref.float(), atol=0.1, rtol=0.05):
        max_diff = (out.float() - ref.float()).abs().max().item()
        print("FAIL:accuracy:max_diff=" + str(round(max_diff, 4)))
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T10"
if [ "$T10" = "PASS" ]; then add_reward 0.09; fi


# --- T11 (0.09): numerical accuracy per-channel scales ---
echo ""
echo "=== Test 11/15: fp8 forward: numerical accuracy per-channel scales [behavioral] ==="
T11=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn
import torch.nn.functional as F

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    torch.manual_seed(123)
    in_f, out_f = 8, 4
    W = torch.randn(out_f, in_f)
    W_fp8 = W.clamp(-448, 448).to(torch.float8_e4m3fn)
    scale_vals = torch.tensor([[1.0], [2.0], [0.5], [1.5]])
    scale_fp8 = scale_vals.to(torch.float8_e4m3fn)

    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(W_fp8, requires_grad=False)
    linear.register_buffer("scale_weight", scale_fp8)

    x = torch.randn(2, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    # Manual reference dequantization
    W_deq = W_fp8.to(torch.bfloat16) * scale_vals.to(torch.bfloat16)
    ref = F.linear(x, W_deq)

    if out is None:
        print("FAIL:returns_none")
    elif not torch.allclose(out.float(), ref.float(), atol=0.1, rtol=0.05):
        max_diff = (out.float() - ref.float()).abs().max().item()
        print("FAIL:accuracy:max_diff=" + str(round(max_diff, 4)))
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T11"
if [ "$T11" = "PASS" ]; then add_reward 0.09; fi


# --- T12 (0.08): different dims (64->32) + scale=0.5 ---
echo ""
echo "=== Test 12/15: fp8 forward: different dims (64->32) + scale=0.5 [behavioral] ==="
T12=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    in_f, out_f = 64, 32
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([0.5], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(4, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (4, out_f):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype != torch.bfloat16:
        print("FAIL:dtype:" + str(out.dtype))
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T12"
if [ "$T12" = "PASS" ]; then add_reward 0.08; fi


# --- T13 (0.08): wide->narrow (32->4) + scale=128.0 ---
echo ""
echo "=== Test 13/15: fp8 forward: wide->narrow (32->4) + scale=128.0 [behavioral] ==="
T13=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    in_f, out_f = 32, 4
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([128.0], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(1, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (1, out_f):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print("FAIL:fp8_output")
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T13"
if [ "$T13" = "PASS" ]; then add_reward 0.08; fi


# --- T14 (0.07): non-unit scale (24->12) + scale=3.5 + float32 input ---
echo ""
echo "=== Test 14/15: fp8 forward: non-unit scale (24->12) + scale=3.5 + float32 [behavioral] ==="
T14=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch
import torch.nn as nn

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

try:
    in_f, out_f = 24, 12
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False)
    linear.register_buffer("scale_weight",
        torch.tensor([3.5], dtype=torch.float32).to(torch.float8_e4m3fn))

    x = torch.randn(3, in_f, dtype=torch.float32)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (3, out_f):
        print("FAIL:shape:" + str(out.shape))
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print("FAIL:fp8_output")
    else:
        print("PASS")
except RuntimeError as e:
    s = str(e)
    if "mul_cpu" in s or "mul_cuda" in s or "not implemented for" in s:
        print("FAIL:fp8_bug_not_fixed")
    else:
        print("FAIL:runtime:" + s[:80])
except Exception as e:
    print("FAIL:error:" + type(e).__name__ + ":" + str(e)[:80])
PYEOF
)
echo "  Result: $T14"
if [ "$T14" = "PASS" ]; then add_reward 0.07; fi


# ═══════════════════════════════════════════════════════════════════
# T15 (0.08): P2P — upstream CPU-safe test suite
# Runs available CPU-safe tests from the sd-scripts repo to verify
# the agent's changes don't break existing functionality.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 15/15: P2P upstream CPU-safe tests [behavioral] ==="
cd /workspace/sd-scripts

P2P_RESULT="SKIP"
TEST_FILES=""
if [ -d "tests/library" ]; then
    TEST_FILES=$(find tests/library -name "test_*.py" -type f 2>/dev/null | sort | head -10)
fi

if [ -n "$TEST_FILES" ]; then
    python3 -m pytest $TEST_FILES -x --timeout=60 -q -k "not cuda and not gpu" 2>/dev/null
    if [ $? -eq 0 ]; then
        P2P_RESULT="PASS"
    else
        P2P_PASSED=0
        P2P_TOTAL=0
        for tf in $TEST_FILES; do
            P2P_TOTAL=$((P2P_TOTAL + 1))
            python3 -m pytest "$tf" -x --timeout=30 -q -k "not cuda and not gpu" 2>/dev/null
            if [ $? -eq 0 ]; then P2P_PASSED=$((P2P_PASSED + 1)); fi
        done
        if [ "$P2P_TOTAL" -gt 0 ] && [ "$P2P_PASSED" -eq "$P2P_TOTAL" ]; then
            P2P_RESULT="PASS"
        elif [ "$P2P_PASSED" -gt 0 ]; then
            P2P_RESULT="PARTIAL"
        else
            P2P_RESULT="FAIL"
        fi
    fi
else
    if [ -d "tests" ]; then
        ALL_TESTS=$(find tests -name "test_*.py" -type f 2>/dev/null | head -5)
        if [ -n "$ALL_TESTS" ]; then
            python3 -m pytest $ALL_TESTS -x --timeout=60 -q -k "not cuda and not gpu" 2>/dev/null
            if [ $? -eq 0 ]; then P2P_RESULT="PASS"; else P2P_RESULT="FAIL"; fi
        else
            P2P_RESULT="SKIP"
        fi
    fi
fi

echo "  P2P result: $P2P_RESULT"
if [ "$P2P_RESULT" = "PASS" ]; then
    add_reward 0.08
elif [ "$P2P_RESULT" = "PARTIAL" ]; then
    add_reward 0.04
fi


# ═══════════════════════════════════════════════════════════════════
# T16 (0.02): Audit-T2 hardening — TARGET_KEYS must point to real
# NextDiT self.<attr> names in lumina_models.py (not guessed strings).
# Source: user turn 2 ("Do your added keys actually exist in Lumina2?").
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 16/17: TARGET_KEYS grounded in real NextDiT attrs [audit-T2] ==="
T16=$(python3 << 'PYEOF' | tail -1
import re

# 1. Extract TARGET_KEYS literal from the agent's source.
target_keys = []
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        with open(path) as f:
            src = f.read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        target_keys = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        break

if not target_keys:
    print("FAIL:no_target_keys")
else:
    try:
        with open("/workspace/sd-scripts/library/lumina_models.py") as f:
            models_src = f.read()
    except FileNotFoundError:
        print("FAIL:no_models_file")
    else:
        # All `self.<attr> =` names defined anywhere in lumina_models.py.
        # These become the prefixes of state_dict keys consumed by
        # optimize_state_dict_with_fp8 — pattern matching is substring-based.
        real_attrs = set(re.findall(r'self\.(\w+)\s*=', models_src))
        if not real_attrs:
            print("FAIL:no_real_attrs")
        else:
            unmatched = [
                tk for tk in target_keys
                if not any(tk in attr or attr in tk for attr in real_attrs)
            ]
            if unmatched:
                print("FAIL:unmatched:" + ",".join(unmatched[:3]))
            else:
                print("PASS")
PYEOF
)
echo "  Result: $T16"
if [ "$T16" = "PASS" ]; then add_reward 0.02; fi


# ═══════════════════════════════════════════════════════════════════
# T17 (0.02): Audit-T6 hardening — behavioral verification that
# adaLN_modulation weights are NOT quantized to fp8 when the agent's
# EXCLUDE_KEYS are passed to optimize_state_dict_with_fp8.
# Source: user turn 6 (loss regression: 5.0 vs 0.5).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 17/17: adaLN_modulation excluded from fp8 quant [audit-T6] ==="
T17=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, re
sys.path.insert(0, "/tmp")
import _vfp8mock
import torch

# Pull the agent's EXCLUDE_KEYS list from source.
exclude_keys = []
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        with open(path) as f:
            src = f.read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        exclude_keys = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        break

if not exclude_keys:
    print("FAIL:no_exclude_keys")
    sys.exit(0)

try:
    from library.fp8_optimization_utils import optimize_state_dict_with_fp8
except Exception as e:
    print("FAIL:import:" + str(e)[:100])
    sys.exit(0)

# Mock state_dict: one regular layers.* weight (should be quantized) and
# one adaLN_modulation weight (should be EXCLUDED so loss does not regress).
torch.manual_seed(0)
ada_key = "layers.0.adaLN_modulation.1.weight"
reg_key = "layers.0.attention.wqkv.weight"
state_dict = {
    reg_key: torch.randn(64, 64, dtype=torch.float32),
    ada_key: torch.randn(128, 64, dtype=torch.float32),
}

try:
    optimize_state_dict_with_fp8(
        state_dict,
        calc_device="cpu",
        target_layer_keys=["layers"],
        exclude_layer_keys=exclude_keys,
        move_to_device=False,
    )
except Exception as e:
    print("FAIL:call:" + type(e).__name__ + ":" + str(e)[:80])
    sys.exit(0)

ada_w = state_dict.get(ada_key)
reg_w = state_dict.get(reg_key)
ada_scale_in_dict = (ada_key.replace(".weight", ".scale_weight") in state_dict)
reg_scale_in_dict = (reg_key.replace(".weight", ".scale_weight") in state_dict)
fp8_dtypes = (torch.float8_e4m3fn, torch.float8_e5m2)

# adaLN_modulation must remain unquantized (no fp8 dtype, no scale buffer added).
ada_excluded = (ada_w is not None
                and ada_w.dtype not in fp8_dtypes
                and not ada_scale_in_dict)
# Sanity: the regular layers weight should have actually been quantized,
# otherwise the EXCLUDE filter could be vacuously true (e.g., everything skipped).
reg_quantized = (reg_w is not None
                 and (reg_w.dtype in fp8_dtypes or reg_scale_in_dict))

if ada_excluded and reg_quantized:
    print("PASS")
elif not reg_quantized:
    print("FAIL:nothing_quantized")
else:
    print("FAIL:adaln_was_quantized:" + str(ada_w.dtype if ada_w is not None else None))
PYEOF
)
echo "  Result: $T17"
if [ "$T17" = "PASS" ]; then add_reward 0.02; fi


# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
