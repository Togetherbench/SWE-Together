# Step 2 Filter Design — V2

**Status**: canonical as of 2026-05-30. Supersedes the legacy Filter A / Block 2 Guard 1 / Block 2 Guard 2 in [`eval_design.md`](eval_design.md) §"Filter protocol (step 2)" + §"Block 2 — Sim health".

**Purpose**: define the per-trial filter that gates which trials enter Block 1 capability aggregation. Document the gap between the design's stated intent ("filter sim-failure") and what the filter can actually identify from observable data.

---

## 1. Design intent

Per [`eval_design.md`](eval_design.md) §Core challenge:

> Remove as much **user-simulator variance** as possible from the agent's correctness measurement, while preserving as much **user-simulator realism** as possible in how the trial actually unfolds.

The Step 2 filter is supposed to drop trials where the sim "wandered off the oracle's task". The design enumerates 4 sim-behavior modes and assigns each a treatment:

| sim behavior | designed treatment |
|---|---|
| (a) sim cursor mis-routed, skips critical intents | filter (legacy Guard 2) |
| (b) sim over-anchors, cohort-divergent specificity | filter (legacy Guard 1) |
| (c) sim silent — strong model self-drives | **keep**, counts toward `self_completion` |
| (d) sim funnels all agents to same terminal state | flag in Block 4 (diagnostic, not filter) |

The intent is unambiguous: **filter is for sim noise, not agent behavior**.

---

## 2. The hard gap between intent and implementation

The filter has only one observable that distinguishes (a)/(b)/(c)/(d): `intent_coverage_verdict.overall_score` (the 0.65·weighted_coverage + 0.35·scope_precision composite). But low `overall_score` corresponds to at least **five distinct generation mechanisms**, only two of which the design says to filter:

| mechanism | should filter? | typical signature |
|---|---|---|
| (a) sim cursor mis-routed | ✓ yes | low cov, low judge, peer cov high |
| (b) sim over-anchored, cohort-divergent | ✓ yes | low cov, any judge |
| (c) sim silent — agent autonomy | ✗ no (→ `self_completion`) | cov=0, effort=0, judge often high |
| (d) agent scope-creep / off-task | ambiguous | low cov, low judge, low reward |
| (e) alt-path autonomy — agent solves via non-oracle path | ✗ no | mid cov, high judge |

**From `overall_score` alone, mechanisms (a), (b), (d) are indistinguishable.** A filter that triggers on "low overall_score" cannot guarantee it is removing only sim noise — it may also drop agent-driven failures or autonomy successes.

### Empirical illustration

On the 39-task × 4-cohort × 3-rep dataset, the legacy A+C filter dropped 42 trials. **12 (29%) had judge ≥ 0.85** — clear autonomy or alt-path successes wrongly identified as sim noise. Of those 12:

- 5 were fully sim-silent (`effort_cost = 0, n_sim_msgs = 0`) — mechanism (c)
- 7 were near-silent (`effort_cost ≤ 13, n_sim_msgs ≤ 5`) with judge=1.0 — mechanism (c) or (e)

The legacy Filter A's `overall_score < 0.50` absolute floor fires by definition when sim is silent (coverage of zero intents = 0), so it systematically penalized autonomy.

---

## 3. V2 unified rule (canonical)

V2 collapses legacy A / B / C into **one rule with two new guards** that close the autonomy escapes:

```python
SUCCESS_THRESHOLD       = 0.85   # judge bar (shared with pass@k, Guard 2)
SIGMA_K                 = 1.0
ABS_FLOOR               = 0.50
MAGNITUDE_GAP           = 0.10
FILTER_SIM_SILENT_SKIP  = 4      # ≤ 1 prescriptive hint OR ≤ 2 directional hints

def is_sim_noise_v2(trial, peers_in_same_cohort_task):
    """Drop iff ALL four conditions hold. Any single failure → keep.

    `peers` = other replicates of the SAME (cohort, task). Never cross-cohort.
    """

    # 0. NEW: skip near-silent autonomy (mechanism c)
    if trial.effort_cost is not None and trial.effort_cost <= FILTER_SIM_SILENT_SKIP:
        return False

    # 1. within-cohort cov 3-AND outlier (was legacy Filter A)
    covs = [p.overall_score for p in peers if p.overall_score is not None]
    if len(covs) < 2:
        return False
    med, sd = statistics.median(covs), statistics.pstdev(covs)
    cov_outlier = (
        trial.overall_score < med - SIGMA_K * sd
        and trial.overall_score < ABS_FLOOR
        and (med - trial.overall_score) > MAGNITUDE_GAP
    )
    if not cov_outlier:
        return False

    # 2. NEW: judge agrees this is a bad trial (closes mechanism e)
    if trial.judge_score >= SUCCESS_THRESHOLD:
        return False

    # 3. peer-proof (generalizes legacy Filter C from critical-intent to cov+judge)
    healthy_peers = [
        p for p in peers if p is not trial
        and p.overall_score is not None and p.overall_score >= ABS_FLOOR
        and p.judge_score >= SUCCESS_THRESHOLD
    ]
    if not healthy_peers:
        return False

    return True
```

