#!/usr/bin/env bash
#
# Verification test for ComfyUI-WanVideoWrapper Triton AMD GPU fix.
#
# Bug: In _attn_fwd_inner(), k_scale is loaded via a mutating pointer:
#   k_scale = tl.load(K_scale_ptr)   <- bare load, no index
#   K_scale_ptr += 1                  <- pointer mutation at loop end
# This causes "operation destroyed but still has uses" on AMD GPU (Triton WMMA backend).
#
# Fix: Replace with indexed load from stable base pointer and remove mutation.
#
# NOTE: Triton @triton.jit kernels require GPU hardware to execute.
# Core fix verification uses AST semantic analysis + behavioral validation.
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring:
#   Test 1: 0.05  Silver      — mock-import, verify functions callable + K_scale_ptr param
#   Test 2: 0.05  Bronze      — anti-stub: _attn_fwd_inner has for loop + >=15 meaningful stmts
#   Test 3: 0.25  F2P-AST     — CORE: bare tl.load(K_scale_ptr) removed from loop + indexed load in loop
#   Test 4: 0.30  Silver      — loop variable is used in load expression + offset correctness
#   Test 5: 0.20  F2P-AST     — K_scale_ptr mutation removed + for-loop preserved
#   Test 6: 0.05  P2P-AST     — k_scale assigned + used + K_ptrs/V_ptrs updates preserved
#   Test 7: 0.05  Bronze      — _attn_fwd calls _attn_fwd_inner (interface intact)
#   Test 8: 0.05  Bronze      — _attn_fwd has substantial body (>=10 stmts)
#   Test 9: 0.05  P2P         — modified Triton kernel file parses as valid Python (ast.parse)
#
# Behavioral: 35% (Tests 1,4) | F2P-AST: 45% (Tests 3,5) | P2P-AST: 5% (Test 6) | P2P: 5% (Test 9) | Structural: 15% (Tests 2,7,8)
# AST justified: @triton.jit kernels cannot execute on CPU
# P2P: no upstream tests available (kijai/ComfyUI-WanVideoWrapper has no test suite)
# Total: 1.05 (capped at 1.0)

set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
TARGET="/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════
# TEST 1 (0.05): Silver — mock-import + verify functions + signatures
#   Mocks triton (GPU-only) and imports the real module to verify:
#   (a) Module loads without error
#   (b) _attn_fwd_inner, _attn_fwd, forward are callable
#   (c) _attn_fwd_inner has K_scale_ptr in its parameter list
# ═══════════════════════════════════════════════════════════
echo "=== Test 1/9: Silver — mock-import + verify functions + signatures ==="
T1=$(python3 << 'PYEOF'
import sys, inspect, importlib.util
from unittest.mock import MagicMock

# Mock triton (not available without GPU)
mock_triton = MagicMock()
def passthrough_jit(fn=None, **kwargs):
    if fn is not None:
        return fn
    return lambda f: f
mock_triton.jit = passthrough_jit
mock_triton.jit.side_effect = passthrough_jit
sys.modules['triton'] = mock_triton
sys.modules['triton.language'] = mock_triton.language

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    spec = importlib.util.spec_from_file_location("attn_mod", TARGET)
    if spec is None or spec.loader is None:
        print("FAIL:cannot_load_spec")
        sys.exit(0)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:import_error:{type(e).__name__}:{e}")
    sys.exit(0)

inner = getattr(mod, '_attn_fwd_inner', None)
fwd = getattr(mod, '_attn_fwd', None)
forward_fn = getattr(mod, 'forward', None)

if inner is None or fwd is None or forward_fn is None:
    missing = [n for n, f in [('_attn_fwd_inner', inner), ('_attn_fwd', fwd), ('forward', forward_fn)] if f is None]
    print(f"FAIL:missing_functions:{missing}")
    sys.exit(0)

if not all(callable(f) for f in [inner, fwd, forward_fn]):
    print("FAIL:not_callable")
    sys.exit(0)

# Verify _attn_fwd_inner has K_scale_ptr parameter
try:
    sig = inspect.signature(inner)
    if 'K_scale_ptr' not in sig.parameters:
        print("FAIL:K_scale_ptr_not_in_signature")
        sys.exit(0)
except (ValueError, TypeError) as e:
    print(f"FAIL:signature_error:{e}")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# TEST 2 (0.05): Anti-stub: _attn_fwd_inner has substantial body
#   Must have a for loop AND >= 15 meaningful statements
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/9: Anti-stub: _attn_fwd_inner has real body ==="
T2=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn"); sys.exit(0)

has_for_loop = any(isinstance(n, ast.For) for n in ast.walk(inner_fn))

meaningful = 0
for node in ast.walk(inner_fn):
    if isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                          ast.For, ast.If, ast.Return, ast.Call)):
        meaningful += 1

