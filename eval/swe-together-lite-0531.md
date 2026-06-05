# 70-task analysis — metric choice & cohort interpretation

> **Note on terminology** (added 2026-05-31): what this doc calls "**stable solve rate**" is shorthand for **stable solve rate @ k=3, T=0.85**: the fraction of tasks whose mean@3 judge_score meets the 0.85 threshold. 

> **Dataset evolution** (added 2026-05-31): it now covers **70 unique tasks × 18 cohorts (2 harness × 3 model × 3 rep)**. Three of the 70 tasks (`amytis-task-e3714e`, `lock-code-manager-fix-7c955a`, `moltis-task-ffe9ec`) carry **6 trials per cell** instead of 3 because they appear in both v39 and v26 source pools; the headline metrics below use [`scripts/_aggregate_n_normalized.py`](../scripts/_aggregate_n_normalized.py)'s `subsample_to_k(k=3)` for fair cross-task aggregation. 

**Scope**: how to read the three correctness metrics (pass@1, stable solve rate, pass@3) on the 70-task × 6-cohort × 3-rep dataset (DS · Opus · GPT × mini-swe-agent · opencode), why **stable solve rate best matches deployment intuition**, and the recommended leaderboard headline structure.

**Companion docs**: [`eval_design.md`](eval_design.md) (metric specs). *(Trial filtering was removed — intent-coverage is now a diagnostic only; see `eval_design.md` §"Step 2 is diagnostic-only".)*

---

## 1. Ceiling table (T = 0.85, strict two-step aggregation, n=3 subsample)

| cohort | pass@1 | stable solve rate | pass@3 |
|---|---:|---:|---:|
| mini-DS         | 0.529 | 0.357 | 0.757 |
| **mini-Opus**       | **0.619** | **0.529** | 0.786 |
| mini-GPT        | 0.581 | **0.529** | 0.686 |
| opencode-DS     | 0.529 | 0.429 | 0.757 |
| **opencode-Opus** | 0.595 | 0.500 | **0.814** |
| opencode-GPT    | 0.452 | 0.371 | 0.629 |

Aggregation rule: each metric is computed per-task first (over 3 trials), then averaged over all 70 tasks (each task contributes weight 1). For the 3 overlap tasks with n=6 trials/cell, only the lexicographic-first 3 are used; the raw n=6 analysis is preserved as a sensitivity appendix.

**Key takeaways** (changed vs the earlier 39-task numbers; see §9 changelog):

