# Source-of-truth notes for canonical patch extraction

What each upstream session source actually guarantees, and what we can / can't recover from it. Researched 2026-05-08.

## DataClaw (`peteromallet/dataclaw` + 30+ donor HF repos)

- **Spec**: github.com/peteromallet/dataclaw README "Data schema" section.
- **Schema requires** `messages[].tool_uses[].input` to be a dict with full `old_string` / `new_string` for `Edit` and `content` for `Write`.
- **However** older exports (pre-April 2026) shipped `tool_uses[].input` as a bare string like `"reigh/.../foo.tsx (6434 chars)"`. This was a deliberate summarization step in the old exporter — the original Edit content was never written to the record.
  - Detection: `isinstance(tool_uses[i]['input'], str)` → old/lossy export.
  - Affected donors include `peteromallet/dataclaw-peteromallet`, `misterkerns/my-personal-claude-code-data`, `woctordho/dataclaw`, all `*/my-personal-codex-data` (Codex-shaped, separate concern).
- **No upstream commit/PR linkage** (only `git_branch`). Sessions are not joinable to a canonical commit.
- **Redaction policy**: secret/email/PII substitution in `tool_uses[].input` text — never wholesale dropping.

→ Sessions with bare-string inputs are **un-replayable** for Edit-content verifiers. Skip cleanly with a clear reason. Do NOT attempt to reconstruct.

## pi-mono (`badlogicgames/pi-mono` + community uploads via `pi-share-hf`)

- **Three Edit schemas exist in the wild**:
  1. Classic single-edit: `{path, oldText, newText}` ✓ supported.
  2. Multi-edit array: `{path, edits: [{oldText, newText}, ...]}` ✓ supported.
  3. **Hashline** (oh-my-pi fork + `pi-hashline-edit` extension, also adopted by mainline pi-mono ≥13.15.0 around 2026-03-23): `{path, edits: [{loc, content}]}` with op variants `replace_line`, `replace_range`, `insert_after`, `append_eof`, `prepend_bof`. Anchors are content-hash IDs like `1#BB`, `67#MV-120#JP`. **Not supported** by our extractor — old text is never recorded; would need to resolve `loc` against the workspace at session time.
- `pi-share-hf` redaction is exact-value-only via TruffleHog, never empties `oldText`/`newText`.
- **No upstream commit/PR linkage** in pi sessions either. Issue numbers in our task names are reconstructed out-of-band by the scaffold pipeline.

→ Hashline-format sessions emit "stripped_content" warnings but the session is real, just uses an anchor format we don't parse. Either implement a hashline replay (resolve `loc` against earlier `read` ops in the same JSONL) or skip cleanly.

## Hyperswitch (`archit11/claude_traces_hs`)

- **Custom Juspay format**, not Claude API rollouts. Open-model rollouts (GLM, Kat, ...) served via SGLang/vLLM, embedded in a single `chatml` string with inline `<tool_use id="chatcmpl-tool-XXX">{...}</tool_use>` markup.
- **Hard 1000-character cap on assistant turns** in the rollout harness. Many `<tool_use>` JSON blocks are truncated mid-arguments. Tool results aged out are reset to `[Old tool result content cleared]`.

### Important correction (2026-05-08)

The parquet's `gitdiff` column is **NOT the resolving PR's diff** — it's the **session's own edits** captured during the rollout. Cross-validation showed 0 of 17 records byte-matched the actual upstream PR. Don't use the parquet for canonical patches.

Use **`gh pr diff <closing_PR>`** instead. The script now:
1. Parses task name `hyperswitch-<N>` → upstream issue.
2. `gh issue view <N> --json closedByPullRequestsReferences` → list of closing PRs.
3. For each candidate PR, `gh pr view <N> --json state` (DON'T trust the embedded `state` field — gh CLI returns null/missing for closedByPullRequestsReferences entries).
4. Filter to PRs where `state == "MERGED"`. Pick the **earliest** (smallest number) — that's almost always the original closing PR; later PRs are follow-up bugfixes that just mention the same issue.
5. `gh pr diff <PR>` for the diff.

Validated 2026-05-08: 16 of 17 hyperswitch records produce byte-equal upstream PR diffs that apply cleanly to base commit. The 17th (hyperswitch-118) has no closing PR — issue still OPEN since 2022-12-12.

**Schema cap**: hyperswitch gold patches use 2 MB cap (vs 256 KB for message-replay) since legitimate PRs can exceed 256 KB (e.g. PR #8007 is ~600 KB).

## Reigh + others with bare-string tool inputs

Same shape as old DataClaw — cannot recover. Skip cleanly.

## Cross-validation findings (5 sample tasks, 2026-05-08)

| task | upstream PR | our extracted patch | verdict |
|---|---|---|---|
| `cc-backend-task-ceb685` | direct push commit `39635ea1` | numstat byte-identical | ✅ exact |
| `amytis-task-103a94` | PR #24 (relevant slice) | feed-utils.ts char-identical, 1 dup-block artifact | ✅ exact |
| `cli-task-4ddad8` | PR #325 | 100% file subset, ~50% additions, almost no deletions captured | ⚠️ directional only |
| `pi-mono-auto-cad40af4` | PR #907 (rejected unmerged) | follows rejected PR's approach | ⚠️ wrong target |
| `hyperswitch-9063` | PR #9064 fixed JS `locale.js` | agent edited Rust `transformers.rs`, syntactically broken | ❌ session-quality failure |

## Implications for our extractor

1. **Warnings-clean reconstructions (≤2 warnings, 0 fuzzy used) are reliable.** Use as gold-patch verifiers.
2. **High-warning reconstructions are directional only** — captures the right file set but typically loses ~50% of deletions because failed Edit ops silently no-op. Don't use as textual gold patch.
3. **Some sessions are session-quality failures** where the agent did the wrong thing. Faithful replay is faithful to a wrong fix. We cannot detect this from the session alone — needs upstream PR comparison.
4. **Fuzzy matching is REJECTED** — risk of inventing patches that don't match the human-shipped fix outweighs the recovery benefit. We deliberately keep exact-match-only.
5. **For Hyperswitch, prefer the parquet's `gitdiff`** over message replay. Replay was strictly worse than the gold patch.
