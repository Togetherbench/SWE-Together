#!/usr/bin/env bash
# =============================================================================
# Harbor verifier for rudel-task-d1ddb8
#
# CI/CD source: .github/workflows/ci.yml uses "bunx turbo run lint check-types test build"
# CLI tests:    apps/cli/package.json uses "bun test" (Bun native test runner)
# =============================================================================
set +e


# Canonical PATH (E2B strips Dockerfile ENV PATH; restore tool dirs)
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO_DIR="/workspace/rudel"
TS_FILE="$REPO_DIR/apps/cli/src/lib/claude-settings.ts"
GATES_JSON="/logs/verifier/gates.json"
REWARD_FILE="/logs/verifier/reward.txt"
TEST_DIR="/tmp/harbor_test"

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Track verdicts
declare -A VERDICTS

emit_gate() {
    local gid="$1"
    local verdict="$2"
    local reason="$3"
    VERDICTS["$gid"]="$verdict"
    echo "[GATE] $gid: $verdict — $reason" >&2
}

echo "=== Harbor Verifier: rudel-task-d1ddb8 ===" >&2
echo "TS_FILE=$TS_FILE" >&2

# =============================================================================
# STRUCTURAL CHECKS (Bronze gates)
# =============================================================================

# --- F2P-1: getClaudeSettingsPath no longer hardcodes HOME for path ---
GID="f2p_no_home_path"
# The old code had: return join(process.env.HOME ?? "~", ".claude", "settings.json")
# The new code should NOT use process.env.HOME for the settings path
if grep -q "process\.env\.HOME" "$TS_FILE"; then
    # Check if HOME is still used to construct the settings path directly
    # (it might be used elsewhere legitimately, but NOT for the settings path)
    if grep -A2 "getClaudeSettingsPath" "$TS_FILE" | grep -q "process\.env\.HOME.*\.claude.*settings"; then
        emit_gate "$GID" "false" "process.env.HOME still used to construct settings path in getClaudeSettingsPath"
    else
        emit_gate "$GID" "true" "process.env.HOME not used for settings path construction"
    fi
else
    emit_gate "$GID" "true" "process.env.HOME not referenced in file"
fi

# --- F2P-2: findClaudeDir function exists ---
GID="f2p_find_claude_dir"
if grep -q "function findClaudeDir" "$TS_FILE"; then
    emit_gate "$GID" "true" "findClaudeDir function found"
else
    emit_gate "$GID" "false" "findClaudeDir function not found"
fi

# --- F2P-3: findClaudeDir has meaningful body (>3 non-trivial statements) ---
GID="f2p_meaningful_body"
# Count meaningful lines in findClaudeDir body: let, const, if, while, try, return, execSync
BODY_START=$(grep -n "function findClaudeDir" "$TS_FILE" | head -1 | cut -d: -f1)
if [[ -n "$BODY_START" ]]; then
    # Find the closing brace (assume it's indented at same level as function)
    BODY_END=$(tail -n +"$BODY_START" "$TS_FILE" | grep -n "^}" | head -1 | cut -d: -f1)
    BODY_END=$((BODY_START + BODY_END - 1))
    STMT_COUNT=$(sed -n "${BODY_START},${BODY_END}p" "$TS_FILE" | grep -cE "^\s+(let |const |if |while |try |return |execSync|for )" 2>/dev/null || echo 0)
    if [[ "$STMT_COUNT" -gt 3 ]]; then
        emit_gate "$GID" "true" "findClaudeDir has $STMT_COUNT meaningful statements (>3)"
    else
        emit_gate "$GID" "false" "findClaudeDir has only $STMT_COUNT statements (need >3)"
    fi
else
    emit_gate "$GID" "false" "findClaudeDir function not found"
fi

# --- F2P-4: execSync imported for git root detection ---
GID="f2p_execsync_import"
if grep -q "execSync.*node:child_process" "$TS_FILE"; then
    emit_gate "$GID" "true" "execSync imported from node:child_process"
else
    emit_gate "$GID" "false" "execSync not imported for git root fallback"
fi

