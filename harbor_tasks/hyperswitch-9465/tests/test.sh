#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.cargo/bin:$PATH

# Find the repo directory
if [ -d /workspace/hyperswitch ]; then
    cd /workspace/hyperswitch
elif [ -d /workspace/hyperswitch/hyperswitch_pool_5 ]; then
    cd /workspace/hyperswitch/hyperswitch_pool_5
else
    echo "ERROR: Cannot find hyperswitch repo"
    mkdir -p /logs/verifier
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

mkdir -p /logs/verifier
REWARD="0.00"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN {printf "%.2f", a + b}')
}

finish_zero() {
    echo "Regression / hard gate failed: $1"
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
}

###############################################################################
# Quick structural pre-check: do the new column names exist anywhere in the
# diesel_models schema_v2.rs? On the buggy base, none of these exist anywhere.
# This is purely an F2P-style fast filter; we still verify behaviorally below.
###############################################################################
SCHEMA_V2="crates/diesel_models/src/schema_v2.rs"
if [ ! -f "$SCHEMA_V2" ]; then
    finish_zero "schema_v2.rs missing — cannot proceed"
fi

# Confirm baseline: these markers are ABSENT on a no-op (buggy) state.
# We don't reward grep matches; we just use them to decide whether to even try
# the expensive cargo probes. If absent we skip straight to 0.
HAS_COL_AAGI=$(grep -c 'active_attempts_group_id' "$SCHEMA_V2" 2>/dev/null)
HAS_COL_AAIT=$(grep -c 'active_attempt_id_type' "$SCHEMA_V2" 2>/dev/null)
HAS_COL_AGI=$(grep -c 'attempts_group_id' "$SCHEMA_V2" 2>/dev/null)

echo "schema_v2 markers: aagi=$HAS_COL_AAGI aait=$HAS_COL_AAIT agi=$HAS_COL_AGI"

if [ "$HAS_COL_AAGI" -eq 0 ] && [ "$HAS_COL_AAIT" -eq 0 ] && [ "$HAS_COL_AGI" -eq 0 ]; then
    # Pure no-op state. Nothing was added. Reward must be 0.
    echo "No-op detected: none of the new schema columns present."
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

###############################################################################
# Compile diesel_models with v2 feature. This is the CORE behavioral check:
# the buggy base compiles cleanly; the agent has added new columns/struct
# fields, and to keep it compiling they must wire them through consistently.
# But just compiling alone is also true on base — so we DO NOT reward base
# compilation. Instead we reward "compiles AND new symbols are reachable",
# which is impossible on the no-op base.
###############################################################################
echo ""
echo "=== Compiling diesel_models --features v2 ==="
timeout 600 cargo check -p diesel_models --features v2 2>/tmp/cargo_v2.log
CARGO_V2=$?
echo "cargo check v2 exit: $CARGO_V2"
tail -20 /tmp/cargo_v2.log

echo ""
echo "=== Compiling diesel_models default features ==="
timeout 600 cargo check -p diesel_models 2>/tmp/cargo_v1.log
CARGO_V1=$?
echo "cargo check default exit: $CARGO_V1"
tail -10 /tmp/cargo_v1.log

# Hard regression gate: if default-feature build broke, the agent destroyed
# pre-existing functionality. No partial credit.
if [ $CARGO_V1 -ne 0 ]; then
    finish_zero "diesel_models default build broke (regression)"
fi

# If v2 build is broken, no behavioral gates can pass. Reward stays 0.
if [ $CARGO_V2 -ne 0 ]; then
    echo "diesel_models v2 build failed — cannot evaluate behavioral gates."
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

###############################################################################
# F2P Gate A (0.30): synthetic probe — schema columns reachable via dsl
# On no-op base: FAILS (columns don't exist).
# On correct fix: PASSES (all 3 columns exposed in table! macro).
###############################################################################
echo ""
echo "=== F2P Gate A [0.30]: synthetic probe — schema columns reachable ==="
PROBE_OK=0
PROBE_FILE="crates/diesel_models/src/_probe_split_payments.rs"
cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports)]
#[cfg(feature = "v2")]
mod probe {
    use crate::schema_v2::payment_intent::dsl as pi_dsl;
    use crate::schema_v2::payment_attempt::dsl as pa_dsl;

    fn _check_columns_exist() {
        let _a = pi_dsl::active_attempts_group_id;
        let _b = pi_dsl::active_attempt_id_type;
        let _c = pa_dsl::attempts_group_id;
    }
}
EOF

LIB="crates/diesel_models/src/lib.rs"
cp "$LIB" /tmp/lib.rs.bak
{
    echo ""
    echo "#[cfg(feature = \"v2\")]"
    echo "mod _probe_split_payments;"
} >> "$LIB"

timeout 300 cargo check -p diesel_models --features v2 2>/tmp/probe.log
PRC=$?

mv /tmp/lib.rs.bak "$LIB"
rm -f "$PROBE_FILE"

if [ $PRC -eq 0 ]; then
    PROBE_OK=1
    echo "PASS Gate A"
    add_reward 0.30
else
    echo "FAIL Gate A"
    tail -25 /tmp/probe.log
fi

###############################################################################
# F2P Gate B (0.30): synthetic probe — struct fields reachable on
# PaymentIntent and PaymentAttempt v2 structs.
# On no-op base: FAILS. On correct fix: PASSES.
###############################################################################
echo ""
echo "=== F2P Gate B [0.30]: synthetic probe — struct fields exist ==="
STRUCT_PROBE_OK=0
PROBE_FILE="crates/diesel_models/src/_probe_struct_fields.rs"
cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports, unused_variables)]
#[cfg(feature = "v2")]
mod probe2 {
    use crate::payment_intent::PaymentIntent;
    use crate::payment_attempt::PaymentAttempt;

