#!/bin/bash
set +e

# Verifier for hyperswitch-8084: Add api-key support for routing APIs
#
# Strategy: The fix must remove all #[cfg(not(feature = "release"))] / #[cfg(feature = "release")]
# pairs from routing auth blocks in routing.rs, replacing the JWT-only release path with a
# unified auth::auth_type() call that accepts both API-key AND JWT for both builds.
#
# We score:
#   - structural (~25%): cfg pairs removed, auth_type/ApiKeyAuth preserved
#   - behavioral (~65%): cargo check passes with both default and --features release
#   - regression guards (~10%): file still compiles structurally (balanced braces, no leftover orphan cfgs)

FILE="/workspace/hyperswitch/crates/router/src/routes/routing.rs"
mkdir -p /logs/verifier

# PATH setup for cargo
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    fi
fi

SCORE=0.0
add_score() {
    SCORE=$(awk "BEGIN {printf \"%.4f\", $SCORE + $1}")
    echo "  +$1 -> total: $SCORE  ($2)"
}

write_reward() {
    # Clamp to [0,1]
    SCORE=$(awk "BEGIN {s=$SCORE; if (s<0) s=0; if (s>1) s=1; printf \"%.2f\", s}")
    echo ""
    echo "=== FINAL SCORE: $SCORE ==="
    echo "$SCORE" > /logs/verifier/reward.txt
    exit 0
}

# Sanity: file must exist
if [ ! -f "$FILE" ]; then
    echo "FAIL: $FILE not found"
    write_reward
fi

echo "=== Structural metrics ==="
NOT_REL=$(grep -c '#\[cfg(not(feature = "release"))\]' "$FILE" 2>/dev/null)
REL=$(grep -c '#\[cfg(feature = "release")\]' "$FILE" 2>/dev/null)
AUTH_TYPE=$(grep -c 'auth::auth_type' "$FILE" 2>/dev/null)
API_KEY_AUTH=$(grep -c 'ApiKeyAuth' "$FILE" 2>/dev/null)
JWT_AUTH=$(grep -c 'JWTAuth' "$FILE" 2>/dev/null)
NOT_REL=${NOT_REL:-0}
REL=${REL:-0}
AUTH_TYPE=${AUTH_TYPE:-0}
API_KEY_AUTH=${API_KEY_AUTH:-0}
JWT_AUTH=${JWT_AUTH:-0}

echo "  cfg(not(feature=\"release\")) count: $NOT_REL (target: 0)"
echo "  cfg(feature=\"release\")     count: $REL     (target: 0)"
echo "  auth::auth_type            count: $AUTH_TYPE (preserve, target>=25)"
echo "  ApiKeyAuth                 count: $API_KEY_AUTH (preserve, target>=20)"
echo "  JWTAuth                    count: $JWT_AUTH (preserve)"

echo ""
echo "=== Section A: Structural removal (weight 0.25) ==="

# A1: At least 50% of release-cfg pairs removed (weight 0.05)
if [ "$NOT_REL" -le 13 ] && [ "$REL" -le 13 ]; then
    add_score 0.05 "A1: >=50% cfg release pairs removed"
else
    echo "  --- A1 fail: NOT_REL=$NOT_REL REL=$REL"
fi

# A2: At least 90% removed (weight 0.05)
if [ "$NOT_REL" -le 3 ] && [ "$REL" -le 3 ]; then
    add_score 0.05 "A2: >=90% cfg release pairs removed"
else
    echo "  --- A2 fail"
fi

# A3: All removed (weight 0.05)
if [ "$NOT_REL" -eq 0 ] && [ "$REL" -eq 0 ]; then
    add_score 0.05 "A3: all cfg release pairs removed"
else
    echo "  --- A3 fail"
fi

# A4: auth::auth_type preserved (weight 0.05) - confirms the fix kept api-key+JWT path,
# not just stripped attributes leaving JWT-only behind
if [ "$AUTH_TYPE" -ge 25 ]; then
    add_score 0.05 "A4: auth::auth_type preserved (api-key+JWT path kept)"
else
    echo "  --- A4 fail: only $AUTH_TYPE auth::auth_type calls (need >=25)"
fi

# A5: ApiKeyAuth references preserved (weight 0.05)
if [ "$API_KEY_AUTH" -ge 20 ]; then
    add_score 0.05 "A5: ApiKeyAuth references preserved"
else
    echo "  --- A5 fail: only $API_KEY_AUTH ApiKeyAuth (need >=20)"
fi

echo ""
echo "=== Section B: Regression guards (weight 0.10) ==="

# B1: file is non-trivially sized (no accidental wipe) (weight 0.03)
SIZE=$(wc -c < "$FILE" 2>/dev/null)
SIZE=${SIZE:-0}
if [ "$SIZE" -gt 30000 ]; then
    add_score 0.03 "B1: file size reasonable ($SIZE bytes)"
else
    echo "  --- B1 fail: file too small ($SIZE bytes)"
fi

# B2: no orphan #[cfg( ... "release" leftover variants (weight 0.03)
ORPHAN=$(grep -c 'cfg(.*"release"' "$FILE" 2>/dev/null)
ORPHAN=${ORPHAN:-0}
# Only count those NOT involving feature=, which would be unusual; total release-cfg should be 0
TOTAL_RELEASE_CFG=$(grep -cE '#\[cfg\(.*feature = "release".*\)\]' "$FILE" 2>/dev/null)
TOTAL_RELEASE_CFG=${TOTAL_RELEASE_CFG:-0}
if [ "$TOTAL_RELEASE_CFG" -le 2 ]; then
    add_score 0.03 "B2: no leftover release feature cfgs ($TOTAL_RELEASE_CFG)"
