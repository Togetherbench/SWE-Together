#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono foreign tool-call ID fix
#
# Bug surface: convertResponsesMessages() in openai-responses-shared.ts
# mishandles foreign tool-call IDs:
#   - Pipe-separated "call_xxx|item_yyy" feed the whole string through
#     normalizeIdPart when target provider not in allowedToolCallProviders,
#     replacing "|" with "_" and "/" with "_", producing a mangled composite
#     id that the API rejects.
#   - Bare long fc_xxx IDs (>40 chars) routed to a Responses target exceed
#     the limit if not hashed/truncated.
#
# Every F2P gate executes convertResponsesMessages and asserts on its output.
# =============================================================================

GATES_FILE=/logs/verifier/gates.json
REWARD_FILE=/logs/verifier/reward.txt
mkdir -p "$(dirname "$GATES_FILE")"
: > "$GATES_FILE"
echo "0.0000" > "$REWARD_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr -d '\n' | sed 's/"/\\"/g' | cut -c1-200)
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO_ROOT="/workspace/pi-mono"
SRC_FILE="$REPO_ROOT/packages/ai/src/providers/openai-responses-shared.ts"

export PATH="/root/.bun/bin:/usr/local/bun/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v bun >/dev/null 2>&1; then
    BUN_BIN=$(find /root /usr/local /opt -maxdepth 5 -name bun -type f -executable 2>/dev/null | head -1)
    if [ -n "$BUN_BIN" ]; then export PATH="$(dirname "$BUN_BIN"):$PATH"; fi
fi

finalize() {
    local reward="$1"
    printf "%.4f\n" "$reward" > "$REWARD_FILE"
    echo "=== FINAL REWARD: $(cat "$REWARD_FILE") ==="
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
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
run_v043_gate p2p_upstream_771580d1 'npm_typecheck_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_816994b6 'vitest_session_manager_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t12_f2p_oversized_call_portion_hashed": 0.2, "t12_f2p_oversized_fc_id_hashed_under_limit": 0.25, "t12_f2p_pipe_id_extracts_clean_call_prefix": 0.3, "t13_f2p_copilot_real_string_clean_id": 0.15, "t13_f2p_no_underscore_substituted_slash_in_output": 0.1}
P2P_GATING = ["p2p_tsc_clean"]
P2P_REGRESSION = ["p2p_upstream_771580d1", "p2p_upstream_816994b6"]
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
}

# All F2P gates default to fail; flip to pass on success.
fail_all() {
    emit t12_f2p_pipe_id_extracts_clean_call_prefix false "$1"
    emit t12_f2p_oversized_fc_id_hashed_under_limit false "$1"
    emit t12_f2p_oversized_call_portion_hashed false "$1"
    emit t13_f2p_copilot_real_string_clean_id false "$1"
    emit t13_f2p_no_underscore_substituted_slash_in_output false "$1"
}

if [ ! -d "$REPO_ROOT" ] || [ ! -f "$SRC_FILE" ]; then
    emit p2p_tsc_clean false "repo or source missing"
    fail_all "repo or source missing"
    finalize 0.0
fi

# ---------------------------------------------------------------------------
# P2P: tsc clean (gating only)
# ---------------------------------------------------------------------------
echo "=== P2P: tsc compile check ==="
TSC_OUT=$(cd "$REPO_ROOT" && timeout 180 npx --no-install tsc --noEmit --project packages/ai/tsconfig.build.json 2>&1)
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    emit p2p_tsc_clean true ""
    TSC_OK=1
else
    emit p2p_tsc_clean false "tsc failed"
    echo "$TSC_OUT" | tail -30
    TSC_OK=0
fi

# ---------------------------------------------------------------------------
# Behavioral harness
# ---------------------------------------------------------------------------
echo ""
echo "=== Building behavioral harness ==="

HARNESS=$(cat <<'EOF'
import { getModel } from "./packages/ai/src/models.js";
import { convertResponsesMessages } from "./packages/ai/src/providers/openai-responses-shared.js";

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };

// Real failing pipe-id from the bug report.
const COPILOT_CALL_PORTION = "call_4VnzVawQXPB9MgYib7CiQFEY";
const COPILOT_ITEM_PORTION = "I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";
const COPILOT_PIPE_ID = COPILOT_CALL_PORTION + "|" + COPILOT_ITEM_PORTION;

// Bare long fc_ id (>40 chars).
const BARE_FC_ID = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi";

// Pipe id where the CALL portion alone is >40 chars.
const LONG_CALL_PORTION = "call_" + "A".repeat(60);  // 65 chars
const LONG_CALL_PIPE_ID = LONG_CALL_PORTION + "|fc_someitem";

function makeCtx(toolId, srcProvider, srcApi) {
    return {
        systemPrompt: "test",
        messages: [
            { role: "user", content: "hi", timestamp: Date.now() - 4000 },
            {
                role: "assistant",
                content: [{ type: "toolCall", id: toolId, name: "edit", arguments: { path: "a.css" } }],
                api: srcApi, provider: srcProvider, model: "gpt-5.3-codex",
                usage, stopReason: "toolUse", timestamp: Date.now() - 2000,
            },
            {
                role: "toolResult", toolCallId: toolId, toolName: "edit",
                content: [{ type: "text", text: "ok" }], isError: false, timestamp: Date.now() - 1000,
            },
        ],
    };
}

function tryConvert(targetProvider, targetModel, ctx, allowedSet) {
    const providers = new Set(allowedSet);
    try {
        const model = getModel(targetProvider, targetModel);
        const input = convertResponsesMessages(model, ctx, providers);
        const fc = input.find((i) => i.type === "function_call");
        const fco = input.find((i) => i.type === "function_call_output");
        return {
            ok: true,
            id: fc ? (fc.id ?? null) : null,
            call_id: fc ? (fc.call_id ?? null) : null,
            output_call_id: fco ? (fco.call_id ?? null) : null,
            ids_match: fc && fco ? fc.call_id === fco.call_id : false,
        };
    } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
    }
}

const results = {};

// Conservative buggy-base providers set: target 'github-copilot' is NOT in it,
// so a fix that ONLY widens the set in production code does NOT pass this harness.
// This forces the test to discriminate based on the actual conversion logic.
const CONSERVATIVE = ["openai", "openai-codex", "opencode"];

// A: Foreign Copilot pipe-id replayed onto github-copilot (target NOT in providers).
// Buggy base: normalizeIdPart eats the whole pipe string -> mangled.
// Correct fix: extracts clean call_4VnzVawQXPB9MgYib7CiQFEY.
results.A = tryConvert("github-copilot", "gpt-5.1-codex",
    makeCtx(COPILOT_PIPE_ID, "openai-codex", "openai-codex-responses"),
    CONSERVATIVE);

// B: Bare 64-char fc_ id onto openai-codex with source github-copilot (foreign).
// Buggy base may pass through unchanged (length 64 -> exceeds 40 limit).
// Correct fix: hashes/truncates to <=40, output != input.
results.B = tryConvert("openai-codex", "gpt-5.3-codex",
    makeCtx(BARE_FC_ID, "github-copilot", "openai-responses"),
    CONSERVATIVE);

// C: Pipe id whose call portion is itself >40 chars onto github-copilot (foreign).
// Buggy base: produces long mangled id. Fix: hashes call portion to <=40.
results.C = tryConvert("github-copilot", "gpt-5.1-codex",
    makeCtx(LONG_CALL_PIPE_ID, "openai-codex", "openai-codex-responses"),
    CONSERVATIVE);

console.log("===META===");
console.log(JSON.stringify({
    COPILOT_CALL_PORTION,
    BARE_FC_ID,
    LONG_CALL_PORTION_PREFIX: "call_",
}));
console.log("===RESULTS===");
console.log(JSON.stringify(results));
EOF
)

HARNESS_OUT=$(cd "$REPO_ROOT" && timeout 120 bun -e "$HARNESS" 2>&1)
HARNESS_EXIT=$?
echo "--- harness output (tail) ---"
echo "$HARNESS_OUT" | tail -40
echo "--- end harness output ---"

RESULTS_JSON=$(echo "$HARNESS_OUT" | awk '/^===RESULTS===$/{flag=1;next} flag' | head -1)

if [ -z "$RESULTS_JSON" ]; then
    echo "Harness produced no results."
    fail_all "harness failed"
    finalize 0.0
fi

echo "RESULTS: $RESULTS_JSON"

