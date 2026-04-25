#!/bin/bash
set +e

mkdir -p /logs/verifier

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD=0

add_reward() {
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + $1}")
}

cd /workspace/pi-mono 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }

BASELINE_EXTENSIONS="diff.ts files.ts prompt-url-widget.ts redraws.ts tps.ts"

# ============================================================
# Gate 1 (P2P): Environment sanity (0.05)
# ============================================================
echo "=== Gate 1 (P2P): Environment ==="
if command -v node >/dev/null 2>&1 && command -v bun >/dev/null 2>&1; then
    add_reward 0.05
    echo "PASS (0.05)"
else
    echo "FAIL: node=$(command -v node) bun=$(command -v bun)"
fi

# ============================================================
# Gate 2 (P2P): pi-mono repo structure intact (0.05)
# ============================================================
echo "=== Gate 2 (P2P): repo intact ==="
if [ -d /workspace/pi-mono/packages/coding-agent ] && \
   [ -f /workspace/pi-mono/package.json ] && \
   [ -d /workspace/pi-mono/.pi ]; then
    add_reward 0.05
    echo "PASS (0.05)"
else
    echo "FAIL"
fi

# ============================================================
# Locate new extension file
# ============================================================
echo "=== Locating new extension ==="
NEW_EXTS=""
for f in $(git -C /workspace/pi-mono ls-files --others --exclude-standard 2>/dev/null | grep '\.ts$'); do
    NEW_EXTS="$NEW_EXTS /workspace/pi-mono/$f"
done
for f in $(git -C /workspace/pi-mono diff --name-only HEAD 2>/dev/null | grep '\.ts$'); do
    case "$NEW_EXTS" in *"$f"*) ;; *) NEW_EXTS="$NEW_EXTS /workspace/pi-mono/$f" ;; esac
done

# Prefer .pi/extensions/*.ts that aren't baseline
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

# Fallback: any new .ts
if [ -z "$EXT_ABS" ]; then
    for f in $NEW_EXTS; do
        [ -f "$f" ] || continue
        BN=$(basename "$f")
        SKIP=0
        for b in $BASELINE_EXTENSIONS; do
            [ "$BN" = "$b" ] && SKIP=1 && break
        done
        [ $SKIP -eq 1 ] && continue
        EXT_ABS="$f"
        break
    done
fi

