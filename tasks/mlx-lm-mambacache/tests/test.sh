#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

GATES_FILE=/logs/verifier/gates.json
REWARD_FILE=/logs/verifier/reward.txt
mkdir -p /logs/verifier
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

write_reward() {
    awk -v r="$1" 'BEGIN{ if (r>1.0) r=1.0; if (r<0.0) r=0.0; printf "%.4f\n", r }' > "$REWARD_FILE"
}

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"

if [ ! -f "$CACHE_PY" ] || [ ! -f "$GENERATE_PY" ]; then
    emit p2p_cache_module_loads false "missing source files"
    write_reward 0.0
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
    _mx.less = np.less
    _mx.greater = np.greater
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

# ---------- P2P gate: cache.py loads, base classes present, _merge_caches importable ----------
gate_out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
ok = True
for name in ['ArraysCache','MambaCache','CacheList','KVCache','RotatingKVCache']:
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
if echo "$gate_out" | grep -q "^GATE_OK$"; then
    emit p2p_cache_module_loads true ""
    P2P_OK=1
else
    emit p2p_cache_module_loads false "module load failed"
    P2P_OK=0
fi

# Helper for awk float add
add() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.4f", a+b}'; }
REWARD=0.0

# =========================================================================
# F2P t2_f2p_merge_caches_arrayscache [0.18]
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

# Independence: merged should not be the same object as inputs
if m0 is ac1 or m0 is ac2:
    print("FAIL:identity"); sys.exit(0)

c0 = np.asarray(m0.cache[0])
c1 = np.asarray(m0.cache[1])
if c0.shape != (2,4,3) or c1.shape != (2,4,8):
    print(f"FAIL:bad_shape:{c0.shape}|{c1.shape}"); sys.exit(0)

if not (np.allclose(c0[0], 1.0) and np.allclose(c0[1], 3.0)):
    print(f"FAIL:bad_vals_c0"); sys.exit(0)
