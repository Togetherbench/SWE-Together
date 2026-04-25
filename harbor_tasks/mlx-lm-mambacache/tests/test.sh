#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"

if [ ! -f "$CACHE_PY" ] || [ ! -f "$GENERATE_PY" ]; then
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ---------- Build mlx shim env ----------
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
            'MambaCache': MambaCache,
        }
        exec(compile(_func_src, 'generate.py', 'exec'), _merge_ns)
        _merge_caches = _merge_ns.get('_merge_caches')
except Exception as _e:
    print(f"WARNING: could not load _merge_caches: {_e}")

import mlx.core as mx
ENVEOF

run_py() {
    python3 -c "exec(open('/tmp/mlx_test_env.py').read()); $1" 2>&1
}

# ---------- P2P gate: cache.py loads, base classes present, _merge_caches importable ----------
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
if ! echo "$gate_out" | grep -q "^GATE_OK$"; then
    echo "P2P gate failed."
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# Helper for awk float add
add() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.4f", a+b}'; }

# =========================================================================
# F2P-1 [0.15] — _merge_caches no longer raises on ArraysCache, returns
#   ArraysCache instance with batched leading dimension (concat along axis 0).
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
if _merge_caches is None:
    print("FAIL:no_merge"); sys.exit(0)

ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3))
ac1.cache[1] = mx.ones((1, 4, 8)) * 2.0

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 3.0
ac2.cache[1] = mx.ones((1, 4, 8)) * 4.0

try:
    merged = _merge_caches([[ac1], [ac2]])
except Exception as e:
    print(f"FAIL:exc:{e}"); sys.exit(0)

if not isinstance(merged, list) or len(merged) != 1:
    print(f"FAIL:shape"); sys.exit(0)

m0 = merged[0]
if not isinstance(m0, ArraysCache):
    print(f"FAIL:not_arrayscache:{type(m0).__name__}"); sys.exit(0)

c0 = np.asarray(m0.cache[0])
c1 = np.asarray(m0.cache[1])
if c0.shape != (2,4,3) or c1.shape != (2,4,8):
    print(f"FAIL:bad_shape:{c0.shape}|{c1.shape}"); sys.exit(0)

# Verify values: batch 0 should be 1.0/2.0, batch 1 should be 3.0/4.0
if not (np.allclose(c0[0], 1.0) and np.allclose(c0[1], 3.0)):
    print(f"FAIL:bad_vals_c0"); sys.exit(0)
if not (np.allclose(c1[0], 2.0) and np.allclose(c1[1], 4.0)):
    print(f"FAIL:bad_vals_c1"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.15)
    echo "F2P-1 PASS (+0.15)"
else
    echo "F2P-1 FAIL: $out"
fi

# =========================================================================
# F2P-2 [0.15] — _merge_caches handles CacheList wrapping mixed cache types
#   (KVCache + MambaCache), the canonical hybrid model layout.
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
if _merge_caches is None:
    print("FAIL:no_merge"); sys.exit(0)

def make_layer(seed):
    np.random.seed(seed)
    # MambaCache (subclass of ArraysCache)
    mc = MambaCache()
    mc.cache[0] = mx.array(np.random.randn(1, 3, 4).astype(np.float32))
    mc.cache[1] = mx.array(np.random.randn(1, 2, 5).astype(np.float32))
    # KVCache
    kv = KVCache()
    kv.update_and_fetch(
        mx.array(np.random.randn(1, 2, 4, 6).astype(np.float32)),
        mx.array(np.random.randn(1, 2, 4, 6).astype(np.float32)),
    )
    return CacheList(mc, kv)

c1 = [make_layer(1)]
c2 = [make_layer(2)]

try:
    merged = _merge_caches([c1, c2])
except Exception as e:
    print(f"FAIL:exc:{e}"); sys.exit(0)

if len(merged) != 1:
    print(f"FAIL:len"); sys.exit(0)

ml = merged[0]
if not isinstance(ml, CacheList):
    print(f"FAIL:not_cachelist:{type(ml).__name__}"); sys.exit(0)

# Inspect inner caches
sub0, sub1 = ml.caches[0], ml.caches[1]
if not isinstance(sub0, ArraysCache):
    print(f"FAIL:sub0_type:{type(sub0).__name__}"); sys.exit(0)

c0 = np.asarray(sub0.cache[0])
if c0.shape[0] != 2:
    print(f"FAIL:sub0_batch:{c0.shape}"); sys.exit(0)

# sub1 should be a batch-capable KV cache
if not (isinstance(sub1, KVCache) or isinstance(sub1, BatchKVCache)):
    print(f"FAIL:sub1_type:{type(sub1).__name__}"); sys.exit(0)

