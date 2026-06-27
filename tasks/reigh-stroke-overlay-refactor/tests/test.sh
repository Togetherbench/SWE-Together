#!/bin/bash
set +e

mkdir -p /logs/verifier
export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

REPO=""
for candidate in /workspace/repo /workspace/reigh /workspace/Reigh; do
    if [ -d "$candidate" ]; then REPO="$candidate"; break; fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 2 -name "package.json" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
fi

REWARD=0
finalize() {
    awk "BEGIN{printf \"FINAL REWARD: %.4f\n\", $REWARD}"
    awk "BEGIN{printf \"%.4f\", $REWARD}" > /logs/verifier/reward.txt
    exit 0
}

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot locate repo"
    finalize
fi

cd "$REPO"

INPAINT_DIR="$REPO/src/shared/components/MediaLightbox/hooks/inpainting"
COMP_DIR="$REPO/src/shared/components/MediaLightbox/components"
OVERLAY="$COMP_DIR/StrokeOverlay.tsx"
INPAINT_HOOK="$REPO/src/shared/components/MediaLightbox/hooks/useInpainting.ts"
ACTIONS_HOOK="$INPAINT_DIR/useInpaintActions.ts"
TYPES_FILE="$INPAINT_DIR/types.ts"
VIDEO_LB="$REPO/src/shared/components/MediaLightbox/VideoLightbox.tsx"
EDIT_CTX="$REPO/src/shared/components/MediaLightbox/contexts/ImageEditContext.tsx"

add_reward() {
    local amount=$1
    local label=$2
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $amount}")
    echo "  +${amount}  ${label}"
}

read_file() {
    [ -f "$1" ] && cat "$1" || echo ""
}

# ════════════════════════════════════════════════════════════════════
# Gates total = 1.0
#   G1 (0.15) Step 1a: useStrokeRendering deleted + redrawStrokes purged
#   G2 (0.15) Step 1b: useInpaintActions cleaned of redrawStrokes (behavioral via AST)
#   G3 (0.15) Step 1c: types.ts: handler props + canvas refs removed
#   G4 (0.20) Step 2a: StrokeOverlay exposes new callback API (props)
#   G5 (0.20) Step 2b: StrokeOverlay owns drawing state machine internally (substantive)
#   G6 (0.10) Step 2c: Old prop-threaded handlers removed; consumers updated
#   G7 (0.05) Cross-file consistency: VideoLightbox stub matches new shape
# ════════════════════════════════════════════════════════════════════

echo "REPO=$REPO"

# ─── G1: useStrokeRendering removed + redrawStrokes purged from useInpainting ──
echo "═══ G1: useStrokeRendering deletion + redrawStrokes purge ═══"
G1=0
SR_DELETED=0
[ ! -f "$INPAINT_DIR/useStrokeRendering.ts" ] && SR_DELETED=1

INP_SRC=$(read_file "$INPAINT_HOOK")
INP_HAS_SR_IMPORT=0
INP_HAS_REDRAW=0
echo "$INP_SRC" | grep -q "useStrokeRendering" && INP_HAS_SR_IMPORT=1
echo "$INP_SRC" | grep -q "redrawStrokes" && INP_HAS_REDRAW=1

if [ $SR_DELETED -eq 1 ]; then
    G1=$(awk "BEGIN{print $G1 + 0.06}")
    echo "    ✓ useStrokeRendering.ts deleted (+0.06)"
else
    echo "    ✗ useStrokeRendering.ts still present"
fi
if [ $INP_HAS_SR_IMPORT -eq 0 ] && [ -n "$INP_SRC" ]; then
    G1=$(awk "BEGIN{print $G1 + 0.04}")
    echo "    ✓ useInpainting no longer references useStrokeRendering (+0.04)"
fi
if [ $INP_HAS_REDRAW -eq 0 ] && [ -n "$INP_SRC" ]; then
    G1=$(awk "BEGIN{print $G1 + 0.05}")
    echo "    ✓ useInpainting has no redrawStrokes references (+0.05)"
fi
add_reward $G1 "G1 total"

