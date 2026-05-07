# Task: cli-task-30159a

| Field | Value |
|-------|-------|
| Source session | `30159aa1-626d-4de8-923a-317a4859bbc4` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `1278f43b5de25e177d089f9a1dc0b67592c2fc16` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 7 |
| Language | Go |

## Summary

The user identified that `TestUpdateCommand` in the versioncheck package is non-deterministic — it tests against the local machine's setup (where Go/the CLI is installed) rather than testing each code path. The task is to make the test deterministic and fix path detection to avoid false positives from usernames (e.g., `/home/mise/bin/entire` should not trigger "mise upgrade").

## Changes Required

1. **`versioncheck.go`**: Extract `os.Executable` calls into an overridable variable so tests can inject paths. Tighten path detection patterns:
   - `/mise/` → `/mise/installs/` (avoids username "mise" false positive)
   - `/homebrew/` → `/opt/homebrew/` and `/linuxbrew/` (avoids username "homebrew" false positive)

2. **`versioncheck_test.go`**: Replace the single non-deterministic test with table-driven subtests covering all branches: Homebrew Cellar, Homebrew opt, Linuxbrew, mise, username false positives, unknown path fallback, and executable error fallback.

## User Simulator Behavior
- Total real user messages: 7 in 83 turns. Silence is the default.
- Longest silence: ~2 min 18 sec (agent implementing fix)
- Turn 1: "can you review the local changes? can you then look at TestUpdateCommand I feel this test is wrong..."
- Turn 2: "yes" (confirmed proposed fix)
- Turn 3: "can you help me understand how mise install knows of packages?" (curiosity)
- Turn 4: "what's the aqua registry?" (curiosity)
- Turn 5: "can we guard against the user name is 'mise'..." (identified edge case)
- Turn 6: "yeah let's do 1 for both mise homebrew" (confirmed approach)
- Turn 7: "can you explain this change..." (review question)

## Verifier Gates

| Gate | Kind | Weight | Description |
|------|------|--------|-------------|
| test_update_command_deterministic | F2P | 0.25 | Test passes with >= 5 subtests |
| all_tests_pass | F2P | 0.20 | No regressions in package |
| no_direct_os_executable | F2P | 0.15 | AST: no direct os.Executable() call |
| specific_path_detection | F2P | 0.15 | AST: no generic path patterns |
| test_uses_table_driven | F2P | 0.15 | AST: table-driven subtests |
| exec_path_indirection | F2P | 0.10 | AST: function-type var exists |
| p2p_go_mod_exists | P2P | 0.0 | go.mod exists |
| p2p_source_files_exist | P2P | 0.0 | Source files present |
