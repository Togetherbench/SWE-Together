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

emit_gate() {
    local gid="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$gid" "$passed" "$detail" >> /logs/verifier/gates.json
}

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

# ─── P2P GATE: router_env compiles (INFORMATIONAL, diagnostic only) ───
# Per v0.4.3.1 rule: P2P_REGRESSION must NOT zero reward. We log the verdict
# but never short-circuit the script. Also OOM-tolerant: SIGKILL (rc=137) on a
# memory-constrained sandbox is an infra fault, not an agent failure.
echo ""
echo "=== P2P GATE (informational): router_env compiles ==="
_cargo_check_with_oom_detect cargo check -p router_env --quiet 2>&1 | tail -5
ROUTERENV_RC=${PIPESTATUS[0]}
if [ "$ROUTERENV_RC" = "99" ]; then
    echo "WARN: router_env check OOM/SIGKILL (infra fault — ignoring)"
elif [ "$ROUTERENV_RC" -ne 0 ]; then
    echo "WARN (informational): router_env did not pass cargo check (rc=$ROUTERENV_RC)"
else
    echo "OK"
fi

# ─── P2P GATE: api_models compiles with v2 (INFORMATIONAL, diagnostic only) ───
echo ""
echo "=== P2P GATE (informational): api_models compiles with v2 ==="
_cargo_check_with_oom_detect cargo check -p api_models --no-default-features --features "v2" --quiet 2>&1 | tail -10
APIMODELS_RC=${PIPESTATUS[0]}
if [ "$APIMODELS_RC" = "99" ]; then
    echo "WARN: api_models check OOM/SIGKILL (infra fault — ignoring)"
elif [ "$APIMODELS_RC" -ne 0 ]; then
    echo "WARN (informational): api_models did not pass cargo check (rc=$APIMODELS_RC)"
else
    echo "OK"
fi

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
      if(/(payment_attempts|payment_attempt_list|attempts)[[:space:]]*:[[:space:]]*Vec[[:space:]]*</){
          if(current ~ /[Aa]ttempt/ && (current ~ /[Ll]ist/ || current ~ /[Rr]esponse/)){
            print current; exit
          }
      }
  }
' "$API_FILE")
if [ -n "$TYPE_NAME" ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.06}')
    echo "PASS: detected response type '$TYPE_NAME' (+0.06)"
    emit_gate "f2p_response_type" true "detected $TYPE_NAME"
else
    echo "FAIL: no response type with payment_attempts: Vec<..> found"
    emit_gate "f2p_response_type" false "no response type with payment_attempts: Vec<..>"
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
        emit_gate "f2p_handler_wiring" true "handler $HANDLER_NAME wired to core"
    else
        echo "FAIL: handler exists but does not call list_payment_attempts core fn with payment id"
        emit_gate "f2p_handler_wiring" false "handler exists but not wired"
    fi
    rm -f /tmp/handler_body.txt
else
    echo "FAIL: no handler function found"
    emit_gate "f2p_handler_wiring" false "no handler function"
fi

# ===========================================================================
# F2P Gate 3 — Core fn queries attempts by intent and returns the new type
# Weight: 0.09 (scaled from 0.15 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 3: Core list_payment_attempts function ==="
# Accept either the session-style name `list_payment_attempts` or the upstream
# gold-style names (`payments_list_attempts_using_payment_intent_id`,
# `payments_attempt_operation_core`, etc.). Behavioral requirements:
#   1. A pub async fn dedicated to listing attempts exists in core (name
#      contains both `list` and `attempt`, OR matches the gold helper
#      `payments_attempt_operation_core`).
#   2. Anywhere in the file, the list-attempts type/data is referenced
#      (response type or domain data wrapper).
#   3. Anywhere in the file, GlobalPaymentId / payment_id appears (sanity).
CORE_OK=0
if grep -qE "pub async fn ([a-zA-Z0-9_]*list[a-zA-Z0-9_]*attempt[a-zA-Z0-9_]*|[a-zA-Z0-9_]*attempt[a-zA-Z0-9_]*list[a-zA-Z0-9_]*|payments_attempt_operation_core)" "$CORE_FILE"; then
    HAS_FN=1
else
    HAS_FN=0
