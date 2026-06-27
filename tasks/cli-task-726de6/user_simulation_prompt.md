# User Simulator Prompt — cli-task-726de6

## Simulator Calibration

- **Total real user messages**: 7 in 7 turns. Silence is the default.
- **Longest silence between user messages**: ~15 agent message blocks (between Turn 5 and Turn 6, while agent was reverting changes to Gemini/OpenCode/Cursor).
- **Communication pattern**: Directive and iterative. User reports a problem, checks the fix, gives corrective feedback when it doesn't match expected behavior. Brief messages, no hand-holding. Expects agent to investigate independently.
- **Target message count**: 5-7. User may stay silent if the fix works on first try (unlikely), or provide up to 3 rounds of corrective feedback before accepting.

## User Turns

### Turn 1 (after 0 agent turns — first message)
- **Context**: User opens the conversation with a bug report.
- **Said**: "when I start factory ai droid, and type a prompt I see this: >  {\"systemMessage\":\"\\n\\nPowered by Entire:\\n  This conversation will be linked to your next commit.\"}"
- **Why**: User sees raw JSON printed in the terminal instead of a formatted message. This is the bug they want fixed. They expect the agent to investigate where this JSON comes from and fix it so Factory AI Droid displays a proper message instead of raw JSON.

### Turn 2 (after ~6 agent message blocks — agent explored code, applied initial fix, ran tests)
- **Context**: Agent removed the JSON output and replaced it with the HookResponseWriter interface. Claude Code got JSON output, but Factory AI Droid got nothing (the agent only implemented it for Claude Code initially).
- **Said**: "but now there is no output at all anymore?"
- **Why**: The first fix broke the user-visible behavior entirely. User checks the fix and reports the regression immediately. The message should still appear — just not as raw JSON.

### Turn 3 (after ~4 agent message blocks — agent tried writing to stderr)
- **Context**: Agent implemented WriteHookResponse for Factory AI Droid writing to stderr instead of stdout.
- **Said**: "this seems not to work"
- **Why**: stderr output isn't visible to Factory AI Droid's UI. User tests and reports failure. The output needs to go to stdout as plain text.

### Turn 4 (after ~15 agent message blocks — agent switched to stdout)
- **Context**: Agent changed Factory AI Droid to write plain text to stdout. User now asks about other agents.
- **Said**: "and gemini and opencode didn't had this?"
- **Why**: User realizes the same raw JSON problem would affect Gemini CLI and OpenCode agents. Wants to understand scope — did the fix need to cover them too?

### Turn 5 (after ~12 agent message blocks — agent added HookResponseWriter to all agents)
- **Context**: Agent added WriteHookResponse to Gemini CLI, OpenCode, and Cursor agents. User observed that these agents don't show any output.
- **Said**: "cursor, opencode and gemini are not showing anything, I also didn't see the json before, I think they just don't support showing a message, can you search/check?"
- **Why**: User provides domain knowledge — these agents don't display hook stdout at all, so they never showed the raw JSON and don't need the fix. User asks agent to verify this by searching the codebase/docs. This is a corrective turn that narrows the scope.

### Turn 6 (after ~4 agent message blocks — agent reverted Gemini/OpenCode/Cursor changes)
- **Context**: Agent reverted changes to Gemini CLI, OpenCode, and Cursor. Code is clean with only Claude Code and Factory AI Droid implementing HookResponseWriter.
- **Said**: "can you run simplifier"
- **Why**: User wants a code quality check. This is a project convention (the simplifier/simplify skill reviews code for reuse, quality, and efficiency).

### Turn 7 (after ~2 agent message blocks — simplifier ran, found no issues)
- **Context**: Agent ran simplifier which found no issues. User now asks about documentation.
- **Said**: "does the docs need an update with the new interface?"
- **Why**: User thinks about completeness — new interfaces should be documented. This is a quality-conscious user who wants the codebase maintainable.

## Overview

| Field | Value |
|-------|-------|
| Total user messages | 7 |
| Longest silence | ~15 agent blocks |
| User style | Directive, iterative, detail-oriented |
| Expected fix scope | Add HookResponseWriter interface, implement for Claude Code (JSON) and Factory AI Droid (plain text), remove old outputHookResponse, update lifecycle.go dispatch, update docs |
| Key constraint from user | Only Claude Code and Factory AI Droid need WriteHookResponse — Gemini, OpenCode, Cursor don't display hook stdout |
