Implement the following plan:

# OpenCode Agent Refactoring Plan

## Problem Summary

The OpenCode implementation violates the agent integration checklist:
1. **Creates custom JSONL format** instead of using `opencode export` (native JSON)
2. **ExportData never populated** so rewind doesn't restore OpenCode's database
3. **Two file formats** written by plugin (`.jsonl` and `.export.json`)

## Design Decision

**Store `opencode export` JSON as NativeData.** This is OpenCode's native format. The Go hook handler will call `opencode export` to get the canonical transcript. No backward compatibility needed - integration is brand new.

## Implementation Phases

### Phase 1: Add `runOpenCodeExport` CLI wrapper

**File:** `cmd/entire/cli/agent/opencode/cli_commands.go`

```go
func runOpenCodeExport(sessionID string) ([]byte, error)
```

Execute `opencode export <session-id>` and capture stdout as JSON bytes.

### Phase 2: Update `ReadTranscript` to use canonical export

**File:** `cmd/entire/cli/agent/opencode/opencode.go`

Change `ReadTranscript(sessionRef)` to:
1. Extract session ID from sessionRef path (filename without extension)
2. Call `runOpenCodeExport(sessionID)` to get native JSON

### Phase 3: Rewrite transcript parsing for export JSON format

**File:** `cmd/entire/cli/agent/opencode/transcript.go`

Export JSON structure:
```json
{
  "info": { "id": "...", ... },
  "messages": [
    { "info": { "id": "...", "role": "user", ... }, "parts": [...] }
  ]
}
```

Replace all JSONL parsing with export JSON parsing:
- `ParseMessages()` → `ParseExportSession()`
- `ExtractModifiedFiles()` - rewrite for export JSON
- `ExtractAllUserPrompts()` - rewrite for export JSON
- `CalculateTokenUsageFromBytes()` - rewrite for export JSON

Delete JSONL-specific code.

### Phase 4: Update `ReadSession` to populate ExportData

**File:** `cmd/entire/cli/agent/opencode/opencode.go`

```go
func (a *OpenCodeAgent) ReadSession(input *agent.HookInput) (*agent.AgentSession, error) {
    data, err := a.ReadTranscript(input.SessionRef)
    if err != nil {
        return nil, err
    }
    modifiedFiles, _ := ExtractModifiedFiles(data)
    return &agent.AgentSession{
        AgentName:     a.Name(),
        SessionID:     input.SessionID,
        SessionRef:    input.SessionRef,
        NativeData:    data,  // Export JSON
        ExportData:    data,  // Same - used for opencode import
        ModifiedFiles: modifiedFiles,
    }, nil
}
```

### Phase 5: Simplify `WriteSession`

**File:** `cmd/entire/cli/agent/opencode/opencode.go`

```go
func (a *OpenCodeAgent) WriteSession(session *agent.AgentSession) error {
    if err := os.WriteFile(session.SessionRef, session.NativeData, 0o600); err != nil {
        return err
    }
    // NativeData is export JSON - import directly
    if err := a.importSessionIntoOpenCode(session.SessionID, session.NativeData); err != nil {
        fmt.Fprintf(os.Stderr, "warning: could not import session: %v\n", err)
    }
    return nil
}
```

### Phase 6: Update chunking for JSON format

**File:** `cmd/entire/cli/agent/opencode/opencode.go`

Rewrite `ChunkTranscript()` and `ReassembleTranscript()` for JSON (split/merge messages array). Reference Gemini CLI's implementation.

### Phase 7: Simplify plugin - remove all JSONL code

**File:** `cmd/entire/cli/agent/opencode/entire_plugin.ts`

Delete:
- `writeTranscriptFromMemory()`
- `writeTranscriptWithFallback()`
- `formatMessageFromStore()`
- `formatMessageFromAPI()`
- All `.jsonl` references

The plugin only needs to pass session_id to hooks. Go calls `opencode export` directly.

Update `session.idle`:
```typescript
case "session.idle": {
    const sessionID = (event as any).properties?.sessionID
    if (!sessionID) break
    await callHook("turn-end", { session_id: sessionID })
    break
}
```

### Phase 8: Remove special-case in lifecycle.go

**File:** `cmd/entire/cli/lifecycle.go`

Delete lines 209-218 (`.export.json` copying logic). The transcript IS the export data now.

### Phase 9: Update types.go

**File:** `cmd/entire/cli/agent/opencode/types.go`

- Add `ExportSession` struct for top-level export JSON
- Keep/adapt `Message` and `Part` types for the nested structure
- Delete JSONL-specific types if any

## Files to Modify

1. `cmd/entire/cli/agent/opencode/cli_commands.go` - Add `runOpenCodeExport`
2. `cmd/entire/cli/agent/opencode/opencode.go` - ReadTranscript, ReadSession, WriteSession, chunking
3. `cmd/entire/cli/agent/opencode/transcript.go` - Rewrite all parsing for export JSON
4. `cmd/entire/cli/agent/opencode/types.go` - Add ExportSession, clean up
5. `cmd/entire/cli/agent/opencode/entire_plugin.ts` - Delete JSONL code, simplify
6. `cmd/entire/cli/lifecycle.go` - Remove export.json special-case

## Verification

1. **Unit tests**: Rewrite tests in `transcript_test.go` for export JSON
2. **Integration tests**: Update `integration_test/opencode_hooks_test.go`
3. **Manual testing**:
   - Start OpenCode session, make changes, verify checkpoint captures export JSON
   - Rewind to checkpoint, verify `opencode -s <id>` resumes correctly
4. **Run**: `mise run fmt && mise run lint && mise run test:ci`


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: ~/.REDACTED.jsonl
