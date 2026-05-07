Implement the following plan:

# Fix: Sort checkpoint IDs by timestamp in `resumeMultipleCheckpoints`

## Context

`entire resume` on a branch whose HEAD is a git CLI squash merge restores checkpoints in the wrong order. GitHub squash merges list `Entire-Checkpoint` trailers chronologically (oldest first), but git CLI squash merges list them in reverse order (newest first). Since `RestoreLogsOnly` writes session files to disk eagerly, the last checkpoint processed "wins" — meaning the oldest transcript overwrites the newest one.

The fix: read metadata for all checkpoint IDs upfront, sort by `CreatedAt` ascending (oldest first), then iterate. The newest checkpoint writes last and wins on disk.

## Changes

### 1. Modify `resumeMultipleCheckpoints` in `cmd/entire/cli/resume.go` (lines 186-259)

**Current flow:**
```
for _, cpID := range checkpointIDs {
    metadata := ReadCheckpointMetadata(tree, cpID.Path())
    strat.RestoreLogsOnly(ctx, point, force)
    deduplicateSessions(allSessions, sessions)
}
```

**New flow:**
```
// Phase 1: Read metadata for all checkpoints, collect into slice
type checkpointWithMeta struct {
    cpID     id.CheckpointID
    metadata *CheckpointInfo
}
var checkpoints []checkpointWithMeta
for _, cpID := range checkpointIDs {
    metadata := ReadCheckpointMetadata(tree, cpID.Path())
    if metadata != nil {
        checkpoints = append(checkpoints, checkpointWithMeta{cpID, metadata})
    }
}

// Phase 2: Sort by CreatedAt ascending (oldest first → newest writes last)
sort.Slice(checkpoints, func(i, j int) bool {
    return checkpoints[i].metadata.CreatedAt.Before(checkpoints[j].metadata.CreatedAt)
})

// Phase 3: Iterate sorted checkpoints (same logic as before)
for _, cp := range checkpoints {
    point := RewindPoint{IsLogsOnly: true, CheckpointID: cp.cpID, Agent: cp.metadata.Agent}
    sessions := strat.RestoreLogsOnly(ctx, point, force)
    allSessions = deduplicateSessions(allSessions, sessions)
}
```

Key types/functions already available:
- `strategy.ReadCheckpointMetadata(tree, path)` returns `*CheckpointInfo` with `CreatedAt time.Time` — `cmd/entire/cli/strategy/common.go:363`
- `strategy.CheckpointInfo.CreatedAt` — `cmd/entire/cli/strategy/manual_commit_types.go`
- `sort.Slice` already imported in `resume.go`

### 2. Add test in `cmd/entire/cli/resume_test.go`

Add a test case for `resumeMultipleCheckpoints` ordering behavior, or extend existing `TestDeduplicateSessions` tests to verify that order-independence holds. The `deduplicateSessions` function is already well-tested (line 441-547), but a test confirming that reverse-ordered checkpoint IDs produce the same result as chronological ones would be valuable.

## Files to modify

- `cmd/entire/cli/resume.go` — refactor `resumeMultipleCheckpoints` (lines 186-259)
- `cmd/entire/cli/resume_test.go` — add ordering test

## Verification

```bash
mise run fmt && mise run lint && mise run test:ci
```