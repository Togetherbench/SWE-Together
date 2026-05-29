# Eval Design

**Scope**: how we measure model performance on this benchmark， companion to [`correctness/METHOD_AND_PILOT.md`](correctness/METHOD_AND_PILOT.md), [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md), and [`user_behavior/METHOD_AND_PILOT.md`](user_behavior/METHOD_AND_PILOT.md).

---

## What we did 

Per trial, four artefacts already land on disk:

| artefact | producer | what it captures |
|---|---|---|
| `verifier/reward.txt` (+ `reward.replay.txt`) | Harbor / [`correctness/clean_replay.py`](correctness/clean_replay.py) | `test.sh` reward, polluted-sandbox + clean-replay |
| `judge_verdict.json` | [`correctness/run_batch.py`](correctness/run_batch.py) — Phase 2 scoring against the per-task frozen rubric (Phase 1 output, see below) | agentic judge marks each rubric goal `met:true/false`; `judge_score = sum(weight × met)` mechanically derived |
| `intent_coverage_verdict.json` | [`intent_coverage/coverage_one.py`](intent_coverage/coverage_one.py) | LLM match-table between sim msgs and oracle intents — `overall_score`, `coverage_rate`, `scope_precision`, plus `effort_cost` / `per_tier_count` / `per_kind_count` (§B) |
| `user_behavior_verdict.json` | [`user_behavior/behavior_one.py`](user_behavior/behavior_one.py) | no-LLM panel of sim behavior — `intervention_count`, `per_action_count`, `hard_cap_abandon` (locally computed) plus `effort_cost` / `per_tier_count` / `per_kind_count` (passthrough from intent_coverage — single source of truth) |

Per task, two cached artefacts (each produced once, frozen, re-used across all cohorts):

| artefact | producer | what it captures |
|---|---|---|
| `oracle_intents.json` | [`intent_coverage/extract_intents.py`](intent_coverage/extract_intents.py) | atomic intents from the canonical human session, with `intent_kind` |
| `canonical_goals.json` | [`correctness/generate_task_goals.py`](correctness/generate_task_goals.py) — **Phase 1** of the two-phase correctness judge | weighted completeness goals derived from the task spec + oracle patch. Frozen rubric: same goals + same weights apply to every (cohort, trial) of this task, so judge_score deltas reflect agent quality rather than per-trial decomposition noise. Phase 2 (per-trial) scoring against this rubric is mechanically deterministic given `met:true/false` per goal |

The pilot (10 tasks × 3 cohorts, 31 trials) lives at [release v0.5.0](https://github.com/Togetherbench/SWE-Together/releases/tag/v0.5.0).

`user_behavior_verdict.json` reads `intent_coverage_verdict.json` opportunistically — when the §Proposal schema extension (`trial_msg_specificity` + `effort_cost`) has landed, tier/effort fields are populated; otherwise it gracefully degrades and just reports the file-I/O metrics (action counts, intervention count, hard-cap abandon). See [`user_behavior/METHOD_AND_PILOT.md`](user_behavior/METHOD_AND_PILOT.md#relationship-to-the-proposal-schema-extension).

---

## Core challenge — the simulator stability vs. realism trade-off

A user simulator sits between the benchmark and the coding agent. To rank agents fairly we need the sim to be **stable** — the same task, replayed against the same agent, should land in roughly the same place each time, or the leaderboard is measuring sim variance instead of agent capability. But a stable sim is an unrealistic sim: real users do not behave identically across sessions. They give a strong agent a brief instruction and step back; they repeatedly re-anchor a weaker agent with `file:line` hints, code snippets, and "no, do X instead"; sometimes they give up.

The two pressures pull in opposite directions:

- **Stability** ⇒ the sim should be deterministic-ish, intent-anchored, agent-blind.
- **Realism**  ⇒ the sim should adapt to the agent it's talking to, which is exactly what makes runs non-iid.

We do **not** resolve this by picking one. We accept that the sim is both an instrument and an actor, and design the eval to **separate sim-induced variance from agent-induced variance** rather than collapse them. The philosophy:

> Remove as much **user-simulator variance** as possible from the agent's correctness measurement, while preserving as much **user-simulator realism** as possible in how the trial actually unfolds.

### Three-step protocol per (task, agent)

1. **Replicate.** Run the (task, agent, sim) trial **k times**, k ∈ {3, 5}. Judge each trial's final patch with [`eval/correctness`](correctness/) → per-trial `judge_score`.

   **Step 1 is internally two phases**, orchestrated by [`correctness/run_batch.py`](correctness/run_batch.py):
   - **Phase 1 — frozen rubric, run once per task.** [`correctness/generate_task_goals.py`](correctness/generate_task_goals.py) reads the task spec + oracle patch and emits `harbor_tasks/<task>/canonical_goals.json` (weighted completeness goals). Cached on disk; re-used across every cohort × replicate of this task. Same rubric for every agent ⇒ judge_score deltas reflect agent quality rather than per-trial decomposition noise.
   - **Phase 2 — per-trial scoring, run k times per task per agent.** Reads the frozen rubric, asks the judge to mark each goal `met:true/false` against the agent's patch, then computes `judge_score = sum(weight × met)` mechanically. Writes `judge_verdict.json` per trial.

   `run_batch.py` auto-runs Phase 1 for any task in the plan that's missing a rubric (one-time, cached) before dispatching the Phase 2 sandbox pool. The legacy single-pass judge ([`correctness/judge_one.py`](correctness/judge_one.py)) is deprecated.
2. **Clean.** For each of the k trials, measure **intent divergence** via [`eval/intent_coverage`](intent_coverage/) (`overall_score` / `coverage_rate` / `scope_precision`). Drop the trial when divergence is large or coverage is low (i.e. the sim wandered off the oracle's task). Report `mean(judge_score)` and `var(judge_score)` over the **cleaned** subset, plus the number of trials that survived the filter. **Filter protocol** — see §"Filter protocol (step 2)" below.
3. **Characterize.** On the surviving trials, run a panel of **user-behavior measurements** — user effort (§"Proposal" below), per-tier specificity distribution, intervention count, abandonment / give-up rate, etc. These are not aggregated into the correctness number; they sit alongside it so a reader can see *how* the sim got the agent to the score it got. Implementation lives at [`eval/user_behavior/`](user_behavior/).

### Filter protocol (step 2)

**Same algorithm** as [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md#algorithm--filter-outlier-cohorts) `disentangle_correctness()`, applied **within-cohort** instead of cross-cohort. There the cohorts are different sims for the same task; here the "cohorts" are k replicate trials of a single (task, agent, sim). The three guards — relative spread, absolute floor, magnitude gap — and their default values are identical, so this is one filter operating at two granularities, not two filters.

```python
import statistics

SIGMA_K       = 1.0   # drop trials more than 1σ below the median
ABS_FLOOR     = 0.50  # never drop a trial whose overall_score is already healthy
MAGNITUDE_GAP = 0.10  # never drop on noise — gap to median must exceed this

def clean_trials(trials):
    """trials: list of {overall_score, judge_score, ...} dicts.

    3-AND form: all three guards are explicit AND-clauses on overall_score.
    abs_floor is a TRUE guard ("if a trial is healthy in absolute terms,
    never drop it") — not a floor on the threshold via max(), which would
    only kick in when σ is small. This matches the §"Pitfall — gemini-voyager"
    expected behavior in intent_coverage/METHOD_AND_PILOT.md.
    """
    overalls = [t["overall_score"] for t in trials]
    median   = statistics.median(overalls)
    sd       = statistics.pstdev(overalls)
    relative_threshold = median - SIGMA_K * sd

    kept, dropped = [], []
    for t in trials:
        o = t["overall_score"]
        # Drop iff all three guards hold (AND): relative + absolute + magnitude.
        is_outlier = (
            o < relative_threshold              # ① relative
            and o < ABS_FLOOR                   # ② absolute (true AND guard)
            and (median - o) > MAGNITUDE_GAP    # ③ magnitude gap
        )
        (dropped if is_outlier else kept).append(t)

    if not kept:                                      # safety: never drop everything
        best = max(trials, key=lambda t: t["overall_score"])
        kept, dropped = [best], [t for t in trials if t is not best]
    return kept, dropped
```

Three guards, **all must hold to drop** (AND — matches the existing protocol verbatim):
1. **relative**: `overall_score < median − 1·σ`
2. **absolute floor**: `overall_score < 0.50` — protects healthy outliers from a low-σ cohort being dropped for no good reason. This is the `gemini-voyager` pitfall (see [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md#pitfall--when-filtering-would-worsen-things))
3. **magnitude gap**: `(median − overall_score) > 0.10` — avoids dropping when σ is tiny (e.g. sd-scripts has σ ≈ 0 so a 0.01 dip should not trigger)

`coverage_rate` and `scope_precision` are not separate filter inputs — they roll up into `overall_score` (the 0.65·weighted_coverage + 0.35·scope_precision composite in [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md#score-formulas-computed-in-code)), so the single `overall_score` threshold is the load-bearing signal. The same is true cross-cohort.

After filtering, report **four numbers** per (task, agent):

```
n_total      = k                                  # replicates we started with
n_surviving  = len(kept)                          # passed the filter
mean_judge   = mean(t.judge_score for t in kept)  # cleaned correctness number
var_judge    = pvariance(t.judge_score for t in kept)
```

Never collapse `n_surviving` into the headline — a low survival count is itself a signal that the sim couldn't keep itself on-task for this (task, agent) pair. Report it alongside, the way `intent_coverage`'s outlier filter reports `dropped` separately from `kept`.

Default thresholds (`SIGMA_K`, `ABS_FLOOR`, `MAGNITUDE_GAP`) are the §Q1 pilot calibration. **If you change them, change them in [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md#algorithm--filter-outlier-cohorts) too** — the two filters must stay in sync; one diverging would mean a trial that's an outlier within its replicate set isn't an outlier across cohorts (or vice versa) for arbitrary reasons.

This is what the three blocks below operationalize: Block 1 is the cleaned correctness number with effort as a second axis; Block 2 is the sim-divergence filter (the cleaning step itself); Block 3 is benchmark fidelity. **No composite score across blocks.**

---

## Why we need a third metric

`judge_score` measures **what the agent produced**. `intent_coverage.overall_score` measures **whether the sim covered the right ground**. Neither measures **how much the sim handed to the agent** — i.e. user effort.

Without a user-effort axis the leaderboard cannot distinguish:
- agent A that nails the task on the first vague message
- agent B that needs a `file:line` + code snippet before producing the same patch

The graph-era plan handled this by summing `correction_specificity` over fired nodes. Post-graph we measure the same thing directly against the trial's sim messages.

---

## Proposal — user effort as a per-trial scalar

### A. Schema extension (one prompt, no new stage)

Extend [`intent_coverage/prompts/coverage_system.md`](intent_coverage/prompts/coverage_system.md) to emit, alongside the existing `match_table`, a per-trial-message specificity row:

```jsonc
{
  "match_table": { ... unchanged ... },
  "trial_msg_specificity": [
    {
      "trial_idx": 0,
      "tier": "vague | directional | diagnostic | prescriptive | patch_level",
      "kind_hint": "request | correction | question | verification | workflow | context | approval",
      "rationale": "<≤25 words>"
    }
  ]
}
```

The coverage judge already reads every trial msg in full to build the match table; adding one structured field is near-zero marginal cost.

**V2 principle preserved**: the LLM does pattern-matching only. All arithmetic (effort_cost, success@k, AUC) is computed in code in `coverage_one.py`.

### B. Effort formula (computed in code)

```python
SPECIFICITY_WEIGHTS = {
    "vague":         1,   # "this seems broken"
    "directional":   2,   # "look at the import section"
    "diagnostic":    3,   # "you're using np.load instead of zipfile-stream read"
    "prescriptive":  4,   # "replace np.load with zipfile.ZipFile.open"
    "patch_level":   5,   # full diff / near-verbatim code
}

FREE_KINDS = {"workflow", "context", "approval"}  # commit/push/ok/continue cost 0

def effort_cost(verdict) -> int:
    return sum(
        SPECIFICITY_WEIGHTS[m["tier"]]
        for m in verdict["trial_msg_specificity"]
        if m["kind_hint"] not in FREE_KINDS
    )
```

Written to `intent_coverage_verdict.json` as a top-level `effort_cost` field, parallel to `overall_score`.

### C. Where to source `kind_hint`

A trial msg that matches an oracle intent inherits `intent_kind` from `oracle_intents.json` via the match_table (free, deterministic). Only unmatched trial msgs need the judge to classify on the fly. This both saves LLM output tokens and prevents drift between intent_coverage's notion of "this msg = oracle intent 3" and effort's notion of "this msg is a request".

---

## Leaderboard structure

Three blocks per model. **No composite score** across blocks (per `eval_metric.md` §"Non-Goals").

### Block 1 — Capability (effort-aware) **[P0]**

| metric | formula | answers |
|---|---|---|
| `effort_cost(trial)` | §B | how much hint+task-spec the sim revealed in this trial |
| `success@k(task, model)` for k ∈ {0, 3, 10} | `mean(judge_score ≥ 0.85 over trials with effort_cost ≤ k)` | model's capability curve under different effort budgets |
| `effort_AUC(model)` | area under success-vs-effort / `max_k`, normalised to [0, 1] | one number summarising **capability under effort-penalty**: higher AUC means the agent succeeds at smaller cumulative-effort budgets. See §"What effort actually measures" below — `effort_cost` mixes *task-design intrinsic complexity* (the original human session needed N substantive turns to unfold the task) and *agent responsiveness* (a weak agent additionally provokes more corrections). Cross-cohort comparison on the same task suite is fair because intrinsic complexity cancels; absolute AUC across benchmarks is not directly comparable. |

```python
SUCCESS_THRESHOLD = 0.85  # judge_score

def success_at_k(replicates, k):
    eligible = [r for r in replicates if r.effort_cost <= k]
    if not eligible: return None
    return mean(r.judge_score >= SUCCESS_THRESHOLD for r in eligible)

def effort_auc(replicates, max_k=10):
    curve = [success_at_k(replicates, k) or 0 for k in range(max_k + 1)]
    return sum(curve) / (max_k + 1)
```

Reading the curve (effort-penalty framing — every additional turn of revealed task spec / correction costs):
- `success@0` = trial reached its final state with **zero substantive sim messages**, which means *both* the agent didn't need correction AND the task happened to be specified well enough in the first user message alone. On a multi-turn benchmark where most tasks are deliberately not front-loaded, success@0 is usually small.
- `success@3` = trial finished with at most ~one diagnostic-tier user turn of effort. Strong agent + well-bounded task.
- `success@10` = trial needed the full multi-turn conversational unfolding. Acceptable for tasks intrinsically designed across many turns; signals weakness only if the agent really got stuck for the same task that other agents resolved at lower k.

A strong agent has high `success@k` at low k *for tasks designed to unfold quickly*, and follows the Oracle curve closely *for tasks designed to unfold over many turns*. The curve never measures "ability to use hints well" — it measures *how much effort the trial accumulated to succeed*.

### What effort actually measures (and what it doesn't)

The user simulator drives this benchmark by **progressively revealing the task across turns** — `instruction.md` is only the first user message, and the full requirements only emerge as the sim sends follow-ups (see [`harbor_tasks/<task>/user_simulation_prompt.md`](../harbor_tasks/) — typically 10–20 substantive turns per task). `effort_cost` is therefore a mixed signal:

1. **Task-design intrinsic complexity** — even the Oracle agent (a perfectly-replayed human canonical solution) requires `effort_oracle` turns to reach 0.85 on a given task, because the task spec itself wasn't ready at turn 0. On the pilot10 curve the Oracle line tops out at AUC ≈ 0.83 with success only reaching 100% near k ≈ 8, which is the task suite's intrinsic effort floor.
2. **Agent responsiveness penalty** — for a given task, a weaker agent provokes additional sim correction turns (sim repeats, restates, drills down) on top of the task-design baseline. This is the "hint penalty" the prior framing isolated.

Both components combine into the single `effort_cost` we report. Implications:

- **Same task, different cohorts**: differences in `effort_cost` reflect (2) only. Comparison is fair.
- **Across tasks**: differences in `effort_cost` reflect both (1) and (2). Hard to attribute.
- **Tasks where `effort_oracle` is small (≤ 2)**: the task is essentially single-turn. These should be audited and ideally pruned — see CLAUDE.md §"Multi-turn gap".
- **Tasks where `effort_oracle` is large (≥ 10)**: the task is genuinely conversational. A model failing at low k here is doing the *expected* thing; failure judgment should be relative to Oracle, not absolute.

For benchmark hygiene, the Oracle's per-task `effort_cost` floor is the right reference. Cohort `effort_AUC` is best read **relative to Oracle's AUC** on the same task suite, not as an absolute number.

### Block 1' — secondary effort metrics **[P1]**

| metric | formula | use |
|---|---|---|
| `min_effort_to_success(task, model)` P50 | `median(min(r.effort_cost) over r with judge_score ≥ 0.85)` | "typical hint budget you need per task" |
| `effort_per_matched_intent` | `effort_cost / matched_intents` | sim health check — if sim fragments one oracle intent into many small msgs, per-intent cost drops; flags sim verbosity |

### Block 2 — Sim health (filter, not rank)

`intent_coverage.overall_score` stays in its existing role: feed the Stage 4 disentangle filter (see [`intent_coverage/METHOD_AND_PILOT.md`](intent_coverage/METHOD_AND_PILOT.md) §"How to remove outlier cohorts"). Drop sim-divergent cohorts before computing Block 1, never let it enter ranking directly.

### Block 3 — Benchmark fidelity

- `judge_clean_testsh_delta` per task — QA signal on `test.sh` hygiene (see [`correctness/METHOD_AND_PILOT.md`](correctness/METHOD_AND_PILOT.md) §1)
- Empty-patch rate per cohort
- Schema-warning rate on judge / coverage verdicts

Used to caveat or exclude tasks; never enters Block 1.

---

## Block separation — why `effort_cost` and `overall_score` are orthogonal

| metric | measures | role |
|---|---|---|
| `intent_coverage.overall_score` | did the sim cover the oracle's intents? | **Block 2 — cohort filter** (drop sim-divergent cohorts) |
| `effort_cost` | how specific were the sim's hints? | **Block 1 — leaderboard ranking dimension** |

They are independent: a sim can be high-coverage low-effort (vague but on-topic) or low-coverage high-effort (off-topic but very specific). Mixing them would re-couple "did the sim get there" with "did the agent get there", which is exactly what the disentanglement story breaks.

Practical rule: **filter cohorts by Block 2, then rank survivors by Block 1**. Never average across blocks.

---

## Per-trial output schema (canonical)

After this lands, each trial dir contains:

```
trials_*/<trial>/
├── verifier/
│   ├── reward.txt              # Harbor live
│   └── reward.replay.txt       # clean replay
├── agent/
│   ├── final.patch
│   ├── claude-code.txt
│   └── episode-*/user_decision.json
├── judge_verdict.json          # eval/correctness — judge_score, verdict, completeness_goals
├── intent_coverage_verdict.json # eval/intent_coverage — match_table, overall_score,
│                                #   **trial_msg_specificity, effort_cost**  (new)
└── session.jsonl               # data-pipeline trial schema
```

Aggregation scripts read `judge_verdict.judge_score` + `intent_coverage_verdict.effort_cost` + `intent_coverage_verdict.overall_score` per trial; everything in the leaderboard is a deterministic transformation of those three numbers across replicates.

---

## Open questions

1. **Tier granularity** — 5 tiers match the graph-era plan. LLM judgment between adjacent tiers (directional ↔ diagnostic) is noisy. After the retrofit, if `effort_cost` variance from re-runs > 25% of cross-trial variance, collapse to 3 tiers (vague / specific / patch).
2. **`verification` as free?** — graph plan counted questions as effort (they reveal "look here"). I lean keep — a question like "are you sure all 4 corners snap?" carries the same hint payload as a directional correction.
3. **`patch_level` calibration** — if the sim writes ≥20 lines of code verbatim, that's patch_level. But sims rarely do this; tier may be near-empty in practice. Acceptable; just keep the bin for the cli-task-2a55af r2 case studies.
4. **Length tiebreaker** — when two trials have identical `effort_cost` but different message counts, do we prefer the shorter trial? Probably yes (concision is a virtue), but defer until we see ties in the retrofit data.