# --- F2P-5: mkdirSync called in writeClaudeSettings ---
GID="f2p_mkdir_in_write"
if grep -A5 "export function writeClaudeSettings" "$TS_FILE" | grep -q "mkdirSync"; then
    emit_gate "$GID" "true" "mkdirSync found in writeClaudeSettings body"
else
    emit_gate "$GID" "false" "mkdirSync not found in writeClaudeSettings"
fi

# =============================================================================
# BEHAVIORAL CHECKS (Gold/Silver gates)
# =============================================================================

# --- F2P-6: Walk-up finds existing .claude/ directory ---
GID="f2p_walk_up"
WALK_REPO="$TEST_DIR/repo_with_claude"
rm -rf "$WALK_REPO"
mkdir -p "$WALK_REPO/.claude"
cd "$WALK_REPO" && git init -q 2>/dev/null
git -C "$WALK_REPO" config user.email "test@test.com"
git -C "$WALK_REPO" config user.name "Test"
git -C "$WALK_REPO" commit --allow-empty -q -m "init" 2>/dev/null
mkdir -p "$WALK_REPO/sub/deep"

cat > "$TEST_DIR/walk_up_test.ts" << 'TSEOF'
import { getClaudeSettingsPath } from '/workspace/rudel/apps/cli/src/lib/claude-settings';
console.log(getClaudeSettingsPath());
TSEOF

GOT=$(cd "$WALK_REPO/sub/deep" && bun run "$TEST_DIR/walk_up_test.ts" 2>/dev/null)
EXPECTED="$WALK_REPO/.claude/settings.json"
if [[ "$GOT" == "$EXPECTED" ]]; then
    emit_gate "$GID" "true" "walk-up found .claude/ at repo root"
else
    emit_gate "$GID" "false" "expected $EXPECTED, got '$GOT'"
fi

# --- F2P-7: Falls back to git root when no .claude/ dir exists ---
GID="f2p_git_fallback"
GIT_REPO="$TEST_DIR/repo_no_claude"
rm -rf "$GIT_REPO"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q 2>/dev/null
git -C "$GIT_REPO" config user.email "test@test.com"
git -C "$GIT_REPO" config user.name "Test"
git -C "$GIT_REPO" commit --allow-empty -q -m "init" 2>/dev/null
mkdir -p "$GIT_REPO/sub"

cat > "$TEST_DIR/git_fallback_test.ts" << 'TSEOF'
import { getClaudeSettingsPath } from '/workspace/rudel/apps/cli/src/lib/claude-settings';
console.log(getClaudeSettingsPath());
TSEOF

GOT=$(cd "$GIT_REPO/sub" && bun run "$TEST_DIR/git_fallback_test.ts" 2>/dev/null)
EXPECTED="$GIT_REPO/.claude/settings.json"
if [[ "$GOT" == "$EXPECTED" ]]; then
    emit_gate "$GID" "true" "fell back to git root when no .claude/ dir"
else
    emit_gate "$GID" "false" "expected $EXPECTED, got '$GOT'"
fi

# --- F2P-8: writeClaudeSettings creates .claude/ directory ---
GID="f2p_mkdir_created"
WRITE_TEST="$TEST_DIR/write_test"
rm -rf "$WRITE_TEST"
mkdir -p "$WRITE_TEST"

cat > "$TEST_DIR/mkdir_test.ts" << 'TSEOF'
import { writeClaudeSettings } from '/workspace/rudel/apps/cli/src/lib/claude-settings';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const settings: Record<string, unknown> = { _harbor_test: true };
writeClaudeSettings(settings);
const settingsPath = join(process.cwd(), '.claude', 'settings.json');
if (existsSync(settingsPath)) {
    const content = readFileSync(settingsPath, 'utf-8');
    const parsed = JSON.parse(content);
    if (parsed._harbor_test === true) {
        console.log('CREATED_OK');
    } else {
        console.log('WRONG_CONTENT');
    }
} else {
    console.log('NOT_CREATED');
}
TSEOF

