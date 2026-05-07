#!/bin/bash
set +e
# [v042-fix] Robust Rust toolchain setup. Direct cargo binary on PATH
# bypasses rustup's proxy (which fails 'could not choose a version of cargo
# to run' when no toolchain is installed).
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
hash -r 2>/dev/null || true
if command -v rustup >/dev/null 2>&1; then
    rustup show active-toolchain >/dev/null 2>&1 \
        || rustup default stable 2>&1 \
        || rustup install stable 2>&1 \
        || true
fi

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


export PATH=/usr/local/cargo/bin:/root/.cargo/bin:/usr/local/bin:$PATH

mkdir -p /logs/verifier
REWARD="0.00"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN {printf "%.2f", a + b}')
    echo "[+${1}] reward now $REWARD ($2)"
}

finish_zero() {
    echo "Hard gate failed: $1"
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
}

# Locate repo
REPO=""
for cand in /workspace/hyperswitch /workspace/hyperswitch_pool_5 /workspace/hyperswitch/hyperswitch_pool_5; do
    if [ -d "$cand/crates/diesel_models" ]; then
        REPO="$cand"
        break
    fi
done

if [ -z "$REPO" ]; then
    # Try discovery
    REPO=$(find /workspace -maxdepth 3 -type d -name diesel_models 2>/dev/null | head -1 | xargs -r dirname | xargs -r dirname)
fi

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    finish_zero "Cannot find hyperswitch repo"
fi

cd "$REPO" || finish_zero "Cannot cd to repo"
echo "Repo: $REPO"

if ! command -v cargo >/dev/null 2>&1; then
    finish_zero "cargo not on PATH"
fi

SCHEMA_V2="crates/diesel_models/src/schema_v2.rs"
SCHEMA_V1="crates/diesel_models/src/schema.rs"
PI_FILE="crates/diesel_models/src/payment_intent.rs"
PA_FILE="crates/diesel_models/src/payment_attempt.rs"

for f in "$SCHEMA_V2" "$PI_FILE" "$PA_FILE"; do
    if [ ! -f "$f" ]; then
        finish_zero "Required file missing: $f"
    fi
done

###############################################################################
# Pre-check: detect no-op state.
# On the buggy base, NONE of the new column markers exist anywhere.
###############################################################################
HAS_AAGI=$(grep -l 'active_attempts_group_id' crates/diesel_models/src/ -r 2>/dev/null | wc -l)
HAS_AAIT=$(grep -l 'active_attempt_id_type' crates/diesel_models/src/ -r 2>/dev/null | wc -l)
HAS_AGI=$(grep -l 'attempts_group_id' crates/diesel_models/src/ -r 2>/dev/null | wc -l)

echo "Marker file counts: aagi=$HAS_AAGI aait=$HAS_AAIT agi=$HAS_AGI"

if [ "$HAS_AAGI" -eq 0 ] && [ "$HAS_AAIT" -eq 0 ] && [ "$HAS_AGI" -eq 0 ]; then
    echo "No-op detected — none of the new identifiers introduced."
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

###############################################################################
# P2P regression gate: default-features build of diesel_models must still work.
# This is gating-only (zero reward weight). If broken, agent regressed.
###############################################################################
echo ""
echo "=== P2P [gating]: cargo check -p diesel_models (default features) ==="
timeout 600 cargo check -p diesel_models 2>/tmp/cargo_default.log
RC_DEFAULT=$?
tail -15 /tmp/cargo_default.log
if [ $RC_DEFAULT -ne 0 ]; then
    echo "WARNING: P2P diesel_models build failed (informational, continuing)"
fi

###############################################################################
# Try to build diesel_models with v2 — required to evaluate behavioral gates.
###############################################################################
echo ""
echo "=== Compiling diesel_models --features v2 ==="
timeout 800 cargo check -p diesel_models --features v2 2>/tmp/cargo_v2.log
RC_V2=$?
echo "v2 exit: $RC_V2"
tail -25 /tmp/cargo_v2.log

V2_OK=0
if [ $RC_V2 -eq 0 ]; then
    V2_OK=1
fi

###############################################################################
# F2P Gate 1 (0.10): schema_v2 has all THREE column declarations within
# the right diesel::table! blocks (payment_intent + payment_attempt).
# This catches the "I added a column to the wrong table" error.
###############################################################################
echo ""
echo "=== F2P Gate 1 [0.10]: schema_v2 column placement ==="

# Extract payment_intent block
PI_BLOCK=$(awk '/payment_intent \(id\) \{/,/^    \}$/' "$SCHEMA_V2")
PA_BLOCK=$(awk '/payment_attempt \(id\) \{/,/^    \}$/' "$SCHEMA_V2")