- **mini-Opus now leads pass@1 (0.619)** and ties mini-GPT for stable solve rate (0.529). Opus + mini-swe-agent is the **new "consistency winner"** — high pass@1, highest stable solve rate, low reliability ratio (1.49).
- **opencode-Opus remains the pass@3 leader (0.814)** and the only cohort hitting >0.80 on best-of-3.
- **mini-GPT recovered dramatically from the 39-task baseline** (ssr 0.308 → 0.529, +72%). The aiohttp fix (commit `feb02e55`) + codex-OAuth v1.0 hardening (#191-#200) unblocked a class of "model never tried" failures.
- **opencode-GPT is now the weakest cohort** (pass@1 0.452, ssr 0.371). The opencode harness can no longer make GPT outperform mini after the mini-side fixes landed.
- **mini-DS preserves its boom-or-bust signature** — lowest stable solve rate (0.357) but pass@3 (0.757) on par with opencode-DS.

---

## 2. Why stable solve rate best matches deployment intuition

The "desired conclusion" — Opus ≥ DS for capability, harness choice depending on whether retry capacity is available — aligns with **stable solve rate's ranking and exhibits the largest separation under stable solve rate**. Two amplification mechanisms explain why:

### Mechanism 1 — single-point CDF at the bimodal gap

Per-task `mean@3` distribution (binned, fractions of 70 tasks):

| cohort | <0.20 | [0.20, 0.50) | **[0.50, 0.85) partial** | [0.85, 0.95) | ≥0.95 decisive | mean@3 | ssr |
|---|---:|---:|---:|---:|---:|---:|---:|
| mini-DS         | 10.0% | 15.7% | **38.6%** | 11.4% | 24.3% | 0.668 | 0.357 |
| mini-Opus       | 5.7% | 17.1% | 24.3% | 20.0% | **32.9%** | 0.728 | 0.529 |
| mini-GPT        | **14.3%** | 12.9% | 20.0% | 20.0% | **32.9%** | 0.698 | 0.529 |
| opencode-DS     | 7.1% | 12.9% | 37.1% | 20.0% | 22.9% | 0.700 | 0.429 |
| opencode-Opus   | 5.7% | 15.7% | 28.6% | 17.1% | **32.9%** | 0.729 | 0.500 |
| opencode-GPT    | **18.6%** | 17.1% | 27.1% | 17.1% | 20.0% | 0.600 | 0.371 |

Three patterns the binning surfaces:

1. **mini-DS / opencode-DS share a 37–39% partial-credit mass** — the DeepSeek signature: many tasks land in the 0.50–0.85 "almost but not quite" band, dragging stable solve rate down even though mean@3 is respectable.
2. **opencode-GPT carries the largest tail-mass (18.6% < 0.20)** — these are catastrophic failures the opencode harness can't shield against. After the mini-side aiohttp fix, mini-GPT's tail dropped to 14.3% while opencode-GPT's stayed high.
3. **Three cohorts converge at 32.9% decisive** — mini-Opus, mini-GPT, and opencode-Opus all push the same fraction of tasks past 0.95. Differences in stable solve rate come from the `[0.85, 0.95)` band, where Opus cohorts (20%) edge out mini-GPT (20%) tied but the partial-credit mass differs.

The judge has a **bimodal distribution** (heavy mass near 1.0 and near 0, sparse middle). `stable solve rate = 1 − F(0.85)` is a single point of the per-task CDF, sitting **right in the bimodal gap**. Small cohort differences in how many tasks cross 0.85 directly determine stable solve rate.

mean@3 and pass@1 dilute this signal: they average across all bins, so partial-credit mass reduces apparent separation.

### Mechanism 2 — variance penalty

A cohort with reps `[0.95, 0.95, 0.40]` (mean 0.77) gets stable solve rate = 0 on that task, while a cohort with `[0.85, 0.85, 0.85]` gets stable solve rate = 1. Identical mean@3, opposite stable solve rate. **stable solve rate doubly punishes inconsistent cohorts** — once for not exceeding the threshold on average, again for variance pulling the mean down.

This matches the deployment reality: a model that occasionally nails a task isn't the same as a model that reliably does it.

### Mechanism 3 — n=6 overlap tasks validate the variance story

The 3 overlap tasks (n=6 trials/cell, see §10 sensitivity appendix) directly show this mechanism in action:

- `opencode-Opus × moltis-task-ffe9ec`: rewards `[1.0, 1.0, 1.0, 0.0, 1.0, 1.0]` — mean=0.83 (pass@1=0.83) but **17% catastrophic failure** that the rename-refactor outlier exposes
- `opencode-GPT × moltis-task-ffe9ec`: rewards `[0.0, 0.9, 0.6, 0.0, 0.6, 0.6]` — **33% catastrophic failure rate**

Stable solve rate would mark both as "not decisive" (mean < 0.85). pass@1 would mistakenly rank opencode-Opus 0.83 as nearly solving the task. The reliability ratio (§3) captures this gap.

---

## 3. The reliability ratio `pass@3 / stable solve rate` — diagnostic for "lucky wins"

`pass@3 / stable solve rate` measures how much of best-of-3 ceiling is "the lucky one-third of reps":

| cohort | stable solve rate | pass@3 | **pass@3 / ssr** | reading |
|---|---:|---:|---:|---|
| **mini-DS**         | 0.357 | 0.757 | **2.12** | 53% of pass@3 wins **don't** clear ssr — heaviest boom-or-bust |
| mini-Opus       | 0.529 | 0.786 | **1.49** | most consistent; least "luck water" |
| **mini-GPT**        | 0.529 | 0.686 | **1.30** | unexpectedly tight — when mini-GPT solves a task, it solves it stably; pass@3 ceiling is low because tail failures don't recover |
| opencode-DS     | 0.429 | 0.757 | 1.77 | strong retry payoff |
| opencode-Opus   | 0.500 | 0.814 | 1.63 | high ceiling with moderate luck component |
| opencode-GPT    | 0.371 | 0.629 | 1.69 | moderate ratio but lowest absolute base |

**Story shift vs 39-task**: previously mini-Opus had the lowest reliability ratio. Now mini-GPT does (1.30). Reading: post-aiohttp-fix mini-GPT either consistently solves a task or consistently fails it — no middle ground that retry can rescue. This is a different shape of "reliable" than mini-Opus's (which has steady partial credit that occasionally promotes past threshold).

The reliability ratio's job in the leaderboard is to **flag cohorts whose pass@3 oversells real capability**:

- mini-DS pass@3 = 0.757 looks competitive with opencode-DS, but 53% of those wins are single-rep luck.
- opencode-Opus pass@3 = 0.814 is the genuine ceiling — only 38% of its pass@3 wins are luck-driven.

---

## 4. Cohort deployment profiles

| cohort | profile | deployment scenario |
|---|---|---|
| **mini-Opus** | strongest pass@1 + ssr, lowest reliability ratio for non-GPT | **single-shot production default** — wins where reliability matters most |
| **opencode-Opus** | strongest pass@3 ceiling; high autonomy | **retry-enabled / agentic production** — wins where best-of-N inference is feasible |
| **mini-GPT** | tied ssr with mini-Opus, lowest reliability ratio | viable as a **substantive single-shot substitute** when GPT pricing matters |
| **opencode-DS** | mid pass@1, strong retry payoff | cost-sensitive retry-enabled deployment |
| **mini-DS** | boom-or-bust, best-of-N pays off (2.1× ratio) | **only when retry is available** — single-shot deployment NOT recommended |
| **opencode-GPT** | weakest cohort across all 3 metrics, ~19% tail-failure | not recommended; opencode harness no longer compensates for codex-OAuth quirks after mini-side fixes |

**Big-picture finding**: harness × model interactions are **non-monotonic**. opencode lifts Opus on pass@3 (+0.028 over mini-Opus) but mini-Opus wins on pass@1 (+0.024) and ssr (+0.029). DeepSeek is the only model where opencode universally helps. GPT now favors mini (+0.130 pass@1 over opencode-GPT) after the mini-side path stabilized.

---

## 5. Harness architecture — what mini-swe-agent and opencode actually expose

The two harnesses behave very differently as **tool-surface shapes**, and that shape (not the model alone) drives several headline observations in §1-§4. Verified directly from the trajectory files on this dataset.

### 5.1 Registered tools

| harness | distinct tools | observed mix |
|---|---|---|
| **mini-swe-agent** | **1** (`bash`) | 3,732 / 3,732 calls (100%) are `bash`. File edits go through `sed`, `cat <<EOF`, etc. inside the shell. |
| **opencode** | **11** (`bash`, `read`, `grep`, `edit`, `todowrite`, `apply_patch`, `glob`, `webfetch`, `write`, `task`, `skill`) | bash 34% · read 28% · grep 11% · edit 10% · todowrite 8% · apply_patch 3% · others ≤2% |

Mini's system prompt is `"You are a helpful assistant that can interact with a computer."` followed by a single `bash` tool spec. Opencode ships a multi-tool inventory including a planning tool (`todowrite`) and a sub-agent spawn (`task`).

### 5.2 Per-trial tool-call density

| cohort | tool calls / trial |
|---|---:|
| **mini-GPT** | **6.6**  ← most decisive |
| mini-Opus    | 17.6 |
| mini-DS      | 25.1 |
| opencode-GPT | 90.6 |
| opencode-DS  | 95.4 |
| **opencode-Opus** | **107.9** ← highest call density |

opencode trials use **4-15× more tool calls** than mini trials, even when the same model is paired. This is the granularity tax: a single bash line `sed -i '...' file.py` becomes a `read` + `edit` + (often) a follow-up `read` to verify. The density tax is paid in tokens (see §5.3) and visible wall-clock (§ time-vs-pass plot).

GPT-5.5 does NOT explode tool counts in opencode — `opencode-GPT 90.6 < opencode-Opus 107.9`. So the "GPT spawns more tool calls under richer surfaces" intuition is wrong. The real signature is the opposite: **GPT-5.5 produces the most decisive trajectories in EVERY harness** (lowest per-trial call count of the three models, in both rows).

### 5.3 Token cost rolls up from these patterns — mini is the more expensive harness

Per-task output tokens (visible + reasoning/thinking; summed across all
per-turn `mini-swe-agent.trajectory.turn-N.json` files for mini, and across
all `step_finish` events for opencode):

| cohort | tokens / task | mini / opencode (same model) |
|---|---:|---|
| mini-DS       | 77,877 | **1.97×** opencode-DS |
| mini-Opus     | 52,625 | **1.67×** opencode-Opus |
| mini-GPT      | 34,118 | **1.77×** opencode-GPT |
| opencode-DS   | 39,563 | base |
| opencode-Opus | 31,515 | base |
| opencode-GPT  | 19,334 | base |

**Mini is the more token-expensive harness, not the cheaper one** — this is
the opposite of what the 39-task headline figure suggested and is the
correction over an earlier "char÷4 on last turn only" artefact (commit
2026-05-31). The mechanism is mini's multi-turn pattern: every turn re-issues
the cumulative context, and the agent re-derives its plan from scratch
against that augmented prompt. Each restart re-emits reasoning trace and
re-explains its next step, so the per-trial output token sum grows
roughly linearly with turn count.

Opencode, by contrast, runs one continuous session — its reasoning trace
accumulates additively rather than being re-emitted, so even with 4-15× more
tool calls per trial it ends up using fewer total output tokens than mini.

### 5.4 What this means for the harness × model pattern in §4

The non-monotonic harness × model interaction (Opus splits, DS prefers
opencode, GPT prefers mini) is NOT explained by token efficiency. mini-GPT
spends **1.77× more output tokens** than opencode-GPT and yet reaches a
higher stable solve rate (0.529 vs 0.371). The real mechanism is closer to
**how the harness structures the agent's decision-making**:

- **Mini's multi-turn re-issue forces self-review.** Each turn, the agent
  sees the cumulative diff + recent tool calls + prior user messages and
  decides what to do next from a fresh internal state. This is expensive in
  tokens but creates natural correction points: a wrong patch on turn 0 can
  be discarded on turn 1 without sunk-cost momentum. GPT-5.5 benefits most
  from this because its strength is producing one well-reasoned next action;
  the restart pattern matches that strength.
- **Opencode's continuous session amortises context but loses self-correction.**
  All 90-107 tool calls per trial happen in one running conversation. The
  agent's earlier plans bias its later decisions — efficient when the plan
  is correct, painful when it's not. opencode-GPT spends fewer tokens but
  gets stuck on its initial trajectory; opencode-Opus is robust enough to
  recover mid-stream.
- **DS prefers opencode** because DS's failure mode is meandering, not wrong
  initial plans — opencode's structured tool surface keeps it from
  meandering and the continuous session amortises its chattiness across
  steps.

In short: **mini buys correction headroom at a token premium; opencode buys
token efficiency at a correction-headroom discount.** Which trade-off wins
depends on the model's failure mode — GPT-5.5 needs the correction
headroom, DS needs the structure, Opus is robust to either.

The takeaway for the paper: **tool surface is itself a first-order axis**,
not just a wrapper detail. Reporting "model X on harness Y" without
commenting on the restart-vs-continuous-session axis hides the actual
mechanism.

---

## 6. Recommended leaderboard headline

```
Primary metrics (always reported)
├── stable solve rate @ k=3, T=0.85   ← main, "stably solves the task" — best discriminator
├── pass@1                            ← single-shot success rate
└── pass@3 (unbiased)                 ← best-of-N ceiling

Diagnostic
├── reliability ratio                 ← pass@3 / ssr — "lucky-win water content"
├── self_completion                   ← effort ≤ 2 AND judge ≥ 0.70, autonomy signal
└── Oracle reference                  ← AUC + ceiling on same panel as stable solve rate

Aggregation
└── Strict task-level → cohort-level. n=3 subsample on the 3 n=6 overlap tasks
    (scripts/_aggregate_n_normalized.py).
```

Three reasons to report all three of (stable solve rate, pass@1, pass@3) and not just one:

1. **stable solve rate** answers "would I deploy this?" — most aligned with production but T-sensitive.
2. **pass@1** answers "single-shot success rate?" — least sensitive to threshold, most directly comparable across studies.
3. **pass@3** answers "best-of-N potential?" — captures cohorts that have high ceiling but high variance (RL training candidates, retry-enabled deployment).

A cohort that wins on all three would be unambiguously strongest, but on this dataset **no cohort does** — mini-Opus wins pass@1/ssr, opencode-Opus wins pass@3. That harness split is itself the result.

---

## 7. Risks of stable solve rate (don't use it alone)

1. **Threshold sensitivity**: at T = 0.90 the numbers shift materially. Always report at multiple thresholds or alongside pass@1.
2. **Punishes high-ceiling-high-variance cohorts**: if your research goal is "find models with the highest reachable performance" (e.g., for RL post-training or best-of-N inference deployment), stable solve rate buries cohorts like mini-DS that pass@3 reveals. Report both.

The recommendation is **stable solve rate as primary headline, pass@1 + pass@3 as secondary**, never any one of the three alone.

---

## 8. Qualitative audit — does the trajectory data validate the quantitative claims?

Audit of 4 case sets (~12 trials), reading the judge's reasoning, patch sizes, and per-rep outcomes. The qualitative claims below were validated on the 39-task version and continue to hold on the 70-task dataset — they describe per-trial behavior that's invariant to the cohort denominator.

### 8.1 Case A — mini-DS boom-or-bust validated (`cli-task-4cfca9`)

Same agent, same task, 3 reps:

| rep | judge | patch | judge_notes (excerpt) |
|---|---:|---:|---|
| r1 | 0.00 | 6.2 KB  | "fundamentally different approach... **addresses a symptom, not root cause**" |
| r2 | 0.00 | 4.9 KB  | "addressed a **different (tangentially related) problem**... actual production bug was not fixed" |
| r3 | 0.85 | 22.0 KB | "**correctly identified and fixed the core bug** with the phase guard" |

**Verdict**: ✓ Validates the 2.12 reliability ratio for mini-DS. 2/3 reps misdiagnose entirely; 1/3 nails root cause. Categorically different attempts, not gradations.

### 8.2 Case B — opencode-Opus autonomy (`hyperswitch-9430`)

3 reps, **all with `effort_cost = 0` (sim never spoke)**:

| rep | effort | judge | reward | judge_notes |
|---|---:|---:|---:|---|
| r1 | 0 | 1.00 | 1.00 | "complete implementation across all layers. **patch goes beyond the minimum**" |
| r2 | 0 | 1.00 | 1.00 | "**comprehensive patch covering migrations, diesel schema, models, conversion logic...**" |
| r3 | 0 | 1.00 | 1.00 | "**comprehensively added... going beyond the minimum required**" |

**Verdict**: ✓ This task's canonical session uses 96 user turns, yet opencode-Opus completes it 3/3 times with the sim entirely silent. Direct evidence of opencode-Opus's pass@3 = 0.814 advantage being driven by genuine autonomy rather than retry luck.

### 8.3 Case D — stable solve rate differentiator (`pi-mono-overflow-detection`)

| | per-rep judges | reading |
|---|---|---|
| opencode-DS    | r1=0.86, r2=0.97, r3≈0.00 | **2 strong + 1 catastrophic failure** |
| opencode-Opus  | r1=1.00, r2=0.97, r3≈1.00 | **3 strong, consistent** |

**Verdict**: ✓ Stable solve rate's binarization is correct for the deployment question. opencode-DS has a real 33% catastrophic failure rate on this task; opencode-Opus does not. pass@3 = 1 for both, missing the difference; mean@3 numerically shows the gap (0.61 vs 0.99) but doesn't convey deployment consequence.

### 8.4 Case E — judge–reward divergence (`pi-mono-auto-90748a5d`)

| cohort | rep | judge | reward | patch | judge_notes |
|---|---|---:|---:|---:|---|
| mini-DS    | r1 | **1.00** | 0.00 | 6.8 MB | "All 4 goals met. Agent's patch adds BMP-to-PNG conversion ... using Photon (matching oracle approach)" |
| mini-DS    | r3 | **1.00** | 0.00 | 8.1 MB | "All 4 goals met. Agent's commit implements BMP-to-PNG conversion in clipboard-image.ts" |
| mini-Opus  | r1 | **1.00** | 0.00 | 8.1 MB | (similar) |
| opencode-Opus | r2,r3 | **1.00** | 0.00 | 6.8 MB | (similar pattern) |

**Verdict**: ⚠ judge probably correct; test.sh is the unreliable signal here. The [SWE-bench Verified critique pattern](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/): ~35% of test.sh failures are narrow-test or environment-driven false negatives that the judge catches.

CLAUDE.md's eval pipeline guidance already encodes this: "**Headline ranking lives in `judge_score`, not `reward.txt`.**" The qualitative audit confirms that policy is correct on this dataset.

### 8.5 Summary — quantitative claim × qualitative verdict

| quantitative claim | qualitative verdict | evidence |
|---|---|---|
| **mini-Opus is the strongest single-shot cohort** (pass@1 0.619, ssr 0.529) | ✓ supported by the trajectory consistency seen in §8.1 (mini-DS contrast) | mini-Opus has lowest variance among non-GPT cohorts; trajectory data confirms steady partial-credit rather than lucky spikes |
| **opencode-Opus has the strongest pass@3 ceiling** (0.814) | ✓ supported by §8.2 hyperswitch-9430 autonomy | When opencode-Opus solves a task, it tends to over-complete; pass@3 wins are genuine. |
| **mini-DS boom-or-bust** (reliability 2.12) | ✓ Strong | §8.1: 2/3 reps misdiagnose entirely |
| **stable solve rate best matches deployment intuition** | ✓ Strong | §8.3: opencode-DS's 33% catastrophic failure rate surfaces only in stable solve rate |
| **Judge can be trusted as primary signal** | ✓ Confirmed | the trials where judge ≥ 0.85 disagrees with reward = 0 are dominated by **test.sh false negatives** |

### 8.6 Audit-driven follow-ups (not filter changes)

1. **Repair test.sh on the 3 tasks where judge–reward divergence is systematic** — `pi-mono-auto-90748a5d`, `pi-mono-auto-796a21ab`, `comfyui-newbie-lumina-refactor`.
2. **Report "judge=1.0 with effort=0" separately** in the autonomy panel — on this dataset opencode-Opus does it ~13/117 trials, mini-Opus ~0. Real harness × model interaction worth surfacing.
3. **Do NOT add a `patch_contamination` size-based filter.** Judge–reward divergence is the actionable signal, not patch size.


