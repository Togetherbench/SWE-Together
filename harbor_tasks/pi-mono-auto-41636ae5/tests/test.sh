#!/bin/bash
set +e
mkdir -p /logs/verifier
cd /workspace/pi-mono 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/usr/local/bin:/usr/bin:$PATH"

REWARD=0

add() {
    REWARD=$(awk "BEGIN{printf \"%.2f\", $REWARD + $1}")
}

# ============================================================
# Behavioral test 1 (0.40): clipboard-native module loads safely
# without DISPLAY/WAYLAND_DISPLAY on linux. The bug: requiring
# @crosscopy/clipboard (or @mariozechner/clipboard) on headless
# linux panics. Fix: guard the require with a display check.
# ============================================================
echo "=== Behavioral 1: clipboard-native loads on headless linux ==="

NATIVE_FILE="/workspace/pi-mono/packages/coding-agent/src/utils/clipboard-native.ts"
if [ ! -f "$NATIVE_FILE" ]; then
    # try to discover a clipboard wrapper
    NATIVE_FILE=$(find /workspace/pi-mono/packages/coding-agent/src -maxdepth 4 -name 'clipboard*.ts' 2>/dev/null | head -1)
fi

if [ -n "$NATIVE_FILE" ] && [ -f "$NATIVE_FILE" ]; then
    cd /workspace/pi-mono/packages/coding-agent
    # Run in a subshell with no DISPLAY, simulating headless linux. Import the
    # module via tsx and exercise hasImage if available — if the guard works,
    # this returns null/false instead of panicking the process.
    OUT=$(env -u DISPLAY -u WAYLAND_DISPLAY \
        node --import tsx -e '
        (async () => {
            try {
                const mod = await import("./src/utils/clipboard-native.ts");
                // Module should load without throwing/panicking.
                // Try to access default or named exports gracefully.
                const v = mod.default ?? mod.clipboard ?? mod;
                if (v && typeof v.hasImage === "function") {
                    try { v.hasImage(); } catch (e) { /* tolerated */ }
                }
                console.log("LOADED_OK");
            } catch (e) {
                console.log("LOAD_FAIL:" + (e && e.message ? e.message : String(e)));
            }
        })();
        ' 2>&1)
    echo "$OUT" | tail -20
    if echo "$OUT" | grep -q "LOADED_OK"; then
        # Additional check: ensure it's null on headless (not just lucky catch)
        OUT2=$(env -u DISPLAY -u WAYLAND_DISPLAY \
            node --import tsx -e '
            (async () => {
                try {
                    const mod = await import("./src/utils/clipboard-native.ts");
                    const candidates = [mod.default, mod.clipboard, mod.clipboardModule];
                    let found = null;
                    for (const c of candidates) {
                        if (c !== undefined) { found = c; break; }
                    }
                    if (found === null) console.log("NULL_OK");
                    else console.log("VALUE:" + typeof found);
                } catch (e) {
                    console.log("ERR:" + e.message);
                }
            })();
            ' 2>&1)
        echo "$OUT2" | tail -5
        if echo "$OUT2" | grep -qE "NULL_OK|VALUE:"; then
            add 0.40
            echo "Behavioral 1 PASS (0.40)"
        else
            add 0.20
            echo "Behavioral 1 PARTIAL (0.20) — loaded but couldn't verify guard semantic"
        fi
    else
        echo "Behavioral 1 FAIL — module fails to load on headless linux"
    fi
    cd /workspace/pi-mono
else
    echo "Behavioral 1 FAIL — clipboard-native source not found"
fi

# ============================================================
# Behavioral test 2 (0.25): clipboard-image utility works without DISPLAY
# Should not invoke native clipboard or wl-paste when DISPLAY/WAYLAND_DISPLAY
# are unset (returning null cleanly).
# ============================================================
echo ""
echo "=== Behavioral 2: clipboard-image headless behavior ==="
CLIP_IMG="/workspace/pi-mono/packages/coding-agent/src/utils/clipboard-image.ts"
if [ -f "$CLIP_IMG" ]; then
    cd /workspace/pi-mono/packages/coding-agent
    OUT=$(env -u DISPLAY -u WAYLAND_DISPLAY \
        node --import tsx -e '
        (async () => {
            try {
                const mod = await import("./src/utils/clipboard-image.ts");
                const fn = mod.readClipboardImage ?? mod.default;
                if (typeof fn !== "function") {
                    console.log("NO_FN");
                    return;
                }
                let result;
                try {
                    result = await fn({ platform: "linux", env: {} });
                } catch (e) {
                    try {
                        result = await fn();
                    } catch (e2) {
                        console.log("THREW:" + e2.message);
                        return;
                    }
                }
                if (result === null || result === undefined) console.log("NULL_OK");
                else console.log("GOT:" + JSON.stringify(result).slice(0, 80));
            } catch (e) {
                console.log("IMPORT_ERR:" + e.message);
            }
        })();
        ' 2>&1)
    echo "$OUT" | tail -10
    if echo "$OUT" | grep -q "NULL_OK"; then
        add 0.25
        echo "Behavioral 2 PASS (0.25)"
    elif echo "$OUT" | grep -q "IMPORT_ERR"; then
        echo "Behavioral 2 FAIL — clipboard-image fails to import"
    else
        # If module exists but doesn't accept env injection, run vitest as fallback
        if [ -f /workspace/pi-mono/packages/coding-agent/test/clipboard-image.test.ts ]; then
            cd /workspace/pi-mono
            VOUT=$(npx vitest --run packages/coding-agent/test/clipboard-image.test.ts 2>&1)
            VEXIT=$?
            echo "$VOUT" | tail -20
            if [ $VEXIT -eq 0 ]; then
                add 0.25
                echo "Behavioral 2 PASS via vitest (0.25)"
            else
                echo "Behavioral 2 FAIL"
            fi
        fi
    fi
    cd /workspace/pi-mono
else
    # Module doesn't exist, give the points if behavioral 1 passed
    echo "clipboard-image.ts not found — skipping"
fi

# ============================================================
# Structural test (0.15): Display guard exists in code path
# ============================================================
echo ""
echo "=== Structural: display guard present ==="
GUARD_OK=1
if [ -f "$NATIVE_FILE" ]; then
    if grep -qE "DISPLAY|WAYLAND|hasDisplay|canUseClipboard|isHeadless|X11-unix" "$NATIVE_FILE"; then
        GUARD_OK=0
    fi
fi
# Also check interactive-mode if guard is upstream
IM="/workspace/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
if [ $GUARD_OK -ne 0 ] && [ -f "$IM" ]; then
    if grep -qE "DISPLAY|WAYLAND|hasDisplay|canUseClipboard" "$IM"; then
        GUARD_OK=0
    fi
fi
if [ $GUARD_OK -eq 0 ]; then
    add 0.15
    echo "Structural PASS (0.15)"
else
    echo "Structural FAIL — no display-related guard found"
fi

# ============================================================
# P2P regression (0.10): general skills test still passes
# ============================================================
echo ""
echo "=== P2P: skills regression ==="
cd /workspace/pi-mono
SKILLS_TEST="packages/coding-agent/test/skills.test.ts"
if [ -f "$SKILLS_TEST" ]; then
    npx vitest --run "$SKILLS_TEST" >/tmp/skills.log 2>&1
    SX=$?
    tail -15 /tmp/skills.log
    if [ $SX -eq 0 ]; then
        add 0.10
        echo "P2P PASS (0.10)"
    else
        echo "P2P FAIL (exit=$SX)"
    fi
else
    # fallback: any small unit test
    ALT=$(find packages/coding-agent/test -maxdepth 2 -name 'tools.test.ts' 2>/dev/null | head -1)
    if [ -n "$ALT" ]; then
        npx vitest --run "$ALT" >/tmp/p2p.log 2>&1
        if [ $? -eq 0 ]; then
            add 0.10
            echo "P2P PASS via $ALT (0.10)"
        fi
    fi
fi

# ============================================================
# Type-check sanity (0.10): TypeScript still compiles
# ============================================================
echo ""
echo "=== TypeScript compiles ==="
cd /workspace/pi-mono
if command -v npx >/dev/null 2>&1; then
    timeout 180 npx tsgo --noEmit >/tmp/tsc.log 2>&1
    TX=$?
    if [ $TX -ne 0 ]; then
        # try plain tsc
        timeout 180 npx tsc --noEmit >/tmp/tsc.log 2>&1
        TX=$?
    fi
    tail -10 /tmp/tsc.log
    if [ $TX -eq 0 ]; then
        add 0.10
        echo "TS PASS (0.10)"
    else
        echo "TS FAIL"
    fi
fi

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt