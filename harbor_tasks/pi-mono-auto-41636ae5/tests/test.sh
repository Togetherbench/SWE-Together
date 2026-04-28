#!/bin/bash
set +e
mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr -d '\n' | sed 's/"/\\"/g' | cut -c1-200)
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:$PATH"

REPO=/workspace/pi-mono
CA_DIR="$REPO/packages/coding-agent"
NATIVE_FILE="$CA_DIR/src/utils/clipboard-native.ts"
PRINT_TEST="$CA_DIR/test/print-mode.test.ts"

write_reward() {
    local r="$1"
    printf "%.4f\n" "$r" > /logs/verifier/reward.txt
}

# If the repo is missing or node isn't available, emit all F2P fails and exit 0
if [ ! -d "$REPO" ] || ! command -v node >/dev/null 2>&1; then
    emit t3_f2p_bogus_display_no_crash false "no repo or node"
    emit t3_f2p_headless_no_native_loaded false "no repo or node"
    emit t5_f2p_minimal_change_clipboard_native false "no repo or node"
    emit t5_f2p_bogus_display_safe false "no repo or node"
    emit t6_f2p_print_mode_passes false "no repo or node"
    emit t6_f2p_termux_branch_preserved false "no repo or node"
    emit p2p_no_instruction_modified true "no repo"
    write_reward 0.0
    exit 0
fi

cd "$REPO"

# --------------------------------------------------------------------
# P2P: instruction.md unchanged
# --------------------------------------------------------------------
INSTR_OK=true
if [ -f /baseline/instruction.md ]; then
    if ! diff -q /baseline/instruction.md "$REPO/instruction.md" >/dev/null 2>&1; then
        INSTR_OK=false
    fi
fi
if $INSTR_OK; then
    emit p2p_no_instruction_modified true ""
else
    emit p2p_no_instruction_modified false "instruction.md changed"
fi

