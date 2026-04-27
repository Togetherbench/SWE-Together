#!/bin/bash
set +e
# [v041-fix] rustup default stable
if command -v rustup >/dev/null 2>&1; then
    rustup default stable >/dev/null 2>&1 || true
fi
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"


mkdir -p /logs/verifier
REWARD=0.0

REPO_DIR=""
for cand in /workspace/hyperswitch /workspace/hyperswitch_pool_0 ./repos/hyperswitch_pool_0 /workspace/repo; do
    if [ -d "$cand" ]; then REPO_DIR="$cand"; break; fi
done

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
    echo "FATAL: repo not found"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

cd "$REPO_DIR" || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

DIESEL_PI="crates/diesel_models/src/payment_intent.rs"
DIESEL_PA="crates/diesel_models/src/payment_attempt.rs"
SI_LIB="crates/storage_impl/src/lib.rs"
SI_PI="crates/storage_impl/src/payments/payment_intent.rs"

# ============================================================
# F2P gates - all check behavioral changes that FAIL on base
# ============================================================

add() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
    echo "  +$1 = $REWARD ($2)"
}

# ---------- Helpers to extract v2 blocks ----------

# Extract a v2 impl block by name from a file
extract_v2_impl() {
    local file="$1" impl_name="$2"
    [ ! -f "$file" ] && return 1
    awk -v target="$impl_name" '
        BEGIN{state=0; depth=0}
        # state 0: looking for #[cfg(feature = "v2")]
        state==0 {
            if ($0 ~ /#\[cfg\(feature = "v2"\)\]/) { state=1; buf=""; next }
        }
        state==1 {
            # skip blank lines and other attributes
            if ($0 ~ /^[[:space:]]*$/) next
            if ($0 ~ /^#\[/) next
            # Check if this is the impl we want
            if ($0 ~ ("^impl[[:space:]]+" target "[[:space:]]*\\{")) {
                state=2
                depth=1
                print
                next
            } else {
                state=0
                next
            }
        }
        state==2 {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth <= 0) { state=0 }
        }
    ' "$file"
}

# ---------- F2P 1: V2 PaymentIntentUpdateInternal::apply_changeset implemented (0.20) ----------
F1_OK=0
if [ -f "$DIESEL_PI" ]; then
    BLOCK=$(extract_v2_impl "$DIESEL_PI" "PaymentIntentUpdateInternal")
    if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'fn apply_changeset'; then
        # Strip comments
        UNCOMMENTED=$(echo "$BLOCK" | sed 's|//.*||')
        HAS_TODO=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(\)|todo!\("|unimplemented!')
        HAS_PI_CTOR=$(echo "$UNCOMMENTED" | grep -cE 'PaymentIntent[[:space:]]*\{')
        HAS_SOURCE=$(echo "$UNCOMMENTED" | grep -cE '\.\.source')
        FIELD_COUNT=$(echo "$UNCOMMENTED" | grep -cE '(unwrap_or|\.or)\(source\.')
        if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PI_CTOR" -ge 1 ] && [ "$HAS_SOURCE" -ge 1 ] && [ "$FIELD_COUNT" -ge 8 ]; then
            F1_OK=1
        fi
    fi
fi
if [ "$F1_OK" = "1" ]; then
    add 0.20 "F2P-1: V2 PaymentIntentUpdateInternal::apply_changeset implemented"
else
    echo "  F2P-1 FAIL"
fi

# ---------- F2P 2: V2 PaymentAttempt apply_changeset NOT todo!() (0.20) ----------
F2_OK=0
if [ -f "$DIESEL_PA" ]; then
    # Look at v2 impls of either PaymentAttemptUpdate or PaymentAttemptUpdateInternal
    for impl_target in "PaymentAttemptUpdateInternal" "PaymentAttemptUpdate"; do
        BLOCK=$(extract_v2_impl "$DIESEL_PA" "$impl_target")
        if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'fn apply_changeset'; then
            FN_BODY=$(echo "$BLOCK" | awk '
                /fn apply_changeset/ {found=1; depth=0; n_started=0}
                found {
                    print
                    n1=gsub(/\{/,"{")
                    n2=gsub(/\}/,"}")
                    if (n1>0) n_started=1
                    depth += n1 - n2
                    if (n_started && depth<=0) exit
                }
            ')
            UNCOMMENTED=$(echo "$FN_BODY" | sed 's|//.*||')
            HAS_TODO=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(\)|todo!\("|unimplemented!')
            HAS_PA_CTOR=$(echo "$UNCOMMENTED" | grep -cE 'PaymentAttempt[[:space:]]*\{')
            FIELD_COUNT=$(echo "$UNCOMMENTED" | grep -cE '(unwrap_or|\.or)\((source|self|update)\.')
            if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PA_CTOR" -ge 1 ] && [ "$FIELD_COUNT" -ge 8 ]; then
                F2_OK=1
                break
            fi
        fi
    done
fi
if [ "$F2_OK" = "1" ]; then
    add 0.20 "F2P-2: V2 PaymentAttempt apply_changeset implemented (no todo!)"
else
    echo "  F2P-2 FAIL"
fi

# ---------- F2P 3: V2 UniqueConstraints impl for PaymentAttempt (0.15) ----------
# Base has only #[cfg(feature = "v1")] for this impl. Must add v2.
F3_OK=0
if [ -f "$SI_LIB" ]; then
    # Look for a v2 UniqueConstraints impl for PaymentAttempt
    BLOCK=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 {
            if ($0 ~ /^impl[[:space:]]+UniqueConstraints[[:space:]]+for[[:space:]]+diesel_models::PaymentAttempt/) {
                inblock=1; depth=0
            }
            gate=0
        }
        inblock {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<=0 && /\}/) { inblock=0 }
        }
    ' "$SI_LIB")
    if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'unique_constraints' && echo "$BLOCK" | grep -q 'self.id'; then
        F3_OK=1
    fi
fi
if [ "$F3_OK" = "1" ]; then
    add 0.15 "F2P-3: V2 UniqueConstraints for PaymentAttempt added"
else
    echo "  F2P-3 FAIL"
fi

# ---------- F2P 4: V2 storage_impl payment_intent KV imports unblocked (0.10) ----------
# Base has many `#[cfg(feature = "v1")]` gates on imports like `kv`, `HsetnxReply`,
# and `redis::kv_store::{...}`. These must be ungated for v2 to use them.
F4_OK=0
if [ -f "$SI_PI" ]; then
    # Check that `use diesel_models::kv` is NOT v1-only
    KV_LINE_NUM=$(grep -nE 'use diesel_models::(kv\b|\{kv)' "$SI_PI" | head -1 | cut -d: -f1)
    HSETNX_LINE_NUM=$(grep -nE 'use redis_interface::HsetnxReply' "$SI_PI" | head -1 | cut -d: -f1)
    KVSTORE_LINE_NUM=$(grep -nE 'redis::kv_store::\{' "$SI_PI" | head -1 | cut -d: -f1)

    UNGATED_COUNT=0
    for ln in "$KV_LINE_NUM" "$HSETNX_LINE_NUM" "$KVSTORE_LINE_NUM"; do
        if [ -n "$ln" ] && [ "$ln" -gt 1 ]; then
            PREV_LINE=$(sed -n "$((ln-1))p" "$SI_PI")
            if ! echo "$PREV_LINE" | grep -q 'cfg(feature = "v1")'; then
                UNGATED_COUNT=$((UNGATED_COUNT+1))
            fi
        fi
    done
    if [ "$UNGATED_COUNT" -ge 2 ]; then
        F4_OK=1
    fi
fi
if [ "$F4_OK" = "1" ]; then
    add 0.10 "F2P-4: V2 storage_impl KV imports unblocked"
else
    echo "  F2P-4 FAIL"
fi

# ---------- F2P 5: V2 insert_payment_intent KV branch implemented (no todo!) (0.15) ----------
F5_OK=0
if [ -f "$SI_PI" ]; then
    # Extract the v2 insert_payment_intent function
    FN=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 && /^[[:space:]]*#\[/ {next}
        gate==1 {
            if ($0 ~ /async fn insert_payment_intent/) {
                inblock=1; depth=0; brace_seen=0
            }
            gate=0
        }
        inblock {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            if (n1>0) brace_seen=1
            depth += n1 - n2
            if (brace_seen && depth<=0) { inblock=0 }
        }
    ' "$SI_PI")
    if [ -n "$FN" ]; then
        # Check the RedisKv branch doesn't have todo!()
        # The whole function should reference HsetnxReply or kv_wrapper
        UNCOMMENTED=$(echo "$FN" | sed 's|//.*||')
        REDIS_KV_PRESENT=$(echo "$UNCOMMENTED" | grep -c 'RedisKv')
        TODO_COUNT=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(')
        HAS_KV_LOGIC=$(echo "$UNCOMMENTED" | grep -cE 'HsetnxReply|kv_wrapper|KvOperation')
        if [ "$REDIS_KV_PRESENT" -ge 1 ] && [ "$TODO_COUNT" -eq 0 ] && [ "$HAS_KV_LOGIC" -ge 1 ]; then
            F5_OK=1
        fi
    fi
fi
if [ "$F5_OK" = "1" ]; then
    add 0.15 "F2P-5: V2 insert_payment_intent KV branch implemented"
else
    echo "  F2P-5 FAIL"
fi

# ---------- F2P 6: V2 update_payment_intent KV branch implemented (0.10) ----------
F6_OK=0
if [ -f "$SI_PI" ]; then
    FN=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 && /^[[:space:]]*#\[/ {next}
        gate==1 {
            if ($0 ~ /async fn update_payment_intent/) {
                inblock=1; depth=0; brace_seen=0
            }
            gate=0
        }
        inblock {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            if (n1>0) brace_seen=1
            depth += n1 - n2
            if (brace_seen && depth<=0) { inblock=0 }
        }
    ' "$SI_PI")
    if [ -n "$FN" ]; then
        UNCOMMENTED=$(echo "$FN" | sed 's|//.*||')
        REDIS_KV_PRESENT=$(echo "$UNCOMMENTED" | grep -c 'RedisKv')
        TODO_COUNT=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(')
        HAS_KV_LOGIC=$(echo "$UNCOMMENTED" | grep -cE 'kv_wrapper|KvOperation|apply_changeset')
        if [ "$REDIS_KV_PRESENT" -ge 1 ] && [ "$TODO_COUNT" -eq 0 ] && [ "$HAS_KV_LOGIC" -ge 1 ]; then
            F6_OK=1
        fi
    fi
fi
if [ "$F6_OK" = "1" ]; then
    add 0.10 "F2P-6: V2 update_payment_intent KV branch implemented"
else
    echo "  F2P-6 FAIL"
fi

# ---------- F2P 7: openapi_v2 references KV merchant route (0.10) ----------
# Base does not include any merchant_account_*kv* in openapi_v2.rs
F7_OK=0
OPENAPI_V2="crates/openapi/src/openapi_v2.rs"
if [ -f "$OPENAPI_V2" ]; then
    if grep -qE 'merchant_account.*kv' "$OPENAPI_V2"; then
        F7_OK=1
    fi
fi
if [ "$F7_OK" = "1" ]; then
    add 0.10 "F2P-7: openapi_v2 references KV merchant route"
else
    echo "  F2P-7 FAIL"
fi

echo ""
echo "Total reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0