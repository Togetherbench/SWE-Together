Implement the following plan:

# Fix: Cursor stop hook failures and deferred session-end checkpoint

## Context

The Cursor `stop` hook IS firing, but `handleLifecycleTurnEnd` hard-fails because:
1. `sanitizePathForCursor` produces wrong paths (`-Users-soph-...` instead of `Users-soph-...`)
2. The transcript file doesn't exist at the computed path
3. `handleLifecycleTurnEnd` returns `"transcript file not found"` error at line 166
4. The error goes to stderr (captured by Cursor) and is never logged

Additionally, if `stop` truly doesn't fire (different Cursor versions/modes), `handleLifecycleSessionEnd` does no checkpoint — it only marks the session as ended.

## Changes

### 1. Fix `sanitizePathForCursor` (root cause)

**File:** `cmd/entire/cli/agent/cursor/cursor.go:154-156`

Strip leading path separator before regex replacement:

```go
func sanitizePathForCursor(path string) string {
    path = strings.TrimLeft(path, "/")
    return nonAlphanumericRegex.ReplaceAllString(path, "-")
}
```

**Test file:** `cmd/entire/cli/agent/cursor/cursor_test.go` — fix test expectations that encode the wrong leading `-` behavior.

### 2. Make `handleLifecycleTurnEnd` resilient to missing transcripts

**File:** `cmd/entire/cli/lifecycle.go:161-167`

Change the transcript check from hard-fail to soft-continue. When transcript is missing, skip transcript extraction but still detect file changes via git status and save the checkpoint:

```go
transcriptRef := event.SessionRef
hasTranscript := transcriptRef != "" && fileExists(transcriptRef)
if !hasTranscript {
    logging.Warn(logCtx, "transcript not available, falling back to git status",
        slog.String("session_ref", transcriptRef))
}
```

Then guard transcript-dependent operations (read, copy, extract prompts/summary/files) behind `if hasTranscript { ... }`. The git status detection (`DetectFileChanges`) and `SaveStep` work independently and don't need a transcript.

### 3. Deferred SaveStep in `handleLifecycleSessionEnd`

**File:** `cmd/entire/cli/lifecycle.go:421-442`

When session-end fires and the session is still ACTIVE (TurnEnd never happened), dispatch a synthetic TurnEnd first:

```go
func handleLifecycleSessionEnd(ctx context.Context, ag agent.Agent, event *agent.Event) error {
    // ... existing logging ...

    // Check if session is still ACTIVE (TurnEnd never fired)
    state, _ := strategy.LoadSessionState(ctx, event.SessionID)
    if state != nil && state.Phase == session.PhaseActive {
        // Deferred turn-end: stop hook didn't fire or failed
        logging.Info(logCtx, "deferred turn-end: session ending while still active")
        syntheticEvent := &agent.Event{
            Type:      agent.TurnEnd,
            SessionID: event.SessionID,
            SessionRef: event.SessionRef,
            Timestamp: event.Timestamp,
        }
        if err := handleLifecycleTurnEnd(ctx, ag, syntheticEvent); err != nil {
            logging.Warn(logCtx, "deferred turn-end failed", "err", err)
            // Continue to mark session ended even if deferred save fails
        }
    }

    if err := markSessionEnded(ctx, event.SessionID); err != nil {
        fmt.Fprintf(os.Stderr, "Warning: failed to mark session ended: %v\n", err)
    }
    return nil
}
```

This reuses the existing `handleLifecycleTurnEnd` (now resilient to missing transcripts) instead of duplicating logic.

### 4. Update tests

- `cmd/entire/cli/agent/cursor/cursor_test.go` — fix `TestSanitizePathForCursor` expectations (remove leading `-`)
- `cmd/entire/cli/agent/cursor/cursor_test.go` — fix `TestCursorAgent_GetSessionDir_DefaultPath` if affected
- `cmd/entire/cli/lifecycle_test.go` — update `TestHandleLifecycleTurnEnd_NonexistentTranscript` (now should succeed with git-status-only, not error)
- Add test for deferred turn-end in session-end (ACTIVE session)

## Files to modify

1. `cmd/entire/cli/agent/cursor/cursor.go` — `sanitizePathForCursor`
2. `cmd/entire/cli/agent/cursor/cursor_test.go` — fix test expectations
3. `cmd/entire/cli/lifecycle.go` — `handleLifecycleTurnEnd` (soft-fail on missing transcript), `handleLifecycleSessionEnd` (deferred turn-end)
4. `cmd/entire/cli/lifecycle_test.go` — update/add tests

## Verification

1. `mise run fmt && mise run lint && mise run test:ci`
2. Rebuild binary: `go build -o <HOST_PATH> ./cmd/entire/`
3. Re-test with test_cursor2 wrapper to confirm stop hook succeeds (EXIT=0)
4. Verify shadow branch is created after a Cursor agent session


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: <HOST_PATH>
