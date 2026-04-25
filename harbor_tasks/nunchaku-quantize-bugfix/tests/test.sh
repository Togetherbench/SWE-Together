#!/bin/bash
set +e

# Verifier for nunchaku-quantize-bugfix
# All reward comes from F2P behavioral checks that fail on the buggy base.

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

finish() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

if [ ! -f "$QF" ]; then
    echo "FATAL: $QF missing"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

# ── Gate (P2P): file parses & functions defined (passes on base; gating only) ──
python3 -c "
import ast, sys
with open('$QF') as f:
    tree = ast.parse(f.read())
found = set()
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef):
        found.add(n.name)
for name in ('pack_awq_qweight','quantize_residual','quantize_awq_layer','pack_svdq_qweight'):
    assert name in found, name
" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "GATE FAIL: file syntax / missing functions"
    finish
fi

python3 -c "
import sys
sys.path.insert(0, '/workspace')
import quantize
for fn in ('quantize_residual','quantize_awq_layer','pack_awq_qweight','pack_svdq_qweight'):
    assert hasattr(quantize, fn), fn
" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "GATE FAIL: module import error"
    finish
fi

# ── F2P 1 (0.12): quantize_residual runs without crash ─────────────────
# Buggy base uses .max(...).keepdim=True without .values → returns namedtuple,
# subsequent arithmetic crashes.
python3 - <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_residual
torch.manual_seed(0)
residual = torch.randn(128, 128, dtype=torch.float32)
qweight, wscales = quantize_residual(residual)
assert qweight.dtype == torch.int8
assert qweight.shape == (128, 64)
assert wscales.shape == (2, 128)
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.12 1 "quantize_residual runs and returns correct shapes/dtypes"
else
    fail 1 "quantize_residual crash or wrong shape (.values bug)"
fi

# ── F2P 2 (0.10): quantize_residual semantic correctness ───────────────
python3 - <<'PYEOF' 2>/dev/null
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
assert (max_abs <= ws.T * 7 + 1e-3).all(), 'scale bound violated'
torch.manual_seed(1)
r2 = torch.randn(64, 128, dtype=torch.float32)
qa, sa = quantize_residual(r2)
qb, sb = quantize_residual(-r2)
assert torch.allclose(sa, sb, atol=1e-5), 'symmetric scales should match'
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.10 2 "quantize_residual semantics correct"
else
    fail 2 "quantize_residual semantic check failed"
fi

# ── F2P 3 (0.15): quantize_awq_layer runs and shapes/dtypes correct ────
# Buggy base: .min/.max without .values → crash.
python3 - <<'PYEOF' 2>/dev/null
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
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.15 3 "quantize_awq_layer runs with correct shapes/dtypes"
else
    fail 3 "quantize_awq_layer crash or wrong shape"
fi

# ── F2P 4 (0.25): AWQ pack/unpack roundtrip reconstruction ─────────────
# Tests that pack_awq_qweight + quantize_awq_layer reconstruct weights when
# unpacked using nunchaku canonical layout. Catches wrong shifts/indices.
python3 - <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import quantize_awq_layer
gs = 64