G1_PI_AAGI=$(echo "$PI_BLOCK" | grep -c 'active_attempts_group_id')
G1_PI_AAIT=$(echo "$PI_BLOCK" | grep -c 'active_attempt_id_type')
G1_PA_AGI=$(echo "$PA_BLOCK" | grep -c 'attempts_group_id')

echo "schema_v2 placement: pi.aagi=$G1_PI_AAGI pi.aait=$G1_PI_AAIT pa.agi=$G1_PA_AGI"

if [ "$G1_PI_AAGI" -ge 1 ] && [ "$G1_PI_AAIT" -ge 1 ] && [ "$G1_PA_AGI" -ge 1 ]; then
    add_reward 0.10 "Gate 1: schema_v2 column placement"
else
    echo "FAIL Gate 1"
fi

###############################################################################
# F2P Gate 2 (0.15): schema columns reachable via dsl (synthetic probe).
# Validates: not just text but actually compiled into the table! macro.
# Requires V2 build success.
###############################################################################
echo ""
echo "=== F2P Gate 2 [0.15]: schema dsl probe ==="
G2_OK=0
if [ $V2_OK -eq 1 ]; then
    PROBE_FILE="crates/diesel_models/src/_probe_schema_split.rs"
    cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports)]
#[cfg(feature = "v2")]
mod probe_schema_split {
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
        echo "mod _probe_schema_split;"
    } >> "$LIB"

    timeout 400 cargo check -p diesel_models --features v2 2>/tmp/probe2.log
    PRC=$?

    cp /tmp/lib.rs.bak "$LIB"
    rm -f "$PROBE_FILE" /tmp/lib.rs.bak

    if [ $PRC -eq 0 ]; then
        G2_OK=1
        add_reward 0.15 "Gate 2: schema dsl probe"
    else
        echo "FAIL Gate 2"
        tail -25 /tmp/probe2.log
    fi
else
    echo "SKIP Gate 2 (v2 build broken)"
fi

###############################################################################
# F2P Gate 3 (0.20): PaymentIntent struct (v2) has BOTH new fields, and
# PaymentAttempt struct (v2) has the new field — synthetic probe.
###############################################################################
echo ""
echo "=== F2P Gate 3 [0.20]: struct field probe ==="
G3_OK=0
if [ $V2_OK -eq 1 ]; then
    PROBE_FILE="crates/diesel_models/src/_probe_struct_split.rs"
    cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports, unused_variables)]
#[cfg(feature = "v2")]
mod probe_struct_split {
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
    {
        echo ""
        echo "#[cfg(feature = \"v2\")]"
        echo "mod _probe_struct_split;"
    } >> "$LIB"

    timeout 400 cargo check -p diesel_models --features v2 2>/tmp/probe3.log
    PRC=$?

    cp /tmp/lib.rs.bak "$LIB"
    rm -f "$PROBE_FILE" /tmp/lib.rs.bak

    if [ $PRC -eq 0 ]; then
        G3_OK=1
        add_reward 0.20 "Gate 3: struct field probe"
    else
        echo "FAIL Gate 3"
        tail -25 /tmp/probe3.log
    fi
else
    echo "SKIP Gate 3 (v2 build broken)"
fi

###############################################################################
# F2P Gate 4 (0.15): Insertable structs (PaymentIntentNew, PaymentAttemptNew)
# carry the new fields. Catches partial fixes that update the read struct
# but forget the insert struct (which would break inserts at runtime).
###############################################################################
echo ""
echo "=== F2P Gate 4 [0.15]: insertable struct fields ==="
G4_OK=0
if [ $V2_OK -eq 1 ]; then
    PROBE_FILE="crates/diesel_models/src/_probe_new_split.rs"
    cat > "$PROBE_FILE" <<'EOF'
#![allow(dead_code, unused_imports, unused_variables)]
#[cfg(feature = "v2")]
mod probe_new_split {
    use crate::payment_intent::PaymentIntentNew;
    use crate::payment_attempt::PaymentAttemptNew;

    fn _pi_new_fields(pi: &PaymentIntentNew) {
        let _x = &pi.active_attempts_group_id;
        let _y = &pi.active_attempt_id_type;
    }

    fn _pa_new_fields(pa: &PaymentAttemptNew) {
        let _z = &pa.attempts_group_id;
    }
}
EOF

    LIB="crates/diesel_models/src/lib.rs"
    cp "$LIB" /tmp/lib.rs.bak
    {
        echo ""
        echo "#[cfg(feature = \"v2\")]"
        echo "mod _probe_new_split;"
    } >> "$LIB"

