#!/usr/bin/env bash
#
# Verification tests for ComfyUI NewBie architecture refactoring.
#
# The task: refactor comfy/ldm/newbie/model.py to follow ComfyUI conventions:
# - Use operations.Linear / operations.RMSNorm (not fallback ops)
# - Remove _pop_unexpected_kwargs and _fallback_operations anti-patterns
# - Return -img (not img) from _forward — matches Lumina convention
# - Use t = 1.0 - timesteps (not t = timesteps) — matches Lumina convention
# - Remove nn.init calls from __init__ (not done in ComfyUI)
# - Remove unnecessary try...except for dtype casting in _forward
# - Remove unnecessary apply_model override in NewBieImage
#
# Scoring: 60% behavioral (Silver), 40% structural/absence (Bronze)
#   T1-T8: 0.05 each = 0.40 (structural/absence/AST+stub-rejection)
#   T9:    0.60 compound behavioral (Silver: import+instantiate+call+verify)
#
#   Test 1:  0.05  newbie/model.py parses as valid Python (structural)
#   Test 2:  0.05  NewBieNextDiT inherits NextDiT (structural)
#   Test 3:  0.05  No _pop_unexpected_kwargs (absence)
#   Test 4:  0.05  No _fallback_operations (absence)
#   Test 5:  0.05  _forward returns -img + stub rejection >= 8 calls (Bronze+)
#   Test 6:  0.05  _forward uses t = 1.0 - timesteps + stub rejection (Bronze+)
#   Test 7:  0.05  No nn.init calls in __init__ (absence)
#   Test 8:  0.05  No try...except in _forward (absence)
#   Test 9:  0.60  Behavioral compound: import, instantiate, verify ops,
#                  check model_base.py, call _forward (Silver)
#
# Max stub score: 0.25 (bare stub) to 0.30 (stub with trivial _forward)
# Total: 1.00  (behavioral = 0.60, structural/absence = 0.40)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

MODEL_PY="/workspace/ComfyUI/comfy/ldm/newbie/model.py"
MODEL_BASE_PY="/workspace/ComfyUI/comfy/model_base.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): newbie/model.py parses as valid Python with a class def
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/9: newbie/model.py is valid Python with class ==="
T1=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
    sys.exit(0)

# Must define at least one class
classes = [n.name for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]
if classes:
    print("PASS")
else:
    print("FAIL:no_classes")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.05): Main class inherits from NextDiT (not NextDiTBase)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/9: Class inherits from NextDiT (not NextDiTBase) ==="
T2=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

# Look for class that inherits from NextDiT (not NextDiTBase or an alias)
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        for base in node.bases:
            # NextDiT directly (not NextDiTBase)
            if isinstance(base, ast.Name) and base.id == "NextDiT":
                print("PASS")
                sys.exit(0)
            if isinstance(base, ast.Attribute) and base.attr == "NextDiT":
                print("PASS")
                sys.exit(0)

# Check if NextDiTBase alias is used (means not refactored)
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        for base in node.bases:
            if isinstance(base, ast.Name) and "NextDiTBase" in base.id:
                print("FAIL:still_using_NextDiTBase_alias")
                sys.exit(0)

print("FAIL:no_nextdit_subclass")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.05): No _pop_unexpected_kwargs function (anti-pattern removed)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/9: No _pop_unexpected_kwargs function ==="
T3=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if node.name == "_pop_unexpected_kwargs":
            print("FAIL:function_still_exists")
            sys.exit(0)

# Also check for calls to this function
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Name) and node.func.id == "_pop_unexpected_kwargs":
            print("FAIL:function_still_called")
            sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.05): No _fallback_operations function (anti-pattern removed)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/9: No _fallback_operations function ==="
T4=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if node.name == "_fallback_operations":
            print("FAIL:function_still_exists")
            sys.exit(0)

# Also check for calls to this function
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Name) and node.func.id == "_fallback_operations":
            print("FAIL:function_still_called")
            sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.05): _forward returns -img (not img) + stub rejection
#   Bronze+ tier: AST pattern check + minimum 8 Call nodes to reject stubs
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/9: _forward returns -img + non-trivial body ==="
T5=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

