#!/bin/bash
set +e

# ═══════════════════════════════════════════════════════════════════
# Verifier for pi-mono extensions event refactor task
# Tests that tool_result events are handled by a dedicated emitToolResult
# method instead of being processed inline in emit().
# ═══════════════════════════════════════════════════════════════════

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier 2>/dev/null || true
touch "$REWARD_FILE" 2>/dev/null || REWARD_FILE="/tmp/reward.txt"

cd /workspace/pi-mono

# Ensure git works regardless of which user runs the test
git config --global --add safe.directory /workspace/pi-mono 2>/dev/null || true

RUNNER="packages/coding-agent/src/core/extensions/runner.ts"
WRAPPER="packages/coding-agent/src/core/extensions/wrapper.ts"

# Weights must sum to 100
# Gate layout:
#   P2P gates: pass on base AND on correct fix (regression guards)
#   F2P gates: fail on base, pass on correct fix (discrimination gates)

SCORE=0

# ─────────────────────────────────────────────────────────────────
# GATE 1 [P2P] — TypeScript compilation (weight 5)
# The coding-agent package must compile without errors in extension files.
# Passes on base (no pre-existing errors) and on correct fix.
# ─────────────────────────────────────────────────────────────────
echo "=== GATE 1 [P2P]: TypeScript compilation ==="
cd /workspace/pi-mono/packages/coding-agent
TSC_OUTPUT=$(npx tsc -p tsconfig.build.json --noEmit 2>&1)
TSC_EXT_ERRORS=$(echo "$TSC_OUTPUT" | grep -c "extensions/\(runner\|wrapper\|types\)\.ts.*error TS" || true)

if [ "$TSC_EXT_ERRORS" -eq 0 ]; then
    echo "PASS: No TypeScript errors in extension files"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: $TSC_EXT_ERRORS TypeScript errors in extension files"
    echo "$TSC_OUTPUT" | grep "extensions/" | head -10
fi

cd /workspace/pi-mono

# ─────────────────────────────────────────────────────────────────
# GATE 2 [P2P] — tsgo build produces runner.js (weight 5)
# The project must build successfully with tsgo.
# Passes on base and on correct fix.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 2 [P2P]: tsgo build produces valid output ==="
cd /workspace/pi-mono/packages/coding-agent
rm -rf dist 2>/dev/null
npx tsgo -p tsconfig.build.json 2>&1 > /dev/null

if [ -f "dist/core/extensions/runner.js" ] && [ -f "dist/core/extensions/wrapper.js" ]; then
    echo "PASS: tsgo build produced runner.js and wrapper.js"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: tsgo build did not produce expected output files"
fi

cd /workspace/pi-mono

