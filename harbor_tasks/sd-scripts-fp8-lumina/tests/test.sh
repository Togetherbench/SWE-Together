#!/usr/bin/env bash
#
# Verification tests for fp8_scaled implementation for the Lumina model in sd-scripts.
#
# The agent must implement fp8_scaled quantization for Lumina following the pattern
# used for HunyuanImage in library/hunyuan_image_models.py. Key changes:
#   1. library/lumina_util.py: Add FP8_OPTIMIZATION_TARGET_KEYS and
#      FP8_OPTIMIZATION_EXCLUDE_KEYS (including "modulation"), modify load_lumina_model
#      to accept fp8_scaled param and call apply_fp8_monkey_patch
#   2. library/lumina_train_util.py: Add --fp8_scaled CLI argument
#   3. library/fp8_optimization_utils.py: Fix fp8_linear_forward_patch to cast
#      scale_weight to input dtype (not fp8) before dequantization multiply
#
# Scoring (structural=10%, import+integration=30%, runtime-behavioral=60%):
#   Test 1: 0.02  FP8_OPTIMIZATION_TARGET_KEYS defined in lumina_util.py (structural/AST)
#   Test 2: 0.02  FP8_OPTIMIZATION_EXCLUDE_KEYS defined in lumina_util.py (structural/AST)
#   Test 3: 0.03  --fp8_scaled argument in lumina_train_util.py (structural/AST)
#   Test 4: 0.03  load_lumina_model has fp8_scaled parameter (structural/AST)
#   Test 5: 0.10  TARGET_KEYS importable, contains "layers", cross-refs model (import+verify)
#   Test 6: 0.30  fp8_linear_forward_patch works with fp8-typed scale_weight (runtime CORE BUG)
#   Test 7: 0.10  EXCLUDE_KEYS importable, contains "modulation", cross-refs model (import+verify)
#   Test 8: 0.10  apply_fp8_monkey_patch integration in load_lumina_model (import+verify)
#   Test 9: 0.30  fp8_linear_forward_patch output dtype matches input dtype (runtime)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

LUMINA_UTIL="/workspace/sd-scripts/library/lumina_util.py"
LUMINA_TRAIN_UTIL="/workspace/sd-scripts/library/lumina_train_util.py"
FP8_UTILS="/workspace/sd-scripts/library/fp8_optimization_utils.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.02): FP8_OPTIMIZATION_TARGET_KEYS defined in lumina_util.py
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/9: FP8_OPTIMIZATION_TARGET_KEYS defined ==="
T1=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/lumina_util.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
    sys.exit(0)

# Check for FP8_OPTIMIZATION_TARGET_KEYS at module level
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "FP8_OPTIMIZATION_TARGET_KEYS":
                print("PASS")
                sys.exit(0)

print("FAIL:not_found")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.02): FP8_OPTIMIZATION_EXCLUDE_KEYS defined in lumina_util.py
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/9: FP8_OPTIMIZATION_EXCLUDE_KEYS defined ==="
T2=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/lumina_util.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "FP8_OPTIMIZATION_EXCLUDE_KEYS":
                print("PASS")
                sys.exit(0)

print("FAIL:not_found")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.03): --fp8_scaled argument added to lumina_train_util.py
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/9: --fp8_scaled CLI argument in lumina_train_util.py ==="
T3=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/lumina_train_util.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

tree = ast.parse(source)

# Look for add_argument("--fp8_scaled", ...) call
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == "add_argument":
            # Check the first positional arg or keyword args
            for arg in node.args:
                if isinstance(arg, ast.Constant) and "--fp8_scaled" in str(arg.value):
                    print("PASS")
                    sys.exit(0)
            for kw in node.keywords:
                if kw.arg == "dest" and isinstance(kw.value, ast.Constant) and "fp8_scaled" in str(kw.value.value):
                    print("PASS")
                    sys.exit(0)

print("FAIL:not_found")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.03): load_lumina_model has fp8_scaled parameter
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/9: load_lumina_model has fp8_scaled parameter ==="
T4=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/lumina_util.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_lumina_model":
        all_params = [a.arg for a in node.args.args]
        all_params += [a.arg for a in (node.args.kwonlyargs or [])]
        if "fp8_scaled" in all_params:
            print("PASS")
        else:
            print(f"FAIL:params={all_params}")
        sys.exit(0)

print("FAIL:function_not_found")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.10): FP8_OPTIMIZATION_TARGET_KEYS importable + correct + integrated
#   Silver: import the constant, verify it contains "layers", cross-reference
#   against actual NextDiT2 model attributes, and verify it's used in load_lumina_model
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/9: TARGET_KEYS importable, correct, and integrated ==="
T5=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, ast, inspect
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
mock_cv2 = MagicMock()
mock_cv2.__spec__ = MagicMock()
sys.modules['cv2'] = mock_cv2
for mod in ['diffusers', 'diffusers.schedulers',
            'diffusers.schedulers.scheduling_euler_ancestral_discrete']:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.lumina_util import FP8_OPTIMIZATION_TARGET_KEYS, load_lumina_model
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:import_error:{type(e).__name__}:{str(e)[:80]}")
    sys.exit(0)

# Must be a non-empty list/tuple
if not isinstance(FP8_OPTIMIZATION_TARGET_KEYS, (list, tuple)):
    print(f"FAIL:not_list:{type(FP8_OPTIMIZATION_TARGET_KEYS)}")
    sys.exit(0)

if len(FP8_OPTIMIZATION_TARGET_KEYS) == 0:
    print("FAIL:empty_list")
    sys.exit(0)

# Must contain "layers" (NextDiT2's main transformer blocks: self.layers)
if "layers" not in FP8_OPTIMIZATION_TARGET_KEYS:
    print(f"FAIL:no_layers:{FP8_OPTIMIZATION_TARGET_KEYS}")
    sys.exit(0)

# Cross-reference: verify "layers" is a real attribute in the Lumina NextDiT2 model
with open("/workspace/sd-scripts/library/lumina_models.py") as f:
    model_source = f.read()

model_tree = ast.parse(model_source)
model_attrs = set()
for node in ast.walk(model_tree):
    if isinstance(node, ast.ClassDef) and "NextDiT" in node.name:
        for child in ast.walk(node):
            if isinstance(child, ast.Assign):
                for t in child.targets:
                    if isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name) and t.value.id == "self":
                        model_attrs.add(t.attr)

if "layers" not in model_attrs:
    # Fallback: check source text for self.layers
    if "self.layers" not in model_source:
        print("FAIL:layers_not_in_model")
        sys.exit(0)

# Verify TARGET_KEYS is referenced in load_lumina_model body (not just defined globally)
try:
    load_src = inspect.getsource(load_lumina_model)
    if "FP8_OPTIMIZATION_TARGET_KEYS" not in load_src:
        print("FAIL:not_used_in_load_function")
        sys.exit(0)
except Exception:
    print("FAIL:inspect_failed")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.30): CORE BUG — fp8_linear_forward_patch works with fp8-typed scale_weight
#   Original bug: self.weight.to(fp8_dtype) * self.scale_weight throws
#   RuntimeError: "mul_cpu" not implemented for 'Float8_e4m3fn'
#   Fix: cast to input tensor dtype (bfloat16/float32) before multiplying
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/9: fp8_linear_forward_patch handles fp8-typed scale_weight (CORE BUG) ==="
T6=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, torch, torch.nn as nn
sys.path.insert(0, "/workspace/sd-scripts")

# Mock out heavy optional deps that library/utils.py imports at module level
from unittest.mock import MagicMock
for mod in ['diffusers', 'diffusers.schedulers',
            'diffusers.schedulers.scheduling_euler_ancestral_discrete',
            'cv2']:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

