#!/bin/bash
# Verifier for pi-mono-auto-1b58dd4f
#
# Bug: when no extensions are present at startup, `session.bindExtensions(...)`
# was gated behind an early-return on `!session.extensionRunner` (in
# interactive-mode.ts `initExtensions()`) or an `if (extensionRunner)` wrapper
# (in print-mode.ts / rpc-mode.ts). As a consequence the UI bindings (uiContext,
# command context actions, error listeners) were never registered. After
# `/reload`, when an extension that calls `ui.notify(...)` was loaded, the UI
# methods were undefined and the notification never fired.
#
# Upstream fix (commit 5dbeadae) makes `bindExtensions(...)` eager:
#  - interactive-mode.ts: bindExtensions() is now called BEFORE the
#    `!extensionRunner` early-return (the early-return moved to AFTER bind).
#  - print-mode.ts / rpc-mode.ts: drops the `if (extensionRunner)` wrapper —
#    bindExtensions(...) is unconditional at the top of mode setup.
#
# This verifier grades that fix surface (the canonical touches exactly these 4
# files). The previous test.sh asked for strings (`_applyExtensionBindings`,
# `reload re-applies bindings`) that have ZERO matches in pi-mono's entire git
# history; that hypothesis was wrong.
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

REPO=/workspace/pi-mono
cd "$REPO" 2>/dev/null || { echo "FAIL: repo not found"; echo 0.0 > "$REWARD_FILE"; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL: node missing"; echo 0.0 > "$REWARD_FILE"; exit 0; }

INTERACTIVE="packages/coding-agent/src/modes/interactive/interactive-mode.ts"
PRINT_MODE="packages/coding-agent/src/modes/print-mode.ts"
RPC_MODE="packages/coding-agent/src/modes/rpc/rpc-mode.ts"
CHANGELOG="packages/coding-agent/CHANGELOG.md"

mkdir -p /logs/verifier
GATES_JSON="/logs/verifier/gates.json"
> "$GATES_JSON"

# =============================================================================
# F2P Gate 1 (weight 0.30): interactive-mode.ts initExtensions() — eager bind
#
# In the buggy base, initExtensions() returns early on !extensionRunner BEFORE
# calling bindExtensions(). After the fix, bindExtensions() is called first,
# and only AFTER it returns do we check extensionRunner and possibly return.
#
# Behavioral check: inside initExtensions(), confirm that the FIRST occurrence
# of `bindExtensions(` precedes the FIRST `extensionRunner` early-return that
# bails out without bindExtensions having run.
#
# Implemented as: parse initExtensions() body, walk top-level statements in
# order, and verify that some statement awaits `*.bindExtensions(...)` BEFORE
# any if-statement whose body contains a bare `return` and whose condition
# tests `extensionRunner`.
# =============================================================================
echo ""
echo "=== F2P Gate 1: interactive-mode.ts initExtensions() — eager bindExtensions ==="

GATE1_RESULT=$(node -e '
const fs = require("fs");
const ts = require("typescript");
const path = "'"$INTERACTIVE"'";
if (!fs.existsSync(path)) { console.log("MISSING"); process.exit(0); }
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile(path, src, ts.ScriptTarget.Latest, true);

let initExt = null;
function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name && node.name.getText(sf) === "initExtensions" && node.body) {
        initExt = node;
    }
    ts.forEachChild(node, visit);
}
visit(sf);
if (!initExt) { console.log("NO_METHOD"); process.exit(0); }

const stmts = initExt.body.statements;
let bindIdx = -1;
let earlyReturnIdx = -1;

function containsBindExtensions(node) {
    let found = false;
    function w(n) {
        if (found) return;
        if (ts.isCallExpression(n)) {
            const expr = n.expression.getText(sf);
            if (/\bbindExtensions$/.test(expr)) { found = true; return; }
        }
        ts.forEachChild(n, w);
    }
    w(node);
    return found;
}

