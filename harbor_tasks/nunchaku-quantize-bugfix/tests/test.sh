#!/bin/bash
# Verifier for nunchaku-quantize-bugfix
# Tests that quantize.py bugs are fixed AND pack_awq_qweight is simplified:
#   Bug 1: quantize_residual — torch.max(dim=) returns namedtuple, needs .values
#   Bug 2: quantize_awq_layer — torch.min/max(dim=) return namedtuples, need .values
#   Bug 3: main() — f-string uses tensor variables instead of string literals
#   Enhancement: pack_awq_qweight loop simplification (user-requested, keep |= not sum)

set +e

REWARD=0.0
PASS=0
TOTAL=10

QF=/workspace/quantize.py

add_reward() {
    PASS=$((PASS + 1))
    REWARD=$(python3 -c "print(round($REWARD + $1, 4))")
    echo "Test $2 PASS: $3 (+$1)"
}

# ── Test 1 (0.03): file parses + key functions non-stub [Bronze] ────────
python3 -c "
import ast, sys

with open('$QF') as f:
    tree = ast.parse(f.read())

def meaningful_stmts(func_node):
    return [s for s in func_node.body
            if not isinstance(s, ast.Pass)
            and not (isinstance(s, ast.Expr)
                     and isinstance(getattr(s, 'value', None), ast.Constant)
                     and isinstance(s.value.value, str))]

found = {}
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in (
        'pack_awq_qweight', 'quantize_residual', 'quantize_awq_layer',
        'pack_svdq_qweight', 'quantize_svdq_layer'
    ):
        found[node.name] = len(meaningful_stmts(node))

for name in ('pack_awq_qweight', 'quantize_residual', 'quantize_awq_layer'):
    if found.get(name, 0) < 3:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.03 1 "file parses, key functions have real bodies"
else
    echo "Test 1 FAIL: file does not parse or key functions are stubs"
fi

# ── Test 2 (0.18): quantize_residual runs + correctness [F2P + Gold] ────
# Core bug: .max(dim=-1, keepdim=True) returns namedtuple, needs .values
# Buggy code crashes with TypeError; fixed code produces valid quantization.
# Hardened: constant-input check catches stubs returning correct shapes but wrong values.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual

group_size = 64

