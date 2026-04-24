#!/bin/bash
set +e

# ═══════════════════════════════════════════════════════════════════
# Verifier for: reigh-stroke-overlay-refactor
# Task: Move drawing state machine into StrokeOverlay (4-step refactor)
#
# Nop score: 0.10 (only P2P gate passes on unmodified base)
# Weights: P2P=0.10, F2P=0.90, Total=1.00
# Execution gates: 0.75 of 1.00 (75% from tsc/node -e)
# ═══════════════════════════════════════════════════════════════════

REPO=/workspace/repo
INPAINT_DIR="$REPO/src/shared/components/MediaLightbox/hooks/inpainting"
OVERLAY="$REPO/src/shared/components/MediaLightbox/components/StrokeOverlay.tsx"
INPAINT_HOOK="$REPO/src/shared/components/MediaLightbox/hooks/useInpainting.ts"
TYPES_FILE="$INPAINT_DIR/types.ts"

REWARD=0

add_reward() {
    local amount=$1
    local label=$2
    REWARD=$(awk "BEGIN{printf \"%.2f\", $REWARD + $amount}")
    echo "  +${amount}  ${label}"
}

# ─── P2P Gate 1: TypeScript compilation (weight: 0.10) ─────────────
# Passes on unmodified base AND on correct fix.
# This is the foundational execution gate — code must compile.
echo "GATE 1 [P2P]: TypeScript compilation"
cd "$REPO"
npx tsc --noEmit >/dev/null 2>&1
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    add_reward 0.10 "TypeScript compiles cleanly"
    TSC_OK=1
else
    echo "  FAIL: TypeScript compilation errors (exit $TSC_EXIT)"
    TSC_OK=0
fi

# ─── F2P Gate 2: Dead hook files removed (weight: 0.25) ────────────
# Base has all 4 files. Correct fix deletes them per Steps 1-3 of plan.
# Requires compilation (Gate 1) to ensure removal was done safely
# (imports updated, not just files deleted).
echo "GATE 2 [F2P]: Dead hook files removed"
GONE=0
for f in useStrokeRendering.ts usePointerHandlers.ts useDragState.ts useInpaintActions.ts; do
    [ ! -f "$INPAINT_DIR/$f" ] && GONE=$((GONE+1))
done
if [ $GONE -eq 4 ] && [ $TSC_OK -eq 1 ]; then
    add_reward 0.25 "All 4 dead hook files removed and code compiles"
elif [ $GONE -eq 4 ]; then
    echo "  FAIL: Files removed but TypeScript compilation broken"
else
    echo "  FAIL: $((4-GONE)) of 4 hook files still exist"
fi

# ─── F2P Gate 3: StrokeOverlay absorbed drawing state machine (weight: 0.25) ──
# StrokeOverlay.tsx must have grown (base=421 lines) and now contain
# pointer handling, drawing state, and drag state internally.
# Verified via node -e execution gate.
echo "GATE 3 [F2P]: StrokeOverlay absorbed state machine"
if [ -f "$OVERLAY" ] && [ $TSC_OK -eq 1 ]; then
    OVERLAY_LINES=$(wc -l < "$OVERLAY")
    HAS_STATE=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync(process.argv[1], 'utf8');
        const checks = [
            /pointer.*(Down|Up|Move|down|up|move)/i.test(src),
            /(isDrawing|currentStroke)/.test(src),
            /(isDragging|dragOffset|dragMode)/.test(src),
        ];
        console.log(checks.every(Boolean) ? '1' : '0');
    " "$OVERLAY" 2>/dev/null)
    if [ "$OVERLAY_LINES" -gt 450 ] && [ "$HAS_STATE" = "1" ]; then
        add_reward 0.25 "StrokeOverlay grew to ${OVERLAY_LINES} lines with state machine"
    else
        echo "  FAIL: StrokeOverlay=${OVERLAY_LINES} lines, has_state=${HAS_STATE} (need >450 lines + state patterns)"
    fi
else
    echo "  FAIL: StrokeOverlay.tsx missing or TSC failed"
fi

# ─── F2P Gate 4: useInpainting simplified (weight: 0.20) ──────────
# useInpainting.ts must no longer import/call the deleted hooks.
# Base is 349 lines; after refactoring should be significantly smaller.
# Verified via node -e execution gate.
echo "GATE 4 [F2P]: useInpainting simplified"
if [ -f "$INPAINT_HOOK" ] && [ $TSC_OK -eq 1 ]; then
    HOOK_LINES=$(wc -l < "$INPAINT_HOOK")
    CLEAN=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync(process.argv[1], 'utf8');
        const noOldRefs = [
            !/useStrokeRendering/.test(src),
            !/usePointerHandlers/.test(src),
            !/useDragState/.test(src),
        ];
        console.log(noOldRefs.every(Boolean) ? '1' : '0');
    " "$INPAINT_HOOK" 2>/dev/null)
    if [ "$CLEAN" = "1" ] && [ "$HOOK_LINES" -lt 320 ]; then
        add_reward 0.20 "useInpainting.ts cleaned (${HOOK_LINES} lines, no old imports)"
    else
        echo "  FAIL: useInpainting lines=${HOOK_LINES} (need <320), clean=${CLEAN}"
    fi
else
    echo "  FAIL: useInpainting.ts missing or TSC failed"
fi

# ─── F2P Gate 5: Types cleaned — handler props removed (weight: 0.20) ─
# UseInpaintingReturn in types.ts should no longer export pointer handler
# methods or drawing state that moved into StrokeOverlay.
# Verified via node -e execution gate.
echo "GATE 5 [F2P]: Types cleaned — handler props removed"
if [ -f "$TYPES_FILE" ] && [ $TSC_OK -eq 1 ]; then
    TYPES_CLEAN=$(node -e "
        const fs = require('fs');
        const src = fs.readFileSync(process.argv[1], 'utf8');
        const removed = [
            !/handleKonvaPointerDown/.test(src),
            !/handleKonvaPointerMove/.test(src),
            !/handleKonvaPointerUp/.test(src),
            !/handleShapeClick/.test(src),
            !/redrawStrokes/.test(src),
        ];
        console.log(removed.every(Boolean) ? '1' : '0');
    " "$TYPES_FILE" 2>/dev/null)
    if [ "$TYPES_CLEAN" = "1" ]; then
        add_reward 0.20 "Handler props removed from types"
    else
        echo "  FAIL: types.ts still has old handler props"
    fi
else
    echo "  FAIL: types.ts missing or TSC failed"
fi

# ─── Write reward ──────────────────────────────────────────────────
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo ""
echo "═══ TOTAL REWARD: $REWARD ═══"
