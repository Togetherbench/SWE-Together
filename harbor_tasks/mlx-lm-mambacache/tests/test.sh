#!/usr/bin/env bash
#
# Verification test for MambaCache/ArraysCache batching support in mlx-lm.
#
# Weighted scoring: accumulates points out of 100, normalized to 0.0-1.0.
# 80% behavioral (F2P + Silver), 20% structural (Bronze AST).
#
# mlx is macOS-only (no Linux wheels on PyPI). A numpy-backed shim enables
# behavioral testing on Linux Docker by exec'ing cache.py directly, bypassing
# the heavy mlx_lm package import chain.
#
# No upstream CPU-safe tests available (mlx tests require Apple Metal) -- P2P skipped.
#
# Writes reward to /logs/verifier/reward.txt.
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"

###############################################################################
# SETUP: numpy-backed mlx shim + cache/generate loader
#
# Why a shim? mlx (Apple's ML framework) only publishes macOS wheels.
# Our Docker image is Linux. The shim maps mlx.core operations to numpy so
# we can exec cache.py and actually call ArraysCache/CacheList/MambaCache
# methods behaviorally instead of resorting to AST-only checks.
###############################################################################
cat > /tmp/mlx_test_env.py << 'ENVEOF'
import sys, types, ast
import numpy as np

# ---- mlx.core shim (numpy-backed) ----
if 'mlx.core' not in sys.modules:
    _mx = types.ModuleType('mlx.core')
    _mx.array = lambda x, dtype=None, **kw: np.array(x) if dtype is None else np.array(x, dtype=dtype)
    _mx.zeros = lambda shape, dtype=np.float32: np.zeros(shape, dtype=dtype)
    _mx.ones = lambda shape, dtype=np.float32: np.ones(shape, dtype=dtype)
    _mx.concatenate = lambda arrays, axis=0: np.concatenate(arrays, axis=axis)
    _mx.stack = lambda arrays, axis=0: np.stack(arrays, axis=axis)
    _mx.arange = lambda *a, **kw: np.arange(*a, **kw)
    _mx.expand_dims = lambda a, axis: np.expand_dims(a, axis=axis)
    _mx.pad = lambda a, widths, **kw: np.pad(a, widths)
    _mx.roll = lambda a, shift, **kw: np.roll(a, shift, **kw)
    _mx.take_along_axis = lambda a, idx, axis: np.take_along_axis(a, idx, axis=axis)
    _mx.where = lambda cond, x, y: np.where(cond, x, y)
    _mx.full = lambda shape, val, dtype=None: np.full(shape, val, dtype=dtype)
    _mx.contiguous = lambda x: np.ascontiguousarray(x)
    _mx.save_safetensors = lambda *a, **kw: None
    _mx.load = lambda *a, **kw: ({}, {})
    _mx.eval = lambda *a, **kw: None
    _mx.compile = lambda fn=None, **kw: fn if fn is not None else (lambda f: f)
    _mx.stop_gradient = lambda x, **kw: x
    _mx.abs = np.abs
    _mx.sum = np.sum
    _mx.max = np.max
    _mx.min = np.min
    _mx.float32 = np.float32
    _mx.float16 = np.float16
    _mx.bfloat16 = np.float32
    _mx.int32 = np.int32
    _mx.int64 = np.int64
    _mx.uint32 = np.uint32
    _mx.bool_ = np.bool_

    # ---- mlx.nn shim ----
    _nn = types.ModuleType('mlx.nn')
    class _Mod: pass
    _nn.Module = _Mod
    _nn.Linear = type('Linear', (_Mod,), {})
    _nn.Embedding = type('Embedding', (_Mod,), {})
    _nn.QuantizedLinear = type('QuantizedLinear', (_Mod,), {})
    _nn.QuantizedEmbedding = type('QuantizedEmbedding', (_Mod,), {})
    _nn.quantize = lambda *a, **kw: None

    # ---- mlx.utils shim ----
    _utils = types.ModuleType('mlx.utils')
    def _tf(tree, prefix="", sep="."):
        if isinstance(tree, (list, tuple)):
            r = []
            for i, item in enumerate(tree):
                key = f"{prefix}{sep}{i}" if prefix else str(i)
                r.extend(_tf(item, key, sep) if isinstance(item, (list, tuple, dict)) else [(key, item)])
            return r
        elif isinstance(tree, dict):
            r = []
            for k, v in tree.items():
                key = f"{prefix}{sep}{k}" if prefix else str(k)
                r.extend(_tf(v, key, sep) if isinstance(v, (list, tuple, dict)) else [(key, v)])
            return r
        return [(prefix, tree)]
    _utils.tree_flatten = lambda tree, **kw: _tf(tree)
    _utils.tree_unflatten = lambda pairs: pairs
    _utils.tree_map = lambda fn, tree, *r: tree
    _utils.tree_reduce = lambda fn, tree, **kw: None

    # Register all modules
    _mlx = types.ModuleType('mlx')
    _mlx.core = _mx; _mlx.nn = _nn; _mlx.utils = _utils
    sys.modules['mlx'] = _mlx
    sys.modules['mlx.core'] = _mx
    sys.modules['mlx.nn'] = _nn
    sys.modules['mlx.utils'] = _utils

