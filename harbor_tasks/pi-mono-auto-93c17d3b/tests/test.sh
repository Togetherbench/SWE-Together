#!/bin/bash
set +e

mkdir -p /logs/verifier

# Baseline extensions at commit 5133697 (skip when scanning)
BASELINE_EXTENSIONS="diff.ts files.ts prompt-url-widget.ts redraws.ts tps.ts"

REWARD=0

# Nop baseline score: 0.10 (only P2P gates 1+2 pass on unmodified base)

add_reward() {
    REWARD=$(awk "BEGIN {printf \"%.2f\", $REWARD + $1}")
}

cd /workspace/pi-mono

# ============================================================
# Gate 1 (P2P): Environment sanity — node and bun available
# Weight: 0.05
# ============================================================
echo "=== Gate 1 (P2P): Environment sanity ==="
if node --version >/dev/null 2>&1 && bun --version >/dev/null 2>&1; then
    add_reward 0.05
    echo "PASS (0.05)"
else
    echo "FAIL"
fi

# ============================================================
# Gate 2 (P2P): pi-mono repo intact
# Weight: 0.05
# ============================================================
echo "=== Gate 2 (P2P): pi-mono repo intact ==="
if [ -d /workspace/pi-mono/packages/coding-agent ] && \
   [ -f /workspace/pi-mono/package.json ]; then
    add_reward 0.05
    echo "PASS (0.05)"
else
    echo "FAIL"
fi

# ============================================================
# Detect new TypeScript extension files
# ============================================================
echo "=== Scanning for new extension files ==="

NEW_EXTS=""

for f in $(git ls-files --others --exclude-standard 2>/dev/null | grep '\.ts$'); do
    NEW_EXTS="$NEW_EXTS $f"
done

for f in $(git diff --name-only HEAD 2>/dev/null | grep '\.ts$'); do
    NEW_EXTS="$NEW_EXTS $f"
done

for f in $(find /workspace -name '*.ts' -newer /workspace/pi-mono/.git/HEAD \
    -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null); do
    BASENAME=$(basename "$f")
    IS_BASELINE=0
    for b in $BASELINE_EXTENSIONS; do
        if [ "$BASENAME" = "$b" ]; then IS_BASELINE=1; break; fi
    done
    if [ $IS_BASELINE -eq 0 ]; then
        REL=$(echo "$f" | sed "s|^/workspace/pi-mono/||")
        case "$NEW_EXTS" in
            *"$REL"*) ;;
            *) NEW_EXTS="$NEW_EXTS $REL" ;;
        esac
    fi
done

NEW_EXTS=$(echo "$NEW_EXTS" | xargs)
FIRST_EXT=$(echo "$NEW_EXTS" | awk '{print $1}')
echo "New files: ${NEW_EXTS:-none}"

EXT_ABS=""
if [ -n "$FIRST_EXT" ]; then
    if [ -f "$FIRST_EXT" ]; then
        EXT_ABS="$(realpath "$FIRST_EXT" 2>/dev/null || echo "$FIRST_EXT")"
    elif [ -f "/workspace/pi-mono/$FIRST_EXT" ]; then
        EXT_ABS="/workspace/pi-mono/$FIRST_EXT"
    fi
fi

# ============================================================
# Gate 3 (F2P): New extension file exists
# Weight: 0.10
# ============================================================
echo "=== Gate 3 (F2P): New extension file exists ==="
if [ -n "$EXT_ABS" ] && [ -f "$EXT_ABS" ]; then
    add_reward 0.10
    echo "PASS (0.10): $EXT_ABS"
else
    echo "FAIL"
fi

# ============================================================
# Gate 4 (F2P): Extension compiles — bun transpile
# Weight: 0.10
# Basic syntax check via bun build --no-bundle.
# ============================================================
echo "=== Gate 4 (F2P): Extension compiles (bun build) ==="
if [ -n "$EXT_ABS" ]; then
    rm -rf /tmp/ext-compile && mkdir -p /tmp/ext-compile
    COMPILE_OUT=$(cd /workspace/pi-mono && bun build --no-bundle "$EXT_ABS" --outdir /tmp/ext-compile 2>&1)
    if echo "$COMPILE_OUT" | grep -qi "error"; then
        echo "FAIL: compilation errors"
    elif echo "$COMPILE_OUT" | grep -qi "transpiled"; then
        add_reward 0.10
        echo "PASS (0.10)"
    else
        echo "FAIL"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 5 (F2P): Registers event handlers AND slash commands
# Weight: 0.10
# ============================================================
echo "=== Gate 5 (F2P): Registers handlers and commands ==="
if [ -n "$EXT_ABS" ]; then
    cat > /tmp/test-gate5.ts <<'HARNESS'
const extPath = process.argv[2];
const mod = await import(extPath.startsWith("/") ? extPath : `${process.cwd()}/${extPath}`);
const extFn = mod.default || mod[Object.keys(mod).find(k => typeof mod[k] === "function") || ""];
if (typeof extFn !== "function") { console.log("FAIL: no callable export"); process.exit(1); }
const handlers: Record<string, any> = {};
const commands: Record<string, any> = {};
const mockPi: any = new Proxy({}, {
    get(_t: any, p: string) {
        if (p === "on") return (e: string, h: any) => { handlers[e] = h; };
        if (p === "registerCommand") return (n: string, o: any) => { commands[n] = o; };
        if (p === "then") return undefined;
        return (..._a: any[]) => undefined;
    }
});
try { const r = extFn(mockPi); if (r?.then) await r; } catch(e: any) { console.log(`FAIL: ${e.message}`); process.exit(1); }
const h = Object.keys(handlers).length, c = Object.keys(commands).length;
if (h > 0 && c > 0) { console.log(`PASS: ${h} handlers, ${c} commands`); process.exit(0); }
else { console.log(`FAIL: handlers=${h} commands=${c}`); process.exit(1); }
HARNESS
    G5=$(cd /workspace/pi-mono && bun run /tmp/test-gate5.ts "$EXT_ABS" 2>&1)
    echo "$G5"
    if echo "$G5" | grep -q "^PASS"; then
        add_reward 0.10
        echo "PASS (0.10)"
    else
        echo "FAIL"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 6 (F2P): before_agent_start injects signal protocol
# Weight: 0.15
# Calls handler and checks systemPrompt is augmented with signals.
# ============================================================
echo "=== Gate 6 (F2P): before_agent_start injects signal instructions ==="
if [ -n "$EXT_ABS" ]; then
    cat > /tmp/test-gate6.ts <<'HARNESS'
const extPath = process.argv[2];
const mod = await import(extPath.startsWith("/") ? extPath : `${process.cwd()}/${extPath}`);
const extFn = mod.default || mod[Object.keys(mod).find(k => typeof mod[k] === "function") || ""];
if (typeof extFn !== "function") { console.log("FAIL"); process.exit(1); }
const handlers: Record<string, any> = {};
const commands: Record<string, any> = {};
const mockPi: any = new Proxy({}, {
    get(_t: any, p: string) {
        if (p === "on") return (e: string, h: any) => { handlers[e] = h; };
        if (p === "registerCommand") return (n: string, o: any) => { commands[n] = o; };
        if (p === "then") return undefined;
        return (..._a: any[]) => undefined;
    }
});
try { const r = extFn(mockPi); if (r?.then) await r; } catch(e: any) { console.log(`FAIL: ${e.message}`); process.exit(1); }

// Activate by calling a start-like command
for (const [name, cmd] of Object.entries(commands)) {
    if (/start|activate|signal|begin/i.test(name)) {
        const handler = typeof cmd === "function" ? cmd : (cmd as any)?.handler;
        if (typeof handler === "function") {
            try { await handler("", { ui: { notify:()=>{}, select:async()=>null, confirm:async()=>true } }); } catch(_e) {}
        }
        break;
    }
}