# ─── G2: useInpaintActions cleaned (behavioral: callable without redrawStrokes) ──
echo "═══ G2: useInpaintActions purged of redrawStrokes ═══"
G2=0
ACT_SRC=$(read_file "$ACTIONS_HOOK")
if [ -n "$ACT_SRC" ]; then
    REDRAW_COUNT=$(echo "$ACT_SRC" | grep -c "redrawStrokes")
    PROP_REDRAW=0
    echo "$ACT_SRC" | grep -E "redrawStrokes\s*:" >/dev/null && PROP_REDRAW=1
    echo "    redrawStrokes occurrences in useInpaintActions: $REDRAW_COUNT"
    if [ "$REDRAW_COUNT" -eq 0 ]; then
        G2=$(awk "BEGIN{print $G2 + 0.10}")
        echo "    ✓ all redrawStrokes references removed (+0.10)"
    elif [ "$REDRAW_COUNT" -le 2 ]; then
        G2=$(awk "BEGIN{print $G2 + 0.04}")
        echo "    ~ partial removal (+0.04)"
    fi
    # Verify the actions still implement the four core handlers
    HCNT=0
    for h in handleUndo handleClearMask handleDeleteSelected handleToggleFreeForm; do
        echo "$ACT_SRC" | grep -q "$h" && HCNT=$((HCNT+1))
    done
    if [ "$HCNT" -ge 4 ]; then
        G2=$(awk "BEGIN{print $G2 + 0.05}")
        echo "    ✓ all 4 action handlers still implemented (+0.05)"
    elif [ "$HCNT" -ge 2 ]; then
        G2=$(awk "BEGIN{print $G2 + 0.02}")
    fi
fi
add_reward $G2 "G2 total"

# ─── G3: types.ts cleanup ──
echo "═══ G3: types.ts handler/canvas-ref removal ═══"
G3=0
TYPES_SRC=$(read_file "$TYPES_FILE")
if [ -n "$TYPES_SRC" ]; then
    REMOVED=0
    for sym in handleKonvaPointerDown handleKonvaPointerMove handleKonvaPointerUp displayCanvasRef maskCanvasRef redrawStrokes; do
        if ! echo "$TYPES_SRC" | grep -q "$sym"; then
            REMOVED=$((REMOVED+1))
        fi
    done
    echo "    types.ts symbols removed: $REMOVED/6"
    # Also check that old DragState interface is gone (state moved into overlay)
    DRAGSTATE_GONE=0
    if ! echo "$TYPES_SRC" | grep -E "interface\s+DragState" >/dev/null; then
        DRAGSTATE_GONE=1
    fi

    if [ $REMOVED -ge 6 ]; then
        G3=$(awk "BEGIN{print $G3 + 0.12}")
        echo "    ✓ all 6 stale type symbols removed (+0.12)"
    elif [ $REMOVED -ge 4 ]; then
        G3=$(awk "BEGIN{print $G3 + 0.07}")
    elif [ $REMOVED -ge 2 ]; then
        G3=$(awk "BEGIN{print $G3 + 0.03}")
    fi
    if [ $DRAGSTATE_GONE -eq 1 ]; then
        G3=$(awk "BEGIN{print $G3 + 0.03}")
        echo "    ✓ DragState interface removed from types (+0.03)"
    fi
fi
add_reward $G3 "G3 total"

# ─── G4: StrokeOverlay new callback API (probed via prop usage) ──
echo "═══ G4: StrokeOverlay new callback API ═══"
G4=0
OV_SRC=$(read_file "$OVERLAY")
if [ -n "$OV_SRC" ]; then
    CB=0
    # Each callback must appear AS A PROP — i.e., destructured or part of props interface
    for cb in onStrokeComplete onStrokesChange onSelectionChange onTextModeHint; do
        # Must appear at least once destructured or typed in props
        if echo "$OV_SRC" | grep -E "${cb}\s*[?:,)}]" >/dev/null; then
            CB=$((CB+1))
        fi
    done
    echo "    new callback props present: $CB/4"
    case $CB in
        4) G4=$(awk "BEGIN{print $G4 + 0.12}"); echo "    ✓ all 4 callbacks (+0.12)" ;;
        3) G4=$(awk "BEGIN{print $G4 + 0.08}") ;;
        2) G4=$(awk "BEGIN{print $G4 + 0.04}") ;;
        1) G4=$(awk "BEGIN{print $G4 + 0.01}") ;;
    esac

    # New mode-flag props (isInpaintMode, isAnnotateMode, editMode) — required by spec
    MF=0
    for f in isInpaintMode isAnnotateMode editMode; do
        if echo "$OV_SRC" | grep -E "${f}\s*[?:,)}]" >/dev/null; then
            MF=$((MF+1))
        fi
    done
    echo "    mode-flag props present: $MF/3"
    case $MF in
        3) G4=$(awk "BEGIN{print $G4 + 0.05}"); echo "    ✓ all 3 mode flags (+0.05)" ;;
        2) G4=$(awk "BEGIN{print $G4 + 0.03}") ;;
        1) G4=$(awk "BEGIN{print $G4 + 0.01}") ;;
    esac

    # New handle methods (getSelectedShapeId / getSelectedShapePosition)
    HM=0
    echo "$OV_SRC" | grep -q "getSelectedShapeId" && HM=$((HM+1))
    echo "$OV_SRC" | grep -q "getSelectedShapePosition" && HM=$((HM+1))
    if [ $HM -eq 2 ]; then
        G4=$(awk "BEGIN{print $G4 + 0.03}")
        echo "    ✓ both new handle methods (+0.03)"
    elif [ $HM -eq 1 ]; then
        G4=$(awk "BEGIN{print $G4 + 0.01}")
    fi
fi
add_reward $G4 "G4 total"

# ─── G5: StrokeOverlay owns drawing state machine internally ──
echo "═══ G5: StrokeOverlay state machine ownership ═══"
G5=0
if [ -n "$OV_SRC" ]; then
    OV_LINES=$(echo "$OV_SRC" | wc -l)
    echo "    StrokeOverlay.tsx lines: $OV_LINES"

    # Check for internal state declarations (not just references)
    OWNS_DRAWING=0
    OWNS_STROKE=0
    OWNS_DRAG=0
    OWNS_SELECTION=0
    OWNS_PTRDOWN=0
    OWNS_PTRMOVE=0
    OWNS_PTRUP=0
    OWNS_GLOBAL_LISTENER=0

    # useState/useRef declarations for internal state — these MUST be declared inside, not received as props
    if echo "$OV_SRC" | grep -E "(useState|useRef)\s*[<(][^)]*\)\s*[;,]?" >/dev/null; then
        :
    fi
    # isDrawing owned: declared via useState or useRef, OR setIsDrawing exists
    if echo "$OV_SRC" | grep -E "(setIsDrawing|isDrawingRef|isDrawing\s*,\s*set)" >/dev/null; then
        OWNS_DRAWING=1
    fi
    if echo "$OV_SRC" | grep -E "(setCurrentStroke|currentStrokeRef|currentStroke\s*,\s*set)" >/dev/null; then
        OWNS_STROKE=1
    fi
    if echo "$OV_SRC" | grep -E "(setIsDragging|setDragOffset|setDragMode|dragOffset\s*,\s*set|isDragging\s*,\s*set|draggingCorner)" >/dev/null; then
        OWNS_DRAG=1
    fi
    if echo "$OV_SRC" | grep -E "(setSelectedShapeId|selectedShapeId\s*,\s*set)" >/dev/null; then
        OWNS_SELECTION=1
    fi
    # Internal pointer handlers (defined as functions/consts, not just received as props)
    if echo "$OV_SRC" | grep -E "(const|function)\s+(handlePointerDown|onPointerDownInternal|handleStagePointerDown)" >/dev/null; then
        OWNS_PTRDOWN=1
    fi
    if echo "$OV_SRC" | grep -E "(const|function)\s+(handlePointerMove|onPointerMoveInternal|handleStagePointerMove)" >/dev/null; then
        OWNS_PTRMOVE=1
    fi
    if echo "$OV_SRC" | grep -E "(const|function)\s+(handlePointerUp|onPointerUpInternal|handleStagePointerUp)" >/dev/null; then
        OWNS_PTRUP=1
    fi
    # Global pointerup listener
    if echo "$OV_SRC" | grep -E "(window|document)\.addEventListener\([\"']pointerup" >/dev/null; then
        OWNS_GLOBAL_LISTENER=1
    fi

    SCORE=$((OWNS_DRAWING + OWNS_STROKE + OWNS_DRAG + OWNS_SELECTION))
    PTR_SCORE=$((OWNS_PTRDOWN + OWNS_PTRMOVE + OWNS_PTRUP))
    echo "    state ownership: drawing=$OWNS_DRAWING stroke=$OWNS_STROKE drag=$OWNS_DRAG selection=$OWNS_SELECTION (=$SCORE/4)"
    echo "    pointer handlers internal: down=$OWNS_PTRDOWN move=$OWNS_PTRMOVE up=$OWNS_PTRUP (=$PTR_SCORE/3)"
    echo "    global pointerup listener: $OWNS_GLOBAL_LISTENER"

    # Significant size growth indicates real absorption
    if [ "$OV_LINES" -gt 500 ]; then
        SIZE_BONUS=1
    elif [ "$OV_LINES" -gt 400 ]; then
        SIZE_BONUS=1
    else
        SIZE_BONUS=0
    fi

    if [ $SCORE -ge 4 ] && [ $PTR_SCORE -ge 3 ] && [ $SIZE_BONUS -eq 1 ]; then
        G5=$(awk "BEGIN{print $G5 + 0.16}")
        echo "    ✓ full state machine absorbed (+0.16)"
    elif [ $SCORE -ge 3 ] && [ $PTR_SCORE -ge 2 ]; then
        G5=$(awk "BEGIN{print $G5 + 0.10}")
    elif [ $SCORE -ge 2 ] && [ $PTR_SCORE -ge 1 ]; then
        G5=$(awk "BEGIN{print $G5 + 0.04}")
    elif [ $SCORE -ge 1 ]; then
        G5=$(awk "BEGIN{print $G5 + 0.01}")
    fi

    if [ $OWNS_GLOBAL_LISTENER -eq 1 ]; then
        G5=$(awk "BEGIN{print $G5 + 0.04}")
        echo "    ✓ global pointerup listener present (+0.04)"
    fi
