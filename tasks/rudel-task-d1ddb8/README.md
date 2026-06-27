# Task: rudel-task-d1ddb8

| Field | Value |
|-------|-------|
| Source session | `d1ddb826-b4ef-42c2-b940-1b81d4c9b6de` |
| Repo | obsessiondb/rudel (184 stars) |
| Base commit | `64f29e4a` (tag: `rudel@0.1.2`) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

The user reports that `rudel enable` doesn't add hooks to `.claude/settings.json`. Investigation reveals the command always targets `~/.claude/settings.json` (the user's global settings) rather than the project-level `.claude/settings.json`. The fix requires changing `getClaudeSettingsPath()` in `apps/cli/src/lib/claude-settings.ts` to walk up from the current directory looking for an existing `.claude/` directory, falling back to the git repo root, then cwd.

## Key Files
- `apps/cli/src/lib/claude-settings.ts` — core file to modify (getClaudeSettingsPath, writeClaudeSettings, findClaudeDir)
- `apps/cli/src/commands/enable.ts` — uses getClaudeSettingsPath for status messages
- `apps/cli/src/commands/disable.ts` — uses getClaudeSettingsPath for status messages

## User Simulator Behavior
- Total real user messages: 3 in 59 turns. Silence is the default.
- Longest silence: 20 agent turns between message 1 and 2
- Turn 1: Bug report — `rudel enable` doesn't add hooks to settings
- Turn 2 (after 20 turns): Asks whether it defaults to user dir, wants to test from clean state
- Turn 3 (after 14 turns): Specifies desired behavior — walk up directories to find `.claude/`, fall back to git root
- Communication: Direct, terse, no pleasantries. Reports issues and specifies desired behavior.

## Verifier
- 8 F2P gates (5 structural, 3 behavioral) totaling weight 1.00
- 6 P2P regression gates (diagnostic-only)
- CI test source: `.github/workflows/ci.yml` uses `bunx turbo run lint check-types test build`
- CLI tests: `bun test` (Bun native test runner)
