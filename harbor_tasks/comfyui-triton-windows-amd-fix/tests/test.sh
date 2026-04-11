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
#   Test 1:  0.01  P2P         — mock-import, verify functions callable + K_scale_ptr param
#   Test 2:  0.01  P2P         — anti-stub: _attn_fwd_inner has for loop + >=15 meaningful stmts
#   Test 3:  0.20  F2P-AST     — CORE: bare tl.load(K_scale_ptr) removed from loop + indexed load in loop
#   Test 4:  0.20  F2P-AST     — loop variable is used in load expression + offset correctness
#   Test 5:  0.10  F2P-AST     — K_scale_ptr mutation removed + for-loop preserved
#   Test 6:  0.02  P2P-AST     — k_scale assigned + used + K_ptrs/V_ptrs updates preserved
#   Test 7:  0.01  P2P         — module structure intact + valid Python + forward signature
#   Test 8:  0.25  F2P-AST     — WORKAROUND: k_scale not directly in tl.dot expression
#   Test 9:  0.10  F2P-AST     — WORKAROUND: pre-computed scale variable exists
#   Test 10: 0.10  F2P-AST     — WORKAROUND: k_scale load expression modified from original
#
# F2P core: 50% (Tests 3,4,5) — full indexed load fix
# F2P workaround: 45% (Tests 8,9,10) — partial fixes addressing SSA issue
# P2P: 5% (Tests 1,2,6,7) — structural integrity
# Total: 1.00

set +e

# Activate venv so python3 finds torch and other installed packages.
# The Dockerfile sets ENV PATH but E2B runtime may override it.
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
TARGET="/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════
# TEST 1 (0.01): P2P — mock-import + verify functions + signatures
# ═══════════════════════════════════════════════════════════
echo "=== Test 1/10: P2P — mock-import + verify functions + signatures ==="
T1=$(python3 << 'PYEOF'
import sys, inspect, importlib.util
from unittest.mock import MagicMock

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
if [ "$T1" = "PASS" ]; then add_reward 0.01; fi

# ═══════════════════════════════════════════════════════════
# TEST 2 (0.01): P2P — Anti-stub: _attn_fwd_inner has substantial body
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/10: P2P — Anti-stub: _attn_fwd_inner has real body ==="
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
if [ "$T2" = "PASS" ]; then add_reward 0.01; fi

# ═══════════════════════════════════════════════════════════
# TEST 3 (0.20): CORE BUG FIX — bare load removed, indexed load in loop
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/10: CORE FIX: bare K_scale_ptr load removed, indexed load in loop ==="
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

for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

bare_load_found = False
indexed_load_found = False

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

    if isinstance(arg0, ast.Name) and arg0.id == "K_scale_ptr":
        bare_load_found = True

    if isinstance(arg0, ast.BinOp):
        left_is_kscale = isinstance(arg0.left, ast.Name) and arg0.left.id == "K_scale_ptr"
        right_is_kscale = isinstance(arg0.right, ast.Name) and arg0.right.id == "K_scale_ptr"
        if left_is_kscale or right_is_kscale:
            indexed_load_found = True

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
if [ "$T3" = "PASS" ]; then add_reward 0.20; fi

# ═══════════════════════════════════════════════════════════
# TEST 4 (0.20): F2P — loop variable used in load + offset correctness
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/10: F2P — loop variable in load expr + offset correctness ==="
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

for_loop = None
loop_var_name = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        if isinstance(node.target, ast.Name):
            loop_var_name = node.target.id
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

if loop_var_name is None:
    print("FAIL:cannot_determine_loop_variable"); sys.exit(0)

loop_assignments = {}
for node in ast.walk(for_loop):
    if isinstance(node, ast.Assign) and len(node.targets) == 1:
        t = node.targets[0]
        if isinstance(t, ast.Name):
            loop_assignments[t.id] = node.value

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

resolved_expr_node = offset_expr_node
if isinstance(offset_expr_node, ast.Name) and offset_expr_node.id in loop_assignments:
    resolved_expr_node = loop_assignments[offset_expr_node.id]

offset_expr_src = ast.unparse(resolved_expr_node)

uses_loop_var = False
is_counter = False

referenced_names = set()
for node in ast.walk(resolved_expr_node):
    if isinstance(node, ast.Name):
        referenced_names.add(node.id)

if loop_var_name in referenced_names:
    uses_loop_var = True
else:
    unresolved_names = set()
    for node in ast.walk(offset_expr_node):
        if isinstance(node, ast.Name):
            unresolved_names.add(node.id)

    if loop_var_name in unresolved_names:
        uses_loop_var = True
    elif isinstance(offset_expr_node, ast.Name) and offset_expr_node.id in loop_assignments:
        derived_names = set()
        for node in ast.walk(loop_assignments[offset_expr_node.id]):
            if isinstance(node, ast.Name):
                derived_names.add(node.id)
        if loop_var_name in derived_names:
            uses_loop_var = True

if not uses_loop_var and isinstance(offset_expr_node, ast.Name):
    counter_name = offset_expr_node.id
    if counter_name != "K_scale_ptr":
        for node in ast.walk(for_loop):
            if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name):
                if node.target.id == counter_name and isinstance(node.op, ast.Add):
                    if isinstance(node.value, ast.Constant) and node.value.value == 1:
                        is_counter = True
                        break

if not uses_loop_var and not is_counter:
    print(f"FAIL:offset_not_dynamic:{loop_var_name}:refs={referenced_names}")
    sys.exit(0)

if is_counter:
    print("PASS")
    sys.exit(0)

safe_builtins = {"int": int, "float": float, "abs": abs, "round": round, "min": min, "max": max}

def eval_offsets(block_n, n_iters=5):
    lo = 0
    hi = n_iters * block_n
    results = []
    for start_n in range(lo, hi, block_n):
        try:
            val = eval(offset_expr_src, {"__builtins__": safe_builtins},
                       {loop_var_name: start_n, "BLOCK_N": block_n, "lo": lo, "hi": hi, "kv_len": hi})
            if isinstance(val, float) and val != int(val):
                return None, f"non_integer_offset:{val}"
            results.append(int(val))
        except Exception as e:
            return None, str(e)
    return results, None

expected_64 = list(range(5))
actual_64, err_64 = eval_offsets(64)

if err_64:
    print(f"FAIL:eval_error_64:{offset_expr_src}:{err_64}")
    sys.exit(0)

if actual_64 != expected_64:
    print(f"FAIL:wrong_sequence_64:expr={offset_expr_src}:expected={expected_64}:got={actual_64}")
    sys.exit(0)

expected_128 = list(range(5))
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
if [ "$T4" = "PASS" ]; then add_reward 0.20; fi

# ═══════════════════════════════════════════════════════════
# TEST 5 (0.10): F2P — K_scale_ptr mutation removed + for-loop preserved
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/10: F2P — K_scale_ptr mutation removed, loop preserved ==="
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

