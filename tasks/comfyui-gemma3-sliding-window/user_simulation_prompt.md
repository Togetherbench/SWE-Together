# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 4
- **Session start**: 2025-12-18T15:34:36.511Z
- **Session end**: 2025-12-18T15:48:36.633Z
- **Session duration**: ~14 minutes
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 3 (turns 2-4; turn 1 is the initial instruction)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

Turn 1 is the initial instruction (instruction.md) and is NOT included here.

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has produced analysis comparing ComfyUI and HuggingFace Gemma implementations, mentioning softcap or logit capping differences | "Is there any other difference between functionality apart from the softcap?" | Verbatim from session. User pushes agent to look beyond softcap to find sliding window gap. |
| T3 | Agent has discussed or started implementing sliding window changes but has not referenced the authoritative Gemma config for the correct window size | "The Gemma-3-4b-it config sets sliding_window to 1024. Check the relevant code and config in this repo — shouldn't the sliding window be 1024 ?" | Offline-safe rewrite of the session turn: the live `huggingface.co/.../config.json` URL was inlined to its value (1024) so the task is reproducible without internet and does not hand the agent an external URL to the answer. |
| T4 | Agent has not yet confirmed the sliding window should be 1024, OR agent used a wrong value like 4096 | "Per the authoritative Gemma-3-4b-it config, sliding_window is 1024. Check the relevant code and config in this repo — shouldn't the sliding window be 1024 ?" | Offline-safe rewrite (URL inlined to 1024). Repeat of T3 with slightly different wording — user insists on 1024 value. Only fire if T3 did not already achieve its goal. |
