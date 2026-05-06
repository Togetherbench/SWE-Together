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

if ! command -v "$BUN" >/dev/null 2>&1 && [ ! -x "$BUN" ]; then
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

SHARED_FILE="/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.ts"

if [ ! -f "$SHARED_FILE" ]; then
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Gate weights (sum = 1.0)
#   G1 (0.10): driver runs without throwing
#   G2 (0.20): primary item-id (long Copilot raw id) is Codex-safe (no internal _,
#              ≤64 chars, or omitted) — addresses the literal bug
#   G3 (0.15): second distinct foreign id ALSO becomes safe — i.e., the fix
#              applies generally, not just to the example string
#   G4 (0.15): determinism — same input twice → same output
#   G5 (0.15): function_call_output.call_id is the clean call_<alnum> prefix
#              (not the full "|"-mangled compound)
#   G6 (0.10): foreign ids from two distinct raw inputs are NOT collapsed to
#              the same id (collision check / actually using the input)
#   G7 (0.15): vitest run of the foreign-toolcall test file (if present) passes
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
  ["openai-codex", "gpt-5.2-codex"],
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

TEST_OUTPUT=$($BUN run /tmp/test_foreign_id.ts 2>&1)
echo "=== driver output (tail) ==="
echo "$TEST_OUTPUT" | tail -40
echo "============================"

JSON_LINE=$(echo "$TEST_OUTPUT" | grep '^__JSON__' | head -1 | sed 's/^__JSON__//')

if [ -z "$JSON_LINE" ]; then
  echo "Driver did not produce JSON; reward=0"
  echo "0.0" > /logs/verifier/reward.txt
  exit 0
fi

echo "$JSON_LINE" > /tmp/driver.json

extract() {
python3 - "$1" <<'PYEOF'
import json, sys
key = sys.argv[1]
with open('/tmp/driver.json') as f:
    d = json.loads(f.read())
v = d.get(key)
if v is None:
    print('__NULL__')
else:
    print(v)
PYEOF
}

THREW=$(extract threw)
ERR_MSG=$(extract errMsg)
FC1_ID=$(extract fc1_id)
FC1_CALL_ID=$(extract fc1_call_id)
FCO1_CALL_ID=$(extract fco1_call_id)
FC2_ID=$(extract fc2_id)
FC2_CALL_ID=$(extract fc2_call_id)
FCO2_CALL_ID=$(extract fco2_call_id)
FC1B_ID=$(extract fc1b_id)
FC1B_CALL_ID=$(extract fc1b_call_id)

echo "THREW=$THREW"
echo "FC1_ID=$FC1_ID"
echo "FC1_CALL_ID=$FC1_CALL_ID"
echo "FCO1_CALL_ID=$FCO1_CALL_ID"
echo "FC2_ID=$FC2_ID"
echo "FC2_CALL_ID=$FC2_CALL_ID"
echo "FC1B_ID=$FC1B_ID"

# Helpers for grading individual ids
is_null() {
  local v="$1"
  [ "$v" = "__NULL__" ] || [ -z "$v" ] || [ "$v" = "undefined" ] || [ "$v" = "null" ] || [ "$v" = "None" ]
}

# An id is "Codex-safe" if EITHER
#   - it's null/omitted (the "drop the id" school of fix), OR
#   - it matches ^fc_[A-Za-z0-9]+$ AND length ≤ 64 (the "hash the id" school).
# The buggy form is ^fc_[A-Za-z0-9]*_.*$ (underscore inside the body) — that
# fails because '/' '+' '=' got mapped to '_'.
is_codex_safe_item_id() {
  local v="$1"
  if is_null "$v"; then
    return 0
  fi
  local len=${#v}
  if [ "$len" -gt 64 ]; then
    return 1
  fi
  # Must start with fc_ and body must be alnum only (no _, no -, no |, no /, no +, no =)
  if echo "$v" | grep -qE '^fc_[A-Za-z0-9]+$'; then
    return 0
  fi
  return 1
}

# call_id should be the clean prefix call_<alnum>+ — never the mangled
# "call_xxx|fc_yyy" or "call_xxx_fc_yyy" compound form.
is_clean_call_id() {
  local v="$1"
  if is_null "$v"; then
    return 1
  fi
  if echo "$v" | grep -qE '^call_[A-Za-z0-9]+$'; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Gate scoring
# ─────────────────────────────────────────────────────────────────────────────
W1=0.10  # didn't throw
W2=0.20  # primary id is safe
W3=0.15  # second distinct id is safe
W4=0.15  # deterministic
W5=0.15  # call_id is clean prefix (both fc and fco)
W6=0.10  # distinct inputs → distinct outputs (no collapse)
W7=0.15  # vitest passes (foreign-toolcall test file)

S1=0.0; S2=0.0; S3=0.0; S4=0.0; S5=0.0; S6=0.0; S7=0.0

# G1: driver didn't throw
if [ "$THREW" = "False" ] || [ "$THREW" = "false" ]; then
  S1=$W1
  echo "G1 PASS: driver did not throw (+$W1)"
else
  echo "G1 FAIL: driver threw: $ERR_MSG"
fi

# G2: primary id safe
if is_codex_safe_item_id "$FC1_ID"; then
  S2=$W2
  echo "G2 PASS: fc1.id codex-safe ($FC1_ID) (+$W2)"
else
  echo "G2 FAIL: fc1.id not codex-safe: $FC1_ID"
fi

# G3: second id safe
if is_codex_safe_item_id "$FC2_ID"; then
  S3=$W3
  echo "G3 PASS: fc2.id codex-safe ($FC2_ID) (+$W3)"
else
  echo "G3 FAIL: fc2.id not codex-safe: $FC2_ID"
fi

# G4: determinism (only meaningful if id is non-null; if both null, also "deterministic")
if [ "$FC1_ID" = "$FC1B_ID" ]; then
  S4=$W4
  echo "G4 PASS: deterministic ($FC1_ID == $FC1B_ID) (+$W4)"
else
  echo "G4 FAIL: not deterministic: $FC1_ID vs $FC1B_ID"
fi

# G5: call_ids are clean prefix on both function_call and function_call_output
G5_FC=0
G5_FCO=0
if is_clean_call_id "$FC1_CALL_ID"; then G5_FC=1; fi
if is_clean_call_id "$FCO1_CALL_ID"; then G5_FCO=1; fi
if [ "$G5_FC" = "1" ] && [ "$G5_FCO" = "1" ]; then
  S5=$W5
  echo "G5 PASS: clean call_id on fc and fco ($FC1_CALL_ID / $FCO1_CALL_ID) (+$W5)"
elif [ "$G5_FC" = "1" ] || [ "$G5_FCO" = "1" ]; then
  S5=$(awk "BEGIN{printf \"%.4f\", $W5 * 0.5}")
  echo "G5 PARTIAL: only one of fc/fco has clean call_id (+$S5)"
else
  echo "G5 FAIL: call_ids not clean: fc=$FC1_CALL_ID fco=$FCO1_CALL_ID"
fi

# G6: distinct raw inputs → distinct outputs (no hash collapse / unconditional null)
# If both ids are null, that's still acceptable behavior (omit-id strategy) — but
# we still want some signal that the function used the input. We accept either:
#   (a) fc1.id != fc2.id (different non-null ids), OR
#   (b) both null AND fc1.call_id != fc2.call_id (call_ids differ — input was used)
G6_OK=0
if ! is_null "$FC1_ID" && ! is_null "$FC2_ID" && [ "$FC1_ID" != "$FC2_ID" ]; then
  G6_OK=1
elif is_null "$FC1_ID" && is_null "$FC2_ID"; then
  if ! is_null "$FC1_CALL_ID" && ! is_null "$FC2_CALL_ID" && [ "$FC1_CALL_ID" != "$FC2_CALL_ID" ]; then
    G6_OK=1
  fi
fi
if [ "$G6_OK" = "1" ]; then
  S6=$W6
  echo "G6 PASS: distinct inputs produced distinct outputs (+$W6)"
else
  echo "G6 FAIL: outputs collapsed for distinct inputs"
fi

# G7: run vitest if a relevant test file is present
VITEST_BIN=""
for cand in /workspace/pi-mono/node_modules/.bin/vitest /workspace/pi-mono/packages/ai/node_modules/.bin/vitest; do
  [ -x "$cand" ] && VITEST_BIN="$cand" && break
done

TEST_FILE=""
for cand in \
  /workspace/pi-mono/packages/ai/test/openai-responses-foreign-toolcall-id.test.ts \
  /workspace/pi-mono/packages/ai/test/openai-responses-foreign-toolcall.test.ts; do
  [ -f "$cand" ] && TEST_FILE="$cand" && break
done

if [ -n "$VITEST_BIN" ] && [ -n "$TEST_FILE" ]; then
  echo "Running vitest on $TEST_FILE"
  cd /workspace/pi-mono/packages/ai
  VITEST_OUT=$("$VITEST_BIN" run "$TEST_FILE" --reporter=verbose 2>&1)
  echo "$VITEST_OUT" | tail -50
  PASSED=$(echo "$VITEST_OUT" | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+')
  FAILED=$(echo "$VITEST_OUT" | grep -oE '[0-9]+ failed' | head -1 | grep -oE '[0-9]+')
  [ -z "$PASSED" ] && PASSED=0
  [ -z "$FAILED" ] && FAILED=0
  if [ "$PASSED" -gt 0 ] && [ "$FAILED" -eq 0 ]; then
    S7=$W7
    echo "G7 PASS: $PASSED vitest cases passed (+$W7)"
  elif [ "$PASSED" -gt 0 ] && [ "$FAILED" -gt 0 ]; then
    TOTAL=$((PASSED + FAILED))
    S7=$(awk "BEGIN{printf \"%.4f\", $W7 * $PASSED / $TOTAL}")
    echo "G7 PARTIAL: $PASSED/$TOTAL passed (+$S7)"
  else
    echo "G7 FAIL: vitest failed or 0 passed"
  fi
  cd /workspace/pi-mono
else
  # No test file present (e.g. agent didn't add one). Substitute an inline
  # behavioral check: the buggy substring `fc_I9b95oN1wD_cHXKTw3` (or any
  # underscore-after-fc_ in body) must NOT appear anywhere in fc1.id, fc2.id,
  # fc1.call_id, fco1.call_id. This catches the literal regression.
  echo "No vitest file or vitest binary; using inline behavioral substitute for G7"
  BUG_PRESENT=0
  for v in "$FC1_ID" "$FC2_ID" "$FC1_CALL_ID" "$FCO1_CALL_ID" "$FC2_CALL_ID" "$FCO2_CALL_ID"; do
    if ! is_null "$v"; then
      # Buggy: fc_<alnum>_<alnum> OR call_<alnum>|... OR contains | / + =
      if echo "$v" | grep -qE '[/+=|]'; then
        BUG_PRESENT=1
        echo "  buggy raw chars in: $v"
      fi
      if echo "$v" | grep -qE '^fc_[A-Za-z0-9]+_[A-Za-z0-9]'; then
        BUG_PRESENT=1
        echo "  buggy fc_ underscore body in: $v"
      fi
    fi
  done
  if [ "$BUG_PRESENT" = "0" ]; then
    S7=$W7
    echo "G7 PASS (inline): no buggy fragments in any id (+$W7)"
  else
    echo "G7 FAIL (inline): buggy fragment detected"
  fi
fi

REWARD=$(awk "BEGIN{printf \"%.4f\", $S1 + $S2 + $S3 + $S4 + $S5 + $S6 + $S7}")
echo "---"
echo "G1=$S1 G2=$S2 G3=$S3 G4=$S4 G5=$S5 G6=$S6 G7=$S7"
echo "REWARD=$REWARD"

echo "$REWARD" > /logs/verifier/reward.txt
# ---- v5: orchestrator-wrapped appended block ----
_v5_run_upstream_appended() {
  set +e  # never abort the host script from inside the wrapper


# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
: > "$GATES_FILE"

BUN_CMD=$(command -v bun 2>/dev/null)
if [ -z "$BUN_CMD" ]; then
  for cand in /root/.bun/bin/bun /usr/local/bin/bun /workspace/pi-mono/node_modules/.bin/bun; do
    [ -x "$cand" ] && BUN_CMD="$cand" && break
  done
fi
[ -z "$BUN_CMD" ] && BUN_CMD="bun"

# F2P gate 1: function_call.id is properly hashed fc_<hash>
echo "=== Upstream F2P gate: f2p_upstream_item_id_hashed ==="
cat > /tmp/_f2p_item_id.ts << 'TSEOF'
import { convertResponsesMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.js";
import { getModel } from "/workspace/pi-mono/packages/ai/src/models.js";
import type { AssistantMessage, Context, ToolResultMessage, Usage } from "/workspace/pi-mono/packages/ai/src/types.js";
const RAW_ID = "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";
const u: Usage = { input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };
let model: any = null;
for (const [p,m] of [["openai-codex","gpt-5.1"],["openai-codex","gpt-5.1-codex"],["openai-codex","gpt-5.3-codex"],["openai-codex","gpt-5"],["openai-codex","gpt-5-codex"],["openai-codex","gpt-5.2-codex"]]) { try { model = getModel(p as any, m as any); break; } catch {} }
if (!model) { process.exit(1); }
const now = Date.now();
const a: AssistantMessage = { role:"assistant", content:[{type:"toolCall",id:RAW_ID,name:"edit",arguments:{path:"x"}}], api:"openai-responses" as any, provider:"github-copilot" as any, model:"gpt-5.1-codex", usage:u, stopReason:"toolUse", timestamp:now-2000 };
const tr: ToolResultMessage = { role:"toolResult", toolCallId:RAW_ID, toolName:"edit", content:[{type:"text",text:"ok"}], isError:false, timestamp:now-1000 };
const ctx: Context = { systemPrompt:"t", messages:[{role:"user",content:"x",timestamp:now-3000},a,tr] };
const items = convertResponsesMessages(model, ctx, new Set());
const fc = items.find((i:any) => i.type === "function_call") as any;
if (!fc || !fc.id || typeof fc.id !== "string" || !/^fc_[A-Za-z0-9]+$/.test(fc.id) || fc.id.length > 64) process.exit(1);
process.exit(0);
TSEOF
if "$BUN_CMD" run /tmp/_f2p_item_id.ts 2>&1; then
  echo '{"id":"f2p_upstream_item_id_hashed","passed":true,"detail":"function_call.id is fc_<hash>"}' >> "$GATES_FILE"
  echo "f2p_upstream_item_id_hashed: PASS"
else
  echo '{"id":"f2p_upstream_item_id_hashed","passed":false,"detail":"function_call.id not properly hashed"}' >> "$GATES_FILE"
  echo "f2p_upstream_item_id_hashed: FAIL"
fi

# F2P gate 2: function_call.call_id is clean prefix
echo "=== Upstream F2P gate: f2p_upstream_call_id_clean ==="
cat > /tmp/_f2p_call_id.ts << 'TSEOF'
import { convertResponsesMessages } from "/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.js";
import { getModel } from "/workspace/pi-mono/packages/ai/src/models.js";
import type { AssistantMessage, Context, ToolResultMessage, Usage } from "/workspace/pi-mono/packages/ai/src/types.js";
const RAW_ID = "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";
const u: Usage = { input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };
let model: any = null;
for (const [p,m] of [["openai-codex","gpt-5.1"],["openai-codex","gpt-5.1-codex"],["openai-codex","gpt-5.3-codex"],["openai-codex","gpt-5"],["openai-codex","gpt-5-codex"],["openai-codex","gpt-5.2-codex"]]) { try { model = getModel(p as any, m as any); break; } catch {} }
if (!model) { process.exit(1); }
const now = Date.now();
const a: AssistantMessage = { role:"assistant", content:[{type:"toolCall",id:RAW_ID,name:"edit",arguments:{path:"x"}}], api:"openai-responses" as any, provider:"github-copilot" as any, model:"gpt-5.1-codex", usage:u, stopReason:"toolUse", timestamp:now-2000 };
const tr: ToolResultMessage = { role:"toolResult", toolCallId:RAW_ID, toolName:"edit", content:[{type:"text",text:"ok"}], isError:false, timestamp:now-1000 };
const ctx: Context = { systemPrompt:"t", messages:[{role:"user",content:"x",timestamp:now-3000},a,tr] };
const items = convertResponsesMessages(model, ctx, new Set());
const fc = items.find((i:any) => i.type === "function_call") as any;
if (!fc || !fc.call_id || typeof fc.call_id !== "string" || !/^call_[A-Za-z0-9]+$/.test(fc.call_id)) process.exit(1);
process.exit(0);
TSEOF
if "$BUN_CMD" run /tmp/_f2p_call_id.ts 2>&1; then
  echo '{"id":"f2p_upstream_call_id_clean","passed":true,"detail":"function_call.call_id is clean prefix"}' >> "$GATES_FILE"
  echo "f2p_upstream_call_id_clean: PASS"
else
  echo '{"id":"f2p_upstream_call_id_clean","passed":false,"detail":"function_call.call_id is mangled compound"}' >> "$GATES_FILE"
  echo "f2p_upstream_call_id_clean: FAIL"
fi

# P2P gate 1: vitest on foreign-toolcall-id test
echo "=== Upstream P2P gate: p2p_upstream_vitest_foreign_id ==="
VITEST_BIN=""
for cand in /workspace/pi-mono/node_modules/.bin/vitest /workspace/pi-mono/packages/ai/node_modules/.bin/vitest; do
  [ -x "$cand" ] && VITEST_BIN="$cand" && break
done
TEST_FILE="/workspace/pi-mono/packages/ai/test/openai-responses-foreign-toolcall-id.test.ts"
if [ -n "$VITEST_BIN" ] && [ -f "$TEST_FILE" ]; then
  cd /workspace/pi-mono/packages/ai
  if "$VITEST_BIN" run "$TEST_FILE" --reporter=verbose 2>&1 | tail -10; then
    echo '{"id":"p2p_upstream_vitest_foreign_id","passed":true,"detail":"vitest passed"}' >> "$GATES_FILE"
    echo "p2p_upstream_vitest_foreign_id: PASS"
  else
    echo '{"id":"p2p_upstream_vitest_foreign_id","passed":false,"detail":"vitest failed"}' >> "$GATES_FILE"
    echo "p2p_upstream_vitest_foreign_id: FAIL"
  fi
  cd /workspace/pi-mono
else
  echo '{"id":"p2p_upstream_vitest_foreign_id","passed":true,"detail":"vitest or test file not found, skip"}' >> "$GATES_FILE"
  echo "p2p_upstream_vitest_foreign_id: SKIP (no vitest or test file)"
fi

# P2P gate 2: tsgo type check (scoped to agent-touched .ts/.tsx files)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
echo "=== Upstream P2P gate: p2p_upstream_tsgo (scoped) ==="
cd /workspace/pi-mono
CHANGED_TS_FILES=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
  echo '{"id":"p2p_upstream_tsgo","passed":true,"detail":"no agent .ts/.tsx changes — gate skipped"}' >> "$GATES_FILE"
  echo "p2p_upstream_tsgo: PASS (no agent .ts/.tsx changes — gate skipped)"
elif npx tsgo --noEmit $CHANGED_TS_FILES 2>&1; then
  echo '{"id":"p2p_upstream_tsgo","passed":true,"detail":"tsgo passed on agent-changed files"}' >> "$GATES_FILE"
  echo "p2p_upstream_tsgo: PASS"
else
  echo '{"id":"p2p_upstream_tsgo","passed":false,"detail":"tsgo failed on agent-changed files"}' >> "$GATES_FILE"
  echo "p2p_upstream_tsgo: FAIL"
fi

# ---- upstream reward tail ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_item_id_hashed": 0.20, "f2p_upstream_call_id_clean": 0.20}
P2P_REGRESSION = ["p2p_upstream_vitest_foreign_id", "p2p_upstream_tsgo"]
TOTAL_F2P_WEIGHT = sum(WEIGHTS.values())  # 0.40
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
# P2P regression: any failure zeros everything
# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
hard_zero = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
if hard_zero:
    reward = 0.0
else:
    # F2P gates are behavioral tests for the actual bug.
    # If none passed, the bug isn't fixed -> zero reward.
    f2p_earned = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            f2p_earned += w
    f2p_any_passed = f2p_earned > 0
    if WEIGHTS and not f2p_any_passed:
        reward = 0.0
    else:
        # Scale existing reward to make room for F2P weight
        scaled_existing = existing * (1.0 - TOTAL_F2P_WEIGHT)
        reward = scaled_existing + f2p_earned
        reward = min(reward, 1.0)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM_REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYEOF
# ---- end ----
}
# Run via subshell so even unhandled `exit N` in the wrapper
# only kills the subshell, not the host. Exit codes ignored.
( _v5_run_upstream_appended ) || true
# ---- end v5 wrapper ----
