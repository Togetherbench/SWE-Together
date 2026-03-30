#!/usr/bin/env bash
#
# Verification tests for fp8_scaled implementation for the Lumina model in sd-scripts.
#
# The agent must:
#   1. library/lumina_util.py: Add FP8_OPTIMIZATION_TARGET_KEYS (containing "layers")
#      and FP8_OPTIMIZATION_EXCLUDE_KEYS (containing "modulation" to prevent loss regression),
#      modify load_lumina_model to accept fp8_scaled and call apply_fp8_monkey_patch
#   2. library/lumina_train_util.py: Add --fp8_scaled CLI argument
#   3. library/fp8_optimization_utils.py: Fix fp8_linear_forward_patch to cast
#      scale_weight to x.dtype (not fp8) before dequantization multiply
#
# Scoring breakdown (behavioral=90%, structural=5%, P2P=5%):
#   Test 1: 0.05  TARGET_KEYS importable, non-empty, contains "layers" (Silver)
#   Test 2: 0.10  EXCLUDE_KEYS importable, contains "modulation" (Silver)
#   Test 3: 0.07  load_lumina_model fp8_scaled integration (Silver)
#   Test 4: 0.28  CORE BUG: fp8 per-tensor scale_weight multiply (F2P)
#   Test 5: 0.10  fp8 per-channel (2D) scale_weight (F2P)
#   Test 6: 0.15  Output dtype matches input dtype (F2P)
#   Test 7: 0.15  Numerical accuracy of fp8 dequantization (Gold)
#   Test 8: 0.05  --fp8_scaled CLI argument (Bronze/AST)
#   Test 9: 0.05  Upstream CPU-safe test suite regression (P2P)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

MOCK_SETUP='
import sys
from unittest.mock import MagicMock
mock_cv2 = MagicMock(); mock_cv2.__spec__ = MagicMock()
sys.modules["cv2"] = mock_cv2
for mod in ["diffusers", "diffusers.schedulers",
            "diffusers.schedulers.scheduling_euler_ancestral_discrete"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()
sys.path.insert(0, "/workspace/sd-scripts")
'

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): FP8_OPTIMIZATION_TARGET_KEYS importable and correct
#   Silver: import constant, verify it's a non-empty list containing "layers"
#   (NextDiT's main transformer blocks use self.layers)
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/9: TARGET_KEYS importable and contains 'layers' ==="
T1=$(python3 2>/dev/null << PYEOF | tail -1
${MOCK_SETUP}

try:
    from library.lumina_util import FP8_OPTIMIZATION_TARGET_KEYS
except (ImportError, Exception) as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

if not isinstance(FP8_OPTIMIZATION_TARGET_KEYS, (list, tuple)):
    print(f"FAIL:not_list:{type(FP8_OPTIMIZATION_TARGET_KEYS)}")
    sys.exit(0)

if len(FP8_OPTIMIZATION_TARGET_KEYS) == 0:
    print("FAIL:empty")
    sys.exit(0)

if "layers" not in FP8_OPTIMIZATION_TARGET_KEYS:
    print(f"FAIL:no_layers:{FP8_OPTIMIZATION_TARGET_KEYS}")
    sys.exit(0)

# Cross-reference: verify "layers" exists as an attribute in the Lumina model source
with open("/workspace/sd-scripts/library/lumina_models.py") as f:
    src = f.read()
if "self.layers" not in src:
    print("FAIL:layers_not_in_model")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.10): FP8_OPTIMIZATION_EXCLUDE_KEYS contains "modulation"
