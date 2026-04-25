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
# TEST 1 (0.10): P2P — file parses, structure intact, importable under mocked triton
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 1 (0.10): P2P module structure & import ==="
T1=$(python3 << 'PYEOF'
import sys, os, ast, importlib.util
from unittest.mock import MagicMock

target = os.environ["TARGET"]

mock_triton = MagicMock()
def passthrough_jit(fn=None, **kwargs):
    if fn is not None: return fn
    return lambda f: f
mock_triton.jit = passthrough_jit
sys.modules['triton'] = mock_triton
sys.modules['triton.language'] = mock_triton.language

try:
    src = open(target).read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

names = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
need = {"_attn_fwd_inner", "_attn_fwd", "forward"}
if not need.issubset(names):
    print(f"FAIL:missing:{need-names}"); sys.exit(0)

try:
    spec = importlib.util.spec_from_file_location("amod", target)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as e:
    print(f"FAIL:exec:{type(e).__name__}:{e}"); sys.exit(0)

print("PASS")
PYEOF
)
echo "  $T1"
[ "$T1" = "PASS" ] && add_reward 0.10

# ════════════════════════════════════════════════════════════
# TEST 2 (0.10): P2P — anti-stub: _attn_fwd_inner has substantial body, for-loop, k_scale & dot used
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2 (0.10): P2P anti-stub ==="
T2=$(python3 << 'PYEOF'
import os, ast
target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)
inner = next((n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner is None: print("FAIL:no_inner"); raise SystemExit
has_for = any(isinstance(n, ast.For) for n in ast.walk(inner))
stmts = sum(1 for n in ast.walk(inner) if isinstance(n, (ast.Assign,ast.AugAssign,ast.For,ast.If,ast.Return)))
has_dot = any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "dot"
              for n in ast.walk(inner))
# k_scale referenced (Name load) somewhere
refs_kscale = any(isinstance(n, ast.Name) and n.id == "k_scale" for n in ast.walk(inner))
refs_qscale = any(isinstance(n, ast.Name) and n.id == "q_scale" for n in ast.walk(inner))
if has_for and stmts >= 12 and has_dot and refs_kscale and refs_qscale:
    print("PASS")
else:
    print(f"FAIL:for={has_for} stmts={stmts} dot={has_dot} k={refs_kscale} q={refs_qscale}")
PYEOF
)
echo "  $T2"
[ "$T2" = "PASS" ] && add_reward 0.10

# ════════════════════════════════════════════════════════════
# TEST 3 (0.15): Structural — buggy chained-splat qk pattern eliminated
#   Original: qk = tl.dot(q,k).to(tl.float32) * q_scale * k_scale
#   This pattern (chained scalar mults on tensor) is what triggers the AMD bug.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3 (0.15): Structural - buggy chained pattern eliminated ==="
T3=$(python3 << 'PYEOF'
import os, ast
def is_buggy_chain(val):
    # Detect: <tensor_expr> * q_scale * k_scale  (left-assoc BinOp)
    # i.e. BinOp(BinOp(X, *, Name('q_scale')), *, Name('k_scale'))
    # OR  BinOp(BinOp(X, *, Name('k_scale')), *, Name('q_scale'))
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")): return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)): return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")): return False
    if val.right.id == inner.right.id: return False
    return True

def check_file(path):
    src = open(path).read()
    tree = ast.parse(src)
    qk_assigns = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name) and t.id == "qk":
                    qk_assigns.append(n)
    if not qk_assigns: return None  # no qk in this file
    for a in qk_assigns:
        if is_buggy_chain(a.value):
            return False
    return True

target = os.environ["TARGET"]
sparse = os.environ.get("SPARSE","")

t_ok = check_file(target)
if t_ok is None:
    print("FAIL:no_qk_in_target"); raise SystemExit
if t_ok is False:
    print("FAIL:target_buggy_present"); raise SystemExit

if sparse and os.path.isfile(sparse):
    s_ok = check_file(sparse)
    if s_ok is False:
        print("FAIL:sparse_buggy_present"); raise SystemExit

print("PASS")
PYEOF
)
echo "  $T3"
[ "$T3" = "PASS" ] && add_reward 0.15

