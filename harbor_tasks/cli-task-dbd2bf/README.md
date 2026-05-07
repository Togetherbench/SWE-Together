# Task: cli-task-dbd2bf

| Field | Value |
|-------|-------|
| Source session | `dbd2bfe1-bc12-4d4c-be2e-e2ec6b92170f` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `febf309b5a54770f084a3028c31df17f54205a0f` |
| Canonical patch | `7ca7ef1690260939ee00d2d4a992d2f19b2b1501` |
| Difficulty | medium |
| Category | refactor |
| Real user msgs | 4 |

## Summary

Refactor the Entire CLI to defer external agent discovery from eager (every CLI invocation) to lazy (only when hooks are actually invoked). The `DiscoverAndRegister` call in `newHooksCmd()` runs PATH scanning + process spawning on every command (`entire version`, `entire status`, etc.), adding unnecessary overhead.

## Changes Required

1. **hooks_cmd.go**: Remove eager `DiscoverAndRegister`, add `RunE` fallback with `Args: cobra.ArbitraryArgs` to lazily discover external agents when hooks are invoked for unknown subcommands.
2. **hook_registry.go**: Extract `executeAgentHook` function from `newAgentHookVerbCmdWithLogging`'s RunE into a reusable function, and update the RunE to delegate to it.
3. **setup.go**: Add `DiscoverAndRegister` during the enable flow so external agents are discoverable during `entire enable`.
4. **external.go**: Fix `limitedWriter.Write` to properly propagate errors from `buf.Write`.

## User Simulator Behavior

- Total real user messages: 4 in 74 agent turns. Silence is the default.
- Longest silence: 49 agent turns (during main implementation)
- Turn 1: Detailed implementation plan (the instruction)
- Turn 2: "which other outstanding issues we have?" — status check after ~11 min
- Turn 3: "fix liniting and run the tests" — correction after lint/test failures
- Turn 4: "don't remove the nolint:ireturn comments" — preserve linter suppressions

## Verification

- 8 F2P gates (5 behavioral Gold/Silver, 3 structural Bronze)
- 1 P2P_REGRESSION gate (nolint:ireturn preservation)
- Go build + unit tests must pass
