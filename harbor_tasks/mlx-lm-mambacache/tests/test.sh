#!/bin/bash
#
# Verification test for MambaCache/ArraysCache batching support in mlx-lm.
#
# Weighted scoring: accumulates points out of 100, normalized to 0.0-1.0.
# ~82% behavioral (F2P + Silver), ~18% structural (Bronze AST), ~4% P2P.
# Total raw points exceed 100 (capped at 1.0) to allow multi-turn coverage
# checks without diluting the existing discriminating tests.
#
# F2P/P2P classification:
#   F2P (fail-to-pass): Tests 1-18 — all test features absent at base commit
#   P2P (pass-to-pass): P2P-1 (source files intact), P2P-2 (tool_parsers)
#
# mlx is macOS-only (no Linux wheels on PyPI). A numpy-backed shim enables
# behavioral testing on Linux Docker by exec'ing cache.py directly, bypassing
# the heavy mlx_lm package import chain.
#
# Upstream P2P: tool_parsers tests are CPU-safe (pure Python, no mlx needed).
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
    _mx.squeeze = lambda a, axis=None: np.squeeze(a, axis=axis)
    _mx.reshape = lambda a, shape: np.reshape(a, shape)
    _mx.split = lambda a, indices_or_sections, axis=0: np.split(a, indices_or_sections, axis=axis)
    _mx.transpose = lambda a, axes=None: np.transpose(a, axes=axes)
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
# TEST 1 [F2P, 10pts]: _merge_caches works with ArraysCache
#   Base commit: raises "ValueError: ... does not yet support batching with history"
#   After fix: returns batched cache with correct batch dim and values
###############################################################################
echo "=== Test 1: F2P -- _merge_caches handles ArraysCache (10pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
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
# TEST 2 [F2P, 8pts]: _merge_caches works with CacheList
#   Base commit: raises ValueError for CacheList (wrapping ArraysCache)
#   After fix: recursively merges sub-caches inside CacheList
###############################################################################
echo ""
echo "=== Test 2: F2P -- _merge_caches handles CacheList (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
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
# TEST 3 [F2P, 8pts]: ArraysCache.merge batches 3 caches correctly
###############################################################################
echo ""
echo "=== Test 3: Silver -- ArraysCache.merge correct batched output (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
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
# TEST 4 [F2P, 8pts]: ArraysCache.extract recovers individual caches
###############################################################################
echo ""
echo "=== Test 4: Silver -- ArraysCache.extract recovers individual caches (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
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
# TEST 5 [F2P, 8pts]: CacheList.merge + extract round-trip
###############################################################################
echo ""
echo "=== Test 5: Silver -- CacheList.merge + extract round-trip (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
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
# TEST 6 [F2P, 8pts]: MambaCache inherits merge/extract from ArraysCache
###############################################################################
echo ""
echo "=== Test 6: Silver -- MambaCache inherits merge/extract (8pts) ==="
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
# TEST 7 [F2P, 12pts]: _lengths / make_mask right-padding
#   Base commit: make_mask ignores _lengths, returns all-True mask
#   After fix: make_mask uses _lengths to create right-padding mask
#
#   Behavioral test: set lengths via prepare() with right_padding context,
#   then verify make_mask produces a mask that masks out right-padded positions.
#   Accepts any internal attribute naming (_lengths, lengths, etc.).
###############################################################################
echo ""
echo "=== Test 7: Silver -- _lengths support in make_mask for right-padding (12pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 12)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

# Create cache WITHOUT left_padding -- we test the _lengths / right-padding
# mask path, which is independent of left_padding mask generation.
ac = ArraysCache(size=1)

# Set lengths via prepare() with right_padding context, or direct attribute.
# Accept multiple valid API designs:
#   1. prepare(lengths=..., right_padding=...) -- most complete
#   2. prepare(lengths=...) alone
#   3. Direct attribute assignment as fallback
lengths_set = False
if hasattr(ac, 'prepare') and callable(ac.prepare):
    # Try with both lengths and right_padding first (most complete API)
    try:
        ac.prepare(lengths=[3, 4], right_padding=[2, 1])
        lengths_set = True
    except TypeError:
        # Fallback: try with just lengths
        try:
            ac.prepare(lengths=[3, 4])
            lengths_set = True
        except TypeError:
            pass

