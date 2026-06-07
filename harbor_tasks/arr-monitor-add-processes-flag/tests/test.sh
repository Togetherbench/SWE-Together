#!/bin/bash
set +e

mkdir -p /logs/verifier
REPO="/workspace"
REWARD=0.0

cd "$REPO" 2>/dev/null || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

# ---- HARD GATES (P2P-style; diagnostic/penalty only, no points) ----
if [ ! -f arr-monitor.py ]; then
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

# Conflict markers => no merge happened
if grep -nE '^(<{7}|={7}|>{7})( |$)' arr-monitor.py >/dev/null 2>&1; then
  echo "Conflict markers present"
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

# File must compile
if ! python3 -m py_compile arr-monitor.py 2>/dev/null; then
  echo "py_compile failed"
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

# No-op detection: if file is byte-identical to base, score 0
BASE_COMMIT="eba91a1905745415a4f4d5a91e7e246829cda566"
if git cat-file -e "${BASE_COMMIT}:arr-monitor.py" 2>/dev/null; then
  if git diff --quiet "$BASE_COMMIT" -- arr-monitor.py 2>/dev/null; then
    echo "No changes vs base"
    echo "0.0" > /logs/verifier/reward.txt; exit 0
  fi
fi

# ============================================================
# F2P GATES (weights sum to 1000 milli-points = 1.0)
# Each tests a DIFFERENT slice of behavioral correctness:
#   G1 (0.15): IGNORE_EXTENSIONS includes .exe and .msi (merge of fix-ignore-exe-extension)
#   G2 (0.15): --add-new-processes flag visible in --help
#   G3 (0.15): flag actually parses via argparse
#   G4 (0.20): run_monitor signature accepts add_new_processes AND call site passes it
#   G5 (0.20): runtime body actually scans for new processes (find_arr_processes inside loop region influenced by flag)
#   G6 (0.15): --add-new-processes without --all errors with validation message
# ============================================================

SCORE=0

# ---- G1 (0.15): IGNORE_EXTENSIONS extended ----
G1_RES=$(python3 - <<'EOF' 2>/dev/null
import ast
try:
    src = open('/workspace/arr-monitor.py').read()
    tree = ast.parse(src)
except Exception:
    print("ERR"); raise SystemExit
found = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == 'IGNORE_EXTENSIONS':
                try:
                    found = ast.literal_eval(node.value)
                except Exception:
                    found = None
if found is None:
    print("NONE"); raise SystemExit
s = set(found)
need_new = {'.exe', '.msi'}
need_old = {'.nfo'}
ok_new = need_new.issubset(s)
ok_old = need_old.issubset(s)
if ok_new and ok_old:
    print("FULL")
elif ok_new and not ok_old:
    print("LOST_OLD")
elif ok_old and not ok_new:
    print("MISSING_NEW")
else:
    print("BROKEN")
EOF
)
case "$G1_RES" in
  FULL)        SCORE=$((SCORE + 150)) ;;
  LOST_OLD)    SCORE=$((SCORE + 60))  ;;
  MISSING_NEW) SCORE=$((SCORE + 30))  ;;
  *) ;;
esac

# ---- G2 (0.15): --help shows --add-new-processes ----
HELP_OUT=$(timeout 10 python3 arr-monitor.py --help 2>&1)
HELP_RC=$?
G2_OK=0
if [ "$HELP_RC" -eq 0 ] && echo "$HELP_OUT" | grep -q -- '--add-new-processes'; then
  G2_OK=1
  SCORE=$((SCORE + 150))
fi

# ---- G3 (0.15): flag parses (no argparse error) ----
G3_OK=0
if [ "$G2_OK" -eq 1 ]; then
  # Try without --all first; if parser.error (validation), retry with --all.
  # Use a sentinel approach: parse via argparse-only by importing module and
  # invoking parse_known_args with the flag through the script's argparse.
  PARSE_RES=$(python3 - <<'EOF' 2>/dev/null
import sys, types, runpy, importlib.util, argparse, io, contextlib
spec = importlib.util.spec_from_file_location("arrmon", "/workspace/arr-monitor.py")
mod = importlib.util.module_from_spec(spec)
# Block actual main execution by patching curses.wrapper and sys.exit paths.
# We just want argparse; many scripts only run argparse under __main__.
# Simpler: parse the AST and check action exists with correct dest.
import ast
src = open('/workspace/arr-monitor.py').read()
tree = ast.parse(src)
found = False
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        f = node.func
        is_add = (isinstance(f, ast.Attribute) and f.attr == 'add_argument')
        if not is_add:
            continue
        for a in node.args:
            if isinstance(a, ast.Constant) and isinstance(a.value, str) and a.value == '--add-new-processes':
                found = True
                break
        if found:
            break
print("OK" if found else "NO")
EOF
)
  if [ "$PARSE_RES" = "OK" ]; then
    G3_OK=1
    SCORE=$((SCORE + 150))
  fi
fi

# ---- G4 (0.20): plumbing — signature + call site ----
G4_RES=$(python3 - <<'EOF' 2>/dev/null
import ast
try:
    src = open('/workspace/arr-monitor.py').read()
    tree = ast.parse(src)
except Exception:
    print("ERR"); raise SystemExit

sig_ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'run_monitor':
        argnames = [a.arg for a in node.args.args] + [a.arg for a in node.args.kwonlyargs]
        for n in argnames:
            ln = n.lower()
            if 'new_process' in ln or 'add_new' in ln:
                sig_ok = True
                break

# Call site: must pass args.add_new_processes (or equivalent) somewhere
call_ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        # any arg that references args.add_new_processes
        for a in list(node.args) + [kw.value for kw in node.keywords]:
            try:
                code = ast.unparse(a)
            except Exception:
                code = ''
            if 'add_new_processes' in code and 'args' in code:
                call_ok = True
                break

if sig_ok and call_ok:
    print("FULL")
elif sig_ok or call_ok:
    print("PARTIAL")
else:
    print("NONE")
EOF
)
case "$G4_RES" in
  FULL)    SCORE=$((SCORE + 200)) ;;
  PARTIAL) SCORE=$((SCORE + 90))  ;;
  *) ;;
esac

# ---- G5 (0.20): runtime body scans for new processes when flag is set ----
# A real fix calls find_arr_processes() inside run_monitor (or a helper called
# from it) gated on the add_new_processes parameter. Shallow patches that only
# add the flag but don't rescan should fail this.
G5_RES=$(python3 - <<'EOF' 2>/dev/null
import ast
try:
    src = open('/workspace/arr-monitor.py').read()
    tree = ast.parse(src)
except Exception:
    print("ERR"); raise SystemExit

# Find run_monitor body source
target = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'run_monitor':
        target = node
        break
if target is None:
    print("NO_FUNC"); raise SystemExit

try:
    body_src = ast.unparse(target)
except Exception:
    print("ERR"); raise SystemExit

calls_finder = 'find_arr_processes' in body_src
mentions_flag = ('add_new_processes' in body_src)
# Must also extend/append to pid_list (i.e., actually pick up new pids)
extends_list = ('pid_list.append' in body_src) or ('pid_list.extend' in body_src) or \
               ('pid_list +=' in body_src) or ('pid_list = pid_list +' in body_src)

if calls_finder and mentions_flag and extends_list:
    print("FULL")
elif calls_finder and mentions_flag:
    print("HALF")
elif mentions_flag:
    print("FLAG_ONLY")
else:
    print("NONE")
EOF
)
case "$G5_RES" in
  FULL)      SCORE=$((SCORE + 200)) ;;
  HALF)      SCORE=$((SCORE + 110)) ;;
  FLAG_ONLY) SCORE=$((SCORE + 40))  ;;
  *) ;;
esac

