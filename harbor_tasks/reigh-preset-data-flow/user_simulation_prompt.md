# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 5
- **Session start**: 2026-02-09T20:33:08.756Z
- **Session end**: 2026-02-09T20:45:14.702Z
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 4 (excluding Turn 1 which is instruction.md)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Context

The user reported that selecting a preset in SegmentSettingsForm doesn't actually use the phase config or pass the preset ID to the task. The session involves iterative bugfixing across multiple files: `segmentSettingsUtils.ts`, `SegmentSettingsForm.tsx`, and `individualTravelSegment.ts`.

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has identified the preset data flow issue (e.g., modified or discussed `buildTaskParams` or the `motionMode === 'basic'` gate in `segmentSettingsUtils.ts`) | and we'll include the id in the right format too, riiiiighhtt? | Verbatim from session. User nudges agent to also fix preset ID format/passthrough in `individualTravelSegment.ts`. |
| T3 | Agent has made changes that switch mode to 'advanced' when a preset is selected, OR agent has modified `handlePhasePresetSelect` or `handleMotionModeChange` in `SegmentSettingsForm.tsx` | and from a UX perspective, could we stay in 'basic' mode but with that selected? how can we make it so it just looks selected but we don't jump into advanced :) | Verbatim from session. User wants preset selection to NOT auto-switch to advanced mode. |
| T4 | Agent has modified the code to keep basic mode on preset selection (e.g., changed the `phase_config` gate in `buildTaskParams` to allow preset data in basic mode) | it should send the right data tho - and if i click into Advanced those settings will be there, right? | Verbatim from session. User confirms data should still flow correctly and be visible in advanced mode. |
| T5 | Agent has completed the code changes and declared the task done or asked if there's anything else | push to github | Verbatim from session. User requests final push. |
