#!/usr/bin/env bash
#
# Verification tests for the reigh TimelineModeContent refactor.
#
# Tests that the agent eliminated the pass-through TimelineModeContent layer,
# properly wired ShotImagesEditor.tsx directly to Timeline, cleaned the barrel
# file, and removed dead props from Timeline.tsx and TimelineContainer.tsx.
#
# Reward: 0.0 to 1.0, written to /logs/verifier/reward.txt
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=12

REPO="/workspace/reigh"
TIMELINE_MODE_CONTENT="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$REPO/src/tools/travel-between-images/components/ShotImagesEditor.tsx"
TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline.tsx"
TIMELINE_CONTAINER="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/TimelineContainer.tsx"
TIMELINE_CONTAINER_TYPES="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/types.ts"

###############################################################################
# Test 1 (Bronze): TimelineModeContent.tsx is deleted (1/12)
###############################################################################
echo "=== Test 1/8: TimelineModeContent.tsx deleted ==="
if [ ! -f "$TIMELINE_MODE_CONTENT" ]; then
    echo "PASS: TimelineModeContent.tsx has been deleted"
    PASS=$((PASS + 1))  # worth 1 point
else
    echo "FAIL: TimelineModeContent.tsx still exists at $TIMELINE_MODE_CONTENT"
fi

###############################################################################
# Test 2 (Bronze): Barrel file no longer exports TimelineModeContent (0.10)
###############################################################################
echo ""
echo "=== Test 2/8: Barrel file doesn't export TimelineModeContent ==="
if [ ! -f "$BARREL" ]; then
    # Barrel file itself deleted — also acceptable
    echo "PASS: Barrel file deleted (acceptable)"
    PASS=$((PASS + 1))
elif ! grep -q "TimelineModeContent" "$BARREL" 2>/dev/null; then
    echo "PASS: Barrel file no longer exports TimelineModeContent"
    PASS=$((PASS + 1))
else
    echo "FAIL: Barrel file still exports TimelineModeContent:"
    grep "TimelineModeContent" "$BARREL" | head -3
fi

###############################################################################
# Test 3 (Silver): ShotImagesEditor.tsx renders <Timeline> not <TimelineModeContent> (0.10)
# Upgraded: uses node to strip comments and check JSX tags, not bare grep
###############################################################################
echo ""
echo "=== Test 3/8: ShotImagesEditor.tsx renders Timeline directly ==="
if [ -f "$SHOT_EDITOR" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
// Strip single-line and multi-line comments before checking
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
// Check for <TimelineModeContent in actual code (should be absent)
if (/<TimelineModeContent[\s\/>]/.test(noComments)) {
    console.error('FAIL: <TimelineModeContent> JSX still in actual code');
    process.exit(1);
}
// Check for <Timeline in actual code (should be present)
if (!/<Timeline[\s\/>]/.test(noComments)) {
    console.error('FAIL: <Timeline> JSX not found in actual code');
    process.exit(1);
}
console.log('PASS: ShotImagesEditor renders <Timeline> directly (comment-stripped check)');
process.exit(0);
" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ShotImagesEditor.tsx does not render <Timeline> directly"
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# Test 4 (Silver): Unpositioned generations rendering inlined into ShotImagesEditor.tsx (0.10)
# Checks for the actual rendered text "unpositioned generation" — this string
# only existed in TimelineModeContent.tsx at the base commit, NOT in ShotImagesEditor.
# Strips comments to prevent comment-injection gaming.
###############################################################################
echo ""
echo "=== Test 4/8: Unpositioned generations div inlined into ShotImagesEditor.tsx ==="
if [ -f "$SHOT_EDITOR" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
// Strip single-line and multi-line comments before checking
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
// Must have the rendered text string (was in TimelineModeContent's JSX, now must be here)
if (!noComments.includes('unpositioned generation')) {
    console.error('FAIL: rendered text \"unpositioned generation\" not found in ShotImagesEditor.tsx code');
    console.error('  (The unpositioned generations div must be inlined from TimelineModeContent)');
    process.exit(1);
}
// Must also reference unpositionedGenerationsCount in a conditional (not just as a prop)
if (!(/unpositionedGenerationsCount\s*[>!=]/.test(noComments) || /unpositionedGenerationsCount\s*&&/.test(noComments))) {
    console.error('FAIL: unpositionedGenerationsCount not used in a conditional in ShotImagesEditor.tsx');
    console.error('  (Should have something like: unpositionedGenerationsCount > 0 && ...)');
    process.exit(1);
}
console.log('PASS: Unpositioned generations div properly inlined into ShotImagesEditor.tsx');
process.exit(0);
" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: Unpositioned generations div not properly inlined into ShotImagesEditor.tsx"
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# Test 5 (Silver): hookData prop removed from Timeline.tsx interface (2/12)
###############################################################################
echo ""
echo "=== Test 5/8: Dead hookData prop removed from Timeline.tsx ==="
if [ -f "$TIMELINE" ]; then
    # Check interface definition for hookData: / hookData?:
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
// Check for hookData in interface/props definition (not in comments)
const lines = src.split('\n');
const interfaceLines = [];
let inInterface = false;
for (const line of lines) {
    if (line.match(/interface\s+TimelineProps/)) inInterface = true;
    if (inInterface) {
        interfaceLines.push(line);
        if (line.match(/^\s*\}/) && interfaceLines.length > 1) break;
    }
}
const interfaceText = interfaceLines.join('\n');
if (interfaceText.includes('hookData')) {
    console.error('FAIL: hookData still in TimelineProps interface');
    process.exit(1);
}
if (src.includes('propHookData')) {
    console.error('FAIL: propHookData still in Timeline.tsx body');
    process.exit(1);
}
console.log('PASS: hookData/propHookData removed from Timeline.tsx');
process.exit(0);
" 2>/dev/null; then
        PASS=$((PASS + 2))  # worth 2 points — dead prop cleanup
    elif ! grep -qE "hookData\s*[?:]" "$TIMELINE" 2>/dev/null && ! grep -q "propHookData" "$TIMELINE" 2>/dev/null; then
        echo "PASS: hookData/propHookData not found in Timeline.tsx (grep fallback)"
        PASS=$((PASS + 2))
    else
        echo "FAIL: hookData or propHookData still present in Timeline.tsx"
        grep -n "hookData\|propHookData" "$TIMELINE" | head -5
    fi
else
    echo "FAIL: Timeline.tsx not found"
fi

###############################################################################
# Test 6 (Silver): enhancedPrompts and EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx (2/12)
###############################################################################
echo ""
echo "=== Test 6/8: Dead enhancedPrompts prop and constant removed from Timeline.tsx ==="
if [ -f "$TIMELINE" ]; then
    HAS_ENHANCED=$(grep -c "EMPTY_ENHANCED_PROMPTS" "$TIMELINE" 2>/dev/null || echo 0)
    # Check if enhancedPrompts is still in the interface (not just passed as JSX prop to TimelineContainer)
    HAS_ENHANCED_PROP=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const lines = src.split('\n');
let inInterface = false;
let interfaceText = '';
for (const line of lines) {
    if (line.match(/interface\s+TimelineProps/)) inInterface = true;
    if (inInterface) {
        interfaceText += line + '\n';
        if (line.match(/^\s*\}/) && interfaceText.length > 10) break;
    }
}
process.stdout.write(interfaceText.includes('enhancedPrompts') ? '1' : '0');
" 2>/dev/null || grep -c "enhancedPrompts\s*[?:]" "$TIMELINE")

    if [ "$HAS_ENHANCED" -eq 0 ] && [ "${HAS_ENHANCED_PROP:-0}" = "0" ]; then
        echo "PASS: EMPTY_ENHANCED_PROMPTS and enhancedPrompts prop removed from Timeline.tsx"
        PASS=$((PASS + 2))  # worth 2 points — dead prop cleanup
    else
        if [ "$HAS_ENHANCED" -gt 0 ]; then
            echo "FAIL: EMPTY_ENHANCED_PROMPTS constant still present in Timeline.tsx"
        fi
        if [ "${HAS_ENHANCED_PROP:-0}" != "0" ]; then
            echo "FAIL: enhancedPrompts still in TimelineProps interface"
        fi
        grep -n "EMPTY_ENHANCED_PROMPTS\|enhancedPrompts" "$TIMELINE" | head -5
    fi
