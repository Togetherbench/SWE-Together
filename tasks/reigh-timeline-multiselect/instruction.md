Implement the following plan:

# Timeline Multi-Select Implementation Plan

## Summary

Add multi-select functionality to the Timeline view, supporting both desktop (click/drag) and iPad (tap-to-select, tap-to-place) interactions. Reuses existing `SelectionActionBar` component.

## Key Decision: Multi-Drag Behavior

**Chosen: Bundle Together (5 frames apart)**
- Selecting items does NOT change their positions
- Only when you drag/move selected items do they bundle
- Example: Items at frames 0, 30, 60 selected → drag to frame 10 → become 10, 15, 20
- Simple, predictable behavior
- Keeps items compact, won't overflow timeline

---

## Implementation Phases

### Phase 1: Create `useTimelineSelection.ts` Hook

**New file:** `src/tools/travel-between-images/components/Timeline/hooks/useTimelineSelection.ts`

State:
- `selectedIds: string[]` - currently selected item IDs
- `showSelectionBar: boolean` - delayed by 200ms

Behaviors:
- **Click/Tap**: Toggle selection (add if not selected, remove if selected)
- No modifier keys required - each click toggles that item
- Selection bar appears when 1+ items selected

---

### Phase 2: Modify `TimelineItem.tsx`

Add props:
- `isSelected: boolean`
- `onSelectionClick: (e: React.MouseEvent) => void`

Visual changes:
- Blue ring/border when selected (similar to existing `isSelectedForMove`)
- Selection count badge when multiple items selected

---

### Phase 3: Modify `useTimelineDrag.ts` for Multi-Item Drag

Add prop: `selectedIds: string[]`

New logic:
```typescript
// If only 1 item selected: use existing single-item drag (unchanged)
if (selectedIds.length === 1) {
  return existingSingleDragLogic();
}

// If multiple selected: bundle them
const sortedSelected = selectedIds
  .map(id => ({ id, frame: framePositions.get(id) }))
  .sort((a, b) => a.frame - b.frame);

// Bundle items 5 frames apart starting at target frame
const BUNDLE_GAP = 5;
sortedSelected.forEach((item, index) => {
  newPositions.set(item.id, targetFrame + (index * BUNDLE_GAP));
});

// Apply fluid timeline constraints
```

---

### Phase 4: Modify `useTapToMove.ts` for Multi-Item Movement

Change from single-select to using external `selectedIds`:
- **Single item selected**: Moves to exact tapped position (same as current behavior)
- **Multiple items selected**: Bundle items 5 frames apart at tapped position
- Clear selection after move

---

### Phase 5: Integrate `SelectionActionBar` in `TimelineContainer.tsx`

```tsx
{showSelectionBar && selectedIds.length > 0 && (
  <SelectionActionBar
    selectedCount={selectedIds.length}
    onDeselect={clearSelection}
    onDelete={() => handleBatchDelete(selectedIds)}
    onNewShot={onNewShotFromSelection ? () => {
      onNewShotFromSelection(selectedIds);
    } : undefined}
  />
)}
```

---

## Files to Modify

| File | Change |
|------|--------|
| `Timeline/hooks/useTimelineSelection.ts` | **NEW** - Selection state hook |
| `Timeline/hooks/useTimelineDrag.ts` | Add multi-item drag support |
| `Timeline/hooks/useTapToMove.ts` | Use external selectedIds, multi-item move |
| `Timeline/TimelineItem.tsx` | Add `isSelected` prop and visuals |
| `Timeline/TimelineContainer.tsx` | Integrate selection hook + SelectionActionBar |
| `Timeline/utils/timeline-utils.ts` | Add `applyFluidTimelineMulti()` helper |

---

## Edge Cases

1. **Frame 0**: Must always have an item - if moved away, reassign to nearest
2. **Gap constraints**: Max 81 frames between items enforced
3. **Non-contiguous selection**: Items A, C selected (B not) - maintain relative positions
4. **Selection during drag**: Lock selection toggles while dragging

---

## Verification

1. Click/tap item → toggles selection (position unchanged), shows SelectionActionBar
2. Click/tap another item → adds to selection (no modifier keys needed)
3. Click/tap selected item → removes from selection
4. Drag single selected item → moves to new position (same as before)
5. Drag with multiple selected → all bundle together (5 frames apart)
6. Tablet single item: tap to select, tap timeline → moves to exact position
7. Tablet multiple items: tap to select each, tap timeline → bundle at position
8. SelectionActionBar Delete → deletes all selected items
9. SelectionActionBar New Shot → creates shot from selected
10. Frame 0 constraint respected
11. Gap constraints (81 frames max) respected


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /user_c042661f/.claude/projects/-Users-user_c042661f/a29a9b6d-d706-459e-85e4-763d642a98ce.jsonl
