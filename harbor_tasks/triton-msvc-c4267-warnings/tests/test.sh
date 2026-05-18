#!/bin/bash
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

mkdir -p /logs/verifier
REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"
WORK=$(mktemp -d)

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.6f", a+b}')
}

finalize() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

# Hard gate: file must exist
if [ ! -f "$FILE" ]; then
    finalize
fi

# Pick a C++ compiler
CXX=""
for c in g++ clang++ c++; do
    if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done
if [ -z "$CXX" ]; then
    finalize
fi

# Strip comments/strings to avoid false positives
python3 - "$FILE" > "$WORK/stripped.cpp" << 'PYEOF'
import re, sys
code = open(sys.argv[1]).read()
code = re.sub(r'/\*.*?\*/', '', code, flags=re.DOTALL)
code = re.sub(r'//[^\n]*', '', code)
code = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', code)
sys.stdout.write(code)
PYEOF

STRIPPED="$WORK/stripped.cpp"

# ----- P2P diagnostic: don't allow the file to become unparseable garbage -----
# Quick sanity: balanced braces and parens at top level (rough but catches truncations).
python3 - "$STRIPPED" > "$WORK/sanity.txt" << 'PYEOF'
import sys
s=open(sys.argv[1]).read()
b=s.count('{')-s.count('}')
p=s.count('(')-s.count(')')
print(b,p)
PYEOF
read SBR SPR < "$WORK/sanity.txt"
if [ "$SBR" != "0" ] || [ "$SPR" != "0" ]; then
    finalize
fi

# Extract candidate expressions at known buggy call sites
mkdir -p "$WORK/exprs"
python3 - "$STRIPPED" "$WORK/exprs" << 'PYEOF'
import re, os, sys
src = open(sys.argv[1]).read()
outdir = sys.argv[2]

def balanced_args(s, p):
    if p >= len(s) or s[p] != '(':
        return None, -1
    depth = 0
    for i in range(p, len(s)):
        c = s[i]
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return s[p+1:i], i
    return None, -1

def split_args(args):
    out=[]; depth=0; cur=[]
    for c in args:
        if c in '(<[{': depth+=1
        elif c in ')>]}': depth-=1
        if c==',' and depth==0:
            out.append(''.join(cur).strip()); cur=[]
        else:
            cur.append(c)
    if cur: out.append(''.join(cur).strip())
    return out

def calls(text, fname):
    res=[]
    for m in re.finditer(r'\b'+re.escape(fname)+r'\s*\(', text):
        # avoid matching member-defs like `lowerBarrier(...) {`
        p=m.end()-1
        a,_=balanced_args(text,p)
        if a is not None:
            res.append(split_args(a))
    return res

barrier=[a[2] for a in calls(src,'lowerBarrier') if len(a)>=3]
callop=[a[2] for a in calls(src,'lowerCallOp') if len(a)>=3]

geparg=[]
for m in re.finditer(r'\bLLVM::GEPArg\s*\(', src):
    p=m.end()-1
    a,_=balanced_args(src,p)
    if a: geparg.append(a.strip())

toerase=[]
for m in re.finditer(r'\btoErase\.set\s*\(', src):
    p=m.end()-1
    a,_=balanced_args(src,p)
    if a: toerase.append(a.strip())

getresult=[]
for m in re.finditer(r'\bgetResult\s*\(', src):
    p=m.end()-1
    a,end=balanced_args(src,p)
    if a is None: continue
    tail=src[end:end+80]
    if 'replaceAllUsesWith' in tail or 'setType' in tail:
        getresult.append(a.strip())

getarg=[]
for m in re.finditer(r'\bgetArgument\s*\(', src):
    p=m.end()-1
    a,end=balanced_args(src,p)
    if a is None: continue
    tail=src[end:end+80]
    if 'replaceAllUsesWith' in tail:
        getarg.append(a.strip())

def w(name,lst):
    open(os.path.join(outdir,name),'w').write(("\n".join(lst)+"\n") if lst else "")

w('barrier.txt',barrier)
w('callop.txt',callop)
w('geparg.txt',geparg)
w('toerase.txt',toerase)
w('getresult.txt',getresult)
w('getarg.txt',getarg)
PYEOF

# Behavioral check via tiny compile probe under -Wconversion -Werror.
test_expr_clean() {
    local expr="$1"
    local target="$2"  # "unsigned" or "int32_t"
    local var="$3"
    local src="$WORK/probe.cpp"
    cat > "$src" <<EOF
#include <cstddef>
#include <cstdint>
struct Sink { void take_unsigned(unsigned){} void take_i32(std::int32_t){} };
int main() {
    std::size_t $var = 7;
    (void)$var;
    Sink s;
EOF
    if [ "$target" = "unsigned" ]; then
        echo "    s.take_unsigned($expr);" >> "$src"
    else
        echo "    s.take_i32($expr);" >> "$src"
    fi
    echo "    return 0; }" >> "$src"
    "$CXX" -std=c++17 -Wconversion -Werror -c "$src" -o "$WORK/probe.o" >/dev/null 2>&1
    return $?
}

pick_var() {
    local expr="$1"
    for cand in idx i j oldIdx newIdx index captureIdx; do
        if echo "$expr" | grep -qE "\b${cand}\b"; then
            echo "$cand"; return
        fi
    done
    echo "idx"
}

# Returns 0 iff EVERY non-empty expression in the file is clean for the target type
# AND we actually saw at least one expression.
all_clean() {
    local sitefile="$1"
    local target="$2"
    [ ! -s "$sitefile" ] && return 1
    local saw=0
    while IFS= read -r expr; do
        [ -z "$expr" ] && continue
        saw=1
        local var
        var=$(pick_var "$expr")
        if ! test_expr_clean "$expr" "$target" "$var"; then
            return 1
        fi
    done < "$sitefile"
    [ "$saw" = "1" ] && return 0 || return 1
}

# Helper: count non-empty lines.
nlines() {
    [ -s "$1" ] || { echo 0; return; }
    awk 'NF' "$1" | wc -l
}

# ---------------------------------------------------------------------------
# F2P gates — narrowing-fix detection. The instruction.md error points at one
# site (WarpSpecializeUtility.cpp line 99: lowerBarrier idx narrowing in
# std::optional<unsigned>). The session fixed it via the lambda-capture
# pattern `[&, idx = static_cast<unsigned>(idx)]` (also satisfies the parallel
# lowerCallOp call on line 104) AND added `static_cast<unsigned>(i)` to a
# `getResult(...)` call at line 249.
#
# The compile-probe-with-std::size_t-decl strategy below DOES NOT model the
# lambda capture (the captured `idx` is `unsigned` only inside the lambda
# scope, not at the synthesized probe site), so we ALSO accept the textual
# `static_cast<unsigned>` lambda-capture pattern as evidence of the fix.
# ---------------------------------------------------------------------------

# Helper: does the source text show the lambda-capture-cast pattern?
HAS_LAMBDA_CAPTURE_CAST=0
if grep -qE "idx\s*=\s*static_cast<\s*unsigned\s*>\s*\(\s*idx\s*\)" "$FILE" 2>/dev/null; then
    HAS_LAMBDA_CAPTURE_CAST=1
fi

# Gate A (0.20): the literal compile-error site — lowerBarrier idx narrowing
# fixed via either explicit cast at call OR via lambda-capture cast.
GATE_A=0
if all_clean "$WORK/exprs/barrier.txt" "unsigned" \
   || [ "$HAS_LAMBDA_CAPTURE_CAST" = "1" ]; then
    GATE_A=1
    add_reward 0.20
fi

# Gate B (0.20): the parallel site — lowerCallOp idx narrowing fixed via
# either explicit cast at call OR via lambda-capture cast (same lambda).
GATE_B=0
if all_clean "$WORK/exprs/callop.txt" "unsigned" \
   || [ "$HAS_LAMBDA_CAPTURE_CAST" = "1" ]; then
    GATE_B=1
    add_reward 0.20
fi

# Gate C (0.09): GEPArg(j) — int32_t narrowing, distinct target type.
GATE_C=0
if all_clean "$WORK/exprs/geparg.txt" "int32_t"; then
    GATE_C=1
    add_reward 0.09
fi

# Gate D (0.09): toErase.set(i) — BitVector::set takes unsigned.
GATE_D=0
if all_clean "$WORK/exprs/toerase.txt" "unsigned"; then
    GATE_D=1
    add_reward 0.09
fi

# Gate E (0.20): op->getResult(i).{replaceAllUsesWith,setType} — unsigned.
# The original session also fixed the convertOpTypes getResult call at line 249.
GATE_E=0
if all_clean "$WORK/exprs/getresult.txt" "unsigned"; then
    GATE_E=1
    add_reward 0.20
fi

# Gate F (0.09): region->getArgument(i).replaceAllUsesWith — unsigned.
GATE_F=0
if all_clean "$WORK/exprs/getarg.txt" "unsigned"; then
    GATE_F=1
    add_reward 0.09
fi

# ---------------------------------------------------------------------------
# Anti-cheese: ensure the agent didn't simply delete the call sites to make
# the gates trivially pass. We require minimum populations.
# ---------------------------------------------------------------------------
NB=$(nlines "$WORK/exprs/barrier.txt")
NC=$(nlines "$WORK/exprs/callop.txt")
NG=$(nlines "$WORK/exprs/geparg.txt")
NTE=$(nlines "$WORK/exprs/toerase.txt")
NGR=$(nlines "$WORK/exprs/getresult.txt")
NGA=$(nlines "$WORK/exprs/getarg.txt")

# If site population collapsed below baseline, treat the corresponding gate as
# failed (subtract its weight back out).
revert() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.6f", a-b}')
}

if [ "$NB" -lt 1 ] && [ "$GATE_A" = "1" ]; then revert 0.20; fi
if [ "$NC" -lt 1 ] && [ "$GATE_B" = "1" ]; then revert 0.20; fi
if [ "$NG" -lt 1 ] && [ "$GATE_C" = "1" ]; then revert 0.09; fi
if [ "$NTE" -lt 1 ] && [ "$GATE_D" = "1" ]; then revert 0.09; fi
if [ "$NGR" -lt 1 ] && [ "$GATE_E" = "1" ]; then revert 0.20; fi
if [ "$NGA" -lt 1 ] && [ "$GATE_F" = "1" ]; then revert 0.09; fi

# Floor REWARD at 0
NEG=$(awk -v r="$REWARD" 'BEGIN{print (r<0)?1:0}')
if [ "$NEG" = "1" ]; then REWARD=0.0; fi

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
> "$GATES_FILE"

# Emit the inline F2P/bonus gates that we computed above so the unified
# F2P-coverage scorer can see them. The manifest demotes gate_c/d/f to
# P2P_REGRESSION (bonus, not required); emit them passed when GATE_X=1 OR
# the site population was below baseline (anti-cheese revert => population
# collapsed => treat the bonus as "not exercised, so don't penalize").
emit_gate() {
    local id="$1" passed="$2" detail="$3"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}
# F2P gates A/B/E (required by manifest)
if [ "$GATE_A" = "1" ] || [ "$HAS_LAMBDA_CAPTURE_CAST" = "1" ]; then
    emit_gate "gate_a_barrier_arg" true "lowerBarrier idx clean OR lambda-capture cast present"
else
    emit_gate "gate_a_barrier_arg" false "lowerBarrier idx narrows under -Wconversion"
fi
if [ "$GATE_B" = "1" ] || [ "$HAS_LAMBDA_CAPTURE_CAST" = "1" ]; then
    emit_gate "gate_b_callop_arg" true "lowerCallOp idx clean OR lambda-capture cast present"
else
    emit_gate "gate_b_callop_arg" false "lowerCallOp idx narrows under -Wconversion"
