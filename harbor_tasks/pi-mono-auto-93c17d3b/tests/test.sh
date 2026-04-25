#!/bin/bash
set +e

mkdir -p /logs/verifier

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD=0

add_reward() {
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + $1}")
}

finalize() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

cd /workspace/pi-mono 2>/dev/null || finalize

BASELINE_EXTENSIONS="diff.ts files.ts prompt-url-widget.ts redraws.ts tps.ts go-to-bed.ts"

# ============================================================
# P2P GATE: Environment available (no reward, gating only)
# ============================================================
if ! command -v node >/dev/null 2>&1 || ! command -v bun >/dev/null 2>&1; then
    echo "P2P FAIL: node/bun missing"
    finalize
fi

# ============================================================
# P2P GATE: Repo intact (no reward)
# ============================================================
if [ ! -d /workspace/pi-mono/packages/coding-agent ] || \
   [ ! -f /workspace/pi-mono/package.json ] || \
   [ ! -d /workspace/pi-mono/.pi ]; then
    echo "P2P FAIL: repo structure missing"
    finalize
fi

# ============================================================
# Locate new (agent-created) extension file
# ============================================================
NEW_EXTS=""
for f in $(git -C /workspace/pi-mono ls-files --others --exclude-standard 2>/dev/null | grep '\.ts$'); do
    NEW_EXTS="$NEW_EXTS /workspace/pi-mono/$f"
done
for f in $(git -C /workspace/pi-mono diff --name-only HEAD 2>/dev/null | grep '\.ts$'); do
    case "$NEW_EXTS" in *"$f"*) ;; *) NEW_EXTS="$NEW_EXTS /workspace/pi-mono/$f" ;; esac
done

