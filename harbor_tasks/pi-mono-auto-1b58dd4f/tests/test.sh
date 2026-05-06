#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

REWARD=0.0
add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

REPO=/workspace/pi-mono
cd "$REPO" 2>/dev/null || { echo "FAIL: repo not found"; echo 0.0 > "$REWARD_FILE"; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL: node missing"; echo 0.0 > "$REWARD_FILE"; exit 0; }

AGENT_SESSION="packages/coding-agent/src/core/agent-session.ts"

if [ ! -f "$AGENT_SESSION" ]; then
    echo "FAIL: agent-session.ts not found"
    finish
fi

# =============================================================================
# Gate P2P (gating only, no reward): TypeScript compiles (scoped to agent diff)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
# If this fails on the agent's patch, treat as regression and return 0.
# =============================================================================
echo "=== P2P Gate: TypeScript compilation (gating only, no reward) ==="
CHANGED_TS_FILES=$(cd "$REPO" && (git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
    echo "PASS: no agent .ts/.tsx changes — gate skipped"
else
    TSC_OUT=$(cd "$REPO" && npx tsgo --noEmit $CHANGED_TS_FILES 2>&1)
    TSC_EXIT=$?
    if [ $TSC_EXIT -ne 0 ]; then
        echo "FAIL: TypeScript compilation regression on agent-changed files"
        echo "$TSC_OUT" | tail -40
        REWARD=0.0
        finish
    fi
    echo "PASS: tsc clean on agent-changed files"
fi

# =============================================================================
# F2P Gate 1 (weight 0.50): The buggy `hasBindings` guard around
# session_start/reload + extendResourcesFromExtensions("reload") is gone OR
# has been changed so that it no longer prevents the emit when no UI bindings
# were previously set.
#
# The buggy base code looks exactly like:
#     const hasBindings =
#         this._extensionUIContext ||
#         this._extensionCommandContextActions ||
#         this._extensionShutdownHandler ||
#         this._extensionErrorListener;
#     if (hasBindings) {
#         await this._extensionRunner.emit({ type: "session_start", reason: "reload" });
#         await this.extendResourcesFromExtensions("reload");
#     }
#
# Acceptance: AST-walk the reload() body and confirm that the
# session_start/"reload" emit + extendResourcesFromExtensions("reload") pair
# is NOT both gated by an if-condition that ANDs/ORs over the four
# `_extension*` binding fields. Equivalently: either the emit is unguarded,
# or it's guarded by something else (e.g., a boolean flag flipped inside
# bindExtensions, or after re-applying bindings).
# =============================================================================
echo ""
echo "=== F2P Gate 1: reload() no longer gated on UI-binding presence (weight 0.30) ==="

GATE1_RESULT=$(node -e '
const fs = require("fs");
const ts = require("typescript");
const path = "'"$AGENT_SESSION"'";
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile(path, src, ts.ScriptTarget.Latest, true);

let reloadNode = null;
function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name && node.name.getText(sf) === "reload" && node.body) {
        reloadNode = node;
    }
    ts.forEachChild(node, visit);
}
visit(sf);

if (!reloadNode) { console.log("NO_RELOAD"); process.exit(0); }

const reloadText = reloadNode.body.getText(sf);

// Must contain the session_start/reload emit at all
const emitRe = /emit\s*\(\s*\{[^}]*type\s*:\s*["\x27]session_start["\x27][^}]*reason\s*:\s*["\x27]reload["\x27]/;
if (!emitRe.test(reloadText)) { console.log("NO_EMIT"); process.exit(0); }

// Walk reload body, find the emit call, check enclosing ifs.
const bindingFields = [
    "_extensionUIContext",
    "_extensionCommandContextActions",
    "_extensionShutdownHandler",
    "_extensionErrorListener",
];

function isBuggyGuard(condText) {
    let count = 0;
    for (const f of bindingFields) if (condText.includes(f)) count++;
    if (count >= 2) return true;
    // Also detect indirect guard via variable (e.g. const hasBindings = field1 || field2; if (hasBindings) ...)
    if (/\bhasBindings\b/.test(condText)) {
        let varCount = 0;
        for (const f of bindingFields) if (reloadText.includes(f)) varCount++;
        if (varCount >= 2) return true;
    }
    return false;
}

let foundUnguardedEmit = false;
let foundBuggyGuardedEmit = false;

function walk(node) {
    if (ts.isCallExpression(node)) {
        const callText = node.getText(sf);
        if (/session_start/.test(callText) && /reload/.test(callText) && /\bemit\b/.test(node.expression.getText(sf))) {
            // Find enclosing ifs up to reload body
            let p = node.parent;
            let buggyGuard = false;
            while (p && p !== reloadNode.body) {
                if (ts.isIfStatement(p)) {
                    const cond = p.expression.getText(sf);
                    if (isBuggyGuard(cond)) { buggyGuard = true; break; }
                }
                p = p.parent;
            }
            if (buggyGuard) foundBuggyGuardedEmit = true;
            else foundUnguardedEmit = true;
        }
    }
    ts.forEachChild(node, walk);
}
walk(reloadNode.body);

if (foundUnguardedEmit && !foundBuggyGuardedEmit) { console.log("PASS"); process.exit(0); }
if (foundBuggyGuardedEmit && !foundUnguardedEmit) { console.log("BUGGY_GUARD"); process.exit(0); }
if (foundUnguardedEmit && foundBuggyGuardedEmit) { console.log("PASS"); process.exit(0); }
console.log("UNKNOWN");
' 2>&1)

echo "Gate1 result: $GATE1_RESULT"
if [ "$GATE1_RESULT" = "PASS" ]; then
    echo "PASS: reload() emit is no longer guarded by UI-binding presence check"
    add_reward 0.30
    GATE1_OK=1
else
    echo "FAIL: reload() still gated on UI-binding presence (or emit missing)"
    GATE1_OK=0
fi

# =============================================================================
# F2P Gate 2 (weight 0.50): Behavioral simulation.
#
# Build a tiny harness that:
#  1. Constructs an AgentSession-like flow by stripping/loading the relevant
#     reload() logic via a runtime stub.
#  2. Verifies that calling reload() WITHOUT having previously set any of
#     the four _extension* fields still results in
#       - exactly one `session_start` emit with reason "reload"
#       - one `extendResourcesFromExtensions("reload")` invocation
#
# To stay implementation-agnostic, we don't import the real class. We
# transform reload() into a standalone async function and execute it with
# stub `this`. The buggy base will skip both calls; any reasonable fix
# (unguarded, flag-based-with-flag-set, applyBindings-then-emit) will make
# them happen.
# =============================================================================
echo ""
echo "=== F2P Gate 2: behavioral simulation of reload() with no prior bindings (weight 0.30) ==="

if [ "$GATE1_OK" != "1" ]; then
    # Even if Gate 1 says it's still buggy-shaped, run the sim anyway as a
    # second independent signal. (Don't skip — let it speak for itself.)
    :
fi

GATE2_RESULT=$(node -e '
const fs = require("fs");
const ts = require("typescript");
const path = "'"$AGENT_SESSION"'";
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile(path, src, ts.ScriptTarget.Latest, true);

let reloadBody = null;
function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name && node.name.getText(sf) === "reload" && node.body) {
        reloadBody = node.body.getText(sf);
    }
    ts.forEachChild(node, visit);
}
visit(sf);

if (!reloadBody) { console.log("NO_RELOAD"); process.exit(0); }

// Strip type annotations / generics is hard; instead simulate by counting
// what the body would do under stubbed `this`. We write a tracer for `this`.
//
// Approach: run reload body inside a `with(self)` proxy where every property
// access returns a chainable stub that records calls. Track whether
// session_start/reload emit happened and extendResourcesFromExtensions("reload").
//
// But reload body uses await, calls methods, and references local consts
// (e.g., `previousFlagValues`, `this._buildRuntime(...)`). We need a JS
// environment.
//
// Strategy: rewrite "this." -> "self." and stub `self` with a Proxy that
// returns recording functions / chainable values.

let body = reloadBody;
// Strip TS type annotations from variable declarations that we hit. The
// reload body is mostly assignments and method calls; type-cast `as` and
// generic params can break parsing. Run through tsc transpile to JS first.
const transpiled = ts.transpileModule("async function __reload() " + body, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText;

// Replace this. with self.
let js = transpiled.replace(/\bthis\./g, "self.");

const events = [];

function makeProxy(name) {
    const fn = function(...args) {
        events.push({ name, args });
        return makeProxy(name + "()");
    };
    return new Proxy(fn, {
        get(target, prop) {
            if (prop === "then") return undefined; // not a thenable
            if (prop === Symbol.toPrimitive) return () => name;
            if (typeof prop === "symbol") return undefined;
            return makeProxy(name + "." + String(prop));
        },
        apply(target, thisArg, args) {
            events.push({ name, args });
            return makeProxy(name + "()");
        },
    });
}

const self = makeProxy("self");

// Provide globals reload body might use
const sandbox = { self, console, Promise };

let runErr = null;
try {
    const wrapper = new Function("self", "console",
        js + "\nreturn __reload();"
    );
    // Run with a top-level await emulation: the function returns a promise.
    const p = wrapper(self, console);
    // Use Atomics-style sync wait via deasync? Not available. Use polling.
    let done = false, result, err;
    p.then(r => { result = r; done = true; }, e => { err = e; done = true; });
    // Since await on proxy returns a proxy (non-thenable), promise chain
    // should resolve almost immediately; but emit returns a proxy without
    // .then so await will resolve to the proxy. Wait briefly.
    const start = Date.now();
    function spin() {
        return new Promise((res) => setImmediate(res));
    }
    (async () => {
        while (!done && Date.now() - start < 3000) {
            await spin();
        }
    })().then(() => {
        if (err) runErr = err;
        // Analyze events
        let sessionStartReload = 0;
        let extendResourcesReload = 0;
        for (const ev of events) {
            // Look for emit(...) where args[0].type === "session_start" and reason === "reload"
            if (/\.emit$/.test(ev.name) && ev.args && ev.args[0] && typeof ev.args[0] === "object") {
                const a = ev.args[0];
                if (a.type === "session_start" && a.reason === "reload") sessionStartReload++;
            }
            if (/extendResourcesFromExtensions$/.test(ev.name) && ev.args && ev.args[0] === "reload") {
                extendResourcesReload++;
            }
        }
        if (sessionStartReload >= 1 && extendResourcesReload >= 1) console.log("PASS");
        else console.log("FAIL ss=" + sessionStartReload + " er=" + extendResourcesReload);
    });
} catch (e) {
    console.log("ERR " + e.message);
}
' 2>&1)

echo "Gate2 result: $GATE2_RESULT"
if echo "$GATE2_RESULT" | grep -q "^PASS"; then
    echo "PASS: behavioral sim — reload() emits session_start and extends resources without prior bindings"
    add_reward 0.30
    GATE2_OK=1
else
    echo "FAIL: behavioral sim shows reload() still skips emit/extend on no-binding state"
    GATE2_OK=0
fi

echo ""
echo "=== Final reward (pre-upstream): $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_JSON="/logs/verifier/gates.json"
> "$GATES_JSON"

# F2P upstream gate: reload_structure
echo ""
echo "=== Upstream F2P: reload() structure check ==="
cd /workspace/pi-mono && node -e "const fs=require('fs');const src=fs.readFileSync('packages/coding-agent/src/core/agent-session.ts','utf8');const lines=src.split('\n');let inReload=false,braceCount=0,reloadBody='';for(const line of lines){if(/async\s+reload\s*\(\)/.test(line)){inReload=true;braceCount=0;}if(inReload){for(const ch of line){if(ch==='{')braceCount++;if(ch==='}')braceCount--;}reloadBody+=line+'\n';if(braceCount===0&&reloadBody.includes('{')){inReload=false;break;}}}if(!reloadBody)process.exit(1);if(reloadBody.includes('const hasBindings'))process.exit(1);if(!reloadBody.includes('_applyExtensionBindings'))process.exit(1);process.exit(0);"
F2P_RELOAD_RC=$?
if [ $F2P_RELOAD_RC -eq 0 ]; then
    echo '{"id":"f2p_upstream_reload_structure","passed":true,"detail":"reload() has _applyExtensionBindings and no hasBindings guard"}' >> "$GATES_JSON"
    echo "PASS: upstream reload structure check"
else
    echo '{"id":"f2p_upstream_reload_structure","passed":false,"detail":"reload() still has hasBindings guard or missing _applyExtensionBindings"}' >> "$GATES_JSON"
    echo "FAIL: upstream reload structure check"
fi

# F2P upstream gate: changelog_entry
echo ""
echo "=== Upstream F2P: CHANGELOG entry check ==="
cd /workspace/pi-mono && grep -q 'reload.*re-applies bindings' packages/coding-agent/CHANGELOG.md
F2P_CHANGELOG_RC=$?
if [ $F2P_CHANGELOG_RC -eq 0 ]; then
    echo '{"id":"f2p_upstream_changelog_entry","passed":true,"detail":"CHANGELOG documents reload fix"}' >> "$GATES_JSON"
    echo "PASS: upstream changelog entry"
else
    echo '{"id":"f2p_upstream_changelog_entry","passed":false,"detail":"CHANGELOG missing reload fix entry"}' >> "$GATES_JSON"
    echo "FAIL: upstream changelog entry"
fi

# P2P upstream gate: tsgo typecheck (scoped to agent-touched .ts/.tsx files)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
echo ""
echo "=== Upstream P2P: tsgo --noEmit (scoped) ==="
CHANGED_TS_FILES=$(cd /workspace/pi-mono && (git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
    echo "PASS: upstream tsgo typecheck (no agent .ts/.tsx changes — gate skipped)"
    echo '{"id":"p2p_upstream_tsgo","passed":true,"detail":"no agent .ts/.tsx changes — gate skipped"}' >> "$GATES_JSON"
else
    cd /workspace/pi-mono && npx tsgo --noEmit $CHANGED_TS_FILES 2>&1 | tail -20
    P2P_TSGO_RC=${PIPESTATUS[0]}
    if [ $P2P_TSGO_RC -eq 0 ]; then
        echo '{"id":"p2p_upstream_tsgo","passed":true,"detail":"tsgo --noEmit clean on agent-changed files"}' >> "$GATES_JSON"
        echo "PASS: upstream tsgo typecheck"
    else
        echo '{"id":"p2p_upstream_tsgo","passed":false,"detail":"tsgo --noEmit failed on agent-changed files"}' >> "$GATES_JSON"
        echo "FAIL: upstream tsgo typecheck"
    fi
fi

# Run upstream reward tail
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_gate1_reload_no_guard": 0.3,
    "f2p_gate2_behavioral_sim": 0.3,
    "f2p_upstream_reload_structure": 0.2,
    "f2p_upstream_changelog_entry": 0.2
}
P2P_REGRESSION = ["p2p_upstream_tsgo"]
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
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
p2p_failed = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
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
echo "=== Final reward (post-upstream): $(cat /logs/verifier/reward.txt) ==="
# ---- end ----
exit 0