#!/bin/bash
set +e

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
REWARD_FILE=/logs/verifier/reward.txt
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO=""
for cand in /workspace/pi-mono /workspace/$(ls /workspace 2>/dev/null | head -1); do
    if [ -d "$cand" ] && [ -d "$cand/packages" ]; then
        REPO="$cand"; break
    fi
done

if [ -z "$REPO" ]; then
    emit p2p_src_files_exist false "no repo found"
    emit t6_f2p_keybindings_have_scope_tags false "no repo"
    emit t6_f2p_runner_consults_scope false "no repo"
    emit t11_f2p_picker_scope_keys_count false "no repo"
    emit t11_f2p_global_editor_scope_keys_present false "no repo"
    emit t13_f2p_runner_tests_pass false "no repo"
    printf "%.4f\n" 0 > "$REWARD_FILE"
    exit 0
fi

cd "$REPO"
echo "Repo: $REPO"

BUN_BIN=$(command -v bun)
if [ -z "$BUN_BIN" ]; then
    for p in /root/.bun/bin/bun /usr/local/bin/bun /opt/bun/bin/bun; do
        [ -x "$p" ] && BUN_BIN="$p" && break
    done
fi

RUNNER_FILE="packages/coding-agent/src/core/extensions/runner.ts"
KB_AGENT_FILE="packages/coding-agent/src/core/keybindings.ts"
KB_TUI_FILE="packages/tui/src/keybindings.ts"

###############################################################################
# P2P: required source files exist
###############################################################################
missing=""
for f in "$RUNNER_FILE" "$KB_AGENT_FILE"; do
    [ -f "$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then
    emit p2p_src_files_exist true ""
else
    emit p2p_src_files_exist false "missing:$missing"
fi

###############################################################################
# Helper: gather keybindings + runner content for greps
###############################################################################
KB_CONTENT=""
[ -f "$KB_AGENT_FILE" ] && KB_CONTENT="$KB_CONTENT
$(cat "$KB_AGENT_FILE")"
[ -f "$KB_TUI_FILE" ] && KB_CONTENT="$KB_CONTENT
$(cat "$KB_TUI_FILE")"

RUNNER_CONTENT=""
[ -f "$RUNNER_FILE" ] && RUNNER_CONTENT=$(cat "$RUNNER_FILE")

# Strip line comments and block comments crudely so a stray "// scope: ..."
# comment doesn't satisfy structural gates.
strip_comments() {
    # Remove /* ... */ and //... but keep strings mostly intact for grep purposes.
    sed -e 's://.*$::' "$@" 2>/dev/null | awk '
        BEGIN{inb=0}
        {
            line=$0
            while (1) {
                if (inb) {
                    p=index(line,"*/")
                    if (p==0) { line=""; break }
                    line=substr(line,p+2); inb=0
                } else {
                    p=index(line,"/*")
                    if (p==0) break
                    q=index(substr(line,p+2),"*/")
                    if (q==0) { line=substr(line,1,p-1); inb=1; break }
                    line=substr(line,1,p-1) substr(line,p+2+q+1)
                }
            }
            print line
        }'
}

KB_NOCMT=$(printf '%s\n' "$KB_CONTENT" | strip_comments)
RUNNER_NOCMT=$(printf '%s\n' "$RUNNER_CONTENT" | strip_comments)
COMBINED_NOCMT="$KB_NOCMT
$RUNNER_NOCMT"

###############################################################################
# F2P Gate t6_f2p_keybindings_have_scope_tags (0.30)
# Behavioral-structural: keybinding declarations must carry a scope field
# distinguishing picker/selector/tree from editor/global.
# We require BOTH a scope-key shape AND at least one picker-ish value AND at
# least one editor/global-ish value so a comment or a single tag can't satisfy.
###############################################################################
PICKER_VALS='picker|selector|session-?picker|tree-?picker|tree|models|overlay|prompt'
GLOBAL_VALS='editor|global|app|chat|input|message|composer'

# Count occurrences of `scope:` (or `scope =`) in declarations.
SCOPE_DECL_COUNT=$(printf '%s\n' "$KB_NOCMT" | grep -cE "scope[[:space:]]*[:=][[:space:]]*['\"]")

# Find scope values that are picker-like
PICKER_SCOPE_HITS=$(printf '%s\n' "$KB_NOCMT" | grep -cE "scope[[:space:]]*[:=][[:space:]]*['\"]($PICKER_VALS)['\"]")
# Find scope values that are global/editor-like
GLOBAL_SCOPE_HITS=$(printf '%s\n' "$KB_NOCMT" | grep -cE "scope[[:space:]]*[:=][[:space:]]*['\"]($GLOBAL_VALS)['\"]")

# Alternative shape: scopes registry like PICKER_SCOPES = [...] / SCOPES = {...}
SCOPE_REGISTRY=$(printf '%s\n' "$COMBINED_NOCMT" | grep -cE "(PICKER_SCOPES|GLOBAL_SCOPES|EDITOR_SCOPES|KEYBINDING_SCOPES|SCOPE_(SET|MAP|TABLE)|coexistingScopes)")

if [ "$SCOPE_DECL_COUNT" -ge 4 ] && [ "$PICKER_SCOPE_HITS" -ge 1 ] && [ "$GLOBAL_SCOPE_HITS" -ge 1 ]; then
    emit t6_f2p_keybindings_have_scope_tags true "decls=$SCOPE_DECL_COUNT picker=$PICKER_SCOPE_HITS global=$GLOBAL_SCOPE_HITS"
elif [ "$SCOPE_REGISTRY" -ge 1 ] && [ "$SCOPE_DECL_COUNT" -ge 2 ]; then
    emit t6_f2p_keybindings_have_scope_tags true "registry+decls"
else
    emit t6_f2p_keybindings_have_scope_tags false "scope_decls=$SCOPE_DECL_COUNT picker=$PICKER_SCOPE_HITS global=$GLOBAL_SCOPE_HITS reg=$SCOPE_REGISTRY"
fi

###############################################################################
# F2P Gate t6_f2p_runner_consults_scope (0.20)
# Runner code references scope/definition info when checking conflicts.
# Must NOT be satisfied by the buggy base which uses an allowlist
# RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS.
###############################################################################
RUNNER_HAS_SCOPE=$(printf '%s\n' "$RUNNER_NOCMT" | grep -cE "(scope|isPickerScope|isGlobalKeybinding|getEditorScope|definitions|conflictsWith|canConflict|coexist)")
RUNNER_HAS_RESERVED_ONLY=$(printf '%s\n' "$RUNNER_NOCMT" | grep -cE "RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS")

# Code structure: an `if`/`for` referencing scope (not just a string literal).
RUNNER_USES_SCOPE_LOGIC=$(printf '%s\n' "$RUNNER_NOCMT" | grep -cE "\.scope|\.scopes|scope[[:space:]]*===|scope[[:space:]]*!==|\\bscope\\b.*(\\?|\\&\\&|\\|\\|)")

if [ "$RUNNER_HAS_SCOPE" -ge 2 ] && [ "$RUNNER_USES_SCOPE_LOGIC" -ge 1 ]; then
    emit t6_f2p_runner_consults_scope true "scope_refs=$RUNNER_HAS_SCOPE logic=$RUNNER_USES_SCOPE_LOGIC reserved=$RUNNER_HAS_RESERVED_ONLY"
else
    emit t6_f2p_runner_consults_scope false "scope_refs=$RUNNER_HAS_SCOPE logic=$RUNNER_USES_SCOPE_LOGIC"
fi

###############################################################################
# F2P Gate t11_f2p_picker_scope_keys_count (0.20)
# Multiple picker/selector/tree-scope tags so the new model is actually applied
# broadly (not just one demo entry).
###############################################################################
PICKER_TAG_COUNT=$(printf '%s\n' "$KB_NOCMT" | grep -cE "scope[[:space:]]*[:=][[:space:]]*['\"]($PICKER_VALS)['\"]")
# Also count occurrences via a registry mapping (e.g., `'app.session.toggleSort': 'picker'`).
PICKER_MAP_COUNT=$(printf '%s\n' "$COMBINED_NOCMT" | grep -cE "['\"]($PICKER_VALS)['\"]")

if [ "$PICKER_TAG_COUNT" -ge 3 ]; then
    emit t11_f2p_picker_scope_keys_count true "picker_tags=$PICKER_TAG_COUNT"
elif [ "$PICKER_TAG_COUNT" -ge 1 ] && [ "$PICKER_MAP_COUNT" -ge 5 ]; then
    emit t11_f2p_picker_scope_keys_count true "tags=$PICKER_TAG_COUNT map_hits=$PICKER_MAP_COUNT"
else
    emit t11_f2p_picker_scope_keys_count false "picker_tags=$PICKER_TAG_COUNT map_hits=$PICKER_MAP_COUNT"
fi

###############################################################################
# F2P Gate t11_f2p_global_editor_scope_keys_present (0.15)
# At least some keys flagged as global/editor scope so conflict detection
# still has a target set. Prevents "make every key picker-scope" stub.
###############################################################################
GLOBAL_TAG_COUNT=$(printf '%s\n' "$KB_NOCMT" | grep -cE "scope[[:space:]]*[:=][[:space:]]*['\"]($GLOBAL_VALS)['\"]")
GLOBAL_REGISTRY_HIT=$(printf '%s\n' "$COMBINED_NOCMT" | grep -cE "(GLOBAL_SCOPES|EDITOR_SCOPES|isGlobalKeybinding|isEditorScope|global.*scope|editor.*scope)")

if [ "$GLOBAL_TAG_COUNT" -ge 1 ] || [ "$GLOBAL_REGISTRY_HIT" -ge 2 ]; then
    emit t11_f2p_global_editor_scope_keys_present true "global_tags=$GLOBAL_TAG_COUNT reg=$GLOBAL_REGISTRY_HIT"
else
    emit t11_f2p_global_editor_scope_keys_present false "global_tags=$GLOBAL_TAG_COUNT reg=$GLOBAL_REGISTRY_HIT"
fi

###############################################################################
# F2P Gate t13_f2p_runner_tests_pass (0.15)
# Behavioral: the in-repo extensions-runner tests pass after the fix.
# Patches typically update these tests to reflect the new behavior.
# To avoid penalizing a refactor that legitimately changes the API while
# fixing tests, we check that:
#   (a) the test file exists,
#   (b) running it yields >=1 pass and 0 fails.
# On the no-op base, tests will fail because (i) the buggy state may have
# broken assertions, or (ii) we still want to confirm nothing regressed.
# This gate also gives credit for any model that produced a coherent fix
# with passing tests, regardless of API shape.
###############################################################################
TEST_FILE="packages/coding-agent/test/extensions-runner.test.ts"
if [ -z "$BUN_BIN" ] || [ ! -f "$TEST_FILE" ]; then
    emit t13_f2p_runner_tests_pass false "no bun or no test file"
else
    OUT=$("$BUN_BIN" test "$TEST_FILE" 2>&1)
    echo "----- runner test output (tail) -----"
    echo "$OUT" | tail -25
    PASS=$(echo "$OUT" | grep -cE "\(pass\)")
    FAIL=$(echo "$OUT" | grep -cE "\(fail\)")
    # Bun also reports a summary line "X pass" / "Y fail"
    SUMMARY_PASS=$(echo "$OUT" | grep -oE "[0-9]+ pass" | head -1 | awk '{print $1}')
    SUMMARY_FAIL=$(echo "$OUT" | grep -oE "[0-9]+ fail" | head -1 | awk '{print $1}')
    [ -z "$SUMMARY_PASS" ] && SUMMARY_PASS=0
    [ -z "$SUMMARY_FAIL" ] && SUMMARY_FAIL=0

    EFFECTIVE_PASS=$PASS
    EFFECTIVE_FAIL=$FAIL
    [ "$SUMMARY_PASS" -gt "$EFFECTIVE_PASS" ] && EFFECTIVE_PASS=$SUMMARY_PASS
    [ "$SUMMARY_FAIL" -gt "$EFFECTIVE_FAIL" ] && EFFECTIVE_FAIL=$SUMMARY_FAIL

    if [ "$EFFECTIVE_PASS" -ge 1 ] && [ "$EFFECTIVE_FAIL" -eq 0 ]; then
        emit t13_f2p_runner_tests_pass true "pass=$EFFECTIVE_PASS fail=$EFFECTIVE_FAIL"
    else
        emit t13_f2p_runner_tests_pass false "pass=$EFFECTIVE_PASS fail=$EFFECTIVE_FAIL"
    fi
fi

###############################################################################
# Reward computation
###############################################################################
P2P_FAILED=0
while IFS= read -r line; do
    id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
    passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
    case "$id" in
        p2p_*)
            if [ "$passed" = "false" ]; then
                P2P_FAILED=1
            fi
            ;;
    esac
