# Task: cli-task-2a55af

| Field | Value |
|-------|-------|
| Source session | `2a55af89-4e4f-4460-b18f-42a07287ae76` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `b51e394d8f87fdd1c96d14869625e5da5a181f71` (parent of fix) |
| Canonical fix | `150ba2a832ea7cad0d097f06a0bdbc8272e648c9` (proper gemini session id extraction) |
| Difficulty | medium |
| Category | bugfix |
| Language | Go |
| Real user msgs | 20 (3 auto-continuation msgs excluded) |

## Summary

The `extractSessionIDFromMetadata` function in `cmd/entire/cli/rewind.go` uses `strings.SplitN(base, "-", 4)` and returns `parts[3]`, which was designed for legacy date-prefixed session IDs like `2025-01-25-<uuid>`. For new-format UUID session IDs (no date prefix) like `0544a0f5-46a6-41b3-a89c-e7804df731b8`, this incorrectly returns `a89c-e7804df731b8` — truncating the first three UUID segments.

The fix: change `extractSessionIDFromMetadata` to return `filepath.Base(metadataDir)` (the identity function for non-date-prefixed IDs). Also, prefer `selectedPoint.SessionID` from the `Entire-Session` trailer over path-based extraction at call sites in `runRewindInteractive` and `runRewindToInternal`.

## User Simulator Behavior

- Total real user messages: 20 in 742 agent turns. Silence is the default.
- Longest silence: 174 agent turns
- Turn-by-turn summary:
  - Turn 0: Research question about Gemini rewind centricity
  - Turn 1-3: Fix RestoreLogsOnly + transcript file extension (issue #1 → #2)
  - Turn 4-7: Fix protected directories (.gemini/ + generic agent-protected-paths interface)
  - Turn 8-9: Tests + holistic review
  - Turn 10-12: Bug: task checkpoint transcript + concurrency + platform separator
  - Turn 13: **Manual testing reveals truncated session ID** (the core bug)
  - Turn 14-16: Fix session ID extraction, transcript file resolution, end-to-end verification
  - Turn 17-19: Cleanup (dead code, duplicate logic)

## Files Changed (canonical)

| File | Lines |
|------|-------|
| `cmd/entire/cli/rewind.go` | +17 / -12 |
| `cmd/entire/cli/rewind_test.go` | +69 (new) |

## CI Test Commands

From `.github/workflows/ci.yml` via `mise.toml`:
- `go test ./...` (unit tests)
- `go test -tags=integration -race ./...` (CI: unit + integration with race detection)
