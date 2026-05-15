#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono foreign tool-call ID fix
#
# Bug: convertResponsesMessages() in openai-responses-shared.ts mishandles
# tool-call IDs when a conversation switches providers/APIs:
#   - Pipe-separated "call_xxx|item_yyy" IDs from one provider, replayed onto
#     a target whose provider is NOT in allowedToolCallProviders, get fed to
#     normalizeIdPart() as a single string — the "|" becomes "_" and the
#     resulting call_id is a mangled 64-char composite that the API rejects.
#   - Bare long fc_xxx IDs (no pipe) routed to a Responses target may exceed
#     the 40/64-char limit if not hashed.
#
# Reward only comes from BEHAVIORAL differences between buggy base and fix.
# =============================================================================

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
echo "0.0" > "$REWARD_FILE"

REWARD=0.0
REPO_ROOT="/workspace/pi-mono"
SRC_FILE="$REPO_ROOT/packages/ai/src/providers/openai-responses-shared.ts"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    echo ""
    echo "=== FINAL REWARD: $REWARD ==="
    exit 0
}

export PATH="/root/.bun/bin:/usr/local/bun/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v bun >/dev/null 2>&1; then
    BUN_BIN=$(find /root /usr/local /opt -maxdepth 5 -name bun -type f -executable 2>/dev/null | head -1)
    if [ -n "$BUN_BIN" ]; then export PATH="$(dirname "$BUN_BIN"):$PATH"; fi
fi

if [ ! -d "$REPO_ROOT" ]; then
    echo "FAIL: Repo root not found at $REPO_ROOT"
    finish
fi

if [ ! -f "$SRC_FILE" ]; then
    echo "FAIL: Required source file not found: $SRC_FILE"
    finish
fi

# ─────────────────────────────────────────────────────────────────────────────
# P2P GATE (diagnostic/penalty only, no reward): TypeScript still compiles.
# This guards against destructive edits but DOES NOT award reward — it passes
# on the unmodified buggy base.
# ─────────────────────────────────────────────────────────────────────────────
echo "=== P2P Gate: TypeScript compilation (diagnostic, no reward) ==="
TSC_OUT=$(cd "$REPO_ROOT" && npx --no-install tsc --noEmit --project packages/ai/tsconfig.build.json 2>&1)
TSC_EXIT=$?
if [ $TSC_EXIT -ne 0 ]; then
    echo "REGRESSION: TypeScript compilation broken — refusing to award reward."
    echo "WARNING: P2P gate failed (informational only, continuing)"
fi
echo "PASS (diagnostic): tsc clean."

# ─────────────────────────────────────────────────────────────────────────────
# P2P GATE (diagnostic/penalty only): convertResponsesMessages still exists and is exported.
# ─────────────────────────────────────────────────────────────────────────────
if ! grep -q "convertResponsesMessages" "$SRC_FILE"; then
    echo "REGRESSION: convertResponsesMessages missing from source."
    REWARD=0.0
    finish
fi

# ─────────────────────────────────────────────────────────────────────────────
# Behavioral harness: drive convertResponsesMessages with several inputs that
# differentiate buggy vs fixed behavior.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Building behavioral harness ==="

HARNESS=$(cat <<'EOF'
import { getModel } from "./packages/ai/src/models.js";
import { convertResponsesMessages } from "./packages/ai/src/providers/openai-responses-shared.js";

const usage = { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} };

// Real failing pipe-id from the bug report (call_id|base64-with-/+= item_id).
const COPILOT_PIPE_ID = "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";
const EXPECTED_CALL_PREFIX = "call_4VnzVawQXPB9MgYib7CiQFEY";

// Bare fc_ id over 40 chars — replayed onto codex (foreign).
const BARE_FC_ID = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi";

// Short pipe id, same provider/api as target — should round-trip cleanly.
const SHORT_PIPE_ID = "call_XYZ123abc|fc_shortItemAbc";

function makeCtx(toolId, srcProvider, srcApi) {
    return {
        systemPrompt: "test",
        messages: [
            { role: "user", content: "hi", timestamp: Date.now() - 4000 },
            {
                role: "assistant",
                content: [{ type: "toolCall", id: toolId, name: "edit", arguments: { path: "a.css" } }],
                api: srcApi, provider: srcProvider, model: "gpt-5.3-codex",
                usage, stopReason: "toolUse", timestamp: Date.now() - 2000,
            },
            {
                role: "toolResult", toolCallId: toolId, toolName: "edit",
                content: [{ type: "text", text: "ok" }], isError: false, timestamp: Date.now() - 1000,
            },
        ],
    };
}

function tryConvert(targetProvider, targetModel, ctx) {
    // Use the conservative (buggy-base) allowedToolCallProviders set so a fix that
    // ONLY widens the set doesn't get free credit when the target is e.g. github-copilot.
    const providers = new Set(["openai", "openai-codex", "opencode"]);
    try {
        const model = getModel(targetProvider, targetModel);
        const input = convertResponsesMessages(model, ctx, providers);
        const fc = input.find((i) => i.type === "function_call");
        const fco = input.find((i) => i.type === "function_call_output");
        return {
            ok: true,
            id: fc ? (fc.id ?? null) : null,
            call_id: fc ? (fc.call_id ?? null) : null,
            output_call_id: fco ? (fco.call_id ?? null) : null,
            ids_match: fc && fco ? fc.call_id === fco.call_id : false,
        };
    } catch (e) {
        return { ok: false, error: String(e && e.message ? e.message : e) };
    }
}

const results = {};

// A: foreign Copilot pipe-id replayed onto github-copilot (NOT in providers set).
//    Buggy base: feeds the whole pipe string through normalizeIdPart, producing a
//    long mangled call_id with no "|" but length close to 64 and definitely
//    containing the substituted underscores from "/" and "+".
//    Fix: must extract just the call_id portion (or otherwise produce a clean id
//    that does NOT contain the buggy "_cHXKTw3" tail substring).
results.A = tryConvert("github-copilot", "gpt-5.1-codex", makeCtx(COPILOT_PIPE_ID, "openai-codex", "openai-codex-responses"));

// B: foreign Copilot pipe-id replayed onto openai-codex (IN providers set).
//    Buggy base: returns "<call>|<item-with-direct-substitution>" where the
//    item portion is the truncated/underscored item id — a known bad shape.
//    Fix: returns a hashed/short item portion, OR omits id, OR otherwise differs
//    from the exact buggy substitution.
results.B = tryConvert("openai-codex", "gpt-5.3-codex", makeCtx(COPILOT_PIPE_ID, "github-copilot", "openai-responses"));

// C: bare fc_ id (>40 chars, foreign) onto openai-codex.
//    Must not crash. Output call_id must be ≤64 and match output's call_id.
results.C = tryConvert("openai-codex", "gpt-5.3-codex", makeCtx(BARE_FC_ID, "github-copilot", "openai-responses"));

// D: short, same-provider/same-api pipe id onto openai-codex — sanity round-trip.
results.D = tryConvert("openai-codex", "gpt-5.3-codex", makeCtx(SHORT_PIPE_ID, "openai-codex", "openai-codex-responses"));

console.log("EXPECTED_CALL_PREFIX=" + EXPECTED_CALL_PREFIX);
console.log("===RESULTS===");
console.log(JSON.stringify(results));
EOF
)

HARNESS_OUT=$(cd "$REPO_ROOT" && bun -e "$HARNESS" 2>&1)
HARNESS_EXIT=$?
echo "--- harness output (tail) ---"
echo "$HARNESS_OUT" | tail -20
echo "--- end harness output ---"

RESULTS_JSON=$(echo "$HARNESS_OUT" | awk '/^===RESULTS===$/{flag=1;next} flag' | head -1)

if [ -z "$RESULTS_JSON" ]; then
    echo "Harness failed to produce results — reward stays 0."
    finish
fi

echo "RESULTS: $RESULTS_JSON"