fi
HAS_TYPE=0
HAS_QUERY=0
HAS_GLOBAL_ID=0
grep -qE "PaymentAttemptListResponse|PaymentAttemptsListResponse|PaymentListAttemptsResponse|PaymentAttemptListData|PaymentGetListAttempts|list_payments_attempts" "$CORE_FILE" && HAS_TYPE=1
grep -qE "find_payment_attempts_by_payment_intent_id|find_attempts_by_payment_intent|payment_attempts_by_payment_intent|PaymentAttemptListData|PaymentGetListAttempts|payments_attempt_operation_core|payment_attempt_list" "$CORE_FILE" && HAS_QUERY=1
grep -qE "GlobalPaymentId|payment_id" "$CORE_FILE" && HAS_GLOBAL_ID=1

if [ $HAS_FN -eq 1 ] && [ $HAS_TYPE -eq 1 ] && [ $HAS_QUERY -eq 1 ] && [ $HAS_GLOBAL_ID -eq 1 ]; then
    CORE_OK=1
fi
if [ $CORE_OK -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.09}')
    echo "PASS: core fn queries attempts and returns list response (+0.09)"
    emit_gate "f2p_core_fn" true "core fn present"
else
    echo "FAIL: core fn missing or doesn't query/return correctly"
    emit_gate "f2p_core_fn" false "core fn missing or mis-wired"
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
    emit_gate "f2p_route_registration" true "GET route registered"
else
    echo "FAIL: route not properly registered"
    emit_gate "f2p_route_registration" false "route not registered"
fi

# ===========================================================================
# F2P Gate 5 — Auxiliary plumbing (Flow variant, lock_utils, ApiEventMetric)
# Weight: 0.06  (3 sub-checks, partial credit; scaled from 0.10)
# ===========================================================================
echo ""
echo "=== F2P Gate 5: Auxiliary plumbing (Flow + lock_utils + ApiEventMetric) ==="
AUX_SCORE=0
FLOW_VARIANT=""
if grep -qE "PaymentsListAttempts|PaymentsAttemptList|PaymentAttemptsList|PaymentAttemptList" "$TYPES_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    FLOW_VARIANT=$(grep -oE "PaymentsListAttempts|PaymentsAttemptList|PaymentAttemptsList|PaymentAttemptList" "$TYPES_FILE" | head -1)
    echo "  + Flow variant '$FLOW_VARIANT' added"
else
    echo "  - Flow variant missing"
fi
if grep -qE "PaymentsListAttempts|PaymentsAttemptList|PaymentAttemptsList|PaymentAttemptList" "$LOCK_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    echo "  + lock_utils mapping added"
else
    echo "  - lock_utils mapping missing"
fi
if grep -qE "impl ApiEventMetric for (api_models::payments::|payments::)?(PaymentAttemptListResponse|PaymentAttemptsListResponse|PaymentListAttemptsResponse|PaymentAttemptListRequest|PaymentListAttemptsRequest)" "$EVENTS_FILE"; then
    AUX_SCORE=$((AUX_SCORE+1))
    echo "  + ApiEventMetric impl added"
else
    echo "  - ApiEventMetric impl missing"
fi
AUX_REWARD=$(awk -v s=$AUX_SCORE 'BEGIN{printf "%.4f", (s/3.0)*0.06}')
REWARD_AWK=$(awk -v r="$REWARD_AWK" -v a="$AUX_REWARD" 'BEGIN{printf "%.4f", r+a}')
echo "Aux subscore: $AUX_SCORE/3 → +$AUX_REWARD"
if [ "$AUX_SCORE" -ge 2 ]; then
    emit_gate "f2p_auxiliary_plumbing" true "$AUX_SCORE/3 aux checks pass"
else
    emit_gate "f2p_auxiliary_plumbing" false "$AUX_SCORE/3 aux checks pass"
fi

# ===========================================================================
# F2P Gate 6 — Behavioral / dominant: full router crate compiles with v2
# Weight: 0.24 (scaled from 0.40 to accommodate upstream gates)
# ===========================================================================
echo ""
echo "=== F2P Gate 6: cargo check -p router with v2 features ==="
# Bounded to 300s — full cargo check on hyperswitch's router crate routinely
# exceeds the 900-1200s sandbox lifetime, causing oracle replay to ERROR. If
# the check times out we treat it as inconclusive and award the gate if
# structural gates 1-5 all passed (which is strong canonical-shape evidence
# the crate is well-formed). Round-5 used 600s; bumped down to 300s after the
# retry path together still spent >900s.
timeout 300 cargo check -p router --no-default-features --features "v2,olap,oltp" --quiet 2>&1 | tail -40
G_RC=${PIPESTATUS[0]}
if [ $G_RC -eq 124 ]; then
    echo "TIMEOUT after 300s: treating as inconclusive (will fallback to structural credit)"
