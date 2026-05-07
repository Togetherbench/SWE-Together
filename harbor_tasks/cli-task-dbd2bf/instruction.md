Implement the following plan:

# Fix: Defer external agent discovery from CLI startup to hooks execution

## Context

`DiscoverAndRegister` in `hooks_cmd.go:31-33` runs during `newHooksCmd()`, which is called during `NewRootCmd()` command tree construction (`root.go:82`). This means external agent discovery (PATH scanning + process spawning for `info` calls) happens on **every CLI invocation**, including `entire version`, `entire status`, etc. This adds unnecessary overhead.

## Approach: Cobra RunE fallback for external agents

**Key insight:** When Cobra can't match a subcommand, it falls back to the parent command's `RunE` with the unmatched args. We use this to lazily discover external agents only when they're actually invoked via hooks.

### Changes

#### 1. `cmd/entire/cli/hooks_cmd.go` — Remove eager discovery, add RunE fallback

- Remove `DiscoverAndRegister` call from `newHooksCmd()`
- Keep built-in agent subcommand registration (no process spawning, agents already imported via `_` imports)
- Add `RunE` to the hooks command that handles unrecognized subcommands (external agents):

```go
func newHooksCmd() *cobra.Command {
    cmd := &cobra.Command{
        Use:    "hooks",
        Short:  "Hook handlers",
        Long:   "Commands called by hooks. These are internal and not for direct user use.",
        Hidden: true,
        // RunE handles external agent hooks that aren't registered as subcommands.
        // When Cobra can't match a subcommand (e.g., "entire hooks my-ext-agent stop"),
        // it falls back to this RunE with args ["my-ext-agent", "stop"].
        Args: cobra.ArbitraryArgs,
        RunE: func(cmd *cobra.Command, args []string) error {
            if len(args) < 2 {
                return cmd.Help()
            }
            agentName := types.AgentName(args[0])
            hookName := args[1]

            // Lazily discover external agents
            discoveryCtx, cancel := context.WithTimeout(cmd.Context(), 5*time.Second)
            defer cancel()
            external.DiscoverAndRegister(discoveryCtx)

            // Execute the hook for the discovered agent
            return executeAgentHook(cmd, agentName, hookName)
        },
    }

    cmd.AddCommand(newHooksGitCmd())

    // Only built-in agents are registered eagerly (no process spawning)
    for _, agentName := range agent.List() {
        ag, err := agent.Get(agentName)
        if err != nil {
            continue
        }
        if handler, ok := agent.AsHookSupport(ag); ok {
            cmd.AddCommand(newAgentHooksCmd(agentName, handler))
        }
    }

    return cmd
}
```

#### 2. `cmd/entire/cli/hook_registry.go` — Extract hook execution logic

Extract the core hook execution logic from `newAgentHookVerbCmdWithLogging`'s `RunE` into a reusable function:

```go
func executeAgentHook(cmd *cobra.Command, agentName types.AgentName, hookName string) error {
    // Same logic as newAgentHookVerbCmdWithLogging's RunE:
    // - Check git repo
    // - Check enabled
    // - Init logging
    // - Parse hook event from stdin
    // - Dispatch lifecycle event
}
```

Update `newAgentHookVerbCmdWithLogging` to call this extracted function to avoid duplication.

#### 3. `cmd/entire/cli/setup.go` — Add discovery during `entire enable` (if needed)

The review notes that external agents aren't discoverable during `entire enable`. If agent selection during setup should include external agents, add `DiscoverAndRegister` to the enable flow. Check if this is already handled or needs to be added.

### Files to modify
- `cmd/entire/cli/hooks_cmd.go` — Remove eager discovery, add RunE fallback
- `cmd/entire/cli/hook_registry.go` — Extract `executeAgentHook` function, reuse in both paths

### Files to check
- `cmd/entire/cli/setup.go` — Whether external agents should be discoverable during `entire enable`
- `cmd/entire/cli/hook_registry_test.go` — Tests that call `newHooksCmd()` may need updates

## Verification

1. `mise run fmt && mise run lint` — no lint errors
2. `mise run test:ci` — all unit + integration tests pass
3. Manual verification: `entire version` no longer triggers external agent discovery (check with `ENTIRE_LOG_LEVEL=debug`)
4. Manual verification: `entire hooks <external-agent> <hook>` still works via the RunE fallback
