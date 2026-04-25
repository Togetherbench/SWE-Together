#!/bin/bash
set +e

export PATH="/usr/local/cargo/bin:$PATH"
mkdir -p /logs/verifier
REWARD=0.0

cd /workspace/hyperswitch 2>/dev/null || { echo "$REWARD" > /logs/verifier/reward.txt; exit 0; }

echo "============================================"
echo "Hyperswitch PR #8377 Verifier"
echo "v2 endpoint: list payment attempts by intent_id"
echo "============================================"

API_FILE="crates/api_models/src/payments.rs"
HANDLER_FILE="crates/router/src/routes/payments.rs"
CORE_FILE="crates/router/src/core/payments.rs"
APP_FILE="crates/router/src/routes/app.rs"

for f in "$API_FILE" "$HANDLER_FILE" "$CORE_FILE" "$APP_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Missing required file: $f"
        echo "$REWARD" > /logs/verifier/reward.txt
        exit 0
    fi
done

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

# ─── Structural detections (used as F2P signals, since they're absent on base) ───

# F2P signal 1: New response type with payment_attempts: Vec<...> in api_models
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
          if(current ~ /[Aa]ttempt/ && current ~ /[Ll]ist|[Rr]esponse/){
            print current; exit
          }
      }
  }
' "$API_FILE")
echo "Detected response type: '${TYPE_NAME:-<none>}'"

# F2P signal 2: New handler function in routes/payments.rs (v2 olap)
HANDLER_NAME=$(grep -oE "pub async fn [a-zA-Z0-9_]*(list_payment_attempts|payments_list_attempts)[a-zA-Z0-9_]*" "$HANDLER_FILE" | head -1 | awk '{print $4}')
echo "Detected handler: '${HANDLER_NAME:-<none>}'"

# F2P signal 3: New core function in core/payments.rs
CORE_FN=$(grep -oE "pub async fn [a-zA-Z0-9_]*list_payment_attempts[a-zA-Z0-9_]*|pub async fn [a-zA-Z0-9_]*payments_list_attempts[a-zA-Z0-9_]*" "$CORE_FILE" | head -1 | awk '{print $4}')
echo "Detected core fn: '${CORE_FN:-<none>}'"

# F2P signal 4: Route registered under /payments/{id}/(list_attempts|attempts)
ROUTE_FOUND=0
if grep -qE 'web::resource\("/(list_attempts|attempts)"\)' "$APP_FILE"; then
    if grep -qE 'list_payment_attempts|payments_list_attempts' "$APP_FILE"; then
        ROUTE_FOUND=1
    fi
fi
echo "Route registered: $ROUTE_FOUND"

# Sanity: all four must be present, otherwise skip behavioral compile
if [ -z "$TYPE_NAME" ] || [ -z "$HANDLER_NAME" ] || [ -z "$CORE_FN" ] || [ "$ROUTE_FOUND" -ne 1 ]; then
    # Award nothing — these signals are all absent on base, so any present is a partial fix.
    # But per Rule 1: only behavioral signals get weight. Give very small partials only if some structural changes are made.
    PARTIAL_AWK=$(awk -v t="$TYPE_NAME" -v h="$HANDLER_NAME" -v c="$CORE_FN" -v r="$ROUTE_FOUND" 'BEGIN{
        s=0;
        if(t!="") s+=0.05;
        if(h!="") s+=0.05;
        if(c!="") s+=0.05;
        if(r=="1") s+=0.05;
        printf "%.2f", s;
    }')
    echo "Incomplete implementation, partial structural reward: $PARTIAL_AWK"
    REWARD=$PARTIAL_AWK
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ─── F2P Gate A (structural, but absent on base): all 4 signals present ─── weight: 0.20
REWARD_AWK=$(awk 'BEGIN{print 0.20}')