# ---- Load cache.py via exec (avoids mlx_lm package import chain) ----
with open("/workspace/mlx-lm/mlx_lm/models/cache.py") as _f:
    _cache_src = _f.read()
# Replace relative import with stub (not needed for our tests)
_cache_src = _cache_src.replace(
    "from .base import create_causal_mask",
    "def create_causal_mask(*_a, **_kw): return None"
)
_cache_ns = {'__builtins__': __builtins__}
exec(compile(_cache_src, 'cache.py', 'exec'), _cache_ns)

ArraysCache = _cache_ns['ArraysCache']
MambaCache = _cache_ns['MambaCache']
CacheList = _cache_ns['CacheList']
KVCache = _cache_ns['KVCache']
BatchKVCache = _cache_ns['BatchKVCache']
RotatingKVCache = _cache_ns.get('RotatingKVCache')
BatchRotatingKVCache = _cache_ns.get('BatchRotatingKVCache')

# ---- Load _merge_caches from generate.py via AST extraction ----
_merge_caches = None
try:
    with open("/workspace/mlx-lm/mlx_lm/generate.py") as _f:
        _gen_src = _f.read()
    _gen_tree = ast.parse(_gen_src)
    _func_src = None
    for _node in ast.walk(_gen_tree):
        if isinstance(_node, ast.FunctionDef) and _node.name == "_merge_caches":
            _func_src = ast.get_source_segment(_gen_src, _node)
            break
    if _func_src:
        _merge_ns = {
            '__builtins__': __builtins__,
            'KVCache': KVCache, 'BatchKVCache': BatchKVCache,
            'RotatingKVCache': RotatingKVCache,
            'BatchRotatingKVCache': BatchRotatingKVCache,
            'ArraysCache': ArraysCache, 'CacheList': CacheList,
        }
        exec(compile(_func_src, 'generate.py', 'exec'), _merge_ns)
        _merge_caches = _merge_ns.get('_merge_caches')
except Exception as _e:
    print(f"WARNING: could not load _merge_caches: {_e}")

import mlx.core as mx
ENVEOF

###############################################################################
# TEST 1/10 [F2P, 15pts]: _merge_caches works with ArraysCache
#   Base commit: raises "ValueError: ... does not yet support batching with history"
#   After fix: returns batched cache with correct batch dim and values
###############################################################################
echo "=== Test 1/10: F2P -- _merge_caches handles ArraysCache (15pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 15)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if _merge_caches is None:
    print("FAIL: could not extract _merge_caches from generate.py")
    sys.exit(1)

ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3))
ac1.cache[1] = mx.ones((1, 4, 8)) * 2.0

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 3.0
ac2.cache[1] = mx.ones((1, 4, 8)) * 4.0

# At base commit this raises: ValueError("...does not yet support batching with history")
try:
    merged = _merge_caches([[ac1], [ac2]])