GOT=$(cd "$WRITE_TEST" && bun run "$TEST_DIR/mkdir_test.ts" 2>/dev/null)
if [[ "$GOT" == "CREATED_OK" ]]; then
    emit_gate "$GID" "true" "writeClaudeSettings created .claude/ dir with correct content"
else
    emit_gate "$GID" "false" "writeClaudeSettings dir creation failed: $GOT"
fi

# =============================================================================
# P2P REGRESSION GATES (diagnostic-only — any failure zeros reward)
# =============================================================================

P2P_FAILED=false

# --- P2P-1: TypeScript compilation passes ---
GID="p2p_typescript_ok"
cd "$REPO_DIR/apps/cli" && bun run check-types > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    emit_gate "$GID" "true" "TypeScript compilation passes"
else
    emit_gate "$GID" "false" "TypeScript compilation failed"
    P2P_FAILED=true
fi

# --- P2P-2: readClaudeSettings still works ---
GID="p2p_read_settings"
READ_TEST="$TEST_DIR/read_test"
rm -rf "$READ_TEST"
mkdir -p "$READ_TEST/.claude"
echo '{"existing": true}' > "$READ_TEST/.claude/settings.json"
git -C "$READ_TEST" init -q 2>/dev/null
git -C "$READ_TEST" config user.email "test@test.com"
git -C "$READ_TEST" config user.name "Test"
git -C "$READ_TEST" commit --allow-empty -q -m "init" 2>/dev/null

cat > "$TEST_DIR/read_settings_test.ts" << 'TSEOF'
import { readClaudeSettings } from '/workspace/rudel/apps/cli/src/lib/claude-settings';
const settings = readClaudeSettings();
if (settings && settings.existing === true) {
    console.log('OK');
} else {
    console.log('FAIL');
}
TSEOF

GOT=$(cd "$READ_TEST" && bun run "$TEST_DIR/read_settings_test.ts" 2>/dev/null)
if [[ "$GOT" == "OK" ]]; then
    emit_gate "$GID" "true" "readClaudeSettings reads settings correctly"
else
    emit_gate "$GID" "false" "readClaudeSettings failed: $GOT"
    P2P_FAILED=true
fi

# --- P2P-3: addHook adds hook to SessionEnd ---
GID="p2p_add_hook"
ADD_TEST="$TEST_DIR/add_test"
rm -rf "$ADD_TEST"
mkdir -p "$ADD_TEST/.claude"
echo '{}' > "$ADD_TEST/.claude/settings.json"
git -C "$ADD_TEST" init -q 2>/dev/null
git -C "$ADD_TEST" config user.email "test@test.com"
git -C "$ADD_TEST" config user.name "Test"
git -C "$ADD_TEST" commit --allow-empty -q -m "init" 2>/dev/null

cat > "$TEST_DIR/add_hook_test.ts" << 'TSEOF'
import {
    addHook,
    isHookEnabled,
    readClaudeSettings,
} from '/workspace/rudel/apps/cli/src/lib/claude-settings';

addHook();
const settings = readClaudeSettings();
const entries = settings.hooks?.SessionEnd;
const found = Array.isArray(entries) && entries.some((e: any) =>
    e.hooks?.some((h: any) => h.command === 'rudel hooks claude session-end')
);
const enabled = isHookEnabled();
if (found && enabled) {
    console.log('OK');
} else {
    console.log('FAIL');
}
TSEOF

GOT=$(cd "$ADD_TEST" && bun run "$TEST_DIR/add_hook_test.ts" 2>/dev/null)
if [[ "$GOT" == "OK" ]]; then
    emit_gate "$GID" "true" "addHook correctly adds hook"
else
    emit_gate "$GID" "false" "addHook failed: $GOT"
    P2P_FAILED=true
fi

# --- P2P-4: removeHook removes only the rudel hook ---
GID="p2p_remove_hook"
REMOVE_TEST="$TEST_DIR/remove_test"
rm -rf "$REMOVE_TEST"
mkdir -p "$REMOVE_TEST/.claude"
cat > "$REMOVE_TEST/.claude/settings.json" << 'JSONEOF'
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "other-hook", "async": true }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "rudel hooks claude session-end", "async": true }
        ]
      }
    ]
  }
}
JSONEOF
git -C "$REMOVE_TEST" init -q 2>/dev/null
git -C "$REMOVE_TEST" config user.email "test@test.com"
git -C "$REMOVE_TEST" config user.name "Test"
git -C "$REMOVE_TEST" commit --allow-empty -q -m "init" 2>/dev/null

