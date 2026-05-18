#!/bin/bash
set +e


# Canonical PATH (E2B strips Dockerfile ENV PATH; restore tool dirs)
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

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

emit_gate() {
    local id="$1" passed="$2" detail="$3"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> /logs/verifier/gates.json
}

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
// Brace-balanced body extraction: regex \{([\s\S]*?)\n\s*\} stops at the FIRST
// closing brace, which mismatches when the canonical handler body contains an
// inner if-block. Walk braces from the '{' to find the true matching '}'.
const startMatch = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{/);
if (!startMatch) { console.log('FAIL: no shutdownHandler key'); process.exit(1); }
const startPos = src.indexOf(startMatch[0]) + startMatch[0].length;
let depth = 1, endPos = -1;
for (let i = startPos; i < src.length; i++) {
    const c = src[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { endPos = i; break; } }
}
if (endPos < 0) { console.log('FAIL: brace mismatch in handler'); process.exit(1); }
const body = src.slice(startPos, endPos);

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
if [ $? -eq 0 ]; then add_score 0.12; emit_gate "f2p_shutdown_handler_key" true "shutdownHandler key sets shutdownRequested"; else emit_gate "f2p_shutdown_handler_key" false "shutdownHandler missing or doesn't set flag"; fi

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
if [ $? -eq 0 ]; then add_score 0.24; emit_gate "f2p_deferred_shutdown_drain" true "drain path exists"; else emit_gate "f2p_deferred_shutdown_drain" false "no drain path"; fi

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

const startMatch = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{/);
if (!startMatch) { console.log('FAIL: no shutdownHandler'); process.exit(1); }
const startPos = src.indexOf(startMatch[0]) + startMatch[0].length;
let depth = 1, endPos = -1;
for (let i = startPos; i < src.length; i++) {
    const c = src[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { endPos = i; break; } }
}
if (endPos < 0) { console.log('FAIL: brace mismatch'); process.exit(1); }
const body = src.slice(startPos, endPos);

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
if [ $? -eq 0 ]; then add_score 0.16; emit_gate "f2p_shutdown_deferred_streaming" true "shutdown deferred when streaming"; else emit_gate "f2p_shutdown_deferred_streaming" false "shutdown called while streaming or not deferred"; fi

# ============================================================
# F2P Gate 4: when idle, handler triggers actual shutdown (sync or via setImmediate)
# Weight 0.15
# ============================================================
echo ""
echo "=== F2P Gate 4: shutdown invoked when idle ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf-8');

const startMatch = src.match(/shutdownHandler\s*:\s*(?:async\s*)?\(\s*\)\s*=>\s*\{/);
if (!startMatch) { console.log('FAIL: no shutdownHandler'); process.exit(1); }
const startPos = src.indexOf(startMatch[0]) + startMatch[0].length;
let depth = 1, endPos = -1;
for (let i = startPos; i < src.length; i++) {
    const c = src[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) { endPos = i; break; } }
}
if (endPos < 0) { console.log('FAIL: brace mismatch'); process.exit(1); }
const body = src.slice(startPos, endPos);

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
if [ $RES -eq 0 ]; then add_score 0.12; emit_gate "f2p_shutdown_invoked_idle" true "shutdown invoked when idle"; else emit_gate "f2p_shutdown_invoked_idle" false "shutdown not invoked when idle"; fi

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
if [ $? -eq 0 ]; then add_score 0.16; emit_gate "f2p_example_reachable_cmd" true "example registers reachable slash command"; else emit_gate "f2p_example_reachable_cmd" false "example missing or registers conflicting built-in"; fi

echo ""
echo "=== Final reward: $REWARD ==="
write_reward

# ---- inner-claude upstream gates ----
echo ""
echo "=== Upstream Gates ==="
mkdir -p /logs/verifier

# F2P: Example extension registers non-conflicting command
echo "--- f2p_upstream_example_cmd ---"
cd /workspace/pi-mono
EXAMPLE_FILE="packages/coding-agent/examples/extensions/shutdown-command.ts"
if [ -f "$EXAMPLE_FILE" ]; then
    npx tsx -e "
import ext from './packages/coding-agent/examples/extensions/shutdown-command.ts';
let cmdName = '';
const api = { registerCommand: (name) => { cmdName = name; }, registerTool: () => {} };
ext(api);
if (cmdName === 'quit') { console.log('FAIL: registers built-in /quit'); process.exit(1); }
console.log('PASS: registers /' + cmdName);
" > /tmp/f2p_example_cmd.log 2>&1
    F2P_EXAMPLE_RC=$?
else
    echo "FAIL: example file not found"
    F2P_EXAMPLE_RC=1
fi
if [ $F2P_EXAMPLE_RC -eq 0 ]; then
    echo '{"id": "f2p_upstream_example_cmd", "passed": true, "detail": "registers non-conflicting command"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "f2p_upstream_example_cmd", "passed": false, "detail": "registers conflicting built-in command or missing"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# P2P: tsgo typecheck (scoped to agent-touched .ts/.tsx files)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
echo "--- p2p_upstream_tsgo (scoped) ---"
cd /workspace/pi-mono
CHANGED_TS_FILES=$((git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
    echo '{"id": "p2p_upstream_tsgo", "passed": true, "detail": "no agent .ts/.tsx changes — gate skipped"}' >> /logs/verifier/gates.json
    echo "PASS (no agent .ts/.tsx changes — gate skipped)"
else
    npx tsgo --noEmit $CHANGED_TS_FILES > /tmp/p2p_tsgo.log 2>&1
    P2P_TSGO_RC=$?
    if [ $P2P_TSGO_RC -eq 0 ]; then
        echo '{"id": "p2p_upstream_tsgo", "passed": true, "detail": "typecheck passed on agent-changed files"}' >> /logs/verifier/gates.json
        echo "PASS"
    else
        echo '{"id": "p2p_upstream_tsgo", "passed": false, "detail": "typecheck failed on agent-changed files"}' >> /logs/verifier/gates.json
        echo "FAIL"
    fi
fi

# P2P: biome check on changed files
echo "--- p2p_upstream_biome ---"
cd /workspace/pi-mono
npx biome check --error-on-warnings packages/coding-agent/src/modes/interactive/interactive-mode.ts packages/coding-agent/src/modes/print-mode.ts packages/coding-agent/examples/extensions/shutdown-command.ts packages/coding-agent/src/core/extensions/types.ts > /tmp/p2p_biome.log 2>&1
P2P_BIOME_RC=$?
if [ $P2P_BIOME_RC -eq 0 ]; then
    echo '{"id": "p2p_upstream_biome", "passed": true, "detail": "biome check passed"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "p2p_upstream_biome", "passed": false, "detail": "biome check failed"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# P2P: vitest example extension tests
echo "--- p2p_upstream_vitest_examples ---"
cd /workspace/pi-mono
npx vitest run packages/coding-agent/test/trigger-compact-extension.test.ts packages/coding-agent/test/compaction-extensions-example.test.ts > /tmp/p2p_vitest.log 2>&1
P2P_VITEST_RC=$?
if [ $P2P_VITEST_RC -eq 0 ]; then
    echo '{"id": "p2p_upstream_vitest_examples", "passed": true, "detail": "vitest example tests passed"}' >> /logs/verifier/gates.json
    echo "PASS"
else
    echo '{"id": "p2p_upstream_vitest_examples", "passed": false, "detail": "vitest example tests failed"}' >> /logs/verifier/gates.json
    echo "FAIL"
fi

# ---- upstream reward tail ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_example_cmd": 0.20}
P2P_REGRESSION = ["p2p_upstream_tsgo", "p2p_upstream_biome", "p2p_upstream_vitest_examples"]
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

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
p2p_failed = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('REWARD=%.4f' % reward)
PYEOF
# ---- end ----

exit 0

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
