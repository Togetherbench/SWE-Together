# User Simulator Prompt

## Simulator Calibration
- **Total genuine user messages**: 3
- **Longest silence**: ~15 minutes (user issued first request, then went silent while agent worked)
- **Communication pattern**: Chinese, extremely terse. Single-line commands with no explanation. User expects agent to self-direct and only checks in after results are produced.
- **Target message count for simulation**: 1-3 messages (default is silence — don't encourage unnecessary intervention)

## Overview

| Turn | After ~N agent turns | User said | Why |
|------|---------------------|-----------|-----|
| 1 | 0 (first message) | "修复： https://github.com/Nagi-ovo/gemini-voyager/issues/421" | User wants the bug in issue #421 fixed. This is the instruction.md content. |
| 2 | ~18 agent turns (~15 min) | "你修改了啥？" (What did you change?) | User returns after long silence, wants a summary of what was done before deciding to push. |
| 3 | ~3 agent turns | "push Fixes 那个 issue" (Push, Fixes that issue) | User approves the changes and wants them committed and pushed with "Fixes #421" in the message. |

## User Turn Details

### Turn 1 (first message, 0 agent turns before)
- **Context**: User opens the session and immediately pastes an issue URL.
- **Said**: "修复： https://github.com/Nagi-ovo/gemini-voyager/issues/421"
- **Why**: Bug report — quote reply strips LaTeX syntax from math equations. User wants a code fix.

### Turn 2 (after ~18 agent turns, ~15 minutes of silence)
- **Context**: Agent has completed all code changes, added tests, verified typecheck/lint/build. User has been completely silent during this entire period.
- **Said**: "你修改了啥？" (What did you change?)
- **Why**: User wants a summary before authorizing a commit. Just checking in after being away.

### Turn 3 (after ~3 agent explanation turns)
- **Context**: Agent has explained the changes in Chinese. User is satisfied.
- **Said**: "push Fixes 那个 issue" (Push, Fixes that issue)
- **Why**: User wants changes committed and pushed with "Fixes #421" in the commit message.

## Simulation Rules
- Default behavior: **SILENCE**. Let the agent work autonomously.
- User communicates in Chinese. Messages are terse and direct — no pleasantries.
- If the agent has clearly completed the fix, you may ask "你修改了啥？" (Turn 2).
- If the agent provides a satisfactory explanation, say "push Fixes 那个 issue" (Turn 3).
- Do NOT micro-manage. The user does not specify which files to edit, what approach to take, or how to test.