else
    echo "  --- B2 fail: $TOTAL_RELEASE_CFG leftover release cfgs"
fi

# B3: braces look balanced (weight 0.04)
OPEN_BRACE=$(grep -o '{' "$FILE" | wc -l)
CLOSE_BRACE=$(grep -o '}' "$FILE" | wc -l)
if [ "$OPEN_BRACE" -eq "$CLOSE_BRACE" ] && [ "$OPEN_BRACE" -gt 100 ]; then
    add_score 0.04 "B3: braces balanced ($OPEN_BRACE = $CLOSE_BRACE)"
else
    echo "  --- B3 fail: braces $OPEN_BRACE vs $CLOSE_BRACE"
fi

echo ""
echo "=== Section C: Behavioral - cargo check (weight 0.65) ==="

cd /workspace/hyperswitch 2>/dev/null
if [ ! -d /workspace/hyperswitch ]; then
    echo "FAIL: /workspace/hyperswitch missing"
    write_reward
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "WARN: cargo not on PATH; skipping behavioral checks"
    write_reward
fi

# Use a build log dir
LOGDIR=/logs/verifier
DEFAULT_LOG="$LOGDIR/cargo_default.log"
RELEASE_LOG="$LOGDIR/cargo_release.log"

# C1: cargo check default features (weight 0.30) - this is the dev path,
# which used to be (api-key + JWT). Should still compile.
echo ""
echo "Running: cargo check -p router --lib (default features) ..."
timeout 1800 cargo check -p router --lib --message-format=short > "$DEFAULT_LOG" 2>&1
RC_DEFAULT=$?
echo "  exit code: $RC_DEFAULT"
tail -n 20 "$DEFAULT_LOG"

if [ "$RC_DEFAULT" -eq 0 ]; then
    add_score 0.30 "C1: cargo check (default features) passed"
else
    # Partial: maybe only a few errors. Count error lines.
    ERR_DEFAULT=$(grep -cE '^error' "$DEFAULT_LOG" 2>/dev/null)
    ERR_DEFAULT=${ERR_DEFAULT:-0}
    echo "  --- C1 fail: $ERR_DEFAULT errors"
    if [ "$ERR_DEFAULT" -le 2 ] && [ "$ERR_DEFAULT" -gt 0 ]; then
        add_score 0.10 "C1 partial: only $ERR_DEFAULT errors"
    fi
fi

# C2: cargo check with release feature (weight 0.30) - the formerly-JWT-only path.
# Critical: this is where the bug existed. If the agent merely deleted attrs without
# unifying via auth_type, the release build typically breaks (duplicate or missing args).
echo ""
echo "Running: cargo check -p router --lib --features release ..."
timeout 1800 cargo check -p router --lib --features release --message-format=short > "$RELEASE_LOG" 2>&1
RC_RELEASE=$?
echo "  exit code: $RC_RELEASE"
tail -n 30 "$RELEASE_LOG"

if [ "$RC_RELEASE" -eq 0 ]; then
    add_score 0.30 "C2: cargo check --features release passed"
else
    ERR_RELEASE=$(grep -cE '^error' "$RELEASE_LOG" 2>/dev/null)
    ERR_RELEASE=${ERR_RELEASE:-0}
    echo "  --- C2 fail: $ERR_RELEASE errors"
    if [ "$ERR_RELEASE" -le 2 ] && [ "$ERR_RELEASE" -gt 0 ]; then
        add_score 0.10 "C2 partial: only $ERR_RELEASE errors"
    fi
fi

# C3: behavioral evidence the auth in BOTH builds uses api-key path.
# Inspect the post-fix file: every block that previously had a release-gated
# JWT-only branch should now have just an auth::auth_type call. We check that
# there are NO bare `&auth::JWTAuth {` lines that aren't immediately preceded
# by an auth::auth_type wrapper (i.e., JWT used as the second arg of auth_type
# is fine, JWT as the standalone auth argument to the handler is the old bug).
# Heuristic: count occurrences of `\n        &auth::JWTAuth` with `,\n` after,
# inside server_wrap calls. Approximate with: lines that say `&auth::JWTAuth {`
# and are followed within 6 lines by `api_locking::LockAction`.
echo ""
echo "Behavioral C3: detect remaining JWT-only auth handler args ..."

python3 - "$FILE" <<'PY' > "$LOGDIR/jwt_only.txt" 2>&1
import re, sys
src = open(sys.argv[1]).read()
# Find calls like: server_wrap( ... , <auth>, api_locking::LockAction
# A 'JWT-only' bug pattern: the auth argument is `&auth::JWTAuth { ... },` (or JWTAuthProfileFromRoute)
# directly followed by `api_locking::LockAction`. If api-key support is correctly added,
# the auth arg must be wrapped in auth::auth_type(...).
pattern = re.compile(
    r'(?P<lead>[^\n]*\n[^\n]*\n[^\n]*\n)\s*&auth::JWTAuth(?:ProfileFromRoute)?\s*\{[^}]*\},\s*\n\s*api_locking::LockAction',
    re.MULTILINE
)
matches = pattern.findall(src)
print(f"jwt_only_handler_arg_count={len(matches)}")
PY

JWT_ONLY=$(grep -oE 'jwt_only_handler_arg_count=[0-9]+' "$LOGDIR/jwt_only.txt" | head -n1 | cut -d= -f2)
JWT_ONLY=${JWT_ONLY:-99}
echo "  jwt_only_handler_arg_count = $JWT_ONLY"

if [ "$JWT_ONLY" -eq 0 ]; then
    add_score 0.05 "C3: no remaining JWT-only auth handler args"
else
    echo "  --- C3 fail: $JWT_ONLY JWT-only auth args remain"
fi

write_reward