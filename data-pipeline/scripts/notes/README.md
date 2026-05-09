# Canonical patch extraction

Extracts the canonical (human-shipped) patch for every harbor task into
`data-pipeline/artifacts_<source>/canonical_patches/<sid>.json`, in the same
schema as the SWE-chat extractor's output.

## Three scripts, one schema

| Script | What it does | When to use |
|---|---|---|
| `step4_extract_canonical_patches.py` (existing) | Joins `SALT-NLP/SWE-chat` `sessions.parquet` → `commits.parquet` via `canonical_checkpoint_pk`; pulls the user's eventual commit patch | SWE-chat sessions only |
| `step4_extract_canonical_patches_messages.py` | Replays Edit / Write / MultiEdit / `apply_patch` / `sed -i` ops against a clone of the repo at the task's base commit | Any session with structured tool calls (DataClaw, pi-mono, amytis, cli, cc-backend, …) |
| `step4_extract_canonical_patches_hyperswitch.py` | Pulls the gold patch directly from `archit11/claude_traces_hs` parquet's `gitdiff` column | Hyperswitch tasks specifically. Run AFTER message-replay so it overrides |

Output schema is identical across all three (15 SWE-chat fields + a few
underscore-prefixed extras). Downstream consumers don't need to know which
script produced a record.

## Run order

```bash
python3 data-pipeline/scripts/step4_extract_canonical_patches.py            # SWE-chat
python3 data-pipeline/scripts/step4_extract_canonical_patches_messages.py   # everything else (default + sub-glob)
python3 data-pipeline/scripts/step4_extract_canonical_patches_hyperswitch.py  # overrides hyperswitch with gold patches
```

The third script overwrites the second's hyperswitch output because gold
patches from the parquet are strictly better than message replay (the
hyperswitch dataset hard-caps assistant turns at 1000 chars, so replay
loses ~50% of edits to mid-string truncation).

## `_fidelity` field

Every record carries `_fidelity` ∈ {`exact`, `directional`, `lossy`} so
consumers can decide what to trust:

- **`exact`**: the patch reproduces the upstream human-shipped fix
  byte-for-byte (verified by cross-validation against PRs, see
  `source_research.md`). Safe to use as a gold-patch verifier oracle.
  - All `parquet_gold_patch` records (hyperswitch).
  - Message-replay records with ≤2 warnings AND ≤15% warning/op ratio.
- **`directional`**: right file set, but typically ~50% of deletions are
  missing because some Edit ops failed anchor match. Use as "did the agent
  touch the right files" gate, NOT as exact textual match.
  - Message-replay records with 16-50% warning/op ratio.
- **`lossy`**: most ops failed; patch may misrepresent the real fix or be
  near-empty. Manual review needed.
  - Message-replay records with >50% warning/op ratio.
  - Records with `_n_mutating_ops == 0`.

## Why no fuzzy matching

Earlier prototypes added whitespace-tolerant Edit-anchor matching to recover
from formatter-between-edits warnings (`gofmt`/`prettier` ran between two
agent Edits, leaving the second's `old_string` non-byte-equal to the file).
Cross-validation against upstream PRs showed fuzzy matching can synthesize
patches that don't reflect what the human actually shipped. We deliberately
keep exact-match-only: real warnings are surfaced, not swept under fuzzy
recovery.

## Source-by-source fidelity expectations

See `source_research.md` for full notes. Summary:

| Source | Ground-truth source | Best achievable fidelity | Notes |
|---|---|---|---|
| SWE-chat | Native `commits.parquet.patch` | exact | First-party; original SWE-chat extractor handles this |
| Hyperswitch | `archit11/claude_traces_hs.gitdiff` parquet column | exact | Use the dedicated parquet-pull script |
| DataClaw (newer exports, dict inputs) | Message replay against base commit | exact when warnings ≤2 | No upstream PR linkage; replay is the only ground truth |
| DataClaw (older exports, string inputs — reigh, banodoco, etc.) | Cannot recover | n/a (skipped) | Old DataClaw exporter dropped Edit content; not recoverable from messages |
| pi-mono (classic + multi-edit shapes) | Message replay | exact when warnings ≤2 | Most pi-mono sessions |
| pi-mono (Hashline / oh-my-pi anchor shape) | Cannot recover from messages alone | n/a (skipped) | Anchors are content hashes; old text never recorded |
| amytis, cli, cc-backend, agent-swarm, etc. | Message replay | exact when warnings ≤2 | Standard Anthropic Edit/Write field names |

## What this is NOT

- **Not an oracle for "the agent did the right thing"**: faithful replay is
  faithful even when the agent did the wrong fix (see hyperswitch-9063's
  message-replay version vs the parquet gold patch). For verifier oracles
  you want `_fidelity == "exact"` AND ideally the parquet ground truth
  when available.
- **Not a complete bench corpus**: ~50 of 179 tasks skip cleanly because
  their source dataset stripped Edit content (older DataClaw, hashline
  pi-mono). Skip reasons are recorded in the run log.
