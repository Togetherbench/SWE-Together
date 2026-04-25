#!/bin/bash
set +e

mkdir -p /logs/verifier
SCORE=0

WORKSPACE="/workspace/pi-mono"
TARGET_FILE="$WORKSPACE/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
EXAMPLE_DIR="$WORKSPACE/packages/coding-agent/examples/extensions"

cd "$WORKSPACE" || { echo "FAIL: workspace not found"; echo "0.0000" > /logs/verifier/reward.txt; exit 0; }

# Ensure node/npm on PATH
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL: node not available"; echo "0.0000" > /logs/verifier/reward.txt; exit 0; }

add_score() {
    SCORE=$(awk -v a="$SCORE" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# ============================================================
# P2P Gate 1: TypeScript compilation (weight 0.10)
# ============================================================
echo "=== P2P Gate 1: TypeScript compilation ==="
npx tsgo --noEmit > /tmp/tsc.log 2>&1
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS: TypeScript compilation successful"
    add_score 0.10
else
    echo "FAIL: TypeScript compilation failed (exit $TSC_EXIT)"
    tail -30 /tmp/tsc.log
fi

# ============================================================
# F2P Gate 2: shutdownHandler triggers shutdown when idle (weight 0.30)
# ============================================================
echo ""
echo "=== F2P Gate 2: shutdownHandler triggers shutdown when idle ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

// Try multiple regex shapes — be tolerant to formatting
const patterns = [
    /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\n\s*\},?\s*\n\s*onError/,
    /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\}\s*,\s*onError/,
    /shutdownHandler\s*[:=]\s*(?:async\s*)?\(\)\s*=>\s*\{([\s\S]*?)\n\s*\}/,
];
let body = null;
for (const re of patterns) {
    const m = src.match(re);
    if (m) { body = m[1]; break; }
}
if (!body) {
    console.log('FAIL: Could not locate shutdownHandler');
    process.exit(1);
}

let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    isShuttingDown: false,
    session: { isStreaming: false, isIdle: true },
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); },
    checkShutdownRequested: function() { return Promise.resolve(); },
};

try {
    const code = body
        .replace(/this\./g, 'self.');
    const fn = new Function('self', 'setImmediate', 'process', code);
    fn(mockSelf, setImmediate, process);
} catch(e) {
    console.log('FAIL: handler exec error: ' + e.message);
    process.exit(1);
}

if (mockSelf.shutdownRequested !== true) {
    console.log('FAIL: shutdownRequested not set to true');
    process.exit(1);
}

// Allow setImmediate-deferred shutdown to fire
setTimeout(() => {
    if (!shutdownCalled) {
        console.log('FAIL: shutdown() not invoked when session idle');
        process.exit(1);
    }
    console.log('PASS: shutdownHandler invokes shutdown when idle');
    process.exit(0);
}, 50);
"
if [ $? -eq 0 ]; then add_score 0.30; fi

# ============================================================
# F2P Gate 3: handler does NOT call shutdown when streaming (weight 0.25)
# ============================================================
echo ""
echo "=== F2P Gate 3: shutdownHandler defers when streaming ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

const patterns = [
    /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\n\s*\},?\s*\n\s*onError/,
    /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\}\s*,\s*onError/,
    /shutdownHandler\s*[:=]\s*(?:async\s*)?\(\)\s*=>\s*\{([\s\S]*?)\n\s*\}/,
];
let body = null;
for (const re of patterns) {
    const m = src.match(re);
    if (m) { body = m[1]; break; }
}
if (!body) { console.log('FAIL: locate handler'); process.exit(1); }

const accessed = new Set();
const sessionProxy = new Proxy({ isStreaming: true, isIdle: false }, {
    get(t, p) { accessed.add(String(p)); return t[p]; }
});

let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    isShuttingDown: false,
    session: sessionProxy,
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); },
    checkShutdownRequested: function() { return Promise.resolve(); },
};

try {
    const code = body.replace(/this\./g, 'self.');
    const fn = new Function('self', 'setImmediate', 'process', code);
    fn(mockSelf, setImmediate, process);
} catch(e) {
    console.log('FAIL: exec ' + e.message);
    process.exit(1);
}

setTimeout(() => {
    // Either checks streaming state directly, OR doesn't call shutdown synchronously
    // (e.g. fully deferred-via-loop strategies).
    const checksState = accessed.has('isStreaming') || accessed.has('isIdle');
    if (shutdownCalled) {
        console.log('FAIL: shutdown() called while streaming (should be deferred)');
        process.exit(1);
    }
    if (mockSelf.shutdownRequested !== true) {
        console.log('FAIL: shutdownRequested flag not set');
        process.exit(1);
    }
    // Accept either explicit streaming check OR fully-deferred (no-shutdown-call) approach
    console.log('PASS: shutdown deferred when streaming (state-checked=' + checksState + ')');
    process.exit(0);
}, 50);
"
if [ $? -eq 0 ]; then add_score 0.25; fi

