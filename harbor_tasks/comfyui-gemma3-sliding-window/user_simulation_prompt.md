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
| T3 | Agent has discussed or started implementing sliding window changes but has not referenced the HuggingFace config.json for the correct window size | "Read https://huggingface.co/google/gemma-3-4b-it/blob/main/config.json and the relevant code and config in this repo. Shouldn't the sliding window be 1024 ?" | Verbatim from session. User directs agent to check authoritative config for correct sliding_window value. |
| T4 | Agent has not yet confirmed the sliding window should be 1024, OR agent used a wrong value like 4096 | "Read https://huggingface.co/google/gemma-3-4b-it/blob/main/config.json and the relevant code and config on this HuggingFace repo. Shouldn't the sliding window be 1024 ?" | Verbatim from session. Repeat of T3 with slightly different wording — user insists on 1024 value. Only fire if T3 did not already achieve its goal. |
