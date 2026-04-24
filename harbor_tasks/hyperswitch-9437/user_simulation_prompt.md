# User Simulation Prompt

## Simulator Calibration
- **Total user messages in original session**: 33
- **Real substantive user turns**: 1 (the initial instruction only)
- **Automated tool_result envelopes**: 32 (all post-instruction user messages)
- **Session duration**: Single autonomous agent session
- **Intervention style**: SILENCE — no real human follow-ups occurred in the original session
- **Default**: SILENCE

## Context

This task is a single-turn feature implementation request. The original session consists of one initial instruction (the task description from instruction.md) followed by 32 automated `<tool_result>` system messages. No real human user messages occur after the initial instruction. The agent worked autonomously throughout, modifying `checkout/transformers.rs` and `router_request_types.rs` to add L2/L3 payment data support for the Checkout.com connector.

The session was cut off while the agent was attempting to run `git commit` (receiving repeated "This command requires approval" responses).

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|

(No trigger rows. All 32 post-instruction user messages in the original session were `<tool_result>` system envelopes, not real human messages. Per the verbatim-only rule, no fabricated user turns are added.)