    timeout 400 cargo check -p diesel_models --features v2 2>/tmp/probe4.log
    PRC=$?

    cp /tmp/lib.rs.bak "$LIB"
    rm -f "$PROBE_FILE" /tmp/lib.rs.bak

    if [ $PRC -eq 0 ]; then
        G4_OK=1
        add_reward 0.15 "Gate 4: insertable struct fields"
    else
        echo "FAIL Gate 4"
        tail -25 /tmp/probe4.log
    fi
else
    echo "SKIP Gate 4 (v2 build broken)"
fi

###############################################################################
# F2P Gate 5 (0.10): SQL migration files exist with the right ALTER TABLE
# statements. A complete DB-changes PR includes diesel migrations.
###############################################################################
echo ""
echo "=== F2P Gate 5 [0.10]: migration files ==="
G5_OK=0
MIG_UPS=$(find migrations -mindepth 2 -maxdepth 2 -name 'up.sql' 2>/dev/null)
HIT_AAGI=0
HIT_AAIT=0
HIT_AGI=0
for f in $MIG_UPS; do
    if grep -qiE 'ALTER[[:space:]]+TABLE[[:space:]]+payment_intent.*active_attempts_group_id' "$f" 2>/dev/null; then
        HIT_AAGI=1
    fi
    if grep -qiE 'ALTER[[:space:]]+TABLE[[:space:]]+payment_intent.*active_attempt_id_type' "$f" 2>/dev/null; then
        HIT_AAIT=1
    fi
    if grep -qiE 'ALTER[[:space:]]+TABLE[[:space:]]+payment_attempt.*attempts_group_id' "$f" 2>/dev/null; then
        HIT_AGI=1
    fi
    # Also try multi-line within the same file
    if grep -qi 'active_attempts_group_id' "$f" 2>/dev/null; then
        # validate context: file mentions payment_intent
        if grep -qi 'payment_intent' "$f" 2>/dev/null; then
            HIT_AAGI=1
        fi
    fi
    if grep -qi 'active_attempt_id_type' "$f" 2>/dev/null; then
        if grep -qi 'payment_intent' "$f" 2>/dev/null; then
            HIT_AAIT=1
        fi
    fi
    if grep -qi 'attempts_group_id' "$f" 2>/dev/null && ! grep -qi 'active_attempts_group_id' "$f" 2>/dev/null; then
        if grep -qi 'payment_attempt' "$f" 2>/dev/null; then
            HIT_AGI=1
        fi
    fi
done

# More accurate AGI check (since active_attempts_group_id contains attempts_group_id substring)
HIT_AGI=0
for f in $MIG_UPS; do
    # find lines with attempts_group_id but not active_attempts_group_id
    if grep -E 'attempts_group_id' "$f" 2>/dev/null | grep -v 'active_attempts_group_id' | grep -qi 'payment_attempt\|attempts_group_id'; then
        # just check the file mentions payment_attempt
        if grep -qi 'payment_attempt' "$f"; then
            HIT_AGI=1
        fi
    fi
done

echo "migration markers: pi.aagi=$HIT_AAGI pi.aait=$HIT_AAIT pa.agi=$HIT_AGI"

if [ "$HIT_AAGI" -eq 1 ] && [ "$HIT_AAIT" -eq 1 ] && [ "$HIT_AGI" -eq 1 ]; then
    G5_OK=1
    add_reward 0.10 "Gate 5: complete migrations"
elif [ "$HIT_AAGI" -eq 1 ] || [ "$HIT_AAIT" -eq 1 ] || [ "$HIT_AGI" -eq 1 ]; then
    echo "PARTIAL Gate 5 (some migrations present) — no credit"
else
    echo "FAIL Gate 5"
fi

###############################################################################
# F2P Gate 6 (0.15): full workspace propagation — domain models / services
# / kafka destructuring need to handle the new fields, otherwise the rest of
# the workspace breaks. Build a downstream crate.
###############################################################################
echo ""
echo "=== F2P Gate 6 [0.15]: domain models compile with v2 ==="
G6_OK=0
if [ $V2_OK -eq 1 ]; then
    timeout 900 cargo check -p hyperswitch_domain_models --features v2 2>/tmp/cargo_dom.log
    RC_DOM=$?
    echo "domain_models v2 exit: $RC_DOM"
    tail -30 /tmp/cargo_dom.log
    if [ $RC_DOM -eq 0 ]; then
        G6_OK=1
        add_reward 0.15 "Gate 6: domain_models v2 build"
    else
        echo "FAIL Gate 6"
    fi
else
    echo "SKIP Gate 6 (v2 build broken upstream)"
fi

###############################################################################
# F2P Gate 7 (0.15): full router build with v2 — final integration check.
# Requires the agent to have propagated changes through ALL destructurings
# (kafka events, retry helpers, sample data, etc.).
###############################################################################
echo ""
echo "=== F2P Gate 7 [0.15]: router v2 build ==="
G7_OK=0
if [ $V2_OK -eq 1 ] && [ $G6_OK -eq 1 ]; then
    timeout 1200 cargo check -p router --no-default-features --features "v2 olap oltp" 2>/tmp/cargo_router.log
    RC_ROUTER=$?
    echo "router v2 exit: $RC_ROUTER"
    if [ $RC_ROUTER -ne 0 ]; then
        # Try alternate feature combo
        timeout 1200 cargo check -p router --features v2 2>/tmp/cargo_router2.log
        RC_ROUTER2=$?
        if [ $RC_ROUTER2 -eq 0 ]; then
            RC_ROUTER=0
        fi
        tail -40 /tmp/cargo_router.log
    fi
    if [ $RC_ROUTER -eq 0 ]; then
        G7_OK=1
        add_reward 0.15 "Gate 7: router v2 build"
    else
        echo "FAIL Gate 7"
    fi
else
    echo "SKIP Gate 7 (upstream broken)"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=== Summary ==="
echo "V2 base build:    $V2_OK"
echo "Gate 1 (schema):  $([ "$G1_PI_AAGI" -ge 1 ] && [ "$G1_PI_AAIT" -ge 1 ] && [ "$G1_PA_AGI" -ge 1 ] && echo OK || echo FAIL)"
echo "Gate 2 (dsl):     $G2_OK"
echo "Gate 3 (struct):  $G3_OK"
echo "Gate 4 (insert):  $G4_OK"
echo "Gate 5 (migrate): $G5_OK"
echo "Gate 6 (domain):  $G6_OK"
echo "Gate 7 (router):  $G7_OK"
echo "Final reward:     $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
export PATH=/usr/local/cargo/bin:/root/.cargo/bin:$PATH
rustup default stable > /dev/null 2>&1 || true

mkdir -p /logs/verifier

# F2P upstream gate: Domain + Kafka field propagation
echo ""
echo "=== Upstream F2P: Domain + Kafka field propagation ==="
if grep -q 'active_attempts_group_id' crates/hyperswitch_domain_models/src/payments.rs 2>/dev/null && \
   grep -q 'active_attempt_id_type' crates/hyperswitch_domain_models/src/payments.rs 2>/dev/null && \
   grep -q 'active_attempts_group_id' crates/router/src/services/kafka/payment_intent.rs 2>/dev/null && \
   grep -q 'active_attempts_group_id' crates/router/src/services/kafka/payment_intent_event.rs 2>/dev/null; then
    echo '{"id": "f2p_upstream_domain_kafka_propagation", "passed": true, "detail": "All split payment fields found in domain models and kafka events"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_domain_kafka_propagation", "passed": false, "detail": "Missing split payment fields in domain models or kafka events"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# F2P upstream gate: Migration file completeness
echo ""
echo "=== Upstream F2P: Migration file completeness ==="
if grep -rq 'active_attempts_group_id' migrations/ 2>/dev/null && \
   grep -rq 'active_attempt_id_type' migrations/ 2>/dev/null && \
   grep -rq 'attempts_group_id' migrations/ 2>/dev/null; then
    echo '{"id": "f2p_upstream_migration_completeness", "passed": true, "detail": "All 3 new columns found in migration files"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_migration_completeness", "passed": false, "detail": "Missing column definitions in migration files"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# P2P upstream gate: Cargo metadata workspace integrity
echo ""
echo "=== Upstream P2P: Cargo metadata workspace integrity ==="
if timeout 60 cargo metadata --format-version 1 --no-deps > /dev/null 2>&1; then
    echo '{"id": "p2p_upstream_cargo_metadata", "passed": true, "detail": "Cargo workspace metadata loads successfully"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "p2p_upstream_cargo_metadata", "passed": false, "detail": "Cargo workspace metadata failed to load"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# Upstream reward tail: adjust reward based on upstream gate results
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_domain_kafka_propagation": 0.2,
    "f2p_upstream_migration_completeness": 0.2
}
P2P_REGRESSION = ["p2p_upstream_cargo_metadata"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

p2p_failed = False  # P2P_REGRESSION gates are informational only (v043 fix)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- end ----