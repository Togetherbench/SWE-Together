#!/bin/bash
set +e

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

# Locate target files
TARGET_CANDIDATES=(
    "/workspace/ComfyUI/ultravico/sageattn/attn_qk_int8_per_block.py"
    "/workspace/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/ultravico/sageattn/attn_qk_int8_per_block.py"
)
TARGET=""
for c in "${TARGET_CANDIDATES[@]}"; do
    if [ -f "$c" ]; then TARGET="$c"; break; fi
done

SPARSE_CANDIDATES=(
    "/workspace/ComfyUI/wanvideo/radial_attention/sparse_sage/sparse_int8_attn.py"
    "/workspace/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/wanvideo/radial_attention/sparse_sage/sparse_int8_attn.py"
)
SPARSE=""
for c in "${SPARSE_CANDIDATES[@]}"; do
    if [ -f "$c" ]; then SPARSE="$c"; break; fi
done

echo "TARGET=$TARGET"
echo "SPARSE=$SPARSE"

if [ -z "$TARGET" ]; then
    echo "FATAL: target not found"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

export TARGET SPARSE

# ════════════════════════════════════════════════════════════
# P2P GATE (no reward): file still parses & has expected functions.
# If broken => regression => exit with 0.0.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== P2P GATE: parse & structure ==="
GATE=$(python3 << 'PYEOF'
import os, ast, sys
target = os.environ["TARGET"]
sparse = os.environ.get("SPARSE","")
try:
    src = open(target).read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse_target:{e}"); sys.exit(0)
names = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
need = {"_attn_fwd_inner", "_attn_fwd", "forward"}
if not need.issubset(names):
    print(f"FAIL:missing:{need-names}"); sys.exit(0)
if sparse and os.path.isfile(sparse):
    try:
        ast.parse(open(sparse).read())
    except Exception as e:
        print(f"FAIL:parse_sparse:{e}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  GATE=$GATE"
if [ "$GATE" != "PASS" ]; then
    echo "Regression: $GATE"
    echo "0.0000" > "$REWARD_FILE"
    exit 0
fi

# ════════════════════════════════════════════════════════════
# F2P 1 (0.50): The buggy chained scalar*tensor pattern
#   qk = <expr> * q_scale * k_scale   (or reversed)
# must NOT remain in the target file. This is the line called out
# in the AMD MLIR error. On the unmodified base this pattern IS
# present → fails on base, passes on fix.
#
# Accept any rewrite: parenthesized combine, precomputed scale var,
# moved load, etc. The check is purely "buggy chain absent".
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 1 (0.50): buggy chained-mult eliminated in TARGET ==="
F1=$(python3 << 'PYEOF'
import os, ast, sys

def is_buggy_chain(val):
    # BinOp(BinOp(X, *, Name('q_scale'|'k_scale')), *, Name('k_scale'|'q_scale'))
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)):
        return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")):
        return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)):
        return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")):
        return False
    if val.right.id == inner.right.id:
        return False
    return True

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

qk_assigns = []
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_assigns.append(n)

if not qk_assigns:
    print("FAIL:no_qk"); sys.exit(0)

for a in qk_assigns:
    if is_buggy_chain(a.value):
        print("FAIL:buggy_chain_present"); sys.exit(0)

print("PASS")
PYEOF
)
echo "  F1=$F1"
[ "$F1" = "PASS" ] && add_reward 0.50

# ════════════════════════════════════════════════════════════
# F2P 2 (0.20): Same fix applied in the SPARSE companion file
#   (if it exists). Buggy base has same chained pattern there.
#   If file doesn't exist on this checkout, skip (no reward, no penalty).
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 2 (0.20): buggy chained-mult eliminated in SPARSE ==="
F2=$(python3 << 'PYEOF'
import os, ast, sys

sparse = os.environ.get("SPARSE","")
if not sparse or not os.path.isfile(sparse):
    print("SKIP"); sys.exit(0)

def is_buggy_chain(val):
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)):
        return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")):
        return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)):
        return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")):
        return False
    if val.right.id == inner.right.id:
        return False
    return True