if has_for_loop and meaningful >= 15:
    print("PASS")
elif has_for_loop:
    print(f"FAIL:stub:only_{meaningful}_statements")
else:
    print("FAIL:no_for_loop")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# TEST 3 (0.25): CORE BUG FIX — bare load removed, indexed load in loop
#   Searches INSIDE the for loop of _attn_fwd_inner:
#   (a) No bare tl.load(K_scale_ptr) — just Name as sole argument
#   (b) Indexed tl.load(K_scale_ptr + ...) IS present
#   Both conditions must hold. Restricting to the for loop prevents
#   gaming by placing an indexed load outside the loop.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/9: CORE FIX: bare K_scale_ptr load removed, indexed load in loop ==="
T3=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn"); sys.exit(0)

# Find the for loop
for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

bare_load_found = False
indexed_load_found = False

# Search INSIDE the for loop only
for node in ast.walk(for_loop):
    if not isinstance(node, ast.Call):
        continue

    func = node.func
    is_tl_load = (
        isinstance(func, ast.Attribute) and func.attr == "load" and
        isinstance(func.value, ast.Name) and func.value.id == "tl"
    )
    if not is_tl_load or not node.args:
        continue

    arg0 = node.args[0]

    # Bare: arg is just Name('K_scale_ptr')
    if isinstance(arg0, ast.Name) and arg0.id == "K_scale_ptr":
        bare_load_found = True

    # Indexed: arg is BinOp with K_scale_ptr on either side
    if isinstance(arg0, ast.BinOp):
        left_is_kscale = isinstance(arg0.left, ast.Name) and arg0.left.id == "K_scale_ptr"
        right_is_kscale = isinstance(arg0.right, ast.Name) and arg0.right.id == "K_scale_ptr"
        if left_is_kscale or right_is_kscale:
            indexed_load_found = True

    # Also accept subscript: K_scale_ptr[...]
    if isinstance(arg0, ast.Subscript):
        if isinstance(arg0.value, ast.Name) and arg0.value.id == "K_scale_ptr":
            indexed_load_found = True

if not bare_load_found and indexed_load_found:
    print("PASS")
elif bare_load_found and indexed_load_found:
    print("FAIL:bare_load_still_present")
elif not bare_load_found and not indexed_load_found:
    print("FAIL:no_k_scale_load_in_loop")
else:
    print("FAIL:bare_load_present_no_indexed")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.25; fi

# ═══════════════════════════════════════════════════════════
# TEST 4 (0.30): Silver — loop variable used in load + offset correctness
#
#   The core fix replaces `K_scale_ptr += 1` (pointer mutation) with
#   indexed access using the loop variable. This test verifies:
#
#   (a) The offset expression in tl.load(K_scale_ptr + <expr>) references
#       the loop iteration variable (e.g., start_n) — NOT a hardcoded constant.
#       This prevents gaming with `tl.load(K_scale_ptr + 0)` or similar.
#
#   (b) The offset expression produces the correct [0, 1, 2, 3, 4] sequence
#       when evaluated across 5 loop iterations (BLOCK_N=64).
#
#   (c) The offset expression uses division or similar to convert the loop
#       variable (which steps by BLOCK_N) into an index (which steps by 1).
#       A hardcoded sequence can't adapt to different BLOCK_N values.
#
#   Two-BLOCK_N validation: evaluates with BLOCK_N=64 AND BLOCK_N=128 to
#   ensure the expression actually depends on BLOCK_N (not hardcoded).
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/9: Silver — loop variable in load expr + offset correctness ==="
T4=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn"); sys.exit(0)

# Find the for loop and its iteration variable
for_loop = None
loop_var_name = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        # Extract the loop variable name (e.g., start_n)
        if isinstance(node.target, ast.Name):
            loop_var_name = node.target.id
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

if loop_var_name is None:
    print("FAIL:cannot_determine_loop_variable"); sys.exit(0)

# Extract the range() args to understand loop bounds
lo_expr = None
hi_expr = None
step_expr = None
if isinstance(for_loop.iter, ast.Call) and isinstance(for_loop.iter.func, ast.Name):
    if for_loop.iter.func.id == "range":
        args = for_loop.iter.args
        if len(args) == 3:
            lo_expr = ast.unparse(args[0])
            hi_expr = ast.unparse(args[1])
            step_expr = ast.unparse(args[2])

# Collect all assignments in the for loop (for variable resolution)
loop_assignments = {}
for node in ast.walk(for_loop):
    if isinstance(node, ast.Assign) and len(node.targets) == 1:
        t = node.targets[0]
        if isinstance(t, ast.Name):
            loop_assignments[t.id] = node.value