if not lengths_set:
    # Direct attribute assignment fallback (try both naming conventions)
    try:
        ac._lengths = mx.array([3, 4])
        lengths_set = True
    except Exception:
        try:
            ac.lengths = mx.array([3, 4])
            lengths_set = True
        except Exception:
            pass

if not lengths_set:
    print("FAIL: Cannot set lengths via prepare() or attribute")
    sys.exit(1)

# Accept either _lengths or lengths attribute name (both are valid designs)
has_lengths = (getattr(ac, '_lengths', None) is not None or
               getattr(ac, 'lengths', None) is not None)
if not has_lengths:
    print("FAIL: neither _lengths nor lengths is set after prepare()")
    sys.exit(1)

try:
    mask = ac.make_mask(5)
except Exception as e:
    print(f"FAIL: make_mask(5) raised: {e}")
    sys.exit(1)

if mask is None:
    print("FAIL: make_mask returned None despite lengths being set")
    sys.exit(1)

# Flatten to 2D for checking (mask may be 2D, 3D, or 4D depending on impl)
import numpy as _np
mask_np = _np.array(mask.tolist()) if hasattr(mask, 'tolist') else _np.array(mask)
while mask_np.ndim > 2:
    mask_np = mask_np.squeeze(axis=1)

if mask_np.shape[0] < 2 or mask_np.shape[1] < 5:
    print(f"FAIL: mask shape {mask_np.shape} too small, expected at least (2, 5)")
    sys.exit(1)

# Row 0 (length=3): position 2 should be True, position 3 should be False
if not bool(mask_np[0, 2]):
    print(f"FAIL: row 0 pos 2 should be True (within length 3)")
    sys.exit(1)
if bool(mask_np[0, 3]):
    print(f"FAIL: row 0 pos 3 should be False (right-padded, length=3)")
    sys.exit(1)

# Row 1 (length=4): position 3 should be True, position 4 should be False
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
# TEST 8 [F2P, 5pts]: prepare() and finalize() work correctly
###############################################################################
echo ""
echo "=== Test 8/11: Silver -- prepare() and finalize() functional (5pts) ==="
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
# TEST 9 [F2P/Bronze, 5pts]: ArraysCache merge+extract AST non-trivial
# Justification: AST supplements behavioral Tests 3-4. Rejects stubs that
# pass hasattr but have empty bodies.
###############################################################################
echo ""
echo "=== Test 9: AST -- ArraysCache merge+extract non-trivial (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
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
# TEST 10 [F2P/Bronze, 5pts]: CacheList merge+extract AST non-trivial
# Justification: AST supplements behavioral Test 5. Rejects stubs that
# pass hasattr but have empty bodies.
###############################################################################
echo ""
echo "=== Test 10: AST -- CacheList merge+extract non-trivial (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
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
        if extract_stmts < 1:
            print(f"FAIL: CacheList.extract has only {extract_stmts} meaningful stmts (need >=1)")
            sys.exit(1)

        print(f"PASS: CacheList.merge ({merge_stmts} stmts) + extract ({extract_stmts} stmts)")
        sys.exit(0)

if not found:
    print("FAIL: CacheList class not found in cache.py")
sys.exit(1)
PYEOF

###############################################################################
# TEST 11 [F2P, 8pts]: _merge_caches works with MambaCache
#   MambaCache inherits from ArraysCache. A correct _merge_caches that handles
#   isinstance(_, ArraysCache) should also work for MambaCache.
#   Also tests that ArraysCache.merge handles MambaCache subclass correctly
#   (e.g. __new__ or other approach that avoids MambaCache __init__ issues).
###############################################################################
echo ""
echo "=== Test 11: F2P -- _merge_caches handles MambaCache (8pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

if _merge_caches is None:
    print("FAIL: could not extract _merge_caches from generate.py")
    sys.exit(1)

