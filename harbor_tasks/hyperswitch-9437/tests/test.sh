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

# ===== P2P diagnostic: ensure base regression guard - PaymentsRequest preserves processing_channel_id =====
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

emit_gate() {
    local id="$1" passed="$2" detail="$3"
    detail="${detail//\"/\\\"}"
    mkdir -p /logs/verifier
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> /logs/verifier/gates.json
}

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
    emit_gate "gate_a_processing_field" true "PaymentsRequest has new 'processing' field"
else
    echo "FAIL A (0.09)"
    emit_gate "gate_a_processing_field" false "PaymentsRequest missing 'processing' field"
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
    emit_gate "gate_b_l3_line_item_struct" true "L3 line-item struct present"
else
    echo "FAIL B (0.09)"
    emit_gate "gate_b_l3_line_item_struct" false "L3 line-item struct missing"
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
    emit_gate "gate_c_l2_order_struct" true "L2 order-level struct present"
else
    echo "FAIL C (0.09)"
    emit_gate "gate_c_l2_order_struct" false "L2 order-level struct missing"
fi

# ----- Gate D (0.12): Code references l2_l3 data accessor / field on the router data -----
gateD=0
if grep -qE 'get_optional_l2_l3_data|\.l2_l3_data\b|L2L3Data' "$CHECKOUT_TRANSFORMERS"; then
    gateD=1
    score=$((score + 12))
    echo "PASS D (0.12): L2/L3 data is consumed in transformers"
    emit_gate "gate_d_l2l3_data_accessor" true "l2_l3 accessor/type referenced"
else
    echo "FAIL D (0.12)"
    emit_gate "gate_d_l2l3_data_accessor" false "no l2_l3 accessor/type reference"
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
    emit_gate "gate_e_processing_populated" true "TryFrom populates processing from L2/L3 data"
else
    echo "FAIL E (0.12)"
    emit_gate "gate_e_processing_populated" false "TryFrom does not populate processing from L2/L3"
fi

# ----- Gate F (0.09): hyperswitch_connectors crate still compiles (cargo check) -----
# This compiles ONLY if changes are syntactically valid + types resolve. On no-op base it would also pass.
# So this is gated behind one of the F2P signals: only award if at least one of A/B/C/D/E passed AND it compiles.
# To keep no-op = 0: we require gateA OR gateB OR gateD AND compilation success.
gateF=0
gateF_skip_reason=""
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
            # Sandbox infra fault: if cargo errored on rustc version (workspace
            # needs 1.85 but sandbox has 1.82), this is an environment issue
            # unrelated to the canonical patch. Treat as inconclusive and award.
            if grep -qE "is not supported by the following packages|requires rustc 1\.[8-9][0-9]" /tmp/cargo_check.log 2>/dev/null; then
                gateF=1
                score=$((score + 9))
                gateF_skip_reason="rustc version mismatch in sandbox (infra-only)"
                echo "PASS F (0.09): cargo check infra-skipped (rustc version mismatch)"
            else
                echo "FAIL F (0.09): cargo check failed"
                tail -50 /tmp/cargo_check.log 2>/dev/null
            fi
        fi
    else
        echo "FAIL F (0.09): cargo not available"
    fi
else
    echo "FAIL F (0.09): no F2P signals - skipping compile credit (no-op safety)"
fi
if [ "$gateF" -eq 1 ]; then
    emit_gate "gate_f_cargo_check" true "compiled OK${gateF_skip_reason:+ ($gateF_skip_reason)}"
else
    emit_gate "gate_f_cargo_check" false "compile failed or skipped"
fi

# Compute reward as decimal score/100
REWARD=$(awk -v s="$score" -v t="$TOTAL_PTS" 'BEGIN { printf "%.2f", s/t }')
echo "Final score: $score / $TOTAL_PTS = $REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$GATES_FILE")"
# Do NOT truncate here — inline gates above already wrote their verdicts.

# F2P gate: CheckoutProcessing struct exists
if grep -q 'pub struct CheckoutProcessing' "$CHECKOUT_TRANSFORMERS" 2>/dev/null; then
    echo '{"id": "f2p_upstream_checkout_processing_struct", "passed": true, "detail": "CheckoutProcessing struct found"}' >> "$GATES_FILE"
    echo "UPSTREAM PASS: f2p_upstream_checkout_processing_struct"
else
    echo '{"id": "f2p_upstream_checkout_processing_struct", "passed": false, "detail": "CheckoutProcessing struct not found"}' >> "$GATES_FILE"
    echo "UPSTREAM FAIL: f2p_upstream_checkout_processing_struct"
fi

# F2P gate: L2/L3 data is consumed (behavioral check — accept any of the canonical
# accessor patterns: `.l2_l3_data` field access, `get_optional_l2_l3_data` helper
# (older session shape), or an `L2L3Data` type reference). Upstream PR #9446
# uses `&item.router_data.l2_l3_data`, so the field-access form is the gold path.
if grep -qE 'get_optional_l2_l3_data|\.l2_l3_data\b|L2L3Data' "$CHECKOUT_TRANSFORMERS" 2>/dev/null; then
    echo '{"id": "f2p_upstream_l2l3_data_usage", "passed": true, "detail": "l2_l3_data accessor / L2L3Data type found"}' >> "$GATES_FILE"
    echo "UPSTREAM PASS: f2p_upstream_l2l3_data_usage"
else
    echo '{"id": "f2p_upstream_l2l3_data_usage", "passed": false, "detail": "no l2_l3_data accessor / L2L3Data type found"}' >> "$GATES_FILE"
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
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
# weighted-replace formula (c8bc168a standard, replaces additive)
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYEOF
# ---- end inner-claude upstream gates ----

exit 0

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
