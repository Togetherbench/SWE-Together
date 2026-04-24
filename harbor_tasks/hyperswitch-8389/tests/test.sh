#!/bin/bash
# Verifier for hyperswitch-8389: KV Redis feature for V2 models
#
# Tests check for correct V2 KV Redis support implementation:
# - V2 route handlers with proper auth
# - V2 route registration
# - V2 OpenAPI docs
# - Proper V1/V2 feature gating (CRITICAL for compilation)
# - Storage and diesel model changes
#
# BASE STATE (commit c5c0e67): No V2 KV support exists.

set -euo pipefail

REPO_DIR="/workspace/hyperswitch"
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

TOTAL=0
PASSED=0

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo "PASS: $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    echo "FAIL: $1"
}

cd "$REPO_DIR"

BASE_COMMIT="c5c0e677f2a2d43170a66330c98e0ebc4d771717"
ADMIN_RS="crates/router/src/routes/admin.rs"
APP_RS="crates/router/src/routes/app.rs"
OPENAPI_RS="crates/openapi/src/routes/merchant_account.rs"

# Helper: check if file was changed from base
file_changed() {
    local file="$1"
    local base_content curr_content
    base_content=$(git show "${BASE_COMMIT}:${file}" 2>/dev/null || echo "__MISSING__")
    curr_content=$(cat "$file" 2>/dev/null || echo "__MISSING2__")
    [ "$base_content" != "$curr_content" ]
}

# ============================================================
# TEST 1: admin.rs has V2 KV toggle function
# Base: 1 kv_for_merchant call. V2 adds a second.
# ============================================================
KV_MERCHANT_COUNT=$(grep -c 'kv_for_merchant' "$ADMIN_RS" 2>/dev/null || echo "0")
if [ "$KV_MERCHANT_COUNT" -ge 2 ]; then
    pass "T1: V2 KV toggle function added ($KV_MERCHANT_COUNT kv_for_merchant calls)"
else
    fail "T1: No V2 KV toggle (kv_for_merchant count: $KV_MERCHANT_COUNT)"
fi

# ============================================================
# TEST 2: V2 KV toggle uses V2AdminApiAuth
# ============================================================
KV_LINES=$(grep -n 'kv_for_merchant' "$ADMIN_RS" 2>/dev/null | cut -d: -f1)
FOUND_V2_AUTH=0
for line in $KV_LINES; do
    START=$((line - 20))
    END=$((line + 10))
    if [ "$START" -lt 1 ]; then START=1; fi
    if sed -n "${START},${END}p" "$ADMIN_RS" 2>/dev/null | grep -qE 'V2AdminApiAuth'; then
        FOUND_V2_AUTH=1
        break
    fi
done
if [ "$FOUND_V2_AUTH" -eq 1 ]; then
    pass "T2: V2 KV toggle uses V2AdminApiAuth"
else
    fail "T2: V2AdminApiAuth not found near kv_for_merchant"
fi

# ============================================================
# TEST 3: app.rs V2 MerchantAccount block registers /kv route
# ============================================================
FOUND_V2_KV=0
while IFS= read -r line_num; do
    PREV_START=$((line_num - 3))
    if [ "$PREV_START" -lt 1 ]; then PREV_START=1; fi
    CONTEXT=$(sed -n "${PREV_START},${line_num}p" "$APP_RS" 2>/dev/null)
    if echo "$CONTEXT" | grep -qE 'cfg.*v2.*olap|cfg.*olap.*v2'; then
        BLOCK=$(sed -n "${line_num},$((line_num + 40))p" "$APP_RS" 2>/dev/null | sed '/^#\[cfg/q' | head -n -1)
        if echo "$BLOCK" | grep -q 'v2/merchant-accounts' && echo "$BLOCK" | grep -qE '"/kv"|/kv\)|toggle_kv'; then
            FOUND_V2_KV=1
            break
        fi
    fi
done < <(grep -n 'impl MerchantAccount' "$APP_RS" 2>/dev/null | cut -d: -f1)
if [ "$FOUND_V2_KV" -eq 1 ]; then
    pass "T3: V2 MerchantAccount block has /kv route"
else
    fail "T3: V2 MerchantAccount block missing /kv route"
fi

# ============================================================
# TEST 4: OpenAPI V2 KV endpoint documentation
# ============================================================
if file_changed "$OPENAPI_RS"; then
    if grep -qE 'v2/merchant.accounts.*kv|v2.*accounts.*kv' "$OPENAPI_RS" 2>/dev/null; then
        pass "T4: OpenAPI has V2 KV endpoint path"
    elif grep -B2 -A5 'cfg.*v2' "$OPENAPI_RS" 2>/dev/null | grep -qiE 'kv|toggle'; then
        pass "T4: OpenAPI has V2-gated KV docs"
    else
        fail "T4: OpenAPI changed but no V2 KV endpoint"
    fi
else
    fail "T4: OpenAPI not modified"
fi

