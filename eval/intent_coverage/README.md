# `eval/intent_coverage` — LLM-judged user-sim intent coverage

Companion to [`eval/correctness/`](../correctness/). `correctness/` answers "did the agent produce the right patch?"; this package answers **"did the user simulator actually reflect the original human user's intentions?"** The two together let us disentangle agent capability from sim noise when reporting cohort-level scores.

Closely related design docs:
- [`analysis/JUDGE_VS_TESTSH_PILOT.md`](../../analysis/JUDGE_VS_TESTSH_PILOT.md) — 10-task × 3-cohort qualitative pilot we calibrate against
- [`analysis/eval_metric.md`](../../analysis/eval_metric.md) — the disentanglement metric taxonomy this fits into

---

## What's in the box

```
eval/intent_coverage/
├── extract_intents.py        # Stage 1 — per-task, run once, cached
├── coverage_one.py           # Stage 2 — per-trial judge
├── run_batch.py              # Stage 3 — async batch wrapper
└── prompts/
    ├── extract_intents_system.md
    └── coverage_system.md
```

Per-task artifact (committed alongside each task):

```
harbor_tasks/<task>/oracle_intents.json   # cache of stage 1 output
```

Per-trial artifact:

```
trials_*/<trial>/intent_coverage_verdict.json
```

---

## V2 pipeline — three stages

### Stage 1 — `extract_intents.py` (one-time per task, cached)

Reads `harbor_tasks/<task>/oracle_session.jsonl` (the canonical human session) and decomposes the post-instruction user turns into atomic **intent units**.

Why decompose? Long plan documents (the `cli-task-46c118` PR-review plan, the multi-paragraph turn in `gemini-voyager`) carry several independent intents per turn. Treating them as one atomic match would lose partial-coverage signal. The extractor runs Opus 4.6 with `temperature=0` against the prompt in `prompts/extract_intents_system.md`, then validates and writes `oracle_intents.json`.

Filter rules applied upstream (in `load_oracle_user_turns`):
- skip turn 0 (= `instruction.md` content, delivered by Harbor, not the sim)
- skip `[Request interrupted by user for tool use]` markers
- skip continuation markers (`This session is being continued ...`)
- skip turns shorter than 10 chars (`ok`, `yes`, `wait` — already filtered)

Output schema (one entry per atomic intent):

```jsonc
{
  "intent_id": 0,
  "source_turn": <int>,                 // which oracle turn it came from
  "intent_kind": "request|correction|question|verification|workflow|context",
  "text": "<≤25 word paraphrase>",
  "verbatim_excerpt": "<≤80 char span>"
}
```

Caching: re-running on a task with an existing `oracle_intents.json` is a no-op. Pass `--force` to refresh after editing the oracle.

```bash
python -m eval.intent_coverage.extract_intents \
    --task-dir harbor_tasks/cli-task-2a55af
```

### Stage 2 — `coverage_one.py` (per trial)

For one trial, this:

1. Loads cached intents (auto-extracts if missing)
2. Loads sim messages from `<trial>/agent/episode-*/user_decision.json` (only `has_message=true` ones)
3. Sends `(intents, trial_msgs)` to Opus 4.6 with the prompt in `prompts/coverage_system.md`
4. Gets back **only a match table** — `per_intent` (matched_trial_idx + match_confidence + rationale) and `unmatched_trial_msgs` (category + rationale)
5. Computes aggregate scores **in code, not by the LLM** (see formulas below)

The LLM does pattern-matching; arithmetic is deterministic. This is the key V2-over-V1 design choice.

```bash
python -m eval.intent_coverage.coverage_one \
    --trial-dir trials_judge_cmp_r1/cli-task-2a55af__LXqASZW \
    --task-dir  harbor_tasks/cli-task-2a55af
```

Output (`<trial>/intent_coverage_verdict.json`):

```jsonc
{
  "schema_version": 1,
  "n_intents": 18,
  "n_trial_msgs": 5,
  "match_table": {
    "per_intent": [
      {"intent_id": 0, "matched_trial_idx": null, "match_confidence": 0.0,
       "rationale": "No trial message addresses proceeding with fix 1"},
      {"intent_id": 1, "matched_trial_idx": 0, "match_confidence": 0.9,
       "rationale": "trial msg 0 verbatim asks for the proposal on the ending fix"},
      …
    ],
    "unmatched_trial_msgs": [
      {"trial_idx": 4, "category": "task-relevant-extra",
       "rationale": "asks about extractSessionIDFromMetadata; deeper than oracle"}
    ]
  },
  "coverage_rate":     0.29,
  "weighted_coverage": 0.28,
  "scope_precision":   1.00,
  "overall_score":     0.53,
  "judge_model": "anthropic/claude-opus-4-6",
  "elapsed_sec": 4.1,
  "schema_warnings": []
}
```

