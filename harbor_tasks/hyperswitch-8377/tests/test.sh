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


export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
mkdir -p /logs/verifier
REWARD=0.0

cd /workspace/hyperswitch 2>/dev/null || { echo "$REWARD" > /logs/verifier/reward.txt; exit 0; }

echo "============================================"
echo "Hyperswitch PR #8377 Verifier (rewritten)"
echo "v2 endpoint: list payment attempts by intent_id"
echo "============================================"

API_FILE="crates/api_models/src/payments.rs"
HANDLER_FILE="crates/router/src/routes/payments.rs"
CORE_FILE="crates/router/src/core/payments.rs"
APP_FILE="crates/router/src/routes/app.rs"
EVENTS_FILE="crates/api_models/src/events/payment.rs"
LOCK_FILE="crates/router/src/routes/lock_utils.rs"
TYPES_FILE="crates/router_env/src/logger/types.rs"
OPENAPI_V2="crates/openapi/src/openapi_v2.rs"
OPENAPI_ROUTES="crates/openapi/src/routes/payments.rs"

for f in "$API_FILE" "$HANDLER_FILE" "$CORE_FILE" "$APP_FILE" "$EVENTS_FILE" "$LOCK_FILE" "$TYPES_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Missing required file: $f"
        echo "$REWARD" > /logs/verifier/reward.txt
        exit 0
    fi
done

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo not on PATH"
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ─── Detect whether the agent did anything (no-op guard) ───
# A no-op should have none of these. Any present means at least one edit occurred.
EDITS_DETECTED=0
grep -qE "list_payment_attempts|payments_list_attempts|PaymentAttemptListResponse|PaymentAttemptsListResponse|PaymentListAttemptsResponse|PaymentsListAttempts|PaymentsAttemptList" \
    "$API_FILE" "$HANDLER_FILE" "$CORE_FILE" "$APP_FILE" "$EVENTS_FILE" "$LOCK_FILE" "$TYPES_FILE" 2>/dev/null && EDITS_DETECTED=1

if [ $EDITS_DETECTED -eq 0 ]; then
    echo "No edits detected — no-op patch."
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

# ─── P2P GATE: router_env compiles (regression guard, no reward) ───
echo ""
echo "=== P2P GATE: router_env compiles ==="
cargo check -p router_env --quiet 2>&1 | tail -5
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "REGRESSION: router_env broken"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi
echo "OK"

# ─── P2P GATE: api_models compiles with v2 (regression guard) ───
echo ""
echo "=== P2P GATE: api_models compiles with v2 ==="
cargo check -p api_models --no-default-features --features "v2" --quiet 2>&1 | tail -10
APIMODELS_RC=${PIPESTATUS[0]}
if [ $APIMODELS_RC -ne 0 ]; then
    echo "REGRESSION: api_models broken with v2"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi
echo "OK"

REWARD_AWK="0.00"

# ===========================================================================
# F2P Gate 1 — New response type with payment_attempts: Vec<...> in api_models
# Weight: 0.06 (scaled from 0.10 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 1: New response type in api_models ==="
TYPE_NAME=$(awk '
  /pub struct [A-Za-z0-9_]+/ {
      match($0, /pub struct [A-Za-z0-9_]+/);
      name=substr($0,RSTART+11,RLENGTH-11);
      current=name;
      inside=1;
      brace=0;
  }
  inside==1 {
      for(i=1;i<=length($0);i++){
        c=substr($0,i,1);
        if(c=="{") brace++;
        if(c=="}") { brace--; if(brace<=0 && inside==1){inside=0; break} }
      }
      if(/payment_attempts[[:space:]]*:[[:space:]]*Vec[[:space:]]*</){
          if(current ~ /[Aa]ttempt/ && (current ~ /[Ll]ist/ || current ~ /[Rr]esponse/)){
            print current; exit
          }
      }
  }
' "$API_FILE")
if [ -n "$TYPE_NAME" ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.06}')
    echo "PASS: detected response type '$TYPE_NAME' (+0.06)"
else
    echo "FAIL: no response type with payment_attempts: Vec<..> found"
fi

# ===========================================================================
# F2P Gate 2 — Handler function exists and is wired to a list-attempts core fn
# Weight: 0.09 (scaled from 0.15 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 2: Handler function and wiring ==="
HANDLER_NAME=$(grep -oE "pub async fn [a-zA-Z0-9_]*(list_payment_attempts|payments_list_attempts)[a-zA-Z0-9_]*" "$HANDLER_FILE" | head -1 | awk '{print $4}')
if [ -n "$HANDLER_NAME" ]; then
    awk -v fn="$HANDLER_NAME" '
      $0 ~ "pub async fn "fn"\\(" {found=1; brace=0; started=0}
      found {
          print;
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1);
            if(c=="{") {brace++; started=1}
            else if(c=="}") { brace--; if(started && brace==0){exit} }
          }
      }
    ' "$HANDLER_FILE" > /tmp/handler_body.txt
    if grep -qE "list_payment_attempts|payments_list_attempts" /tmp/handler_body.txt && \
       grep -qE "GlobalPaymentId|payment_id" /tmp/handler_body.txt; then
        REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.09}')
        echo "PASS: handler '$HANDLER_NAME' wired to core list-attempts (+0.09)"
    else
        echo "FAIL: handler exists but does not call list_payment_attempts core fn with payment id"
    fi
    rm -f /tmp/handler_body.txt
