#!/bin/bash
# Verifier for arr-monitor PR merge task
# Tests: merge open PRs, resolve conflicts, clean up branches
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

cd "$REPO" 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "0.00" > /logs/verifier/reward.txt; exit 0
fi

BASE_COMMIT="eba91a1905745415a4f4d5a91e7e246829cda566"

# Prune stale remote-tracking refs
git remote prune origin 2>/dev/null
git fetch --prune origin 2>/dev/null

# -------------------------------------------------------
# Gate 1 (20 pts) [F2P]: HEAD advanced AND Python file compiles
# Compound behavioral gate: catches no-op AND broken merges
# Fails on base: HEAD == BASE_COMMIT, so HEAD_ADVANCED=0
# -------------------------------------------------------
CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null)
HEAD_ADVANCED=0
if [ "$CURRENT_HEAD" != "$BASE_COMMIT" ]; then
  if git merge-base --is-ancestor "$BASE_COMMIT" HEAD 2>/dev/null; then
    HEAD_ADVANCED=1
  fi
fi
PY_COMPILES=0
if python3 -m py_compile arr-monitor.py 2>/dev/null; then
  PY_COMPILES=1
fi
if [ "$HEAD_ADVANCED" -eq 1 ] && [ "$PY_COMPILES" -eq 1 ]; then
  add_test "Merges applied AND arr-monitor.py compiles (behavioral)" 20 1
else
  add_test "Merges applied AND arr-monitor.py compiles (behavioral)" 20 0
fi

# -------------------------------------------------------
# Gate 2 (25 pts) [F2P]: .exe in IGNORE_EXTENSIONS (AST execution check)
# PR #4 adds .exe but conflicts with .nfo from PR #3
# Verifies conflict was resolved correctly via Python AST
# Fails on base: .exe not in IGNORE_EXTENSIONS
# -------------------------------------------------------
EXE_CHECK=$(python3 -c "
import ast, sys
try:
    with open('arr-monitor.py') as f:
        tree = ast.parse(f.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == 'IGNORE_EXTENSIONS':
                    val = ast.literal_eval(node.value)
                    if '.exe' in val:
                        print('FOUND')
                        sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null)
if [ "$EXE_CHECK" = "FOUND" ]; then
  add_test "PR #4 conflict resolved: .exe in IGNORE_EXTENSIONS (AST-verified)" 25 1
else
  add_test "PR #4 conflict resolved: .exe in IGNORE_EXTENSIONS (AST-verified)" 25 0
fi

# -------------------------------------------------------
# Gate 3 (10 pts) [F2P]: All conflict extensions present (.nfo, .exe, .msi)
# PR #3 added .nfo, PR #4 added .exe and .msi — all must survive merge
# Fails on base: .exe and .msi missing from IGNORE_EXTENSIONS
# -------------------------------------------------------
ALL_EXTS_CHECK=$(python3 -c "
import ast, sys
try:
    with open('arr-monitor.py') as f:
        tree = ast.parse(f.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == 'IGNORE_EXTENSIONS':
                    val = ast.literal_eval(node.value)
                    missing = [e for e in ['.nfo', '.exe', '.msi'] if e not in val]
                    if not missing:
                        print('ALL_PRESENT')
                    else:
                        print('MISSING:' + ','.join(missing))
                    sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null)
if [ "$ALL_EXTS_CHECK" = "ALL_PRESENT" ]; then
  add_test "All conflict extensions preserved: .nfo .exe .msi (AST-verified)" 10 1
else
  add_test "All conflict extensions preserved: .nfo .exe .msi (AST-verified)" 10 0
fi

# -------------------------------------------------------
# Gate 4 (20 pts) [F2P]: All 3 feature branches deleted locally
# Fails on base: all 3 feature branches exist
# -------------------------------------------------------
LOCAL_BRANCHES_REMAINING=0
for br in feature-add-new-processes-flag ignore-nfo-and-dll-transfers fix-ignore-exe-extension; do
  if git branch --list "$br" 2>/dev/null | grep -q .; then
    LOCAL_BRANCHES_REMAINING=$((LOCAL_BRANCHES_REMAINING + 1))
  fi
done
if [ "$LOCAL_BRANCHES_REMAINING" -eq 0 ]; then
  add_test "All 3 feature branches deleted locally" 20 1
else
  add_test "All 3 feature branches deleted locally ($LOCAL_BRANCHES_REMAINING remaining)" 20 0
fi

# -------------------------------------------------------
# Gate 5 (10 pts) [F2P]: All 3 feature branches deleted from remote
# Fails on base: all 3 remote branches exist
# -------------------------------------------------------
REMOTE_BRANCHES_REMAINING=0
for br in feature-add-new-processes-flag ignore-nfo-and-dll-transfers fix-ignore-exe-extension; do
  if git branch -r 2>/dev/null | grep -q "origin/$br"; then
    REMOTE_BRANCHES_REMAINING=$((REMOTE_BRANCHES_REMAINING + 1))
  fi
done
if [ "$REMOTE_BRANCHES_REMAINING" -eq 0 ]; then
  add_test "All 3 feature branches deleted from remote" 10 1
else
  add_test "All 3 feature branches deleted from remote ($REMOTE_BRANCHES_REMAINING remaining)" 10 0
fi

# -------------------------------------------------------
# Gate 6 (5 pts) [P2P]: On main with clean working tree
# Passes on base: starts on main with clean tree
# Passes on fix: should remain on main, clean
# -------------------------------------------------------
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
DIRTY=$(git status --porcelain 2>/dev/null | grep -v '?? instruction.md' | grep -v '?? __pycache__/' | head -1)
if [ "$CURRENT_BRANCH" = "main" ] && [ -z "$DIRTY" ]; then
  add_test "On main branch with clean working tree" 5 1
else
  add_test "On main branch with clean working tree" 5 0
fi

# -------------------------------------------------------
# Gate 7 (10 pts) [F2P]: At least 2 merge commits since base
# Verifies multiple PRs were actually merged (not just one)
# Fails on base: no commits after BASE_COMMIT
# -------------------------------------------------------
MERGE_COUNT=$(git log --merges --oneline "$BASE_COMMIT"..HEAD 2>/dev/null | wc -l)
if [ "$MERGE_COUNT" -ge 2 ]; then
  add_test "At least 2 merge commits since base (multiple PRs merged)" 10 1
else
  add_test "At least 2 merge commits since base (multiple PRs merged)" 10 0
fi

# -------------------------------------------------------
# Calculate and write reward
# -------------------------------------------------------
if [ "$TOTAL" -gt 0 ]; then
  REWARD=$(echo "scale=2; $SCORE / $TOTAL" | bc)
else
  REWARD="0.00"
fi

mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt

echo "========================="
echo "Test Results"
echo "========================="
echo -e "$DETAILS"
echo ""
echo "Score: $SCORE / $TOTAL = $REWARD"
echo "========================="
