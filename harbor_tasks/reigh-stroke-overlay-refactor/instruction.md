Implement the following plan:

# Refactor: Move drawing state machine into StrokeOverlay

## Context

After fixing three bugs in the inpainting drawing system (pointer capture on wrong element, stale closures, buttons===0 false positive), the underlying structural issues are clear:

- **Pointer handlers thread through 4 component layers untouched**: `useInpainting` → `ImageLightbox` → `LightboxLayout` → `MediaDisplayWithCanvas` → `StrokeOverlay` — all just passing functions through as props
- **useStrokeRendering is dead code**: It renders to hidden 2D canvases that are completely redundant with StrokeOverlay's Konva rendering. Mask export was moved to `StrokeOverlay.exportMask()` already.
- **Three overlapping pointer-release mechanisms** made the bugs hard to find: Konva pointerUp, global window listeners in usePointerHandlers, and global window listeners in useDragState
- **Drawing state lives far from where it's used**: `isDrawing`, `currentStroke`, drag state all live in hooks outside StrokeOverlay, then get passed back in as props

The fix: StrokeOverlay should own its drawing state machine internally. Parent components just pass in strokes (data) and receive callbacks when strokes change.

## Plan (4 incremental steps)

### Step 1: Delete useStrokeRendering (~270 lines)

This hook renders strokes on hidden 2D canvases. StrokeOverlay replaced it entirely. Only one consumer remains: `getDeleteButtonPosition` in `useInpainting.ts` uses `imageToCanvas()` and `canvasSize`.

