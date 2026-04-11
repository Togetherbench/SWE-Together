#!/bin/bash
# Verifier for nunchaku-quantize-bugfix
# Tests that quantize.py bugs are fixed AND pack_awq_qweight is simplified:
#   Bug 1: quantize_residual — torch.max(dim=) returns namedtuple, needs .values
#   Bug 2: quantize_awq_layer — torch.min/max(dim=) return namedtuples, need .values
#   Bug 3: main() — f-string uses tensor variables instead of string literals
#   Enhancement: pack_awq_qweight loop simplification (user-requested, keep |= not sum)
#
# Weight budget (sums to 1.00):
#   P2P (0.05): T1(0.01) T4(0.01) T5(0.01) P2P(0.01) P2P-2(0.01)
#   F2P (0.95): T2a-c(0.18) T3a-c(0.18) T6(0.12) T7(0.06) T8(0.14) T9(0.10) T10(0.09) T11(0.08)

set +e

# Activate venv so torch is available (E2B resets PATH on sandbox start)
export PATH="/workspace/venv/bin:$PATH"

REWARD=0.0
PASS=0
TOTAL=17

QF=/workspace/quantize.py

add_reward() {
    PASS=$((PASS + 1))
    REWARD=$(python3 -c "print(round($REWARD + $1, 4))")
    echo "Test $2 PASS: $3 (+$1)"
}

# ── Test 1 (0.01): file parses + key functions non-stub [P2P] ───────────
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
    add_reward 0.01 1 "file parses, key functions have real bodies"
else
    echo "Test 1 FAIL: file does not parse or key functions are stubs"
fi

# ── Test 2a (0.06): quantize_residual runs without crash [F2P core] ────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual

try:
    torch.manual_seed(0)
    residual = torch.randn(128, 128, dtype=torch.float32)
    qweight, wscales = quantize_residual(residual)
    print('quantize_residual ran without crash')
    sys.exit(0)
except Exception as e:
    print(f'quantize_residual crashed: {type(e).__name__}: {e}')
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 2a "quantize_residual runs without crash"
else
    echo "Test 2a FAIL: quantize_residual crashes"
fi

# ── Test 2b (0.06): quantize_residual output shapes/dtypes correct ─────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual

group_size = 64

for seed, N, K in [(0, 128, 128), (42, 256, 256)]:
    torch.manual_seed(seed)
    residual = torch.randn(N, K, dtype=torch.float32)

    qweight, wscales = quantize_residual(residual)

    assert qweight.dtype == torch.int8, f'qweight dtype: {qweight.dtype}'
    assert qweight.shape == (N, K // 2), f'qweight shape: {qweight.shape}'
    assert wscales.shape == (K // group_size, N), f'wscales shape: {wscales.shape}'
    assert (wscales > 0).all(), 'wscales must be positive'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 2b "quantize_residual output shapes/dtypes correct"
else
    echo "Test 2b FAIL: quantize_residual output shapes/dtypes wrong"
fi

# ── Test 2c (0.06): quantize_residual scale bounds + constant input ────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual

group_size = 64

for seed, N, K in [(0, 128, 128), (42, 256, 256)]:
    torch.manual_seed(seed)
    residual = torch.randn(N, K, dtype=torch.float32)

    qweight, wscales = quantize_residual(residual)

    res_grouped = residual.view(N, K // group_size, group_size)
    max_abs = res_grouped.abs().max(dim=-1).values
    assert (max_abs <= wscales.T * 7 + 1e-4).all(), 'scale bound violated'

# Constant input: 0.7 everywhere -> all quantize to 15 -> packed bytes all 0xFF (-1)
residual_const = torch.full((128, 128), 0.7, dtype=torch.float32)
qw, ws = quantize_residual(residual_const)
assert (qw == -1).all(), 'Constant 0.7 input: packed bytes should all be 0xFF'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 2c "quantize_residual scale bounds checked + constant input OK"
else
    echo "Test 2c FAIL: quantize_residual scale bound or constant input check failed"
fi

# ── Test 3a (0.06): quantize_awq_layer runs without crash [F2P core] ───
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer

try:
    torch.manual_seed(1)
    weight = torch.randn(4, 64, dtype=torch.bfloat16)
    qweight, wscales, wzeros = quantize_awq_layer(weight)
    print('quantize_awq_layer ran without crash')
    sys.exit(0)
except Exception as e:
    print(f'quantize_awq_layer crashed: {type(e).__name__}: {e}')
    sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 3a "quantize_awq_layer runs without crash"
else
    echo "Test 3a FAIL: quantize_awq_layer crashes"
fi

# ── Test 3b (0.06): quantize_awq_layer output shapes/dtypes correct ────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer

group_size = 64
for seed, N, K in [(1, 4, 64), (99, 8, 128)]:
    torch.manual_seed(seed)
    weight = torch.randn(N, K, dtype=torch.bfloat16)

    qweight, wscales, wzeros = quantize_awq_layer(weight)

    n_groups = K // group_size
    assert qweight.dtype == torch.int32, f'qweight dtype: {qweight.dtype}'
    assert qweight.shape == (N // 4, K // 2), f'qweight shape: {qweight.shape}'
    assert wscales.shape == (n_groups, N), f'wscales shape: {wscales.shape}'
    assert wzeros.shape == (n_groups, N), f'wzeros shape: {wzeros.shape}'
    assert (wscales > 0).all(), 'wscales must be positive'

sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 3b "quantize_awq_layer output shapes/dtypes correct"
else
    echo "Test 3b FAIL: quantize_awq_layer output shapes/dtypes wrong"
fi

# ── Test 3c (0.06): quantize_awq_layer roundtrip reconstruction < 0.5 ──
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer

group_size = 64
for seed, N, K in [(1, 4, 64), (99, 8, 128)]:
    torch.manual_seed(seed)
    weight = torch.randn(N, K, dtype=torch.bfloat16)

    qweight, wscales, wzeros = quantize_awq_layer(weight)

    n_groups = K // group_size

    # Roundtrip: unpack AWQ -> dequantize -> compare with original
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
    add_reward 0.06 3c "quantize_awq_layer roundtrip reconstruction error < 0.5"
else
    echo "Test 3c FAIL: quantize_awq_layer roundtrip error too large"
fi

# ── Test 4 (0.01): pack_svdq_qweight shape/dtype + determinism [P2P] ────
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
    add_reward 0.01 4 "pack_svdq_qweight correct shape/dtype + deterministic"
else
    echo "Test 4 FAIL: pack_svdq_qweight error"
fi

# ── Test 5 (0.01): pack_awq_qweight correct output (ref compare) [P2P] ──
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
    add_reward 0.01 5 "pack_awq_qweight correct output (ref compare)"
else
    echo "Test 5 FAIL: pack_awq_qweight output incorrect"
fi

# ── Test 6 (0.12): f-string bug fixed in main() [F2P-AST] ──────────────
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
    add_reward 0.12 6 "f-string bug fixed in main()"
else
    echo "Test 6 FAIL: f-string still uses tensor variable instead of string literal"
fi

# ── Test 7 (0.06): pack_awq simplified structure [F2P structural] ───────
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

# ── Test 8 (0.14): pack_awq simplified + correct (multiple sizes) [F2P] ─
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
    add_reward 0.14 8 "pack_awq_qweight simplified + correct (multiple sizes)"
else
    echo "Test 8 FAIL: pack_awq_qweight not simplified or incorrect"
fi

# ── Test 9 (0.10): quantize_svdq_layer end-to-end [F2P] ────────────────
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

# ── Test 10 (0.09): quantize_awq_layer edge cases [F2P] ────────────────
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
    add_reward 0.09 10 "quantize_awq_layer edge cases pass"
else
    echo "Test 10 FAIL: quantize_awq_layer fails on edge case inputs"
fi

# ── Test 11 (0.08): main() f-string fixed + structural integrity [F2P] ─
# Gate: f-string bug must be fixed (F2P gate — fails on nop).
# Then checks that agents didn't over-modify main(): block count, layer lists,
# and key structure should be preserved. Catches incorrect additions like
# img_mlp.net.2, txt_mlp.net.2 or changes to block count.
python3 -c "
import ast, sys

with open('$QF') as f:
    tree = ast.parse(f.read())

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'main':
        # Anti-stub
        meaningful = [n for n in ast.walk(node)
                      if isinstance(n, (ast.Assign, ast.AugAssign, ast.Call,
                                        ast.For, ast.With, ast.If, ast.Return,
                                        ast.Expr))]
        if len(meaningful) < 10:
            print('main() too short — likely a stub')
            sys.exit(1)

        # F2P gate: f-string bug must be fixed
        for subnode in ast.walk(node):
            if isinstance(subnode, ast.JoinedStr):
                for val in subnode.values:
                    if (isinstance(val, ast.FormattedValue)
                            and isinstance(val.value, ast.Name)
                            and val.value.id in ('weight', 'bias')):
                        print('f-string bug not fixed — T11 gate fails')
                        sys.exit(1)

        source = ast.get_source_segment(open('$QF').read(), node)
        if source is None:
            with open('$QF') as f:
                lines = f.readlines()
            source = ''.join(lines[node.lineno - 1: node.end_lineno])

        # 1. Block count: must iterate over 60 blocks
        has_range_60 = 'range(60)' in source
        if not has_range_60:
            print('main() missing range(60) — block count changed')
            sys.exit(1)

        # 2. AWQ layers should be exactly img_mod.1 and txt_mod.1
        if 'img_mlp.net.2' in source or 'txt_mlp.net.2' in source:
            print('main() has incorrect layer additions (net.2)')
            sys.exit(1)

        # 3. Check awq_layers list: should have exactly 2 entries
        for subnode in ast.walk(node):
            if isinstance(subnode, ast.Assign):
                for target in subnode.targets:
                    if isinstance(target, ast.Name) and target.id == 'awq_layers':
                        if isinstance(subnode.value, ast.List):
                            n_entries = len(subnode.value.elts)
                            if n_entries != 2:
                                print(f'awq_layers has {n_entries} entries, expected 2')
                                sys.exit(1)

        # 4. svdq_layers should have exactly 6 entries
        for subnode in ast.walk(node):
            if isinstance(subnode, ast.Assign):
                for target in subnode.targets:
                    if isinstance(target, ast.Name) and target.id == 'svdq_layers':
                        if isinstance(subnode.value, ast.List):
                            n_entries = len(subnode.value.elts)
                            if n_entries != 6:
                                print(f'svdq_layers has {n_entries} entries, expected 6')
                                sys.exit(1)

        sys.exit(0)
sys.exit(1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.08 11 "main() structural integrity preserved"
else
    echo "Test 11 FAIL: main() over-modified (wrong block count, extra layers, etc.)"
fi

# ── P2P (0.01): Upstream NunchakuWeightPacker functional test on CPU ──────
python3 -c "
import sys, types, importlib.util
import torch

REPO = '/workspace/nunchaku'

# Stub out nunchaku's __init__.py to avoid CUDA model imports
nunchaku_pkg = types.ModuleType('nunchaku')
nunchaku_pkg.__path__ = [f'{REPO}/nunchaku']
nunchaku_pkg.__package__ = 'nunchaku'
sys.modules['nunchaku'] = nunchaku_pkg

def ceil_divide(x, d):
    return (x + d - 1) // d

nu = types.ModuleType('nunchaku.utils')
nu.ceil_divide = ceil_divide
nu.load_state_dict_in_safetensors = None
sys.modules['nunchaku.utils'] = nu

for name, path in [
    ('nunchaku.lora', f'{REPO}/nunchaku/lora'),
    ('nunchaku.lora.flux', f'{REPO}/nunchaku/lora/flux'),
]:
    m = types.ModuleType(name)
    m.__path__ = [path]
    m.__package__ = name
    sys.modules[name] = m

spec = importlib.util.spec_from_file_location(
    'nunchaku.lora.flux.utils', f'{REPO}/nunchaku/lora/flux/utils.py')
fu = importlib.util.module_from_spec(spec)
sys.modules['nunchaku.lora.flux.utils'] = fu
spec.loader.exec_module(fu)

spec = importlib.util.spec_from_file_location(
    'nunchaku.lora.flux.packer', f'{REPO}/nunchaku/lora/flux/packer.py')
pk = importlib.util.module_from_spec(spec)
sys.modules['nunchaku.lora.flux.packer'] = pk
spec.loader.exec_module(pk)

wp = pk.NunchakuWeightPacker(bits=4, warp_n=128)

# 1) Lowrank pack->unpack round-trip (both directions)
for down in [True, False]:
    for shape in [(256, 16), (512, 32)]:
        torch.manual_seed(42)
        orig = torch.randn(*shape, dtype=torch.bfloat16)
        packed = wp.pack_lowrank_weight(orig, down=down)
        unpacked = wp.unpack_lowrank_weight(packed, down=down)
        err = (orig.float() - unpacked.float()).abs().max().item()
        assert err < 1e-6, f'lowrank round-trip error {err} for down={down} shape={shape}'

# 2) pack_weight shape + determinism
torch.manual_seed(99)
N, K = 256, 256
w = torch.randint(0, 16, (N, K), dtype=torch.int32)
packed = wp.pack_weight(w)
assert packed.dtype == torch.int8, f'pack_weight dtype: {packed.dtype}'
assert packed.shape == (N, K // 2), f'pack_weight shape: {packed.shape}'
packed2 = wp.pack_weight(w)
assert torch.equal(packed, packed2), 'pack_weight non-deterministic'

# 3) pack_scale shape
G = 64
s = torch.randn(N, K // G, dtype=torch.bfloat16)
ps = wp.pack_scale(s, group_size=G)
assert ps.shape == (K // G, N), f'pack_scale shape: {ps.shape}'

print('P2P PASS: NunchakuWeightPacker pack/unpack round-trips correct on CPU')
sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.01 P2P "upstream NunchakuWeightPacker functional test on CPU"
else
    echo "Test P2P FAIL: upstream NunchakuWeightPacker broken or corrupted"
fi

# ── P2P-2 (0.01): modified quantize.py parses + key structures intact ────
python3 -c "
import ast, sys

with open('$QF') as f:
    source = f.read()

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f'P2P-2 FAIL: quantize.py has syntax error: {e}')
    sys.exit(1)

# All functions that must exist at module level
required_funcs = {
    'pack_svdq_qweight', 'pack_awq_qweight',
    'quantize_residual', 'quantize_awq_layer',
    'quantize_svdq_layer', 'main',
}
found_funcs = {
    node.name for node in ast.iter_child_nodes(tree)
    if isinstance(node, ast.FunctionDef)
}
missing = required_funcs - found_funcs
if missing:
    print(f'P2P-2 FAIL: missing top-level functions: {sorted(missing)}')
    sys.exit(1)

# Key imports that must be present (torch, argparse used in main)
import_names = set()
for node in ast.iter_child_nodes(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            import_names.add(alias.name.split('.')[0])
    elif isinstance(node, ast.ImportFrom) and node.module:
        import_names.add(node.module.split('.')[0])
if 'torch' not in import_names:
    print('P2P-2 FAIL: torch import missing')
    sys.exit(1)

print(f'P2P-2 PASS: quantize.py parses, {len(found_funcs & required_funcs)} required functions present')
sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.01 P2P-2 "modified quantize.py parses + key structures intact"
else
    echo "Test P2P-2 FAIL: quantize.py corrupted or missing key structures"
fi

# ── Write reward ──────────────────────────────────────────────────────────
REWARD=$(python3 -c "print(min(1.0, round($REWARD, 4)))")
echo ""
echo "Score: $PASS/$TOTAL tests passed"
echo "Reward: $REWARD"
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
