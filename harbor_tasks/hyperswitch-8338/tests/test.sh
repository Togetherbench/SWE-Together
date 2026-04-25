#!/bin/bash
set +e

# Test script for hyperswitch-8338: refactor auth analytics to support profile, org and merchant level auth
# Strategy: Heavily favor behavioral verification (cargo check) over grep matching.

REPO_DIR="/workspace/hyperswitch"
ROUTER_ANALYTICS="$REPO_DIR/crates/router/src/analytics.rs"
AUTH_DIR="$REPO_DIR/crates/analytics/src/auth_events"
AUTH_CORE="$AUTH_DIR/core.rs"
AUTH_FILTERS="$AUTH_DIR/filters.rs"
AUTH_METRICS="$AUTH_DIR/metrics.rs"
AUTH_METRICS_DIR="$AUTH_DIR/metrics"
ANALYTICS_LIB="$REPO_DIR/crates/analytics/src/lib.rs"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

# Make cargo available
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.cargo/bin/cargo /usr/local/cargo/bin/cargo /usr/bin/cargo; do
        [ -x "$c" ] && export PATH="$(dirname $c):$PATH" && break
    done
fi

TOTAL_W=0
EARNED_W=0

gate() {
    local weight=$1 pass=$2 desc=$3 type=$4
    TOTAL_W=$(awk "BEGIN {printf \"%.4f\", $TOTAL_W + $weight}")
    if [ "$pass" -eq 0 ]; then
        EARNED_W=$(awk "BEGIN {printf \"%.4f\", $EARNED_W + $weight}")
        echo "PASS ($type, w=$weight): $desc"
    else
        echo "FAIL ($type, w=$weight): $desc"
    fi
}

# ============================================================================
# Gate 1 — P2P (weight 0.05): Source structure intact
# ============================================================================
P2P_RESULT=1
if [ -f "$ROUTER_ANALYTICS" ] && [ -f "$AUTH_CORE" ] && [ -f "$AUTH_FILTERS" ] && \
   [ -f "$AUTH_METRICS" ] && [ -f "$ANALYTICS_LIB" ] && [ -d "$AUTH_METRICS_DIR" ]; then
    P2P_RESULT=0
fi
gate 0.05 $P2P_RESULT "Base analytics source files exist" "P2P"

# ============================================================================
# Run cargo check ONCE — gates the heavy behavioral weight
# ============================================================================
cd "$REPO_DIR" || { echo "$REPO_DIR not found"; echo "0.00" > "$REWARD_FILE"; exit 0; }

CARGO_LOG=$(mktemp)
CARGO_OK=1
echo "Running cargo check -p analytics -p router (this may take a while)..."
timeout 900 cargo check -p analytics -p router --message-format=short > "$CARGO_LOG" 2>&1
CARGO_EXIT=$?
if [ "$CARGO_EXIT" -eq 0 ]; then
    CARGO_OK=0
    echo "cargo check PASSED"
else
    echo "cargo check FAILED (exit $CARGO_EXIT). Last 30 lines:"
    tail -30 "$CARGO_LOG"
fi

# ============================================================================
# Gate 2 — F2P (weight 0.30): Workspace compiles cleanly
# This is the largest behavioral signal — refactoring an API that touches many
# call sites is only verified correct if everything still type-checks.
# ============================================================================
gate 0.30 $CARGO_OK "Cargo check (analytics + router) compiles" "F2P"

# ============================================================================
# Gate 3 — F2P (weight 0.20): AuthInfo plumbed through metrics pipeline
# Verified ONLY through a successful build that also shows the trait signature
# was changed (load_metrics now takes an AuthInfo). We test by building a
# small probe that checks the symbol presence via cargo doc/check would be
# excessive; instead we inspect compiled artifact by matching trait signature
# in source (this is signature-level not arbitrary string).
# ============================================================================
AUTH_TRAIT_RESULT=1
if [ "$CARGO_OK" -eq 0 ]; then
    # Trait must take auth: &AuthInfo (any name with AuthInfo type)
    if grep -Pzo '(?s)trait\s+AuthEventMetric.*?fn\s+load_metrics\s*\([^)]*AuthInfo' "$AUTH_METRICS" >/dev/null 2>&1; then
        AUTH_TRAIT_RESULT=0
    fi
    # Fallback: looser check across the file
    if [ "$AUTH_TRAIT_RESULT" -ne 0 ]; then
        if grep -A 15 'fn load_metrics' "$AUTH_METRICS" 2>/dev/null | grep -q 'AuthInfo'; then
            AUTH_TRAIT_RESULT=0
        fi
    fi
fi
gate 0.20 $AUTH_TRAIT_RESULT "AuthEventMetric trait load_metrics takes AuthInfo (compiles)" "F2P"

# ============================================================================
# Gate 4 — F2P (weight 0.15): At least 3 metric impl files migrated to AuthInfo
# Requires that individual metric modules use auth.set_filter_clause OR accept
# &AuthInfo. Counts unique files. Compilation-gated.
# ============================================================================
METRIC_MIG_RESULT=1
if [ "$CARGO_OK" -eq 0 ] && [ -d "$AUTH_METRICS_DIR" ]; then
    MIG_COUNT=0
    for f in "$AUTH_METRICS_DIR"/*.rs; do
        [ -f "$f" ] || continue
        # File migrated if it references AuthInfo AND no longer takes merchant_id as primary param
        if grep -q 'AuthInfo' "$f" 2>/dev/null; then
            if grep -q 'auth.*set_filter_clause\|auth\.set_filter_clause' "$f" 2>/dev/null || \
               grep -qE 'auth\s*:\s*&AuthInfo' "$f" 2>/dev/null; then
                MIG_COUNT=$((MIG_COUNT + 1))
            fi
        fi
    done
    echo "Metric files migrated to AuthInfo: $MIG_COUNT"
    if [ "$MIG_COUNT" -ge 3 ]; then
        METRIC_MIG_RESULT=0
    fi
fi
gate 0.15 $METRIC_MIG_RESULT "≥3 auth_event metric impls migrated to AuthInfo + set_filter_clause" "F2P"

# ============================================================================
# Gate 5 — F2P (weight 0.20): Org AND Profile level endpoints registered
# Verifies actual endpoint registration in route table — both /org and /profile
# scopes must register auth_events metrics handlers. Compilation-gated.
# ============================================================================
ENDPOINT_RESULT=1
if [ "$CARGO_OK" -eq 0 ] && [ -f "$ROUTER_ANALYTICS" ]; then
    # Extract /org scope block, look for metrics/auth_events
    ORG_HIT=0
    PROF_HIT=0
    MERCH_HIT=0

    # Use awk to scan scope-bound blocks for registration of auth_events route
    # Look for any handler invocation matching org+auth_event*
    if grep -E 'route.*to\(\s*get_org_auth_event' "$ROUTER_ANALYTICS" >/dev/null 2>&1 || \
       grep -E 'route.*to\(\s*\w*org\w*auth_event' "$ROUTER_ANALYTICS" >/dev/null 2>&1; then
        ORG_HIT=1
    fi
    if grep -E 'route.*to\(\s*get_profile_auth_event' "$ROUTER_ANALYTICS" >/dev/null 2>&1 || \
       grep -E 'route.*to\(\s*\w*profile\w*auth_event' "$ROUTER_ANALYTICS" >/dev/null 2>&1; then
        PROF_HIT=1
    fi
    if grep -E 'route.*to\(\s*get_auth_event_metrics\)|to\(\s*\w*merchant\w*auth_event' "$ROUTER_ANALYTICS" >/dev/null 2>&1 || \
       grep -E 'metrics/auth_events.*get_auth_event_metrics' "$ROUTER_ANALYTICS" >/dev/null 2>&1; then
        MERCH_HIT=1
    fi

    # Also accept inline scope-based hits via line proximity
    # Count distinct "metrics/auth_events" registrations
    AE_REGS=$(grep -c 'metrics/auth_events' "$ROUTER_ANALYTICS" 2>/dev/null)
    [ -z "$AE_REGS" ] && AE_REGS=0

    SUM=$((ORG_HIT + PROF_HIT + MERCH_HIT))
    echo "Endpoint hits: org=$ORG_HIT profile=$PROF_HIT merchant=$MERCH_HIT total_auth_events_routes=$AE_REGS"
    if [ "$ORG_HIT" -eq 1 ] && [ "$PROF_HIT" -eq 1 ] && [ "$AE_REGS" -ge 2 ]; then
        ENDPOINT_RESULT=0
    elif [ "$SUM" -ge 2 ] && [ "$AE_REGS" -ge 2 ]; then
        # Partial credit path won't apply (binary gate) — keep strict
        :
    fi
fi
gate 0.20 $ENDPOINT_RESULT "Org + Profile auth_events endpoints registered (compiles)" "F2P"

# ============================================================================
# Gate 6 — F2P (weight 0.05): Filter API uses AuthInfo
# filters.rs get_auth_events_filter_for_dimension takes &AuthInfo
# ============================================================================
FILTER_AUTH_RESULT=1
if [ "$CARGO_OK" -eq 0 ] && [ -f "$AUTH_FILTERS" ]; then
    if grep -A 8 'fn get_auth_events_filter_for_dimension' "$AUTH_FILTERS" 2>/dev/null | grep -q 'AuthInfo'; then
        FILTER_AUTH_RESULT=0
    fi
fi
gate 0.05 $FILTER_AUTH_RESULT "filters.rs get_auth_events_filter_for_dimension takes AuthInfo" "F2P"

# ============================================================================
# Gate 7 — Structural (weight 0.05): Provider lib.rs uses AuthInfo
# AnalyticsProvider::get_auth_event_metrics threads AuthInfo through.
# ============================================================================
PROVIDER_RESULT=1
if [ "$CARGO_OK" -eq 0 ] && [ -f "$ANALYTICS_LIB" ]; then
    if grep -A 12 'fn get_auth_event_metrics' "$ANALYTICS_LIB" 2>/dev/null | grep -q 'AuthInfo'; then
        PROVIDER_RESULT=0
    fi
fi
gate 0.05 $PROVIDER_RESULT "AnalyticsProvider::get_auth_event_metrics uses AuthInfo" "STRUCT"

# ============================================================================
# Final reward
# ============================================================================
echo ""
echo "=== Results: earned=$EARNED_W / total=$TOTAL_W ==="
if awk "BEGIN {exit !($TOTAL_W > 0)}"; then
    REWARD=$(awk "BEGIN {printf \"%.2f\", $EARNED_W / $TOTAL_W}")
else
    REWARD="0.00"
fi
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"

rm -f "$CARGO_LOG"