### Stage 3 — `run_batch.py` (cohort-level wrapper)

Plan-file driven, asyncio.Semaphore concurrency control. Mirrors `eval/correctness/run_batch.py` shape so the two evaluators have parallel CLIs.

```bash
python -m eval.intent_coverage.run_batch \
    --plan pipeline_logs/intent_coverage_plan.json \
    --model anthropic/claude-opus-4-6 \
    --workers 5 \
    --summary pipeline_logs/intent_coverage_summary.json
```

Plan file shape:

```jsonc
[
  {"trial_dir": "<abs>", "task_dir": "<abs>",
   "out_name": "intent_coverage_verdict.json"},
  …
]
```

---

## Score formulas (computed in code)

```python
MATCH_CONFIDENCE_FLOOR_FOR_COVERED = 0.5
W_COVERAGE  = 0.65
W_PRECISION = 0.35

coverage_rate     = matched intents (conf ≥ 0.5) / n_intents
weighted_coverage = mean(match_confidence over all intents)
scope_precision   = unique trial idxs used as a match / n_trial_msgs
overall_score     = W_COVERAGE * weighted_coverage + W_PRECISION * scope_precision
```

Edge cases:
- `n_intents = 0` (oracle has no follow-up) — `coverage_rate = weighted_coverage = 1.0`; `scope_precision = 0` if any trial msg fired (means the sim invented intents) else `1.0`
- `n_trial_msgs = 0` (sim silent) — `scope_precision = 0`
- a single trial msg matching multiple intents counts ONCE in `scope_precision` (deliberate — discourages credit-stuffing)

Weight balance (0.65 / 0.35): coverage matters more than precision because **missing an oracle intent is a sim regression**, while a sim adding a legitimate extra question is fine.

---

## How to remove outlier cohorts to disentangle sim variance

This is the production use-case the pipeline was built for.

### Setup — what we observe

For each `(task, model)` cohort run, we have:
- `judge_score` per trial — from `eval/correctness/` (the patch-correctness judge)
- `overall_score` per trial — from this package (the sim-coverage judge)

Across N cohorts of the same task, `judge_score`'s standard deviation σ has **two components**:

```
σ²(judge_score)  =  σ²(agent given the sim path)  +  σ²(sim path)
```

`σ_agent` is what we want to measure (real model capability noise). `σ_sim` is what we want to *remove* (different sim trajectories pushing the agent into different solution spaces).

Intent coverage's `overall_score` is a direct proxy for σ_sim: a cohort with low coverage drifted off the original user's intents, contributing to σ_sim.

### Algorithm — filter outlier cohorts

```python
def disentangle_correctness(task_cohorts, sigma_k=1.0, abs_floor=0.50, magnitude_gap=0.10):
    """
    task_cohorts: list of dicts, each having
        - 'overall_score' from intent_coverage_verdict.json
        - 'judge_score'   from judge_verdict.json
    Returns: filtered subset + per-cohort outlierness + diagnostics
    """
    overalls = [c['overall_score'] for c in task_cohorts]
    median   = statistics.median(overalls)
    sd       = statistics.pstdev(overalls)
    threshold_relative = median - sigma_k * sd
    threshold = max(threshold_relative, abs_floor)

    kept, dropped = [], []
    for c in task_cohorts:
        # Drop iff: clearly low AND meaningful gap from median
        is_outlier = (
            c['overall_score'] < threshold
            and (median - c['overall_score']) > magnitude_gap
        )
        (dropped if is_outlier else kept).append(c)

    if not kept:                       # safety: never drop everything
        kept = [min(task_cohorts, key=lambda c: -c['overall_score'])]
        dropped = [c for c in task_cohorts if c not in kept]
    return kept, dropped
```

Three guards on the drop rule:
1. **relative**: `overall_score < median − 1·σ`
2. **absolute floor**: `overall_score < 0.50` (no point dropping cohorts that are healthy in absolute terms even if they're statistically below the median — that's the gemini-voyager pitfall, see §pitfall below)
3. **magnitude gap**: `(median − overall_score) > 0.10` (avoids dropping when σ is tiny — sd-scripts has σ_overall ≈ 0 so a 0.01 dip should not trigger a drop)

