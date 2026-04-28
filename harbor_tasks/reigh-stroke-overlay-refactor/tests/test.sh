#!/bin/bash
set +e

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/"/\\"/g' | tr -d '\n')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

REPO=""
for candidate in /workspace/repo /workspace/reigh /workspace/Reigh; do
    if [ -d "$candidate" ]; then REPO="$candidate"; break; fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 2 -name "package.json" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
fi

finalize_zero() {
    for gid in t1_f2p_dead_hooks_deleted t1_f2p_overlay_owns_state_machine \
               t2_f2p_overlay_callback_api_invoked t2_f2p_overlay_handle_methods \
               t3_f2p_useinpainting_purged t3_f2p_types_and_chain_cleaned; do
        emit "$gid" false "repo not found"
    done
    printf "%.4f\n" 0 > /logs/verifier/reward.txt
    exit 0
}

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot locate repo"
    finalize_zero
fi

cd "$REPO"

INPAINT_DIR="$REPO/src/shared/components/MediaLightbox/hooks/inpainting"
COMP_DIR="$REPO/src/shared/components/MediaLightbox/components"
OVERLAY="$COMP_DIR/StrokeOverlay.tsx"
INPAINT_HOOK="$REPO/src/shared/components/MediaLightbox/hooks/useInpainting.ts"
ACTIONS_HOOK="$INPAINT_DIR/useInpaintActions.ts"
TYPES_FILE="$INPAINT_DIR/types.ts"
VIDEO_LB="$REPO/src/shared/components/MediaLightbox/VideoLightbox.tsx"
LAYOUT_TYPES="$COMP_DIR/layouts/types.ts"
LAYOUT="$COMP_DIR/layouts/LightboxLayout.tsx"
MEDIA_DISPLAY="$COMP_DIR/MediaDisplayWithCanvas.tsx"

read_file() { [ -f "$1" ] && cat "$1" || echo ""; }

# strip line/block comments (best-effort) so symbol mentions in comments don't satisfy gates
strip_comments() {
    # remove // ... and /* ... */ (single-line block); good enough for our greps
    sed -E 's://.*$::g; s:/\*[^*]*\*+([^/*][^*]*\*+)*/::g'
}

OV_SRC=$(read_file "$OVERLAY" | strip_comments)
INP_SRC=$(read_file "$INPAINT_HOOK" | strip_comments)
ACT_SRC=$(read_file "$ACTIONS_HOOK" | strip_comments)
TYPES_SRC=$(read_file "$TYPES_FILE" | strip_comments)
VL_SRC=$(read_file "$VIDEO_LB" | strip_comments)
LT_SRC=$(read_file "$LAYOUT_TYPES" | strip_comments)
LAY_SRC=$(read_file "$LAYOUT" | strip_comments)
MD_SRC=$(read_file "$MEDIA_DISPLAY" | strip_comments)

# ════════════════════════════════════════════════════════════════════
# G1 (T1): Dead hooks deleted
# Spec mandates deletion of all 4 hooks. Each must be gone.
# ════════════════════════════════════════════════════════════════════
echo "═══ G1 (t1_f2p_dead_hooks_deleted) ═══"
DELETED=0
TOTAL=4
[ ! -f "$INPAINT_DIR/useStrokeRendering.ts" ] && DELETED=$((DELETED+1)) && echo "  ✓ useStrokeRendering.ts gone"
[ ! -f "$INPAINT_DIR/usePointerHandlers.ts" ] && DELETED=$((DELETED+1)) && echo "  ✓ usePointerHandlers.ts gone"
[ ! -f "$INPAINT_DIR/useDragState.ts" ] && DELETED=$((DELETED+1)) && echo "  ✓ useDragState.ts gone"
[ ! -f "$INPAINT_DIR/useInpaintActions.ts" ] && DELETED=$((DELETED+1)) && echo "  ✓ useInpaintActions.ts gone"
echo "  deleted=$DELETED/$TOTAL"
if [ "$DELETED" -eq "$TOTAL" ]; then
    emit t1_f2p_dead_hooks_deleted true ""
else
    emit t1_f2p_dead_hooks_deleted false "only $DELETED/$TOTAL legacy hooks deleted"
fi

# ════════════════════════════════════════════════════════════════════
# G2 (T1): StrokeOverlay owns state machine internally
# Must declare state via useState/useRef AND call setters/refs from inside
# pointer handler bodies AND attach a global pointerup listener.
# ════════════════════════════════════════════════════════════════════
echo "═══ G2 (t1_f2p_overlay_owns_state_machine) ═══"
OVERLAY_OK=0
if [ -n "$OV_SRC" ]; then
    # 1. State declarations: useState/useRef with isDrawing & currentStroke
    DECL_DRAWING=0
    DECL_STROKE=0
    DECL_DRAG=0
    if echo "$OV_SRC" | grep -qE "(useState|useRef)[^;]*\bisDrawing"; then DECL_DRAWING=1; fi
    if echo "$OV_SRC" | grep -qE "(useState|useRef)[^;]*\bcurrentStroke"; then DECL_STROKE=1; fi
    if echo "$OV_SRC" | grep -qE "(useState|useRef)[^;]*(isDragging|dragOffset|dragMode|draggingCorner)"; then DECL_DRAG=1; fi

    # 2. Setters actually invoked (not just declared)
    SET_INVOKED=0
    if echo "$OV_SRC" | grep -qE "setIsDrawing\s*\("; then SET_INVOKED=$((SET_INVOKED+1)); fi
    if echo "$OV_SRC" | grep -qE "setCurrentStroke\s*\("; then SET_INVOKED=$((SET_INVOKED+1)); fi
    if echo "$OV_SRC" | grep -qE "(setIsDragging|setDragOffset|setDragMode)\s*\("; then SET_INVOKED=$((SET_INVOKED+1)); fi

    # 3. Global pointerup listener (window/document.addEventListener)
    HAS_GLOBAL=0
    if echo "$OV_SRC" | grep -qE "(window|document)\.addEventListener\s*\(\s*['\"]pointerup"; then
        HAS_GLOBAL=1
    fi

    # 4. Internal pointer-down handler that mutates drawing state
    # Find a pointer handler body that contains setIsDrawing(true) or isDrawingRef.current = true
    HAS_PD_WIRING=0
    if echo "$OV_SRC" | tr '\n' ' ' | grep -qE "(onPointerDown|handlePointerDown|handleStagePointerDown|onMouseDown)[^{]*\{[^}]{0,2000}(setIsDrawing\s*\(\s*true|isDrawingRef\.current\s*=\s*true)"; then
        HAS_PD_WIRING=1
    fi

    # File size sanity (real absorption produces >= ~400 lines)
    OV_LINES=$(echo "$OV_SRC" | wc -l)

    echo "  decl: drawing=$DECL_DRAWING stroke=$DECL_STROKE drag=$DECL_DRAG"
    echo "  setters invoked: $SET_INVOKED/3"
    echo "  global pointerup listener: $HAS_GLOBAL"
    echo "  pointer-down wires drawing state: $HAS_PD_WIRING"
    echo "  overlay lines: $OV_LINES"

    DECL_OK=$((DECL_DRAWING + DECL_STROKE + DECL_DRAG))
    if [ "$DECL_OK" -ge 3 ] && [ "$SET_INVOKED" -ge 3 ] && [ "$HAS_GLOBAL" -eq 1 ] && [ "$HAS_PD_WIRING" -eq 1 ] && [ "$OV_LINES" -ge 350 ]; then
        OVERLAY_OK=1
    fi
fi
if [ "$OVERLAY_OK" -eq 1 ]; then
    emit t1_f2p_overlay_owns_state_machine true ""
else
    emit t1_f2p_overlay_owns_state_machine false "overlay does not fully own state machine (decl/setters/listener/wiring/size check failed)"
fi

# ════════════════════════════════════════════════════════════════════
# G3 (T2): Callback API both declared AND invoked
# Each of onStrokeComplete/onStrokesChange/onSelectionChange must
# appear as a prop AND be called inside the overlay (e.g., props.onX(...)
# or destructured `onX(...)`).
# ════════════════════════════════════════════════════════════════════
echo "═══ G3 (t2_f2p_overlay_callback_api_invoked) ═══"
CB_OK=0
if [ -n "$OV_SRC" ]; then
    DECL_CNT=0
    INVOKE_CNT=0
    for cb in onStrokeComplete onStrokesChange onSelectionChange; do
        # Declared as a prop (in interface, type, or destructure)
        if echo "$OV_SRC" | grep -qE "${cb}\s*[?:,)}]"; then
            DECL_CNT=$((DECL_CNT+1))
        fi
        # Invoked: `onX(` or `props.onX(` or `?.onX(`
        if echo "$OV_SRC" | grep -qE "(\b|\.|\?)${cb}\s*\("; then
            INVOKE_CNT=$((INVOKE_CNT+1))
        fi
    done
    echo "  callbacks declared: $DECL_CNT/3, invoked: $INVOKE_CNT/3"
    if [ "$DECL_CNT" -ge 3 ] && [ "$INVOKE_CNT" -ge 3 ]; then
        CB_OK=1
    fi
fi
if [ "$CB_OK" -eq 1 ]; then
    emit t2_f2p_overlay_callback_api_invoked true ""
else
    emit t2_f2p_overlay_callback_api_invoked false "callbacks not both declared and invoked"
fi