# Find _forward method in any class
for class_node in ast.walk(tree):
    if not isinstance(class_node, ast.ClassDef):
        continue
    for node in class_node.body:
        if not (isinstance(node, ast.FunctionDef) and node.name == "_forward"):
            continue

        # Stub rejection: _forward must have >= 8 Call nodes (real impls have dozens)
        call_count = sum(1 for n in ast.walk(node) if isinstance(n, ast.Call))
        if call_count < 8:
            print(f"FAIL:stub_detected:only_{call_count}_calls_need_8")
            sys.exit(0)

        # Check all return statements
        returns = [n for n in ast.walk(node) if isinstance(n, ast.Return)]
        if not returns:
            print("FAIL:no_return_in_forward")
            sys.exit(0)

        for ret in returns:
            val = ret.value
            # Accept: return -img (UnaryOp with USub and Name "img")
            if isinstance(val, ast.UnaryOp) and isinstance(val.op, ast.USub):
                if isinstance(val.operand, ast.Name) and val.operand.id == "img":
                    print("PASS")
                    sys.exit(0)
                # Also accept: return -img[something] (subscript)
                if isinstance(val.operand, ast.Subscript):
                    print("PASS")
                    sys.exit(0)

        # Check if there's a bare 'return img' without negation
        has_bare_return_img = False
        for ret in returns:
            val = ret.value
            if isinstance(val, ast.Name) and val.id == "img":
                has_bare_return_img = True
            elif isinstance(val, ast.Subscript):
                if not isinstance(val, ast.UnaryOp):
                    if isinstance(val.value, ast.Name) and val.value.id == "img":
                        has_bare_return_img = True

        if has_bare_return_img:
            print("FAIL:returns_positive_img")
        else:
            print("FAIL:no_matching_return_pattern")
        sys.exit(0)

print("FAIL:no_forward_method")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.05): _forward uses t = 1.0 - timesteps (not t = timesteps)
#   Bronze+ tier: AST pattern check + minimum 8 Call nodes to reject stubs
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/9: _forward uses t = 1.0 - timesteps + non-trivial body ==="
T6=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

def is_subtraction_of_timesteps(node):
    """Check if node is (1.0 - timesteps) or (1 - timesteps)."""
    if not isinstance(node, ast.BinOp):
        return False
    if not isinstance(node.op, ast.Sub):
        return False
    # Left side must be 1.0 or 1
    left = node.left
    if not (isinstance(left, ast.Constant) and left.value in (1, 1.0)):
        return False
    # Right side must reference 'timesteps'
    right = node.right
    if isinstance(right, ast.Name) and right.id == "timesteps":
        return True
    return False

# Find _forward method
for class_node in ast.walk(tree):
    if not isinstance(class_node, ast.ClassDef):
        continue
    for node in class_node.body:
        if not (isinstance(node, ast.FunctionDef) and node.name == "_forward"):
            continue

        # Stub rejection: _forward must have >= 8 Call nodes
        call_count = sum(1 for n in ast.walk(node) if isinstance(n, ast.Call))
        if call_count < 8:
            print(f"FAIL:stub_detected:only_{call_count}_calls_need_8")
            sys.exit(0)

        # Walk all assignments in _forward
        for stmt in ast.walk(node):
            if isinstance(stmt, ast.Assign):
                # Check if any target is 't' and value is (1.0 - timesteps)
                for target in stmt.targets:
                    if isinstance(target, ast.Name) and target.id == "t":
                        if is_subtraction_of_timesteps(stmt.value):
                            print("PASS")
                            sys.exit(0)
            elif isinstance(stmt, ast.AnnAssign):
                if isinstance(stmt.target, ast.Name) and stmt.target.id == "t":
                    if is_subtraction_of_timesteps(stmt.value):
                        print("PASS")
                        sys.exit(0)

        # Check for bare t = timesteps (the bug)
        has_bare_t_assign = False
        for stmt in ast.walk(node):
            if isinstance(stmt, ast.Assign):
                for target in stmt.targets:
                    if isinstance(target, ast.Name) and target.id == "t":
                        val = stmt.value
                        if isinstance(val, ast.Name) and val.id == "timesteps":
                            has_bare_t_assign = True

        if has_bare_t_assign:
            print("FAIL:t_equals_timesteps_not_1_minus")
        else:
            print("FAIL:no_t_assignment_found")
        sys.exit(0)

print("FAIL:no_forward_method")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.05): No nn.init calls in __init__ (not the ComfyUI way)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/9: No nn.init calls in __init__ ==="
T7=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

# Find any __init__ method in any class
for class_node in ast.walk(tree):
    if not isinstance(class_node, ast.ClassDef):
        continue
    for node in class_node.body:
        if not (isinstance(node, ast.FunctionDef) and node.name == "__init__"):
            continue

        # Look for nn.init.* calls
        for stmt in ast.walk(node):
            if isinstance(stmt, ast.Call):
                func = stmt.func
                # nn.init.normal_, nn.init.zeros_, etc.
                if isinstance(func, ast.Attribute):
                    if isinstance(func.value, ast.Attribute):
                        if (isinstance(func.value.value, ast.Name) and
                                func.value.value.id == "nn" and
                                func.value.attr == "init"):
                            print(f"FAIL:nn_init_{func.attr}_call_found")
                            sys.exit(0)
                    # Also catch init.zeros_ etc.
                    if func.attr in ("normal_", "zeros_", "ones_", "uniform_",
                                     "xavier_uniform_", "kaiming_normal_",
                                     "constant_", "eye_"):
                        print(f"FAIL:init_{func.attr}_found")
                        sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.05): No try...except in _forward for dtype casting
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/9: No try...except in _forward for dtype ==="
T8=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:parse:{e}")
    sys.exit(0)

