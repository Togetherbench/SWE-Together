#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
MAX=100

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"
TEST_FILE="/workspace/mlx-lm/tests/test_mamba_cache_batching.py"

if [ ! -f "$CACHE_PY" ] || [ ! -f "$GENERATE_PY" ]; then
    echo "FAIL: required source files missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

###############################################################################
# Build a numpy-backed mlx shim and load cache.py + extract _merge_caches.
###############################################################################
cat > /tmp/mlx_test_env.py << 'ENVEOF'
import sys, types, ast
import numpy as np

if 'mlx.core' not in sys.modules:
    _mx = types.ModuleType('mlx.core')
    _mx.array = lambda x, dtype=None, **kw: (np.array(x) if dtype is None else np.array(x, dtype=dtype))
    _mx.zeros = lambda shape, dtype=np.float32: np.zeros(shape, dtype=dtype)
    _mx.ones = lambda shape, dtype=np.float32: np.ones(shape, dtype=dtype)
    _mx.concatenate = lambda arrays, axis=0: np.concatenate(arrays, axis=axis)
    _mx.stack = lambda arrays, axis=0: np.stack(arrays, axis=axis)
    _mx.arange = lambda *a, **kw: np.arange(*a, **kw)
    _mx.expand_dims = lambda a, axis=None, axes=None: (np.expand_dims(a, axis) if axes is None else (lambda r: r)(_expand_axes(a, axes)))
    def _expand_axes(a, axes):
        for ax in sorted(axes):
            a = np.expand_dims(a, ax)
        return a
    _mx.expand_dims = lambda a, axis=None, axes=None: (np.expand_dims(a, axis=axis) if axes is None else _expand_axes(a, axes))
    _mx.pad = lambda a, widths, **kw: np.pad(a, widths)
    _mx.roll = lambda a, shift, axis=None, **kw: np.roll(a, shift, axis=axis)
    _mx.take_along_axis = lambda a, idx, axis: np.take_along_axis(a, idx, axis=axis)
    _mx.where = lambda cond, x, y: np.where(cond, x, y)
    _mx.full = lambda shape, val, dtype=None: np.full(shape, val, dtype=dtype)
    _mx.contiguous = lambda x: np.ascontiguousarray(x)
    _mx.maximum = lambda a, b: np.maximum(a, b)
    _mx.minimum = lambda a, b: np.minimum(a, b)
    _mx.clip = lambda a, lo, hi: np.clip(a, lo, hi)
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

    _nn = types.ModuleType('mlx.nn')
    class _Mod: pass
    _nn.Module = _Mod
    _nn.Linear = type('Linear', (_Mod,), {})
    _nn.Embedding = type('Embedding', (_Mod,), {})
    _nn.QuantizedLinear = type('QuantizedLinear', (_Mod,), {})
    _nn.QuantizedEmbedding = type('QuantizedEmbedding', (_Mod,), {})
    _nn.quantize = lambda *a, **kw: None

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

    _mlx = types.ModuleType('mlx')
    _mlx.core = _mx; _mlx.nn = _nn; _mlx.utils = _utils
    sys.modules['mlx'] = _mlx
    sys.modules['mlx.core'] = _mx
    sys.modules['mlx.nn'] = _nn
    sys.modules['mlx.utils'] = _utils

with open("/workspace/mlx-lm/mlx_lm/models/cache.py") as _f:
    _cache_src = _f.read()
_cache_src = _cache_src.replace(
    "from .base import create_causal_mask",
    "def create_causal_mask(*_a, **_kw): return None"
)
_cache_ns = {'__builtins__': __builtins__}
exec(compile(_cache_src, 'cache.py', 'exec'), _cache_ns)

ArraysCache = _cache_ns.get('ArraysCache')
MambaCache = _cache_ns.get('MambaCache')
CacheList = _cache_ns.get('CacheList')
KVCache = _cache_ns.get('KVCache')
BatchKVCache = _cache_ns.get('BatchKVCache')
RotatingKVCache = _cache_ns.get('RotatingKVCache')
BatchRotatingKVCache = _cache_ns.get('BatchRotatingKVCache')

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

run_py() {
    python3 -c "$1" 2>&1
}

###############################################################################
# P2P-1 [10pts]: Source files still parse + key classes still present.
###############################################################################
echo "=== P2P-1: cache.py & generate.py parse + base classes preserved (10pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
ok = True
for name in ['ArraysCache', 'MambaCache', 'CacheList', 'KVCache', 'BatchKVCache', 'RotatingKVCache']:
    if _cache_ns.get(name) is None:
        print(f"MISSING: {name}")
        ok = False
# Verify MambaCache subclasses ArraysCache
try:
    if not issubclass(MambaCache, ArraysCache):
        print("FAIL: MambaCache must subclass ArraysCache")
        ok = False
