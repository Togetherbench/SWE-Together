# Task: agent-swarm-task-ea4bd8

| Field | Value |
|-------|-------|
| Source session | `ea4bd83a-342a-478d-8ad6-14afe2adc5ca` |
| Repo | desplega-ai/agent-swarm (257 stars) |
| Base commit | `c3a5e1a4c0eeadd87057629db2baa0d0abe1575e` |
| Canonical patch | `c26a402303d469dbdbc96dcc9e10970aae319f3a` (+70/-123, 5 files) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 4 |

## Summary

The Docker worker image rebuilds slowly due to un-pinned npm package versions (`@latest`),
runtime marketplace plugin installs in the entrypoint, static setup happening at container
start instead of build time, and apt-get split across 3 separate RUN layers.

The user provides a detailed 4-phase plan covering:
1. Pin npm package versions in Dockerfile.worker
2. Consolidate apt-get into a single RUN layer
3. Move marketplace installs, wts config, and static directories from entrypoint to Dockerfile
4. Reorder Docker layers for optimal cache hits

Later messages add scope: agentmail-mcp support in .mcp.json and lazy task loading in the UI.

## Files Changed (canonical patch)

| File | Lines | Description |
|------|-------|-------------|
| Dockerfile.worker | +53/-51 | Consolidated apt, pinned npm, moved static setup, reordered layers |
| docker-entrypoint.sh | +21/-83 | Removed marketplace block, wts config, static dirs; refactored MCP to jq |
| new-ui/src/api/hooks/use-agents.ts | +1/-1 | Lazy task loading: `fetchAgent(id, false)` |
| package.json | +1/-1 | Version bump 1.35.3 → 1.35.4 |
| .gitignore | +3/-0 | Added `.humanlayer/tasks/` |

## User Simulator Behavior

- Total real user messages: 4 in 102 turns. Silence is the default.
- Longest silence: 18 agent turns (end of session)
- Turn-by-turn summary:
  1. **Turn 1** — Pastes detailed 4-phase implementation plan
  2. **Turn 2** — "continue" after ~25min interruption
  3. **Turn 3** — "please perform e2e, also double check pinned versions are latest"
  4. **Turn 4** — Adds agentmail-mcp and lazy UI task loading

## Test Gates

5 F2P gates (weights sum to 1.0): apt-get consolidation (0.25), npm version pinning (0.20),
MCP JSON jq generation (0.25), marketplace at build time (0.15), lazy task loading (0.15).

5 P2P regression gates: no marketplace/plugin installs in entrypoint, no wts config in
entrypoint, MCP uses jq not heredoc, wts config present in Dockerfile, no static dir
creation in entrypoint.

## CI Reference

Upstream CI (.github/workflows/ci.yml): `bun install --frozen-lockfile`, `bun run lint`,
`bun run tsc:check`, `bun test`.
