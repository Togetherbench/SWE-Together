Implement the following plan:

# Plan: External Agent Plugin Protocol + Cursor Extraction

## Context

The CLI currently has all agent implementations compiled in (Claude Code, Cursor, Gemini CLI, OpenCode, Factory AI Droid). To make the CLI extensible — allowing third-party agents without modifying the main repo — we need a protocol for external agent binaries that the CLI discovers via PATH and communicates with over stdin/stdout.

**Starting point:** Extract the Cursor agent into a separate repo (`entire-agent-cursor`) as the first external agent. The built-in Cursor code will be removed from this repo.

## Step 1: Define the Protocol Specification

Create `docs/architecture/external-agent-protocol.md` documenting the full protocol.

**Protocol summary:**
- **Discovery:** CLI scans PATH for `entire-agent-<name>` binaries
- **Communication:** Subcommand-based, JSON over stdin/stdout, raw bytes for transcripts
- **Stateless:** Each invocation is independent
- **Environment:** `ENTIRE_REPO_ROOT` and `ENTIRE_PROTOCOL_VERSION=1` are always set; working directory is repo root

**Subcommands** (each maps to an Agent interface method):

| Subcommand | Required | Maps to | I/O |
|---|---|---|---|
| `info` | Always | Name/Type/Description/IsPreview/ProtectedDirs/HookNames + capabilities | stdout: JSON |
| `detect` | Always | DetectPresence | stdout: `{"present": bool}` |
| `parse-hook --hook <name>` | If hooks capable | ParseHookEvent | stdin: raw agent payload → stdout: JSON Event or `null` |
| `read-transcript --session-ref <path>` | Always | ReadTranscript | stdout: raw bytes |
| `chunk-transcript --max-size <n>` | Always | ChunkTranscript | stdin: raw → stdout: JSON `{"chunks": ["base64..."]}` |
| `reassemble-transcript` | Always | ReassembleTranscript | stdin: JSON chunks → stdout: raw |
| `get-session-id` | Always | GetSessionID | stdin: JSON HookInput → stdout: `{"session_id": "..."}` |
| `get-session-dir --repo-path <p>` | Always | GetSessionDir | stdout: `{"session_dir": "..."}` |
| `resolve-session-file --session-dir <d> --session-id <id>` | Always | ResolveSessionFile | stdout: `{"session_file": "..."}` |
| `read-session` | Always | ReadSession | stdin: JSON HookInput → stdout: JSON AgentSession |
| `write-session` | Always | WriteSession | stdin: JSON AgentSession → exit 0 |
| `format-resume-command --session-id <id>` | Always | FormatResumeCommand | stdout: `{"command": "..."}` |
| `install-hooks [--local-dev] [--force]` | If hooks | InstallHooks | stdout: `{"hooks_installed": N}` |
| `uninstall-hooks` | If hooks | UninstallHooks | exit 0 |
| `are-hooks-installed` | If hooks | AreHooksInstalled | stdout: `{"installed": bool}` |
| `get-transcript-position --path <p>` | If transcript_analyzer | GetTranscriptPosition | stdout: `{"position": N}` |
| `extract-modified-files --path <p> --offset <n>` | If transcript_analyzer | ExtractModifiedFilesFromOffset | stdout: JSON |
| `extract-prompts --session-ref <p> --offset <n>` | If transcript_analyzer | ExtractPrompts | stdout: JSON |
| `extract-summary --session-ref <p>` | If transcript_analyzer | ExtractSummary | stdout: JSON |
| `prepare-transcript --session-ref <p>` | If transcript_preparer | PrepareTranscript | exit 0 |
| `calculate-tokens --offset <n>` | If token_calculator | CalculateTokenUsage | stdin: raw → stdout: JSON |
| `generate-text --model <m>` | If text_generator | GenerateText | stdin: prompt → stdout: JSON |
| `write-hook-response --message <m>` | If hook_response_writer | WriteHookResponse | stdout: agent-native format |
| `extract-all-modified-files --offset <n> --subagents-dir <d>` | If subagent_aware | ExtractAllModifiedFiles | stdin: raw → stdout: JSON |
| `calculate-total-tokens --offset <n> --subagents-dir <d>` | If subagent_aware | CalculateTotalTokenUsage | stdin: raw → stdout: JSON |

**`info` response** declares capabilities:
```json
{
  "protocol_version": 1,
  "name": "cursor",
  "type": "Cursor",
  "description": "Cursor - AI-powered code editor",
  "is_preview": true,
  "protected_dirs": [".cursor"],
  "hook_names": ["session-start", "session-end", "stop", ...],
  "capabilities": {
    "hooks": true,
    "transcript_analyzer": true,
    "transcript_preparer": false,
    "token_calculator": false,
    "text_generator": false,
    "hook_response_writer": false,
    "subagent_aware_extractor": false
  }
}
```

**Error handling:** exit 0 = success, non-zero = error with message on stderr.

## Step 2: Create ExternalAgent Adapter

Create `cmd/entire/cli/agent/external/` package with:

### `external.go` — Core adapter

```go
type ExternalAgent struct {
    binaryPath string
    info       *InfoResponse  // cached from `info`
}
```

- Implements `agent.Agent` (all 14 methods) by shelling out to the binary
- Each method: build args → exec binary → parse JSON response
- Helper: `exec(ctx, subcommand, args, stdin) (stdout, error)`

