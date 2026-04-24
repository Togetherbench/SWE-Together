#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

cd /workspace/pi-mono

# ═══════════════════════════════════════════════════════════════════
# P2P Test 1 (weight: 0.05): TypeScript compilation
# Passes on unmodified base AND on correct fix. Guards regressions.
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P Test 1: TypeScript compilation ==="
P2P1=0
if npx tsgo --noEmit 2>&1; then
    P2P1=1
    echo "PASS: TypeScript compilation"
elif npx tsc --noEmit 2>&1; then
    P2P1=1
    echo "PASS: TypeScript compilation (tsc fallback)"
else
    echo "FAIL: TypeScript compilation"
fi

# ═══════════════════════════════════════════════════════════════════
# P2P Test 2 (weight: 0.05): Existing tests still pass
# Passes on unmodified base AND on correct fix. Guards regressions.
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P Test 2: Existing tests still pass ==="
P2P2=0
if cd packages/ai && npx vitest --run test/openai-completions-tool-choice.test.ts 2>&1; then
    P2P2=1
    echo "PASS: Existing tests"
else
    echo "FAIL: Existing tests broken"
fi
cd /workspace/pi-mono

# ═══════════════════════════════════════════════════════════════════
# F2P Test 1 (weight: 0.20): qwen3-32b medium -> "default"
# Fails on base: base sends "medium" raw which Groq rejects for qwen3.
# Passes after correct fix maps medium -> default for qwen3-32b.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P Test 1: Behavioral - qwen3-32b medium -> default ==="
F2P1=0
cat > /tmp/test_f2p1.test.ts << 'TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as unknown }));