# ---------------------------------------------------------------------------
# Run python predicates
# ---------------------------------------------------------------------------
PY_OUT=$(python3 - "$RESULTS_JSON" <<'PYEOF'
import json, sys

d = json.loads(sys.argv[1])
COPILOT_CALL = "call_4VnzVawQXPB9MgYib7CiQFEY"
BARE_FC_ID = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"

A = d.get("A", {})
B = d.get("B", {})
C = d.get("C", {})

def b(x): return "1" if x else "0"

# Gate t12_pipe_id_extracts_clean_call_prefix:
# Scenario A must succeed and call_id must be exactly the clean call portion.
g1 = A.get("ok") and A.get("call_id") == COPILOT_CALL and A.get("ids_match") is True

# Gate t12_oversized_fc_id_hashed_under_limit:
# Scenario B: call_id present, length <= 40, and DIFFERENT from raw input
# (proves hashing/normalization fired, not just passthrough).
b_call = B.get("call_id") if B.get("ok") else None
g2 = (B.get("ok")
      and isinstance(b_call, str)
      and len(b_call) <= 40
      and b_call != BARE_FC_ID
      and B.get("ids_match") is True)

# Gate t12_oversized_call_portion_hashed:
# Scenario C: call_id starts with 'call_', length <= 40, and contains no '|'.
c_call = C.get("call_id") if C.get("ok") else None
g3 = (C.get("ok")
      and isinstance(c_call, str)
      and c_call.startswith("call_")
      and len(c_call) <= 40
      and "|" not in c_call
      and C.get("ids_match") is True)

# Gate t13_copilot_real_string_clean_id:
# Strict: A.call_id == clean prefix AND A.output_call_id == clean prefix.
g4 = (A.get("ok")
      and A.get("call_id") == COPILOT_CALL
      and A.get("output_call_id") == COPILOT_CALL)

# Gate t13_no_underscore_substituted_slash_in_output:
# Output call_id from A must NOT contain '_cHXKTw3' (the buggy '/' -> '_' signature).
a_call = A.get("call_id") if A.get("ok") else ""
a_out  = A.get("output_call_id") if A.get("ok") else ""
g5 = (A.get("ok")
      and isinstance(a_call, str)
      and "_cHXKTw3" not in a_call
      and "_cHXKTw3" not in (a_out or "")
      # AND must be a real id (not empty / not the raw mangled form). Require
      # call_id length <= 40 to ensure we're not just looking at trimmed garbage.
      and len(a_call) <= 40
      and len(a_call) > 0)

print(f"G1={b(g1)}")
print(f"G2={b(g2)}")
print(f"G3={b(g3)}")
print(f"G4={b(g4)}")
print(f"G5={b(g5)}")
print(f"A_call_id={A.get('call_id')!r}")
print(f"A_output_call_id={A.get('output_call_id')!r}")
print(f"A_ids_match={A.get('ids_match')}")
print(f"B_call_id={B.get('call_id')!r}  len={len(B.get('call_id') or '')}")
print(f"C_call_id={C.get('call_id')!r}  len={len(C.get('call_id') or '')}")
PYEOF
)

echo "$PY_OUT"

get() {
    echo "$PY_OUT" | grep -E "^$1=" | head -1 | cut -d= -f2
}

G1=$(get G1); G2=$(get G2); G3=$(get G3); G4=$(get G4); G5=$(get G5)

REWARD=0
add() { REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}'); }

if [ "$G1" = "1" ]; then
    emit t12_f2p_pipe_id_extracts_clean_call_prefix true ""
    add 0.30
else
    emit t12_f2p_pipe_id_extracts_clean_call_prefix false "A.call_id != clean call prefix"
fi

if [ "$G2" = "1" ]; then
    emit t12_f2p_oversized_fc_id_hashed_under_limit true ""
    add 0.25
else
    emit t12_f2p_oversized_fc_id_hashed_under_limit false "B oversized fc_ not hashed/truncated"
fi

if [ "$G3" = "1" ]; then
    emit t12_f2p_oversized_call_portion_hashed true ""
    add 0.20
else
    emit t12_f2p_oversized_call_portion_hashed false "C oversized call portion not hashed"
fi

if [ "$G4" = "1" ]; then
    emit t13_f2p_copilot_real_string_clean_id true ""
    add 0.15
else
    emit t13_f2p_copilot_real_string_clean_id false "copilot real string did not yield clean call_id on both fc and fco"
fi

if [ "$G5" = "1" ]; then
    emit t13_f2p_no_underscore_substituted_slash_in_output true ""
    add 0.10
else
    emit t13_f2p_no_underscore_substituted_slash_in_output false "output still bears '_cHXKTw3' substitution signature or is malformed"
fi

# P2P_GATING: if tsc failed, zero out reward.
if [ "$TSC_OK" != "1" ]; then
    echo "P2P_GATING failed (tsc) -> reward = 0."
    finalize 0.0
fi

finalize "$REWARD"