# ─────────────────────────────────────────────────────────────────
# GATE 3 [F2P] — emitToolResult method exists on runner (weight 25)
# After fix, ExtensionRunner must have a dedicated emitToolResult method.
# This is verified by building the TS and checking the JS prototype via Node.
# FAILS on base (method doesn't exist). PASSES after correct fix.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 3 [F2P]: emitToolResult method exists (behavioral) ==="
if [ -f "packages/coding-agent/dist/core/extensions/runner.js" ]; then
    HAS_METHOD=$(cd packages/coding-agent && node -e "
        try {
            const mod = require('./dist/core/extensions/runner.js');
            const Runner = mod.ExtensionRunner;
            if (Runner && typeof Runner.prototype.emitToolResult === 'function') {
                console.log('YES');
            } else {
                console.log('NO');
            }
        } catch(e) {
            console.log('NO');
        }
    " 2>/dev/null)

    if [ "$HAS_METHOD" = "YES" ]; then
        echo "PASS: emitToolResult method found on ExtensionRunner prototype"
        SCORE=$((SCORE + 25))
    else
        echo "FAIL: emitToolResult method not found on ExtensionRunner prototype"
    fi
else
    echo "FAIL: Cannot check — build output missing"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 4 [F2P] — emit() no longer handles tool_result inline (weight 20)
# After fix, the generic emit() method should NOT contain special-case
# handling for tool_result events. Verified by checking the built JS.
# FAILS on base (emit contains tool_result check). PASSES after fix.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 4 [F2P]: emit() does not handle tool_result inline ==="
if [ -f "packages/coding-agent/dist/core/extensions/runner.js" ]; then
    EMIT_HANDLES_TR=$(cd packages/coding-agent && node -e "
        const fs = require('fs');
        const src = fs.readFileSync('./dist/core/extensions/runner.js', 'utf8');
        // Find the emit method body (from 'async emit(' to next 'async emitXxx')
        const emitMatch = src.match(/async emit\([\s\S]*?(?=async emit[A-Z])/);
        if (!emitMatch) { console.log('NO'); process.exit(0); }
        const body = emitMatch[0];
        // Check for ANY tool_result handling: literal string OR helper method
        const hasLiteral = /['\"]tool_result['\"]/.test(body);
        const hasHelper = /isToolResultEvent/.test(body);
        const hasToolResultCast = /ToolResultEventResult/.test(body);
        if (hasLiteral || hasHelper || hasToolResultCast) {
            console.log('YES');
        } else {
            console.log('NO');
        }
    " 2>/dev/null)

    if [ "$EMIT_HANDLES_TR" = "NO" ]; then
        echo "PASS: emit() does not handle tool_result events"
        SCORE=$((SCORE + 20))
    else
        echo "FAIL: emit() still handles tool_result events inline"
    fi
else
    echo "FAIL: Cannot check — build output missing"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 5 [F2P] — wrapper.ts calls dedicated emitToolResult (weight 20)
# After fix, wrapper.ts should call runner.emitToolResult() instead of
# runner.emit() for tool_result events.
# FAILS on base (wrapper calls emit). PASSES after fix.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 5 [F2P]: wrapper calls emitToolResult (behavioral) ==="
if [ -f "packages/coding-agent/dist/core/extensions/wrapper.js" ]; then
    WRAPPER_CALLS=$(cd packages/coding-agent && node -e "
        const fs = require('fs');
        const src = fs.readFileSync('./dist/core/extensions/wrapper.js', 'utf8');
        // Check if wrapper calls emitToolResult (any naming convention)
        if (/\.emitToolResult\s*\(/.test(src)) {
            console.log('YES');
        } else {
            console.log('NO');
        }
    " 2>/dev/null)

    if [ "$WRAPPER_CALLS" = "YES" ]; then
        echo "PASS: wrapper.js calls emitToolResult"
        SCORE=$((SCORE + 20))
    else
        echo "FAIL: wrapper.js does not call emitToolResult"
    fi
else
    echo "FAIL: Cannot check — build output missing"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 6 [F2P] — emit() return type excludes ToolResultEventResult (weight 15)
# After fix, emit() should not reference ToolResultEventResult in its
# return type. Verified via the .d.ts declaration output.
# FAILS on base. PASSES after correct fix.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 6 [F2P]: emit() return type cleaned up ==="
if [ -f "packages/coding-agent/dist/core/extensions/runner.d.ts" ]; then
    EMIT_TYPE_CLEAN=$(cd packages/coding-agent && node -e "
        const fs = require('fs');
        const dts = fs.readFileSync('./dist/core/extensions/runner.d.ts', 'utf8');
        // Find emit method signature and check if it references ToolResultEventResult
        const emitMatch = dts.match(/emit\(event[^)]*\)[^;]*?Promise<[^>]+>/);
        if (emitMatch && /ToolResultEventResult/.test(emitMatch[0])) {
            console.log('DIRTY');
        } else {
            console.log('CLEAN');
        }
    " 2>/dev/null)

    if [ "$EMIT_TYPE_CLEAN" = "CLEAN" ]; then
        echo "PASS: emit() return type does not include ToolResultEventResult"
        SCORE=$((SCORE + 15))
    else
        echo "FAIL: emit() return type still includes ToolResultEventResult"
    fi
else
    echo "FAIL: Cannot check — .d.ts output missing"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 7 [F2P] — runner.ts was actually modified (weight 10)
# The agent must have changed runner.ts. Verified via git diff.
# FAILS on base (no changes). PASSES after any fix attempt.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 7 [F2P]: runner.ts was modified ==="
RUNNER_CHANGED=false
BASE_COMMIT="961d3aacbc9ac5145ac40448960582e3f44d7c4a"
if git diff --name-only 2>/dev/null | grep -q "extensions/runner\.ts"; then
    RUNNER_CHANGED=true
fi
if git diff --cached --name-only 2>/dev/null | grep -q "extensions/runner\.ts"; then
    RUNNER_CHANGED=true
fi
if git diff --name-only "$BASE_COMMIT" HEAD 2>/dev/null | grep -q "extensions/runner\.ts"; then
    RUNNER_CHANGED=true
fi
if git log --oneline "$BASE_COMMIT"..HEAD -- "$RUNNER" 2>/dev/null | grep -q .; then
    RUNNER_CHANGED=true
fi

if [ "$RUNNER_CHANGED" = true ]; then
    echo "PASS: runner.ts was modified"
    SCORE=$((SCORE + 10))
else
    echo "FAIL: runner.ts was not modified"
fi

# ─────────────────────────────────────────────────────────────────
# Calculate reward
# ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "TOTAL SCORE: $SCORE / 100"

# Convert to 0.00-1.00 range
REWARD_WHOLE=$((SCORE / 100))
REWARD_FRAC=$((SCORE % 100))
REWARD=$(printf "%d.%02d" "$REWARD_WHOLE" "$REWARD_FRAC")

echo "REWARD: $REWARD"
echo "========================================="

echo "$REWARD" > "$REWARD_FILE"