# Find tl.load(K_scale_ptr + <offset>) in the loop body
offset_expr_node = None
for node in ast.walk(for_loop):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    is_tl_load = (
        isinstance(func, ast.Attribute) and func.attr == "load" and
        isinstance(func.value, ast.Name) and func.value.id == "tl"
    )
    if not is_tl_load or not node.args:
        continue
    arg0 = node.args[0]
    if isinstance(arg0, ast.BinOp):
        left_is_kscale = isinstance(arg0.left, ast.Name) and arg0.left.id == "K_scale_ptr"
        right_is_kscale = isinstance(arg0.right, ast.Name) and arg0.right.id == "K_scale_ptr"
        if left_is_kscale:
            offset_expr_node = arg0.right
            break
        elif right_is_kscale:
            offset_expr_node = arg0.left
            break

if offset_expr_node is None:
    print("FAIL:no_indexed_k_scale_load"); sys.exit(0)

# If offset is a simple variable name, resolve it from loop assignments
resolved_expr_node = offset_expr_node
if isinstance(offset_expr_node, ast.Name) and offset_expr_node.id in loop_assignments:
    resolved_expr_node = loop_assignments[offset_expr_node.id]

offset_expr_src = ast.unparse(resolved_expr_node)

# CHECK (a): The offset expression must reference the loop variable.
# Collect all Name references in the offset expression.
referenced_names = set()
for node in ast.walk(resolved_expr_node):
    if isinstance(node, ast.Name):
        referenced_names.add(node.id)

# The loop variable (e.g., start_n) must appear in the offset expression
if loop_var_name not in referenced_names:
    # Also check if the unresolved expression references the loop var
    # (in case the resolved assignment uses it indirectly)
    unresolved_names = set()
    for node in ast.walk(offset_expr_node):
        if isinstance(node, ast.Name):
            unresolved_names.add(node.id)

    # Check if the offset variable itself is derived from the loop variable
    if isinstance(offset_expr_node, ast.Name) and offset_expr_node.id in loop_assignments:
        derived_names = set()
        for node in ast.walk(loop_assignments[offset_expr_node.id]):
            if isinstance(node, ast.Name):
                derived_names.add(node.id)
        if loop_var_name not in derived_names:
            print(f"FAIL:offset_does_not_use_loop_var:{loop_var_name}:refs={referenced_names}")
            sys.exit(0)
    elif loop_var_name not in unresolved_names:
        print(f"FAIL:offset_does_not_use_loop_var:{loop_var_name}:refs={referenced_names | unresolved_names}")
        sys.exit(0)

# CHECK (b): Simulate offset for 5 loop iterations with BLOCK_N=64
# The offset must produce [0, 1, 2, 3, 4]
safe_builtins = {"int": int, "float": float, "abs": abs, "round": round, "min": min, "max": max}

def eval_offsets(block_n, n_iters=5):
    lo = 0
    hi = n_iters * block_n
    results = []
    for start_n in range(lo, hi, block_n):
        try:
            val = eval(offset_expr_src, {"__builtins__": safe_builtins},
                       {loop_var_name: start_n, "BLOCK_N": block_n, "lo": lo, "hi": hi, "kv_len": hi})
            results.append(int(val))
        except Exception as e:
            return None, str(e)
    return results, None

expected_64 = list(range(5))  # [0, 1, 2, 3, 4]
actual_64, err_64 = eval_offsets(64)

if err_64:
    print(f"FAIL:eval_error_64:{offset_expr_src}:{err_64}")
    sys.exit(0)

if actual_64 != expected_64:
    print(f"FAIL:wrong_sequence_64:expr={offset_expr_src}:expected={expected_64}:got={actual_64}")
    sys.exit(0)

# CHECK (c): Two-BLOCK_N validation — with BLOCK_N=128, must also produce [0,1,2,3,4]
# A hardcoded expression like `start_n // 64` would produce [0, 2, 4, 6, 8] with BLOCK_N=128
expected_128 = list(range(5))  # [0, 1, 2, 3, 4]
actual_128, err_128 = eval_offsets(128)

if err_128:
    print(f"FAIL:eval_error_128:{offset_expr_src}:{err_128}")
    sys.exit(0)

if actual_128 != expected_128:
    print(f"FAIL:wrong_sequence_128:expr={offset_expr_src}:expected={expected_128}:got={actual_128}")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.30; fi

# ═══════════════════════════════════════════════════════════
# TEST 5 (0.20): K_scale_ptr mutation removed + for-loop preserved
#   K_scale_ptr += ... must be GONE from the function body.
#   The for loop itself must still be present (not deleted as workaround).
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/9: K_scale_ptr mutation removed, loop preserved ==="
T5=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn"); sys.exit(0)

