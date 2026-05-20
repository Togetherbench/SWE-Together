# Pilot study — Leaderboard structure rendered (v0.5.0)

Concrete numbers for every block of [`eval_design.md`](eval_design.md#leaderboard-structure)
§"Leaderboard structure", computed on the
[release v0.5.0](https://github.com/Togetherbench/SWE-Together/releases/tag/v0.5.0)
pilot:

- agent: **DS-Pro** coding agent
- user-sim: **Gemini-3.1-Pro** free-LLM sim (no graph constraint)
- trials: `trials_eval_pilot_10_task_r{1,2,3}/` → **10 tasks × 3 trials = 31 trials**

Pipeline: [`eval/run_eval.py`](run_eval.py). Raw artefacts at
[`pipeline_logs/pilot_v050/`](../pipeline_logs/pilot_v050/) — JSON + per-trial join.

> **One model = one row's worth of leaderboard.** The design doc says
> *three blocks per model*. The pilot has one (agent, sim) cohort so the
> "leaderboard" is one row; the tables below are per-task within that row.

---

## Block 1 — Capability (effort-aware) **[P0]**

| metric | per-trial source | pilot value |
|---|---|---|
| `effort_cost(trial)` | `user_behavior_verdict.json` | **not populated** — §Proposal schema extension hasn't landed in `coverage_one.py`, so `trial_msg_specificity` is `null` across all 31 trials |
| `success@k` for k ∈ {0, 3, 10} | derived from effort_cost + judge_score | **—** (gated on effort_cost) |
| `effort_AUC` | derived from success@k curve | **—** (gated on effort_cost) |

What we *can* report from this block is the **cleaned mean judge** (step-2
filter applied; see Block 2), which is the natural Block-1 headline until
effort_cost lands:

| task | n → surv | mean_judge | var_judge | judge_scores (kept) |
|---|---:|---:|---:|---|
| `cli-task-2a55af` | 3 → 3 | 0.223 | 0.100 | [0.00, 0.00, 0.67] |
| `cli-task-2f5833` | 3 → 3 | 0.653 | 0.001 | [0.64, 0.69, 0.63] |
| `cli-task-46c118` | 3 → 3 | 0.840 | 0.011 | [0.69, 0.93, 0.90] |
| `cli-task-7e3475` | 3 → 2 | 0.920 | 0.001 | [0.89, 0.95] |
| `cli-task-f76665` | 3 → 2 | 0.985 | 0.000 | [0.97, 1.00] |
| `cluefin-task-52eab9` | 3 → 3 | 0.953 | 0.001 | [0.93, 0.93, 1.00] |
| `comfyui-frontend-autoscale-layout` | 4 → 4 | 0.897 | 0.002 | [0.91, 0.93, 0.82, 0.93] |
| `gemini-voyager-task-18a6ae` | 3 → 3 | 0.453 | **0.124** | [0.86, 0.50, 0.00] |
| `rudel-task-468289` | 3 → 3 | 0.800 | 0.009 | [0.77, 0.93, 0.70] |
| `sd-scripts-reg-image-dedup` | 3 → 3 | 0.830 | 0.030 | [0.59, 0.90, 1.00] |
| **cross-task mean** | | **0.756** | — | — |

Bold `var_judge` = high spread the filter *preserved* (real agent variance —
see Block 2 §"Preserved (textbook §Pitfall case)").

---

## Block 1' — Secondary effort metrics **[P1]**

| metric | per-trial source | pilot value |
|---|---|---|
| `min_effort_to_success(task)` P50 | `median(min(r.effort_cost) over r with judge_score ≥ 0.85)` | **—** (gated on effort_cost) |
| `effort_per_matched_intent` | `effort_cost / matched_intents` | **—** (gated on effort_cost) |

Both columns are entirely effort-cost-dependent; both are deferred to the
post-§Proposal re-run. The per-trial verdict already carries
`matched_intents` (derived from the existing `match_table` — already
populated for all 31 trials in the pilot), so the denominator is ready —
only the numerator (`effort_cost`) is missing.

---

## Block 2 — Sim health (filter, not rank)

`overall_score` per trial across the 3 cohorts, plus what the **3-AND filter**
did with each row. **Used only to drop divergent trials before computing
Block 1 — never enters the rank itself.**

| task | r1 overall | r2 overall | r3 overall | filter action | reason |
|---|---:|---:|---:|---|---|
| `cli-task-2a55af` | 0.529 | 0.643 | 0.436 | keep all | r3 magnitude gap 0.093 < 0.10 |
| `cli-task-2f5833` | 1.000 | 0.883 | 0.883 | keep all | spread tiny |
| `cli-task-46c118` | 1.000 | 1.000 | 1.000 | keep all | identical |
| `cli-task-7e3475` | 0.610 | **0.493** | 0.610 | **drop r2** | rel ✓ · abs ✓ (0.493<0.50) · gap ✓ (0.117) |
| `cli-task-f76665` | **0.409** | 0.747 | 0.698 | **drop r1** | rel ✓ · abs ✓ (0.409<0.50) · gap ✓ (0.289) |
| `cluefin-task-52eab9` | 0.816 | 0.673 | 0.633 | keep all | all ≥ abs_floor |
| `comfyui-frontend-autoscale-layout` | 0.781 / 0.626 / 0.787 / 0.727 (4 cohorts) | | | keep all | r2 0.626 ≥ abs_floor |
| `gemini-voyager-task-18a6ae` | 0.904 | 0.626 | 0.757 | keep all | **§Pitfall**: r2 ≥ abs_floor → preserve, the 0.124 `var_judge` is real agent variance |
| `rudel-task-468289` | 0.935 | 0.786 | 0.903 | keep all | all ≥ abs_floor |
| `sd-scripts-reg-image-dedup` | 0.763 | 0.772 | 0.761 | keep all | σ ≈ 0 |

Filter parameters (matches `eval_design.md` §"Filter protocol (step 2)"):

```
SIGMA_K = 1.0   ABS_FLOOR = 0.50   MAGNITUDE_GAP = 0.10
drop ⇐ (o < median−σ) AND (o < 0.50) AND (median − o > 0.10)
```

**Summary**: 2 / 31 trials dropped (6.5%). Both dropped trials had
`overall_score < 0.50` *and* the relative + magnitude guards triggered —
exactly the cases the prose says should drop.

### Preserved (textbook §Pitfall case)

`gemini-voyager-task-18a6ae` overalls = [0.904, 0.626, 0.757]; judges =
[0.86, 0.50, 0.00]. The r2 trial (overall=0.626) is below the relative
threshold (0.643) and exceeds the magnitude gap (0.13), so the *old*
`max()`-based filter would have dropped it — but `0.626 > abs_floor 0.50`,
so the 3-AND form correctly keeps it. The high `var_judge = 0.124` is
*real agent variance*, not sim noise, and is preserved in the headline.
This is the disentanglement story working as designed.

### Filter bug fix (2026-05-20)

The first version of `disentangle_correctness` used
`threshold = max(relative, abs_floor)` and only checked `o < threshold`.
That form meant `abs_floor` only protected trials when σ was *small*; when
σ was large enough that `relative > 0.50`, healthy trials like
`gemini-voyager r2` got dropped, contradicting both the prose and the
§Pitfall claim.

Effect on the v0.5.0 pilot, fixed vs. old:

| task | old filter | 3-AND filter | reason |
|---|---|---|---|
| `gemini-voyager-task-18a6ae` | dropped r2 | kept all 3 | r2 overall 0.626 ≥ abs_floor ✓ |
| `comfyui-frontend-autoscale-layout` | dropped r2 | kept all 4 | r2 overall 0.626 ≥ abs_floor ✓ |
| `rudel-task-468289` | dropped r2 | kept all 3 | r2 overall 0.786 ≥ abs_floor ✓ |
| `cli-task-7e3475` | dropped r2 | dropped r2 (same) | overall 0.493 < 0.50 ✓ |
| `cli-task-f76665` | dropped r1 | dropped r1 (same) | overall 0.409 < 0.50 ✓ |

Net: **drops shrunk from 5 → 2**. Both
[`eval_design.md`](eval_design.md#filter-protocol-step-2) and
[`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md#algorithm--filter-outlier-cohorts)
now carry the corrected code; inline notes flag the change.

---

## Block 3 — Benchmark fidelity

Per-task QA signals. **Used to caveat / exclude tasks; never enters Block 1.**

| task | `judge_clean_testsh_delta` mean | empty-patch rate | judge warn rate | coverage warn rate |
|---|---:|---:|---:|---:|
| `cli-task-2a55af` | +0.223 | 0% | **66.7%** | 0% |
| `cli-task-2f5833` | +0.237 | 0% | 0% | 0% |
| `cli-task-46c118` | −0.160 | 0% | 0% | 0% |
| `cli-task-7e3475` | +0.330 | 0% | **100.0%** | 0% |
| `cli-task-f76665` | −0.083 | 0% | 0% | 0% |
| `cluefin-task-52eab9` | +0.453 | 0% | 0% | 0% |
| `comfyui-frontend-autoscale-layout` | +0.373 | 0% | 25.0% | 0% |
| `gemini-voyager-task-18a6ae` | −0.247 | 0% | 33.3% | 0% |
| `rudel-task-468289` | +0.100 | 0% | 33.3% | 0% |
| `sd-scripts-reg-image-dedup` | −0.120 | 0% | 0% | 0% |
| **cross-task mean** | **+0.111** | **0%** | **25.8%** | **0%** |

Reading the columns:
- **`judge_clean_testsh_delta`** = `judge_score − test.sh reward`. Positive
  means the agentic judge is more lenient than the `test.sh` verifier (which
  it usually is — `cluefin` at +0.45 is the most generous tier). Negative
  means the judge is *stricter* than `test.sh` (`gemini-voyager` at −0.25 —
  judge sees the agent broke something the verifier missed). Per
  [`correctness/METHOD_AND_PILOT.md`](correctness/METHOD_AND_PILOT.md),
  `|delta| > 0.30` flags the task for verifier-hygiene review (in this
  pilot: `cli-task-7e3475` +0.33 and `comfyui-frontend...` +0.37).
- **`empty-patch rate` = 0%** across all 31 trials — every run produced
  *some* patch. Nothing to exclude here.
- **`judge warn rate`**: 25.8% of trials had at least one judge schema
  warning. Concentrated in `cli-task-7e3475` (100%) and `cli-task-2a55af`
  (66.7%) — both tasks worth a separate audit; the warnings are most likely
  judge LLM nondeterminism on hard match-tables.
- **`coverage warn rate` = 0%** across all 31 trials — the intent-coverage
  match-table format is clean on this pilot.

---

## Headline — single-row leaderboard (this cohort)

The full §"Leaderboard structure" three blocks collapse to one row for the
DS-Pro + Gemini-3.1-Pro cohort:

| dimension | metric | value |
|---|---|---:|
| **Block 1** | `mean_judge_over_tasks` (after step-2 filter) | **0.756** |
| Block 1 | `success@0` (effort-aware) | — (pending effort_cost) |
| Block 1 | `effort_AUC` | — (pending effort_cost) |
| **Block 1'** | `effort_per_matched_intent_mean` | — (pending effort_cost) |
| Block 1' | `min_effort_to_success_p50` | — (pending effort_cost) |
| **Block 2** | trials surviving the filter | **29 / 31** (93.5%) |
| Block 2 | tasks with all replicates kept | **8 / 10** |
| **Block 3** | `judge_clean_testsh_delta_mean` | **+0.111** |
| Block 3 | `empty_patch_rate_mean` | **0.0%** |
| Block 3 | `judge_warn_rate_mean` | **25.8%** |
| Block 3 | `coverage_warn_rate_mean` | **0.0%** |
| **step 3 (behavior)** | `intervention_count_mean` | **4.34 msgs / trial** |
| step 3 | `hard_cap_abandon_rate_mean` | **0.0%** |

**No composite score across blocks**, per `eval_metric.md` §"Non-Goals".
Each block is read separately.

---

## What's missing & what's next

1. **§Proposal — `effort_cost`**. Land the schema extension to
   [`coverage_system.md`](intent_coverage/prompts/coverage_system.md)
   (emit `trial_msg_specificity` per trial msg) + the `effort_cost` field on
   `coverage_one.py`. Re-run intent_coverage on the same 31 trials (~$3, ~60s)
   and re-aggregate with `--only-aggregate`. Block 1 / 1' auto-populate;
   no `run_eval.py` change needed.
2. **`judge_warn_rate` audit**. 25.8% is high; concentrate on
   `cli-task-7e3475` (100%) and `cli-task-2a55af` (66.7%) first — likely
   judge LLM nondeterminism but worth confirming it's not a schema bug.
3. **Second cohort for cross-cohort filter calibration**. The pilot is one
   (agent, sim) so we only get within-cohort filtering. Run a second sim
   (e.g., the graph-constrained baseline) to also exercise the *cross-cohort*
   path of `disentangle_correctness` in
   [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md).

---

## Reproducing

```bash
python -m eval.run_eval \
    --trials-root trials_eval_pilot_10_task_r1 \
    --trials-root trials_eval_pilot_10_task_r2 \
    --trials-root trials_eval_pilot_10_task_r3 \
    --coverage-out-name intent_coverage_verdict_v2_freeLLM_r1.json \
    --coverage-out-name intent_coverage_verdict_v2_freeLLM_r2.json \
    --coverage-out-name intent_coverage_verdict_v2_freeLLM_r3.json \
    --tasks-root harbor_tasks \
    --output-dir pipeline_logs/pilot_v050 \
    --model-tag "DS-Pro + Gemini-3.1-Pro user-sim (pilot v0.5.0)" \
    --only-aggregate
```

Outputs:
- [`pipeline_logs/pilot_v050/eval_report.json`](../pipeline_logs/pilot_v050/eval_report.json) — per-task aggregate
- [`pipeline_logs/pilot_v050/eval_report.md`](../pipeline_logs/pilot_v050/eval_report.md) — auto-rendered Markdown summary
- [`pipeline_logs/pilot_v050/per_trial.json`](../pipeline_logs/pilot_v050/per_trial.json) — 31 trials, joined view (all three verdicts + cohort tag)
