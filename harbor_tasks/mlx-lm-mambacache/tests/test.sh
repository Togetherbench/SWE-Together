#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"

if [ ! -f "$CACHE_PY" ] || [ ! -f "$GENERATE_PY" ]; then
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# Build mlx shim + load cache.py and extract _merge_caches
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
    _utils.tree_flatten = lambda tree, **kw: []
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
try:
    exec(compile(_cache_src, 'cache.py', 'exec'), _cache_ns)
except Exception as _e:
    print(f"FAIL_LOAD: {_e}")
    raise

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

# ---------- P2P gating: parse + classes still present ----------
echo "=== P2P gate: cache.py loads, base classes present ==="
gate_out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
ok = True
for name in ['ArraysCache','MambaCache','CacheList','KVCache','BatchKVCache','RotatingKVCache']:
    if _cache_ns.get(name) is None:
        print(f"MISSING:{name}")
        ok = False
try:
    if not issubclass(MambaCache, ArraysCache):
        print("FAIL:MambaCache_subclass")
        ok = False
except Exception as e:
    print(f"FAIL:subclass:{e}")
    ok = False
if _merge_caches is None:
    print("FAIL:_merge_caches")
    ok = False
print("GATE_OK" if ok else "GATE_FAIL")
PYEOF
)
echo "$gate_out" | tail -5
if ! echo "$gate_out" | grep -q "^GATE_OK$"; then
    echo "P2P gate failed (regression). Reward=0."
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ---------- F2P-1 [0.20]: _merge_caches handles ArraysCache batch ----------
echo "=== F2P-1: _merge_caches handles ArraysCache (0.20) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys
if _merge_caches is None:
    print("FAIL")
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
        print(f"FAIL:still_raises")
        sys.exit(0)
    print(f"FAIL:valueerr:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:exc:{e}")
    sys.exit(0)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL:shape:{type(merged)}")
    sys.exit(0)

m0 = merged[0]
# Should be an ArraysCache or subclass
if not isinstance(m0, ArraysCache):
    print(f"FAIL:not_arrayscache:{type(m0)}")
    sys.exit(0)

# Batch dim should now be 2
try:
    s0 = m0.cache[0].shape
    s1 = m0.cache[1].shape
except Exception as e:
    print(f"FAIL:no_cache_attr:{e}")
    sys.exit(0)

if s0[0] != 2 or s1[0] != 2:
    print(f"FAIL:bad_batch_dim:{s0},{s1}")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.20}")
    echo "F2P-1: PASS (+0.20)"
fi

# ---------- F2P-2 [0.15]: ArraysCache.merge classmethod exists & works ----------
echo "=== F2P-2: ArraysCache.merge classmethod (0.15) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys
m = getattr(ArraysCache, 'merge', None)
if m is None or not callable(m):
    print("FAIL:no_merge")
    sys.exit(0)

c1 = ArraysCache(size=2)
c1.cache[0] = mx.ones((1, 3, 4))
c1.cache[1] = mx.ones((1, 3, 4)) * 2.0
c2 = ArraysCache(size=2)
c2.cache[0] = mx.ones((1, 3, 4)) * 3.0
c2.cache[1] = mx.ones((1, 3, 4)) * 4.0
c3 = ArraysCache(size=2)
c3.cache[0] = mx.ones((1, 3, 4)) * 5.0
c3.cache[1] = mx.ones((1, 3, 4)) * 6.0

try:
    merged = ArraysCache.merge([c1, c2, c3])
except Exception as e:
    print(f"FAIL:exc:{e}")
    sys.exit(0)

if not isinstance(merged, ArraysCache):
    print(f"FAIL:type:{type(merged)}")
    sys.exit(0)

if merged.cache[0].shape[0] != 3 or merged.cache[1].shape[0] != 3:
    print(f"FAIL:bad_batch:{merged.cache[0].shape},{merged.cache[1].shape}")
    sys.exit(0)

# Spot-check values: index 0 should be all 1s, index 2 all 5s in cache[0]
import numpy as np
if not np.allclose(np.asarray(merged.cache[0][0]), 1.0):
    print("FAIL:val0")
    sys.exit(0)
if not np.allclose(np.asarray(merged.cache[0][2]), 5.0):
    print("FAIL:val2")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.15}")
    echo "F2P-2: PASS (+0.15)"
fi