# Find _forward method in any class — must exist AND have no try...except
found_forward = False
for class_node in ast.walk(tree):
    if not isinstance(class_node, ast.ClassDef):
        continue
    for node in class_node.body:
        if not (isinstance(node, ast.FunctionDef) and node.name == "_forward"):
            continue
        found_forward = True

        # Check for Try nodes in _forward
        for stmt in ast.walk(node):
            if isinstance(stmt, ast.Try):
                for handler in stmt.handlers:
                    exc_type = handler.type
                    if exc_type is not None:
                        if isinstance(exc_type, ast.Name) and exc_type.id == "StopIteration":
                            print("FAIL:try_except_StopIteration_in_forward")
                            sys.exit(0)
                # Any try in _forward is suspicious for this task
                print("FAIL:try_except_in_forward")
                sys.exit(0)
        # Found _forward with no try/except
        print("PASS")
        sys.exit(0)

if not found_forward:
    print("FAIL:no_forward_method")
else:
    print("PASS")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.60): Compound behavioral test — Silver tier
#   Imports the module, instantiates the model, verifies operations,
#   checks model_base.py, and calls _forward with dummy inputs.
#   Each sub-part awards partial credit independently.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/9: Compound behavioral verification (0.60) ==="
T9=$(python3 << 'PYEOF'
import sys, ast, inspect
sys.path.insert(0, "/workspace/ComfyUI")

score = 0.0

# ---- Part A (0.05): Import module and find NextDiT subclass with own _forward ----
print("  Part A: Import + find subclass with own _forward...")
try:
    import comfy.ldm.newbie.model as newbie_mod
    import comfy.ldm.lumina.model as lumina_mod
    NextDiT = lumina_mod.NextDiT
except Exception as e:
    print(f"  Part A: FAIL (import: {e})")
    print(f"SCORE:{score:.2f}")
    sys.exit(0)

newbie_class = None
for name, obj in inspect.getmembers(newbie_mod, inspect.isclass):
    if issubclass(obj, NextDiT) and obj is not NextDiT:
        newbie_class = obj
        break

if newbie_class is None:
    print("  Part A: FAIL (no NextDiT subclass found)")
    print(f"SCORE:{score:.2f}")
    sys.exit(0)

# Must define its own _forward (not just inherit from NextDiT)
if '_forward' not in newbie_class.__dict__:
    print("  Part A: FAIL (_forward not overridden — bare subclass detected)")
    print(f"SCORE:{score:.2f}")
    sys.exit(0)

# Stub rejection: _forward must be non-trivial (>= 8 Call nodes, matching T5/T6)
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py", "r") as f:
        _src = f.read()
    _tree = ast.parse(_src)
    _fwd_calls = 0
    for _cn in ast.walk(_tree):
        if isinstance(_cn, ast.ClassDef):
            for _item in _cn.body:
                if isinstance(_item, ast.FunctionDef) and _item.name == "_forward":
                    _fwd_calls = sum(1 for _n in ast.walk(_item) if isinstance(_n, ast.Call))
    if _fwd_calls < 8:
        print(f"  Part A: FAIL (_forward too trivial: {_fwd_calls} calls, need >= 8)")
        print(f"SCORE:{score:.2f}")
        sys.exit(0)
except Exception:
    pass  # If AST check fails, skip stub rejection (runtime checks below will catch)

score += 0.05
print(f"  Part A: PASS (found {newbie_class.__name__} with non-trivial _forward)")

# ---- Part B (0.10): Instantiate on CPU ----
print("  Part B: Instantiate on CPU...")
import comfy.ops
ops = comfy.ops.disable_weight_init

model = None
try:
    # axes_dims must sum to dim//n_heads: 256//4=64, so [32,32]
    model = newbie_class(
        patch_size=2,
        in_channels=16,
        dim=256,
        n_layers=2,
        n_heads=4,
        n_kv_heads=2,
        axes_dims=[32, 32],
        axes_lens=[32, 32],
        clip_text_dim=256,
        clip_img_dim=256,
        device="cpu",
        dtype=None,
        operations=ops,
    )
    import torch.nn as nn
    if not isinstance(model, nn.Module):
        print(f"  Part B: FAIL (not nn.Module: {type(model).__name__})")
        print(f"SCORE:{score:.2f}")
        sys.exit(0)
    score += 0.10
    print(f"  Part B: PASS (instantiated on CPU)")
except Exception as e:
    print(f"  Part B: FAIL (instantiation: {e})")
    print(f"SCORE:{score:.2f}")
    sys.exit(0)

# ---- Part C (0.10): Model has substantial parameters (not a stub) ----
print("  Part C: Check parameter count and Linear submodules...")
param_count = sum(p.numel() for p in model.parameters())
has_linear = any(isinstance(m, nn.Linear) for m in model.modules() if m is not model)

if param_count > 10000 and has_linear:
    score += 0.10
    print(f"  Part C: PASS ({param_count} params, has Linear layers)")
elif param_count <= 10000:
    print(f"  Part C: FAIL (only {param_count} params — likely stub)")
else:
    print(f"  Part C: FAIL (no Linear submodules found)")

# ---- Part D (0.10): NewBieImage in model_base.py has no apply_model override ----
print("  Part D: Check NewBieImage has no apply_model...")
try:
    with open("/workspace/ComfyUI/comfy/model_base.py", "r") as f:
        mb_source = f.read()
    mb_tree = ast.parse(mb_source)

    found_newbie_image = False
    has_apply_model = False
    for node in ast.walk(mb_tree):
        if isinstance(node, ast.ClassDef) and node.name == "NewBieImage":
            found_newbie_image = True
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == "apply_model":
                    has_apply_model = True

    if found_newbie_image and not has_apply_model:
        score += 0.10
        print(f"  Part D: PASS (NewBieImage has no apply_model)")
    elif not found_newbie_image:
        print(f"  Part D: FAIL (NewBieImage class not found)")
    else:
        print(f"  Part D: FAIL (apply_model still present)")
except Exception as e:
    print(f"  Part D: FAIL ({e})")

# ---- Part E (0.10): Model uses operations-based Linear (not raw nn.Linear) ----
print("  Part E: Check operations.Linear usage...")
has_ops_linear = False
has_raw_nn_linear = False
for mod_name, mod in model.named_modules():
    if mod is model:
        continue
    if isinstance(mod, nn.Linear):
        # comfy.ops.disable_weight_init.Linear is a subclass of nn.Linear
        # but type(mod) is NOT nn.Linear itself
        if type(mod) is nn.Linear:
            has_raw_nn_linear = True
        else:
            has_ops_linear = True

if has_ops_linear and not has_raw_nn_linear:
    score += 0.10
    print(f"  Part E: PASS (uses operations.Linear, not raw nn.Linear)")
elif has_raw_nn_linear:
    print(f"  Part E: FAIL (uses raw nn.Linear instead of operations.Linear)")
elif not has_ops_linear:
    print(f"  Part E: FAIL (no Linear modules found)")
else:
    print(f"  Part E: FAIL (mix of raw and ops Linear)")

# ---- Part F (0.15): Call _forward with dummy inputs and get tensor output ----
print("  Part F: Call _forward with dummy inputs...")
import torch

try:
    sig = inspect.signature(model._forward)
    params = dict(sig.parameters)

    batch = 1
    dim = 256
    # Build kwargs for _forward based on parameter names
    kwargs = {}
    for pname, param in params.items():
        if pname == 'self':
            continue
        if pname in ('x', 'img'):
            kwargs[pname] = torch.randn(batch, 16, 4, 4)
        elif pname == 'timesteps':
            kwargs[pname] = torch.tensor([0.5])
        elif pname in ('context', 'y'):
            kwargs[pname] = torch.randn(batch, 8, dim)
        elif pname in ('clip_text_embed',):
            kwargs[pname] = torch.randn(batch, dim)
        elif pname in ('clip_img_embed',):
            kwargs[pname] = torch.randn(batch, dim)
        elif pname in ('adaln_input',):
            kwargs[pname] = torch.randn(batch, dim)
        elif param.default != inspect.Parameter.empty:
            continue  # use default value
        elif param.kind == inspect.Parameter.VAR_KEYWORD:
            continue  # **kwargs
        elif param.kind == inspect.Parameter.VAR_POSITIONAL:
            continue  # *args
        else:
            kwargs[pname] = None

    with torch.no_grad():
        result = model._forward(**kwargs)

    if isinstance(result, torch.Tensor):
        score += 0.15
        print(f"  Part F: PASS (_forward returned tensor shape {list(result.shape)})")
    else:
        print(f"  Part F: FAIL (returned {type(result).__name__}, not tensor)")
except Exception as e:
    print(f"  Part F: FAIL (_forward call: {e})")

print(f"SCORE:{score:.2f}")
PYEOF
)
echo "  Result: $T9"
# Extract score from SCORE:X.XX format (last SCORE line)
T9_SCORE=$(echo "$T9" | grep -oP 'SCORE:\K[0-9.]+' | tail -1)
if [ -n "$T9_SCORE" ] && [ "$T9_SCORE" != "0.00" ]; then
    add_reward "$T9_SCORE"
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