### `capabilities.go` — Optional interface wrappers

Since Go interfaces are checked at compile time via type assertions, the adapter needs wrapper types for each optional interface:

```go
// ExternalAgentWithHooks wraps ExternalAgent and implements agent.HookSupport
type ExternalAgentWithHooks struct{ *ExternalAgent }

// ExternalAgentWithAnalyzer wraps ExternalAgent and implements agent.TranscriptAnalyzer
type ExternalAgentWithAnalyzer struct{ *ExternalAgent }

// ... etc for each optional interface
```

A `NewExternalAgent(binaryPath)` constructor calls `info`, caches the response, and returns the appropriate wrapper combining all declared capabilities. Uses Go embedding + interface composition.

### `types.go` — Protocol JSON types

JSON request/response structs for all subcommands (InfoResponse, EventResponse, SessionResponse, etc.).

### `external_test.go` — Unit tests

Test the adapter with a mock binary (shell script or test helper that implements the protocol).

**Key files:**
- `cmd/entire/cli/agent/external/external.go`
- `cmd/entire/cli/agent/external/capabilities.go`
- `cmd/entire/cli/agent/external/types.go`
- `cmd/entire/cli/agent/external/external_test.go`

## Step 3: Add PATH Discovery to Registry

Modify `cmd/entire/cli/agent/registry.go`:

- Add `DiscoverExternal()` function that:
  1. Scans `$PATH` for executables matching `entire-agent-*`
  2. For each found binary, calls `entire-agent-<name> info`
  3. Creates an `ExternalAgent` adapter
  4. Registers it via `Register(name, factory)`
- Skip binaries whose name conflicts with already-registered (built-in) agents

Modify `cmd/entire/cli/hooks_cmd.go`:

- Call `DiscoverExternal()` before building the hooks command tree (alongside the blank imports)
- Remove the `_ "github.com/entireio/cli/cmd/entire/cli/agent/cursor"` blank import

## Step 4: Remove Built-in Cursor Agent

Delete `cmd/entire/cli/agent/cursor/` directory entirely (9 files).

**Keep in this repo** (not Cursor-specific):
- `AgentNameCursor` / `AgentTypeCursor` constants in `registry.go` — used in switch statements in `explain.go`, `summarize.go`, `manual_commit_condensation.go`
- `transcript` package — shared JSONL parsing (handles role→type normalization)
- `textutil` package — IDE tag stripping (handles `<user_query>` tags)

**Update references:**
- `hooks_cmd.go`: Remove cursor blank import
- `strategy/manual_commit_condensation_test.go`: Remove cursor blank import, adjust test to use external agent or mock
- `agent/architecture_test.go`: Update if it validates cursor package imports

## Step 5: Tests

### Unit tests for ExternalAgent adapter
- Mock binary (test helper script) implementing the protocol
- Test each method delegation
- Test capability-based interface composition
- Test error handling (binary not found, non-zero exit, malformed JSON)

### Integration tests
- Test PATH discovery finds and registers external agents
- Test hook dispatch works end-to-end with external agent
- Test that removing built-in Cursor doesn't break any existing tests (the constants remain)

### Test commands
```bash
mise run fmt && mise run lint && mise run test:ci
```

## Files to Create
- `docs/architecture/external-agent-protocol.md` — Protocol specification
- `cmd/entire/cli/agent/external/external.go` — Core adapter
- `cmd/entire/cli/agent/external/capabilities.go` — Optional interface wrappers
- `cmd/entire/cli/agent/external/types.go` — Protocol JSON types
- `cmd/entire/cli/agent/external/external_test.go` — Tests

## Files to Modify
- `cmd/entire/cli/agent/registry.go` — Add `DiscoverExternal()`
- `cmd/entire/cli/hooks_cmd.go` — Call discovery, remove cursor import
- `cmd/entire/cli/strategy/manual_commit_condensation_test.go` — Remove cursor import
- `cmd/entire/cli/agent/architecture_test.go` — Update import validation

## Files to Delete
- `cmd/entire/cli/agent/cursor/cursor.go`
- `cmd/entire/cli/agent/cursor/cursor_test.go`
- `cmd/entire/cli/agent/cursor/hooks.go`
- `cmd/entire/cli/agent/cursor/hooks_test.go`
- `cmd/entire/cli/agent/cursor/lifecycle.go`
- `cmd/entire/cli/agent/cursor/lifecycle_test.go`
- `cmd/entire/cli/agent/cursor/transcript.go`
- `cmd/entire/cli/agent/cursor/transcript_test.go`
- `cmd/entire/cli/agent/cursor/types.go`
- `cmd/entire/cli/agent/cursor/AGENT.md`

## Verification

1. `mise run fmt && mise run lint && mise run test:ci` — All pass
2. Create a test `entire-agent-test` shell script implementing `info` and `detect`, verify discovery works
3. Verify `entire hooks` command tree still builds correctly
4. Verify agent type switch statements (`explain.go`, `summarize.go`) still work via the constants

## Out of Scope (Follow-up)
- **`entire-agent-cursor` binary** — Built in a separate repo, implements the protocol using the extracted Cursor logic
- **Migrating other agents** (Gemini, OpenCode, Factory AI Droid) to external binaries
- **Batch subcommand** — Optimizing warm-path (turn-end) by combining multiple operations into one exec
- **Long-running daemon mode** — Future protocol extension for latency-sensitive scenarios


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: <HOST_PATH>
