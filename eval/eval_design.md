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

### Filter protocol (step 2) — V2 canonical

**Canonical spec lives at [`FILTER_DESIGN.md`](FILTER_DESIGN.md).** This section is a one-page summary; the design rationale, the gap between "filter sim-failure" intent and what coverage observation can actually identify, and the migration from legacy A/B/C are documented there.

V2 is a single rule with two new guards. A trial is dropped iff **all four** conditions hold:

```python
SUCCESS_THRESHOLD       = 0.85
SIGMA_K, ABS_FLOOR, MAGNITUDE_GAP = 1.0, 0.50, 0.10
FILTER_SIM_SILENT_SKIP  = 4         # ≤ 1 prescriptive hint or ≤ 2 directional hints

def is_sim_noise_v2(trial, peers_in_same_cohort_task):
    # 0. skip near-silent autonomy (don't penalize a trial when sim barely spoke)
    if trial.effort_cost is not None and trial.effort_cost <= FILTER_SIM_SILENT_SKIP:
        return False
    # 1. within-cohort cov 3-AND outlier (was legacy Filter A)
    covs = [p.overall_score for p in peers if p.overall_score is not None]
    if len(covs) < 2: return False
    med, sd = statistics.median(covs), statistics.pstdev(covs)
    if not (trial.overall_score < med - SIGMA_K * sd
            and trial.overall_score < ABS_FLOOR
            and (med - trial.overall_score) > MAGNITUDE_GAP): return False
    # 2. judge agrees this is a bad trial (closes alt-path autonomy)
    if trial.judge_score >= SUCCESS_THRESHOLD: return False
    # 3. peer-proof: ≥1 same-(cohort,task) peer cleared BOTH cov AND judge
    if not any(p.overall_score is not None and p.overall_score >= ABS_FLOOR
               and p.judge_score >= SUCCESS_THRESHOLD
               for p in peers if p is not trial): return False
    return True
```

**Two new guards** vs the legacy `clean_trials()` (3-AND on `overall_score` alone):

- **Condition 0 — sim_silent short-circuit.** Trials where sim sent ≤ 1 prescriptive hint (effort ≤ 4) are protected from the filter regardless of coverage. Without this, the legacy `ABS_FLOOR = 0.50` rule errantly killed near-autonomy successes (`effort = 0` → `cov = 0` by definition; the legacy filter then fires).
- **Condition 2 — judge-low AND-guard.** Trials where `judge_score ≥ 0.85` are protected regardless of coverage. Without this, the filter drops alt-path autonomy where the agent succeeded via a non-oracle route.

**Removed from V2:** legacy Block 2 Guard 1 (cohort-level outlier on `overall_score`). It assumed different cohorts use different sims; in our same-sim cross-model default it systematically drops the most autonomous cohort. See [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §4.

After filtering, report **four numbers** per (task, agent):

```
n_total      = k                                  # replicates we started with
n_surviving  = len(kept)                          # passed V2 filter
mean_judge   = mean(t.judge_score for t in kept)  # cleaned correctness number
var_judge    = pvariance(t.judge_score for t in kept)
```

Never collapse `n_surviving` into the headline — a low survival count is itself a signal worth reporting alongside the cleaned mean. Default thresholds calibrated on the 39-task × 4-cohort × 3-rep dataset; see [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §6 for sensitivity.

**Honest framing.** Coverage alone cannot strictly distinguish sim-failure from agent-driven low coverage (scope creep, autonomy, alt-path). V2 drops trials where (cov low + judge low + peer-proof of feasibility); the dropped trial does not represent the agent's true ceiling, but the exact source (sim noise vs agent variance) is undetermined. Strict sim-failure identification requires a fixed-agent baseline experiment — see [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §7.

This is what the three blocks below operationalize: Block 1 is the cleaned correctness number with effort as a second axis; Block 2 is the V2 filter (the cleaning step itself); Block 3 is benchmark fidelity. **No composite score across blocks.**

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

### Block 1 — Capability (multi-axis panel, no headline) **[P0]**

The pilot10 study (see §"Pilot10 findings" below) showed that **a single capability number is misleading** — different metrics expose different facets, with different cohorts winning each. The Block 1 panel reports **five orthogonal axes** plus the threshold-AUC view; there is **no composite headline**.

| metric | formula | what it measures |
|---|---|---|
| `effort_cost(trial)` | §B | how much hint+task-spec the sim revealed in this trial |
| `mean@3(task)` | `mean(judge_score over the 3 reps)` | per-task soft reliability — threshold-free, retains magnitude differences |
| `pass@1(task)` for T ∈ {0.80, 0.85, 0.90} | `mean(1{judge_score ≥ T} over reps)` | single-shot success rate, binary — sensitivity to threshold flags marginal trials |
| `pass@3(task)` for T ∈ {0.80, 0.85, 0.90} | `1 if ∃ rep with judge_score ≥ T else 0` (codex unbiased) | best-of-3 capability ceiling — robust to sim noise (see Block 2) |
| `effort_AUC(model)` @ T ∈ {0.80, 0.85, 0.90} | area under pass@1-cumulative curve over `k ∈ [0, max_k]`, normalised to [0, 1] | capability under effort-penalty: per-task fraction of reps satisfying `(judge ≥ T AND effort_cost ≤ k)`, averaged across tasks, averaged across k. Monotone non-decreasing in k. |
| `self_completion(model)` | `fraction of trials with effort_cost ≤ 2 AND judge_score ≥ 0.70` | **model autonomy** — fraction of trials where agent reaches substantive progress with minimal sim hand-holding |

```python
SUCCESS_THRESHOLD = 0.85  # primary judge_score threshold
SELF_COMPLETION_THRESHOLD = 0.70  # looser bar for self-completion (substantive ≠ perfect)
SELF_COMPLETION_MAX_EFFORT = 2  # ≤ 1 vague hint or full sim silence

def pass_at_1_cumulative(by_task, k, T=SUCCESS_THRESHOLD):
    """Per-task fraction of reps with (judge >= T AND effort <= k), averaged across tasks.
    Monotone non-decreasing in k — adding budget can only add successes, not subtract."""
    if not by_task: return 0
    return mean(
        sum(1 for r in reps if r.judge_score >= T and r.effort_cost <= k) / len(reps)
        for reps in by_task.values()
    )

def effort_auc(by_task, max_k=10, T=SUCCESS_THRESHOLD):
    """Mean of pass@1-cumulative over budgets 0..max_k. Matches the
    cumulative success-vs-effort plot used in pilot reports."""
    curve = [pass_at_1_cumulative(by_task, k, T) for k in range(max_k + 1)]
    return sum(curve) / (max_k + 1)

def self_completion(replicates):
    if not replicates: return 0
    return sum(
        1 for r in replicates
        if r.effort_cost <= SELF_COMPLETION_MAX_EFFORT
        and r.judge_score >= SELF_COMPLETION_THRESHOLD
    ) / len(replicates)
```

Reading the panel:
- **`mean@3`** = "if I sample one rep at random, what soft score do I expect?" Reliability premium — punishes high-variance cohorts. **Most sensitive to Block 2 sim-noise filter**.
- **`pass@1`** = "single-shot success rate" — what fraction of trials clear the binary bar. Sensitive to threshold (multiple thresholds reported).
- **`pass@3`** = "best-of-3 ceiling" — capability under retry. **Robust to sim noise** (best-rep dominates).
- **`effort_AUC`** = pass@1-cumulative AUC over budgets `[0, max_k]`. Per-task fraction of reps satisfying `(judge ≥ T AND effort_cost ≤ k)`, averaged across tasks, averaged across k. **Monotone non-decreasing in k** (unlike the legacy per-trial `success_at_k`, which selected only in-budget trials and produced non-monotone curves — pilot10 §"success@k weirdness" documents the symptom; the cumulative redefinition resolves it).
- **`self_completion`** = **NEW**: fraction of trials where the agent reached `judge ≥ 0.70` with `effort_cost ≤ 2`. Distinct from `success@0` (which used 0.85 + effort=0) — this captures *substantive autonomous progress*, not perfect autonomous completion. Pilot10 showed strong models occasionally finish tasks under sim silence (intv=0) at judge≈0.74; these are positive signals, not noise.

Choosing among them depends on the deployment scenario (see §"Pilot10 findings" — five metrics gave four different winners). A strong agent has high `success@k` at low k *for tasks designed to unfold quickly*, and follows the Oracle curve closely *for tasks designed to unfold over many turns*. The curve never measures "ability to use hints well" — it measures *how much effort the trial accumulated to succeed*.

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

Block 2 applies the **V2 unified filter** (see §"Filter protocol (step 2)" above and [`FILTER_DESIGN.md`](FILTER_DESIGN.md)). Trials dropped here are removed before Block 1 computes anything. Block 2 never enters ranking directly.

**V2 drops a trial iff all four conditions hold:** ① sim was substantively active (`effort_cost > 4`), ② trial's `overall_score` is a 3-AND within-cohort outlier, ③ judge agrees the trial failed (`judge_score < 0.85`), ④ at least one same-(cohort, task) peer cleared **both** `overall_score ≥ 0.50` and `judge_score ≥ 0.85`. See [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §3 for the canonical pseudocode and §5 for what V2 actually identifies (versus what the design intends).

**Sim noise is multi-faceted.** V2 + the panel metrics together handle the design's enumerated sim behaviors:

| sim behavior | V2 / metric handling |
|---|---|
| sim over-anchors with cohort-divergent specificity | V2 conditions 1 + 2 + 3 (within-cohort cov outlier + judge low + peer-proof) |
| sim skips critical intents (cursor mis-routed) | V2 conditions 1 + 2 + 3 (generalizes legacy Guard 2's critical-intent peer-proof) |
| sim silent (intv=0) — strong model self-drives | V2 condition 0 skips these; **`self_completion` counts them** (POSITIVE signal) |
| sim funnels all agents to same terminal state | Block 4 — task discriminability flag (diagnostic) |
| agent scope-creep / alt-path autonomy | V2 condition 2 (`judge ≥ 0.85`) protects alt-path; V2 cannot cleanly distinguish scope-creep from sim noise — see [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §2 |

**Legacy filter components** (Filter A within-cohort 3-AND, Block 2 Guard 1 cohort-level, Block 2 Guard 2 critical-intent peer-proof) are subsumed or removed. See [`FILTER_DESIGN.md`](FILTER_DESIGN.md) §3 mapping table and §4 for the reasoning behind removing Guard 1 in same-sim cross-model experiments.

### Block 3 — Benchmark fidelity

- `judge_clean_testsh_delta` per task — QA signal on `test.sh` hygiene (see [`correctness/METHOD_AND_PILOT.md`](correctness/METHOD_AND_PILOT.md) §1)
- Empty-patch rate per cohort
- Schema-warning rate on judge / coverage verdicts

Used to caveat or exclude tasks; never enters Block 1.

### Block 4 — Benchmark coverage **[NEW from pilot10]**

Pilot10 surfaced an issue the original design did not name: **sim funneling**. On 6 of 10 tasks, all 6 cohorts produced identical per-task `mean@3` (often 1.000). The sim drove every agent to the same terminal state — fine for "everyone passes" but a wasted comparison opportunity. The benchmark cannot rank capability on a task where 100% of cohorts get the same score.

| metric | formula | use |
|---|---|---|
| `task_discriminability` | `max(cohort mean@3) − min(cohort mean@3)` per task | tasks with discriminability < 0.10 are "sim-funneled, low information" — flag for task-suite redesign |
| `% information-bearing tasks` | fraction with `discriminability ≥ 0.10` | benchmark coverage health |

On pilot10, only 4 of 10 tasks had `discriminability ≥ 0.10`:
- cli-task-2a55af (range 0.00–0.66 across cohorts)
- cli-task-2f5833
- gemini-voyager-task-18a6ae
- cli-task-f76665

All four are "hard tasks where mini hits 3600s timeout or model truly fails." Sim funneling is **most severe on easy tasks** (cluefin, sd-scripts, comfyui, cli-task-46c118 — all funnel to 1.0). For Peter pilot (26 tasks) the same audit should be applied; tasks below the discriminability floor are candidates for rewrite or removal.

Block 4 is **diagnostic, not ranking** — it tells benchmark designers which tasks earn their place. Never enters Block 1.

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

## Pilot10 findings — what the design uncovered

Running the design end-to-end on the v0.5 10-task pilot (3 reps × 6 cohorts = 180 trials, 3 models × 2 harnesses) produced five concrete revisions, all folded into the sections above:

1. **No single capability headline.** Five metrics gave four different winners:

   | metric | #1 cohort |
   |---|---|
   | `mean@3` (reliability) | opencode-DS (0.842) |
   | `pass@1` (single-shot) | mini-Opus (0.733) |
   | `pass@3` (best-of-3) | mini-Opus (0.900) |
   | `self_completion` (autonomy) | **opencode-Opus (0.286)** |
   | `success@0` (perfect autonomy) | mini-GPT = opencode-DS (0.207, tied) |

   No metric is "the right one"; together they describe a multi-axis capability surface. The leaderboard reports all five.

2. **Sim funneling is real and quantifiable.** 6 of 10 pilot tasks produced identical `mean@3` across all 6 cohorts (typically 1.0). The interesting comparisons happen on only 4 tasks. This motivated Block 4 (benchmark coverage).

3. **Sim noise is bounded.** Block 2 Guard 2 (critical-intent peer-proof) flagged 5/180 trials (2.8%) as sim-noise. Effect on cohort metrics:

   | metric | sensitivity to Guard 2 |
   |---|---|
   | `mean@3` | most sensitive (+0.012 to +0.025) — reflects "graded" correction |
   | `pass@1` | medium (+0.000 to +0.067) — discrete 1/N steps |
   | `pass@3` | **zero** (+0.000 across all 6 cohorts) — best-of-3 already absorbs |

   `pass@3` is the natural sim-noise-robust headline; `mean@3` is the natural reliability headline. Both should be reported.

4. **Same model × different harness ≠ small effect.** Pairing the *same* model across mini-swe-agent vs opencode revealed harness-induced capability shifts:

   - Opus: mini reaches `pass@1=0.733`, opencode `pass@1=0.667`. But opencode reaches `self_completion=0.286` vs mini's `0.133` — **opencode lets Opus run autonomously, mini needs to step-by-step it**. Both are valid; different deployment shape.
   - DeepSeek: opencode's `mean@3=0.842` beats mini's `0.803` by reliability (lower variance), but `pass@3` favors mini (0.800 vs 0.700) — mini's reps are boom-or-bust.

   This is the eval doing its job: the same model in two harnesses isn't one capability number, it's a different point on the multi-axis surface.

5. **Qualitative ≠ quantitative on close calls.** The opencode-DS vs opencode-Opus `mean@3` gap is 0.003 (basically tied). Walking trajectories showed: 6/10 tasks identical outcomes (sim funneled both to same answer); the 0.003 advantage came entirely from one Opus rep crashing (cli-task-2f5833 r2 = 0.35) while DS stayed consistent. Both models *can* solve the same tasks; Opus has higher variance and higher ceiling. The headline metric flattens that; the panel exposes it.

---

## Open questions

1. **Tier granularity** — 5 tiers match the graph-era plan. LLM judgment between adjacent tiers (directional ↔ diagnostic) is noisy. After the retrofit, if `effort_cost` variance from re-runs > 25% of cross-trial variance, collapse to 3 tiers (vague / specific / patch).
2. **`verification` as free?** — graph plan counted questions as effort (they reveal "look here"). I lean keep — a question like "are you sure all 4 corners snap?" carries the same hint payload as a directional correction.
3. **`patch_level` calibration** — if the sim writes ≥20 lines of code verbatim, that's patch_level. But sims rarely do this; tier may be near-empty in practice. Acceptable; just keep the bin for the cli-task-2a55af r2 case studies.
4. **Length tiebreaker** — when two trials have identical `effort_cost` but different message counts, do we prefer the shorter trial? Probably yes (concision is a virtue), but defer until we see ties in the retrofit data.

