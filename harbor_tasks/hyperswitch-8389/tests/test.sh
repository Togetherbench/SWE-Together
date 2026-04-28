#!/bin/bash
set +e
if command -v rustup >/dev/null 2>&1; then
    rustup default stable >/dev/null 2>&1 || true
fi
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO_DIR=""
for cand in /workspace/hyperswitch /workspace/hyperswitch_pool_0 ./repos/hyperswitch_pool_0 /workspace/repo; do
    if [ -d "$cand" ]; then REPO_DIR="$cand"; break; fi
done

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR" ]; then
    echo "FATAL: repo not found"
    for g in t1_f2p_pi_apply_changeset_v2 t1_f2p_pa_apply_changeset_v2 t1_f2p_unique_constraints_pa_v2 t1_f2p_kv_imports_ungated t1_f2p_insert_pi_v2_kv_branch t1_f2p_update_pi_v2_kv_branch t1_f2p_v2_kv_route_registered t1_f2p_global_payment_id_partition; do
        emit "$g" false "no repo"
    done
    printf "%.4f\n" 0.0 > /logs/verifier/reward.txt
    exit 0
fi

cd "$REPO_DIR" || exit 0

DIESEL_PI="crates/diesel_models/src/payment_intent.rs"
DIESEL_PA="crates/diesel_models/src/payment_attempt.rs"
SI_LIB="crates/storage_impl/src/lib.rs"
SI_PI="crates/storage_impl/src/payments/payment_intent.rs"
SI_PA="crates/storage_impl/src/payments/payment_attempt.rs"
KV_STORE="crates/storage_impl/src/redis/kv_store.rs"
APP_RS="crates/router/src/routes/app.rs"
ADMIN_RS="crates/router/src/routes/admin.rs"