else
    echo "FAIL: no handler function found"
fi

# ===========================================================================
# F2P Gate 3 — Core fn queries attempts by intent and returns the new type
# Weight: 0.09 (scaled from 0.15 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 3: Core list_payment_attempts function ==="
CORE_FN=$(grep -oE "pub async fn list_payment_attempts" "$CORE_FILE" | head -1 | awk '{print $4}')
CORE_OK=0
if [ -n "$CORE_FN" ]; then
    awk -v fn="$CORE_FN" '
      $0 ~ "pub async fn "fn"\\(" {found=1; brace=0; started=0}
      found {
          print;
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1);
            if(c=="{") {brace++; started=1}
            else if(c=="}") { brace--; if(started && brace==0){exit} }
          }
      }
    ' "$CORE_FILE" > /tmp/core_body.txt

    HAS_QUERY=0
    HAS_TYPE=0
    HAS_GLOBAL_ID=0
    grep -qE "find_payment_attempts_by_payment_intent_id|find_attempts_by_payment_intent|payment_attempts_by_payment_intent" /tmp/core_body.txt && HAS_QUERY=1
    grep -qE "PaymentAttemptListResponse|PaymentAttemptsListResponse|PaymentListAttemptsResponse" /tmp/core_body.txt && HAS_TYPE=1
    grep -qE "GlobalPaymentId|payment_id" /tmp/core_body.txt && HAS_GLOBAL_ID=1

    if [ $HAS_QUERY -eq 1 ] && [ $HAS_TYPE -eq 1 ] && [ $HAS_GLOBAL_ID -eq 1 ]; then
        CORE_OK=1
    fi
    rm -f /tmp/core_body.txt
fi
if [ $CORE_OK -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.09}')
    echo "PASS: core fn queries attempts and returns list response (+0.09)"
else
    echo "FAIL: core fn missing or doesn't query/return correctly"
fi

# ===========================================================================
# F2P Gate 4 — Route registered with GET method on /payments/{id}/(list_)attempts
# Weight: 0.06 (scaled from 0.10 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 4: Route registration ==="
ROUTE_OK=0
# Look in app.rs for: web::resource("/list_attempts" or "/attempts") + GET + the handler name
if grep -qE 'web::resource\("/(list_attempts|attempts)"\)[[:space:]]*\.route\(web::get\(\)\.to\(payments::(list_payment_attempts|payments_list_attempts)\)\)' "$APP_FILE"; then
    ROUTE_OK=1
else
    # Try multi-line tolerance
    awk '
      /web::resource\("\/(list_attempts|attempts)"\)/ {found=1; buf=""}
      found {buf = buf $0 " "; if(buf ~ /web::get\(\)/ && buf ~ /(list_payment_attempts|payments_list_attempts)/){print "MATCH"; exit}}
    ' "$APP_FILE" | grep -q MATCH && ROUTE_OK=1
fi
if [ $ROUTE_OK -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.06}')
    echo "PASS: GET route /list_attempts or /attempts registered (+0.06)"
else
    echo "FAIL: route not properly registered"
fi

# ===========================================================================
# F2P Gate 5 — Auxiliary plumbing (Flow variant, lock_utils, ApiEventMetric)
# Weight: 0.06  (3 sub-checks, partial credit; scaled from 0.10)
# ===========================================================================
echo ""
echo "=== F2P Gate 5: Auxiliary plumbing (Flow + lock_utils + ApiEventMetric) ==="
AUX_SCORE=0
FLOW_VARIANT=""
if grep -qE "PaymentsListAttempts|PaymentsAttemptList" "$TYPES_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    FLOW_VARIANT=$(grep -oE "PaymentsListAttempts|PaymentsAttemptList" "$TYPES_FILE" | head -1)
    echo "  + Flow variant '$FLOW_VARIANT' added"