**Changes:**
- `useInpainting.ts`: Remove `useStrokeRendering` import/call. Rewrite `getDeleteButtonPosition` with inline coordinate math (it's just `imageX / imageWidth * displayWidth` — 5 lines).
- `useInpainting.ts`: Remove `redrawStrokes` from return value.
- `useInpaintActions.ts`: Remove `redrawStrokes` parameter and all calls to it (4 call sites). It's a no-op now since Konva re-renders reactively.
- `useInpainting.ts`: Stop passing `redrawStrokes` to `useInpaintActions`.
- Delete `useStrokeRendering.ts`.
- Remove `displayCanvasRef` and `maskCanvasRef` from `useInpainting` props (and from `types.ts`).

**Files:** `useInpainting.ts`, `useInpaintActions.ts`, `types.ts`, delete `useStrokeRendering.ts`

### Step 2: Move drawing state machine into StrokeOverlay

This is the main change. StrokeOverlay absorbs `usePointerHandlers` and `useDragState` — it owns `isDrawing`, `currentStroke`, drag state, and the pointer event state machine internally.

**New StrokeOverlay props (replacing handler props):**
```typescript
// IN: data + mode (same as now)
strokes: BrushStroke[];
isEraseMode: boolean;
brushSize: number;
annotationMode: 'rectangle' | null;
imageWidth: number;
imageHeight: number;
displayWidth: number;
displayHeight: number;
// IN: mode flags (new — needed for guard logic currently in usePointerHandlers)
isInpaintMode: boolean;
isAnnotateMode: boolean;
editMode: EditMode;

// OUT: callbacks (replacing prop-threaded handlers)
onStrokeComplete: (stroke: BrushStroke) => void;      // new stroke drawn
onStrokesChange: (strokes: BrushStroke[]) => void;     // drag mutation
onSelectionChange: (shapeId: string | null) => void;   // selection changed
onTextModeHint: () => void;                             // tried to draw in text mode
```

**New StrokeOverlayHandle (ref methods):**
```typescript
exportMask: (options?: { pixelRatio?: number }) => string | null;  // existing
getSelectedShapeId: () => string | null;                            // for getDeleteButtonPosition
getSelectedShapePosition: () => { x: number; y: number } | null;   // for delete button
```

**What moves inside StrokeOverlay:**
- All of `usePointerHandlers` (isDrawing, currentStroke, refs, pointer down/move/up logic)
- All of `useDragState` (isDragging, dragOffset, dragMode, corner drag)
- `selectedShapeId` state
- Single global pointerup listener (replacing 2 overlapping ones)
- Pointer capture on `stage.content` (already there, now the only mechanism)

**What stays in useInpainting:**
- `useMediaPersistence` (stroke arrays, persistence)
- `useTaskGeneration` (task creation)
- Mode state (editMode, annotationMode, isEraseMode)
- `onStrokeComplete` callback: appends to correct stroke array based on mode
- `onStrokesChange` callback: updates correct stroke array (for drag mutations)

**Files:** Rewrite `StrokeOverlay.tsx` (~380→~550 lines), delete `usePointerHandlers.ts` (~390 lines), delete `useDragState.ts` (~124 lines)

### Step 3: Move action handlers into StrokeOverlay ref

`useInpaintActions` has 4 simple functions (undo, clear, delete, toggleFreeForm) plus a keyboard listener. These operate on strokes + selection, which now live in StrokeOverlay.

**Add to StrokeOverlayHandle:**
```typescript
undo: () => void;
clear: () => void;
deleteSelected: () => void;
toggleFreeForm: () => void;
```

The keyboard listener (Delete/Backspace) moves into StrokeOverlay since it needs `selectedShapeId`.

**Changes:**
- `useInpainting.ts`: Remove `useInpaintActions` import/call. Expose action methods via `strokeOverlayRef.current?.undo()` etc.
- Delete `useInpaintActions.ts`.

**Files:** `StrokeOverlay.tsx`, `useInpainting.ts`, delete `useInpaintActions.ts`

### Step 4: Clean up prop threading

With StrokeOverlay owning its state machine, we can remove the pass-through props from the component chain.

**Remove from the chain:**
- `handleKonvaPointerDown`, `handleKonvaPointerMove`, `handleKonvaPointerUp`, `handleShapeClick` — no longer threaded
- `isDrawing`, `currentStroke` — internal to StrokeOverlay
- `selectedShapeId` — internal to StrokeOverlay (exposed via ref)

**Keep in the chain:**
- `strokeOverlayRef` — still passed from useInpainting → LightboxLayout → MediaDisplayWithCanvas
- `brushStrokes`, `isEraseMode`, `brushSize`, `annotationMode` — data props, same as now
- Mode flags (`isInpaintMode`, `isAnnotateMode`, `editMode`) — new props on StrokeOverlay

**Update `getDeleteButtonPosition`:**
- Use `strokeOverlayRef.current?.getSelectedShapePosition()` instead of `imageToCanvas` + `canvasSize`
- Or keep the inline math from Step 1 and use `strokeOverlayRef.current?.getSelectedShapeId()` to find the shape

**Files:** `ImageLightbox.tsx`, `LightboxLayout.tsx`, `MediaDisplayWithCanvas.tsx`, `types.ts` (UseInpaintingReturn)

## Net impact

| | Before | After |
|---|---|---|
| usePointerHandlers.ts | 390 lines | deleted |
| useDragState.ts | 124 lines | deleted |
| useStrokeRendering.ts | 270 lines | deleted |
| useInpaintActions.ts | 163 lines | deleted |
| StrokeOverlay.tsx | 420 lines | ~550 lines |
| useInpainting.ts | 350 lines | ~200 lines |
| **Net** | **~1717 lines** | **~750 lines** |

One pointer release mechanism (pointer capture) instead of three. Drawing state machine lives next to Konva, not 4 layers away.

## Verification

1. **Draw freehand strokes** in inpaint mode — strokes render while drawing and persist after release
2. **Draw rectangles** in annotate mode — preview shows while dragging, commits on release
3. **Select/drag/resize rectangles** — move (edge click), resize (corner drag), free-form (double-click corner)
4. **Undo/clear/delete** — all actions work, keyboard Delete works on selected shape
5. **Edge drawing** — drag pointer outside canvas bounds, stroke continues and completes correctly
6. **Mask export** — generate inpaint task, verify mask is correct
7. **Mode switching** — switch between inpaint/annotate/text, strokes persist per-mode
8. **Erase mode** — erase strokes work correctly


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /user_c042661f/.claude/projects/-Users-user_c042661f-Documents-reigh/8da94ca5-4253-4319-b07b-3d9d7dfb268f.jsonl
