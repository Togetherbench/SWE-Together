#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD=0

WORKSPACE="/workspace/pi-mono"
TARGET_FILE="$WORKSPACE/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
EXAMPLE_DIR="$WORKSPACE/packages/coding-agent/examples/extensions"

write_reward() {
    echo "$REWARD" > /logs/verifier/reward.txt
}

cd "$WORKSPACE" || { echo "FAIL: workspace not found"; write_reward; exit 0; }

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FAIL: node not available"; write_reward; exit 0; }

add_score() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

if [ ! -f "$TARGET_FILE" ]; then
    echo "FAIL: target file missing"
    write_reward; exit 0
fi

# ============================================================
# F2P Gate 1: shutdownHandler sets shutdownRequested=true (weight 0.15)
# Buggy base: handler is `shutdown: () => { this.shutdownRequested = true; }`
# but is registered under key `shutdown:` — the framework expects
# `shutdownHandler:`. So even reading shutdownRequested flag through the
# *correctly-keyed* handler fails on base.
# ============================================================
echo "=== F2P Gate 1: shutdownHandler key exists and sets shutdownRequested ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

// Must be keyed as 'shutdownHandler' (the bug uses 'shutdown:')
const m = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{([\s\S]*?)\n\s*\}/);
if (!m) { console.log('FAIL: no shutdownHandler key'); process.exit(1); }
const body = m[1];

let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    isShuttingDown: false,
    session: { isStreaming: false, isIdle: true },
    runtimeHost: { dispose: () => Promise.resolve() },
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); },
    checkShutdownRequested: function() { return Promise.resolve(); },
    ui: { terminal: { drainInput: () => Promise.resolve() }, requestRender: () => {} },
    stop: function() {},
    unregisterSignalHandlers: function() {},
    updatePendingMessagesDisplay: function() {},
};

try {
    const code = body.replace(/this\./g, 'self.');
    const fn = new Function('self', 'setImmediate', 'process', code);
    fn(mockSelf, setImmediate, { exit: () => {}, kill: () => {}, nextTick: (cb)=>cb(), pid: 1 });
} catch(e) {
    console.log('FAIL: handler exec error: ' + e.message);
    process.exit(1);
}

if (mockSelf.shutdownRequested !== true) {
    console.log('FAIL: shutdownRequested not set');
    process.exit(1);
}
console.log('PASS');
process.exit(0);
"
if [ $? -eq 0 ]; then add_score 0.15; fi

# ============================================================
# F2P Gate 2: There is a path from shutdownRequested -> actual shutdown
# Either:
#   (a) handler calls this.shutdown() when not streaming, OR
#   (b) main loop awaits checkShutdownRequested() after session.prompt()
# Buggy base does NEITHER.
# Weight 0.30
# ============================================================
echo ""
echo "=== F2P Gate 2: deferred-shutdown drain path exists ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

// Path A: handler triggers this.shutdown() (with or without streaming check)
const handlerMatch = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{([\s\S]*?)\n\s*\}/);
let directPath = false;
if (handlerMatch) {
    const body = handlerMatch[1];
    directPath = /this\.shutdown\(\)/.test(body);
}

// Path B: main loop awaits checkShutdownRequested after session.prompt
const loopPath = /while\s*\(\s*true\s*\)[\s\S]{0,1200}?session\.prompt\([\s\S]{0,800}?checkShutdownRequested\(\)/.test(src);

if (directPath || loopPath) {
    console.log('PASS (direct=' + directPath + ', loop=' + loopPath + ')');
    process.exit(0);
}
console.log('FAIL: no shutdownRequested -> shutdown drain path');
process.exit(1);
"
if [ $? -eq 0 ]; then add_score 0.30; fi

# ============================================================
# F2P Gate 3: handler does NOT call shutdown synchronously while streaming
# Either checks streaming state, or fully defers via loop.
# Weight 0.20
# ============================================================
echo ""
echo "=== F2P Gate 3: shutdown deferred when streaming ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

const m = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{([\s\S]*?)\n\s*\}/);
if (!m) { console.log('FAIL: no shutdownHandler'); process.exit(1); }
const body = m[1];

let shutdownCalledSync = false;
const sessionProxy = { isStreaming: true, isIdle: false };

const mockSelf = {
    shutdownRequested: false,
    isShuttingDown: false,
    session: sessionProxy,
    runtimeHost: { dispose: () => Promise.resolve() },
    shutdown: function() { shutdownCalledSync = true; return Promise.resolve(); },
    checkShutdownRequested: function() { return Promise.resolve(); },
    ui: { terminal: { drainInput: () => Promise.resolve() }, requestRender: () => {} },
    stop: function() {},
    unregisterSignalHandlers: function() {},
    updatePendingMessagesDisplay: function() {},
};

try {
    const code = body.replace(/this\./g, 'self.');
    const fn = new Function('self', 'setImmediate', 'process', code);
    fn(mockSelf, setImmediate, { exit: () => {}, kill: () => {}, nextTick: (cb)=>cb(), pid: 1 });
} catch(e) {
    console.log('FAIL: exec error: ' + e.message);
    process.exit(1);
}