function isExtensionRunnerEarlyReturn(stmt) {
    // Looks like:
    //   const extensionRunner = this.session.extensionRunner;
    //   if (!extensionRunner) { ...; return; }
    // We accept either a VariableStatement that captures extensionRunner OR
    // an IfStatement gated on extensionRunner with a return inside.
    if (!ts.isIfStatement(stmt)) return false;
    const cond = stmt.expression.getText(sf);
    if (!/extensionRunner/.test(cond)) return false;
    // Check the then-block contains a return
    let hasReturn = false;
    function w(n) {
        if (ts.isReturnStatement(n)) hasReturn = true;
        ts.forEachChild(n, w);
    }
    w(stmt.thenStatement);
    return hasReturn;
}

for (let i = 0; i < stmts.length; i++) {
    if (bindIdx < 0 && containsBindExtensions(stmts[i])) bindIdx = i;
    if (earlyReturnIdx < 0 && isExtensionRunnerEarlyReturn(stmts[i])) earlyReturnIdx = i;
}

if (bindIdx < 0) { console.log("NO_BIND"); process.exit(0); }
if (earlyReturnIdx < 0) {
    // No early-return at all is also valid (fully unconditional bind)
    console.log("PASS_NO_EARLY_RETURN");
    process.exit(0);
}
if (bindIdx < earlyReturnIdx) { console.log("PASS"); process.exit(0); }
console.log("FAIL bind=" + bindIdx + " earlyReturn=" + earlyReturnIdx);
' 2>&1)

echo "Gate1 result: $GATE1_RESULT"
if echo "$GATE1_RESULT" | grep -qE "^PASS"; then
    echo "PASS: interactive-mode.ts initExtensions() binds extensions eagerly"
    echo '{"id":"f2p_interactive_eager_bind","passed":true,"detail":"bindExtensions called before extensionRunner early-return"}' >> "$GATES_JSON"
else
    echo "FAIL: interactive-mode.ts still gates bindExtensions on extensionRunner"
    echo '{"id":"f2p_interactive_eager_bind","passed":false,"detail":"'"$GATE1_RESULT"'"}' >> "$GATES_JSON"
fi

# =============================================================================
# F2P Gate 2 (weight 0.25): print-mode.ts — unconditional session.bindExtensions
#
# Buggy base wraps `await session.bindExtensions({...})` inside
#   const extensionRunner = session.extensionRunner;
#   if (extensionRunner) { await session.bindExtensions({...}); }
# Canonical drops the wrapper so bindExtensions runs unconditionally.
#
# Acceptance: a call to `session.bindExtensions(` exists at the top level of
# runPrintMode (i.e., NOT nested inside any if-statement whose condition tests
# `extensionRunner`).
# =============================================================================
echo ""
echo "=== F2P Gate 2: print-mode.ts runPrintMode — unconditional bindExtensions ==="

GATE2_RESULT=$(node -e '
const fs = require("fs");
const ts = require("typescript");
const path = "'"$PRINT_MODE"'";
if (!fs.existsSync(path)) { console.log("MISSING"); process.exit(0); }
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile(path, src, ts.ScriptTarget.Latest, true);

let fn = null;
function visit(node) {
    if (ts.isFunctionDeclaration(node) && node.name && node.name.getText(sf) === "runPrintMode" && node.body) {
        fn = node;
    }
    ts.forEachChild(node, visit);
}
visit(sf);
if (!fn) { console.log("NO_FN"); process.exit(0); }

let unconditional = false;
let conditionalOnly = false;

function findBindCalls(node, gatedByExtensionRunner) {
    if (ts.isCallExpression(node)) {
        const expr = node.expression.getText(sf);
        if (/\.bindExtensions$/.test(expr) && /\bsession\b|\bthis\.session\b/.test(expr)) {
            if (gatedByExtensionRunner) conditionalOnly = true;
            else unconditional = true;
        }
    }
    if (ts.isIfStatement(node)) {
        const cond = node.expression.getText(sf);
        const childGate = gatedByExtensionRunner || /extensionRunner/.test(cond);
        findBindCalls(node.thenStatement, childGate);
        if (node.elseStatement) findBindCalls(node.elseStatement, gatedByExtensionRunner);
        // Don'\''t descend into the condition itself
        return;
    }
    ts.forEachChild(node, (c) => findBindCalls(c, gatedByExtensionRunner));
}
findBindCalls(fn.body, false);

if (unconditional) { console.log("PASS"); process.exit(0); }
if (conditionalOnly) { console.log("STILL_GATED"); process.exit(0); }
console.log("NO_BIND");
' 2>&1)

echo "Gate2 result: $GATE2_RESULT"
if [ "$GATE2_RESULT" = "PASS" ]; then
    echo "PASS: print-mode.ts calls session.bindExtensions unconditionally"
    echo '{"id":"f2p_print_mode_unconditional_bind","passed":true,"detail":"bindExtensions called outside any extensionRunner if-guard"}' >> "$GATES_JSON"
else
    echo "FAIL: print-mode.ts still gates bindExtensions on extensionRunner"
    echo '{"id":"f2p_print_mode_unconditional_bind","passed":false,"detail":"'"$GATE2_RESULT"'"}' >> "$GATES_JSON"
fi

# =============================================================================
# F2P Gate 3 (weight 0.25): rpc-mode.ts — unconditional session.bindExtensions
# Same shape as Gate 2 but for runRpcMode.
# =============================================================================
echo ""
echo "=== F2P Gate 3: rpc-mode.ts runRpcMode — unconditional bindExtensions ==="

GATE3_RESULT=$(node -e '
const fs = require("fs");
const ts = require("typescript");
const path = "'"$RPC_MODE"'";
if (!fs.existsSync(path)) { console.log("MISSING"); process.exit(0); }
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile(path, src, ts.ScriptTarget.Latest, true);

let fn = null;
function visit(node) {
    if (ts.isFunctionDeclaration(node) && node.name && node.name.getText(sf) === "runRpcMode" && node.body) {
        fn = node;
    }
    ts.forEachChild(node, visit);
}
visit(sf);
if (!fn) { console.log("NO_FN"); process.exit(0); }

let unconditional = false;
let conditionalOnly = false;

function findBindCalls(node, gatedByExtensionRunner) {
    if (ts.isCallExpression(node)) {
        const expr = node.expression.getText(sf);
        if (/\.bindExtensions$/.test(expr) && /\bsession\b|\bthis\.session\b/.test(expr)) {
            if (gatedByExtensionRunner) conditionalOnly = true;
            else unconditional = true;
        }
    }
    if (ts.isIfStatement(node)) {
        const cond = node.expression.getText(sf);
        const childGate = gatedByExtensionRunner || /extensionRunner/.test(cond);
        findBindCalls(node.thenStatement, childGate);
        if (node.elseStatement) findBindCalls(node.elseStatement, gatedByExtensionRunner);
        return;
    }
    ts.forEachChild(node, (c) => findBindCalls(c, gatedByExtensionRunner));
}
findBindCalls(fn.body, false);

if (unconditional) { console.log("PASS"); process.exit(0); }
if (conditionalOnly) { console.log("STILL_GATED"); process.exit(0); }
console.log("NO_BIND");
' 2>&1)

echo "Gate3 result: $GATE3_RESULT"
if [ "$GATE3_RESULT" = "PASS" ]; then
    echo "PASS: rpc-mode.ts calls session.bindExtensions unconditionally"
    echo '{"id":"f2p_rpc_mode_unconditional_bind","passed":true,"detail":"bindExtensions called outside any extensionRunner if-guard"}' >> "$GATES_JSON"
else
    echo "FAIL: rpc-mode.ts still gates bindExtensions on extensionRunner"
    echo '{"id":"f2p_rpc_mode_unconditional_bind","passed":false,"detail":"'"$GATE3_RESULT"'"}' >> "$GATES_JSON"
fi

# =============================================================================
# F2P Gate 4 (weight 0.20): CHANGELOG entry
#
# Canonical adds a CHANGELOG line about extension UI bindings + /reload. We do
# NOT require the exact wording — accept any new entry mentioning "extension"
# AND ("bind"|"binding") AND "reload" in proximity (within the same line).
# =============================================================================
echo ""
echo "=== F2P Gate 4: CHANGELOG entry mentions extension bindings + reload ==="

if [ ! -f "$CHANGELOG" ]; then
    echo "FAIL: CHANGELOG.md missing"
    echo '{"id":"f2p_changelog_entry","passed":false,"detail":"file missing"}' >> "$GATES_JSON"
else
    CHANGELOG_HIT=$(grep -iE 'extension.*(bind|binding).*reload|reload.*extension.*(bind|binding)|extension.*UI.*reload|reload.*extension.*UI' "$CHANGELOG" | head -1)
    if [ -n "$CHANGELOG_HIT" ]; then
        echo "PASS: CHANGELOG mentions extension bindings + reload"
        echo "  match: $CHANGELOG_HIT"
        echo '{"id":"f2p_changelog_entry","passed":true,"detail":"CHANGELOG documents extension UI bindings + reload fix"}' >> "$GATES_JSON"
    else
        echo "FAIL: CHANGELOG missing extension-bindings + reload entry"
        echo '{"id":"f2p_changelog_entry","passed":false,"detail":"no matching changelog line"}' >> "$GATES_JSON"
    fi
fi

# =============================================================================
# P2P_REGRESSION (informational only, no reward): tsgo --noEmit on agent-touched
# .ts/.tsx files. Pre-existing repo errors in unrelated files would otherwise
# zero every reward — scope is mandatory.
# =============================================================================
echo ""
echo "=== P2P (informational): tsgo --noEmit on agent-changed files ==="
CHANGED_TS_FILES=$(cd "$REPO" && (git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
    echo "PASS: no agent .ts/.tsx changes — gate skipped"
    echo '{"id":"p2p_tsgo","passed":true,"detail":"no agent .ts/.tsx changes — gate skipped"}' >> "$GATES_JSON"
else
    cd "$REPO" && npx tsgo --noEmit $CHANGED_TS_FILES 2>&1 | tail -20
    P2P_RC=${PIPESTATUS[0]}
    if [ $P2P_RC -eq 0 ]; then
        echo "PASS: tsgo --noEmit clean on agent-changed files"
        echo '{"id":"p2p_tsgo","passed":true,"detail":"tsgo --noEmit clean on agent-changed files"}' >> "$GATES_JSON"
    else
        echo "WARNING: tsgo --noEmit failed on agent-changed files (informational only, continuing)"
        echo '{"id":"p2p_tsgo","passed":false,"detail":"tsgo --noEmit failed on agent-changed files"}' >> "$GATES_JSON"
    fi
fi

# =============================================================================
# Compute reward — weighted-replace, naturally bounded to [0, 1]
# =============================================================================
python3 - <<'PYEOF'
import json
WEIGHTS = {
    "f2p_interactive_eager_bind": 0.30,
    "f2p_print_mode_unconditional_bind": 0.25,
    "f2p_rpc_mode_unconditional_bind": 0.25,
    "f2p_changelog_entry": 0.20,
}
P2P_REGRESSION = ["p2p_tsgo"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass

# P2P_REGRESSION is informational only — never zeroes reward.
p2p_failed = False
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
existing = 0.0  # No legacy inner reward — WEIGHTS sums to 1.0
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF

echo ""
echo "=== Final reward: $(cat /logs/verifier/reward.txt) ==="
exit 0