# Create MambaCache instances (size=2 fixed)
try:
    mc1 = MambaCache()
except TypeError:
    mc1 = MambaCache(left_padding=None)

try:
    mc2 = MambaCache()
except TypeError:
    mc2 = MambaCache(left_padding=None)

mc1.cache[0] = mx.ones((1, 4, 3)) * 5.0
mc1.cache[1] = mx.ones((1, 4, 8)) * 6.0
mc2.cache[0] = mx.ones((1, 4, 3)) * 7.0
mc2.cache[1] = mx.ones((1, 4, 8)) * 8.0

try:
    merged = _merge_caches([[mc1], [mc2]])
except ValueError as e:
    if "does not yet support batching" in str(e):
        print("FAIL: _merge_caches still raises original ValueError for MambaCache")
    else:
        print(f"FAIL: ValueError: {e}")
    sys.exit(1)
except TypeError as e:
    print(f"FAIL: _merge_caches raised TypeError (MambaCache subclass compat issue): {e}")
    sys.exit(1)
except Exception as e:
    print(f"FAIL: _merge_caches raised {type(e).__name__}: {e}")
    sys.exit(1)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL: expected list of length 1")
    sys.exit(1)

m = merged[0]
if not hasattr(m, 'cache') or m.cache[0] is None:
    print("FAIL: merged MambaCache result has no valid cache data")
    sys.exit(1)

if m.cache[0].shape[0] != 2:
    print(f"FAIL: batch dim is {m.cache[0].shape[0]}, expected 2")
    sys.exit(1)

v0 = float(m.cache[0][0, 0, 0])
v1 = float(m.cache[0][1, 0, 0])
if abs(v0 - 5.0) > 0.01 or abs(v1 - 7.0) > 0.01:
    print(f"FAIL: values [{v0}, {v1}], expected [5.0, 7.0]")
    sys.exit(1)

print("PASS: _merge_caches handles MambaCache with correct batched result")
sys.exit(0)
PYEOF

###############################################################################
# TEST 12 [Silver, 5pts]: MambaCache type preservation through merge+extract
#   A quality implementation preserves MambaCache type through merge→extract.
#   Weaker implementations may downcast to ArraysCache.
###############################################################################
echo ""
echo "=== Test 12: Silver -- MambaCache type preservation in extract (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

try:
    mc1 = MambaCache()
except TypeError:
    mc1 = MambaCache(size=2)

try:
    mc2 = MambaCache()
except TypeError:
    mc2 = MambaCache(size=2)

mc1.cache[0] = mx.ones((1, 2, 2)) * 1.0
mc1.cache[1] = mx.ones((1, 2, 2)) * 2.0
mc2.cache[0] = mx.ones((1, 2, 2)) * 3.0
mc2.cache[1] = mx.ones((1, 2, 2)) * 4.0

try:
    merged = MambaCache.merge([mc1, mc2])
    extracted = merged.extract(0)
except Exception as e:
    print(f"FAIL: merge/extract raised: {e}")
    sys.exit(1)

if not isinstance(extracted, MambaCache):
    print(f"FAIL: extract returned {type(extracted).__name__}, expected MambaCache")
    sys.exit(1)

print("PASS: MambaCache type preserved through merge + extract")
sys.exit(0)
PYEOF

###############################################################################
# TEST 13 [Silver, 5pts]: CacheList prepare/finalize delegates to sub-caches
#   A correct CacheList.prepare should forward to all sub-caches.
###############################################################################
echo ""
echo "=== Test 13: Silver -- CacheList prepare/finalize delegation (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys

ac = ArraysCache(size=1)
cl = CacheList(ac)

if not hasattr(cl, 'prepare') or not callable(cl.prepare):
    print("FAIL: CacheList has no prepare method")
    sys.exit(1)

if not hasattr(cl, 'finalize') or not callable(cl.finalize):
    print("FAIL: CacheList has no finalize method")
    sys.exit(1)

try:
    cl.prepare(lengths=[3], right_padding=[2])
except Exception as e:
    print(f"FAIL: CacheList.prepare raised: {e}")
    sys.exit(1)

