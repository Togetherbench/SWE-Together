#!/bin/bash
set +e

cd /workspace/pi-mono
FILE="packages/ai/src/providers/openai-responses.ts"
TESTABLE="packages/ai/src/providers/openai-responses-testable.ts"
mkdir -p /logs/verifier

# Fix git safe directory issue
git config --global --add safe.directory /workspace/pi-mono 2>/dev/null || true

REWARD=0

# Helper: add to reward (integer, out of 100)
add_reward() { REWARD=$((REWARD + $1)); }

# ═══════════════════════════════════════════════════════════════
# Create testable copy with convertMessages exported for
# behavioral testing. The agent never sees this file.
# ═══════════════════════════════════════════════════════════════
cp "$FILE" "$TESTABLE"
sed -i 's/^function convertMessages/export function convertMessages/' "$TESTABLE"

# ═══════════════════════════════════════════════════════════════
# Gate 0 [P2P]: TypeScript compilation (5%)
# Passes on both unmodified base and correct fix.
# Guards against agent-introduced type errors.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 0 [P2P]: TypeScript compilation ---"
G0=0
if (cd packages/ai && npx tsc --noEmit -p tsconfig.build.json 2>/tmp/tsc_errors.txt); then
    G0=1
    add_reward 5
    echo "PASS: TypeScript compiles (+0.05)"
else
    echo "FAIL: TypeScript compilation errors:"
    tail -20 /tmp/tsc_errors.txt
fi

# ═══════════════════════════════════════════════════════════════
# Gate 1 [P2P]: Same-model messages preserved (5%)
# Behavioral: calls convertMessages with same-model data and
# verifies reasoning + function_call pair is preserved.
# Passes on both base and fix (base handles same-model correctly).
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 1 [P2P]: Same-model reasoning+function_call preserved ---"
G1=0

