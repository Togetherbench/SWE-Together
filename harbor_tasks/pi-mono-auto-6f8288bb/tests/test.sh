#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono || { echo "0.0" > "$REWARD_FILE"; exit 0; }

REWARD=0
TOTAL=0

# Helper: run a vitest test file from the ai package
run_vitest() {
    local testfile="$1"
    (cd packages/ai && npx vitest --run "$testfile" 2>&1)
}

# ═══════════════════════════════════════════════════════════════════
# P2P 1 (0.05): TypeScript compilation
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P 1: TypeScript compilation ==="
P2P1=0
if npx tsgo --noEmit 2>&1 | tail -50; [ ${PIPESTATUS[0]} -eq 0 ]; then
    P2P1=1
elif npx tsc --noEmit 2>&1 | tail -50; [ ${PIPESTATUS[0]} -eq 0 ]; then
    P2P1=1
fi
echo "P2P1=$P2P1"

# ═══════════════════════════════════════════════════════════════════
# P2P 2 (0.05): Existing tool-choice tests still pass
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P 2: Existing tests still pass ==="
P2P2=0
if run_vitest test/openai-completions-tool-choice.test.ts | tail -40; [ ${PIPESTATUS[0]} -eq 0 ]; then
    P2P2=1
fi
echo "P2P2=$P2P2"

# ═══════════════════════════════════════════════════════════════════
# Build a reusable behavioral test harness using vitest
# Tests qwen/qwen3-32b and openai/gpt-oss-20b with various reasoning levels
# ═══════════════════════════════════════════════════════════════════
HARNESS=packages/ai/test/_issue1745_harness.test.ts
cat > "$HARNESS" << 'TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as any }));

vi.mock("openai", () => {
    class FakeOpenAI {
        chat = {
            completions: {
                create: async (params: any) => {
                    mockState.lastParams = params;
                    return {
                        async *[Symbol.asyncIterator]() {
                            yield {
                                choices: [{ delta: {}, finish_reason: "stop" }],
                                usage: {
                                    prompt_tokens: 1,
                                    completion_tokens: 1,
                                    prompt_tokens_details: { cached_tokens: 0 },
                                    completion_tokens_details: { reasoning_tokens: 0 },
                                },
                            };
                        },
                    };
                },
            },
        };
    }
    return { default: FakeOpenAI };
});

async function capture(provider: string, modelId: string, reasoning: any): Promise<any> {
    mockState.lastParams = undefined;
    const model = getModel(provider, modelId);
    if (!model) throw new Error(`model not found: ${provider}/${modelId}`);
    let payload: any;
    const opts: any = {
        apiKey: "test",
        onPayload: (p: any) => { payload = p; },
    };
    if (reasoning !== undefined) opts.reasoning = reasoning;
    await streamSimple(
        model,
        { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
        opts,
    ).result();
    return payload ?? mockState.lastParams;
}

describe("issue 1745 behavioral", () => {
    it("QWEN_MEDIUM", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "medium");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_HIGH", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "high");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_LOW", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "low");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_MINIMAL", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "minimal");
        expect(p.reasoning_effort).toBe("default");
    });
    it("GPTOSS_HIGH_UNCHANGED", async () => {
        const p = await capture("groq", "openai/gpt-oss-20b", "high");
        expect(p.reasoning_effort).toBe("high");
    });
    it("GPTOSS_MEDIUM_UNCHANGED", async () => {
        const p = await capture("groq", "openai/gpt-oss-20b", "medium");
        expect(p.reasoning_effort).toBe("medium");
    });
    it("GPTOSS_LOW_UNCHANGED", async () => {
        const p = await capture("groq", "openai/gpt-oss-20b", "low");
        expect(p.reasoning_effort).toBe("low");
    });
});
TESTEOF

echo "=== Running behavioral harness ==="
HARNESS_OUT=$(run_vitest test/_issue1745_harness.test.ts 2>&1)
echo "$HARNESS_OUT" | tail -80

