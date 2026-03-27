#!/usr/bin/env bash
#
# Verification script for dataclaw-add-8d7f4a task.
# Tests that the agent wrote a comprehensive test suite for the dataclaw package.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# DESIGN PRINCIPLES:
#   - >=60% behavioral (Gold/Silver): pytest runs and tests actually pass
#   - <=40% structural (Bronze): test files exist, importable
#   - Core behavioral check (tests passing) worth >= 0.15
#   - Anti-stub: reject trivially empty test files
#   - Accepts multiple valid implementations
#
set +e

REWARD=0.0
WORKSPACE="/workspace/dataclaw"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ===================================================================
# CHECK 1 (0.05 Bronze): tests/ directory with test files exists
# ===================================================================
echo "--- Check 1: tests/ directory exists ---"

if [ -d "tests" ] && ls tests/test_*.py 2>/dev/null | grep -q .; then
    TEST_COUNT=$(ls tests/test_*.py 2>/dev/null | wc -l)
    echo "  PASS: tests/ directory exists with $TEST_COUNT test files"
    add_reward 0.05
else
    echo "  FAIL: tests/ directory missing or has no test_*.py files"
fi

# ===================================================================
# CHECK 2 (0.05 Bronze): Core dataclaw modules importable
# ===================================================================
echo "--- Check 2: Core modules importable ---"

IMPORT_RESULT=$(python3 -c "
try:
    import dataclaw.secrets
    import dataclaw.anonymizer
    import dataclaw.parser
    import dataclaw.config
    print('PASS')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Import result: $IMPORT_RESULT"
if [ "$IMPORT_RESULT" = "PASS" ]; then
    echo "  PASS: All core dataclaw modules import cleanly"
    add_reward 0.05
else
    echo "  FAIL: ($IMPORT_RESULT)"
fi

# ===================================================================
# CHECK 3 (0.05 Bronze): test_secrets.py exists with meaningful content
#   Anti-stub: must have >= 5 test functions defined
# ===================================================================
echo "--- Check 3: test_secrets.py has meaningful content ---"

if [ -f "tests/test_secrets.py" ]; then
    SECRETS_TEST_COUNT=$(python3 -c "
import ast, sys
try:
    with open('tests/test_secrets.py') as f:
        tree = ast.parse(f.read())
    count = sum(1 for node in ast.walk(tree)
                if isinstance(node, ast.FunctionDef) and node.name.startswith('test_'))
    print(count)
except Exception as e:
    print(0)
" 2>&1)
    echo "  test_secrets.py has $SECRETS_TEST_COUNT test functions"
    if [ "$SECRETS_TEST_COUNT" -ge 5 ] 2>/dev/null; then
        echo "  PASS: test_secrets.py has substantial content"
        add_reward 0.05
    else
        echo "  FAIL: too few test functions (need >= 5, got $SECRETS_TEST_COUNT)"
    fi
else
    echo "  FAIL: tests/test_secrets.py does not exist"
fi

# ===================================================================
# CHECK 4 (0.05 Bronze): test_anonymizer.py and test_parser.py exist
# ===================================================================
echo "--- Check 4: test_anonymizer.py and test_parser.py exist ---"

ANON_EXISTS=0
PARSER_EXISTS=0
[ -f "tests/test_anonymizer.py" ] && ANON_EXISTS=1
[ -f "tests/test_parser.py" ] && PARSER_EXISTS=1

if [ $ANON_EXISTS -eq 1 ] && [ $PARSER_EXISTS -eq 1 ]; then
    echo "  PASS: Both test_anonymizer.py and test_parser.py exist"
    add_reward 0.05
else
    [ $ANON_EXISTS -eq 0 ] && echo "  MISSING: tests/test_anonymizer.py"
    [ $PARSER_EXISTS -eq 0 ] && echo "  MISSING: tests/test_parser.py"
fi

# ===================================================================
# CHECK 5 (0.25 Gold): pytest runs without import errors
#   Tests must at least be collectible (no syntax/import errors)
# ===================================================================
echo "--- Check 5: pytest collection (no import/syntax errors) ---"

COLLECT_OUT=$(python3 -m pytest tests/ --collect-only -q 2>&1)
COLLECT_STATUS=$?

if echo "$COLLECT_OUT" | grep -q "error" && ! echo "$COLLECT_OUT" | grep -q " error"; then
    # There are collection errors
    echo "  FAIL: pytest collection errors detected"
    echo "  $COLLECT_OUT" | head -20
else
    COLLECTED=$(echo "$COLLECT_OUT" | grep -oP '\d+ test' | head -1 | grep -oP '\d+' || echo "0")
    echo "  Collected: $COLLECTED tests"
    if [ -n "$COLLECTED" ] && [ "$COLLECTED" -gt 0 ] 2>/dev/null; then
        echo "  PASS: pytest collected $COLLECTED tests without errors"
        add_reward 0.25
    else
        # Try with more lenient check
        if python3 -m pytest tests/ --collect-only -q 2>&1 | grep -q "test session"; then
            echo "  PASS: pytest session started successfully"
            add_reward 0.15
        else
            echo "  FAIL: could not collect any tests"
        fi
    fi
fi

# ===================================================================
# CHECK 6 (0.20 Gold): pytest test_secrets.py passes
#   The most critical test file — secrets module is pure functions
# ===================================================================
echo "--- Check 6: test_secrets.py passes ---"

if [ -f "tests/test_secrets.py" ]; then
    SECRETS_RESULT=$(python3 -m pytest tests/test_secrets.py -v --tb=short 2>&1)
    SECRETS_STATUS=$?
    SECRETS_PASSED=$(echo "$SECRETS_RESULT" | grep -oP '\d+ passed' | head -1 | grep -oP '\d+' || echo "0")
    SECRETS_FAILED=$(echo "$SECRETS_RESULT" | grep -oP '\d+ failed' | head -1 | grep -oP '\d+' || echo "0")
    echo "  test_secrets.py: $SECRETS_PASSED passed, $SECRETS_FAILED failed"

    if [ "$SECRETS_STATUS" -eq 0 ] && [ "$SECRETS_PASSED" -gt 0 ]; then
        echo "  PASS: All test_secrets.py tests pass ($SECRETS_PASSED tests)"
        add_reward 0.20
    elif [ "$SECRETS_PASSED" -gt 0 ]; then
        # Partial credit: some passed
        FRAC=$(python3 -c "p=$SECRETS_PASSED; f=$SECRETS_FAILED; total=p+f; print(round(0.20 * p / total, 3) if total > 0 else 0)")
        echo "  PARTIAL: $SECRETS_PASSED passed, $SECRETS_FAILED failed — reward $FRAC"
        add_reward $FRAC
    else
        echo "  FAIL: No test_secrets.py tests passed"
        echo "  $SECRETS_RESULT" | tail -10
    fi
else
    echo "  SKIP: tests/test_secrets.py does not exist"
fi

# ===================================================================
# CHECK 7 (0.15 Gold): test_anonymizer.py passes
# ===================================================================
echo "--- Check 7: test_anonymizer.py passes ---"

if [ -f "tests/test_anonymizer.py" ]; then
    ANON_RESULT=$(python3 -m pytest tests/test_anonymizer.py -v --tb=short 2>&1)
    ANON_STATUS=$?
    ANON_PASSED=$(echo "$ANON_RESULT" | grep -oP '\d+ passed' | head -1 | grep -oP '\d+' || echo "0")
    ANON_FAILED=$(echo "$ANON_RESULT" | grep -oP '\d+ failed' | head -1 | grep -oP '\d+' || echo "0")
    echo "  test_anonymizer.py: $ANON_PASSED passed, $ANON_FAILED failed"

    if [ "$ANON_STATUS" -eq 0 ] && [ "$ANON_PASSED" -gt 0 ]; then
        echo "  PASS: All test_anonymizer.py tests pass ($ANON_PASSED tests)"
        add_reward 0.15
    elif [ "$ANON_PASSED" -gt 0 ]; then
        FRAC=$(python3 -c "p=$ANON_PASSED; f=$ANON_FAILED; total=p+f; print(round(0.15 * p / total, 3) if total > 0 else 0)")
        echo "  PARTIAL: $ANON_PASSED passed, $ANON_FAILED failed — reward $FRAC"
        add_reward $FRAC
    else
        echo "  FAIL: No test_anonymizer.py tests passed"
    fi
else
    echo "  SKIP: tests/test_anonymizer.py does not exist"
fi

# ===================================================================
# CHECK 8 (0.10 Gold): test_parser.py passes
# ===================================================================
echo "--- Check 8: test_parser.py passes ---"

if [ -f "tests/test_parser.py" ]; then
    PARSER_RESULT=$(python3 -m pytest tests/test_parser.py -v --tb=short 2>&1)
    PARSER_STATUS=$?
    PARSER_PASSED=$(echo "$PARSER_RESULT" | grep -oP '\d+ passed' | head -1 | grep -oP '\d+' || echo "0")
    PARSER_FAILED=$(echo "$PARSER_RESULT" | grep -oP '\d+ failed' | head -1 | grep -oP '\d+' || echo "0")
    echo "  test_parser.py: $PARSER_PASSED passed, $PARSER_FAILED failed"

    if [ "$PARSER_STATUS" -eq 0 ] && [ "$PARSER_PASSED" -gt 0 ]; then
        echo "  PASS: All test_parser.py tests pass ($PARSER_PASSED tests)"
        add_reward 0.10
    elif [ "$PARSER_PASSED" -gt 0 ]; then
        FRAC=$(python3 -c "p=$PARSER_PASSED; f=$PARSER_FAILED; total=p+f; print(round(0.10 * p / total, 3) if total > 0 else 0)")
        echo "  PARTIAL: $PARSER_PASSED passed, $PARSER_FAILED failed — reward $FRAC"
        add_reward $FRAC
    else
        echo "  FAIL: No test_parser.py tests passed"
    fi
else
    echo "  SKIP: tests/test_parser.py does not exist"
fi

# ===================================================================
# CHECK 9 (0.10 Silver): Overall test count >= 20
#   Ensures substantial coverage, not just a handful of tests
# ===================================================================
echo "--- Check 9: Overall test coverage breadth ---"

TOTAL_PASSED=$(python3 -m pytest tests/ -q --tb=no 2>&1 | grep -oP '\d+ passed' | head -1 | grep -oP '\d+' || echo "0")
echo "  Total tests passing: $TOTAL_PASSED"

if [ "$TOTAL_PASSED" -ge 30 ] 2>/dev/null; then
    echo "  PASS: $TOTAL_PASSED tests passing (>= 30)"
    add_reward 0.10
elif [ "$TOTAL_PASSED" -ge 20 ] 2>/dev/null; then
    echo "  PARTIAL: $TOTAL_PASSED tests passing (>= 20, < 30)"
    add_reward 0.07
elif [ "$TOTAL_PASSED" -ge 10 ] 2>/dev/null; then
    echo "  PARTIAL: $TOTAL_PASSED tests passing (>= 10)"
    add_reward 0.04
else
    echo "  FAIL: Only $TOTAL_PASSED tests passing (need >= 10)"
fi

# ===================================================================
# Write final reward
# ===================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