const bas = handlers["before_agent_start"];
if (!bas) { console.log("FAIL: no before_agent_start"); process.exit(1); }
try {
    const result = await bas({ systemPrompt: "Base prompt.", message: null, messages: [] }, {});
    if (!result) { console.log("FAIL: returned nothing"); process.exit(1); }
    if (typeof result.systemPrompt === "string") {
        const sp = result.systemPrompt.toLowerCase();
        if (/signal|marker|\[\[/.test(sp) && /open|close|ui|done|complete|input|checkpoint/.test(sp)) {
            console.log("PASS: systemPrompt augmented with signal protocol");
            process.exit(0);
        }
        console.log("FAIL: systemPrompt modified but missing signal keywords");
        process.exit(1);
    }
    if (result.message && /signal|marker|\[\[/.test(JSON.stringify(result.message).toLowerCase())) {
        console.log("PASS: signal instructions via message");
        process.exit(0);
    }
    console.log("FAIL: no signal injection detected");
    process.exit(1);
} catch(e: any) { console.log(`FAIL: ${e.message}`); process.exit(1); }
HARNESS
    G6=$(cd /workspace/pi-mono && bun run /tmp/test-gate6.ts "$EXT_ABS" 2>&1)
    echo "$G6"
    if echo "$G6" | grep -q "^PASS"; then
        add_reward 0.15
        echo "PASS (0.15)"
    else
        echo "FAIL"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 7 (F2P): message_end detects embedded signals
# Weight: 0.15
# ============================================================
echo "=== Gate 7 (F2P): message_end detects signals ==="
if [ -n "$EXT_ABS" ]; then
    cat > /tmp/test-gate7.ts <<'HARNESS'
const extPath = process.argv[2];
const mod = await import(extPath.startsWith("/") ? extPath : `${process.cwd()}/${extPath}`);
const extFn = mod.default || mod[Object.keys(mod).find(k => typeof mod[k] === "function") || ""];
if (typeof extFn !== "function") { console.log("FAIL"); process.exit(1); }
const handlers: Record<string, any> = {};
const commands: Record<string, any> = {};
const logs: string[] = [];
const origLog = console.log;
console.log = (...args: any[]) => { logs.push(args.join(" ")); };
const mockPi: any = new Proxy({}, {
    get(_t: any, p: string) {
        if (p === "on") return (e: string, h: any) => { handlers[e] = h; };
        if (p === "registerCommand") return (n: string, o: any) => { commands[n] = o; };
        if (p === "then") return undefined;
        return (..._a: any[]) => undefined;
    }
});
try { const r = extFn(mockPi); if (r?.then) await r; } catch(e: any) { origLog(`FAIL: ${e.message}`); process.exit(1); }

// Activate
for (const [name, cmd] of Object.entries(commands)) {
    if (/start|activate|signal|begin/i.test(name)) {
        const handler = typeof cmd === "function" ? cmd : (cmd as any)?.handler;
        if (typeof handler === "function") {
            try { await handler("", { ui: { notify:()=>{}, select:async()=>null, confirm:async()=>true } }); } catch(_e) {}
        }
        break;
    }
}

const me = handlers["message_end"];
if (!me) { origLog("FAIL: no message_end handler"); process.exit(1); }

const signalText = "Here is content [[SIGNAL_OPEN_UI]] with text";
try {
    logs.length = 0;
    const result = await me({
        content: signalText,
        message: { role: "assistant", content: [{ type: "text", text: signalText }] },
    }, { ui: { notify:()=>{}, setWidget:()=>{} } });
    console.log = origLog;
    const logStr = logs.join(" ").toLowerCase();
    if (/signal|open|detect|received|found/.test(logStr) ||
        (result && JSON.stringify(result).toLowerCase().includes("signal"))) {
        origLog("PASS: signal detected and processed");
        process.exit(0);
    }
    origLog("FAIL: no signal detection evidence");
    process.exit(1);
} catch(e: any) {
    console.log = origLog;
    origLog(`FAIL: message_end threw: ${e.message}`);
    process.exit(1);
}
HARNESS
    G7=$(cd /workspace/pi-mono && bun run /tmp/test-gate7.ts "$EXT_ABS" 2>&1)
    echo "$G7"
    if echo "$G7" | grep -q "^PASS"; then
        add_reward 0.15
        echo "PASS (0.15)"
    else
        echo "FAIL"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 8 (F2P): TypeScript strict type-check passes
# Weight: 0.30
# Runs npx tsc --noEmit with a tsconfig that includes the
# agent's extension. Checks for NEW type errors (beyond the
# baseline errors in existing .pi/extensions/ files).
# A correct implementation should match the ExtensionAPI types.
# ============================================================
echo "=== Gate 8 (F2P): TypeScript strict type-check ==="
if [ -n "$EXT_ABS" ]; then
    # Get the relative path from pi-mono root
    EXT_REL=$(echo "$EXT_ABS" | sed "s|^/workspace/pi-mono/||")

    # Create a tsconfig that includes .pi/extensions/
    cat > /workspace/pi-mono/tsconfig-verify.json <<'TSCFG'
{
    "extends": "./tsconfig.json",
    "include": [".pi/extensions/**/*", "packages/*/src/**/*", "packages/*/test/**/*", "packages/coding-agent/examples/**/*"],
    "exclude": ["packages/web-ui/**/*", "**/dist/**"]
}
TSCFG

    # Count errors ONLY from the agent's new extension file
    TSC_OUT=$(npx tsc --noEmit --project tsconfig-verify.json 2>&1)
    NEW_ERRORS=$(echo "$TSC_OUT" | grep "^${EXT_REL}" | wc -l)
    rm -f /workspace/pi-mono/tsconfig-verify.json

    echo "Type errors in $EXT_REL: $NEW_ERRORS"
    if [ "$NEW_ERRORS" -gt 0 ]; then
        echo "$TSC_OUT" | grep "^${EXT_REL}" | head -5
        echo "FAIL: $NEW_ERRORS type errors in extension"
    else
        add_reward 0.30
        echo "PASS (0.30)"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Final score
# ============================================================
echo ""
echo "============================================"
echo "FINAL SCORE: $REWARD"
echo "============================================"
echo "$REWARD" > /logs/verifier/reward.txt