# --------------------------------------------------------------------
# Helper: run an import probe with given env. Outputs a single-line tag.
# --------------------------------------------------------------------
probe_native() {
    # $1 = env-prefix string (eval'd), e.g. "env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION"
    local envcmd="$1"
    cd "$CA_DIR"
    eval "$envcmd timeout 60 node --import tsx -e '
        (async () => {
            try {
                const mod = await import(\"./src/utils/clipboard-native.ts\");
                let sawUsable = false;
                let sawNull = false;
                const inspect = (v) => {
                    if (v === null || v === undefined) { sawNull = true; return; }
                    if (typeof v === \"object\" && (typeof v.hasImage === \"function\" || typeof v.readImage === \"function\" || typeof v.read === \"function\")) {
                        sawUsable = true;
                    }
                };
                inspect(mod.default);
                for (const k of Object.keys(mod)) inspect(mod[k]);
                if (sawUsable) console.log(\"USABLE_NATIVE\");
                else console.log(\"NO_NATIVE\");
            } catch (e) {
                console.log(\"IMPORT_CRASH:\" + (e && e.message ? e.message.replace(/\\n/g, \" \") : String(e)));
                process.exit(2);
            }
        })();
    ' 2>&1"
    local rc=$?
    cd "$REPO"
    return $rc
}

# --------------------------------------------------------------------
# Gate t3_f2p_bogus_display_no_crash:
# Set DISPLAY=:99 (no socket). Buggy code attempts to load the native
# binding which connects to X and crashes; fixed code checks socket / env
# more carefully and returns null.
# --------------------------------------------------------------------
BOGUS_DISP=":97"
[ -e "/tmp/.X11-unix/X97" ] && BOGUS_DISP=":98"
[ -e "/tmp/.X11-unix/X98" ] && BOGUS_DISP=":99"
[ -e "/tmp/.X11-unix/X99" ] && BOGUS_DISP=":91"

OUT_BOGUS=$(probe_native "env -u WAYLAND_DISPLAY -u TERMUX_VERSION DISPLAY=$BOGUS_DISP")
RC_BOGUS=$?
echo "[bogus DISPLAY=$BOGUS_DISP] rc=$RC_BOGUS"
echo "$OUT_BOGUS" | tail -3

if [ $RC_BOGUS -eq 0 ] && echo "$OUT_BOGUS" | grep -q "NO_NATIVE"; then
    emit t3_f2p_bogus_display_no_crash true ""
else
    emit t3_f2p_bogus_display_no_crash false "rc=$RC_BOGUS out=$(echo "$OUT_BOGUS" | tail -1)"
fi

# t5_f2p_bogus_display_safe — same probe, distinct gate (turn 5 deliverable).
if [ $RC_BOGUS -eq 0 ] && echo "$OUT_BOGUS" | grep -q "NO_NATIVE"; then
    emit t5_f2p_bogus_display_safe true ""
else
    emit t5_f2p_bogus_display_safe false "rc=$RC_BOGUS out=$(echo "$OUT_BOGUS" | tail -1)"
fi

# --------------------------------------------------------------------
# Gate t3_f2p_headless_no_native_loaded:
# No DISPLAY, no WAYLAND_DISPLAY, no TERMUX. Must yield NO_NATIVE.
# To avoid being decorative (passing on nop because base may already
# return null), we ALSO require that the file has been modified vs
# baseline OR that the bogus-display path passes — i.e., a real fix
# was applied. We enforce this by combining with the source-change check.
# --------------------------------------------------------------------
OUT_HEADLESS=$(probe_native "env -u DISPLAY -u WAYLAND_DISPLAY -u TERMUX_VERSION")
RC_HEADLESS=$?
echo "[headless] rc=$RC_HEADLESS"
echo "$OUT_HEADLESS" | tail -3

# --------------------------------------------------------------------
# Source change detection vs baseline hash for clipboard-native.ts.
# We compute a baseline hash once (preferring /baseline if available;
# fallback: git show HEAD).
# --------------------------------------------------------------------
NATIVE_CHANGED=false
NATIVE_BASELINE_HASH=""
NATIVE_CURRENT_HASH=""

if [ -f "$NATIVE_FILE" ]; then
    NATIVE_CURRENT_HASH=$(sha256sum "$NATIVE_FILE" 2>/dev/null | awk '{print $1}')
fi

if [ -f /baseline/clipboard-native.ts ]; then
    NATIVE_BASELINE_HASH=$(sha256sum /baseline/clipboard-native.ts 2>/dev/null | awk '{print $1}')
fi

if [ -z "$NATIVE_BASELINE_HASH" ]; then
    # Fallback: pull from git HEAD
    BL=$(cd "$REPO" && git show HEAD:packages/coding-agent/src/utils/clipboard-native.ts 2>/dev/null)
    if [ -n "$BL" ]; then
        NATIVE_BASELINE_HASH=$(printf '%s' "$BL" | sha256sum | awk '{print $1}')
    fi
fi

if [ -n "$NATIVE_BASELINE_HASH" ] && [ -n "$NATIVE_CURRENT_HASH" ] && [ "$NATIVE_BASELINE_HASH" != "$NATIVE_CURRENT_HASH" ]; then
    NATIVE_CHANGED=true
fi

echo "native_changed=$NATIVE_CHANGED baseline=$NATIVE_BASELINE_HASH current=$NATIVE_CURRENT_HASH"

# Headless gate: requires NO_NATIVE AND a real change to the file.
# (If the buggy baseline already returns NO_NATIVE harmlessly under headless,
# the no-op patch would otherwise leak credit; require source change too.)
if [ $RC_HEADLESS -eq 0 ] && echo "$OUT_HEADLESS" | grep -q "NO_NATIVE" && $NATIVE_CHANGED; then
    emit t3_f2p_headless_no_native_loaded true ""
else
    emit t3_f2p_headless_no_native_loaded false "rc=$RC_HEADLESS changed=$NATIVE_CHANGED"
fi

# Minimal-change gate: file was edited.
if $NATIVE_CHANGED; then
    emit t5_f2p_minimal_change_clipboard_native true ""
else
    emit t5_f2p_minimal_change_clipboard_native false "clipboard-native.ts unchanged vs baseline"
fi

# --------------------------------------------------------------------
# Gate t6_f2p_termux_branch_preserved:
# Set TERMUX_VERSION; the file must still import without crashing.
# Combined with the source-change marker so the no-op cannot leak
# credit (otherwise the buggy baseline likely already imports fine
# under TERMUX since it skips the X path).
# --------------------------------------------------------------------
OUT_TERMUX=$(probe_native "env -u DISPLAY -u WAYLAND_DISPLAY TERMUX_VERSION=0.118")
RC_TERMUX=$?
echo "[termux] rc=$RC_TERMUX"
echo "$OUT_TERMUX" | tail -3

if [ $RC_TERMUX -eq 0 ] && ! echo "$OUT_TERMUX" | grep -q "IMPORT_CRASH" && $NATIVE_CHANGED; then
    emit t6_f2p_termux_branch_preserved true ""
else
    emit t6_f2p_termux_branch_preserved false "rc=$RC_TERMUX changed=$NATIVE_CHANGED"
fi

# --------------------------------------------------------------------
# Gate t6_f2p_print_mode_passes:
# Run vitest on print-mode.test.ts and require it to pass cleanly.
# --------------------------------------------------------------------
PRINT_PASS=false
if [ -f "$PRINT_TEST" ]; then
    cd "$CA_DIR"
    timeout 240 npx vitest run test/print-mode.test.ts \
        --reporter=verbose --no-coverage >/tmp/g_print.log 2>&1
    EX=$?
    tail -25 /tmp/g_print.log
    PASSED=$(grep -Eo "Tests +[0-9]+ passed" /tmp/g_print.log | head -1 | grep -Eo "[0-9]+" | head -1)
    FAILED=$(grep -Eo "[0-9]+ failed" /tmp/g_print.log | head -1 | grep -Eo "[0-9]+" | head -1)
    if [ "$EX" = "0" ] && [ -n "$PASSED" ] && [ "${PASSED:-0}" -ge 1 ] && { [ -z "$FAILED" ] || [ "${FAILED:-0}" -eq 0 ]; }; then
        PRINT_PASS=true
    fi
    cd "$REPO"
fi

if $PRINT_PASS; then
    emit t6_f2p_print_mode_passes true ""
else
    emit t6_f2p_print_mode_passes false "vitest print-mode failed"
fi

# --------------------------------------------------------------------
# Compute reward.
# --------------------------------------------------------------------
# Check P2P_GATING: if any failed, reward = 0.
P2P_FAIL=$(grep -E '"id":"p2p_' "$GATES_FILE" | grep -c '"passed":false')

if [ "$P2P_FAIL" -gt 0 ]; then
    write_reward 0.0
    exit 0
fi

# Sum F2P weights for passed gates.
declare -A WEIGHTS
WEIGHTS[t3_f2p_bogus_display_no_crash]=0.20
WEIGHTS[t3_f2p_headless_no_native_loaded]=0.15
WEIGHTS[t5_f2p_minimal_change_clipboard_native]=0.15
WEIGHTS[t5_f2p_bogus_display_safe]=0.20
WEIGHTS[t6_f2p_print_mode_passes]=0.15
WEIGHTS[t6_f2p_termux_branch_preserved]=0.15

REWARD=0
for gid in "${!WEIGHTS[@]}"; do
    if grep -q "\"id\":\"$gid\",\"passed\":true" "$GATES_FILE"; then
        REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + ${WEIGHTS[$gid]}}")
    fi
done

write_reward "$REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_771580d1 'npm_typecheck_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_816994b6 'vitest_session_manager_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'
run_v043_gate p2p_upstream_e395cbc7 'npm_typecheck_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_522628b0 'vitest_session_manager_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t3_f2p_bogus_display_no_crash": 0.2, "t3_f2p_headless_no_native_loaded": 0.15, "t5_f2p_bogus_display_safe": 0.2, "t5_f2p_minimal_change_clipboard_native": 0.15, "t6_f2p_print_mode_passes": 0.15, "t6_f2p_termux_branch_preserved": 0.15}
P2P_GATING = ["p2p_no_instruction_modified"]
P2P_REGRESSION = ["p2p_upstream_771580d1", "p2p_upstream_816994b6", "p2p_upstream_e395cbc7", "p2p_upstream_522628b0"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0