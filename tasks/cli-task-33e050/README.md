# Task: cli-task-33e050

| Field | Value |
|-------|-------|
| Source session | `33e0503c-ecf6-44f0-9f93-e70fe49cfa87` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `a009258cdce04b0dde8c4d559361e8b034ad3ae8` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 9 |

## Summary

The user reports that git commits in their repo are slow and suspects the Entire CLI hooks are the cause. The investigation leads to a specific bottleneck: `waitForTranscriptFlush` in `cmd/entire/cli/agent/claudecode/lifecycle.go`. This function has a fast-path check that skips the poll loop for stale transcript files (unchanged for 2+ minutes), but it does NOT handle the case where the transcript file doesn't exist at all. When `os.Stat` fails (nonexistent file), the code falls through to a 3-second poll loop, adding unnecessary delay during git commits.

The fix: when the transcript file doesn't exist, return immediately — there's nothing to wait for.

## Files Changed (canonical)

- `cmd/entire/cli/agent/claudecode/lifecycle.go`: `waitForTranscriptFlush` — add early return when `os.Stat` fails
- `cmd/entire/cli/agent/claudecode/lifecycle_test.go`: Update nonexistent-file test to expect sub-second return

## User Simulator Behavior

- Total real user messages: 9 in 9 turns. Silence is the default.
- Longest silence: 56 agent turns (~3h 50min between turn 1 and turn 2)
- Communication style: Direct, terse, technically precise. User reads code carefully and challenges assumptions.
- Key turns: Turn 1 (initial request), Turn 8 (notices misleading test comment), Turn 9 (questions whether waiting for nonexistent file makes sense)

## Verifier Tests

- 4 behavioral gates (Gold/Silver, 0.70 total weight): timing-based tests for nonexistent file fast return, recent file wait, stale file skip
- 2 structural gates (Bronze, 0.13 total weight): function existence, test update check
- 2 P2P_REGRESSION gates (diagnostic-only): existing tests pass, stale fast path preserved
