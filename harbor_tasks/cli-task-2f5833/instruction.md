Implement the following plan:

# Plan: Fix prompt.txt — use shadow branch/filesystem as source of truth, never transcript

## Context

The filesystem `prompt.txt` is being overwritten at TurnEnd by `handleLifecycleTurnEnd` (lifecycle.go:277-283) which re-extracts prompts from the transcript and overwrites the accumulated file. This clobbers the prompts that were correctly appended at TurnStart.

**Principle:** `prompt.txt` on the shadow branch is the source of truth for checkpoint prompts. Prompts should be **appended** at TurnStart, never overwritten. Checkpoints should read prompts from the shadow branch `prompt.txt` (or filesystem fallback), **never from the transcript**.

## Changes

### 1. Stop TurnEnd from overwriting prompt.txt or extracting prompts from transcript

**`cmd/entire/cli/lifecycle.go`** — `handleLifecycleTurnEnd()`:

- Remove `analyzer.ExtractPrompts()` call entirely (lines 249-256)
- Remove `allPrompts` variable
- Remove the `os.WriteFile` for `promptFile` (lines 279-286)
- For the commit message, use `state.LastPrompt` (loaded from session state) instead of extracting from transcript
- **Restore** the summary extraction and write that was accidentally removed in the current diff (`analyzer.ExtractSummary`, summary file write)

Before:
```go
var allPrompts []string
// ... ExtractPrompts from transcript ...
// ... WriteFile prompt.txt ...
lastPrompt := ""
if len(allPrompts) > 0 {
    lastPrompt = allPrompts[len(allPrompts)-1]
}
commitMessage := generateCommitMessage(lastPrompt)
```

After:
```go
// ... no prompt extraction or prompt.txt write ...
// Read last prompt from session state (set at TurnStart/InitializeSession)
lastPrompt := ""
if sessionState, stateErr := strategy.LoadSessionState(ctx, sessionID); stateErr == nil && sessionState != nil {
    lastPrompt = sessionState.LastPrompt
}
commitMessage := generateCommitMessage(lastPrompt)
```

### 2. Add filesystem fallback to `finalizeAllTurnCheckpoints`

**`cmd/entire/cli/strategy/manual_commit_hooks.go`** (~line 2062):

```go
prompts := readPromptsFromShadowBranch(ctx, repo, state)
if len(prompts) == 0 {
    prompts = readPromptsFromFilesystem(ctx, state.SessionID)
}
```

### 3. No other changes needed

- `extractSessionData` — already reads from shadow branch → filesystem ✓
- `extractSessionDataFromLiveTranscript` — already reads from filesystem ✓
- TurnStart append logic — already correct ✓
- `clearFilesystemPrompt` after condensation — already in `condenseAndUpdateState` ✓
- `readPromptsFromShadowBranch` — already implemented ✓

## Files Modified

- `cmd/entire/cli/lifecycle.go` — remove prompt extraction/write at TurnEnd, use `state.LastPrompt` for commit message, restore summary extraction
- `cmd/entire/cli/strategy/manual_commit_hooks.go` — add filesystem fallback to `finalizeAllTurnCheckpoints`

## Verification

`mise run fmt && mise run test:ci`


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: <HOST_PATH>
