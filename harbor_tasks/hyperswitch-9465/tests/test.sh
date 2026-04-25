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

###############################################################################
# Gate 1 (0.10): Rust syntax validity (regression guard)
###############################################################################
echo "=== Gate 1 [0.10]: Rust syntax validity ==="
SYNTAX_OK=1
for f in crates/diesel_models/src/schema_v2.rs \
         crates/diesel_models/src/payment_intent.rs \
         crates/diesel_models/src/payment_attempt.rs; do
    if [ -f "$f" ]; then
        cp "$f" /tmp/syntax_check.rs
        rustfmt --edition 2021 --check /tmp/syntax_check.rs >/dev/null 2>/tmp/rustfmt_err.txt
        RC=$?
        # rustfmt returns 1 for "would reformat" (ok) and parse errors. Detect parse errors specifically.
        if grep -qiE 'error\[|parse|expected|unexpected token|unclosed' /tmp/rustfmt_err.txt 2>/dev/null; then
            echo "  SYNTAX ERROR in: $f"
            SYNTAX_OK=0
        fi
    else
        echo "  MISSING: $f"
        SYNTAX_OK=0
    fi
done
if [ $SYNTAX_OK -eq 1 ]; then
    echo "PASS Gate 1"
    add_reward 0.10
else
    echo "FAIL Gate 1"
fi

###############################################################################
# Compile diesel_models with v2 (used for behavioral gates)
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

###############################################################################
# Gate 2 (0.25): BEHAVIORAL — diesel_models compiles with v2 feature
# This is the strongest signal; partial structs / missing fields will fail here.
###############################################################################
echo ""
echo "=== Gate 2 [0.25]: cargo check -p diesel_models --features v2 ==="
if [ $CARGO_V2 -eq 0 ]; then
    echo "PASS Gate 2"
    add_reward 0.25
else
    echo "FAIL Gate 2"
fi

###############################################################################
# Gate 3 (0.10): BEHAVIORAL — diesel_models compiles with default features
###############################################################################
echo ""
echo "=== Gate 3 [0.10]: cargo check -p diesel_models (default) ==="
if [ $CARGO_V1 -eq 0 ]; then
    echo "PASS Gate 3"
    add_reward 0.10
else
    echo "FAIL Gate 3"
fi

###############################################################################
# Gate 4 (0.15): BEHAVIORAL via synthetic compile probe.
# Write a tiny Rust file that references the new schema columns and the new
# struct fields. Try to compile it as a probe inside diesel_models. This forces
# the agent to have actually wired the columns into the table! macro AND into
# the struct definitions. Implementation-agnostic on field types.
###############################################################################
echo ""
echo "=== Gate 4 [0.15]: synthetic probe — schema columns reachable ==="
PROBE_OK=0
if [ $CARGO_V2 -eq 0 ]; then
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
    # Hook probe into lib.rs temporarily
    LIB="crates/diesel_models/src/lib.rs"
    cp "$LIB" /tmp/lib.rs.bak
    echo "" >> "$LIB"
    echo "#[cfg(feature = \"v2\")]" >> "$LIB"
    echo "mod _probe_split_payments;" >> "$LIB"

    timeout 300 cargo check -p diesel_models --features v2 2>/tmp/probe.log
    PRC=$?

    # Restore
    mv /tmp/lib.rs.bak "$LIB"
    rm -f "$PROBE_FILE"

    if [ $PRC -eq 0 ]; then
        PROBE_OK=1
    else
        echo "Probe failed:"
        tail -25 /tmp/probe.log
    fi
fi
if [ $PROBE_OK -eq 1 ]; then
    echo "PASS Gate 4"
    add_reward 0.15
else
    echo "FAIL Gate 4"
fi

###############################################################################
# Gate 5 (0.15): BEHAVIORAL probe — struct fields exist on PaymentIntent/Attempt
# Write a probe that pattern-matches the new fields out of the structs.
###############################################################################
echo ""
echo "=== Gate 5 [0.15]: synthetic probe — struct fields exist ==="
STRUCT_PROBE_OK=0
if [ $CARGO_V2 -eq 0 ]; then
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
    LIB="crates/diesel_models/src/lib.rs"
    cp "$LIB" /tmp/lib.rs.bak
    echo "" >> "$LIB"
    echo "#[cfg(feature = \"v2\")]" >> "$LIB"
    echo "mod _probe_struct_fields;" >> "$LIB"

    timeout 300 cargo check -p diesel_models --features v2 2>/tmp/probe2.log
    PRC=$?

    mv /tmp/lib.rs.bak "$LIB"
    rm -f "$PROBE_FILE"

    if [ $PRC -eq 0 ]; then
        STRUCT_PROBE_OK=1
    else
        echo "Struct probe failed:"
        tail -25 /tmp/probe2.log
    fi
fi
if [ $STRUCT_PROBE_OK -eq 1 ]; then
    echo "PASS Gate 5"
    add_reward 0.15
else
    echo "FAIL Gate 5"
fi

###############################################################################
# Gate 6 (0.10): Migration up/down SQL files exist with all 3 columns referenced
###############################################################################
echo ""
echo "=== Gate 6 [0.10]: migration files (up + down) cover all 3 columns ==="
MIGRATION_OK=0
MIGRATION_DOWN_OK=0
for mdir in migrations v2_migrations; do
    [ -d "$mdir" ] || continue
    for dir in "$mdir"/*/; do
        UP="$dir/up.sql"
        DOWN="$dir/down.sql"
        [ -f "$UP" ] || continue
        if grep -q 'active_attempts_group_id' "$UP" 2>/dev/null && \
           grep -q 'active_attempt_id_type' "$UP" 2>/dev/null && \
           grep -q 'attempts_group_id' "$UP" 2>/dev/null; then
            MIGRATION_OK=1
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
if [ $MIGRATION_OK -eq 1 ] && [ $MIGRATION_DOWN_OK -eq 1 ]; then
    echo "PASS Gate 6 (full)"
    add_reward 0.10
elif [ $MIGRATION_OK -eq 1 ]; then
    echo "PARTIAL Gate 6 (up only)"
    add_reward 0.05
else
    echo "FAIL Gate 6"
fi

###############################################################################
# Gate 7 (0.15): Workspace-wide compile sanity — broader crates still build.
# This catches agents who only patched diesel_models but broke downstream
# callers (domain models, router, kafka events, etc.)
###############################################################################
echo ""
echo "=== Gate 7 [0.15]: cargo check -p hyperswitch_domain_models --features v2 ==="
WORKSPACE_OK=0
if [ $CARGO_V2 -eq 0 ]; then
    timeout 900 cargo check -p hyperswitch_domain_models --features v2 2>/tmp/dm_v2.log
    DM_RC=$?
    echo "domain_models v2 exit: $DM_RC"
    tail -15 /tmp/dm_v2.log
    if [ $DM_RC -eq 0 ]; then
        WORKSPACE_OK=1
    fi
fi
if [ $WORKSPACE_OK -eq 1 ]; then
    echo "PASS Gate 7"
    add_reward 0.15
else
    echo "FAIL Gate 7"
fi

###############################################################################
# Final
###############################################################################
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt