#!/usr/bin/env bash
#
# Verification test for ComfyUI-WanVideoWrapper Triton AMD GPU fix.
#
# Bug: In _attn_fwd_inner(), k_scale is loaded via a mutating pointer:
#   k_scale = tl.load(K_scale_ptr)   ← bare load, no index
#   K_scale_ptr += 1                  ← pointer mutation at loop end
# This causes "operation destroyed but still has uses" on AMD GPU (Triton WMMA backend).
#
# Fix: Replace with indexed load from stable base pointer:
#   k_scale = tl.load(K_scale_ptr + (start_n // BLOCK_N))
#   (remove K_scale_ptr += 1)
#
# NOTE: Triton kernels require GPU hardware to execute, so Silver-tier
# (import+call+verify output) tests are limited to mock-import checks.
# Core fix verification uses AST semantic analysis (Bronze+ tier).
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring:
#   Test 1: 0.10  silver      - mock-import module, verify functions callable + signatures
#   Test 2: 0.05  structural  - anti-stub: _attn_fwd_inner has real body (AST)
#   Test 3: 0.25  AST-semantic - CORE: bare tl.load(K_scale_ptr) removed AND indexed load present
#   Test 4: 0.20  AST-semantic - correct index: start_n used in k_scale load offset
#   Test 5: 0.15  AST-semantic - mutation removed AND for-loop body preserved
#   Test 6: 0.10  AST-semantic - K_ptrs/V_ptrs pointer updates preserved (no regression)
#   Test 7: 0.10  AST-semantic - _attn_fwd still calls _attn_fwd_inner (interface intact)
#   Test 8: 0.05  structural  - _attn_fwd function body preserved (AST)
#
# Total: 1.0

set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
TARGET="/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════
# TEST 1 (0.10): Silver — mock-import module, verify functions callable + signatures
#   Mocks triton (GPU-only) and imports the real module to verify:
#   (a) Module loads without error
#   (b) _attn_fwd_inner, _attn_fwd, forward are callable
#   (c) _attn_fwd_inner has K_scale_ptr in its parameter list
# ═══════════════════════════════════════════════════════════
echo "=== Test 1/8: Silver — mock-import + verify functions + signatures ==="
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
        print(f"FAIL:K_scale_ptr_not_in_signature:params={list(sig.parameters.keys())}")
        sys.exit(0)
except (ValueError, TypeError) as e:
    print(f"FAIL:signature_error:{e}")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# TEST 2 (0.05): Anti-stub: _attn_fwd_inner has substantial body
#   Must have a for loop AND >= 8 meaningful statements
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/8: Anti-stub: _attn_fwd_inner has real body ==="
T2=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn")
    sys.exit(0)

# Check for for loop
has_for_loop = any(isinstance(n, ast.For) for n in ast.walk(inner_fn))

# Count meaningful statements in function body
meaningful = 0
for node in ast.walk(inner_fn):
    if isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                          ast.For, ast.If, ast.Return, ast.Call)):
        meaningful += 1

if has_for_loop and meaningful >= 8:
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
# TEST 3 (0.25): CORE BUG FIX
#   (a) No bare tl.load(K_scale_ptr) in _attn_fwd_inner loop body
#   (b) Indexed tl.load(K_scale_ptr + ...) IS present
#   Both conditions must hold to score — prevents gaming by deletion.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/8: CORE FIX: bare K_scale_ptr load removed, indexed load present ==="
T3=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn")
    sys.exit(0)

# Scan all tl.load() calls in _attn_fwd_inner
bare_load_found = False     # tl.load(K_scale_ptr) — bare, no offset
indexed_load_found = False  # tl.load(K_scale_ptr + ...) — with offset

for node in ast.walk(inner_fn):
    if not isinstance(node, ast.Call):
        continue

    # Check if this is tl.load(...)
    func = node.func
    is_tl_load = (
        isinstance(func, ast.Attribute) and func.attr == "load" and
        isinstance(func.value, ast.Name) and func.value.id == "tl"
    )
    if not is_tl_load or not node.args:
        continue

    arg0 = node.args[0]
    arg0_dump = ast.dump(arg0)

    # Bare: arg is just Name('K_scale_ptr')
    if isinstance(arg0, ast.Name) and arg0.id == "K_scale_ptr":
        bare_load_found = True

    # Indexed: arg is BinOp with K_scale_ptr on left
    if isinstance(arg0, ast.BinOp):
        if isinstance(arg0.left, ast.Name) and arg0.left.id == "K_scale_ptr":
            indexed_load_found = True
        # Also accept: K_scale_ptr[...] subscript pattern
    if isinstance(arg0, ast.Subscript):
        if isinstance(arg0.value, ast.Name) and arg0.value.id == "K_scale_ptr":
            indexed_load_found = True

if not bare_load_found and indexed_load_found:
    print("PASS")
elif bare_load_found and indexed_load_found:
    print("FAIL:bare_load_still_present")
elif not bare_load_found and not indexed_load_found:
    print("FAIL:no_load_at_all:function_body_may_be_deleted")
else:
    print("FAIL:bare_load_present_no_indexed")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.25; fi

# ═══════════════════════════════════════════════════════════
# TEST 4 (0.20): Correct index: start_n used in k_scale load offset
#   The indexed load must use start_n (loop var) and BLOCK_N
#   to compute the correct per-block index.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/8: Correct index: start_n in k_scale load offset ==="
T4=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn")
    sys.exit(0)

# Find the indexed tl.load(K_scale_ptr + ...) and check if start_n appears in offset
indexed_with_start_n = False
indexed_without_start_n = False

for node in ast.walk(inner_fn):
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
    if not isinstance(arg0, ast.BinOp):
        continue
    if not (isinstance(arg0.left, ast.Name) and arg0.left.id == "K_scale_ptr"):
        continue

    # Found: tl.load(K_scale_ptr + <expr>)
    # Check if <expr> contains start_n
    offset_expr = arg0.right
    offset_dump = ast.dump(offset_expr)
    has_start_n = any(
        isinstance(n, ast.Name) and n.id == "start_n"
        for n in ast.walk(ast.Expression(body=offset_expr))
        if isinstance(n, ast.Name)
    )
    # Also check directly in dump
    if "start_n" in offset_dump:
        has_start_n = True

    if has_start_n:
        indexed_with_start_n = True
    else:
        indexed_without_start_n = True

if indexed_with_start_n:
    print("PASS")
elif indexed_without_start_n:
    print("FAIL:indexed_but_no_start_n_in_offset")
else:
    print("FAIL:no_indexed_k_scale_load")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.20; fi

# ═══════════════════════════════════════════════════════════
# TEST 5 (0.15): Pointer mutation removed AND for-loop preserved
#   K_scale_ptr += 1 must be GONE from loop body
#   The for loop itself must still be present (not deleted as workaround)
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/8: K_scale_ptr mutation removed, loop preserved ==="
T5=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn")
    sys.exit(0)

# Check for-loop still present
has_for_loop = any(isinstance(n, ast.For) for n in ast.walk(inner_fn))

# Check K_scale_ptr += 1 is NOT present (AugAssign on K_scale_ptr with Add)
kscale_mutation_present = False
for node in ast.walk(inner_fn):
    if isinstance(node, ast.AugAssign):
        if isinstance(node.target, ast.Name) and node.target.id == "K_scale_ptr":
            if isinstance(node.op, ast.Add):
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
if [ "$T5" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════
# TEST 6 (0.10): K_ptrs and V_ptrs pointer updates preserved
#   K_ptrs += BLOCK_N * stride_kn and V_ptrs += BLOCK_N * stride_vn
#   must still be in the loop body — no regression.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/8: K_ptrs and V_ptrs updates preserved (no regression) ==="
T6=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

inner_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd_inner":
        inner_fn = node
        break

if inner_fn is None:
    print("FAIL:no_inner_fn")
    sys.exit(0)

# Check K_ptrs += ... and V_ptrs += ... are still in the function
k_ptrs_updated = False
v_ptrs_updated = False

for node in ast.walk(inner_fn):
    if isinstance(node, ast.AugAssign) and isinstance(node.op, ast.Add):
        if isinstance(node.target, ast.Name):
            if node.target.id == "K_ptrs":
                k_ptrs_updated = True
            elif node.target.id == "V_ptrs":
                v_ptrs_updated = True

if k_ptrs_updated and v_ptrs_updated:
    print("PASS")
elif k_ptrs_updated:
    print("FAIL:V_ptrs_update_removed")
elif v_ptrs_updated:
    print("FAIL:K_ptrs_update_removed")
else:
    print("FAIL:both_ptr_updates_removed")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# TEST 7 (0.10): _attn_fwd still calls _attn_fwd_inner
#   The interface between the two functions must be intact.
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/8: _attn_fwd calls _attn_fwd_inner (interface intact) ==="
T7=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

fwd_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd":
        fwd_fn = node
        break

if fwd_fn is None:
    print("FAIL:no_attn_fwd")
    sys.exit(0)

# Check that _attn_fwd_inner is called inside _attn_fwd
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
    print("FAIL:_attn_fwd_inner_not_called_from_attn_fwd")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════
# TEST 8 (0.05): _attn_fwd function has substantial body
#   Ensures _attn_fwd itself wasn't simplified into a stub
# ═══════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/8: _attn_fwd has substantial body ==="
T8=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py") as f:
    source = f.read()

tree = ast.parse(source)

fwd_fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_attn_fwd":
        fwd_fn = node
        break

if fwd_fn is None:
    print("FAIL:no_attn_fwd")
    sys.exit(0)

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
# Final reward
# ═══════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