All three must hold to drop. Default thresholds are tuned to the §Q1 pilot — adjust if your cohorts have systematically different distributions.

### Report after filtering

For each task, **report both numbers** in parallel — never just one:

```
task: cli-task-2a55af
  n_cohorts: 3
  intent_coverage overall: [0.53, 0.64, 0.44]
  filter: drop r3 (overall=0.44, < median 0.53 by 0.09 + below abs_floor 0.50)
  judge_score all:        [0.00, 0.00, 0.67]  σ=0.316
  judge_score filtered:   [0.00, 0.00]        σ=0.000   ← disentangled agent variance
  rationale: r3 went off-script (oracle covered 33%); patch luck doesn't reflect agent capability
```

### Pitfall — when filtering would WORSEN things

`gemini-voyager-task-18a6ae` is the textbook negative example. V2 intent_coverage flags r2 as the weakest cohort (overall = 0.63, below median 0.76). Looks like a candidate to drop.

**Don't.** The judges are `[0.86, 0.50, 0.00]`. r2's `judge_score = 0.50` is the *middle* value. Dropping r2 leaves `[0.86, 0.00]` → σ goes from 0.353 to **0.430** (worse).

What's actually happening: sim variance here is small (overall_σ = 0.11 across cohorts), but agent variance is huge (judge_σ = 0.35). The filter rule above correctly leaves this case alone because:
- r2's overall = 0.63 > `abs_floor = 0.50` → don't drop
- median − r2 = 0.13 just barely exceeds magnitude_gap = 0.10, but absolute floor saves us

The cohort variance you're seeing IS the disentangled agent variance you came for. Don't try to hide it.

---

## Validation — against `JUDGE_VS_TESTSH_PILOT.md` §Q1

The pilot defined a 4-bucket qualitative classification of cohort-level sim behavior:

> 1 IDENTICAL · 1 front-converged · 5 partial-converge · 3 DIVERGENT  
> (10 tasks total, 3-cohort runs)

V2 gives a continuous score; here's how it lines up.

### Quantitative table — all 31 trials, Opus 4.6 match-table

| task | n_intents | r1 overall / cov / scope | r2 overall / cov / scope | r3 overall / cov / scope | overall σ | judge σ (pilot §Q2) |
|---|---|---|---|---|---|---|
| `cli-task-46c118` | 2 | 1.00 / 1.00 / 1.00 | 1.00 / 1.00 / 1.00 | 1.00 / 1.00 / 1.00 | **0.00** | 0.107 |
| `cli-task-2f5833` | 2 | 1.00 / 1.00 / 1.00 | 0.88 / 1.00 / 0.67 | 0.88 / 1.00 / 0.67 | 0.06 | 0.026 |
| `comfyui-frontend-autoscale-layout` | 5 | 0.78 / 0.80 / 0.80 | 0.79 / 0.80 / 0.80 | 0.73 / 0.60 / 1.00 | 0.03 | 0.009 |
| `sd-scripts-reg-image-dedup` | 7 | 0.76 / 0.86 / 0.80 | 0.77 / 0.86 / 0.80 | 0.76 / 0.86 / 0.71 | **0.00** | 0.175 |
| `cli-task-4a9dde` | 23 | 0.60 / 0.43 / 1.00 | 0.73 / 0.70 / 0.93 | 0.63 / 0.52 / 0.92 | 0.06 | — (empty patches) |
| `cli-task-2a55af` | 18 | 0.53 / 0.28 / 1.00 | 0.64 / 0.56 / 0.85 | 0.44 / 0.33 / 0.75 | 0.08 | **0.316** |
| `cluefin-task-52eab9` | 4 | 0.82 / 0.75 / 0.80 | 0.67 / 0.75 / 0.60 | 0.63 / 0.75 / 0.60 | 0.08 | 0.033 |
| `gemini-voyager-task-18a6ae` | 5 | 0.90 / 1.00 / 0.80 | 0.63 / 0.60 / 0.75 | 0.76 / 0.80 / 0.75 | 0.11 | **0.353** |
| `cli-task-f76665` | 10 | 0.41 / 0.10 / 1.00 | 0.75 / 0.70 / 1.00 | 0.70 / 0.60 / 1.00 | **0.15** | 0.097 |
| `rudel-task-d64e5a` | 3 | 0.39 / 0.33 / 0.50 | 1.00 / 1.00 / 1.00 | 0.91 / 1.00 / 0.75 | **0.27** | — (empty patches) |

