#!/bin/bash
set +e

# Test script for hyperswitch-8008: Move stripe connector from router to hyperswitch_connectors
# Multi-tier: behavioral (cargo check) dominates, structural checks support it.

REPO="/workspace/hyperswitch"
HC="$REPO/crates/hyperswitch_connectors"
HC_CONNECTORS="$HC/src/connectors"
ROUTER="$REPO/crates/router"
ROUTER_CONNECTOR="$ROUTER/src/connector"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier

# Ensure cargo is on PATH
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    fi
fi

REWARD=0

# Helper: add weight (float) to REWARD
add_reward() {
    local w="$1"
    local label="$2"
    REWARD=$(awk -v r="$REWARD" -v w="$w" 'BEGIN{printf "%.4f", r+w}')
    echo "PASS [+$w]: $label  (running=$REWARD)"
}

skip_reward() {
    echo "FAIL [+0]: $1"
}

cd "$REPO" 2>/dev/null || {
    echo "FATAL: repo path $REPO not found"
    echo "0" > "$REWARD_FILE"
    exit 0
}

# ============================================================================
# TIER 1: STRUCTURAL VERIFICATIONS (≈ 0.20 total)
# ============================================================================

# S1 (0.05): stripe.rs exists in hyperswitch_connectors with substantial content
NEW_STRIPE="$HC_CONNECTORS/stripe.rs"
if [ -f "$NEW_STRIPE" ]; then
    lc=$(wc -l < "$NEW_STRIPE")
    if [ "$lc" -gt 800 ]; then
        add_reward 0.05 "stripe.rs in hyperswitch_connectors ($lc lines)"
    elif [ "$lc" -gt 100 ]; then
        add_reward 0.025 "stripe.rs exists but small ($lc lines)"
    else
        skip_reward "stripe.rs is a stub ($lc lines)"
    fi
else
    skip_reward "stripe.rs missing in hyperswitch_connectors"
fi

# S2 (0.05): transformers exist with substantial content
TRANSFORMERS_FILE="$HC_CONNECTORS/stripe/transformers.rs"
TRANSFORMERS_DIR="$HC_CONNECTORS/stripe"
if [ -f "$TRANSFORMERS_FILE" ]; then
    tl=$(wc -l < "$TRANSFORMERS_FILE")
    if [ "$tl" -gt 1500 ]; then
        add_reward 0.05 "stripe/transformers.rs ($tl lines)"
    elif [ "$tl" -gt 500 ]; then
        add_reward 0.025 "stripe/transformers.rs medium ($tl lines)"
    else
        skip_reward "stripe/transformers.rs too small ($tl lines)"
    fi
elif [ -d "$TRANSFORMERS_DIR" ]; then
    total=$(find "$TRANSFORMERS_DIR" -name "*.rs" -exec cat {} + 2>/dev/null | wc -l)
    if [ "$total" -gt 1500 ]; then
        add_reward 0.05 "stripe/ dir ($total lines total)"
    else
        skip_reward "stripe/ dir too small ($total lines)"
    fi
else
    skip_reward "no stripe transformers"
fi

# S3 (0.04): pub mod stripe; declared and Stripe re-exported
CONNECTORS_RS="$HC/src/connectors.rs"
mod_ok=0
reexport_ok=0
if grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$CONNECTORS_RS" 2>/dev/null; then
    mod_ok=1
fi
if grep -qE 'stripe::Stripe' "$CONNECTORS_RS" 2>/dev/null; then
    reexport_ok=1
fi
if [ "$mod_ok" -eq 1 ] && [ "$reexport_ok" -eq 1 ]; then
    add_reward 0.04 "pub mod stripe + Stripe re-export in connectors.rs"
elif [ "$mod_ok" -eq 1 ] || [ "$reexport_ok" -eq 1 ]; then
    add_reward 0.02 "partial: mod or re-export only"
else
    skip_reward "neither mod nor re-export of stripe"
fi

