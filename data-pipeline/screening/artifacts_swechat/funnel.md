# SWE-chat Screening Funnel

Snapshot of the SWE-chat → benchmark-candidate pipeline as of 2026-05-06.

## Headline numbers

```
SWE-chat raw                                5,851
   │  step1: deterministic filters
   ▼
step1_all_sessions.json                       760   (13.0% of raw)   ← updated 2026-05-06
   │  step2: Gemini 3.1 Pro reproducibility judge
   ▼
step2_screening.json (full)                   ___   STALE; reflects prior step1 input of 626
   ├─ VIABLE                                  ___
   └─ NOT_VIABLE                              ___
   │
   │  filter: verdict==VIABLE AND reproducible_in_harbor==true
   ▼
step2_candidates.json                         274   STALE; rerun step2 to refresh against 760 input
```

> **2026-05-06 filter relaxation.** Three changes to step1 (see "Step 1
> filter changes" below): dropped `is_fork` (was filtering 0 rows),
> dropped `session_success` (redundant Gemini-derived signal that step2
> Pro already independently judges), and lowered `stars` from 20 to 10
> (SWE-chat repos are pre-filtered to public GitHub projects, so a lower
> star bar is fine). Net: step1 626 → 760 (+134 / +21%).
>
> step2 has not been rerun on the new 760-input set. Numbers in the
> "Step 2" section below still reflect the prior 626-input run and are
> marked **STALE**.

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

(`step1_candidates.json` is currently re-emitted as a duplicate of
`step1_all_sessions.json`; SWE-chat path applies all filters inline so a
separate "candidates" file is redundant. Either delete after each run or
strip the duplicate write from `step1_collect.py`.)

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

`entireio/cli` is 35% of step1 — still concentrated. Two new repos
appear in top 5 from the stars-10 relaxation: `lightfastai/lightfast`
(68) and `shunkakinoki/dotfiles` (24).

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

## Step 2 — `step2_screen_with_llm.py --source swechat`  ⚠ STALE

> **Numbers in this section reflect the prior step1 626-input run.** Rerun
> step2 against the new 760-input `step1_all_sessions.json` to refresh.

Gemini 3.1 Pro per-session viability judge. Replaced the older Flash → Pro
two-stage flow because SWE-chat already exposes `repo_id` + star count +
`action_count` natively, so the Flash repo+stars step added no signal and
disagreed with Pro on 46% of cases.

Per-session Pro answers (stored in [`step2_screening.json`](step2_screening.json)):
- `primary_deliverable` ∈ {code_changes, pr_creation, issue_triage, analysis_only, deployment_ops, other}
- `reproducible_in_harbor` ∈ {true, false}
- `verdict` ∈ {VIABLE, NOT_VIABLE}
- `reason` (1 sentence)

### Verdict distribution (626-input run, STALE)

| Verdict | # | % |
|---|---:|---:|
| VIABLE | 277 | 44.2 |
| NOT_VIABLE | 349 | 55.8 |

### Primary deliverable distribution (626-input run, STALE)

| Deliverable | # | % |
|---|---:|---:|
| `code_changes` | 533 | 85.1 |
| `other` | 48 | 7.7 |
| `pr_creation` | 22 | 3.5 |
| `analysis_only` | 12 | 1.9 |
| `deployment_ops` | 9 | 1.4 |
| `issue_triage` | 2 | 0.3 |

### NOT_VIABLE breakdown by deliverable (626-input run, STALE)

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

## Final candidate set — `step2_candidates.json`  ⚠ STALE

Filter: `verdict==VIABLE AND reproducible_in_harbor==true`. **274 records**
(based on 626-input).

### Top repos (274 STALE candidates)

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

### Stars distribution (274 STALE)

| Stars | # |
|---:|---:|
| < 50 | 10 |
| 50–99 | 11 |
| 100–499 | 50 |
| 500–999 | 9 |
| 1k–9999 | 193 |
| 10k+ | 1 |

### User persona (274 STALE)

| # | Persona |
|---:|---|
| 167 | Expert Nitpicker |
| 87 | Vague Requester |
| 20 | Mind Changer |

## Open questions / follow-ups

1. **Rerun step2 on the new 760-input set.** Expected outcome based on
   step2's prior 43.8% pass rate: ~333 VIABLE candidates (+59 over current
   274). Some of the +134 newly-included step1 sessions sit in repos
   with stars 10–19 — Pro will judge each independently.

2. **Per-repo concentration.** `entireio/cli` is 35% of step1 (down from
   42% pre-relaxation, but still dominant). Consider `--per-repo-cap` at
   step1 to diversify before scaffolding.

3. **The 256 "code_changes but NOT_VIABLE" sessions** are the most
   interesting NOT_VIABLE bucket — agent did real edits but Pro judged
   they aren't reproducible in a clean Harbor sandbox. Worth a manual
   spot-check to confirm Pro's reasoning is well-calibrated; some may
   be rescuable by sharpening the Harbor reproducibility prompt.

4. **Transcript parse errors.** A handful of `'str' object has no attribute 'get'`
   warnings showed up during step2 fetch. Fixing the JSONL parser to handle
   the alternative SWE-chat schema would lift 5–10 missing evaluations.

5. **step1 schema, optional rework.** SWE-chat path writes only the 760
   post-filter records. To match DataClaw's two-file schema (5,851 raw
   with `pass_*` flags, plus filtered candidates), step1 would need to
   emit the pre-filter set as well — useful for "why was this dropped?"
   debugging but ~10× larger. Also worth dropping the redundant
   `step1_candidates.json` duplicate write while we're at it.