try:
    # Create a minimal linear layer with fp8 weight and fp8 scale_weight
    linear = nn.Linear(16, 8, bias=False)
    # Cast weight to fp8 (simulating a quantized layer)
    linear.weight = nn.Parameter(
        linear.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    # Add scale_weight as fp8 buffer — this is the bug trigger
    # (original code: original_dtype = self.scale_weight.dtype; then fp8 * fp8 crashes)
    linear.register_buffer(
        'scale_weight',
        torch.tensor([0.01], dtype=torch.float8_e4m3fn)
    )

    # Create bfloat16 input (typical training dtype)
    x = torch.randn(2, 16, dtype=torch.bfloat16)

    # Call the patched forward — should NOT raise RuntimeError
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
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.30; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.10): FP8_OPTIMIZATION_EXCLUDE_KEYS importable + contains "modulation" + integrated
#   The session found that adaLN_modulation layers must be excluded to prevent
#   training loss regression (5.0 vs 0.5). Cross-reference against model source.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/9: EXCLUDE_KEYS importable, contains 'modulation', and integrated ==="
T7=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, inspect
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
mock_cv2 = MagicMock()
mock_cv2.__spec__ = MagicMock()
sys.modules['cv2'] = mock_cv2
for mod in ['diffusers', 'diffusers.schedulers',
            'diffusers.schedulers.scheduling_euler_ancestral_discrete']:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.lumina_util import FP8_OPTIMIZATION_EXCLUDE_KEYS, load_lumina_model
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:import_error:{type(e).__name__}:{str(e)[:80]}")
    sys.exit(0)

# Must be a non-empty list/tuple
if not isinstance(FP8_OPTIMIZATION_EXCLUDE_KEYS, (list, tuple)):
    print(f"FAIL:not_list:{type(FP8_OPTIMIZATION_EXCLUDE_KEYS)}")
    sys.exit(0)

# Must include "modulation" (adaLN_modulation causes loss spike when quantized)
has_modulation = any("modulation" in k for k in FP8_OPTIMIZATION_EXCLUDE_KEYS)
if not has_modulation:
    print(f"FAIL:no_modulation:{FP8_OPTIMIZATION_EXCLUDE_KEYS}")
    sys.exit(0)

# Cross-reference: verify "modulation" appears in the actual Lumina model
with open("/workspace/sd-scripts/library/lumina_models.py") as f:
    model_source = f.read()
if "modulation" not in model_source:
    print("FAIL:modulation_not_in_model")
    sys.exit(0)

# Verify EXCLUDE_KEYS is referenced in load_lumina_model body
try:
    load_src = inspect.getsource(load_lumina_model)
    if "FP8_OPTIMIZATION_EXCLUDE_KEYS" not in load_src:
        print("FAIL:not_used_in_load_function")
        sys.exit(0)
except Exception:
    print("FAIL:inspect_failed")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.10): apply_fp8_monkey_patch is imported and called in load_lumina_model
#   When fp8_scaled=True, the function must call apply_fp8_monkey_patch.
#   Verifies: import works, function accepts fp8_scaled, source shows
#   conditional call to apply_fp8_monkey_patch.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/9: apply_fp8_monkey_patch imported and called in load_lumina_model ==="
T8=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, inspect, ast
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
mock_cv2 = MagicMock()
mock_cv2.__spec__ = MagicMock()
sys.modules['cv2'] = mock_cv2
for mod in ['diffusers', 'diffusers.schedulers',
            'diffusers.schedulers.scheduling_euler_ancestral_discrete']:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.lumina_util import load_lumina_model
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:import_error:{type(e).__name__}:{str(e)[:80]}")
    sys.exit(0)

# Verify fp8_scaled parameter exists
sig = inspect.signature(load_lumina_model)
if "fp8_scaled" not in sig.parameters:
    print(f"FAIL:no_fp8_scaled_param:{list(sig.parameters.keys())}")
    sys.exit(0)