except ValueError as e:
    if "does not yet support batching" in str(e):
        print(f"FAIL: _merge_caches still raises original ValueError: {e}")
    else:
        print(f"FAIL: _merge_caches raised ValueError: {e}")
    sys.exit(1)
except Exception as e:
    print(f"FAIL: _merge_caches raised {type(e).__name__}: {e}")
    sys.exit(1)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL: expected list of length 1, got {type(merged).__name__} len={getattr(merged, '__len__', lambda: '?')()}")
    sys.exit(1)

m = merged[0]
if not hasattr(m, 'cache') or m.cache[0] is None:
    print("FAIL: merged result has no valid cache data")
    sys.exit(1)

if m.cache[0].shape[0] != 2:
    print(f"FAIL: batch dim is {m.cache[0].shape[0]}, expected 2")
    sys.exit(1)

v0 = float(m.cache[0][0, 0, 0])
v1 = float(m.cache[0][1, 0, 0])
if abs(v0 - 1.0) > 0.01 or abs(v1 - 3.0) > 0.01:
    print(f"FAIL: values [{v0}, {v1}], expected [1.0, 3.0]")
    sys.exit(1)

print("PASS: _merge_caches handles ArraysCache with correct batched result")
sys.exit(0)
PYEOF

###############################################################################
# TEST 2/10 [F2P, 10pts]: _merge_caches works with CacheList
#   Base commit: raises ValueError for CacheList (wrapping ArraysCache)
#   After fix: recursively merges sub-caches inside CacheList
###############################################################################
echo ""
echo "=== Test 2/10: F2P -- _merge_caches handles CacheList (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if _merge_caches is None:
    print("FAIL: could not extract _merge_caches from generate.py")
    sys.exit(1)

ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3))
ac1.cache[1] = mx.ones((1, 4, 8))

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 2.0
ac2.cache[1] = mx.ones((1, 4, 8)) * 2.0

cl1 = CacheList(ac1)
cl2 = CacheList(ac2)

try:
    merged = _merge_caches([[cl1], [cl2]])
except ValueError as e:
    if "does not yet support batching" in str(e):
        print("FAIL: _merge_caches still raises original ValueError for CacheList")
    else:
        print(f"FAIL: ValueError: {e}")
    sys.exit(1)
except Exception as e:
    print(f"FAIL: _merge_caches raised {type(e).__name__}: {e}")
    sys.exit(1)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL: expected list of length 1")
    sys.exit(1)

m = merged[0]
# Access sub-cache (may be via .caches attribute or indexing)
sub = None
if hasattr(m, 'caches') and len(m.caches) > 0:
    sub = m.caches[0]
elif hasattr(m, '__getitem__'):
    try:
        sub = m[0]
    except Exception:
        pass

if sub is None or not hasattr(sub, 'cache') or sub.cache[0] is None:
    print("FAIL: cannot access batched sub-cache from merged CacheList")
    sys.exit(1)

if sub.cache[0].shape[0] != 2:
    print(f"FAIL: sub-cache batch dim is {sub.cache[0].shape[0]}, expected 2")
    sys.exit(1)

print("PASS: _merge_caches handles CacheList with batched sub-caches")
sys.exit(0)
PYEOF

###############################################################################
# TEST 3/10 [Silver, 12pts]: ArraysCache.merge batches 3 caches correctly
###############################################################################
echo ""
echo "=== Test 3/10: Silver -- ArraysCache.merge correct batched output (12pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 12)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if not hasattr(ArraysCache, 'merge') or not callable(getattr(ArraysCache, 'merge')):
    print("FAIL: ArraysCache has no callable merge method")
    sys.exit(1)

c1 = ArraysCache(size=2)
c1.cache[0] = mx.ones((1, 4, 3)) * 1.0
c1.cache[1] = mx.ones((1, 4, 8)) * 10.0

c2 = ArraysCache(size=2)
c2.cache[0] = mx.ones((1, 4, 3)) * 2.0
c2.cache[1] = mx.ones((1, 4, 8)) * 20.0

