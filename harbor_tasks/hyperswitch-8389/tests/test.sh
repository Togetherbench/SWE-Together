#!/bin/bash
set +e

# Verifier for hyperswitch-8389: KV Redis feature for V2 models
# Behavioral-leaning multi-tier scoring focused on:
#   - V2 PaymentIntentUpdateInternal::apply_changeset implementation (no todo!)
#   - V2 PaymentAttemptUpdate / PaymentAttemptUpdateInternal apply_changeset (no todo!)
#   - V2 storage_impl payment_intent KV branch implementation (insert/update/find)
#   - V2 UniqueConstraints impl for PaymentAttempt
#   - Cargo check parses (compiles syntactically) for diesel_models with v2 feature
#   - Structural plumbing: openapi_v2 KV reference, app.rs/admin.rs registration

REPO_DIR=""
for cand in /workspace/hyperswitch /workspace/hyperswitch_pool_0 ./repos/hyperswitch_pool_0 /workspace/repo; do
    if [ -d "$cand" ]; then REPO_DIR="$cand"; break; fi
done

mkdir -p /logs/verifier

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
    echo "FATAL: repo not found"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

cd "$REPO_DIR" || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
    for p in /usr/local/cargo/bin /root/.cargo/bin /opt/cargo/bin; do
        [ -x "$p/cargo" ] && export PATH="$p:$PATH"
    done
fi

BASE_COMMIT="c5c0e677f2a2d43170a66330c98e0ebc4d771717"
DIESEL_PI="crates/diesel_models/src/payment_intent.rs"
DIESEL_PA="crates/diesel_models/src/payment_attempt.rs"
SI_LIB="crates/storage_impl/src/lib.rs"
SI_PI="crates/storage_impl/src/payments/payment_intent.rs"
SI_PA="crates/storage_impl/src/payments/payment_attempt.rs"
ADMIN_RS="crates/router/src/routes/admin.rs"
APP_RS="crates/router/src/routes/app.rs"
OPENAPI_V2="crates/openapi/src/openapi_v2.rs"

SCORE=0.0

add_score() {
    local v="$1"
    SCORE=$(awk -v a="$SCORE" -v b="$v" 'BEGIN{printf "%.4f", a+b}')
    echo "  +$v -> total=$SCORE ($2)"
}

file_get_base() {
    git show "${BASE_COMMIT}:$1" 2>/dev/null
}

count_in_file() {
    # count_in_file <file> <pattern>
    local f="$1" p="$2"
    local n
    n=$(grep -c -E "$p" "$f" 2>/dev/null)
    [ -z "$n" ] && n=0
    echo "$n"
}

# Extract a function/impl block by signature pattern; prints first matching block
extract_block_after_match() {
    local file="$1" pattern="$2" max_lines="${3:-200}"
    awk -v pat="$pattern" -v maxl="$max_lines" '
        BEGIN{found=0; depth=0; printed=0}
        {
            if (!found && match($0, pat)) {
                found=1
                # find first {
            }
            if (found) {
                line=$0
                # count braces
                n1=gsub(/\{/,"{",line)
                n2=gsub(/\}/,"}",line)
                # restore $0 (gsub modifies copy)
                print $0
                started=started+n1
                depth+=n1
                depth-=n2
                printed++
                if (started>0 && depth<=0) exit
                if (printed>=maxl) exit
            }
        }
    ' "$file" 2>/dev/null
}

echo "=== TIER A: V2 apply_changeset implementations (max 0.25) ==="

