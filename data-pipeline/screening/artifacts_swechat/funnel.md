# SWE-chat Screening Funnel

Snapshot of the SWE-chat → benchmark-candidate pipeline as of 2026-05-06.

## Headline numbers

```
SWE-chat raw                                5,851
   │  step1: deterministic filters
   ▼
step1_all_sessions.json                       626   (10.7% of raw)
   │  step2: Gemini 3.1 Pro reproducibility judge
   ▼
step2_screening.json (full)                   626   (627 - 1 transcript-parse error tolerated)
   ├─ VIABLE                                  277
   └─ NOT_VIABLE                              349
   │
   │  filter: verdict==VIABLE AND reproducible_in_harbor==true
   ▼
step2_candidates.json                         274   (43.8% of step1, 4.7% of raw)
```

## Step 1 — `step1_collect.py --source swechat`

Deterministic Stage-0 filters (no LLM). All thresholds in
[`step1_run_config.json`](step1_run_config.json):

| Filter | Threshold | Field |
|---|---|---|
| Genuine user messages | `>= 3` | `prompt_count` |
| Has code-modifying actions | `> 0` | `action_count` |
| Repo popularity | `>= 20` | `repositories.repo_github_metadata.stargazers_count` |
| Not a fork | `is_fork == False` | `repositories.is_fork` |
| Session graded successful | `>= 50` | `session_success` |
| Agent did the writing | `>= 30 %` | `agent_percentage` |

Outputs:
- [`step1_all_sessions.json`](step1_all_sessions.json) — 626 records, full Stage-0 payload (also serves as step2's input snapshot).
- [`step1_run_config.json`](step1_run_config.json) — config of this run.

(`step1_candidates.json` was emitted by an earlier run as a duplicate of
`step1_all_sessions.json` and has been removed; the SWE-chat path applies
all filters inline, so a separate "candidates" set is redundant.)

## Step 2 — `step2_screen_with_llm.py --source swechat`

Gemini 3.1 Pro per-session viability judge. Replaced the older Flash → Pro
two-stage flow because SWE-chat already exposes `repo_id` + star count +
`action_count` natively, so the Flash repo+stars step added no signal and
disagreed with Pro on 46% of cases.

Per-session Pro answers (stored in [`step2_screening.json`](step2_screening.json) for all 626):
- `primary_deliverable` ∈ {code_changes, pr_creation, issue_triage, analysis_only, deployment_ops, other}
- `reproducible_in_harbor` ∈ {true, false}
- `verdict` ∈ {VIABLE, NOT_VIABLE}
- `reason` (1 sentence)

### Verdict distribution (all 626 evaluated)

| Verdict | # | % |
|---|---:|---:|
| VIABLE | 277 | 44.2 |
| NOT_VIABLE | 349 | 55.8 |

### Primary deliverable distribution (all 626)

| Deliverable | # | % |
|---|---:|---:|
| `code_changes` | 533 | 85.1 |
| `other` | 48 | 7.7 |
| `pr_creation` | 22 | 3.5 |
| `analysis_only` | 12 | 1.9 |
| `deployment_ops` | 9 | 1.4 |
| `issue_triage` | 2 | 0.3 |

### Reproducible-in-Harbor distribution (all 626)

| Reproducible | # |
|---|---:|
| `true` | 275 |
| `false` | 339 |
| missing | 12 |

### NOT_VIABLE breakdown by deliverable

| Deliverable | # | Why dropped |
|---|---:|---|
| `code_changes` | 256 | Codes but external state (push/PR/deploy) is the actual deliverable, or workspace is not reproducible from a clean clone |
| `other` | 48 | — |
| `pr_creation` | 22 | Primary value is opening a PR, not the diff |
| `analysis_only` | 12 | Discussion / planning, no substantive edits |
| `deployment_ops` | 9 | Live infra changes |
| `issue_triage` | 2 | Filing / commenting on issues |

The big one: **256/349 NOT_VIABLE sessions DID make code changes** — Pro
classified them as not reproducible in a clean Harbor task because the
session's true deliverable was tied to external state (push to remote, PR
description, side effects), not the repo diff alone.

## Final candidate set — `step2_candidates.json`

Filter: `verdict==VIABLE AND reproducible_in_harbor==true`. **274 records.**

(277 VIABLE − 3 where Pro returned VIABLE but flagged reproducible=false or missing.)

### Top repos (top 15)

| # | Repo |
|---:|---|
| 115 | entireio/cli |
| 39 | Nagi-ovo/gemini-voyager |
| 37 | moltis-org/moltis |
| 33 | obsessiondb/rudel |
| 9 | marin-community/marin |
| 7 | hutusi/amytis |
| 6 | Lightprotocol/light-protocol |
| 6 | desplega-ai/agent-swarm |
| 5 | ClusterCockpit/cc-backend |
| 5 | kgcrom/cluefin |
| 4 | adrientaudiere/MiscMetabar |
| 2 | 4gray/iptvnator |
| 2 | Mathews-Tom/no-magic |
| 2 | raman325/lock_code_manager |
| 1 | f/prompts.chat |

Top 5 = 86%, top 1 = 42%. Without a per-repo cap, downstream Harbor task
selection will over-index on `entireio/cli` (the dataset author's own
dogfood CLI).

### Stars distribution (274 candidates)

| Stars | # |
|---:|---:|
| < 50 | 10 |
| 50–99 | 11 |
| 100–499 | 50 |
| 500–999 | 9 |
| 1k–9999 | 193 |
| 10k+ | 1 |

70% of candidates land in the 1k–9999 star range — a healthy popularity
band for benchmark inclusion.

### User persona (274 candidates)

| # | Persona |
|---:|---|
| 167 | Expert Nitpicker |
| 87 | Vague Requester |
| 20 | Mind Changer |

Both top personas are well-suited to a multi-turn user-correction benchmark.

## Step 1 enrichment fields (full 626)

User persona breakdown:

| # | Persona |
|---:|---|
| 337 | Expert Nitpicker |
| 234 | Vague Requester |
| 35 | Mind Changer |
| 20 | Other |

Agent breakdown:

| # | Agent |
|---:|---|
| 603 | Claude Code |
| 19 | OpenCode |
| 4 | Agent (unspecified) |

## Step 1 funnel (drilled by filter)

| Filter | Surviving |
|---|---:|
| start (sessions.parquet) | 5,851 |
| `prompt_count >= 3` | 3,704 |
| `action_count > 0` | 3,541 |
| `stars >= 20` | 1,160 |
| not a fork | 1,160 |
| `session_success >= 50` | 1,088 |
| `agent_percentage >= 30` | **626** |

## Open questions / follow-ups

1. **Per-repo concentration.** Top 1 repo (`entireio/cli`) dominates 42% of
   the VIABLE pool. Consider a `--per-repo-cap` step at either step1 or
   step2 to diversify before scaffolding into Harbor tasks. With
   `--per-repo-cap 5` the candidate count drops from 274 → ~80 but
   diversity climbs sharply.

2. **The 256 "code_changes but NOT_VIABLE" sessions** are the most
   interesting NOT_VIABLE bucket — agent did real edits but Pro judged
   they aren't reproducible in a clean Harbor sandbox. Worth a manual
   spot-check to confirm Pro's reasoning is well-calibrated; some of
   these may be rescuable by sharpening the Harbor reproducibility
   prompt.

3. **Transcript parse errors.** A handful of `'str' object has no attribute 'get'`
   warnings showed up during step2 fetch. Fixing the JSONL parser to handle
   the alternative SWE-chat schema would lift 5–10 missing evaluations.

4. **step1 schema, optional rework.** SWE-chat path writes only the 626
   post-filter records. To match DataClaw's two-file schema (5,851 raw
   with `pass_*` flags, plus filtered candidates), step1 would need to
   emit the pre-filter set as well — useful for "why was this dropped?"
   debugging but ~10× larger.