### Mapping legacy → V2

| legacy | V2 |
|---|---|
| Filter A (within-cohort 3-AND on overall_score) | V2 condition 1 |
| Block 2 Guard 1 (cohort-level 3-AND on overall_score) | **removed** — see §4 |
| Block 2 Guard 2 (critical-intent peer-proof) | absorbed/generalized into V2 condition 3 |
| (new) sim_silent short-circuit | V2 condition 0 |
| (new) judge-low AND-guard | V2 condition 2 |

---

## 4. Why legacy Filter B (cohort-level Guard 1) is removed

Filter B drops all of a cohort's replicates on a task when that cohort's median `overall_score` is an outlier vs the other cohorts. **This is sound when different cohorts run different sims** — the design's original framing was "cross-cohort coverage diverges = sim is behaving differently for different cohorts, so the low-cov cohort's sim is broken on this task".

**It fails in same-sim cross-model experiments** (our default setup). When the sim is identical across cohorts, cross-cohort coverage differences are largely *agent-attributable*, not sim-attributable. Filter B then systematically drops the cohort whose agent is more autonomous (lower coverage because the agent doesn't need sim guidance), reverse-cheating the comparison.

On 39-task data, Filter B dropped 24 trials — **100% from mini-Opus alone**, on 8 tasks. Several were judge=1.0 reward=1.0 trials. Filter B inflated mini-Opus's `mean@3` from 0.729 → 0.797 by removing autonomy as if it were sim noise.

**Rule**: Filter B is disabled in V2. Re-enable only as an explicit opt-in (`enable_legacy_guard_1=True`) when running a multi-sim experiment.

---

## 5. What V2 actually filters — honest semantics

Each V2 condition does NOT identify a single generation mechanism cleanly:

| V2 condition | what it actually identifies |
|---|---|
| 0. effort > 4 | excludes mechanism (c) — near-silent autonomy |
| 1. cov is within-cohort outlier | signal is abnormal, but mechanisms (a), (b), (d) all possible |
| 2. judge < 0.85 | excludes mechanism (e) — alt-path autonomy |
| 3. peer cleared both cov & judge | proves "this agent CAN succeed on this task under this sim" |

**What V2 does NOT do:** prove that a dropped trial is sim-failure (a/b). The dropped trial may still be agent scope-creep (d) — the agent went off-task and the sim couldn't keep up.

**What V2 CAN claim:** the dropped trial does not represent the agent's true ceiling on this task. Peer evidence in the same (cohort, task) shows the agent does better in other reps, so this rep is an "outlier of undetermined source" — sim noise, agent variance, or both. Including it would underweight the agent's representable behavior; dropping it does not depend on attributing the cause.

### Honest reformulation

- ❌ "V2 filters sim-failure trials"
- ✓ "V2 filters trials where cov is anomalously low, judge agrees the trial failed, and a peer rep in the same (cohort, task) proves the agent can succeed on this task. The dropped trial is unlikely to represent the agent's true capability, but the exact source (sim noise vs agent variance) is undetermined."

This reformulation also captures what we can NOT do without a baseline experiment (§7).

---

## 6. Threshold choices

V2 has two effort thresholds with different roles:

| constant | default | role |
|---|---:|---|
| `SELF_COMPLETION_MAX_EFFORT` | 2 | **strict** — only count as "autonomy" when sim gave ≤ 1 vague hint or stayed silent |
| `FILTER_SIM_SILENT_SKIP`     | 4 | **lenient** — never penalize a trial for low cov when sim gave ≤ 1 prescriptive hint |

Different concepts, different right answers:

- `self_completion` is the **positive autonomy counter** — strict threshold avoids overcounting autonomy
- `FILTER_SIM_SILENT_SKIP` is the **protective guard against false drops** — lenient threshold avoids penalizing borderline-autonomy trials

These are not the same constant and should not be unified.

### Empirical sensitivity (39-task data)

| `FILTER_SIM_SILENT_SKIP` | V2 drops | mini-Opus mean@3 | opencode-Opus mean@3 |
|---:|---:|---:|---:|
| 2 | 7 | 0.735 | 0.770 |
| 3 | 6 | 0.735 | 0.766 |
| **4** | **4** | 0.731 | 0.766 |
| 5 | 4 | 0.731 | 0.766 |

`pass@3` is invariant across all four settings × all four cohorts. `mean@3` varies by ≤ 0.005. Threshold 4 = the most conservative defensible setting (fewest drops, all clearly defensible — see §8).

---

## 7. Open: fixed-agent baseline for strict sim-failure identification

The gap in §2 cannot be closed with the current experimental design. To strictly distinguish sim-attributable variance from agent-attributable variance, we need one of:

1. **Fixed-agent N-rep baseline.** Pick one canonical agent (e.g., Opus 4.6 on mini), run each task 20 times. Variance in `overall_score` under fixed agent = sim's intrinsic per-task variance. Cov outside `baseline_mean ± 2σ` is then agent-attributable.

2. **Oracle-through-sim.** Run the Oracle agent (mimics canonical session) through the sim, get `oracle_cov(task)` as the perfect-agent ceiling. Filter can then use relative `trial.overall / oracle_cov` instead of absolute thresholds.

3. **Variance decomposition.** With baseline, decompose total cov variance into within-agent (sim variance) vs cross-agent (agent variance). Filter on the within-agent component only.

Until that baseline experiment ships, V2 is the most conservative approximation: it filters only what *cannot represent the agent's capability under peer-proof*, regardless of cause.

---

## 8. Empirical validation (39-task × 4-cohort × 3-rep dataset)

468 trials total (`auto_zero_empty_patch` counted as `judge_score = 0`).

### Drop counts

| filter | drops | judge ≥ 0.85 drops (SUSPECT) | per-cohort balance |
|---|---:|---:|---|
| legacy A+B+C | 64 | 12 | very uneven (B drops 24 mini-Opus only) |
| legacy A+C | 42 | 12 (29%) | uneven (mini-DS=13, mini-Opus=8, opencode-DS=8, opencode-Opus=13) |
| **V2 (SILENT=4)** | **4** | **0** | balanced (1/1/0/2) |
| V2 (SILENT=2) | 7 | 0 | balanced (1/3/1/2) |

### The 4 V2 (SILENT=4) drops — all strong defensible

| # | cohort | task | rep | judge | cov | effort | peer judge |
|---:|---|---|---|---:|---:|---:|---:|
| 1 | mini-DS | gemini-voyager-task-18a6ae | r2 | 0.55 | 0.49 | 9 | 0.91 |
| 2 | mini-Opus | cli-task-0ec2e9 | r2 | 0.64 | 0.22 | 11 | 0.96 |
| 3 | mini-Opus | gemini-voyager-task-18a6ae | r2 | 0.46 | 0.40 | 17 | 0.91 |
| 4 | opencode-Opus | pi-mono-extensions-event-refactor | r3 | 0.36 | 0.47 | 28 | 1.00 |

All 4 received substantial sim guidance (effort 9–28), failed to clear 0.85, and a same-cohort peer succeeded with healthy cov AND cleared 0.85. These are the cleanest "underperformance under proof of feasibility" cases. The cohort distribution is naturally balanced (1/1/0/2) with no systematic bias.

### Effect on cohort metrics

| metric | property under V2 |
|---|---|
| `pass@3 @ 0.85` | **invariant from raw across all 4 cohorts** — V2 never drops a trial that affects pass@3 |
| `pass@1 @ 0.85` | shifts by ≤ 0.013 per cohort |
| `mean@3` | shifts by 0.001–0.014 per cohort |

V2 preserves the raw `pass@3` signal, including diagnostically interesting results like "mini-DS (0.821) > mini-Opus (0.795)" that the legacy A+C filter erased (the legacy filter dropped Opus scope-creep evidence and compressed the cohorts).

---

## 9. Reporting convention

The V2 filter is intended to support a `mean@3 (V2-filtered)` graded view alongside the raw pass-rate headlines. Recommended leaderboard structure:

| metric | filter | role |
|---|---|---|
| `pass@3 raw @ 0.85` | none | **headline** — best-of-3 ceiling, naturally noise-robust |
| `pass@1 raw @ {0.85, 0.90}` | none | secondary — multi-threshold sensitivity, exposes judge bimodality |
| `self_completion` | none | autonomy panel (effort ≤ 2 AND judge ≥ 0.70) |
| `mean@3 (V2-filtered)` | V2 | optional graded view; report `n_kept` separately |

`pass@3` raw is preferred over filtered because filtering can occasionally remove a task's only successful rep on small (cohort, task) groups, distorting the per-task ceiling. V2 was designed to minimize this (the 4 V2 drops never affect a task's pass@3 ceiling on this dataset), but the raw version remains the cleanest headline.

