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

SHARED="packages/ai/src/providers/openai-responses-shared.ts"
RESPONSES="packages/ai/src/providers/openai-responses.ts"

# ═══════════════════════════════════════════════════════════════
# Gate 0 [P2P]: TypeScript compilation (15%)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 0 [P2P]: TypeScript compilation (0.15) ---"
G0=0
if (cd packages/ai && npx tsc --noEmit -p tsconfig.build.json 2>/tmp/tsc_errors.txt); then
    G0=1
    add_reward 0.15
    echo "PASS: TypeScript compiles (+0.15)"
else
    echo "FAIL: TypeScript compilation errors:"
    tail -30 /tmp/tsc_errors.txt
fi

# ═══════════════════════════════════════════════════════════════
# Gate 1 [Structural]: strictResponsesPairing flag is no longer required (10%)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 1 [Structural]: behavior NOT gated on strictResponsesPairing (0.10) ---"
G1=0
GATED=0
for f in "$SHARED" "$RESPONSES"; do
    if [ -f "$f" ]; then
        if grep -E "if\s*\(.*strictResponsesPairing" "$f" >/dev/null 2>&1; then
            GATED=$((GATED + 1))
        fi
        if grep -E "\?\s*.*strictResponsesPairing" "$f" >/dev/null 2>&1; then
            GATED=$((GATED + 1))
        fi
    fi
done
if [ "$GATED" -eq 0 ]; then
    G1=1
    add_reward 0.10
    echo "PASS: No conditional gating on strictResponsesPairing (+0.10)"
else
    echo "FAIL: Behavior still gated on strictResponsesPairing flag in $GATED location(s)"
fi

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
# Gate 2 [P2P Behavioral]: Same-model reasoning + function_call preserved (15%)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 2 [P2P Behavioral]: Same-model reasoning + function_call preserved (0.15) ---"

cat > /tmp/pitest/same_model.ts << 'SAMEEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";

const convert = await loadConvert();

const model = {
    id: "gpt-5-codex",
    name: "gpt-5-codex",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "thinking",
                    thinkingSignature: JSON.stringify({
                        type: "reasoning",
                        id: "rs_sametest",
                        summary: [{ type: "summary_text", text: "thinking" }],
                    }),
                },
                {
                    type: "toolCall" as const,
                    id: "call_same|fc_sametest",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "gpt-5-codex",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "call_same|fc_sametest",
            toolName: "search",
            content: [{ type: "text" as const, text: "result" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const reasoning = result.filter((i: any) => i.type === "reasoning");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");

    let fcHasFcId = false;
    for (const fc of fcs) {
        if ((fc as any).id && String((fc as any).id).startsWith("fc_")) {
            fcHasFcId = true;
        }
    }

    const ok = reasoning.length >= 1 && fcs.length >= 1 && fcOut.length >= 1 && fcHasFcId;
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} reasoning=${reasoning.length} fcs=${fcs.length} fcOut=${fcOut.length} fcHasFcId=${fcHasFcId}`);
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
SAMEEOF

OUT=$(run_test /tmp/pitest/same_model.ts)
echo "$OUT" | tail -5
G2=0
if echo "$OUT" | grep -q "RESULT=PASS"; then
    G2=1
    add_reward 0.15
    echo "PASS: Same-model preserved reasoning + fc_xxx id (+0.15)"
else
    echo "FAIL: Same-model behavior broken"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 3 [F2P Behavioral - CORE FIX]: Different-model same-provider handoff
# (25% - this IS the bug)
#
# When an assistant message has provider==model.provider, api==model.api,
# but a different model.id, the fc_xxx item id MUST be cleared (set to
# undefined or omitted) because the rs_xxx reasoning item was stripped
# by transformMessages and replaying fc_xxx without its paired rs_xxx
# triggers a 400. The function_call must still be present so that
# function_call_output can pair via call_id.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 3 [F2P CORE]: Different-model handoff clears fc_xxx (0.25) ---"

cat > /tmp/pitest/diff_model.ts << 'DIFFEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";

const convert = await loadConvert();

// Target model: different model.id, same provider+api
const model = {
    id: "gpt-5-codex",
    name: "gpt-5-codex",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            // Different model.id from target. Note: in real flow, transformMessages
            // strips thinkingSignature from cross-model messages. Simulate that.
            content: [
                {
                    type: "thinking" as const,
                    thinking: "thinking",
                    // No thinkingSignature — transformMessages stripped it
                },
                {
                    type: "toolCall" as const,
                    id: "call_diff|fc_difftest",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "gpt-5-mini",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "call_diff|fc_difftest",
            toolName: "search",
            content: [{ type: "text" as const, text: "result" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const reasoning = result.filter((i: any) => i.type === "reasoning");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");
    const assistantMsgs = result.filter((i: any) => i.role === "assistant" || i.type === "message");

    // CORE: no rs_xxx replayed because no signature
    const noOrphanReasoning = reasoning.length === 0;

    // CORE: tool result must be reachable somehow.
    // Two valid strategies:
    //   (a) Keep function_call but clear fc_xxx id; emit function_call_output (call_id pairs)
    //   (b) Convert tool call to assistant text + tool result to user text
    let strategyA = false;
    let strategyB = false;

    if (fcs.length >= 1) {
        // Strategy A: function_call exists, but its id must NOT be a leaky fc_xxx
        // that was paired with a missing rs_xxx
        const fcIds = fcs.map((fc: any) => fc.id);
        const noLeakyFcId = fcIds.every((id: any) => !id || !String(id).startsWith("fc_"));
        const callIdPreserved = fcs.some((fc: any) => fc.call_id === "call_diff");
        const hasFcOut = fcOut.some((o: any) => o.call_id === "call_diff");
        strategyA = noLeakyFcId && callIdPreserved && hasFcOut;
    } else {
        // Strategy B: no function_call at all → must have text describing the tool call
        // and the tool result, sent as messages
        const allText = JSON.stringify(result);
        strategyB = allText.includes("search") && allText.includes("result");
    }

    const ok = noOrphanReasoning && (strategyA || strategyB);
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} noOrphanReasoning=${noOrphanReasoning} strategyA=${strategyA} strategyB=${strategyB} fcs=${fcs.length} reasoning=${reasoning.length} fcOut=${fcOut.length}`);
    if (!ok) {
        console.log("FCs:", JSON.stringify(fcs));
        console.log("Reasoning:", JSON.stringify(reasoning));
    }
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
    console.log(e.stack);
}
DIFFEOF

