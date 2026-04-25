#!/bin/bash
set +e

cd /workspace/pi-mono 2>/dev/null || cd /workspace/$(ls /workspace 2>/dev/null | head -1)
WORKDIR=$(pwd)
echo "Working in: $WORKDIR"

mkdir -p /logs/verifier

git config --global --add safe.directory "$WORKDIR" 2>/dev/null || true

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
which bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REWARD=0
add_reward() {
    REWARD=$(awk -v r="$REWARD" -v a="$1" 'BEGIN { printf "%.4f", r + a }')
}

write_reward_and_exit() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

SHARED="packages/ai/src/providers/openai-responses-shared.ts"
RESPONSES="packages/ai/src/providers/openai-responses.ts"

# ═══════════════════════════════════════════════════════════════
# P2P GATE (regression guard, no reward): TypeScript compiles
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- P2P GATE: TypeScript compilation (gating, no reward) ---"
if ! (cd packages/ai && npx tsc --noEmit -p tsconfig.build.json 2>/tmp/tsc_errors.txt); then
    echo "FAIL: TypeScript compilation broken — destructive change. REWARD=0."
    tail -30 /tmp/tsc_errors.txt
    REWARD=0
    write_reward_and_exit
fi
echo "PASS gate: TypeScript compiles."

# ═══════════════════════════════════════════════════════════════
# Set up testable copies that export internal functions
# ═══════════════════════════════════════════════════════════════
TESTABLE_SHARED=""
TESTABLE_RESPONSES=""
if [ -f "$SHARED" ]; then
    TESTABLE_SHARED="${SHARED%.ts}-testable.ts"
    cp "$SHARED" "$TESTABLE_SHARED"
    sed -i 's/^function convertResponsesMessages/export function convertResponsesMessages/' "$TESTABLE_SHARED"
    sed -i 's/^function convertMessages/export function convertMessages/' "$TESTABLE_SHARED"
fi
if [ -f "$RESPONSES" ]; then
    TESTABLE_RESPONSES="${RESPONSES%.ts}-testable.ts"
    cp "$RESPONSES" "$TESTABLE_RESPONSES"
    sed -i 's/^function convertMessages/export function convertMessages/' "$TESTABLE_RESPONSES"
    sed -i 's/^function convertResponsesMessages/export function convertResponsesMessages/' "$TESTABLE_RESPONSES"
fi

cleanup() {
    [ -n "$TESTABLE_SHARED" ] && rm -f "$WORKDIR/$TESTABLE_SHARED" 2>/dev/null
    [ -n "$TESTABLE_RESPONSES" ] && rm -f "$WORKDIR/$TESTABLE_RESPONSES" 2>/dev/null
}
trap cleanup EXIT

mkdir -p /tmp/pitest

cat > /tmp/pitest/harness.ts << 'HARNESS'
async function loadConvert(): Promise<any> {
    const candidates = [
        process.cwd() + "/packages/ai/src/providers/openai-responses-shared-testable.ts",
        process.cwd() + "/packages/ai/src/providers/openai-responses-testable.ts",
    ];
    for (const c of candidates) {
        try {
            const mod = await import(c);
            if (typeof mod.convertResponsesMessages === "function") return mod.convertResponsesMessages;
            if (typeof mod.convertMessages === "function") return mod.convertMessages;
        } catch (e) {
            // try next
        }
    }
    throw new Error("Could not load convert function from any testable module");
}

export { loadConvert };
HARNESS

run_test() {
    local script="$1"
    (cd "$WORKDIR" && timeout 30 bun "$script" 2>&1)
}

# ═══════════════════════════════════════════════════════════════
# F2P GATE A: Same-model preservation (regression check w/ behavior)
# Buggy base preserves these. Reward only because the fix could
# accidentally break this; but it's also true on no-op. So we make
# this PURELY GATING with no reward — if fix broke it, reward=0.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- F2P GATE A: same-model still works (gating, 0 reward) ---"

cat > /tmp/pitest/same_model.ts << 'SAMEEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";
const convert = await loadConvert();