# Check sub-cache got the lengths (either _lengths or lengths attr)
sub = cl.caches[0]
has_lengths = (getattr(sub, '_lengths', None) is not None or
               getattr(sub, 'lengths', None) is not None)
if not has_lengths:
    print("FAIL: sub-cache has no lengths after CacheList.prepare")
    sys.exit(1)

try:
    cl.finalize()
except Exception as e:
    print(f"FAIL: CacheList.finalize raised: {e}")
    sys.exit(1)

print("PASS: CacheList delegates prepare/finalize to sub-caches")
sys.exit(0)
PYEOF

###############################################################################
# TEST 14 [Bronze, 5pts]: _merge_caches dispatches on ArraysCache (not hardcoded)
#   Verifies _merge_caches uses isinstance checks for ArraysCache (catches
#   MambaCache too via inheritance), not just string/class-name matching.
#   Checks the actual AST of _merge_caches for isinstance(_, ArraysCache).
###############################################################################
echo ""
echo "=== Test 14: AST -- _merge_caches handles ArraysCache isinstance check (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/generate.py", "r") as f:
    source = f.read()

tree = ast.parse(source)
found_func = False
has_arrays_cache_check = False

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_merge_caches":
        found_func = True
        src = ast.get_source_segment(source, node)
        if src is None:
            print("FAIL: could not extract _merge_caches source")
            sys.exit(1)
        # Check for ArraysCache or CacheList in isinstance calls
        for child in ast.walk(node):
            if isinstance(child, ast.Call):
                if isinstance(child.func, ast.Name) and child.func.id == "isinstance":
                    for arg in child.args:
                        if isinstance(arg, ast.Name) and arg.id in ("ArraysCache", "CacheList"):
                            has_arrays_cache_check = True
                        elif isinstance(arg, ast.Tuple):
                            for elt in arg.elts:
                                if isinstance(elt, ast.Name) and elt.id in ("ArraysCache", "CacheList"):
                                    has_arrays_cache_check = True

if not found_func:
    print("FAIL: _merge_caches function not found in generate.py")
    sys.exit(1)

if not has_arrays_cache_check:
    print("FAIL: _merge_caches doesn't check isinstance for ArraysCache or CacheList")
    sys.exit(1)

print("PASS: _merge_caches has proper isinstance checks for ArraysCache/CacheList")
sys.exit(0)
PYEOF

###############################################################################
# TEST 15 [Silver, 5pts]: _lengths propagates through merge+extract
#   Turn 5 ask: "add the _lengths feature to our PR". Beyond make_mask (Test 7),
#   _lengths must survive batched merge and be recoverable via extract so that
#   right-padded batched decoding produces correct masks per sample.
###############################################################################
echo ""
echo "=== Test 15: Silver -- _lengths survives merge+extract (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys
import numpy as _np

def _set_lengths(c, lens):
    # Try prepare() with full signature, then partial, then direct attr.
    if hasattr(c, 'prepare') and callable(c.prepare):
        try:
            c.prepare(lengths=lens, right_padding=[0]*len(lens))
            return True
        except TypeError:
            try:
                c.prepare(lengths=lens)
                return True
            except TypeError:
                pass
    try:
        c._lengths = mx.array(lens)
        return True
    except Exception:
        pass
    try:
        c.lengths = mx.array(lens)
        return True
    except Exception:
        return False

ac1 = ArraysCache(size=1)
ac1.cache[0] = mx.ones((1, 2, 4))
ac2 = ArraysCache(size=1)
ac2.cache[0] = mx.ones((1, 2, 4)) * 2.0

if not _set_lengths(ac1, [3]) or not _set_lengths(ac2, [4]):
    print("FAIL: cannot set _lengths on ArraysCache")
    sys.exit(1)

try:
    merged = ArraysCache.merge([ac1, ac2])
except Exception as e:
    print(f"FAIL: merge raised: {e}")
    sys.exit(1)

# Merged cache must still expose _lengths (or lengths) as an attribute so
# downstream make_mask can compute per-row right padding for the batch.
lens_attr = getattr(merged, '_lengths', None)
if lens_attr is None:
    lens_attr = getattr(merged, 'lengths', None)
if lens_attr is None:
    print("FAIL: merged ArraysCache lost _lengths/lengths attribute")
    sys.exit(1)

# Verify lengths was batched across samples (shape[0] == 2) with correct values
arr = _np.array(lens_attr.tolist()) if hasattr(lens_attr, 'tolist') else _np.array(lens_attr)
if arr.ndim == 0 or arr.shape[0] != 2:
    print(f"FAIL: merged lengths shape={arr.shape}, expected leading dim=2")
    sys.exit(1)
vals = sorted(int(x) for x in arr.reshape(-1)[:2])
if vals != [3, 4]:
    print(f"FAIL: merged lengths values={vals}, expected [3, 4]")
    sys.exit(1)

print("PASS: _lengths propagates through merge with correct batched values")
sys.exit(0)
PYEOF

###############################################################################
# TEST 16 [Bronze, 3pts]: Unit tests file written for batching feature
#   T1/Turn3 explicit ask: "write unit tests". instruction.md point 4 names
#   the target path tests/test_mamba_cache_batching.py. Verify the file exists
#   and contains non-trivial test code (at least 2 test functions / classes).
###############################################################################
echo ""
echo "=== Test 16: Bronze -- unit test file written for batching (3pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 3)) || true
import ast, os, sys

candidates = [
    "/workspace/mlx-lm/tests/test_mamba_cache_batching.py",
    "/workspace/mlx-lm/tests/test_cache_batching.py",
    "/workspace/mlx-lm/tests/test_arrays_cache_batching.py",
    "/workspace/mlx-lm/tests/test_batch_cache.py",
]
found = None
for p in candidates:
    if os.path.isfile(p):
        found = p
        break

if found is None:
    # Fallback: any test file under tests/ referencing ArraysCache/MambaCache merge/batch
    tests_dir = "/workspace/mlx-lm/tests"
    if os.path.isdir(tests_dir):
        for name in os.listdir(tests_dir):
            if not name.endswith(".py") or not name.startswith("test_"):
                continue
            try:
                with open(os.path.join(tests_dir, name)) as f:
                    src = f.read()
            except Exception:
                continue
            if (("ArraysCache" in src or "MambaCache" in src) and
                ("merge" in src or "batch" in src.lower())):
                found = os.path.join(tests_dir, name)
                break

if found is None:
    print("FAIL: no unit test file written for batching (expected tests/test_mamba_cache_batching.py or similar)")
    sys.exit(1)

try:
    with open(found) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL: {found} not parseable: {e}")
    sys.exit(1)

test_fns = [n for n in ast.walk(tree)
            if isinstance(n, ast.FunctionDef) and n.name.startswith("test_")]
if len(test_fns) < 2:
    print(f"FAIL: {found} has only {len(test_fns)} test_* functions (need >=2)")
    sys.exit(1)

print(f"PASS: {os.path.basename(found)} has {len(test_fns)} test functions")
sys.exit(0)
PYEOF

###############################################################################
# TEST 17 [Bronze, 3pts]: New ArraysCache methods have docstrings
#   Turn 3 ask: "with clear documentation". Performance testing and live-model
#   testing can't be verified on CPU/Linux, but docstrings on the public API
#   additions (merge, extract, prepare, finalize) are a concrete documentation
#   artifact. Require at least 2 of the 4 new methods to carry a docstring.
###############################################################################
echo ""
echo "=== Test 17: Bronze -- docstrings on new ArraysCache methods (3pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 3)) || true
import ast, sys

with open("/workspace/mlx-lm/mlx_lm/models/cache.py") as f:
    tree = ast.parse(f.read())

target_methods = {"merge", "extract", "prepare", "finalize"}
documented = []
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        for sub in node.body:
            if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and sub.name in target_methods:
                doc = ast.get_docstring(sub)
                if doc and len(doc.strip()) >= 10:
                    documented.append(sub.name)
        break

if len(documented) < 2:
    print(f"FAIL: only {len(documented)}/4 new ArraysCache methods have docstrings (documented: {documented})")
    sys.exit(1)

print(f"PASS: {len(documented)}/4 new ArraysCache methods documented: {documented}")
sys.exit(0)
PYEOF

###############################################################################
# TEST 18 [Silver, 4pts]: _lengths survives extract (per-sample recovery)
#   Turn 5 ask: "add the _lengths feature to our PR". Test 15 verifies merge
#   propagation; this test closes the gap on extract propagation — after a
#   batched merge, extracting sample i must recover ac_i's original length so
#   downstream right-padded per-sample decoding produces correct masks.
###############################################################################
echo ""
echo "=== Test 18: Silver -- _lengths survives extract (4pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 4)) || true
exec(open('/tmp/mlx_test_env.py').read())
import sys
import numpy as _np

def _set_lengths(c, lens):
    if hasattr(c, 'prepare') and callable(c.prepare):
        try:
            c.prepare(lengths=lens, right_padding=[0]*len(lens))
            return True
        except TypeError:
            try:
                c.prepare(lengths=lens)
                return True
            except TypeError:
                pass
    try:
        c._lengths = mx.array(lens)
        return True
    except Exception:
        pass
    try:
        c.lengths = mx.array(lens)
        return True
    except Exception:
        return False

def _get_lens(c):
    v = getattr(c, '_lengths', None)
    if v is None:
        v = getattr(c, 'lengths', None)
    if v is None:
        return None
    return _np.array(v.tolist()) if hasattr(v, 'tolist') else _np.array(v)

ac1 = ArraysCache(size=1)
ac1.cache[0] = mx.ones((1, 2, 4))
ac2 = ArraysCache(size=1)
ac2.cache[0] = mx.ones((1, 2, 4)) * 2.0

if not _set_lengths(ac1, [3]) or not _set_lengths(ac2, [5]):
    print("FAIL: cannot set lengths on ArraysCache")
    sys.exit(1)

try:
    merged = ArraysCache.merge([ac1, ac2])
    ex0 = merged.extract(0)
    ex1 = merged.extract(1)
except Exception as e:
    print(f"FAIL: merge/extract raised: {e}")
    sys.exit(1)

l0 = _get_lens(ex0)
l1 = _get_lens(ex1)
if l0 is None or l1 is None:
    print(f"FAIL: extracted caches lost _lengths (ex0={l0}, ex1={l1})")
    sys.exit(1)

# Each extracted cache's lengths should contain its original value (3 or 5).
# Accept scalar, (1,), or broadcasted shapes — just check the value.
v0 = int(_np.asarray(l0).reshape(-1)[0])
v1 = int(_np.asarray(l1).reshape(-1)[0])
if v0 != 3 or v1 != 5:
    print(f"FAIL: extracted lengths [{v0}, {v1}], expected [3, 5]")
    sys.exit(1)

print(f"PASS: extract recovers per-sample _lengths [{v0}, {v1}]")
sys.exit(0)
PYEOF

###############################################################################
# P2P: Existing mlx-lm Python modules parseable + core cache classes exist
#
# mlx is macOS-only (no Linux wheels) so upstream pytest is not CPU-safe.
# This P2P verifies:
#   (a) cache.py is valid Python (syntax check)
#   (b) generate.py is valid Python (syntax check)
#   (c) The base KVCache/BatchKVCache classes still exist (not deleted by agent)
# Weight: 2pts (reduced from 5 to keep nop <= 0.05)
###############################################################################
echo ""
echo "=== P2P [2pts]: Existing mlx-lm source files intact ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 2)) || true
import ast, sys, os

cache_py = "/workspace/mlx-lm/mlx_lm/models/cache.py"
generate_py = "/workspace/mlx-lm/mlx_lm/generate.py"

# (a) cache.py parseable
if not os.path.isfile(cache_py):
    print("FAIL: cache.py not found")
    sys.exit(1)
try:
    with open(cache_py) as f:
        tree = ast.parse(f.read())
except SyntaxError as e:
    print(f"FAIL: cache.py syntax error: {e}")
    sys.exit(1)

