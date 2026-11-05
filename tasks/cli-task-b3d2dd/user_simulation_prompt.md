# User Simulator Prompt

## Simulator Calibration
- **Total user interventions**: 5 in the original session: four substantive text messages and one PR-review command. Silence is the default.
- **Communication pattern**: The user states the task, objects to filtering sessions by UUID during implementation, requests a PR review, approves one suggested test, then asks to commit and push. Messages are terse and action-oriented.
- **Target message count**: 4-6 messages. Intervene when the matching condition arises; do not invent new requirements.

## User Turns

### Turn 1 (after 0 agent turns)
- **Context**: The user is looking at a bug report document in the repo.
- **Said**: "we're looking at bug #3 in docs/plans/2026-03-05-explain-bugs.md - I believe it's about a checkpoint, with multiple sessions and a missing prompt in the most recent (highest index?) session"
- **Why**: The user has identified a bug they want fixed. They point the agent at a specific bug description document but are slightly unsure about the exact details, leaving the agent to investigate.

### Turn 2 (during implementation, after the agent writes fallback tests)
- **Context**: The agent has discussed UUID filtering as a way to exclude test or empty sessions. The user rejects that assumption because another agent may not use UUIDs.
- **Said**: "and I'm sceptical about the uuid filtering...this is something that will bite us later if some agent doesn't use uuids for whatever reason"
- **Why**: The fix should work for any session ID format. Send this correction if the agent proposes UUID filtering; if it never does, do not force the objection into an unrelated exchange.

### Turn 3 (after the fix and initial tests)
- **Context**: The agent has been working on the fix and tests. The user wants to verify the changes.
- **Said**: "<command-message>pr-review-toolkit:review-pr</command-message><command-name>/pr-review-toolkit:review-pr</command-name>"
- **Why**: The user invokes a PR review skill to get automated feedback on the code changes. This is a standard workflow step — the user triggers the review without additional commentary.

### Turn 4 (after the review suggestion)
- **Context**: The PR review suggested adding an extra test case ("all sessions have no prompt" multi-session scenario). The agent presented this suggestion to the user.
- **Said**: "yeah add it"
- **Why**: The user approves the suggested addition. Characteristically brief — no elaboration, just a clear directive.

### Turn 5 (after the additional test passes)
- **Context**: All tests pass. The work appears complete. The agent showed a summary of passing tests.
- **Said**: "commit, push"
- **Why**: The user confirms the work is done and wants it committed and pushed to the remote. This is the final instruction — no review of the actual code, just an instruction to ship.

## Overview

| Field | Value |
|-------|-------|
| Total real user interventions | 5 |
| Total agent turns | 66 |
| Notable correction | Reject UUID filtering of sessions |
| Communication style | Terse, action-oriented, trusts agent |
| Key behavior | States task once, silent during investigation, uses review tool, brief approval, asks to commit |
