# Canonical patch extraction

Extracts the canonical (human-shipped) patch for every harbor task into
`data-pipeline/artifacts_<source>/canonical_patches/<sid>.json`, in the SWE-chat
15-field schema plus `_*` extras.

## One unified extractor (consolidated 2026-05-14)

| Script | Role |
|---|---|
| `data-pipeline/scripts/step4_extract_canonical_patches.py` | **Active** — single entry point for all non-SWE-chat sources |
| `data-pipeline/scripts/_legacy/step4_extract_canonical_patches_hyperswitch.py` | Deprecated; logic absorbed into the active script |
| `data-pipeline/scripts/_legacy/step4_extract_canonical_patches_swechat.py` | Deprecated; SWE-chat parquet flow is currently unused (no active SWE-chat-sourced harbor tasks) |

## Strategy waterfall (per task)

The unified script tries these in order; first match wins:

1. **Hyperswitch issue → PR → `gh pr diff`** — `hyperswitch-<N>` task names
   resolve N → earliest merged closing PR → its full diff. Gold-standard
   when available. (Was the standalone hyperswitch script.)
2. **`install_config.json` `commit_sha` → `gh api commits/<sha>.diff`** —
   when the task records an upstream commit SHA, the exact upstream diff
   is fetched. Adds `_install_config_commit_sha` for traceability.
   (New 2026-05-14, "Fix A".)
3. **Tool-replay** — clone repo at `_base_commit`, replay structured
   `tool_use` ops (Write / Edit / MultiEdit / NotebookEdit / apply_patch)
   against the working tree, then `git diff HEAD`. Fidelity bucketed
   `exact | directional | lossy` based on warning/op ratio.

## Run

```bash
python3 data-pipeline/scripts/step4_extract_canonical_patches.py            # all tasks
python3 data-pipeline/scripts/step4_extract_canonical_patches.py --tasks 'hyperswitch-*'
python3 data-pipeline/scripts/step4_extract_canonical_patches.py --tasks 'pi-mono-*' --limit 5
python3 data-pipeline/scripts/step4_extract_canonical_patches.py --force        # re-extract cached
```

Default behavior is non-destructive: existing canonicals are not overwritten
unless `--force` is passed. Promoted manual curations (with `_curation_method`
or `_fidelity_verified` set) survive normal re-runs.

## `_fidelity` field

| Value | Meaning |
|---|---|
| `exact` | Patch byte-matches an upstream commit/PR diff (via hyperswitch path or Fix A); or message-replay with ≤2 warnings AND ≤15% warning/op ratio |
| `directional` | Right file set, but some Edit ops missed anchor match (formatter ran between edits, etc.). Use as "did the agent touch the right files" oracle, not as byte-exact ground truth |
| `lossy` | Many ops failed; patch may misrepresent the real fix. Triggers smell-test failure unless `_fidelity_verified = true` is set |
| `verifier_aligned` | Hand-reconstructed to match `tests/test.sh` ground truth (used when the session diverged from what the task author normalized for the verifier) |
| `clean`, `high`, `curated` | Curator-set after manual verification; treat same as `exact` |

A separate `_fidelity_verified: true` flag means the original `_fidelity`
label was over-conservative and a human audit confirmed the patch is safe to
use. See `_verification_note` for the audit rationale.

## What this is NOT

- **Not an oracle for "the agent did the right thing"** — even an `exact`
  upstream-PR canonical only tells you what the human shipped, not whether
  the agent's session arrived there. Cross-reference with `tests/test.sh`.
- **Not a complete bench corpus** — ~43 tasks skip cleanly because their
  source dataset stripped Edit content (older Reigh/DataClaw exports, certain
  pi-mono Hashline shapes). Skip reasons are recorded in the run log; the
  smell test does not flag these because there's no canonical to evaluate.
- **NEVER use `archit11/claude_traces_hs.gitdiff`** for hyperswitch.
  That parquet column is the agent session trace, not the gold patch. The
  unified extractor uses `gh pr diff <closing_PR>` exclusively.
