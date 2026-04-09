#!/usr/bin/env bash
#
# Verification tests for reigh TimelineModeContent refactor.
#
# 15 tests, 100 points total → reward = PASS/100
#
#   Structural (10%):  T1-T4   (2+2+3+3 = 10 pts)
#   Behavioral (90%):  T5-T15  (10+7+7+7+6+6+10+15+12+5+5 = 90 pts)
#
# Prop mapping tests (T6-T10) check that ShotImagesEditor passes the
# correctly-renamed props to <Timeline> — each checks a different prop name
# to catch partial or hardcoded solutions.
#
# Gaming analysis (stub scores):
#   No changes:             T5(10)+T14(5)              = 0.15
#   Delete TMC only:        T1(2)+T14(5)               = 0.07
#   Trivial SIE edit+commit: T5(10)+T14(5)+T15(5)      = 0.20
#   All structural hacks:   T1-T4(10)+T14(5)           = 0.15
#   Core refactor only:     10+10+40+10+5+5            = 0.80
#   Core + partial cleanup: 80+15                      = 0.95
#   Full solution:          100                        = 1.00
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=100

REPO="/workspace/reigh"
SRC="$REPO/src"
TMC="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$REPO/src/tools/travel-between-images/components/ShotImagesEditor.tsx"
TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline.tsx"
TC="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/TimelineContainer.tsx"
TC_TYPES="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/types.ts"
TS_MOD="$REPO/node_modules/typescript"

###############################################################################
# Pre-check: Run tsc once (result used by behavioral tests)
###############################################################################