# ============================================================
# TEST 5: V1 merchant_account_toggle_kv properly feature-gated
# CRITICAL: Without cfg(v1) on V1 version, having duplicate function names
# (V1 ungated + V2 with cfg(v2)) causes compilation failure.
# Check: the FIRST occurrence of merchant_account_toggle_kv must have cfg(v1).
# ============================================================
FIRST_TOGGLE_LINE=$(grep -n 'pub async fn merchant_account_toggle_kv' "$ADMIN_RS" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$FIRST_TOGGLE_LINE" ]; then
    GATE_START=$((FIRST_TOGGLE_LINE - 5))
    if [ "$GATE_START" -lt 1 ]; then GATE_START=1; fi
    GATE_CONTEXT=$(sed -n "${GATE_START},${FIRST_TOGGLE_LINE}p" "$ADMIN_RS" 2>/dev/null)
    TOGGLE_COUNT=$(grep -c 'pub async fn merchant_account_toggle_kv' "$ADMIN_RS" 2>/dev/null || echo "0")
    if [ "$TOGGLE_COUNT" -lt 2 ]; then
        fail "T5: Only $TOGGLE_COUNT toggle_kv version(s) - V2 version not added"
    elif echo "$GATE_CONTEXT" | grep -qE 'cfg.*feature.*"v1"'; then
        pass "T5: V1 toggle_kv properly gated with cfg(v1)"
    else
        fail "T5: V1 toggle_kv MISSING cfg(v1) gate (compile error risk)"
    fi
else
    fail "T5: merchant_account_toggle_kv not found"
fi

# ============================================================
# TEST 6: V1 merchant_account_kv_status properly feature-gated
# Same issue: the V1 kv_status function needs cfg(v1) when a V2 version exists.
# ============================================================
FIRST_STATUS_LINE=$(grep -n 'pub async fn merchant_account_kv_status' "$ADMIN_RS" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$FIRST_STATUS_LINE" ]; then
    GATE_START=$((FIRST_STATUS_LINE - 5))
    if [ "$GATE_START" -lt 1 ]; then GATE_START=1; fi
    GATE_CONTEXT=$(sed -n "${GATE_START},${FIRST_STATUS_LINE}p" "$ADMIN_RS" 2>/dev/null)
    STATUS_COUNT=$(grep -c 'pub async fn merchant_account_kv_status' "$ADMIN_RS" 2>/dev/null || echo "0")
    if [ "$STATUS_COUNT" -lt 2 ]; then
        fail "T6: Only $STATUS_COUNT kv_status version(s) - V2 version not added"
    elif echo "$GATE_CONTEXT" | grep -qE 'cfg.*feature.*"v1"'; then
        pass "T6: V1 kv_status properly gated with cfg(v1)"
    else
        fail "T6: V1 kv_status MISSING cfg(v1) gate (compile error risk)"
    fi
else
    fail "T6: merchant_account_kv_status not found"
fi

# ============================================================
# TEST 7: Agent committed changes
# ============================================================
CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ "$CURRENT_HEAD" != "$BASE_COMMIT" ] && [ -n "$CURRENT_HEAD" ]; then
    pass "T7: Agent committed changes"
else
    CHANGED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
    if [ "$CHANGED_FILES" -gt 0 ]; then
        pass "T7: Agent made changes ($CHANGED_FILES files, not committed)"
    else
        fail "T7: No changes detected"
    fi
fi

# ============================================================
# TEST 8: storage_impl payment files modified for V2 KV support
# ============================================================
PI_CHANGED=0
PA_CHANGED=0
if file_changed "crates/storage_impl/src/payments/payment_intent.rs" 2>/dev/null; then PI_CHANGED=1; fi
if file_changed "crates/storage_impl/src/payments/payment_attempt.rs" 2>/dev/null; then PA_CHANGED=1; fi
STORAGE_CHANGED=$((PI_CHANGED + PA_CHANGED))
if [ "$STORAGE_CHANGED" -ge 1 ]; then
    pass "T8: storage_impl payment files modified ($STORAGE_CHANGED files)"
else
    if file_changed "crates/storage_impl/src/payments.rs" 2>/dev/null || \
       file_changed "crates/storage_impl/src/lib.rs" 2>/dev/null; then
        pass "T8: storage_impl modified (alternative location)"
    else
        fail "T8: No storage_impl payment files modified"
    fi
fi

# ============================================================
# TEST 9: diesel_models V2 KV changes
# ============================================================
DIESEL_CHANGED=0
for f in "crates/diesel_models/src/kv.rs" "crates/diesel_models/src/payment_intent.rs" "crates/diesel_models/src/payment_attempt.rs"; do
    if file_changed "$f" 2>/dev/null; then
        DIESEL_CHANGED=$((DIESEL_CHANGED + 1))
    fi
done
if [ "$DIESEL_CHANGED" -ge 1 ]; then
    pass "T9: diesel_models modified ($DIESEL_CHANGED files)"
else
    if file_changed "crates/storage_impl/src/payments.rs" 2>/dev/null && \
       grep -qE 'cfg.*v2' "crates/storage_impl/src/payments.rs" 2>/dev/null; then
        pass "T9: V2 KvStorePartition in payments.rs (alternative)"
    else
        fail "T9: No diesel_models or V2 KvStorePartition changes"
    fi
fi

# ============================================================
# TEST 10: Comprehensive scope (>= 7 files changed)
# A thorough implementation touches admin.rs, app.rs, openapi, storage_impl
# payment files, diesel_models, and possibly lib.rs. Minimal solutions
# that miss integration points score lower.
# ============================================================
if [ "$CURRENT_HEAD" != "$BASE_COMMIT" ] && [ -n "$CURRENT_HEAD" ]; then
    TOTAL_CHANGED=$(git diff "${BASE_COMMIT}" --name-only 2>/dev/null | wc -l)
else
    TOTAL_CHANGED=$(git diff --name-only 2>/dev/null | wc -l)
fi
if [ "$TOTAL_CHANGED" -ge 7 ]; then
    pass "T10: Comprehensive scope ($TOTAL_CHANGED files)"
else
    fail "T10: Limited scope ($TOTAL_CHANGED files, need >= 7)"
fi

# ============================================================
# Calculate reward
# ============================================================
if [ "$TOTAL" -eq 0 ]; then
    REWARD="0.0"
else
    REWARD=$(awk "BEGIN {printf \"%.2f\", $PASSED / $TOTAL}")
fi

echo ""
echo "===== RESULTS ====="
echo "Passed: $PASSED / $TOTAL"
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