# S4 (0.03): router crate no longer has stripe.rs (or it's a stub) AND no stripe dir module
ROUTER_STRIPE_RS="$ROUTER_CONNECTOR/stripe.rs"
ROUTER_STRIPE_DIR="$ROUTER_CONNECTOR/stripe"
ROUTER_CONNECTOR_RS="$ROUTER/src/connector.rs"
removed_ok=0
if [ ! -f "$ROUTER_STRIPE_RS" ] && [ ! -d "$ROUTER_STRIPE_DIR" ]; then
    removed_ok=1
elif [ -f "$ROUTER_STRIPE_RS" ]; then
    rs_lines=$(wc -l < "$ROUTER_STRIPE_RS")
    if [ "$rs_lines" -lt 50 ]; then
        removed_ok=1
    fi
fi
# Also confirm router/src/connector.rs no longer declares `pub mod stripe;`
mod_decl_removed=1
if grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$ROUTER_CONNECTOR_RS" 2>/dev/null; then
    mod_decl_removed=0
fi
if [ "$removed_ok" -eq 1 ] && [ "$mod_decl_removed" -eq 1 ]; then
    add_reward 0.03 "router stripe module removed"
elif [ "$removed_ok" -eq 1 ] || [ "$mod_decl_removed" -eq 1 ]; then
    add_reward 0.015 "router stripe partly removed"
else
    skip_reward "router still has stripe module"
fi

# S5 (0.03): router connector.rs re-exports Stripe from hyperswitch_connectors
if grep -qE 'stripe::Stripe' "$ROUTER_CONNECTOR_RS" 2>/dev/null; then
    # Make sure it's in the hyperswitch_connectors re-export block, not local
    if grep -B2 -A50 'pub use hyperswitch_connectors::connectors' "$ROUTER_CONNECTOR_RS" 2>/dev/null | grep -qE 'stripe::Stripe'; then
        add_reward 0.03 "router re-exports stripe::Stripe from hyperswitch_connectors"
    else
        add_reward 0.015 "router references stripe::Stripe (location unclear)"
    fi
else
    skip_reward "router connector.rs does not re-export Stripe"
fi

# ============================================================================
# TIER 2: IMPORT-HYGIENE (≈ 0.10 total) — adapted code patterns
# ============================================================================

# I1 (0.05): new stripe.rs uses hyperswitch_interfaces / hyperswitch_domain_models
if [ -f "$NEW_STRIPE" ]; then
    if grep -qE 'use hyperswitch_interfaces' "$NEW_STRIPE" && grep -qE 'use hyperswitch_domain_models' "$NEW_STRIPE"; then
        add_reward 0.05 "new stripe.rs uses hyperswitch_interfaces + domain_models"
    elif grep -qE 'hyperswitch_interfaces|hyperswitch_domain_models' "$NEW_STRIPE"; then
        add_reward 0.025 "new stripe.rs uses one of the hs crates"
    else
        skip_reward "new stripe.rs missing expected imports"
    fi
else
    skip_reward "no new stripe.rs to inspect"
fi

# I2 (0.05): new stripe.rs does NOT have router-specific crate:: imports
if [ -f "$NEW_STRIPE" ]; then
    bad=$(grep -cE '^\s*use\s+crate::(configs|core::|services::|consts::|headers;|types::api|utils::crypto)' "$NEW_STRIPE" 2>/dev/null)
    bad=${bad:-0}
    bad=$(echo "$bad" | tr -d '[:space:]')
    if [ "${bad:-0}" -eq 0 ]; then
        add_reward 0.05 "no router-specific crate:: imports"
    elif [ "$bad" -lt 3 ]; then
        add_reward 0.02 "few residual crate:: imports ($bad)"
    else
        skip_reward "$bad router-specific crate:: imports remain"
    fi
else
    skip_reward "no new stripe.rs to inspect"
fi

# ============================================================================
# TIER 3: BEHAVIORAL — cargo check (≈ 0.70 total)
# ============================================================================

if ! command -v cargo >/dev/null 2>&1; then
    skip_reward "cargo not available; skipping behavioral checks"
    echo "$REWARD" > "$REWARD_FILE"
    echo "FINAL REWARD: $REWARD"
    exit 0
fi

LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