# Last resort: scan .pi/extensions for non-baseline
if [ -z "$EXT_ABS" ]; then
    for f in /workspace/pi-mono/.pi/extensions/*.ts; do
        [ -f "$f" ] || continue
        BN=$(basename "$f")
        SKIP=0
        for b in $BASELINE_EXTENSIONS; do
            [ "$BN" = "$b" ] && SKIP=1 && break
        done
        [ $SKIP -eq 1 ] || { EXT_ABS="$f"; break; }
    done
fi

echo "Extension: ${EXT_ABS:-<none>}"

# ============================================================
# Gate 3 (Structural): New extension file exists (0.05)
# ============================================================
echo "=== Gate 3: Extension file exists ==="
if [ -n "$EXT_ABS" ] && [ -f "$EXT_ABS" ] && [ -s "$EXT_ABS" ]; then
    add_reward 0.05
    echo "PASS (0.05)"
else
    echo "FAIL"
fi

# ============================================================
# Gate 4 (Structural): Compiles via bun --no-bundle (0.05)
# ============================================================
echo "=== Gate 4: Extension compiles ==="
G4_OK=0
if [ -n "$EXT_ABS" ]; then
    rm -rf /tmp/ext-compile && mkdir -p /tmp/ext-compile
    COMPILE_OUT=$(cd /workspace/pi-mono && bun build --no-bundle "$EXT_ABS" --outdir /tmp/ext-compile 2>&1)
    if ! echo "$COMPILE_OUT" | grep -qi "error" && echo "$COMPILE_OUT" | grep -qiE "transpiled|bundled|written"; then
        add_reward 0.05
        G4_OK=1
        echo "PASS (0.05)"
    else
        echo "FAIL: $COMPILE_OUT" | head -20
    fi
fi

# ============================================================
# Build a reusable mock harness
# ============================================================
mkdir -p /tmp/sigtest
cat > /tmp/sigtest/harness.ts <<'HARNESS'
// Generic harness: load extension, capture handlers + commands, expose helpers.
const extPath = process.argv[2];
const action = process.argv[3] || "summary";

const handlers: Record<string, Function> = {};
const commands: Record<string, any> = {};
const widgets: Record<string, any> = {};
const notifications: any[] = [];
const events: any[] = [];

const uiMock = {
    notify: (msg: string, kind?: string) => { notifications.push({ msg, kind }); },
    setWidget: (id: string, w: any) => { widgets[id] = w; },
    setStatus: (_id: string, _v: any) => {},
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
    session: { id: "test-session" },
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

// Try to activate via any "start"-like command
async function activate() {
    const candidates = Object.keys(commands).filter((n) =>
        /start|activate|signal|begin|enable|on/i.test(n)
    );
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

async function callMessageUpdate(text: string, delta: string) {
    const h = handlers["message_update"];
    if (!h) return null;
    const message = {
        role: "assistant",
        content: [{ type: "text", text }],
    };
    try {
        return await h(
            { message, assistantMessageEvent: { type: "text_delta", delta } },
            ctxMock,
        );
    } catch (e: any) {
        return { __error: e.message };
    }
}

if (action === "summary") {
    console.log(JSON.stringify({
        handlers: Object.keys(handlers),
        commands: Object.keys(commands),
    }));
} else if (action === "before_start") {
    const activated = await activate();
    const r = await callBeforeAgentStart();
    console.log(JSON.stringify({
        activated,
        result: r,
    }));
} else if (action === "signal_detect") {
    await activate();
    await callBeforeAgentStart();

    // Try a variety of signal styles models might emit
    const signalText = "Sure, I'll help. [[SHOW_UI]] [[OPEN_UI]] [[SIGNAL_OPEN_UI]] Working on it. [[DONE]] [[SIGNAL_DONE]]";

    // Stream via message_update token by token
    let acc = "";
    const tokens = signalText.split(/(\s+)/);
    for (const tok of tokens) {
        acc += tok;
        await callMessageUpdate(acc, tok);
    }
    // Then fire message_end
    await callMessageEnd(signalText);

    console.log(JSON.stringify({
        notifications,
        widgets: Object.keys(widgets).reduce((acc: any, k) => {
            acc[k] = widgets[k] !== undefined ? "set" : "cleared";
            return acc;
        }, {}),
        events,
    }));
} else if (action === "no_signal_noop") {
    await activate();
    await callBeforeAgentStart();
    const plainText = "Hello, this is a normal message with no special tokens.";
    let acc = "";
    for (const tok of plainText.split(/(\s+)/)) {
        acc += tok;
        await callMessageUpdate(acc, tok);
    }
    await callMessageEnd(plainText);
    console.log(JSON.stringify({
        notifications: notifications.length,
        widgetsTouched: Object.keys(widgets).length,
    }));
}
HARNESS

run_harness() {
    cd /workspace/pi-mono && timeout 30 bun run /tmp/sigtest/harness.ts "$EXT_ABS" "$1" 2>&1
}

# ============================================================
# Gate 5 (F2P Behavioral): Registers handlers + at least one command (0.10)
# ============================================================
echo "=== Gate 5 (F2P): Handler & command registration ==="
HANDLERS=""
COMMANDS=""
if [ -n "$EXT_ABS" ] && [ "$G4_OK" = "1" ]; then
    SUMMARY=$(run_harness "summary")
    echo "$SUMMARY" | tail -5
    LAST=$(echo "$SUMMARY" | tail -1)
    HANDLERS=$(echo "$LAST" | grep -oE '"handlers":\[[^]]*\]' | head -1)
    COMMANDS=$(echo "$LAST" | grep -oE '"commands":\[[^]]*\]' | head -1)
    HCOUNT=$(echo "$HANDLERS" | grep -oE '"[a-z_]+"' | wc -l)
    CCOUNT=$(echo "$COMMANDS" | grep -oE '"[a-z_-]+"' | wc -l)
    echo "handlers=$HCOUNT commands=$CCOUNT"
    if [ "$HCOUNT" -ge 1 ] && [ "$CCOUNT" -ge 1 ]; then
        add_reward 0.10
        echo "PASS (0.10)"
    elif [ "$HCOUNT" -ge 1 ]; then
        add_reward 0.05
        echo "PARTIAL (0.05): handlers but no commands"
    else
        echo "FAIL"
    fi
fi

# ============================================================
# Gate 6 (F2P Behavioral): Listens for assistant output (message_end or message_update) (0.10)
# ============================================================
echo "=== Gate 6 (F2P): Listens to assistant message stream ==="
if [ -n "$HANDLERS" ]; then
    if echo "$HANDLERS" | grep -qE '"message_end"|"message_update"'; then
        add_reward 0.10
        echo "PASS (0.10)"
    else
        echo "FAIL: no message_end/message_update handler"
    fi
fi

# ============================================================
# Gate 7 (F2P Behavioral): Injects signal protocol when activated (0.20)
# Strong: must mention signal-style tokens AND at least one verb (open/close/done/ui/show/hide/complete)
# Partial credit if injection present but no clear protocol vocabulary.
# ============================================================
echo "=== Gate 7 (F2P): Signal protocol injection ==="
if [ -n "$EXT_ABS" ] && [ "$G4_OK" = "1" ]; then
    BS_OUT=$(run_harness "before_start")
    echo "$BS_OUT" | tail -3
    LAST=$(echo "$BS_OUT" | tail -1)

    HAS_RESULT=0
    HAS_SP=0
    HAS_TOKENS=0
    HAS_VERBS=0

    if echo "$LAST" | grep -q '"result"'; then HAS_RESULT=1; fi
    if echo "$LAST" | grep -qE '"systemPrompt":"[^"]'; then HAS_SP=1; fi
    # Look for [[ ... ]] tokens or "signal" vocabulary inside the result
    if echo "$LAST" | grep -qiE '\[\[[A-Z_]+|SIGNAL_|signal '; then HAS_TOKENS=1; fi
    if echo "$LAST" | grep -qiE 'open|close|done|complete|show|hide|panel|ui'; then HAS_VERBS=1; fi

    if [ $HAS_SP -eq 1 ] && [ $HAS_TOKENS -eq 1 ] && [ $HAS_VERBS -eq 1 ]; then
        add_reward 0.20
        echo "PASS (0.20): full protocol injection"
    elif [ $HAS_SP -eq 1 ] && [ $HAS_TOKENS -eq 1 ]; then
        add_reward 0.12
        echo "PARTIAL (0.12): tokens but limited vocabulary"
    elif [ $HAS_RESULT -eq 1 ] && ([ $HAS_TOKENS -eq 1 ] || [ $HAS_VERBS -eq 1 ]); then
        add_reward 0.07
        echo "PARTIAL (0.07): some injection via message"
    else
        echo "FAIL: no signal protocol detected"
    fi
fi

# ============================================================
# Gate 8 (F2P Behavioral, KEY): Signals from model output trigger reactions (0.30)
# This is the core behavioral test — does the extension actually react to
# [[SIGNAL_*]] / [[SHOW_UI]] / [[DONE]] / [[OPEN_UI]] tokens in assistant text?
# Tiered:
#   - 0.30: triggers >=2 distinct reactions (notify or setWidget)
#   - 0.20: triggers exactly 1 reaction
#   - 0.10: events.emit or some side effect
#   - 0.00: nothing
# ============================================================
echo "=== Gate 8 (F2P): Signal token detection triggers reaction ==="
if [ -n "$EXT_ABS" ] && [ "$G4_OK" = "1" ]; then
    SD_OUT=$(run_harness "signal_detect")
    echo "$SD_OUT" | tail -3
    LAST=$(echo "$SD_OUT" | tail -1)

    NOTIF_COUNT=$(echo "$LAST" | grep -oE '"msg":' | wc -l)
    WIDGET_SET=$(echo "$LAST" | grep -oE '"set"' | wc -l)
    EVENT_COUNT=$(echo "$LAST" | grep -oE '"e":' | wc -l)

    echo "notifications=$NOTIF_COUNT widgets_set=$WIDGET_SET events=$EVENT_COUNT"

    REACTIONS=$((NOTIF_COUNT + WIDGET_SET))

    if [ $REACTIONS -ge 2 ]; then
        add_reward 0.30
        echo "PASS (0.30): multi-reaction signal handling"
    elif [ $REACTIONS -ge 1 ]; then
        add_reward 0.20
        echo "PARTIAL (0.20): single reaction"
    elif [ $EVENT_COUNT -ge 1 ]; then
        add_reward 0.10
        echo "PARTIAL (0.10): event emission only"
    else
        echo "FAIL: no observable reaction to signal tokens"
    fi
fi

# ============================================================
# Gate 9 (F2P Behavioral): No spurious reactions on normal text (0.10)
# Quality check: when no signal tokens appear, the extension should not
# fire UI side effects.
# ============================================================
echo "=== Gate 9 (F2P): No spurious reactions on plain text ==="
if [ -n "$EXT_ABS" ] && [ "$G4_OK" = "1" ]; then
    NN_OUT=$(run_harness "no_signal_noop")
    echo "$NN_OUT" | tail -3
    LAST=$(echo "$NN_OUT" | tail -1)
    NN_NOTIF=$(echo "$LAST" | grep -oE '"notifications":[0-9]+' | grep -oE '[0-9]+')
    NN_WIDGETS=$(echo "$LAST" | grep -oE '"widgetsTouched":[0-9]+' | grep -oE '[0-9]+')
    NN_NOTIF=${NN_NOTIF:-0}
    NN_WIDGETS=${NN_WIDGETS:-0}
    if [ "$NN_NOTIF" = "0" ] && [ "$NN_WIDGETS" = "0" ]; then
        add_reward 0.10
        echo "PASS (0.10): clean no-op"
    elif [ "$NN_NOTIF" -le 1 ] && [ "$NN_WIDGETS" -le 1 ]; then
        add_reward 0.05
        echo "PARTIAL (0.05): minor noise"
    else
        echo "FAIL: spurious reactions ($NN_NOTIF notif, $NN_WIDGETS widgets)"
    fi
fi

echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt