# User Simulation Prompt

## Simulator Calibration
- **Total user messages in original session**: 102 (1 real instruction + 101 tool-result envelopes)
- **Substantive user interventions**: 0 (single-turn task — no follow-up from user)
- **Session duration**: Agent ran autonomously, cut off mid-exploration
- **Intervention style**: None — user never intervened after initial instruction
- **Default**: SILENCE

## Context
This was a fully autonomous single-turn session. The user submitted a GitHub issue
(feature request / refactoring task) as the initial instruction and never returned.
The agent explored the codebase (102 tool calls) but was cut off before completing
the implementation. There are no substantive user messages to populate the trigger table.

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| (none) | — | — | No real user follow-up messages in original session; all 101 post-instruction "user" turns were `<tool_result>` envelopes from automated tool execution |
