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

LOG_DIR=/logs/verifier
mkdir -p "$LOG_DIR"
GATES_FILE="$LOG_DIR/gates.json"
: > "$GATES_FILE"
REWARD_FILE="$LOG_DIR/reward.txt"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

# Locate repo
REPO=""
for cand in /workspace/hyperswitch /workspace/hyperswitch_pool_0 /workspace/repos/hyperswitch_pool_0; do
    if [ -d "$cand/crates/hyperswitch_connectors" ]; then
        REPO="$cand"; break
    fi
done
if [ -z "$REPO" ]; then
    found=$(find /workspace -maxdepth 4 -type d -name hyperswitch_connectors 2>/dev/null | head -n1)
    if [ -n "$found" ]; then
        REPO=$(dirname "$(dirname "$found")")
    fi
fi

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    emit t1_f2p_hc_declares_stripe_mod false "repo not found"
    emit t1_f2p_hc_reexports_stripe false "repo not found"
    emit t1_f2p_router_mod_removed false "repo not found"
    emit t1_f2p_router_reexports_from_hc false "repo not found"
    printf "%.4f\n" 0 > "$REWARD_FILE"
    exit 0
fi

HC="$REPO/crates/hyperswitch_connectors"
ROUTER="$REPO/crates/router"
HC_CONNECTORS_RS="$HC/src/connectors.rs"
ROUTER_CONNECTOR_RS="$ROUTER/src/connector.rs"
ROUTER_CONNECTOR_DIR="$ROUTER/src/connector"

REWARD=0
add_reward() {
    REWARD=$(awk -v r="$REWARD" -v w="$1" 'BEGIN{printf "%.4f", r+w}')
}

# ---------------------------------------------------------------------------
# Gate 1: hyperswitch_connectors declares pub mod stripe;
# Search across the connectors module entry points (connectors.rs or connectors/mod.rs)
# ---------------------------------------------------------------------------
mod_decl_found=0
for f in "$HC_CONNECTORS_RS" "$HC/src/connectors/mod.rs" "$HC/src/lib.rs"; do
    if [ -f "$f" ] && grep -qE '^[[:space:]]*pub[[:space:]]+mod[[:space:]]+stripe[[:space:]]*;' "$f"; then
        mod_decl_found=1
        break
    fi
done
# Also accept conditional cfg-gated declaration
if [ "$mod_decl_found" -eq 0 ]; then
    for f in "$HC_CONNECTORS_RS" "$HC/src/connectors/mod.rs" "$HC/src/lib.rs"; do
        if [ -f "$f" ] && grep -qE 'pub[[:space:]]+mod[[:space:]]+stripe[[:space:]]*;' "$f"; then
            mod_decl_found=1
            break
        fi
    done
fi

if [ "$mod_decl_found" -eq 1 ]; then
    emit t1_f2p_hc_declares_stripe_mod true ""
    add_reward 0.25
    G1=1
else
    emit t1_f2p_hc_declares_stripe_mod false "no pub mod stripe; in hyperswitch_connectors"
    G1=0
fi

# ---------------------------------------------------------------------------
# Gate 2: hyperswitch_connectors re-exports Stripe (`stripe::Stripe`)
# Look in connectors.rs / lib.rs / connectors/mod.rs for the re-export
# ---------------------------------------------------------------------------
reexport_found=0
for f in "$HC_CONNECTORS_RS" "$HC/src/connectors/mod.rs" "$HC/src/lib.rs"; do
    if [ -f "$f" ] && grep -qE 'stripe::Stripe' "$f"; then
        reexport_found=1
        break
    fi
done

if [ "$reexport_found" -eq 1 ]; then
    emit t1_f2p_hc_reexports_stripe true ""
    add_reward 0.25
else
    emit t1_f2p_hc_reexports_stripe false "no stripe::Stripe re-export in hyperswitch_connectors"
fi

# ---------------------------------------------------------------------------
# Gate 3: router/src/connector.rs no longer declares local `pub mod stripe;`
# (must drop the local declaration since stripe now lives in hyperswitch_connectors)
# ---------------------------------------------------------------------------
router_local_mod_present=0
if [ -f "$ROUTER_CONNECTOR_RS" ]; then
    if grep -qE '^[[:space:]]*pub[[:space:]]+mod[[:space:]]+stripe[[:space:]]*;' "$ROUTER_CONNECTOR_RS"; then
        router_local_mod_present=1
    fi
fi

if [ "$router_local_mod_present" -eq 0 ]; then
    emit t1_f2p_router_mod_removed true ""
    add_reward 0.25
else
    emit t1_f2p_router_mod_removed false "router/src/connector.rs still declares pub mod stripe;"
fi

# ---------------------------------------------------------------------------
# Gate 4: router pulls Stripe from hyperswitch_connectors via re-export
# Accept either:
#   pub use hyperswitch_connectors::connectors::{ ..., stripe, ... };
#   pub use hyperswitch_connectors::connectors::stripe;
#   pub use hyperswitch_connectors::connectors::stripe::{...Stripe...};
# Look across router source tree, not just connector.rs (some patches put it elsewhere).
# ---------------------------------------------------------------------------
router_reexport_found=0
# Search router crate for a use/pub-use referencing hyperswitch_connectors::connectors::stripe
if [ -d "$ROUTER/src" ]; then
    if grep -rEn 'hyperswitch_connectors::connectors[^;]*stripe' "$ROUTER/src" 2>/dev/null | grep -qE '(pub[[:space:]]+use|^[^/]*use)[[:space:]]'; then
        router_reexport_found=1
    fi
fi

if [ "$router_reexport_found" -eq 1 ]; then
    emit t1_f2p_router_reexports_from_hc true ""
    add_reward 0.25
else
    emit t1_f2p_router_reexports_from_hc false "router does not import stripe from hyperswitch_connectors"
fi

printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
echo "FINAL REWARD: $REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjb21tYW5kIC12IHB5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
    # prelude 1
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
# v043.1 fix: removed bogus f2p_upstream_54b5536e (py_compile transform_script.py;
# files do not exist in upstream PR 8007 — they were agent scratch artifacts).
# Weight redistributed 0.20 -> 0.05 each across the 4 valid stripe-relocation gates.
run_v043_gate p2p_upstream_7a8254b6 'cargo_metadata_workspace' 'cd /workspace/hyperswitch && export PATH=/usr/local/cargo/bin:$PATH && cargo metadata --no-deps --format-version=1 >/dev/null && echo OK'

# Recompute reward using v043 weights.
# v043.1 fix: P2P_REGRESSION is informational only (never zero reward).
# Only P2P_GATING ids may hard-zero. f2p_any_pass guard preserves inner reward.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_hc_declares_stripe_mod": 0.25, "t1_f2p_hc_reexports_stripe": 0.25, "t1_f2p_router_mod_removed": 0.25, "t1_f2p_router_reexports_from_hc": 0.25}
P2P_GATING = []
P2P_REGRESSION = ["p2p_upstream_7a8254b6"]
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
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
p2p_failed = False
for gid in P2P_GATING:
    if not verdicts.get(gid, False):
        p2p_failed = True; break
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += float(w)
reward = max(0.0, min(1.0, reward))
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0