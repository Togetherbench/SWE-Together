Implement the following plan:

# Eliminate TimelineModeContent — remove pure pass-through layer

## Context

The data path from `ShotImagesEditor` to `SegmentOutputStrip` traverses 4 layers:
```
ShotImagesEditor → TimelineModeContent → Timeline → TimelineContainer → SegmentOutputStrip
```

`TimelineModeContent` is a pure pass-through with **zero local logic** — it receives 65 props, destructures all 65, and forwards all 65 to `<Timeline>`. Its only unique rendering is a 6-line conditional div for unpositioned generations. Every time we thread a new prop to Timeline (like `isSegmentsLoading`, `hasPendingTask`), we have to declare it three extra times (interface, destructure, JSX) in this component for no reason.

Eliminating it reduces the chain to 3 layers, where every remaining layer owns real logic.

## Plan

### 1. ShotImagesEditor.tsx — Render Timeline directly

Replace `<TimelineModeContent ...65 props />` with:
```tsx
<>
  <Timeline
    key={`timeline-${selectedShotId}`}
    shotId={selectedShotId}
    ...same 63 props currently passed to TimelineModeContent
    (minus unpositionedGenerationsCount, onOpenUnpositionedPane — those are TimelineModeContent-only)
  />
  {unpositionedGenerationsCount > 0 && (
    <div className="mt-4">
      <div className="flex items-center justify-between p-3 bg-muted/50 rounded-lg border border-dashed">
        <div className="text-sm text-muted-foreground">
          {unpositionedGenerationsCount} unpositioned generation{unpositionedGenerationsCount !== 1 ? 's' : ''}
        </div>
        <Button variant="outline" size="sm" onClick={onOpenUnpositionedPane} className="text-xs">
          View & Position
        </Button>
      </div>
    </div>
  )}
</>
```

Note: The prop names differ slightly between ShotImagesEditor→TimelineModeContent and TimelineModeContent→Timeline. Need to map carefully:
- `batchVideoFrames` → Timeline's `frameSpacing`
- `onFramePositionsChange` → not forwarded (TimelineModeContent passes it but Timeline doesn't use it — check)
- `handleClearEnhancedPromptByIndex` → Timeline's `onClearEnhancedPrompt`
- `handleTimelineChange` → Timeline's `onTimelineChange`
- `handleDragStateChange` → Timeline's `onDragStateChange`
- `handlePairClick` → Timeline's `onPairClick`
- `updatePairFrameCount` → Timeline's `onSegmentFrameCountChange`
- `registerTrailingUpdater` → Timeline's `onRegisterTrailingUpdater`
- `onAddToShot` adapter → Timeline's `onAddToShot`
- `onAddToShotWithoutPosition` adapter → Timeline's `onAddToShotWithoutPosition`
- `onCreateShot` adapter → Timeline's `onCreateShot`

Also need to add Timeline's import (replace TimelineModeContent import). Timeline is at `../../Timeline` from ShotImagesEditor's perspective, or `../Timeline` — check the existing import path from TimelineModeContent.

### 2. ShotImagesEditor/components/index.ts — Remove exports

Remove:
```ts
export { TimelineModeContent } from './TimelineModeContent';
export type { TimelineModeContentProps } from './TimelineModeContent';
```

### 3. Delete TimelineModeContent.tsx

Remove file entirely — no other consumers.

## Files to modify

| File | Change |
|------|--------|
| `src/tools/travel-between-images/components/ShotImagesEditor.tsx` | Import Timeline directly, inline JSX + unpositioned div |
| `src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts` | Remove 2 export lines |
| `src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx` | Delete file |

## What this does NOT change

- SegmentOutputStrip — no changes needed
- BatchModeContent — separate component, unaffected (has its own unpositioned helper)

## Dead code cleanup (after the core refactor)

After removing TimelineModeContent, some props and constants in downstream components become dead code — they were only ever passed by TimelineModeContent and are no longer used by any caller. Review and clean these up:

### Timeline.tsx
Remove dead props from the component interface and destructure that no longer have any caller after TMC is deleted. Also remove any module-level constants that only existed as defaults for those dead props (e.g. empty-array sentinels).

### TimelineContainer/
Check TimelineContainer's types and component file for any props or variables that were only threaded through from the now-removed dead props above. Remove them.

## Verification

1. Timeline renders identically (same props, same behavior)
2. Unpositioned generations helper still shows below timeline when count > 0
3. Batch mode unaffected (separate component)
4. TypeScript: `npx tsc --noEmit` passes


