# Task: cli-task-2f5833

| Field | Value |
|-------|-------|
| Source session | `2f5833ec-423b-47b4-9535-556896507b53` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `1d76de91` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 4 |

## Bug Summary

The `prompt.txt` file on the filesystem is being overwritten at TurnEnd by `handleLifecycleTurnEnd` in `lifecycle.go`, which re-extracts prompts from the transcript and overwrites the file that was correctly populated at TurnStart. This means checkpoints lose accumulated prompts from prior turns.

## What Needs to Change

1. **`cmd/entire/cli/lifecycle.go`**: Remove `ExtractPrompts()` call and `prompt.txt` write from `handleLifecycleTurnEnd`. Use `state.LastPrompt` (loaded from session state) for commit messages. Add prompt append to filesystem at TurnStart.

2. **`cmd/entire/cli/strategy/manual_commit_hooks.go`**: Add filesystem fallback to `finalizeAllTurnCheckpoints` — read prompts from shadow branch first, then fall back to filesystem (not from transcript).

3. **`cmd/entire/cli/strategy/manual_commit_condensation.go`**: Change `extractSessionData` and `extractSessionDataFromLiveTranscript` to read prompts from shadow branch/filesystem instead of `extractCheckpointPrompts`.

4. **Dead code cleanup**: Remove `ExtractSummary` from the agent interface and all implementations. Remove `SummaryFileName` constant. Rename `FirstPrompt` → `LastPrompt`.

## User Simulator Behavior
- Total real user messages: 4 in 79 turns. Silence is the default.
- Longest silence: ~70 agent turns
- User provides a detailed plan at turn 1, gives a mid-session correction about carry-forward file handling (turns 2-3), then asks to commit (turn 4).

## Verification
- 3 Gold gates (0.45): behavioral checks on TurnEnd prompt extraction, shadow branch fallback, prompt.txt overwrite
- 4 Silver gates (0.35): ExtractSummary removal, SummaryFileName removal, FirstPrompt→LastPrompt rename, commit message source
- 4 Bronze gates (0.20): structural checks on naming conventions and helpers
- 2 P2P regression gates: build and unit tests pass