except Exception as e:
    print(f"FAIL: subclass check {e}")
    ok = False
if _merge_caches is None:
    print("FAIL: _merge_caches not extractable")
    ok = False
print("OK" if ok else "FAIL")
PYEOF
)
echo "$out" | tail -5
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 10))
    echo "P2P-1: PASS (+10)"
fi

###############################################################################
# F2P-1 [15pts]: _merge_caches no longer raises for ArraysCache.
###############################################################################
echo "=== F2P-1: _merge_caches handles ArraysCache (15pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys
if _merge_caches is None:
    print("FAIL: no _merge_caches")
    sys.exit(0)

ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3))
ac1.cache[1] = mx.ones((1, 4, 8)) * 2.0

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 3.0
ac2.cache[1] = mx.ones((1, 4, 8)) * 4.0

try:
    merged = _merge_caches([[ac1], [ac2]])
except ValueError as e:
    if "does not yet support batching" in str(e):
        print(f"FAIL: still raises original error: {e}")
    else:
        print(f"FAIL: unexpected ValueError: {e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL: unexpected exception {type(e).__name__}: {e}")
    sys.exit(0)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL: expected list of length 1, got {merged!r}")
    sys.exit(0)
m = merged[0]
if m.cache[0].shape[0] != 2:
    print(f"FAIL: batch dim should be 2, got {m.cache[0].shape}")
    sys.exit(0)
# Verify values preserved
import numpy as np
if not (np.allclose(m.cache[0][0], 1.0) and np.allclose(m.cache[0][1], 3.0)):
    print(f"FAIL: values not preserved correctly")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 15))
    echo "F2P-1: PASS (+15)"
fi

###############################################################################
# F2P-2 [10pts]: ArraysCache.merge classmethod exists and works directly.
###############################################################################
echo "=== F2P-2: ArraysCache.merge classmethod (10pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
if not hasattr(ArraysCache, 'merge'):
    print("FAIL: ArraysCache.merge missing")
    sys.exit(0)
c1 = ArraysCache(size=2); c1.cache[0] = mx.ones((1,3,4)); c1.cache[1] = mx.ones((1,3,4))*2
c2 = ArraysCache(size=2); c2.cache[0] = mx.ones((1,3,4))*3; c2.cache[1] = mx.ones((1,3,4))*4
c3 = ArraysCache(size=2); c3.cache[0] = mx.ones((1,3,4))*5; c3.cache[1] = mx.ones((1,3,4))*6
try:
    merged = ArraysCache.merge([c1, c2, c3])
except Exception as e:
    print(f"FAIL: merge raised: {e}")
    sys.exit(0)
if merged.cache[0].shape[0] != 3:
    print(f"FAIL: expected batch=3, got {merged.cache[0].shape}")
    sys.exit(0)
if not (np.allclose(merged.cache[0][0],1) and np.allclose(merged.cache[0][1],3) and np.allclose(merged.cache[0][2],5)):
    print("FAIL: values mismatched")
    sys.exit(0)
if not (np.allclose(merged.cache[1][1],4) and np.allclose(merged.cache[1][2],6)):
    print("FAIL: second slot values mismatched")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 10))
    echo "F2P-2: PASS (+10)"
fi

###############################################################################
# F2P-3 [10pts]: ArraysCache.extract returns single-batch slice.
###############################################################################
echo "=== F2P-3: ArraysCache.extract (10pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
if not hasattr(ArraysCache, 'extract'):
    print("FAIL: ArraysCache.extract missing")
    sys.exit(0)
c = ArraysCache(size=2)
c.cache[0] = mx.array(np.stack([np.ones((3,4))*i for i in range(4)]))  # (4,3,4)
c.cache[1] = mx.array(np.stack([np.ones((3,4))*(i+10) for i in range(4)]))
try:
    e2 = c.extract(2)
except Exception as e:
    print(f"FAIL: extract raised: {e}")
    sys.exit(0)
if e2.cache[0].shape[0] != 1:
    print(f"FAIL: extract batch dim {e2.cache[0].shape}")
    sys.exit(0)
if not np.allclose(e2.cache[0][0], 2.0):
    print(f"FAIL: extract value: {e2.cache[0][0]}")
    sys.exit(0)
if not np.allclose(e2.cache[1][0], 12.0):
    print(f"FAIL: extract second slot: {e2.cache[1][0]}")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 10))
    echo "F2P-3: PASS (+10)"
fi

###############################################################################
# F2P-4 [10pts]: ArraysCache.prepare and finalize methods exist + accept kwargs.
###############################################################################
echo "=== F2P-4: ArraysCache.prepare/finalize (10pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys, inspect
ok = True
for name in ['prepare', 'finalize']:
    if not hasattr(ArraysCache, name):
        print(f"FAIL: ArraysCache.{name} missing")
        ok = False
if not ok:
    sys.exit(0)
# prepare must accept left_padding, lengths, right_padding kwargs
sig = inspect.signature(ArraysCache.prepare)
params = sig.parameters
needed = ['left_padding', 'lengths', 'right_padding']
missing = [p for p in needed if p not in params]
if missing:
    print(f"FAIL: prepare missing kwargs: {missing}")
    sys.exit(0)
# Call prepare and finalize without crashing.
c = ArraysCache(size=2)
c.cache[0] = mx.ones((3, 5, 4))
c.cache[1] = mx.ones((3, 5, 4))
try:
    c.prepare(left_padding=[0,1,2], lengths=[5,4,3], right_padding=[0,0,0])
    c.finalize()
except Exception as e:
    print(f"FAIL: prepare/finalize raised: {e}")
    sys.exit(0)
# After finalize, lengths state should be cleared
length_attr = None
for attr in ('_lengths', 'lengths'):
    if hasattr(c, attr):
        length_attr = attr
        break
if length_attr is None:
    print("FAIL: no _lengths/lengths attribute")
    sys.exit(0)
val = getattr(c, length_attr)
if val is not None:
    print(f"FAIL: {length_attr} should be None after finalize, got {val}")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 10))
    echo "F2P-4: PASS (+10)"
fi

###############################################################################
# F2P-5 [10pts]: prepare with right_padding sets lengths attribute (used by make_mask).
###############################################################################
echo "=== F2P-5: ArraysCache prepare records lengths (10pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys
c = ArraysCache(size=2)
c.cache[0] = mx.ones((3, 5, 4))
try:
    c.prepare(left_padding=None, lengths=[5,4,3], right_padding=[0,1,2])
except Exception as e:
    print(f"FAIL: prepare raised: {e}")
    sys.exit(0)
length_attr = None
for attr in ('_lengths', 'lengths'):
    if hasattr(c, attr) and getattr(c, attr) is not None:
        length_attr = attr
        break
if length_attr is None:
    print("FAIL: prepare with right_padding>0 did not set lengths")
    sys.exit(0)
import numpy as np
val = np.asarray(getattr(c, length_attr))
if val.tolist() != [5,4,3]:
    print(f"FAIL: lengths={val.tolist()} expected [5,4,3]")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 10))
    echo "F2P-5: PASS (+10)"
fi

###############################################################################
# F2P-6 [15pts]: CacheList.merge handles mixed sub-caches.
###############################################################################
echo "=== F2P-6: CacheList.merge with mixed sub-caches (15pts) ==="
out=$(python3 << 'PYEOF'
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

if not hasattr(CacheList, 'merge'):
    print("FAIL: CacheList.merge missing")
    sys.exit(0)

def make_one(val):
    m = ArraysCache(size=2)
    m.cache[0] = mx.ones((1, 3, 4)) * val
    m.cache[1] = mx.ones((1, 3, 4)) * (val + 0.5)
    kv = KVCache()
    # populate with small step
    keys = mx.ones((1, 2, 4, 6)) * val
    vals = mx.ones((1, 2, 4, 6)) * (val + 0.1)
    kv.update_and_fetch(keys, vals)
    return CacheList(m, kv)

cl1 = make_one(1.0)
cl2 = make_one(2.0)

try:
    merged = CacheList.merge([cl1, cl2])
except Exception as e:
    print(f"FAIL: CacheList.merge raised: {e}")
    sys.exit(0)

if not isinstance(merged, CacheList):
    print(f"FAIL: merge returned {type(merged)}")
    sys.exit(0)

sub0 = merged.caches[0]
sub1 = merged.caches[1]
if not isinstance(sub0, ArraysCache):
    print(f"FAIL: sub0 should be ArraysCache, got {type(sub0)}")
    sys.exit(0)
if sub0.cache[0].shape[0] != 2:
    print(f"FAIL: ArraysCache batch dim {sub0.cache[0].shape}")
    sys.exit(0)
if not (np.allclose(sub0.cache[0][0], 1.0) and np.allclose(sub0.cache[0][1], 2.0)):
    print("FAIL: ArraysCache values mismatched after merge")
    sys.exit(0)
# Sub1 must be batched KV-style cache (BatchKVCache or KVCache batch=2)
keys = getattr(sub1, 'keys', None)
if keys is None:
    print("FAIL: sub1 has no keys")
    sys.exit(0)
if keys.shape[0] != 2:
    print(f"FAIL: KV batch dim {keys.shape}")
    sys.exit(0)
print("OK")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^OK$"; then
    SCORE=$((SCORE + 15))
    echo "F2P-6: PASS (+15)"
fi

###############################################################################
# F2P-7 [10pts]: CacheList.extract returns a CacheList of single-batch sub-caches.
###############################################################################
echo "=== F2P-7: CacheList.extract (10pts) ==="
out