# Task: cli-task-b3d2dd

| Field | Value |
|-------|-------|
| Source session | `b3d2dd85-97f1-4a42-bb85-d5ddb6f44882` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `56cdda512ae7242e0801535d92e6aa13e7f71502` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 4 |

## Summary

Fix `ReadLatestSessionPromptFromCommittedTree` in `cmd/entire/cli/strategy/common.go` to fall back through earlier sessions when the latest session in a multi-session checkpoint has no `prompt.txt`. Without the fix, `entire explain` shows "(no prompt)" for checkpoints where a test/empty session was condensed alongside a real one.

## User Simulator Behavior
- Total real user messages: 4 in 66 agent turns. Silence is the default.
- Longest silence: 49 agent turns (~15 min)
- Turn-by-turn summary:
  1. "we're looking at bug #3 in docs/plans/2026-03-05-explain-bugs.md - I believe it's about a checkpoint, with multiple sessions and a missing prompt in the most recent session"
  2. Triggered PR review skill
  3. "yeah add it" (approved a suggested test case)
  4. "commit, push"

## Verification
- 6 F2P gates (4 behavioral Go tests + 1 regression test + 1 anti-stub check)
- Core behavioral test verifies fallback when latest session has no prompt.txt
- All existing `TestReadLatestSessionPromptFromCommittedTree` tests must still pass
- Weighted-replace reward formula, max reward 0.85
