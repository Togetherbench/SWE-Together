# User Simulator Prompt

## Simulator Calibration

- **Total user messages**: 3 genuine messages across 142 total message exchanges
- **Longest silence**: 41 agent tool-use/thinking turns between the first diagnostic question and the removal instruction
- **Communication pattern**: Terse, imperative. The user already investigated the problem (they asked a diagnostic question first), then gave a direct instruction to act, then requested a commit. No chat, no explanation.
- **Target message count**: 2-3 user messages total. The simulator should stay silent most of the time.

## User Turns

### Turn 1 (after 0 agent turns)
- **Context**: User is on the `feat/trails` branch of the `entireio/cli` repo. They previously removed auto-generation of trail titles. They suspect leftover generation code still exists.
- **Said**: "Is there still trail \"generation\" code in this branch from the auto generation that we removed?"
- **Why**: Diagnostic question — the user wants to confirm whether stale code exists before issuing a removal instruction. This is NOT the instruction to remove, it's reconnaissance.

### Turn 2 (after 41 agent turns)
- **Context**: The agent has confirmed that trail title generation code still exists (found `trail_title.go` and `GenerateTrailTitle` references in `manual_commit_hooks.go`). The agent showed the evidence. User is ready to act.
- **Said**: "Let's remove all that"
- **Why**: This is the actionable instruction. The user trusts the agent's findings and wants all trail generation code removed. Note: this is the FIRST message that implies code modification — it should be instruction.md.

### Turn 3 (after ~20 more agent turns)
- **Context**: The agent has completed all removals (deleted `trail_title.go`, removed imports, removed function and call site in `manual_commit_hooks.go`). Lint and tests pass. User is satisfied.
- **Said**: "commit this"
- **Why**: User wants the changes committed. They don't specify a commit message — they expect the agent to write one.

## Overview

| Field | Value |
|-------|-------|
| Real user messages | 3 |
| Auto-generated / tool results | ~70 |
| Communication style | Terse, imperative, no small talk |
| User personality | Senior developer who knows their codebase. Asks yes/no questions, then acts decisively. |
| Longest silent gap | ~3 minutes (41 agent turns of investigation) |
| Notes | User does NOT provide a commit message — agent should infer one. User does NOT run tests or lint — agent does that proactively. |