# (b) generate.py parseable
if not os.path.isfile(generate_py):
    print("FAIL: generate.py not found")
    sys.exit(1)
try:
    with open(generate_py) as f:
        ast.parse(f.read())
except SyntaxError as e:
    print(f"FAIL: generate.py syntax error: {e}")
    sys.exit(1)

# (c) Core cache classes still exist
class_names = {n.name for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
required = {"KVCache", "BatchKVCache", "ArraysCache", "MambaCache", "CacheList"}
missing = required - class_names
if missing:
    print(f"FAIL: missing core classes from cache.py: {missing}")
    sys.exit(1)

print(f"PASS: cache.py + generate.py valid, all {len(required)} core classes present")
PYEOF

###############################################################################
# P2P [5pts]: Upstream tool_parsers tests (CPU-safe, no mlx needed)
#
# mlx_lm.tool_parsers.* are pure-Python modules (json/regex only).
# This runs the upstream test_tool_parsing.py logic inline, bypassing the
# mlx_lm.__init__ import chain (which pulls in mlx.core / transformers).
# Ensures the agent hasn't broken unrelated package modules.
###############################################################################
echo ""
echo "=== P2P [2pts]: Upstream tool_parsers tests ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 2)) || true
import sys, os, importlib, types

# Ensure mlx_lm package root is importable
sys.path.insert(0, "/workspace/mlx-lm")

# Load individual parser modules directly, bypassing mlx_lm.__init__
# (which would trigger import mlx.core and fail on Linux)
parser_dir = "/workspace/mlx-lm/mlx_lm/tool_parsers"
if not os.path.isdir(parser_dir):
    print("FAIL: mlx_lm/tool_parsers directory not found")
    sys.exit(1)

# Each parser expects a specific input format (positional match from upstream test)
parser_specs = [
    ("function_gemma", "call:multiply{a:12234585,b:48838483920}"),
    ("glm47",          "multiply<arg_key>a</arg_key><arg_value>12234585</arg_value><arg_key>b</arg_key><arg_value>48838483920</arg_value>"),
    ("json_tools",     '{"name": "multiply", "arguments": {"a": 12234585, "b": 48838483920}}'),
    ("minimax_m2",     '<invoke name="multiply">\n<parameter name="a">12234585</parameter>\n<parameter name="b">48838483920</parameter>\n</invoke>'),
    ("qwen3_coder",    "<function=multiply>\n<parameter=a>\n12234585\n</parameter>\n<parameter=b>\n48838483920\n</parameter>\n</function>"),
]

tools_multiply = [
    {
        "type": "function",
        "function": {
            "name": "multiply",
            "description": "Multiply two numbers.",
            "parameters": {
                "type": "object",
                "required": ["a", "b"],
                "properties": {
                    "a": {"type": "number", "description": "a is a number"},
                    "b": {"type": "number", "description": "b is a number"},
                },
            },
        },
    }
]
expected_multiply = {"name": "multiply", "arguments": {"a": 12234585, "b": 48838483920}}

passed = 0
skipped = 0
for name, test_input in parser_specs:
    mod_path = os.path.join(parser_dir, f"{name}.py")
    if not os.path.isfile(mod_path):
        print(f"FAIL: parser module {name}.py not found")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location(name, mod_path)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except ImportError as e:
        # regex package may not be installed; skip that parser
        print(f"WARN: skipping {name} (import error: {e})")
        skipped += 1
        continue

    try:
        result = mod.parse_tool_call(test_input, tools_multiply)
        if result != expected_multiply:
            print(f"FAIL: {name} returned {result}, expected {expected_multiply}")
            sys.exit(1)
        passed += 1
    except Exception as e:
        print(f"FAIL: {name}.parse_tool_call raised {type(e).__name__}: {e}")
        sys.exit(1)

if passed < 2:
    print(f"FAIL: only {passed}/5 parser tests passed ({skipped} skipped)")
    sys.exit(1)

print(f"PASS: {passed}/5 upstream tool_parsers tests passed ({skipped} skipped)")
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