# B1 (0.40): cargo check on hyperswitch_connectors crate
echo "==> Running cargo check on hyperswitch_connectors (this may take a while)..."
HC_LOG="$LOG_DIR/cargo_hc.log"
timeout 1500 cargo check -p hyperswitch_connectors --message-format=short > "$HC_LOG" 2>&1
HC_RC=$?

if [ "$HC_RC" -eq 0 ]; then
    add_reward 0.40 "hyperswitch_connectors compiles cleanly"
else
    # Partial credit based on error count
    err_count=$(grep -cE '^error(\[E[0-9]+\])?:' "$HC_LOG" 2>/dev/null)
    err_count=${err_count:-999}
    err_count=$(echo "$err_count" | tr -d '[:space:]')
    err_count=${err_count:-999}
    if [ "$err_count" -le 5 ]; then
        add_reward 0.20 "hyperswitch_connectors near-compiles ($err_count errors)"
    elif [ "$err_count" -le 20 ]; then
        add_reward 0.10 "hyperswitch_connectors many errors ($err_count)"
    elif [ "$err_count" -le 100 ]; then
        add_reward 0.03 "hyperswitch_connectors heavy errors ($err_count)"
    else
        skip_reward "hyperswitch_connectors fails ($err_count errors)"
    fi
    # Show first few errors for debugging
    echo "--- first errors from hyperswitch_connectors check ---"
    grep -E '^error' "$HC_LOG" 2>/dev/null | head -8
    echo "------"
fi

# B2 (0.25): cargo check on router crate (verifies the re-export works)
echo "==> Running cargo check on router..."
ROUTER_LOG="$LOG_DIR/cargo_router.log"
timeout 1500 cargo check -p router --message-format=short > "$ROUTER_LOG" 2>&1
ROUTER_RC=$?

if [ "$ROUTER_RC" -eq 0 ]; then
    add_reward 0.25 "router crate compiles cleanly"
else
    err_count=$(grep -cE '^error(\[E[0-9]+\])?:' "$ROUTER_LOG" 2>/dev/null)
    err_count=${err_count:-999}
    err_count=$(echo "$err_count" | tr -d '[:space:]')
    err_count=${err_count:-999}
    if [ "$err_count" -le 5 ]; then
        add_reward 0.12 "router near-compiles ($err_count errors)"
    elif [ "$err_count" -le 20 ]; then
        add_reward 0.06 "router many errors ($err_count)"
    elif [ "$err_count" -le 100 ]; then
        add_reward 0.02 "router heavy errors ($err_count)"
    else
        skip_reward "router fails ($err_count errors)"
    fi
    echo "--- first errors from router check ---"
    grep -E '^error' "$ROUTER_LOG" 2>/dev/null | head -8
    echo "------"
fi

# B3 (0.05): symbol resolves — `cargo check` with explicit --tests is too costly,
# so instead verify the Stripe symbol path is reachable via doc/check on a tiny stub.
# We do a lighter check: cargo check on hyperswitch_connectors with --features default still
# resolves stripe::Stripe in connectors.rs. Use rustc to grep for the symbol from the
# successful compilation already done.
if [ "$HC_RC" -eq 0 ] && [ "$ROUTER_RC" -eq 0 ]; then
    add_reward 0.05 "both crates build — refactor end-to-end works"
else
    # If cargo metadata still resolves the package and stripe module is wired in
    if cargo metadata --format-version 1 --no-deps >/dev/null 2>&1; then
        if grep -qE 'stripe::Stripe' "$CONNECTORS_RS" && grep -qE '^\s*pub\s+mod\s+stripe\s*;' "$CONNECTORS_RS"; then
            add_reward 0.02 "wiring present though build incomplete"
        else
            skip_reward "wiring missing"
        fi
    else
        skip_reward "cargo metadata fails"
    fi
fi

# ============================================================================
# Cap reward at 1.0
# ============================================================================
REWARD=$(awk -v r="$REWARD" 'BEGIN{ if (r>1.0) r=1.0; if (r<0) r=0; printf "%.4f", r }')

echo "============================================"
echo "FINAL REWARD: $REWARD"
echo "============================================"
echo "$REWARD" > "$REWARD_FILE"
exit 0