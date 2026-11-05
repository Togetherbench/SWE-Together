# `entire explain` bugs

## Bug 1: "(no prompt)" in list view

`ReadLatestSessionPromptFromCommittedTree` only reads the latest session's `prompt.txt`.
When the latest session has no prompt (e.g. a test session condensed alongside a real one),
it returns `""` and the list view shows `(no prompt)`.

**Fix:** Fall back through earlier sessions when the latest has no prompt.

**Files:** `cmd/entire/cli/strategy/common.go:546` (`ReadLatestSessionPromptFromCommittedTree`)

## Bug 2: Wrong author in detail view

`GetCheckpointAuthor` walks `entire/checkpoints/v1` commit history to find the commit that
introduced the checkpoint's `metadata.json`. This is broken:

1. The tree is cumulative — every commit after creation has the file, so it walks thousands of commits
2. `LogOrderCommitterTime` with multi-timezone authors creates unpredictable walk order
3. In worktrees, go-git may resolve the branch ref incorrectly (packed-refs vs loose refs mismatch)
4. Even when it works, it returns the git identity of whoever ran the CLI that condensed, not the session author

**Observed:** Returns `Sven Pfleiderer` for Alex's checkpoint because the walk stops at the wrong boundary.

**Fix:** Use the associated commit's author (from the user's branch) instead. `getAssociatedCommits()`
already computes this at `explain.go:293` — use the first commit's author.

**Files:** `cmd/entire/cli/checkpoint/committed.go:1614` (`GetCheckpointAuthor`), `cmd/entire/cli/explain.go:290`

## Bug 3: Test session leaking into real checkpoint data

Checkpoint `629ded414de3` has two sessions:
- Session 0: Alex's real Claude Code session (UUID session ID, has prompt, has tokens)
- Session 1: `session_id: "test"`, `agent: "Mock Lifecycle Agent"`, no prompt, no transcript

Both were condensed from the same shadow branch `entire/aaeab8f-d4735e` during the same
PostCommit hook execution. The test session had a `.git/entire-sessions/test.json` state file
with matching `WorktreePath` and `BaseCommit`.

**Root cause:** The `TestDispatchLifecycleEvent_RoutesToCorrectHandler` test's **SubagentEnd**
case creates `test.json` whenever the working tree has untracked files.

The chain:

1. SubagentEnd test case runs with `sessionID: "test"` and no `t.Chdir()` — real CWD
2. `handleLifecycleSubagentEnd` calls `DetectFileChanges(ctx, nil)` — nil preUntrackedFiles
   because `LoadPreTaskState` fails (no pre-task state was captured for this fake event)
3. With nil preUntrackedFiles, every untracked file in the working tree is reported as "New"
   (only `.entire/` paths are filtered by `IsInfrastructurePath`)
4. Non-empty file change list → handler calls `SaveTaskStep` with `AgentType: ag.Type()`
   → `"Mock Lifecycle Agent"` (from `newMockAgent()`)
5. `SaveTaskStep` (`manual_commit_git.go:176`) finds no session state for "test" → calls
   `initializeSession("test", "Mock Lifecycle Agent", ...)` as fallback
6. `test.json` is written to `.git/entire-sessions/` with fresh `started_at` and `turn_id`

**Why it affects everyone:** Every developer has untracked files (temp files, `.DS_Store`,
editor swap files, `tmp/` contents). Any non-`.entire/` untracked file triggers the chain.

**Why it gets recreated:** Each test run overwrites the file via `initializeSession` (fresh
`started_at`, fresh `turn_id`). The Compaction test case then maintains it by updating
`last_interaction_time`.

**Maintenance (ongoing):** Two mechanisms keep the file alive between recreations:
- **Compaction test:** Same dispatch test's Compaction case runs with `sessionID: "test"` from
  real CWD — loads existing `test.json`, transitions phase, saves back, updating
  `last_interaction_time`.
- **PostCommit hook:** `findSessionsForWorktree` matches `test.json` by `WorktreePath` on
  every real commit. Condenses it alongside real sessions, sets `files_touched` and
  `last_checkpoint_id`.

**Reproduction:**

```bash
# Create any untracked file in the worktree
echo "trigger" > untracked-trigger.txt

# Run the SubagentEnd dispatch test
go test -count=1 -run 'TestDispatchLifecycleEvent_RoutesToCorrectHandler/SubagentEnd' ./cmd/entire/cli/

# Verify test.json was created
cat .git/entire-sessions/test.json
# → session_id: "test", agent_type: "Mock Lifecycle Agent", files_touched: ["untracked-trigger.txt"]

# Clean up
rm untracked-trigger.txt .git/entire-sessions/test.json
```

**Fix:**
1. Fix the dispatch test: add `t.Chdir(t.TempDir())` to SubagentEnd and Compaction cases
   (or the entire test) so they don't touch real repo state
2. Delete `.git/entire-sessions/test.json` on all developer machines
3. Add defensive filtering: skip sessions with non-UUID `session_id` during condensation
4. Consider `entire clean` check for suspicious session IDs

**Impact:** Bugs 1 and 2 are symptoms — the test session becomes the "latest" session in
multi-session checkpoints, masking the real session's prompt and metadata.

**Scope:** 147 contaminated checkpoints on `entire/checkpoints/v1` across 57 branches,
all with `session_id: "test"` and `agent: "Mock Lifecycle Agent"`.