# Helper: run a python predicate against $RESULTS_JSON, echoing 1/0.
predicate() {
    python3 - "$RESULTS_JSON" <<PYEOF
import json, sys, re
d = json.loads(sys.argv[1])
$1
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 1 (0.30): Scenario A — pipe-id onto github-copilot (provider NOT in
# allowedToolCallProviders) must produce a clean call_id, not the mangled
# direct-substitution of the entire pipe string.
#
# On buggy base, normalizeIdPart is applied to the whole "call_xxx|item..." —
# the "|" becomes "_", and the call_id contains the substring "_cHXKTw3" (from
# the item id's "/cHXKTw3" → "_cHXKTw3"). On fixes, the call_id is either the
# clean prefix "call_4VnzVawQXPB9MgYib7CiQFEY" or a hashed form, but in either
# case must NOT contain that buggy "_cHXKTw3" tail and must NOT include "|".
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 1: pipe-id → github-copilot produces clean call_id (0.30) ==="
G1=$(predicate '
r = d.get("A", {})
ok = r.get("ok") is True
cid = r.get("call_id") or ""
# Must succeed, must produce a call_id
if not ok or not cid:
    print(0); sys.exit()
# Must not contain pipe (proves "|" was handled, not blindly substituted)
if "|" in cid:
    print(0); sys.exit()
# Must not contain the tell-tale buggy substring from direct substitution
# of the full pipe string. The buggy normalizeIdPart turns "/" and "+" into "_"
# so the head of the item portion "I9b95oN1wD/cHXKTw3" becomes "I9b95oN1wD_cHXKTw3".
# Any presence of that substring inside call_id means the buggy pipe-flattening
# leaked through.
if "I9b95oN1wD_cHXKTw3" in cid:
    print(0); sys.exit()
# Must be within Responses-API length bound
if len(cid) > 64:
    print(0); sys.exit()
# call_id must match output_call_id for tool result pairing
if r.get("call_id") != r.get("output_call_id"):
    print(0); sys.exit()
# Must match allowed character class
if not re.match(r"^[a-zA-Z0-9_-]+$", cid):
    print(0); sys.exit()
print(1)
')
if [ "$G1" = "1" ]; then
    echo "PASS"
    add_reward 0.30
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 2 (0.25): Scenario B — pipe-id onto openai-codex must produce a
# function_call.id that is NOT the buggy direct-substitution string.
#
# Buggy base path (id has "|" AND target IS in allowed set) splits the pipe
# and runs normalizeIdPart on each half. The item half — the long base64 with
# "/" and "+" — gets character-substituted in place. A correct fix either:
#   - hashes the foreign item id to a short fc_<hash> (Kimi/Opus style), OR
#   - omits the id (some implementations set id=undefined for foreign), OR
#   - otherwise produces an id whose item portion is NOT the exact 64-char
#     buggy substitution.
#
# The buggy-base item portion is exactly:
#   "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"
# (length 64, comes from sanitize+truncate of the base64 item id).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 2: pipe-id → openai-codex avoids buggy item substitution (0.25) ==="
G2=$(predicate '
r = d.get("B", {})
if not r.get("ok"):
    print(0); sys.exit()
buggy_item = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"
fid = r.get("id")
cid = r.get("call_id") or ""
# call_id must be clean prefix
if not cid.startswith("call_4VnzVawQXPB9MgYib7CiQFEY"):
    print(0); sys.exit()
# Whatever shape the fix uses, function_call.id must NOT be the literal
# buggy direct-substitution item string, and must NOT be a "<call>|<buggy>"
# composite either.
if fid is not None:
    if fid == buggy_item:
        print(0); sys.exit()
    if isinstance(fid, str) and buggy_item in fid:
        print(0); sys.exit()
    # Must satisfy the Responses API id constraint
    if not re.match(r"^[a-zA-Z0-9_|-]+$", fid):
        print(0); sys.exit()
    if len(fid) > 64:
        print(0); sys.exit()
# call_id and output call_id still must match
if r.get("call_id") != r.get("output_call_id"):
    print(0); sys.exit()
print(1)
')
if [ "$G2" = "1" ]; then
    echo "PASS"
    add_reward 0.25
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 3 (0.20): Scenario C — bare 63-char fc_ id (foreign) onto codex.
#
# Buggy base: id has no "|", so normalizeIdPart trims to 64 chars (passes
# through unchanged) and there is no fc_<hash>; furthermore the id is sent
# unchanged as call_id, which exceeds the Responses API's 40-char rule for
# call_ids in some configurations. More importantly, the buggy code has no
# branch for "bare foreign fc_ id" at all — it returns the 63-char raw id as
# both id and call_id. A correct fix shortens / hashes / drops it; specifically
# the call_id should NOT be the exact 63-char raw input, OR the function_call.id
# should differ from the raw input (proving foreign-aware handling).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 3: bare foreign fc_ id is normalized, not passed through (0.20) ==="
G3=$(predicate '
r = d.get("C", {})
if not r.get("ok"):
    print(0); sys.exit()
raw = "fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi"
cid = r.get("call_id") or ""
fid = r.get("id")
# Must produce a non-empty call_id that matches output
if not cid or r.get("call_id") != r.get("output_call_id"):
    print(0); sys.exit()
if len(cid) > 64 or not re.match(r"^[a-zA-Z0-9_|-]+$", cid):
    print(0); sys.exit()
# Foreign-aware fix differs from buggy passthrough in at least one of:
#   - call_id is no longer the raw 63-char string (e.g. hashed to call_<hash>)
#   - id differs from raw (hashed, undefined, or pipe-composite)
# Buggy base: cid == raw AND fid == raw.
if cid == raw and fid == raw:
    print(0); sys.exit()
print(1)
')
if [ "$G3" = "1" ]; then
    echo "PASS"
    add_reward 0.20
else
    echo "FAIL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 4 (0.15): Cross-scenario consistency — the new behavior must be
# narrowly targeted, not blanket. Specifically: same-provider/same-api SHORT
# pipe id (Scenario D) must STILL round-trip with a clean call_id matching
# the input's call_id prefix, and call_id == output_call_id. This guards
# against a "fix" that hashes everything indiscriminately and breaks the
# happy path.
#
# This passes on the buggy base too (it's a correctness invariant) — but
# Gate 4's reward is conditional on Gate 1 OR Gate 2 ALSO passing, so a
# no-op cannot collect it.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 4: same-provider short-id round-trip preserved (0.15, conditional) ==="
G4_OK=$(predicate '
r = d.get("D", {})
if not r.get("ok"):
    print(0); sys.exit()
cid = r.get("call_id") or ""
if not cid.startswith("call_XYZ123abc"):
    print(0); sys.exit()
if r.get("call_id") != r.get("output_call_id"):
    print(0); sys.exit()
if len(cid) > 64:
    print(0); sys.exit()
print(1)
')
if [ "$G4_OK" = "1" ] && { [ "$G1" = "1" ] || [ "$G2" = "1" ]; }; then
    echo "PASS"
    add_reward 0.15
else
    echo "FAIL or unconditioned (only counts if Gate 1 or Gate 2 also passed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# F2P Gate 5 (0.10): Source-level evidence that the agent altered tool-call
# ID handling in *some* deliberate way. This is awarded ONLY if at least one
# behavioral gate (1, 2, or 3) passed — so a no-op that touches nothing gets
# nothing here. The check tolerates any of the observed fix patterns:
#   - widened OPENAI_TOOL_CALL_PROVIDERS set to include "github-copilot"
#   - new branching on `id.includes("|")` inside the !allowed block
#   - changes to normalizeIdPart's length/sanitization
#   - new helper for foreign call_id (e.g. buildForeignCallId / shortHash on
#     callId)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== F2P Gate 5: deliberate tool-call-id handling change (0.10, conditional) ==="
EVIDENCE=0
# Pattern 1: github-copilot added to an allowed set
if grep -rEq 'TOOL_CALL_PROVIDERS[[:space:]]*=[[:space:]]*new Set\([^)]*github-copilot' "$REPO_ROOT/packages/ai/src/providers/" 2>/dev/null; then
    EVIDENCE=1
fi
# Pattern 2: explicit pipe handling inside the !allowedToolCallProviders branch
# (i.e. splitting the pipe before falling back to normalizeIdPart)
if [ $EVIDENCE -eq 0 ]; then
    if awk '/!allowedToolCallProviders\.has/{flag=1; depth=0} flag{print; if (/\{/) depth++; if (/\}/){depth--; if (depth<=0 && NR>1) {flag=0}}}' "$SRC_FILE" 2>/dev/null | grep -qE '\.split\("\|"\)|includes\("\|"\)|split\(.\|.\)'; then
        EVIDENCE=1
    fi
fi
# Pattern 3: a buildForeignCallId-style helper or shortHash applied to callId
if [ $EVIDENCE -eq 0 ]; then
    if grep -qE 'buildForeignCallId|shortHash\([^)]*callId|call_\$\{shortHash' "$SRC_FILE" 2>/dev/null; then
        EVIDENCE=1
    fi
fi
# Pattern 4: tightened normalizeIdPart length (40 instead of 64) — Kimi-style fix
if [ $EVIDENCE -eq 0 ]; then
    if awk '/normalizeIdPart[[:space:]]*=/{flag=1} flag{print; if (/};/) flag=0}' "$SRC_FILE" 2>/dev/null | grep -qE '\.slice\(0,[[:space:]]*40\)|>[[:space:]]*40'; then
        EVIDENCE=1
    fi
fi

if [ $EVIDENCE -eq 1 ] && { [ "$G1" = "1" ] || [ "$G2" = "1" ] || [ "$G3" = "1" ]; }; then
    echo "PASS: deliberate fix pattern detected and a behavioral gate passed"
    add_reward 0.10
else
    echo "FAIL or unconditioned"
fi

finish