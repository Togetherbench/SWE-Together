#!/bin/bash
set +e

# Verifier for nunchaku-quantize-bugfix
# Total weight = 1.00

export PATH="/workspace/venv/bin:$PATH"

REWARD=0.0
QF=/workspace/quantize.py

mkdir -p /logs/verifier

add_reward() {
    REWARD=$(awk -v r="$REWARD" -v a="$1" 'BEGIN{printf "%.4f", r + a}')
    echo "PASS [$2] (+$1): $3"
}

fail() {
    echo "FAIL [$1]: $2"
}

if [ ! -f "$QF" ]; then
    echo "FATAL: $QF missing"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

# ── Test 1 (0.03): file parses, key functions present ──────────────────
python3 -c "
import ast, sys
with open('$QF') as f:
    tree = ast.parse(f.read())
def meaningful(n):
    return [s for s in n.body if not isinstance(s, ast.Pass)
            and not (isinstance(s, ast.Expr) and isinstance(getattr(s,'value',None), ast.Constant)
                     and isinstance(s.value.value, str))]
found = {}
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef):
        found[n.name] = len(meaningful(n))
for name in ('pack_awq_qweight','quantize_residual','quantize_awq_layer','pack_svdq_qweight'):
    if found.get(name, 0) < 2:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.03 1 "file parses, key functions present"
else
    fail 1 "file syntax / missing functions"
fi

# ── Test 2 (0.04): module imports cleanly ──────────────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import quantize
for fn in ('quantize_residual','quantize_awq_layer','pack_awq_qweight','pack_svdq_qweight'):
    assert hasattr(quantize, fn), fn
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.04 2 "module imports cleanly"
else
    fail 2 "module import error"
fi

# ── Test 3 (0.05): quantize_residual runs ──────────────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
torch.manual_seed(0)
residual = torch.randn(128, 128, dtype=torch.float32)
qweight, wscales = quantize_residual(residual)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 3 "quantize_residual runs without crash"
else
    fail 3 "quantize_residual crash (.values bug?)"
fi

