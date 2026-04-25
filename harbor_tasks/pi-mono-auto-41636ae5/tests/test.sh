#!/bin/bash
set +e
mkdir -p /logs/verifier
REWARD=0

cd /workspace/pi-mono 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:$PATH"

add() {
    REWARD=$(awk "BEGIN{printf \"%.2f\", $REWARD + $1}")
}

finish() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

NATIVE_FILE="/workspace/pi-mono/packages/coding-agent/src/utils/clipboard-native.ts"

# ============================================================
# F2P 1 (0.50): clipboard-native module loads safely on headless linux
# (no DISPLAY, no WAYLAND_DISPLAY) AND the exported clipboard is null.
# On the buggy base, the require of @mariozechner/clipboard panics
# the process at module load on headless linux, so this fails.
# On the fix, a guard short-circuits the require => clipboard = null.
# ============================================================
echo "=== F2P 1: clipboard-native loads as null on headless linux ==="

if [ ! -f "$NATIVE_FILE" ]; then
    echo "F2P 1 FAIL — clipboard-native.ts missing"
else
    cd /workspace/pi-mono/packages/coding-agent
    OUT=$(env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION \
        timeout 45 node --import tsx -e '
        (async () => {
            try {
                const mod = await import("./src/utils/clipboard-native.ts");
                // Inspect every export, find the clipboard module reference.
                const candidates = [];
                for (const k of Object.keys(mod)) candidates.push([k, mod[k]]);
                if (mod.default !== undefined) candidates.push(["default", mod.default]);

                // We want at least one exported value that is null on headless.
                let sawNull = false;
                let sawNonNullObj = false;
                for (const [, v] of candidates) {
                    if (v === null) sawNull = true;
                    else if (v && typeof v === "object" && typeof v.hasImage === "function") sawNonNullObj = true;
                }
                if (sawNull && !sawNonNullObj) console.log("HEADLESS_NULL_OK");
                else if (sawNonNullObj) console.log("LOADED_NATIVE_BAD");
                else console.log("LOADED_UNKNOWN");
            } catch (e) {
                console.log("LOAD_FAIL:" + (e && e.message ? e.message : String(e)));
            }
        })();
        ' 2>&1)
    echo "$OUT" | tail -10
    if echo "$OUT" | grep -q "HEADLESS_NULL_OK"; then
        add 0.50
        echo "F2P 1 PASS (0.50)"
    else
        echo "F2P 1 FAIL"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# F2P 2 (0.30): With DISPLAY=:0 set but no X11 socket present, OR with
# WAYLAND_DISPLAY set but no socket, the module should still not load
# the native clipboard. This catches purely env-based guards that don't
# verify the socket exists. We accept either the socket-aware fix or
# the simpler env-only fix by checking the no-DISPLAY case strictly,
# and here we only require: with env unset, behavior remains null.
# Specifically test: setting only TERMUX_VERSION makes clipboard null.
# On base: TERMUX guard already exists, so this is also null on base.
# So instead, we pivot: verify clipboard-image returns null on headless.
# ============================================================
echo ""
echo "=== F2P 2: clipboard-image returns null on headless linux ==="

CLIP_IMG="/workspace/pi-mono/packages/coding-agent/src/utils/clipboard-image.ts"
if [ -f "$CLIP_IMG" ]; then
    cd /workspace/pi-mono/packages/coding-agent
    OUT=$(env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION \
        timeout 45 node --import tsx -e '
        (async () => {
            try {
                const mod = await import("./src/utils/clipboard-image.ts");
                const fn = mod.readClipboardImage ?? mod.default;
                if (typeof fn !== "function") { console.log("NO_FN"); return; }
                let r;
                try { r = await fn({ platform: "linux", env: {} }); }
                catch { try { r = await fn(); } catch (e) { console.log("THREW:" + e.message); return; } }
                if (r === null || r === undefined) console.log("NULL_OK");
                else console.log("GOT:" + JSON.stringify(r).slice(0,80));
            } catch (e) {
                console.log("IMPORT_ERR:" + (e && e.message ? e.message : String(e)));
            }
        })();
        ' 2>&1)
    echo "$OUT" | tail -10
    if echo "$OUT" | grep -q "NULL_OK"; then
        add 0.30
        echo "F2P 2 PASS (0.30)"
    else
        echo "F2P 2 FAIL"
    fi
    cd /workspace/pi-mono
else
    echo "F2P 2 SKIP — clipboard-image.ts not found"
fi

# ============================================================
# F2P 3 (0.20): Behavioral — the clipboard-native module must not
# panic when imported in a child process simulating headless linux.
# We launch a fresh node process, import, and check exit code 0.
# On the buggy base, the native addon load throws/panics at module
# evaluation when there's no display, yielding a non-zero exit.
# ============================================================
echo ""
echo "=== F2P 3: child process import does not crash on headless ==="

if [ -f "$NATIVE_FILE" ]; then
    cd /workspace/pi-mono/packages/coding-agent
    env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION \
        timeout 45 node --import tsx -e '
        import("./src/utils/clipboard-native.ts").then(() => {
            process.stdout.write("OK_IMPORT\n");
            process.exit(0);
        }).catch((e) => {
            process.stdout.write("FAIL_IMPORT:" + (e && e.message ? e.message : String(e)) + "\n");
            process.exit(2);
        });
        ' >/tmp/native_import.log 2>&1
    EX=$?
    tail -5 /tmp/native_import.log
    if [ $EX -eq 0 ] && grep -q "OK_IMPORT" /tmp/native_import.log; then
        add 0.20
        echo "F2P 3 PASS (0.20)"
    else
        echo "F2P 3 FAIL (exit=$EX)"
    fi
    cd /workspace/pi-mono
fi

finish