kscale_mutation_present = False
for node in ast.walk(inner_fn):
    if isinstance(node, ast.AugAssign):
        if isinstance(node.target, ast.Name) and node.target.id == "K_scale_ptr":
            kscale_mutation_present = True
            break
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "K_scale_ptr":
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
if [ "$T5" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# TEST 6 (0.02): P2P — k_scale assigned + used + K_ptrs/V_ptrs preserved
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/10: P2P — k_scale assigned + used + K_ptrs/V_ptrs preserved ==="
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
    if isinstance(node, ast.AugAssign) and isinstance(node.op, ast.Add):
        if isinstance(node.target, ast.Name):
            if node.target.id == "K_ptrs":
                k_ptrs_updated = True
            elif node.target.id == "V_ptrs":
                v_ptrs_updated = True

    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
        for child in ast.walk(node):
            if isinstance(child, ast.Name) and child.id == "k_scale":
                k_scale_used_in_mult = True
                break

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
if [ "$T6" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════
# TEST 7 (0.01): P2P — Triton kernel file valid Python + module structure intact
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/10: P2P — Triton kernel file valid + module structure intact ==="
T7=$(python3 << 'PYEOF'
import sys, ast, inspect, importlib.util
from unittest.mock import MagicMock

TARGET = "/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

try:
    with open(TARGET) as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found"); sys.exit(0)

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax_error:line_{e.lineno}:{e.msg}")
    sys.exit(0)

line_count = len(source.strip().split('\n'))
if line_count < 80:
    print(f"FAIL:truncated:{line_count}_lines_expected_80+")
    sys.exit(0)

func_names = [n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]
expected_funcs = {'forward', '_attn_fwd', '_attn_fwd_inner'}
missing_funcs = expected_funcs - set(func_names)
if missing_funcs:
    print(f"FAIL:missing_functions:{missing_funcs}")
    sys.exit(0)

decorator_count = 0
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef):
        for dec in node.decorator_list:
            dec_src = ast.unparse(dec) if hasattr(ast, 'unparse') else ''
            if 'triton' in dec_src or 'jit' in dec_src:
                decorator_count += 1
if decorator_count < 2:
    print(f"FAIL:only_{decorator_count}_triton_decorators_expected_2+")
    sys.exit(0)

mock_triton = MagicMock()
def passthrough_jit(fn=None, **kwargs):
    if fn is not None:
        return fn
    return lambda f: f
mock_triton.jit = passthrough_jit
sys.modules['triton'] = mock_triton
sys.modules['triton.language'] = mock_triton.language

try:
    spec = importlib.util.spec_from_file_location("attn_mod", TARGET)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    forward_fn = getattr(mod, 'forward', None)
    if forward_fn is None:
        print("FAIL:forward_not_found_after_import")
        sys.exit(0)

    sig = inspect.signature(forward_fn)
    if len(sig.parameters) < 4:
        print(f"FAIL:forward_has_only_{len(sig.parameters)}_params_expected_4+")
        sys.exit(0)

except Exception as e:
    print(f"FAIL:import_error:{type(e).__name__}:{e}")
    sys.exit(0)
finally:
    sys.modules.pop('triton', None)
    sys.modules.pop('triton.language', None)

imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            imports.add(alias.name.split('.')[0])
    elif isinstance(node, ast.ImportFrom) and node.module:
        imports.add(node.module.split('.')[0])

if 'triton' not in imports:
    print("FAIL:no_triton_import")
    sys.exit(0)
if 'torch' not in imports:
    print("FAIL:no_torch_import")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.01; fi

# ═══════════════════════════════════════════════════════════
# TEST 8 (0.25): F2P — WORKAROUND: k_scale NOT a direct top-level factor in
#   the tl.dot multiplication chain.
#   The SSA destruction bug occurs because k_scale (from tl.load) is used
#   via tt.splat DIRECTLY after tl.dot. Valid workarounds:
#   (a) Pre-compute into a separate variable: scale = q_scale * k_scale
#   (b) Parenthesize: tl.dot(...) * (q_scale * k_scale) — scalar-scalar first
#   (c) Remove k_scale from the dot expression entirely
#   FAIL if k_scale is a direct top-level factor (like the original:
#   tl.dot(...).to(tl.float32) * q_scale * k_scale where k_scale gets splatted)
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/10: F2P — k_scale not a direct factor in dot multiplication ==="
T8=$(python3 << 'PYEOF'
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

for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

# Find the assignment in the loop body whose RHS contains tl.dot
dot_assign = None
for stmt in for_loop.body:
    if isinstance(stmt, (ast.Assign, ast.AugAssign)):
        value = stmt.value if isinstance(stmt, ast.Assign) else stmt.value
        for node in ast.walk(value):
            if isinstance(node, ast.Call):
                func = node.func
                if (isinstance(func, ast.Attribute) and func.attr == "dot" and
                    isinstance(func.value, ast.Name) and func.value.id == "tl"):
                    dot_assign = stmt
                    break
        if dot_assign:
            break

if dot_assign is None:
    print("FAIL:no_tl_dot_assignment_in_loop"); sys.exit(0)

value = dot_assign.value if isinstance(dot_assign, ast.Assign) else dot_assign.value

# Get top-level multiplication factors.
# For left-associative `a * b * c` = `((a * b) * c)`:
#   factors = [a, b, c] (all are direct/top-level)
# For parenthesized `a * (b * c)`:
#   factors = [a, BinOp(b * c)] (BinOp is NOT unwound — b and c are inside)
def get_top_mult_factors(node):
    """Unwind left-associative multiplication chain. Returns list of factor nodes."""
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
        # Only recurse into LEFT (left-associative), keep RIGHT as a factor
        return get_top_mult_factors(node.left) + [node.right]
    else:
        return [node]

factors = get_top_mult_factors(value)

# Check if k_scale is a DIRECT top-level factor (Name node with id 'k_scale')
k_scale_is_direct_factor = False
for factor in factors:
    if isinstance(factor, ast.Name) and factor.id == "k_scale":
        k_scale_is_direct_factor = True
        break

if k_scale_is_direct_factor:
    print("FAIL:k_scale_is_direct_factor_in_dot_chain")
else:
    # k_scale is either:
    # - Not in the expression at all (pre-computed into separate var) → PASS
    # - Inside a sub-expression like (q_scale * k_scale) → PASS
    # - Not used (removed/refactored) → PASS
    print("PASS")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.25; fi

# ═══════════════════════════════════════════════════════════
# TEST 9 (0.10): F2P — WORKAROUND: pre-computed scale variable exists
#   Checks if there's an intermediate variable (not k_scale, not qk) that
#   pre-computes a combined scale factor from k_scale and q_scale.
#   This is a higher-quality workaround that shows understanding of the SSA issue.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/10: F2P — pre-computed scale variable exists ==="
T9=$(python3 << 'PYEOF'
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

for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

# Look for an assignment in the for loop body where:
# (a) The target is NOT k_scale, qk, or other standard loop vars
# (b) The value involves k_scale in a multiplication
pre_computed_scale_found = False

for stmt in for_loop.body:
    if not isinstance(stmt, ast.Assign):
        continue
    if len(stmt.targets) != 1:
        continue
    target = stmt.targets[0]
    if not isinstance(target, ast.Name):
        continue
    # Skip standard variable names
    if target.id in ('k_scale', 'qk', 'k', 'v', 'p', 'q', 'm', 'n',
                      'm_ij', 'l_ij', 'alpha', 'acc', 'l_i', 'm_i',
                      'k_mask', 'window_th', 'dist2', 'dist_mask',
                      'negative_mask', 'window3', 'start_n'):
        continue

    has_k_scale = False
    has_multiplication = False

    for node in ast.walk(stmt.value):
        if isinstance(node, ast.Name) and node.id == "k_scale":
            has_k_scale = True
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
            has_multiplication = True

    if has_k_scale and has_multiplication:
        pre_computed_scale_found = True
        break

if pre_computed_scale_found:
    print("PASS")
else:
    print("FAIL:no_pre_computed_scale_variable")
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# TEST 10 (0.10): F2P — k_scale load expression modified from original bare pattern
#   The original code has: k_scale = tl.load(K_scale_ptr)
#   This test checks if the load expression was modified in ANY way:
#   - Added .to() chaining: tl.load(K_scale_ptr).to(tl.float32)
#   - Changed to indexed: tl.load(K_scale_ptr + ...)
#   - Added extra arguments: tl.load(K_scale_ptr, ...)
#   - Wrapped in another call
#   Any modification shows the agent identified the load as problematic.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 10/10: F2P — k_scale load expression modified from original ==="
T10=$(python3 << 'PYEOF'
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

for_loop = None
for node in ast.walk(inner_fn):
    if isinstance(node, ast.For):
        for_loop = node
        break

if for_loop is None:
    print("FAIL:no_for_loop"); sys.exit(0)

# Find the assignment to k_scale in the loop
k_scale_assign = None
for stmt in for_loop.body:
    if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1:
        if isinstance(stmt.targets[0], ast.Name) and stmt.targets[0].id == "k_scale":
            k_scale_assign = stmt
            break

if k_scale_assign is None:
    # k_scale not assigned in loop — it was moved or removed. Counts as modified.
    print("PASS")
    sys.exit(0)

value = k_scale_assign.value

# The ORIGINAL bare pattern is:
#   k_scale = tl.load(K_scale_ptr)
# AST: Assign(targets=[Name('k_scale')],
#             value=Call(func=Attr(Name('tl'), 'load'), args=[Name('K_scale_ptr')]))
#
# Check if value is EXACTLY this pattern (bare, unmodified).
is_bare_original = False

if isinstance(value, ast.Call):
    func = value.func
    if (isinstance(func, ast.Attribute) and func.attr == "load" and
        isinstance(func.value, ast.Name) and func.value.id == "tl"):
        if len(value.args) == 1:
            arg0 = value.args[0]
            if isinstance(arg0, ast.Name) and arg0.id == "K_scale_ptr":
                if not value.keywords:
                    is_bare_original = True

if is_bare_original:
    print("FAIL:load_expression_unchanged")
else:
    print("PASS")
PYEOF
)
echo "  Result: $T10"
if [ "$T10" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# Final reward
# ═══════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
