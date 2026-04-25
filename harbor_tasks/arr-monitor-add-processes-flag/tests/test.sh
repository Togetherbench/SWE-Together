#!/bin/bash
set +e

REPO="/workspace"
SCORE=0
TOTAL=0
DETAILS=""

add_test() {
  local name="$1" weight="$2" result="$3"
  TOTAL=$((TOTAL + weight))
  if [ "$result" -eq 1 ]; then
    SCORE=$((SCORE + weight))
    DETAILS="$DETAILS\nPASS ($weight pts): $name"
  else
    DETAILS="$DETAILS\nFAIL ($weight pts): $name"
  fi
}

add_partial() {
  local name="$1" weight="$2" earned="$3"
  TOTAL=$((TOTAL + weight))
  SCORE=$((SCORE + earned))
  DETAILS="$DETAILS\nPARTIAL ($earned/$weight pts): $name"
}

mkdir -p /logs/verifier

cd "$REPO" 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "0.00" > /logs/verifier/reward.txt; exit 0
fi

BASE_COMMIT="eba91a1905745415a4f4d5a91e7e246829cda566"

git remote prune origin 2>/dev/null
git fetch --prune origin 2>/dev/null

# -------------------------------------------------------
# Gate A (10 pts) [P2P]: arr-monitor.py compiles cleanly
# Catches broken merges with stray conflict markers
# -------------------------------------------------------
PY_COMPILES=0
COMPILE_OUT=$(python3 -m py_compile arr-monitor.py 2>&1)
if [ -z "$COMPILE_OUT" ]; then
  PY_COMPILES=1
fi
# Also reject if file contains conflict markers
CONFLICT_MARKERS=0
if grep -nE '^(<{7}|={7}|>{7})' arr-monitor.py >/dev/null 2>&1; then
  CONFLICT_MARKERS=1
fi
if [ "$PY_COMPILES" -eq 1 ] && [ "$CONFLICT_MARKERS" -eq 0 ]; then
  add_test "arr-monitor.py compiles and has no conflict markers" 10 1
else
  add_test "arr-monitor.py compiles and has no conflict markers" 10 0
fi

# -------------------------------------------------------
# Gate B (10 pts) [F2P]: HEAD advanced past base
# -------------------------------------------------------
CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null)
HEAD_ADVANCED=0
if [ "$CURRENT_HEAD" != "$BASE_COMMIT" ] && git merge-base --is-ancestor "$BASE_COMMIT" HEAD 2>/dev/null; then
  HEAD_ADVANCED=1
fi
add_test "Merges integrated (HEAD advanced past base)" 10 "$HEAD_ADVANCED"

# -------------------------------------------------------
# Gate C (15 pts) [F2P]: All 3 ext markers (.nfo, .exe, .msi) actually
# present in IGNORE_EXTENSIONS at runtime (not just textually)
# -------------------------------------------------------
EXTS_RESULT=$(python3 - <<'EOF' 2>/dev/null
import ast, sys
try:
    src = open('/workspace/arr-monitor.py').read()
    tree = ast.parse(src)
except Exception as e:
    print("PARSE_ERR")
    sys.exit(0)

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
    print("NOT_FOUND")
    sys.exit(0)

required = {'.nfo', '.exe', '.msi'}
missing = required - set(found)
if not missing:
    print("ALL")
else:
    print("MISSING:" + ",".join(sorted(missing)))
EOF
)
EXT_SCORE=0
case "$EXTS_RESULT" in
  ALL) EXT_SCORE=15 ;;
  MISSING:*)
    # partial credit per ext present
    miss_count=$(echo "$EXTS_RESULT" | tr ',' '\n' | wc -l)
    if [ "$miss_count" = "1" ]; then EXT_SCORE=10
    elif [ "$miss_count" = "2" ]; then EXT_SCORE=5
    else EXT_SCORE=0
    fi
    ;;
  *) EXT_SCORE=0 ;;
esac
add_partial "IGNORE_EXTENSIONS contains .nfo, .exe, .msi ($EXTS_RESULT)" 15 "$EXT_SCORE"

