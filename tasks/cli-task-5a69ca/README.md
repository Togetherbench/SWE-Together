# Task: cli-task-5a69ca

| Field | Value |
|-------|-------|
| Source session | `5a69ca08-eee5-4626-ac94-c23483e262cb` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `4f09f97c2a2d90f5fa28609ff98dbd9ccb988794` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 7 |

## Summary

Fix the cryptic "reference not found" error that occurs when using the `entire` CLI
in a freshly `git init`'d repo with no commits. The `go-git` library's `repo.Head()`
returns `plumbing.ErrReferenceNotFound` for empty repos, which both strategy
implementations fail to handle, producing unhelpful error messages. The fix adds
an `ErrEmptyRepository` sentinel error, an `IsEmptyRepository()` helper, and
graceful error handling in both auto-commit and manual-commit strategies.

## Changes required

- Add `ErrEmptyRepository` sentinel error to `strategy/strategy.go`
- Add `IsEmptyRepository(*git.Repository) bool` helper to `strategy/common.go`
- Detect empty repos in `strategy/manual_commit_session.go` `initializeSession`
- Detect empty repos in `strategy/auto_commit.go` `InitializeSession`
- Show friendly note in `hooks_claudecode_handlers.go` instead of generic warning
- Warn during `entire enable` in `setup.go` that checkpoints need a first commit
- Add unit tests in strategy test files

## Files touched

| File | Change |
|------|--------|
| `cmd/entire/cli/strategy/strategy.go` | Add `ErrEmptyRepository` sentinel |
| `cmd/entire/cli/strategy/common.go` | Add `IsEmptyRepository()` helper |
| `cmd/entire/cli/strategy/manual_commit_session.go` | Detect empty repo in `initializeSession` |
| `cmd/entire/cli/strategy/auto_commit.go` | Detect empty repo in `InitializeSession` |
| `cmd/entire/cli/hooks_claudecode_handlers.go` | Friendly message for empty repo |
| `cmd/entire/cli/setup.go` | Warning during `entire enable` |
| `cmd/entire/cli/strategy/manual_commit_test.go` | Unit test |
| `cmd/entire/cli/strategy/auto_commit_test.go` | Unit test |
| `cmd/entire/cli/strategy/common_test.go` | Unit test |

## User Simulator Behavior

- Total real user messages: 7 in 153 total messages. Silence is the default.
- Longest silence: 58 agent turns (while agent implemented the plan)
- Turn 1 (after 58 agent turns): "commit this on a feature branch. use prefix 'rwr/' for the branch name"
- Turn 2 (after 8 agent turns): resource leak concern about `OpenRepository`
- Turn 3 (after 3 agent turns): architectural suggestion to centralize empty-repo check
- Turn 4 (after 3 agent turns): "make a PR for this"
- Turn 5 (after 6 agent turns): request for empty commit checkpoint
- Turn 6 (after 2 agent turns): "push this to the branch"
- Turn 7 (after 2 agent turns): flag that `hooks_geminicli_handers.go` needs same fix

## CI/CD

- Build: `go build ./...`
- Test: `go test ./...` (unit), `go test -tags=integration -race ./...` (CI)
- Format: `gofmt -s -w .`
- Lint: `golangci-lint run --timeout=30m ./...`