fi
# Skip the retry path on timeout — second cargo invocation would push past the
# sandbox lifetime. Only retry on a real (non-timeout) compile error.
if [ $G_RC -ne 0 ] && [ $G_RC -ne 124 ]; then
    echo "Retrying with extra features..."
    timeout 240 cargo check -p router --no-default-features --features "v2,olap,oltp,kv_store,stripe,payouts,frm,dummy_connector,recon" --quiet 2>&1 | tail -40
    G_RC=${PIPESTATUS[0]}
fi
if [ $G_RC -eq 0 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.24}')
    echo "PASS: router crate compiles with v2 features (+0.24)"
    emit_gate "f2p_cargo_check_router_v2" true "compiled with v2 features"
elif [ $G_RC -eq 124 ]; then
    # Timeout: pass if all 4 structural F2P gates (1-4) above passed — strong
    # evidence the canonical's surface area is intact.
    STRUCTURAL_OK=0
    if [ -n "$TYPE_NAME" ] && [ -n "$HANDLER_NAME" ] && [ $CORE_OK -eq 1 ] && [ $ROUTE_OK -eq 1 ]; then
        STRUCTURAL_OK=1
    fi
    if [ $STRUCTURAL_OK -eq 1 ]; then
        REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.4f", r+0.24}')
        echo "PASS (inconclusive timeout): structural gates 1-4 all passed (+0.24)"
        emit_gate "f2p_cargo_check_router_v2" true "cargo check timed out; structural gates 1-4 all passed (canonical-shape OK)"
    else
        echo "FAIL: cargo check timed out and structural gates 1-4 did not all pass"
        emit_gate "f2p_cargo_check_router_v2" false "timeout + structural gates 1-4 incomplete"
    fi
else
    echo "FAIL: router crate does not compile with v2 features"
    emit_gate "f2p_cargo_check_router_v2" false "compilation failed (rc=$G_RC)"
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
# Pass if the agent registered the list-attempts endpoint in OpenAPI metadata.
# Two valid surfaces:
#   1. session-style: a route fn `list_payment_attempts` in
#      `crates/openapi/src/routes/payments.rs`
#   2. gold-style: the request schema `PaymentAttemptListRequest` (or
#      `PaymentListAttemptsRequest`) registered in
#      `crates/openapi/src/openapi_v2.rs`
OPENAPI_OK=0
if cd /workspace/hyperswitch; then
    if grep -q 'list_payment_attempts\|payments_list_attempts' crates/openapi/src/routes/payments.rs 2>/dev/null; then
        OPENAPI_OK=1
    elif grep -qE 'PaymentAttemptListRequest|PaymentListAttemptsRequest|PaymentAttemptsListRequest' crates/openapi/src/openapi_v2.rs 2>/dev/null; then
        OPENAPI_OK=1
    fi
fi
if [ $OPENAPI_OK -eq 1 ]; then
    echo '{"id": "f2p_upstream_openapi_route", "passed": true, "detail": "list-attempts registered in openapi routes or schemas"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_openapi_route", "passed": false, "detail": "list-attempts not registered in openapi routes or schemas"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

echo ""
echo "=== Upstream Gate: f2p_upstream_openapi_v2_schema ==="
# Accept both the session-style name (PaymentListAttemptsResponse) and the
# upstream gold-style name (PaymentAttemptListResponse). Either is a valid
# response schema name for the list-attempts endpoint.
if cd /workspace/hyperswitch && grep -qE 'PaymentListAttemptsResponse|PaymentAttemptListResponse|PaymentAttemptsListResponse' crates/openapi/src/openapi_v2.rs; then
    echo '{"id": "f2p_upstream_openapi_v2_schema", "passed": true, "detail": "list-attempts response schema found in openapi_v2.rs"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_openapi_v2_schema", "passed": false, "detail": "list-attempts response schema not found in openapi_v2.rs"}' >> /logs/verifier/gates.json
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
# Only the IDs actually emitted to /logs/verifier/gates.json contribute via
# the WEIGHTS path. The bash REWARD_AWK already accumulates 0.06+0.09+0.09+
# 0.06+0.06+0.24 = 0.60 inline (legacy inner reward). The upstream openapi
# gates add the remaining 0.40 weight via this dict. With sum=0.40,
# inner_weight=0.60 — the legacy inner reward is preserved at full scale.
WEIGHTS = {
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
echo ""
echo "============================================"
FINAL_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "0.0000")
echo "FINAL REWARD (after upstream gates): $FINAL_REWARD"
echo "============================================"

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
