#!/bin/bash
set +e
# [v041-fix] rustup default stable
if command -v rustup >/dev/null 2>&1; then
    rustup default stable >/dev/null 2>&1 || true
fi
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

# [v041-fix] cargo SIGKILL/OOM detection helper
_cargo_check_with_oom_detect() {
    # Run a cargo invocation and detect SIGKILL/OOM. On OOM, mark
    # /logs/verifier/infra_fault and skip penalising the agent.
    # Usage: _cargo_check_with_oom_detect <cmd…>
    local out
    out=$("$@" 2>&1)
    local rc=$?
    if [ $rc -eq 137 ] || echo "$out" | grep -qE "signal: 9|SIGKILL|Killed"; then
        mkdir -p /logs/verifier
        echo "1" > /logs/verifier/infra_fault
        echo "$out" | tail -20
        return 99   # sentinel: don't fail but don't pass
    fi
    return $rc
}


# Verifier for hyperswitch-8084: Add api-key support for routing APIs
#
# CORE PRINCIPLE: no-op (unmodified buggy file) MUST score 0.0.
#
# The buggy base contains many `#[cfg(not(feature = "release"))]` and
# `#[cfg(feature = "release")]` attribute pairs guarding routing auth blocks.
# The correct fix removes these cfg pairs so that ALL routing endpoints use
# the unified (api-key + JWT) `auth::auth_type(...)` path in BOTH default and
# `--features release` builds.
#
# All reward comes from F2P signals:
#   - The release-feature cfg gates on routing auth must be gone (zero on fix,
#     dozens on base).
#   - The unified auth::auth_type calls must remain (preserves api-key auth).
#   - Behavioral: `cargo check -p router --features release` must succeed
#     after the fix; the buggy base also compiles, so we don't reward bare
#     compile -- we reward the *combination* of compile + cfg removal.

mkdir -p /logs/verifier
REWARD=0.00

write_reward() {
    REWARD=$(awk "BEGIN {s=$REWARD; if (s<0) s=0; if (s>1) s=1; printf \"%.2f\", s}")
    echo ""
    echo "=== FINAL REWARD: $REWARD ==="
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

add() {
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + $1}")
    echo "  +$1 -> $REWARD  ($2)"
}

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
fi

REPO=/workspace/hyperswitch
FILE="$REPO/crates/router/src/routes/routing.rs"

# ---------- P2P / sanity gates (no reward, just guards) ----------
if [ ! -d "$REPO" ]; then
    echo "GATE FAIL: $REPO missing"
    write_reward
fi
if [ ! -f "$FILE" ]; then
    echo "GATE FAIL: $FILE missing"
    write_reward
fi

SIZE=$(wc -c < "$FILE" 2>/dev/null)
SIZE=${SIZE:-0}
if [ "$SIZE" -lt 20000 ]; then
    echo "GATE FAIL: file too small ($SIZE bytes), agent may have wiped it"
    write_reward
fi

# Brace balance — guard against syntactic destruction
OPEN=$(tr -cd '{' < "$FILE" | wc -c)
CLOSE=$(tr -cd '}' < "$FILE" | wc -c)
if [ "$OPEN" -ne "$CLOSE" ]; then
    echo "GATE FAIL: braces unbalanced ($OPEN vs $CLOSE)"
    write_reward
fi

# ---------- Measure F2P structural signals ----------
NOT_REL=$(grep -c '#\[cfg(not(feature = "release"))\]' "$FILE")
REL=$(grep -c '#\[cfg(feature = "release")\]' "$FILE")
AUTH_TYPE=$(grep -c 'auth::auth_type' "$FILE")
API_KEY_AUTH=$(grep -cE 'ApiKeyAuth|V2ApiKeyAuth' "$FILE")
NOT_REL=${NOT_REL:-0}; REL=${REL:-0}
AUTH_TYPE=${AUTH_TYPE:-0}; API_KEY_AUTH=${API_KEY_AUTH:-0}

echo "=== F2P metrics ==="
echo "  cfg(not(feature=release)) attrs: $NOT_REL  (base: many; fix: 0)"
echo "  cfg(feature=release)      attrs: $REL      (base: many; fix: 0)"
echo "  auth::auth_type calls          : $AUTH_TYPE (must remain present)"
echo "  ApiKeyAuth/V2ApiKeyAuth refs   : $API_KEY_AUTH (must remain present)"

# Sanity: the buggy base has roughly 26+ of each cfg gate. If we see those
# numbers we know the agent didn't change anything → reward must be 0.
TOTAL_CFG=$((NOT_REL + REL))
echo "  total release-cfg attrs        : $TOTAL_CFG"