src = open(sparse).read()
tree = ast.parse(src)
qk_assigns = []
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_assigns.append(n)
if not qk_assigns:
    # No qk in sparse file at all – treat as skip (don't reward, don't penalize).
    print("SKIP"); sys.exit(0)
for a in qk_assigns:
    if is_buggy_chain(a.value):
        print("FAIL:buggy_chain_present"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  F2=$F2"
[ "$F2" = "PASS" ] && add_reward 0.20

# ════════════════════════════════════════════════════════════
# F2P 3 (0.30): BEHAVIORAL — execute the qk-scaling logic of
# _attn_fwd_inner under a tracing harness. We replace tl.dot's
# result with a TensorProxy that records every scalar __mul__.
# Buggy base => proxy receives TWO sequential scalar multiplications
# (q_scale then k_scale, or vice versa) ⇒ FAIL.
# Any correct fix collapses scaling to ONE scalar multiplication
# applied to the tensor (combined scale, parenthesized, or
# precomputed var) ⇒ PASS.
#
# We synthesize a tiny driver that mirrors the relevant statements
# of _attn_fwd_inner by extracting just the qk-related lines from
# the function body via AST, then exec'ing them with a controlled
# namespace.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 3 (0.30): behavioral scale-multiplication trace ==="
F3=$(python3 << 'PYEOF'
import os, ast, sys, types

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

inner = next((n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner is None:
    print("FAIL:no_inner"); sys.exit(0)

# Collect statements in execution order: top-level body of the function,
# plus any For-loop bodies (the qk computation lives inside the for-loop).
stmts = []
def collect(body):
    for s in body:
        if isinstance(s, ast.For):
            collect(s.body)
        elif isinstance(s, ast.If):
            # take then-branch statements (best effort)
            stmts.append(s)
            collect(s.body)
        else:
            stmts.append(s)
collect(inner.body)

# Find index of qk assignment.
qk_idx = None
for i, s in enumerate(stmts):
    if isinstance(s, ast.Assign):
        for t in s.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_idx = i
                break
        if qk_idx is not None:
            break

if qk_idx is None:
    print("FAIL:no_qk_assign"); sys.exit(0)

# We want statements that may define scale-related names leading up to qk.
# Keep only Assign statements (simple) up to and including qk_idx, and
# skip those whose RHS we cannot evaluate. We'll try to exec them in a
# permissive namespace; on NameError for an unknown name, we inject a
# benign sentinel and retry.
relevant = [s for s in stmts[:qk_idx+1] if isinstance(s, ast.Assign)]

# Build a small module containing just these statements as a function.
fn_ast = ast.FunctionDef(
    name="_run",
    args=ast.arguments(posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[], defaults=[]),
    body=relevant + [ast.Return(value=ast.Name(id="qk", ctx=ast.Load()))],
    decorator_list=[],
    returns=None,
    type_comment=None,
)
mod = ast.Module(body=[fn_ast], type_ignores=[])
ast.fix_missing_locations(mod)

# Tracer
class TensorProxy:
    def __init__(self, scalar_mul_count=0):
        self.scalar_mul_count = scalar_mul_count
    def _wrap(self, other):
        # Multiplying by anything that isn't another TensorProxy counts as
        # a scalar mul on the tensor.
        if isinstance(other, TensorProxy):
            return TensorProxy(self.scalar_mul_count + other.scalar_mul_count)
        return TensorProxy(self.scalar_mul_count + 1)
    def __mul__(self, o): return self._wrap(o)
    def __rmul__(self, o): return self._wrap(o)
    def __add__(self, o): return self
    def __radd__(self, o): return self
    def __sub__(self, o): return self
    def __rsub__(self, o): return self
    def __truediv__(self, o): return self
    def __rtruediv__(self, o): return self
    def to(self, *a, **kw): return self
    def __getitem__(self, k): return self
    def __neg__(self): return self

class FakeTL:
    float32 = "float32"
    float16 = "float16"
    int32 = "int32"
    @staticmethod
    def dot(a, b, *args, **kwargs):
        return TensorProxy()
    @staticmethod
    def load(ptr, *args, **kwargs):
        # Scalar load (q_scale / k_scale style) — return a plain float.
        return 1.0
    @staticmethod
    def arange(a, b): return 0
    @staticmethod
    def maximum(a, b): return a
    @staticmethod
    def minimum(a, b): return a
    @staticmethod
    def exp(a): return a
    @staticmethod
    def exp2(a): return a
    @staticmethod
    def log2(a): return a
    @staticmethod
    def sum(a, axis=None): return a
    @staticmethod
    def max(a, axis=None): return a
    @staticmethod
    def where(c, a, b): return a
    @staticmethod
    def zeros(shape, dtype=None): return TensorProxy()
    @staticmethod
    def full(shape, value, dtype=None): return TensorProxy()
    @staticmethod
    def cdiv(a, b): return 1
    @staticmethod
    def program_id(axis): return 0
    @staticmethod
    def num_programs(axis): return 1
    @staticmethod
    def static_assert(*a, **kw): return None
    @staticmethod
    def static_print(*a, **kw): return None
    @staticmethod
    def trans(a, *args): return a
    @staticmethod
    def view(a, *args): return a
    @staticmethod
    def reshape(a, *args): return a
    @staticmethod
    def broadcast_to(a, *args): return a

# Compile
try:
    code = compile(mod, "<extracted>", "exec")
except Exception as e:
    print(f"FAIL:compile:{e}"); sys.exit(0)

# Try executing with a permissive namespace, auto-injecting unknown names
# as benign scalars. q_scale / k_scale are real floats so chained
# multiplications are detectable on the TensorProxy.
attempts = 0
ns = {
    "tl": FakeTL,
    "q": TensorProxy(),
    "k": TensorProxy(),
    "v": TensorProxy(),
    "q_scale": 1.0,
    "k_scale": 1.0,
    "Q_scale_ptr": 0,
    "K_scale_ptr": 0,
    "K_ptrs": 0,
    "V_ptrs": 0,
    "Q_ptrs": 0,
    "k_mask": True,
    "v_mask": True,
    "q_mask": True,
    "offs_m": TensorProxy(),
    "offs_n": TensorProxy(),
    "start_n": 0,
    "STAGE": 1,
    "BLOCK_M": 64,
    "BLOCK_N": 64,
    "HEAD_DIM": 64,
    "N_CTX": 64,
    "stride_kn": 1, "stride_kk": 1,
    "stride_vn": 1, "stride_vk": 1,
    "stride_qm": 1, "stride_qk": 1,
    "lo": 0, "hi": 0,
    "m_i": TensorProxy(), "l_i": TensorProxy(), "acc": TensorProxy(),
    "qk_scale": 1.0,
    "n": TensorProxy(), "m": TensorProxy(),
    "True": True, "False": False, "None": None,
    "scale": 1.0,
    "combined_scale": 1.0,
    "qk": TensorProxy(),
}

result = None
last_err = None
for attempt in range(60):
    try:
        local_ns = {}
        exec(code, ns, local_ns)
        result = local_ns["_run"]()
        break
    except NameError as e:
        # Extract missing name from message: "name 'X' is not defined"
        msg = str(e)
        import re
        m = re.search(r"'([^']+)'", msg)
        if not m:
            last_err = e; break
        missing = m.group(1)
        if missing in ns:
            last_err = e; break
        ns[missing] = 1.0  # benign scalar
    except Exception as e:
        last_err = e
        break

if result is None:
    print(f"FAIL:exec:{type(last_err).__name__}:{last_err}"); sys.exit(0)

if not isinstance(result, TensorProxy):
    print(f"FAIL:not_tensor:{type(result).__name__}"); sys.exit(0)

# Buggy form: tensor multiplied by q_scale then by k_scale separately
# => scalar_mul_count >= 2.
# Correct fix: scales combined first => scalar_mul_count == 1
# (one tensor*scalar applied to the dot result).
n = result.scalar_mul_count
if n <= 1:
    print(f"PASS:n={n}")
else:
    print(f"FAIL:scalar_muls={n}")
PYEOF
)
echo "  F3=$F3"
case "$F3" in
    PASS*) add_reward 0.30 ;;
esac

echo ""
echo "Final reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"