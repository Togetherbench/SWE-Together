#!/bin/bash
#
# Verification tests for reigh TimelineModeContent refactor.
#
# Nop score: 0.05 (only P2P tsc gate passes on unmodified base)
#
# Gate classification (F2P = fail-to-pass, P2P = pass-to-pass):
#   P2P : T5 (0.05)  -- tsc passes on unmodified base AND after correct fix
#   F2P : T1-T4, T6-T20 -- all require agent changes to pass
#
# Execution gates (>50% weight):
#   T5        : npx tsc --noEmit (compilation gate)
#   T6-T14,T16-T19 : node -e TypeScript AST parsing (gated on T5 tsc pass)
#
# Total weights sum to ~1.0; reward = min(1.0, accumulated)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null
chmod 777 "$(dirname "$REWARD_FILE")" 2>/dev/null

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

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
# Pre-check: Extract <Timeline> JSX props from ShotImagesEditor (used by T6-T18)
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
# T1 (0.02, F2P, structural): TimelineModeContent.tsx deleted
###############################################################################

echo ""
echo "=== T1: TimelineModeContent.tsx deleted ==="
if [ ! -f "$TMC" ]; then
    echo "PASS"
    add_reward 0.02
else
    echo "FAIL: file still exists"
fi

###############################################################################
# T2 (0.02, F2P, structural): Barrel file cleaned of TMC exports
###############################################################################

echo ""
echo "=== T2: Barrel file cleaned ==="
if [ ! -f "$BARREL" ]; then
    echo "PASS: barrel deleted (acceptable)"
    add_reward 0.02
elif ! grep -q 'TimelineModeContent' "$BARREL"; then
    echo "PASS: no TMC references in barrel"
    add_reward 0.02
else
    echo "FAIL: barrel still references TimelineModeContent"
fi

###############################################################################
# T3 (0.03, F2P, structural): No file in src/ imports/exports/uses TMC
###############################################################################

