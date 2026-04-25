#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null
chmod 777 "$(dirname "$REWARD_FILE")" 2>/dev/null

REWARD=0.0

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

# Detect repo path
REPO=""
for candidate in /workspace/reigh /workspace/repo; do
    if [ -d "$candidate/src/tools/travel-between-images" ]; then
        REPO="$candidate"
        break
    fi
done
if [ -z "$REPO" ]; then
    # Fallback search
    REPO=$(find /workspace -maxdepth 3 -type d -name "travel-between-images" 2>/dev/null | head -1 | sed 's|/src/tools/travel-between-images||')
fi

echo "Using REPO=$REPO"

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot find repo"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

SRC="$REPO/src"
TBI="$REPO/src/tools/travel-between-images/components"
TMC="$TBI/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$TBI/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$TBI/ShotImagesEditor.tsx"
TIMELINE="$TBI/Timeline.tsx"
TC="$TBI/Timeline/TimelineContainer/TimelineContainer.tsx"
TC_TYPES="$TBI/Timeline/TimelineContainer/types.ts"
TS_MOD="$REPO/node_modules/typescript"

###############################################################################
# Pre-check: tsc compilation
###############################################################################
TSC_PASSED=0
TSC_ERR_COUNT=999
echo "=== Pre-check: TypeScript compilation ==="
if [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
    cd "$REPO"
    TSC_OUT=$(npx --no-install tsc --noEmit 2>&1)
    TSC_RC=$?
    TSC_ERR_COUNT=$(echo "$TSC_OUT" | grep -c 'error TS')
    if [ $TSC_RC -eq 0 ]; then
        echo "tsc: PASS"
        TSC_PASSED=1
    else
        echo "tsc: FAIL ($TSC_ERR_COUNT errors)"
        echo "$TSC_OUT" | grep 'error TS' | head -10
    fi
else
    echo "tsc: SKIP"
fi

###############################################################################
# Pre-check: Extract <Timeline> JSX props (using TS AST when available)
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
PROP_COUNT=$(echo "$TIMELINE_PROPS" | grep -c .)
echo "Extracted $PROP_COUNT Timeline props from ShotImagesEditor"

has_prop() {
    echo "$TIMELINE_PROPS" | grep -qx "$1"
}

prop_value() {
    echo "$TIMELINE_PROP_VALUES" | grep "^$1=" | head -1 | sed "s/^$1=//"
}

###############################################################################
# STRUCTURAL TIER (~25%)
###############################################################################

# T1 (0.04): TimelineModeContent.tsx deleted
echo ""
echo "=== T1: TimelineModeContent.tsx deleted ==="
if [ ! -f "$TMC" ]; then
    echo "PASS"
    add_reward 0.04
else
    echo "FAIL"
fi

# T2 (0.03): Barrel cleaned
echo ""
echo "=== T2: Barrel cleaned of TMC exports ==="
if [ ! -f "$BARREL" ]; then
    echo "PASS (barrel deleted)"
    add_reward 0.03
elif ! grep -q 'TimelineModeContent' "$BARREL"; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL"
fi

# T3 (0.03): No TMC references in src/
echo ""
echo "=== T3: No TMC code references in codebase ==="
TMC_REFS=$(grep -rlE "(import|export)[^\n]*TimelineModeContent|<\/?TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null)
if [ -z "$TMC_REFS" ]; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL: refs in:"
    echo "$TMC_REFS"
fi

# T4 (0.04): ShotImagesEditor renders <Timeline>, not <TimelineModeContent>
echo ""
echo "=== T4: ShotImagesEditor uses <Timeline> directly ==="
T4_OK=1
if [ ! -f "$SHOT_EDITOR" ]; then
    echo "FAIL: missing"; T4_OK=0
else
    if grep -q '<TimelineModeContent' "$SHOT_EDITOR"; then
        echo "FAIL: <TimelineModeContent> still present"; T4_OK=0
    fi
    if ! grep -qE '<Timeline[[:space:]>]' "$SHOT_EDITOR"; then
        echo "FAIL: <Timeline> not found"; T4_OK=0
    fi
    if ! grep -qE "import[[:space:]]+Timeline[[:space:]]+from|import[[:space:]]+\{[^}]*Timeline[^}]*\}" "$SHOT_EDITOR"; then
        echo "FAIL: Timeline import missing"; T4_OK=0
    fi
fi
if [ "$T4_OK" -eq 1 ]; then
    echo "PASS"; add_reward 0.04
fi

# T5 (0.03): Unpositioned generations helper inline
echo ""
echo "=== T5: Unpositioned helper inlined in ShotImagesEditor ==="
if [ -f "$SHOT_EDITOR" ] && grep -q 'unpositionedGenerationsCount' "$SHOT_EDITOR" && \
   grep -q 'onOpenUnpositionedPane' "$SHOT_EDITOR" && \
   grep -qE 'View[[:space:]]*&[[:space:]]*Position' "$SHOT_EDITOR"; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL: unpositioned helper not inlined"
fi

###############################################################################
# COMPILATION GATE (P2P) — ~12%
###############################################################################

# T6 (0.12): tsc --noEmit passes (P2P + post-fix)
echo ""
echo "=== T6: TSC compilation passes ==="
if [ "$TSC_PASSED" -eq 1 ]; then
    echo "PASS"
    add_reward 0.12
elif [ "$TSC_ERR_COUNT" -le 3 ] && [ "$TSC_ERR_COUNT" -gt 0 ]; then
    echo "PARTIAL: only $TSC_ERR_COUNT errors"
    add_reward 0.04
else
    echo "FAIL: $TSC_ERR_COUNT tsc errors"
fi

###############################################################################
# BEHAVIORAL TIER — Timeline JSX props (gated on tsc) ~50%
###############################################################################

# Helper to award only if tsc passes (so syntactic-only fixes don't get full credit)
behavior_check() {
    local label="$1"
    local weight="$2"
    local cond="$3"
    echo ""
    echo "=== $label ==="
    if [ "$cond" = "1" ]; then
        if [ "$TSC_PASSED" -eq 1 ]; then
            echo "PASS"
            add_reward "$weight"
        else
            # Partial credit: prop is present but compilation broken
            local partial=$(awk -v w="$weight" 'BEGIN{printf "%.4f", w*0.4}')
            echo "PARTIAL (tsc fail): $partial"
            add_reward "$partial"
        fi
    else
        echo "FAIL"
    fi
}

# T7 (0.04): frameSpacing prop renamed from batchVideoFrames
COND=0
if has_prop "frameSpacing"; then
    val=$(prop_value "frameSpacing")
    if echo "$val" | grep -qE 'batchVideoFrames|frameSpacing'; then
        COND=1
    fi
fi
behavior_check "T7: frameSpacing prop on <Timeline>" 0.04 "$COND"

# T8 (0.04): onTimelineChange prop wired
COND=0
if has_prop "onTimelineChange"; then COND=1; fi
behavior_check "T8: onTimelineChange prop" 0.04 "$COND"

# T9 (0.04): onClearEnhancedPrompt mapped from handleClearEnhancedPromptByIndex
COND=0
if has_prop "onClearEnhancedPrompt"; then
    val=$(prop_value "onClearEnhancedPrompt")
    if echo "$val" | grep -qE 'handleClearEnhancedPromptByIndex|clearEnhancedPrompt'; then
        COND=1
    fi
fi
behavior_check "T9: onClearEnhancedPrompt mapping" 0.04 "$COND"

# T10 (0.04): onDragStateChange mapped from handleDragStateChange
COND=0
if has_prop "onDragStateChange"; then COND=1; fi
behavior_check "T10: onDragStateChange prop" 0.04 "$COND"

# T11 (0.04): onPairClick prop
COND=0
if has_prop "onPairClick"; then COND=1; fi
behavior_check "T11: onPairClick prop" 0.04 "$COND"

# T12 (0.04): onSegmentFrameCountChange mapped from updatePairFrameCount
COND=0
if has_prop "onSegmentFrameCountChange"; then COND=1; fi
behavior_check "T12: onSegmentFrameCountChange prop" 0.04 "$COND"

# T13 (0.04): onRegisterTrailingUpdater mapped from registerTrailingUpdater
COND=0
if has_prop "onRegisterTrailingUpdater"; then COND=1; fi
behavior_check "T13: onRegisterTrailingUpdater prop" 0.04 "$COND"

# T14 (0.04): onAddToShot, onAddToShotWithoutPosition, onCreateShot all present
COND=0
if has_prop "onAddToShot" && has_prop "onAddToShotWithoutPosition" && has_prop "onCreateShot"; then
    COND=1
fi
behavior_check "T14: shot adapter props (onAddToShot/WithoutPosition/onCreateShot)" 0.04 "$COND"

# T15 (0.04): shotId prop = selectedShotId, key uses selectedShotId
COND=0
if has_prop "shotId"; then
    val=$(prop_value "shotId")
    if echo "$val" | grep -q 'selectedShotId'; then
        COND=1
    fi
fi
behavior_check "T15: shotId={selectedShotId}" 0.04 "$COND"

# T16 (0.04): projectId, readOnly props threaded
COND=0
if has_prop "projectId" && has_prop "readOnly"; then COND=1; fi
behavior_check "T16: projectId & readOnly props" 0.04 "$COND"

# T17 (0.04): unpositioned helper props NOT passed to <Timeline>
echo ""
echo "=== T17: unpositionedGenerationsCount/onOpenUnpositionedPane NOT passed to <Timeline> ==="
COND=1
if has_prop "unpositionedGenerationsCount"; then
    echo "FAIL: unpositionedGenerationsCount leaked to <Timeline>"
    COND=0
fi
if has_prop "onOpenUnpositionedPane"; then
    echo "FAIL: onOpenUnpositionedPane leaked to <Timeline>"
    COND=0
fi
if [ "$COND" -eq 1 ]; then
    echo "PASS"
    add_reward 0.04
fi

###############################################################################
# DEAD CODE CLEANUP TIER — Timeline.tsx & TimelineContainer (~13%)
###############################################################################

# T18 (0.04): Timeline.tsx removed `enhancedPrompts` prop (dead code)
echo ""
echo "=== T18: Timeline.tsx dead prop 'enhancedPrompts' removed ==="
COND_T18=0
if [ -f "$TIMELINE" ]; then
    # Should not have `enhancedPrompts?:` in interface anymore
    if ! grep -qE '^\s*enhancedPrompts\?\s*:' "$TIMELINE"; then
        COND_T18=1
    fi
fi
if [ "$COND_T18" -eq 1 ]; then
    if [ "$TSC_PASSED" -eq 1 ]; then
        echo "PASS"; add_reward 0.04
    else
        echo "PARTIAL (tsc fail)"; add_reward 0.015
    fi
else
    echo "FAIL: enhancedPrompts still in Timeline interface"
fi

# T19 (0.03): Timeline.tsx removed EMPTY_ENHANCED_PROMPTS sentinel constant
echo ""
echo "=== T19: EMPTY_ENHANCED_PROMPTS sentinel removed from Timeline.tsx ==="
if [ -f "$TIMELINE" ] && ! grep -q 'EMPTY_ENHANCED_PROMPTS' "$TIMELINE"; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL: sentinel still present"
fi

# T20 (0.03): TimelineContainer types.ts dropped `enhancedPrompts`
echo ""
echo "=== T20: TimelineContainer types.ts dropped enhancedPrompts ==="
if [ -f "$TC_TYPES" ] && ! grep -qE '^\s*enhancedPrompts\?\s*:' "$TC_TYPES"; then
    echo "PASS"
    add_reward 0.03
else
    echo "FAIL"
fi

# T21 (0.03): TimelineContainer.tsx no longer destructures/uses enhancedPrompts
echo ""
echo "=== T21: TimelineContainer.tsx removed enhancedPrompts usage ==="
COND=1
if [ -f "$TC" ]; then
    if grep -qE '\benhancedPrompts\b' "$TC"; then
        # Could still have a comment; check stronger: no reference at all
        COND=0
    fi
else
    COND=0
fi
if [ "$COND" -eq 1 ]; then
    echo "PASS"; add_reward 0.03
else
    echo "FAIL: enhancedPrompts still referenced"
fi

###############################################################################
# Final report
###############################################################################
echo ""
echo "=========================================="
echo "FINAL REWARD: $REWARD"
echo "=========================================="

echo "$REWARD" > "$REWARD_FILE"
chmod 644 "$REWARD_FILE" 2>/dev/null
exit 0