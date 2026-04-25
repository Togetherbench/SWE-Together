#!/bin/bash
set +e

mkdir -p /logs/verifier
cd /workspace/pi-mono 2>/dev/null || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BUN=$(which bun 2>/dev/null)
if [ -z "$BUN" ]; then
  for cand in /root/.bun/bin/bun /usr/local/bin/bun /workspace/pi-mono/node_modules/.bin/bun; do
    [ -x "$cand" ] && BUN="$cand" && break
  done
fi
[ -z "$BUN" ] && BUN="bun"

NPX=$(which npx 2>/dev/null)
[ -z "$NPX" ] && NPX="npx"

SHARED_FILE="/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.ts"

if [ ! -f "$SHARED_FILE" ]; then
  echo "Missing shared file" 
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build the behavioral driver
# ─────────────────────────────────────────────────────────────────────────────
cat > /tmp/test_foreign_id.ts << 'TSEOF'
import { getModel } from "/workspace/pi-mono/packages/ai/src/models.js";
import { convertResponsesMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.js";
import type { AssistantMessage, Context, ToolResultMessage, Usage } from "/workspace/pi-mono/packages/ai/src/types.js";

const COPILOT_RAW_ID =
  "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";

const SECOND_RAW_ID =
  "call_vs1eoMWtUBKjTmXJjM9clHiF|X90bLu7itE+qX5vORjDhfNHnWPBttLg03yQnn/CIPeBwSrORnhuil386M75H4p";

const SHORT_RAW_ID =
  "call_shortTest1234567|foreign/with+special/chars+inside";

const ANTHROPIC_LIKE_ID = "call_anthropic_xyz|ant_someItem/with+chars==";

const usage: Usage = {
  input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function buildForeignContext(rawToolCallId: string, sourceProvider = "github-copilot", sourceApi = "openai-responses", sourceModel = "gpt-5.1-codex"): Context {
  const now = Date.now();
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [{
      type: "toolCall",
      id: rawToolCallId,
      name: "edit",
      arguments: { path: "src/app.ts" },
    }],
    api: sourceApi as any,
    provider: sourceProvider as any,
    model: sourceModel,
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
      id: "call_abc123XYZ|fc_normalItem456",
      name: "edit",
      arguments: { path: "test.ts" },
    }],
    api: "openai-codex-responses" as any,
    provider: "openai-codex" as any,
    model: "gpt-5.1",
    usage,
    stopReason: "toolUse",
    timestamp: now - 2000,
  };
  const toolResult: ToolResultMessage = {
    role: "toolResult",
    toolCallId: "call_abc123XYZ|fc_normalItem456",
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

function findFunctionCall(items: any[]): any {
  return items.find((i: any) => i.type === "function_call");
}
function findFunctionCallOutput(items: any[]): any {
  return items.find((i: any) => i.type === "function_call_output");
}

let model: any;
try {
  model = getModel("openai-codex", "gpt-5.1");
} catch (e) {
  // try alternates
  try { model = getModel("openai-codex", "gpt-5.3-codex"); }
  catch (e2) {
    try { model = getModel("openai-codex", "gpt-5"); }
    catch (e3) {
      console.log("__JSON__" + JSON.stringify({ error: "model_lookup_failed: " + String(e) }));
      process.exit(0);
    }
  }
}

const allowedProviders = new Set(["openai", "openai-codex", "opencode", "github-copilot"]);

const r1 = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
const fc1 = findFunctionCall(r1);
const fco1 = findFunctionCallOutput(r1);

const r2 = convertResponsesMessages(model, buildForeignContext(SECOND_RAW_ID), allowedProviders);
const fc2 = findFunctionCall(r2);
const fco2 = findFunctionCallOutput(r2);

const r3 = convertResponsesMessages(model, buildForeignContext(SHORT_RAW_ID), allowedProviders);
const fc3 = findFunctionCall(r3);
const fco3 = findFunctionCallOutput(r3);

const r1b = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
const fc1b = findFunctionCall(r1b);

const rs = convertResponsesMessages(model, buildSameProviderContext(), allowedProviders);
const fcS = findFunctionCall(rs);
const fcoS = findFunctionCallOutput(rs);

const r6 = convertResponsesMessages(model, buildForeignContext(ANTHROPIC_LIKE_ID, "anthropic", "anthropic-messages", "claude-3"), allowedProviders);
const fc6 = findFunctionCall(r6);
const fco6 = findFunctionCallOutput(r6);

const out = {
  fc1_id: fc1?.id ?? null,
  fc1_call_id: fc1?.call_id ?? null,
  fco1_call_id: fco1?.call_id ?? null,
  fc2_id: fc2?.id ?? null,
  fc2_call_id: fc2?.call_id ?? null,
  fco2_call_id: fco2?.call_id ?? null,
  fc3_id: fc3?.id ?? null,
  fc3_call_id: fc3?.call_id ?? null,
  fco3_call_id: fco3?.call_id ?? null,
  fc1b_id: fc1b?.id ?? null,
  fc1b_call_id: fc1b?.call_id ?? null,
  fcS_id: fcS?.id ?? null,
  fcS_call_id: fcS?.call_id ?? null,
  fcoS_call_id: fcoS?.call_id ?? null,
  fc6_id: fc6?.id ?? null,
  fc6_call_id: fc6?.call_id ?? null,
  fco6_call_id: fco6?.call_id ?? null,
  threw: false,
};
console.log("__JSON__" + JSON.stringify(out));
TSEOF

# ─────────────────────────────────────────────────────────────────────────────
# Run driver
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Running behavioral driver ==="
TEST_OUTPUT=$($BUN run /tmp/test_foreign_id.ts 2>&1)
TEST_EXIT=$?
echo "$TEST_OUTPUT" | tail -40

JSON_LINE=$(echo "$TEST_OUTPUT" | grep '^__JSON__' | head -1 | sed 's/^__JSON__//')

extract() {
  python3 -c "
import json,sys
try:
  d=json.loads(r'''$JSON_LINE''')
  v=d.get('$1')
  if v is None: print('__NULL__')
  else: print(v)
except Exception:
  print('__ERR__')
"
}

FC1_ID=$(extract fc1_id)
FC1_CALL_ID=$(extract fc1_call_id)
FCO1_CALL_ID=$(extract fco1_call_id)
FC2_ID=$(extract fc2_id)
FC2_CALL_ID=$(extract fc2_call_id)
FCO2_CALL_ID=$(extract fco2_call_id)
FC3_ID=$(extract fc3_id)
FC3_CALL_ID=$(extract fc3_call_id)
FCO3_CALL_ID=$(extract fco3_call_id)
FC1B_ID=$(extract fc1b_id)
FC1B_CALL_ID=$(extract fc1b_call_id)
FCS_ID=$(extract fcS_id)
FCS_CALL_ID=$(extract fcS_call_id)
FCOS_CALL_ID=$(extract fcoS_call_id)
FC6_ID=$(extract fc6_id)
FC6_CALL_ID=$(extract fc6_call_id)
FCO6_CALL_ID=$(extract fco6_call_id)

# Invalid character pattern (BUGGY): contains _ in the fc_ body where original had / + =
BUGGY_FRAGMENT_1="fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"

# Helper: returns 1 if id is "safe" — either undefined/null, or ^fc_[A-Za-z0-9]+$ within 64 chars
is_safe_id() {
  local v="$1"
  # null/undefined treated as safe (omitting the id is a valid fix)
  if [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ]; then
    return 0
  fi
  local len=${#v}
  if [ "$len" -gt 64 ]; then return 1; fi
  # must start with fc_ and have only alphanumerics after fc_
  if echo "$v" | grep -Eq '^fc_[A-Za-z0-9]+$'; then
    return 0
  fi
  return 1
}

is_call_id_clean() {
  local v="$1"
  # clean call_id: ^call_[A-Za-z0-9]+$  (no | no special chars no underscores in body except leading prefix)
  if echo "$v" | grep -Eq '^call_[A-Za-z0-9]+$'; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Scoring
# ─────────────────────────────────────────────────────────────────────────────
SCORE=0
MAX=100

echo ""
echo "=== Behavioral observations ==="
echo "fc1_id       = $FC1_ID"
echo "fc1_call_id  = $FC1_CALL_ID"
echo "fco1_call_id = $FCO1_CALL_ID"
echo "fc2_id       = $FC2_ID"
echo "fc3_id       = $FC3_ID"
echo "fc1b_id      = $FC1B_ID"
echo "fcS_id       = $FCS_ID"
echo "fc6_id       = $FC6_ID"

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate A (15pts): Long Copilot foreign ID is SAFE for Codex backend
#   (either omitted/undefined, OR /^fc_[A-Za-z0-9]+$/ within 64 chars,
#    AND does NOT equal the buggy mangled form)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate A: Foreign Copilot tool ID (long base64) is backend-safe ==="
GATE_A=0
if is_safe_id "$FC1_ID"; then
  if [ "$FC1_ID" = "$BUGGY_FRAGMENT_1" ]; then
    echo "FAIL: id matches the known-buggy mangled form"
  else
    echo "PASS: id is null/omitted or fc_<alnum> within 64 chars"
    GATE_A=15
  fi
else
  echo "FAIL: id contains invalid characters or exceeds 64 chars"
fi
SCORE=$((SCORE + GATE_A))

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate B (15pts): call_id (and function_call_output.call_id) preserved as
# a clean prefix — NOT the mangled compound containing _ in place of |
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate B: call_id pairing preserved (clean prefix) ==="
GATE_B=0
EXPECTED_CALL="call_4VnzVawQXPB9MgYib7CiQFEY"
if [ "$FC1_CALL_ID" = "$EXPECTED_CALL" ] && [ "$FCO1_CALL_ID" = "$EXPECTED_CALL" ]; then
  echo "PASS: function_call.call_id and function_call_output.call_id both = $EXPECTED_CALL"
  GATE_B=15
elif is_call_id_clean "$FC1_CALL_ID" && [ "$FC1_CALL_ID" = "$FCO1_CALL_ID" ]; then
  echo "PARTIAL: call_id is clean and consistent ($FC1_CALL_ID)"
  GATE_B=8
else
  echo "FAIL: call_id mangled or inconsistent (fc=$FC1_CALL_ID, fco=$FCO1_CALL_ID)"
fi
SCORE=$((SCORE + GATE_B))

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate C (10pts): Determinism — same input → same id
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate C: Determinism ==="
GATE_C=0
if [ "$FC1_ID" = "$FC1B_ID" ] && [ "$FC1_CALL_ID" = "$FC1B_CALL_ID" ]; then
  echo "PASS: identical output across runs"
  GATE_C=10
else
  echo "FAIL: nondeterministic (fc1=$FC1_ID vs fc1b=$FC1B_ID)"
fi
SCORE=$((SCORE + GATE_C))

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate D (10pts): Different foreign IDs produce SAFE outputs (not the
# raw mangled form) — second copilot ID and short ID
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate D: Other foreign IDs are also safe ==="
GATE_D=0
D_OK=1
for label_id in "fc2:$FC2_ID" "fc3:$FC3_ID" "fc6:$FC6_ID"; do
  label="${label_id%%:*}"
  val="${label_id#*:}"
  if is_safe_id "$val"; then
    echo "  $label safe: $val"
  else
    echo "  $label UNSAFE: $val"
    D_OK=0
  fi
done
# also check call_ids of these are clean
for label_id in "fc2_call:$FC2_CALL_ID" "fc3_call:$FC3_CALL_ID" "fc6_call:$FC6_CALL_ID"; do
  label="${label_id%%:*}"
  val="${label_id#*:}"
  if is_call_id_clean "$val"; then
    echo "  $label clean: $val"
  else
    echo "  $label UNCLEAN: $val"
    D_OK=0
  fi
done
if [ "$D_OK" -eq 1 ]; then
  echo "PASS"
  GATE_D=10
else
  echo "FAIL"
fi
SCORE=$((SCORE + GATE_D))

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate E (10pts): Distinct foreign IDs produce DISTINCT outputs (or both
# omitted). Prevents collapsing-to-empty-string trivial fixes from
# scoring well unless they consistently omit (we accept both omit OR distinct).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate E: Distinct inputs distinguishable ==="
GATE_E=0
# Either both null (omitted), or distinct values
both_null() { [ "$1" = "__NULL__" ] && [ "$2" = "__NULL__" ]; }
if both_null "$FC1_ID" "$FC2_ID"; then
  echo "  fc1 vs fc2: both omitted (acceptable)"
  E1=1
elif [ "$FC1_ID" != "$FC2_ID" ] && [ "$FC1_ID" != "__NULL__" ] && [ "$FC2_ID" != "__NULL__" ]; then
  echo "  fc1 vs fc2: distinct"
  E1=1
elif [ "$FC1_ID" = "__NULL__" ] || [ "$FC2_ID" = "__NULL__" ]; then
  # mixed: one omitted one not — the call_ids should at least be distinct
  if [ "$FC1_CALL_ID" != "$FC2_CALL_ID" ]; then
    echo "  fc1 vs fc2: mixed but call_ids distinct"
    E1=1
  else
    E1=0
  fi
else
  echo "  fc1 vs fc2: COLLAPSED to same ($FC1_ID)"
  E1=0
fi

# call_ids must always differ for different inputs
if [ "$FC1_CALL_ID" != "$FC2_CALL_ID" ] && [ "$FC2_CALL_ID" != "$FC3_CALL_ID" ]; then
  E2=1
else
  echo "  call_ids collapsed across distinct inputs"
  E2=0
fi

if [ "$E1" -eq 1 ] && [ "$E2" -eq 1 ]; then
  echo "PASS"
  GATE_E=10
else
  echo "FAIL"
fi
SCORE=$((SCORE + GATE_E))

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate F (10pts): Same-provider/same-API IDs still pass through
# (regression guard) — call_id preserved
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate F: Same-provider regression guard ==="
GATE_F=0
if [ "$FCS_CALL_ID" = "call_abc123XYZ" ] && [ "$FCOS_CALL_ID" = "call_abc123XYZ" ]; then
  echo "PASS: same-provider call_id preserved"
  GATE_F=10
else
  echo "FAIL: same-provider call_id mangled (fc=$FCS_CALL_ID, fco=$FCOS_CALL_ID)"
fi
SCORE=$((SCORE + GATE_F))

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate G (10pts): TypeScript still compiles
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate G: TypeScript compiles ==="
GATE_G=0
if [ -f /workspace/pi-mono/packages/ai/tsconfig.build.json ]; then
  TSC_OUT=$(cd /workspace/pi-mono && $NPX tsc --noEmit -p packages/ai/tsconfig.build.json 2>&1)
  TSC_EXIT=$?
  if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS"
    GATE_G=10
  else
    echo "FAIL"
    echo "$TSC_OUT" | tail -10
  fi
else
  echo "SKIP (no tsconfig.build.json)"
  GATE_G=10
fi
SCORE=$((SCORE + GATE_G))

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate H (10pts): Existing package tests in the affected file pass
# (not all tests, just sanity-check the related provider tests don't break)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate H: Related vitest suite ==="
GATE_H=0
TEST_FILES=$(find /workspace/pi-mono/packages/ai/test -maxdepth 2 -name '*responses*.test.ts' 2>/dev/null | head -5)
if [ -n "$TEST_FILES" ]; then
  cd /workspace/pi-mono/packages/ai
  VITEST_OUT=$($BUN x vitest run --no-coverage $TEST_FILES 2>&1)
  VITEST_EXIT=$?
  cd /workspace/pi-mono
  if [ $VITEST_EXIT -eq 0 ]; then
    echo "PASS"
    GATE_H=10
  else
    # partial credit: count passing
    PASS_COUNT=$(echo "$VITEST_OUT" | grep -Eo '[0-9]+ passed' | head -1 | grep -Eo '[0-9]+')
    FAIL_COUNT=$(echo "$VITEST_OUT" | grep -Eo '[0-9]+ failed' | head -1 | grep -Eo '[0-9]+')
    [ -z "$PASS_COUNT" ] && PASS_COUNT=0
    [ -z "$FAIL_COUNT" ] && FAIL_COUNT=0
    TOTAL=$((PASS_COUNT + FAIL_COUNT))
    if [ "$TOTAL" -gt 0 ]; then
      GATE_H=$(awk -v p="$PASS_COUNT" -v t="$TOTAL" 'BEGIN { printf "%d", (p*10)/t }')
    fi
    echo "PARTIAL: $PASS_COUNT/$TOTAL passing → $GATE_H/10"
    echo "$VITEST_OUT" | tail -15
  fi
else
  echo "SKIP (no related test files)"
  GATE_H=10
fi
SCORE=$((SCORE + GATE_H))

# ─────────────────────────────────────────────────────────────────────────────
# Structural Gate I (10pts): Source file shows hash-based / omit-based fix
# (not just the original pattern). Implementation-agnostic: accept either
# (a) shortHash usage, OR (b) explicit undefined assignment for foreign source,
# OR (c) call_id-only return path
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Gate I: Source shows a real fix pattern ==="
GATE_I=0
SHARED_CONTENT=$(cat "$SHARED_FILE")

# Check for ANY of the three reasonable approaches
PATTERN_HASH=0
if echo "$SHARED_CONTENT" | grep -q "shortHash"; then
  PATTERN_HASH=1
fi

PATTERN_OMIT=0
if echo "$SHARED_CONTENT" | grep -Eq "itemId\s*=\s*undefined"; then
  PATTERN_OMIT=1
fi

PATTERN_CALLID_ONLY=0
# Look for a return path that returns just the callId without |itemId in foreign branch
if echo "$SHARED_CONTENT" | grep -Eq 'isForeign[A-Za-z]*' && echo "$SHARED_CONTENT" | grep -Eq 'return\s+normalizedCallId\s*;'; then
  PATTERN_CALLID_ONLY=1
fi

echo "  shortHash usage: $PATTERN_HASH"
echo "  itemId=undefined: $PATTERN_OMIT"
echo "  callId-only return: $PATTERN_CALLID_ONLY"

if [ $((PATTERN_HASH + PATTERN_OMIT + PATTERN_CALLID_ONLY)) -ge 1 ]; then
  echo "PASS"
  GATE_I=10
else
  echo "FAIL: no recognizable fix pattern"
fi
SCORE=$((SCORE + GATE_I))

# ─────────────────────────────────────────────────────────────────────────────
# Tally
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Score Breakdown ==="
echo "A (foreign id safe)        : $GATE_A / 15"
echo "B (call_id preserved)      : $GATE_B / 15"
echo "C (determinism)            : $GATE_C / 10"
echo "D (other foreign safe)     : $GATE_D / 10"
echo "E (distinct inputs)        : $GATE_E / 10"
echo "F (same-provider regress)  : $GATE_F / 10"
echo "G (tsc compile)            : $GATE_G / 10"
echo "H (related tests)          : $GATE_H / 10"
echo "I (fix pattern present)    : $GATE_I / 10"
echo "TOTAL: $SCORE / $MAX"

REWARD=$(awk -v s="$SCORE" -v m="$MAX" 'BEGIN { printf "%.3f", s/m }')
echo "REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0