# Check the keys batch dimension
keys = np.asarray(sub1.keys)
if keys.shape[0] != 2:
    print(f"FAIL:sub1_batch:{keys.shape}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.15)
    echo "F2P-2 PASS (+0.15)"
else
    echo "F2P-2 FAIL: $out"
fi

# =========================================================================
# F2P-3 [0.15] — ArraysCache.merge classmethod produces correct concat,
#   and ArraysCache.extract(idx) recovers a single-batch slice.
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

if not hasattr(ArraysCache, 'merge'):
    print("FAIL:no_merge_classmethod"); sys.exit(0)
if not hasattr(ArraysCache, 'extract'):
    print("FAIL:no_extract"); sys.exit(0)

a = ArraysCache(size=2)
a.cache[0] = mx.array(np.full((1,3,4), 7.0, dtype=np.float32))
a.cache[1] = mx.array(np.full((1,2,2), 1.0, dtype=np.float32))
b = ArraysCache(size=2)
b.cache[0] = mx.array(np.full((1,3,4), 9.0, dtype=np.float32))
b.cache[1] = mx.array(np.full((1,2,2), 2.0, dtype=np.float32))

try:
    merged = ArraysCache.merge([a, b])
except Exception as e:
    print(f"FAIL:merge_exc:{e}"); sys.exit(0)

if not isinstance(merged, ArraysCache):
    print(f"FAIL:not_arrays:{type(merged).__name__}"); sys.exit(0)

m0 = np.asarray(merged.cache[0])
if m0.shape != (2,3,4):
    print(f"FAIL:merged_shape:{m0.shape}"); sys.exit(0)
if not (np.allclose(m0[0], 7.0) and np.allclose(m0[1], 9.0)):
    print(f"FAIL:merged_vals"); sys.exit(0)

try:
    e0 = merged.extract(0)
    e1 = merged.extract(1)
except Exception as e:
    print(f"FAIL:extract_exc:{e}"); sys.exit(0)

if not isinstance(e0, ArraysCache):
    print(f"FAIL:extract_type"); sys.exit(0)

x0 = np.asarray(e0.cache[0])
x1 = np.asarray(e1.cache[0])
if x0.shape[0] != 1 or x1.shape[0] != 1:
    print(f"FAIL:extract_shape:{x0.shape}|{x1.shape}"); sys.exit(0)
if not (np.allclose(x0, 7.0) and np.allclose(x1, 9.0)):
    print(f"FAIL:extract_vals"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.15)
    echo "F2P-3 PASS (+0.15)"
else
    echo "F2P-3 FAIL: $out"
fi

# =========================================================================
# F2P-4 [0.15] — CacheList.merge classmethod and CacheList.extract recursive
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

if not hasattr(CacheList, 'merge'):
    print("FAIL:no_clist_merge"); sys.exit(0)
if not hasattr(CacheList, 'extract'):
    print("FAIL:no_clist_extract"); sys.exit(0)

def mklist(v):
    a = ArraysCache(size=1)
    a.cache[0] = mx.array(np.full((1, 2, 3), v, dtype=np.float32))
    return CacheList(a)

cls_a = mklist(5.0)
cls_b = mklist(6.0)
cls_c = mklist(7.0)

try:
    merged = CacheList.merge([cls_a, cls_b, cls_c])
except Exception as e:
    print(f"FAIL:merge_exc:{e}"); sys.exit(0)

if not isinstance(merged, CacheList):
    print(f"FAIL:not_cachelist:{type(merged).__name__}"); sys.exit(0)
inner = merged.caches[0]
arr = np.asarray(inner.cache[0])
if arr.shape != (3,2,3):
    print(f"FAIL:shape:{arr.shape}"); sys.exit(0)
if not (np.allclose(arr[0],5.0) and np.allclose(arr[1],6.0) and np.allclose(arr[2],7.0)):
    print(f"FAIL:vals"); sys.exit(0)

# recursive extract
try:
    ex = merged.extract(1)
except Exception as e:
    print(f"FAIL:extract_exc:{e}"); sys.exit(0)
if not isinstance(ex, CacheList):
    print(f"FAIL:extract_type"); sys.exit(0)
ex_inner = np.asarray(ex.caches[0].cache[0])
if ex_inner.shape[0] != 1 or not np.allclose(ex_inner, 6.0):
    print(f"FAIL:extract_vals"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.15)
    echo "F2P-4 PASS (+0.15)"
else
    echo "F2P-4 FAIL: $out"
fi

# =========================================================================
# F2P-5 [0.15] — ArraysCache.prepare/finalize work and _lengths (or lengths)
#   gets populated when right_padding is provided. Tests behavioral hookup.
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

ac = ArraysCache(size=2)
if not hasattr(ac, 'prepare'):
    print("FAIL:no_prepare"); sys.exit(0)
if not hasattr(ac, 'finalize'):
    print("FAIL:no_finalize"); sys.exit(0)

# Test prepare with right_padding sets length attr
try:
    ac.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except Exception as e:
    print(f"FAIL:prepare_exc:{e}"); sys.exit(0)

len_attr = getattr(ac, '_lengths', None)
if len_attr is None:
    len_attr = getattr(ac, 'lengths', None)
if len_attr is None:
    print("FAIL:no_lengths_set"); sys.exit(0)

la = np.asarray(len_attr)
if la.shape != (2,) or int(la[0]) != 3 or int(la[1]) != 5:
    print(f"FAIL:bad_lengths:{la}"); sys.exit(0)

# finalize should clear it
try:
    ac.finalize()
except Exception as e:
    print(f"FAIL:finalize_exc:{e}"); sys.exit(0)

post = getattr(ac, '_lengths', None)
if post is None:
    post = getattr(ac, 'lengths', None)
if post is not None:
    print(f"FAIL:lengths_not_cleared:{post}"); sys.exit(0)

# Test prepare with left_padding only (no right_padding) — should not set lengths
ac2 = ArraysCache(size=2)
ac2.prepare(left_padding=[1, 2], lengths=[3, 5], right_padding=None)
post2 = getattr(ac2, '_lengths', None) or getattr(ac2, 'lengths', None)
if post2 is not None:
    print(f"FAIL:lengths_set_when_no_right_pad:{post2}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.15)
    echo "F2P-5 PASS (+0.15)"
else
    echo "F2P-5 FAIL: $out"
fi

# =========================================================================
# F2P-6 [0.10] — CacheList delegates prepare/finalize/extract; doesn't crash
#   on mixed sub-caches.
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

mc = MambaCache()
mc.cache[0] = mx.array(np.zeros((2, 3, 4), dtype=np.float32))
mc.cache[1] = mx.array(np.zeros((2, 2, 5), dtype=np.float32))
kv = KVCache()
kv.update_and_fetch(
    mx.array(np.zeros((2,2,4,6), dtype=np.float32)),
    mx.array(np.zeros((2,2,4,6), dtype=np.float32)),
)
cl = CacheList(mc, kv)

if not hasattr(cl, 'prepare'):
    print("FAIL:no_prepare"); sys.exit(0)
if not hasattr(cl, 'extract'):
    print("FAIL:no_extract"); sys.exit(0)

try:
    cl.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except Exception as e:
    print(f"FAIL:prepare_exc:{e}"); sys.exit(0)

# After prepare, mamba sub should have lengths
sub_len = getattr(mc, '_lengths', None) or getattr(mc, 'lengths', None)
if sub_len is None:
    print("FAIL:sub_lengths_not_set"); sys.exit(0)

try:
    ex = cl.extract(0)
except Exception as e:
    print(f"FAIL:extract_exc:{e}"); sys.exit(0)
if not isinstance(ex, CacheList):
    print(f"FAIL:extract_not_cachelist:{type(ex).__name__}"); sys.exit(0)
sub0 = ex.caches[0]
if not isinstance(sub0, ArraysCache):
    print(f"FAIL:sub0:{type(sub0).__name__}"); sys.exit(0)
arr = np.asarray(sub0.cache[0])
if arr.shape[0] != 1:
    print(f"FAIL:extract_batch:{arr.shape}"); sys.exit(0)

try:
    cl.finalize()
except Exception as e:
    print(f"FAIL:finalize_exc:{e}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    REWARD=$(add "$REWARD" 0.10)
    echo "F2P-6 PASS (+0.10)"
else
    echo "F2P-6 FAIL: $out"
fi

# =========================================================================
# F2P-7 [0.10] — Source-level: _merge_caches in generate.py mentions both
#   ArraysCache and CacheList (completeness gate against shallow patches that
#   only handle one).
# =========================================================================
gen_src=$(cat "$GENERATE_PY")
# Extract _merge_caches body specifically
mc_body=$(python3 << 'PYEOF' 2>&1
import ast
src = open('/workspace/mlx-lm/mlx_lm/generate.py').read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_merge_caches":
        print(ast.get_source_segment(src, node))
        break
PYEOF
)
has_arrays=0
has_cachelist=0
echo "$mc_body" | grep -q "ArraysCache" && has_arrays=1
echo "$mc_body" | grep -q "CacheList" && has_cachelist=1
if [ "$has_arrays" = "1" ] && [ "$has_cachelist" = "1" ]; then
    REWARD=$(add "$REWARD" 0.10)
    echo "F2P-7 PASS (+0.10)"
else
    echo "F2P-7 FAIL: arrays=$has_arrays cachelist=$has_cachelist"
fi

# =========================================================================
# F2P-8 [0.05] — Author-supplied unit test file exists and at least one test
#   passes (rewards bug-fix authoring discipline; small weight).
# =========================================================================
TEST_FILE="/workspace/mlx-lm/tests/test_mamba_cache_batching.py"
if [ -f "$TEST_FILE" ]; then
    cd /workspace/mlx-lm
    pyt_out=$(python3 -m pytest "$TEST_FILE" -v --no-header -x 2>&1 | tail -50)
    passed=$(echo "$pyt_out" | grep -oE "[0-9]+ passed" | head -1 | awk '{print $1}')
    if [ -n "$passed" ] && [ "$passed" -ge 1 ]; then
        REWARD=$(add "$REWARD" 0.05)
        echo "F2P-8 PASS (+0.05) — $passed tests passed"
    else
        echo "F2P-8 FAIL: no passing tests in $TEST_FILE"
    fi
    cd - >/dev/null
else
    echo "F2P-8 FAIL: test file missing"
fi

# Clamp
REWARD=$(awk -v r="$REWARD" 'BEGIN{ if (r>1.0) r=1.0; if (r<0.0) r=0.0; printf "%.4f", r }')
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt