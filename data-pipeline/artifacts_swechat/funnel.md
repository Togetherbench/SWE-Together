# SWE-chat Screening Funnel

Snapshot of the SWE-chat → benchmark-candidate pipeline as of 2026-05-06.

## Headline numbers

```
SWE-chat raw                                5,851
   │  step1: deterministic filters
   ▼
step1_all_sessions.json                       760   (13.0% of raw)
   │  step2: Gemini 3.1 Pro reproducibility judge
   ▼
step2_screening.json (full)                   760   (760/760, no parse losses)
   ├─ VIABLE                                  333
   └─ NOT_VIABLE                              427
   │
   │  filter: verdict==VIABLE AND reproducible_in_harbor==true
   ▼
step2_candidates.json                         329   (43.3% of step1, 5.6% of raw)
```

> **2026-05-06 filter relaxation.** Three changes to step1: dropped
> `is_fork` (was filtering 0 rows), dropped `session_success` (redundant
> Gemini-derived signal that step2 Pro already independently judges), and
> lowered `stars` from 20 to 10 (SWE-chat repos are pre-filtered to public
> GitHub projects, so a lower star bar is fine). step1 626 → 760
> (+134 / +21%); after step2 Pro the candidate pool 274 → 329 (+55 / +20%).

## Step 1 — `step1_collect.py --source swechat`

Deterministic Stage-0 filters (no LLM). All thresholds in
[`step1_run_config.json`](step1_run_config.json):

| Filter | Threshold | Field |
|---|---|---|
| Genuine user messages | `>= 3` | `prompt_count` |
| Has code-modifying actions | `> 0` | `action_count` |
| Repo popularity | `>= 10` | `repositories.repo_github_metadata.stargazers_count` |
| Agent did the writing | `>= 30 %` | `agent_percentage` |

### Step 1 funnel (drilled by filter)

| Filter | Surviving |
|---|---:|
| start (sessions.parquet) | 5,851 |
| `prompt_count >= 3` | 3,704 |
| `action_count > 0` | 3,541 |
| `stars >= 10` | 1,373 |
| `agent_percentage >= 30` | **760** |

### Step 1 filter changes (2026-05-06)

| Filter | Old | New | Why |
|---|---|---|---|
| `is_fork == False` | enforced | **removed** | SWE-chat's `repositories` table never includes forks; the filter dropped 0 rows. Dead code. |
| `session_success >= 50` | enforced | **removed** | `session_success` is itself a Gemini annotation. step2 Pro reruns the viability judgment on each survivor, so this filter just preapplies a weaker version of the same signal. |
| `stars >= 20` | 20 | **10** | DataClaw used 20 to filter individual hobby repos. SWE-chat is pre-curated to public GitHub projects with a `repo_type_audience` field, so the star bar is less load-bearing — quality is enforced by step2 Pro. |

Outputs:
- [`step1_all_sessions.json`](step1_all_sessions.json) — 760 records, full Stage-0 payload.
- [`step1_run_config.json`](step1_run_config.json) — config of this run.

(`step1_candidates.json` is a byte-identical duplicate of
`step1_all_sessions.json`; the SWE-chat path applies all filters inline,
so a separate "candidates" file is redundant. Currently regenerated on
each run; either delete after each run or strip the duplicate write
from `step1_collect.py`.)

### Step 1 — top repos (760 candidates)

| # | Repo |
|---:|---|
| 269 | entireio/cli |
| 100 | moltis-org/moltis |
| 99 | obsessiondb/rudel |
| 68 | lightfastai/lightfast |
| 56 | Nagi-ovo/gemini-voyager |
| 24 | shunkakinoki/dotfiles |
| 22 | desplega-ai/agent-swarm |
| 17 | Sagit-chu/flvx |
| 17 | hutusi/amytis |
| 16 | marin-community/marin |

`entireio/cli` is 35% of step1 (down from 42% pre-relaxation, but still
dominant). Two new repos appear in the top 5 from the stars-10 relaxation:
`lightfastai/lightfast` (68) and `shunkakinoki/dotfiles` (24).

### Step 1 — user persona (760)

| # | Persona |
|---:|---|
| 388 | Expert Nitpicker |
| 300 | Vague Requester |
| 49 | Mind Changer |
| 23 | Other |

### Step 1 — agent (760)

| # | Agent |
|---:|---|
| 735 | Claude Code |
| 21 | OpenCode |
| 4 | Agent (unspecified) |

## Step 2 — `step2_screen_with_llm.py --source swechat`

Gemini 3.1 Pro per-session viability judge. Replaced the older Flash → Pro
two-stage flow because SWE-chat already exposes `repo_id` + star count +
`action_count` natively, so the Flash repo+stars step added no signal and
disagreed with Pro on 46% of cases.

Per-session Pro answers (stored in [`step2_screening.json`](step2_screening.json) for all 760):
- `primary_deliverable` ∈ {code_changes, pr_creation, issue_triage, analysis_only, deployment_ops, other}
- `reproducible_in_harbor` ∈ {true, false}
- `verdict` ∈ {VIABLE, NOT_VIABLE}
- `reason` (1 sentence)

Most recent run was a `--resume` against the prior 626-input result file:
626 already-judged sessions reused, only the 134 newly-added (from the
2026-05-06 relaxation) sent to Pro.

### Verdict distribution (all 760)