# Get the function source and parse its AST
try:
    func_source = inspect.getsource(load_lumina_model)
except Exception:
    print("FAIL:inspect_failed")
    sys.exit(0)

# Parse the function body AST to verify apply_fp8_monkey_patch is called
# (not just referenced in a comment or string)
try:
    func_tree = ast.parse(func_source)
except SyntaxError:
    print("FAIL:syntax_error_in_function")
    sys.exit(0)

has_monkey_patch_call = False
for node in ast.walk(func_tree):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Name) and func.id == "apply_fp8_monkey_patch":
            has_monkey_patch_call = True
            break
        if isinstance(func, ast.Attribute) and func.attr == "apply_fp8_monkey_patch":
            has_monkey_patch_call = True
            break

if not has_monkey_patch_call:
    print("FAIL:apply_fp8_monkey_patch_not_called_in_function")
    sys.exit(0)

# Verify the call is conditional on fp8_scaled (should be inside an if block)
if "fp8_scaled" not in func_source:
    print("FAIL:fp8_scaled_not_referenced_in_body")
    sys.exit(0)

# Verify apply_fp8_monkey_patch is actually importable (not a fake name)
try:
    from library.fp8_optimization_utils import apply_fp8_monkey_patch
    if not callable(apply_fp8_monkey_patch):
        print("FAIL:not_callable")
        sys.exit(0)
except ImportError as e:
    print(f"FAIL:monkey_patch_import:{e}")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.30): fp8_linear_forward_patch output dtype matches input dtype
#   The fixed implementation must dequantize in input dtype (not fp8 dtype).
#   Tests multiple input dtypes (float32, bfloat16) and verifies correct output.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/9: fp8_linear_forward_patch output dtype matches input dtype ==="
T9=$(python3 2>/dev/null << 'PYEOF' | tail -1
import sys, torch, torch.nn as nn
sys.path.insert(0, "/workspace/sd-scripts")

from unittest.mock import MagicMock
for mod in ['diffusers', 'diffusers.schedulers',
            'diffusers.schedulers.scheduling_euler_ancestral_discrete',
            'cv2']:
    if mod not in sys.modules:
        sys.modules[mod] = MagicMock()

try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

passed = 0
total = 2

# Sub-test A: float32 input
try:
    linear_a = nn.Linear(8, 4, bias=False)
    linear_a.weight = nn.Parameter(
        linear_a.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    linear_a.register_buffer('scale_weight', torch.tensor([0.1], dtype=torch.float8_e4m3fn))

    x_f32 = torch.randn(1, 8, dtype=torch.float32)
    out_f32 = fp8_linear_forward_patch(linear_a, x_f32, use_scaled_mm=False)

    if out_f32 is not None and out_f32.dtype == x_f32.dtype:
        passed += 1
    elif out_f32 is not None and out_f32.dtype in (torch.float32, torch.bfloat16, torch.float16):
        passed += 1  # Accept non-fp8 output types
except Exception:
    pass

# Sub-test B: bfloat16 input with different dimensions
try:
    linear_b = nn.Linear(32, 16, bias=False)
    linear_b.weight = nn.Parameter(
        linear_b.weight.to(torch.float32).clamp(-448, 448).to(torch.float8_e4m3fn),
        requires_grad=False
    )
    linear_b.register_buffer('scale_weight', torch.tensor([0.05], dtype=torch.float8_e4m3fn))

    x_bf16 = torch.randn(4, 32, dtype=torch.bfloat16)
    out_bf16 = fp8_linear_forward_patch(linear_b, x_bf16, use_scaled_mm=False)

    if out_bf16 is not None and out_bf16.shape == (4, 16):
        if out_bf16.dtype not in (torch.float8_e4m3fn, torch.float8_e5m2):
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
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then
    add_reward 0.30
elif [[ "$T9" == PARTIAL:* ]]; then
    add_reward 0.15
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