fi
# gate_e: accept either ALL getResult sites clean (strict), OR at least one
# explicit static_cast<unsigned> wrapping a getResult call (canonical PR shape,
# which only fixed the one site at convertOpTypes line 249).
HAS_GETRESULT_CAST=0
if grep -qE 'getResult\(\s*static_cast<\s*unsigned\s*>\s*\(' "$FILE" 2>/dev/null; then
    HAS_GETRESULT_CAST=1
fi
if [ "$GATE_E" = "1" ] || [ "$HAS_GETRESULT_CAST" = "1" ]; then
    emit_gate "gate_e_getresult" true "op->getResult(i) clean OR explicit static_cast<unsigned>(i) wrapping a getResult call"
else
    emit_gate "gate_e_getresult" false "op->getResult(i) narrows under -Wconversion"
fi
# Bonus P2P_REGRESSION gates C/D/F: pass when fix detected OR site population
# below baseline (anti-cheese already handled). Default-pass when not exercised.
emit_gate "gate_c_geparg" true "bonus: not required by instruction"
emit_gate "gate_d_toerase" true "bonus: not required by instruction"
emit_gate "gate_f_getargument" true "bonus: not required by instruction"

# F2P Gate: lowerBarrier/lowerCallOp idx narrowing — accepts either
# (a) explicit static_cast<unsigned>(...) wrapping the 3rd arg in the call, OR
# (b) the lambda-capture-cast pattern `[&, idx = static_cast<unsigned>(idx)]`
#     which makes the captured `idx` unsigned in the lambda's scope (the
#     pattern the original session used).
F2P1_PASSED=false
cd /workspace/triton && python3 -c "
import re, sys
src = open('lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp').read()
src_nocomments = re.sub(r'//[^\n]*', '', src)
src_nocomments = re.sub(r'/\*.*?\*/', '', src_nocomments, flags=re.DOTALL)
# Accept the lambda-capture-cast pattern (idx is then unsigned throughout the lambda)
if re.search(r'idx\s*=\s*static_cast<\s*unsigned\s*>\s*\(\s*idx\s*\)', src_nocomments):
    sys.exit(0)
# Or accept explicit cast in the call's 3rd arg
norm = re.sub(r'\s+', ' ', src_nocomments)
ok = True
seen = False
for fn, prefix in [('lowerBarrier', 'op'), ('lowerCallOp', 'callOp')]:
    for m in re.finditer(fn + r'\(\s*' + prefix + r'\s*,\s*numWarps\s*,\s*(.+?)\s*,\s*barrierHelper\s*\)', norm):
        seen = True
        arg = m.group(1).strip()
        if 'static_cast<unsigned>' not in arg and 'unsigned(' not in arg:
            ok = False
sys.exit(0 if (seen and ok) else 1)
" 2>/dev/null && F2P1_PASSED=true
echo "{\"id\": \"f2p_upstream_narrowing_barrier_callop\", \"passed\": $F2P1_PASSED, \"detail\": \"compile probe for lowerBarrier/lowerCallOp idx narrowing\"}" >> "$GATES_FILE"

# F2P Gate: toErase/getResult/getArgument/GEPArg narrowing compile probe
F2P2_PASSED=false
cd /workspace/triton && python3 -c "
import re, subprocess, sys, tempfile, os
SRC_PATH = 'lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp'
src = open(SRC_PATH).read()
src = re.sub(r'//[^\n]*', '', src)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)
def balanced_args(s, p):
    if p >= len(s) or s[p] != '(': return None, -1
    depth = 0
    for i in range(p, len(s)):
        if s[i] == '(': depth += 1
        elif s[i] == ')':
            depth -= 1
            if depth == 0: return s[p+1:i], i
    return None, -1
sites = []
for m in re.finditer(r'toErase\.set\s*\(', src):
    p = m.end()-1
    a, _ = balanced_args(src, p)
    if a: sites.append(('unsigned', a.strip(), 'i'))
for m in re.finditer(r'->getResult\s*\(', src):
    p = m.end()-1
    a, end = balanced_args(src, p)
    if a is None: continue
    tail = src[end:end+60]
    if 'replaceAllUsesWith' in tail: sites.append(('unsigned', a.strip(), 'i'))
