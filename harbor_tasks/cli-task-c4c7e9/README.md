# Task: cli-task-c4c7e9

| Field | Value |
|-------|-------|
| Source session | `c4c7e905-d2bf-4366-99c5-b3c2a0948d8a` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `cef3938d6f9a678a364567482033a219dc0d22db` (parent of `8b01d8e0` "Remove trail title generation") |
| Difficulty | easy |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

Remove trail title generation code from the `entireio/cli` Go codebase. The buggy state has a `trail_title.go` file and a `generateTrailTitleForTrail` function that uses an LLM to auto-generate trail titles/descriptions. The user wants this removed — trails should be manually titled.

## Changes Expected

1. Delete `cmd/entire/cli/summarize/trail_title.go`
2. Remove `generateTrailTitleForTrail` function from `cmd/entire/cli/strategy/manual_commit_hooks.go`
3. Remove the call to `generateTrailTitleForTrail` in `condenseAndUpdateState`
4. Remove the `summarize` import from `manual_commit_hooks.go` (if no other usage)

## User Simulator Behavior

- Total real user messages: 3 in 142 total message exchanges. Silence is the default.
- Longest silence: 41 agent turns (~3 minutes of investigation)
- Turn 1: "Is there still trail 'generation' code in this branch from the auto generation that we removed?" — diagnostic
- Turn 2: "Let's remove all that" — actionable instruction (this is instruction.md)
- Turn 3: "commit this" — request to commit changes

## CI/CD

- CI: `.github/workflows/ci.yml` — `mise run test:ci:core` (wraps `go test ./...`)
- Build: `go build ./cmd/entire/...`
- Lint: `mise run lint` (wraps gofmt, golangci-lint, shellcheck)

## Test Gates

| Gate | Weight | Tier | What it checks |
|------|--------|------|----------------|
| g1 | 0.25 | Gold | trail_title.go does not exist |
| g2 | 0.20 | Gold | summarize import removed from manual_commit_hooks.go |
| g3 | 0.25 | Gold | generateTrailTitleForTrail function removed |
| g4 | 0.15 | Gold | GenerateTrailTitle function not found anywhere |
| g5 | 0.10 | Bronze | go vet passes on affected packages |
| g6 | 0.05 | Bronze | No stale references in summarize/ directory |
| p2p | gate | P2P | go build ./cmd/entire/... still succeeds |