# ── Test 4 (0.06): quantize_residual shapes/dtypes ─────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
gs = 64
for seed, N, K in [(0,128,128),(42,256,256)]:
    torch.manual_seed(seed)
    residual = torch.randn(N, K, dtype=torch.float32)
    qw, ws = quantize_residual(residual)
    assert qw.dtype == torch.int8, f'qw dtype {qw.dtype}'
    assert qw.shape == (N, K//2), f'qw shape {qw.shape}'
    assert ws.shape == (K//gs, N), f'ws shape {ws.shape}'
    assert (ws > 0).all()
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 4 "quantize_residual shapes/dtypes correct"
else
    fail 4 "quantize_residual shape/dtype wrong"
fi

# ── Test 5 (0.07): quantize_residual semantics ─────────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
gs = 64
torch.manual_seed(0)
N, K = 128, 128
residual = torch.randn(N, K, dtype=torch.float32)
qw, ws = quantize_residual(residual)
res_grouped = residual.view(N, K//gs, gs)
max_abs = res_grouped.abs().max(dim=-1).values
assert (max_abs <= ws.T * 7 + 1e-4).all(), 'scale bound violated'
torch.manual_seed(1)
r2 = torch.randn(64, 128, dtype=torch.float32)
qa, sa = quantize_residual(r2)
qb, sb = quantize_residual(-r2)
assert torch.allclose(sa, sb, atol=1e-5), 'symmetric scales should match'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.07 5 "quantize_residual semantics correct"
else
    fail 5 "quantize_residual semantic check failed"
fi

# ── Test 6 (0.05): quantize_awq_layer runs ─────────────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
torch.manual_seed(1)
weight = torch.randn(4, 64, dtype=torch.bfloat16)
qweight, wscales, wzeros = quantize_awq_layer(weight)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 6 "quantize_awq_layer runs without crash"
else
    fail 6 "quantize_awq_layer crashed"
fi

# ── Test 7 (0.06): quantize_awq_layer shapes/dtypes ────────────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
gs = 64
for seed, N, K in [(1,4,64),(99,8,128),(7,16,256)]:
    torch.manual_seed(seed)
    w = torch.randn(N, K, dtype=torch.bfloat16)
    qw, ws, wz = quantize_awq_layer(w)
    ng = K // gs
    assert qw.dtype == torch.int32, f'qw dtype {qw.dtype}'
    assert qw.shape == (N//4, K//2), f'qw shape {qw.shape}'
    assert ws.shape == (ng, N), f'ws shape {ws.shape}'
    assert wz.shape == (ng, N), f'wz shape {wz.shape}'
    assert (ws > 0).all()
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 7 "quantize_awq_layer shapes/dtypes correct"
else
    fail 7 "quantize_awq_layer shape/dtype wrong"
fi

# ── Test 8 (0.18): AWQ roundtrip reconstruction (THE key behavioral) ───
# Validates that pack_awq_qweight + quantize_awq_layer together produce output
# that, when unpacked using the canonical nunchaku layout, reconstructs the
# original weight to within quantization error. Catches wrong shifts/indices,
# wrong row-interleave, and wrong dequant params.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
gs = 64

def unpack_canonical(qw, N, K):
    # Try without row interleave first
    packed_3d = qw.view(N, K//32, 4)
    unpacked = torch.zeros((N, K//32, 32), dtype=torch.int32)
    for g in range(4):
        for j in range(4):
            ie = 8*g + 2*j
            io = 8*g + 2*j + 1
            unpacked[:, :, ie] = (packed_3d[:, :, j] >> (4*g)) & 0xF
            unpacked[:, :, io] = (packed_3d[:, :, j] >> (16 + 4*g)) & 0xF
    return unpacked.view(N, K)

errs_a = []
for seed, N, K in [(1,4,64),(99,8,128),(7,16,256),(13,32,512)]:
    torch.manual_seed(seed)
    w = torch.randn(N, K, dtype=torch.bfloat16)
    qw, ws, wz = quantize_awq_layer(w)
    ng = K // gs
    unpacked = unpack_canonical(qw, N, K)
    scales = ws.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
    zeros  = wz.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
    recon = unpacked.float() * scales + zeros
    err = (w.float() - recon).abs().max().item()
    errs_a.append(err)
print('roundtrip max errs:', errs_a)
for e in errs_a:
    assert e < 0.5, f'roundtrip error too large: {e}'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.18 8 "AWQ pack/unpack roundtrip reconstruction < 0.5"
else
    fail 8 "AWQ roundtrip failed (pack indexing wrong?)"
fi

# ── Test 9 (0.10): pack_awq_qweight equivalence to canonical impl ──────
# Independently test pack_awq_qweight on synthetic 4-bit input.
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import pack_awq_qweight

def canonical_pack(weight4):
    N, K = weight4.shape
    assert K % 32 == 0 and N % 4 == 0
    w = weight4.view(N, K//32, 32)
    packed = torch.zeros((N, K//32, 4), dtype=torch.int32)
    for g in range(4):
        sl = 4*g
        sh = 16 + 4*g
        for j in range(4):
            ie = 8*g + 2*j
            io = 8*g + 2*j + 1
            packed[:,:,j] |= w[:,:,ie] << sl
            packed[:,:,j] |= w[:,:,io] << sh
    return packed.view(N, K//2)

mismatches = []
for seed, N, K in [(0,4,64),(1,8,128),(2,16,256),(3,32,128)]:
    torch.manual_seed(seed)
    w4 = torch.randint(0, 16, (N, K), dtype=torch.int32)
    expected = canonical_pack(w4.clone())
    actual = pack_awq_qweight(w4.clone())
    if actual.shape != expected.shape:
        mismatches.append(('shape', seed, actual.shape, expected.shape))
        continue
    # Allow either (N, K//2) flat or interleaved (N//4, K//2)
    if actual.shape == (N//4, K//2):
        # Maybe interleaved; check both flat-equiv possibilities
        # Reshape expected accordingly: nunchaku interleaves rows in groups of 4
        exp_flat = expected  # (N, K//2)
        act_flat = actual.view(N, K//2)
        if not torch.equal(act_flat, exp_flat):
            # Try permuted-row variants
            ok = False
            try:
                # (N//4, 4, K//2) interleave possibilities
                e = exp_flat.view(N//4, 4, K//2)
                for perm in [(0,1,2),(0,2,1)]:
                    pass
            except Exception:
                pass
            mismatches.append(('value', seed))
    else:
        if not torch.equal(actual, expected):
            mismatches.append(('value', seed))
print('pack mismatches:', mismatches)
assert len(mismatches) == 0, f'pack_awq_qweight differs from canonical: {mismatches}'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 9 "pack_awq_qweight equivalent to canonical impl"
else
    fail 9 "pack_awq_qweight not equivalent to canonical"
fi

# ── Test 10 (0.06): pack_awq_qweight loop simplified to single loop ────
# The instruction explicitly asks for single-loop with |= (not sum()).
python3 -c "
import ast, sys
with open('$QF') as f:
    src = f.read()
tree = ast.parse(src)
target = None
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == 'pack_awq_qweight':
        target = n
        break
assert target is not None
# Count For loops in pack_awq_qweight
for_count = sum(1 for n in ast.walk(target) if isinstance(n, ast.For))
# Check no sum() call inside
sum_calls = 0
for n in ast.walk(target):
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'sum':
        sum_calls += 1
# Also verify |= is used (AugAssign with BitOr)
has_ior = any(isinstance(n, ast.AugAssign) and isinstance(n.op, ast.BitOr) for n in ast.walk(target))
print(f'for_count={for_count} sum_calls={sum_calls} has_ior={has_ior}')
assert sum_calls == 0, 'must not use sum()'
assert has_ior, 'must use |= bitwise or'
assert for_count <= 1, f'must be single loop, got {for_count} for loops'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.06 10 "pack_awq_qweight simplified to single loop with |="
else
    fail 10 "pack_awq_qweight not simplified per instruction"
fi

# ── Test 11 (0.05): main() builds tensor key names correctly ───────────
# Check that the f-string bug ({weight}/{bias} as variables) is fixed.
python3 -c "
import re, sys
with open('$QF') as f:
    src = f.read()
# Look for the buggy pattern: f\"{name}.{weight}\" or f\"{name}.{bias}\" where weight/bias are vars
# After fix, should be {name}.weight (literal) or use a string variable
buggy_w = re.search(r'f[\"\']\\s*\\{[^}]*name[^}]*\\}\\.\\{weight\\}', src)
buggy_b = re.search(r'f[\"\']\\s*\\{[^}]*name[^}]*\\}\\.\\{bias\\}', src)
assert buggy_w is None, 'still has buggy {weight} interpolation'
assert buggy_b is None, 'still has buggy {bias} interpolation'
# Should reference .weight and .bias as literals somewhere
assert '.weight' in src and '.bias' in src, 'missing literal .weight/.bias keys'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 11 "main() tensor key construction fixed"
else
    fail 11 "main() key construction still buggy"
fi

# ── Test 12 (0.10): AWQ symmetric/edge behavior — semantic correctness ─
# Quantization should approximately preserve relative weight ordering and
# scales/zeros must satisfy w ≈ q*scale + zero with q in [0,15].
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
gs = 64

# 1. Constant input -> wscales > 0, recon close to input
w = torch.full((8, 128), 0.5, dtype=torch.bfloat16)
qw, ws, wz = quantize_awq_layer(w)
assert (ws > 0).all(), 'scales must be positive'
# All zeros tensor with one large outlier
torch.manual_seed(5)
w2 = torch.randn(16, 128, dtype=torch.bfloat16) * 0.01
w2[0, 0] = 5.0
qw2, ws2, wz2 = quantize_awq_layer(w2)
assert torch.isfinite(ws2).all()
assert torch.isfinite(wz2).all()
# 2. Average reconstruction error should be small relative to weight magnitude
torch.manual_seed(11)
N, K = 64, 256
w3 = torch.randn(N, K, dtype=torch.bfloat16)
qw3, ws3, wz3 = quantize_awq_layer(w3)
ng = K // gs
packed_3d = qw3.view(N, K//32, 4)
unpacked = torch.zeros((N, K//32, 32), dtype=torch.int32)
for g in range(4):
    for j in range(4):
        ie = 8*g + 2*j
        io = 8*g + 2*j + 1
        unpacked[:, :, ie] = (packed_3d[:, :, j] >> (4*g)) & 0xF
        unpacked[:, :, io] = (packed_3d[:, :, j] >> (16 + 4*g)) & 0xF
assert (unpacked >= 0).all() and (unpacked <= 15).all(), '4-bit range violated'
unpacked = unpacked.view(N, K)
scales = ws3.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
zeros  = wz3.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
recon = unpacked.float() * scales + zeros
rel_err = (w3.float() - recon).abs().mean().item() / w3.float().abs().mean().item()
print(f'mean relative error: {rel_err:.4f}')
assert rel_err < 0.15, f'mean relative error too high: {rel_err}'
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 12 "AWQ semantic correctness (range, recon error)"
else
    fail 12 "AWQ semantic check failed"
fi

# ── Test 13 (0.05): pack_svdq_qweight produces valid output ────────────
python3 -c "
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import pack_svdq_qweight, quantize_residual
torch.manual_seed(0)
for N, K in [(128,128),(256,256)]:
    residual = torch.randn(N, K, dtype=torch.float32)
    qw, ws = quantize_residual(residual)
    out = pack_svdq_qweight(qw)
    assert out is not None
    assert torch.is_tensor(out)
    assert out.numel() > 0
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.05 13 "pack_svdq_qweight produces valid output"
else
    fail 13 "pack_svdq_qweight failed"
fi

# ── Test 14 (0.10): No-op detection — original buggy file should fail ──
# Verify all four primary bugs are fixed (defensive: each contributes).
python3 -c "
import sys, re
with open('$QF') as f:
    src = f.read()
score = 0
# Bug 1: .max(...).values for residual
if re.search(r'torch\\.abs\\(residual\\)\\.max\\([^)]*\\)\\.values', src):
    score += 1
elif re.search(r'amax|\\.values', src):
    score += 1
# Bug 2: .min/.max .values for weight (awq)
if re.search(r'weight\\.min\\([^)]*\\)\\.values', src) or re.search(r'aminmax|w_min.*values|amin', src):
    score += 1
# Bug 3: f-string keys fixed (no {weight}/{bias} as var interpolation)
if not re.search(r'f[\"\']\\s*\\{[^}]*name[^}]*\\}\\.\\{(weight|bias)\\}', src):
    score += 1
# Bug 4: pack loop simplified (single for-loop in pack_awq_qweight body)
import ast
tree = ast.parse(src)
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == 'pack_awq_qweight':
        fc = sum(1 for x in ast.walk(n) if isinstance(x, ast.For))
        if fc == 1:
            score += 1
        break
print(f'bugs fixed score: {score}/4')
sys.exit(0 if score >= 3 else 1)
" 2>/dev/null
if [ $? -eq 0 ]; then
    add_reward 0.10 14 ">=3/4 primary bugs fixed structurally"
else
    fail 14 "fewer than 3/4 bugs fixed"
fi

echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0