Aggregate: 31 trials, `overall_score` mean = 0.75, σ = 0.17.

### Quantitative ↔ qualitative — how V2 numbers map onto §Q1 buckets

| §Q1 bucket | tasks | V2 reading |
|---|---|---|
| IDENTICAL | `cli-task-46c118` | All cohorts overall = 1.00; σ_overall = 0. Perfect alignment with §Q1's "IDENTICAL" label. |
| front-converged | `cluefin-task-52eab9` | Three cohorts cluster 0.63–0.82; weakest cohort coverage low because scope_precision drops on later turns. Matches §Q1's "front matches, later diverges". |
| partial-converge | `cli-task-2a55af`, `cli-task-2f5833`, `comfyui-frontend...`, `rudel-task-d64e5a`, `sd-scripts...` | overall σ spans 0.00 (sd-scripts/2f5833 — very tight) to 0.27 (rudel — wide). §Q1's "partial-converge" label can't distinguish these; **V2 reveals the continuous spectrum.** |
| DIVERGENT | `cli-task-4a9dde`, `cli-task-f76665`, `gemini-voyager-task-18a6ae` | σ_overall 0.06–0.15. Different cohorts opened differently but cover overlapping intents; pilot's "DIVERGENT" label is fuzzy on these (see §Q1 §3 pilot disagreement). V2 detects the spread but doesn't necessarily call it DIVERGENT — semantically the cohorts shared scope. |

**Where V2 actually adds value beyond §Q1**:
- `sd-scripts-reg-image-dedup` and `cli-task-2f5833`: §Q1 calls both "partial-converge" but V2 σ ≈ 0 — these cohorts are effectively IDENTICAL in intent coverage. The §Q1 label was over-cautious.
- `cli-task-2a55af` and `rudel-task-d64e5a`: same §Q1 "partial-converge" label, but V2 σ = 0.08 vs 0.27 — rudel has a real cohort outlier that §Q1's category misses.
- `gemini-voyager`: §Q1 said "DIVERGENT" by opening-msg disagreement, but V2 finds overall σ only 0.11 — cohorts cover the same 5 intents in different orderings. **The variance §Q1 attributed to sim is actually agent variance** (visible in judge σ = 0.353).

This is the headline V2 win: continuous score + per-intent matching disambiguates cases that the categorical §Q1 classifier conflated.

### Before / after outlier removal — σ_judge per task

Using the filter rule above (k=1.0, abs_floor=0.50, magnitude_gap=0.10):

| task | cohorts dropped | judge σ all-cohort | judge σ filtered | Δσ | regime |
|---|---|---|---|---|---|
| `cli-task-46c118` | (none) | 0.107 | 0.107 | 0 | agent variance only |
| `cli-task-2f5833` | (none) | 0.026 | 0.026 | 0 | tight; no filter needed |
| `cli-task-2a55af` | **r3 (overall 0.44)** | 0.316 | **0.000** | **−0.316** | sim outlier — major win |
| `cli-task-f76665` | **r1 (overall 0.41)** | 0.097 | **0.015** | **−0.082** | sim outlier — single short msg |
| `cluefin-task-52eab9` | (none — r3=0.63 above floor) | 0.033 | 0.033 | 0 | already tight |
| `comfyui-frontend...` | (none — σ too small) | 0.009 | 0.009 | 0 | tight |
| `sd-scripts-reg-image-dedup` | (none — σ too small) | 0.175 | 0.175 | 0 | **agent variance unhidden** |
| `gemini-voyager...` | (none — r2 above floor) | 0.353 | 0.353 | 0 | **correctly preserved** (pure agent variance) |
| `cli-task-4a9dde` / `rudel-task-d64e5a` | — | n/a (empty patches) | — | — | — |

**Aggregate σ_judge across 8 tasks with measurable judge data**:

```
all cohorts:  mean σ_judge = 0.140
filtered:     mean σ_judge = 0.090     (35% reduction, 2 cohorts dropped out of 24)
```

The filter:
- Removes 2 truly-divergent sim cohorts (cli-task-2a55af r3, cli-task-f76665 r1)
- Leaves untouched the cases where high σ is real agent variance (gemini-voyager, sd-scripts)

This is the *disentangled* number we report — σ_judge after sim-outlier removal is a tighter estimate of σ_agent, the metric we actually care about for model comparison.