else
    echo "FAIL: Timeline.tsx not found"
fi

###############################################################################
# Test 7 (Silver): enhancedPrompts removed from TimelineContainer (2/12)
# Upgraded: uses node to strip comments before checking, preventing comment-injection gaming
###############################################################################
echo ""
echo "=== Test 7/8: enhancedPrompts removed from TimelineContainer ==="
if node -e "
const fs = require('fs');
function stripComments(s) {
    return s.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
}
// Check types.ts
const typesPath = '$TIMELINE_CONTAINER_TYPES';
if (fs.existsSync(typesPath)) {
    const types = stripComments(fs.readFileSync(typesPath, 'utf8'));
    if (types.includes('enhancedPrompts')) {
        console.error('FAIL: enhancedPrompts still in TimelineContainer/types.ts (actual code, not comments)');
        process.exit(1);
    }
}
// Check TimelineContainer.tsx
const containerPath = '$TIMELINE_CONTAINER';
if (fs.existsSync(containerPath)) {
    const container = stripComments(fs.readFileSync(containerPath, 'utf8'));
    if (container.includes('enhancedPromptFromProps')) {
        console.error('FAIL: enhancedPromptFromProps still in TimelineContainer.tsx (actual code, not comments)');
        process.exit(1);
    }
}
console.log('PASS: enhancedPrompts/enhancedPromptFromProps removed from TimelineContainer (comment-stripped check)');
process.exit(0);
" 2>/dev/null; then
    PASS=$((PASS + 2))  # worth 2 points — dead prop cleanup
else
    echo "FAIL: enhancedPrompts/enhancedPromptFromProps still in TimelineContainer"
fi

###############################################################################
# Test 8 (Gold): TypeScript compilation passes (0.20) — primary behavioral gate
###############################################################################
echo ""
echo "=== Test 8/8: TypeScript compilation (npx tsc --noEmit) ==="
if command -v npx &>/dev/null && [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
    cd "$REPO"
    TSC_OUT=$(npx tsc --noEmit 2>&1)
    TSC_EXIT=$?
    if [ "$TSC_EXIT" -eq 0 ]; then
        echo "PASS: TypeScript compilation succeeds with zero errors"
        PASS=$((PASS + 2))  # worth 2 points — strongest behavioral check for refactoring tasks
    else
        ERROR_COUNT=$(echo "$TSC_OUT" | grep -c "error TS" || echo "?")
        echo "FAIL: TypeScript compilation failed ($ERROR_COUNT errors)"
        echo "$TSC_OUT" | head -20
    fi
else
    echo "SKIP: node_modules not available — skipping TypeScript check"
    echo "  (install node_modules with 'npm ci' to enable this check)"
fi

###############################################################################
# Results
###############################################################################
echo ""
echo "================================"
echo "Results: $PASS / $TOTAL passed"
echo "================================"

REWARD=$(python3 -c "print(round(min(1.0, $PASS / $TOTAL), 2))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