vi.mock("openai", () => {
    class FakeOpenAI {
        chat = {
            completions: {
                create: async (params: unknown) => {
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

describe("qwen3-32b medium", () => {
    it("maps medium to default", async () => {
        const model = getModel("groq", "qwen/qwen3-32b")!;
        let payload: unknown;
        await streamSimple(
            model,
            { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
            { apiKey: "test", reasoning: "medium", onPayload: (p: unknown) => { payload = p; } },
        ).result();
        const params = (payload ?? mockState.lastParams) as { reasoning_effort?: string };
        expect(params.reasoning_effort).toBe("default");
    });
});
TESTEOF

cp /tmp/test_f2p1.test.ts packages/ai/test/test_f2p1.test.ts
if cd packages/ai && npx vitest --run test/test_f2p1.test.ts 2>&1; then
    F2P1=1; echo "PASS"
else
    echo "FAIL"
fi
cd /workspace/pi-mono
rm -f packages/ai/test/test_f2p1.test.ts

# ═══════════════════════════════════════════════════════════════════
# F2P Test 2 (weight: 0.20): qwen3-32b high -> "default"
# Fails on base: base sends "high" raw.
# Passes after correct fix maps high -> default for qwen3-32b.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P Test 2: Behavioral - qwen3-32b high -> default ==="
F2P2=0
cat > /tmp/test_f2p2.test.ts << 'TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as unknown }));

vi.mock("openai", () => {
    class FakeOpenAI {
        chat = {
            completions: {
                create: async (params: unknown) => {
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

describe("qwen3-32b high", () => {
    it("maps high to default", async () => {
        const model = getModel("groq", "qwen/qwen3-32b")!;
        let payload: unknown;
        await streamSimple(
            model,
            { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
            { apiKey: "test", reasoning: "high", onPayload: (p: unknown) => { payload = p; } },
        ).result();
        const params = (payload ?? mockState.lastParams) as { reasoning_effort?: string };
        expect(params.reasoning_effort).toBe("default");
    });
});
TESTEOF

cp /tmp/test_f2p2.test.ts packages/ai/test/test_f2p2.test.ts
if cd packages/ai && npx vitest --run test/test_f2p2.test.ts 2>&1; then
    F2P2=1; echo "PASS"
else
    echo "FAIL"
fi
cd /workspace/pi-mono
rm -f packages/ai/test/test_f2p2.test.ts

# ═══════════════════════════════════════════════════════════════════
# F2P Test 3 (weight: 0.10): qwen3-32b low -> "default"
# Fails on base: base sends "low" raw.
# Passes after correct fix maps low -> default for qwen3-32b.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P Test 3: Behavioral - qwen3-32b low -> default ==="
F2P3=0
cat > /tmp/test_f2p3.test.ts << 'TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as unknown }));

vi.mock("openai", () => {
    class FakeOpenAI {
        chat = {
            completions: {
                create: async (params: unknown) => {
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

describe("qwen3-32b low", () => {
    it("maps low to default", async () => {
        const model = getModel("groq", "qwen/qwen3-32b")!;
        let payload: unknown;
        await streamSimple(
            model,
            { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
            { apiKey: "test", reasoning: "low", onPayload: (p: unknown) => { payload = p; } },
        ).result();
        const params = (payload ?? mockState.lastParams) as { reasoning_effort?: string };
        expect(params.reasoning_effort).toBe("default");
    });
});
TESTEOF

cp /tmp/test_f2p3.test.ts packages/ai/test/test_f2p3.test.ts
if cd packages/ai && npx vitest --run test/test_f2p3.test.ts 2>&1; then
    F2P3=1; echo "PASS"
else
    echo "FAIL"
fi
cd /workspace/pi-mono
rm -f packages/ai/test/test_f2p3.test.ts

# ═══════════════════════════════════════════════════════════════════
# F2P-conditional Test 4 (weight: 0.25): Other Groq models unaffected
# This test PASSES on both base and correct fix (P2P-like behavior).
# Scored only when core fix is detected (F2P1 or F2P2 pass), to prevent
# nop baseline inflation. Guards against blanket fixes that break other
# models — a key discriminator between careful and naive fixes.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P-conditional Test 4: Other Groq models keep standard values ==="
F2P4=0
cat > /tmp/test_f2p4.test.ts << 'TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as unknown }));

vi.mock("openai", () => {
    class FakeOpenAI {
        chat = {
            completions: {
                create: async (params: unknown) => {
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

describe("other groq models", () => {
    it("keeps medium for openai/gpt-oss-20b", async () => {
        const model = getModel("groq", "openai/gpt-oss-20b");
        if (!model || !model.reasoning) { console.log("SKIP - model not found or no reasoning"); return; }
        let payload: unknown;
        await streamSimple(
            model,
            { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
            { apiKey: "test", reasoning: "medium", onPayload: (p: unknown) => { payload = p; } },
        ).result();
        const params = (payload ?? mockState.lastParams) as { reasoning_effort?: string };
        expect(params.reasoning_effort).toBe("medium");
    });
});
TESTEOF

cp /tmp/test_f2p4.test.ts packages/ai/test/test_f2p4.test.ts
if cd packages/ai && npx vitest --run test/test_f2p4.test.ts 2>&1; then
    F2P4=1; echo "PASS"
else
    echo "FAIL"
fi
cd /workspace/pi-mono
rm -f packages/ai/test/test_f2p4.test.ts

# Zero out F2P4 if core fix was not applied (prevents nop inflation)
CORE_FIX=$((F2P1 + F2P2))
if [ "$CORE_FIX" -eq 0 ]; then
    F2P4=0
    echo "NOTE: F2P4 zeroed — core fix not detected"
fi

# ═══════════════════════════════════════════════════════════════════
# F2P Test 5 (weight: 0.15): Documentation updated
# Fails on base: no doc changes exist.
# Passes after custom-provider.md is updated with reasoning effort info.
# Uses base commit SHA to detect changes even if agent committed.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P Test 5: Documentation updated ==="
F2P5=0
DOC_FILE="packages/coding-agent/docs/custom-provider.md"
BASE_SHA="42579dd9230a0efcf8c8805d0a26bdb2b9075e80"
if git diff "$BASE_SHA" -- "$DOC_FILE" 2>/dev/null | grep -qiE 'reasoning.?effort|reasoningEffort|reasoning_effort'; then
    F2P5=1
    echo "PASS: Documentation updated with reasoning effort info"
else
    echo "FAIL: Documentation not updated with reasoning effort info"
fi

# ═══════════════════════════════════════════════════════════════════
# SCORING
# P2P weight: 0.05 + 0.05 = 0.10 (nop baseline)
# F2P weight: 0.20 + 0.20 + 0.10 + 0.25 + 0.15 = 0.90
# Execution-based weight: 0.05 + 0.05 + 0.20 + 0.20 + 0.10 + 0.25 = 0.85 (>50%)
# Reward gates: 7 (>= 3)
# ═══════════════════════════════════════════════════════════════════
SCORE=$(awk "BEGIN { printf \"%.2f\", 0.05*$P2P1 + 0.05*$P2P2 + 0.20*$F2P1 + 0.20*$F2P2 + 0.10*$F2P3 + 0.25*$F2P4 + 0.15*$F2P5 }")

# Clamp to [0, 1]
SCORE=$(awk "BEGIN { s=$SCORE; if(s>1) s=1; if(s<0) s=0; printf \"%.2f\", s }")

echo ""
echo "===== RESULTS ====="
echo "P2P1 (TS compilation):      $P2P1  (5%)"
echo "P2P2 (existing tests):      $P2P2  (5%)"
echo "F2P1 (qwen3 medium):        $F2P1  (20%)"
echo "F2P2 (qwen3 high):          $F2P2  (20%)"
echo "F2P3 (qwen3 low):           $F2P3  (10%)"
echo "F2P4 (narrow fix check):    $F2P4  (25%)"
echo "F2P5 (docs):                $F2P5  (15%)"
echo "Total Score: $SCORE"
echo "$SCORE" > "$REWARD_FILE"