# ─── F2P Gate B: handler body invokes the core list-attempts fn ─── weight: 0.15
echo ""
echo "=== F2P Gate B: Handler wired to core list-attempts function ==="
WIRED=0
awk -v fn="$HANDLER_NAME" '
  $0 ~ "pub async fn "fn"\\(" {found=1; brace=0}
  found {
      print;
      for(i=1;i<=length($0);i++){
        c=substr($0,i,1);
        if(c=="{") {brace++; started=1}
        else if(c=="}") { brace--; if(started && brace==0){exit} }
      }
  }
' "$HANDLER_FILE" > /tmp/handler_body.txt
if grep -qE "list_payment_attempts|payments_list_attempts" /tmp/handler_body.txt; then
    WIRED=1
fi
rm -f /tmp/handler_body.txt
if [ $WIRED -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.2f", r+0.15}')
    echo "PASS: handler invokes list-attempts core fn (+0.15)"
else
    echo "FAIL: handler does not invoke list-attempts core fn"
fi

# ─── F2P Gate C: core fn returns Vec-bearing list response type ─── weight: 0.10
echo ""
echo "=== F2P Gate C: Core fn returns new response type ==="
CORE_OK=0
awk -v fn="$CORE_FN" '
  $0 ~ "pub async fn "fn"\\(" {found=1; brace=0}
  found {
      print;
      for(i=1;i<=length($0);i++){
        c=substr($0,i,1);
        if(c=="{") {brace++; started=1}
        else if(c=="}") { brace--; if(started && brace==0){exit} }
      }
  }
' "$CORE_FILE" > /tmp/core_body.txt
if grep -q "$TYPE_NAME" /tmp/core_body.txt && grep -qE "find_payment_attempts_by_payment_intent_id|payment_attempts_by_payment_intent|find_attempts_by_payment_intent" /tmp/core_body.txt; then
    CORE_OK=1
fi
rm -f /tmp/core_body.txt
if [ $CORE_OK -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.2f", r+0.10}')
    echo "PASS: core fn returns $TYPE_NAME from store query (+0.10)"
else
    echo "FAIL: core fn does not query attempts and return $TYPE_NAME"
fi

# ─── F2P Gate D: route registered correctly under /payments scope (v2) ─── weight: 0.10
echo ""
echo "=== F2P Gate D: Route registered with GET method ==="
ROUTE_OK=0
if grep -qE 'web::resource\("/(list_attempts|attempts)"\)[[:space:]]*\.route\(web::get\(\)\.to\(payments::(list_payment_attempts|payments_list_attempts)\)\)' "$APP_FILE"; then
    ROUTE_OK=1
fi
if [ $ROUTE_OK -eq 1 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.2f", r+0.10}')
    echo "PASS: GET route registered (+0.10)"
else
    echo "FAIL: route not registered with GET method"
fi

# ─── F2P Gate E (behavioral, dominant): full router compiles with v2 features ─── weight: 0.45
echo ""
echo "=== F2P Gate E: cargo check -p router with v2 features ==="
cargo check -p router --no-default-features --features "v2,olap,oltp,kv_store,stripe,payouts,frm,dummy_connector,recon" --quiet 2>&1 | tail -30
G_RC=${PIPESTATUS[0]}
if [ $G_RC -ne 0 ]; then
    echo "Retrying with smaller feature set..."
    cargo check -p router --no-default-features --features "v2,olap,oltp" --quiet 2>&1 | tail -30
    G_RC=${PIPESTATUS[0]}
fi
if [ $G_RC -eq 0 ]; then
    REWARD_AWK=$(awk -v r="$REWARD_AWK" 'BEGIN{printf "%.2f", r+0.45}')
    echo "PASS: router compiles with new code wired up (+0.45)"
else
    echo "FAIL: compilation failed"
fi

REWARD=$REWARD_AWK
echo ""
echo "============================================"
echo "FINAL REWARD: $REWARD"
echo "============================================"
echo "$REWARD" > /logs/verifier/reward.txt