# ---------- Helpers ----------
extract_v2_impl() {
    local file="$1" impl_name="$2"
    [ ! -f "$file" ] && return 1
    awk -v target="$impl_name" '
        BEGIN{state=0; depth=0}
        state==0 {
            if ($0 ~ /#\[cfg\(feature = "v2"\)\]/) { state=1; next }
        }
        state==1 {
            if ($0 ~ /^[[:space:]]*$/) next
            if ($0 ~ /^#\[/) next
            if ($0 ~ ("^impl[[:space:]]+" target "[[:space:]]*\\{") || $0 ~ ("^impl[[:space:]]+.*" target ".*\\{")) {
                state=2; depth=1; print; next
            } else { state=0; next }
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

extract_v2_fn() {
    local file="$1" fn_name="$2"
    [ ! -f "$file" ] && return 1
    awk -v target="$fn_name" '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 && /^[[:space:]]*#\[/ {next}
        gate==1 {
            if ($0 ~ ("(async[[:space:]]+)?fn[[:space:]]+" target "[[:space:]]*[<(]")) {
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
    ' "$file"
}

# ---------- F2P 1: V2 PaymentIntentUpdateInternal::apply_changeset ----------
F1_OK=0
F1_DETAIL=""
if [ -f "$DIESEL_PI" ]; then
    BLOCK=$(extract_v2_impl "$DIESEL_PI" "PaymentIntentUpdateInternal")
    if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'fn apply_changeset'; then
        UNCOMMENTED=$(echo "$BLOCK" | sed 's|//.*||')
        HAS_TODO=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(|unimplemented!')
        HAS_PI_CTOR=$(echo "$UNCOMMENTED" | grep -cE 'PaymentIntent[[:space:]]*\{')
        HAS_SOURCE=$(echo "$UNCOMMENTED" | grep -cE '\.\.source')
        # Require references to multiple known PaymentIntent fields
        FIELD_HITS=0
        for fld in status amount currency modified_at customer_id active_attempt_id; do
            if echo "$UNCOMMENTED" | grep -qE "\\b${fld}\\b.*(unwrap_or|\\.or)\\(source\\.${fld}|${fld}:[[:space:]]*self\\.${fld}\\.(clone\\(\\)\\.)?(unwrap_or|or)" ; then
                FIELD_HITS=$((FIELD_HITS+1))
            fi
        done
        FIELD_COUNT=$(echo "$UNCOMMENTED" | grep -cE '(unwrap_or|\.or)\(source\.')
        if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PI_CTOR" -ge 1 ] && [ "$HAS_SOURCE" -ge 1 ] && [ "$FIELD_COUNT" -ge 8 ] && [ "$FIELD_HITS" -ge 2 ]; then
            F1_OK=1
        else
            F1_DETAIL="todo=$HAS_TODO ctor=$HAS_PI_CTOR src=$HAS_SOURCE fc=$FIELD_COUNT fh=$FIELD_HITS"
        fi
    else
        F1_DETAIL="no v2 PaymentIntentUpdateInternal::apply_changeset"
    fi
else
    F1_DETAIL="missing $DIESEL_PI"
fi
if [ "$F1_OK" = "1" ]; then emit t1_f2p_pi_apply_changeset_v2 true ""; else emit t1_f2p_pi_apply_changeset_v2 false "$F1_DETAIL"; fi

# ---------- F2P 2: V2 PaymentAttempt apply_changeset ----------
F2_OK=0
F2_DETAIL=""
if [ -f "$DIESEL_PA" ]; then
    for impl_target in "PaymentAttemptUpdateInternal" "PaymentAttemptUpdate"; do
        BLOCK=$(extract_v2_impl "$DIESEL_PA" "$impl_target")
        if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'fn apply_changeset'; then
            UNCOMMENTED=$(echo "$BLOCK" | sed 's|//.*||')
            HAS_TODO=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(|unimplemented!')
            HAS_PA_CTOR=$(echo "$UNCOMMENTED" | grep -cE 'PaymentAttempt[[:space:]]*\{')
            FIELD_COUNT=$(echo "$UNCOMMENTED" | grep -cE '(unwrap_or|\.or)\((source|self|update)\.')
            HAS_SOURCE_OR_SPREAD=$(echo "$UNCOMMENTED" | grep -cE '\.\.source|\.\.self')
            if [ "$HAS_TODO" -eq 0 ] && [ "$HAS_PA_CTOR" -ge 1 ] && [ "$FIELD_COUNT" -ge 6 ]; then
                F2_OK=1
                break
            else
                F2_DETAIL="impl=$impl_target todo=$HAS_TODO ctor=$HAS_PA_CTOR fc=$FIELD_COUNT spread=$HAS_SOURCE_OR_SPREAD"
            fi
        fi
    done
fi
[ -z "$F2_DETAIL" ] && F2_DETAIL="no v2 PaymentAttempt apply_changeset"
if [ "$F2_OK" = "1" ]; then emit t1_f2p_pa_apply_changeset_v2 true ""; else emit t1_f2p_pa_apply_changeset_v2 false "$F2_DETAIL"; fi

# ---------- F2P 3: V2 UniqueConstraints for PaymentAttempt ----------
F3_OK=0
F3_DETAIL=""
if [ -f "$SI_LIB" ]; then
    BLOCK=$(awk '
        /#\[cfg\(feature = "v2"\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 {
            if ($0 ~ /^impl[[:space:]]+UniqueConstraints[[:space:]]+for[[:space:]]+(diesel_models::)?PaymentAttempt/) {
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
    if [ -n "$BLOCK" ] && echo "$BLOCK" | grep -q 'unique_constraints' && echo "$BLOCK" | grep -qE 'self\.id|self\.payment_id'; then
        F3_OK=1
    else
        F3_DETAIL="no v2 UniqueConstraints PaymentAttempt"
    fi
else
    F3_DETAIL="missing $SI_LIB"
fi
if [ "$F3_OK" = "1" ]; then emit t1_f2p_unique_constraints_pa_v2 true ""; else emit t1_f2p_unique_constraints_pa_v2 false "$F3_DETAIL"; fi

# ---------- F2P 4: V2 storage_impl KV imports ungated ----------
F4_OK=0
F4_DETAIL=""
if [ -f "$SI_PI" ]; then
    KV_LINE=$(grep -nE 'use diesel_models::(kv\b|\{kv|\{[^}]*\bkv\b)' "$SI_PI" | head -1 | cut -d: -f1)
    HSETNX_LINE=$(grep -nE 'use redis_interface::HsetnxReply' "$SI_PI" | head -1 | cut -d: -f1)
    KVSTORE_LINE=$(grep -nE 'redis::kv_store::\{|kv_store::(KvStorePartition|PartitionKey|KvOperation)' "$SI_PI" | head -1 | cut -d: -f1)
    UNGATED=0
    for ln in "$KV_LINE" "$HSETNX_LINE" "$KVSTORE_LINE"; do
        if [ -n "$ln" ] && [ "$ln" -gt 1 ]; then
            PREV=$(sed -n "$((ln-1))p" "$SI_PI")
            if ! echo "$PREV" | grep -q 'cfg(feature = "v1")'; then
                UNGATED=$((UNGATED+1))
            fi
        fi
    done
    if [ "$UNGATED" -ge 2 ]; then F4_OK=1; else F4_DETAIL="ungated=$UNGATED kv=$KV_LINE hs=$HSETNX_LINE kvs=$KVSTORE_LINE"; fi
else
    F4_DETAIL="missing $SI_PI"
fi
if [ "$F4_OK" = "1" ]; then emit t1_f2p_kv_imports_ungated true ""; else emit t1_f2p_kv_imports_ungated false "$F4_DETAIL"; fi

# ---------- F2P 5: V2 insert_payment_intent KV branch ----------
# Require co-occurrence of multiple cooperating KV symbols inside the v2 fn body.
F5_OK=0
F5_DETAIL=""
if [ -f "$SI_PI" ]; then
    FN=$(extract_v2_fn "$SI_PI" "insert_payment_intent")
    if [ -n "$FN" ]; then
        UNCOMMENTED=$(echo "$FN" | sed 's|//.*||')
        REDIS_KV=$(echo "$UNCOMMENTED" | grep -c 'RedisKv')
        TODO_COUNT=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(|unimplemented!')
        HAS_KV_WRAPPER=$(echo "$UNCOMMENTED" | grep -cE 'kv_wrapper')
        HAS_PARTITION=$(echo "$UNCOMMENTED" | grep -cE 'PartitionKey::')
        HAS_TYPED_SQL=$(echo "$UNCOMMENTED" | grep -cE 'TypedSql|DBOperation|redis_entry|HSetNx|HsetnxReply')
        if [ "$REDIS_KV" -ge 1 ] && [ "$TODO_COUNT" -eq 0 ] && [ "$HAS_KV_WRAPPER" -ge 1 ] && [ "$HAS_PARTITION" -ge 1 ] && [ "$HAS_TYPED_SQL" -ge 1 ]; then
            F5_OK=1
        else
            F5_DETAIL="rk=$REDIS_KV todo=$TODO_COUNT kw=$HAS_KV_WRAPPER pk=$HAS_PARTITION ts=$HAS_TYPED_SQL"
        fi
    else
        F5_DETAIL="no v2 insert_payment_intent fn"
    fi
else
    F5_DETAIL="missing $SI_PI"
fi
if [ "$F5_OK" = "1" ]; then emit t1_f2p_insert_pi_v2_kv_branch true ""; else emit t1_f2p_insert_pi_v2_kv_branch false "$F5_DETAIL"; fi

# ---------- F2P 6: V2 update_payment_intent KV branch ----------
F6_OK=0
F6_DETAIL=""
if [ -f "$SI_PI" ]; then
    FN=$(extract_v2_fn "$SI_PI" "update_payment_intent")
    if [ -n "$FN" ]; then
        UNCOMMENTED=$(echo "$FN" | sed 's|//.*||')
        REDIS_KV=$(echo "$UNCOMMENTED" | grep -c 'RedisKv')
        TODO_COUNT=$(echo "$UNCOMMENTED" | grep -cE 'todo!\(|unimplemented!')
        HAS_KV_WRAPPER=$(echo "$UNCOMMENTED" | grep -cE 'kv_wrapper')
        HAS_PARTITION=$(echo "$UNCOMMENTED" | grep -cE 'PartitionKey::')
        HAS_KV_OP=$(echo "$UNCOMMENTED" | grep -cE 'KvOperation::|apply_changeset|TypedSql')
        if [ "$REDIS_KV" -ge 1 ] && [ "$TODO_COUNT" -eq 0 ] && [ "$HAS_KV_WRAPPER" -ge 1 ] && [ "$HAS_PARTITION" -ge 1 ] && [ "$HAS_KV_OP" -ge 1 ]; then
            F6_OK=1
        else
            F6_DETAIL="rk=$REDIS_KV todo=$TODO_COUNT kw=$HAS_KV_WRAPPER pk=$HAS_PARTITION op=$HAS_KV_OP"
        fi
    else
        F6_DETAIL="no v2 update_payment_intent fn"
    fi
else
    F6_DETAIL="missing $SI_PI"
fi
if [ "$F6_OK" = "1" ]; then emit t1_f2p_update_pi_v2_kv_branch true ""; else emit t1_f2p_update_pi_v2_kv_branch false "$F6_DETAIL"; fi

# ---------- F2P 7: V2 merchant-accounts /:id/kv route registered ----------
# Base has only v1 route registration. For v2, must register route inside the v2 MerchantAccount server scope.
F7_OK=0
F7_DETAIL=""
if [ -f "$APP_RS" ]; then
    # Find the v2 MerchantAccount block
    V2_BLOCK=$(awk '
        /#\[cfg\(all\(feature = "v2", feature = "olap"\)\)\]/ {gate=1; next}
        gate==1 && /^[[:space:]]*$/ {next}
        gate==1 {
            if ($0 ~ /^impl[[:space:]]+MerchantAccount[[:space:]]*\{/) {
                inblock=1; depth=1; print; next
            }
            gate=0
        }
        inblock {
            print
            n1=gsub(/\{/,"{")
            n2=gsub(/\}/,"}")
            depth += n1 - n2
            if (depth<=0) { inblock=0 }
        }
    ' "$APP_RS")
    if [ -n "$V2_BLOCK" ] && echo "$V2_BLOCK" | grep -qE '/kv|"kv"|\{[a-z_]+\}/kv' ; then
        if echo "$V2_BLOCK" | grep -qE 'merchant_account_(toggle_)?kv|kv_for_merchant'; then
            F7_OK=1
        else
            F7_DETAIL="kv path found but no v2 handler ref"
        fi
    else
        F7_DETAIL="no /kv route in v2 MerchantAccount block"
    fi
fi
if [ "$F7_OK" = "1" ]; then emit t1_f2p_v2_kv_route_registered true ""; else emit t1_f2p_v2_kv_route_registered false "$F7_DETAIL"; fi

# ---------- F2P 8: V2 PartitionKey variant for global payment id ----------
# The v2 KV partition needs a key variant. Accept GlobalPaymentId, GlobalId expansion, or v2-gated variant
# referencing GlobalPaymentId in kv_store.rs AND used in payment_intent.rs.
F8_OK=0
F8_DETAIL=""
if [ -f "$KV_STORE" ]; then
    # Look for a v2-related variant (GlobalPaymentId or similar) OR usage by storage_impl payment_intent
    HAS_VARIANT=0
    if grep -qE 'GlobalPaymentId[[:space:]]*\{|GlobalId[[:space:]]*\{|MerchantIdGlobalPaymentId|GlobalAttemptId[[:space:]]*\{' "$KV_STORE"; then
        HAS_VARIANT=1
    fi
    USED=0
    if [ -f "$SI_PI" ] && grep -qE 'PartitionKey::(GlobalPaymentId|GlobalId|MerchantIdGlobalPaymentId)' "$SI_PI"; then
        USED=1
    fi
    if [ "$HAS_VARIANT" = "1" ] && [ "$USED" = "1" ]; then
        F8_OK=1
    else
        F8_DETAIL="variant=$HAS_VARIANT used=$USED"
    fi
else
    F8_DETAIL="missing $KV_STORE"
fi
if [ "$F8_OK" = "1" ]; then emit t1_f2p_global_payment_id_partition true ""; else emit t1_f2p_global_payment_id_partition false "$F8_DETAIL"; fi

# ---------- Compute reward ----------
REWARD=0.0
declare -A WEIGHTS=(
    [t1_f2p_pi_apply_changeset_v2]=0.18
    [t1_f2p_pa_apply_changeset_v2]=0.18
    [t1_f2p_unique_constraints_pa_v2]=0.14
    [t1_f2p_kv_imports_ungated]=0.10
    [t1_f2p_insert_pi_v2_kv_branch]=0.15
    [t1_f2p_update_pi_v2_kv_branch]=0.10
    [t1_f2p_v2_kv_route_registered]=0.10
    [t1_f2p_global_payment_id_partition]=0.05
)

while IFS= read -r line; do
    gid=$(echo "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    passed=$(echo "$line" | sed -n 's/.*"passed":\(true\|false\).*/\1/p')
    if [ "$passed" = "true" ]; then
        w=${WEIGHTS[$gid]:-0}
        REWARD=$(awk -v a="$REWARD" -v b="$w" 'BEGIN{printf "%.4f", a+b}')
    fi
done < "$GATES_FILE"

echo "Reward: $REWARD"
printf "%.4f\n" "$REWARD" > /logs/verifier/reward.txt
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBleHBvcnQgUEFUSD0vdXNyL2xvY2FsL2NhcmdvL2JpbjokUEFUSDsgcnVzdHVwIGluc3RhbGwgMS44NS4wIDI+JjEgfCB0YWlsIC0yOyBydXN0dXAgZGVmYXVsdCAxLjg1LjAgMj4mMSB8IHRhaWwgLTI7IGVjaG8gUEFUSD0vdXNyL2xvY2FsL2NhcmdvL2JpbjokUEFUSCA+IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNoOyBlY2hvICdleHBvcnQgQ0FSR09fQlVJTERfSk9CUz0xJyA+PiAvZXRjL3Byb2ZpbGUuZC9jYXJnby5zaDsgZWNobyAnZXhwb3J0IENBUkdPX0lOQ1JFTUVOVEFMPTAnID4+IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNoOyBjaG1vZCAwNjQ0IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNo' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_7a8254b6 'cargo_metadata_workspace' 'cd /workspace/hyperswitch && export PATH=/usr/local/cargo/bin:$PATH && cargo metadata --no-deps --format-version=1 >/dev/null && echo OK'
run_v043_gate p2p_upstream_27c5f56d 'rust_files_nonempty' 'cd /workspace/hyperswitch && ok=1; for f in crates/diesel_models/src/payment_intent.rs crates/storage_impl/src/payments/payment_intent.rs crates/storage_impl/src/redis/kv_store.rs crates/diesel_models/src/payment_attempt.rs crates/storage_impl/src/payments/payment_attempt.rs crates/diesel_models/src/kv.rs crates/router/src/routes/app.rs crates/openapi/src/routes/merchant_account.rs crates/openapi/src/openapi_v2.rs crates/storage_impl/src/lib.rs; do if [ ! -s "$f" ]; then ok=0; break; fi; head -c 4 "$f" | grep -q '\''^//'\'' && head -c 4 "$f" >/dev/null; done; [ $ok = 1 ] && echo OK || exit 1'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_global_payment_id_partition": 0.05, "t1_f2p_insert_pi_v2_kv_branch": 0.15, "t1_f2p_kv_imports_ungated": 0.1, "t1_f2p_pa_apply_changeset_v2": 0.18, "t1_f2p_pi_apply_changeset_v2": 0.18, "t1_f2p_unique_constraints_pa_v2": 0.14, "t1_f2p_update_pi_v2_kv_branch": 0.1, "t1_f2p_v2_kv_route_registered": 0.1}
P2P_GATING = []
P2P_REGRESSION = ["p2p_upstream_7a8254b6", "p2p_upstream_27c5f56d"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0