cat > /tmp/test_same_model.ts << 'SAMEEOF'
import { convertMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-testable.ts";

const model = {
    id: "codex-mini",
    name: "codex-mini",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

const context = {
    messages: [
        {
            role: "user" as const,
            content: "Hello",
            timestamp: Date.now(),
        },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "Let me search",
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
            model: "codex-mini",
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

const result = convertMessages(model, context);
const fcs = result.filter((item: any) => item.type === "function_call");
const reasoning = result.filter((item: any) => item.type === "reasoning");

// Same model: MUST have both reasoning and function_call
if (fcs.length > 0 && reasoning.length > 0) {
    console.log("SAME_MODEL=PASS");
} else {
    console.log("SAME_MODEL=FAIL");
    console.log("  fcs=" + fcs.length + " reasoning=" + reasoning.length);
}
SAMEEOF

SAME_RESULT=$(bun /tmp/test_same_model.ts 2>/dev/null)
echo "  Result: $SAME_RESULT"

if echo "$SAME_RESULT" | grep -q "SAME_MODEL=PASS"; then
    G1=1
    add_reward 5
    echo "PASS: Same-model reasoning+function_call preserved (+0.05)"
else
    echo "FAIL: Same-model messages not properly preserved"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 2 [F2P]: Cross-model function_call handling (35%)
# Behavioral: calls convertMessages with cross-model data
# (same provider openai, different model). Verifies that
# function_call items do NOT have orphaned fc_ IDs without
# paired reasoning items.
# FAILS on base code (fc_ id present without reasoning).
# PASSES on correct fix (id set to undefined or reasoning added).
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 2 [F2P]: Cross-model function_call handling ---"
G2=0

cat > /tmp/test_cross_model.ts << 'CROSSEOF'
import { convertMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-testable.ts";

const model = {
    id: "codex-mini",
    name: "codex-mini",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

// Cross-model: assistant from gpt-4o, current model is codex-mini
const context = {
    messages: [
        {
            role: "user" as const,
            content: "Hello",
            timestamp: Date.now(),
        },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "I should search for that",
                    thinkingSignature: JSON.stringify({
                        type: "reasoning",
                        id: "rs_crossabc",
                        summary: [{ type: "summary_text", text: "thinking" }],
                    }),
                },
                {
                    type: "toolCall" as const,
                    id: "call_cross|fc_crossabc",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "gpt-4o",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "call_cross|fc_crossabc",
            toolName: "search",
            content: [{ type: "text" as const, text: "result data" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convertMessages(model, context);
    const fcs = result.filter((item: any) => item.type === "function_call");
    const reasoning = result.filter((item: any) => item.type === "reasoning");

    // Check for orphaned fc_ IDs (fc_ id without paired reasoning)
    let hasOrphanedFc = false;
    for (const fc of fcs) {
        const fcId = (fc as any).id;
        if (fcId !== undefined && String(fcId).startsWith("fc_")) {
            const hasPairedReasoning = reasoning.some((r: any) =>
                r.id && String(fcId).replace(/^fc_/, "rs_") === r.id
            );
            if (!hasPairedReasoning) {
                hasOrphanedFc = true;
            }
        }
    }

    // PASS if no orphaned fc_ ids
    // Accepts: id=undefined, id without fc_ prefix, or paired reasoning present
    // Also accepts: function_call converted to message output (alternative fix)
    const outputItems = result.filter((item: any) =>
        item.type === "function_call" || item.type === "message" || item.type === "reasoning"
    );

    if (!hasOrphanedFc && outputItems.length > 0) {
        console.log("CROSS_MODEL=PASS");
    } else if (hasOrphanedFc) {
        console.log("CROSS_MODEL=FAIL_ORPHAN");
    } else {
        console.log("CROSS_MODEL=FAIL_EMPTY");
    }
} catch (e: any) {
    console.log("CROSS_MODEL=ERROR:" + String(e.message || e).substring(0, 100));
}
CROSSEOF

CROSS_RESULT=$(bun /tmp/test_cross_model.ts 2>/dev/null)
echo "  Result: $CROSS_RESULT"

if echo "$CROSS_RESULT" | grep -q "CROSS_MODEL=PASS"; then
    G2=1
    add_reward 35
    echo "PASS: Cross-model function_call handling correct (+0.35)"
else
    echo "FAIL: Cross-model function_calls have orphaned fc_ IDs"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 3 [F2P]: Cross-provider (Anthropic→OpenAI) handling (15%)
# Behavioral: assistant message from Anthropic model, current
# model is OpenAI Responses. Verifies function_call IDs are
# handled properly for cross-provider scenario.
# FAILS on base (normalizeToolCallId adds fc_ prefix to
# non-OpenAI IDs, creating orphaned fc_ without reasoning).
# PASSES on correct fix.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 3 [F2P]: Cross-provider function_call handling ---"
G3=0

cat > /tmp/test_cross_provider.ts << 'CPEOF'
import { convertMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-testable.ts";

const model = {
    id: "codex-mini",
    name: "codex-mini",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

// Cross-provider: assistant from claude-sonnet (Anthropic)
const context = {
    messages: [
        {
            role: "user" as const,
            content: "Hello",
            timestamp: Date.now(),
        },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "I should use the search tool",
                },
                {
                    type: "toolCall" as const,
                    id: "toolu_abc123|item_xyz",
                    name: "search",
                    arguments: { query: "test" },
                },
            ],
            model: "claude-sonnet-4-5-20250514",
            provider: "anthropic",
            api: "anthropic" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "toolUse" as const,
            timestamp: Date.now(),
        },
        {
            role: "toolResult" as const,
            toolCallId: "toolu_abc123|item_xyz",
            toolName: "search",
            content: [{ type: "text" as const, text: "result data" }],
            isError: false,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convertMessages(model, context);
    const fcs = result.filter((item: any) => item.type === "function_call");
    const reasoning = result.filter((item: any) => item.type === "reasoning");

    let hasOrphanedFc = false;
    for (const fc of fcs) {
        const fcId = (fc as any).id;
        if (fcId !== undefined && String(fcId).startsWith("fc_")) {
            const hasPairedReasoning = reasoning.some((r: any) =>
                r.id && String(fcId).replace(/^fc_/, "rs_") === r.id
            );
            if (!hasPairedReasoning) {
                hasOrphanedFc = true;
            }
        }
    }

    const outputItems = result.filter((item: any) =>
        item.type === "function_call" || item.type === "message" || item.type === "reasoning"
    );

    if (!hasOrphanedFc && outputItems.length > 0) {
        console.log("CROSS_PROVIDER=PASS");
    } else if (hasOrphanedFc) {
        console.log("CROSS_PROVIDER=FAIL_ORPHAN");
    } else {
        console.log("CROSS_PROVIDER=FAIL_EMPTY");
    }
} catch (e: any) {
    console.log("CROSS_PROVIDER=ERROR:" + String(e.message || e).substring(0, 100));
}
CPEOF

CP_RESULT=$(bun /tmp/test_cross_provider.ts 2>/dev/null)
echo "  Result: $CP_RESULT"

if echo "$CP_RESULT" | grep -q "CROSS_PROVIDER=PASS"; then
    G3=1
    add_reward 15
    echo "PASS: Cross-provider function_call handling correct (+0.15)"
else
    echo "FAIL: Cross-provider function_calls have orphaned fc_ IDs"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 4 [F2P]: function_call ID differs per model (20%)
# Behavioral: verifies that convertMessages sets the
# function_call `id` field differently for same-model vs
# cross-model assistant messages. Same-model should have
# fc_-prefixed id; cross-model should NOT.
# FAILS on base (both get fc_ id), PASSES on correct fix.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 4 [F2P]: function_call ID model-awareness ---"
G4=0

cat > /tmp/test_differential.ts << 'DIFFEOF'
import { convertMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-testable.ts";

const model = {
    id: "codex-mini",
    name: "codex-mini",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

function makeContext(aModel: string, aProvider: string, aApi: string) {
    return {
        messages: [
            { role: "user" as const, content: "Hello", timestamp: Date.now() },
            {
                role: "assistant" as const,
                content: [
                    {
                        type: "thinking" as const,
                        thinking: "reasoning text here",
                        thinkingSignature: JSON.stringify({
                            type: "reasoning",
                            id: "rs_difftest",
                            summary: [{ type: "summary_text", text: "thinking" }],
                        }),
                    },
                    {
                        type: "toolCall" as const,
                        id: "call_diff|fc_difftest",
                        name: "search",
                        arguments: { query: "test" },
                    },
                ],
                model: aModel,
                provider: aProvider,
                api: aApi as any,
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
}

try {
    // Same model: should preserve fc_ id
    const sameResult = convertMessages(model, makeContext("codex-mini", "openai", "openai-responses"));
    const sameFcs = sameResult.filter((item: any) => item.type === "function_call");
    const sameFcId = sameFcs[0] ? (sameFcs[0] as any).id : undefined;
    const sameFcHasFcPrefix = sameFcId !== undefined && String(sameFcId).startsWith("fc_");

    // Different model: should NOT have orphaned fc_ id
    const diffResult = convertMessages(model, makeContext("gpt-4o", "openai", "openai-responses"));
    const diffFcs = diffResult.filter((item: any) => item.type === "function_call");
    const diffFcId = diffFcs[0] ? (diffFcs[0] as any).id : undefined;
    const diffReasoning = diffResult.filter((item: any) => item.type === "reasoning");

    // Cross-model fc must NOT have fc_ prefix (unless paired with reasoning)
    const diffFcSafe = (
        diffFcId === undefined ||
        !String(diffFcId).startsWith("fc_") ||
        diffReasoning.some((r: any) => r.id && String(diffFcId).replace(/^fc_/, "rs_") === r.id)
    );
    // Also accept: function_call converted to message (alternative fix)
    const diffConvertedToMsg = diffFcs.length === 0 &&
        diffResult.some((item: any) => item.type === "message" && (item as any).role === "assistant");

    if (sameFcHasFcPrefix && (diffFcSafe || diffConvertedToMsg)) {
        console.log("DIFFERENTIAL=PASS");
    } else {
        console.log("DIFFERENTIAL=FAIL");
        console.log("  sameFcId=" + sameFcId + " diffFcId=" + diffFcId);
    }
} catch (e: any) {
    console.log("DIFFERENTIAL=ERROR:" + String(e.message || e).substring(0, 100));
}
DIFFEOF

DIFF_RESULT=$(bun /tmp/test_differential.ts 2>/dev/null)
echo "  Result: $DIFF_RESULT"

if echo "$DIFF_RESULT" | grep -q "DIFFERENTIAL=PASS"; then
    G4=1
    add_reward 20
    echo "PASS: function_call ID model-awareness detected (+0.20)"
else
    echo "FAIL: function_call IDs not model-aware"
fi

# ═══════════════════════════════════════════════════════════════
# Gate 5 [F2P]: Orphaned reasoning prevention (20%)
# Behavioral: same-model assistant message with ONLY a thinking
# block (no toolCall or text). The reasoning item should NOT
# be sent to the API without a following content item, as OpenAI
# rejects orphaned reasoning ("reasoning without following item").
# FAILS on base (reasoning pushed alone).
# PASSES on fix that guards reasoning replay.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Gate 5 [F2P]: Orphaned reasoning prevention ---"
G5=0

cat > /tmp/test_orphan_reasoning.ts << 'ORPHANEOF'
import { convertMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-testable.ts";

const model = {
    id: "codex-mini",
    name: "codex-mini",
    provider: "openai",
    api: "openai-responses" as const,
    input: ["text"],
    reasoning: true,
    baseUrl: "https://api.openai.com/v1",
    headers: {},
} as any;

// Same-model assistant message with ONLY a thinking block
// Simulates incomplete turn where reasoning exists but no output followed
const context = {
    messages: [
        { role: "user" as const, content: "Hello", timestamp: Date.now() },
        {
            role: "assistant" as const,
            content: [
                {
                    type: "thinking" as const,
                    thinking: "Some partial reasoning",
                    thinkingSignature: JSON.stringify({
                        type: "reasoning",
                        id: "rs_orphantest",
                        summary: [{ type: "summary_text", text: "partial" }],
                    }),
                },
            ],
            model: "codex-mini",
            provider: "openai",
            api: "openai-responses" as const,
            usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
            stopReason: "stop" as const,
            timestamp: Date.now(),
        },
    ],
};

try {
    const result = convertMessages(model, context);
    const reasoning = result.filter((item: any) => item.type === "reasoning");
    const followingContent = result.filter((item: any) =>
        item.type === "function_call" || (item.type === "message" && (item as any).role === "assistant")
    );

    // Reasoning without following content is an error — should not be produced
    if (reasoning.length > 0 && followingContent.length === 0) {
        console.log("ORPHAN_REASONING=FAIL");
    } else {
        console.log("ORPHAN_REASONING=PASS");
    }
} catch (e: any) {
    console.log("ORPHAN_REASONING=ERROR:" + String(e.message || e).substring(0, 100));
}
ORPHANEOF

ORPHAN_RESULT=$(bun /tmp/test_orphan_reasoning.ts 2>/dev/null)
echo "  Result: $ORPHAN_RESULT"

if echo "$ORPHAN_RESULT" | grep -q "ORPHAN_REASONING=PASS"; then
    G5=1
    add_reward 20
    echo "PASS: Orphaned reasoning prevention (+0.20)"
else
    echo "FAIL: Reasoning item sent without following content"
fi

# ═══════════════════════════════════════════════════════════════
# Cleanup and final score
# ═══════════════════════════════════════════════════════════════
rm -f "$TESTABLE" /tmp/test_same_model.ts /tmp/test_cross_model.ts /tmp/test_cross_provider.ts /tmp/test_differential.ts /tmp/test_orphan_reasoning.ts

echo ""
echo "=== Final Score ==="
awk "BEGIN {printf \"%.2f\n\", $REWARD/100}" > /logs/verifier/reward.txt
cat /logs/verifier/reward.txt
echo "Breakdown: G0(P2P:tsc)=$G0 G1(P2P:same-model)=$G1 G2(F2P:cross-model)=$G2 G3(F2P:cross-provider)=$G3 G4(F2P:differential)=$G4 G5(F2P:orphan-reasoning)=$G5"