#   Silver: import constant, verify "modulation" is present.
#   adaLN_modulation layers must be excluded from fp8 quantization —
#   the session discovered that quantizing them causes loss regression (5.0 vs 0.5).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/9: EXCLUDE_KEYS importable and contains 'modulation' ==="
T2=$(python3 2>/dev/null << PYEOF | tail -1
${MOCK_SETUP}

try:
    from library.lumina_util import FP8_OPTIMIZATION_EXCLUDE_KEYS
except (ImportError, Exception) as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

if not isinstance(FP8_OPTIMIZATION_EXCLUDE_KEYS, (list, tuple)):
    print(f"FAIL:not_list:{type(FP8_OPTIMIZATION_EXCLUDE_KEYS)}")
    sys.exit(0)

has_modulation = any("modulation" in k for k in FP8_OPTIMIZATION_EXCLUDE_KEYS)
if not has_modulation:
    print(f"FAIL:no_modulation:{FP8_OPTIMIZATION_EXCLUDE_KEYS}")
    sys.exit(0)

# Cross-reference: verify "modulation" appears in the Lumina model
with open("/workspace/sd-scripts/library/lumina_models.py") as f:
    src = f.read()
if "modulation" not in src:
    print("FAIL:modulation_not_in_model")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.07): load_lumina_model fp8_scaled integration