else
    echo "  - Flow variant missing"
fi
if grep -qE "PaymentsListAttempts|PaymentsAttemptList" "$LOCK_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    echo "  + lock_utils mapping added"
else
    echo "  - lock_utils mapping missing"
fi
if grep -qE "impl ApiEventMetric for (api_models::payments::|payments::)?(PaymentAttemptListResponse|PaymentAttemptsListResponse|PaymentListAttemptsResponse)" "$EVENTS_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    echo "  + ApiEventMetric impl added"
else
    echo "  - ApiEventMetric impl missing"
fi
AUX_REWARD=$(awk -v s=$AUX_SCORE 'BEGIN{printf "%.4f", (s/3.0)*0.06}')
REWARD_AWK=$(awk -v r="$REWARD_AWK" -v a="$AUX_REWARD" 'BEGIN{printf "%.4f", r+a}')
echo "Aux subscore: $AUX_SCORE/3 → +$AUX_REWARD"

# ===========================================================================
# F2P Gate 6 — Behavioral / dominant: full router crate compiles with v2
# Weight: 0.24 (scaled from 0.40 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 6: cargo check -p router with v2 features ==="
cargo check -p router --no-default-features --features "v2,olap,oltp" --quiet 2>&1 | tail -40
G_RC=${PIPESTATUS[0]}
if [ $G_RC -ne 0 ]; then
    echo "Retrying with extra features..."
    cargo check -p router --no-default-features --features "v2,olap,oltp,kv_store,stripe,payouts,frm,dummy_connector,recon" --quiet 2>&1 | tail -40
    G_RC=${PIPESTATUS[0]}
fi
if [ $G_RC -eq 0 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.24}')
    echo "PASS: router crate compiles with v2 features (+0.24)"
else
    echo "FAIL: router crate does not compile with v2 features"
fi

REWARD=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r}')

echo ""
echo "============================================"
echo "PER-TURN REWARD: $REWARD"
echo "============================================"

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH="/usr/local/cargo/bin:$PATH"
command -v rustup >/dev/null 2>&1 && (rustup show active-toolchain >/dev/null 2>&1 || rustup default stable 2>&1 || rustup install stable 2>&1 || true)

mkdir -p /logs/verifier

echo ""
echo "=== Upstream Gate: f2p_upstream_openapi_route ==="
if cd /workspace/hyperswitch && grep -q 'list_payment_attempts' crates/openapi/src/routes/payments.rs; then
    echo '{"id": "f2p_upstream_openapi_route", "passed": true, "detail": "list_payment_attempts found in openapi routes"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_openapi_route", "passed": false, "detail": "list_payment_attempts not found in openapi routes"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

echo ""
echo "=== Upstream Gate: f2p_upstream_openapi_v2_schema ==="
if cd /workspace/hyperswitch && grep -q 'PaymentListAttemptsResponse' crates/openapi/src/openapi_v2.rs; then
    echo '{"id": "f2p_upstream_openapi_v2_schema", "passed": true, "detail": "PaymentListAttemptsResponse found in openapi_v2.rs"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_openapi_v2_schema", "passed": false, "detail": "PaymentListAttemptsResponse not found in openapi_v2.rs"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

echo ""
echo "=== Upstream Gate: p2p_upstream_cargo_metadata ==="
if cd /workspace/hyperswitch && cargo metadata --format-version 1 --no-deps > /dev/null 2>&1; then
    echo '{"id": "p2p_upstream_cargo_metadata", "passed": true, "detail": "cargo metadata succeeded"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "p2p_upstream_cargo_metadata", "passed": false, "detail": "cargo metadata failed"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi
# ---- end upstream gates ----

# ---- upstream reward adjustment ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_response_type": 0.06,
    "f2p_handler_wiring": 0.09,
    "f2p_core_fn": 0.09,
    "f2p_route_registration": 0.06,
    "f2p_auxiliary_plumbing": 0.06,
    "f2p_cargo_check_router_v2": 0.24,
    "f2p_upstream_openapi_route": 0.2,
    "f2p_upstream_openapi_v2_schema": 0.2
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

p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Preserve the bash-computed legacy reward and add upstream F2P gate
    # weights on top for any upstream gate that passed.
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
echo ""
echo "============================================"
FINAL_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "0.0000")
echo "FINAL REWARD (after upstream gates): $FINAL_REWARD"
echo "============================================"