# Random inputs: must not crash (F2P) + shape/dtype + scale bound
for seed, N, K in [(0, 128, 128), (42, 256, 256)]:
    torch.manual_seed(seed)
    residual = torch.randn(N, K, dtype=torch.float32)

    qweight, wscales = quantize_residual(residual)

    assert qweight.dtype == torch.int8, f'qweight dtype: {qweight.dtype}'
    assert qweight.shape == (N, K // 2), f'qweight shape: {qweight.shape}'
    assert wscales.shape == (K // group_size, N), f'wscales shape: {wscales.shape}'
    assert (wscales > 0).all(), 'wscales must be positive'

    # Scale bound: wscales * 7 >= max(|residual|) per group
    res_grouped = residual.view(N, K // group_size, group_size)
    max_abs = res_grouped.abs().max(dim=-1).values
    assert (max_abs <= wscales.T * 7 + 1e-4).all(), 'scale bound violated'

# Constant input: 0.7 everywhere → all quantize to 15 → packed bytes all 0xFF (-1)
# This catches stubs that return correct shapes but zero/random qweight.
residual_const = torch.full((128, 128), 0.7, dtype=torch.float32)
qw, ws = quantize_residual(residual_const)
assert (qw == -1).all(), 'Constant 0.7 input: packed bytes should all be 0xFF'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.18 2 "quantize_residual runs + correctness validated"
else
    echo "Test 2 FAIL: quantize_residual crashes or produces wrong output"
fi

# ── Test 3 (0.18): quantize_awq_layer runs + roundtrip [F2P + Gold] ─────
# Core bug: .min/.max(dim=-1, keepdim=True) return namedtuples, need .values
# Buggy code crashes; fixed code produces bounded reconstruction error.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer

group_size = 64
for seed, N, K in [(1, 4, 64), (99, 8, 128)]:
    torch.manual_seed(seed)
    weight = torch.randn(N, K, dtype=torch.bfloat16)

    # Must not crash (F2P)
    qweight, wscales, wzeros = quantize_awq_layer(weight)

    # Shape/dtype
    n_groups = K // group_size
    assert qweight.dtype == torch.int32, f'qweight dtype: {qweight.dtype}'
    assert qweight.shape == (N // 4, K // 2), f'qweight shape: {qweight.shape}'
    assert wscales.shape == (n_groups, N), f'wscales shape: {wscales.shape}'
    assert wzeros.shape == (n_groups, N), f'wzeros shape: {wzeros.shape}'
    assert (wscales > 0).all(), 'wscales must be positive'

    # Roundtrip: unpack AWQ → dequantize → compare with original
    packed_3d = qweight.view(N, K // 32, 4)
    unpacked = torch.zeros((N, K // 32, 32), dtype=torch.int32)
    for g in range(4):
        for j in range(4):
            idx_even = 8 * g + 2 * j
            idx_odd = 8 * g + 2 * j + 1
            unpacked[:, :, idx_even] = (packed_3d[:, :, j] >> (4 * g)) & 0xF
            unpacked[:, :, idx_odd] = (packed_3d[:, :, j] >> (16 + 4 * g)) & 0xF
    unpacked = unpacked.view(N, K)

    scales = wscales.T.float().unsqueeze(-1).expand(N, n_groups, group_size).reshape(N, K)
    zeros = wzeros.T.float().unsqueeze(-1).expand(N, n_groups, group_size).reshape(N, K)
    reconstructed = unpacked.float() * scales + zeros

    # 4-bit quantization of randn: max error should be well under 0.5
    max_err = (weight.float() - reconstructed).abs().max().item()
    assert max_err < 0.5, f'Roundtrip error too large: {max_err}'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.18 3 "quantize_awq_layer runs + roundtrip error bounded"
else
    echo "Test 3 FAIL: quantize_awq_layer crashes or roundtrip error too large"
fi

# ── Test 4 (0.05): pack_svdq_qweight shape/dtype + determinism [Silver] ─
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import pack_svdq_qweight

for seed, N, K in [(7, 128, 128), (13, 256, 128)]:
    torch.manual_seed(seed)
    weight = torch.randint(0, 16, (N, K), dtype=torch.int32)
    packed = pack_svdq_qweight(weight)
    assert packed.dtype == torch.int8, f'dtype: {packed.dtype}'
    assert packed.shape == (N, K // 2), f'shape: {packed.shape}'
    packed2 = pack_svdq_qweight(weight)
    assert torch.equal(packed, packed2), 'Non-deterministic output'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 4 "pack_svdq_qweight correct shape/dtype + deterministic"
else
    echo "Test 4 FAIL: pack_svdq_qweight error"
fi

# ── Test 5 (0.08): pack_awq_qweight correct output (ref compare) [Silver]
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

for seed, N, K in [(42, 4, 64), (100, 8, 128), (200, 16, 64)]:
    torch.manual_seed(seed)
    weight = torch.randint(0, 16, (N, K), dtype=torch.int32)
    ref = pack_awq_ref(weight)
    got = pack_awq_qweight(weight)
    assert torch.equal(ref, got), f'Mismatch at seed={seed}'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.08 5 "pack_awq_qweight correct output (ref compare)"
else
    echo "Test 5 FAIL: pack_awq_qweight output incorrect"
fi

# ── Test 6 (0.10): f-string bug fixed in main() [F2P-AST] ──────────────
# Bug: f"{name}.{weight}" uses tensor variable; fix: f"{name}.weight" literal
# Can't call main() — requires safetensors model files not in Docker image.
python3 -c "
import ast, sys

with open('$QF') as f:
    tree = ast.parse(f.read())

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'main':
        # Anti-stub: main must have substantial body
        meaningful = [n for n in ast.walk(node)
                      if isinstance(n, (ast.Assign, ast.AugAssign, ast.Call,
                                        ast.For, ast.With, ast.If, ast.Return,
                                        ast.Expr))]
        if len(meaningful) < 10:
            sys.exit(1)

        # Check for the f-string bug: FormattedValue referencing Name('weight'/'bias')
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
    add_reward 0.10 6 "f-string bug fixed in main()"
else
    echo "Test 6 FAIL: f-string still uses tensor variable instead of string literal"
fi

# ── Test 7 (0.06): pack_awq simplified structure [Bronze] ───────────────
# Original has 2 nested for-loops. Simplified should have at most 1.
# Must NOT use sum() as replacement for |= (user correction re: int32 overflow).
python3 -c "
import ast, sys

with open('$QF') as f:
    tree = ast.parse(f.read())

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'pack_awq_qweight':
        # Anti-stub
        body = [s for s in node.body if not isinstance(s, ast.Pass)
                and not (isinstance(s, ast.Expr)
                         and isinstance(getattr(s, 'value', None), ast.Constant))]
        if len(body) < 3:
            sys.exit(1)

        for_loops = [n for n in ast.walk(node) if isinstance(n, ast.For)]

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

        if len(for_loops) <= 1 and not uses_sum and not uses_torch_sum:
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 7 "pack_awq_qweight simplified (<=1 loop, no sum)"
else
    echo "Test 7 FAIL: pack_awq_qweight not simplified or uses sum instead of |="
fi

# ── Test 8 (0.15): pack_awq simplified + correct (multiple sizes) [Silver]
python3 -c "
import ast, sys
sys.path.insert(0, '/workspace')

# Structural gate: must be simplified (<=1 for-loop)
with open('$QF') as f:
    tree = ast.parse(f.read())
simplified = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'pack_awq_qweight':
        for_loops = [n for n in ast.walk(node) if isinstance(n, ast.For)]
        if len(for_loops) <= 1:
            simplified = True
if not simplified:
    sys.exit(1)

# Correctness check with multiple input sizes
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

for seed, N, K in [(100, 4, 64), (200, 8, 128), (300, 16, 64), (400, 4, 128)]:
    torch.manual_seed(seed)
    weight = torch.randint(0, 16, (N, K), dtype=torch.int32)
    ref = pack_awq_ref(weight)
    got = pack_awq_qweight(weight)
    assert torch.equal(ref, got), f'Mismatch at seed={seed}, N={N}, K={K}'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.15 8 "pack_awq_qweight simplified + correct (multiple sizes)"
else
    echo "Test 8 FAIL: pack_awq_qweight not simplified or incorrect on varied inputs"
fi

# ── Test 9 (0.10): quantize_svdq_layer end-to-end [Silver] ──────────────
# Integration test: SVD decomposition + residual quantization pipeline.
# Exercises quantize_residual indirectly — catches stubs that skip packing.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_svdq_layer

torch.manual_seed(77)
N, K = 128, 256
weight = torch.randn(N, K, dtype=torch.bfloat16)
smooth_factor = torch.ones(K, dtype=torch.bfloat16)

proj_down, proj_up, qweight, wscales = quantize_svdq_layer(weight, smooth_factor, rank=32)

# Check shapes (rank=32)
assert proj_down.shape == (K, 32), f'proj_down shape: {proj_down.shape}'
assert proj_up.shape == (N, 32), f'proj_up shape: {proj_up.shape}'
assert qweight.dtype == torch.int8, f'qweight dtype: {qweight.dtype}'
assert qweight.shape == (N, K // 2), f'qweight shape: {qweight.shape}'
assert wscales.shape == (K // 64, N), f'wscales shape: {wscales.shape}'
assert (wscales > 0).all(), 'wscales must be positive'

# Low-rank approx should explain significant variance
low_rank_approx = proj_up.float() @ proj_down.float().T
residual_norm = (weight.float() - low_rank_approx).norm()
original_norm = weight.float().norm()
assert residual_norm / original_norm < 0.95, f'Low-rank approx too poor: {residual_norm/original_norm:.3f}'

# qweight must not be trivial (all zeros) — catches stubs
assert qweight.any(), 'qweight is all zeros — likely a stub'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 9 "quantize_svdq_layer end-to-end correct"
else
    echo "Test 9 FAIL: quantize_svdq_layer error"
fi

# ── Test 10 (0.07): quantize_awq_layer edge cases [Silver] ──────────────
# Tests edge inputs: near-zero weights (clamping path) and larger tensors.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer

# Near-zero weights — exercises wscales clamping path
weight = torch.full((4, 64), 1e-8, dtype=torch.bfloat16)
qweight, wscales, wzeros = quantize_awq_layer(weight)
assert qweight.shape == (1, 32), f'shape: {qweight.shape}'
assert (wscales >= 1e-5).all(), 'wscales clamping failed'

# Larger tensor with multiple groups
torch.manual_seed(555)
weight = torch.randn(16, 128, dtype=torch.bfloat16)
qweight, wscales, wzeros = quantize_awq_layer(weight)
assert qweight.shape == (4, 64), f'shape: {qweight.shape}'
assert wscales.shape == (2, 16), f'wscales shape: {wscales.shape}'
assert wzeros.shape == (2, 16), f'wzeros shape: {wzeros.shape}'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.07 10 "quantize_awq_layer edge cases pass"
else
    echo "Test 10 FAIL: quantize_awq_layer fails on edge case inputs"
fi

# ── Write reward ──────────────────────────────────────────────────────────
REWARD=$(python3 -c "print(min(1.0, round($REWARD, 4)))")
echo ""
echo "Score: $PASS/$TOTAL tests passed"
echo "Reward: $REWARD"
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
