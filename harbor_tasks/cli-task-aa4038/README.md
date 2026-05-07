# Task: cli-task-aa4038

| Field | Value |
|-------|-------|
| Source session | `aa4038a5-34b6-41e4-8541-9cca654dcbc5` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `1b69ae14da4a0d3deb08922bb6798b9bc5fb6e02` |
| Difficulty | hard |
| Category | bugfix |
| Real user msgs | 7 |
| Files changed (canonical) | 5 files, +65/-11 lines |

## Problem

Multi-session checkpoints can contain sessions from different agents (Claude, Gemini). When restoring transcripts, the system collapses everything to a single agent's directory, causing non-primary sessions' transcripts to be written to the wrong location with wrong file extensions and wrong resume commands.

## Solution Space

The fix requires ensuring that when a checkpoint is written, enough information is stored to restore each session's transcript to its correct location. Two valid approaches:

1. **Transcript path storage**: Store the transcript path in `CommittedMetadata` and use it during restore (the canonical approach)
2. **Per-session agent resolution**: Resolve each session's agent from `content.Metadata.Agent` during restore to compute the correct directory (the approach described in the instruction plan)

## Key Files

| File | Role |
|------|------|
| `cmd/entire/cli/checkpoint/checkpoint.go` | `CommittedMetadata` and `WriteCommittedOptions` structs |
| `cmd/entire/cli/checkpoint/committed.go` | Writes session metadata to git |
| `cmd/entire/cli/strategy/common.go` | Shared utilities (e.g., path helpers) |
| `cmd/entire/cli/strategy/manual_commit_condensation.go` | Condenses sessions into checkpoints |
| `cmd/entire/cli/strategy/manual_commit_rewind.go` | `RestoreLogsOnly`, `classifySessionsForRestore`, `ResolveSessionFilePath` |
| `cmd/entire/cli/strategy/strategy.go` | `LogsOnlyRestorer` interface |
| `cmd/entire/cli/rewind.go` | Callers of `RestoreLogsOnly` and resume command printing |
| `cmd/entire/cli/resume.go` | Resume logic using restored sessions |

## User Simulator Behavior
- Total real user messages: 7 in 367 total messages (229 agent turns). Silence is the default.
- Longest silence: 191 agent turns (~14 min) between Turn 1 and Turn 2
- Turn 1: Detailed implementation plan (per-session agent resolution)
- Turn 2: "Do not fallback" — no silent fallback for unknown agents
- Turn 3: "Log skipped sessions" — visibility into dropped sessions
- Turn 4: Warning message phrasing correction
- Turn 5: "fix test" — brief directive
- Turn 6: Diagnostic question about Gemini path patterns
- Turn 7: New requirements — actual Gemini path format, asks for a plan to fix only Gemini

## Verification

CI commands (from `.github/workflows/ci.yml` and `mise.toml`):
- Build: `go build ./...`
- Test: `go test ./...`
- CI test: `go test -tags=integration -race ./...`
- Lint: `gofmt -s -w .`
- Go version: 1.25.6
