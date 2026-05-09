#!/bin/bash
set +e

mkdir -p /logs/verifier

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD=0

add_reward() {
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + $1}")
}

finalize() {
    echo "REWARD=$REWARD"
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

# ---- inner-claude upstream gates (runs on every exit path via trap) ----
run_upstream_gates() {
    mkdir -p /logs/verifier

    # F2P: Extension file exists and is non-empty
    # Accept either the runtime install path (instruction-canonical) OR the
    # source-tree examples path (upstream-canonical patch location).
    UPSTREAM_FILE=""
    for cand in \
        /workspace/pi-mono/.pi/extensions/message-signal.ts \
        /workspace/pi-mono/packages/coding-agent/examples/extensions/message-signal.ts; do
        if test -s "$cand"; then UPSTREAM_FILE="$cand"; break; fi
    done
    if [ -n "$UPSTREAM_FILE" ]; then
        echo "{\"id\": \"f2p_upstream_file_exists\", \"passed\": true, \"detail\": \"message-signal.ts found at $UPSTREAM_FILE\"}" >> /logs/verifier/gates.json
        echo "UPSTREAM f2p_upstream_file_exists PASS ($UPSTREAM_FILE)"
    else
        echo '{"id": "f2p_upstream_file_exists", "passed": false, "detail": "message-signal.ts missing or empty in both .pi/extensions and packages/coding-agent/examples/extensions"}' >> /logs/verifier/gates.json
        echo "UPSTREAM f2p_upstream_file_exists FAIL"
    fi

    # F2P: Extension loads via bun and exports a function
    if [ -n "$UPSTREAM_FILE" ] && cd /workspace/pi-mono && bun -e "try { const m = await import('$UPSTREAM_FILE'); if (typeof m.default !== 'function') process.exit(1); } catch { process.exit(1); }" 2>/dev/null; then
        echo '{"id": "f2p_upstream_ext_loadable", "passed": true, "detail": "Extension imports and exports default function"}' >> /logs/verifier/gates.json
        echo "UPSTREAM f2p_upstream_ext_loadable PASS"
    else
        echo '{"id": "f2p_upstream_ext_loadable", "passed": false, "detail": "Extension failed to import or no default function export"}' >> /logs/verifier/gates.json
        echo "UPSTREAM f2p_upstream_ext_loadable FAIL"
    fi

    # P2P: Extensions directory exists
    if test -d /workspace/pi-mono/.pi/extensions; then
        echo '{"id": "p2p_upstream_extensions_dir", "passed": true, "detail": ".pi/extensions directory exists"}' >> /logs/verifier/gates.json
        echo "UPSTREAM p2p_upstream_extensions_dir PASS"
    else
        echo '{"id": "p2p_upstream_extensions_dir", "passed": false, "detail": ".pi/extensions directory missing"}' >> /logs/verifier/gates.json
        echo "UPSTREAM p2p_upstream_extensions_dir FAIL"
    fi

    # P2P: Existing extension tps.ts compiles
    if cd /workspace/pi-mono && bun build --no-bundle .pi/extensions/tps.ts > /dev/null 2>&1; then
        echo '{"id": "p2p_upstream_existing_ext_compiles", "passed": true, "detail": "tps.ts compiles with bun"}' >> /logs/verifier/gates.json
        echo "UPSTREAM p2p_upstream_existing_ext_compiles PASS"
    else
        echo '{"id": "p2p_upstream_existing_ext_compiles", "passed": false, "detail": "tps.ts failed to compile"}' >> /logs/verifier/gates.json
        echo "UPSTREAM p2p_upstream_existing_ext_compiles FAIL"
    fi

    # Adjust reward based on upstream gates
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_file_exists": 0.05,    # informational; reduced from 0.20
    "f2p_upstream_ext_loadable": 0.05,   # informational; reduced from 0.20
}
# inner_weight = 1.0 - 0.10 = 0.90 → bash-computed behavioral reward (the
# genuine inner gate, accumulated via add_reward) gets 90% weight.
# The former f2p_gate1..6 keys were never emitted into gates.json, so they
# only shrank inner_weight without ever contributing — removed.
P2P_REGRESSION = ["p2p_upstream_extensions_dir", "p2p_upstream_existing_ext_compiles"]
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
if p2p_failed or (not f2p_any_pass and existing <= 0):
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
}
trap run_upstream_gates EXIT

cd /workspace/pi-mono 2>/dev/null || finalize

BASELINE_EXTENSIONS="diff.ts files.ts prompt-url-widget.ts redraws.ts tps.ts go-to-bed.ts"

# ============================================================
# P2P GATE: Environment available
# ============================================================
if ! command -v node >/dev/null 2>&1 || ! command -v bun >/dev/null 2>&1; then
    echo "P2P FAIL: node/bun missing"
    finalize
fi

if [ ! -d /workspace/pi-mono/packages/coding-agent ] || \
   [ ! -f /workspace/pi-mono/package.json ] || \
   [ ! -d /workspace/pi-mono/.pi ]; then
    echo "P2P FAIL: repo structure missing"
    finalize
fi

# ============================================================
# Locate new (agent-created) extension file
# Search both the runtime install path (.pi/extensions/, what the instruction
# tells the agent to use) and the source-tree examples path (where the
# upstream canonical patch lives — the maintainer-rejected example dir).
# ============================================================
EXT_ABS=""
SEARCH_DIRS=(
    /workspace/pi-mono/.pi/extensions
    /workspace/pi-mono/packages/coding-agent/examples/extensions
)
for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.ts; do
        [ -f "$f" ] || continue
        BN=$(basename "$f")
        SKIP=0
        for b in $BASELINE_EXTENSIONS; do
            [ "$BN" = "$b" ] && SKIP=1 && break
        done
        [ $SKIP -eq 1 ] && continue
        if ! git -C /workspace/pi-mono ls-files --error-unmatch "${f#/workspace/pi-mono/}" >/dev/null 2>&1; then
            EXT_ABS="$f"
            break 2
        fi
        # also accept modified
        if git -C /workspace/pi-mono diff --name-only HEAD -- "${f#/workspace/pi-mono/}" 2>/dev/null | grep -q .; then
            EXT_ABS="$f"
            break 2
        fi
    done
done

echo "Extension: ${EXT_ABS:-<none>}"

# No-op patch → reward 0
if [ -z "$EXT_ABS" ] || [ ! -s "$EXT_ABS" ]; then
    echo "No new extension found — reward 0"
    finalize
fi

# ============================================================
# P2P GATE: Extension compiles (gating only)
# ============================================================
rm -rf /tmp/ext-compile && mkdir -p /tmp/ext-compile
COMPILE_OUT=$(cd /workspace/pi-mono && bun build --no-bundle "$EXT_ABS" --outdir /tmp/ext-compile 2>&1)
if echo "$COMPILE_OUT" | grep -qi "error" || ! echo "$COMPILE_OUT" | grep -qiE "transpiled|bundled|written"; then
    echo "P2P FAIL: extension does not compile"
    echo "$COMPILE_OUT" | head -30
    finalize
fi

EXT_SRC=$(cat "$EXT_ABS")

# ============================================================
# Build harness
# ============================================================
mkdir -p /tmp/sigtest
cat > /tmp/sigtest/harness.ts <<'HARNESS'
const extPath = process.argv[2];
const action = process.argv[3] || "summary";
const extraText = process.argv[4] || "";

const handlers: Record<string, Function[]> = {};
const commands: Record<string, any> = {};
const widgets: Record<string, any> = {};
const widgetHistory: Array<{ id: string; w: any }> = [];
const notifications: any[] = [];
const events: any[] = [];
const statuses: Record<string, any> = {};
const sessionMessages: any[] = [];
let setWidgetCalls = 0;

const uiMock = {
    notify: (msg: string, kind?: string) => { notifications.push({ msg, kind }); },
    setWidget: (id: string, w: any) => { setWidgetCalls++; widgets[id] = w; widgetHistory.push({ id, w }); },
    setStatus: (id: string, v: any) => { statuses[id] = v; },
    setWorkingMessage: (_v: any) => {},
    setWorkingIndicator: (_v: any) => {},
    select: async () => null,
    confirm: async () => true,
    theme: {
        fg: (_c: string, t: string) => t,
        bg: (_c: string, t: string) => t,
    },
};

const ctxMock: any = {
    hasUI: true,
    ui: uiMock,
    session: { id: "test-session", messages: sessionMessages },
    addMessage: (m: any) => { sessionMessages.push(m); },
    isIdle: () => false,
};

const piMock: any = new Proxy({}, {
    get(_t: any, p: string) {
        if (p === "on") return (e: string, h: Function) => {
            if (!handlers[e]) handlers[e] = [];
            handlers[e].push(h);
        };
        if (p === "registerCommand") return (n: string, o: any) => { commands[n] = o; };
        // Capture pi.sendMessage(...) (canonical path) into sessionMessages so
        // the activation-injects-protocol gate can detect injected hidden
        // protocol instructions regardless of whether the extension uses
        // ctx.addMessage (runtime path) or pi.sendMessage (canonical path).
        if (p === "sendMessage") return (m: any, _opts?: any) => { sessionMessages.push(m); };
        if (p === "events") return {
            emit: (e: string, d: any) => events.push({ e, d }),
            on: (e: string, h: Function) => {
                if (!handlers[`event:${e}`]) handlers[`event:${e}`] = [];
                handlers[`event:${e}`].push(h);
            },
        };
        if (p === "then") return undefined;
        return (..._a: any[]) => undefined;
    },
});

let mod: any;
try {
    mod = await import(extPath);
} catch (e: any) {
    console.log(`LOAD_ERROR: ${e.message}`);
    process.exit(2);
}

const extFn = mod.default || (mod && Object.values(mod).find((v: any) => typeof v === "function"));
if (typeof extFn !== "function") {
    console.log("NO_EXPORT");
    process.exit(2);
}

try {
    const r = extFn(piMock);
    if (r && typeof r.then === "function") await r;
} catch (e: any) {
    console.log(`INIT_ERROR: ${e.message}`);
    process.exit(2);
}

async function activate(): Promise<string | null> {
    const names = Object.keys(commands);
    const candidates = names.filter((n) =>
        /^(start|signal-start|signal|activate|enable|on|signalstart)$/i.test(n) ||
        /start|activate|enable/i.test(n)
    );
    candidates.sort((a, b) => {
        const aShort = /^(start|signal-start|signal)$/i.test(a) ? 0 : 1;
        const bShort = /^(start|signal-start|signal)$/i.test(b) ? 0 : 1;
        return aShort - bShort;
    });
    for (const name of candidates) {
        const cmd = commands[name];
        const handler = typeof cmd === "function" ? cmd : (cmd && cmd.handler);
        if (typeof handler === "function") {
            try {
                const r = handler("", ctxMock);
                if (r && r.then) await r;
                return name;
            } catch {}
        }
    }
    return null;
}

async function callBeforeAgentStart(): Promise<any> {
    const hs = handlers["before_agent_start"] || [];
    let result = null;
    for (const h of hs) {
        try {
            const r = await h({ systemPrompt: "Base prompt.", message: null }, ctxMock);
            if (r) result = r;
        } catch (e: any) {}
    }
    return result;
}

function makeAssistantMessage(text: string): any {
    return {
        role: "assistant",
        content: [{ type: "text", text }],
        stopReason: "end_turn",
    };
}

async function fireMessageEnd(text: string) {
    const hs = handlers["message_end"] || [];
    for (const h of hs) {
        try {
            await h({ message: makeAssistantMessage(text) }, ctxMock);
        } catch (e: any) {}
    }
}

async function fireMessageUpdate(fullText: string, delta: string) {
    const hs = handlers["message_update"] || [];
    for (const h of hs) {
        try {
            await h({
                message: makeAssistantMessage(fullText),
                assistantMessageEvent: { type: "text_delta", delta },
            }, ctxMock);
        } catch (e: any) {}
    }
}

async function fireMessageStart() {
    const hs = handlers["message_start"] || [];
    for (const h of hs) {
        try {
            await h({ message: makeAssistantMessage("") }, ctxMock);
        } catch (e: any) {}
    }
}

