#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono foreign tool-call ID fix
# =============================================================================
# The bug: normalizeToolCallId in openai-responses-shared.ts does simple
# character replacement on foreign (cross-provider) tool-call IDs, producing
# IDs that the OpenAI Codex backend rejects. The fix should detect foreign
# tool calls and hash the item ID into a short, valid fc_<hash> form.
#
# Weight breakdown:
#   P2P (0.05) TypeScript compilation
#   P2P (0.05) Source structure
#   F2P (0.20) Primary Copilot ID not buggy
#   F2P (0.20) Primary Copilot ID valid format
#   F2P (0.25) Foreign detection logic
#   F2P (0.25) Second foreign ID generality
#   Total: 1.00
# =============================================================================

# Nop score: 0.10  (P2P gates only — tsc compiles, source file exists)

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
echo "0.0" > "$REWARD_FILE"

REWARD=0.0
SRC_FILE="/workspace/pi-mono/packages/ai/src/providers/openai-responses-shared.ts"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate 1: TypeScript compilation of packages/ai
# weight: 0.05
# Should pass on both unmodified base and correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo "=== P2P Gate 1: TypeScript compilation ==="
TSC_OUT=$(cd /workspace/pi-mono && npx tsc --noEmit --project packages/ai/tsconfig.build.json 2>&1)
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS: TypeScript compiles cleanly"
    add_reward 0.05
else
    echo "FAIL: TypeScript compilation errors:"
    echo "$TSC_OUT" | tail -20
fi

# ─────────────────────────────────────────────────────────────────────────────
# P2P Gate 2: Source file exists and exports convertResponsesMessages
# weight: 0.05
# Should pass on both unmodified base and correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== P2P Gate 2: Source file structure ==="
if [ -f "$SRC_FILE" ] && grep -q "export function convertResponsesMessages" "$SRC_FILE"; then
    echo "PASS: Source file exists with convertResponsesMessages export"
    add_reward 0.05
else
    echo "FAIL: Source file missing or convertResponsesMessages not found"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 3a: Primary Copilot ID NOT the buggy sanitised value
# weight: 0.20
# Tests that the exact problematic Copilot ID from the bug report
# no longer produces the buggy fc_I9b95oN1wD_... string.
# Fails on unmodified base, passes on correct fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 3a: Primary Copilot ID not buggy ==="
GATE3A_OUT=$(cd /workspace/pi-mono && bun -e "
import { getModel } from './packages/ai/src/models.js';
import { convertResponsesMessages } from './packages/ai/src/providers/openai-responses-shared.js';

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };

const COPILOT_RAW_ID = 'call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==';
const BUGGY_ITEM_ID = 'fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi';

const model = getModel('openai-codex', 'gpt-5.3-codex');
const ctx = {
    systemPrompt: 'test',
    messages: [
        { role: 'user', content: 'hi', timestamp: Date.now() - 3000 },
        {
            role: 'assistant',
            content: [{ type: 'toolCall', id: COPILOT_RAW_ID, name: 'edit', arguments: { path: 'a.css' } }],
            api: 'openai-responses', provider: 'github-copilot', model: 'gpt-5.3-codex',
            usage, stopReason: 'toolUse', timestamp: Date.now() - 2000,
        },
        {
            role: 'toolResult', toolCallId: COPILOT_RAW_ID, toolName: 'edit',
            content: [{ type: 'text', text: 'ok' }], isError: false, timestamp: Date.now() - 1000,
        },
    ],
};

const input = convertResponsesMessages(model, ctx, new Set(['openai', 'openai-codex', 'opencode']));
const fc = input.find((i) => i.type === 'function_call');
const id = fc?.id ?? '';
const notBuggy = id !== BUGGY_ITEM_ID && id !== '';
console.log(JSON.stringify({ id, notBuggy }));
" 2>&1)
GATE3A_EXIT=$?

if [ $GATE3A_EXIT -ne 0 ]; then
    echo "FAIL: Gate 3a test crashed"
    echo "$GATE3A_OUT" | tail -5
else
    G3A_JSON=$(echo "$GATE3A_OUT" | grep '^{' | tail -1)
    G3A_NB=$(echo "$G3A_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('notBuggy',False))" 2>&1)
    G3A_ID=$(echo "$G3A_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','?'))" 2>&1)

    if [ "$G3A_NB" = "True" ]; then
        echo "PASS: Foreign Copilot ID is not the buggy value (id=$G3A_ID)"
        add_reward 0.20
    else
        echo "FAIL: Foreign ID is still the buggy sanitised value (id=$G3A_ID)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 3b: Primary Copilot ID has valid Codex format
# weight: 0.20
# The normalised ID must: start with fc_, be <= 64 chars, only [a-zA-Z0-9_].
# Fails on base (buggy ID matches format but is wrong), passes on fix.
# This gate is gated on 3a passing (buggy ID has valid format).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 3b: Primary Copilot ID valid format ==="
if [ "$G3A_NB" = "True" ]; then
    G3B_FMT=$(echo "$G3A_JSON" | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
id=d.get('id','')
ok = id.startswith('fc_') and 0 < len(id) <= 64 and bool(re.match(r'^[a-zA-Z0-9_]+$', id))
print('True' if ok else 'False')
print(f'len={len(id)} prefix={id[:4]}')
" 2>&1)
    G3B_OK=$(echo "$G3B_FMT" | head -1)
    G3B_DETAIL=$(echo "$G3B_FMT" | tail -1)

    if [ "$G3B_OK" = "True" ]; then
        echo "PASS: ID has valid Codex format ($G3B_DETAIL)"
        add_reward 0.20
    else
        echo "FAIL: ID format invalid ($G3B_DETAIL, id=$G3A_ID)"
    fi
else
    echo "SKIP: Gate 3a failed, skipping format check"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 4: Foreign detection — different treatment for foreign
# vs same-provider IDs. Uses a shorter Copilot ID.
# weight: 0.25
# Fails on base (ignores source param), passes on fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 4: Foreign detection logic ==="
GATE4_OUT=$(cd /workspace/pi-mono && bun -e "
import { getModel } from './packages/ai/src/models.js';
import { convertResponsesMessages } from './packages/ai/src/providers/openai-responses-shared.js';

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };

const foreignAssistant = {
    role: 'assistant',
    content: [{ type: 'toolCall', id: 'call_XYZ|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi', name: 'edit', arguments: { path: 'a.ts' } }],
    api: 'openai-responses', provider: 'github-copilot', model: 'gpt-5.3-codex',
    usage, stopReason: 'toolUse', timestamp: Date.now() - 2000,
};

const model = getModel('openai-codex', 'gpt-5.3-codex');
const providers = new Set(['openai', 'openai-codex', 'opencode']);

const foreignCtx = {
    systemPrompt: 'test',
    messages: [
        { role: 'user', content: 'hi', timestamp: Date.now() - 3000 },
        foreignAssistant,
        { role: 'toolResult', toolCallId: 'call_XYZ|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi', toolName: 'edit', content: [{ type: 'text', text: 'ok' }], isError: false, timestamp: Date.now() - 1000 },
    ],
};
const foreignInput = convertResponsesMessages(model, foreignCtx, providers);
const foreignFc = foreignInput.find((i) => i.type === 'function_call');

const simpleSanitised = 'fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi';
const foreignId = foreignFc?.id ?? '';
const foreignOk = foreignId !== simpleSanitised && foreignId !== '' && foreignId.startsWith('fc_') && foreignId.length <= 64 && /^[a-zA-Z0-9_]+$/.test(foreignId);

console.log(JSON.stringify({ foreignId, foreignOk }));
" 2>&1)
GATE4_EXIT=$?

if [ $GATE4_EXIT -ne 0 ]; then
    echo "FAIL: Gate 4 test crashed"
    echo "$GATE4_OUT" | tail -5
else
    G4_JSON=$(echo "$GATE4_OUT" | grep '^{' | tail -1)
    G4_OK=$(echo "$G4_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('foreignOk',False))" 2>&1)
    G4_ID=$(echo "$G4_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('foreignId','?'))" 2>&1)

    if [ "$G4_OK" = "True" ]; then
        echo "PASS: Foreign ID properly differentiated (id=$G4_ID)"
        add_reward 0.25
    else
        echo "FAIL: Foreign ID not properly differentiated (id=$G4_ID)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 5: Second foreign ID — generality check.
# weight: 0.25
# Uses a different raw Copilot ID to ensure the fix is general.
# Fails on base, passes on fix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 5: Second foreign ID (generality) ==="
GATE5_OUT=$(cd /workspace/pi-mono && bun -e "
import { getModel } from './packages/ai/src/models.js';
import { convertResponsesMessages } from './packages/ai/src/providers/openai-responses-shared.js';

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };
const COPILOT_ID_2 = 'call_vs1eoMWtUBKjTmXJjM9clHiF|X90bLu7itE+qX5vORjDhfNHnWPBttLg03yQnnCIPeBwSrORnhuil386M75H4pZXovYK2ij0bxA==';

const model = getModel('openai-codex', 'gpt-5.3-codex');
const ctx = {
    systemPrompt: 'test',
    messages: [
        { role: 'user', content: 'hi', timestamp: Date.now() - 3000 },
        {
            role: 'assistant',
            content: [{ type: 'toolCall', id: COPILOT_ID_2, name: 'edit', arguments: { path: 'b.ts' } }],
            api: 'openai-responses', provider: 'github-copilot', model: 'gpt-5.3-codex',
            usage, stopReason: 'toolUse', timestamp: Date.now() - 2000,
        },
        {
            role: 'toolResult', toolCallId: COPILOT_ID_2, toolName: 'edit',
            content: [{ type: 'text', text: 'ok' }], isError: false, timestamp: Date.now() - 1000,
        },
    ],
};

const input = convertResponsesMessages(model, ctx, new Set(['openai', 'openai-codex', 'opencode']));
const fc = input.find((i) => i.type === 'function_call');
const id = fc?.id ?? '';

const ok = id.startsWith('fc_') && id.length <= 64 && id.length > 0 && /^[a-zA-Z0-9_]+$/.test(id);
const notSimple = !id.includes('X90bLu7itE_qX5vORjDhfNH');
const allOk = ok && notSimple;
console.log(JSON.stringify({ id, allOk }));
" 2>&1)
GATE5_EXIT=$?

if [ $GATE5_EXIT -ne 0 ]; then
    echo "FAIL: Gate 5 test crashed"
    echo "$GATE5_OUT" | tail -5
else
    G5_JSON=$(echo "$GATE5_OUT" | grep '^{' | tail -1)
    G5_OK=$(echo "$G5_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('allOk',False))" 2>&1)
    G5_ID=$(echo "$G5_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','?'))" 2>&1)

    if [ "$G5_OK" = "True" ]; then
        echo "PASS: Second foreign ID normalised correctly (id=$G5_ID)"
        add_reward 0.25
    else
        echo "FAIL: Second foreign ID not properly normalised (id=$G5_ID)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final score
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Final Score ==="
REWARD=$(awk -v r="$REWARD" 'BEGIN{if(r>1)r=1; if(r<0)r=0; printf "%.4f", r}')
echo "$REWARD" > "$REWARD_FILE"
echo "Reward: $REWARD"