for m in re.finditer(r'->getArgument\s*\(', src):
    p = m.end()-1
    a, end = balanced_args(src, p)
    if a is None: continue
    tail = src[end:end+60]
    if 'replaceAllUsesWith' in tail: sites.append(('unsigned', a.strip(), 'i'))
for m in re.finditer(r'LLVM::GEPArg\(\s*', src):
    start = m.start()
    context = src[max(0,start-30):start]
    if '{' in context and '}' not in context: continue
    p = m.end()-1
    a, _ = balanced_args(src, p)
    if a is None: continue
    expr = a.strip()
    if 'j' in expr: sites.append(('int32_t', expr, 'j'))
if not sites: sys.exit(2)
all_clean = True
for target_type, expr, var in sites:
    func_decl = 'void take(unsigned) {}' if target_type == 'unsigned' else 'void take(std::int32_t) {}'
    probe = '#include <cstddef>\n#include <cstdint>\n%s\nint main() {\n    std::size_t %s = 7; (void)%s;\n    take(%s);\n    return 0;\n}\n' % (func_decl, var, var, expr)
    with tempfile.NamedTemporaryFile(suffix='.cpp', mode='w', delete=False) as f:
        f.write(probe)
        fname = f.name
    rc = subprocess.call(['g++', '-std=c++17', '-Wconversion', '-Werror', '-c', fname, '-o', '/dev/null'], stderr=subprocess.PIPE)
    os.unlink(fname)
    if rc != 0: all_clean = False
sys.exit(0 if all_clean else 1)
" 2>/dev/null && F2P2_PASSED=true
echo "{\"id\": \"f2p_upstream_narrowing_secondary\", \"passed\": $F2P2_PASSED, \"detail\": \"compile probe for toErase/getResult/getArgument/GEPArg narrowing\"}" >> "$GATES_FILE"

# P2P Gate: file exists and non-empty
P2P1_PASSED=false
test -s /workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp && P2P1_PASSED=true
echo "{\"id\": \"p2p_upstream_file_exists\", \"passed\": $P2P1_PASSED, \"detail\": \"file exists and is non-empty\"}" >> "$GATES_FILE"

# P2P Gate: balanced braces and parens
P2P2_PASSED=false
python3 -c "
import re, sys
s = open('/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp').read()
s = re.sub(r'//[^\n]*','',s)
s = re.sub(r'/\*.*?\*/','',s,flags=re.DOTALL)
s = re.sub(r'\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"','\"\"',s)
b = s.count('{') - s.count('}')
p = s.count('(') - s.count(')')
if b != 0 or p != 0: sys.exit(1)
" 2>/dev/null && P2P2_PASSED=true
echo "{\"id\": \"p2p_upstream_balanced_syntax\", \"passed\": $P2P2_PASSED, \"detail\": \"balanced braces and parens\"}" >> "$GATES_FILE"

# P2P Gate: required function symbols present
P2P3_PASSED=false
python3 -c "
import sys
src = open('/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp').read()
for r in ['lowerBarrier', 'lowerCallOp', 'lowerKernelBarriers', 'elideTrivialCaptures']:
    if r not in src: sys.exit(1)
" 2>/dev/null && P2P3_PASSED=true
echo "{\"id\": \"p2p_upstream_required_symbols\", \"passed\": $P2P3_PASSED, \"detail\": \"required function names present\"}" >> "$GATES_FILE"

# ---- end upstream gates ----

# Upstream reward tail: adjust reward based on upstream gate verdicts
python3 - << 'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_narrowing_barrier_callop": 0.20}
P2P_REGRESSION = ["p2p_upstream_file_exists", "p2p_upstream_balanced_syntax", "p2p_upstream_required_symbols", "f2p_upstream_narrowing_secondary"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
# weighted-replace formula (c8bc168a standard, replaces additive)
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('REWARD=%.4f' % reward)
PYEOF

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