# ============================================================
# F2P Gate 4: Loop drains shutdownRequested via checkShutdownRequested (weight 0.15)
# Either: (a) shutdownHandler calls shutdown immediately when idle, OR
#         (b) main loop awaits checkShutdownRequested after prompt
# ============================================================
echo ""
echo "=== F2P Gate 4: deferred-shutdown drain path exists ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

// Path A: handler triggers shutdown directly when not streaming
const directPath = /shutdownHandler[\s\S]{0,400}?(?:!\s*this\.session\.isStreaming|this\.session\.isIdle)[\s\S]{0,200}?this\.shutdown\(\)/.test(src);

// Path B: main loop calls checkShutdownRequested after session.prompt
const loopPath = /while\s*\(true\)[\s\S]{0,800}?session\.prompt\([\s\S]{0,500}?checkShutdownRequested\(\)/.test(src);

if (directPath || loopPath) {
    console.log('PASS: deferred-shutdown wiring present (direct=' + directPath + ', loop=' + loopPath + ')');
    process.exit(0);
}
console.log('FAIL: no path from shutdownRequested -> actual shutdown found');
process.exit(1);
"
if [ $? -eq 0 ]; then add_score 0.15; fi

# ============================================================
# F2P Gate 5: example extension exists, registers a slash command (weight 0.10)
# ============================================================
echo ""
echo "=== F2P Gate 5: example extension registers a slash command ==="
EXAMPLE_OK=0
if [ -d "$EXAMPLE_DIR" ]; then
    # Find any .ts example that calls registerCommand
    EXAMPLE_FILE=$(grep -l "registerCommand" "$EXAMPLE_DIR"/*.ts 2>/dev/null | head -1)
    if [ -n "$EXAMPLE_FILE" ] && [ -f "$EXAMPLE_FILE" ]; then
        # Verify structural validity: default-exported function taking ExtensionAPI and calling registerCommand with a name + handler
        node -e "
const fs = require('fs');
const t = fs.readFileSync('$EXAMPLE_FILE', 'utf-8');
const hasDefault = /export\s+default\s+(?:async\s+)?function/.test(t);
const hasExtAPI = /ExtensionAPI/.test(t);
const reg = t.match(/registerCommand\(\s*[\"'\`]([\w-]+)[\"'\`]\s*,\s*\{([\s\S]*?)\}\s*\)/);
if (!hasDefault || !hasExtAPI || !reg) {
    console.log('FAIL: example missing default export / ExtensionAPI / registerCommand call');
    process.exit(1);
}
const cmdName = reg[1];
const cmdBlock = reg[2];
if (!/handler\s*:/.test(cmdBlock)) {
    console.log('FAIL: registerCommand has no handler');
    process.exit(1);
}
if (!/description\s*:/.test(cmdBlock)) {
    console.log('FAIL: registerCommand has no description');
    process.exit(1);
}
console.log('PASS: example registers /' + cmdName + ' with handler + description');
process.exit(0);
"
        if [ $? -eq 0 ]; then EXAMPLE_OK=1; fi
    else
        echo "FAIL: no .ts example file with registerCommand under $EXAMPLE_DIR"
    fi
else
    echo "FAIL: $EXAMPLE_DIR missing"
fi
if [ $EXAMPLE_OK -eq 1 ]; then add_score 0.10; fi

# ============================================================
# Structural Gate 6: ExtensionContext.shutdown documented (weight 0.10)
# Ensures the API contract was acknowledged in types.ts
# ============================================================
echo ""
echo "=== Gate 6: ExtensionContext.shutdown documented ==="
TYPES_FILE="$WORKSPACE/packages/coding-agent/src/core/extensions/types.ts"
if [ -f "$TYPES_FILE" ]; then
    node -e "
const fs = require('fs');
const t = fs.readFileSync('$TYPES_FILE', 'utf-8');
// must still declare shutdown(): void
if (!/shutdown\(\)\s*:\s*void/.test(t)) {
    console.log('FAIL: shutdown(): void missing from types');
    process.exit(1);
}
// Look for any doc comment block mentioning shutdown semantics
const m = t.match(/\/\*\*([\s\S]{0,500}?)\*\/\s*shutdown\(\)\s*:\s*void/);
if (!m) {
    console.log('FAIL: no JSDoc on shutdown()');
    process.exit(1);
}
const doc = m[1].toLowerCase();
const mentionsDefer = /(defer|until|after|finishes|completes|current turn|streaming|idle|gracef)/.test(doc);
if (!mentionsDefer) {
    console.log('FAIL: shutdown() docs do not describe deferred/graceful semantics');
    process.exit(1);
}
console.log('PASS: shutdown() documented with deferred semantics');
process.exit(0);
"
    if [ $? -eq 0 ]; then add_score 0.10; fi
else
    echo "FAIL: types.ts missing"
fi

# ============================================================
# Final
# ============================================================
echo ""
echo "=== Final score: $SCORE ==="
echo "$SCORE" > /logs/verifier/reward.txt