async function streamMessage(text: string) {
    await fireMessageStart();
    let acc = "";
    // chunk into ~5-char pieces to simulate streaming
    const chunks: string[] = [];
    for (let i = 0; i < text.length; i += 5) chunks.push(text.slice(i, i + 5));
    for (const c of chunks) {
        acc += c;
        await fireMessageUpdate(acc, c);
    }
    await fireMessageEnd(acc);
}

if (action === "summary") {
    const evtNames = Object.keys(handlers);
    console.log("EVENTS=" + evtNames.join(","));
    console.log("COMMANDS=" + Object.keys(commands).join(","));
    process.exit(0);
}

if (action === "activate-only") {
    const cmd = await activate();
    console.log("ACTIVATED=" + (cmd || ""));
    console.log("COMMANDS=" + Object.keys(commands).join(","));
    process.exit(0);
}

if (action === "before-start") {
    const r = await callBeforeAgentStart();
    if (r && r.systemPrompt) {
        console.log("HAS_SYSTEM_PROMPT=1");
        console.log("PROMPT_LEN=" + r.systemPrompt.length);
        console.log("PROMPT_DELTA_LEN=" + (r.systemPrompt.length - "Base prompt.".length));
        // Print prompt for grep
        console.log("---PROMPT_START---");
        console.log(r.systemPrompt);
        console.log("---PROMPT_END---");
    } else {
        console.log("HAS_SYSTEM_PROMPT=0");
    }
    process.exit(0);
}

if (action === "signal-roundtrip") {
    // Activate the extension
    await activate();
    // Run a before_agent_start (some implementations inject prompt here)
    await callBeforeAgentStart();

    // Inspect what the activation/before-start put into context
    const sysHints: string[] = [];
    for (const m of sessionMessages) {
        try { sysHints.push(JSON.stringify(m)); } catch {}
    }
    console.log("SESSION_MESSAGE_COUNT=" + sessionMessages.length);
    console.log("SESSION_HINTS=" + sysHints.join("||").slice(0, 4000));

    // Use extraText (signal token list) — feed several known signal token formats
    const candidates = [
        "Hello [[SIGNAL_OPEN_UI]] world",
        "Hello [[OPEN_UI]] world",
        "Hello [[SHOW_UI]] world",
        "Hello [[SIGNAL_CLOSE_UI]] world",
        "Hello [[CLOSE_UI]] world",
        "Hello [[HIDE_UI]] world",
        "Hello [[DONE]] world",
        "Hello [[SIGNAL_DONE]] world",
    ];
    for (const t of candidates) {
        await streamMessage(t);
    }

    console.log("NOTIFICATIONS=" + notifications.length);
    for (const n of notifications) {
        console.log("NOTIFY: " + JSON.stringify(n));
    }
    console.log("SET_WIDGET_CALLS=" + setWidgetCalls);
    console.log("WIDGET_HISTORY_COUNT=" + widgetHistory.length);
    for (const h of widgetHistory) {
        console.log("WIDGET: id=" + h.id + " value=" + (h.w === undefined ? "undefined" : "set"));
    }
    console.log("EVENTS_EMITTED=" + events.length);
    process.exit(0);
}

if (action === "no-active-passive") {
    // Don't activate. Fire a signal-bearing message. Should NOT react.
    await streamMessage("Random text [[SIGNAL_OPEN_UI]] [[OPEN_UI]] [[SHOW_UI]] [[DONE]]");
    console.log("NOTIFICATIONS_PRE=" + notifications.length);
    console.log("SET_WIDGET_CALLS_PRE=" + setWidgetCalls);
    process.exit(0);
}

console.log("UNKNOWN_ACTION");
process.exit(1);
HARNESS

cd /workspace/pi-mono

run_harness() {
    local action="$1"
    local extra="$2"
    timeout 30 bun /tmp/sigtest/harness.ts "$EXT_ABS" "$action" "$extra" 2>&1
}

SUMMARY=$(run_harness summary "")
echo "=== SUMMARY ==="
echo "$SUMMARY"

# ============================================================
# F2P Gate 1 (weight 0.15): Extension registers a command AND a message_end OR message_update handler
# Tests basic structural integrity — the signal pattern requires both
# ============================================================
HAS_CMD=0
HAS_MSG_HANDLER=0
if echo "$SUMMARY" | grep -q "^COMMANDS=" && echo "$SUMMARY" | grep "^COMMANDS=" | grep -qE "[a-zA-Z]"; then
    HAS_CMD=1