if not (np.allclose(c1[0], 2.0) and np.allclose(c1[1], 4.0)):
    print(f"FAIL:bad_vals_c1"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t2_f2p_merge_caches_arrayscache true ""
    REWARD=$(add "$REWARD" 0.18)
else
    emit t2_f2p_merge_caches_arrayscache false "$out"
fi

# =========================================================================
# F2P t2_f2p_merge_caches_cachelist_hybrid [0.18]
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np
if _merge_caches is None:
    print("FAIL:no_merge"); sys.exit(0)

def make_layer(seed):
    np.random.seed(seed)
    mc = MambaCache()
    mc.cache[0] = mx.array(np.random.randn(1, 3, 4).astype(np.float32))
    mc.cache[1] = mx.array(np.random.randn(1, 2, 5).astype(np.float32))
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

# Order preserved: sub0 must be the ArraysCache/MambaCache, sub1 must be KV-flavored
sub0, sub1 = ml.caches[0], ml.caches[1]
if not isinstance(sub0, ArraysCache):
    print(f"FAIL:sub0_type:{type(sub0).__name__}"); sys.exit(0)
if isinstance(sub0, (KVCache, RotatingKVCache)) and not isinstance(sub0, ArraysCache):
    # ArraysCache base check above already handles it; guard against KV being placed first
    print(f"FAIL:sub0_is_kv"); sys.exit(0)

c0 = np.asarray(sub0.cache[0])
if c0.shape[0] != 2:
    print(f"FAIL:sub0_batch:{c0.shape}"); sys.exit(0)

# sub1 should be a KV-flavored cache, batched
kv_types = (KVCache,)
if BatchKVCache is not None:
    kv_types = (KVCache, BatchKVCache)
if not isinstance(sub1, kv_types):
    print(f"FAIL:sub1_type:{type(sub1).__name__}"); sys.exit(0)

keys = np.asarray(sub1.keys)
if keys.shape[0] != 2:
    print(f"FAIL:sub1_batch:{keys.shape}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t2_f2p_merge_caches_cachelist_hybrid true ""
    REWARD=$(add "$REWARD" 0.18)
else
    emit t2_f2p_merge_caches_cachelist_hybrid false "$out"
fi

# =========================================================================
# F2P t2_f2p_arrayscache_merge_extract [0.16]
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

if not hasattr(ArraysCache, 'merge'):
    print("FAIL:no_merge_classmethod"); sys.exit(0)
if not hasattr(ArraysCache, 'extract'):
    print("FAIL:no_extract"); sys.exit(0)

# Build a 4-batch cache with distinguishable per-batch values
a = ArraysCache(size=2)
arr0 = np.zeros((4, 2, 3), dtype=np.float32)
for i in range(4):
    arr0[i] = float(i + 10)
a.cache[0] = mx.array(arr0)
arr1 = np.zeros((4, 5), dtype=np.float32)
for i in range(4):
    arr1[i] = float(i + 100)
a.cache[1] = mx.array(arr1)

# Test merge round trip
b = ArraysCache(size=2)
b.cache[0] = mx.array(np.full((1,2,3), -1.0, dtype=np.float32))
b.cache[1] = mx.array(np.full((1,5), -2.0, dtype=np.float32))

# Build via merge
c = ArraysCache(size=2)
c.cache[0] = mx.array(np.full((1,2,3), 99.0, dtype=np.float32))
c.cache[1] = mx.array(np.full((1,5), 88.0, dtype=np.float32))
try:
    merged = ArraysCache.merge([b, c])
except Exception as e:
    print(f"FAIL:merge_exc:{e}"); sys.exit(0)
if not isinstance(merged, ArraysCache):
    print(f"FAIL:merge_type:{type(merged).__name__}"); sys.exit(0)
m0 = np.asarray(merged.cache[0])
if m0.shape != (2,2,3):
    print(f"FAIL:merge_shape:{m0.shape}"); sys.exit(0)
if not (np.allclose(m0[0], -1.0) and np.allclose(m0[1], 99.0)):
    print(f"FAIL:merge_vals"); sys.exit(0)

# Test extract on the 4-batch cache
try:
    e2 = a.extract(2)
except Exception as e:
    print(f"FAIL:extract_exc:{e}"); sys.exit(0)
if not isinstance(e2, ArraysCache):
    print(f"FAIL:extract_type:{type(e2).__name__}"); sys.exit(0)
x0 = np.asarray(e2.cache[0])
x1 = np.asarray(e2.cache[1])
if x0.shape != (1,2,3) or x1.shape != (1,5):
    print(f"FAIL:extract_shape:{x0.shape}|{x1.shape}"); sys.exit(0)
if not np.allclose(x0, 12.0):
    print(f"FAIL:extract_val0:{x0}"); sys.exit(0)
if not np.allclose(x1, 102.0):
    print(f"FAIL:extract_val1:{x1}"); sys.exit(0)

# Ensure extract didn't mutate source
src_check = np.asarray(a.cache[0])
if src_check.shape[0] != 4:
    print(f"FAIL:source_mutated:{src_check.shape}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t2_f2p_arrayscache_merge_extract true ""
    REWARD=$(add "$REWARD" 0.16)
else
    emit t2_f2p_arrayscache_merge_extract false "$out"
fi

# =========================================================================
# F2P t2_f2p_cachelist_merge_extract [0.13]
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

if not hasattr(CacheList, 'merge'):
    print("FAIL:no_clist_merge"); sys.exit(0)
if not hasattr(CacheList, 'extract'):
    print("FAIL:no_clist_extract"); sys.exit(0)

def mklist(v, w):
    a = ArraysCache(size=1)
    a.cache[0] = mx.array(np.full((1, 2, 3), v, dtype=np.float32))
    b = ArraysCache(size=1)
    b.cache[0] = mx.array(np.full((1, 4), w, dtype=np.float32))
    return CacheList(a, b)

cls_a = mklist(5.0, 50.0)
cls_b = mklist(6.0, 60.0)
cls_c = mklist(7.0, 70.0)

try:
    merged = CacheList.merge([cls_a, cls_b, cls_c])
except Exception as e:
    print(f"FAIL:merge_exc:{e}"); sys.exit(0)

if not isinstance(merged, CacheList):
    print(f"FAIL:not_cachelist:{type(merged).__name__}"); sys.exit(0)
inner0 = merged.caches[0]
inner1 = merged.caches[1]
arr0 = np.asarray(inner0.cache[0])
arr1 = np.asarray(inner1.cache[0])
if arr0.shape != (3,2,3) or arr1.shape != (3,4):
    print(f"FAIL:shape:{arr0.shape}|{arr1.shape}"); sys.exit(0)
if not (np.allclose(arr0[0],5.0) and np.allclose(arr0[1],6.0) and np.allclose(arr0[2],7.0)):
    print(f"FAIL:vals0"); sys.exit(0)
if not (np.allclose(arr1[0],50.0) and np.allclose(arr1[1],60.0) and np.allclose(arr1[2],70.0)):
    print(f"FAIL:vals1"); sys.exit(0)

# Recursive extract
try:
    ex = merged.extract(1)
except Exception as e:
    print(f"FAIL:extract_exc:{e}"); sys.exit(0)
if not isinstance(ex, CacheList):
    print(f"FAIL:extract_type:{type(ex).__name__}"); sys.exit(0)
ex0 = np.asarray(ex.caches[0].cache[0])
ex1 = np.asarray(ex.caches[1].cache[0])
if ex0.shape[0] != 1 or ex1.shape[0] != 1:
    print(f"FAIL:extract_shape:{ex0.shape}|{ex1.shape}"); sys.exit(0)
if not (np.allclose(ex0, 6.0) and np.allclose(ex1, 60.0)):
    print(f"FAIL:extract_vals"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t2_f2p_cachelist_merge_extract true ""
    REWARD=$(add "$REWARD" 0.13)
else
    emit t2_f2p_cachelist_merge_extract false "$out"
fi

# =========================================================================
# F2P t2_f2p_test_file_present_passes [0.10]
# =========================================================================
TEST_FILE="/workspace/mlx-lm/tests/test_mamba_cache_batching.py"
if [ -f "$TEST_FILE" ]; then
    if grep -qE "ArraysCache|MambaCache|CacheList" "$TEST_FILE"; then
        cd /workspace/mlx-lm
        pyt_out=$(python3 -m pytest "$TEST_FILE" -v --no-header 2>&1 | tail -80)
        passed=$(echo "$pyt_out" | grep -oE "[0-9]+ passed" | head -1 | awk '{print $1}')
        cd - >/dev/null
        if [ -n "$passed" ] && [ "$passed" -ge 1 ]; then
            emit t2_f2p_test_file_present_passes true "$passed tests passed"
            REWARD=$(add "$REWARD" 0.10)
        else
            emit t2_f2p_test_file_present_passes false "no passing tests"
        fi
    else
        emit t2_f2p_test_file_present_passes false "test file lacks Cache class references"
    fi
else
    emit t2_f2p_test_file_present_passes false "test file missing"
fi

# =========================================================================
# F2P t4_f2p_lengths_right_padding [0.15]
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

ac = ArraysCache(size=2)
if not hasattr(ac, 'prepare'):
    print("FAIL:no_prepare"); sys.exit(0)
if not hasattr(ac, 'finalize'):
    print("FAIL:no_finalize"); sys.exit(0)

# right_padding given => _lengths populated
try:
    ac.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except Exception as e:
    print(f"FAIL:prepare_exc:{e}"); sys.exit(0)

len_attr = getattr(ac, '_lengths', None)
if len_attr is None:
    len_attr = getattr(ac, 'lengths', None)
if len_attr is None:
    print("FAIL:no_lengths_set"); sys.exit(0)
la = np.asarray(len_attr).reshape(-1)
if la.shape[0] != 2 or int(la[0]) != 3 or int(la[1]) != 5:
    print(f"FAIL:bad_lengths:{la}"); sys.exit(0)

# finalize clears
try:
    ac.finalize()
except Exception as e:
    print(f"FAIL:finalize_exc:{e}"); sys.exit(0)
post = getattr(ac, '_lengths', None)
if post is None:
    post = getattr(ac, 'lengths', None)
if post is not None:
    print(f"FAIL:lengths_not_cleared:{post}"); sys.exit(0)

# left_padding only => no _lengths
ac2 = ArraysCache(size=2)
ac2.prepare(left_padding=[1, 2], lengths=[3, 5], right_padding=None)
post2 = getattr(ac2, '_lengths', None) or getattr(ac2, 'lengths', None)
if post2 is not None:
    print(f"FAIL:lengths_set_when_no_right_pad:{post2}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t4_f2p_lengths_right_padding true ""
    REWARD=$(add "$REWARD" 0.15)
else
    emit t4_f2p_lengths_right_padding false "$out"
fi

# =========================================================================
# F2P t4_f2p_make_mask_lengths [0.10]
# Behavioral check: when _lengths is set, a mask construction that respects
# lengths must yield False at positions >= length per row.
# We accept either:
#  - a make_mask method on ArraysCache that returns a (B, L) or compatible mask
#  - or an internal _lengths attribute that the make_mask in cache module uses.
# Strategy: prefer instance method; if absent, look for module-level make_mask
# that accepts a cache and returns a mask.
# =========================================================================
out=$(python3 << 'PYEOF' 2>&1
existing = 0.0  # injected: legacy restoration (avoid NameError)
exec(open('/tmp/mlx_test_env.py').read())
import sys, numpy as np

ac = ArraysCache(size=1)
ac.cache[0] = mx.array(np.zeros((2, 5), dtype=np.float32))
try:
    ac.prepare(left_padding=None, lengths=[3, 5], right_padding=[2, 0])
except Exception as e:
    print(f"FAIL:prepare_exc:{e}"); sys.exit(0)

# Find a make_mask callable
mk = None
target_len = 5
if hasattr(ac, 'make_mask'):
    mk = ac.make_mask
elif 'make_mask' in _cache_ns and callable(_cache_ns['make_mask']):
    _f = _cache_ns['make_mask']
    mk = lambda L=target_len: _f(ac, L)
else:
    # Fallback: derive mask from _lengths attribute directly. Accepts gates
    # where the patch wires _lengths into the existing create_causal_mask path
    # which we shimmed out — at minimum, _lengths must be present and usable.
    le = getattr(ac, '_lengths', None)
    if le is None:
        print("FAIL:no_make_mask_and_no_lengths"); sys.exit(0)
    la = np.asarray(le).reshape(-1)
    rows = la.shape[0]
    mask = np.zeros((rows, target_len), dtype=bool)
    for i, L in enumerate(la):
        mask[i, :int(L)] = True
    # This fallback only validates _lengths is wired correctly — not a full
    # behavioral check. We require the patch to either expose make_mask OR
    # at least keep _lengths usable to build a right-pad mask.
    if mask.shape != (2, 5):
        print(f"FAIL:fallback_shape:{mask.shape}"); sys.exit(0)
    if mask[0].tolist() != [True,True,True,False,False]:
        print(f"FAIL:fallback_row0:{mask[0]}"); sys.exit(0)
    if mask[1].tolist() != [True]*5:
        print(f"FAIL:fallback_row1:{mask[1]}"); sys.exit(0)
    print("PASS")
    sys.exit(0)

try:
    m = mk(target_len) if mk.__code__.co_argcount >= 1 else mk()
except Exception as e:
    # Try no-arg
    try:
        m = mk()
    except Exception as e2:
        print(f"FAIL:make_mask_exc:{e}|{e2}"); sys.exit(0)

m_arr = np.asarray(m)
# Reduce to a (rows, L) bool view if higher rank
while m_arr.ndim > 2:
    m_arr = m_arr[0] if m_arr.shape[0] == 1 else m_arr.reshape(m_arr.shape[0], -1)
if m_arr.dtype != bool:
    m_arr = m_arr.astype(bool)
if m_arr.shape[0] != 2 or m_arr.shape[-1] < 5:
    print(f"FAIL:mask_shape:{m_arr.shape}"); sys.exit(0)

row0 = m_arr[0, :5].tolist()
row1 = m_arr[1, :5].tolist()
# Either True=valid or False=valid convention; we accept either, requiring
# differentiation: row0 must have exactly 3 valid positions, row1 exactly 5.
def count_one_value(row):
    return row.count(True), row.count(False)
t0, f0 = count_one_value(row0)
t1, f1 = count_one_value(row1)
# row1 should be all-True OR all-False; row0 should have count 3 of the
# "valid" symbol (whichever matches row1's all-value).
if t1 == 5:
    valid = True
elif f1 == 5:
    valid = False
else:
    print(f"FAIL:row1_not_uniform:{row1}"); sys.exit(0)

count0 = row0.count(valid)
if count0 != 3:
    print(f"FAIL:row0_count:{count0} row0={row0}"); sys.exit(0)

# And the first 3 positions of row0 should be 'valid' (right-padding semantics)
if row0[:3] != [valid, valid, valid] or row0[3] == valid or row0[4] == valid:
    print(f"FAIL:row0_pattern:{row0}"); sys.exit(0)

print("PASS")
PYEOF
)
if echo "$out" | grep -q "^PASS$"; then
    emit t4_f2p_make_mask_lengths true ""
    REWARD=$(add "$REWARD" 0.10)
else
    emit t4_f2p_make_mask_lengths false "$out"
fi

# ---------- Apply P2P diagnostic ----------
if [ "$P2P_OK" != "1" ]; then
    write_reward 0.0
    echo "P2P diagnostic failed; reward=0.0"
    exit 0
fi

write_reward "$REWARD"
echo "FINAL REWARD: $(cat $REWARD_FILE)"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjb21tYW5kIC12IHB5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate f2p_upstream_bd8a7d6f 'py_compile_changed_generic' 'cd /workspace/mlx-lm && cd /workspace && python3 -m py_compile /workspace/mlx-lm/mlx_lm/models/cache.py /workspace/mlx-lm/mlx_lm/generate.py /workspace/mlx-lm/tests/test_mamba_cache_batching.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"f2p_upstream_bd8a7d6f": 0.2, "t2_f2p_arrayscache_merge_extract": 0.128, "t2_f2p_cachelist_merge_extract": 0.104, "t2_f2p_merge_caches_arrayscache": 0.144, "t2_f2p_merge_caches_cachelist_hybrid": 0.144, "t2_f2p_test_file_present_passes": 0.08, "t4_f2p_lengths_right_padding": 0.12, "t4_f2p_make_mask_lengths": 0.08}
P2P_REGRESSION = ["p2p_cache_module_loads"]
P2P_REGRESSION = []
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
reward = 0.0
for gid, w in WEIGHTS.items():
    if verdicts.get(gid, False): reward += w
if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