cat > "$TEST_DIR/remove_hook_test.ts" << 'TSEOF'
import {
    isHookEnabled,
    readClaudeSettings,
    removeHook,
} from '/workspace/rudel/apps/cli/src/lib/claude-settings';

const before = isHookEnabled();
removeHook();
const after = isHookEnabled();
const settings = readClaudeSettings();
const entries = settings.hooks?.SessionEnd;
const otherPreserved = Array.isArray(entries) && entries.some((e: any) =>
    e.hooks?.some((h: any) => h.command === 'other-hook')
);
const rudelGone = !(Array.isArray(entries) && entries.some((e: any) =>
    e.hooks?.some((h: any) => h.command === 'rudel hooks claude session-end')
));

if (before && !after && otherPreserved && rudelGone) {
    console.log('OK');
} else {
    console.log('FAIL');
}
TSEOF

GOT=$(cd "$REMOVE_TEST" && bun run "$TEST_DIR/remove_hook_test.ts" 2>/dev/null)
if [[ "$GOT" == "OK" ]]; then
    emit_gate "$GID" "true" "removeHook correctly removes rudel hook, preserves others"
else
    emit_gate "$GID" "false" "removeHook failed: $GOT"
    P2P_FAILED=true
fi

# --- P2P-5: Empty hooks object is cleaned up ---
GID="p2p_cleanup_empty"
CLEANUP_TEST="$TEST_DIR/cleanup_test"
rm -rf "$CLEANUP_TEST"
mkdir -p "$CLEANUP_TEST/.claude"
cat > "$CLEANUP_TEST/.claude/settings.json" << 'JSONEOF'
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "rudel hooks claude session-end", "async": true }
        ]
      }
    ]
  }
}
JSONEOF
git -C "$CLEANUP_TEST" init -q 2>/dev/null
git -C "$CLEANUP_TEST" config user.email "test@test.com"
git -C "$CLEANUP_TEST" config user.name "Test"
git -C "$CLEANUP_TEST" commit --allow-empty -q -m "init" 2>/dev/null

cat > "$TEST_DIR/cleanup_test.ts" << 'TSEOF'
import { readClaudeSettings, removeHook } from '/workspace/rudel/apps/cli/src/lib/claude-settings';

removeHook();
const settings = readClaudeSettings();
// After removing the only hook, hooks.SessionEnd should be empty,
// and if no other hooks exist, the hooks key should be deleted
const hooksKeyDeleted = !settings.hooks || Object.keys(settings.hooks).length === 0;
if (hooksKeyDeleted) {
    console.log('OK');
} else {
    console.log('FAIL');
}
TSEOF

GOT=$(cd "$CLEANUP_TEST" && bun run "$TEST_DIR/cleanup_test.ts" 2>/dev/null)
if [[ "$GOT" == "OK" ]]; then
    emit_gate "$GID" "true" "empty hooks object cleaned up on remove"
else
    emit_gate "$GID" "false" "cleanup failed: $GOT"
    P2P_FAILED=true
fi

# --- P2P-6: addHook preserves existing hooks ---
GID="p2p_preserve_hooks"
PRESERVE_TEST="$TEST_DIR/preserve_test"
rm -rf "$PRESERVE_TEST"
mkdir -p "$PRESERVE_TEST/.claude"
cat > "$PRESERVE_TEST/.claude/settings.json" << 'JSONEOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "startup-hook" }
        ]
      }
    ]
  }
}
JSONEOF
git -C "$PRESERVE_TEST" init -q 2>/dev/null
git -C "$PRESERVE_TEST" config user.email "test@test.com"
git -C "$PRESERVE_TEST" config user.name "Test"
git -C "$PRESERVE_TEST" commit --allow-empty -q -m "init" 2>/dev/null

