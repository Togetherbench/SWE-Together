# Task: cli-fix-2026-0

| Field | Value |
|-------|-------|
| Source session | `2026-01-26-4fec7ea0-3335-43ec-a178-d4ab47d5aef3` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `7cd5dfae6435f16aa21360f7a4880e8508b73a24` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 7 |

## Summary

The user reports that `calculatePromptAttributionAtStart` silently returns empty results on error conditions (corrupt shadow branch, permission issues). The instruction asks for debug-level logging to be added to these error paths. The session also reveals deeper attribution bugs: staged/unstaged inconsistency causing misattribution, pre-first-prompt edits being silently attributed to the agent, and a performance issue in `getAllChangedFilesBetweenTrees` that double-reads file contents.

## User Simulator Behavior
- Total real user messages: 7 in 93 turns. Silence is the default.
- Longest silence: 27 agent turns (between turn 4 and turn 5)
- Turn-by-turn summary:
  1. Request to add debug logging to error paths
  2. Bug report: staged/unstaged attribution discrepancy
  3. Analysis question: how unstaged changes are handled
  4. Bug report: pre-first-prompt edits never captured
  5. Performance issue + question about getAllChangedFilesBetweenTrees
  6. Dead code check: is getFileContent still used?
  7. Test coverage check: does getAllChangedFilesBetweenTrees have tests?

## Files of Interest
- `cmd/entire/cli/strategy/manual_commit_hooks.go` — `calculatePromptAttributionAtStart`
- `cmd/entire/cli/strategy/manual_commit_attribution.go` — `getAllChangedFilesBetweenTrees`, `getFileContent`
- `cmd/entire/cli/strategy/manual_commit_condensation.go` — reference logging pattern
- `cmd/entire/cli/strategy/manual_commit_staging_test.go` — existing staging tests
- `cmd/entire/cli/strategy/manual_commit_attribution_test.go` — existing attribution tests

## Verifier
- 6 F2P gates: builds, tests pass, debug logs exist, hash-based diff, checkpoint guard removed, new tests
- 2 P2P regression gates: getFileContent exists, getAllChangedFilesBetweenTrees exists
- Weighted-replace reward formula, total F2P weights = 0.75, inner weight = 0.25