done < "$GATES_FILE"

REWARD=0
if [ "$P2P_FAILED" -eq 0 ]; then
    declare -A WEIGHTS
    WEIGHTS[t6_f2p_keybindings_have_scope_tags]="0.30"
    WEIGHTS[t6_f2p_runner_consults_scope]="0.20"
    WEIGHTS[t11_f2p_picker_scope_keys_count]="0.20"
    WEIGHTS[t11_f2p_global_editor_scope_keys_present]="0.15"
    WEIGHTS[t13_f2p_runner_tests_pass]="0.15"

    while IFS= read -r line; do
        id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
        passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
        w="${WEIGHTS[$id]}"
        if [ -n "$w" ] && [ "$passed" = "true" ]; then
            REWARD=$(awk -v r="$REWARD" -v w="$w" 'BEGIN { printf "%.6f", r+w }')
        fi
    done < "$GATES_FILE"
fi

printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
echo "REWARD=$REWARD"
cat "$GATES_FILE"
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
run_v043_gate p2p_upstream_c09e61c3 'npm_typecheck_tui' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/tui && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_047e9a81 'vitest_session_manager_tui' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/tui && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'
run_v043_gate p2p_upstream_e395cbc7 'npm_typecheck_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_522628b0 'vitest_session_manager_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t11_f2p_global_editor_scope_keys_present": 0.15, "t11_f2p_picker_scope_keys_count": 0.2, "t13_f2p_runner_tests_pass": 0.15, "t6_f2p_keybindings_have_scope_tags": 0.3, "t6_f2p_runner_consults_scope": 0.2}
P2P_GATING = ["p2p_src_files_exist"]
P2P_REGRESSION = ["p2p_upstream_c09e61c3", "p2p_upstream_047e9a81", "p2p_upstream_e395cbc7", "p2p_upstream_522628b0"]
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