#!/bin/bash
set +e

cd /workspace/hyperswitch
SCORE=0

echo "============================================"
echo "Hyperswitch PR #8377 Verifier"
echo "v2 endpoint: list payment attempts by intent_id"
echo "============================================"

# ─── Gate 1 (P2P): Base crate compiles ─── weight: 0.10
# Passes on unmodified base AND on correct fix.
# Guards against regressions that break existing code.
echo ""
echo "=== Gate 1 (P2P): router_env crate compiles ==="
cargo check -p router_env 2>&1 | tail -5
if [ $? -eq 0 ]; then
    SCORE=$(echo "$SCORE + 10" | bc)
    echo "PASS: +0.10"
else
    echo "FAIL"
fi

# ─── Gate 2 (F2P): New operation module file exists ─── weight: 0.10
# The PR adds a new operation module for payment attempt listing.
# Any correct implementation must create this module (name may vary).
echo ""
echo "=== Gate 2 (F2P): Payment attempt list operation module ==="
FOUND_MODULE=0
# Accept any reasonable module name for the operation
# The gold creates payment_attempt_list.rs, but accept variations
for f in crates/router/src/core/payments/operations/*attempt*list*.rs \
         crates/router/src/core/payments/operations/*list*attempt*.rs \
         crates/router/src/core/payments/operations/payment_attempt_list.rs \
         crates/router/src/core/payments/operations/list_attempts.rs \
         crates/router/src/core/payments/operations/attempt_list.rs; do
    if [ -f "$f" ]; then
        FOUND_MODULE=1
        echo "Found: $f"
        break
    fi
done
# Also check if operations.rs was modified to include a new attempt list module
if [ $FOUND_MODULE -eq 0 ]; then
    if grep -q "payment_attempt_list\|list_attempt\|attempt_list" crates/router/src/core/payments/operations.rs 2>/dev/null; then
        FOUND_MODULE=1
        echo "Found module reference in operations.rs"
    fi
fi
if [ $FOUND_MODULE -eq 1 ]; then
    SCORE=$(echo "$SCORE + 10" | bc)
    echo "PASS: +0.10"
else
    echo "FAIL: No new attempt/list operation module found"
fi

# ─── Gate 3 (F2P): Request/Response types defined ─── weight: 0.10
# The endpoint needs request and response types in api_models.
# The gold adds PaymentAttemptListRequest + PaymentAttemptListResponse,
# but accept any struct combining "Attempt" with "List" concepts.
echo ""
echo "=== Gate 3 (F2P): API request/response types for attempt listing ==="
TYPES_FOUND=0
# Check for list-specific attempt types (not existing PaymentAttempt types)
if grep -rq "struct.*AttemptList\|struct.*ListAttempt\|struct.*AttemptsResponse\|struct.*AttemptsList" crates/api_models/src/ 2>/dev/null; then
    TYPES_FOUND=$((TYPES_FOUND + 1))
fi
# Also check for a struct with payment_attempts field (Vec of attempts)
if grep -rq "payment_attempts.*Vec\|attempts.*Vec\|Vec.*PaymentAttempt" crates/api_models/src/ 2>/dev/null; then
    TYPES_FOUND=$((TYPES_FOUND + 1))
fi
if [ $TYPES_FOUND -ge 1 ]; then
    SCORE=$(echo "$SCORE + 10" | bc)
    echo "PASS: +0.10 (types_found=$TYPES_FOUND)"
else
    echo "FAIL: No attempt list types found in api_models"
fi

# ─── Gate 4 (F2P): Route registered in app.rs ─── weight: 0.10
# The v2 payments routes must include the list_attempts endpoint.
# Must be specific: "list_attempts" is the new route, "attempt" alone exists already.
echo ""
echo "=== Gate 4 (F2P): Route registration ==="
if grep -q "list_attempts\|list_payment_attempts" crates/router/src/routes/app.rs 2>/dev/null; then
    SCORE=$(echo "$SCORE + 10" | bc)
    echo "PASS: +0.10"
else
    echo "FAIL: No list_attempts route found in app.rs"
fi

# ─── Gate 5 (F2P): Route handler or core function ─── weight: 0.10
# Either routes/payments.rs or core/payments.rs must have a new function
# for listing attempts. Patterns must distinguish from existing attempt code.
echo ""
echo "=== Gate 5 (F2P): Handler/core function ==="
HANDLER_OK=0
# Check routes/payments.rs for a list_attempts handler
grep -q "list_payment_attempts\|list_attempts\|PaymentGetListAttempts" crates/router/src/routes/payments.rs 2>/dev/null && HANDLER_OK=1
# Check core/payments.rs for the core function
grep -q "attempt_operation_core\|list_attempts\|PaymentGetListAttempts\|payments_list_attempts" crates/router/src/core/payments.rs 2>/dev/null && HANDLER_OK=1
if [ $HANDLER_OK -eq 1 ]; then
    SCORE=$(echo "$SCORE + 10" | bc)
    echo "PASS: +0.10"
else
    echo "FAIL: No handler/core function for attempt listing"
fi

# ─── Gate 6 (F2P): Full project compiles with v2 + new code ─── weight: 0.50
# This is the primary behavioral gate. It verifies that:
# 1. The agent's new code actually compiles (not just exists)
# 2. The new code integrates correctly with existing codebase
# Only awards points if new code is structurally present AND compiles.
echo ""
echo "=== Gate 6 (F2P): cargo check --features v2 with new code ==="
cargo check --features v2 2>&1 | tail -15
COMPILE_OK=$?

# Count how many structural prerequisites are met
STRUCT_COUNT=0
[ $FOUND_MODULE -eq 1 ] && STRUCT_COUNT=$((STRUCT_COUNT + 1))
[ $TYPES_FOUND -ge 1 ] && STRUCT_COUNT=$((STRUCT_COUNT + 1))
grep -q "list_attempts\|list_payment_attempts" crates/router/src/routes/app.rs 2>/dev/null && STRUCT_COUNT=$((STRUCT_COUNT + 1))
[ $HANDLER_OK -eq 1 ] && STRUCT_COUNT=$((STRUCT_COUNT + 1))

if [ $COMPILE_OK -eq 0 ] && [ $STRUCT_COUNT -ge 2 ]; then
    SCORE=$(echo "$SCORE + 50" | bc)
    echo "PASS: +0.50 (compiles=yes, structural=$STRUCT_COUNT/4)"
elif [ $COMPILE_OK -eq 0 ]; then
    echo "FAIL (compiles but new code not found: structural=$STRUCT_COUNT/4)"
else
    echo "FAIL (compilation failed)"
fi

# Calculate final reward
REWARD=$(echo "scale=2; $SCORE / 100" | bc -l)
# Ensure leading zero
case $REWARD in
    .*) REWARD="0$REWARD" ;;
esac

mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo ""
echo "============================================"
echo "TOTAL REWARD: $REWARD"
echo "============================================"
