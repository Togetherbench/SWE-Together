#!/bin/bash
set +e
mkdir -p /logs/verifier
REWARD=0

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }

add() {
    REWARD=$(awk "BEGIN{printf \"%.2f\", $REWARD + $1}")
}

finish() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

CA_DIR="/workspace/pi-mono/packages/coding-agent"
AI_DIR="/workspace/pi-mono/packages/ai"
NATIVE_FILE="$CA_DIR/src/utils/clipboard-native.ts"
CONCURRENT_TEST="$CA_DIR/test/agent-session-concurrent.test.ts"
PRINT_TEST="$CA_DIR/test/print-mode.test.ts"
COMPACTION_TEST="$CA_DIR/test/interactive-mode-compaction.test.ts"
HANDOFF_TEST="$AI_DIR/test/cross-provider-handoff.test.ts"
OPUS_SMOKE_TEST="$AI_DIR/test/anthropic-opus-4-7-smoke.test.ts"

if ! command -v node >/dev/null 2>&1; then
    finish
fi

# ============================================================
# GATE 1 (0.18): clipboard-native — load returns null on headless linux
# (no DISPLAY, no WAYLAND_DISPLAY). The clipboard export must be null.
# Must NOT crash. The buggy code panics; a guard fix returns null.
# ============================================================
echo "=== GATE 1: clipboard-native exports null on headless linux ==="
G1_PASS=0
if [ -f "$NATIVE_FILE" ]; then
    cd "$CA_DIR"
    OUT=$(env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION \
        timeout 45 node --import tsx -e '
        (async () => {
            try {
                const mod = await import("./src/utils/clipboard-native.ts");
                let sawNull = false, sawNonNull = false;
                for (const k of Object.keys(mod)) {
                    const v = mod[k];
                    if (v === null) sawNull = true;
                    else if (v && typeof v === "object" && typeof v.hasImage === "function") sawNonNull = true;
                }
                if (mod.default === null) sawNull = true;
                if (sawNull && !sawNonNull) console.log("HEADLESS_NULL_OK");
                else if (sawNonNull) console.log("LOADED_NATIVE_BAD");
                else console.log("UNKNOWN");
            } catch (e) {
                console.log("LOAD_FAIL:" + (e && e.message ? e.message : String(e)));
            }
        })();
        ' 2>&1)
    echo "$OUT" | tail -5
    if echo "$OUT" | grep -q "HEADLESS_NULL_OK"; then
        add 0.18
        G1_PASS=1
        echo "GATE 1 PASS (0.18)"
    else
        echo "GATE 1 FAIL"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# GATE 2 (0.18): clipboard-native — DISPLAY=:0 set BUT no X11 socket present.
# A robust fix verifies the unix socket exists; an env-only fix WILL crash here.
# This discriminates "complete behavioral fix" (GLM4.7, MiniMax) from
# "env-only guard" (Kimi, etc).
# ============================================================
echo ""
echo "=== GATE 2: clipboard-native handles bogus DISPLAY (socket-aware) ==="
if [ -f "$NATIVE_FILE" ]; then
    cd "$CA_DIR"
    # Pick a display number with no X socket
    BOGUS_DISP=":97"
    if [ -e "/tmp/.X11-unix/X97" ]; then BOGUS_DISP=":98"; fi
    if [ -e "/tmp/.X11-unix/X98" ]; then BOGUS_DISP=":99"; fi
    env -u WAYLAND_DISPLAY -u TERMUX_VERSION DISPLAY="$BOGUS_DISP" \
        timeout 45 node --import tsx -e '
        import("./src/utils/clipboard-native.ts").then((mod) => {
            let sawNull = false, sawNonNull = false;
            for (const k of Object.keys(mod)) {
                const v = mod[k];
                if (v === null) sawNull = true;
                else if (v && typeof v === "object" && typeof v.hasImage === "function") sawNonNull = true;
            }
            if (mod.default === null) sawNull = true;
            if (sawNonNull) { console.log("LOADED_NATIVE"); process.exit(0); }
            if (sawNull) { console.log("BOGUS_DISP_NULL_OK"); process.exit(0); }
            console.log("UNKNOWN"); process.exit(0);
        }).catch((e) => {
            console.log("CRASH:" + (e && e.message ? e.message : String(e)));
            process.exit(2);
        });
        ' >/tmp/g2.log 2>&1
    EX=$?
    tail -5 /tmp/g2.log
    if [ $EX -eq 0 ] && grep -q "BOGUS_DISP_NULL_OK" /tmp/g2.log; then
        add 0.18
        echo "GATE 2 PASS (0.18) — socket-aware guard"
    else
        echo "GATE 2 FAIL (env-only or no fix)"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# GATE 3 (0.16): child-process import does not crash on headless linux
# (separate process, exit code 0). Catches lazy/throw-deferred fixes too.
# ============================================================
echo ""
echo "=== GATE 3: child-process import exit=0 on headless ==="
if [ -f "$NATIVE_FILE" ]; then
    cd "$CA_DIR"
    env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION \
        timeout 45 node --import tsx -e '
        import("./src/utils/clipboard-native.ts").then(() => {
            process.stdout.write("OK_IMPORT\n");
            process.exit(0);
        }).catch((e) => {
            process.stdout.write("FAIL_IMPORT:" + (e && e.message ? e.message : String(e)) + "\n");
            process.exit(2);
        });
        ' >/tmp/g3.log 2>&1
    EX=$?
    tail -3 /tmp/g3.log
    if [ $EX -eq 0 ] && grep -q "OK_IMPORT" /tmp/g3.log; then
        add 0.16
        echo "GATE 3 PASS (0.16)"
    else
        echo "GATE 3 FAIL (exit=$EX)"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# GATE 4 (0.16): agent-session-concurrent.test.ts — runs vitest and
# requires it to pass. The fix is to add `invalidate` to extensionRunner mocks.
# Buggy code OR partial mock fixes cause type/runtime errors.
# ============================================================
echo ""
echo "=== GATE 4: agent-session-concurrent vitest run ==="
G4_PASS=0
if [ -f "$CONCURRENT_TEST" ]; then
    cd "$CA_DIR"
    timeout 180 npx vitest run test/agent-session-concurrent.test.ts \
        --reporter=verbose --no-coverage >/tmp/g4.log 2>&1
    EX=$?
    tail -25 /tmp/g4.log
    # require explicit pass markers; failed tests must be 0
    PASSED=$(grep -Eo "Tests +[0-9]+ passed" /tmp/g4.log | head -1 | grep -Eo "[0-9]+" | head -1)
    FAILED=$(grep -Eo "[0-9]+ failed" /tmp/g4.log | head -1 | grep -Eo "[0-9]+" | head -1)
    if [ $EX -eq 0 ] && [ -n "$PASSED" ] && [ "${PASSED:-0}" -ge 2 ] && [ -z "$FAILED" -o "${FAILED:-0}" -eq 0 ]; then
        add 0.16
        G4_PASS=1
        echo "GATE 4 PASS (0.16) — $PASSED tests passed"
    else
        echo "GATE 4 FAIL (exit=$EX passed=$PASSED failed=$FAILED)"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# GATE 5 (0.12): print-mode.test.ts requires `setRebindSession` on the
# FakeRuntimeHost mock. A complete fix touches print-mode.test.ts AND
# rpc-prompt-response-semantics.test.ts. Run vitest on print-mode.
# ============================================================
echo ""
echo "=== GATE 5: print-mode vitest run ==="
G5_PASS=0
if [ -f "$PRINT_TEST" ]; then
    cd "$CA_DIR"
    timeout 180 npx vitest run test/print-mode.test.ts \
        --reporter=verbose --no-coverage >/tmp/g5.log 2>&1
    EX=$?
    tail -20 /tmp/g5.log
    PASSED=$(grep -Eo "Tests +[0-9]+ passed" /tmp/g5.log | head -1 | grep -Eo "[0-9]+" | head -1)
    FAILED=$(grep -Eo "[0-9]+ failed" /tmp/g5.log | head -1 | grep -Eo "[0-9]+" | head -1)
    if [ $EX -eq 0 ] && [ -n "$PASSED" ] && [ "${PASSED:-0}" -ge 1 ] && [ -z "$FAILED" -o "${FAILED:-0}" -eq 0 ]; then
        add 0.12
        G5_PASS=1
        echo "GATE 5 PASS (0.12) — $PASSED tests passed"
    else
        echo "GATE 5 FAIL (exit=$EX passed=$PASSED failed=$FAILED)"
    fi
    cd /workspace/pi-mono
fi

# ============================================================
# GATE 6 (0.10): completeness — print-mode.test.ts must contain
# `setRebindSession` (mock added) AND interactive-mode-compaction.test.ts
# must contain `setProgress` (terminal mock added). Each contributes half.
# This catches patches that fix some files but skip others.
# ============================================================
echo ""
echo "=== GATE 6: completeness markers in test mocks ==="
G6_SCORE=0
if [ -f "$PRINT_TEST" ] && grep -q "setRebindSession" "$PRINT_TEST"; then
    G6_SCORE=$(awk "BEGIN{printf \"%.2f\", $G6_SCORE + 0.05}")
    echo "  setRebindSession present in print-mode.test.ts (+0.05)"
else
    echo "  setRebindSession MISSING in print-mode.test.ts"
fi
if [ -f "$COMPACTION_TEST" ] && grep -q "setProgress" "$COMPACTION_TEST"; then
    G6_SCORE=$(awk "BEGIN{printf \"%.2f\", $G6_SCORE + 0.05}")
    echo "  setProgress present in interactive-mode-compaction.test.ts (+0.05)"
else
    echo "  setProgress MISSING in interactive-mode-compaction.test.ts"
fi
add "$G6_SCORE"
echo "GATE 6 score: $G6_SCORE / 0.10"

# ============================================================
# GATE 7 (0.10): cross-provider-handoff.test.ts must use a count-based
# skip predicate (not just !hasAnyApiKey) — the proper fix changes the
# .skipIf to check Object.keys(contexts).length < 2 OR similar.
# Run vitest; in CI no API keys are present, so the test must SKIP cleanly,
# not error. Verify zero failures.
# ============================================================
echo ""
echo "=== GATE 7: cross-provider-handoff skips cleanly ==="
if [ -f "$HANDOFF_TEST" ]; then
    cd "$AI_DIR"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u GEMINI_API_KEY -u XAI_API_KEY -u GROQ_API_KEY -u CEREBRAS_API_KEY \
        timeout 120 npx vitest run test/cross-provider-handoff.test.ts \
        --reporter=verbose --no-coverage >/tmp/g7.log 2>&1
    EX=$?
    tail -20 /tmp/g7.log
    FAILED=$(grep -Eo "[0-9]+ failed" /tmp/g7.log | head -1 | grep -Eo "[0-9]+" | head -1)
    # Either passes-or-skips (no failures), and exit ok
    if [ $EX -eq 0 ] && [ -z "$FAILED" -o "${FAILED:-0}" -eq 0 ]; then
        add 0.10
        echo "GATE 7 PASS (0.10)"
    else
        echo "GATE 7 FAIL (exit=$EX failed=$FAILED)"
    fi
    cd /workspace/pi-mono
fi

finish