fi
if echo "$SUMMARY" | grep "^EVENTS=" | grep -qE "message_end|message_update"; then
    HAS_MSG_HANDLER=1
fi
if [ "$HAS_CMD" -eq 1 ] && [ "$HAS_MSG_HANDLER" -eq 1 ]; then
    echo "GATE1 PASS: command + message handler registered"
    add_reward 0.15
else
    echo "GATE1 FAIL: HAS_CMD=$HAS_CMD HAS_MSG_HANDLER=$HAS_MSG_HANDLER"
fi

# ============================================================
# F2P Gate 2 (weight 0.20): Activation injects signal protocol
# Either via systemPrompt mutation in before_agent_start, or via session.addMessage,
# AND the injected text must reference at least one signal-style token like [[...]]
# ============================================================
ACTIVATE_OUT=$(run_harness activate-only "")
echo "=== ACTIVATE ==="
echo "$ACTIVATE_OUT"

BEFORE_OUT=$(run_harness before-start "")
echo "=== BEFORE_START ==="
echo "$BEFORE_OUT" | head -50

ROUNDTRIP_OUT=$(run_harness signal-roundtrip "")
echo "=== ROUNDTRIP ==="
echo "$ROUNDTRIP_OUT"

PROTOCOL_INJECTED=0
# Check session messages from session-message-injection style
SESSION_HINTS=$(echo "$ROUNDTRIP_OUT" | grep "^SESSION_HINTS=" | head -1)
PROMPT_TEXT=$(echo "$BEFORE_OUT" | sed -n '/---PROMPT_START---/,/---PROMPT_END---/p')

COMBINED_INJECTED="${SESSION_HINTS}${PROMPT_TEXT}"

if echo "$COMBINED_INJECTED" | grep -qE '\[\[[A-Z_]+(SIGNAL|OPEN|CLOSE|SHOW|HIDE|DONE|UI)[A-Z_]*\]\]|\[\[SIGNAL_'; then
    PROTOCOL_INJECTED=1
fi

if [ "$PROTOCOL_INJECTED" -eq 1 ]; then
    echo "GATE2 PASS: signal protocol injected (via session msg or system prompt)"
    add_reward 0.20
else
    echo "GATE2 FAIL: no signal protocol injected on activation"
fi

# ============================================================
# F2P Gate 3 (weight 0.20): Extension reacts to assistant signal output
# Activate, fire several known signal tokens via streaming. Must produce
# at least one notification or setWidget call.
# ============================================================
NOTIFY_COUNT=$(echo "$ROUNDTRIP_OUT" | grep "^NOTIFICATIONS=" | head -1 | sed 's/^NOTIFICATIONS=//')
WIDGET_CALLS=$(echo "$ROUNDTRIP_OUT" | grep "^SET_WIDGET_CALLS=" | head -1 | sed 's/^SET_WIDGET_CALLS=//')
EVT_COUNT=$(echo "$ROUNDTRIP_OUT" | grep "^EVENTS_EMITTED=" | head -1 | sed 's/^EVENTS_EMITTED=//')
[ -z "$NOTIFY_COUNT" ] && NOTIFY_COUNT=0
[ -z "$WIDGET_CALLS" ] && WIDGET_CALLS=0
[ -z "$EVT_COUNT" ] && EVT_COUNT=0

REACTED_TOTAL=$((NOTIFY_COUNT + WIDGET_CALLS + EVT_COUNT))
if [ "$REACTED_TOTAL" -ge 1 ]; then
    echo "GATE3 PASS: extension reacted to signals (notifs=$NOTIFY_COUNT widgets=$WIDGET_CALLS events=$EVT_COUNT)"
    add_reward 0.20
else
    echo "GATE3 FAIL: no observable reaction to any signal"
fi

# ============================================================
# F2P Gate 4 (weight 0.15): Recognizes BOTH an open-UI and a close-UI signal
# Tests that more than one distinct signal kind is implemented.
# Look for notifications referencing different signal semantics.
# ============================================================
OPEN_REACTED=0
CLOSE_REACTED=0
DONE_REACTED=0

