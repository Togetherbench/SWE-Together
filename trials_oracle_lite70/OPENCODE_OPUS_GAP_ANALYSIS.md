# Why opencode-Opus replay scores far below the oracle ceiling

**Companion to the oracle-ceiling trials in this folder.** This note explains the gap
between the oracle ceiling (reference patches scored against their own frozen
`canonical_goals.json` rubric) and a same-or-stronger model replayed live through the
opencode harness.

- Oracle ceiling (60 lite70 tasks with a canonical patch): **mean judge_score 0.95**, 56/60 ≥ 0.85.
  See the per-task verdicts under `trials_oracle_lite70/<task>__oracle/judge_verdict.json`.
- opencode-Opus (`openrouter/anthropic/claude-opus-4-6`, `trials_opencode/trials_70_opencode_opus_r{1,2,3}`):
  **mean judge_score 0.73**, pass@1 (per-trial judge ≥ 0.85) = **0.60** over 210 scored trials.

**Bottom line: the gap is mostly a measurement / harness artifact, not a model-capability gap.**
Opus demonstrably *can* solve these tasks — many tasks have at least one replicate at ≈1.0.
The 0.95 → 0.73 drop decomposes into five mechanisms; the first is conceptual (the rubric),
the rest are harness/extraction/stability, and an infra-sentinel blind spot hides them all.

The oracle is graded against a rubric **derived from the oracle itself**, so it is ≈1.0 by
construction. A live replay must additionally survive: the user-simulator, the opencode
harness, `repo_diff.py` patch extraction, and a prescriptive oracle-shaped rubric.

---

## Biggest oracle → Opus gaps (mean over r1–r3)

| task | oracle | opus mean | reps (r1,r2,r3) | dominant cause |
|---|---|---|---|---|
| pi-mono-auto-796a21ab | 1.00 | 0.00 | 0.0 / 0.0 / 0.0 | #2 catastrophic extraction (759-file whole-repo diff) |
| linux-amdgpu-dkms-convert | 0.94 | 0.00 | 0.0 / 0.0 / 0.0 | #3 work outside `/workspace`, empty patch |
| agent-swarm-task-4a881b | 1.00 | 0.27 | 0.2 / 0.4 / 0.2 | #1 prescriptive rubric (valid alt design) |
| cli-task-0ec2e9 | 1.00 | 0.29 | 0.16 / 0.36 / 0.36 | #5 real partial (one code path missed, w=0.35) |
| arr-monitor-add-processes-flag | 1.00 | 0.33 | 0.0 / 0.0 / 1.0 | #4 run-to-run instability |
| pi-mono-extension-loader-priority | 1.00 | 0.33 | 1.0 / 0.0 / 0.0 | #4 run-to-run instability |
| sageattention-rebase-conflicts | 1.00 | 0.34 | 0.34 / 0.34 / 0.34 | #2/#5 partial rebase + bloated diff |
| flash-attention-autotune-cache | 1.00 | 0.38 | 0.14 / 0.93 / 0.07 | #4 early termination (minimal patch r1/r3) |

---

## The five mechanisms

### 1. The rubric is "oracle-shaped" and prescriptive — the largest conceptual driver

`canonical_goals.json` is generated (Phase 1) from the task spec **+ the oracle patch**, so its
goals encode the oracle's specific columns, API names, and decomposition. A capable model that
solves the task a *different but valid* way is penalized.

**Evidence — `agent-swarm-task-4a881b`** (opus 0.2/0.4/0.2 vs oracle 1.0): the agent shipped a
*working* one-time-schedule feature using a `runAt` column + `oneTime` boolean filter, instead
of the oracle's `scheduleType: 'recurring' | 'one_time'` enum. The judge's own evidence repeatedly
confirms the functionality is present, then marks the goal unmet on naming:

> goal_4: "POST supports `runAt` … ✓. PUT supports `runAt` … ✓. **However: no `scheduleType` …**"
> goal_5: "has `oneTime` boolean filter … **However, there is no `scheduleType` filter**"
> goal_7: "`runAt` added to Zod schema … **But no `scheduleType` …**"

This is the [SWE-bench Verified narrow-test problem](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)
re-expressed at the rubric layer. It is a measurement bias, not a capability gap.

### 2. Catastrophic patch extraction (`repo_diff.py`)

`agent/final.patch` is produced by `repo_diff.py` as `cumulative vs harbor-base`. For a few
tasks it emits a near-whole-repo diff in which the judge cannot locate the real change.

- `pi-mono-auto-796a21ab`: **759 files / 6.4 MB**, every monorepo package, **0.0 on all 3 reps**.
  The agent actually ran 11 episodes (opencode.txt ≈ 501 KB) — the work happened; the *diff* is junk.
- `moltis-task-ffe9ec` (2052 files → 0.0), `vibecomfy-mcp-pr-integration` (1020 files → 0.0).

**Caveat — large diffs are usually fine.** Of 219 opus trials, 31 have ≥30-file patches and they
average **0.61**; many score a clean 1.0 (`cli-task-7e3475` 856 files → 1.0, `rudel-task-468289`
741 files → 1.0). File count alone is not the problem — only the catastrophic cases fail.

### 3. Empty patch — agent works outside the tracked workspace

`repo_diff` only captures `/workspace/<repo>`. When the task's real work lives elsewhere, the
patch is empty and scores 0 even though the agent ran correctly.

- `linux-amdgpu-dkms-convert`: agent ran fine (≈516 KB log, a real ROCm/mainline amdgpu DKMS plan)
  but operated in `~/amdgpu` / `~/amdgpu-mainline` (HOME). `final.patch` is just the header line.
  **0.0 on r1/r3** (r2 a tiny 1-file change, also 0).
- 4 opus trials total have an empty (<300 B) patch, all 0.0: also `comfyui-gemma3-sliding-window` r3,
  `comfyui-lumina-axes-lens` r1.

### 4. Run-to-run instability / early termination

The agent *can* solve the task (one replicate ≈1.0) but bails or stops early in others, dragging
the mean:

- `flash-attention-autotune-cache` [0.14, **0.93**, 0.07] — r1/r3 are the *same* 2438-byte patch
  (one autotune-key edit, then stop); r2 did the full 5-file change.
- `pi-mono-extension-loader-priority` [**1.0**, 0, 0], `arr-monitor-add-processes-flag` [0, 0, **1.0**],
  `desloppify-treesitter-plugins` [0, **1.0**].

This is a mix of user-simulator variance and opencode-harness flakiness.

### 5. Genuine partials, amplified by weight concentration

Some misses are real but minor, then heavily penalized because one goal carries most of the weight.

- `cli-task-0ec2e9` (weights g1=0.35, g2=0.35, g3/4/5=0.1): the agent implemented the dedup merge
  **and** tests correctly (goals 2/3/4 met) but applied the merge in only one of the two lifecycle
  handlers (`handleLifecycleTurnEnd`, not `handleLifecycleSubagentEnd`). That single missed path is
  goal_1 (w=0.35) → score 0.36.
- `sageattention-rebase-conflicts`: only part of the rebase conflicts resolved → stable 0.34.

---

## Cross-cutting: the infra sentinel is blind to opencode

Every opencode trial's `trial_infra.json` reports
`assistant_turn_count: 0, edit_tool_calls: 0, status: "ok"` — the sentinel's parser is written for
claude-code transcripts and does not parse the opencode trajectory at all. Consequently it flagged
**none** of the disasters above (759-file diff, empty patch) — all reported "ok". Any automated
triage of these cohorts is currently flying blind.

---

## Method (reproducible)

```bash
# Oracle ceiling (this folder): reference patch -> agent/final.patch, Phase 2 judge vs frozen rubric
#   built from scripts/canonical_plan_lite70.json (60/70 tasks have a canonical patch; 10 no_canonical)
uv run python -m eval.correctness.run_batch \
  --plan pipeline_logs/oracle_lite70_plan_correctness.json --workers 50 --skip-phase1

# Replay verdicts already on disk per trial:
#   trials_opencode/trials_70_opencode_opus_r{1,2,3}/<task>__<id>/judge_verdict.json
# final.patch composition: count "diff --git" occurrences; header is "=== /workspace/<repo> (cumulative vs harbor-base) ==="
```

Scored sample sizes: oracle 60 tasks; opus 210–219 trials across 3 replicates of 70 tasks.

---

## Suggested follow-ups

1. **Quantify the rubric bias (#1):** re-judge a sample of partials with an approach-agnostic rubric
   (function/behavior, not oracle naming) and measure how much score the prescriptive phrasing eats.
2. **Fix `repo_diff.py` (#2/#3):** bound/whitelist the diff so monorepo build/generated files don't
   produce whole-repo diffs (pi-mono-auto); and capture the task's actual work directory, not just
   `/workspace/<repo>` (linux-amdgpu).
3. **Teach the infra sentinel to read opencode trajectories (#4 detection):** real turn/edit counts +
   empty-patch and bloated-patch detectors, so these failures stop reporting "ok".
4. **Triage instability (#4):** for tasks with one good rep and two early-exits, check whether the
   user-sim terminated early or the agent stopped on its own.