EXT_ABS=""
for f in $NEW_EXTS; do
    [ -f "$f" ] || continue
    BN=$(basename "$f")
    SKIP=0
    for b in $BASELINE_EXTENSIONS; do
        [ "$BN" = "$b" ] && SKIP=1 && break
    done
    [ $SKIP -eq 1 ] && continue
    case "$f" in
        */.pi/extensions/*.ts)
            EXT_ABS="$f"
            break
            ;;
    esac
done

if [ -z "$EXT_ABS" ]; then
    for f in $NEW_EXTS; do
        [ -f "$f" ] || continue
        BN=$(basename "$f")
        SKIP=0
        for b in $BASELINE_EXTENSIONS; do
            [ "$BN" = "$b" ] && SKIP=1 && break
        done
        [ $SKIP -eq 1 ] && continue
        case "$f" in
            */.pi/extensions/*.ts) EXT_ABS="$f"; break;;
        esac
    done
fi

if [ -z "$EXT_ABS" ]; then
    for f in /workspace/pi-mono/.pi/extensions/*.ts; do
        [ -f "$f" ] || continue
        BN=$(basename "$f")
        SKIP=0
        for b in $BASELINE_EXTENSIONS; do
            [ "$BN" = "$b" ] && SKIP=1 && break
        done
        if [ $SKIP -eq 0 ]; then
            # Make sure it's not tracked in HEAD
            if ! git -C /workspace/pi-mono ls-files --error-unmatch "${f#/workspace/pi-mono/}" >/dev/null 2>&1; then
                EXT_ABS="$f"
                break
            fi
        fi
    done
fi

echo "Extension: ${EXT_ABS:-<none>}"

# If no new extension, agent did nothing → reward stays at 0
if [ -z "$EXT_ABS" ] || [ ! -s "$EXT_ABS" ]; then
    echo "No new extension found — reward 0"
    finalize
fi

# ============================================================
# P2P GATE: Extension compiles (gating only, no reward)
# ============================================================
rm -rf /tmp/ext-compile && mkdir -p /tmp/ext-compile
COMPILE_OUT=$(cd /workspace/pi-mono && bun build --no-bundle "$EXT_ABS" --outdir /tmp/ext-compile 2>&1)
if echo "$COMPILE_OUT" | grep -qi "error" || ! echo "$COMPILE_OUT" | grep -qiE "transpiled|bundled|written"; then
    echo "P2P FAIL: extension does not compile"
    echo "$COMPILE_OUT" | head -20
    finalize
fi

# ============================================================
# Build harness for behavioral tests
# ============================================================
mkdir -p /tmp/sigtest
cat > /tmp/sigtest/harness.ts <<'HARNESS'
const extPath = process.argv[2];
const action = process.argv[3] || "summary";
const arg1 = process.argv[4] || "";
const arg2 = process.argv[5] || "";

const handlers: Record<string, Function> = {};
const commands: Record<string, any> = {};
const widgets: Record<string, any> = {};
const widgetHistory: Array<{ id: string; w: any }> = [];
const notifications: any[] = [];
const events: any[] = [];
const statuses: Record<string, any> = {};

const uiMock = {
    notify: (msg: string, kind?: string) => { notifications.push({ msg, kind }); },
    setWidget: (id: string, w: any) => { widgets[id] = w; widgetHistory.push({ id, w }); },
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
    session: { id: "test-session", messages: [] },
    addMessage: (m: any) => { ctxMock.session.messages.push(m); },
};

const piMock: any = new Proxy({}, {
    get(_t: any, p: string) {
        if (p === "on") return (e: string, h: Function) => { handlers[e] = h; };
        if (p === "registerCommand") return (n: string, o: any) => { commands[n] = o; };
        if (p === "events") return { emit: (e: string, d: any) => events.push({ e, d }), on: () => {} };
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
    const candidates = Object.keys(commands).filter((n) =>
        /^(start|signal-start|signal|activate|enable|on)$/i.test(n) ||
        /start|activate|enable/i.test(n)
    );
    candidates.sort((a, b) => {
        const aShort = /^(start|signal-start)$/i.test(a) ? 0 : 1;
        const bShort = /^(start|signal-start)$/i.test(b) ? 0 : 1;
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

async function callBeforeAgentStart() {
    const h = handlers["before_agent_start"];
    if (!h) return null;
    try {
        return await h(
            { systemPrompt: "Base prompt.", message: null, messages: [] },
            ctxMock,
        );
    } catch (e: any) {
        return { __error: e.message };
    }
}

async function callMessageEnd(text: string) {
    const h = handlers["message_end"];
    if (!h) return null;
    const message = {
        role: "assistant",
        content: [{ type: "text", text }],
        stopReason: "end_turn",
    };
    try {
        return await h({ message, assistantMessageEvent: { type: "text_delta", delta: text } }, ctxMock);
    } catch (e: any) {
        return { __error: e.message };
    }
}

async function callMessageStart() {
    const h = handlers["message_start"];
    if (!h) return null;
    const message = { role: "assistant", content: [{ type: "text", text: "" }] };
    try {
        return await h({ message }, ctxMock);
    } catch (e: any) { return { __error: e.message }; }
}

async function streamMessage(fullText: string, chunkSize = 8) {
    const hUpdate = handlers["message_update"];
    const hEnd = handlers["message_end"];
    let acc = "";
    await callMessageStart();
    for (let i = 0; i < fullText.length; i += chunkSize) {
        const delta = fullText.slice(i, i + chunkSize);
        acc += delta;
        const message = { role: "assistant", content: [{ type: "text", text: acc }] };
        if (hUpdate) {
            try {
                await hUpdate({ message, assistantMessageEvent: { type: "text_delta", delta } }, ctxMock);
            } catch {}
        }
    }
    if (hEnd) {
        const message = { role: "assistant", content: [{ type: "text", text: acc }], stopReason: "end_turn" };
        try {
            await hEnd({ message, assistantMessageEvent: { type: "text_delta", delta: "" } }, ctxMock);
        } catch {}
    }
}

if (action === "summary") {
    console.log(JSON.stringify({
        handlers: Object.keys(handlers),
        commands: Object.keys(commands),
    }));
} else if (action === "before_start_inactive") {
    // Without activation: should NOT inject signal protocol
    const r = await callBeforeAgentStart();
    const sp = (r && (r as any).systemPrompt) || "";
    const out = {
        prompt: sp,
        hasSignalRef: /SIGNAL|\[\[/.test(sp),
    };
    console.log(JSON.stringify(out));
} else if (action === "before_start_active") {
    const c = await activate();
    const r = await callBeforeAgentStart();
    const sp = (r && (r as any).systemPrompt) || "";
    // Some impls inject via custom message instead — also check session messages
    const msgs = JSON.stringify(ctxMock.session.messages || []);
    const blob = sp + "\n" + msgs;
    const out = {
        activated: c,
        promptLen: sp.length,
        // Look for any "signal-protocol-like" instruction
        hasSignalProtocol: /\[\[[A-Z_]+/.test(blob) || /signal/i.test(blob),
        injectsTokens: /\[\[[A-Z_]+\]\]/.test(blob),
    };
    console.log(JSON.stringify(out));
} else if (action === "signal_react") {
    await activate();
    await callBeforeAgentStart();
    // Emit a message that contains an open-UI-style signal token
    const text = arg1 || "Working on it. [[SIGNAL_OPEN_UI]] [[OPEN_UI]] [[SHOW_UI]] now starting.";
    await callMessageEnd(text);
    // Also try streaming for impls using message_update
    await streamMessage(text);
    const out = {
        notifications,
        widgets: Object.keys(widgets).filter((k) => widgets[k] !== undefined),
        widgetHistory: widgetHistory.map((w) => ({ id: w.id, defined: w.w !== undefined })),
        events,
        statuses: Object.keys(statuses),
    };
    console.log(JSON.stringify(out));
} else if (action === "signal_no_op") {
    await activate();
    await callBeforeAgentStart();
    // Plain text — no signal tokens at all
    const text = "Just a normal message, nothing special here.";
    await callMessageEnd(text);
    await streamMessage(text);
    const out = {
        notifications,
        widgets: Object.keys(widgets).filter((k) => widgets[k] !== undefined),
        widgetHistory,
    };
    console.log(JSON.stringify(out));
} else if (action === "signal_close") {
    await activate();
    await callBeforeAgentStart();
    // First open, then close
    await callMessageEnd("[[SIGNAL_OPEN_UI]] [[OPEN_UI]] [[SHOW_UI]]");
    await streamMessage("[[SIGNAL_OPEN_UI]] [[OPEN_UI]] [[SHOW_UI]]");
    const beforeClose = {
        widgets: Object.keys(widgets).filter((k) => widgets[k] !== undefined),
    };
    await callMessageEnd("[[SIGNAL_CLOSE_UI]] [[CLOSE_UI]] [[HIDE_UI]]");
    await streamMessage("[[SIGNAL_CLOSE_UI]] [[CLOSE_UI]] [[HIDE_UI]]");
    const out = {
        beforeClose,
        afterCloseWidgets: Object.keys(widgets).filter((k) => widgets[k] !== undefined),
        notifications,
    };
    console.log(JSON.stringify(out));
}
HARNESS

run_harness() {
    local action="$1"; shift
    cd /workspace/pi-mono && timeout 30 bun run /tmp/sigtest/harness.ts "$EXT_ABS" "$action" "$@" 2>&1
}

# ============================================================
# Get summary of registered handlers/commands
# ============================================================
SUMMARY=$(run_harness summary)
echo "Summary: $SUMMARY"

# Extract handler list
HANDLERS=$(echo "$SUMMARY" | grep -oE '"handlers":\[[^]]*\]' | head -1)
COMMANDS=$(echo "$SUMMARY" | grep -oE '"commands":\[[^]]*\]' | head -1)

# ============================================================
# F2P Gate A: Extension registers a slash command (0.10)
# Base = no extension exists → fails. Empty file → no commands → fails.
# ============================================================
echo "=== F2P A: registers a command ==="
if echo "$COMMANDS" | grep -qE '"[a-zA-Z_-]+"'; then
    add_reward 0.10
    echo "PASS A (0.10)"
else
    echo "FAIL A — no commands registered"
fi

# ============================================================
# F2P Gate B: Extension listens to assistant output stream (0.10)
# Must subscribe to message_end OR message_update (signal detection)
# ============================================================
echo "=== F2P B: listens to message_end or message_update ==="
if echo "$HANDLERS" | grep -qE '"(message_end|message_update)"'; then
    add_reward 0.10
    echo "PASS B (0.10)"
else
    echo "FAIL B"
fi

# ============================================================
# F2P Gate C: When inactive, no signal protocol leaks into prompt (0.10)
# Tests that activation gating actually works.
# ============================================================
echo "=== F2P C: inactive = no protocol injection ==="
INACTIVE=$(run_harness before_start_inactive)
echo "Inactive: $INACTIVE"
# Either before_agent_start returns null/no systemPrompt, OR systemPrompt has no signal refs.
# We accept: no signal token mention while inactive.
if echo "$INACTIVE" | grep -qE '"hasSignalRef":false' || ! echo "$INACTIVE" | grep -q '"prompt"'; then
    add_reward 0.10
    echo "PASS C (0.10)"
else
    # If extension auto-activates and always injects, that's still a working extension; partial credit none here
    echo "FAIL C — protocol leaks while inactive (or unable to verify)"
fi

# ============================================================
# F2P Gate D: After activation, signal protocol is injected (0.20)
# Either as systemPrompt addition OR custom message — must include [[TOKEN]] style.
# ============================================================
echo "=== F2P D: active = signal protocol injected ==="
ACTIVE=$(run_harness before_start_active)
echo "Active: $ACTIVE"
if echo "$ACTIVE" | grep -qE '"injectsTokens":true'; then
    add_reward 0.20
    echo "PASS D (0.20)"
else
    echo "FAIL D"
fi

# ============================================================
# F2P Gate E: Reacting to signal token produces observable side effect (0.30)
# Must call ui.notify, setWidget, setStatus, or emit an event when a known
# signal token appears in assistant output.
# ============================================================
echo "=== F2P E: signal token triggers side effect ==="
REACT=$(run_harness signal_react)
echo "React: $REACT"
NO_OP=$(run_harness signal_no_op)
echo "NoOp: $NO_OP"

# Count side effects when signal present
HAS_NOTIFY_REACT=0
HAS_WIDGET_REACT=0
HAS_STATUS_REACT=0
HAS_EVENT_REACT=0
echo "$REACT" | grep -qE '"notifications":\[\{' && HAS_NOTIFY_REACT=1
echo "$REACT" | grep -qE '"widgets":\["[^"]+"\]|"widgetHistory":\[\{' && HAS_WIDGET_REACT=1
echo "$REACT" | grep -qE '"statuses":\["[^"]+"\]' && HAS_STATUS_REACT=1
echo "$REACT" | grep -qE '"events":\[\{' && HAS_EVENT_REACT=1

# Count side effects on plain text (should be ZERO)
HAS_NOTIFY_NOOP=0
HAS_WIDGET_NOOP=0
echo "$NO_OP" | grep -qE '"notifications":\[\{' && HAS_NOTIFY_NOOP=1
echo "$NO_OP" | grep -qE '"widgets":\["[^"]+"\]' && HAS_WIDGET_NOOP=1

REACT_SIGNAL=$((HAS_NOTIFY_REACT + HAS_WIDGET_REACT + HAS_STATUS_REACT + HAS_EVENT_REACT))
NOOP_SIGNAL=$((HAS_NOTIFY_NOOP + HAS_WIDGET_NOOP))

if [ $REACT_SIGNAL -ge 1 ] && [ $NOOP_SIGNAL -eq 0 ]; then
    add_reward 0.30
    echo "PASS E (0.30) — signal-triggered side effect, no false positives"
elif [ $REACT_SIGNAL -ge 1 ] && [ $NOOP_SIGNAL -ge 1 ]; then
    # Reacts to signals but also fires on plain text — half credit
    add_reward 0.15
    echo "PARTIAL E (0.15) — reacts but also fires on non-signal text"
else
    echo "FAIL E — no observable reaction to signal tokens"
fi

# ============================================================
# F2P Gate F: Open/Close (or toggle) — open differs from close state (0.20)
# Demonstrates the bidirectional pattern: a "close"/"hide"/"done" signal
# undoes the effect of an "open"/"show" signal.
# ============================================================
echo "=== F2P F: open then close changes widget/state ==="
TOGGLE=$(run_harness signal_close)
echo "Toggle: $TOGGLE"

# Extract widget arrays
BEFORE=$(echo "$TOGGLE" | grep -oE '"beforeClose":\{"widgets":\[[^]]*\]' | head -1)
AFTER=$(echo "$TOGGLE" | grep -oE '"afterCloseWidgets":\[[^]]*\]' | head -1)

# Pass if EITHER (a) widget added on open and removed on close,
# OR (b) at least 2 distinct notifications (one for open, one for close)
NOTIF_COUNT=$(echo "$TOGGLE" | grep -oE '"msg":"[^"]*"' | wc -l)

PASS_F=0
# Widget toggle: opened then unset
if echo "$BEFORE" | grep -qE '"widgets":\["[^"]+"\]' && echo "$AFTER" | grep -qE '"afterCloseWidgets":\[\]'; then
    PASS_F=1
fi
# OR notification toggle: at least 2 distinct messages, with one matching open and one close
if [ $PASS_F -eq 0 ]; then
    if [ "$NOTIF_COUNT" -ge 2 ]; then
        # Check for open-themed and close-themed notifications
        if echo "$TOGGLE" | grep -qiE 'open|show' && echo "$TOGGLE" | grep -qiE 'close|hide|done'; then
            PASS_F=1
        fi
    fi
fi

if [ $PASS_F -eq 1 ]; then
    add_reward 0.20
    echo "PASS F (0.20) — open/close produce distinct effects"
else
    echo "FAIL F — open and close not differentiated"
fi

# ============================================================
# Final
# ============================================================
echo "=== Final reward: $REWARD ==="
finalize