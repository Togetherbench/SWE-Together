#!/bin/bash
set +e

# Verifier for hyperswitch-8338: refactor auth analytics to support profile, org and merchant level auth
# Core principle: a no-op patch MUST produce 0.0. All reward comes from F2P behavioral changes.

REPO_DIR="/workspace/hyperswitch"
ROUTER_ANALYTICS="$REPO_DIR/crates/router/src/analytics.rs"
AUTH_DIR="$REPO_DIR/crates/analytics/src/auth_events"
AUTH_CORE="$AUTH_DIR/core.rs"
AUTH_FILTERS="$AUTH_DIR/filters.rs"
AUTH_METRICS="$AUTH_DIR/metrics.rs"
AUTH_METRICS_DIR="$AUTH_DIR/metrics"
ANALYTICS_LIB="$REPO_DIR/crates/analytics/src/lib.rs"

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
REWARD=0.0

# Make cargo available
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for c in /root/.cargo/bin/cargo /usr/local/cargo/bin/cargo /usr/bin/cargo; do
        [ -x "$c" ] && export PATH="$(dirname $c):$PATH" && break
    done
fi

# ============================================================================
# P2P gating: must have repo and required source files. If missing, exit 0.0.
# These checks pass on the unmodified base too (they exist there) — they
# do NOT contribute reward, only short-circuit on environmental failure.
# ============================================================================
if [ ! -d "$REPO_DIR" ]; then
    echo "Repo missing"; echo "0.0" > "$REWARD_FILE"; exit 0
fi
for f in "$ROUTER_ANALYTICS" "$AUTH_CORE" "$AUTH_FILTERS" "$AUTH_METRICS" "$ANALYTICS_LIB"; do
    if [ ! -f "$f" ]; then
        echo "Missing required file: $f"; echo "0.0" > "$REWARD_FILE"; exit 0
    fi
done
if [ ! -d "$AUTH_METRICS_DIR" ]; then
    echo "Missing metrics dir"; echo "0.0" > "$REWARD_FILE"; exit 0
fi

cd "$REPO_DIR" || { echo "0.0" > "$REWARD_FILE"; exit 0; }

# ============================================================================
# F2P gates only. Each gate must FAIL on the no-op (buggy base) to award reward.
# Total weights sum to 1.0.
# ============================================================================

TOTAL_W=0
EARNED_W=0

award() {
    local weight=$1 pass=$2 desc=$3
    TOTAL_W=$(awk "BEGIN {printf \"%.4f\", $TOTAL_W + $weight}")
    if [ "$pass" -eq 0 ]; then
        EARNED_W=$(awk "BEGIN {printf \"%.4f\", $EARNED_W + $weight}")
        echo "PASS (w=$weight): $desc"
    else
        echo "FAIL (w=$weight): $desc"
    fi
}

# ----------------------------------------------------------------------------
# F2P Gate 1 (weight 0.18): The AuthEventMetric trait's load_metrics signature
# was changed from taking merchant_id to taking AuthInfo.
# On base: load_metrics takes &common_utils::id_type::MerchantId → FAIL
# On fix: takes &AuthInfo → PASS
# ----------------------------------------------------------------------------
G1=1
if [ -f "$AUTH_METRICS" ]; then
    # The trait must NOT have merchant_id param in load_metrics
    # AND must reference AuthInfo in load_metrics signature
    TRAIT_BLOCK=$(awk '
        /pub trait AuthEventMetric/,/^}/ {print}
    ' "$AUTH_METRICS" 2>/dev/null)
    if [ -n "$TRAIT_BLOCK" ]; then
        if echo "$TRAIT_BLOCK" | grep -q 'AuthInfo' && \
           ! echo "$TRAIT_BLOCK" | grep -q 'merchant_id.*MerchantId'; then
            G1=0
        fi
    fi
fi
award 0.18 $G1 "AuthEventMetric trait load_metrics uses AuthInfo (not merchant_id)"

