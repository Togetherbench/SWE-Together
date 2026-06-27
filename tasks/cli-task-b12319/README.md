# Task: cli-task-b12319

| Field | Value |
|-------|-------|
| Source session | `b12319af-9a0a-4691-b084-e5fc5ae7e446` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `5268246a18f069b450de4feff863bd80e7ea759e` |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 2 (initial detailed plan + 1 follow-up) |

## Summary

Implement an external agent plugin protocol for the Entire CLI. The task requires:

1. Creating `cmd/entire/cli/agent/external/` — an adapter package that bridges external agent binaries to the CLI's Agent interface via a subcommand-based JSON protocol
2. Creating `cmd/entire-agent-cursor/` — a standalone binary that implements the external protocol for Cursor IDE integration
3. Adding PATH-based discovery (`external.DiscoverAndRegister()`) to find `entire-agent-*` binaries
4. Removing the built-in Cursor agent (`cmd/entire/cli/agent/cursor/`)
5. Updating `hooks_cmd.go`, `architecture_test.go`, and `manual_commit_condensation_test.go` accordingly
6. Writing protocol documentation at `docs/architecture/external-agent-protocol.md`

## User Simulator Behavior
- Total real user messages: 2 in 321 total turns. Silence is the default.
- Longest silence: 154 agent turns
- Turn 0: User sends a 10K-character detailed implementation plan
- Turn 1: User asks "Can you implement the cursor agent using the new external type? Keep it in this repo for now."

## Test Commands
- Build: `go build ./cmd/entire/cli/...`
- Vet: `go vet ./cmd/entire/cli/...`
- Test: `go test -tags=integration -race ./...` (from CI: `mise run test:ci`)
- Lint: `golangci-lint run` (from CI: `mise run lint`)
