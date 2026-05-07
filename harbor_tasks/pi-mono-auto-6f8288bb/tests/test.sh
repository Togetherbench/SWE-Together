#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"
REWARD="0.0"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || { echo "0.0" > "$REWARD_FILE"; exit 0; }

# Probe essential tools
command -v npx >/dev/null 2>&1 || { echo "npx missing"; echo "0.0" > "$REWARD_FILE"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# P2P GATE: TypeScript compilation (scoped to agent-touched .ts/.tsx files)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P GATE: TypeScript compilation (scoped) ==="
CHANGED_TS_FILES=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
COMPILE_OK=0
if [ -z "$CHANGED_TS_FILES" ]; then
    echo "No .ts/.tsx changes in agent diff — gate vacuously passes"
    COMPILE_OK=1
elif npx tsgo --noEmit $CHANGED_TS_FILES > /tmp/tsc.out 2>&1; then
    COMPILE_OK=1
elif npx tsc --noEmit $CHANGED_TS_FILES > /tmp/tsc.out 2>&1; then
    COMPILE_OK=1
fi
[ -f /tmp/tsc.out ] && tail -30 /tmp/tsc.out
if [ "$COMPILE_OK" -ne 1 ]; then
    echo "TypeScript compilation failed on agent-changed files — regression"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# P2P GATE: Existing tool-choice tests must still pass
# ═══════════════════════════════════════════════════════════════════
echo "=== P2P GATE: existing openai-completions-tool-choice tests ==="
EXISTING_OUT=$(cd packages/ai && npx vitest --run test/openai-completions-tool-choice.test.ts --reporter=verbose 2>&1)
echo "$EXISTING_OUT" | tail -50
if echo "$EXISTING_OUT" | grep -Eqi "(✗|×|failed|FAIL )" && ! echo "$EXISTING_OUT" | grep -Eq "Tests +.* passed.*\(.*\)"; then
    echo "Existing tests broken — regression"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# Build behavioral test harness
# Tests groq qwen3-32b reasoning_effort remapping behavior
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
    it("GPTOSS_MINIMAL_UNCHANGED", async () => {
        const p = await capture("groq", "openai/gpt-oss-20b", "minimal");
        expect(p.reasoning_effort).toBe("minimal");
    });
});
TESTEOF

echo "=== Running behavioral harness ==="
HARNESS_OUT=$(cd packages/ai && npx vitest --run test/_issue1745_harness.test.ts --reporter=verbose 2>&1)
echo "$HARNESS_OUT" | tail -120

