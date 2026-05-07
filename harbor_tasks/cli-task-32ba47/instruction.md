Implement the following plan:

# Consolidate Transcript Parsing

## Context

5 duplicate JSONL parsers across 3 packages. Consolidate into the shared `transcript` package using the `bufio.Reader` approach (no size limit).

## Plan

### Step 1: Add `ParseFromFileAtLine` to `transcript/parse.go`

Move `cli.parseTranscriptFromLine` implementation here. One function, no convenience wrappers.

```go
func ParseFromFileAtLine(path string, startLine int) ([]Line, int, error)
```

### Step 2: Delete duplicates and update callers

**Delete from `cli/transcript.go`:**
- `parseTranscript(path)` → callers use `transcript.ParseFromFileAtLine(path, 0)`, ignore totalLines
- `parseTranscriptFromLine(path, startLine)` → callers use `transcript.ParseFromFileAtLine(path, startLine)`
- `parseTranscriptFromBytes(content)` → callers use `transcript.ParseFromBytes(content)` (already exists)

**Delete from `claudecode/transcript.go`:**
- `ParseTranscript(data)` → callers use `transcript.ParseFromBytes(data)`
- `parseTranscriptFromLine(path, startLine)` → callers use `transcript.ParseFromFileAtLine(path, startLine)`
- `scannerBufferSize` constant → removed

### Step 3: Move parsing tests to `transcript/parse_test.go`

Move `TestParseTranscript_*` and `TestParseTranscriptFromLine_*` from `cli/transcript_test.go`. Keep extract/utility tests in place.

### Step 4: Clean up imports

## Key files

- `cmd/entire/cli/transcript/parse.go` — add `ParseFromFileAtLine`
- `cmd/entire/cli/transcript.go` — delete 3 functions
- `cmd/entire/cli/agent/claudecode/transcript.go` — delete 2 functions + constant
- `cmd/entire/cli/hooks_claudecode_handlers.go` — update callers
- `cmd/entire/cli/debug.go` — update caller
- `cmd/entire/cli/rewind.go` — update caller
- `cmd/entire/cli/agent/claudecode/claude.go` — update callers
- `cmd/entire/cli/strategy/manual_commit_condensation.go` — update caller

## Verification

```bash
mise run fmt && mise run lint && mise run test:ci
```
