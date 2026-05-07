# Task: cli-task-19def0

| Field | Value |
|-------|-------|
| Source session | `19def01c-b939-40ef-b431-47aa7121df4c` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `7f6c5bd3ce5d041269a2619c66f352607a06d6b2` (parent of `4fc9356`) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 2 |

## Task Summary

The stale session cleanup logic is inconsistently applied across the codebase: the package-level `LoadSessionState()` function in `strategy/` does stale detection, but `StateStore.Load()` in `session/` does not. This means callers that use `StateStore.Load()` directly (like `ManualCommitStrategy.loadSessionState()`, used in hooks, condensation, rewind, and git operations) never clean up stale sessions.

The fix involves moving the stale session check into `StateStore.Load()` so all callers benefit automatically, then simplifying the strategy package's `LoadSessionState()` to delegate to `StateStore` instead of duplicating file I/O, unmarshaling, and stale checks.

## User Simulator Behavior

- **Total real user messages**: 2 in 3 total user turns. Silence is the default.
- **Longest silence**: 55 agent turns between the first message and the commit instruction
- **Turn 0**: Detailed technical request to move stale session cleanup into `StateStore.Load()`
- **Turn 85**: System interruption (cancelled a long-running tool)
- **Turn 86**: "Commit with thorough message."

## Key Files

| File | Role |
|------|------|
| `cmd/entire/cli/session/state.go` | Core session state — `StateStore.Load()`, `IsStale()`, `StaleSessionThreshold` |
| `cmd/entire/cli/strategy/session_state.go` | Strategy-level `LoadSessionState()` — should delegate to `StateStore` |
| `cmd/entire/cli/session/state_test.go` | Existing tests for session package |
| `cmd/entire/cli/strategy/session_state_test.go` | Existing tests for strategy package |

## Verifier Design

- **10 F2P gates**: 5 behavioral (65% of weight budget), 5 structural (35% of weight budget)
- **1 P2P_REGRESSION gate**: ensures no duplicate stale check in strategy package
- **Behavioral tests**: Go harness using `NewStateStoreWithDir()` exercises Save/Load/List with stale and active sessions
- **No anti-stub**: harness mutates disk state — a stub `IsStale() { return false }` causes failures
