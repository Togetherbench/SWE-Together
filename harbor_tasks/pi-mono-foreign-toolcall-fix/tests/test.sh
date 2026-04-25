#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono foreign tool-call ID fix
# =============================================================================
# Bug: When a conversation switches from one provider (e.g. openai-codex or
# github-copilot) to another that uses the openai-responses API, tool-call IDs
# stored from the prior session can be:
#   (a) pipe-separated "call_xxx|item_yyy" forms, or
#   (b) bare long fc_xxx ids that exceed the destination provider's length
#       constraint (40 or 64 chars depending on backend), or
#   (c) contain characters outside [a-zA-Z0-9_-].
#
# The fix should:
#   - On a pure pipe-delim foreign ID, produce a normalized id that does not
#     contain the buggy direct-substitution result.
#   - Produce a Responses-API-valid id (matches ^[a-zA-Z0-9_-]+$, length<=64).
#   - Differentiate foreign vs same-provider/same-api inputs so foreign IDs
#     are remapped (hashed / shortened) but same-provider IDs are preserved
#     as-is when valid.
#   - Not crash on bare ids without a pipe.
# =============================================================================

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
echo "0.0" > "$REWARD_FILE"

REWARD=0.0
REPO_ROOT="/workspace/pi-mono"
SRC_FILE="$REPO_ROOT/packages/ai/src/providers/openai-responses-shared.ts"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

export PATH="/root/.bun/bin:/usr/local/bun/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v bun >/dev/null 2>&1; then
    BUN_BIN=$(find /root /usr/local /opt -maxdepth 5 -name bun -type f -executable 2>/dev/null | head -1)
    if [ -n "$BUN_BIN" ]; then export PATH="$(dirname "$BUN_BIN"):$PATH"; fi
fi

if [ ! -d "$REPO_ROOT" ]; then
    echo "FAIL: Repo root not found at $REPO_ROOT"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate 1: TypeScript compilation (0.10)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== P2P Gate 1: TypeScript compilation ==="
TSC_OUT=$(cd "$REPO_ROOT" && npx --no-install tsc --noEmit --project packages/ai/tsconfig.build.json 2>&1)
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS: TypeScript compiles cleanly"
    add_reward 0.10
else
    echo "FAIL: TypeScript compilation errors:"
    echo "$TSC_OUT" | tail -15
fi

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate 2: Source structure (0.05)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== P2P Gate 2: Source structure ==="
if [ -f "$SRC_FILE" ] && grep -q "convertResponsesMessages" "$SRC_FILE"; then
    echo "PASS: Source file exists with convertResponsesMessages"
    add_reward 0.05
else
    echo "FAIL: Source structure broken"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Behavioral harness: exercise convertResponsesMessages with a variety of inputs
# representative of what the agent should fix. We capture the IDs produced for
# four scenarios and score against several behavioral predicates.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Building behavioral harness ==="

HARNESS=$(cat <<'EOF'
import { getModel } from "./packages/ai/src/models.js";
import { convertResponsesMessages } from "./packages/ai/src/providers/openai-responses-shared.js";

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };

const COPILOT_PIPE_ID = "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";
const BARE_FC_ID = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi";
const SHORT_PIPE_ID = "call_XYZ123|fc_short_item_id";

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

function tryConvert(targetProvider, ctx) {
    const providers = new Set(["openai", "openai-codex", "opencode"]);
    try {
        const model = getModel(targetProvider, "gpt-5.3-codex");
        const input = convertResponsesMessages(model, ctx, providers);
        const fc = input.find((i) => i.type === "function_call");
        const fco = input.find((i) => i.type === "function_call_output");
        return {
            ok: true,
            id: fc?.id ?? null,
            call_id: fc?.call_id ?? null,
            output_call_id: fco?.call_id ?? null,
            ids_match: fc?.call_id === fco?.call_id,
        };
    } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
    }
}

const results = {};

// Scenario A: Foreign Copilot pipe-id replayed via openai-codex (responses API).
results.A_foreign_copilot_to_codex = tryConvert(
    "openai-codex",
    makeCtx(COPILOT_PIPE_ID, "github-copilot", "openai-responses"),
);

