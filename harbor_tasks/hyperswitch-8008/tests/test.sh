#!/bin/bash
set +e

# Verifier for hyperswitch-8008: stripe connector moved from router crate to hyperswitch_connectors
#
# CORE PRINCIPLE: A no-op patch (buggy base) MUST score 0.0.
# On the buggy base:
#   - crates/router/src/connector/stripe.rs and crates/router/src/connector/stripe/ exist
#   - hyperswitch_connectors does NOT have stripe.rs / stripe/ module
#   - hyperswitch_connectors/src/connectors.rs does NOT declare `pub mod stripe;` or re-export Stripe
#   - router/src/connector.rs declares `pub mod stripe;` locally
#
# F2P signals (all FAIL on buggy base, PASS on correct fix):
#   - hyperswitch_connectors declares pub mod stripe; AND re-exports stripe::Stripe
#   - router/src/connector.rs no longer declares local `pub mod stripe;`
#   - router/src/connector.rs re-exports stripe from hyperswitch_connectors
#   - hyperswitch_connectors crate compiles (with stripe wired)
#   - router crate compiles (with stripe coming from hyperswitch_connectors)

REPO="/workspace/hyperswitch"
HC="$REPO/crates/hyperswitch_connectors"
HC_CONNECTORS="$HC/src/connectors"
ROUTER="$REPO/crates/router"
ROUTER_CONNECTOR_DIR="$ROUTER/src/connector"
ROUTER_CONNECTOR_RS="$ROUTER/src/connector.rs"
HC_CONNECTORS_RS="$HC/src/connectors.rs"
LOG_DIR="/logs/verifier"
REWARD_FILE="$LOG_DIR/reward.txt"

mkdir -p "$LOG_DIR"

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
fi

REWARD=0

add() {
    local w="$1"; local label="$2"
    REWARD=$(awk -v r="$REWARD" -v w="$w" 'BEGIN{printf "%.4f", r+w}')
    echo "PASS [+$w]: $label  (running=$REWARD)"
}
fail() {
    echo "FAIL [+0]: $1"
}

finish() {
    echo "FINAL REWARD: $REWARD"
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

if [ ! -d "$REPO" ]; then
    echo "FATAL: repo $REPO not found"
    echo "0" > "$REWARD_FILE"
    exit 0
fi

cd "$REPO" || { echo "0" > "$REWARD_FILE"; exit 0; }

# ============================================================================
# F2P GATE 1 (0.10): hyperswitch_connectors declares `pub mod stripe;`
#   On buggy base: NO. After fix: YES.
# ============================================================================
if [ -f "$HC_CONNECTORS_RS" ] && grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$HC_CONNECTORS_RS"; then
    add 0.10 "hyperswitch_connectors/src/connectors.rs declares pub mod stripe;"
    F2P_MOD_DECLARED=1
else
    fail "hyperswitch_connectors does not declare pub mod stripe;"
    F2P_MOD_DECLARED=0
fi

# ============================================================================
# F2P GATE 2 (0.10): hyperswitch_connectors re-exports Stripe
#   On buggy base: NO. After fix: YES.
# ============================================================================
if [ -f "$HC_CONNECTORS_RS" ] && grep -qE 'stripe::Stripe' "$HC_CONNECTORS_RS"; then
    add 0.10 "hyperswitch_connectors re-exports stripe::Stripe"
else
    fail "hyperswitch_connectors does not re-export stripe::Stripe"
fi

# ============================================================================
# F2P GATE 3 (0.05): new stripe module exists with substantial content
#   On buggy base: file does NOT exist in hyperswitch_connectors. After fix: YES.
# ============================================================================
NEW_STRIPE="$HC_CONNECTORS/stripe.rs"
new_stripe_lines=0
if [ -f "$NEW_STRIPE" ]; then
    new_stripe_lines=$(wc -l < "$NEW_STRIPE" 2>/dev/null || echo 0)
fi
if [ "${new_stripe_lines:-0}" -gt 800 ]; then
    add 0.05 "hyperswitch_connectors/src/connectors/stripe.rs has $new_stripe_lines lines"
else
    fail "no substantial stripe.rs in hyperswitch_connectors ($new_stripe_lines lines)"
fi

# ============================================================================
# F2P GATE 4 (0.05): stripe transformers exist with substantial content
#   On buggy base: NO. After fix: YES.
# ============================================================================
TRANSFORMERS_FILE="$HC_CONNECTORS/stripe/transformers.rs"
TRANSFORMERS_DIR="$HC_CONNECTORS/stripe"
trans_lines=0
if [ -f "$TRANSFORMERS_FILE" ]; then
    trans_lines=$(wc -l < "$TRANSFORMERS_FILE" 2>/dev/null || echo 0)
elif [ -d "$TRANSFORMERS_DIR" ]; then
    trans_lines=$(find "$TRANSFORMERS_DIR" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l)
fi
if [ "${trans_lines:-0}" -gt 1500 ]; then
    add 0.05 "stripe transformers present ($trans_lines lines)"
else
    fail "no substantial stripe transformers ($trans_lines lines)"
fi

# ============================================================================
# F2P GATE 5 (0.05): router crate no longer declares local `pub mod stripe;`
#   On buggy base: declared. After fix: removed.
# ============================================================================
router_mod_removed=0
if [ -f "$ROUTER_CONNECTOR_RS" ]; then
    if ! grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$ROUTER_CONNECTOR_RS"; then
        router_mod_removed=1
    fi
fi
if [ "$router_mod_removed" -eq 1 ]; then
    add 0.05 "router/src/connector.rs no longer declares local pub mod stripe;"
else
    fail "router/src/connector.rs still declares local pub mod stripe;"
fi

# ============================================================================
# F2P GATE 6 (0.05): router crate's local stripe sources are gone (or stub)
#   On buggy base: full module exists. After fix: removed.
# ============================================================================
router_stripe_removed=0
if [ ! -f "$ROUTER_CONNECTOR_DIR/stripe.rs" ] && [ ! -d "$ROUTER_CONNECTOR_DIR/stripe" ]; then
    router_stripe_removed=1
else
    # Allow stub
    rs_lines=0
    if [ -f "$ROUTER_CONNECTOR_DIR/stripe.rs" ]; then
        rs_lines=$(wc -l < "$ROUTER_CONNECTOR_DIR/stripe.rs" 2>/dev/null || echo 0)
    fi
    dir_lines=0
    if [ -d "$ROUTER_CONNECTOR_DIR/stripe" ]; then
        dir_lines=$(find "$ROUTER_CONNECTOR_DIR/stripe" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l)
    fi
    total=$((rs_lines + dir_lines))
    if [ "$total" -lt 50 ]; then
        router_stripe_removed=1
    fi
fi
if [ "$router_stripe_removed" -eq 1 ]; then
    add 0.05 "router crate local stripe sources removed"
else
    fail "router crate still has local stripe module sources"
fi

# ============================================================================
# F2P GATE 7 (0.05): router/src/connector.rs references hyperswitch_connectors::connectors::stripe
#   On buggy base: the re-export block lists other connectors but not stripe.
#   After fix: stripe is added to that re-export list.
# ============================================================================
router_reexports_stripe=0
if [ -f "$ROUTER_CONNECTOR_RS" ]; then
    # Look for stripe in the hyperswitch_connectors re-export block
    if awk '
        /pub use hyperswitch_connectors::connectors/ { in_block=1 }
        in_block { print }
        in_block && /};/ { in_block=0 }
    ' "$ROUTER_CONNECTOR_RS" 2>/dev/null | grep -qE '(^|[^a-zA-Z_])stripe::Stripe'; then
        router_reexports_stripe=1
    fi
