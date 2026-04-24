#!/bin/bash
set +e

mkdir -p /logs/verifier
cd /workspace/pi-mono

SCORE=0

# ─────────────────────────────────────────────────────────────────────────────
# Helper: write inline bun test script
# ─────────────────────────────────────────────────────────────────────────────
cat > /tmp/test_foreign_id.ts << 'TSEOF'
import { getModel } from "/workspace/pi-mono/packages/ai/src/models.js";
import { convertResponsesMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.js";
import type { AssistantMessage, Context, ToolResultMessage, Usage } from "/workspace/pi-mono/packages/ai/src/types.js";

const COPILOT_RAW_ID =
  "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";

const SECOND_RAW_ID =
  "call_vs1eoMWtUBKjTmXJjM9clHiF|X90bLu7itE+qX5vORjDhfNHnWPBttLg03yQnn/CIPeBwSrORnhuil386M75H4p";

// Short foreign ID — item part < 61 chars, but still contains /+= chars
const SHORT_RAW_ID =
  "call_shortTest1234567|foreign/with+special/chars+inside";

const usage: Usage = {
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function buildForeignContext(rawToolCallId: string): Context {
  const now = Date.now();
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [{
      type: "toolCall",
      id: rawToolCallId,
      name: "edit",
      arguments: { path: "src/app.ts" },
    }],
    api: "openai-responses",
    provider: "github-copilot",
    model: "gpt-5.1-codex",
    usage,
    stopReason: "toolUse",
    timestamp: now - 2000,
  };
  const toolResult: ToolResultMessage = {
    role: "toolResult",
    toolCallId: rawToolCallId,
    toolName: "edit",
    content: [{ type: "text", text: "ok" }],
    isError: false,
    timestamp: now - 1000,
  };
  return {
    systemPrompt: "test",
    messages: [
      { role: "user", content: "Do it.", timestamp: now - 3000 },
      assistant,
      toolResult,
    ],
  };
}

function buildSameProviderContext(): Context {
  const now = Date.now();
  const sameProviderAssistant: AssistantMessage = {
    role: "assistant",
    content: [{
      type: "toolCall",
      id: "call_abc123|fc_normalItem456",
      name: "edit",
      arguments: { path: "test.ts" },
    }],
    api: "openai-codex-responses",
    provider: "openai-codex",
    model: "gpt-5.1",
    usage,
    stopReason: "toolUse",
    timestamp: now - 2000,
  };
  const toolResult: ToolResultMessage = {
    role: "toolResult",
    toolCallId: "call_abc123|fc_normalItem456",
    toolName: "edit",
    content: [{ type: "text", text: "ok" }],
    isError: false,
    timestamp: now - 1000,
  };
  return {
    systemPrompt: "test",
    messages: [
      { role: "user", content: "Do it.", timestamp: now - 3000 },
      sameProviderAssistant,
      toolResult,
    ],
  };
}

const model = getModel("openai-codex", "gpt-5.1");
const allowedProviders = new Set(["openai", "openai-codex", "opencode"]);

// Test 1: Foreign ID normalization (Copilot → Codex) — long ID
const foreignResult1 = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
const fc1 = foreignResult1.find((i: any) => i.type === "function_call") as any;
const foreignId1 = fc1?.id ?? "";

// Test 2: Second foreign ID — medium length
const foreignResult2 = convertResponsesMessages(model, buildForeignContext(SECOND_RAW_ID), allowedProviders);
const fc2 = foreignResult2.find((i: any) => i.type === "function_call") as any;
const foreignId2 = fc2?.id ?? "";

// Test 3: Short foreign ID — under 61 chars but still has special chars
const foreignResult3 = convertResponsesMessages(model, buildForeignContext(SHORT_RAW_ID), allowedProviders);
const fc3 = foreignResult3.find((i: any) => i.type === "function_call") as any;
const foreignId3 = fc3?.id ?? "";

// Test 4: Determinism (run foreign ID 1 again)
const foreignResult1b = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
const fc1b = foreignResult1b.find((i: any) => i.type === "function_call") as any;
const foreignId1b = fc1b?.id ?? "";

// Test 5: Same-provider IDs
const sameResult = convertResponsesMessages(model, buildSameProviderContext(), allowedProviders);
const fcSame = sameResult.find((i: any) => i.type === "function_call") as any;
const sameId = fcSame?.id ?? "";

// Output results
console.log("FOREIGN_ID_1:" + foreignId1);
console.log("FOREIGN_ID_2:" + foreignId2);
console.log("FOREIGN_ID_3:" + foreignId3);
console.log("FOREIGN_ID_1B:" + foreignId1b);
console.log("SAME_PROVIDER_ID:" + sameId);
TSEOF

# ─────────────────────────────────────────────────────────────────────────────
# [P2P] Gate 1 (weight 0.05): TypeScript compilation
# Passes on unmodified base AND on correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo "=== P2P Gate 1: TypeScript compilation ==="
TSC_OUTPUT=$(npx tsc --noEmit -p packages/ai/tsconfig.build.json 2>&1)
TSC_EXIT=$?
echo "$TSC_OUTPUT" | tail -10
if [ $TSC_EXIT -eq 0 ]; then
  echo "PASS"
  SCORE=$(python3 -c "print($SCORE + 5)")
else
  echo "FAIL: tsc exit=$TSC_EXIT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Run the behavioral test script
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Running behavioral tests ==="
TEST_OUTPUT=$(bun run /tmp/test_foreign_id.ts 2>&1)
echo "$TEST_OUTPUT"

FOREIGN_ID_1=$(echo "$TEST_OUTPUT" | grep "^FOREIGN_ID_1:" | head -1 | cut -d: -f2)
FOREIGN_ID_2=$(echo "$TEST_OUTPUT" | grep "^FOREIGN_ID_2:" | head -1 | cut -d: -f2)
FOREIGN_ID_3=$(echo "$TEST_OUTPUT" | grep "^FOREIGN_ID_3:" | head -1 | cut -d: -f2)
FOREIGN_ID_1B=$(echo "$TEST_OUTPUT" | grep "^FOREIGN_ID_1B:" | head -1 | cut -d: -f2)
SAME_PROVIDER_ID=$(echo "$TEST_OUTPUT" | grep "^SAME_PROVIDER_ID:" | head -1 | cut -d: -f2)

# Known-buggy outputs from the char-replacement approach
BUGGY_ID_1="fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"
BUGGY_ID_2="fc_X90bLu7itE_qX5vORjDhfNHnWPBttLg03yQnn_CIPeBwSrORnhuil386M75H4"
BUGGY_ID_3="fc_foreign_with_special_chars_inside"

echo ""
echo "Foreign ID 1 (long):  $FOREIGN_ID_1"
echo "Foreign ID 2 (med):   $FOREIGN_ID_2"
echo "Foreign ID 3 (short): $FOREIGN_ID_3"
echo "Foreign ID 1b:        $FOREIGN_ID_1B"
echo "Same provider:        $SAME_PROVIDER_ID"

# ─────────────────────────────────────────────────────────────────────────────
# [P2P] Gate 2 (weight 0.05): Same-provider IDs preserved
# Same-provider tool call IDs pass through unchanged on both base and fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== P2P Gate 2: Same-provider ID normalization ==="
if [ "$SAME_PROVIDER_ID" = "fc_normalItem456" ]; then
  echo "PASS"
  SCORE=$(python3 -c "print($SCORE + 5)")
else
  echo "FAIL: expected fc_normalItem456, got $SAME_PROVIDER_ID"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [F2P] Gate 3 (weight 0.25): Foreign ID #1 (long) differs from buggy output
# FAILS on unmodified base (produces known-bad ID). PASSES on correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 3: Foreign ID #1 (long) not buggy ==="
GATE3=0
if [ -n "$FOREIGN_ID_1" ] && [ "$FOREIGN_ID_1" != "$BUGGY_ID_1" ]; then
  ID_LEN=${#FOREIGN_ID_1}
  if echo "$FOREIGN_ID_1" | grep -qE '^fc[_-][a-zA-Z0-9_-]+$' && [ "$ID_LEN" -le 64 ]; then
    echo "PASS (id=$FOREIGN_ID_1, len=$ID_LEN)"
    GATE3=1
    SCORE=$(python3 -c "print($SCORE + 25)")
  else
    echo "FAIL: ID format invalid (id=$FOREIGN_ID_1, len=$ID_LEN)"
  fi
else
  echo "FAIL: ID matches buggy output or is empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [F2P] Gate 4 (weight 0.20): Foreign ID #2 (medium) also properly handled
# FAILS on unmodified base. PASSES on correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 4: Foreign ID #2 (medium) not buggy ==="
if [ -n "$FOREIGN_ID_2" ] && [ "$FOREIGN_ID_2" != "$BUGGY_ID_2" ]; then
  ID2_LEN=${#FOREIGN_ID_2}
  if echo "$FOREIGN_ID_2" | grep -qE '^fc[_-][a-zA-Z0-9_-]+$' && [ "$ID2_LEN" -le 64 ]; then
    echo "PASS (id=$FOREIGN_ID_2, len=$ID2_LEN)"
    SCORE=$(python3 -c "print($SCORE + 20)")
  else
    echo "FAIL: ID format invalid (id=$FOREIGN_ID_2, len=$ID2_LEN)"
  fi
else
  echo "FAIL: ID matches buggy output or is empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [F2P] Gate 5 (weight 0.25): Foreign ID #3 (short) also properly handled
# FAILS on unmodified base. PASSES on correct fix.
# This catches fixes that only hash long IDs but leave short foreign IDs
# using the buggy character-replacement approach.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 5: Foreign ID #3 (short) not buggy ==="
if [ -n "$FOREIGN_ID_3" ] && [ "$FOREIGN_ID_3" != "$BUGGY_ID_3" ]; then
  ID3_LEN=${#FOREIGN_ID_3}
  if echo "$FOREIGN_ID_3" | grep -qE '^fc[_-][a-zA-Z0-9_-]+$' && [ "$ID3_LEN" -le 64 ]; then
    echo "PASS (id=$FOREIGN_ID_3, len=$ID3_LEN)"
    SCORE=$(python3 -c "print($SCORE + 25)")
  else
    echo "FAIL: ID format invalid (id=$FOREIGN_ID_3, len=$ID3_LEN)"
  fi
else
  echo "FAIL: ID matches buggy output or is empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# [F2P] Gate 6 (weight 0.20): Determinism — same input gives same output
# FAILS on unmodified base (Gate 3 dependency). PASSES on correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 6: Determinism ==="
if [ "$GATE3" -eq 1 ] && [ "$FOREIGN_ID_1" = "$FOREIGN_ID_1B" ] && [ -n "$FOREIGN_ID_1" ]; then
  echo "PASS (both runs: $FOREIGN_ID_1)"
  SCORE=$(python3 -c "print($SCORE + 20)")
else
  if [ "$GATE3" -ne 1 ]; then
    echo "FAIL: Gate 3 did not pass, skipping determinism check"
  else
    echo "FAIL: non-deterministic (run1=$FOREIGN_ID_1, run2=$FOREIGN_ID_1B)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final score
# ─────────────────────────────────────────────────────────────────────────────
REWARD=$(python3 -c "print(round($SCORE / 100, 2))")
echo ""
echo "=== TOTAL SCORE: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt
