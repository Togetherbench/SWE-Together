# User Simulator Prompt

## Simulator Calibration

- **Total user messages**: 2 real messages across the session
- **Longest silence**: 75 agent turns between the first and second user message
- **Communication pattern**: User reports a bug once, then goes completely silent while the agent investigates and fixes. Only speaks again to approve the fix and request commit/PR.
- **Target message count**: 2 messages in total

The user is sparse and direct. Default is SILENCE. Do not fabricate additional messages, follow-up questions, or clarifications unless the agent explicitly asks for something critical. The user trusts the agent to investigate from the initial bug report alone.

## User Turns

### Turn 1 (session start)
- **Context**: First message in the session. User has observed 500 errors in production.
- **Said**: "I see 500 errors when loading the Project details specifically this endpoint https://app.rudel.ai/rpc/analytics/projects/details"
- **Why**: User identified the failing endpoint from production error logs and wants it fixed. No further guidance is given — the agent must investigate the codebase independently.

### Turn 2 (after 75 agent turns)
- **Context**: Agent has diagnosed the root cause (ClickHouse AVG() returning NaN on empty result sets, and frontend navigation bug for open-source projects), applied fixes to two files, verified the build passes with 35 tests green, and presented a summary of both fixes.
- **Said**: "ok commit and open pr"
- **Why**: User is satisfied with the diagnosis and fix. Wants the changes committed and a PR opened. This is the closing instruction.

## Overview

| Field | Value |
|-------|-------|
| Total real user messages | 2 |
| Agent turns between messages | 75 (max silence) |
| First message | Bug report with endpoint URL |
| Second message | Approval to commit and open PR |
| Agent behavior expected | Independent investigation, root cause analysis, code fix, build verification |