# ---- G6 (0.15): --add-new-processes without --all triggers validation error ----
G6_OK=0
if [ "$G2_OK" -eq 1 ]; then
  VAL_OUT=$(timeout 8 python3 arr-monitor.py --add-new-processes </dev/null 2>&1)
  VAL_RC=$?
  if [ "$VAL_RC" -ne 0 ] && echo "$VAL_OUT" | grep -qiE '(requires.*--all|--all.*required|with --all|requires --a|--a)'; then
    # narrower: must mention all
    if echo "$VAL_OUT" | grep -qiE '\-\-all|requires.*all|with all'; then
      G6_OK=1
      SCORE=$((SCORE + 150))
    fi
  fi
fi

# ============================================================
# Convert milli-score to decimal reward
# ============================================================
REWARD=$(awk -v s="$SCORE" 'BEGIN { printf "%.3f", s/1000.0 }')
REWARD=$(awk -v r="$REWARD" 'BEGIN { if (r<0) r=0; if (r>1) r=1; printf "%.3f", r }')

echo "Score components:"
echo "  G1 IGNORE_EXTENSIONS:     $G1_RES"
echo "  G2 --help has flag:       $G2_OK"
echo "  G3 flag parses:           $G3_OK"
echo "  G4 plumbing (sig+call):   $G4_RES"
echo "  G5 runtime rescan:        $G5_RES"
echo "  G6 validation error:      $G6_OK"
echo "  raw score (x1000):        $SCORE"
echo "  REWARD:                   $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier

# F2P: --add-new-processes in --help
F2P_HELP_PASSED=false
if cd /workspace && python3 arr-monitor.py --help 2>&1 | grep -q -- '--add-new-processes'; then
  F2P_HELP_PASSED=true
fi
echo "{\"id\": \"f2p_upstream_help_flag\", \"passed\": $F2P_HELP_PASSED, \"detail\": \"--add-new-processes in help\"}" >> /logs/verifier/gates.json

# F2P: .exe/.msi in IGNORE_EXTENSIONS
F2P_EXT_PASSED=false
if cd /workspace && python3 -c "import ast; src=open('arr-monitor.py').read(); tree=ast.parse(src); found=[ast.literal_eval(n.value) for n in ast.walk(tree) if isinstance(n, ast.Assign) for t in n.targets if isinstance(t, ast.Name) and t.id=='IGNORE_EXTENSIONS']; exts=set(found[0]) if found else set(); exit(0 if '.exe' in exts and '.msi' in exts else 1)"; then
  F2P_EXT_PASSED=true
fi
echo "{\"id\": \"f2p_upstream_exe_msi_ext\", \"passed\": $F2P_EXT_PASSED, \"detail\": \".exe/.msi in IGNORE_EXTENSIONS\"}" >> /logs/verifier/gates.json

# P2P: py_compile
P2P_COMPILE_PASSED=false
if cd /workspace && python3 -m py_compile arr-monitor.py 2>/dev/null; then
  P2P_COMPILE_PASSED=true
fi
echo "{\"id\": \"p2p_upstream_py_compile\", \"passed\": $P2P_COMPILE_PASSED, \"detail\": \"py_compile check\"}" >> /logs/verifier/gates.json

# P2P: --help exits clean
P2P_HELP_PASSED=false
if cd /workspace && python3 arr-monitor.py --help > /dev/null 2>&1; then
  P2P_HELP_PASSED=true
fi
echo "{\"id\": \"p2p_upstream_help_exits_clean\", \"passed\": $P2P_HELP_PASSED, \"detail\": \"--help exits 0\"}" >> /logs/verifier/gates.json

# Upstream reward adjustment (best-effort; missing tail script is a no-op)
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_help_flag": 0.15,
    "f2p_upstream_exe_msi_ext": 0.15
}
P2P_REGRESSION = ["p2p_upstream_py_compile", "p2p_upstream_help_exits_clean"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
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

p2p_failed = False  # P2P_REGRESSION gates are informational only (v043 fix)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- end ----
exit 0