fi
add_reward $G5 "G5 total"

# ─── G6: Old prop-threaded handlers removed; useDragState/usePointerHandlers gone ──
echo "═══ G6: Dead hooks deleted; old API removed ═══"
G6=0
USEDRAG_DEL=0
USEPH_DEL=0
[ ! -f "$INPAINT_DIR/useDragState.ts" ] && USEDRAG_DEL=1
[ ! -f "$INPAINT_DIR/usePointerHandlers.ts" ] && USEPH_DEL=1
if [ $USEDRAG_DEL -eq 1 ]; then
    G6=$(awk "BEGIN{print $G6 + 0.03}")
    echo "    ✓ useDragState.ts deleted (+0.03)"
fi
if [ $USEPH_DEL -eq 1 ]; then
    G6=$(awk "BEGIN{print $G6 + 0.03}")
    echo "    ✓ usePointerHandlers.ts deleted (+0.03)"
fi
# Also: useInpainting must no longer import either
if [ -n "$INP_SRC" ]; then
    if ! echo "$INP_SRC" | grep -q "usePointerHandlers" && ! echo "$INP_SRC" | grep -q "useDragState"; then
        G6=$(awk "BEGIN{print $G6 + 0.04}")
        echo "    ✓ useInpainting drops both stale hook imports (+0.04)"
    fi
fi
add_reward $G6 "G6 total"

# ─── G7: VideoLightbox stub updated to match new shape ──
echo "═══ G7: VideoLightbox stub consistency ═══"
G7=0
VL_SRC=$(read_file "$VIDEO_LB")
if [ -n "$VL_SRC" ]; then
    # Old stub keys gone
    OLD_GONE=0
    if ! echo "$VL_SRC" | grep -E "handleKonvaPointerDown\s*:" >/dev/null \
       && ! echo "$VL_SRC" | grep -E "handleKonvaPointerMove\s*:" >/dev/null \
       && ! echo "$VL_SRC" | grep -E "handleKonvaPointerUp\s*:" >/dev/null; then
        OLD_GONE=1
    fi
    # isDrawing/currentStroke removed from stub
    STATE_GONE=0
    if ! echo "$VL_SRC" | grep -E "isDrawing\s*:\s*false" >/dev/null \
       && ! echo "$VL_SRC" | grep -E "currentStroke\s*:" >/dev/null; then
        STATE_GONE=1
    fi
    # New callback stubs added
    NEW_CB=0
    for cb in onStrokeComplete onStrokesChange onSelectionChange onTextModeHint handleStrokeComplete handleStrokesChange; do
        echo "$VL_SRC" | grep -E "${cb}\s*:" >/dev/null && NEW_CB=$((NEW_CB+1))
    done

    if [ $OLD_GONE -eq 1 ] && [ $STATE_GONE -eq 1 ] && [ $NEW_CB -ge 3 ]; then
        G7=$(awk "BEGIN{print $G7 + 0.05}")
        echo "    ✓ video stub fully migrated (+0.05)"
    elif [ $OLD_GONE -eq 1 ] || [ $STATE_GONE -eq 1 ]; then
        G7=$(awk "BEGIN{print $G7 + 0.02}")
    fi
fi
add_reward $G7 "G7 total"

echo ""
echo "═══ SUMMARY ═══"
finalize

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
