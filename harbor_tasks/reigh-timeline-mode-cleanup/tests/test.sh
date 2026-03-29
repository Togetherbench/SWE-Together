#!/usr/bin/env bash
#
# Verification tests for the reigh TimelineModeContent refactor.
#
# Scoring: 20 total points
#   Structural: 7 pts (35%) — tests 1-7
#   Behavioral: 13 pts (65%) — tests 8, 9a, 9b
#
# TSC is split into two gated components:
#   9a (5 pts): tsc passes AND ≥2 core structural tests (1-4) pass
#   9b (5 pts): tsc passes AND ≥2 cleanup structural tests (5-7) pass
# This prevents free tsc credit on unmodified code AND rewards user-sim-driven cleanup.
#
# TSC gate: if tsc fails, reward capped at 0.25 (prevents gaming via mass deletion)
#
# Gaming analysis:
#   Base state (no changes): 0/20 = 0.0 ✓
#   Max stub without tsc: min(0.25, 10/20) = 0.25 ✓
#   Core refactor only (no cleanup): (4+3+5)/20 = 0.60
#   Full solution: 20/20 = 1.0
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=20

REPO="/workspace/reigh"
SRC="$REPO/src"
TMC="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$REPO/src/tools/travel-between-images/components/ShotImagesEditor.tsx"
TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline.tsx"
TC="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/TimelineContainer.tsx"
TC_TYPES="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/types.ts"

TSC_PASSED=0
CORE_PASS=0    # count of tests 1-4 that pass
CLEANUP_PASS=0 # count of tests 5-7 that pass

###############################################################################
# STRUCTURAL — Core Refactoring (4 pts)
###############################################################################