def unpack_canonical(qw_packed, N, K):
    # Try both layouts: (N, K//2) flat OR (N//4, K//2) row-interleaved.
    # We test against full-row (N, K//2) here.
    packed_3d = qw_packed.view(N, K//32, 4)
    unpacked = torch.zeros((N, K//32, 32), dtype=torch.int32)
    for g in range(4):
        for j in range(4):
            ie = 8*g + 2*j
            io = 8*g + 2*j + 1
            unpacked[:, :, ie] = (packed_3d[:, :, j] >> (4*g)) & 0xF
            unpacked[:, :, io] = (packed_3d[:, :, j] >> (16 + 4*g)) & 0xF
    return unpacked.view(N, K)

def deinterleave_rows(qw, N, K):
    # If shape is (N//4, K//2), try undoing the 4-row interleave that
    # nunchaku uses, returning to (N, K//2).
    # The exact permutation is tested by reconstruction quality below.
    candidates = []
    # Candidate A: simple reshape (no interleave)
    candidates.append(qw.view(N, K//2))
    # Candidate B: (N//4, K//64, 4, 2, 4) -> permute (0,2,1,3,4) -> (N, K//2)
    try:
        c = qw.reshape(N//4, K//64, 4, 2, 4).permute(0, 2, 1, 3, 4).contiguous().reshape(N, K//2)
        candidates.append(c)
    except Exception:
        pass
    # Candidate C: simple reshape via different chunking
    try:
        c = qw.reshape(N//4, 4, K//2).permute(0, 1, 2).reshape(N, K//2)
        candidates.append(c)
    except Exception:
        pass
    return candidates

errs_overall = []
for seed, N, K in [(1,4,64),(99,8,128),(7,16,256),(13,32,512)]:
    torch.manual_seed(seed)
    w = torch.randn(N, K, dtype=torch.bfloat16)
    qw, ws, wz = quantize_awq_layer(w)
    ng = K // gs

    # qw shape is (N//4, K//2); try multiple deinterleave candidates and
    # take the best reconstruction (implementation-agnostic).
    cands = deinterleave_rows(qw, N, K)
    best = float('inf')
    for cand in cands:
        try:
            unpacked = unpack_canonical(cand, N, K)
            scales = ws.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
            zeros  = wz.T.float().unsqueeze(-1).expand(N, ng, gs).reshape(N, K)
            recon = unpacked.float() * scales + zeros
            err = (w.float() - recon).abs().max().item()
            if err < best:
                best = err
        except Exception:
            continue
    errs_overall.append(best)

print('roundtrip max errs:', errs_overall)
for e in errs_overall:
    assert e < 0.5, f'roundtrip error too large: {e}'
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.25 4 "AWQ pack/unpack roundtrip reconstruction < 0.5"
else
    fail 4 "AWQ roundtrip failed (pack indexing or row interleave wrong)"
fi

# ── F2P 5 (0.18): pack_awq_qweight equivalence (canonical 4-bit pack) ──
# Independently tests pack_awq_qweight on synthetic 4-bit input.
# Accepts either (N, K//2) flat or (N//4, K//2) row-interleaved layout.
python3 - <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, '/workspace')
import torch
from quantize import pack_awq_qweight

def canonical_pack_flat(weight4):
    N, K = weight4.shape
    w = weight4.view(N, K//32, 32)
    packed = torch.zeros((N, K//32, 4), dtype=torch.int32)
    for g in range(4):
        for j in range(4):
            ie = 8*g + 2*j
            io = 8*g + 2*j + 1
            packed[:,:,j] |= w[:,:,ie] << (4*g)
            packed[:,:,j] |= w[:,:,io] << (16 + 4*g)
    return packed.view(N, K//2)

def matches_any_layout(actual, expected_flat, N, K):
    if actual.shape == expected_flat.shape:
        if torch.equal(actual, expected_flat):
            return True
    if actual.shape == (N//4, K//2):
        # Try several deinterleave permutations
        try:
            cand = actual.reshape(N//4, K//64, 4, 2, 4).permute(0, 2, 1, 3, 4).contiguous().reshape(N, K//2)
            if torch.equal(cand, expected_flat):
                return True
        except Exception:
            pass
        try:
            cand = actual.reshape(N//4, 4, K//2).reshape(N, K//2)
            if torch.equal(cand, expected_flat):
                return True
        except Exception:
            pass
    return False

ok = True
for seed, N, K in [(0,4,64),(1,8,128),(2,16,256),(3,32,128)]:
    torch.manual_seed(seed)
    w4 = torch.randint(0, 16, (N, K), dtype=torch.int32)
    expected = canonical_pack_flat(w4.clone())
    actual = pack_awq_qweight(w4.clone())
    if not matches_any_layout(actual, expected, N, K):
        print(f'mismatch seed={seed} N={N} K={K} actual_shape={actual.shape}')
        ok = False
assert ok
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.18 5 "pack_awq_qweight matches canonical packing"
else
    fail 5 "pack_awq_qweight differs from canonical layout"
fi

# ── F2P 6 (0.10): pack_awq_qweight uses simplified single loop with |= ──
# Per instruction: "nested loops in pack_awq_qweight can be simplified to a
# single loop using bitwise |= operations (not sum())". Verify structurally
# that the function body has at most one for-loop and uses an augmented BitOr.
python3 - <<'PYEOF' 2>/dev/null
import ast, sys
with open('/workspace/quantize.py') as f:
    tree = ast.parse(f.read())

target = None
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == 'pack_awq_qweight':
        target = n
        break
assert target is not None

# Count for-loops anywhere in the function body
for_count = 0
has_bitor_aug = False
has_sum_call = False
for node in ast.walk(target):
    if isinstance(node, ast.For):
        for_count += 1
    if isinstance(node, ast.AugAssign) and isinstance(node.op, ast.BitOr):
        has_bitor_aug = True
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'sum':
        has_sum_call = True

# Buggy base: 2 nested for-loops. Correct simplification: 1 for-loop.
assert for_count <= 1, f'expected single loop, found {for_count}'
assert has_bitor_aug, 'expected |= bitwise-or augmented assignment'
assert not has_sum_call, 'should not use sum()'
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.10 6 "pack_awq_qweight simplified to single loop with |="
else
    fail 6 "pack_awq_qweight not simplified per instructions"
fi

# ── F2P 7 (0.10): main() constructs correct tensor key names ───────────
# Buggy base: get_b(f"{name}.{weight}") shadows the variable, producing
# garbage keys. Verify the source uses literal .weight / .bias suffixes.
python3 - <<'PYEOF' 2>/dev/null
import re
src = open('/workspace/quantize.py').read()
# Look for the f-string construction; it must use the literal suffix
# "{name}.weight" / "{name}.bias", not the local variables {weight}/{bias}.
# Reject if the buggy form survives anywhere.
buggy = re.search(r'f"\{name\}\.\{weight\}"', src) or re.search(r"f'\{name\}\.\{weight\}'", src)
assert not buggy, 'buggy {name}.{weight} f-string still present'
buggy_b = re.search(r'f"\{name\}\.\{bias\}"', src) or re.search(r"f'\{name\}\.\{bias\}'", src)
assert not buggy_b, 'buggy {name}.{bias} f-string still present'
# And require the corrected form to be present
good_w = re.search(r'f"\{name\}\.weight"', src) or re.search(r"f'\{name\}\.weight'", src)
good_b = re.search(r'f"\{name\}\.bias"', src) or re.search(r"f'\{name\}\.bias'", src)
assert good_w, 'expected f"{name}.weight"'
assert good_b, 'expected f"{name}.bias"'
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.10 7 "main() uses correct .weight/.bias key names"
else
    fail 7 "main() still uses shadowed {weight}/{bias} f-string keys"
fi

echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0