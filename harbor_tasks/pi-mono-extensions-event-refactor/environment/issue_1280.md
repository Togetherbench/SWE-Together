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

[REDACTED for benchmark: the reporter's "How?" section in the upstream issue
included a near-complete proposed implementation. It was removed from this
offline snapshot to avoid answer-leakage. The Problem / Context / Expected
Behavior / Actual Behavior sections above describe the desired semantics
(chaining modifications across handlers, middleware-style); design and
implementation are left to the agent.]