count_pass() {
    local name="$1"
    # vitest prints "✓ ... > NAME" on pass; check for both pass marker and the test name
    if echo "$HARNESS_OUT" | grep -E "(✓|PASS|√).*${name}" > /dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

# Behavioral results
QWEN_MEDIUM=$(count_pass "QWEN_MEDIUM")
QWEN_HIGH=$(count_pass "QWEN_HIGH")
QWEN_LOW=$(count_pass "QWEN_LOW")
QWEN_MINIMAL=$(count_pass "QWEN_MINIMAL")
GPTOSS_HIGH=$(count_pass "GPTOSS_HIGH_UNCHANGED")
GPTOSS_MEDIUM=$(count_pass "GPTOSS_MEDIUM_UNCHANGED")
GPTOSS_LOW=$(count_pass "GPTOSS_LOW_UNCHANGED")

# Cleanup harness
rm -f "$HARNESS"

echo "QWEN_MEDIUM=$QWEN_MEDIUM"
echo "QWEN_HIGH=$QWEN_HIGH"
echo "QWEN_LOW=$QWEN_LOW"
echo "QWEN_MINIMAL=$QWEN_MINIMAL"
echo "GPTOSS_HIGH=$GPTOSS_HIGH"
echo "GPTOSS_MEDIUM=$GPTOSS_MEDIUM"
echo "GPTOSS_LOW=$GPTOSS_LOW"

# ═══════════════════════════════════════════════════════════════════
# Structural: docs were updated to mention the qwen3 / reasoning_effort behavior
# ═══════════════════════════════════════════════════════════════════
echo "=== Structural: docs updated ==="
DOCS=packages/coding-agent/docs/custom-provider.md
DOC_HIT=0
if [ -f "$DOCS" ]; then
    # Look for any mention indicating awareness of the qwen3 / groq reasoning effort restriction
    if grep -Eqi "(qwen.*qwen3|qwen3-32b|reasoningEffortMap)" "$DOCS"; then
        if grep -Eqi "(default|none|groq)" "$DOCS"; then
            DOC_HIT=1
        fi
    fi
fi
echo "DOC_HIT=$DOC_HIT"

# ═══════════════════════════════════════════════════════════════════
# Structural: source actually contains a per-model gate (not provider-wide)
# Look for the openai-completions provider source that conditions the map
# on a model.id check (qwen3-32b specifically) rather than just isGroq.
# ═══════════════════════════════════════════════════════════════════
echo "=== Structural: targeted model gate in source ==="
SRC=packages/ai/src/providers/openai-completions.ts
SRC_HIT=0
if [ -f "$SRC" ]; then
    # Either explicit qwen/qwen3-32b reference, or a non-trivial gate that excludes openai/* models
    if grep -Eq 'qwen/qwen3-32b|qwen3-32b' "$SRC"; then
        SRC_HIT=1
    elif grep -Eq 'startsWith\("openai/"\)|!== "openai/"|model\.id\.startsWith\("qwen' "$SRC"; then
        SRC_HIT=1
    fi
fi
echo "SRC_HIT=$SRC_HIT"

# ═══════════════════════════════════════════════════════════════════
# Compute reward
# Weights:
#   P2P1 = 0.05 (compile)
#   P2P2 = 0.05 (existing tests)
#   QWEN behavioral (4 tests) = 0.10 each = 0.40
#   GPT-OSS behavioral (3 tests) = 0.08 each = 0.24
#   DOC_HIT = 0.13
#   SRC_HIT = 0.08
# Total = 0.05 + 0.05 + 0.40 + 0.24 + 0.13 + 0.08 = 0.95
# Plus 0.05 base if at least the qwen-medium gate passes (the canonical test from issue)
# ═══════════════════════════════════════════════════════════════════

REWARD=$(awk -v p1=$P2P1 -v p2=$P2P2 \
    -v qm=$QWEN_MEDIUM -v qh=$QWEN_HIGH -v ql=$QWEN_LOW -v qmin=$QWEN_MINIMAL \
    -v gh=$GPTOSS_HIGH -v gm=$GPTOSS_MEDIUM -v gl=$GPTOSS_LOW \
    -v doc=$DOC_HIT -v src=$SRC_HIT \
    'BEGIN {
        r = p1*0.05 + p2*0.05 \
          + qm*0.10 + qh*0.10 + ql*0.10 + qmin*0.10 \
          + gh*0.08 + gm*0.08 + gl*0.08 \
          + doc*0.13 + src*0.08;
        if (r > 1.0) r = 1.0;
        printf "%.4f", r;
    }')

echo ""
echo "================================"
echo "FINAL REWARD: $REWARD"
echo "  P2P1 (compile)          = $P2P1  [0.05]"
echo "  P2P2 (existing tests)   = $P2P2  [0.05]"
echo "  QWEN_MEDIUM             = $QWEN_MEDIUM  [0.10]"
echo "  QWEN_HIGH               = $QWEN_HIGH  [0.10]"
echo "  QWEN_LOW                = $QWEN_LOW  [0.10]"
echo "  QWEN_MINIMAL            = $QWEN_MINIMAL  [0.10]"
echo "  GPTOSS_HIGH (unchanged) = $GPTOSS_HIGH  [0.08]"
echo "  GPTOSS_MEDIUM (unchang) = $GPTOSS_MEDIUM  [0.08]"
echo "  GPTOSS_LOW (unchanged)  = $GPTOSS_LOW  [0.08]"
echo "  DOC_HIT                 = $DOC_HIT  [0.13]"
echo "  SRC_HIT                 = $SRC_HIT  [0.08]"
echo "================================"

echo "$REWARD" > "$REWARD_FILE"
exit 0