| Verdict | # | % |
|---|---:|---:|
| VIABLE | 333 | 43.8 |
| NOT_VIABLE | 427 | 56.2 |

### Primary deliverable distribution (all 760)

| Deliverable | # | % |
|---|---:|---:|
| `code_changes` | 642 | 84.5 |
| `other` | 63 | 8.3 |
| `pr_creation` | 24 | 3.2 |
| `analysis_only` | 18 | 2.4 |
| `deployment_ops` | 11 | 1.4 |
| `issue_triage` | 2 | 0.3 |

### Reproducible-in-Harbor distribution (all 760)

| Reproducible | # |
|---|---:|
| `true` | 330 |
| `false` | 417 |
| missing | 13 |

### NOT_VIABLE breakdown by deliverable

| Deliverable | # | Why dropped |
|---|---:|---|
| `code_changes` | 309 | Codes but external state (push/PR/deploy) is the actual deliverable, or workspace is not reproducible from a clean clone |
| `other` | 63 | — |
| `pr_creation` | 24 | Primary value is opening a PR, not the diff |
| `analysis_only` | 18 | Discussion / planning, no substantive edits |
| `deployment_ops` | 11 | Live infra changes |
| `issue_triage` | 2 | Filing / commenting on issues |

The big one: **309/427 NOT_VIABLE sessions DID make code changes** — Pro
classified them as not reproducible in a clean Harbor task because the
session's true deliverable was tied to external state (push to remote, PR
description, side effects), not the repo diff alone.

## Final candidate set — `step2_candidates.json`

Filter: `verdict==VIABLE AND reproducible_in_harbor==true`. **329 records.**

(333 VIABLE − 4 where Pro returned VIABLE but flagged reproducible=false or missing.)

### Top repos (top 15)

| # | Repo |
|---:|---|
| 122 | entireio/cli |
| 39 | Nagi-ovo/gemini-voyager |
| 37 | moltis-org/moltis |
| 33 | obsessiondb/rudel |
| 32 | lightfastai/lightfast |
| 10 | shunkakinoki/dotfiles |
| 9 | marin-community/marin |
| 7 | Lightprotocol/light-protocol |
| 7 | hutusi/amytis |
| 6 | desplega-ai/agent-swarm |
| 6 | kgcrom/cluefin |
| 5 | ClusterCockpit/cc-backend |
| 4 | adrientaudiere/MiscMetabar |
| 3 | Brickell-Research/caffeine_lang |
| 2 | 4gray/iptvnator |

Top 1 = 37% (down from 42% pre-relaxation), top 5 = 80%. Without a
per-repo cap, downstream Harbor task selection still over-indexes on
`entireio/cli` (the dataset author's own dogfood CLI).

### Stars distribution (329 candidates)

| Stars | # |
|---:|---:|
| < 50 | 56 |
| 50–99 | 11 |
| 100–499 | 52 |
| 500–999 | 9 |
| 1k–9999 | 200 |
| 10k+ | 1 |

61% of candidates land in the 1k–9999 star range — a healthy popularity
band for benchmark inclusion. The new 56 candidates with <50 stars are
the ones admitted by lowering `stars >= 20` to `>= 10`.

### User persona (329 candidates)

| # | Persona |
|---:|---|
| 188 | Expert Nitpicker |
| 116 | Vague Requester |
| 25 | Mind Changer |

Both top personas are well-suited to a multi-turn user-correction benchmark.

## Open questions / follow-ups

1. **Per-repo concentration.** `entireio/cli` is 37% of step2 candidates
   (down from 42% pre-relaxation, but still dominant). Consider
   `--per-repo-cap` at step1 to diversify before scaffolding into Harbor
   tasks. With `--per-repo-cap 5` the candidate count drops sharply but
   diversity climbs.

2. **The 309 "code_changes but NOT_VIABLE" sessions** are the most
   interesting NOT_VIABLE bucket — agent did real edits but Pro judged
   they aren't reproducible in a clean Harbor sandbox. Worth a manual
   spot-check to confirm Pro's reasoning is well-calibrated; some may
   be rescuable by sharpening the Harbor reproducibility prompt.

3. **Transcript parse errors.** A handful of `'str' object has no attribute 'get'`
   and `'int' object has no attribute 'get'` warnings showed up during
   step2 fetch (≤2 per resume run). Fixing the JSONL parser to handle
   the alternative SWE-chat schema would lift a small handful of
   missing evaluations; the 13 sessions with `reproducible_in_harbor: missing`
   are the ones affected.

4. **step1 schema, optional rework.** SWE-chat path writes only the 760
   post-filter records. To match DataClaw's two-file schema (5,851 raw
   with `pass_*` flags, plus filtered candidates), step1 would need to
   emit the pre-filter set as well — useful for "why was this dropped?"
   debugging but ~10× larger. Also worth dropping the redundant
   `step1_candidates.json` duplicate write while we're at it.

5. **step2 input path is hardcoded.** `step2_screen_with_llm.py` reads
   from `scripts/screening/swechat/all_sessions.json` regardless of
   whether step1 was run with `--out-dir`. Currently we copy from
   artifacts dir → default location before resuming. Adding an
   `--input` arg (or making step2 read `step1_all_sessions.json` from
   `--out-dir` when both are set to the same dir) would close this
   asymmetry.
