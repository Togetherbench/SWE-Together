# User Simulator Prompt

## Simulator Calibration

- **Total genuine user messages:** 3 (in 88 agent turns)
- **Longest silence:** 75 agent turns (between Turn 1 and Turn 2)
- **Communication pattern:** User gives a brief directive, then stays completely silent while the agent explores the codebase and makes changes. Only interrupts with one short clarification, then finalizes with "commit it."
- **Target message count:** 2-3 messages for a successful session (initial directive + optional redirect + commit request)

**Silence is the default.** Do not intervene except as described below. The user will wait through long agent explorations without hand-holding.

---

## User Turns

### Turn 1 (message #0, after 0 agent turns)
- **Context:** Fresh session start. The user has a specific logging improvement in mind across the codebase.
- **Said:** "if we catch any error unmarshaling session data we should, at least, log a warning message with the content"
- **Why:** The user wants error logging added to places where `json.Unmarshal` silently swallows errors on session-related data. They don't specify exact files — the agent must discover the locations.

### Turn 2 (message #132, after 75 agent turns)
- **Context:** The agent had been working through many `json.Unmarshal` locations, editing several files (session.go, common.go, manual_commit_logs.go). Some of those changes were reverted (either by the user or by running `gofmt`/linting). The agent noticed and reported that only the opencode.go change remained. The user wants to confirm and focus effort.
- **Said:** "add warning logging there"
- **Why:** The user is redirecting the agent to focus on one specific location (the opencode agent's error handler for `ExtractModifiedFiles`) rather than the broader set of files the agent was initially modifying.

### Turn 3 (message #143, after 6 more agent turns)
- **Context:** The agent completed the opencode.go change, built successfully, and described the result. The user is satisfied.
- **Said:** "commit it"
- **Why:** The user wants the change committed. They don't address the agent's question about re-applying other changes — the single opencode.go change is sufficient.

---

## Overview

| Field | Value |
|-------|-------|
| Total user messages | 3 |
| Total agent turns | 88 |
| Longest silence | 75 turns |
| User messaging style | Terse, directive, hands-off |
| Task type | Bugfix — add missing error logging |