c3 = ArraysCache(size=2)
c3.cache[0] = mx.ones((1, 4, 3)) * 3.0
c3.cache[1] = mx.ones((1, 4, 8)) * 30.0

try:
    merged = ArraysCache.merge([c1, c2, c3])
except Exception as e:
    print(f"FAIL: merge raised: {e}")
    sys.exit(1)

if not isinstance(merged, ArraysCache):
    print(f"FAIL: merge returned {type(merged).__name__}, expected ArraysCache")
    sys.exit(1)

if merged.cache[0].shape[0] != 3 or merged.cache[1].shape[0] != 3:
    print(f"FAIL: batch dims {merged.cache[0].shape[0]}, {merged.cache[1].shape[0]}, expected 3, 3")
    sys.exit(1)

for i, exp in enumerate([1.0, 2.0, 3.0]):
    v = float(merged.cache[0][i, 0, 0])
    if abs(v - exp) > 0.01:
        print(f"FAIL: cache[0][{i}] = {v}, expected {exp}")
        sys.exit(1)

for i, exp in enumerate([10.0, 20.0, 30.0]):
    v = float(merged.cache[1][i, 0, 0])
    if abs(v - exp) > 0.01:
        print(f"FAIL: cache[1][{i}] = {v}, expected {exp}")
        sys.exit(1)

print("PASS: merge of 3 caches produces batch dim 3 with correct values")
sys.exit(0)
PYEOF

###############################################################################
# TEST 4/10 [Silver, 10pts]: ArraysCache.extract recovers individual caches
###############################################################################
echo ""
echo "=== Test 4/10: Silver -- ArraysCache.extract recovers individual caches (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

c1 = ArraysCache(size=2)
c1.cache[0] = mx.ones((1, 4, 3)) * 10.0
c1.cache[1] = mx.ones((1, 4, 8)) * 20.0

c2 = ArraysCache(size=2)
c2.cache[0] = mx.ones((1, 4, 3)) * 30.0
c2.cache[1] = mx.ones((1, 4, 8)) * 40.0

try:
    merged = ArraysCache.merge([c1, c2])
    ex0 = merged.extract(0)
    ex1 = merged.extract(1)
except Exception as e:
    print(f"FAIL: merge/extract raised: {e}")
    sys.exit(1)

if not isinstance(ex0, ArraysCache):
    print(f"FAIL: extract(0) returned {type(ex0).__name__}, expected ArraysCache")
    sys.exit(1)

if ex0.cache[0].shape[0] != 1:
    print(f"FAIL: extracted batch dim is {ex0.cache[0].shape[0]}, expected 1")
    sys.exit(1)

for ext, expected, name in [(ex0, [10.0, 20.0], "ex0"), (ex1, [30.0, 40.0], "ex1")]:
    for slot, exp in enumerate(expected):
        v = float(ext.cache[slot][0, 0, 0])
        if abs(v - exp) > 0.01:
            print(f"FAIL: {name}.cache[{slot}] = {v}, expected {exp}")
            sys.exit(1)

print("PASS: extract recovers correct individual caches from merged batch")
sys.exit(0)
PYEOF

###############################################################################
# TEST 5/10 [Silver, 10pts]: CacheList.merge + extract round-trip
###############################################################################
echo ""
echo "=== Test 5/10: Silver -- CacheList.merge + extract round-trip (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if not hasattr(CacheList, 'merge'):
    print("FAIL: CacheList has no 'merge' method")
    sys.exit(1)

ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3)) * 5.0
ac1.cache[1] = mx.ones((1, 4, 8)) * 6.0

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 7.0
ac2.cache[1] = mx.ones((1, 4, 8)) * 8.0

cl1 = CacheList(ac1)
cl2 = CacheList(ac2)

try:
    merged = CacheList.merge([cl1, cl2])
except Exception as e:
    print(f"FAIL: CacheList.merge raised: {e}")
    sys.exit(1)

if not isinstance(merged, CacheList):
    print(f"FAIL: CacheList.merge returned {type(merged).__name__}")
    sys.exit(1)

