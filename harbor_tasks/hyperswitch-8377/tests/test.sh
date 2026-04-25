#!/bin/bash
set +e

export PATH="/usr/local/cargo/bin:$PATH"

cd /workspace/hyperswitch || { mkdir -p /logs/verifier; echo "0.00" > /logs/verifier/reward.txt; exit 0; }
mkdir -p /logs/verifier

SCORE=0

echo "============================================"
echo "Hyperswitch PR #8377 Verifier"
echo "v2 endpoint: list payment attempts by intent_id"
echo "============================================"

# ─── Gate 1 (P2P): router_env compiles (regression guard) ─── weight: 0.05
echo ""
echo "=== Gate 1 (P2P): router_env crate compiles ==="
cargo check -p router_env --quiet 2>&1 | tail -5
G1_RC=${PIPESTATUS[0]}
if [ $G1_RC -eq 0 ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05"
else
    echo "FAIL"
fi

# ─── Gate 2 (P2P): api_models compiles under v2 (regression guard) ─── weight: 0.05
echo ""
echo "=== Gate 2 (P2P): api_models compiles with v2 ==="
cargo check -p api_models --no-default-features --features v2,errors,frm,payouts,recon --quiet 2>&1 | tail -5
G2_RC=${PIPESTATUS[0]}
if [ $G2_RC -ne 0 ]; then
    # Try a minimal feature set
    cargo check -p api_models --no-default-features --features v2 --quiet 2>&1 | tail -5
    G2_RC=${PIPESTATUS[0]}
fi
if [ $G2_RC -eq 0 ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05"
else
    echo "FAIL"
fi

# ─── Structural detections (used as inputs to behavioral gates) ───

# Detect new response type with payment_attempts: Vec<...> field in api_models
TYPE_NAME=""
TYPE_FILE="crates/api_models/src/payments.rs"
if [ -f "$TYPE_FILE" ]; then
    # Find struct that has a field "payment_attempts: Vec<" or "attempts: Vec<"
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
            if(c=="}") { brace--; if(brace<=0){inside=0; break} }
          }
          if(/payment_attempts[[:space:]]*:[[:space:]]*Vec[[:space:]]*</ || /attempts[[:space:]]*:[[:space:]]*Vec[[:space:]]*<[[:space:]]*PaymentAttempt/){
              if(current ~ /[Aa]ttempt/ && current ~ /[Ll]ist|[Rr]esponse/){
                print current; exit
              }
          }
      }
    ' "$TYPE_FILE")
fi
echo "Detected response type: '${TYPE_NAME:-<none>}'"

# Detect new handler function name in routes/payments.rs
HANDLER_NAME=""
HANDLER_FILE="crates/router/src/routes/payments.rs"
if [ -f "$HANDLER_FILE" ]; then
    HANDLER_NAME=$(grep -oE "pub async fn [a-zA-Z0-9_]*(list_payment_attempts|payments_list_attempts|list_attempts)[a-zA-Z0-9_]*" "$HANDLER_FILE" | head -1 | awk '{print $4}')
fi
echo "Detected handler: '${HANDLER_NAME:-<none>}'"

# Detect new core function in core/payments.rs
CORE_FN=""
CORE_FILE="crates/router/src/core/payments.rs"
if [ -f "$CORE_FILE" ]; then
    CORE_FN=$(grep -oE "pub async fn [a-zA-Z0-9_]*list_payment_attempts[a-zA-Z0-9_]*|pub async fn [a-zA-Z0-9_]*list_attempts[a-zA-Z0-9_]*|pub async fn [a-zA-Z0-9_]*payments_list_attempts[a-zA-Z0-9_]*" "$CORE_FILE" | head -1 | awk '{print $4}')
fi
echo "Detected core fn: '${CORE_FN:-<none>}'"

# Detect route registration in app.rs (list_attempts or attempts under /payments/{id}/)
ROUTE_FOUND=0
APP_FILE="crates/router/src/routes/app.rs"
if [ -f "$APP_FILE" ]; then
    if grep -qE 'web::resource\("/(list_attempts|attempts)"\)[^;]*payments::(list_payment_attempts|payments_list_attempts|list_attempts)' "$APP_FILE"; then
        ROUTE_FOUND=1
    elif grep -q 'list_attempts\|payments_list_attempts\|list_payment_attempts' "$APP_FILE"; then
        # Lower-quality match — registered handler at least references list_attempts
        ROUTE_FOUND=1
    fi
fi
echo "Route registered: $ROUTE_FOUND"

# ─── Gate 3 (F2P structural): Response type with payment_attempts Vec ─── weight: 0.05
echo ""
echo "=== Gate 3 (F2P): Response type carrying Vec<PaymentAttempt...> ==="
if [ -n "$TYPE_NAME" ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05 ($TYPE_NAME)"
else
    echo "FAIL"
fi

# ─── Gate 4 (F2P structural): Handler + core fn present ─── weight: 0.05
echo ""
echo "=== Gate 4 (F2P): Handler + core function ==="
if [ -n "$HANDLER_NAME" ] && [ -n "$CORE_FN" ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05 (handler=$HANDLER_NAME, core=$CORE_FN)"
elif [ -n "$HANDLER_NAME" ] || [ -n "$CORE_FN" ]; then
    SCORE=$((SCORE + 2))
    echo "PARTIAL: +0.02 (handler=$HANDLER_NAME, core=$CORE_FN)"
else
    echo "FAIL"
fi

# ─── Gate 5 (F2P structural): Route registered correctly under /payments/{id}/ ─── weight: 0.05
echo ""
echo "=== Gate 5 (F2P): Route registered ==="
if [ $ROUTE_FOUND -eq 1 ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05"
else
    echo "FAIL"
fi

# ─── Gate 6 (F2P behavioral): Full router crate compiles with v2 ─── weight: 0.40
# This is the dominant behavioral gate - new code must integrate and compile.
echo ""
echo "=== Gate 6 (F2P): cargo check -p router --features v2 ==="
COMPILE_LOG=$(mktemp)
cargo check -p router --no-default-features --features "v2,olap,oltp,kv_store,stripe,payouts,frm,dummy_connector,recon" --quiet 2>&1 | tee "$COMPILE_LOG" | tail -30
G6_RC=${PIPESTATUS[0]}
if [ $G6_RC -ne 0 ]; then
    # Try a smaller feature set
    cargo check -p router --no-default-features --features "v2,olap,oltp" --quiet 2>&1 | tee "$COMPILE_LOG" | tail -30
    G6_RC=${PIPESTATUS[0]}
fi

NEW_CODE_PRESENT=0
[ -n "$TYPE_NAME" ] && [ -n "$HANDLER_NAME" ] && [ -n "$CORE_FN" ] && [ $ROUTE_FOUND -eq 1 ] && NEW_CODE_PRESENT=1

if [ $G6_RC -eq 0 ] && [ $NEW_CODE_PRESENT -eq 1 ]; then
    SCORE=$((SCORE + 40))
    echo "PASS: +0.40 (compiles with full new code wired up)"
elif [ $G6_RC -eq 0 ]; then
    # Compiles but new code is incomplete - partial credit
    PARTIAL=0
    [ -n "$TYPE_NAME" ] && PARTIAL=$((PARTIAL + 5))
    [ -n "$HANDLER_NAME" ] && PARTIAL=$((PARTIAL + 5))
    [ -n "$CORE_FN" ] && PARTIAL=$((PARTIAL + 5))
    [ $ROUTE_FOUND -eq 1 ] && PARTIAL=$((PARTIAL + 5))
    SCORE=$((SCORE + PARTIAL))
    echo "PARTIAL: +0.$(printf "%02d" $PARTIAL) (compiles, partial new code)"
else
    echo "FAIL: compilation failed"
fi
rm -f "$COMPILE_LOG"

# ─── Gate 7 (F2P behavioral): Handler is wired correctly to core fn ─── weight: 0.15
# Verify the handler actually calls a payment-attempt-listing core function
# (not just exists as a stub). This catches "looks-right but does-nothing" fixes.
echo ""
echo "=== Gate 7 (F2P): Handler wired to core function ==="
WIRED=0
if [ -n "$HANDLER_NAME" ] && [ -f "$HANDLER_FILE" ]; then
    # Extract the body of the handler and check it references list-attempts core fn
    awk -v fn="$HANDLER_NAME" '
      $0 ~ "pub async fn "fn"\\(" {found=1; brace=0}
      found {
          print;
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1);
            if(c=="{") brace++;
            else if(c=="}") { brace--; if(brace==0 && /\}/){exit} }
          }
      }
    ' "$HANDLER_FILE" > /tmp/handler_body.txt
    if grep -qE "list_payment_attempts|payments_list_attempts|list_attempts" /tmp/handler_body.txt; then
        WIRED=1
    fi
    rm -f /tmp/handler_body.txt