# ----------------------------------------------------------------------------
# F2P Gate 2 (weight 0.18): At least 4 metric impl files migrated from
# merchant_id parameter to AuthInfo + auth.set_filter_clause.
# On base: 0 files use AuthInfo → FAIL
# On fix: most/all use AuthInfo → PASS
# ----------------------------------------------------------------------------
G2=1
MIG_COUNT=0
if [ -d "$AUTH_METRICS_DIR" ]; then
    for f in "$AUTH_METRICS_DIR"/*.rs; do
        [ -f "$f" ] || continue
        # File migrated if it references AuthInfo AND uses set_filter_clause via auth
        # AND no longer has add_filter_clause("merchant_id", merchant_id)
        if grep -q 'AuthInfo' "$f" 2>/dev/null && \
           grep -qE 'auth\.set_filter_clause|auth: &AuthInfo' "$f" 2>/dev/null && \
           ! grep -q 'add_filter_clause("merchant_id", merchant_id)' "$f" 2>/dev/null; then
            MIG_COUNT=$((MIG_COUNT + 1))
        fi
    done
fi
echo "Metric impl files migrated to AuthInfo: $MIG_COUNT"
if [ "$MIG_COUNT" -ge 4 ]; then G2=0; fi
award 0.18 $G2 "≥4 metric impls migrated from merchant_id to AuthInfo"

# ----------------------------------------------------------------------------
# F2P Gate 3 (weight 0.10): filters.rs get_auth_events_filter_for_dimension
# now takes AuthInfo instead of merchant_id.
# On base: takes &common_utils::id_type::MerchantId → FAIL
# On fix: takes &AuthInfo → PASS
# ----------------------------------------------------------------------------
G3=1
if [ -f "$AUTH_FILTERS" ]; then
    FN_BLOCK=$(awk '
        /pub async fn get_auth_events_filter_for_dimension/,/^[[:space:]]*\{/ {print}
    ' "$AUTH_FILTERS" 2>/dev/null)
    if [ -n "$FN_BLOCK" ]; then
        if echo "$FN_BLOCK" | grep -q 'AuthInfo' && \
           ! echo "$FN_BLOCK" | grep -q 'merchant_id.*MerchantId'; then
            G3=0
        fi
    fi
fi
award 0.10 $G3 "filters.rs get_auth_events_filter_for_dimension uses AuthInfo"

# ----------------------------------------------------------------------------
# F2P Gate 4 (weight 0.12): analytics/src/lib.rs get_auth_event_metrics
# function signature changed from merchant_id → auth: &AuthInfo.
# On base: signature has merchant_id MerchantId → FAIL
# On fix: signature uses AuthInfo → PASS
# ----------------------------------------------------------------------------
G4=1
if [ -f "$ANALYTICS_LIB" ]; then
    LIB_FN=$(awk '
        /pub async fn get_auth_event_metrics/,/^[[:space:]]*\{[[:space:]]*$/ {print}
    ' "$ANALYTICS_LIB" 2>/dev/null)
    if [ -n "$LIB_FN" ]; then
        if echo "$LIB_FN" | grep -q 'AuthInfo' && \
           ! echo "$LIB_FN" | grep -qE 'merchant_id:\s*&common_utils::id_type::MerchantId'; then
            G4=0
        fi
    fi
fi
award 0.12 $G4 "analytics lib get_auth_event_metrics uses AuthInfo"

# ----------------------------------------------------------------------------
# F2P Gate 5 (weight 0.14): Org-scope auth_events endpoint registered.
# On base: only /merchant has metrics/auth_events → FAIL
# On fix: /org scope registers metrics/auth_events route → PASS
# ----------------------------------------------------------------------------
G5=1
if [ -f "$ROUTER_ANALYTICS" ]; then
    # Extract /org scope block content (heuristic: scope("/org") through next scope() at similar indent)
    ORG_BLOCK=$(awk '
        /web::scope\("\/org"\)/ {found=1}
        found {print}
        found && /web::scope\("\/profile"\)/ {exit}
    ' "$ROUTER_ANALYTICS" 2>/dev/null)
    if [ -n "$ORG_BLOCK" ] && echo "$ORG_BLOCK" | grep -q 'metrics/auth_events'; then
        G5=0
    fi
fi
award 0.14 $G5 "Org-scope auth_events endpoint registered"

# ----------------------------------------------------------------------------
# F2P Gate 6 (weight 0.14): Profile-scope auth_events endpoint registered.
# On base: /profile scope lacks auth_events → FAIL
# On fix: /profile registers metrics/auth_events → PASS
# ----------------------------------------------------------------------------
G6=1
if [ -f "$ROUTER_ANALYTICS" ]; then
    PROFILE_BLOCK=$(awk '
        /web::scope\("\/profile"\)/ {found=1; depth=0}
        found {
            print
            n=gsub(/\.service/,"&")
            if ($0 ~ /^[[:space:]]+\)\,?[[:space:]]*$/) {
                rparen++
                if (rparen >= 8) exit
            }
        }
    ' "$ROUTER_ANALYTICS" 2>/dev/null)
    # Simpler approach: just check that there are ≥2 distinct route registrations to auth_events
    # AND that auth_events appears in close proximity to "/profile" scope
    AE_TOTAL=$(grep -c 'metrics/auth_events' "$ROUTER_ANALYTICS" 2>/dev/null)
    [ -z "$AE_TOTAL" ] && AE_TOTAL=0
    # Look for evidence of profile-level auth events handler
    if grep -qE 'profile.*auth_event|get_profile_auth_event' "$ROUTER_ANALYTICS" 2>/dev/null && \
       [ "$AE_TOTAL" -ge 2 ]; then
        G6=0
    fi
fi
award 0.14 $G6 "Profile-scope auth_events endpoint/handler registered"

# ----------------------------------------------------------------------------
# F2P Gate 7 (weight 0.14): At least 3 distinct metrics/auth_events route
# registrations exist (merchant + org + profile). On base, typically only 1
# (merchant) exists, so this fails. On fix, ≥3 exist.
# ----------------------------------------------------------------------------
G7=1
if [ -f "$ROUTER_ANALYTICS" ]; then
    AE_REGS=$(grep -c 'metrics/auth_events"' "$ROUTER_ANALYTICS" 2>/dev/null)
    [ -z "$AE_REGS" ] && AE_REGS=0
    # Also accept distinct handler names: get_auth_event_metrics, get_org_auth_event_metrics, get_profile_auth_event_metrics
    HANDLERS=0
    grep -qE '\bget_auth_event_metrics\b' "$ROUTER_ANALYTICS" 2>/dev/null && HANDLERS=$((HANDLERS+1))
    grep -qE '\bget_org_auth_event_metrics\b|\bget_org_auth_events?\b' "$ROUTER_ANALYTICS" 2>/dev/null && HANDLERS=$((HANDLERS+1))
    grep -qE '\bget_profile_auth_event_metrics\b|\bget_profile_auth_events?\b' "$ROUTER_ANALYTICS" 2>/dev/null && HANDLERS=$((HANDLERS+1))
    echo "auth_events route registrations: $AE_REGS, distinct handler families: $HANDLERS"
    if [ "$AE_REGS" -ge 3 ] || [ "$HANDLERS" -ge 3 ]; then
        G7=0
    fi
fi
award 0.14 $G7 "≥3 auth_events route registrations (merchant+org+profile)"

# ============================================================================
# Final reward = sum of earned F2P weights, rounded to 0.01.
# Total possible: 0.18 + 0.18 + 0.10 + 0.12 + 0.14 + 0.14 + 0.14 = 1.00
# ============================================================================
echo ""
echo "Total weight allocated: $TOTAL_W"
echo "Earned weight: $EARNED_W"

REWARD=$(awk "BEGIN {printf \"%.2f\", $EARNED_W}")

# Safety: if a no-op patch somehow scored anything, this should still report it
# correctly. We rely on the fact that none of the F2P checks above pass on the
# unmodified base.

echo "$REWARD" > "$REWARD_FILE"
echo "Final reward: $REWARD"
exit 0