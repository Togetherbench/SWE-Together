# Task: agent-swarm-task-4a881b

| Field | Value |
|-------|-------|
| Source session | `4a881bb4-433e-4400-9d44-e77806f19dd7` |
| Repo | desplega-ai/agent-swarm (257 stars) |
| Base commit | `cc8c7f5` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 3 |

## User Simulator Behavior
- Total real user messages: 3 in 380 turns. Silence is the default.
- Longest silence: ~3 hours 48 minutes (user silent during entire implementation)
- Turn-by-turn summary:
  1. User assigns task: `/desplega:implement-plan plans/2026-03-06-one-time-scheduled-tasks.md`
  2. After 3h48m of silence: `did you perform manual e2es?`
  3. After 5 min: `ok, bump tha version, commit the changes and push (disregard the workflow unstaged files!)`

## Task Summary
Extend the agent-swarm scheduled tasks system to support one-time (delayed) schedules alongside existing recurring schedules. A new `scheduleType` column distinguishes recurring from one-time schedules. One-time schedules auto-disable after execution and don't require a cron expression or interval.

### Key changes needed:
1. **Database**: New migration adding `scheduleType` column, relaxing CHECK constraint
2. **Types**: Add `scheduleType` to Zod schema, adjust `.refine()`
3. **DB layer**: Add `scheduleType` to row type, mapper, create/update functions
4. **Scheduler**: Auto-disable one-time after execution (all paths), skip `calculateNextRun`
5. **MCP tools**: Accept `delayMs`/`runAt` for one-time, add `scheduleType`/`hideCompleted` filters
6. **HTTP API**: Support `scheduleType` in POST/PUT, add query filters to GET
7. **UI**: Show schedule type badges in list/detail views

### Tech Stack
- Runtime: Bun
- Language: TypeScript
- DB: SQLite (via better-sqlite3)
- Frontend: React (new-ui/ with pnpm)
- Testing: bun test
- Linting: Biome (`bun run lint:fix`)
- Type check: `bun run tsc:check`

### CI/CD Commands
- `bun run lint` — lint check (Biome)
- `bun run tsc:check` — TypeScript type checking
- `bun test` — full test suite