fi
if [ $WIRED -eq 1 ]; then
    SCORE=$((SCORE + 15))
    echo "PASS: +0.15"
else
    echo "FAIL: handler does not invoke list-attempts core function"
fi

# ─── Gate 8 (F2P behavioral): Core fn returns the new response type w/ Vec ─── weight: 0.10
echo ""
echo "=== Gate 8 (F2P): Core fn returns Vec-bearing list response ==="
CORE_OK=0
if [ -n "$CORE_FN" ] && [ -f "$CORE_FILE" ] && [ -n "$TYPE_NAME" ]; then
    awk -v fn="$CORE_FN" '
      $0 ~ "pub async fn "fn"\\(" {found=1; brace=0}
      found {
          print;
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1);
            if(c=="{") brace++;
            else if(c=="}") { brace--; if(brace==0 && /\}/){exit} }
          }
      }
    ' "$CORE_FILE" > /tmp/core_body.txt
    if grep -q "$TYPE_NAME" /tmp/core_body.txt && \
       grep -qE "find_payment_attempts_by_payment_intent_id|find_attempts_by|list_attempts_by|payment_attempts" /tmp/core_body.txt; then
        CORE_OK=1
    fi
    rm -f /tmp/core_body.txt
fi
if [ $CORE_OK -eq 1 ]; then
    SCORE=$((SCORE + 10))
    echo "PASS: +0.10"
else
    echo "FAIL: core fn does not return $TYPE_NAME with attempts query"
fi

# ─── Gate 9 (F2P behavioral): Flow variant + lock_utils mapping ─── weight: 0.05
# A clean implementation adds a Flow:: variant for the new endpoint and maps it
# in lock_utils to Self::Payments. Catches lazy implementations that reuse a
# generic flow without instrumentation.
echo ""
echo "=== Gate 9 (F2P): New Flow variant + lock_utils mapping ==="
FLOW_OK=0
FLOW_VARIANT=$(grep -oE "Payments(List)?Attempts?List|PaymentsListAttempts|PaymentsAttemptList" crates/router_env/src/logger/types.rs 2>/dev/null | head -1)
if [ -n "$FLOW_VARIANT" ]; then
    if grep -q "$FLOW_VARIANT" crates/router/src/routes/lock_utils.rs 2>/dev/null; then
        FLOW_OK=1
    fi
fi
if [ $FLOW_OK -eq 1 ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05 ($FLOW_VARIANT)"
else
    echo "FAIL"
fi

# ─── Gate 10 (F2P behavioral): OpenAPI integration ─── weight: 0.05
echo ""
echo "=== Gate 10 (F2P): OpenAPI registration ==="
OAPI_OK=0
if grep -q "list_payment_attempts\|payments_list_attempts" crates/openapi/src/openapi_v2.rs 2>/dev/null; then
    if [ -n "$TYPE_NAME" ] && grep -q "$TYPE_NAME" crates/openapi/src/openapi_v2.rs 2>/dev/null; then
        OAPI_OK=1
    fi
fi
if [ $OAPI_OK -eq 1 ]; then
    SCORE=$((SCORE + 5))
    echo "PASS: +0.05"
else
    echo "FAIL"
fi

# ─── Final reward ───
REWARD=$(awk -v s="$SCORE" 'BEGIN{printf "%.2f", s/100}')
echo "$REWARD" > /logs/verifier/reward.txt

echo ""
echo "============================================"
echo "Subscore breakdown: $SCORE/100"
echo "TOTAL REWARD: $REWARD"
echo "============================================"