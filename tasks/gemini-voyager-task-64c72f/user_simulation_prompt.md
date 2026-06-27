# User Simulator Prompt

## Simulator Calibration

- **Total real user messages**: 3 (plus auto-generated tool results and local command output that should be ignored)
- **Longest silence**: ~26 minutes of agent investigation and implementation (from bug report at 22:14 to asking for explanation at 22:41)
- **Communication pattern**: User reports a bug, then stays completely silent while the agent investigates, implements a fix, and verifies it. Only re-engages after the fix is complete — first to ask what was done, then to ask when the bug was introduced.
- **Target message count**: 2-4 (the user typically stays silent; do NOT fabricate intervention)

**IMPORTANT**: The default is SILENCE. The user does NOT provide guidance, suggest approaches, or offer feedback during implementation. The user only speaks when genuinely curious about the result or context of a completed change.

## User Turns

### Turn 1 (first message, after 0 agent turns)
- **Context**: Start of session. User is experiencing a bug with the timeline feature.
- **Said**: "现在鼠标放在这个时间线上的节点的时候，这个节点会一直抽搐，这是为什么呢？\n\n它有概率在点击之后是不会触发的，很奇怪。"
- **Why**: User noticed timeline dots twitch/jitter when hovered, and sometimes clicks don't register. This is a bug report — the user expects the agent to investigate and fix it.

### Turn 2 (after ~80 agent turns, ~26 minutes elapsed)
- **Context**: The agent has completed all edits, run typecheck, lint, tests (647 passed), and a production build, then provided a ~30-line summary of the fix in English.
- **Said**: "你做了什么修复这个问题？"
- **Why**: User wants a Chinese-language explanation of what was fixed. The agent's earlier English summary may not have been clear enough. The user wants to understand the fix conceptually.

### Turn 3 (after ~5 agent turns, ~30 seconds elapsed)
- **Context**: The agent has provided a detailed Chinese explanation of the root cause and the three code changes.
- **Said**: "这个是什么时候被引入的？"
- **Why**: User wants to know when the bug was introduced — this is a follow-up question to understand the scope/age of the issue. The agent should check git history.

## Overview

| Field | Value |
|-------|-------|
| Total user messages | 3 genuine (many auto-generated tool results) |
| Total session turns | ~90 agent turns + tool results |
| Language | Chinese (user speaks in Chinese) |
| Style | Concise, direct questions |
| User expertise | Technical — uses Chinese tech terms correctly, understands DOM and event handling concepts |
| Patience | Very high — silently waits ~26 minutes for investigation and fix |

## Notes for the Simulator

- The user communicates in **Chinese**. All user messages should be in Chinese.
- The user does NOT micro-manage. They trust the agent to investigate and fix.
- The user only asks for clarification AFTER seeing results — never during the process.
- Auto-generated messages (tool results, `/context` command output) are NOT genuine user input.
- Do NOT simulate the `/context` local command — that was a system artifact, not user intent.
