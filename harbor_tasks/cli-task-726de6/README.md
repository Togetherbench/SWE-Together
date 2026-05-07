# Task: cli-task-726de6

| Field | Value |
|-------|-------|
| Source session | `726de64d-e8b7-4952-a516-72c4774b2003` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `7f1cdc8c441effc233552e9780c51821939a00db` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 7 |

## Bug
When Factory AI Droid fires the `SessionStart` hook, raw JSON is printed to the terminal:
```
{"systemMessage":"\n\nPowered by Entire:\n  This conversation will be linked to your next commit."}
```

The root cause is `outputHookResponse()` in `cmd/entire/cli/hooks.go`, which unconditionally writes JSON to stdout. This is the Claude Code hook protocol, but Factory AI Droid doesn't parse it — so raw JSON leaks to the user's terminal.

## Expected Fix
- Add a `HookResponseWriter` interface to `cmd/entire/cli/agent/agent.go` with `WriteHookResponse(message string) error`
- Implement it for Claude Code (JSON `systemMessage` to stdout) and Factory AI Droid (plain text to stdout)
- Remove `outputHookResponse()` and `hookResponse` struct from `cmd/entire/cli/hooks.go`
- Update `handleLifecycleSessionStart` in `cmd/entire/cli/lifecycle.go` to use the interface via type assertion
- Update `docs/architecture/agent-guide.md` to document the new interface
- Do NOT add `HookResponseWriter` to Gemini CLI, OpenCode, or Cursor — they don't display hook stdout

## User Simulator Behavior
- Total real user messages: 7 in 7 turns. Silence is the default.
- Longest silence: ~15 agent message blocks (during agent's revert of Gemini/OpenCode/Cursor changes)
- Communication pattern: Directive and iterative. User reports bug, tests each fix attempt, provides corrective feedback when behavior doesn't match expectations. Brief messages, domain-aware.
- Turn 1: Bug report — raw JSON when starting Factory AI Droid
- Turn 2: "but now there is no output at all anymore?" — regression after first fix removed all output
- Turn 3: "this seems not to work" — stderr approach silently failed
- Turn 4: "and gemini and opencode didn't had this?" — scope question
- Turn 5: Corrective — Gemini, OpenCode, Cursor don't need the fix (they don't display hook stdout)
- Turn 6: "can you run simplifier" — code quality check
- Turn 7: "does the docs need an update with the new interface?" — completeness check
