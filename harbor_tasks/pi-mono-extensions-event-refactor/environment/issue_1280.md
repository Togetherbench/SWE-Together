> Offline snapshot of GitHub issue #1280 from `badlogic/pi-mono`, captured for
> benchmark reproducibility. Analyze from this snapshot and the repository source;
> external links are not available in this environment.

# Issue #1280: Multiple extensions handling `tool_result` events don't chain results

- Repo: badlogic/pi-mono
- Labels: none
- Reported by: @0xferrous

## Issue body

### What do you want to change?

I want to change it so that if there is a modification to the tool_result.content, it is passed on to the next extension in the chain so that every extension's result is applied.

### Why?

## Problem

When multiple extensions register handlers for tool_result events, the output from one extension is not passed to the next. Instead, the last extension in the loop to return is the one whose result gets used. This makes the behavior non-deterministic, unexpected and also difficult to debug.

## Context

This was discovered while implementing an extension to filter sensitive data (e.g., .env file contents) from tool call results before sending to hosted AI providers. I was unable to figure out why my changes were not getting applied until I realised its because of other extension being loaded after mine, `pi --no-extensions -e ./extension.ts` made it work.

## Expected Behavior

When multiple extensions handle tool_result events, the result from the previous extension's content and details should be passed to the next extension in the chain. Each extension should be able to transform the result, similar to a middleware.

## Actual Behavior

Only the last extension's return value is used. Other extensions' modifications to the tool result are discarded.

## Relevant code

`packages/coding-agent/src/core/extensions/runner.ts` (around lines 499-501)

### How? (optional)

do something like this so tool result modifications are chained

```ts
// For tool_result events, chain modifications from all handlers
if (event.type === "tool_result") {
        let currentContent = event.content;
        let currentDetails = event.details;
        let currentIsError = event.isError;
        let modified = false;

        for (const ext of this.extensions) {
                const handlers = ext.handlers.get("tool_result");
                if (!handlers || handlers.length === 0) continue;

                for (const handler of handlers) {
                        try {
                                // Create event with current accumulated values
                                const toolResultEvent = { ...event, content: currentContent, details: currentDetails, isError: currentIsError };
                                const handlerResult = (await handler(toolResultEvent, ctx)) as ToolResultEventResult | undefined;

                                if (handlerResult) {
                                        if (handlerResult.content !== undefined) {
                                                currentContent = handlerResult.content;
                                                modified = true;
                                        }
                                        if (handlerResult.details !== undefined) {
                                                currentDetails = handlerResult.details;
                                                modified = true;
                                        }
                                        if (handlerResult.isError !== undefined) {
                                                currentIsError = handlerResult.isError;
                                                modified = true;
                                        }
                                }
                        } catch (err) {
                                const message = err instanceof Error ? err.message : String(err);
                                const stack = err instanceof Error ? err.stack : undefined;
                                this.emitError({
                                        extensionPath: ext.path,
                                        event: "tool_result",
                                        error: message,
                                        stack,
                                });
                        }
                }
        }

        return modified ? { content: currentContent, details: currentDetails, isError: currentIsError } : undefined;
}
```