NOTIFY_LINES=$(echo "$ROUNDTRIP_OUT" | grep "^NOTIFY:")
WIDGET_LINES=$(echo "$ROUNDTRIP_OUT" | grep "^WIDGET:")

# OPEN-style: any notify mentioning open/show/UI panel opened, OR a setWidget with a defined value
if echo "$NOTIFY_LINES" | grep -qiE "open|show|panel.*open"; then
    OPEN_REACTED=1
fi
if echo "$WIDGET_LINES" | grep -q "value=set"; then
    OPEN_REACTED=1
fi

# CLOSE-style: notify mentioning close/hide, OR setWidget with undefined
if echo "$NOTIFY_LINES" | grep -qiE "close|hide|panel.*closed"; then
    CLOSE_REACTED=1
fi
if echo "$WIDGET_LINES" | grep -q "value=undefined"; then
    CLOSE_REACTED=1
fi

# DONE-style: notify mentioning done/complete/task
if echo "$NOTIFY_LINES" | grep -qiE "done|complete|finished|task"; then
    DONE_REACTED=1
fi

DISTINCT=$((OPEN_REACTED + CLOSE_REACTED + DONE_REACTED))
if [ "$DISTINCT" -ge 2 ]; then
    echo "GATE4 PASS: distinct signal kinds reacted: open=$OPEN_REACTED close=$CLOSE_REACTED done=$DONE_REACTED"
    add_reward 0.15
else
    echo "GATE4 FAIL: only $DISTINCT distinct signal kinds reacted"
fi

# ============================================================
# F2P Gate 5 (weight 0.15): Inactive (no /start) → no reaction
# Critical correctness: signals must be IGNORED when feature is off.
# ============================================================
PASSIVE_OUT=$(run_harness no-active-passive "")
echo "=== PASSIVE ==="
echo "$PASSIVE_OUT"

PASSIVE_NOTIFY=$(echo "$PASSIVE_OUT" | grep "^NOTIFICATIONS_PRE=" | head -1 | sed 's/^NOTIFICATIONS_PRE=//')
PASSIVE_WIDGET=$(echo "$PASSIVE_OUT" | grep "^SET_WIDGET_CALLS_PRE=" | head -1 | sed 's/^SET_WIDGET_CALLS_PRE=//')
[ -z "$PASSIVE_NOTIFY" ] && PASSIVE_NOTIFY=0
[ -z "$PASSIVE_WIDGET" ] && PASSIVE_WIDGET=0

if [ "$PASSIVE_NOTIFY" -eq 0 ] && [ "$PASSIVE_WIDGET" -eq 0 ]; then
    echo "GATE5 PASS: extension is inert before activation"
    add_reward 0.15
else
    echo "GATE5 FAIL: pre-activation reaction notifs=$PASSIVE_NOTIFY widgets=$PASSIVE_WIDGET"
fi

# ============================================================
# F2P Gate 6 (weight 0.15): Source-code shape — pattern fidelity
# A correct demo of "signals via output" needs:
#  (a) a regex/match against [[ ... ]] tokens, AND
#  (b) the extension does NOT register any tools (the whole point)
# ============================================================
PATTERN_REGEX=0
NO_TOOLS=0

if echo "$EXT_SRC" | grep -qE '\\\[\\\[|\[\[[A-Z_]+'; then
    PATTERN_REGEX=1
fi

# check for tool registration patterns
if echo "$EXT_SRC" | grep -qE 'registerTool|pi\.tool\(|defineTool|\.tools\.'; then
    NO_TOOLS=0
else
    NO_TOOLS=1
fi

if [ "$PATTERN_REGEX" -eq 1 ] && [ "$NO_TOOLS" -eq 1 ]; then
    echo "GATE6 PASS: signal-token pattern present, no tool registration"
    add_reward 0.15
else
    echo "GATE6 FAIL: PATTERN_REGEX=$PATTERN_REGEX NO_TOOLS=$NO_TOOLS"
fi

echo "FINAL REWARD=$REWARD"
echo "$REWARD" > /logs/verifier/reward.txt