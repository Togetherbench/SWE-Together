Implement a feature for GitHub issue #2406 in this pi-mono repository.

**Issue**: Render bash tool execution timing at the bottom of the bash tool output, not the top, to avoid triggering a full TUI rerender.

**Background**: The TUI's diff algorithm (`packages/tui/src/tui.ts`) compares previous and new frames. When the first changed line is above the viewport, it falls back to a full redraw. For long bash output where the header scrolls off-screen, mutating the header forces a full redraw. Timing info must therefore go at the **bottom** of the bash component.

**What to implement**:

1. In `packages/coding-agent/src/modes/interactive/components/tool-execution.ts`, add a timing footer line at the **very end** of `renderBashContent()` (after output and truncation warnings):
   - While the bash command is still running: display `Elapsed Xs` (e.g., `Elapsed 12.3s`)
   - After the bash command completes: display `Took Xs` (e.g., `Took 47.2s`)
   - The timing should show with one decimal place of precision
   - Do NOT put any timing in the header — keep the header static
   - The elapsed time should update live (once per second) while the command is running

2. In `packages/coding-agent/src/modes/interactive/interactive-mode.ts`, wire up the execution start timestamp when the `tool_execution_start` event fires for bash tools.

Read the existing code in both files to understand the patterns used (event handling, component rendering, tool types).
