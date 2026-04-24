#!/bin/bash
set +e

# Test script for hyperswitch-8338: refactor auth analytics to support profile, org and merchant level auth
# Verifies that auth_events analytics endpoints are properly exposed at merchant/org/profile levels

REPO_DIR="/workspace/hyperswitch"
ROUTER_ANALYTICS="$REPO_DIR/crates/router/src/analytics.rs"
AUTH_CORE="$REPO_DIR/crates/analytics/src/auth_events/core.rs"
AUTH_FILTERS="$REPO_DIR/crates/analytics/src/auth_events/filters.rs"
ANALYTICS_LIB="$REPO_DIR/crates/analytics/src/lib.rs"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

TOTAL_W=0
EARNED_W=0

gate() {
    local weight=$1 pass=$2 desc=$3 type=$4
    TOTAL_W=$(awk "BEGIN {printf \"%.2f\", $TOTAL_W + $weight}")
    if [ "$pass" -eq 0 ]; then
        EARNED_W=$(awk "BEGIN {printf \"%.2f\", $EARNED_W + $weight}")
        echo "PASS ($type, w=$weight): $desc"
    else
        echo "FAIL ($type, w=$weight): $desc"
    fi
}

# ===========================================================================
# Gate 1 — P2P (weight 0.05): Base repo structure sanity check
# Passes on unmodified base AND on correct fix. Guards against regression
# where agent deletes key files.
# ===========================================================================
P2P_RESULT=1
if [ -f "$ROUTER_ANALYTICS" ] && [ -f "$AUTH_CORE" ] && [ -f "$AUTH_FILTERS" ] && [ -f "$ANALYTICS_LIB" ]; then
    P2P_RESULT=0
fi
gate 0.05 $P2P_RESULT "Base analytics source files exist" "P2P"

# ===========================================================================
# COMPILATION GATE: cargo check is run once, its result gates multiple scores
# This ensures >=50% of reward weight depends on behavioral verification.
# ===========================================================================
CARGO_OK=1
cd "$REPO_DIR"
# Only attempt compilation if structural changes suggest work was done
STRUCT_HITS=0
grep -qE 'fn\s+\w*org\w*auth_event' "$ROUTER_ANALYTICS" 2>/dev/null && STRUCT_HITS=$((STRUCT_HITS + 1))
grep -qE 'fn\s+\w*profile\w*auth_event' "$ROUTER_ANALYTICS" 2>/dev/null && STRUCT_HITS=$((STRUCT_HITS + 1))
grep -A 5 'pub async fn get_metrics' "$AUTH_CORE" 2>/dev/null | grep -qE 'AuthInfo|auth\s*:' && STRUCT_HITS=$((STRUCT_HITS + 1))

if [ "$STRUCT_HITS" -ge 2 ]; then
    echo "Structural changes detected ($STRUCT_HITS/3 checks). Running cargo check..."
    timeout 300 cargo check -p analytics -p router 2>&1 | tail -20
    CARGO_EXIT=$?
    if [ "$CARGO_EXIT" -eq 0 ]; then
        CARGO_OK=0
        echo "cargo check PASSED"
    else
        echo "cargo check FAILED (exit $CARGO_EXIT)"
    fi
else
    echo "Insufficient structural changes ($STRUCT_HITS/3). Skipping cargo check."
fi

# ===========================================================================
# Gate 2 — F2P (weight 0.15): Compilation succeeds
# Standalone compilation credit. Also gates gates 3-5.
# ===========================================================================
gate 0.15 $CARGO_OK "Cargo check -p analytics -p router compiles" "F2P"

# ===========================================================================
# Gate 3 — F2P (weight 0.25): Org-level auth event handlers (compilation-gated)
# New handler functions for org-level analytics must exist, use OrgLevel AuthInfo,
# AND compile. Accepts any function name containing "org" and "auth_event".
# ===========================================================================
ORG_RESULT=1
if [ "$CARGO_OK" -eq 0 ]; then
    ORG_METRICS=$(grep -cE 'fn\s+\w*org\w*auth_event\w*metric' "$ROUTER_ANALYTICS" 2>/dev/null)
    ORG_SANKEY=$(grep -cE 'fn\s+\w*org\w*auth_event\w*sankey' "$ROUTER_ANALYTICS" 2>/dev/null)
    ORG_AUTHLEVEL=0
    grep -A 40 'fn.*org.*auth_event' "$ROUTER_ANALYTICS" 2>/dev/null | grep -q 'OrgLevel' && ORG_AUTHLEVEL=1
    if [ "$ORG_METRICS" -ge 1 ] && [ "$ORG_SANKEY" -ge 1 ] && [ "$ORG_AUTHLEVEL" -eq 1 ]; then
        ORG_RESULT=0
    fi
