# Task: cli-task-ea3f8f

| Field | Value |
|-------|-------|
| Source session | `ea3f8f47-2d40-474f-bb55-bde41f47b79c` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `69b9d730045ad92c202f987e4fee88a3fa0e32aa` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 8 |

## Summary

The Cursor IDE agent's `ResolveSessionFile` method fails to locate transcript files when the IDE creates a session directory before flushing the transcript file. The fix adds a directory-existence check: if the nested directory exists (even if the file hasn't been written yet), predict the nested path instead of falling back to the flat path.

## User Simulator Behavior

- Total real user messages: 8 in 236 agent turns (3.4% message rate). Silence is the default.
- Longest silence: 88 agent turns between user feedback messages
- Turn 0: User posts a detailed implementation plan (4.8K chars)
- Turn 1: "ok, this clearly made progress, the issue is still..." — tests results, reports remaining bugs
- Turn 2: "ok, this works, can you now compare our fixes to 527" — confirms fix, asks for comparison
- Turn 3: "yeah #527 has still the issue..." — PR analysis, wants fix applied to that branch
- Turn 4: "why is in lifecycle.go:22 the ctx needed?" — code design question
- Turn 5: "hmm, I just tried it...not working anymore" — regression report
- Turn 6: "so I tried this now in the cursor ide...failed mid turn" — IDE test report
- Turn 7: "/Users/soph/Work/entire/test/test_cursor2" — test script path

## Key files

| File | Role |
|------|------|
| `cmd/entire/cli/agent/cursor/cursor.go` | Production code — `ResolveSessionFile` (buggy) |
| `cmd/entire/cli/agent/cursor/cursor_test.go` | Existing tests + agent's new test |
| `cmd/entire/cli/agent/cursor/lifecycle.go` | Cursor lifecycle hooks (related context) |
| `cmd/entire/cli/lifecycle.go` | Top-level lifecycle handling (related context) |

## Verifier gates

| Gate | Kind | Weight |
|------|------|--------|
| p2p_compiles | P2P_REGRESSION | 0 |
| p2p_existing_tests | P2P_REGRESSION | 0 |
| f2p_dir_only | F2P | 0.25 |
| f2p_nested_exists | F2P | 0.20 |
| f2p_flat_fallback | F2P | 0.15 |
| f2p_new_test | F2P | 0.10 |