const model = {
    id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai",
    api: "openai-responses" as const, input: ["text"], reasoning: true,
    baseUrl: "https://api.openai.com/v1", headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                { type: "thinking" as const, thinking: "thinking",
                  thinkingSignature: JSON.stringify({ type: "reasoning", id: "rs_sametest", summary: [{ type: "summary_text", text: "thinking" }] }) },
                { type: "toolCall" as const, id: "call_same|fc_sametest", name: "search", arguments: { query: "test" } },
            ],
            model: "gpt-5-codex", provider: "openai", api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const, timestamp: Date.now(),
        },
        { role: "toolResult" as const, toolCallId: "call_same|fc_sametest", toolName: "search",
          content: [{ type: "text" as const, text: "result" }], isError: false, timestamp: Date.now() },
        { role: "user" as const, content: "ok", timestamp: Date.now() },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const reasoning = result.filter((i: any) => i.type === "reasoning");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");

    let fcHasFcId = false;
    for (const fc of fcs) {
        if ((fc as any).id && String((fc as any).id).startsWith("fc_")) fcHasFcId = true;
    }

    const ok = reasoning.length >= 1 && fcs.length >= 1 && fcOut.length >= 1 && fcHasFcId;
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} reasoning=${reasoning.length} fcs=${fcs.length} fcOut=${fcOut.length} fcHasFcId=${fcHasFcId}`);
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
SAMEEOF

OUT_A=$(run_test /tmp/pitest/same_model.ts)
echo "$OUT_A" | tail -5
if ! echo "$OUT_A" | grep -q "RESULT=PASS"; then
    echo "FAIL: Same-model behavior broken — destructive change. REWARD=0."
    REWARD=0
    write_reward_and_exit
fi
echo "PASS gate: same-model preserved."

# ═══════════════════════════════════════════════════════════════
# F2P GATE 1 (CORE FIX, weight 0.55): different-model handoff
# clears fc_xxx by default (no strictResponsesPairing flag set).
# On buggy base: assistant has provider==model.provider, api match,
# different model.id → fc_xxx is replayed AS-IS (bug). On fix: id is
# undefined/missing OR function_call is dropped, but function_call
# still pairs with output via call_id (or fc with no fc_ id).
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- F2P GATE 1 [CORE FIX]: different-model handoff (0.55) ---"

cat > /tmp/pitest/diff_model.ts << 'DIFFEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";
const convert = await loadConvert();

const model = {
    id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai",
    api: "openai-responses" as const, input: ["text"], reasoning: true,
    baseUrl: "https://api.openai.com/v1", headers: {},
} as any;

// Assistant produced by *different* OpenAI Responses model (e.g. gpt-5-mini).
// transformMessages strips the thinkingSignature for cross-model handoffs.
// So the assistant message has no thinkingSignature when convertMessages sees it.
const context = {
    messages: [
        { role: "user" as const, content: "Compute things", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                // no thinkingSignature — transformMessages strips it cross-model
                { type: "thinking" as const, thinking: "let me think" },
                { type: "toolCall" as const, id: "call_x1|fc_xtest", name: "search", arguments: { q: "a" } },
            ],
            model: "gpt-5-mini",
            provider: "openai", api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const, timestamp: Date.now(),
        },
        { role: "toolResult" as const, toolCallId: "call_x1|fc_xtest", toolName: "search",
          content: [{ type: "text" as const, text: "result" }], isError: false, timestamp: Date.now() },
        { role: "user" as const, content: "Continue", timestamp: Date.now() },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");
    const reasoning = result.filter((i: any) => i.type === "reasoning");

    // No reasoning items should be emitted (no signature available).
    const noReasoning = reasoning.length === 0;

    // The toolResult must be representable: either function_call_output with call_x1
    //   matched by some function_call (with fc id cleared / undefined),
    // OR text-conversion: tool call rendered as text and result rendered as user input.
    let coreFix = false;

    // Pattern A: function_call kept but fc_xxx id cleared, function_call_output present, paired by call_id
    const fcWithCallId = fcs.find((f: any) => f.call_id === "call_x1");
    const outWithCallId = fcOut.find((f: any) => f.call_id === "call_x1");
    if (fcWithCallId && outWithCallId) {
        const idCleared = !fcWithCallId.id || !String(fcWithCallId.id).startsWith("fc_");
        if (idCleared) coreFix = true;
    }

    // Pattern B: function_call dropped entirely AND no orphan function_call_output emitted
    //   (must be converted to text user message) — context preserved
    if (!fcWithCallId && !outWithCallId) {
        // verify some user/assistant message in result mentions search/result text
        const serialized = JSON.stringify(result);
        if (serialized.includes("search") && serialized.includes("result")) {
            coreFix = true;
        }
    }

    // BUG signature on base: fc_xtest replayed AS-IS with id="fc_xtest"
    const bugReplayed = fcs.some((f: any) => f.id === "fc_xtest");

    console.log(`RESULT=${coreFix && !bugReplayed && noReasoning ? "PASS" : "FAIL"} coreFix=${coreFix} bugReplayed=${bugReplayed} noReasoning=${noReasoning} reasoning=${reasoning.length} fcs=${fcs.length} fcOut=${fcOut.length}`);
    console.log("FCS:", JSON.stringify(fcs));
    console.log("FCOUT:", JSON.stringify(fcOut));
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
DIFFEOF

OUT_1=$(run_test /tmp/pitest/diff_model.ts)
echo "$OUT_1" | tail -10
if echo "$OUT_1" | grep -q "RESULT=PASS"; then
    add_reward 0.55
    echo "PASS: F2P core fix — different-model handoff clears fc_xxx (+0.55)"
else
    echo "FAIL: F2P core fix not applied"
fi

# ═══════════════════════════════════════════════════════════════
# F2P GATE 2 (weight 0.20): No flag-gating on strictResponsesPairing
# This is the explicit user requirement: behavior must be default,
# without the strictResponsesPairing compat flag.
# Buggy base may not have the flag at all (failed port), but if any
# code path is conditional on the flag, this fails.
# We grep ONLY for conditional gating patterns, not the bare token.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- F2P GATE 2: no flag-gated behavior (0.20) ---"

# We need this to fail on the buggy base too if base has flag-gating.
# But buggy base in this repo never had the flag (the user complained the
# port omitted it). So this gate only awards reward if the agent ALSO did
# not introduce flag-gating while implementing the fix.
# To avoid awarding on no-op (where no fix exists), we couple this to
# Gate 1 having passed — only count if core fix was applied.

GATED=0
for f in "$SHARED" "$RESPONSES"; do
    if [ -f "$f" ]; then
        if grep -E "if\s*\(.*strictResponsesPairing" "$f" >/dev/null 2>&1; then
            GATED=$((GATED + 1))
        fi
        if grep -E "\?\s*.*strictResponsesPairing" "$f" >/dev/null 2>&1; then
            GATED=$((GATED + 1))
        fi
        if grep -E "&&.*strictResponsesPairing" "$f" >/dev/null 2>&1; then
            GATED=$((GATED + 1))
        fi
    fi
done

if echo "$OUT_1" | grep -q "RESULT=PASS" && [ "$GATED" -eq 0 ]; then
    add_reward 0.20
    echo "PASS: behavior is default (not flag-gated) AND core fix applied (+0.20)"
else
    if [ "$GATED" -ne 0 ]; then
        echo "FAIL: behavior is gated on strictResponsesPairing in $GATED location(s)"
    else
        echo "FAIL: core fix not applied (Gate 1 failed) — no credit"
    fi
fi

# ═══════════════════════════════════════════════════════════════
# F2P GATE 3 (weight 0.25): tool-result pairing preserved end-to-end
# After the fix, a different-model handoff with an orphaned tool result
# (the tool call's fc_xxx was paired with a stripped rs_xxx) must NOT
# produce: a function_call with intact fc_xxx id, AND the conversation
# must remain coherent (the model still sees the result somehow).
#
# Specifically: if function_call_output is emitted, there must be a
# matching function_call (paired by call_id) to avoid 400 from the API.
# If function_call is dropped, function_call_output must also be dropped
# (and the result content surfaced as text).
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- F2P GATE 3: tool-result pairing coherent post-fix (0.25) ---"

cat > /tmp/pitest/pairing.ts << 'PAIREOF'
import { loadConvert } from "/tmp/pitest/harness.ts";
const convert = await loadConvert();

const model = {
    id: "gpt-5-codex", name: "gpt-5-codex", provider: "openai",
    api: "openai-responses" as const, input: ["text"], reasoning: true,
    baseUrl: "https://api.openai.com/v1", headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Q", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                { type: "thinking" as const, thinking: "..." },
                { type: "toolCall" as const, id: "call_p|fc_p", name: "search", arguments: { q: "x" } },
            ],
            model: "gpt-5-mini", provider: "openai", api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const, timestamp: Date.now(),
        },
        { role: "toolResult" as const, toolCallId: "call_p|fc_p", toolName: "search",
          content: [{ type: "text" as const, text: "the answer is 42" }], isError: false, timestamp: Date.now() },
        { role: "user" as const, content: "more", timestamp: Date.now() },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");

    // Build pairing map: every function_call_output must have matching function_call
    const fcCallIds = new Set(fcs.map((f: any) => f.call_id));
    const orphanOutputs = fcOut.filter((o: any) => !fcCallIds.has(o.call_id));

    // No orphan outputs (would cause 400)
    const pairingOK = orphanOutputs.length === 0;

    // No fc_xxx id on any function_call (the bug signature)
    const noLeakedFcId = fcs.every((f: any) => !f.id || !String(f.id).startsWith("fc_"));

    // Context preserved: result text "42" must appear somewhere
    const serialized = JSON.stringify(result);
    const contextPreserved = serialized.includes("42");

    const ok = pairingOK && noLeakedFcId && contextPreserved;
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} pairingOK=${pairingOK} noLeakedFcId=${noLeakedFcId} contextPreserved=${contextPreserved} orphans=${orphanOutputs.length}`);
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
PAIREOF

OUT_3=$(run_test /tmp/pitest/pairing.ts)
echo "$OUT_3" | tail -5
if echo "$OUT_3" | grep -q "RESULT=PASS"; then
    add_reward 0.25
    echo "PASS: tool-result pairing coherent (+0.25)"
else
    echo "FAIL: tool-result pairing broken or fc_xxx leaked"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "FINAL REWARD: $REWARD"
echo "═══════════════════════════════════════════════════════════════"

echo "$REWARD" > /logs/verifier/reward.txt