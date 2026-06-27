# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 7
- **Session start**: 2026-02-06T20:24:31.406Z
- **Session end**: 2026-02-06T20:37:12.215Z
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 7
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has mentioned `shutdown-command.ts` or the `/quit` command and identified it as an example slash command | [Extension issues]\n  path (temp) ~/workspaces/pi-mono/packages/coding-agent/examples/extensions/shutdown-command.ts\n    Extension command 'quit' from\n/Users/badlogic/workspaces/pi-mono/packages/coding-agent/examples/extensions/shutdown-command.ts conflicts\nwith built-in commands. Skipping.\n\nplease fix call the command shutdown | User reports name conflict with built-in "quit"; wants it renamed to "shutdown" |
| T3 | Agent has renamed the command from `quit` to `shutdown` in shutdown-command.ts (e.g. changed `registerCommand("quit"` to `registerCommand("shutdown"`) but has NOT modified the shutdown behavior itself | well, that doesn't actually shutdown :D | Renaming alone doesn't fix the actual shutdown behavior |
| T4 | Agent has modified `shutdown-command.ts` handler (e.g. added `process.exit`, `isIdle` check, or similar) but has NOT modified `packages/coding-agent/src/modes/interactive/interactive-mode.ts` | that doesn't exit cleanly. doesn't shut down the tui, so i get garbled output | Fix in extension file causes garbled TUI output; needs to be in core |
| T5 | Agent has made changes to `shutdown-command.ts` (the extension example file) rather than fixing the issue in `packages/coding-agent/src/` | i reverted the chane in ghe @packages/coding-agent/examples/extensions/shutdown-command.ts this must be fixed in coding-agent | User explicitly redirects: fix must be in coding-agent core, not the extension |
| T6 | Agent has modified `packages/coding-agent/src/modes/interactive/interactive-mode.ts` shutdownHandler to call `this.shutdown()` when idle | ok, this waits until the agent has stopped its current turn, is that documented? | User asks about documentation of deferred shutdown behavior |
| T7 | Agent has confirmed the fix passes checks AND has not yet run `git commit` | ok, comimt and push the fix | User asks to commit and push |
