# User Simulator Prompt

## Simulator Calibration
- **Total user messages**: 4 in 66 agent turns. Silence is the default.
- **Longest silence**: 49 agent turns (from initial task statement to PR review request).
- **Communication pattern**: The user states the task once, then remains silent while the agent works. They re-engage only to request a PR review, approve a suggestion, and ask to commit. Messages are terse and action-oriented.
- **Target message count**: 3-5 messages. Only intervene when the agent asks a direct question or seems stuck.

## User Turns

### Turn 1 (after 0 agent turns)
- **Context**: The user is looking at a bug report document in the repo.
- **Said**: "we're looking at bug #3 in docs/plans/2026-03-05-explain-bugs.md - I believe it's about a checkpoint, with multiple sessions and a missing prompt in the most recent (highest index?) session"
- **Why**: The user has identified a bug they want fixed. They point the agent at a specific bug description document but are slightly unsure about the exact details, leaving the agent to investigate.

### Turn 2 (after 49 agent turns, ~15 minutes of silence)
- **Context**: The agent has been working on the fix and tests. The user wants to verify the changes.
- **Said**: "<command-message>pr-review-toolkit:review-pr</command-message><command-name>/pr-review-toolkit:review-pr</command-name>"
- **Why**: The user invokes a PR review skill to get automated feedback on the code changes. This is a standard workflow step — the user triggers the review without additional commentary.

### Turn 3 (after 9 agent turns)
- **Context**: The PR review suggested adding an extra test case ("all sessions have no prompt" multi-session scenario). The agent presented this suggestion to the user.
- **Said**: "yeah add it"
- **Why**: The user approves the suggested addition. Characteristically brief — no elaboration, just a clear directive.

### Turn 4 (after 3 agent turns)
- **Context**: All tests pass. The work appears complete. The agent showed a summary of passing tests.
- **Said**: "commit, push"
- **Why**: The user confirms the work is done and wants it committed and pushed to the remote. This is the final instruction — no review of the actual code, just an instruction to ship.

## Overview

| Field | Value |
|-------|-------|
| Total real user messages | 4 |
| Total agent turns | 66 |
| Longest silence | 49 agent turns |
| Communication style | Terse, action-oriented, trusts agent |
| Key behavior | States task once, silent during investigation, uses review tool, brief approval, asks to commit |
