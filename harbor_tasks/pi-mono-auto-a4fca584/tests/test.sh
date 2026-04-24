#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
TOTAL=0

pass() { local w=$1; shift; echo "PASS ($w): $*"; SCORE=$((SCORE + w)); TOTAL=$((TOTAL + w)); }
fail() { local w=$1; shift; echo "FAIL ($w): $*"; TOTAL=$((TOTAL + w)); }

cd /workspace/pi-mono

# ============================================================
# Gate 1 [P2P] (weight 10): Existing package-manager tests
# Passes on unmodified base AND on correct fix.
# Guards against regressions / delete-to-pass.
# ============================================================
echo "=== Gate 1 [P2P]: Existing package-manager tests ==="
P2P_OUTPUT=$(cd packages/coding-agent && npx vitest --run test/package-manager.test.ts 2>&1 || true)
if echo "$P2P_OUTPUT" | grep -q "Tests.*passed" && ! echo "$P2P_OUTPUT" | grep -q "Tests.*failed"; then
    pass 10 "Existing package-manager tests pass"
else
    fail 10 "Existing package-manager tests broken"
    echo "$P2P_OUTPUT" | tail -10
fi

# ============================================================
# Gates 2-7 [F2P]: Behavioral tests for local extension support
# All fail on unmodified base (install/remove throw "Unsupported
# source"; resolve uses wrong base dir). Pass on correct fix.
# Uses npx vitest — TypeScript compilation + execution gate.
# ============================================================
echo ""
echo "=== Gates 2-7 [F2P]: Local extension behavioral tests ==="
cp /tests/local-install.test.ts packages/coding-agent/test/local-install.test.ts
F2P_OUTPUT=$(cd packages/coding-agent && npx vitest --run --reporter=verbose test/local-install.test.ts 2>&1 || true)
echo "$F2P_OUTPUT" | tail -40

# Helper: check if a specific vitest test name passed (checkmark in line)
test_passed() {
    echo "$F2P_OUTPUT" | grep -F "✓" | grep -qF "$1"
}

# Gate 2 [F2P] (weight 15): install() handles local source type
if test_passed "install should accept a local file path without throwing"; then
    pass 15 "install() accepts local file paths"
else
    fail 15 "install() rejects local file paths"
fi

# Gate 3 [F2P] (weight 10): install() validates path existence
if test_passed "install should validate local path exists"; then
    pass 10 "install() validates local path existence"
else
    fail 10 "install() does not validate local path existence"
fi

# Gate 4 [F2P] (weight 10): remove() handles local source type
if test_passed "remove should accept a local file path without throwing"; then
    pass 10 "remove() accepts local file paths"
else
    fail 10 "remove() rejects local file paths"
fi

# Gate 5 [F2P] (weight 20): user-scope local paths resolve from agentDir
if test_passed "should resolve user-scope local packages relative to agentDir"; then
    pass 20 "User-scope local paths resolve from agentDir"
else
    fail 20 "User-scope local paths fail to resolve from agentDir"
fi

# Gate 6 [F2P] (weight 20): project-scope local paths resolve from .pi dir
if test_passed "should resolve project-scope local packages relative to .pi dir"; then
    pass 20 "Project-scope local paths resolve from .pi dir"
else
    fail 20 "Project-scope local paths fail to resolve from .pi dir"
fi

# Gate 7 [F2P] (weight 15): cross-scope deduplication of local packages
if test_passed "should deduplicate same local package across scopes"; then
    pass 15 "Cross-scope deduplication works"
else
    fail 15 "Cross-scope deduplication broken"
fi

# ============================================================
# Final reward calculation
# ============================================================
echo ""
echo "=== Results ==="
echo "Score: $SCORE / $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
    REWARD="0.0"
else
    REWARD=$(awk "BEGIN { printf \"%.2f\", $SCORE / $TOTAL }")
fi

echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
