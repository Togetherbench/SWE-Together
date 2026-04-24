# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 5
- **Session start**: 2026-01-19T21:26:05.815Z
- **Session end**: 2026-01-19T21:30:09.847Z
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 4 (excluding Turn 1 = instruction.md)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

Turn 1 is the `instruction.md` content (implicit, not listed below).

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has described the bug or proposed a fix for tool-execution.ts BUT has not yet written/edited any source files | "fix it" | Verbatim from session. Fires only if agent analyzed without implementing. |
| T3 | Agent has edited `packages/coding-agent/src/modes/interactive/components/tool-execution.ts` (the fix is in place) | "write a minimal extension so i can test this. the user linked to a simple write tool extension implementation" | Verbatim from session. User wants a test extension after seeing the fix. |
| T4 | Agent has created a file matching `test-write-error-extension/*` or any extension test file | "➜  pi-mono git:(main) ✗ ./pi-test.sh -e test-write-error-extension/index.js\nFailed to load extension \"/Users/badlogic/workspaces/pi-mono/test-write-error-extension/index.js\": Failed to load extension: pi.addTool is not a function\n\nare you fucking stupid? read @packages/coding-agent/docs/extensions.md in full, no truncation" | Verbatim from session. User reports extension loading failure. |
| T5 | Agent has attempted to fix or rewrite the test extension after T4 feedback | "ok remove the test extension, commit and push" | Verbatim from session. User accepts fix, wants cleanup and commit. |