echo ""
echo "=== T3: No TMC code references in codebase ==="
TMC_REFS=$(grep -rlE "(import|export)\b.*TimelineModeContent|<\/?TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null | head -5)
if [ -z "$TMC_REFS" ]; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL: code references found in:"
    echo "$TMC_REFS"
fi

###############################################################################
# T4 (0.03, F2P, structural): ShotImagesEditor renders <Timeline>
###############################################################################

echo ""
echo "=== T4: ShotImagesEditor JSX structure ==="
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
        add_reward 0.03
    fi
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# T5 (0.05, P2P): tsc --noEmit passes
###############################################################################

echo ""
echo "=== T5: TSC compilation passes (P2P) ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    echo "PASS"
    add_reward 0.05
else
    echo "FAIL: TypeScript compilation did not pass"
fi

###############################################################################
# T6 (0.06, F2P, behavioral): frameSpacing prop (renamed from batchVideoFrames)
###############################################################################

echo ""
echo "=== T6: frameSpacing prop ==="
if [ "$TSC_PASSED" -eq 1 ] && echo "$TIMELINE_PROPS" | grep -q "^frameSpacing$"; then
    echo "PASS: frameSpacing found on <Timeline>"
    add_reward 0.06
else
    echo "FAIL: frameSpacing not found (tsc=$TSC_PASSED)"
fi

###############################################################################
# T7 (0.06, F2P, behavioral): onTimelineChange prop
###############################################################################

echo ""
echo "=== T7: onTimelineChange prop ==="
if [ "$TSC_PASSED" -eq 1 ] && echo "$TIMELINE_PROPS" | grep -q "^onTimelineChange$"; then
    echo "PASS: onTimelineChange found on <Timeline>"
    add_reward 0.06
else
    echo "FAIL: onTimelineChange not found (tsc=$TSC_PASSED)"
fi

###############################################################################
# T8 (0.08, F2P, behavioral): onSegmentFrameCountChange prop
###############################################################################

echo ""
echo "=== T8: onSegmentFrameCountChange prop ==="
if [ "$TSC_PASSED" -eq 1 ] && echo "$TIMELINE_PROPS" | grep -q "^onSegmentFrameCountChange$"; then
    echo "PASS: onSegmentFrameCountChange found on <Timeline>"
    add_reward 0.08
else
    echo "FAIL: onSegmentFrameCountChange not found (tsc=$TSC_PASSED)"
fi

###############################################################################
# T9 (0.07, F2P, behavioral): onClearEnhancedPrompt (0.04) + onDragStateChange (0.03)
###############################################################################

echo ""
echo "=== T9: onClearEnhancedPrompt + onDragStateChange ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onClearEnhancedPrompt$"; then
        echo "  PASS: onClearEnhancedPrompt found"
        add_reward 0.04
    else
        echo "  FAIL: onClearEnhancedPrompt not found"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^onDragStateChange$"; then
        echo "  PASS: onDragStateChange found"
        add_reward 0.03
    else
        echo "  FAIL: onDragStateChange not found"
    fi
else
    echo "FAIL: tsc did not pass"
fi

###############################################################################
# T10 (0.07, F2P, behavioral): onPairClick (0.04) + onRegisterTrailingUpdater (0.03)
###############################################################################

echo ""
echo "=== T10: onPairClick + onRegisterTrailingUpdater ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^onPairClick$"; then
        echo "  PASS: onPairClick found"
        add_reward 0.04
    else
        echo "  FAIL: onPairClick not found"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^onRegisterTrailingUpdater$"; then
        echo "  PASS: onRegisterTrailingUpdater found"
        add_reward 0.03
    else
        echo "  FAIL: onRegisterTrailingUpdater not found"
    fi
else
    echo "FAIL: tsc did not pass"
fi

###############################################################################
# T11 (0.10, F2P, behavioral): Unpositioned div inlined into ShotImagesEditor
###############################################################################

echo ""
echo "=== T11: Unpositioned div inlined ==="
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$SHOT_EDITOR" ]; then
    if grep -q 'unpositioned generation' "$SHOT_EDITOR"; then
        echo "  PASS: 'unpositioned generation' text found"
        add_reward 0.04
    else
        echo "  FAIL: 'unpositioned generation' text not found"
    fi
    if grep -qE 'unpositionedGenerationsCount\s*(>|&&|!==|\?)' "$SHOT_EDITOR"; then
        echo "  PASS: conditional rendering on count"
        add_reward 0.03
    else
        echo "  FAIL: no conditional rendering on count"
    fi
    if grep -qE 'View.*Position' "$SHOT_EDITOR"; then
        echo "  PASS: 'View & Position' text found"
        add_reward 0.03
    else
        echo "  FAIL: 'View & Position' text not found"
    fi
else
    echo "FAIL: tsc did not pass or ShotImagesEditor not found"
fi

###############################################################################
# T12 (0.10, F2P, behavioral): hookData + pairPrompts removed from Timeline.tsx
#   Dead props only passed from TimelineModeContent. After deleting TMC, dead.
###############################################################################

echo ""
echo "=== T12: hookData + pairPrompts cleanup ==="
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$TIMELINE" ]; then
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
        echo "  PASS: hookData removed from Timeline interface"
        add_reward 0.05
    else
        echo "  FAIL: hookData still in Timeline interface"
    fi

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
        echo "  PASS: pairPrompts removed from Timeline interface"
        add_reward 0.05
    else
        echo "  FAIL: pairPrompts still in Timeline interface"
    fi
else
    echo "FAIL: tsc did not pass or Timeline.tsx not found"
fi

###############################################################################
# T13 (0.08, F2P, behavioral): enhancedPrompts + EMPTY_ENHANCED_PROMPTS removed
#   Timeline.tsx (const + interface) and TimelineContainer (types + usage)
###############################################################################

echo ""
echo "=== T13: enhancedPrompts + EMPTY_ENHANCED_PROMPTS cleanup ==="
if [ "$TSC_PASSED" -eq 1 ]; then
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
            echo "  PASS: EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx"
            add_reward 0.03
        else
            echo "  FAIL: EMPTY_ENHANCED_PROMPTS still in Timeline.tsx"
        fi
    fi

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
            echo "  PASS: enhancedPrompts removed from Timeline.tsx interface"
            add_reward 0.03
        else
            echo "  FAIL: enhancedPrompts still in Timeline.tsx interface"
        fi
    fi

    TC_CLEAN=1
    if [ -f "$TC_TYPES" ] && grep -q 'enhancedPrompts' "$TC_TYPES" 2>/dev/null; then
        echo "  FAIL: enhancedPrompts still in TimelineContainer types"
        TC_CLEAN=0
    fi
    if [ -f "$TC" ] && grep -q 'enhancedPromptFromProps' "$TC" 2>/dev/null; then
        echo "  FAIL: enhancedPromptFromProps still in TimelineContainer.tsx"
        TC_CLEAN=0
    fi
    if [ "$TC_CLEAN" -eq 1 ]; then
        echo "  PASS: TimelineContainer cleaned of enhancedPrompts"
        add_reward 0.02
    fi
else
    echo "FAIL: tsc did not pass"
fi

###############################################################################
# T14 (0.03, F2P, behavioral): onOpenSegmentSlot adapter present on <Timeline>
###############################################################################

echo ""
echo "=== T14: onOpenSegmentSlot adapter ==="
if [ "$TSC_PASSED" -eq 1 ] && echo "$TIMELINE_PROPS" | grep -q "^onOpenSegmentSlot$"; then
    echo "PASS: onOpenSegmentSlot found on <Timeline>"
    add_reward 0.03
else
    echo "FAIL: onOpenSegmentSlot not found (tsc=$TSC_PASSED)"
fi

###############################################################################
# T15 (0.05, F2P): Changes applied (committed OR uncommitted)
###############################################################################

echo ""
echo "=== T15: Changes applied ==="
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
    UNCOMMITTED=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
    if echo "$UNCOMMITTED" | grep -q 'ShotImagesEditor'; then
        echo "PASS: ShotImagesEditor modified (uncommitted)"
        T15_PASS=1
    fi
fi
if [ "$T15_PASS" -eq 1 ]; then
    add_reward 0.05
else
    echo "FAIL: no changes detected"
fi

###############################################################################
# T16 (0.03, F2P, behavioral): allGenerations + shotGenerations props
###############################################################################

echo ""
echo "=== T16: allGenerations + shotGenerations mapping ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    if echo "$TIMELINE_PROPS" | grep -q "^allGenerations$"; then
        echo "  PASS: allGenerations found on <Timeline>"
        add_reward 0.02
    else
        echo "  FAIL: allGenerations not found"
    fi
    if echo "$TIMELINE_PROPS" | grep -q "^shotGenerations$"; then
        echo "  PASS: shotGenerations found on <Timeline>"
        add_reward 0.01
    else
        echo "  FAIL: shotGenerations not found"
    fi
else
    echo "FAIL: tsc did not pass"
fi

###############################################################################
# T17 (0.06, F2P, behavioral): Prop value correctness
###############################################################################

echo ""
echo "=== T17: Prop value correctness ==="
if [ "$TSC_PASSED" -eq 1 ] && [ -n "$TIMELINE_PROP_VALUES" ]; then
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^frameSpacing=batchVideoFrames$'; then
        echo "  PASS: frameSpacing=batchVideoFrames"
        add_reward 0.02
    else
        echo "  FAIL: frameSpacing value incorrect"
    fi
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onSegmentFrameCountChange=updatePairFrameCount$'; then
        echo "  PASS: onSegmentFrameCountChange=updatePairFrameCount"
        add_reward 0.02
    else
        echo "  FAIL: onSegmentFrameCountChange value incorrect"
    fi
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onRegisterTrailingUpdater=registerTrailingUpdater$'; then
        echo "  PASS: onRegisterTrailingUpdater=registerTrailingUpdater"
        add_reward 0.02
    else
        echo "  FAIL: onRegisterTrailingUpdater value incorrect"
    fi
else
    echo "FAIL: tsc did not pass or prop values not extracted"
fi

###############################################################################
# T18 (0.06, F2P, behavioral): Conditional adapter patterns preserved
###############################################################################

echo ""
echo "=== T18: Conditional adapter patterns ==="
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$SHOT_EDITOR" ]; then
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onAddToShot=.*handleAddToShotAdapter.*undefined'; then
        echo "  PASS: onAddToShot conditional adapter preserved"
        add_reward 0.02
    else
        echo "  FAIL: onAddToShot conditional adapter not found"
    fi
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onCreateShot=.*handleCreateShotAdapter.*undefined'; then
        echo "  PASS: onCreateShot conditional adapter preserved"
        add_reward 0.02
    else
        echo "  FAIL: onCreateShot conditional adapter not found"
    fi
    if echo "$TIMELINE_PROP_VALUES" | grep -q '^onAddToShotWithoutPosition=.*handleAddToShotWithoutPositionAdapter.*undefined'; then
        echo "  PASS: onAddToShotWithoutPosition conditional adapter preserved"
        add_reward 0.02
    else
        echo "  FAIL: onAddToShotWithoutPosition conditional adapter not found"
    fi
else
    echo "FAIL: tsc did not pass or ShotImagesEditor not found"
fi

###############################################################################
# T19 (0.02, F2P, behavioral): onImageDuplicate made optional in Timeline.tsx
###############################################################################

echo ""
echo "=== T19: onImageDuplicate optional in Timeline interface ==="
if [ "$TSC_PASSED" -eq 1 ] && [ -f "$TIMELINE" ]; then
    OID_STATUS=$(node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let result = 'ABSENT';
function visit(node) {
    if (ts.isInterfaceDeclaration(node) || ts.isTypeLiteralNode(node)) {
        for (const m of node.members) {
            if (ts.isPropertySignature(m) && m.name && ts.isIdentifier(m.name) &&
                m.name.escapedText === 'onImageDuplicate') {
                result = m.questionToken ? 'OPTIONAL' : 'REQUIRED';
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
console.log(result);
" 2>/dev/null)

    if [ "$OID_STATUS" = "OPTIONAL" ]; then
        echo "  PASS: onImageDuplicate is optional"
        add_reward 0.02
    elif [ "$OID_STATUS" = "ABSENT" ]; then
        echo "  PASS: onImageDuplicate removed entirely (stricter cleanup accepted)"
        add_reward 0.02
    else
        echo "  FAIL: onImageDuplicate still required in Timeline interface"
    fi
else
    echo "FAIL: tsc did not pass or Timeline.tsx not found"
fi

###############################################################################
# T20 (0.03, F2P): Commit exists for Turn 4 "push to github"
###############################################################################

echo ""
echo "=== T20: Commit present for Turn 4 ==="
cd "$REPO"
FIRST_COMMIT_T20=$(git rev-list --max-parents=0 HEAD 2>/dev/null)
HEAD_T20=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$FIRST_COMMIT_T20" ] && [ -n "$HEAD_T20" ] && [ "$HEAD_T20" != "$FIRST_COMMIT_T20" ]; then
    DIFF_FILES_T20=$(git diff "$FIRST_COMMIT_T20" HEAD --name-only 2>/dev/null)
    if echo "$DIFF_FILES_T20" | grep -qE 'ShotImagesEditor|Timeline'; then
        echo "  PASS: commit present with refactor changes"
        add_reward 0.03
    else
        echo "  FAIL: commit exists but does not touch refactor files"
    fi
else
    echo "  FAIL: no commit beyond the base commit"
fi

###############################################################################
# Results
###############################################################################

echo ""
echo "================================"
echo "TSC: $([ $TSC_PASSED -eq 1 ] && echo 'PASS' || echo 'FAIL')"
echo "REWARD: $REWARD"
echo "================================"

echo "$REWARD" > "$REWARD_FILE"
echo "Written to $REWARD_FILE"