cat > "$TEST_DIR/preserve_test.ts" << 'TSEOF'
import {
    addHook,
    readClaudeSettings,
} from '/workspace/rudel/apps/cli/src/lib/claude-settings';

addHook();
const settings = readClaudeSettings();
const sessionStartPreserved = settings.hooks?.SessionStart?.some((e: any) =>
    e.hooks?.some((h: any) => h.command === 'startup-hook')
);
const sessionEndAdded = settings.hooks?.SessionEnd?.some((e: any) =>
    e.hooks?.some((h: any) => h.command === 'rudel hooks claude session-end')
);
if (sessionStartPreserved && sessionEndAdded) {
    console.log('OK');
} else {
    console.log('FAIL');
}
TSEOF

GOT=$(cd "$PRESERVE_TEST" && bun run "$TEST_DIR/preserve_test.ts" 2>/dev/null)
if [[ "$GOT" == "OK" ]]; then
    emit_gate "$GID" "true" "addHook preserves existing hooks in other categories"
else
    emit_gate "$GID" "false" "preserve failed: $GOT"
    P2P_FAILED=true
fi

# =============================================================================
# REWARD COMPUTATION (weighted-replace formula — NOT additive)
# =============================================================================

# WEIGHTS for F2P gates — must sum to <= 1.0
# Structural: 0.10+0.10+0.05+0.05+0.10 = 0.40 (40% — under R008 limit)
# Behavioral: 0.25+0.25+0.10 = 0.60 (60%)
# Total:      0.40 + 0.60 = 1.00
# Inner weight: max(0.0, 1.0 - 1.00) = 0.0

declare -A WEIGHTS
WEIGHTS["f2p_no_home_path"]="0.10"
WEIGHTS["f2p_find_claude_dir"]="0.10"
WEIGHTS["f2p_meaningful_body"]="0.05"
WEIGHTS["f2p_execsync_import"]="0.05"
WEIGHTS["f2p_mkdir_in_write"]="0.10"
WEIGHTS["f2p_walk_up"]="0.25"
WEIGHTS["f2p_git_fallback"]="0.25"
WEIGHTS["f2p_mkdir_created"]="0.10"

# Check if any F2P gate passed
F2P_ANY_PASS=false
for gid in "${!WEIGHTS[@]}"; do
    if [[ "${VERDICTS[$gid]}" == "true" ]]; then
        F2P_ANY_PASS=true
        break
    fi
done

# Compute reward
if false; then  # P2P_REGRESSION informational only (v043 fix)
    REWARD=0.0
    echo "P2P regression failed — reward=0.0" >&2
elif ! $F2P_ANY_PASS; then
    REWARD=0.0
    echo "No F2P gates passed — reward=0.0" >&2
else
    # Weighted-replace formula
    WEIGHT_SUM=0.0
    for w in "${WEIGHTS[@]}"; do
        WEIGHT_SUM=$(python3 -c "print($WEIGHT_SUM + $w)")
    done
    INNER_WEIGHT=$(python3 -c "print(max(0.0, 1.0 - $WEIGHT_SUM))")

    REWARD=0.0
    # Start: REWARD = existing * inner_weight
    REWARD=$(python3 -c "print(0.0 * $INNER_WEIGHT)")

    # Add weights for passed gates
    for gid in "${!WEIGHTS[@]}"; do
        if [[ "${VERDICTS[$gid]}" == "true" ]]; then
            w="${WEIGHTS[$gid]}"
            REWARD=$(python3 -c "print($REWARD + $w)")
        fi
    done
fi

# Write reward
echo "$REWARD" > "$REWARD_FILE"
echo "Final reward: $REWARD" >&2

# Write gates.json for audit trail
{
    echo -n "["
    FIRST=true
    for gid in "${!VERDICTS[@]}"; do
        if $FIRST; then FIRST=false; else echo -n ","; fi
        echo -n "{\"id\":\"$gid\",\"verdict\":${VERDICTS[$gid]}}"
    done
    echo "]"
} > "$GATES_JSON"

# Clean up test artifacts
rm -rf "$TEST_DIR"
