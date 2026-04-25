#!/bin/bash
set +e

mkdir -p /logs/verifier
REPO="/workspace"
REWARD=0.0

cd "$REPO" 2>/dev/null || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

BASE_COMMIT="eba91a1905745415a4f4d5a91e7e246829cda566"

# ---- HARD GATE 1: file exists & no conflict markers & compiles ----
# On the buggy base, the file likely has unmerged conflict markers OR is a clean
# pre-merge state. We need it parseable to even probe behavior.
if [ ! -f arr-monitor.py ]; then
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

if grep -nE '^(<{7}|={7}|>{7})' arr-monitor.py >/dev/null 2>&1; then
  # Conflict markers present => agent failed to resolve merges => 0
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

if ! python3 -m py_compile arr-monitor.py 2>/dev/null; then
  echo "0.0" > /logs/verifier/reward.txt; exit 0
fi

# ---- HARD GATE 2: HEAD must have advanced past base (merges integrated) ----
CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null)
if [ "$CURRENT_HEAD" = "$BASE_COMMIT" ]; then
  # No-op: HEAD unchanged. Even if compilation passes, no merge happened.
  # But wait: if base is clean (no markers) and compiles, we still gate on F2P.
  # The F2P below will catch it. Don't exit here.
  :
fi

# ============================================================
# F2P GATES (sum = 1.0). Each must FAIL on buggy base.
# ============================================================
SCORE=0
# Use millis (x1000) for awk math.

# ---- F2P 1 (0.20): IGNORE_EXTENSIONS contains all of .nfo, .exe, .msi ----
# On buggy base (with conflict markers OR pre-merge), this set is incomplete.
EXTS_RESULT=$(python3 - <<'EOF' 2>/dev/null
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
required = {'.nfo', '.exe', '.msi'}
have = required & set(found)
print(f"HAVE:{len(have)}")
EOF
)
case "$EXTS_RESULT" in
  HAVE:3) SCORE=$((SCORE + 200)) ;;
  HAVE:2) SCORE=$((SCORE + 130)) ;;
  HAVE:1) SCORE=$((SCORE + 60))  ;;
  *) ;;
esac

# ---- F2P 2 (0.25): --add-new-processes flag is in --help output ----
HELP_OUT=$(timeout 10 python3 arr-monitor.py --help 2>&1)
HELP_RC=$?
HELP_HAS_FLAG=0
if [ "$HELP_RC" -eq 0 ] && echo "$HELP_OUT" | grep -q -- '--add-new-processes'; then
  HELP_HAS_FLAG=1
  SCORE=$((SCORE + 250))
fi

# ---- F2P 3 (0.20): flag actually parses (argparse-registered) ----
FLAG_PARSE_OK=0
if [ "$HELP_HAS_FLAG" -eq 1 ]; then
  PARSE_OUT=$(timeout 10 python3 arr-monitor.py --add-new-processes --help 2>&1)
  PARSE_RC=$?
  if [ "$PARSE_RC" -eq 0 ] && echo "$PARSE_OUT" | grep -q -- '--add-new-processes'; then
    FLAG_PARSE_OK=1
    SCORE=$((SCORE + 200))
  else
    # Try with --all in case it's gated
    PARSE_OUT2=$(timeout 10 python3 arr-monitor.py --all --add-new-processes --help 2>&1)
    if [ $? -eq 0 ] && echo "$PARSE_OUT2" | grep -q -- '--add-new-processes'; then
      FLAG_PARSE_OK=1
      SCORE=$((SCORE + 200))
    fi
  fi
fi

# ---- F2P 4 (0.20): flag is plumbed through to runtime (run_monitor or args ref) ----
PLUMBED=$(python3 - <<'EOF' 2>/dev/null
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

ref_ok = ('args.add_new_processes' in src) or ('add_new_processes=' in src)

if sig_ok and ref_ok:
    print("FULL")
elif sig_ok or ref_ok:
    print("PARTIAL")
else:
    print("NONE")
EOF
)
case "$PLUMBED" in
  FULL)    SCORE=$((SCORE + 200)) ;;
  PARTIAL) SCORE=$((SCORE + 100)) ;;
  *) ;;
esac

# ---- F2P 5 (0.15): behavioral - flag without --all errors out (validation) ----
# This is bonus/optional behavior on top - reward agents who added validation.
# On buggy base, the flag doesn't exist at all so this fails too.
VALIDATION_OK=0
if [ "$HELP_HAS_FLAG" -eq 1 ]; then
  # Run with just the flag, no --all. We expect either:
  #   (a) parser.error -> exits non-zero with "requires --all" in stderr, OR
  #   (b) it tries to run normally (no validation - no points)
  VAL_OUT=$(timeout 5 python3 arr-monitor.py --add-new-processes 2>&1 </dev/null)
  VAL_RC=$?
  # If it errored mentioning --all requirement, validation is in place
  if [ "$VAL_RC" -ne 0 ] && echo "$VAL_OUT" | grep -qiE 'requires.*--all|--all.*required|with --all'; then
    VALIDATION_OK=1
    SCORE=$((SCORE + 150))
  fi
fi

# ============================================================
# Convert milli-score to decimal reward
# ============================================================
REWARD=$(awk -v s="$SCORE" 'BEGIN { printf "%.3f", s/1000.0 }')

# Safety clamp
REWARD=$(awk -v r="$REWARD" 'BEGIN { if (r<0) r=0; if (r>1) r=1; printf "%.3f", r }')

echo "Score components:"
echo "  IGNORE_EXTENSIONS: $EXTS_RESULT"
echo "  --help has flag: $HELP_HAS_FLAG"
echo "  flag parses: $FLAG_PARSE_OK"
echo "  plumbed: $PLUMBED"
echo "  validation: $VALIDATION_OK"
echo "  raw score (x1000): $SCORE"
echo "  REWARD: $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt