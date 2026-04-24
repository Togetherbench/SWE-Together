#!/bin/bash
# Verifier for hyperswitch-8084: Add api-key support for routing APIs
#
# The fix removes all #[cfg(not(feature = "release"))] / #[cfg(feature = "release")]
# pairs from routing auth blocks in routing.rs, keeping the auth::auth_type() calls
# that support both API-key and JWT auth for all builds.
#
# Base state: 26 cfg(not(feature="release")) + 26 cfg(feature="release") in routing.rs
# Fixed state: 0 of each, with auth::auth_type() calls preserved

FILE="/workspace/hyperswitch/crates/router/src/routes/routing.rs"
mkdir -p /logs/verifier

PASS=0
TOTAL=0

check() {
    TOTAL=$((TOTAL + 1))
    if eval "$1"; then
        PASS=$((PASS + 1))
        echo "PASS: $2"
    else
        echo "FAIL: $2"
    fi
}

# Bail early if file doesn't exist
if [ ! -f "$FILE" ]; then
    echo "0.0" > /logs/verifier/reward.txt
    echo "FAIL: routing.rs not found"
    exit 0
fi

# Count key patterns (grep -c returns exit 1 when count=0, so use || true)
NOT_REL=$(grep -c '#\[cfg(not(feature = "release"))\]' "$FILE" || true)
REL=$(grep -c '#\[cfg(feature = "release")\]' "$FILE" || true)
AUTH_TYPE=$(grep -c 'auth::auth_type' "$FILE" || true)
API_KEY_AUTH=$(grep -c 'ApiKeyAuth' "$FILE" || true)
# Default to safe values if empty
NOT_REL=${NOT_REL:-0}
REL=${REL:-0}
AUTH_TYPE=${AUTH_TYPE:-0}
API_KEY_AUTH=${API_KEY_AUTH:-0}

echo "=== Metrics ==="
echo "cfg(not(feature=\"release\")) count: $NOT_REL (base: 26, target: 0)"
echo "cfg(feature=\"release\") count: $REL (base: 26, target: 0)"
echo "auth::auth_type count: $AUTH_TYPE (base: 34, target: >= 30)"
echo "ApiKeyAuth count: $API_KEY_AUTH (base: 25, target: >= 20)"
echo ""

# ---- cfg(not(feature = "release")) removal tiers (base: 26) ----
check '[ "$NOT_REL" -le 23 ]' "cfg(not(release)): at least 3 removed (remaining: $NOT_REL)"
check '[ "$NOT_REL" -le 15 ]' "cfg(not(release)): at least 11 removed (remaining: $NOT_REL)"
check '[ "$NOT_REL" -le 7 ]'  "cfg(not(release)): at least 19 removed (remaining: $NOT_REL)"
check '[ "$NOT_REL" -le 2 ]'  "cfg(not(release)): at least 24 removed (remaining: $NOT_REL)"
check '[ "$NOT_REL" -eq 0 ] && [ "$AUTH_TYPE" -ge 30 ]' "All cfg(not(release)) removed AND auth_type preserved"

# ---- cfg(feature = "release") removal tiers (base: 26) ----
check '[ "$REL" -le 23 ]' "cfg(release): at least 3 removed (remaining: $REL)"
check '[ "$REL" -le 15 ]' "cfg(release): at least 11 removed (remaining: $REL)"
check '[ "$REL" -le 7 ]'  "cfg(release): at least 19 removed (remaining: $REL)"
check '[ "$REL" -le 2 ]'  "cfg(release): at least 24 removed (remaining: $REL)"
check '[ "$REL" -eq 0 ] && [ "$AUTH_TYPE" -ge 30 ]' "All cfg(release) removed AND auth_type preserved"

# ---- Calculate reward ----
# Use awk instead of bc for portability
if [ "$TOTAL" -eq 0 ]; then
    REWARD="0.0"
else
    REWARD=$(awk "BEGIN {printf \"%.2f\", $PASS / $TOTAL}")
fi

echo ""
echo "=== Result ==="
echo "Score: $PASS / $TOTAL = $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
