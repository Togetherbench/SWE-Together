Implement the following plan:

# Plan: Resume Only From Latest Checkpoint on Squash Merges

## Context

When a feature branch is squash-merged, all `Entire-Checkpoint` trailers from the original commits end up in the squash commit. PR #534 added logic to restore sessions from **every** checkpoint, deduplicating by session ID. But this restores stale/ended sessions that the user will never continue. We should only resume from the **latest** checkpoint — the one representing the final state of the branch when the developer finished working.

## Changes

### 1. Simplify `resumeFromCurrentBranch` in `cmd/entire/cli/resume.go`

Replace the multi-checkpoint branch (lines 157-159) with:
- Resolve the latest checkpoint from the list using metadata timestamps
- Show info message: `"Found N checkpoints on the latest commit in this branch, resuming from the latest (N-1 older checkpoints skipped)"`
- Fall through to the existing single-checkpoint path (`resumeSession`)

```go
// Multiple checkpoints (squash merge): resolve latest and resume from it
if len(result.checkpointIDs) > 1 {
    latest, err := resolveLatestCheckpoint(repo, result.checkpointIDs)
    if err != nil {
        // Fallback: use last trailer
        latest = result.checkpointIDs[len(result.checkpointIDs)-1]
    }
    skipped := len(result.checkpointIDs) - 1
    fmt.Fprintf(os.Stderr, "Found %d checkpoints on the latest commit in this branch, resuming from the latest (%d older checkpoints skipped)\n",
        len(result.checkpointIDs), skipped)
    checkpointID = latest
}
```

### 2. Add `resolveLatestCheckpoint` helper in `resume.go`

Reads metadata for each checkpoint ID, returns the one with the latest `CreatedAt`. Reuses `collectCheckpointsByAge` (already sorts ascending, so take the last element).

```go
func resolveLatestCheckpoint(repo *git.Repository, checkpointIDs []id.CheckpointID) (id.CheckpointID, error) {
    metadataTree, err := strategy.GetMetadataBranchTree(repo)
    if err != nil {
        return id.EmptyCheckpointID, err
    }
    sorted := collectCheckpointsByAge(metadataTree, checkpointIDs)
    if len(sorted) == 0 {
        return id.EmptyCheckpointID, fmt.Errorf("no checkpoint metadata found")
    }
    return sorted[len(sorted)-1].CheckpointID, nil
}
```

Also need to handle the remote metadata case (same as current `resumeMultipleCheckpoints` does — try local, then fetch, then remote tree). Can extract a small helper `getMetadataTree` that tries local → fetch → remote.

### 3. Remove dead code

- **`resumeMultipleCheckpoints`** function — no longer called
- **`deduplicateSessions`** function — no longer needed
- Keep **`collectCheckpointsByAge`** — reused by `resolveLatestCheckpoint`

### 4. Update tests in `cmd/entire/cli/resume_test.go`

- **Remove** `TestDeduplicateSessions_*` subtests (5 subtests, ~100 lines)
- **Rewrite** `TestResumeMultipleCheckpoints_SortsByCreatedAt` → `TestResolveLatestCheckpoint` to verify it returns the newest checkpoint ID
- **Keep** `TestFindCheckpointInHistory_MultipleCheckpoints` — still valid (parsing)
- **Keep** `TestFindBranchCheckpoint_SquashMergeMultipleCheckpoints` — still valid (discovery)

### 5. Update integration test in `cmd/entire/cli/integration_test/resume_test.go`

- **Rewrite** `TestResume_SquashMergeMultipleCheckpoints`:
  - Change assertion from "Restored 2 sessions" to checking for the info message about skipped checkpoints
  - Assert only the **latest** session is restored (session2), not both
  - Assert output contains "older checkpoints skipped"

## Files Modified

- `cmd/entire/cli/resume.go` — simplify multi-checkpoint path, add `resolveLatestCheckpoint`
- `cmd/entire/cli/resume_test.go` — remove dedup tests, rewrite sort test
- `cmd/entire/cli/integration_test/resume_test.go` — update squash merge integration test

## Verification

```bash
mise run fmt && mise run lint && mise run test:ci
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: <HOST_PATH>