if (shutdownCalledSync) {
    console.log('FAIL: shutdown() called synchronously while streaming');
    process.exit(1);
}
if (mockSelf.shutdownRequested !== true) {
    console.log('FAIL: shutdownRequested not set');
    process.exit(1);
}
console.log('PASS: shutdown deferred when streaming');
process.exit(0);
"
if [ $? -eq 0 ]; then add_score 0.20; fi

# ============================================================
# F2P Gate 4: when idle, handler triggers actual shutdown (sync or via setImmediate)
# Weight 0.15
# ============================================================
echo ""
echo "=== F2P Gate 4: shutdown invoked when idle ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

const m = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{([\s\S]*?)\n\s*\}/);
if (!m) { console.log('FAIL: no shutdownHandler'); process.exit(1); }
const body = m[1];

// Skip if handler doesn't try to call this.shutdown directly — the loop-path
// covers that case in Gate 2; this gate verifies the direct path when present.
if (!/this\.shutdown\(\)/.test(body)) {
    // Allow loop-only implementations to pass this gate too if loop path exists
    const loopPath = /while\s*\(\s*true\s*\)[\s\S]{0,1200}?session\.prompt\([\s\S]{0,800}?checkShutdownRequested\(\)/.test(src);
    if (loopPath) {
        console.log('PASS: loop-drain implementation');
        process.exit(0);
    }
    console.log('FAIL: no direct or loop shutdown path');
    process.exit(1);
}

let shutdownCalled = false;
const mockSelf = {
    shutdownRequested: false,
    isShuttingDown: false,
    session: { isStreaming: false, isIdle: true },
    runtimeHost: { dispose: () => Promise.resolve() },
    shutdown: function() { shutdownCalled = true; return Promise.resolve(); },
    checkShutdownRequested: function() { return Promise.resolve(); },
    ui: { terminal: { drainInput: () => Promise.resolve() }, requestRender: () => {} },
    stop: function() {},
    unregisterSignalHandlers: function() {},
    updatePendingMessagesDisplay: function() {},
};

try {
    const code = body.replace(/this\./g, 'self.');
    const fn = new Function('self', 'setImmediate', 'process', code);
    fn(mockSelf, setImmediate, { exit: () => {}, kill: () => {}, nextTick: (cb)=>cb(), pid: 1 });
} catch(e) {
    console.log('FAIL: exec error: ' + e.message);
    process.exit(1);
}

setTimeout(() => {
    if (!shutdownCalled) {
        console.log('FAIL: shutdown() not invoked when idle');
        process.exit(1);
    }
    console.log('PASS: shutdown invoked when idle');
    process.exit(0);
}, 60);
" 
RES=$?
if [ $RES -eq 0 ]; then add_score 0.15; fi

# ============================================================
# F2P Gate 5: example extension renamed/exists with /shutdown (or other) command
# Buggy base has the file named 'shutdown-command.ts' but it registers /quit
# (which conflicts with built-in /quit and is therefore unreachable).
# A correct fix renames the registered command to something non-conflicting
# (e.g. /shutdown) OR makes extension commands take priority over built-ins.
# Weight 0.20
# ============================================================
echo ""
echo "=== F2P Gate 5: example registers a reachable slash command ==="
node -e "
const fs = require('fs');
const path = require('path');
const dir = '$EXAMPLE_DIR';
if (!fs.existsSync(dir)) { console.log('FAIL: examples dir missing'); process.exit(1); }

const files = fs.readdirSync(dir).filter(f => f.endsWith('.ts'));
let registeredName = null;
let exampleSrc = null;
for (const f of files) {
    const t = fs.readFileSync(path.join(dir, f), 'utf-8');
    const reg = t.match(/registerCommand\(\s*[\"'\`]([\w-]+)[\"'\`]\s*,\s*\{([\s\S]*?)\}\s*\)/);
    if (!reg) continue;
    const hasDefault = /export\s+default\s+(?:async\s+)?function/.test(t);
    const hasExtAPI = /ExtensionAPI/.test(t);
    const hasHandler = /handler\s*:/.test(reg[2]);
    const hasDescription = /description\s*:/.test(reg[2]);
    if (hasDefault && hasExtAPI && hasHandler && hasDescription) {
        registeredName = reg[1];
        exampleSrc = t;
        break;
    }
}
if (!registeredName) {
    console.log('FAIL: no valid example with default export + ExtensionAPI + registerCommand(name, {description, handler})');
    process.exit(1);
}

// Reachability check: either the registered name is not a built-in,
// or interactive-mode.ts has been changed to let extension commands
// take priority over built-ins (isExtensionCommand check before built-in dispatch).
const builtins = new Set(['quit','exit','clear','help','settings','model','reset','compact','undo','redo','new','save','load']);
const interactiveSrc = fs.readFileSync('$TARGET_FILE', 'utf-8');
const extPriority = /isExtensionCommand\(\s*text\s*\)[\s\S]{0,400}?session\.prompt\(\s*text/.test(interactiveSrc);

if (builtins.has(registeredName) && !extPriority) {
    console.log('FAIL: example registers built-in name /' + registeredName + ' and no extension-priority routing exists');
    process.exit(1);
}
console.log('PASS: example registers reachable /' + registeredName + ' (extPriority=' + extPriority + ')');
process.exit(0);
"
if [ $? -eq 0 ]; then add_score 0.20; fi

echo ""
echo "=== Final reward: $REWARD ==="
write_reward
exit 0