TSC_PASSED=0
echo "=== Pre-check: TypeScript compilation ==="
if [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
    cd "$REPO"
    TSC_OUT=$(npx tsc --noEmit 2>&1)
    if [ $? -eq 0 ]; then
        echo "tsc: PASS"
        TSC_PASSED=1
    else
        echo "tsc: FAIL ($(echo "$TSC_OUT" | grep -c 'error TS') errors)"
        echo "$TSC_OUT" | head -15
    fi
else
    echo "tsc: SKIP (node_modules or tsconfig.json missing)"
fi

###############################################################################
# Pre-check: Extract <Timeline> JSX props from ShotImagesEditor (used by T6-T10)
###############################################################################

TIMELINE_PROPS=""
if [ -f "$SHOT_EDITOR" ] && [ -d "$TS_MOD" ]; then
    TIMELINE_PROPS=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const props = new Set();
function visit(node) {
    if ((ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
        ts.isIdentifier(node.tagName) && node.tagName.escapedText === 'Timeline') {
        for (const attr of node.attributes.properties) {
            if (ts.isJsxAttribute(attr) && ts.isIdentifier(attr.name)) {
                props.add(attr.name.escapedText);
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
for (const p of props) console.log(p);
" 2>/dev/null)
    echo "Extracted $(echo "$TIMELINE_PROPS" | grep -c .) Timeline props from ShotImagesEditor"
fi

###############################################################################
# T1 (2 pts, structural): TimelineModeContent.tsx deleted
###############################################################################

echo ""
echo "=== T1: TimelineModeContent.tsx deleted (2 pts) ==="
if [ ! -f "$TMC" ]; then
    echo "PASS"
    PASS=$((PASS + 2))
else
    echo "FAIL: file still exists"
fi

###############################################################################
# T2 (2 pts, structural): Barrel file cleaned of TMC exports
###############################################################################

echo ""
echo "=== T2: Barrel file cleaned (2 pts) ==="
if [ ! -f "$BARREL" ]; then
    echo "PASS: barrel deleted (acceptable)"
    PASS=$((PASS + 2))
elif ! grep -q 'TimelineModeContent' "$BARREL"; then
    echo "PASS: no TMC references in barrel"
    PASS=$((PASS + 2))
else
    echo "FAIL: barrel still references TimelineModeContent"
fi

###############################################################################
# T3 (3 pts, structural): No file in src/ imports/exports TimelineModeContent
###############################################################################

echo ""
echo "=== T3: No TMC imports in codebase (3 pts) ==="
TMC_REFS=$(grep -rl 'TimelineModeContent' "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null | head -5)
if [ -z "$TMC_REFS" ]; then
    echo "PASS"
    PASS=$((PASS + 3))
else
    echo "FAIL: references found in:"
    echo "$TMC_REFS"
fi

###############################################################################
# T4 (3 pts, structural): ShotImagesEditor renders <Timeline>, not <TimelineModeContent>
###############################################################################

echo ""
echo "=== T4: ShotImagesEditor JSX structure (3 pts) ==="
if [ -f "$SHOT_EDITOR" ]; then
    T4_OK=1
    if grep -q '<TimelineModeContent' "$SHOT_EDITOR"; then
        echo "  FAIL: <TimelineModeContent> JSX still present"
        T4_OK=0
    fi
    if ! grep -q '<Timeline' "$SHOT_EDITOR"; then
        echo "  FAIL: <Timeline> not found"
        T4_OK=0
    fi
    if [ "$T4_OK" -eq 1 ]; then
        echo "PASS"
        PASS=$((PASS + 3))
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# T5 (10 pts, behavioral): tsc --noEmit passes
###############################################################################

echo ""
echo "=== T5: TSC compilation passes (10 pts) ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    echo "PASS"
    PASS=$((PASS + 10))
else
    echo "FAIL: TypeScript compilation did not pass"
fi

###############################################################################
# Helper: check a single renamed prop on <Timeline> (requires TSC pass)
###############################################################################

check_prop() {
    local PROP_NAME="$1"
    local POINTS="$2"
    local LABEL="$3"

    echo ""
    echo "=== $LABEL ($POINTS pts) ==="

    if [ "$TSC_PASSED" -eq 0 ]; then
        echo "FAIL: tsc did not pass"
        return
    fi

    if echo "$TIMELINE_PROPS" | grep -q "^${PROP_NAME}$"; then
        echo "PASS: $PROP_NAME found on <Timeline>"
        PASS=$((PASS + POINTS))
    else
        echo "FAIL: $PROP_NAME not found as named attribute on <Timeline>"
    fi
}

###############################################################################
# T6 (7 pts, behavioral): frameSpacing prop (renamed from batchVideoFrames)
###############################################################################

check_prop "frameSpacing" 7 "T6: frameSpacing prop"

###############################################################################
# T7 (7 pts, behavioral): onTimelineChange prop (renamed from handleTimelineChange)
###############################################################################

check_prop "onTimelineChange" 7 "T7: onTimelineChange prop"

###############################################################################
# T8 (7 pts, behavioral): onSegmentFrameCountChange prop (renamed from updatePairFrameCount)
###############################################################################

check_prop "onSegmentFrameCountChange" 7 "T8: onSegmentFrameCountChange prop"

###############################################################################
# T9 (6 pts, behavioral): onClearEnhancedPrompt + onDragStateChange (3 pts each)
###############################################################################

echo ""
echo "=== T9: onClearEnhancedPrompt + onDragStateChange (6 pts) ==="
T9=0
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onClearEnhancedPrompt$"; then
        echo "  +3: onClearEnhancedPrompt found"
        T9=$((T9 + 3))
    else
        echo "  -0: onClearEnhancedPrompt not found"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^onDragStateChange$"; then
        echo "  +3: onDragStateChange found"
        T9=$((T9 + 3))
    else
        echo "  -0: onDragStateChange not found"
    fi
else
    echo "FAIL: tsc did not pass"
fi
echo "  $T9/6 pts"
PASS=$((PASS + T9))

###############################################################################
# T10 (6 pts, behavioral): onPairClick + onRegisterTrailingUpdater (3 pts each)
###############################################################################

echo ""
echo "=== T10: onPairClick + onRegisterTrailingUpdater (6 pts) ==="
T10=0
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onPairClick$"; then
        echo "  +3: onPairClick found"
        T10=$((T10 + 3))
    else
        echo "  -0: onPairClick not found"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^onRegisterTrailingUpdater$"; then
        echo "  +3: onRegisterTrailingUpdater found"
        T10=$((T10 + 3))
    else
        echo "  -0: onRegisterTrailingUpdater not found"
    fi
else
    echo "FAIL: tsc did not pass"
fi
echo "  $T10/6 pts"
PASS=$((PASS + T10))

###############################################################################
# T11 (10 pts, behavioral): Unpositioned generations div inlined into ShotImagesEditor
#   Sub-checks target content that only exists in TimelineModeContent.tsx
#   at the base commit — NOT in ShotImagesEditor.tsx originally.
###############################################################################

echo ""
echo "=== T11: Unpositioned div inlined (10 pts) ==="
T11=0
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$SHOT_EDITOR" ]; then
    # Sub-check a (4 pts): "unpositioned generation" text literal
    # At base commit this text is ONLY in TimelineModeContent.tsx, not ShotImagesEditor
    if grep -q 'unpositioned generation' "$SHOT_EDITOR"; then
        echo "  +4: 'unpositioned generation' text found"
        T11=$((T11 + 4))
    else
        echo "  -0: 'unpositioned generation' text not found"
    fi

    # Sub-check b (3 pts): Conditional rendering on count
    # Original ShotImagesEditor only passes count as a prop; the conditional
    # (count > 0, count &&, etc.) is in TimelineModeContent
    if grep -qE 'unpositionedGenerationsCount\s*(>|&&|!==|\?)' "$SHOT_EDITOR"; then
        echo "  +3: conditional rendering on count"
        T11=$((T11 + 3))
    else
        echo "  -0: no conditional rendering on count"
    fi

    # Sub-check c (3 pts): "View & Position" or "View" button text
    # At base commit this text is ONLY in TimelineModeContent.tsx
    if grep -qE 'View.*Position' "$SHOT_EDITOR"; then
        echo "  +3: 'View & Position' text found"
        T11=$((T11 + 3))
    else
        echo "  -0: 'View & Position' text not found"
    fi
else
    echo "FAIL: tsc did not pass or ShotImagesEditor not found"
fi
echo "  $T11/10 pts"
PASS=$((PASS + T11))

###############################################################################
# T12 (15 pts, behavioral): hookData + pairPrompts removed from Timeline.tsx
#   These are dead props that were only passed from TimelineModeContent.
#   After deleting TMC, they serve no purpose in Timeline's interface.
###############################################################################

echo ""
echo "=== T12: hookData + pairPrompts cleanup (15 pts) ==="
T12=0
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$TIMELINE" ]; then
    # Sub-check a (8 pts): hookData removed from interface
    HOOK_FOUND=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let found = false;
function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
        for (const m of node.members) {
            if (ts.isPropertySignature(m) && m.name && ts.isIdentifier(m.name) &&
                (m.name.escapedText === 'hookData' || m.name.escapedText === 'propHookData')) {
                found = true;
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
console.log(found ? 'PRESENT' : 'REMOVED');
" 2>/dev/null)

    if [ "$HOOK_FOUND" = "REMOVED" ]; then
        echo "  +8: hookData removed from Timeline interface"
        T12=$((T12 + 8))
    else
        echo "  -0: hookData still in Timeline interface"
    fi

    # Sub-check b (7 pts): pairPrompts removed from interface
    PAIR_FOUND=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let found = false;
function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
        for (const m of node.members) {
            if (ts.isPropertySignature(m) && m.name && ts.isIdentifier(m.name) &&
                m.name.escapedText === 'pairPrompts') {
                found = true;
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
console.log(found ? 'PRESENT' : 'REMOVED');
" 2>/dev/null)

    if [ "$PAIR_FOUND" = "REMOVED" ]; then
        echo "  +7: pairPrompts removed from Timeline interface"
        T12=$((T12 + 7))
    else
        echo "  -0: pairPrompts still in Timeline interface"
    fi
else
    echo "FAIL: tsc did not pass or Timeline.tsx not found"
fi
echo "  $T12/15 pts"
PASS=$((PASS + T12))

###############################################################################
# T13 (12 pts, behavioral): enhancedPrompts + EMPTY_ENHANCED_PROMPTS removed
#   Checks Timeline.tsx (const + interface) and TimelineContainer (types + usage)
###############################################################################

echo ""
echo "=== T13: enhancedPrompts + EMPTY_ENHANCED_PROMPTS cleanup (12 pts) ==="
T13=0
if [ "$TSC_PASSED" -eq 1 ]; then
    # Sub-check a (4 pts): EMPTY_ENHANCED_PROMPTS const removed from Timeline.tsx
    if [ -f "$TIMELINE" ]; then
        CONST_FOUND=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let found = false;
function visit(node) {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) &&
        node.name.escapedText === 'EMPTY_ENHANCED_PROMPTS') { found = true; }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
console.log(found ? 'PRESENT' : 'REMOVED');
" 2>/dev/null)

        if [ "$CONST_FOUND" = "REMOVED" ]; then
            echo "  +4: EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx"
            T13=$((T13 + 4))
        else
            echo "  -0: EMPTY_ENHANCED_PROMPTS still in Timeline.tsx"
        fi
    fi

    # Sub-check b (4 pts): enhancedPrompts removed from Timeline.tsx interface
    if [ -f "$TIMELINE" ]; then
        EP_FOUND=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let found = false;
function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
        for (const m of node.members) {
            if (ts.isPropertySignature(m) && m.name && ts.isIdentifier(m.name) &&
                m.name.escapedText === 'enhancedPrompts') { found = true; }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
console.log(found ? 'PRESENT' : 'REMOVED');
" 2>/dev/null)

        if [ "$EP_FOUND" = "REMOVED" ]; then
            echo "  +4: enhancedPrompts removed from Timeline.tsx interface"
            T13=$((T13 + 4))
        else
            echo "  -0: enhancedPrompts still in Timeline.tsx interface"
        fi
    fi

    # Sub-check c (4 pts): enhancedPrompts + enhancedPromptFromProps from TimelineContainer
    TC_CLEAN=1
    if [ -f "$TC_TYPES" ] && grep -q 'enhancedPrompts' "$TC_TYPES" 2>/dev/null; then
        echo "  -0: enhancedPrompts still in TimelineContainer types"
        TC_CLEAN=0
    fi
    if [ -f "$TC" ] && grep -q 'enhancedPromptFromProps' "$TC" 2>/dev/null; then
        echo "  -0: enhancedPromptFromProps still in TimelineContainer.tsx"
        TC_CLEAN=0
    fi
    if [ "$TC_CLEAN" -eq 1 ]; then
        echo "  +4: TimelineContainer cleaned of enhancedPrompts"
        T13=$((T13 + 4))
    fi
else
    echo "FAIL: tsc did not pass"
fi
echo "  $T13/12 pts"
PASS=$((PASS + T13))

###############################################################################
# T14 (5 pts, behavioral): Pass-to-Pass upstream vitest tests
###############################################################################

echo ""
echo "=== T14: P2P upstream vitest (5 pts) ==="
cd "$REPO"
if [ -f "$REPO/node_modules/.bin/vitest" ]; then
    VITEST_OUT=$(timeout 60 npx vitest run src/test/supabaseAuth.test.ts src/test/systemLogger.test.ts --reporter=verbose 2>&1)
    VITEST_EXIT=$?
    if [ $VITEST_EXIT -eq 0 ]; then
        echo "PASS: upstream vitest tests pass"
        PASS=$((PASS + 5))
    elif echo "$VITEST_OUT" | grep -qiE "Cannot find module|ERR_MODULE_NOT_FOUND|Error: Failed to collect|Config error|no test file|ENOENT|Cannot read config"; then
        echo "SKIP: vitest infra issue (not agent's fault), awarding P2P"
        PASS=$((PASS + 5))
    else
        echo "FAIL: upstream vitest tests failed"
        echo "$VITEST_OUT" | tail -10
    fi
else
    echo "SKIP: vitest not installed, awarding P2P"
    PASS=$((PASS + 5))
fi

###############################################################################
# T15 (5 pts, behavioral): Changes committed (ShotImagesEditor modified in git)
###############################################################################

echo ""
echo "=== T15: Changes committed (5 pts) ==="
cd "$REPO"
FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null)
if [ -n "$FIRST_COMMIT" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$FIRST_COMMIT" ]; then
    DIFF_FILES=$(git diff "$FIRST_COMMIT" HEAD --name-only 2>/dev/null)
    if echo "$DIFF_FILES" | grep -q 'ShotImagesEditor'; then
        echo "PASS: ShotImagesEditor changes committed"
        PASS=$((PASS + 5))
    else
        echo "FAIL: commits exist but ShotImagesEditor not in diff"
    fi
else
    # Check for uncommitted changes as fallback
    if git diff --name-only 2>/dev/null | grep -q 'ShotImagesEditor'; then
        echo "FAIL: ShotImagesEditor modified but not committed"
    else
        echo "FAIL: no changes detected"
    fi
fi

###############################################################################
# Results
###############################################################################

echo ""
echo "================================"
echo "TSC: $([ $TSC_PASSED -eq 1 ] && echo 'PASS' || echo 'FAIL')"
echo "Results: $PASS / $TOTAL"
echo "================================"

REWARD=$(python3 -c "print(round(min(1.0, $PASS / $TOTAL), 2))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