fi
if [ "$router_reexports_stripe" -eq 1 ]; then
    add 0.05 "router re-exports stripe::Stripe from hyperswitch_connectors"
else
    fail "router does not re-export stripe::Stripe from hyperswitch_connectors"
fi

# ============================================================================
# Behavioral checks need cargo. If unavailable, finalize.
# ============================================================================
if ! command -v cargo >/dev/null 2>&1; then
    fail "cargo not available; skipping behavioral checks"
    finish
fi

# Quick sanity gate: if hyperswitch_connectors does not declare pub mod stripe;
# then a behavioral compile of HC won't show this F2P signal. Skip behavioral
# weight to keep no-op == 0.0 (since no-op already gets 0 from structural F2Ps).
if [ "$F2P_MOD_DECLARED" -ne 1 ]; then
    fail "skipping cargo check: stripe not declared in hyperswitch_connectors (no-op base)"
    finish
fi

# ============================================================================
# F2P GATE 8 (0.30): hyperswitch_connectors compiles cleanly
#   On buggy base: this gate is skipped above (mod not declared) → 0.
#   After fix: stripe is wired in and HC must still compile.
# ============================================================================
echo "==> cargo check -p hyperswitch_connectors (timeout 1500s)..."
HC_LOG="$LOG_DIR/cargo_hc.log"
timeout 1500 cargo check -p hyperswitch_connectors --message-format=short > "$HC_LOG" 2>&1
HC_RC=$?
if [ "$HC_RC" -eq 0 ]; then
    add 0.30 "hyperswitch_connectors compiles cleanly with stripe"
else
    err_count=$(grep -cE '^error(\[E[0-9]+\])?:' "$HC_LOG" 2>/dev/null | tr -d '[:space:]')
    err_count=${err_count:-999}
    fail "hyperswitch_connectors fails to compile ($err_count errors)"
    echo "--- first errors ---"
    grep -E '^error' "$HC_LOG" 2>/dev/null | head -10
    echo "--------------------"
fi

# ============================================================================
# F2P GATE 9 (0.25): router compiles cleanly
#   On buggy base: this gate is skipped (HC stripe not declared) → 0.
#   After fix: router must compile while pulling Stripe from hyperswitch_connectors.
# ============================================================================
if [ "$HC_RC" -eq 0 ]; then
    echo "==> cargo check -p router (timeout 1800s)..."
    R_LOG="$LOG_DIR/cargo_router.log"
    timeout 1800 cargo check -p router --message-format=short > "$R_LOG" 2>&1
    R_RC=$?
    if [ "$R_RC" -eq 0 ]; then
        add 0.25 "router crate compiles cleanly"
    else
        err_count=$(grep -cE '^error(\[E[0-9]+\])?:' "$R_LOG" 2>/dev/null | tr -d '[:space:]')
        err_count=${err_count:-999}
        fail "router crate fails to compile ($err_count errors)"
        echo "--- first errors ---"
        grep -E '^error' "$R_LOG" 2>/dev/null | head -10
        echo "--------------------"
    fi
else
    fail "skipping router check (hyperswitch_connectors did not compile)"
fi

finish