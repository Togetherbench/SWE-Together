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
    echo "0.0000" > "$REWARD_FILE"
    exit 0
fi

export TARGET SPARSE

# ════════════════════════════════════════════════════════════
# P2P GATE (no reward): file still parses & has expected funcs.
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
# F2P 1 (0.20): Buggy chained scalar*tensor pattern eliminated
# in TARGET. Specifically the line
#   qk = tl.dot(q, k).to(tl.float32) * q_scale * k_scale
# This is the line called out in the AMD MLIR error. Buggy on base.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 1 (0.20): buggy chained-mult eliminated in TARGET ==="
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
[ "$F1" = "PASS" ] && add_reward 0.20

# ════════════════════════════════════════════════════════════
# F2P 2 (0.20): Same fix in SPARSE companion file (completeness).
# Buggy base has same chained pattern there.
# If file doesn't exist on this checkout: NO REWARD (penalize incomplete checkouts handled by no file).
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 2 (0.20): buggy chained-mult eliminated in SPARSE ==="
F2=$(python3 << 'PYEOF'
import os, ast, sys

sparse = os.environ.get("SPARSE","")
if not sparse or not os.path.isfile(sparse):
    print("SKIP_NOFILE"); sys.exit(0)

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
    print("FAIL:no_qk"); sys.exit(0)
for a in qk_assigns:
    if is_buggy_chain(a.value):
        print("FAIL:buggy_chain_present"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  F2=$F2"
[ "$F2" = "PASS" ] && add_reward 0.20

# ════════════════════════════════════════════════════════════
# F2P 3 (0.30): BEHAVIORAL — simulate the qk-scaling expression
# from the qk-assign in _attn_fwd_inner using a recording proxy.
#
# We build a TensorProxy that records every __mul__/__rmul__ as
# either tensor*scalar or scalar*tensor. Buggy chain
#   T * q_scale * k_scale
# yields TWO sequential tensor*scalar ops on the proxy.
# A correct fix collapses to ONE tensor*scalar, where the scalar
# operand is itself a (q_scale*k_scale) combination — i.e. only
# one tensor-scaling op is applied.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 3 (0.30): behavioral scale-multiplication trace ==="
F3=$(python3 << 'PYEOF'
import os, ast, sys

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

inner = next((n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner is None:
    print("FAIL:no_inner"); sys.exit(0)

# Find the qk = ... assignment expression (any qk assign whose RHS
# involves tl.dot or *_scale).
qk_expr = None
for n in ast.walk(inner):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                # Pick the one that contains tl.dot or references k/q_scale
                src_seg = ast.unparse(n.value) if hasattr(ast, "unparse") else ""
                if "dot" in src_seg or "scale" in src_seg:
                    qk_expr = n.value
                    break
        if qk_expr is not None:
            break

if qk_expr is None:
    print("FAIL:no_qk_expr"); sys.exit(0)

# Also collect any preceding assignments in the loop that define
# helper scale variables (e.g. `scale = q_scale * k_scale`).
helper_assigns = []
def walk_collect_helpers(node):
    for sub in ast.walk(node):
        if isinstance(sub, ast.For):
            for stmt in sub.body:
                if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 \
                   and isinstance(stmt.targets[0], ast.Name) \
                   and stmt.targets[0].id != "qk":
                    src_seg = ast.unparse(stmt.value) if hasattr(ast, "unparse") else ""
                    if "scale" in src_seg or "q_scale" in src_seg or "k_scale" in src_seg:
                        helper_assigns.append(stmt)
walk_collect_helpers(inner)

# Build proxy.
class TensorProxy:
    def __init__(self, name="T"):
        self.name = name
        self.scalar_mults = 0  # how many times a scalar was applied
    def __mul__(self, other):
        if isinstance(other, TensorProxy):
            return TensorProxy(self.name + "*" + other.name)
        # scalar * tensor
        new = TensorProxy(self.name)
        new.scalar_mults = self.scalar_mults + 1
        return new
    def __rmul__(self, other):
        return self.__mul__(other)
    def to(self, *a, **kw):
        return self
    def __add__(self, other):
        return self
    def __radd__(self, other):
        return self
    def __sub__(self, other):
        return self
    def __truediv__(self, other):
        return self

class FakeTL:
    @staticmethod
    def dot(a, b):
        return TensorProxy("dot")
    class language:
        float32 = "float32"
    float32 = "float32"
    @staticmethod
    def load(*a, **kw):
        # Returns scalar-like float
        return 1.5

ns = {
    "tl": FakeTL,
    "q": TensorProxy("q"),
    "k": TensorProxy("k"),
    "q_scale": 1.7,
    "k_scale": 2.3,
}

# Execute helper assigns first (in order)
import copy
try:
    for h in helper_assigns:
        mod = ast.Module(body=[h], type_ignores=[])
        exec(compile(mod, "<helper>", "exec"), ns)
except Exception as e:
    # Helpers might depend on things we don't have; ignore failures.
    pass

# Now evaluate the qk RHS expression
try:
    expr = ast.Expression(body=qk_expr)
    result = eval(compile(expr, "<qk>", "eval"), ns)
except Exception as e:
    print(f"FAIL:eval:{e}"); sys.exit(0)

if not isinstance(result, TensorProxy):
    print(f"FAIL:not_tensor:{type(result)}"); sys.exit(0)

# A correct fix applies the scalar to the tensor exactly ONCE.
# Buggy chain applies it TWICE.
if result.scalar_mults == 1:
    print(f"PASS:scalar_mults={result.scalar_mults}")
elif result.scalar_mults == 0:
    print(f"FAIL:no_scaling")
else:
    print(f"FAIL:chained_scalar_mults={result.scalar_mults}")
PYEOF
)
echo "  F3=$F3"
case "$F3" in
    PASS*) add_reward 0.30 ;;
esac

# ════════════════════════════════════════════════════════════
# F2P 4 (0.15): Same behavioral check on SPARSE file's qk expr.
# This rewards completeness behaviorally (not just textually).
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 4 (0.15): behavioral scale-mult trace in SPARSE ==="
F4=$(python3 << 'PYEOF'
import os, ast, sys

sparse = os.environ.get("SPARSE","")
if not sparse or not os.path.isfile(sparse):
    print("SKIP_NOFILE"); sys.exit(0)

src = open(sparse).read()
try:
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

# Find any function with a qk assign that uses *_scale
candidate_funcs = []
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef):
        for sub in ast.walk(n):
            if isinstance(sub, ast.Assign):
                for t in sub.targets:
                    if isinstance(t, ast.Name) and t.id == "qk":
                        seg = ast.unparse(sub.value) if hasattr(ast, "unparse") else ""
                        if "scale" in seg:
                            candidate_funcs.append((n, sub))

if not candidate_funcs:
    print("FAIL:no_qk_scale_assign"); sys.exit(0)

# Use the first one
fn, qk_assign = candidate_funcs[0]
qk_expr = qk_assign.value

# Collect helper scale assigns inside fn (preceding qk in source order, broadly)
helper_assigns = []
for sub in ast.walk(fn):
    if isinstance(sub, ast.Assign) and len(sub.targets) == 1 \
       and isinstance(sub.targets[0], ast.Name) \
       and sub.targets[0].id not in ("qk",):
        seg = ast.unparse(sub.value) if hasattr(ast, "unparse") else ""
        if "q_scale" in seg and "k_scale" in seg:
            helper_assigns.append(sub)

class TensorProxy:
    def __init__(self, name="T"):
        self.name = name
        self.scalar_mults = 0
    def __mul__(self, other):
        if isinstance(other, TensorProxy):
            return TensorProxy(self.name + "*" + other.name)
        new = TensorProxy(self.name)
        new.scalar_mults = self.scalar_mults + 1
        return new
    def __rmul__(self, other):
        return self.__mul__(other)
    def to(self, *a, **kw):
        return self

class FakeTL:
    @staticmethod
    def dot(a, b):
        return TensorProxy("dot")
    float32 = "float32"
    @staticmethod
    def load(*a, **kw):
        return 1.5

ns = {
    "tl": FakeTL,
    "q": TensorProxy("q"),
    "k": TensorProxy("k"),
    "q_scale": 1.7,
    "k_scale": 2.3,
}

try:
    for h in helper_assigns:
        mod = ast.Module(body=[h], type_ignores=[])
        exec(compile(mod, "<helper>", "exec"), ns)
except Exception:
    pass

try:
    expr = ast.Expression(body=qk_expr)
    result = eval(compile(expr, "<qk>", "eval"), ns)
except Exception as e:
    print(f"FAIL:eval:{e}"); sys.exit(0)

if not isinstance(result, TensorProxy):
    print(f"FAIL:not_tensor"); sys.exit(0)

if result.scalar_mults == 1:
    print(f"PASS:scalar_mults={result.scalar_mults}")
elif result.scalar_mults == 0:
    print(f"FAIL:no_scaling")
else:
    print(f"FAIL:chained_scalar_mults={result.scalar_mults}")
PYEOF
)
echo "  F4=$F4"
case "$F4" in
    PASS*) add_reward 0.15 ;;
esac

# ════════════════════════════════════════════════════════════
# F2P 5 (0.15): Combined-scale evidence — the fix should produce
# a single combined scalar applied to the tensor. We check via
# AST that the tensor*scalar product, after symbolic simplification
# of the qk RHS, multiplies the tensor by an expression that
# REFERENCES BOTH q_scale and k_scale (either directly or through
# a precomputed helper var).
#
# This rewards real fixes (parenthesized combine, helper var,
# load-once-then-multiply) and rejects "did nothing real" patches
# like fake decorators or unrelated edits.
# ════════════════════════════════════════════════════════════
echo ""
echo "=== F2P 5 (0.15): combined-scale references both q_scale and k_scale ==="
F5=$(python3 << 'PYEOF'
import os, ast, sys

target = os.environ["TARGET"]
src = open(target).read()
tree = ast.parse(src)

inner = next((n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner is None:
    print("FAIL:no_inner"); sys.exit(0)

# Find qk assign with scale references
qk_assign = None
for n in ast.walk(inner):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                seg = ast.unparse(n.value) if hasattr(ast, "unparse") else ""
                if "scale" in seg or "dot" in seg:
                    qk_assign = n
                    break
        if qk_assign is not None:
            break

if qk_assign is None:
    print("FAIL:no_qk"); sys.exit(0)

# Collect helper scale-defining assigns in inner (any assign whose value
# references q_scale or k_scale, target is a Name)
helper_defs = {}  # name -> (refs_q, refs_k)
def refs(expr, target_name):
    for sub in ast.walk(expr):
        if isinstance(sub, ast.Name) and sub.id == target_name:
            return True
    return False

for n in ast.walk(inner):
    if isinstance(n, ast.Assign) and len(n.targets) == 1 \
       and isinstance(n.targets[0], ast.Name):
        nm = n.targets[0].id
        if nm == "qk":
            continue
        rq = refs(n.value, "q_scale")
        rk = refs(n.value, "k_scale")
        if rq or rk:
            helper_defs[nm] = (rq, rk)

# Now in the qk RHS, expand all referenced names: collect all Name ids.
referenced = set()
for sub in ast.walk(qk_assign.value):
    if isinstance(sub, ast.Name):
        referenced.add(sub.id)

# Determine if the qk RHS, transitively through helpers, references both.
def transitive_refs(start_expr, helpers):
    seen_names = set()
    rq = rk = False
    stack = []
    for sub in ast.walk(start_expr):
        if isinstance(sub, ast.Name):
            stack.append(sub.id)
    while stack:
        nm = stack.pop()
        if nm in seen_names: continue
        seen_names.add(nm)
        if nm == "q_scale": rq = True
        elif nm == "k_scale": rk = True
        elif nm in helpers:
            hq, hk = helpers[nm]
            if hq: rq = True
            if hk: rk = True
            # No further expansion of helper bodies needed — we already
            # captured what helpers reference into helper_defs.
    return rq, rk

rq, rk = transitive_refs(qk_assign.value, helper_defs)

if rq and rk:
    print("PASS")
else:
    print(f"FAIL:rq={rq},rk={rk}")
PYEOF
)
echo "  F5=$F5"
[ "$F5" = "PASS" ] && add_reward 0.15

# ════════════════════════════════════════════════════════════
# Final
# ════════════════════════════════════════════════════════════
echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"