# Task: cli-task-577e8c

| Field | Value |
|-------|-------|
| Source session | `577e8c02-5f1b-4f4d-ab6a-f1848ef0fd8e` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `092146da477575eeaf5219df24e225c3777687d3` |
| Difficulty | easy |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

Add a warning log when `ExtractModifiedFiles` fails in the OpenCode agent's `ReadSession` method. The existing code silently swallows unmarshal errors — the user wants warning logs added so failures are visible.

## User Simulator Behavior
- **Total real user messages:** 3 in 88 agent turns. Silence is the default.
- **Longest silence:** 75 agent turns between the initial directive and the first redirect
- **Turn 1:** "if we catch any error unmarshaling session data we should, at least, log a warning message with the content" — the initial task
- **Turn 2** (after 75 agent turns): "add warning logging there" — redirecting to opencode.go specifically
- **Turn 3** (after 6 more agent turns): "commit it" — finalizing the change

## Test Gates

| Gate | Weight | Type | Description |
|------|--------|------|-------------|
| compiles | 0.20 | Behavioral | Package compiles cleanly |
| tests_pass | 0.40 | Behavioral | Existing unit tests pass |
| warn_call_present | 0.15 | Structural | `logging.Warn` call exists in `ReadSession` error handler |
| log_has_session_ref | 0.10 | Structural | Warning log includes session reference |
| log_has_error | 0.10 | Structural | Warning log includes error details |
| error_branch_handles | 0.05 | Structural | Error branch has meaningful handling beyond nil assignment |
