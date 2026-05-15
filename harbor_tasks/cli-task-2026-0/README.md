# Task: cli-task-2026-0

| Field | Value |
|-------|-------|
| Source session | `2026-01-29-0f6074fc-a0f5-4d56-8de0-f4a592ddcf3b` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `65fa5640` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 3 |

## Bug Summary
In `cmd/entire/cli/telemetry/detached_unix.go`, the `spawnDetachedAnalytics` function sets `cmd.Stdout = nil` and `cmd.Stderr = nil` with a comment claiming output goes to `/dev/null`. In Go's `os/exec` package, `nil` actually inherits the parent's file descriptors, meaning telemetry subprocess output (including panics) can leak to the user's terminal. The fix is to explicitly direct stdout/stderr to a discard sink (`io.Discard` or `/dev/null`).

## User Simulator Behavior
- Total real user messages: 3 in 19 agent turns. Silence is the default.
- Turn 1: User describes the bug and asks for a fix (detailed, technical)
- Turn 2 (after ~19 agent turns): User asks "what do io.Discard does ?" after agent mentions it
- Turn 3 (after ~3 agent turns): User confirms "yes please" to switch to `io.Discard`
- Longest silence: 19 agent turns between Turn 1 and Turn 2

## Verifier Gates
- **P2P_REGRESSION**: File exists, function exists (diagnostic/penalty only)
- **F2P (Gold)**: Unit tests pass (0.20), integration tests pass (0.10)
- **F2P (Silver)**: No nil stdout/stderr (0.20), discard sink used (0.20)
- Reward formula: weighted-replace (inner_weight = 0.30)