try:
    ex0 = merged.extract(0)
    ex1 = merged.extract(1)
except Exception as e:
    print(f"FAIL: CacheList.extract raised: {e}")
    sys.exit(1)

sub0 = ex0.caches[0] if hasattr(ex0, 'caches') else ex0[0]
sub1 = ex1.caches[0] if hasattr(ex1, 'caches') else ex1[0]

v0 = float(sub0.cache[0][0, 0, 0])
v1 = float(sub1.cache[0][0, 0, 0])
if abs(v0 - 5.0) > 0.01 or abs(v1 - 7.0) > 0.01:
    print(f"FAIL: extracted values [{v0}, {v1}], expected [5.0, 7.0]")
    sys.exit(1)

print("PASS: CacheList merge + extract round-trip with correct values")
sys.exit(0)
PYEOF

###############################################################################
# TEST 6/10 [Silver, 8pts]: MambaCache inherits merge/extract from ArraysCache
###############################################################################
echo ""
echo "=== Test 6/10: Silver -- MambaCache inherits merge/extract (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if not hasattr(MambaCache, 'merge') or not callable(getattr(MambaCache, 'merge')):
    print("FAIL: MambaCache has no callable merge method")
    sys.exit(1)

# MambaCache.__init__ takes no size arg (fixed at 2)
try:
    mc1 = MambaCache()
except TypeError:
    mc1 = MambaCache(size=2)  # fallback if signature changed

try:
    mc2 = MambaCache()
except TypeError:
    mc2 = MambaCache(size=2)

size = len(mc1.cache)
for i in range(size):
    mc1.cache[i] = mx.ones((1, 2, 2)) * (1.0 + i)
    mc2.cache[i] = mx.ones((1, 2, 2)) * (100.0 + i)

try:
    merged = MambaCache.merge([mc1, mc2])
except Exception as e:
    print(f"FAIL: MambaCache.merge raised: {e}")
    sys.exit(1)

if not isinstance(merged, (MambaCache, ArraysCache)):
    print(f"FAIL: merge returned {type(merged).__name__}, expected MambaCache or ArraysCache")
    sys.exit(1)

if merged.cache[0].shape[0] != 2:
    print(f"FAIL: batch dim is {merged.cache[0].shape[0]}, expected 2")
    sys.exit(1)

try:
    ex = merged.extract(1)
except Exception as e:
    print(f"FAIL: extract raised: {e}")
    sys.exit(1)

v = float(ex.cache[0][0, 0, 0])
if abs(v - 100.0) > 0.01:
    print(f"FAIL: extracted value = {v}, expected 100.0")
    sys.exit(1)

print("PASS: MambaCache inherits merge/extract with correct behavior")
sys.exit(0)
PYEOF

###############################################################################
# TEST 7/10 [Silver, 10pts]: _lengths / make_mask right-padding
#   Base commit: make_mask ignores _lengths, returns all-True mask
#   After fix: make_mask uses _lengths to create right-padding mask
###############################################################################
echo ""
echo "=== Test 7/10: Silver -- _lengths support in make_mask for right-padding (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

# Create cache with left_padding (triggers mask generation in make_mask)
try:
    ac = ArraysCache(size=1, left_padding=[0, 0])
except TypeError:
    ac = ArraysCache(size=1)
    ac.left_padding = mx.array([0, 0])

# Set _lengths via prepare() or direct attribute
lengths_set = False
if hasattr(ac, 'prepare') and callable(ac.prepare):
    try:
        ac.prepare(lengths=[3, 4])
        lengths_set = True
    except TypeError:
        pass

if not lengths_set:
    try:
        ac._lengths = mx.array([3, 4])
        lengths_set = True
    except Exception:
        pass

if not lengths_set:
    print("FAIL: Cannot set _lengths via prepare() or attribute")
    sys.exit(1)

if getattr(ac, '_lengths', None) is None:
    print("FAIL: _lengths is None after setting")
    sys.exit(1)

try:
    mask = ac.make_mask(5)
