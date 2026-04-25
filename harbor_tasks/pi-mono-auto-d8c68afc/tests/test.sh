#!/bin/bash
set +e

SCORE=0
mkdir -p /logs/verifier

TARGET_FILE="/workspace/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts"

# ============================================================
# P2P Gate 1: TypeScript compilation (weight 0.10)
# P2P: passes at base and at fix — regression guard
# ============================================================
echo "=== P2P Gate 1: TypeScript compilation ==="
cd /workspace/pi-mono
npx tsgo --noEmit 2>&1
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS: TypeScript compilation successful"
    SCORE=$(awk -v a="$SCORE" 'BEGIN{printf "%.4f", a+0.10}')
else
    echo "FAIL: TypeScript compilation failed (exit $TSC_EXIT)"
fi

# ============================================================
# F2P Gate 2: Behavioral — shutdownHandler triggers shutdown when idle (weight 0.35)
# F2P: fails at base — base handler only sets shutdownRequested flag
# Extracts the shutdownHandler function, executes it with mocks,
# verifies shutdown() is called when session is not streaming.
# ============================================================
echo ""
echo "=== F2P Gate 2: shutdownHandler triggers shutdown when idle ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

// Extract shutdownHandler body from the extension runner setup
// Pattern: shutdownHandler: () => { ... },\n\t\t\tonError
const handlerRegex = /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\n\t\t\t\},?\s*\n\t\t\tonError/;
const match = src.match(handlerRegex);
if (!match) {
    console.log('FAIL: Could not locate shutdownHandler function');
    process.exit(1);
}

const handlerBody = match[1];

// Create mock with session idle (not streaming)
let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    session: { isStreaming: false },
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); }
};

// Execute the extracted handler with this-rebinding
try {
    const code = handlerBody
        .replace(/this\\.shutdownRequested/g, 'self.shutdownRequested')
        .replace(/this\\.session/g, 'self.session')
        .replace(/this\\.shutdown/g, 'self.shutdown');
    const fn = new Function('self', code);
    fn(mockSelf);
} catch(e) {
    console.log('FAIL: Handler execution error: ' + e.message);
    process.exit(1);
}

if (!mockSelf.shutdownRequested) {
    console.log('FAIL: shutdownRequested was not set to true');
    process.exit(1);
}

if (!shutdownCalled) {
    console.log('FAIL: shutdown() was not called when session is idle (not streaming)');
    process.exit(1);
}

console.log('PASS: shutdownHandler calls shutdown() when session is idle');
process.exit(0);
"
F2P1_EXIT=$?
if [ $F2P1_EXIT -eq 0 ]; then
    SCORE=$(awk -v a="$SCORE" 'BEGIN{printf "%.4f", a+0.35}')
fi

# ============================================================
# F2P Gate 3: Behavioral — handler checks streaming state via Proxy (weight 0.30)
# F2P: fails at base — base handler never accesses session state
# Uses a JavaScript Proxy to verify the handler inspects the
# session's streaming/idle state before deciding to call shutdown.
# ============================================================
echo ""
echo "=== F2P Gate 3: shutdownHandler checks session streaming state ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

const handlerRegex = /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\n\t\t\t\},?\s*\n\t\t\tonError/;
const match = src.match(handlerRegex);
if (!match) {
    console.log('FAIL: Could not locate shutdownHandler function');
    process.exit(1);
}

const handlerBody = match[1];

// Use a Proxy to track property accesses on session
const accessLog = [];
const sessionProxy = new Proxy({ isStreaming: false }, {
    get(target, prop) {
        accessLog.push(String(prop));
        return target[prop];
    }
});

let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    session: sessionProxy,
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); }
};

try {
    const code = handlerBody
        .replace(/this\\.shutdownRequested/g, 'self.shutdownRequested')
        .replace(/this\\.session/g, 'self.session')
        .replace(/this\\.shutdown/g, 'self.shutdown');
    const fn = new Function('self', code);
    fn(mockSelf);
} catch(e) {
    console.log('FAIL: Handler execution error: ' + e.message);
    process.exit(1);
}

// The handler must access isStreaming (or equivalent idle check)
const checksState = accessLog.includes('isStreaming') || accessLog.includes('isIdle');
if (!checksState) {
    console.log('FAIL: shutdownHandler does not check session streaming/idle state');
    console.log('  Properties accessed: ' + JSON.stringify(accessLog));
    process.exit(1);
}

// Verify: when streaming, shutdown should NOT be called
let shutdownCalled2 = false;
const sessionProxy2 = new Proxy({ isStreaming: true }, {
    get(target, prop) { return target[prop]; }
});
const mockSelf2 = {
    shutdownRequested: false,
    session: sessionProxy2,
    shutdown: function() { shutdownCalled2 = true; return Promise.resolve(); }
};

try {
    const code = handlerBody
        .replace(/this\\.shutdownRequested/g, 'self.shutdownRequested')
        .replace(/this\\.session/g, 'self.session')
        .replace(/this\\.shutdown/g, 'self.shutdown');
    const fn = new Function('self', code);
    fn(mockSelf2);
} catch(e) {}

if (shutdownCalled2) {
    console.log('FAIL: shutdown() called even while streaming (should be deferred)');
    process.exit(1);
}

console.log('PASS: shutdownHandler checks streaming state and conditionally triggers shutdown');
process.exit(0);
"
F2P2_EXIT=$?
if [ $F2P2_EXIT -eq 0 ]; then
    SCORE=$(awk -v a="$SCORE" 'BEGIN{printf "%.4f", a+0.30}')
fi

# ============================================================
# F2P Gate 4: Build integration — compiled output has the fix (weight 0.25)
# F2P: fails at base — compiled JS in dist/ does not have fix
# Builds the coding-agent package and verifies the compiled JavaScript
# output also contains the shutdown call in the handler.
# ============================================================
echo ""
echo "=== F2P Gate 4: Build integration — compiled JS contains fix ==="
cd /workspace/pi-mono
npm run build 2>&1 | tail -5
BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
    echo "FAIL: npm run build failed"
else
    # Check compiled JS has the fix
    DIST_FILE="packages/coding-agent/dist/modes/interactive/interactive-mode.js"
    if [ ! -f "$DIST_FILE" ]; then
        echo "FAIL: compiled output not found at $DIST_FILE"
    else
        # Extract shutdownHandler from compiled JS and check it calls shutdown
        node -e "
const fs = require('fs');
const js = fs.readFileSync('$DIST_FILE', 'utf-8');

// In compiled JS, the handler pattern is similar but may use different formatting
// Check that the shutdownHandler region calls shutdown() conditionally
const handlerRegex = /shutdownHandler:\s*\(\)\s*=>\s*\{([\s\S]*?)\},\s*\n\s*onError/;
const match = js.match(handlerRegex);
if (!match) {
    console.log('FAIL: Could not find shutdownHandler in compiled JS');
    process.exit(1);
}
const body = match[1];
const callsShutdown = body.includes('.shutdown()');
const checksStreaming = body.includes('isStreaming') || body.includes('isIdle');
if (callsShutdown && checksStreaming) {
    console.log('PASS: Compiled JS contains shutdown fix with streaming check');
    process.exit(0);
} else {
    console.log('FAIL: Compiled JS shutdownHandler missing fix');
    console.log('  callsShutdown=' + callsShutdown + ' checksStreaming=' + checksStreaming);
    process.exit(1);
}
"
        F2P3_EXIT=$?
    fi
fi

if [ "${F2P3_EXIT:-1}" -eq 0 ]; then
    SCORE=$(awk -v a="$SCORE" 'BEGIN{printf "%.4f", a+0.25}')
fi

# ============================================================
# Final score
# ============================================================
echo ""
echo "=== Final Score: $SCORE / 1.00 ==="
echo "$SCORE" > /logs/verifier/reward.txt