# A1: PaymentIntentUpdateInternal::apply_changeset for v2 — must NOT be todo!() (0.13)
A1_OK=0
if [ -f "$DIESEL_PI" ]; then
    # Find any v2-gated impl of apply_changeset taking PaymentIntent source
    # Check that it constructs PaymentIntent { ... } with multiple field assignments and ..source
    BLOCK=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; buf=""; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 {
            if ($0 ~ /impl[[:space:]]+PaymentIntentUpdate(Internal)?[[:space:]]*\{/) {
                inblock=1; depth=0
            } else {
                gate=0
            }
        }
        inblock {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<=0 && /\}/) {inblock=0; gate=0; print "---END---"}
        }
    ' "$DIESEL_PI")
    if echo "$BLOCK" | grep -q 'apply_changeset'; then
        # Extract just the apply_changeset function body
        FN_BODY=$(echo "$BLOCK" | awk '
            /fn apply_changeset/ {found=1; depth=0}
            found {
                print
                n1=gsub(/\{/,"{")
                n2=gsub(/\}/,"}")
                depth += n1 - n2
                if (depth<=0 && /\}/) exit
            }
        ')
        if [ -n "$FN_BODY" ]; then
            HAS_TODO=$(echo "$FN_BODY" | grep -cE 'todo!\(\)|todo!\("')
            HAS_PI_CTOR=$(echo "$FN_BODY" | grep -cE 'PaymentIntent[[:space:]]*\{')
            HAS_SOURCE=$(echo "$FN_BODY" | grep -cE '\.\.source')
            FIELD_COUNT=$(echo "$FN_BODY" | grep -cE '(unwrap_or|\.or)\(source\.')
            if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PI_CTOR" -ge 1 ] && [ "$HAS_SOURCE" -ge 1 ] && [ "$FIELD_COUNT" -ge 10 ]; then
                A1_OK=1
            elif [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PI_CTOR" -ge 1 ] && [ "$FIELD_COUNT" -ge 5 ]; then
                A1_OK=2
            fi
        fi
    fi
fi
if [ "$A1_OK" = "1" ]; then
    add_score 0.13 "A1: V2 PaymentIntentUpdate(Internal)::apply_changeset fully implemented"
elif [ "$A1_OK" = "2" ]; then
    add_score 0.07 "A1-partial: V2 apply_changeset partially implemented"
else
    echo "  A1 FAIL: V2 PaymentIntentUpdate(Internal)::apply_changeset missing/todo"
fi

# A2: PaymentAttempt apply_changeset for v2 — must NOT be todo!() (0.12)
A2_OK=0
if [ -f "$DIESEL_PA" ]; then
    # Look for v2 apply_changeset on PaymentAttemptUpdate or PaymentAttemptUpdateInternal
    PA_FN=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 && /impl[[:space:]]+PaymentAttemptUpdate(Internal)?[[:space:]]*\{/ {inimpl=1; depth=0}
        gate==1 && !/impl[[:space:]]+PaymentAttemptUpdate/ {gate=0}
        inimpl {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<=0 && /\}/) {inimpl=0; gate=0}
        }
    ' "$DIESEL_PA")
    if echo "$PA_FN" | grep -q 'fn apply_changeset'; then
        # Get the apply_changeset body for v2
        BODY=$(echo "$PA_FN" | awk '
            /fn apply_changeset/ {found=1; depth=0}
            found {
                print
                n1=gsub(/\{/,"{")
                n2=gsub(/\}/,"}")
                depth += n1 - n2
                if (depth<=0 && /\}/) exit
            }
        ')
        # Filter out commented lines for evaluation
        UNCOMMENTED=$(echo "$BODY" | grep -vE '^\s*//')
        HAS_TODO=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(\)|todo!\("')
        HAS_PA_CTOR=$(echo "$UNCOMMENTED" | grep -cE 'PaymentAttempt[[:space:]]*\{')
        HAS_SOURCE=$(echo "$UNCOMMENTED" | grep -cE '\.\.source')
        FIELD_COUNT=$(echo "$UNCOMMENTED" | grep -cE '(unwrap_or|\.or)\((source|self)\.')
        if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PA_CTOR" -ge 1 ] && [ "$HAS_SOURCE" -ge 1 ] && [ "$FIELD_COUNT" -ge 10 ]; then
            A2_OK=1
        elif [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PA_CTOR" -ge 1 ] && [ "$FIELD_COUNT" -ge 5 ]; then
            A2_OK=2
        fi
    fi
fi
if [ "$A2_OK" = "1" ]; then
    add_score 0.12 "A2: V2 PaymentAttemptUpdate(Internal)::apply_changeset fully implemented"
elif [ "$A2_OK" = "2" ]; then
    add_score 0.06 "A2-partial: V2 PaymentAttempt apply_changeset partially implemented"
else
    echo "  A2 FAIL: V2 PaymentAttempt apply_changeset missing/todo"
fi

echo ""
echo "=== TIER B: V2 storage_impl KV branch behavior (max 0.30) ==="

# B1: Imports for kv/HsetnxReply/kv_store unblocked for v2 (0.06)
B1_OK=0
if [ -f "$SI_PI" ]; then
    BASE_V1_GATES=$(file_get_base "$SI_PI" | grep -c '#\[cfg(feature = "v1")\]')
    CURR_V1_GATES=$(grep -c '#\[cfg(feature = "v1")\]' "$SI_PI")
    [ -z "$BASE_V1_GATES" ] && BASE_V1_GATES=0
    [ -z "$CURR_V1_GATES" ] && CURR_V1_GATES=0
    # Check that key KV imports are no longer v1-only
    HAS_KV_IMPORT=$(grep -cE 'use diesel_models::kv\b|use diesel_models::\{kv' "$SI_PI")
    HAS_HSETNX=$(grep -cE 'use redis_interface::HsetnxReply' "$SI_PI")
    HAS_KV_STORE=$(grep -cE 'kv_store::\{[^}]*kv_wrapper|kv_wrapper,[^}]*KvOperation' "$SI_PI")
    # Verify v1 gate count dropped
    if [ "$CURR_V1_GATES" -lt "$BASE_V1_GATES" ] && [ "$HAS_KV_IMPORT" -ge 1 ] && [ "$HAS_HSETNX" -ge 1 ]; then
        B1_OK=1
    elif [ "$CURR_V1_GATES" -lt "$BASE_V1_GATES" ]; then
        B1_OK=2
    fi
fi
if [ "$B1_OK" = "1" ]; then
    add_score 0.06 "B1: storage_impl payment_intent.rs v1-only gates lifted on KV imports"
elif [ "$B1_OK" = "2" ]; then
    add_score 0.03 "B1-partial: some v1 gates lifted"
else
    echo "  B1 FAIL: KV imports still v1-gated"
fi

# Helper: extract v2 function body from storage_impl payment_intent
extract_v2_fn() {
    local file="$1" fname="$2"
    awk -v fn="$fname" '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*#\[/ {next}
        gate==1 && match($0, "async fn " fn "\\b") {capture=1; depth=0; gate=0}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 && !/async fn/ {gate=0}
        capture {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth>0) started=1
            if (started && depth<=0) {capture=0; exit}
        }
    ' "$file" 2>/dev/null
}

# B2: V2 insert_payment_intent has KV branch (no todo!, has kv_wrapper or HsetnxReply usage) (0.08)
B2_OK=0
if [ -f "$SI_PI" ]; then
    BLK=$(extract_v2_fn "$SI_PI" "insert_payment_intent")
    if [ -n "$BLK" ]; then
        HAS_TODO=$(echo "$BLK" | grep -cE 'todo!\(\)|todo!\("Implement payment intent insert')
        HAS_KV=$(echo "$BLK" | grep -cE 'kv_wrapper|HsetnxReply|KvOperation::Hset|RedisKv[[:space:]]*=>')
        HAS_REDIS_BRANCH=$(echo "$BLK" | grep -cE 'MerchantStorageScheme::RedisKv')
        if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_KV" -ge 2 ] && [ "$HAS_REDIS_BRANCH" -ge 1 ]; then
            B2_OK=1
        elif [ "$HAS_TODO" -eq 0 ] && [ "$HAS_KV" -ge 1 ]; then
            B2_OK=2
        fi
    fi
fi
if [ "$B2_OK" = "1" ]; then
    add_score 0.08 "B2: V2 insert_payment_intent KV branch implemented"
elif [ "$B2_OK" = "2" ]; then
    add_score 0.04 "B2-partial: KV partially in insert_payment_intent"
else
    echo "  B2 FAIL: V2 insert_payment_intent still todo or no KV"
fi

# B3: V2 update_payment_intent has KV branch (0.08)
B3_OK=0
if [ -f "$SI_PI" ]; then
    BLK=$(extract_v2_fn "$SI_PI" "update_payment_intent")
    if [ -n "$BLK" ]; then
        HAS_TODO=$(echo "$BLK" | grep -cE 'todo!\(\)|todo!\("')
        HAS_KV=$(echo "$BLK" | grep -cE 'kv_wrapper|KvOperation::Hset|Op::Update|PartitionKey')
        HAS_REDIS_BRANCH=$(echo "$BLK" | grep -cE 'MerchantStorageScheme::RedisKv')
        if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_KV" -ge 2 ] && [ "$HAS_REDIS_BRANCH" -ge 1 ]; then
            B3_OK=1
        elif [ "$HAS_TODO" -eq 0 ] && [ "$HAS_KV" -ge 1 ]; then
            B3_OK=2
        fi
    fi
fi
if [ "$B3_OK" = "1" ]; then
    add_score 0.08 "B3: V2 update_payment_intent KV branch implemented"
elif [ "$B3_OK" = "2" ]; then
    add_score 0.04 "B3-partial: KV partially in update_payment_intent"
else
    echo "  B3 FAIL: V2 update_payment_intent still todo or no KV"
fi

# B4: V2 find_payment_intent_by_id uses KV/decide_storage_scheme path (0.04)
B4_OK=0
if [ -f "$SI_PI" ]; then
    BLK=$(extract_v2_fn "$SI_PI" "find_payment_intent_by_id")
    if [ -n "$BLK" ]; then
        HAS_KV=$(echo "$BLK" | grep -cE 'try_redis_get_else_try_database_get|kv_wrapper|decide_storage_scheme|KvOperation')
        if [ "$HAS_KV" -ge 1 ]; then
            B4_OK=1
        fi
    fi
fi
if [ "$B4_OK" = "1" ]; then
    add_score 0.04 "B4: V2 find_payment_intent_by_id uses KV path"
else
    echo "  B4 FAIL: V2 find_payment_intent_by_id no KV path"
fi

# B5: storage_impl/lib.rs has v2 UniqueConstraints for PaymentAttempt (0.04)
B5_OK=0
if [ -f "$SI_LIB" ]; then
    # Look for v2 impl UniqueConstraints for PaymentAttempt
    HAS_V2_UNIQUE=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /impl[[:space:]]+UniqueConstraints[[:space:]]+for[[:space:]]+diesel_models::PaymentAttempt/ {found=1; gate=0}
        gate==1 && !/^[[:space:]]*$/ {gate=0}
        END {print found+0}
    ' "$SI_LIB")
    [ "$HAS_V2_UNIQUE" = "1" ] && B5_OK=1
fi
if [ "$B5_OK" = "1" ]; then
    add_score 0.04 "B5: V2 UniqueConstraints for PaymentAttempt added"
else
    echo "  B5 FAIL: no V2 UniqueConstraints for PaymentAttempt"
fi

echo ""
echo "=== TIER C: Compile sanity for diesel_models (max 0.20) ==="

# C1: cargo check on diesel_models crate with v2 feature (0.20) — behavioral
C1_OK=0
if command -v cargo >/dev/null 2>&1; then
    # Run cargo check restricted to diesel_models with v2 feature, with timeout
    LOG=/tmp/cargo_check_diesel_v2.log
    timeout 480 cargo check -p diesel_models --no-default-features --features "v2" --message-format=short > "$LOG" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        C1_OK=1
    else
        # Check that errors are not in our target file (apply_changeset region)
        # Partial credit if compile fails but apply_changeset is well-formed
        ERR_COUNT=$(grep -cE '^error(\[|:)' "$LOG")
        APPLY_ERR=$(grep -cE 'apply_changeset' "$LOG")
        if [ "$ERR_COUNT" = "0" ]; then
            C1_OK=1
        elif [ "$APPLY_ERR" = "0" ] && [ "$ERR_COUNT" -lt 5 ]; then
            C1_OK=2
        fi
    fi
    tail -50 "$LOG" > /logs/verifier/cargo_check_tail.log 2>/dev/null
else
    echo "  cargo not on PATH, skipping compile check"
fi
if [ "$C1_OK" = "1" ]; then
    add_score 0.20 "C1: cargo check diesel_models --features v2 OK"
elif [ "$C1_OK" = "2" ]; then
    add_score 0.08 "C1-partial: compile errors but not in apply_changeset"
else
    echo "  C1 FAIL: cargo check failed or skipped"
fi

echo ""
echo "=== TIER D: V2 routing/openapi plumbing (max 0.15) ==="

# D1: openapi_v2.rs references KV merchant_account operation (0.05)
D1_OK=0
if [ -f "$OPENAPI_V2" ]; then
    if grep -qE 'merchant_account_(toggle_kv|kv_status)(_v2)?' "$OPENAPI_V2"; then
        D1_OK=1
    fi
fi
[ "$D1_OK" = "1" ] && add_score 0.05 "D1: openapi_v2 references merchant_account KV op" || echo "  D1 FAIL: no openapi_v2 KV reference"

# D2: app.rs registers /kv route in v2 MerchantAccount block (0.05)
D2_OK=0
if [ -f "$APP_RS" ]; then
    # Look for v2 cfg gate near MerchantAccount with /kv path
    if awk '
        /cfg\(.*feature[[:space:]]*=[[:space:]]*"v2"/ {gate=1; depth=0; next}
        gate {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<0) {gate=0; depth=0}
        }
    ' "$APP_RS" | grep -qE '/kv|toggle_kv|kv_status'; then
        D2_OK=1
    fi
    # Alternative: any /kv route within feature v2 olap merchant context
    if [ "$D2_OK" = "0" ]; then
        if grep -B 3 -A 80 'MerchantAccount' "$APP_RS" | grep -qE '"/kv"|"kv"'; then
            # check it's also near v2
            if grep -B 30 -A 5 '"/kv"' "$APP_RS" 2>/dev/null | grep -qE 'feature[[:space:]]*=[[:space:]]*"v2"'; then
                D2_OK=1
            fi
        fi
    fi
fi
[ "$D2_OK" = "1" ] && add_score 0.05 "D2: V2 /kv route registered" || echo "  D2 FAIL: no V2 /kv route"

# D3: admin.rs has v2-gated merchant_account_toggle_kv handler (0.05)
D3_OK=0
if [ -f "$ADMIN_RS" ]; then
    # find v2-gated toggle_kv
    LINES=$(grep -n 'pub async fn merchant_account_toggle_kv' "$ADMIN_RS" | cut -d: -f1)
    for L in $LINES; do
        S=$((L - 8))
        [ "$S" -lt 1 ] && S=1
        CTX=$(sed -n "${S},${L}p" "$ADMIN_RS")
        if echo "$CTX" | grep -qE 'cfg.*feature[[:space:]]*=[[:space:]]*"v2"'; then
            D3_OK=1
            break
        fi
    done
fi
[ "$D3_OK" = "1" ] && add_score 0.05 "D3: V2-gated toggle_kv handler in admin.rs" || echo "  D3 FAIL: no V2-gated toggle_kv"

echo ""
echo "=== TIER E: Regression guards (max 0.10) ==="

# E1: V1 KV path still intact - V1 apply_changeset still exists in payment_intent.rs (0.05)
E1_OK=0
if [ -f "$DIESEL_PI" ]; then
    # V1 PaymentIntentUpdate::apply_changeset must still be present
    HAS_V1_APPLY=$(awk '
        /#\[cfg\(feature = "v1"\)\]/ {gate=1; next}
        gate==1 && /impl[[:space:]]+PaymentIntentUpdate[[:space:]]*\{/ {inimpl=1; depth=0; gate=0}
        gate==1 && !/^[[:space:]]*$/ {gate=0}
        inimpl {
            if (/fn apply_changeset/) {found=1}
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<=0 && /\}/) inimpl=0
        }
        END {print found+0}
    ' "$DIESEL_PI")
    [ "$HAS_V1_APPLY" = "1" ] && E1_OK=1
fi
[ "$E1_OK" = "1" ] && add_score 0.05 "E1: V1 apply_changeset preserved" || echo "  E1 FAIL: V1 apply_changeset broken"

# E2: A commit was created with the task tag (0.05)
E2_OK=0
if git log --oneline -20 2>/dev/null | grep -qE 'hyperswitch-8389|task juspay__hyperswitch-8389|8389'; then
    E2_OK=1
elif git log --oneline -1 2>/dev/null | grep -qiE 'kv|v2'; then
    E2_OK=2
fi
if [ "$E2_OK" = "1" ]; then
    add_score 0.05 "E2: commit tagged with task id"
elif [ "$E2_OK" = "2" ]; then
    add_score 0.02 "E2-partial: recent commit but not tagged"
else
    echo "  E2 FAIL: no commit"
fi

echo ""
echo "==================================="
REWARD=$(awk -v s="$SCORE" 'BEGIN{if (s>1.0) s=1.0; if (s<0) s=0; printf "%.4f", s}')
echo "FINAL REWARD: $REWARD"
echo "==================================="
echo "$REWARD" > /logs/verifier/reward.txt
exit 0