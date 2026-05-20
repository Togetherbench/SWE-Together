# `eval/user_behavior` — per-trial panel of sim behavior metrics

Step 3 of the three-step protocol in [`eval/eval_design.md`](../eval_design.md#three-step-protocol-per-task-agent):

> On the surviving trials, run a panel of user-behavior measurements — user
> effort, per-tier specificity distribution, intervention count, abandonment /
> give-up rate, etc. These are not aggregated into the correctness number;
> they sit alongside it so a reader can see *how* the sim got the agent to
> the score it got.

Companion to [`eval/correctness/`](../correctness/) (judge_score) and
[`eval/intent_coverage/`](../intent_coverage/) (overall_score + effort_cost).

**No LLM calls.** This package only reads existing per-trial artefacts on disk
and emits a `<trial>/user_behavior_verdict.json` per trial.

---

## What's in the box

```
eval/user_behavior/
├── behavior_one.py   # per-trial measurement (file I/O only)
├── run_batch.py      # async pool wrapper, mirrors intent_coverage CLI
└── README.md
```

Per-trial output (`<trial>/user_behavior_verdict.json`):

```jsonc
{
  "schema_version": 1,
  "n_episodes": 10,
  "intervention_count": 7,      // has_message=true count
  "no_op_count": 3,
  "wait_count_final": 2,
  "max_messages": null,
  "hard_cap_abandon": false,    // did the sim hit its message cap?
  "per_action_count": {         // from sim stats.action_breakdown
    "no-op": 3, "question": 1, "redirect": 5,
    "new_requirement": 1, "check_external": 0
  },
  "per_tier_count": {           // from intent_coverage's trial_msg_specificity
    "vague": 0, "directional": 2, "diagnostic": 4,
    "prescriptive": 1, "patch_level": 0
  },
  "per_tier_fraction": {...},   // / n_trial_msgs
  "per_kind_count": {           // from kind_hint
    "request": 3, "correction": 2, "question": 1, "verification": 0,
    "workflow": 1, "context": 0, "approval": 0
  },
  "effort_cost": 18,            // pulled from intent_coverage_verdict, or
                                //   re-derived in code from per_tier × kind_hint
  "matched_intents": 5,
  "effort_per_matched_intent": 3.6,
  "specificity_present": true,  // false if §Proposal schema hasn't landed yet
  "elapsed_sec": 0.012
}
```

---

## Inputs

Per trial — all read-only, all already produced upstream:

| source | what we read | required |
|---|---|---|
| `<trial>/agent/episode-*/user_decision.json` | `action`, `has_message`, `stats.action_breakdown`, `stats.message_count`, `stats.max_messages`, `stats.wait_count`, `raw_response` | **yes** |
| `<trial>/intent_coverage_verdict.json` | `trial_msg_specificity[]`, `effort_cost`, `match_table.per_intent[]`, `n_trial_msgs` | optional — degrades gracefully when absent |
| `<task>/oracle_intents.json` | (unused for now — reserved for future kind cross-checks) | — |

If `intent_coverage_verdict.json` is missing or the §Proposal schema extension
(`trial_msg_specificity` + `effort_cost`) hasn't landed yet, every per-tier /
per-kind / effort field reports `None` or all-zero and `specificity_present`
flags the gap.

---

## What we measure & why

| metric | source | answers |
|---|---|---|
| `intervention_count` | episodes where `has_message=true` | how often the sim spoke up |
| `no_op_count` | episodes where `action == "no-op"` | how often the sim let the agent run |
| `per_action_count` | `stats.action_breakdown` (last episode = cumulative total) | mix of redirect / question / new_requirement / check_external / no-op |
| `per_tier_count` + `per_tier_fraction` | `trial_msg_specificity[].tier` | "did the sim mostly nudge or mostly hand-feed?" |
| `per_kind_count` | `trial_msg_specificity[].kind_hint` | what *kind* of help was the sim giving |
| `effort_cost` | intent_coverage's precomputed field, or re-derived | per-trial scalar of hint payload (§B of eval_design.md) |
| `effort_per_matched_intent` | effort_cost / matched intents (conf ≥ 0.5) | sim-verbosity diagnostic (Block 1') |
| `hard_cap_abandon` | `raw_response == "hard_cap_reached"` OR `message_count >= max_messages` in last episode | did the sim run out of budget instead of finishing on its own |

`hard_cap_abandon` is the operational definition of abandonment we settled on
in this design — strict and unambiguous, sourced from the sim's own counter.
If a future eval needs softer abandonment signals (long trailing no-op runs
while oracle intents remain, etc.) add another field; do not relax this one's
definition, since downstream aggregations rely on its precision.

---

## Running

Single trial:

```bash
python -m eval.user_behavior.behavior_one \
    --trial-dir trials_eval_pilot_10_task_r1/cli-task-2a55af__LXqASZW \
    --task-dir  harbor_tasks/cli-task-2a55af
```

Batch:

```bash
python -m eval.user_behavior.run_batch \
    --plan pipeline_logs/user_behavior_plan.json \
    --workers 16
```

Plan file shape is the same as `intent_coverage/run_batch.py` (a JSON list of
`{trial_dir, task_dir, out_name}` jobs). Re-use the same plan when running
all three evaluators in sequence.

---

## Aggregation (downstream)

This package does NOT aggregate across trials. Aggregation lives in the
leaderboard script (see Block 1 + 1' of [`eval/eval_design.md`](../eval_design.md#block-1--capability-effort-aware-p0)):

- `success@k(task, model)` → reads `effort_cost` + `judge_score` per surviving trial
- `min_effort_to_success` P50 → same inputs
- `effort_per_matched_intent` → as a Block 2 sim-verbosity health column

The per-trial verdict written here is the canonical source for those reads.

---

## 10-task pilot — empirical findings (2026-05-20, 31 trials)

Ran step 3 on every trial of the
[`correctness`](../correctness/METHOD_AND_PILOT.md) /
[`intent_coverage`](../intent_coverage/METHOD_AND_PILOT.md)
pilot set (DS-Pro coding agent + Gemini-3.1-Pro user-sim, no LLM here —
0.01s/trial × 31 trials, finished in under a second). All 31 trials
have `user_behavior_verdict.json`; the §Proposal `effort_cost` /
per-tier fields are still null because the schema extension hasn't
landed in `coverage_one.py` yet — pilot reports the file-I/O metrics
only.

### Headline numbers

| metric | value | reading |
|---|---|---|
| n trials | 31 | 10 tasks × 3 cohorts + comfyui dupe |
| `hard_cap_abandon` | **0 / 31** (0%) | no trial hit the message cap — the cap is not binding on this task set |
| intervention count μ ± σ | **4.2 ± 2.4** (range 1–13) | typical trial: ~4 sim messages |
| no-op share | **47.2%** of all sim decisions | sim sits out almost half the time — selective intervention is the dominant mode |
| `effort_cost` populated | **0 / 31** | §Proposal not landed → re-run after `coverage_one.py` adds `trial_msg_specificity` |

### Action-type mix (aggregate across 31 trials)

| action | count | share |
|---|---:|---:|
| `no-op` | 116 | 47.2% |
| `new_requirement` | 56 | 22.8% |
| `redirect` | 39 | 15.9% |
| `question` | 35 | 14.2% |
| `check_external` | 0 | 0.0% |

`check_external` never fires in this pilot — either the sim policy
doesn't emit it on these tasks or the action is dead code. Worth a
follow-up audit in `user_enabled_claude_code.py`.

### Per-task panel

| task | n | intv μ±σ | no-op% | new_req% | redirect% | question% | judge μ±σ |
|---|---:|---|---:|---:|---:|---:|---|
| `cli-task-2a55af` | 3 | **8.7±4.04** | 23.5 | 41.2 | 32.4 | 2.9 | 0.22±0.39 |
| `cli-task-2f5833` | 3 | 2.7±0.58 | 60.0 | 30.0 | 10.0 | 0.0 | 0.65±0.03 |
| `cli-task-46c118` | 3 | **2.0±0.00** | 66.7 | 16.7 | 0.0 | 16.7 | 0.84±0.13 |
| `cli-task-7e3475` | 3 | 2.3±0.58 | 63.2 | 31.6 | 5.3 | 0.0 | 0.93±0.03 |
| `cli-task-f76665` | 3 | 4.7±**3.21** | 0.0 | 21.4 | 21.4 | **57.1** | 0.92±0.12 |
| `cluefin-task-52eab9` | 3 | 5.0±0.00 | 50.0 | 26.7 | 23.3 | 0.0 | 0.95±0.04 |
| `comfyui-frontend-autoscale-layout` | 4 | 4.2±0.96 | 50.0 | 2.9 | 20.6 | 26.5 | 0.90±0.05 |
| `gemini-voyager-task-18a6ae` | 3 | 4.3±0.58 | 50.0 | 11.5 | 11.5 | 26.9 | 0.45±0.43 |
| `rudel-task-468289` | 3 | 2.3±0.58 | 66.7 | 28.6 | 4.8 | 0.0 | 0.80±0.12 |
| `sd-scripts-reg-image-dedup` | 3 | 5.7±1.15 | 43.3 | 20.0 | 13.3 | 23.3 | 0.83±0.21 |

### Sim-instability signal (intervention-count variance across cohorts)

Three tasks have `intervention_count` σ > 1.0 across cohorts:

| task | intervention counts | doc bucket |
|---|---|---|
| `cli-task-2a55af` | [5, 13, 8] | partial-converge / sim outlier r3 (doc §Q3) |
| `cli-task-f76665` | [1, 7, 6] | DIVERGENT (doc §Q3) — r1 is the 1-msg outlier |
| `sd-scripts-reg-image-dedup` | [5, 5, 7] | partial-converge |

These coincide exactly with the cohorts the `intent_coverage` filter
drops or flags — intervention-count σ is a much cheaper instability
canary than a full coverage re-run, useful when triaging which task to
look at first before paying for an LLM pass.

### Cross-correlations (31 trials)

- **Pearson r(intervention_count, judge_score) = −0.31**
- **Pearson r(intervention_count, intent_overall_score) = −0.30**

Both negative — more sim hand-holding correlates with *worse* outcomes
(both on patch correctness and on intent alignment). The clearest case
is the `incorrect`-verdict trials, which average **7.3** interventions
vs **4.2** for `equivalent` and **3.4** for `partial`. Direction of
causation is not isolated by this run (sim ramps up when the agent is
struggling, vs sim over-interference confusing the agent) — but the
sign is consistent with "sim doing more ≠ helping more," which is the
motivation for tracking `effort_cost` as a leaderboard dimension once
the §Proposal lands.

### Caveats

- 3 trials per task is too thin to read the per-task mix as a real
  policy distribution. Means and σs are sensitive to a single cohort.
- `effort_cost = None` everywhere means the headline §B metric in
  [`eval_design.md`](../eval_design.md) is not yet usable. Re-run this
  pipeline after the §Proposal extension to `coverage_one.py` lands.
- `check_external` count of 0 may be a sim-policy artefact (these
  tasks don't trigger it) or dead code in the simulator — check before
  removing the field.

---

## Relationship to the §Proposal schema extension

The §Proposal in [`eval/eval_design.md`](../eval_design.md#proposal--user-effort-as-a-per-trial-scalar) extends `prompts/coverage_system.md` to emit
`trial_msg_specificity` + computes `effort_cost` in `coverage_one.py`.

This package consumes those fields. Until the proposal lands:
- `effort_cost` is re-derived locally from `trial_msg_specificity` if present
- `per_tier_count` / `per_kind_count` will be all-zero and
  `specificity_present=false`

That's intentional — user_behavior is structurally independent of the
intent_coverage prompt change, so it can ship in parallel.