# -------------------------------------------------------
# Gate D (20 pts) [F2P]: --add-new-processes flag is wired into argparse
# Behavioral check: invoke `--help` and verify the flag is documented
# -------------------------------------------------------
HELP_OUT=$(python3 arr-monitor.py --help 2>&1)
HELP_RC=$?
HAS_FLAG=0
if [ "$HELP_RC" -eq 0 ] && echo "$HELP_OUT" | grep -q -- '--add-new-processes'; then
  HAS_FLAG=1
fi
add_test "--add-new-processes flag appears in --help output" 20 "$HAS_FLAG"

# -------------------------------------------------------
# Gate E (15 pts) [F2P]: Flag actually parses (not just listed)
# Use argparse introspection to confirm the option is registered as a bool flag
# -------------------------------------------------------
FLAG_PARSE=$(python3 - <<'EOF' 2>/dev/null
import sys, importlib.util, ast
sys.path.insert(0, '/workspace')

# Parse the file to find the argparse parser construction and re-execute just the
# parser setup if possible. Fallback: import as module under __name__ guard.
try:
    src = open('/workspace/arr-monitor.py').read()
except Exception:
    print("READ_ERR"); sys.exit(0)

# Try importing module - it's guarded by if __name__ == '__main__'
try:
    spec = importlib.util.spec_from_file_location("arr_monitor_mod", "/workspace/arr-monitor.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except SystemExit:
    pass
except Exception as e:
    # Module-level error
    print("IMPORT_ERR:" + type(e).__name__); sys.exit(0)

# Strategy: invoke the script as subprocess with the flag and a deliberately bad
# extra arg to see if argparse accepts the flag itself.
import subprocess
# Try `--add-new-processes --help` -> should still print help (rc 0)
r = subprocess.run([sys.executable, '/workspace/arr-monitor.py', '--add-new-processes', '--help'],
                   capture_output=True, text=True, timeout=10)
if r.returncode == 0 and '--add-new-processes' in r.stdout:
    print("OK")
    sys.exit(0)

# Else try with --all
r2 = subprocess.run([sys.executable, '/workspace/arr-monitor.py', '--all', '--add-new-processes', '--help'],
                    capture_output=True, text=True, timeout=10)
if r2.returncode == 0 and '--add-new-processes' in r2.stdout:
    print("OK")
    sys.exit(0)

# Else, check if it's at least defined via argparse by looking at error output for an unknown-arg complaint
combined = (r.stderr or '') + (r2.stderr or '')
if 'unrecognized arguments' in combined or 'unrecognized argument' in combined:
    print("UNRECOGNIZED")
else:
    print("UNKNOWN:" + str(r.returncode) + "/" + str(r2.returncode))
EOF
)
if [ "$FLAG_PARSE" = "OK" ]; then
  add_test "--add-new-processes is a real argparse option (parses successfully)" 15 1
else
  add_test "--add-new-processes is a real argparse option ($FLAG_PARSE)" 15 0
fi

# -------------------------------------------------------
# Gate F (10 pts) [F2P]: Flag is plumbed into run_monitor signature OR
# the monitor loop references its parsed value (not just a dead arg)
# -------------------------------------------------------
PLUMBED=$(python3 - <<'EOF' 2>/dev/null
import ast
try:
    src = open('/workspace/arr-monitor.py').read()
    tree = ast.parse(src)
except Exception:
    print("ERR"); raise SystemExit

# Check 1: run_monitor accepts add_new_processes-like kwarg
sig_ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == 'run_monitor':
        argnames = [a.arg for a in node.args.args] + [a.arg for a in node.args.kwonlyargs]
        for n in argnames:
            if 'new_process' in n.lower() or 'add_new' in n.lower():
                sig_ok = True
                break

# Check 2: somewhere the parsed args attribute is referenced
src_lower = src.replace('-', '_')
ref_ok = ('args.add_new_processes' in src_lower) or ('add_new_processes=' in src) or ('add_new_processes =' in src)

if sig_ok and ref_ok:
    print("FULL")
elif sig_ok or ref_ok:
    print("PARTIAL")
else:
    print("NONE")
EOF
)
case "$PLUMBED" in
  FULL) add_partial "Flag plumbed into run_monitor and referenced from args" 10 10 ;;
  PARTIAL) add_partial "Flag partially plumbed ($PLUMBED)" 10 5 ;;
  *) add_partial "Flag not plumbed into runtime ($PLUMBED)" 10 0 ;;