check_pass() {
    local name="$1"
    if echo "$HARNESS_OUT" | grep -E "(✓|√|PASS).*${name}" > /dev/null 2>&1; then
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
GPTOSS_MINIMAL=$(check_pass "GPTOSS_MINIMAL_UNCHANGED")

rm -f "$HARNESS"

echo "QWEN_MEDIUM=$QWEN_MEDIUM"
echo "QWEN_HIGH=$QWEN_HIGH"
echo "QWEN_LOW=$QWEN_LOW"
echo "QWEN_MINIMAL=$QWEN_MINIMAL"
echo "GPTOSS_HIGH=$GPTOSS_HIGH"
echo "GPTOSS_MEDIUM=$GPTOSS_MEDIUM"
echo "GPTOSS_LOW=$GPTOSS_LOW"
echo "GPTOSS_MINIMAL=$GPTOSS_MINIMAL"

# Aggregate behavioral scores
QWEN_PASSED=$((QWEN_MEDIUM + QWEN_HIGH + QWEN_LOW + QWEN_MINIMAL))
GPTOSS_PASSED=$((GPTOSS_HIGH + GPTOSS_MEDIUM + GPTOSS_LOW + GPTOSS_MINIMAL))

# QWEN behavior is the core fix (4 cases, 0.10 each = 0.40)
QWEN_SCORE=$(awk -v n=$QWEN_PASSED 'BEGIN{printf "%.4f", n*0.10}')
# GPT-OSS preservation guards against over-broad fixes (4 cases, 0.075 each = 0.30)
GPTOSS_SCORE=$(awk -v n=$GPTOSS_PASSED 'BEGIN{printf "%.4f", n*0.075}')

# ═══════════════════════════════════════════════════════════════════
# F2P: Source code change in the right file
# Verifies the fix lives in the compat layer (not as global regex override)
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P: source change in openai-completions provider ==="
SRC=packages/ai/src/providers/openai-completions.ts
SRC_F2P=0
if [ -f "$SRC" ]; then
    # Must mention reasoningEffortMap and either qwen or groq-specific gating
    if grep -q "reasoningEffortMap" "$SRC" 2>/dev/null && \
       grep -Eqi "(qwen|isGroq)" "$SRC" 2>/dev/null; then
        # Must have at least one mapping entry to "default"
        if grep -Eq '"default"' "$SRC" 2>/dev/null; then
            SRC_F2P=1
        fi
    fi
fi
echo "SRC_F2P=$SRC_F2P"

# ═══════════════════════════════════════════════════════════════════
# F2P: Documentation update
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P: docs updated ==="
DOCS=packages/coding-agent/docs/custom-provider.md
DOC_F2P=0
if [ -f "$DOCS" ]; then
    if grep -Eqi "reasoningEffortMap" "$DOCS" 2>/dev/null; then
        DOC_F2P=1
    fi
fi
echo "DOC_F2P=$DOC_F2P"

# ═══════════════════════════════════════════════════════════════════
# F2P: Documentation specifically mentions the qwen3/groq restricted-effort case
# (Distinguishes a generic doc edit from one that documents THIS fix)
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P: docs mention qwen3 restricted-effort case ==="
DOC_SPECIFIC=0
if [ -f "$DOCS" ]; then
    if grep -Eqi "(qwen3|qwen/qwen3|qwen-32b)" "$DOCS" 2>/dev/null && \
       grep -Eqi "(default|none|restrict|only accept)" "$DOCS" 2>/dev/null; then
        DOC_SPECIFIC=1
    fi
fi
echo "DOC_SPECIFIC=$DOC_SPECIFIC"

# ═══════════════════════════════════════════════════════════════════
# Compute final reward
#   QWEN_SCORE     (4 cases × 0.10 = 0.40)  — core behavioral fix
#   GPTOSS_SCORE   (4 cases × 0.075 = 0.30) — non-regression / specificity
#   SRC_F2P        0.10                     — fix in correct file
#   DOC_F2P        0.10                     — docs touched
#   DOC_SPECIFIC   0.10                     — docs explain THIS fix
# Total: 1.00
# ═══════════════════════════════════════════════════════════════════

REWARD=$(awk -v q=$QWEN_SCORE -v g=$GPTOSS_SCORE -v s=$SRC_F2P -v d=$DOC_F2P -v ds=$DOC_SPECIFIC \
    'BEGIN{printf "%.4f", q + g + s*0.10 + d*0.10 + ds*0.10}')

echo "QWEN_SCORE=$QWEN_SCORE GPTOSS_SCORE=$GPTOSS_SCORE SRC_F2P=$SRC_F2P DOC_F2P=$DOC_F2P DOC_SPECIFIC=$DOC_SPECIFIC"
echo "FINAL REWARD=$REWARD"

echo "$REWARD" > /logs/verifier/reward.txt
# ---- v5: orchestrator-wrapped appended block ----
_v5_run_upstream_appended() {
  set +e  # never abort the host script from inside the wrapper


# ---- inner-claude upstream gates ----
echo "=== UPSTREAM GATES ==="

# F2P: qwen-qwq-32b reasoning effort mapping (fails on base, passes on fix)
echo "=== UPSTREAM F2P: qwen-qwq-32b reasoning mapping ==="
F2P_QWQ_PASSED=false
cat > packages/ai/test/_f2p_qwq_gate.test.ts << 'GATE_TESTEOF'
import { describe, expect, it, vi } from "vitest";
import { getModel } from "../src/models.js";
import { streamSimple } from "../src/stream.js";

const mockState = vi.hoisted(() => ({ lastParams: undefined as any }));

vi.mock("openai", () => {
  class FakeOpenAI {
    chat = {
      completions: {
        create: (params: any) => {
          mockState.lastParams = params;
          const stream = {
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
          const promise = Promise.resolve(stream) as any;
          promise.withResponse = async () => ({
            data: stream,
            response: { status: 200, headers: new Headers() },
          });
          return promise;
        },
      },
    };
  }
  return { default: FakeOpenAI };
});

describe("issue1745 qwen-qwq reasoning mapping", () => {
  it("maps groq qwen-qwq-32b medium reasoning to default", async () => {
    const model = getModel("groq", "qwen-qwq-32b")!;
    let payload: unknown;
    await streamSimple(
      model,
      { messages: [{ role: "user", content: "Hi", timestamp: Date.now() }] },
      {
        apiKey: "test",
        reasoning: "medium",
        onPayload: (params: unknown) => { payload = params; },
      },
    ).result();
    const params = (payload ?? mockState.lastParams) as { reasoning_effort?: string };
    expect(params.reasoning_effort).toBe("default");
  });
});
GATE_TESTEOF

cd packages/ai
npx vitest --run test/_f2p_qwq_gate.test.ts --reporter=verbose > /tmp/f2p_qwq.out 2>&1
F2P_QWQ_RC=$?
tail -20 /tmp/f2p_qwq.out
if [ "$F2P_QWQ_RC" -eq 0 ]; then
    F2P_QWQ_PASSED=true
fi
rm -f test/_f2p_qwq_gate.test.ts
cd /workspace/pi-mono

echo '{"id": "f2p_upstream_qwq_reasoning_map", "passed": '"$F2P_QWQ_PASSED"', "detail": "qwen-qwq-32b reasoning effort mapping"}' >> /logs/verifier/gates.json

# P2P: TypeScript compilation (already checked above, re-emit as gate)
echo '{"id": "p2p_upstream_tsgo", "passed": true, "detail": "TypeScript compilation (checked above)"}' >> /logs/verifier/gates.json

# P2P: Existing tests (already checked above, re-emit as gate)
echo '{"id": "p2p_upstream_existing_tests", "passed": true, "detail": "Existing tests (checked above)"}' >> /logs/verifier/gates.json

# Python tail: adjust reward based on upstream gate verdicts
python3 - <<'PYEOF'
import json, os

WEIGHTS = {"f2p_upstream_qwq_reasoning_map": 0.20}
P2P_REGRESSION = ["p2p_upstream_tsgo", "p2p_upstream_existing_tests"]

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

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
hard_zero = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
# If no F2P gate passed, fix is not present — zero the reward
any_f2p_passed = any(verdicts.get(gid, False) for gid in WEIGHTS.keys())
if hard_zero or (WEIGHTS and not any_f2p_passed):
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM_REWARD=%.4f' % reward)
PYEOF
# ---- end ----
}
# Run via subshell so even unhandled `exit N` in the wrapper
# only kills the subshell, not the host. Exit codes ignored.
( _v5_run_upstream_appended ) || true
# ---- end v5 wrapper ----
