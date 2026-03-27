#!/bin/bash
# Verifier for nunchaku-implement-a136a8
# Tests that quantize.py bugs are fixed AND pack_awq_qweight is simplified:
#   1. quantize_residual: torch.max(dim=) needs .values
#   2. quantize_awq_layer: torch.min/max(dim=) need .values
#   3. main(): f-string uses literal "weight"/"bias" not tensor variables
#   4. pack_awq_qweight: produces correct output
#   5. pack_awq_qweight: simplified loop (user-triggered requirement)

set +e

REWARD=0.0
PASS=0
TOTAL=11

QF=/workspace/quantize.py

add_reward() {
    PASS=$((PASS + 1))
    REWARD=$(python3 -c "print(round($REWARD + $1, 4))")
    echo "Test $2 PASS: $3 (+$1)"
}

# ── Test 1 (0.03): file exists and parses as valid Python ────────────────────
python3 -c "
import ast, sys
try:
    with open('$QF') as f:
        ast.parse(f.read())
    sys.exit(0)
except SyntaxError as e:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.03 1 "file parses as valid Python"
else
    echo "Test 1 FAIL: file does not parse"
fi

# ── Test 2 (0.02): anti-stub — pack_awq_qweight has real body (>=3 stmts) ───
python3 -c "
import ast, sys
with open('/workspace/quantize.py') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'pack_awq_qweight':
        meaningful = [n for n in node.body if not isinstance(n, ast.Pass)]
        sys.exit(0 if len(meaningful) >= 3 else 1)
sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.02 2 "pack_awq_qweight has real body"
else
    echo "Test 2 FAIL: pack_awq_qweight is stub or missing"
fi

# ── Test 3 (0.10): quantize_residual runs without error ─────────────────────
# Core bug: .max(dim=-1, keepdim=True) returns namedtuple, needs .values
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
residual = torch.randn(128, 128, dtype=torch.float32)
try:
    qweight, wscales = quantize_residual(residual)
    assert qweight.dtype == torch.int8
    assert qweight.shape == (128, 64)
    sys.exit(0)
except Exception as e:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 3 "quantize_residual runs without error"
else
    echo "Test 3 FAIL: quantize_residual raises error (likely .max/.values bug)"
fi

# ── Test 4 (0.10): quantize_awq_layer runs without error ────────────────────
# Core bug: .min/.max(dim=-1, keepdim=True) return namedtuples, need .values
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
weight = torch.randn(4, 64, dtype=torch.bfloat16)
try:
    qweight, wscales, wzeros = quantize_awq_layer(weight)
    assert qweight.dtype == torch.int32
    assert qweight.shape == (1, 32), f'qweight shape wrong: {qweight.shape}'
    assert wscales.shape == (1, 4), f'wscales shape wrong: {wscales.shape}'
    assert wzeros.shape == (1, 4), f'wzeros shape wrong: {wzeros.shape}'
    sys.exit(0)
except Exception as e:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 4 "quantize_awq_layer runs without error"
else
    echo "Test 4 FAIL: quantize_awq_layer raises error (likely .min/.max/.values bug)"
fi

# ── Test 5 (0.05): pack_awq_qweight produces correct output ─────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
def pack_awq_ref(weight):
    N, K = weight.shape
    device = weight.device
    weight = weight.view(N, K // 32, 32)
    packed = torch.zeros((N, K // 32, 4), device=device, dtype=torch.int32)
    for g in range(4):
        shift_low = 4 * g
        shift_high = 16 + 4 * g
        for j in range(4):
            idx_even = 8 * g + 2 * j
            idx_odd = 8 * g + 2 * j + 1
            packed[:, :, j] |= weight[:, :, idx_even] << shift_low
            packed[:, :, j] |= weight[:, :, idx_odd] << shift_high
    return packed.view(N // 4, K // 2)
from quantize import pack_awq_qweight
torch.manual_seed(42)
weight = torch.randint(0, 16, (4, 64), dtype=torch.int32)
try:
    ref = pack_awq_ref(weight)
    got = pack_awq_qweight(weight)
    sys.exit(0 if torch.equal(ref, got) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 5 "pack_awq_qweight produces correct output"
else
    echo "Test 5 FAIL: pack_awq_qweight output incorrect"
fi

# ── Test 6 (0.05): pack_svdq_qweight produces correct output ────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import pack_svdq_qweight
torch.manual_seed(7)
weight = torch.randint(0, 16, (128, 128), dtype=torch.int32)
try:
    packed = pack_svdq_qweight(weight)
    assert packed.dtype == torch.int8
    assert packed.shape == (128, 64)
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 6 "pack_svdq_qweight runs and returns correct shape/dtype"
else
    echo "Test 6 FAIL: pack_svdq_qweight error"
fi

# ── Test 7 (0.05): f-string bug fixed in main() ─────────────────────────────
# Bug: f"{name}.{weight}" uses tensor variable; fix: f"{name}.weight" string literal
# Anti-stub: main must have >=10 meaningful statements (not just pass/return)
python3 -c "
import ast, sys
with open('/workspace/quantize.py') as f:
    source = f.read()
    tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'main':
        # Anti-stub: require main to have real body
        meaningful = [n for n in ast.walk(node)
                      if isinstance(n, (ast.Assign, ast.AugAssign, ast.Call,
                                        ast.For, ast.With, ast.If, ast.Return,
                                        ast.Expr))]
        if len(meaningful) < 10:
            sys.exit(1)
        # Check for the f-string bug
        bad = []
        for subnode in ast.walk(node):
            if isinstance(subnode, ast.JoinedStr):
                for val in subnode.values:
                    if (isinstance(val, ast.FormattedValue)
                            and isinstance(val.value, ast.Name)
                            and val.value.id in ('weight', 'bias')):
                        bad.append(val.value.id)
        sys.exit(1 if bad else 0)
sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 7 "f-string bug fixed in main()"
else
    echo "Test 7 FAIL: f-string still uses tensor variable instead of string literal"
fi

# ── Test 8 (0.05): quantize_residual output values are numerically sensible ──
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
torch.manual_seed(0)
residual = torch.randn(128, 128, dtype=torch.float32)
try:
    qweight, wscales = quantize_residual(residual)
    assert (wscales > 0).all(), 'wscales not positive'
    assert wscales.shape == (2, 128), f'wscales shape wrong: {wscales.shape}'
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 8 "quantize_residual output is numerically correct"
else
    echo "Test 8 FAIL: quantize_residual output values wrong"
fi

# ── Test 9 (0.05): quantize_awq_layer output numerically sensible ────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
torch.manual_seed(99)
weight = torch.randn(8, 64, dtype=torch.bfloat16)
try:
    qweight, wscales, wzeros = quantize_awq_layer(weight)
    assert (wscales > 0).all(), 'wscales not positive'
    assert wscales.shape == (1, 8), f'wscales shape wrong: {wscales.shape}'
    assert wzeros.shape == (1, 8), f'wzeros shape wrong: {wzeros.shape}'
    assert qweight.dtype == torch.int32
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 9 "quantize_awq_layer output is numerically correct"
else
    echo "Test 9 FAIL: quantize_awq_layer output values wrong"
fi

# ── Test 10 (0.25): pack_awq_qweight simplified — fewer nested for-loops ─────
# Original has 2 nested for-loops (for g in range(4): for j in range(4):).
# A simplified version should have at most 1 for-loop (vectorized inner logic).
# Must also preserve |= (bitwise OR accumulation, not sum).
python3 -c "
import ast, sys
with open('/workspace/quantize.py') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'pack_awq_qweight':
        # Count for-loops directly inside pack_awq_qweight body
        for_loops = [n for n in ast.walk(node) if isinstance(n, ast.For)]
        # Check uses |= (AugAssign with BitOr) — not sum()
        has_bitor = any(
            isinstance(n, ast.AugAssign) and isinstance(n.op, ast.BitOr)
            for n in ast.walk(node)
        )
        # Check NOT using sum() as replacement for |=
        uses_sum = any(
            isinstance(n, ast.Call)
            and isinstance(getattr(n, 'func', None), ast.Name)
            and n.func.id == 'sum'
            for n in ast.walk(node)
        )
        uses_torch_sum = any(
            isinstance(n, ast.Call)
            and isinstance(getattr(n, 'func', None), ast.Attribute)
            and n.func.attr == 'sum'
            for n in ast.walk(node)
        )
        # Simplified: at most 1 for-loop, uses |=, does not use sum
        if len(for_loops) <= 1 and has_bitor and not uses_sum and not uses_torch_sum:
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.25 10 "pack_awq_qweight simplified (fewer loops, uses |=, no sum)"
else
    echo "Test 10 FAIL: pack_awq_qweight not simplified or uses sum instead of |="
fi

# ── Test 11 (0.25): pack_awq_qweight simplified AND correct ──────────────────
# Gate: must be simplified (≤1 for-loop) AND produce correct output on varied inputs.
python3 -c "
import ast, sys
sys.path.insert(0, '/workspace')

# Step 1: structural gate — must be simplified
with open('/workspace/quantize.py') as f:
    tree = ast.parse(f.read())
simplified = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'pack_awq_qweight':
        for_loops = [n for n in ast.walk(node) if isinstance(n, ast.For)]
        if len(for_loops) <= 1:
            simplified = True
if not simplified:
    sys.exit(1)

# Step 2: correctness check with multiple input sizes
import torch

def pack_awq_ref(weight):
    N, K = weight.shape
    device = weight.device
    weight = weight.view(N, K // 32, 32)
    packed = torch.zeros((N, K // 32, 4), device=device, dtype=torch.int32)
    for g in range(4):
        shift_low = 4 * g
        shift_high = 16 + 4 * g
        for j in range(4):
            idx_even = 8 * g + 2 * j
            idx_odd = 8 * g + 2 * j + 1
            packed[:, :, j] |= weight[:, :, idx_even] << shift_low
            packed[:, :, j] |= weight[:, :, idx_odd] << shift_high
    return packed.view(N // 4, K // 2)

from quantize import pack_awq_qweight

ok = True
for seed, N, K in [(100, 4, 64), (200, 8, 128), (300, 16, 64), (400, 4, 128)]:
    torch.manual_seed(seed)
    weight = torch.randint(0, 16, (N, K), dtype=torch.int32)
    try:
        ref = pack_awq_ref(weight)
        got = pack_awq_qweight(weight)
        if not torch.equal(ref, got):
            ok = False
            break
    except Exception:
        ok = False
        break
sys.exit(0 if ok else 1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.25 11 "pack_awq_qweight correct with multiple input sizes"
else
    echo "Test 11 FAIL: pack_awq_qweight output incorrect on varied inputs"
fi

# ── Write reward ──────────────────────────────────────────────────────────────
REWARD=$(python3 -c "print(min(1.0, round($REWARD, 4)))")
echo ""
echo "Score: $PASS/$TOTAL tests passed"
echo "Reward: $REWARD"
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
