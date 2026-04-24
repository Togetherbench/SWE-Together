#!/bin/bash
set +e

# Find the repo directory
if [ -d /workspace/hyperswitch ]; then
    cd /workspace/hyperswitch
elif [ -d /workspace/repos/hyperswitch_pool_5 ]; then
    cd /workspace/repos/hyperswitch_pool_5
else
    echo "ERROR: Cannot find hyperswitch repo"
    mkdir -p /logs/verifier
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

mkdir -p /logs/verifier
REWARD="0.00"

###############################################################################
# P2P Gate 1 (weight 0.10): Rust syntax validity via rustfmt
# Copies files to temp and runs rustfmt; exit 0 = parseable, exit 1 = syntax error.
# Passes on unmodified base AND on correct fix — regression guard.
###############################################################################
echo "=== P2P Gate 1: Rust syntax validity (rustfmt parse check) ==="
SYNTAX_OK=1
for f in crates/diesel_models/src/schema_v2.rs \
         crates/diesel_models/src/payment_intent.rs \
         crates/diesel_models/src/payment_attempt.rs; do
    if [ -f "$f" ]; then
        cp "$f" /tmp/syntax_check.rs
        rustfmt --edition 2021 /tmp/syntax_check.rs 2>/dev/null
        if [ $? -ne 0 ]; then
            echo "  SYNTAX ERROR: $f"
            SYNTAX_OK=0
        fi
    else
        echo "  MISSING: $f"
        SYNTAX_OK=0
    fi
done
if [ $SYNTAX_OK -eq 1 ]; then
    echo "PASS: P2P Gate 1 — all files parse as valid Rust"
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + 0.10}")
else
    echo "FAIL: P2P Gate 1"
fi

###############################################################################
# Run cargo check v2 ONCE, reuse exit code for F2P gates 2-4.
# diesel 128-column-tables may OOM with <10GB RAM.
###############################################################################
echo ""
echo "=== Compiling diesel_models --features v2 ==="
timeout 300 cargo check -p diesel_models --features v2 2>&1 | tail -5
CARGO_V2=$?
echo "cargo check v2 exit code: $CARGO_V2"

###############################################################################
# F2P Gate 2 (weight 0.30): New columns in schema_v2.rs + cargo check v2 passes
# Verifies all 3 new columns in diesel table! macros AND project compiles.
# Fails on base (columns don't exist); passes after correct implementation.
###############################################################################
echo ""
echo "=== F2P Gate 2: schema_v2.rs new columns + v2 compilation ==="
SCHEMA="crates/diesel_models/src/schema_v2.rs"
SCHEMA_OK=0
if [ -f "$SCHEMA" ]; then
    HAS_AAGI=$(grep -c 'active_attempts_group_id' "$SCHEMA" 2>/dev/null)
    HAS_AAIT=$(grep -c 'active_attempt_id_type' "$SCHEMA" 2>/dev/null)
    # attempts_group_id must appear separately from active_attempts_group_id
    HAS_AGI=$(grep 'attempts_group_id' "$SCHEMA" 2>/dev/null | grep -vc 'active_attempts_group_id')
    if [ "${HAS_AAGI:-0}" -ge 1 ] && [ "${HAS_AAIT:-0}" -ge 1 ] && [ "${HAS_AGI:-0}" -ge 1 ]; then
        SCHEMA_OK=1
    fi
fi
if [ $SCHEMA_OK -eq 1 ] && [ $CARGO_V2 -eq 0 ]; then
    echo "PASS: F2P Gate 2"
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + 0.30}")
else
    echo "FAIL: F2P Gate 2 (schema_ok=$SCHEMA_OK, cargo_v2=$CARGO_V2)"
fi

###############################################################################
# F2P Gate 3 (weight 0.25): PaymentIntent struct has new fields + compiles
# Checks diesel_models/src/payment_intent.rs for both new PI columns.
###############################################################################
echo ""
echo "=== F2P Gate 3: payment_intent.rs has active_attempts_group_id & active_attempt_id_type ==="
PI_FILE="crates/diesel_models/src/payment_intent.rs"
PI_OK=0
if [ -f "$PI_FILE" ]; then
    HAS_PI_AAGI=$(grep -c 'active_attempts_group_id' "$PI_FILE" 2>/dev/null)
    HAS_PI_AAIT=$(grep -c 'active_attempt_id_type' "$PI_FILE" 2>/dev/null)
    if [ "${HAS_PI_AAGI:-0}" -ge 1 ] && [ "${HAS_PI_AAIT:-0}" -ge 1 ]; then
        PI_OK=1
    fi
fi
if [ $PI_OK -eq 1 ] && [ $CARGO_V2 -eq 0 ]; then
    echo "PASS: F2P Gate 3"
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + 0.25}")
else
    echo "FAIL: F2P Gate 3 (pi_ok=$PI_OK, cargo_v2=$CARGO_V2)"
fi

###############################################################################
# F2P Gate 4 (weight 0.20): PaymentAttempt struct has attempts_group_id + compiles
# Checks diesel_models/src/payment_attempt.rs for the PA column.
###############################################################################
echo ""
echo "=== F2P Gate 4: payment_attempt.rs has attempts_group_id ==="
PA_FILE="crates/diesel_models/src/payment_attempt.rs"
PA_OK=0
if [ -f "$PA_FILE" ]; then
    # Must match attempts_group_id but NOT active_attempts_group_id
    HAS_PA_AGI=$(grep 'attempts_group_id' "$PA_FILE" 2>/dev/null | grep -vc 'active_attempts_group_id')
    if [ "${HAS_PA_AGI:-0}" -ge 1 ]; then
        PA_OK=1
    fi
fi
if [ $PA_OK -eq 1 ] && [ $CARGO_V2 -eq 0 ]; then
    echo "PASS: F2P Gate 4"
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + 0.20}")
else
    echo "FAIL: F2P Gate 4 (pa_ok=$PA_OK, cargo_v2=$CARGO_V2)"
fi

###############################################################################
# F2P Gate 5 (weight 0.15): Migration SQL files exist
# At least one migration up.sql references the new columns.
###############################################################################
echo ""
echo "=== F2P Gate 5: Migration up.sql with new columns ==="
MIGRATION_OK=0
for mdir in migrations v2_migrations; do
    if [ -d "$mdir" ]; then
        for dir in "$mdir"/*/; do
            if [ -f "$dir/up.sql" ]; then
                if grep -qE 'active_attempts_group_id|active_attempt_id_type|attempts_group_id' "$dir/up.sql" 2>/dev/null; then
                    MIGRATION_OK=1
                    echo "  Found migration: $dir"
                    break 2
                fi
            fi
        done
    fi
done
if [ $MIGRATION_OK -eq 1 ]; then
    echo "PASS: F2P Gate 5"
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + 0.15}")
else
    echo "FAIL: F2P Gate 5 — no migration files found for new columns"
fi

###############################################################################
# Write final reward
###############################################################################
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt
