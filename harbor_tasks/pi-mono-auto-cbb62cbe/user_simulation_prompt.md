# User Simulation Prompt

## Simulator Calibration

- **Total user messages in original session**: 25
- **Session start**: 2026-01-30T00:34:31.322Z
- **Session end**: 2026-01-30T02:14:24.579Z
- **Session duration**: ~100 minutes
- **Intervention style**: Reactive — user corrects after observing agent output, increasingly frustrated
- **Target message count**: 8 (substantive turns only, skipping acks/pings)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | A file matching `*daxnut*` exists under `packages/coding-agent/src/modes/interactive/components/` AND has more than 10 lines of content | looks horrible. | Verbatim from session U2. User rejects first attempt at the component. |
| T3 | Agent has modified `interactive-mode.ts` to add daxnuts-related code (import or function), but no extension directory exists under `.pi/extensions/` | built it as a custom component in an extension so we can iterate faster. can later transfer back to core | Verbatim from session U3. User wants extension approach for faster iteration. |
| T4 | Agent created files under an `examples/` directory related to daxnuts | don't put it in examples you idiot, for reload, i need it in .pi/extensions/ | Verbatim from session U4. User corrects file placement. |
| T5 | Agent has made changes to `interactive-mode.ts` AND `daxnuts.ts` exists in components directory AND `git diff --stat` shows changes to at least 2 files | ok i reveted your changes, @packages/coding-agent/src/modes/interactive/components/daxnuts.ts still exists tho | Verbatim from session U5. User reverted some changes but daxnuts.ts persists. |
| T6 | Agent has created daxnuts component but it has no command/trigger integration in interactive-mode.ts (no `/daxnuts` or `handleDaxnuts` pattern) | ok, i need a command in the extension that inserts the thing in the chat ui, possible? | Verbatim from session U6. User wants a command to trigger the easter egg. |
| T7 | Agent created a command handler but it doesn't use `ui.custom` pattern or lacks dismiss-on-keypress behavior | how about we just show a ui.custom and escape disposes it again .. | Verbatim from session U7. User suggests UI display approach. |
| T8 | The daxnuts component source does NOT contain logic to close/dispose on keypress (no `onKey` or `keypress` or `dispose` pattern) | well, that doesn't close on key press .. | Verbatim from session U8. Missing keyboard dismiss. |
| T9 | The daxnuts component has keypress handling working (contains `onKey` or `keypress` or `dispose` pattern) AND the visual content is minimal (file < 80 lines or no ASCII art / image data) | ok, key input works. now for the actual content. it's fucking lame.\n\ncan you clone https://github.com/anomalyco/opencode and see if there's an ascii art image of dax? | Verbatim from session U9. Content needs improvement + look for dax art. |
| T10 | Agent has added substantial visual content (daxnuts.ts > 100 lines or contains image/art data) but no "Free Kimi K2.5" text | ok before powered by daxnuts, add "Free Kimi K2.5 via OpenCode Zen" | Verbatim from session U14. Add specific branding text. |
| T11 | The daxnuts component has "Free Kimi K2.5" AND "daxnuts" text AND has been wired into a component or extension, but interactive-mode.ts does NOT yet have the trigger logic for opencode+kimi model selection | ok, now move to core and wire up the logic | Verbatim from session U16. Move from extension to core integration. |