# ════════════════════════════════════════════════════════════════════
# G4 (T2): Imperative handle exposes action methods
# StrokeOverlayHandle (or useImperativeHandle body) must expose
# undo / clear (or clearAll/clearMask) / deleteSelected / toggleFreeForm
# AND getSelectedShapeId. Methods must be both named AND have a function
# body in the overlay (not just a type-only declaration).
# ════════════════════════════════════════════════════════════════════
echo "═══ G4 (t2_f2p_overlay_handle_methods) ═══"
HANDLE_OK=0
if [ -n "$OV_SRC" ]; then
    # require useImperativeHandle to exist
    HAS_IMP=0
    if echo "$OV_SRC" | grep -q "useImperativeHandle"; then HAS_IMP=1; fi

    METHOD_HITS=0
    # undo
    if echo "$OV_SRC" | grep -qE "\bundo\s*[:(=]"; then METHOD_HITS=$((METHOD_HITS+1)); fi
    # clear / clearAll / clearMask
    if echo "$OV_SRC" | grep -qE "\b(clear|clearAll|clearMask)\s*[:(=]"; then METHOD_HITS=$((METHOD_HITS+1)); fi
    # deleteSelected
    if echo "$OV_SRC" | grep -qE "\bdeleteSelected\s*[:(=]"; then METHOD_HITS=$((METHOD_HITS+1)); fi
    # toggleFreeForm
    if echo "$OV_SRC" | grep -qE "\btoggleFreeForm\s*[:(=]"; then METHOD_HITS=$((METHOD_HITS+1)); fi
    # getSelectedShapeId
    HAS_GETSEL=0
    if echo "$OV_SRC" | grep -qE "\bgetSelectedShapeId\s*[:(=]"; then HAS_GETSEL=1; fi

    echo "  useImperativeHandle: $HAS_IMP, action methods: $METHOD_HITS/4, getSelectedShapeId: $HAS_GETSEL"
    if [ "$HAS_IMP" -eq 1 ] && [ "$METHOD_HITS" -ge 4 ] && [ "$HAS_GETSEL" -eq 1 ]; then
        HANDLE_OK=1
    fi
fi
if [ "$HANDLE_OK" -eq 1 ]; then
    emit t2_f2p_overlay_handle_methods true ""
else
    emit t2_f2p_overlay_handle_methods false "imperative handle missing required methods"
fi

# ════════════════════════════════════════════════════════════════════
# G5 (T3): useInpainting.ts purged
# - no imports/calls of removed hooks
# - no redrawStrokes / handleKonvaPointerDown/Move/Up references
# - imports/calls of legacy hooks must be ABSENT (after comment strip)
# ════════════════════════════════════════════════════════════════════
echo "═══ G5 (t3_f2p_useinpainting_purged) ═══"
INP_OK=0
if [ -n "$INP_SRC" ]; then
    BAD=0
    for sym in useStrokeRendering usePointerHandlers useDragState useInpaintActions; do
        if echo "$INP_SRC" | grep -qE "\b${sym}\b"; then
            echo "  ✗ still references $sym"
            BAD=$((BAD+1))
        fi
    done
    for sym in redrawStrokes handleKonvaPointerDown handleKonvaPointerMove handleKonvaPointerUp; do
        if echo "$INP_SRC" | grep -qE "\b${sym}\b"; then
            echo "  ✗ still references $sym"
            BAD=$((BAD+1))
        fi
    done
    # Must still export something useful (sanity: file not gutted to empty)
    HAS_BODY=0
    if echo "$INP_SRC" | grep -qE "(export\s+(const|function|default)|return\s*\{)"; then
        HAS_BODY=1
    fi
    echo "  bad-symbol count: $BAD ; has body: $HAS_BODY"
    if [ "$BAD" -eq 0 ] && [ "$HAS_BODY" -eq 1 ]; then
        INP_OK=1
    fi
fi
if [ "$INP_OK" -eq 1 ]; then
    emit t3_f2p_useinpainting_purged true ""
else
    emit t3_f2p_useinpainting_purged false "useInpainting still references removed hooks/handlers"
fi

# ════════════════════════════════════════════════════════════════════
# G6 (T3): Types & prop-chain cleaned
# - inpainting/types.ts: no handleKonvaPointer*, displayCanvasRef,
#   maskCanvasRef, redrawStrokes, no DragState interface
# - layouts/types.ts: no handleKonvaPointer*, no canvasRef/maskCanvasRef
# - VideoLightbox: no isDrawing:false / currentStroke: stub, AND has at
#   least one new callback stub (onStrokeComplete/onStrokesChange/...)
# ════════════════════════════════════════════════════════════════════
echo "═══ G6 (t3_f2p_types_and_chain_cleaned) ═══"
CHAIN_OK=1

