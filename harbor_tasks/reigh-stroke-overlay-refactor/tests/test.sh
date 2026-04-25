#!/bin/bash
set +e

mkdir -p /logs/verifier
export PATH=/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH

# Locate repo
REPO=""
for candidate in /workspace/repo /workspace/reigh /workspace/Reigh; do
    if [ -d "$candidate" ]; then REPO="$candidate"; break; fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 2 -name "package.json" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
fi

REWARD=0
finalize() {
    echo "FINAL REWARD: $REWARD"
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot locate repo"
    finalize
fi

INPAINT_DIR="$REPO/src/shared/components/MediaLightbox/hooks/inpainting"
OVERLAY="$REPO/src/shared/components/MediaLightbox/components/StrokeOverlay.tsx"
INPAINT_HOOK="$REPO/src/shared/components/MediaLightbox/hooks/useInpainting.ts"
TYPES_FILE="$INPAINT_DIR/types.ts"

cd "$REPO"

add_reward() {
    local amount=$1
    local label=$2
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $amount}")
    echo "  +${amount}  ${label}"
}

# ════════════════════════════════════════════════════════════════════
# All checks below are F2P: they are TRUE only after the refactor.
# On the unmodified base:
#   - useStrokeRendering.ts, usePointerHandlers.ts, useDragState.ts EXIST
#   - useInpainting.ts imports them and references redrawStrokes
#   - StrokeOverlay.tsx does NOT have onStrokeComplete/onStrokesChange/onSelectionChange callbacks
#   - StrokeOverlay.tsx does NOT own isDrawing/currentStroke/dragOffset state
#   - types.ts has handleKonvaPointerDown etc, displayCanvasRef, maskCanvasRef
# So no-op = 0.0
# ════════════════════════════════════════════════════════════════════

# ─── F2P 1: Three dead hooks deleted (Step 1 + Step 2) — 0.20 ───
echo "═══ F2P GATE 1: Dead hook files removed ═══"
DELETED=0
for f in useStrokeRendering.ts usePointerHandlers.ts useDragState.ts; do
    if [ ! -f "$INPAINT_DIR/$f" ]; then
        DELETED=$((DELETED+1))
        echo "    ✓ $f deleted"
    else
        echo "    ✗ $f still exists"
    fi
done
case $DELETED in
    3) add_reward 0.20 "all 3 dead hooks deleted" ;;
    2) add_reward 0.12 "2 of 3 dead hooks deleted" ;;
    1) add_reward 0.05 "1 of 3 dead hooks deleted" ;;
    *) echo "  no dead hooks deleted (no-op base)" ;;
esac

# ─── F2P 2: useInpainting no longer imports/uses dead hooks — 0.15 ───
echo "═══ F2P GATE 2: useInpainting cleaned ═══"
if [ -f "$INPAINT_HOOK" ]; then
    CLEAN=$(node -e "
        const fs=require('fs');
        const src=fs.readFileSync('$INPAINT_HOOK','utf8');
        let s=0;
        if (!/useStrokeRendering/.test(src)) s++;
        if (!/usePointerHandlers/.test(src)) s++;
        if (!/useDragState/.test(src)) s++;
        if (!/redrawStrokes/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    CLEAN=${CLEAN:-0}
    echo "  cleanliness: $CLEAN/4"
    if [ "$CLEAN" -eq 4 ]; then
        add_reward 0.15 "useInpainting imports & redrawStrokes fully removed"
    elif [ "$CLEAN" -eq 3 ]; then
        add_reward 0.08 "useInpainting mostly cleaned"
    elif [ "$CLEAN" -eq 2 ]; then
        add_reward 0.03 "useInpainting partially cleaned"
    else
        echo "  base state — no credit"
    fi
else
    echo "  useInpainting.ts missing"
fi

# ─── F2P 3: StrokeOverlay has new callback props — 0.20 ───
echo "═══ F2P GATE 3: StrokeOverlay new callback API ═══"
if [ -f "$OVERLAY" ]; then
    CB_SCORE=$(node -e "
        const fs=require('fs');
        const src=fs.readFileSync('$OVERLAY','utf8');
        let s=0;
        if (/onStrokeComplete/.test(src)) s++;
        if (/onStrokesChange/.test(src)) s++;
        if (/onSelectionChange/.test(src)) s++;
        // Old prop-threaded handlers should NOT be the primary API anymore
        // (they may still appear as legacy but new API must exist)
        if (/onTextModeHint/.test(src) || /TextModeHint/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    CB_SCORE=${CB_SCORE:-0}
    echo "  callback score: $CB_SCORE/4"
    if [ "$CB_SCORE" -ge 4 ]; then
        add_reward 0.20 "StrokeOverlay exposes full new callback API"
    elif [ "$CB_SCORE" -eq 3 ]; then
        add_reward 0.14 "StrokeOverlay has 3/4 new callbacks"
    elif [ "$CB_SCORE" -eq 2 ]; then
        add_reward 0.07 "StrokeOverlay has 2/4 new callbacks"
    elif [ "$CB_SCORE" -eq 1 ]; then
        add_reward 0.02 "StrokeOverlay has 1/4 new callbacks"
    else
        echo "  no new callbacks (no-op base)"
    fi
else
    echo "  StrokeOverlay.tsx missing"
fi

# ─── F2P 4: StrokeOverlay owns drawing state machine — 0.20 ───
echo "═══ F2P GATE 4: StrokeOverlay owns drawing state ═══"
if [ -f "$OVERLAY" ]; then
    OVERLAY_LINES=$(wc -l < "$OVERLAY")
    STATE_SCORE=$(node -e "
        const fs=require('fs');
        const src=fs.readFileSync('$OVERLAY','utf8');
        let s=0;
        // Owns isDrawing or currentStroke state internally (useState or useRef)
        if (/(useState|useRef)[^;]*\b(isDrawing|currentStroke)\b/.test(src) ||
            /\bset(IsDrawing|CurrentStroke)\b/.test(src)) s++;
        // Owns drag state
        if (/(isDragging|dragOffset|dragMode|draggingCorner)/.test(src)) s++;
        // Pointer event handlers internal
        if (/(handlePointerDown|handlePointerMove|handlePointerUp|onPointerDown|onPointerMove|onPointerUp)/.test(src)) s++;
        // Selection state internal
        if (/selectedShapeId/.test(src) && /(useState|setSelectedShapeId)/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    STATE_SCORE=${STATE_SCORE:-0}
    echo "  state machine score: $STATE_SCORE/4 ($OVERLAY_LINES lines)"
    # Base StrokeOverlay (~380 lines) does NOT own isDrawing/currentStroke/drag state internally.
    # It receives them as props. Refactor moves them inside.
    if [ "$STATE_SCORE" -ge 4 ] && [ "$OVERLAY_LINES" -gt 450 ]; then
        add_reward 0.20 "StrokeOverlay fully owns state machine"
    elif [ "$STATE_SCORE" -ge 3 ] && [ "$OVERLAY_LINES" -gt 420 ]; then
        add_reward 0.12 "StrokeOverlay mostly owns state machine"
    elif [ "$STATE_SCORE" -ge 2 ]; then
        add_reward 0.05 "StrokeOverlay partially owns state"
    else
        echo "  state still external (no-op base)"
    fi
else
    echo "  StrokeOverlay.tsx missing"
fi

# ─── F2P 5: Old handler props removed from types — 0.10 ───
echo "═══ F2P GATE 5: Handler props removed from types ═══"
if [ -f "$TYPES_FILE" ]; then
    TYPE_SCORE=$(node -e "
        const fs=require('fs');
        const src=fs.readFileSync('$TYPES_FILE','utf8');
        let s=0;
        if (!/handleKonvaPointerDown/.test(src)) s++;
        if (!/handleKonvaPointerMove/.test(src)) s++;
        if (!/handleKonvaPointerUp/.test(src)) s++;
        if (!/displayCanvasRef/.test(src)) s++;
        if (!/maskCanvasRef/.test(src)) s++;
        console.log(s);
    " 2>/dev/null)
    TYPE_SCORE=${TYPE_SCORE:-0}
    echo "  types removed: $TYPE_SCORE/5"
    if [ "$TYPE_SCORE" -ge 5 ]; then
        add_reward 0.10 "all old handler/canvas refs removed from types"
    elif [ "$TYPE_SCORE" -eq 4 ]; then
        add_reward 0.07 "most old props removed"
    elif [ "$TYPE_SCORE" -eq 3 ]; then
        add_reward 0.04 "some old props removed"
    else
        echo "  base types intact (no-op base)"
    fi
else
    echo "  types.ts missing"
fi

# ─── F2P 6: useInpaintActions deleted (Step 3) — 0.05 ───
echo "═══ F2P GATE 6: useInpaintActions deleted ═══"
if [ ! -f "$INPAINT_DIR/useInpaintActions.ts" ]; then
    add_reward 0.05 "useInpaintActions.ts deleted"
else
    echo "  useInpaintActions.ts still exists (Step 3 not done)"
fi

# ─── F2P 7: useInpainting shrunk — 0.05 ───
echo "═══ F2P GATE 7: useInpainting shrunk ═══"
if [ -f "$INPAINT_HOOK" ]; then
    HOOK_LINES=$(wc -l < "$INPAINT_HOOK")
    echo "  useInpainting.ts: $HOOK_LINES lines"
    # Base is ~400+ lines. After refactor should be much smaller.
    if [ "$HOOK_LINES" -lt 300 ]; then
        add_reward 0.05 "useInpainting significantly shrunk"
    elif [ "$HOOK_LINES" -lt 350 ]; then
        add_reward 0.02 "useInpainting somewhat shrunk"
    else
        echo "  not shrunk meaningfully"
    fi
fi

# ─── P2P guard: TypeScript should not have a catastrophic error count ───
# This is a guard, not a reward source. If the refactor produced > 50 TS errors
# in the relevant subtree, the agent destroyed the codebase — return 0.
echo "═══ P2P GUARD: TypeScript sanity ═══"
TSC_LOG=$(mktemp)
TSC_AVAILABLE=0
if [ -x "./node_modules/.bin/tsc" ]; then
    timeout 180 ./node_modules/.bin/tsc --noEmit > "$TSC_LOG" 2>&1
    TSC_AVAILABLE=1
elif command -v npx >/dev/null 2>&1; then
    timeout 180 npx --no-install tsc --noEmit > "$TSC_LOG" 2>&1
    TSC_AVAILABLE=1
fi

if [ "$TSC_AVAILABLE" -eq 1 ]; then
    RELEVANT_ERRORS=$(grep -E "error TS" "$TSC_LOG" 2>/dev/null | grep -E "(StrokeOverlay|useInpainting|inpainting/|MediaLightbox)" | wc -l)
    echo "  relevant TS errors: $RELEVANT_ERRORS"
    if [ "$RELEVANT_ERRORS" -gt 50 ]; then
        echo "  GUARD TRIPPED: catastrophic TS errors — zeroing reward"
        REWARD=0
    fi
fi
rm -f "$TSC_LOG"

echo "$REWARD" > /logs/verifier/reward.txt
echo "FINAL REWARD: $REWARD"