#!/bin/bash
set +e
# [v041-fix] rustup default stable
if command -v rustup >/dev/null 2>&1; then
    rustup default stable >/dev/null 2>&1 || true
fi
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

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


REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD="0.00"

write_reward() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"

WORKSPACE=""
for cand in /workspace/hyperswitch /workspace; do
    if [ -d "$cand/crates/hyperswitch_connectors" ]; then
        WORKSPACE="$cand"
        break
    fi
done

if [ -z "$WORKSPACE" ]; then
    echo "ERROR: cannot locate workspace"
    write_reward
fi

cd "$WORKSPACE" || write_reward

CHECKOUT_TRANSFORMERS="crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs"

if [ ! -f "$CHECKOUT_TRANSFORMERS" ]; then
    echo "ERROR: transformers.rs not found"
    write_reward
fi

# ===== P2P gating: ensure base regression guard - PaymentsRequest preserves processing_channel_id =====
req_block=$(awk '/pub struct PaymentsRequest[ {]/,/^}/' "$CHECKOUT_TRANSFORMERS")
if ! echo "$req_block" | grep -q 'processing_channel_id'; then
    echo "P2P FAIL: PaymentsRequest missing processing_channel_id (regression)"
    write_reward
fi
if ! echo "$req_block" | grep -q 'three_ds'; then
    echo "P2P FAIL: PaymentsRequest missing three_ds (regression)"
    write_reward
fi

# ===== F2P gates =====
# Each gate must FAIL on the unmodified base and PASS only when behavior added.
# All gates are behavioral signatures of the L2/L3 integration.

score=0
TOTAL_PTS=100  # represents 1.00

# ----- Gate A (0.09): PaymentsRequest gains a new `processing` field (not processing_channel_id) -----
gateA=0
if echo "$req_block" | grep -E '^\s*(pub\s+)?processing\s*:' | grep -qv processing_channel_id; then
    gateA=1
fi
if [ "$gateA" -eq 1 ]; then
    score=$((score + 9))
    echo "PASS A (0.09): PaymentsRequest has new 'processing' field"
else
    echo "FAIL A (0.09)"
fi

# ----- Gate B (0.09): An L3 line-item struct exists with commodity_code + unit_of_measure + unit_price -----
gateB=0
python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# match structs with optional attrs
pattern = re.compile(r'pub\s+struct\s+(\w+)\s*\{([^}]*)\}', re.DOTALL)
for m in pattern.finditer(src):
    body = m.group(2)
    if 'commodity_code' in body and 'unit_of_measure' in body and 'unit_price' in body:
        sys.exit(0)
sys.exit(1)
PY
if [ $? -eq 0 ]; then
    gateB=1
    score=$((score + 9))
    echo "PASS B (0.09): L3 line-item struct present"
else
    echo "FAIL B (0.09)"
fi

# ----- Gate C (0.09): An order-level (L2) struct exists with tax/discount/duty/shipping fields -----
gateC=0
python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
pattern = re.compile(r'pub\s+struct\s+(\w+)\s*\{([^}]*)\}', re.DOTALL)
for m in pattern.finditer(src):
    name, body = m.group(1), m.group(2)
    has_tax = ('tax_amount' in body) or ('order_tax_amount' in body)
    has_disc = 'discount_amount' in body
    has_ship = 'shipping' in body
    has_duty = 'duty_amount' in body
    has_items = ('order_details' in body) or ('line_items' in body) or ('items' in body and 'Vec<' in body)
    # accept either a struct grouping at least 2 of these fields, or one with items + at least one
    score_count = sum([has_tax, has_disc, has_ship, has_duty])
    if has_items and score_count >= 1:
        sys.exit(0)
    if score_count >= 2 and 'unit_price' not in body:
        sys.exit(0)
sys.exit(1)
PY
if [ $? -eq 0 ]; then
    gateC=1
    score=$((score + 9))
    echo "PASS C (0.09): L2 order-level struct present"
else
    echo "FAIL C (0.09)"
fi

# ----- Gate D (0.12): Code references l2_l3 data accessor / field on the router data -----
gateD=0
if grep -qE 'get_optional_l2_l3_data|\.l2_l3_data\b|L2L3Data' "$CHECKOUT_TRANSFORMERS"; then
    gateD=1
    score=$((score + 12))
    echo "PASS D (0.12): L2/L3 data is consumed in transformers"
else
    echo "FAIL D (0.12)"
fi

# ----- Gate E (0.12): processing field is actually populated (not None) in TryFrom for PaymentsRequest -----
gateE=0
python3 - <<'PY' 2>/dev/null
import re,sys
src = open("crates/hyperswitch_connectors/src/connectors/checkout/transformers.rs").read()
# Find TryFrom impls that build a PaymentsRequest. Since the struct uses Self, look for `Ok(Self {`
# and check that 'processing' appears either as shorthand `processing,` or `processing: <something not None>`.
ok = False
for m in re.finditer(r'Ok\(\s*Self\s*\{(.*?)\}\s*\)', src, re.DOTALL):
    body = m.group(1)
    # Must reference processing
    if not re.search(r'(^|[\s,])processing\s*[,:]', body):
        continue
    # If shorthand `processing,` then check earlier in the function for a let processing = ...
    # that is not `None`
    fn_start = src.rfind('fn ', 0, m.start())
    prefix = src[fn_start:m.start()] if fn_start != -1 else src[max(0,m.start()-4000):m.start()]
    # If there's a 'let processing' that mentions l2_l3 / get_optional_l2_l3_data / L2L3Data / map(
    if re.search(r'let\s+processing\s*=', prefix) and ('l2_l3' in prefix.lower() or 'L2L3' in prefix or 'get_optional_l2_l3_data' in prefix or '.map(' in prefix):
        ok = True
        break
    # Or inline processing: <expr> where expr is not None
    inline = re.search(r'processing\s*:\s*([^,\n}]+)', body)
    if inline and 'None' not in inline.group(1):
        ok = True
        break