# inpainting types.ts
if [ -n "$TYPES_SRC" ]; then
    for sym in handleKonvaPointerDown handleKonvaPointerMove handleKonvaPointerUp displayCanvasRef maskCanvasRef redrawStrokes; do
        if echo "$TYPES_SRC" | grep -qE "\b${sym}\b"; then
            echo "  ✗ types.ts still has $sym"
            CHAIN_OK=0
        fi
    done
    if echo "$TYPES_SRC" | grep -qE "interface\s+DragState\b"; then
        echo "  ✗ types.ts still defines DragState"
        CHAIN_OK=0
    fi
else
    # types.ts being gone is also acceptable
    echo "  (types.ts absent — acceptable)"
fi

# layouts/types.ts
if [ -n "$LT_SRC" ]; then
    for sym in handleKonvaPointerDown handleKonvaPointerMove handleKonvaPointerUp; do
        if echo "$LT_SRC" | grep -qE "\b${sym}\b"; then
            echo "  ✗ layouts/types.ts still has $sym"
            CHAIN_OK=0
        fi
    done
fi

# MediaDisplayWithCanvas: should not still receive old handler props in its interface
if [ -n "$MD_SRC" ]; then
    if echo "$MD_SRC" | grep -qE "\bhandleKonvaPointer(Down|Move|Up)\b"; then
        echo "  ✗ MediaDisplayWithCanvas still references handleKonvaPointer*"
        CHAIN_OK=0
    fi
fi

# VideoLightbox stub migrated
if [ -n "$VL_SRC" ]; then
    OLD_STUB=0
    if echo "$VL_SRC" | grep -qE "isDrawing\s*:\s*false"; then OLD_STUB=1; fi
    if echo "$VL_SRC" | grep -qE "currentStroke\s*:\s*null"; then OLD_STUB=1; fi
    if echo "$VL_SRC" | grep -qE "handleKonvaPointer(Down|Move|Up)\s*:"; then OLD_STUB=1; fi
    NEW_STUB=0
    for cb in onStrokeComplete onStrokesChange onSelectionChange onTextModeHint; do
        if echo "$VL_SRC" | grep -qE "\b${cb}\b"; then NEW_STUB=$((NEW_STUB+1)); fi
    done
    echo "  VideoLightbox: old_stub=$OLD_STUB new_stub_count=$NEW_STUB"
    if [ "$OLD_STUB" -eq 1 ]; then
        CHAIN_OK=0
    fi
    if [ "$NEW_STUB" -lt 1 ]; then
        echo "  ✗ VideoLightbox missing new callback stubs"
        CHAIN_OK=0
    fi
fi

if [ "$CHAIN_OK" -eq 1 ]; then
    emit t3_f2p_types_and_chain_cleaned true ""
else
    emit t3_f2p_types_and_chain_cleaned false "types or prop-chain still carry legacy handler/state props"
fi

# ════════════════════════════════════════════════════════════════════
# Reward computation
# Sum of F2P weights for passing gates.
# ════════════════════════════════════════════════════════════════════
declare -A WEIGHTS=(
    [t1_f2p_dead_hooks_deleted]=0.18
    [t1_f2p_overlay_owns_state_machine]=0.22
    [t2_f2p_overlay_callback_api_invoked]=0.18
    [t2_f2p_overlay_handle_methods]=0.12
    [t3_f2p_useinpainting_purged]=0.15
    [t3_f2p_types_and_chain_cleaned]=0.15
)

REWARD="0.0000"
while IFS= read -r line; do
    id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
    passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
    w="${WEIGHTS[$id]:-0}"
    if [ "$passed" = "true" ] && [ "$w" != "0" ]; then
        REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $w}")
    fi
done < "$GATES_FILE"

echo ""
echo "═══ SUMMARY ═══"
cat "$GATES_FILE"
echo ""
echo "REWARD=$REWARD"
printf "%.4f\n" "$REWARD" > /logs/verifier/reward.txt
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3JlcG8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_523760b1 'tsc_noemit' 'cd /workspace/repo && cd /workspace/repo && timeout 90 npx tsc --noEmit -p tsconfig.app.json 2>&1 | tail -5; if grep -q '\''error TS'\'' /tmp/tsc.out 2>/dev/null; then exit 1; fi'
run_v043_gate p2p_upstream_cdf050a5 'npm_run_build' 'cd /workspace/repo && cd /workspace/repo && timeout 240 npm run build 2>&1 | tail -3'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_dead_hooks_deleted": 0.18, "t1_f2p_overlay_owns_state_machine": 0.22, "t2_f2p_overlay_callback_api_invoked": 0.18, "t2_f2p_overlay_handle_methods": 0.12, "t3_f2p_types_and_chain_cleaned": 0.15, "t3_f2p_useinpainting_purged": 0.15}
P2P_GATING = ["p2p_src_unmodified"]
P2P_REGRESSION = ["p2p_upstream_523760b1", "p2p_upstream_cdf050a5"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0