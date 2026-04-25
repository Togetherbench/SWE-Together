#!/bin/bash
set +e

# ═══════════════════════════════════════════════════════════════════
# Verifier for: reigh-stroke-overlay-refactor
# Task: Move drawing state machine into StrokeOverlay (4-step refactor)
# ═══════════════════════════════════════════════════════════════════

export PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH

# Locate repo
REPO=""
for candidate in /workspace/repo /workspace/reigh /workspace/Reigh; do
    if [ -d "$candidate" ]; then REPO="$candidate"; break; fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 2 -name "package.json" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
fi
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot locate repo"
    mkdir -p /logs/verifier
    echo "0" > /logs/verifier/reward.txt
    exit 0
fi

INPAINT_DIR="$REPO/src/shared/components/MediaLightbox/hooks/inpainting"
OVERLAY="$REPO/src/shared/components/MediaLightbox/components/StrokeOverlay.tsx"
INPAINT_HOOK="$REPO/src/shared/components/MediaLightbox/hooks/useInpainting.ts"
TYPES_FILE="$INPAINT_DIR/types.ts"

cd "$REPO"

REWARD=0
add_reward() {
    local amount=$1
    local label=$2
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $amount}")
    echo "  +${amount}  ${label}"
}

# ════════════════════════════════════════════════════════════════════
# BEHAVIORAL: TypeScript compilation (the heaviest gate, ~40%)
# ════════════════════════════════════════════════════════════════════
echo "═══ BEHAVIORAL GATE: TypeScript compilation ═══"

TSC_LOG=$(mktemp)
if [ -x "./node_modules/.bin/tsc" ]; then
    ./node_modules/.bin/tsc --noEmit > "$TSC_LOG" 2>&1
    TSC_EXIT=$?
elif command -v npx >/dev/null 2>&1; then
    npx --no-install tsc --noEmit > "$TSC_LOG" 2>&1
    TSC_EXIT=$?
else
    TSC_EXIT=127
fi

# Count errors in StrokeOverlay/useInpainting/types/inpainting subtree
RELEVANT_ERRORS=$(grep -E "error TS" "$TSC_LOG" 2>/dev/null | grep -E "(StrokeOverlay|useInpainting|inpainting/|MediaLightbox)" | wc -l)
TOTAL_ERRORS=$(grep -cE "error TS" "$TSC_LOG" 2>/dev/null)

echo "  tsc exit=$TSC_EXIT  total_errors=$TOTAL_ERRORS  relevant_errors=$RELEVANT_ERRORS"

if [ "$TSC_EXIT" -eq 0 ]; then
    add_reward 0.40 "TypeScript compiles cleanly"
    TSC_OK=1
elif [ "$TSC_EXIT" -eq 127 ]; then
    echo "  WARN: tsc not available — skipping (no credit)"
    TSC_OK=0
elif [ "$RELEVANT_ERRORS" -eq 0 ]; then
    # Errors exist but none in the refactored area — partial credit
    add_reward 0.25 "TypeScript: errors present but none in refactor scope"
    TSC_OK=1
elif [ "$RELEVANT_ERRORS" -le 3 ]; then
    add_reward 0.10 "TypeScript: minor errors in refactor scope ($RELEVANT_ERRORS)"
    TSC_OK=0
else
    echo "  FAIL: $RELEVANT_ERRORS errors in refactor scope"
    head -30 "$TSC_LOG" | sed 's/^/    /'
    TSC_OK=0
fi
rm -f "$TSC_LOG"

# ════════════════════════════════════════════════════════════════════
# BEHAVIORAL: StrokeOverlay surface area via node parse (~25%)
# ════════════════════════════════════════════════════════════════════
echo "═══ BEHAVIORAL GATE: StrokeOverlay absorbed state machine ═══"

if [ -f "$OVERLAY" ]; then
    OVERLAY_LINES=$(wc -l < "$OVERLAY")
    SCORE=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync('$OVERLAY', 'utf8');
        let s = 0;
        // Pointer event handling internal
        if (/onPointer(Down|Move|Up)/.test(src) || /pointer(down|move|up)/i.test(src)) s++;
        // Drawing state internal (useState for isDrawing or currentStroke)
        if (/useState[^;]*\b(isDrawing|currentStroke)\b/.test(src) ||
            /\b(isDrawing|currentStroke)\b\s*,?\s*set[A-Z]/.test(src)) s++;
        // Drag state internal (isDragging / dragOffset / dragMode)
        if (/(isDragging|dragOffset|dragMode|draggingCorner)/.test(src)) s++;
        // New callbacks present
        if (/onStrokeComplete/.test(src) && /onStrokesChange/.test(src)) s++;
        // onSelectionChange or selection callback
        if (/onSelectionChange/.test(src) || /onSelect/.test(src)) s++;
        // Stage with refs
        if (/Stage/.test(src) && /ref/i.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    SCORE=${SCORE:-0}
    echo "  StrokeOverlay: $OVERLAY_LINES lines, behavioral_score=$SCORE/6"

    # Score scaled: full credit if 5-6 features + grew, half if 3-4
    if [ "$SCORE" -ge 5 ] && [ "$OVERLAY_LINES" -gt 450 ]; then
        add_reward 0.25 "StrokeOverlay owns full state machine"
    elif [ "$SCORE" -ge 4 ] && [ "$OVERLAY_LINES" -gt 400 ]; then
        add_reward 0.15 "StrokeOverlay partially absorbed state"
    elif [ "$SCORE" -ge 3 ]; then
        add_reward 0.08 "StrokeOverlay has some new features"
    else
        echo "  FAIL: StrokeOverlay not refactored"
    fi
else
    echo "  FAIL: StrokeOverlay.tsx missing"
fi

# ════════════════════════════════════════════════════════════════════
# STRUCTURAL: Dead hooks deleted (~15%)
# ════════════════════════════════════════════════════════════════════
echo "═══ STRUCTURAL GATE: Dead hook files removed ═══"

DELETED=0
for f in useStrokeRendering.ts usePointerHandlers.ts useDragState.ts; do
    if [ ! -f "$INPAINT_DIR/$f" ]; then
        DELETED=$((DELETED+1))
        echo "    ✓ $f deleted"
    else
        echo "    ✗ $f still exists"
    fi
done
# useInpaintActions.ts is Step 3 — slightly less critical
ACTIONS_GONE=0
[ ! -f "$INPAINT_DIR/useInpaintActions.ts" ] && ACTIONS_GONE=1

# 0.10 for the 3 main deletions + 0.05 for actions
case $DELETED in
    3) add_reward 0.10 "useStrokeRendering, usePointerHandlers, useDragState deleted" ;;
    2) add_reward 0.06 "2 of 3 core hooks deleted" ;;
    1) add_reward 0.03 "1 of 3 core hooks deleted" ;;
    *) echo "  FAIL: 0 core hooks deleted" ;;