    fn _pi_fields(pi: &PaymentIntent) {
        let _x = &pi.active_attempts_group_id;
        let _y = &pi.active_attempt_id_type;
    }

    fn _pa_fields(pa: &PaymentAttempt) {
        let _z = &pa.attempts_group_id;
    }
}
EOF

cp "$LIB" /tmp/lib.rs.bak
{
    echo ""
    echo "#[cfg(feature = \"v2\")]"
    echo "mod _probe_struct_fields;"
} >> "$LIB"

timeout 300 cargo check -p diesel_models --features v2 2>/tmp/probe2.log
PRC=$?

mv /tmp/lib.rs.bak "$LIB"
rm -f "$PROBE_FILE"

if [ $PRC -eq 0 ]; then
    STRUCT_PROBE_OK=1
    echo "PASS Gate B"
    add_reward 0.30
else
    echo "FAIL Gate B"
    tail -25 /tmp/probe2.log
fi

###############################################################################
# F2P Gate C (0.15): synthetic probe — PaymentIntentNew (Insertable) carries
# the new fields too. This catches partial fixes that only touch the read
# struct but forget the insert struct (which would break inserts).
# On no-op base: FAILS. On correct fix: PASSES.
###############################################################################
echo ""
echo "=== F2P Gate C [0.15]: PaymentIntentNew has new fields ==="
NEW_PROBE_OK=0
PROBE_FILE="crates/diesel_models/src/_probe_new_struct.rs"
cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports, unused_variables)]
#[cfg(feature = "v2")]
mod probe3 {
    use crate::payment_intent::PaymentIntentNew;

    fn _pi_new_fields(pi: &PaymentIntentNew) {
        let _x = &pi.active_attempts_group_id;
        let _y = &pi.active_attempt_id_type;
    }
}
EOF

cp "$LIB" /tmp/lib.rs.bak
{
    echo ""
    echo "#[cfg(feature = \"v2\")]"
    echo "mod _probe_new_struct;"
} >> "$LIB"

timeout 300 cargo check -p diesel_models --features v2 2>/tmp/probe3.log
PRC=$?

mv /tmp/lib.rs.bak "$LIB"
rm -f "$PROBE_FILE"

if [ $PRC -eq 0 ]; then
    NEW_PROBE_OK=1
    echo "PASS Gate C"
    add_reward 0.15
else
    echo "FAIL Gate C"
    tail -25 /tmp/probe3.log
fi

###############################################################################
# F2P Gate D (0.15): Migration files contain all 3 columns in up.sql AND a
# matching down.sql. On no-op base: FAILS (no such migration exists). On
# correct fix: PASSES.
###############################################################################
echo ""
echo "=== F2P Gate D [0.15]: migration up+down cover all 3 columns ==="
MIGRATION_UP_OK=0
MIGRATION_DOWN_OK=0
for mdir in migrations v2_migrations; do
    [ -d "$mdir" ] || continue
    for dir in "$mdir"/*/; do
        UP="${dir}up.sql"
        DOWN="${dir}down.sql"
        [ -f "$UP" ] || continue
        if grep -q 'active_attempts_group_id' "$UP" 2>/dev/null && \
           grep -q 'active_attempt_id_type' "$UP" 2>/dev/null && \
           grep -q 'attempts_group_id' "$UP" 2>/dev/null; then
            MIGRATION_UP_OK=1
            echo "  Found up.sql: $UP"
            if [ -f "$DOWN" ] && \
               grep -q 'active_attempts_group_id' "$DOWN" 2>/dev/null && \
               grep -q 'attempts_group_id' "$DOWN" 2>/dev/null; then
                MIGRATION_DOWN_OK=1
                echo "  Found matching down.sql: $DOWN"
            fi
            break 2
        fi
    done
done
if [ $MIGRATION_UP_OK -eq 1 ] && [ $MIGRATION_DOWN_OK -eq 1 ]; then
    echo "PASS Gate D"
    add_reward 0.15
elif [ $MIGRATION_UP_OK -eq 1 ]; then
    echo "PARTIAL Gate D (up only)"
    add_reward 0.07
else
    echo "FAIL Gate D"
fi

###############################################################################
# F2P Gate E (0.10): Broader workspace sanity — hyperswitch_domain_models still
# builds with v2 features. Adding fields to diesel structs commonly breaks
# downstream destructuring; agents that did the work properly thread the new
# fields through. On no-op base: this passes trivially (since no changes).
#
# Therefore we only AWARD this reward if Gates A and B already passed (i.e.
# real changes happened). This way no-op cannot collect free credit here.
###############################################################################
echo ""
echo "=== F2P Gate E [0.10]: hyperswitch_domain_models builds with v2 (post-change) ==="
if [ $PROBE_OK -eq 1 ] && [ $STRUCT_PROBE_OK -eq 1 ]; then
    timeout 900 cargo check -p hyperswitch_domain_models --features v2 2>/tmp/hdm_v2.log
    HDM_RC=$?
    if [ $HDM_RC -eq 0 ]; then
        echo "PASS Gate E"
        add_reward 0.10
    else
        echo "FAIL Gate E (downstream crate broke)"
        tail -30 /tmp/hdm_v2.log
    fi
else
    echo "SKIP Gate E (preconditions A/B not met)"
fi

###############################################################################
echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt