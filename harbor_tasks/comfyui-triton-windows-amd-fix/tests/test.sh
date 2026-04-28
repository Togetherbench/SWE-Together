#!/bin/bash
set +e

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

GATES_FILE=/logs/verifier/gates.json
REWARD_FILE=/logs/verifier/reward.txt
mkdir -p "$(dirname "$GATES_FILE")"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
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
    emit p2p_structure_intact false "target not found"
    emit t1_f2p_target_remediated false "no target"
    emit t1_f2p_sparse_remediated false "no target"
    emit t1_f2p_no_buggy_pair false "no target"
    emit t1_f2p_scale_factor_preserved false "no target"
    printf "%.4f\n" 0 > "$REWARD_FILE"
    exit 0
fi

export TARGET SPARSE

# ════════════════════════════════════════════════════════════
# P2P_GATING: parse + structural sanity
# ════════════════════════════════════════════════════════════
P2P_RES=$(python3 << 'PYEOF'
import os, ast, sys
target = os.environ["TARGET"]
sparse = os.environ.get("SPARSE","")
try:
    src = open(target).read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
need = {"_attn_fwd_inner", "_attn_fwd", "forward"}
missing = need - set(funcs.keys())
if missing:
    print(f"FAIL:missing:{missing}"); sys.exit(0)

# Reject empty stubs: each required function must have >2 statements
# and _attn_fwd_inner must contain a tl.dot call and a qk assignment.
for name in need:
    fn = funcs[name]
    if len(fn.body) < 2:
        print(f"FAIL:stub:{name}"); sys.exit(0)

inner = funcs["_attn_fwd_inner"]
inner_src = ast.unparse(inner) if hasattr(ast, "unparse") else open(target).read()
if "tl.dot" not in inner_src:
    print("FAIL:no_tl_dot_in_inner"); sys.exit(0)
has_qk = any(
    isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "qk" for t in n.targets)
    for n in ast.walk(inner)
)
if not has_qk:
    print("FAIL:no_qk_assign"); sys.exit(0)

if sparse and os.path.isfile(sparse):
    try:
        ast.parse(open(sparse).read())
    except Exception as e:
        print(f"FAIL:parse_sparse:{e}"); sys.exit(0)
print("PASS")
PYEOF
)
if [ "$P2P_RES" = "PASS" ]; then
    emit p2p_structure_intact true ""
else
    emit p2p_structure_intact false "$P2P_RES"
    # Hard zero
    printf "%.4f\n" 0 > "$REWARD_FILE"
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
run_v043_gate p2p_upstream_518584f9 'py_compile_changed_generic' 'cd /workspace/ComfyUI && cd /workspace && python3 -m py_compile /workspace/ComfyUI/ultravico/sageattn/attn_qk_int8_per_block.py /workspace/ComfyUI/wanvideo/radial_attention/sparse_sage/sparse_int8_attn.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_no_buggy_pair": 0.25, "t1_f2p_scale_factor_preserved": 0.15, "t1_f2p_sparse_remediated": 0.25, "t1_f2p_target_remediated": 0.35}
P2P_GATING = ["p2p_structure_intact"]
P2P_REGRESSION = ["p2p_upstream_518584f9"]
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
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
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
fi

# ════════════════════════════════════════════════════════════
# Helper: for a given file, classify what remediation was applied.
# Returns a string describing categories found:
#   ARANGE_LOAD   -- scale load uses tl.arange or +offset indexing
#   FLOAT_CAST    -- .to(tl.float32) added on a scale load
#   SPLIT_CHAIN   -- chained `*q_scale*k_scale` replaced by split/parenthesized/helper form
# A file is "remediated" if at least one category is detected AND
# the buggy verbatim pair is no longer present.
# ════════════════════════════════════════════════════════════
classify_file() {
    local f="$1"
    python3 - "$f" << 'PYEOF'
import sys, ast, re
path = sys.argv[1]
src = open(path).read()

# Detect categories using a mix of regex + AST.
cats = []

# (a) ARANGE_LOAD: tl.load on K_scale with arange/offset indexing
#     e.g. tl.load(K_scale_ptr + tl.arange(0, 1)), or tl.load(K_scale_ptr + start_n//BLOCK_N), etc.
if re.search(r"tl\.load\(\s*K_scale_ptr\s*\+", src):
    cats.append("ARANGE_LOAD")

# (b) FLOAT_CAST: a scale load (or k_scale variable) explicitly cast to float32
#     e.g. tl.load(K_scale_ptr).to(tl.float32) or k_scale.to(tl.float32) or tl.load(...).to(tl.float32)
if re.search(r"tl\.load\(\s*K_scale_ptr[^)]*\)\s*\.to\(\s*tl\.float32", src):
    cats.append("FLOAT_CAST")
if re.search(r"\bk_scale\s*=\s*tl\.load\([^)]*\)\.to\(\s*tl\.float32", src):
    cats.append("FLOAT_CAST")
# Also: cast on the qk side that was added
if re.search(r"k_scale\.to\(\s*tl\.float32", src):
    cats.append("FLOAT_CAST")

# (c) SPLIT_CHAIN: detect via AST that no qk assignment uses the
#     buggy chained `* q_scale * k_scale` form anymore.
try:
    tree = ast.parse(src)
except Exception:
    print("PARSE_FAIL"); sys.exit(0)

def is_chained(val):
    # BinOp(BinOp(_, Mult, Name(q_scale|k_scale)), Mult, Name(k_scale|q_scale))
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")): return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)): return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")): return False
    if val.right.id == inner.right.id: return False
    return True

found_chained = False
qk_count = 0
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_count += 1
                if is_chained(n.value):
                    found_chained = True

if qk_count > 0 and not found_chained:
    cats.append("SPLIT_CHAIN")

# Output cats
print(",".join(sorted(set(cats))) if cats else "NONE")
PYEOF
}

# ════════════════════════════════════════════════════════════
# F2P 1 (0.35): TARGET remediated (any acceptable category present)
# Buggy base: cats=NONE -> FAIL.
# ════════════════════════════════════════════════════════════
TARGET_CATS=$(classify_file "$TARGET")
echo "TARGET_CATS=$TARGET_CATS"
if [ -n "$TARGET_CATS" ] && [ "$TARGET_CATS" != "NONE" ] && [ "$TARGET_CATS" != "PARSE_FAIL" ]; then
    emit t1_f2p_target_remediated true "$TARGET_CATS"
    T1_PASS=1
else
    emit t1_f2p_target_remediated false "no remediation category detected"
    T1_PASS=0
fi

# ════════════════════════════════════════════════════════════
# F2P 2 (0.25): SPARSE remediated similarly
# ════════════════════════════════════════════════════════════
if [ -n "$SPARSE" ] && [ -f "$SPARSE" ]; then
    SPARSE_CATS=$(classify_file "$SPARSE")
    echo "SPARSE_CATS=$SPARSE_CATS"
    if [ -n "$SPARSE_CATS" ] && [ "$SPARSE_CATS" != "NONE" ] && [ "$SPARSE_CATS" != "PARSE_FAIL" ]; then
        emit t1_f2p_sparse_remediated true "$SPARSE_CATS"
    else
        emit t1_f2p_sparse_remediated false "no remediation in sparse"
    fi
else
    emit t1_f2p_sparse_remediated false "sparse file absent"
fi

# ════════════════════════════════════════════════════════════
# F2P 3 (0.25): The exact buggy pair is NOT BOTH present.
#   Buggy pair = (a) bare scalar `tl.load(K_scale_ptr)` with no
#   arange/offset/cast, AND (b) chained `* q_scale * k_scale`.
# Buggy base satisfies BOTH -> gate FAILS on no-op.
# ANY of the three remediation categories breaks the pair.
# ════════════════════════════════════════════════════════════
NO_BUGGY=$(python3 - "$TARGET" << 'PYEOF'
import sys, ast, re
path = sys.argv[1]
src = open(path).read()

# (a) Is the BARE scalar load still present?
#     bare = tl.load(K_scale_ptr) without `+`, without `.to(tl.float32)` chain
bare_pattern = re.compile(r"tl\.load\(\s*K_scale_ptr\s*\)(?!\s*\.to\(\s*tl\.float32)")
has_bare = bool(bare_pattern.search(src))

# (b) Is the chained qk multiplication still present (any qk assign)?
try:
    tree = ast.parse(src)
except Exception:
    print("PARSE_FAIL"); sys.exit(0)

def is_chained(val):
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")): return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)): return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")): return False
    if val.right.id == inner.right.id: return False
    return True

has_chained = False
for n in ast.walk(tree):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                if is_chained(n.value):
                    has_chained = True

if has_bare and has_chained:
    print(f"FAIL:both_present")
else:
    print(f"PASS:bare={has_bare},chained={has_chained}")
PYEOF
)
echo "NO_BUGGY=$NO_BUGGY"
case "$NO_BUGGY" in
    PASS*) emit t1_f2p_no_buggy_pair true "${NO_BUGGY#PASS:}" ;;
    *)     emit t1_f2p_no_buggy_pair false "$NO_BUGGY" ;;
esac