---

## 10. Migration from legacy

Code paths to update:

1. **`eval/run_eval.py`** — replace the existing `clean_trials()` (legacy Filter A) with the V2 rule above. Add `FILTER_SIM_SILENT_SKIP = 4` next to the existing `SIGMA_K / ABS_FLOOR / MAGNITUDE_GAP` constants.

2. **Legacy guards** — remove any separate code path for Block 2 Guard 1 and Block 2 Guard 2. V2 absorbs both. Add an explicit `enable_legacy_guard_1=False` flag if a future multi-sim experiment needs Guard 1.

3. **`intent_coverage/METHOD_AND_PILOT.md`** — the cross-cohort `disentangle_correctness()` filter (legacy Filter B equivalent) should also be marked "multi-sim only" or removed. Keep in sync with this doc.

4. **Pilot reports** — label aggregates as "V2-filtered" instead of "Guard 2-filtered". Reports under `eval/pilot10_v2_report.md` and downstream use the older Guard 2 labeling; either re-run or annotate.

5. **`eval_design.md`** — §"Filter protocol (step 2)" and §"Block 2 — Sim health" point to this doc as canonical.

Backward-compat note: V2 is strictly more conservative than legacy A+C (drops a subset). Existing analyses that used A+C will see higher cohort means after switching, mostly because near-autonomy trials that were errantly removed are restored.
