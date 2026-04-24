# User Simulation Prompt

## Simulator Calibration
- **Total user messages in session**: 1 (only the initial instruction; remaining 21 "user" messages are `<tool_result>` system envelopes, not human turns)
- **Session duration**: single automated run
- **Intervention style**: NONE — single-turn task with no human follow-up
- **Default**: SILENCE

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| — | — | — | No substantive user turns after the initial instruction. All 21 subsequent "user" role messages are `<tool_result>` envelopes from tool execution, not human interventions. |