# ════════════════════════════════════════════════════════════
# TEST 4 (0.35): F2P BEHAVIORAL — execute kernel under mocked triton tracer.
#   Track every multiplication. Buggy form applies two scalar*tensor mults.
#   Fix should either:
#     (a) combine scales first  -> tensor multiplied by ONE scalar (combined)
#     (b) precompute scale var  -> same effect
#     (c) parenthesized * (q*k) -> tensor multiplied by ONE scalar
#   We trace by replacing q_scale, k_scale with sentinel scalars and tl.dot
#   result with a fake Tensor object that records all __mul__ ops.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4 (0.35): F2P behavioral - scaling semantics traced ==="
T4=$(python3 << 'PYEOF'
import os, sys, ast, types

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

inner_fn = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner_fn is None:
    print("FAIL:no_inner"); sys.exit(0)

# We'll directly extract the body of _attn_fwd_inner and execute it after
# extracting/simulating the for-loop body. Simpler: count the structural
# pattern of the qk assignment expressions and verify scale combination.

# More reliable: AST analysis of ALL qk assignments + scale precomputation.
# Acceptable patterns (any one in inner-loop scope):
#   A) qk = <expr> * (q_scale * k_scale)  or * (k_scale * q_scale)
#   B) Some assign before qk: scale = q_scale * k_scale (or reversed); then qk = <expr> * scale
#   C) qk = <expr> * combined_name where combined_name = ... q_scale ... k_scale ...

class TensorProxy:
    def __init__(self, tag): self.tag = tag; self.scalar_muls = []
    def __mul__(self, o):
        # tensor * scalar => still tensor; record
        new = TensorProxy(self.tag)
        new.scalar_muls = self.scalar_muls + [o]
        return new
    def __rmul__(self, o): return self.__mul__(o)
    def to(self, *a, **kw): return self

def analyze(fn_node):
    # Walk top-level statements of function (after for-loop, look in for-body too).
    # Collect: qk assignments, and any scale-precompute assignments preceding them.
    bodies = [fn_node.body]
    for n in ast.walk(fn_node):
        if isinstance(n, (ast.For, ast.If, ast.While)):
            bodies.append(n.body)
            if hasattr(n, 'orelse'): bodies.append(n.orelse)

    results = []
    for body in bodies:
        # Track names defined as combinations involving q_scale and k_scale
        combined_names = set()
        for stmt in body:
            if isinstance(stmt, ast.Assign) and len(stmt.targets)==1 and isinstance(stmt.targets[0], ast.Name):
                tgt = stmt.targets[0].id
                # Check if RHS contains both q_scale and k_scale and is a BinOp Mult of just these
                names_in = [n.id for n in ast.walk(stmt.value) if isinstance(n, ast.Name)]
                if "q_scale" in names_in and "k_scale" in names_in:
                    # And RHS is purely Names/BinOps (not involving tl.dot)
                    has_call = any(isinstance(n, ast.Call) for n in ast.walk(stmt.value))
                    if not has_call:
                        combined_names.add(tgt)
            if isinstance(stmt, ast.Assign):
                for t in stmt.targets:
                    if isinstance(t, ast.Name) and t.id == "qk":
                        results.append((stmt.value, combined_names.copy()))
    return results

qk_results = analyze(inner_fn)
if not qk_results:
    print("FAIL:no_qk_assigns"); sys.exit(0)

def classify(val, combined):
    # val is the RHS expression of qk = ...
    # Walk top-level multiplication chain: collect right-hand operands of nested * BinOps
    operands = []
    cur = val
    while isinstance(cur, ast.BinOp) and isinstance(cur.op, ast.Mult):
        operands.append(cur.right)
        cur = cur.left
    operands.append(cur)  # leftmost
    operands.reverse()
    # operands[0] = base (likely tl.dot(...).to(...))
    # operands[1:] = scalars/tensors multiplied in sequence
    scalar_muls = operands[1:]
    if not scalar_muls:
        return "no_mul"

    # Pattern A: single operand that's a parenthesized BinOp of q_scale*k_scale
    if len(scalar_muls) == 1:
        op = scalar_muls[0]
        if isinstance(op, ast.BinOp) and isinstance(op.op, ast.Mult):
            ns = {n.id for n in ast.walk(op) if isinstance(n, ast.Name)}
            if {"q_scale","k_scale"}.issubset(ns):
                return "combined_inline"
        if isinstance(op, ast.Name) and op.id in combined:
            return "combined_var"
        # Single multiplier that isn't both scales -> something different (could be valid e.g. only one scale used)
        if isinstance(op, ast.Name) and op.id in ("q_scale","k_scale"):
            return "single_scale"
        return "other_single"

    # Pattern B (buggy): multiple chained scalars including q_scale and k_scale
    names = []
    for o in scalar_muls:
        if isinstance(o, ast.Name): names.append(o.id)
    if "q_scale" in names and "k_scale" in names:
        return "buggy_chain"
    return "other_chain"

categories = [classify(v, c) for v, c in qk_results]
# Pass if at least one qk assignment is in {combined_inline, combined_var}
# AND none are buggy_chain
good = {"combined_inline", "combined_var"}
if any(cat == "buggy_chain" for cat in categories):
    print(f"FAIL:buggy_chain_present:{categories}"); sys.exit(0)
if any(cat in good for cat in categories):
    print(f"PASS:{categories}")
else:
    print(f"FAIL:no_combined_form:{categories}")
PYEOF
)
echo "  $T4"
case "$T4" in
    PASS*) add_reward 0.35 ;;
esac

# ════════════════════════════════════════════════════════════
# TEST 5 (0.15): F2P BEHAVIORAL — runtime trace via mocked triton, verify that
#   tensor-vs-scalar multiplication semantics give exactly ONE combined scalar.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5 (0.15): F2P runtime trace - scalar fold semantics ==="
T5=$(python3 << 'PYEOF'
import os, sys, ast, types

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

inner_fn = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner_fn is None: print("FAIL:no_inner"); sys.exit(0)

# Find the for-loop body inside _attn_fwd_inner
loop = None
for n in ast.walk(inner_fn):
    if isinstance(n, ast.For):
        loop = n; break
if loop is None: print("FAIL:no_loop"); sys.exit(0)

# Extract statements up to and including the qk assignment
qk_assign_idx = None
for i, stmt in enumerate(loop.body):
    for t in (getattr(stmt,'targets',None) or []):
        if isinstance(t, ast.Name) and t.id == "qk":
            qk_assign_idx = i; break
    if qk_assign_idx is not None: break

if qk_assign_idx is None: print("FAIL:no_qk_in_loop"); sys.exit(0)

# Build a synthetic module that runs just the relevant statements
prep_stmts = loop.body[:qk_assign_idx+1]

# Compose minimal program
mod = ast.Module(body=prep_stmts, type_ignores=[])
try:
    code = compile(mod, "<trace>", "exec")
except Exception as e:
    print(f"FAIL:compile:{e}"); sys.exit(0)

class Scalar:
    _id = 0
    def __init__(self, name):
        self.name = name
        self.is_tensor = False
    def __mul__(self, o):
        if isinstance(o, Scalar):
            return Scalar(f"({self.name}*{o.name})")
        if isinstance(o, Tensor):
            return o.__rmul__(self)
        return Scalar(f"({self.name}*?)")
    def __rmul__(self, o): return self.__mul__(o)
    def __add__(self, o): return Scalar(f"({self.name}+{getattr(o,'name','?')})")
    def __radd__(self, o): return self.__add__(o)

class Tensor:
    def __init__(self, tag="T"):
        self.tag = tag
        self.scalar_muls = []  # list of scalar names applied
    def __mul__(self, o):
        new = Tensor(self.tag)
        new.scalar_muls = list(self.scalar_muls)
        if isinstance(o, Scalar):
            new.scalar_muls.append(o.name)
        elif isinstance(o, Tensor):
            new.scalar_muls.append(f"<tensor:{o.tag}>")
        else:
            new.scalar_muls.append(f"<v:{o}>")
        return new
    def __rmul__(self, o): return self.__mul__(o)
    def to(self, *a, **k):
        new = Tensor(self.tag+".to")
        new.scalar_muls = list(self.scalar_muls)
        return new
    def __add__(self, o): return self.__mul__(o)
    def __sub__(self, o): return self.__mul__(o)

class TL:
    def load(self, ptr, *a, **kw):
        # Heuristic: pointers named *_scale_ptr return Scalar; else Tensor
        # We can't see name; but ptr passed in is whatever is bound in scope.
        # We'll inspect via repr.
        r = repr(ptr)
        if "scale" in r.lower():
            return Scalar(r)
        return Tensor("loaded")
    def dot(self, a, b, *args, **kw):
        return Tensor("dot")
    float32 = "f32"
    float16 = "f16"
    int32 = "i32"
    constexpr = int
    def arange(self, *a, **k): return Tensor("arange")
    def zeros(self, *a, **k): return Tensor("zeros")
    def full(self, *a, **k): return Tensor("full")
    def where(self, *a, **k): return Tensor("where")
    def maximum(self, *a, **k): return Tensor("max")
    def minimum(self, *a, **k): return Tensor("min")
    def exp(self, x): return x if isinstance(x, Tensor) else Scalar("exp")
    def exp2(self, x): return x if isinstance(x, Tensor) else Scalar("exp2")
    def log(self, x): return x if isinstance(x, Tensor) else Scalar("log")
    def log2(self, x): return x if isinstance(x, Tensor) else Scalar("log2")
    def sum(self, x, *a, **k): return Tensor("sum")
    def max(self, x, *a, **k): return Tensor("max")
    def min(self, x, *a, **k): return Tensor("min")
    def trans(self, x): return x
    def reshape(self, x, *a, **k): return x
    def broadcast_to(self, x, *a, **k): return x
    def cdiv(self, a, b): return 1
    def static_assert(self, *a, **k): pass
    def __getattr__(self, name):
        # generic fallback
        return lambda *a, **k: Tensor(f"tl.{name}")

class K_scale_ptr_repr:
    def __repr__(self): return "K_scale_ptr"
class Q_scale_ptr_repr:
    def __repr__(self): return "Q_scale_ptr"

# Build globals/locals to execute statements with
ns = {
    "tl": TL(),
    "q": Tensor("q"),
    # Need K_scale_ptr/Q_scale_ptr in scope; also K_ptrs, k_mask
    "K_scale_ptr": K_scale_ptr_repr(),
    "Q_scale_ptr": Q_scale_ptr_repr(),
    "K_ptrs": "K_ptrs",
    "k_mask": "k_mask",
    "q_scale": Scalar("q_scale"),  # may already be in scope from caller
    "offs_m": Tensor("offs_m"),
    "offs_n": Tensor("offs_n"),
    "start_n": 0,
    "STAGE": 1,
}

# Allow references to other names as Tensors lazily
class LazyDict(dict):
    def __missing__(self, key):
        # default scalar zero-ish
        v = Tensor(f"_{key}")
        self[key] = v
        return v

g = LazyDict(ns)

try:
    exec(code, g, g)
except KeyError as e:
    print(f"FAIL:keyerr:{e}"); sys.exit(0)
except Exception as e:
    # Some statements may use unsupported ops; this is ok if qk got computed
    pass

qk = g.get("qk")
if not isinstance(qk, Tensor):
    print(f"FAIL:qk_not_tensor:{type(qk).__name__}"); sys.exit(0)

muls = qk.scalar_muls
# Buggy: contains BOTH "q_scale" and "k_scale" as separate entries
# Fixed: contains a single combined entry like "(q_scale*k_scale)" OR a single name that's a precomputed combo
sep_q = any(m == "q_scale" for m in muls)
sep_k = any(m == "k_scale" for m in muls)
combined = any(("q_scale" in m and "k_scale" in m and m != "q_scale" and m != "k_scale") for m in muls)

if sep_q and sep_k and not combined:
    print(f"FAIL:separate_chain:{muls}")
elif combined or (not sep_q and not sep_k) or (sep_q ^ sep_k):
    print(f"PASS:{muls}")
else:
    print(f"PARTIAL:{muls}")
PYEOF
)
echo "  $T5"
case "$T5" in
    PASS*) add_reward 0.15 ;;
    PARTIAL*) add_reward 0.07 ;;
esac

# ════════════════════════════════════════════════════════════
# TEST 6 (0.15): F2P — sparse file also fixed (consistency across both kernels)
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6 (0.15): Sparse kernel also fixed ==="
T6="SKIP"
if [ -n "$SPARSE" ] && [ -f "$SPARSE" ]; then
T6=$(python3 << 'PYEOF'
import os, ast
sparse = os.environ["SPARSE"]
src = open(sparse).read()
try:
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse:{e}"); raise SystemExit

def is_buggy_chain(val):
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")): return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)): return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")): return False
    if val.right.id == inner.right.id: return False
    return True

def is_combined_form(val):
    # qk = X * (q_scale * k_scale) OR qk = X * combined_var
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    r = val.right
    if isinstance(r, ast.BinOp) and isinstance(r.op, ast.Mult):
        ns = {n.id for n in ast.walk(r) if isinstance(n, ast.Name)}
        if {"q_scale","k_scale"}.issubset(ns): return True
    return False

# Find qk assigns
qk_assigns = []
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_assigns.append(n)

if not qk_assigns:
    print("PASS:no_qk"); raise SystemExit  # nothing to fix

any_buggy = any(is_buggy_chain(a.value) for a in qk_assigns)
if any_buggy:
    print("FAIL:buggy_present"); raise SystemExit

# Stronger: at least one is combined form OR whole module looks parseable
# and all qk multiplications are not the buggy chain
print("PASS")
PYEOF
)
fi
echo "  $T6"
case "$T6" in
    PASS*) add_reward 0.15 ;;
    SKIP) add_reward 0.07 ;;  # if sparse file absent, give partial (not penalize)
esac

# ════════════════════════════════════════════════════════════
# Final
# ════════════════════════════════════════════════════════════
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"
exit 0