# ---------- F2P-3 [0.15]: ArraysCache.extract round-trip ----------
echo "=== F2P-3: ArraysCache.extract method (0.15) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
ex = getattr(ArraysCache, 'extract', None)
if ex is None or not callable(ex):
    print("FAIL:no_extract")
    sys.exit(0)

c1 = ArraysCache(size=2)
c1.cache[0] = mx.ones((1, 3, 4))
c1.cache[1] = mx.ones((1, 3, 4)) * 2.0
c2 = ArraysCache(size=2)
c2.cache[0] = mx.ones((1, 3, 4)) * 7.0
c2.cache[1] = mx.ones((1, 3, 4)) * 8.0

try:
    merged = ArraysCache.merge([c1, c2])
except Exception as e:
    print(f"FAIL:merge:{e}")
    sys.exit(0)

try:
    ex0 = merged.extract(0)
    ex1 = merged.extract(1)
except Exception as e:
    print(f"FAIL:extract:{e}")
    sys.exit(0)

if not isinstance(ex0, ArraysCache) or not isinstance(ex1, ArraysCache):
    print(f"FAIL:type:{type(ex0)},{type(ex1)}")
    sys.exit(0)

if ex0.cache[0].shape[0] != 1 or ex1.cache[0].shape[0] != 1:
    print(f"FAIL:bad_shape:{ex0.cache[0].shape},{ex1.cache[0].shape}")
    sys.exit(0)

if not np.allclose(np.asarray(ex0.cache[0]), 1.0):
    print(f"FAIL:val0:{np.asarray(ex0.cache[0]).mean()}")
    sys.exit(0)
if not np.allclose(np.asarray(ex1.cache[0]), 7.0):
    print(f"FAIL:val1:{np.asarray(ex1.cache[0]).mean()}")
    sys.exit(0)
if not np.allclose(np.asarray(ex1.cache[1]), 8.0):
    print(f"FAIL:val1b")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.15}")
    echo "F2P-3: PASS (+0.15)"
fi

# ---------- F2P-4 [0.10]: ArraysCache.prepare + finalize methods ----------
echo "=== F2P-4: ArraysCache.prepare/finalize (0.10) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys
prep = getattr(ArraysCache, 'prepare', None)
fin = getattr(ArraysCache, 'finalize', None)
if prep is None or fin is None or not callable(prep) or not callable(fin):
    print("FAIL:missing")
    sys.exit(0)

c = ArraysCache(size=2)
# Try calling prepare with the documented kwargs
try:
    c.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except TypeError as e:
    print(f"FAIL:signature:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:prepare_exc:{e}")
    sys.exit(0)

try:
    c.finalize()
except Exception as e:
    print(f"FAIL:finalize:{e}")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.10}")
    echo "F2P-4: PASS (+0.10)"
fi

# ---------- F2P-5 [0.10]: ArraysCache _lengths attribute used in make_mask ----------
echo "=== F2P-5: ArraysCache lengths-aware mask (0.10) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

c = ArraysCache(size=2)
# Configure right-padding lengths via prepare
try:
    c.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except Exception as e:
    print(f"FAIL:prepare:{e}")
    sys.exit(0)

# Either _lengths or lengths attribute should now reflect lengths
has_attr = False
val = None
for name in ('_lengths', 'lengths'):
    if hasattr(c, name):
        v = getattr(c, name)
        if v is not None:
            has_attr = True
            val = v
            break
if not has_attr:
    print("FAIL:no_lengths_attr_set")
    sys.exit(0)

try:
    arr = np.asarray(val)
except Exception:
    print(f"FAIL:not_array:{type(val)}")
    sys.exit(0)

if arr.shape[0] != 2 or int(arr[0]) != 3 or int(arr[1]) != 5:
    print(f"FAIL:vals:{arr.tolist()}")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.10}")
    echo "F2P-5: PASS (+0.10)"
fi

# ---------- F2P-6 [0.15]: CacheList.merge classmethod ----------
echo "=== F2P-6: CacheList.merge classmethod (0.15) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys
m = getattr(CacheList, 'merge', None)
if m is None or not callable(m):
    print("FAIL:no_merge")
    sys.exit(0)