OUT=$(run_test /tmp/pitest/diff_model.ts)
echo "$OUT" | tail -10
G3=0
if echo "$OUT" | grep -q "RESULT=PASS"; then
    G3=1
    add_reward 0.25
    echo "PASS: Different-model handoff handled correctly (+0.25)"
else
    echo "FAIL: Different-model handoff still broken"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 4 [F2P Behavioral]: Same-model with missing thinkingSignature (15%)
# When thinkingSignature is missing on same-model (e.g., never persisted,
# or stream cut), fc_xxx must also be cleared because there's no rs_xxx
# to pair with.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 4 [F2P]: Same-model missing thinkingSignature handled (0.15) ---"

cat > /tmp/pitest/missing_sig.ts << 'MISSEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";

const convert = await loadConvert();

const model = {
    id: "gpt-5-codex",
    name: "gpt-5-codex",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "thinking",
                    // signature missing
                },
                {
                    type: "toolCall" as const,
                    id: "call_miss|fc_misssig",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "gpt-5-codex",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "call_miss|fc_misssig",
            toolName: "search",
            content: [{ type: "text" as const, text: "result" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const reasoning = result.filter((i: any) => i.type === "reasoning");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");

    // No reasoning emitted (no signature)
    const noOrphanReasoning = reasoning.length === 0;

    // No fc_xxx id leak (would orphan the rs_xxx pairing)
    const fcIds = fcs.map((fc: any) => fc.id);
    const noLeakyFcId = fcIds.every((id: any) => !id || !String(id).startsWith("fc_"));

    // Tool round-trip preserved (either via function_call+output or text-conversion)
    let roundTrip = false;
    if (fcs.length >= 1) {
        roundTrip = fcs.some((fc: any) => fc.call_id === "call_miss") &&
                    fcOut.some((o: any) => o.call_id === "call_miss");
    } else {
        const txt = JSON.stringify(result);
        roundTrip = txt.includes("search") && txt.includes("result");
    }

    const ok = noOrphanReasoning && noLeakyFcId && roundTrip;
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} noOrphanReasoning=${noOrphanReasoning} noLeakyFcId=${noLeakyFcId} roundTrip=${roundTrip} fcs=${fcs.length}`);
    if (!ok) console.log("FCs:", JSON.stringify(fcs));
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
MISSEOF

OUT=$(run_test /tmp/pitest/missing_sig.ts)
echo "$OUT" | tail -5
G4=0
if echo "$OUT" | grep -q "RESULT=PASS"; then
    G4=1
    add_reward 0.15
    echo "PASS: Missing thinkingSignature handled (+0.15)"
else
    echo "FAIL: Missing thinkingSignature not handled"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 5 [P2P]: Cross-provider tool calls still work (10%)
# Synthetic fc_<hash> IDs from cross-provider must NOT trigger any
# pairing-related dropping/clearing that breaks the replay.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 5 [P2P]: Cross-provider tool round-trip preserved (0.10) ---"

cat > /tmp/pitest/cross_provider.ts << 'CROSSEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";

const convert = await loadConvert();

const model = {
    id: "gpt-5-codex",
    name: "gpt-5-codex",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "toolCall" as const,
                    id: "call_xprov|tooluse_anthropic_xyz",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "claude-3-7",
            provider: "anthropic",
            api: "anthropic-messages" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "call_xprov|tooluse_anthropic_xyz",
            toolName: "search",
            content: [{ type: "text" as const, text: "result" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convert(model, context);
    const fcs = result.filter((i: any) => i.type === "function_call");
    const fcOut = result.filter((i: any) => i.type === "function_call_output");

    // Cross-provider tool round-trip should still happen one way or another.
    let ok = false;
    if (fcs.length >= 1 && fcOut.length >= 1) {
        // Strategy A: function_call + function_call_output paired
        ok = fcs.some((fc: any) => fc.call_id === "call_xprov") &&
             fcOut.some((o: any) => o.call_id === "call_xprov");
    } else {
        // Strategy B: text-converted, but the round-trip context must be present
        const txt = JSON.stringify(result);
        ok = txt.includes("search") && txt.includes("result");
    }

    console.log(`RESULT=${ok ? "PASS" : "FAIL"} fcs=${fcs.length} fcOut=${fcOut.length}`);
    if (!ok) console.log("Result:", JSON.stringify(result, null, 2));
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
CROSSEOF

OUT=$(run_test /tmp/pitest/cross_provider.ts)
echo "$OUT" | tail -5
G5=0
if echo "$OUT" | grep -q "RESULT=PASS"; then
    G5=1
    add_reward 0.10
    echo "PASS: Cross-provider tool round-trip preserved (+0.10)"
else
    echo "FAIL: Cross-provider regression"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 6 [P2P]: Plain text assistant message still works (5%)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 6 [P2P]: Plain text assistant preserved (0.05) ---"

cat > /tmp/pitest/plain.ts << 'PLAINEOF'
import { loadConvert } from "/tmp/pitest/harness.ts";

const convert = await loadConvert();

const model = {
    id: "gpt-5-codex",
    name: "gpt-5-codex",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: false,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        { role: "user" as const, content: "Hi", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [{ type: "text" as const, text: "Hello there!" }],
            model: "gpt-5-codex",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "stop" as const,
            timestamp: Date.now(),
        },
        { role: "user" as const, content: "Bye", timestamp: Date.now() },
    ],
};

try {
    const result = convert(model, context);
    const txt = JSON.stringify(result);
    const ok = txt.includes("Hello there!") && result.length >= 2;
    console.log(`RESULT=${ok ? "PASS" : "FAIL"} length=${result.length}`);
} catch (e: any) {
    console.log(`RESULT=FAIL error=${e.message}`);
}
PLAINEOF

OUT=$(run_test /tmp/pitest/plain.ts)
echo "$OUT" | tail -5
G6=0
if echo "$OUT" | grep -q "RESULT=PASS"; then
    G6=1
    add_reward 0.05
    echo "PASS: Plain text preserved (+0.05)"
else
    echo "FAIL: Plain text regression"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 7 [Structural]: Code change actually addresses the issue (5%)
# Look for evidence that the fix touches the relevant convert function
# beyond trivially removing the flag.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 7 [Structural]: Convert function modified (0.05) ---"
G7=0
SIGNALS=0
for f in "$SHARED" "$RESPONSES"; do
    if [ -f "$f" ]; then
        # Look for evidence of new pairing logic
        if grep -E "(hasPairedContent|hasFollowingContent|hasReplayableReasoning|hasThinkingSignature|reasoningEmittedInTurn|pendingReasoning|emittedCallIds|textConvertedCallIds|isSameProviderApi|hasIncompleteReasoning)" "$f" >/dev/null 2>&1; then
            SIGNALS=$((SIGNALS + 1))
        fi
        # Or the old isDifferentModel is now used to clear ids by default
        if grep -E "isDifferentModel" "$f" >/dev/null 2>&1 && grep -E "itemId\s*=\s*undefined" "$f" >/dev/null 2>&1; then
            SIGNALS=$((SIGNALS + 1))
        fi
    fi
done
if [ "$SIGNALS" -ge 1 ]; then
    G7=1
    add_reward 0.05
    echo "PASS: Convert function shows fix-related changes (+0.05)"
else
    echo "FAIL: No fix signals in convert functions"
fi

# ═══════════════════════════════════════════════════════════════
# Final
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════"
echo "Gate 0 (TS compile, 0.15):           $G0"
echo "Gate 1 (no flag gating, 0.10):       $G1"
echo "Gate 2 (same-model, 0.15):           $G2"
echo "Gate 3 (diff-model CORE, 0.25):      $G3"
echo "Gate 4 (missing sig, 0.15):          $G4"
echo "Gate 5 (cross-provider, 0.10):       $G5"
echo "Gate 6 (plain text, 0.05):           $G6"
echo "Gate 7 (structural change, 0.05):    $G7"
echo "═══════════════════════════════════════════════"
echo "TOTAL REWARD: $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt

exit 0