#   Silver: import load_lumina_model, verify fp8_scaled parameter exists (0.03),
#   and verify apply_fp8_monkey_patch is called in the function body (0.04).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/9: load_lumina_model fp8_scaled integration ==="
T3=$(python3 2>/dev/null << PYEOF | tail -1
${MOCK_SETUP}
import inspect

try:
    from library.lumina_util import load_lumina_model
except (ImportError, Exception) as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

score = 0

# Sub-check A: fp8_scaled parameter exists
sig = inspect.signature(load_lumina_model)
if "fp8_scaled" in sig.parameters:
    score += 1

# Sub-check B: apply_fp8_monkey_patch is called within the function
try:
    func_source = inspect.getsource(load_lumina_model)
    if "apply_fp8_monkey_patch" in func_source:
        score += 1
except Exception:
    pass

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
    add_reward 0.07
elif [ "$T3" = "PARTIAL" ]; then
    add_reward 0.03
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.28): CORE BUG — fp8_linear_forward_patch with per-tensor fp8 scale_weight
#   Original bug: original_dtype = self.scale_weight.dtype → fp8, then
#   self.weight.to(fp8) * fp8_scale_weight raises RuntimeError: "mul_cpu"
#   not implemented for 'Float8_e4m3fn'.
#   Fix: use x.dtype as original_dtype, cast scale_weight to x.dtype.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/9: fp8_linear_forward_patch per-tensor fp8 scale_weight (CORE BUG) ==="
T4=$(python3 2>/dev/null << PYEOF | tail -1
import sys, torch, torch.nn as nn
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
for mod in ["diffusers", "diffusers.schedulers",
            "diffusers.schedulers.scheduling_euler_ancestral_discrete", "cv2"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

try:
    linear = nn.Linear(16, 8, bias=False)
    # Cast weight to fp8 (simulating a quantized layer)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    # Per-tensor scale_weight stored in fp8 — this is the bug trigger
    linear.register_buffer(
        "scale_weight",
        torch.tensor([1.0], dtype=torch.float8_e4m3fn)
    )

    x = torch.randn(2, 16, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, 8):
        print(f"FAIL:wrong_shape:{out.shape}")
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print(f"FAIL:output_is_fp8:{out.dtype}")
    else:
        print("PASS")

except RuntimeError as e:
    msg = str(e)
    if "mul_cpu" in msg or "mul_cuda" in msg or "not implemented for" in msg:
        print(f"FAIL:bug_not_fixed:{msg[:100]}")
    else:
        print(f"FAIL:runtime_error:{msg[:100]}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{str(e)[:100]}")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.28; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.10): fp8_linear_forward_patch with per-channel (2D) fp8 scale_weight
#   The dequantization code has a branch for ndim < 3 (per-tensor/channel).
#   This exercises the per-channel path with scale shape [out_features, 1].
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/9: fp8_linear_forward_patch per-channel (2D) fp8 scale_weight ==="
T5=$(python3 2>/dev/null << PYEOF | tail -1
import sys, torch, torch.nn as nn
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
for mod in ["diffusers", "diffusers.schedulers",
            "diffusers.schedulers.scheduling_euler_ancestral_discrete", "cv2"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

try:
    out_features, in_features = 8, 16
    linear = nn.Linear(in_features, out_features, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    # Per-channel scale: shape [out_features, 1], stored in fp8
    linear.register_buffer(
        "scale_weight",
        torch.ones(out_features, 1, dtype=torch.float32).to(torch.float8_e4m3fn)
    )

    x = torch.randn(2, in_features, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    if out is None:
        print("FAIL:returns_none")
    elif out.shape != (2, out_features):
        print(f"FAIL:wrong_shape:{out.shape}")
    elif out.dtype in (torch.float8_e4m3fn, torch.float8_e5m2):
        print(f"FAIL:output_is_fp8:{out.dtype}")
    else:
        print("PASS")

except RuntimeError as e:
    msg = str(e)
    if "mul_cpu" in msg or "mul_cuda" in msg or "not implemented for" in msg:
        print(f"FAIL:bug_not_fixed:{msg[:100]}")
    else:
        print(f"FAIL:runtime_error:{msg[:100]}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{str(e)[:100]}")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.15): fp8_linear_forward_patch output dtype matches input dtype
#   The fixed code must dequantize using x.dtype, so output should match input.
#   Tests float32, bfloat16, and 3D batched input.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/9: fp8_linear_forward_patch output dtype matches input dtype ==="
T6=$(python3 2>/dev/null << PYEOF | tail -1
import sys, torch, torch.nn as nn
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
for mod in ["diffusers", "diffusers.schedulers",
            "diffusers.schedulers.scheduling_euler_ancestral_discrete", "cv2"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

def make_fp8_linear(in_f, out_f):
    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    linear.register_buffer(
        "scale_weight",
        torch.tensor([1.0], dtype=torch.float8_e4m3fn)
    )
    return linear

passed = 0
total = 3

# Sub-test A: float32 input -> float32 output
try:
    out = fp8_linear_forward_patch(make_fp8_linear(8, 4), torch.randn(1, 8, dtype=torch.float32), use_scaled_mm=False)
    if out is not None and out.dtype == torch.float32:
        passed += 1
except Exception:
    pass

# Sub-test B: bfloat16 input -> bfloat16 output
try:
    out = fp8_linear_forward_patch(make_fp8_linear(32, 16), torch.randn(4, 32, dtype=torch.bfloat16), use_scaled_mm=False)
    if out is not None and out.dtype == torch.bfloat16:
        passed += 1
except Exception:
    pass

# Sub-test C: 3D input (batch, seq, hidden) — typical transformer shape
try:
    out = fp8_linear_forward_patch(make_fp8_linear(16, 8), torch.randn(2, 4, 16, dtype=torch.bfloat16), use_scaled_mm=False)
    if out is not None and out.shape == (2, 4, 8) and out.dtype == torch.bfloat16:
        passed += 1
except Exception:
    pass

if passed == total:
    print("PASS")
elif passed > 0:
    print(f"PARTIAL:{passed}/{total}")
else:
    print("FAIL:no_subtests_passed")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then
    add_reward 0.15
elif [[ "$T6" == PARTIAL:* ]]; then
    P_COUNT=$(echo "$T6" | grep -oP '\d+(?=/)')
    if [ "$P_COUNT" -ge 2 ]; then
        add_reward 0.10
    else
        add_reward 0.05
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.15): Numerical accuracy of fp8 dequantization
#   Gold: create known weights, quantize to fp8 with a known scale,
#   call fp8_linear_forward_patch, compare to manual reference
#   (W_fp8.to(x.dtype) * scale.to(x.dtype)) within tolerance.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/9: Numerical accuracy of fp8 dequantization ==="
T7=$(python3 2>/dev/null << PYEOF | tail -1
import sys, torch, torch.nn as nn, torch.nn.functional as F
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
for mod in ["diffusers", "diffusers.schedulers",
            "diffusers.schedulers.scheduling_euler_ancestral_discrete", "cv2"]:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

passed = 0
total = 2

# Sub-test A: per-tensor scale, known values
try:
    torch.manual_seed(42)
    in_f, out_f = 16, 8
    W = torch.randn(out_f, in_f)
    W_fp8 = W.clamp(-448, 448).to(torch.float8_e4m3fn)
    scale_val = 2.0  # representable in fp8
    scale_fp8 = torch.tensor([scale_val], dtype=torch.float8_e4m3fn)

    linear = nn.Linear(in_f, out_f, bias=False)
    linear.weight = nn.Parameter(W_fp8, requires_grad=False)
    linear.register_buffer("scale_weight", scale_fp8)

    x = torch.randn(3, in_f, dtype=torch.bfloat16)
    out = fp8_linear_forward_patch(linear, x, use_scaled_mm=False)

    # Reference: manual dequantization in bfloat16
    W_deq = W_fp8.to(torch.bfloat16) * torch.tensor([scale_val], dtype=torch.bfloat16)
    ref = F.linear(x, W_deq)

    if out is not None and torch.allclose(out.float(), ref.float(), atol=0.1, rtol=0.05):
        passed += 1
except Exception:
    pass

# Sub-test B: per-channel scale
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

    # Reference
    W_deq = W_fp8.to(torch.bfloat16) * scale_vals.to(torch.bfloat16)
    ref = F.linear(x, W_deq)

    if out is not None and torch.allclose(out.float(), ref.float(), atol=0.1, rtol=0.05):
        passed += 1
except Exception:
    pass

if passed == total:
    print("PASS")
elif passed > 0:
    print(f"PARTIAL:{passed}/{total}")
else:
    print("FAIL:no_subtests_passed")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then
    add_reward 0.15
elif [[ "$T7" == PARTIAL:* ]]; then
    add_reward 0.08
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.05): --fp8_scaled CLI argument added to lumina_train_util.py
#   Bronze/AST: can't easily call the argparser without full CLI env.
#   Checks that add_argument("--fp8_scaled", ...) exists.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/9: --fp8_scaled CLI argument in lumina_train_util.py ==="
T8=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/lumina_train_util.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
    sys.exit(0)

for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == "add_argument":
            for arg in node.args:
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and "fp8_scaled" in arg.value:
                    print("PASS")
                    sys.exit(0)
            for kw in node.keywords:
                if kw.arg == "dest" and isinstance(kw.value, ast.Constant) and "fp8_scaled" in str(kw.value.value):
                    print("PASS")
                    sys.exit(0)

print("FAIL:not_found")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.05): PASS-TO-PASS — upstream CPU-safe test suite
#   Runs available CPU-safe tests from the sd-scripts repo to verify
#   the agent's changes don't break existing functionality.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/9: Upstream CPU-safe test suite (P2P) ==="
cd /workspace/sd-scripts

# Discover available test files in tests/library/ (CPU-safe subset)
P2P_RESULT="SKIP"
TEST_FILES=""
if [ -d "tests/library" ]; then
    TEST_FILES=$(find tests/library -name "test_*.py" -type f 2>/dev/null | sort | head -10)
fi

if [ -n "$TEST_FILES" ]; then
    # Run discovered tests, skip any that require CUDA
    python3 -m pytest $TEST_FILES -x --timeout=60 -q -k "not cuda and not gpu" 2>/dev/null
    if [ $? -eq 0 ]; then
        P2P_RESULT="PASS"
    else
        # Try running just the ones that don't import cuda
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
    # No test files found — check for any tests at all
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
    add_reward 0.05
elif [ "$P2P_RESULT" = "PARTIAL" ]; then
    add_reward 0.03
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
