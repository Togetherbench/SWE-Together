#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD=0.0
echo "$REWARD" > /logs/verifier/reward.txt

cd /workspace/pi-mono 2>/dev/null || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BUN=$(command -v bun 2>/dev/null)
if [ -z "$BUN" ]; then
  for cand in /root/.bun/bin/bun /usr/local/bin/bun /workspace/pi-mono/node_modules/.bin/bun; do
    [ -x "$cand" ] && BUN="$cand" && break
  done
fi
[ -z "$BUN" ] && BUN="bun"

SHARED_FILE="/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.ts"

if [ ! -f "$SHARED_FILE" ]; then
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build the behavioral driver — exercises convertResponsesMessages with a
# realistic Copilot-originated tool call and inspects the produced
# function_call / function_call_output items.
# ─────────────────────────────────────────────────────────────────────────────
cat > /tmp/test_foreign_id.ts << 'TSEOF'
import { convertResponsesMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.js";
import { getModel } from "/workspace/pi-mono/packages/ai/src/models.js";
import type { AssistantMessage, Context, ToolResultMessage, Usage } from "/workspace/pi-mono/packages/ai/src/types.js";

const COPILOT_RAW_ID =
  "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";

const SECOND_RAW_ID =
  "call_vs1eoMWtUBKjTmXJjM9clHiF|X90bLu7itE+qX5vORjDhfNHnWPBttLg03yQnn/CIPeBwSrORnhuil386M75H4p";

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
    api: "openai-responses" as any,
    provider: "github-copilot" as any,
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

function findFunctionCall(items: any[]): any {
  return items.find((i: any) => i.type === "function_call");
}
function findFunctionCallOutput(items: any[]): any {
  return items.find((i: any) => i.type === "function_call_output");
}

let model: any = null;
const candidates = [
  ["openai-codex", "gpt-5.1"],
  ["openai-codex", "gpt-5.1-codex"],
  ["openai-codex", "gpt-5.3-codex"],
  ["openai-codex", "gpt-5"],
  ["openai-codex", "gpt-5-codex"],
];
for (const [p, m] of candidates) {
  try { model = getModel(p as any, m as any); break; } catch {}
}
if (!model) {
  console.log("__JSON__" + JSON.stringify({ error: "model_lookup_failed" }));
  process.exit(0);
}

const allowedProviders = new Set(["openai", "openai-codex", "opencode", "github-copilot"]);

let threw = false;
let errMsg = "";
let r1: any[] = [], r2: any[] = [], r1b: any[] = [];
try {
  r1 = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
  r2 = convertResponsesMessages(model, buildForeignContext(SECOND_RAW_ID), allowedProviders);
  r1b = convertResponsesMessages(model, buildForeignContext(COPILOT_RAW_ID), allowedProviders);
} catch (e: any) {
  threw = true;
  errMsg = String(e?.message ?? e);
}

const fc1 = findFunctionCall(r1);
const fco1 = findFunctionCallOutput(r1);
const fc2 = findFunctionCall(r2);
const fco2 = findFunctionCallOutput(r2);
const fc1b = findFunctionCall(r1b);

const out = {
  threw,
  errMsg,
  fc1_id: fc1?.id ?? null,
  fc1_call_id: fc1?.call_id ?? null,
  fco1_call_id: fco1?.call_id ?? null,
  fc2_id: fc2?.id ?? null,
  fc2_call_id: fc2?.call_id ?? null,
  fco2_call_id: fco2?.call_id ?? null,
  fc1b_id: fc1b?.id ?? null,
  fc1b_call_id: fc1b?.call_id ?? null,
};
console.log("__JSON__" + JSON.stringify(out));
TSEOF

# ─────────────────────────────────────────────────────────────────────────────
# Run driver
# ─────────────────────────────────────────────────────────────────────────────
TEST_OUTPUT=$($BUN run /tmp/test_foreign_id.ts 2>&1)
TEST_EXIT=$?
echo "=== driver output (tail) ==="
echo "$TEST_OUTPUT" | tail -30
echo "============================"

JSON_LINE=$(echo "$TEST_OUTPUT" | grep '^__JSON__' | head -1 | sed 's/^__JSON__//')

if [ -z "$JSON_LINE" ]; then
  echo "Driver did not produce JSON; reward=0"
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

extract() {
python3 - <<PYEOF
import json
d = json.loads(r'''$JSON_LINE''')
v = d.get('$1')
if v is None:
    print('__NULL__')
else:
    print(v)
PYEOF
}

THREW=$(extract threw)
FC1_ID=$(extract fc1_id)
FC1_CALL_ID=$(extract fc1_call_id)
FCO1_CALL_ID=$(extract fco1_call_id)
FC2_ID=$(extract fc2_id)
FC2_CALL_ID=$(extract fc2_call_id)
FCO2_CALL_ID=$(extract fco2_call_id)
FC1B_ID=$(extract fc1b_id)

# Buggy fragment: the broken normalized id contains "_" where original had / + =
# Examples observed on the buggy base:
#   fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi
# Generic "buggy" signature: id starts with fc_ AND contains an underscore
# AFTER the leading "fc_" prefix (i.e., body has _) — meaning a / + = in the
# original got mapped to _, which Codex rejects.

is_buggy_id() {
  local v="$1"
  # If null / undefined / empty → not buggy (omitting id is a valid fix)
  if [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ]; then
    return 1
  fi
  # buggy if it starts with fc_ and the body (after fc_) contains _
  if echo "$v" | grep -qE '^fc_[A-Za-z0-9]*_'; then
    return 0
  fi
  return 1
}

is_safe_id() {
  local v="$1"
  # null/undefined/empty is safe (omitting the id is a valid fix)
  if [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ]; then
    return 0
  fi
  # length check (≤ 64)
  local len=${#v}
  if [ "$len" -gt 64 ]; then
    return 1
  fi
  # must start with fc_ and rest must be [A-Za-z0-9] only (NO underscores in body)
  if echo "$v" | grep -qE '^fc_[A-Za-z0-9]+$'; then
    return 0
  fi
  return 1
}

is_clean_call_id() {
  # call_id is the prefix before "|" — must NOT contain |, must be sane
  local v="$1"
  if [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ]; then
    return 1
  fi
  # call_id should match call_4VnzVawQXPB9MgYib7CiQFEY (no pipe, no special chars)
  if echo "$v" | grep -qE '^call_[A-Za-z0-9_-]+$'; then
    # length sanity
    local len=${#v}
    if [ "$len" -le 64 ]; then
      return 0
    fi
  fi
  return 1
}

echo "----- extracted -----"
echo "threw         = $THREW"
echo "fc1_id        = $FC1_ID"
echo "fc1_call_id   = $FC1_CALL_ID"
echo "fco1_call_id  = $FCO1_CALL_ID"
echo "fc2_id        = $FC2_ID"
echo "fc2_call_id   = $FC2_CALL_ID"
echo "fco2_call_id  = $FCO2_CALL_ID"
echo "fc1b_id       = $FC1B_ID"
echo "---------------------"

# ─────────────────────────────────────────────────────────────────────────────
# HARD GATE: driver must not throw
# ─────────────────────────────────────────────────────────────────────────────
if [ "$THREW" = "True" ] || [ "$THREW" = "true" ]; then
  echo "Driver threw — reward 0"
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

# Score accumulator (F2P only)
SCORE=0.0
add_score() {
  SCORE=$(awk -v a="$SCORE" -v b="$1" 'BEGIN{ printf("%.4f", a + b) }')
}

# ─────────────────────────────────────────────────────────────────────────────
# F2P gate 1 (0.30): fc1.id is SAFE for Codex (not the buggy `fc_..._...` shape).
# On the buggy base, the produced id contains an underscore in the body
# (because '/', '+', '=' → '_'). On the fix it's either omitted or hashed clean.
# ─────────────────────────────────────────────────────────────────────────────
GATE1=0
if is_buggy_id "$FC1_ID"; then
  echo "GATE1 FAIL: fc1.id is buggy ($FC1_ID)"
elif is_safe_id "$FC1_ID"; then
  echo "GATE1 PASS: fc1.id is safe ($FC1_ID)"
  GATE1=1
  add_score 0.30
else
  echo "GATE1 FAIL: fc1.id not safe ($FC1_ID)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P gate 2 (0.20): same for fc2.id (second distinct foreign id).
# Ensures the fix isn't hardcoded to one specific id.
# ─────────────────────────────────────────────────────────────────────────────
GATE2=0
if is_buggy_id "$FC2_ID"; then
  echo "GATE2 FAIL: fc2.id is buggy ($FC2_ID)"
elif is_safe_id "$FC2_ID"; then
  echo "GATE2 PASS: fc2.id is safe ($FC2_ID)"
  GATE2=1
  add_score 0.20
else
  echo "GATE2 FAIL: fc2.id not safe ($FC2_ID)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P gate 3 (0.20): call_id on function_call AND function_call_output is the
# CLEAN prefix `call_4VnzVawQXPB9MgYib7CiQFEY` — i.e., no pipe leakage and the
# pairing between call/result is preserved. On the buggy base the call_id ends
# up mangled (often containing `_` from the pipe substitution or the full
# compound id).
# ─────────────────────────────────────────────────────────────────────────────
GATE3=0
EXPECTED_CALL_ID_1="call_4VnzVawQXPB9MgYib7CiQFEY"
EXPECTED_CALL_ID_2="call_vs1eoMWtUBKjTmXJjM9clHiF"
if [ "$FC1_CALL_ID" = "$EXPECTED_CALL_ID_1" ] && \
   [ "$FCO1_CALL_ID" = "$EXPECTED_CALL_ID_1" ] && \
   [ "$FC2_CALL_ID" = "$EXPECTED_CALL_ID_2" ] && \
   [ "$FCO2_CALL_ID" = "$EXPECTED_CALL_ID_2" ]; then
  echo "GATE3 PASS: call_ids match clean prefix and pair fc/fco"
  GATE3=1
  add_score 0.20
else
  echo "GATE3 FAIL: call_id pairing wrong"
  echo "  fc1=$FC1_CALL_ID fco1=$FCO1_CALL_ID (expected $EXPECTED_CALL_ID_1)"
  echo "  fc2=$FC2_CALL_ID fco2=$FCO2_CALL_ID (expected $EXPECTED_CALL_ID_2)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P gate 4 (0.15): determinism — the SAME input id produces the SAME output
# id across two independent calls. (Trivially true if id is omitted/null in
# both, which is also a valid fix.)
# ─────────────────────────────────────────────────────────────────────────────
GATE4=0
if [ "$FC1_ID" = "$FC1B_ID" ]; then
  # but we must also make sure this isn't trivially passing on the buggy base
  # by also requiring the id be safe (gate1 passes). We already credited gate1
  # for safety; here we only credit determinism if the value isn't the buggy
  # form.
  if is_buggy_id "$FC1_ID"; then
    echo "GATE4 FAIL: deterministic but value is buggy"
  else
    echo "GATE4 PASS: deterministic ($FC1_ID == $FC1B_ID)"
    GATE4=1
    add_score 0.15
  fi
else
  echo "GATE4 FAIL: not deterministic ($FC1_ID vs $FC1B_ID)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P gate 5 (0.15): length compliance — fc1.id and fc2.id, if present, are
# ≤ 64 chars. If null (omitted), this also passes since the unsafe long string
# is not being emitted. Critically must FAIL on the buggy base because the
# buggy normalizer produces a mangled `fc_..._...` body that, while ≤ 64,
# also contains the disallowed `_` — so we additionally require the id to NOT
# be the buggy shape. Effectively gate5 = (length ok) AND (not buggy shape).
# ─────────────────────────────────────────────────────────────────────────────
GATE5=0
length_ok() {
  local v="$1"
  if [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ]; then
    return 0
  fi
  local len=${#v}
  [ "$len" -le 64 ]
}
if length_ok "$FC1_ID" && length_ok "$FC2_ID" && \
   ! is_buggy_id "$FC1_ID" && ! is_buggy_id "$FC2_ID"; then
  echo "GATE5 PASS: ids within 64 chars and not buggy shape"
  GATE5=1
  add_score 0.15
else
  echo "GATE5 FAIL: length/shape violation"
fi

echo "----- gates -----"
echo "GATE1=$GATE1 GATE2=$GATE2 GATE3=$GATE3 GATE4=$GATE4 GATE5=$GATE5"
echo "SCORE=$SCORE"
echo "-----------------"

REWARD="$SCORE"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0