# Test 1 (1 pt): TimelineModeContent.tsx is deleted
echo "=== Test 1/9: TimelineModeContent.tsx deleted ==="
if [ ! -f "$TMC" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
else
    echo "FAIL: TimelineModeContent.tsx still exists"
fi

# Test 2 (1 pt): Barrel file no longer exports TimelineModeContent
echo ""
echo "=== Test 2/9: Barrel file cleaned ==="
if [ ! -f "$BARREL" ]; then
    echo "PASS: Barrel file deleted (acceptable)"
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
elif ! grep -q "TimelineModeContent" "$BARREL" 2>/dev/null; then
    echo "PASS: Barrel no longer exports TimelineModeContent"
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
else
    echo "FAIL: Barrel still exports TimelineModeContent"
    grep "TimelineModeContent" "$BARREL" | head -3
fi

# Test 3 (1 pt): ShotImagesEditor renders <Timeline> not <TimelineModeContent>
# Comment-stripped to prevent comment-injection gaming
echo ""
echo "=== Test 3/9: ShotImagesEditor renders <Timeline> directly ==="
if [ -f "$SHOT_EDITOR" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
if (/<TimelineModeContent[\s\/>]/.test(noComments)) {
    console.error('FAIL: <TimelineModeContent> JSX still in code');
    process.exit(1);
}
if (!/<Timeline[\s\/>]/.test(noComments)) {
    console.error('FAIL: <Timeline> JSX not found in code');
    process.exit(1);
}
console.log('PASS');
" 2>/dev/null; then
        PASS=$((PASS + 1))
        CORE_PASS=$((CORE_PASS + 1))
    else
        echo "FAIL: ShotImagesEditor does not render <Timeline> directly"
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

# Test 4 (1 pt): Unpositioned generations div inlined into ShotImagesEditor
# "unpositioned generation" only existed in TimelineModeContent.tsx at base commit
echo ""
echo "=== Test 4/9: Unpositioned generations div inlined ==="
if [ -f "$SHOT_EDITOR" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
if (!noComments.includes('unpositioned generation')) {
    console.error('FAIL: rendered text not found in ShotImagesEditor');
    process.exit(1);
}
if (!(/unpositionedGenerationsCount\s*[>!=]/.test(noComments) || /unpositionedGenerationsCount\s*&&/.test(noComments))) {
    console.error('FAIL: unpositionedGenerationsCount not used in conditional');
    process.exit(1);
}
console.log('PASS');
" 2>/dev/null; then
        PASS=$((PASS + 1))
        CORE_PASS=$((CORE_PASS + 1))
    else
        echo "FAIL: Unpositioned generations div not properly inlined"
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# STRUCTURAL — Dead Prop Cleanup (3 pts)
###############################################################################

# Test 5 (1 pt): hookData prop removed from Timeline.tsx
echo ""
echo "=== Test 5/9: hookData removed from Timeline.tsx ==="
if [ -f "$TIMELINE" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
if (/hookData\s*[?:]/.test(noComments) || noComments.includes('propHookData')) {
    process.exit(1);
}
console.log('PASS');
" 2>/dev/null; then
        PASS=$((PASS + 1))
        CLEANUP_PASS=$((CLEANUP_PASS + 1))
    else
        echo "FAIL: hookData still present in Timeline.tsx"
    fi
else
    echo "FAIL: Timeline.tsx not found"
fi

# Test 6 (1 pt): enhancedPrompts / EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx
echo ""
echo "=== Test 6/9: enhancedPrompts removed from Timeline.tsx ==="
if [ -f "$TIMELINE" ]; then
    if node -e "
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
if (noComments.includes('EMPTY_ENHANCED_PROMPTS')) {
    console.error('FAIL: EMPTY_ENHANCED_PROMPTS still present');
    process.exit(1);
}
const lines = noComments.split('\n');
let inInterface = false, iText = '';
for (const line of lines) {
    if (line.match(/interface\s+TimelineProps/)) inInterface = true;
    if (inInterface) {
        iText += line + '\n';
        if (line.match(/^\s*\}/) && iText.length > 10) break;
    }
}
if (iText.includes('enhancedPrompts')) {
    console.error('FAIL: enhancedPrompts still in TimelineProps interface');
    process.exit(1);
}
console.log('PASS');
" 2>/dev/null; then
        PASS=$((PASS + 1))
        CLEANUP_PASS=$((CLEANUP_PASS + 1))
    else
        echo "FAIL: enhancedPrompts still in Timeline.tsx"
    fi
else
    echo "FAIL: Timeline.tsx not found"
fi

# Test 7 (1 pt): enhancedPrompts removed from TimelineContainer
echo ""
echo "=== Test 7/9: enhancedPrompts removed from TimelineContainer ==="
if node -e "
const fs = require('fs');
function strip(s) { return s.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, ''); }
if (fs.existsSync('$TC_TYPES')) {
    if (strip(fs.readFileSync('$TC_TYPES', 'utf8')).includes('enhancedPrompts')) {
        console.error('FAIL: enhancedPrompts still in types.ts');
        process.exit(1);
    }
}
if (fs.existsSync('$TC')) {
    if (strip(fs.readFileSync('$TC', 'utf8')).includes('enhancedPromptFromProps')) {
        console.error('FAIL: enhancedPromptFromProps still in TimelineContainer.tsx');
        process.exit(1);
    }
}
console.log('PASS');
" 2>/dev/null; then
    PASS=$((PASS + 1))
    CLEANUP_PASS=$((CLEANUP_PASS + 1))
else
    echo "FAIL: enhancedPrompts still in TimelineContainer"
fi

###############################################################################
# BEHAVIORAL (13 pts)
###############################################################################

# Test 8 (3 pts): No .ts/.tsx file in src/ still imports TimelineModeContent,
# AND ShotImagesEditor has a proper import of Timeline
echo ""
echo "=== Test 8/9: Import graph clean ==="
if node -e "
const { execSync } = require('child_process');
const fs = require('fs');

const files = execSync('find $SRC -name \"*.ts\" -o -name \"*.tsx\"', { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean);

for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    const noComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
    if (/import\s+.*TimelineModeContent/.test(noComments) ||
        /from\s+['\"].*TimelineModeContent/.test(noComments) ||
        /require\s*\(['\"].*TimelineModeContent/.test(noComments)) {
        console.error('FAIL: ' + file + ' still imports TimelineModeContent');
        process.exit(1);
    }
}

// ShotImagesEditor must import Timeline
const editor = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const noComments = editor.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
if (!/(import|from)\s+.*Timeline/m.test(noComments)) {
    console.error('FAIL: ShotImagesEditor does not import Timeline');
    process.exit(1);
}
console.log('PASS: Import graph is clean');
" 2>/dev/null; then
    PASS=$((PASS + 3))
else
    echo "FAIL: Dangling imports or missing Timeline import"
fi

# Test 9 (5+5 pts): TypeScript compilation — split into core and cleanup gates
echo ""
echo "=== Test 9/9: TypeScript compilation (tsc --noEmit) ==="
if command -v npx &>/dev/null && [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
    cd "$REPO"
    TSC_OUT=$(npx tsc --noEmit 2>&1)
    TSC_EXIT=$?
    if [ "$TSC_EXIT" -eq 0 ]; then
        echo "tsc: PASS (zero errors)"
        TSC_PASSED=1

        # 9a (5 pts): tsc passes AND agent did the core refactoring (≥2 of tests 1-4)
        if [ "$CORE_PASS" -ge 2 ]; then
            echo "  9a PASS: tsc + core refactoring verified ($CORE_PASS/4 core tests)"
            PASS=$((PASS + 5))
        else
            echo "  9a FAIL: tsc passes but core refactoring not done ($CORE_PASS/4 core tests)"
        fi

        # 9b (5 pts): tsc passes AND agent did dead prop cleanup (≥2 of tests 5-7)
        if [ "$CLEANUP_PASS" -ge 2 ]; then
            echo "  9b PASS: tsc + dead prop cleanup verified ($CLEANUP_PASS/3 cleanup tests)"
            PASS=$((PASS + 5))
        else
            echo "  9b FAIL: cleanup not done ($CLEANUP_PASS/3 cleanup tests)"
        fi
    else
        ERROR_COUNT=$(echo "$TSC_OUT" | grep -c "error TS" || echo "?")
        echo "FAIL: TypeScript compilation failed ($ERROR_COUNT errors)"
        echo "$TSC_OUT" | head -20
    fi
else
    echo "SKIP: node_modules not available"
fi

###############################################################################
# Results — with TSC gate
###############################################################################
echo ""
echo "================================"
echo "Core structural: $CORE_PASS/4 | Cleanup structural: $CLEANUP_PASS/3"
echo "Results: $PASS / $TOTAL"
echo "================================"

if [ "$TSC_PASSED" -eq 1 ]; then
    REWARD=$(python3 -c "print(round(min(1.0, $PASS / $TOTAL), 2))")
else
    # If tsc fails, the refactor is broken — cap reward.
    UNCAPPED=$(python3 -c "print(round(min(1.0, $PASS / $TOTAL), 2))")
    REWARD=$(python3 -c "print(round(min(0.25, $PASS / $TOTAL), 2))")
    echo "(TSC gate: reward capped at 0.25; uncapped would be $UNCAPPED)"
fi

echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