except Exception as e:
    print(f"FAIL: make_mask(5) raised: {e}")
    sys.exit(1)

if mask is None:
    print("FAIL: make_mask returned None despite _lengths being set")
    sys.exit(1)

# Flatten to 2D for checking (mask may be 2D, 3D, or 4D depending on impl)
import numpy as _np
mask_np = _np.array(mask.tolist()) if hasattr(mask, 'tolist') else _np.array(mask)
while mask_np.ndim > 2:
    mask_np = mask_np.squeeze(axis=1)

if mask_np.shape[0] < 2 or mask_np.shape[1] < 5:
    print(f"FAIL: mask shape {mask_np.shape} too small, expected at least (2, 5)")
    sys.exit(1)

# Row 0 (length=3, left_pad=0): position 2 should be True, position 3 should be False
if not bool(mask_np[0, 2]):
    print(f"FAIL: row 0 pos 2 should be True (within length 3)")
    sys.exit(1)
if bool(mask_np[0, 3]):
    print(f"FAIL: row 0 pos 3 should be False (right-padded, length=3)")
    sys.exit(1)

# Row 1 (length=4, left_pad=0): position 3 should be True, position 4 should be False
if not bool(mask_np[1, 3]):
    print(f"FAIL: row 1 pos 3 should be True (within length 4)")
    sys.exit(1)
if bool(mask_np[1, 4]):
    print(f"FAIL: row 1 pos 4 should be False (right-padded, length=4)")
    sys.exit(1)

print("PASS: _lengths creates correct right-padding mask in make_mask")
sys.exit(0)
PYEOF

###############################################################################
# TEST 8/10 [Silver, 5pts]: prepare() and finalize() work correctly
###############################################################################
echo ""
echo "=== Test 8/10: Silver -- prepare() and finalize() functional (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

ac = ArraysCache(size=2)

if not hasattr(ac, 'prepare') or not callable(ac.prepare):
    print("FAIL: ArraysCache has no callable prepare method")
    sys.exit(1)

if not hasattr(ac, 'finalize') or not callable(ac.finalize):
    print("FAIL: ArraysCache has no callable finalize method")
    sys.exit(1)

# Test prepare with left_padding sets up mask generation
try:
    ac.prepare(left_padding=[2, 0])
except Exception as e:
    print(f"FAIL: prepare(left_padding=[2, 0]) raised: {e}")
    sys.exit(1)

# After prepare with left_padding, left_padding should be set
lp = getattr(ac, 'left_padding', None)
if lp is None:
    print("FAIL: left_padding not set after prepare(left_padding=[2, 0])")
    sys.exit(1)

# Test finalize runs without error
try:
    ac.finalize()
except Exception as e:
    print(f"FAIL: finalize() raised: {e}")
    sys.exit(1)

print("PASS: prepare() and finalize() are functional")
sys.exit(0)
PYEOF

###############################################################################
# STRUCTURAL CHECKS (20%)
###############################################################################

###############################################################################
# TEST 9/10 [Bronze, 10pts]: ArraysCache merge+extract AST non-trivial
# Justification: AST supplements behavioral Tests 3-4. Rejects stubs that
# pass hasattr but have empty bodies.
###############################################################################
echo ""
echo "=== Test 9/10: AST -- ArraysCache merge+extract non-trivial (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

def count_meaningful_stmts(func_node):
    """Count statements that indicate real logic (not stubs)."""
    count = 0
    for s in ast.walk(func_node):
        if s is func_node:
            continue
        if isinstance(s, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                          ast.For, ast.While, ast.If, ast.With,
                          ast.Try, ast.Raise, ast.Assert)):
            count += 1
        elif isinstance(s, ast.Return) and s.value is not None:
            if not (isinstance(s.value, ast.Constant) and s.value.value is None):
                count += 1
        elif isinstance(s, ast.Expr) and isinstance(s.value, ast.Call):
            count += 1
    return count