// Scenario B: Same-provider/same-api short pipe id should pass through (item id should be preserved or normalized cleanly).
results.B_same_provider_short = tryConvert(
    "openai-codex",
    makeCtx(SHORT_PIPE_ID, "openai-codex", "openai-codex-responses"),
);

// Scenario C: Foreign bare fc_ id (no pipe) replayed onto codex — must not crash, must produce a usable id/call_id.
results.C_foreign_bare_fc = tryConvert(
    "openai-codex",
    makeCtx(BARE_FC_ID, "github-copilot", "openai-responses"),
);

// Scenario D: Foreign Copilot pipe-id replayed onto github-copilot (target NOT in allowed set).
results.D_foreign_to_copilot = tryConvert(
    "github-copilot",
    makeCtx(COPILOT_PIPE_ID, "openai-codex", "openai-codex-responses"),
);

console.log("===RESULTS===");
console.log(JSON.stringify(results));
EOF
)

HARNESS_OUT=$(cd "$REPO_ROOT" && bun -e "$HARNESS" 2>&1)
HARNESS_EXIT=$?
echo "$HARNESS_OUT" | tail -30

RESULTS_JSON=$(echo "$HARNESS_OUT" | awk '/^===RESULTS===$/{flag=1;next} flag' | head -1)

if [ -z "$RESULTS_JSON" ]; then
    echo "Harness failed to produce results — skipping behavioral gates"
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
fi

