# Task: cli-task-408b8c

| Field | Value |
|-------|-------|
| Source session | `408b8c7a-970e-44d6-97d2-5055b778a417` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `02c2e987` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 5 |

## Summary

Add caching to `GetWorktreePath()` in `cmd/entire/cli/strategy/common.go`. The function currently runs `git rev-parse --show-toplevel` on every call, which is expensive since it's called ~20 times across the codebase. The `paths.RepoRoot()` function (in `cmd/entire/cli/paths/paths.go`) already implements the same cwd-keyed caching pattern for the identical git command.

The user's instruction is intentionally vague — they only say "look at RepoRoot and GetCommonDir and update GetWorktreePath." Multiple solutions are possible:
- Add a separate cache with mutex (like the initial implementation)
- Delegate to `paths.RepoRoot()` directly (like the final canonical solution)
- Any other caching approach that avoids redundant git commands

## User Simulator Behavior
- **Total real user messages**: 5 in ~35 agent turns. Silence is the default.
- **Longest silence**: ~10 min (between push and next analytical question)
- **Turn-by-turn summary**:
  1. "add caching to GetWorktreePath" (code modification request)
  2. "commit this" (workflow)
  3. "push it to github" (workflow)
  4. "how does OpenRepository work under the covers?" (analysis)
  5. "implement fixes based on feedback" (review-driven refinement)
- User is a senior Go developer who gives direct, concise instructions and responds to code review feedback.

## Verification

Tests verify four behavioral properties of the modified `GetWorktreePath`:
1. **Caching works** — second call in same directory uses cache (proved by breaking git PATH)
2. **Worktree resolution** — returns worktree root, not main repo root, when called from inside a worktree
3. **Cache clearing** — `ClearWorktreePathCache` invalidates the cache
4. **Repo root correctness** — returned path matches `git rev-parse --show-toplevel`

Plus a P2P regression gate: existing strategy package tests must still pass.