found = False
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        found = True
        methods = {n.name: n for n in node.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}

        if "merge" not in methods:
            print("FAIL: ArraysCache has no merge method")
            sys.exit(1)
        if "extract" not in methods:
            print("FAIL: ArraysCache has no extract method")
            sys.exit(1)

        merge = methods["merge"]
        is_cm = any(
            (isinstance(d, ast.Name) and d.id == "classmethod") or
            (isinstance(d, ast.Attribute) and d.attr == "classmethod")
            for d in merge.decorator_list
        )
        params = [a.arg for a in merge.args.args]
        if not is_cm and not (params and params[0] == "cls"):
            print("FAIL: merge is not a classmethod")
            sys.exit(1)

        merge_stmts = count_meaningful_stmts(merge)
        if merge_stmts < 4:
            print(f"FAIL: merge has only {merge_stmts} meaningful stmts (need >=4)")
            sys.exit(1)

        extract = methods["extract"]
        ex_params = [a.arg for a in extract.args.args]
        if len(ex_params) < 2:
            print(f"FAIL: extract has no idx parameter (params: {ex_params})")
            sys.exit(1)

        extract_stmts = count_meaningful_stmts(extract)
        if extract_stmts < 3:
            print(f"FAIL: extract has only {extract_stmts} meaningful stmts (need >=3)")
            sys.exit(1)

        print(f"PASS: merge ({merge_stmts} stmts, classmethod) + extract ({extract_stmts} stmts)")
        sys.exit(0)

if not found:
    print("FAIL: ArraysCache class not found in cache.py")
sys.exit(1)
PYEOF

###############################################################################
# TEST 10/10 [Bronze, 10pts]: CacheList merge+extract AST non-trivial
# Justification: AST supplements behavioral Test 5. Rejects stubs that
# pass hasattr but have empty bodies.
###############################################################################
echo ""
echo "=== Test 10/10: AST -- CacheList merge+extract non-trivial (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

def count_meaningful_stmts(func_node):
    """Count statements that indicate real logic (not stubs)."""
    count = 0
    for s in ast.walk(func_node):
        if s is func_node:
            continue
        if isinstance(s, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                          ast.For, ast.While, ast.If, ast.With,
                          ast.Try, ast.Raise, ast.Assert)):
            count += 1
        elif isinstance(s, ast.Return) and s.value is not None:
            if not (isinstance(s.value, ast.Constant) and s.value.value is None):
                count += 1
        elif isinstance(s, ast.Expr) and isinstance(s.value, ast.Call):
            count += 1
    return count

found = False
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "CacheList":
        found = True
        methods = {n.name: n for n in node.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}

        if "merge" not in methods:
            print("FAIL: CacheList has no merge method")
            sys.exit(1)
        if "extract" not in methods:
            print("FAIL: CacheList has no extract method")
            sys.exit(1)

        merge = methods["merge"]
        is_cm = any(
            (isinstance(d, ast.Name) and d.id == "classmethod") or
            (isinstance(d, ast.Attribute) and d.attr == "classmethod")
            for d in merge.decorator_list
        )
        params = [a.arg for a in merge.args.args]
        if not is_cm and not (params and params[0] == "cls"):
            print("FAIL: CacheList.merge is not a classmethod")
            sys.exit(1)

        merge_stmts = count_meaningful_stmts(merge)
        if merge_stmts < 3:
            print(f"FAIL: CacheList.merge has only {merge_stmts} meaningful stmts (need >=3)")
            sys.exit(1)

        extract_stmts = count_meaningful_stmts(methods["extract"])
        if extract_stmts < 2:
            print(f"FAIL: CacheList.extract has only {extract_stmts} meaningful stmts (need >=2)")
            sys.exit(1)

        print(f"PASS: CacheList.merge ({merge_stmts} stmts) + extract ({extract_stmts} stmts)")
        sys.exit(0)

if not found:
    print("FAIL: CacheList class not found in cache.py")
sys.exit(1)
PYEOF

###############################################################################
# FINAL SCORE
###############################################################################
echo ""
echo "================================"
echo "Score: $SCORE / 100"
echo "================================"

REWARD=$(python3 -c "print(min(1.0, round($SCORE / 100, 2)))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