eval_py() {
    python3 -c "$1" <<<"$RESULTS_JSON" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate A1 (0.15): Scenario A — foreign id is NOT the buggy direct-substitution.
# The buggy base substitutes / -> _ and + -> _ then truncates; produces the exact
# string starting with "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"
# as the item portion. A correct fix must avoid that exact item portion.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate A1: Foreign ID not the buggy direct-substitution ==="
BUGGY_ITEM='fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi'
A_NOT_BUGGY=$(eval_py "
import sys, json
d = json.load(sys.stdin)['A_foreign_copilot_to_codex']
buggy = '$BUGGY_ITEM'
ok = d.get('ok') and d.get('id') and buggy not in (d.get('id') or '') and buggy not in (d.get('call_id') or '')
print('YES' if ok else 'NO')
print('id=', d.get('id'))
print('call_id=', d.get('call_id'))
")
echo "$A_NOT_BUGGY" | tail -3
if echo "$A_NOT_BUGGY" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.15
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate A2 (0.15): Scenario A — produced id and call_id meet Responses API
# format constraints: matches [a-zA-Z0-9_-]+, length <= 64, non-empty,
# and contains no '|' or '+' or '/' or '='.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate A2: Foreign ID format valid for Responses API ==="
A_FMT=$(eval_py "
import sys, json, re
d = json.load(sys.stdin)['A_foreign_copilot_to_codex']
def good(x):
    if not x: return False
    if len(x) == 0 or len(x) > 64: return False
    if not re.match(r'^[A-Za-z0-9_-]+\$', x): return False
    return True
ok = d.get('ok') and good(d.get('id')) and good(d.get('call_id'))
print('YES' if ok else 'NO')
print('lens', len(d.get('id') or ''), len(d.get('call_id') or ''))
")
echo "$A_FMT" | tail -2
if echo "$A_FMT" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.15
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate A3 (0.10): Scenario A — function_call.call_id matches function_call_output.call_id
# This is essential: the Responses API pairs the tool call with its result.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate A3: tool call <-> tool result call_id pairing ==="
A_PAIR=$(eval_py "
import sys, json
d = json.load(sys.stdin)['A_foreign_copilot_to_codex']
ok = d.get('ok') and d.get('ids_match') and d.get('call_id')
print('YES' if ok else 'NO')
")
if echo "$A_PAIR" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate B (0.10): Scenario B — same-provider short pipe id MUST behave
# differently from foreign. The fix must check source.provider/api against
# the target — i.e. the function should not unconditionally hash all pipe ids.
# Same-provider id of length <= 64 should preserve the literal call/item parts
# (post-normalization), so the produced call_id should equal the literal
# call_XYZ123 part (no hashing).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate B: Same-provider id preserved (foreign-vs-same differentiation) ==="
B_OK=$(eval_py "
import sys, json
d = json.load(sys.stdin)['B_same_provider_short']
ok = d.get('ok') and d.get('call_id') == 'call_XYZ123'
print('YES' if ok else 'NO')
print(repr(d))
")
echo "$B_OK" | tail -1
if echo "$B_OK" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate C (0.10): Scenario C — bare fc_ ID (no pipe) must not crash and
# must produce a usable, format-valid call_id (length 1..64, charset clean).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate C: Bare fc_ id (no pipe) handled cleanly ==="
C_OK=$(eval_py "
import sys, json, re
d = json.load(sys.stdin)['C_foreign_bare_fc']
cid = d.get('call_id') or ''
ok = d.get('ok') and 0 < len(cid) <= 64 and re.match(r'^[A-Za-z0-9_-]+\$', cid) and d.get('ids_match')
print('YES' if ok else 'NO')
print('cid=', cid)
")
echo "$C_OK" | tail -1
if echo "$C_OK" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate D (0.10): Scenario D — target github-copilot (NOT in allowed set):
# the produced call_id must NOT contain the original '|', '+', '/', or '=', and
# must be format-valid. This catches the pure-normalizeIdPart path that mangles
# pipe-delim ids into a single underscore-joined blob.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate D: Foreign id targeting non-allowed provider is clean ==="
D_OK=$(eval_py "
import sys, json, re
d = json.load(sys.stdin)['D_foreign_to_copilot']
cid = d.get('call_id') or ''
clean = bool(re.match(r'^[A-Za-z0-9_-]+\$', cid)) and 0 < len(cid) <= 64
no_separators = '|' not in cid and '+' not in cid and '/' not in cid and '=' not in cid
ok = d.get('ok') and clean and no_separators and d.get('ids_match')
print('YES' if ok else 'NO')
print('cid=', cid)
")
echo "$D_OK" | tail -1
if echo "$D_OK" | head -1 | grep -q "^YES$"; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Structural Gate (0.10): some non-trivial diff vs base in the code paths
# that govern foreign-id handling — either openai-responses-shared.ts changed
# OR the OPENAI_TOOL_CALL_PROVIDERS set in openai-responses.ts changed. We
# check via git diff lines on the relevant files.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Structural Gate: source modified in a relevant location ==="
DIFF1=$(cd "$REPO_ROOT" && git diff --unified=0 -- packages/ai/src/providers/openai-responses-shared.ts 2>/dev/null | wc -l)
DIFF2=$(cd "$REPO_ROOT" && git diff --unified=0 -- packages/ai/src/providers/openai-responses.ts 2>/dev/null | wc -l)
DIFF3=$(cd "$REPO_ROOT" && git diff --unified=0 -- packages/ai/src/providers/openai-codex-responses.ts 2>/dev/null | wc -l)
TOTAL_DIFF=$((DIFF1 + DIFF2 + DIFF3))
if [ "$TOTAL_DIFF" -ge 3 ]; then
    echo "PASS: relevant files modified (diff lines=$TOTAL_DIFF)"
    add_reward 0.05
else
    echo "FAIL: no relevant code change detected"
fi

# Bonus: existing repo tests still pass for openai-responses (P2P regression guard).
echo ""
echo "=== P2P Bonus: existing openai-responses tests still pass ==="
if command -v bun >/dev/null 2>&1; then
    BUN_TEST_OUT=$(cd "$REPO_ROOT/packages/ai" && timeout 90 bun test --bail \
        test/openai-responses-foreign-toolcall-id.test.ts 2>&1)
    BUN_TEST_EXIT=$?
    echo "$BUN_TEST_OUT" | tail -10
    if [ $BUN_TEST_EXIT -eq 0 ]; then
        echo "PASS: existing tests pass"
        add_reward 0.05
    else
        # If file doesn't exist (base may not have it), award if no FAIL markers at all
        if echo "$BUN_TEST_OUT" | grep -qiE "(no tests|not found|cannot find)"; then
            echo "SKIP: test file not present"
        else
            echo "FAIL: existing tests broke"
        fi
    fi
fi

echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"