has_for_loop = any(isinstance(n, ast.For) for n in ast.walk(inner_fn))

# Check K_scale_ptr += ... is NOT present (AugAssign on K_scale_ptr)
# Also check K_scale_ptr = K_scale_ptr + ... (regular reassignment)
kscale_mutation_present = False
for node in ast.walk(inner_fn):
    if isinstance(node, ast.AugAssign):
        if isinstance(node.target, ast.Name) and node.target.id == "K_scale_ptr":
            kscale_mutation_present = True
            break
    # Also catch K_scale_ptr = K_scale_ptr + 1 style
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "K_scale_ptr":
                # Check RHS references K_scale_ptr (i.e., it's a mutation)
                for child in ast.walk(node.value):
                    if isinstance(child, ast.Name) and child.id == "K_scale_ptr":
                        kscale_mutation_present = True
                        break

if has_for_loop and not kscale_mutation_present:
    print("PASS")
elif not has_for_loop:
    print("FAIL:for_loop_removed")
else:
    print("FAIL:K_scale_ptr_mutation_still_present")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.20; fi

# ═══════════════════════════════════════════════════════════
# TEST 6 (0.05): P2P — k_scale assigned + used + K_ptrs/V_ptrs preserved
#   Verifies no regression in surrounding attention loop logic:
#   (a) k_scale is assigned inside the for loop
#   (b) k_scale is used in a multiplication (qk scaling)
#   (c) K_ptrs += ... present (key pointer advance)
#   (d) V_ptrs += ... present (value pointer advance)
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/9: k_scale assigned + used + K_ptrs/V_ptrs preserved ==="
T6=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn"); sys.exit(0)

# Find the for loop
for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

k_ptrs_updated = False
v_ptrs_updated = False
k_scale_assigned = False
k_scale_used_in_mult = False

for node in ast.walk(inner_fn):
    # Check pointer updates
    if isinstance(node, ast.AugAssign) and isinstance(node.op, ast.Add):
        if isinstance(node.target, ast.Name):
            if node.target.id == "K_ptrs":
                k_ptrs_updated = True
            elif node.target.id == "V_ptrs":
                v_ptrs_updated = True

    # Check k_scale is used in a multiplication (qk scaling)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
        for child in ast.walk(node):
            if isinstance(child, ast.Name) and child.id == "k_scale":
                k_scale_used_in_mult = True
                break

# Check k_scale is assigned inside the for loop
if for_loop is not None:
    for node in ast.walk(for_loop):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "k_scale":
                    k_scale_assigned = True

if k_ptrs_updated and v_ptrs_updated and k_scale_assigned and k_scale_used_in_mult:
    print("PASS")
else:
    missing = []
    if not k_ptrs_updated: missing.append("K_ptrs_update")
    if not v_ptrs_updated: missing.append("V_ptrs_update")
    if not k_scale_assigned: missing.append("k_scale_assignment")
    if not k_scale_used_in_mult: missing.append("k_scale_in_multiplication")
    print(f"FAIL:missing:{','.join(missing)}")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# TEST 7 (0.05): _attn_fwd calls _attn_fwd_inner (interface intact)
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/9: _attn_fwd calls _attn_fwd_inner (interface intact) ==="
T7=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

fwd_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd":
        fwd_fn = node
        break

if fwd_fn is None:
    print("FAIL:no_attn_fwd"); sys.exit(0)

calls_inner = False
for node in ast.walk(fwd_fn):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Name) and func.id == "_attn_fwd_inner":
            calls_inner = True
            break

if calls_inner:
    print("PASS")
else:
    print("FAIL:_attn_fwd_inner_not_called")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# TEST 8 (0.05): _attn_fwd has substantial body
#   Ensures _attn_fwd itself wasn't simplified into a stub
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/9: _attn_fwd has substantial body ==="
T8=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

tree = ast.parse(source)

fwd_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd":
        fwd_fn = node
        break

if fwd_fn is None:
    print("FAIL:no_attn_fwd"); sys.exit(0)

meaningful = sum(
    1 for node in ast.walk(fwd_fn)
    if isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                          ast.Call, ast.Return))
)

if meaningful >= 10:
    print("PASS")
else:
    print(f"FAIL:stub:only_{meaningful}_statements")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# TEST 9 (0.05): P2P — modified Triton kernel file parses as valid Python
#   Pass-to-pass: the target file must remain syntactically valid Python
#   after agent modifications. Catches truncation, unclosed brackets,
#   or other syntax-breaking edits.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/9: P2P — Triton kernel file parses as valid Python ==="
T9=$(python3 << 'PYEOF'
import sys, ast

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

try:
    ast.parse(source)
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax_error:line_{e.lineno}:{e.msg}")
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════
# Final reward
# ═══════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
