# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 41
- **Session start**: 2026-01-30T10:29:23.963Z
- **Session end**: 2026-01-30T12:18:30.543Z
- **Intervention style**: Reactive — user corrects after observing agent output, provides debug logs and UI feedback
- **Target message count**: 8 (substantive turns after instruction; skipped context-continuations, interruptions, and non-task turns)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Context

The user wants multi-select functionality added to a Timeline view in a React/TypeScript app. The instruction.md contains a detailed implementation plan. The user provides iterative feedback as the agent implements, focusing on:
1. Tap/click selection behavior (should match existing Shot Images Editor)
2. SelectionActionBar integration (new shot button, jump-to-shot)
3. Visual polish (remove badges, check marks)

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has created or modified `useTimelineSelection.ts` and modified `TimelineItem.tsx` to add selection support, but the implementation uses a mechanism other than simple click-to-toggle (e.g., requires modifier keys, double-tap, or doesn't distinguish drag from select) | "Hey so here's some feedback um the first tap on an item should just select it similar to how it does in the shot images editor unless unless it's a drag in which case you should just drag that specific item can you see why um it doesn't um and it should also highlight orange in the same kind of orange the way it does in the shot images editor as wel" | Verbatim from session U2. Fires after initial selection implementation if tap behavior is wrong. |
| T3 | Agent has attempted to fix tap-to-select but `useTimelineSelection.ts` still does not implement a simple single-click toggle, OR `TimelineItem.tsx` onClick handler does not call the selection toggle | "A single tap still doesn't seem to be select. Can you look at how we're doing it in the Shot Images Editor?" | Verbatim from session U4. Fires if first fix attempt didn't resolve tap-to-select. |
| T4 | Agent has implemented selection and `SelectionActionBar` is rendered in `TimelineContainer.tsx`, but the `onNewShot` prop is not passed or is undefined | "Nice! Why does the 'Create a new shot with the selected images' thing not show on the multi-select thing that appears on timeline?" | Verbatim from session U10. Fires when selection bar works but new-shot button is missing. |
| T5 | Agent has wired up `onNewShot` in `SelectionActionBar` within `TimelineContainer.tsx` but does not show success state after shot creation (bar disappears immediately) | "When I create a new shot using that button in the timeline mode the selector disappears afterwards but in the batch mode it shows success date can you make it work like works in the batch mode it should show success date" | Verbatim from session U12. Fires if new-shot integration loses success feedback. |
| T6 | Agent has added success state to the new shot flow but there is no navigation/jump-to-shot functionality after shot creation | "Could you make the success state a -> jump to shot button that when clicked jumps to the shot" | Verbatim from session U13. Fires after success state works but no navigation. |
| T7 | Agent has implemented jump-to-shot but it uses text label instead of an icon, OR the button text is longer than 20 characters | "That jumped to shot button doesn't work. And can you make it just show an icon, not the whole text?" | Verbatim from session U14. Fires if jump-to-shot uses verbose text. |
| T8 | Agent has completed multi-select with selection bar and `TimelineItem.tsx` renders a visible count badge or number overlay on selected items | "And can you see when I select an item on the timeline, it seems like there's something showing in the top right corner like maybe a number or something when I select two. Can you remove that?" | Verbatim from session U30. Fires if selection count badge is visible on items. |
| T9 | Agent has addressed the count badge but `TimelineItem.tsx` still renders a check mark or similar selection indicator overlay on selected items | "Can you also remove the selected check mark thing that appears?" | Verbatim from session U31. Fires if check mark indicator still visible after badge removal. |
