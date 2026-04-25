#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono || { echo "0.0" > "$REWARD_FILE"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# P2P GATE: TypeScript compilation must pass
# (gating only — no reward weight, since this passes on base)
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P GATE: TypeScript compilation ==="
COMPILE_OK=0
if npx tsgo --noEmit 2>&1 | tail -30; [ ${PIPESTATUS[0]} -eq 0 ]; then
    COMPILE_OK=1
elif npx tsc --noEmit 2>&1 | tail -30; [ ${PIPESTATUS[0]} -eq 0 ]; then
    COMPILE_OK=1
fi
if [ "$COMPILE_OK" -ne 1 ]; then
    echo "TypeScript compilation failed — regression"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# P2P GATE: Existing tool-choice tests must still pass
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P GATE: existing tests ==="
EXISTING_OUT=$(cd packages/ai && npx vitest --run test/openai-completions-tool-choice.test.ts 2>&1)
echo "$EXISTING_OUT" | tail -30
if ! echo "$EXISTING_OUT" | grep -Eq "Tests +.*passed"; then
    # Vitest summary not found or failed
    if echo "$EXISTING_OUT" | grep -Eqi "(failed|FAIL )"; then
        echo "Existing tests broken — regression"
        echo "0.0" > "$REWARD_FILE"
        exit 0
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# Build behavioral test harness
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

describe("issue1745", () => {
    it("QWEN_MEDIUM_MAPS_TO_DEFAULT", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "medium");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_HIGH_MAPS_TO_DEFAULT", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "high");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_LOW_MAPS_TO_DEFAULT", async () => {
        const p = await capture("groq", "qwen/qwen3-32b", "low");
        expect(p.reasoning_effort).toBe("default");
    });
    it("QWEN_MINIMAL_MAPS_TO_DEFAULT", async () => {
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
HARNESS_OUT=$(cd packages/ai && npx vitest --run test/_issue1745_harness.test.ts 2>&1)
echo "$HARNESS_OUT" | tail -100

check_pass() {
    local name="$1"
    if echo "$HARNESS_OUT" | grep -E "(✓|√).*${name}" > /dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

QWEN_MEDIUM=$(check_pass "QWEN_MEDIUM_MAPS_TO_DEFAULT")
QWEN_HIGH=$(check_pass "QWEN_HIGH_MAPS_TO_DEFAULT")
QWEN_LOW=$(check_pass "QWEN_LOW_MAPS_TO_DEFAULT")
QWEN_MINIMAL=$(check_pass "QWEN_MINIMAL_MAPS_TO_DEFAULT")
GPTOSS_HIGH=$(check_pass "GPTOSS_HIGH_UNCHANGED")
GPTOSS_MEDIUM=$(check_pass "GPTOSS_MEDIUM_UNCHANGED")
GPTOSS_LOW=$(check_pass "GPTOSS_LOW_UNCHANGED")

rm -f "$HARNESS"

echo "QWEN_MEDIUM=$QWEN_MEDIUM"
echo "QWEN_HIGH=$QWEN_HIGH"
echo "QWEN_LOW=$QWEN_LOW"
echo "QWEN_MINIMAL=$QWEN_MINIMAL"
echo "GPTOSS_HIGH=$GPTOSS_HIGH"
echo "GPTOSS_MEDIUM=$GPTOSS_MEDIUM"
echo "GPTOSS_LOW=$GPTOSS_LOW"

# ═══════════════════════════════════════════════════════════════════
# F2P: Documentation update
# Base file does not mention reasoningEffortMap with qwen3-32b context.
# Verify by checking that DOC change is genuine vs base.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P: docs updated ==="
DOCS=packages/coding-agent/docs/custom-provider.md
DOC_F2P=0
if [ -f "$DOCS" ]; then
    # Must reference the qwen3 model AND the restricted effort behavior (default/none/restricted)
    if grep -Eqi "qwen3-32b|qwen/qwen3" "$DOCS" && \
       grep -Eqi "(reasoningEffortMap|reasoning_effort)" "$DOCS" && \
       grep -Eqi "(default|restrict|only accept|none)" "$DOCS"; then
        DOC_F2P=1
    fi
fi
echo "DOC_F2P=$DOC_F2P"

# ═══════════════════════════════════════════════════════════════════
# Compute reward
# F2P weights sum to 1.0:
#   QWEN behavioral (4 tests): 4 × 0.18 = 0.72
#   GPT-OSS behavioral (3 tests): 3 × 0.06 = 0.18
#   DOC F2P: 0.10
# Total: 0.72 + 0.18 + 0.10 = 1.00
# ═══════════════════════════════════════════════════════════════════

REWARD=$(awk -v qm=$QWEN_MEDIUM -v qh=$QWEN_HIGH -v ql=$QWEN_LOW -v qmin=$QWEN_MINIMAL \
    -v gh=$GPTOSS_HIGH -v gm=$GPTOSS_MEDIUM -v gl=$GPTOSS_LOW \
    -v doc=$DOC_F2P \
    'BEGIN {
        r = qm*0.18 + qh*0.18 + ql*0.18 + qmin*0.18 \
          + gh*0.06 + gm*0.06 + gl*0.06 \
          + doc*0.10;
        if (r > 1.0) r = 1.0;
        if (r < 0.0) r = 0.0;
        printf "%.4f", r;
    }')

echo "REWARD=$REWARD"
echo "$REWARD" > "$REWARD_FILE"