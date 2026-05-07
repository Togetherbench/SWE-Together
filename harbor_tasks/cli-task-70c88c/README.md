# Task: cli-task-70c88c

| Field | Value |
|-------|-------|
| Source session | `70c88cff-cb35-404f-a974-2a08bab4e4bc` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `b386f5faaec2fd2f78941bf3621d89d4000bdf9d` |
| Language | Go (1.25.6+) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

The `entire explain` command silently ignores positional arguments when no qualifier flag (`--checkpoint`, `--session`, `--commit`) is provided. The fix should show help text (and optionally a hint) when a positional argument is passed without any qualifier flags, guiding users to use the correct flags.

## User Simulator Behavior

- **Total real user messages**: 3 in 21 total user turns (18 are tool_result pass-throughs)
- **Target message count**: 2-4. Silence is the default.
- **Longest silence**: ~5 minutes of agent activity between course-correction and refinement
- **Turn 1**: "need a little patch for `entire explain` that prints the help text if a parameter is passed without any qualifier flags" — concise, assumes agent knows the codebase
- **Turn 2** (after agent skipped branch creation): "let's cut a branch first" — workflow correction
- **Turn 3** (after core fix implemented): "let's do the hint if it's small" — UX refinement

## Files Changed

- `cmd/entire/cli/explain.go` — RunE function: capture positional args, check for missing qualifier flags, show help + hint
- `cmd/entire/cli/explain_test.go` — new test for positional arg behavior