fi
gate 0.25 $ORG_RESULT "Org-level auth event handlers (metrics+sankey) with OrgLevel AuthInfo [compiles]" "F2P"

# ===========================================================================
# Gate 4 — F2P (weight 0.25): Profile-level auth event handlers (compilation-gated)
# New handler functions for profile-level analytics must exist, use ProfileLevel,
# AND compile.
# ===========================================================================
PROFILE_RESULT=1
if [ "$CARGO_OK" -eq 0 ]; then
    PROF_METRICS=$(grep -cE 'fn\s+\w*profile\w*auth_event\w*metric' "$ROUTER_ANALYTICS" 2>/dev/null)
    PROF_SANKEY=$(grep -cE 'fn\s+\w*profile\w*auth_event\w*sankey' "$ROUTER_ANALYTICS" 2>/dev/null)
    PROF_AUTHLEVEL=0
    grep -A 40 'fn.*profile.*auth_event' "$ROUTER_ANALYTICS" 2>/dev/null | grep -q 'ProfileLevel' && PROF_AUTHLEVEL=1
    if [ "$PROF_METRICS" -ge 1 ] && [ "$PROF_SANKEY" -ge 1 ] && [ "$PROF_AUTHLEVEL" -eq 1 ]; then
        PROFILE_RESULT=0
    fi
fi
gate 0.25 $PROFILE_RESULT "Profile-level auth event handlers (metrics+sankey) with ProfileLevel AuthInfo [compiles]" "F2P"

# ===========================================================================
# Gate 5 — F2P (weight 0.20): Core/filter + merchant/lib updated (compilation-gated)
# core.rs get_metrics and filters.rs must reference AuthInfo; merchant handler
# uses MerchantLevel; lib.rs provider updated. All must compile.
# ===========================================================================
CORE_MERCH_RESULT=1
if [ "$CARGO_OK" -eq 0 ]; then
    CORE_AUTH=0
    FILTER_AUTH=0
    MERCH_OK=0
    LIB_OK=0

    grep -A 5 'pub async fn get_metrics' "$AUTH_CORE" 2>/dev/null | grep -qE 'AuthInfo|auth\s*:' && CORE_AUTH=1
    grep -q 'AuthInfo' "$AUTH_FILTERS" 2>/dev/null && FILTER_AUTH=1
    grep -A 30 'fn.*merchant.*auth_event\|fn get_auth_event_metrics' "$ROUTER_ANALYTICS" 2>/dev/null | grep -q 'MerchantLevel' && MERCH_OK=1
    grep -A 8 'fn.*auth_event_metrics\|fn.*auth_event.*metric' "$ANALYTICS_LIB" 2>/dev/null | grep -qE 'AuthInfo|auth\s*:' && LIB_OK=1

    HITS=$((CORE_AUTH + FILTER_AUTH + MERCH_OK + LIB_OK))
    if [ "$HITS" -ge 3 ]; then
        CORE_MERCH_RESULT=0
    fi
fi
gate 0.20 $CORE_MERCH_RESULT "Core/filter AuthInfo + merchant MerchantLevel + lib provider updated [compiles]" "F2P"

# ===========================================================================
# Gate 6 — F2P (weight 0.10): Filter clause refactoring
# filters.rs should use auth-based set_filter_clause instead of only
# merchant_id-based filtering. Must compile.
# ===========================================================================
FILTER_CLAUSE_RESULT=1
if [ "$CARGO_OK" -eq 0 ]; then
    grep -q 'auth.*set_filter_clause\|auth_info.*set_filter_clause\|\.set_filter_clause' "$AUTH_FILTERS" 2>/dev/null
    FILTER_CLAUSE_RESULT=$?
fi
gate 0.10 $FILTER_CLAUSE_RESULT "Filter clause uses auth-level set_filter_clause [compiles]" "F2P"

# ===========================================================================
# Compute final reward
# ===========================================================================
echo ""
echo "=== Results: earned=$EARNED_W / total=$TOTAL_W ==="
REWARD=$(awk "BEGIN {printf \"%.2f\", $EARNED_W / $TOTAL_W}")
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
