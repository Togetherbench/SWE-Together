# User Simulation Prompt

## Simulator Calibration

- **Total user messages in original session**: 22
- **Session start**: 2026-02-10T13:41:58.917Z
- **Session end**: 2026-02-10T16:22:15.762Z
- **Intervention style**: Reactive — user corrects after observing agent output, asks for reviews
- **Target message count**: 3 (substantive turns relevant to the refactoring task)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Context

The user gave a detailed 4-step refactoring plan to move the drawing state machine into StrokeOverlay. The session had context overflows (3 continuation messages). After the initial refactoring, the user asked for full code review and quality checks. Later messages diverge to unrelated features (variant selector, fill edges button) — those are excluded as they are outside the scope of instruction.md.

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has edited or deleted at least 2 files under `hooks/inpainting/` but at least one of `useStrokeRendering.ts`, `usePointerHandlers.ts`, `useDragState.ts`, `useInpaintActions.ts` still exists | "Can you send check this from top to bottom?" | Verbatim from U3 (2026-02-10T13:59:47). User asked for full review mid-refactoring. |
| T3 | Agent has deleted all 4 hook files AND modified `StrokeOverlay.tsx` AND modified `useInpainting.ts` | "Is the code beautiful now?" | Verbatim from U5 (2026-02-10T14:02:45). User checking quality after structural changes complete. |
| T4 | Agent has responded to T3 (or declared task done) AND `types.ts` still contains `handleKonvaPointerDown` or `redrawStrokes` | "is it beautiful now?" | Verbatim from U7 (2026-02-10T14:06:36). User repeating quality check — implies cleanup not thorough enough. |
