# Pilot study — Leaderboard structure rendered (v0.5.1)

Concrete numbers for every block of [`eval_design.md`](eval_design.md#leaderboard-structure)
§"Leaderboard structure", computed on the
[release v0.5.0](https://github.com/Togetherbench/SWE-Together/releases/tag/v0.5.0)
pilot, re-judged with the v2 coverage prompt that emits the §Proposal
`trial_msg_specificity` + `effort_cost` fields:

- agent: **DS-Pro** coding agent
- user-sim: **Gemini-3.1-Pro** free-LLM sim (no graph constraint)
- trials: `trials_deepseek_pilot_10_task_r{1,2,3}/` → **10 tasks × 3 trials = 31 trials**
- coverage verdict: `intent_coverage_verdict.json` (schema v2, with effort)

Pipeline: [`eval/run_eval.py`](run_eval.py). Raw artefacts at
[`pipeline_logs/pilot_v051/`](../pipeline_logs/pilot_v051/) — JSON + per-trial join.

> **One model = one row's worth of leaderboard.** The design doc says
> *three blocks per model*. The pilot has one (agent, sim) cohort so the
> "leaderboard" is one row; the tables below are per-task within that row.

---

## Block 1 — Capability (effort-aware) **[P0]**

Now populated end-to-end. `effort_cost` is per-trial scalar (sum of
specificity tier weights over non-`{workflow, context, approval}` msgs),
computed deterministically in code from the v2 coverage prompt's
`trial_msg_specificity` field.

| metric | per-trial source | pilot value (cross-task mean over kept set) |
|---|---|---:|
| `effort_cost(trial)` distribution | `intent_coverage_verdict.trial_msg_specificity` → sum | **min=0, p25=3, median=11, p75=15, max=31** (31 trials) |
| `success@0` | `mean(judge ≥ 0.85 \| effort_cost ≤ 0)` | **0.500** (2 tasks qualify) |
| `success@3` | `mean(judge ≥ 0.85 \| effort_cost ≤ 3)` | **0.556** (3 tasks qualify) |
| `success@10` | `mean(judge ≥ 0.85 \| effort_cost ≤ 10)` | **0.667** (6 tasks qualify) |
| `effort_AUC` | area under per-task s-vs-k / 11 (None→0) | **0.221** (10 tasks, all-counted) |
| `mean_judge` (after step-2 filter) | step 2 cleaned mean | **0.756** |

### Per-task table

| task | n → surv | mean_judge | var_judge | effort_costs (kept) | s@0 | s@3 | s@10 | AUC |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `cli-task-2a55af` | 3 → 3 | 0.223 | 0.100 | [13, 31, 17] | — | — | — | 0.000 |
| `cli-task-2f5833` | 3 → 3 | 0.653 | 0.001 | [4, 8, 8] | — | — | 0.00 | 0.000 |
| `cli-task-46c118` | 3 → 3 | 0.840 | 0.011 | [2, 2, 2] | — | 0.67 | 0.67 | 0.545 |
| `cli-task-7e3475` | 3 → 2 | 0.920 | 0.001 | [0, 0] | **1.00** | 1.00 | 1.00 | **1.000** |
| `cli-task-f76665` | 3 → 2 | 0.985 | 0.000 | [21, 18] | — | — | — | 0.000 |
| `cluefin-task-52eab9` | 3 → 3 | 0.953 | 0.001 | [7, 15, 15] | — | — | 1.00 | 0.364 |
| `comfyui-frontend-autoscale-layout` | 4 → 4 | 0.897 | 0.002 | [15, 14, 14, 10] | — | — | 1.00 | 0.091 |
| `gemini-voyager-task-18a6ae` | 3 → 3 | 0.453 | **0.124** | [13, 13, 11] | — | — | — | 0.000 |
| `rudel-task-468289` | 3 → 3 | 0.800 | 0.009 | [0, 4, 0] | 0.00 | 0.00 | 0.33 | 0.212 |
| `sd-scripts-reg-image-dedup` | 3 → 3 | 0.830 | 0.030 | [14, 14, 23] | — | — | — | 0.000 |

Reading the AUC column:
- **`cli-task-7e3475` AUC = 1.000** — both surviving trials succeed at zero effort (the easiest task in the pilot).
- **`cli-task-46c118` AUC = 0.545** — sim always pays effort_cost=2, 2/3 succeed at that budget.
- **AUC = 0.000** rows are tasks where every surviving trial has `effort_cost > 10`, so no point on the [0, 10] success curve qualifies. The agent may still be succeeding (e.g., `cli-task-f76665` mean_judge=0.985!) — it just needed >10 effort to get there. **Block 1 doesn't reward correct-but-expensive solutions, by design.**

### Success-vs-effort curve (the AUC source)

Per-task `success@k` for `k = 0..10` (kept set only — surviving trials of step-2 filter):

| task | k=0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `cli-task-2a55af` | — | — | — | — | — | — | — | — | — | — | — |
| `cli-task-2f5833` | — | — | — | — | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 |
| `cli-task-46c118` | — | — | 0.67 | 0.67 | 0.67 | 0.67 | 0.67 | 0.67 | 0.67 | 0.67 | 0.67 |
| `cli-task-7e3475` | **1.00** | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| `cli-task-f76665` | — | — | — | — | — | — | — | — | — | — | — |
| `cluefin-task-52eab9` | — | — | — | — | — | — | — | 1.00 | 1.00 | 1.00 | 1.00 |
| `comfyui-frontend-autoscale-layout` | — | — | — | — | — | — | — | — | — | — | 1.00 |
| `gemini-voyager-task-18a6ae` | — | — | — | — | — | — | — | — | — | — | — |
| `rudel-task-468289` | 0.00 | 0.00 | 0.00 | 0.00 | 0.33 | 0.33 | 0.33 | 0.33 | 0.33 | 0.33 | 0.33 |
| `sd-scripts-reg-image-dedup` | — | — | — | — | — | — | — | — | — | — | — |

**Cross-task mean curve** (averaged across populated tasks only — gives the
"if a trial qualifies, how often does it succeed?" view, complementary to
the headline `effort_AUC_mean` which counts `None → 0`):

```
k:           0    1    2    3    4    5    6    7    8    9    10
mean s@k:   0.50 0.50 0.56 0.56 0.50 0.50 0.50 0.60 0.60 0.60 0.67
n_tasks:     2    2    3    3    4    4    4    5    5    5    6
```

ASCII curve:

```
  1.0 │                                                ●
  0.8 │
  0.6 │       ●    ●              ●    ●    ●
  0.4 │  ●    ●         ●    ●
  0.2 │
  0.0 │
      └───────────────────────────────────────────────────
       0    1    2    3    4    5    6    7    8    9   10   ← effort budget
```

Reading the curve:
- The agent is roughly capability-bound below k=7: ~50–55% of qualifying trials
  succeed regardless of small hint budget. Adding effort from 0→6 doesn't
  move the needle.
- A jump at k=7 (cluefin's trials at effort 15 don't qualify, but moving from
  k=6 to k=7 brings in cluefin's "succeeds at budget 15" trial — wait no,
  *qualify* means `effort_cost ≤ k`, so larger k brings in *more* trials).
  More precisely: at k=7 cluefin's lowest-effort kept trial (effort=7) becomes
  eligible, contributing 100% success → mean jumps to 0.60.
- The agent is reasonably **steerable**: success@10 (0.667) > success@0 (0.500)
  by 17 pp. Not a dramatic curve, but not flat either.

---

## Block 1' — Secondary effort metrics **[P1]**

| task | `min_effort_to_success` (P50) | `effort_per_matched_intent` mean | tier mix (count) |
|---|---:|---:|---|
| `cli-task-2a55af` | None (no kept trial succeeded) | 2.71 | vague=1 dir=8 diag=14 prsc=3 |
| `cli-task-2f5833` | None | 3.33 | vague=3 prsc=5 |
| `cli-task-46c118` | **2.0** | 1.00 | dir=3 prsc=3 |
| `cli-task-7e3475` | **0.0** | 0.00 | diag=1 prsc=6 (all `workflow`/`approval` kind) |
| `cli-task-f76665` | 19.5 | 3.00 | dir=4 diag=6 prsc=4 |
| `cluefin-task-52eab9` | 15 | 3.50 | vague=4 diag=3 prsc=8 |
| `comfyui-frontend-autoscale-layout` | 14 | 3.81 | vague=1 dir=1 diag=10 prsc=5 |
| `gemini-voyager-task-18a6ae` | 13 | 3.23 | vague=1 dir=5 diag=2 prsc=5 |
| `rudel-task-468289` | 4 | 0.67 | vague=1 prsc=6 |
| `sd-scripts-reg-image-dedup` | 18.5 | 2.83 | dir=5 diag=7 prsc=5 |

Reading:
- **`min_effort_to_success` P50** = "typical hint budget you'd need on this
  task to succeed". The two cheapest tasks: `cli-task-7e3475` (P50=0; the sim
  asks one diagnostic question then says "commit/push" — all of it free kinds
  or unnecessary) and `cli-task-46c118` (P50=2; the simple "is IsPaneDead
  valuable?" question is enough).
- **`effort_per_matched_intent`** is the sim-verbosity diagnostic from
  `eval_design.md` §Block 1'. Low values flag sims that fragment one oracle
  intent into many small msgs (denominator inflates). `cli-task-46c118` and
  `rudel-task-468289` show low `epmi` (1.0 / 0.67) — the sim is concise on
  these. `comfyui-frontend-autoscale-layout` at 3.81 is the most verbose
  relative to intents matched.

---

## Block 2 — Sim health (filter, not rank)

`overall_score` per trial across the 3 cohorts, plus what the **3-AND filter**
did with each row. **Used only to drop divergent trials before computing
Block 1 — never enters the rank itself.**

| task | r1 | r2 | r3 | filter action | reason |
|---|---:|---:|---:|---|---|
| `cli-task-2a55af` | 0.450 | 0.650 | 0.439 | keep all | spread < gap |
| `cli-task-2f5833` | 0.825 | 0.825 | 0.825 | keep all | identical |
| `cli-task-46c118` | 1.000 | 1.000 | 1.000 | keep all | identical |
| `cli-task-7e3475` | 0.700 | **0.495** | 0.700 | **drop r2** | rel ✓ · abs ✓ (0.495 < 0.50) · gap ✓ (0.205) |
| `cli-task-f76665` | **0.400** | 0.703 | 0.701 | **drop r1** | rel ✓ · abs ✓ (0.400 < 0.50) · gap ✓ (0.301) |
| `cluefin-task-52eab9` | 0.833 | 0.689 | 0.624 | keep all | all ≥ abs_floor |
| `comfyui-frontend-autoscale-layout` | 0.776 / 0.585 / 0.740 / 0.760 (4 cohorts) | | | keep all | r2 0.585 ≥ abs_floor |
| `gemini-voyager-task-18a6ae` | 0.886 | 0.626 | 0.744 | keep all | r2 ≥ abs_floor (§Pitfall) |
| `rudel-task-468289` | 0.853 | 0.812 | 0.902 | keep all | all ≥ abs_floor |
| `sd-scripts-reg-image-dedup` | 0.778 | 0.791 | 0.779 | keep all | σ ≈ 0 |

Filter parameters (matches `eval_design.md` §"Filter protocol (step 2)"):

```
SIGMA_K = 1.0   ABS_FLOOR = 0.50   MAGNITUDE_GAP = 0.10
drop ⇐ (o < median−σ) AND (o < 0.50) AND (median − o > 0.10)
```

**Summary**: 2 / 31 trials dropped (6.5%). Same two trials as the v0.5.0 run
— the v2 prompt didn't change the filter outcome, only added the effort
columns. (The `overall_score` values shifted by ≤0.15 because the v2 prompt
is slightly stricter on confidence assignment, but the filter decisions
held.)

### Preserved (textbook §Pitfall case)

`gemini-voyager-task-18a6ae` overalls = [0.886, 0.626, 0.744]; judges =
[0.86, 0.50, 0.00]. r2 is below the relative threshold but above the
abs_floor → 3-AND form preserves it. The 0.124 `var_judge` is **real agent
variance**, not sim noise. This is the disentanglement story working as
designed.

---

## Block 3 — Benchmark fidelity

Per-task QA signals. **Used to caveat / exclude tasks; never enters Block 1.**

| task | `judge_clean_testsh_delta` mean | empty-patch | judge warn | coverage warn |
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

Reading:
- `judge_clean_testsh_delta`: judge tends to be more lenient than `test.sh`
  (cluefin +0.45, comfyui +0.37 are the most generous). `|delta| > 0.30`
  flags the task for verifier-hygiene review.
- `empty_patch_rate = 0%` everywhere — every run produced a patch.
- `judge warn rate = 25.8%`: concentrated in `cli-task-7e3475` (100%) and
  `cli-task-2a55af` (66.7%) — both worth a separate audit.
- `coverage warn rate = 0%` (v2 prompt is clean — no `schema_warnings`
  triggered across all 31 trials in the new run).

---

## Headline — single-row leaderboard (this cohort)

| dimension | metric | value |
|---|---|---:|
| **Block 1** | `mean_judge_over_tasks` (after step-2 filter) | **0.756** |
| Block 1 | `success@0_mean` | **0.500** |
| Block 1 | `success@3_mean` | **0.556** |
| Block 1 | `success@10_mean` | **0.667** |
| Block 1 | `effort_AUC_mean` | **0.221** |
| **Block 1'** | `effort_per_matched_intent_mean` | **2.41** |
| Block 1' | tasks where any kept trial succeeded | **6 / 10** |
| **Block 2** | trials surviving filter | **29 / 31** (93.5%) |
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

1. **Multi-model leaderboard**. The pilot is one (agent, sim) cohort. Run
   a second agent (e.g., Sonnet, Opus, GLM) against the same sim and the
   same task set to produce a real *N*-row leaderboard.
2. **Tier-calibration audit**. The pilot is the first time the v2 prompt
   has run; do a quick eyeball pass on 5–10 high-effort trials to confirm
   the LLM is tier-classifying the way we'd expect. The §Q4 of
   `eval_design.md` flags collapsing 5→3 tiers if variance > 25% of
   cross-trial variance.
3. **Plot the curves**. The success-vs-effort curve table above is
   text-only; for the leaderboard we'd want a real chart (per-task small
   multiples + cross-task aggregate). Defer until we have ≥2 models to
   compare.
4. **`judge_warn_rate` audit** (carried over from v0.5.0): 25.8% is high;
   `cli-task-7e3475` (100%) and `cli-task-2a55af` (66.7%) first.

---

## Reproducing

End-to-end (steps 1+2+3 + aggregate):

```bash
python -m eval.run_eval \
    --trials-root trials_deepseek_pilot_10_task_r1 \
    --trials-root trials_deepseek_pilot_10_task_r2 \
    --trials-root trials_deepseek_pilot_10_task_r3 \
    --tasks-root harbor_tasks \
    --output-dir pipeline_logs/pilot_v051 \
    --model-tag "DS-Pro + Gemini-3.1-Pro user-sim (pilot v0.5.1)"
```

Aggregate-only (re-uses existing verdicts):

```bash
python -m eval.run_eval \
    --trials-root trials_deepseek_pilot_10_task_r1 \
    --trials-root trials_deepseek_pilot_10_task_r2 \
    --trials-root trials_deepseek_pilot_10_task_r3 \
    --tasks-root harbor_tasks \
    --output-dir pipeline_logs/pilot_v051 \
    --only-aggregate
```

Outputs:
- [`pipeline_logs/pilot_v051/eval_report.json`](../pipeline_logs/pilot_v051/eval_report.json) — per-task aggregate
- [`pipeline_logs/pilot_v051/eval_report.md`](../pipeline_logs/pilot_v051/eval_report.md) — auto-rendered summary
- [`pipeline_logs/pilot_v051/per_trial.json`](../pipeline_logs/pilot_v051/per_trial.json) — 31 trials, joined view (with effort_cost)
