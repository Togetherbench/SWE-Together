#!/usr/bin/env bash
#
# Verification tests for reigh TimelineModeContent refactor.
#
# 16 tests, 100 points total -> reward = PASS/100
#
#   P2P        ( 5%):  T5       (5 pts)   -- tsc must pass (baseline & post-refactor)
#   Structural (10%):  T1-T4    (2+2+3+3 = 10 pts)
#   Behavioral (85%):  T6-T16   (6+6+8+7+7+10+10+8+3+5+3+5+5 = 85 pts)
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
# Pre-check: Extract <Timeline> JSX props from ShotImagesEditor (used by T6-T16)
###############################################################################

TIMELINE_PROPS=""
TIMELINE_PROP_VALUES=""
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
    PROP_COUNT=$(echo "$TIMELINE_PROPS" | grep -c .)
    echo "Extracted $PROP_COUNT Timeline props from ShotImagesEditor"

    # Also extract prop name=value pairs for value checks
    TIMELINE_PROP_VALUES=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
function visit(node) {
    if ((ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
        ts.isIdentifier(node.tagName) && node.tagName.escapedText === 'Timeline') {
        for (const attr of node.attributes.properties) {
            if (ts.isJsxAttribute(attr) && ts.isIdentifier(attr.name)) {
                const name = attr.name.escapedText;
                let value = '';
                if (attr.initializer) {
                    if (ts.isJsxExpression(attr.initializer) && attr.initializer.expression) {
                        value = attr.initializer.expression.getText(sf);
                    } else if (ts.isStringLiteral(attr.initializer)) {
                        value = attr.initializer.text;
                    }
                }
                console.log(name + '=' + value);
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
" 2>/dev/null)
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
# T3 (3 pts, structural): No file in src/ imports/exports/uses TimelineModeContent
###############################################################################

echo ""
echo "=== T3: No TMC code references in codebase (3 pts) ==="
TMC_REFS=$(grep -rlE "(import|export)\b.*TimelineModeContent|<\/?TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null | head -5)
if [ -z "$TMC_REFS" ]; then
    echo "PASS"
    PASS=$((PASS + 3))
else
    echo "FAIL: code references found in:"
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
# T5 (5 pts, P2P): tsc --noEmit passes
###############################################################################

echo ""
echo "=== T5: TSC compilation passes (5 pts, P2P) ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    echo "PASS"
    PASS=$((PASS + 5))
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
# T6 (6 pts, behavioral): frameSpacing prop (renamed from batchVideoFrames)
###############################################################################

check_prop "frameSpacing" 6 "T6: frameSpacing prop"

###############################################################################
# T7 (6 pts, behavioral): onTimelineChange prop (renamed from handleTimelineChange)
###############################################################################

check_prop "onTimelineChange" 6 "T7: onTimelineChange prop"

###############################################################################
# T8 (8 pts, behavioral): onSegmentFrameCountChange prop (renamed from updatePairFrameCount)
###############################################################################

check_prop "onSegmentFrameCountChange" 8 "T8: onSegmentFrameCountChange prop"

###############################################################################
# T9 (7 pts, behavioral): onClearEnhancedPrompt (4) + onDragStateChange (3)
###############################################################################

echo ""
echo "=== T9: onClearEnhancedPrompt + onDragStateChange (7 pts) ==="
T9=0
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onClearEnhancedPrompt$"; then
        echo "  +4: onClearEnhancedPrompt found"
        T9=$((T9 + 4))
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
echo "  $T9/7 pts"
PASS=$((PASS + T9))

###############################################################################
# T10 (7 pts, behavioral): onPairClick (4) + onRegisterTrailingUpdater (3)
###############################################################################

echo ""
echo "=== T10: onPairClick + onRegisterTrailingUpdater (7 pts) ==="
T10=0
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onPairClick$"; then
        echo "  +4: onPairClick found"
        T10=$((T10 + 4))
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
echo "  $T10/7 pts"
PASS=$((PASS + T10))

###############################################################################
# T11 (10 pts, behavioral): Unpositioned generations div inlined into ShotImagesEditor
###############################################################################

echo ""
echo "=== T11: Unpositioned div inlined (10 pts) ==="
T11=0
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$SHOT_EDITOR" ]; then
    # Sub-check a (4 pts): "unpositioned generation" text literal
    if grep -q 'unpositioned generation' "$SHOT_EDITOR"; then
        echo "  +4: 'unpositioned generation' text found"
        T11=$((T11 + 4))
    else
        echo "  -0: 'unpositioned generation' text not found"
    fi

    # Sub-check b (3 pts): Conditional rendering on count
    if grep -qE 'unpositionedGenerationsCount\s*(>|&&|!==|\?)' "$SHOT_EDITOR"; then
        echo "  +3: conditional rendering on count"
        T11=$((T11 + 3))
    else
        echo "  -0: no conditional rendering on count"
    fi

    # Sub-check c (3 pts): "View & Position" or "View" button text
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
# T12 (10 pts, behavioral): hookData + pairPrompts removed from Timeline.tsx
#   These are dead props that were only passed from TimelineModeContent.
#   After deleting TMC, they serve no purpose in Timeline's interface.
###############################################################################

echo ""
echo "=== T12: hookData + pairPrompts cleanup (10 pts) ==="
T12=0
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$TIMELINE" ]; then
    # Sub-check a (5 pts): hookData removed from interface
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
        echo "  +5: hookData removed from Timeline interface"
        T12=$((T12 + 5))
    else
        echo "  -0: hookData still in Timeline interface"
    fi

    # Sub-check b (5 pts): pairPrompts removed from interface
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
        echo "  +5: pairPrompts removed from Timeline interface"
        T12=$((T12 + 5))
    else
        echo "  -0: pairPrompts still in Timeline interface"
    fi
else
    echo "FAIL: tsc did not pass or Timeline.tsx not found"
fi
echo "  $T12/10 pts"
PASS=$((PASS + T12))

###############################################################################
# T13 (8 pts, behavioral): enhancedPrompts + EMPTY_ENHANCED_PROMPTS removed
#   Checks Timeline.tsx (const + interface) and TimelineContainer (types + usage)
###############################################################################

echo ""
echo "=== T13: enhancedPrompts + EMPTY_ENHANCED_PROMPTS cleanup (8 pts) ==="
T13=0
if [ "$TSC_PASSED" -eq 1 ]; then
    # Sub-check a (3 pts): EMPTY_ENHANCED_PROMPTS const removed from Timeline.tsx
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
            echo "  +3: EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx"
            T13=$((T13 + 3))
        else
            echo "  -0: EMPTY_ENHANCED_PROMPTS still in Timeline.tsx"
        fi
    fi

    # Sub-check b (3 pts): enhancedPrompts removed from Timeline.tsx interface
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
            echo "  +3: enhancedPrompts removed from Timeline.tsx interface"
            T13=$((T13 + 3))
        else
            echo "  -0: enhancedPrompts still in Timeline.tsx interface"
        fi
    fi

    # Sub-check c (2 pts): enhancedPrompts + enhancedPromptFromProps from TimelineContainer
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
        echo "  +2: TimelineContainer cleaned of enhancedPrompts"
        T13=$((T13 + 2))
    fi
else
    echo "FAIL: tsc did not pass"
fi
echo "  $T13/8 pts"
PASS=$((PASS + T13))

###############################################################################
# T14 (3 pts, behavioral): onOpenSegmentSlot adapter present on <Timeline>
###############################################################################

echo ""
echo "=== T14: onOpenSegmentSlot adapter (3 pts) ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onOpenSegmentSlot$"; then
        echo "PASS: onOpenSegmentSlot found on <Timeline>"
        PASS=$((PASS + 3))
    else
        echo "FAIL: onOpenSegmentSlot not found -- TMC's inline adapter not migrated"
    fi
else
    echo "FAIL: tsc did not pass"
fi

###############################################################################
# T15 (5 pts, behavioral): Changes applied (committed OR uncommitted)
#   In single-turn mode, agents may not commit. Credit for the work done.
###############################################################################

echo ""
echo "=== T15: Changes applied (5 pts) ==="
cd "$REPO"
T15_PASS=0
FIRST_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null)
if [ -n "$FIRST_COMMIT" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$FIRST_COMMIT" ]; then
    DIFF_FILES=$(git diff "$FIRST_COMMIT" HEAD --name-only 2>/dev/null)
    if echo "$DIFF_FILES" | grep -q 'ShotImagesEditor'; then
        echo "PASS: ShotImagesEditor changes committed"
        T15_PASS=1
    fi
fi
if [ "$T15_PASS" -eq 0 ]; then
    # Check for uncommitted changes as fallback (single-turn agents may not commit)
    UNCOMMITTED=$(git diff --name-only 2>/dev/null)
    if echo "$UNCOMMITTED" | grep -q 'ShotImagesEditor'; then
        echo "PASS: ShotImagesEditor modified (uncommitted)"
        T15_PASS=1
    fi
fi
if [ "$T15_PASS" -eq 1 ]; then
    PASS=$((PASS + 5))
else
    echo "FAIL: no changes detected"
fi

###############################################################################
# T16 (3 pts, behavioral): allGenerations + shotGenerations props present
###############################################################################

echo ""
echo "=== T16: allGenerations + shotGenerations mapping (3 pts) ==="
T16=0
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^allGenerations$"; then
        echo "  +2: allGenerations found on <Timeline>"
        T16=$((T16 + 2))
    else
        echo "  -0: allGenerations not found -- preloadedImages not forwarded"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^shotGenerations$"; then
        echo "  +1: shotGenerations found on <Timeline>"
        T16=$((T16 + 1))
    else
        echo "  -0: shotGenerations not found -- memoizedShotGenerations not forwarded"
    fi
else
    echo "FAIL: tsc did not pass"
fi
echo "  $T16/3 pts"
PASS=$((PASS + T16))

###############################################################################
# T17 (5 pts, behavioral): Prop value correctness -- verify specific mappings
#   Checks that renamed props receive the correct value expressions, not just
#   that the prop name exists. Uses AST to inspect the value side of each JSX
#   attribute assignment.
###############################################################################

echo ""
echo "=== T17: Prop value correctness (6 pts) ==="
T17=0
if [ "$TSC_PASSED" -eq 1 ] && [ -n "$TIMELINE_PROP_VALUES" ]; then
    # Check frameSpacing=batchVideoFrames (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^frameSpacing=batchVideoFrames$'; then
        echo "  +2: frameSpacing correctly maps to batchVideoFrames"
        T17=$((T17 + 2))
    else
        echo "  -0: frameSpacing value incorrect"
    fi

    # Check onSegmentFrameCountChange=updatePairFrameCount (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onSegmentFrameCountChange=updatePairFrameCount$'; then
        echo "  +2: onSegmentFrameCountChange correctly maps to updatePairFrameCount"
        T17=$((T17 + 2))
    else
        echo "  -0: onSegmentFrameCountChange value incorrect"
    fi

    # Check onRegisterTrailingUpdater=registerTrailingUpdater (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onRegisterTrailingUpdater=registerTrailingUpdater$'; then
        echo "  +2: onRegisterTrailingUpdater correctly maps to registerTrailingUpdater"
        T17=$((T17 + 2))
    else
        echo "  -0: onRegisterTrailingUpdater value incorrect"
    fi
else
    echo "FAIL: tsc did not pass or prop values not extracted"
fi
echo "  $T17/6 pts"
PASS=$((PASS + T17))

###############################################################################
# T18 (5 pts, behavioral): Conditional adapter patterns preserved
#   ShotImagesEditor passes onAddToShot/onAddToShotWithoutPosition/onCreateShot
#   through conditional adapters: e.g. onAddToShot ? handleAddToShotAdapter : undefined
#   After TMC elimination, these conditionals must be preserved on <Timeline>.
###############################################################################

echo ""
echo "=== T18: Conditional adapter patterns (6 pts) ==="
T18=0
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$SHOT_EDITOR" ]; then
    # Check for conditional adapter pattern on onAddToShot (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onAddToShot=.*handleAddToShotAdapter.*undefined'; then
        echo "  +2: onAddToShot conditional adapter preserved"
        T18=$((T18 + 2))
    else
        echo "  -0: onAddToShot conditional adapter not found"
    fi

    # Check for conditional adapter pattern on onCreateShot (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onCreateShot=.*handleCreateShotAdapter.*undefined'; then
        echo "  +2: onCreateShot conditional adapter preserved"
        T18=$((T18 + 2))
    else
        echo "  -0: onCreateShot conditional adapter not found"
    fi

    # Check for conditional adapter pattern on onAddToShotWithoutPosition (2 pts)
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onAddToShotWithoutPosition=.*handleAddToShotWithoutPositionAdapter.*undefined'; then
        echo "  +2: onAddToShotWithoutPosition conditional adapter preserved"
        T18=$((T18 + 2))
    else
        echo "  -0: onAddToShotWithoutPosition conditional adapter not found"
    fi
else
    echo "FAIL: tsc did not pass or ShotImagesEditor not found"
fi
echo "  $T18/6 pts"
PASS=$((PASS + T18))

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