# Detect "JWT-only as direct auth handler arg" — the bug pattern preserved
# when an agent merely deletes the `cfg(not(feature=release))` line and leaves
# the bare `&auth::JWTAuth { ... }, api_locking::LockAction` form. We use
# python to count occurrences of a bare JWT auth ref immediately followed by
# api_locking::LockAction (i.e. JWT used as the handler's auth argument, not
# as a sub-arg of auth_type).
JWT_ONLY_HITS=$(python3 - "$FILE" <<'PY' 2>/dev/null
import re, sys
src = open(sys.argv[1]).read()
# Pattern: a closing `},` for a JWTAuth* struct literal followed by whitespace
# then `api_locking::LockAction`. To narrow to "auth handler position", we look
# for `&auth::JWTAuth` or `&auth::JWTAuthProfileFromRoute` blocks whose closing
# `},` is followed (within ~3 lines) by `api_locking::LockAction`.
pat = re.compile(
    r'&auth::JWTAuth(?:ProfileFromRoute)?\s*\{[^}]*\}\s*,\s*\n\s*api_locking::LockAction',
    re.MULTILINE,
)
print(len(pat.findall(src)))
PY
)
JWT_ONLY_HITS=${JWT_ONLY_HITS:-0}
echo "  bare JWT-as-handler-auth hits  : $JWT_ONLY_HITS (base: many; fix: 0)"

# ---------- F2P Gate 1: cfg(not(feature=release)) attrs eliminated (0.30) ----------
# On the unmodified base this is large (>20). On the correct fix it is 0.
if [ "$NOT_REL" -eq 0 ]; then
    add 0.30 "G1: all cfg(not(feature=release)) attrs removed from routing.rs"
elif [ "$NOT_REL" -le 2 ]; then
    add 0.15 "G1 partial: nearly all cfg(not(feature=release)) attrs removed ($NOT_REL left)"
else
    echo "  --- G1 fail: $NOT_REL cfg(not(feature=release)) attrs still present"
fi

# ---------- F2P Gate 2: cfg(feature=release) attrs eliminated (0.20) ----------
if [ "$REL" -eq 0 ]; then
    add 0.20 "G2: all cfg(feature=release) attrs removed from routing.rs"
elif [ "$REL" -le 2 ]; then
    add 0.10 "G2 partial: nearly all cfg(feature=release) attrs removed ($REL left)"
else
    echo "  --- G2 fail: $REL cfg(feature=release) attrs still present"
fi

# ---------- F2P Gate 3: no bare JWT-as-handler-auth pattern remains (0.20) ----------
# This is the actual bug semantics: in `release`, the handler used JWT-only
# auth. After the fix, every handler call site uses auth::auth_type(...).
if [ "$JWT_ONLY_HITS" -eq 0 ]; then
    add 0.20 "G3: no bare &auth::JWTAuth-as-handler-auth pattern (api-key path always taken)"
elif [ "$JWT_ONLY_HITS" -le 2 ]; then
    add 0.10 "G3 partial: only $JWT_ONLY_HITS JWT-only handler auth sites left"
else
    echo "  --- G3 fail: $JWT_ONLY_HITS JWT-only handler-auth call sites remain"
fi

# ---------- F2P Gate 4: api-key path preserved (0.10) ----------
# Guards against an agent deleting cfgs by axing the api-key branch entirely
# (which would also reach 0 cfgs but would break the feature).
if [ "$AUTH_TYPE" -ge 25 ] && [ "$API_KEY_AUTH" -ge 20 ]; then
    add 0.10 "G4: auth_type/ApiKeyAuth references preserved ($AUTH_TYPE / $API_KEY_AUTH)"
else
    echo "  --- G4 fail: auth_type=$AUTH_TYPE ApiKeyAuth=$API_KEY_AUTH (need >=25 / >=20)"
fi

# ---------- F2P Gate 5: builds with --features release (0.20) ----------
# Behavioral: the buggy base ALSO compiles with --features release, so this
# gate alone wouldn't be F2P. We make it F2P by REQUIRING that the cfg gates
# were materially reduced (otherwise we award 0 here). That way:
#   - no-op patch: TOTAL_CFG ~= 50 → gate skipped → 0.0
#   - correct fix: TOTAL_CFG = 0   → gate runs → reward iff release build OK
# This means a destructive patch that removes cfgs but breaks the build is
# (correctly) denied this slice.

if [ "$TOTAL_CFG" -le 4 ]; then
    cd "$REPO" || write_reward
    if command -v cargo >/dev/null 2>&1; then
        LOG=/logs/verifier/cargo_release.log
        echo ""
        echo "Running: cargo check -p router --lib --features release ..."
        timeout 1800 cargo check -p router --lib --features release \
            --message-format=short > "$LOG" 2>&1
        RC=$?
        echo "  exit code: $RC"
        tail -n 20 "$LOG"
        if [ "$RC" -eq 0 ]; then
            add 0.20 "G5: cargo check --features release succeeds with cfg gates removed"
        else
            ERRS=$(grep -cE '^error' "$LOG")
            ERRS=${ERRS:-0}
            echo "  --- G5 fail: $ERRS cargo errors with --features release"
        fi
    else
        echo "  --- G5 skipped: cargo not available"
    fi
else
    echo "  --- G5 skipped: cfg gates not removed (TOTAL_CFG=$TOTAL_CFG > 4); no behavioral evidence of fix"
fi

write_reward