# ════════════════════════════════════════════════════════════
# F2P 4 (0.15): After fix, qk expression must STILL transitively
# reference both q_scale and k_scale (rejects deletion-style edits)
# AND the gate t1_f2p_no_buggy_pair must be passing — otherwise
# the buggy state would also satisfy this trivially.
# So we gate-on no-buggy-pair: if buggy pair still there, fail.
# ════════════════════════════════════════════════════════════
SCALE_OK=$(python3 - "$TARGET" << 'PYEOF'
import sys, ast, re
path = sys.argv[1]
src = open(path).read()

# Pre-check: must have already moved off the buggy pair, otherwise
# the trivial buggy expression `dot*q_scale*k_scale` would pass.
bare_pattern = re.compile(r"tl\.load\(\s*K_scale_ptr\s*\)(?!\s*\.to\(\s*tl\.float32)")
has_bare = bool(bare_pattern.search(src))

try:
    tree = ast.parse(src)
except Exception:
    print("FAIL:parse"); sys.exit(0)

def is_chained(val):
    if not (isinstance(val, ast.BinOp) and isinstance(val.op, ast.Mult)): return False
    if not (isinstance(val.right, ast.Name) and val.right.id in ("k_scale","q_scale")): return False
    inner = val.left
    if not (isinstance(inner, ast.BinOp) and isinstance(inner.op, ast.Mult)): return False
    if not (isinstance(inner.right, ast.Name) and inner.right.id in ("k_scale","q_scale")): return False
    if val.right.id == inner.right.id: return False
    return True

# Find _attn_fwd_inner
inner = next((n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_attn_fwd_inner"), None)
if inner is None:
    print("FAIL:no_inner"); sys.exit(0)

# qk assigns within inner
qk_assigns = []
for n in ast.walk(inner):
    if isinstance(n, ast.Assign):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id == "qk":
                qk_assigns.append(n)

if not qk_assigns:
    print("FAIL:no_qk"); sys.exit(0)

has_chained = any(is_chained(a.value) for a in qk_assigns)

# Hard pre-gate: if the buggy-pair is intact, this gate must FAIL
# (no-op state forbidden).
if has_bare and has_chained:
    print("FAIL:buggy_pair_intact"); sys.exit(0)

# Build helper map: any assign in inner whose target is a Name and
# whose value references q_scale or k_scale (transitively).
helper_refs = {}  # name -> set of base scales referenced
def name_refs(expr):
    s = set()
    for sub in ast.walk(expr):
        if isinstance(sub, ast.Name):
            s.add(sub.id)
    return s

for n in ast.walk(inner):
    if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
        nm = n.targets[0].id
        if nm == "qk": continue
        refs = name_refs(n.value)
        helper_refs.setdefault(nm, set()).update(refs)

# Resolve transitive: for each name in qk RHS, walk helper map up to depth 5
def resolve(name, depth=0, seen=None):
    if seen is None: seen = set()
    if name in seen or depth > 5: return set()
    seen.add(name)
    if name in ("q_scale", "k_scale"):
        return {name}
    out = set()
    if name in helper_refs:
        for sub in helper_refs[name]:
            out |= resolve(sub, depth+1, seen)
    return out

# Check ALL qk assigns: we need at least one whose transitive refs
# cover BOTH q_scale and k_scale. (If multiple qk assigns exist
# in a split-chain fix, kimi's pattern: qk = qk * q_scale; qk = qk * k_scale,
# we need to check the union across chained reassignments.)
# We do this by accumulating refs across all qk assigns in inner.
total_refs = set()
for a in qk_assigns:
    for nm in name_refs(a.value):
        total_refs |= resolve(nm)

has_q = "q_scale" in total_refs
has_k = "k_scale" in total_refs

if has_q and has_k:
    print(f"PASS:q={has_q},k={has_k}")
else:
    print(f"FAIL:q={has_q},k={has_k}")
PYEOF
)
echo "SCALE_OK=$SCALE_OK"
case "$SCALE_OK" in
    PASS*) emit t1_f2p_scale_factor_preserved true "${SCALE_OK#PASS:}" ;;
    *)     emit t1_f2p_scale_factor_preserved false "$SCALE_OK" ;;
esac

# ════════════════════════════════════════════════════════════
# Compute reward from gates.json
# F2P weights: target_remediated=0.35, sparse_remediated=0.25,
#              no_buggy_pair=0.25, scale_factor_preserved=0.15
# ════════════════════════════════════════════════════════════
REWARD=$(python3 << 'PYEOF'
import json
weights = {
    "t1_f2p_target_remediated": 0.35,
    "t1_f2p_sparse_remediated": 0.25,
    "t1_f2p_no_buggy_pair": 0.25,
    "t1_f2p_scale_factor_preserved": 0.15,
}
gating_failed = False
passed = {}
with open("/logs/verifier/gates.json") as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        gid = obj.get("id"); ok = obj.get("passed", False)
        if gid == "p2p_structure_intact" and not ok:
            gating_failed = True
        if gid in weights and ok:
            passed[gid] = weights[gid]
total = 0.0 if gating_failed else sum(passed.values())
print(f"{total:.4f}")
PYEOF
)
echo "REWARD=$REWARD"
printf "%.4f\n" "$REWARD" > "$REWARD_FILE"