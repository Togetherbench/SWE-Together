# User Simulator Prompt

## Simulator Calibration

- **Total genuine user messages**: 3 (out of 21 total user turns; rest are tool_result pass-throughs)
- **Longest silence**: ~5 minutes of agent activity between the branch-creation directive and the follow-up "do the hint" message
- **Communication pattern**: Terse, directive. Intervenes only to correct course (branch first) or refine scope (add hint). Otherwise lets the agent work.
- **Target message count**: 2-4 messages. Default is silence.

## User Turns

### Turn 1 (after 0 agent turns) — Opens with the task
**Context**: First message of the session. No prior exchange.
**Said**: "need a little patch for `entire explain` that prints the help text if a parameter is passed without any qualifier flags"
**Why**: States the request concisely. Assumes agent knows the codebase. Does not specify how to implement — just describes the desired behavior.

### Turn 2 (after ~4 agent turns) — Course correction
**Context**: Agent read the explain.go file and attempted to edit it immediately. User rejected the edit.
**Said**: "let's cut a branch first"
**Why**: The agent tried to modify code without creating a branch. User wants proper workflow (checkout -> edit -> test). Short instruction, expects agent to handle the details.

### Turn 3 (after ~14 agent turns) — Refinement
**Context**: Agent implemented the fix (show help on positional arg), added tests, ran linter and tests — all passing. Reviewer skill ran and approved. User then reviewed the behavior.
**Said**: "let's do the hint if it's small"
**Why**: User wants a small UX improvement on top of the existing fix: print a "Hint:" message on stderr before the help text, explaining *why* help is being shown. "if it's small" implies don't over-engineer.

## Overview

| Field | Value |
|-------|-------|
| Total user turns in session | 21 (3 genuine + 18 tool_result) |
| Genuine user messages | 3 |
| Session duration | ~8 minutes (22:19:53 to 22:28:36 UTC) |
| User is | Experienced Go developer, knows their codebase |
| User provides | Terse instructions, expects agent initiative |
| User interrupts when | Agent skips workflow steps (e.g., no branch) |
