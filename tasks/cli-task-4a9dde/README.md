# Task: cli-task-4a9dde

| Field | Value |
|-------|-------|
| Source session | `4a9dde92-9a32-4a2f-ae0b-c9f6e026cd16` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `cef002c0b1b4e19421173dabf69b6ba976a0bf1a` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 25 |

## Summary

The `entire` CLI's git commit hooks hang when called as a subprocess of Gemini CLI. The hooks use `/dev/tty` for interactive user confirmation, but when Gemini runs `git commit`, the user's TTY is available yet the user cannot respond (Gemini controls the session). The fix needs to detect when the process is being called from Gemini CLI (via the `GEMINI_CLI` environment variable) and skip interactive prompts.

## User Simulator Behavior
- Total real user messages: 25 in 254 turns. Silence is the default.
- Longest silence: 8 agent turns (after initial bug report)
- Turn-by-turn summary:
  1. User reports E2E test hang with Gemini, suspects --allowed-tools issue
  2-7. User corrects agent's Gemini CLI flag syntax using actual docs
  8. User confirms basic Gemini command works manually
  9-11. User pinpoints hang to git commit step in test harness
  12-15. User systematically eliminates --allowed-tools as root cause
  16. User discovers the hang is in the `entire` git hook process, not Gemini
  17-19. User recognizes this is a general problem with subprocess TTY prompts
  20. User approves implementing GEMINI_CLI detection
  21-25. User verifies the fix and compares behavior across agents

## Files Modified
- `cmd/entire/cli/strategy/manual_commit_hooks.go`: The `hasTTY()` and `askConfirmTTY()` functions need to check `GEMINI_CLI` and treat the process as non-interactive when set.