if ok:
    sys.exit(0)
sys.exit(1)
PY
if [ $? -eq 0 ]; then
    gateE=1
    score=$((score + 12))
    echo "PASS E (0.12): TryFrom populates processing from L2/L3 data"
else
    echo "FAIL E (0.12)"
fi

# ----- Gate F (0.09): hyperswitch_connectors crate still compiles (cargo check) -----
# This compiles ONLY if changes are syntactically valid + types resolve. On no-op base it would also pass.
# So this is gated behind one of the F2P signals: only award if at least one of A/B/C/D/E passed AND it compiles.
# To keep no-op = 0: we require gateA OR gateB OR gateD AND compilation success.
gateF=0
if [ "$gateA" -eq 1 ] || [ "$gateB" -eq 1 ] || [ "$gateD" -eq 1 ]; then
    if command -v cargo >/dev/null 2>&1; then
        echo "Running cargo check on hyperswitch_connectors (this may take a while)..."
        cargo check -p hyperswitch_connectors --quiet 2>/tmp/cargo_check.log
        rc=$?
        if [ "$rc" -eq 0 ]; then
            gateF=1
            score=$((score + 9))
            echo "PASS F (0.09): hyperswitch_connectors compiles with new code"
        else
            echo "FAIL F (0.09): cargo check failed"
            tail -50 /tmp/cargo_check.log 2>/dev/null
        fi
    else
        echo "FAIL F (0.09): cargo not available"
    fi
else
    echo "FAIL F (0.09): no F2P signals - skipping compile credit (no-op safety)"
fi

# Compute reward as decimal score/100
REWARD=$(awk -v s="$score" -v t="$TOTAL_PTS" 'BEGIN { printf "%.2f", s/t }')
echo "Final score: $score / $TOTAL_PTS = $REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$GATES_FILE")"
> "$GATES_FILE"

# F2P gate: CheckoutProcessing struct exists
if grep -q 'pub struct CheckoutProcessing' "$CHECKOUT_TRANSFORMERS" 2>/dev/null; then
    echo '{"id": "f2p_upstream_checkout_processing_struct", "passed": true, "detail": "CheckoutProcessing struct found"}' >> "$GATES_FILE"
    echo "UPSTREAM PASS: f2p_upstream_checkout_processing_struct"
else
    echo '{"id": "f2p_upstream_checkout_processing_struct", "passed": false, "detail": "CheckoutProcessing struct not found"}' >> "$GATES_FILE"
    echo "UPSTREAM FAIL: f2p_upstream_checkout_processing_struct"
fi

# F2P gate: get_optional_l2_l3_data is called
if grep -q 'get_optional_l2_l3_data' "$CHECKOUT_TRANSFORMERS" 2>/dev/null; then
    echo '{"id": "f2p_upstream_l2l3_data_usage", "passed": true, "detail": "get_optional_l2_l3_data call found"}' >> "$GATES_FILE"
    echo "UPSTREAM PASS: f2p_upstream_l2l3_data_usage"
else
    echo '{"id": "f2p_upstream_l2l3_data_usage", "passed": false, "detail": "get_optional_l2_l3_data call not found"}' >> "$GATES_FILE"
    echo "UPSTREAM FAIL: f2p_upstream_l2l3_data_usage"
fi

# P2P regression gate: PaymentsRequest retains core fields
p2p_pass=true
p2p_detail=""
p2p_block=$(awk '/pub struct PaymentsRequest/,/^}/' "$CHECKOUT_TRANSFORMERS")
if ! echo "$p2p_block" | grep -q 'processing_channel_id'; then
    p2p_pass=false
    p2p_detail="missing processing_channel_id"
fi
if ! echo "$p2p_block" | grep -q 'three_ds'; then
    p2p_pass=false
    p2p_detail="${p2p_detail:+$p2p_detail; }missing three_ds"
fi
if [ "$p2p_pass" = true ]; then
    echo '{"id": "p2p_upstream_payments_request_regression", "passed": true, "detail": "core fields present"}' >> "$GATES_FILE"
    echo "UPSTREAM PASS: p2p_upstream_payments_request_regression"
else
    echo "{\"id\": \"p2p_upstream_payments_request_regression\", \"passed\": false, \"detail\": \"$p2p_detail\"}" >> "$GATES_FILE"
    echo "UPSTREAM FAIL: p2p_upstream_payments_request_regression"
fi

# Run upstream reward tail script
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_checkout_processing_struct": 0.20, "f2p_upstream_l2l3_data_usage": 0.20}
P2P_REGRESSION = ["p2p_upstream_payments_request_regression"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
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
hard_zero = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
if hard_zero:
    reward = 0.0
else:
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += w
    reward = min(reward, 1.0)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYEOF
# ---- end inner-claude upstream gates ----

exit 0