esac

# -------------------------------------------------------
# Gate G (5 pts) [F2P]: Flag requires --all (or behaves consistently)
# Behavioral: invoke with `--add-new-processes` alone and check it errors,
# OR accept that it runs with --all (lenient).
# This rewards solutions that added the validation, but doesn't punish those who didn't.
# -------------------------------------------------------
# We give credit if EITHER:
#   a) Running with --add-new-processes alone exits non-zero (validated)
#   b) The flag exists at all (already covered, so this is bonus for validation)
VALIDATED=0
ERR_OUT=$(timeout 10 python3 arr-monitor.py --add-new-processes 2>&1 </dev/null)
ERR_RC=$?
# Note: without --all, it might enter interactive mode. Use a brief timeout.
# We only score the 'validated' path here.
if echo "$ERR_OUT" | grep -qiE 'requires --all|--all is required|requires.*all'; then
  VALIDATED=1
fi
if [ "$VALIDATED" -eq 1 ]; then
  add_test "Flag validates dependency on --all (bonus rigor)" 5 1
else
  add_test "Flag validates dependency on --all (bonus rigor)" 5 0
fi

# -------------------------------------------------------
# Gate H (10 pts) [F2P]: Local feature branches deleted
# Partial credit per branch
# -------------------------------------------------------
LOCAL_GONE=0
for br in feature-add-new-processes-flag ignore-nfo-and-dll-transfers fix-ignore-exe-extension; do
  if ! git branch --list "$br" 2>/dev/null | grep -q .; then
    LOCAL_GONE=$((LOCAL_GONE + 1))
  fi
done
LOCAL_PTS=$(( LOCAL_GONE * 10 / 3 ))
add_partial "Local feature branches deleted ($LOCAL_GONE/3)" 10 "$LOCAL_PTS"

# -------------------------------------------------------
# Gate I (10 pts) [F2P]: Remote feature branches deleted
# Partial credit per branch
# -------------------------------------------------------
REMOTE_GONE=0
for br in feature-add-new-processes-flag ignore-nfo-and-dll-transfers fix-ignore-exe-extension; do
  if ! git branch -r 2>/dev/null | grep -q "origin/$br$"; then
    REMOTE_GONE=$((REMOTE_GONE + 1))
  fi
done
REMOTE_PTS=$(( REMOTE_GONE * 10 / 3 ))
add_partial "Remote feature branches deleted ($REMOTE_GONE/3)" 10 "$REMOTE_PTS"

# -------------------------------------------------------
# Gate J (5 pts) [P2P]: On main, clean tree
# -------------------------------------------------------
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '?? instruction.md' | grep -v '?? __pycache__/' | grep -v '?? .pytest_cache/' | head -1)
if [ "$CURRENT_BRANCH" = "main" ] && [ -z "$DIRTY" ]; then
  add_test "On main with clean working tree" 5 1
else
  add_test "On main with clean working tree (branch=$CURRENT_BRANCH dirty=$DIRTY)" 5 0
fi

# -------------------------------------------------------
# Gate K (10 pts) [F2P]: At least 2 merge commits since base
# -------------------------------------------------------
MERGE_COUNT=$(git log --merges --oneline "$BASE_COMMIT"..HEAD 2>/dev/null | wc -l)
if [ "$MERGE_COUNT" -ge 2 ]; then
  add_test "At least 2 merge commits since base (got $MERGE_COUNT)" 10 1
elif [ "$MERGE_COUNT" -eq 1 ]; then
  add_partial "Only 1 merge commit since base" 10 5
else
  add_test "At least 2 merge commits since base (got $MERGE_COUNT)" 10 0
fi

# -------------------------------------------------------
# Compute final reward
# -------------------------------------------------------
if [ "$TOTAL" -gt 0 ]; then
  REWARD=$(awk -v s="$SCORE" -v t="$TOTAL" 'BEGIN { printf "%.2f", s/t }')
else
  REWARD="0.00"
fi

echo "$REWARD" > /logs/verifier/reward.txt

echo "========================="
echo "Test Results"
echo "========================="
echo -e "$DETAILS"
echo ""
echo "Score: $SCORE / $TOTAL = $REWARD"
echo "========================="