def make_cl():
    ac = ArraysCache(size=2)
    ac.cache[0] = mx.ones((1, 4, 3))
    ac.cache[1] = mx.ones((1, 4, 3)) * 2.0
    kv = KVCache()
    # Update KVCache with some keys/values so it's batched-capable
    keys = mx.ones((1, 2, 4, 8))
    vals = mx.ones((1, 2, 4, 8)) * 3.0
    try:
        kv.update_and_fetch(keys, vals)
    except Exception:
        pass
    return CacheList(ac, kv)

cl1 = make_cl()
cl2 = make_cl()

try:
    merged = CacheList.merge([cl1, cl2])
except Exception as e:
    print(f"FAIL:exc:{e}")
    sys.exit(0)

if not isinstance(merged, CacheList):
    print(f"FAIL:type:{type(merged)}")
    sys.exit(0)

# First sub-cache should be an ArraysCache (or subclass) with batch=2
sub0 = merged.caches[0] if hasattr(merged, 'caches') else merged[0]
if not isinstance(sub0, ArraysCache):
    print(f"FAIL:sub0_type:{type(sub0)}")
    sys.exit(0)
if sub0.cache[0].shape[0] != 2:
    print(f"FAIL:sub0_batch:{sub0.cache[0].shape}")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.15}")
    echo "F2P-6: PASS (+0.15)"
fi

# ---------- F2P-7 [0.10]: CacheList.extract method ----------
echo "=== F2P-7: CacheList.extract method (0.10) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
ex = getattr(CacheList, 'extract', None)
if ex is None or not callable(ex):
    print("FAIL:no_extract")
    sys.exit(0)

ac1 = ArraysCache(size=1); ac1.cache[0] = mx.ones((1, 2, 3))
ac2 = ArraysCache(size=1); ac2.cache[0] = mx.ones((1, 2, 3)) * 9.0
cl1 = CacheList(ac1)
cl2 = CacheList(ac2)

try:
    merged = CacheList.merge([cl1, cl2])
    ex0 = merged.extract(0)
    ex1 = merged.extract(1)
except Exception as e:
    print(f"FAIL:exc:{e}")
    sys.exit(0)

if not isinstance(ex0, CacheList) or not isinstance(ex1, CacheList):
    print(f"FAIL:type:{type(ex0)},{type(ex1)}")
    sys.exit(0)

sub0 = ex0.caches[0] if hasattr(ex0, 'caches') else ex0[0]
sub1 = ex1.caches[0] if hasattr(ex1, 'caches') else ex1[0]
if sub0.cache[0].shape[0] != 1 or sub1.cache[0].shape[0] != 1:
    print(f"FAIL:batch:{sub0.cache[0].shape},{sub1.cache[0].shape}")
    sys.exit(0)
if not np.allclose(np.asarray(sub0.cache[0]), 1.0):
    print("FAIL:v0")
    sys.exit(0)
if not np.allclose(np.asarray(sub1.cache[0]), 9.0):
    print("FAIL:v1")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.10}")
    echo "F2P-7: PASS (+0.10)"
fi

# ---------- F2P-8 [0.05]: _merge_caches handles CacheList ----------
echo "=== F2P-8: _merge_caches dispatches to CacheList (0.05) ==="
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys
if _merge_caches is None:
    print("FAIL")
    sys.exit(0)

def make_cl(scale):
    ac = ArraysCache(size=1)
    ac.cache[0] = mx.ones((1, 2, 3)) * scale
    return CacheList(ac)

try:
    merged = _merge_caches([[make_cl(1.0)], [make_cl(2.0)]])
except ValueError as e:
    if "does not yet support batching" in str(e):
        print("FAIL:still_raises")
        sys.exit(0)
    print(f"FAIL:ve:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:exc:{e}")
    sys.exit(0)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL:shape")
    sys.exit(0)
if not isinstance(merged[0], CacheList):
    print(f"FAIL:type:{type(merged[0])}")
    sys.exit(0)
sub = merged[0].caches[0] if hasattr(merged[0], 'caches') else merged[0][0]
if sub.cache[0].shape[0] != 2:
    print(f"FAIL:batch:{sub.cache[0].shape}")
    sys.exit(0)
print("PASS")
PYEOF
)
echo "$out" | tail -3
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(awk "BEGIN{print $REWARD + 0.05}")
    echo "F2P-8: PASS (+0.05)"
fi

# Clamp to [0,1]
REWARD=$(awk "BEGIN{r=$REWARD; if(r<0)r=0; if(r>1)r=1; printf \"%.4f\", r}")
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > "$REWARD_FILE"