esac
if [ "$ACTIONS_GONE" -eq 1 ]; then
    add_reward 0.05 "useInpaintActions deleted (Step 3)"
fi

# ════════════════════════════════════════════════════════════════════
# BEHAVIORAL: useInpainting cleaned up (~10%)
# ════════════════════════════════════════════════════════════════════
echo "═══ BEHAVIORAL GATE: useInpainting simplified ═══"

if [ -f "$INPAINT_HOOK" ]; then
    HOOK_LINES=$(wc -l < "$INPAINT_HOOK")
    CLEAN_SCORE=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync('$INPAINT_HOOK', 'utf8');
        let s = 0;
        // No imports of deleted hooks
        if (!/from\s+['\"][^'\"]*useStrokeRendering/.test(src) &&
            !/import.*useStrokeRendering/.test(src)) s++;
        if (!/from\s+['\"][^'\"]*usePointerHandlers/.test(src) &&
            !/import.*usePointerHandlers/.test(src)) s++;
        if (!/from\s+['\"][^'\"]*useDragState/.test(src) &&
            !/import.*useDragState/.test(src)) s++;
        // No redrawStrokes references in body (return value, calls)
        if (!/redrawStrokes/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    CLEAN_SCORE=${CLEAN_SCORE:-0}
    echo "  useInpainting: $HOOK_LINES lines, clean_score=$CLEAN_SCORE/4"

    if [ "$CLEAN_SCORE" -eq 4 ] && [ "$HOOK_LINES" -lt 320 ]; then
        add_reward 0.10 "useInpainting fully cleaned and shrunk"
    elif [ "$CLEAN_SCORE" -eq 4 ]; then
        add_reward 0.07 "useInpainting cleaned but still large"
    elif [ "$CLEAN_SCORE" -ge 3 ]; then
        add_reward 0.04 "useInpainting partially cleaned"
    else
        echo "  FAIL: useInpainting still references old hooks"
    fi
else
    echo "  FAIL: useInpainting.ts missing"
fi

# ════════════════════════════════════════════════════════════════════
# STRUCTURAL: Types cleaned (~10%)
# ════════════════════════════════════════════════════════════════════
echo "═══ STRUCTURAL GATE: Handler props removed from types ═══"

if [ -f "$TYPES_FILE" ]; then
    TYPE_SCORE=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync('$TYPES_FILE', 'utf8');
        let s = 0;
        if (!/handleKonvaPointerDown/.test(src)) s++;
        if (!/handleKonvaPointerMove/.test(src)) s++;
        if (!/handleKonvaPointerUp/.test(src)) s++;
        if (!/handleShapeClick/.test(src)) s++;
        if (!/redrawStrokes/.test(src)) s++;
        // displayCanvasRef / maskCanvasRef should be gone from props
        if (!/displayCanvasRef/.test(src)) s++;
        if (!/maskCanvasRef/.test(src)) s++;
        // isDrawing/currentStroke should not be in return type
        if (!/\bisDrawing\s*:/.test(src) && !/\bcurrentStroke\s*:/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    TYPE_SCORE=${TYPE_SCORE:-0}
    echo "  types.ts cleanup score: $TYPE_SCORE/8"

    if [ "$TYPE_SCORE" -ge 7 ]; then
        add_reward 0.10 "types.ts thoroughly cleaned"
    elif [ "$TYPE_SCORE" -ge 5 ]; then
        add_reward 0.06 "types.ts mostly cleaned"
    elif [ "$TYPE_SCORE" -ge 3 ]; then
        add_reward 0.03 "types.ts partially cleaned"
    else
        echo "  FAIL: types.ts not cleaned"
    fi
else
    echo "  FAIL: types.ts missing"
fi

# ════════════════════════════════════════════════════════════════════
# Write final reward
# ════════════════════════════════════════════════════════════════════
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo ""
echo "═══ TOTAL REWARD: $REWARD ═══"