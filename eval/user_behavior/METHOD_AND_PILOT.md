# `eval/user_behavior` — LLM-judged user-side interaction metrics

Companion to [`eval/correctness/`](../correctness/). `correctness/` answers "did the agent produce the right patch?" (the headline `judge_score`); this package quantifies **what the user simulator had to do to get there** — three user-side diagnostics, all derived from the same per-trial LLM passes:

1. **User Coverage** — did the sim's messages cover the original human user's intents? (`recall` / `precision` / `overall`)
2. **User Effort** — how *specific* were the sim's directives? (`Σ tier_weight` over directive-bearing messages)
3. **User Correction** — how much *pushback* did the agent need? (`correction + 0.2·nudge` per trial)

Together with `judge_score` these let us read sim fidelity and interaction load as diagnostics alongside agent capability — they never rank the leaderboard (see [`eval/eval_design.md`](../eval_design.md)).

> **Naming note.** This package was formerly `eval/intent_coverage`. The Python module is now `eval.user_behavior`, but the per-trial verdict file is still **`intent_coverage_verdict.json`** (renaming it would collide with the legacy `user_behavior_verdict.json` and break the 2180 existing verdicts).

Closely related design docs:
- [`eval/correctness/METHOD_AND_PILOT.md`](../correctness/METHOD_AND_PILOT.md) — sibling pilot doc (test.sh vs agentic judge comparison; the same trial set)
- [`analysis/eval_metric.md`](../../analysis/eval_metric.md) — the disentanglement metric taxonomy this fits into

---

## What's in the box

```
eval/user_behavior/
├── extract_intents.py        # Stage 1 — per-task oracle intents, run once, cached
├── coverage_one.py           # Stage 2 — per-trial match table + Coverage scores
├── tag_messages.py           # Stage 3 — SPLIT judge: tag-call + tier-call (same model,
│                             #   default Gemini-3.1-Pro), merged → trial_msg_tags
├── adjudicate_3way.py        # Stage 3b (legacy) — 3-way correction adjudication; the
│                             #   split tagger reproduces it to ±0.04 (see eval/result.md)
├── user_metrics.py            # SINGLE SOURCE OF TRUTH — taxonomy, tier weights,
│                             #   user_effort() + user_correction() metric fns
├── run_batch.py              # Stage 4 — async batch wrapper (drives Stage 2)
└── prompts/
    ├── extract_intents_system.md
    ├── coverage_system.md          # match-table prompt (coverage only)
    ├── tag_messages_system.md      # Stage 3 tag-call — tags + frustration (no tier)
    └── tier_messages_system.md     # Stage 3 tier-call — specificity tier only
```

Per-task artifact (committed alongside each task):

```
harbor_tasks/<task>/oracle_intents.json   # cache of stage 1 output
```

Per-trial artifact (one file, written by Stage 2, then **augmented in place** by Stage 3):

```
trials_*/<trial>/intent_coverage_verdict.json
  ├── match_table + coverage_rate / weighted_coverage / scope_precision / overall_score   (Stage 2)
  ├── trial_msg_tags: [{trial_idx, tags:[...], tier, frustration}, ...]                    (Stage 3)
  └── user_effort + user_correction  (derived from trial_msg_tags via user_metrics)         (Stage 3)
```

`user_effort` and `user_correction` are **persisted** into the verdict by Stage 3 (top-level keys), derived from `trial_msg_tags` via `user_metrics.metrics_from_rows` — the single source of truth. `eval/run_eval.py::_tag_metrics` recomputes from the same deriver during aggregation, so the stored values and the aggregated values are always identical (the stored copy is a convenience for downstream readers; the tags remain the canonical input).

---

## Pipeline — four stages

### Pipeline at a glance

LLM passes: one **per task** (extract_intents, cached forever) and **three per trial** — `coverage_one` → match table, then Stage 3's split tagger makes two calls (tag-call → tags+frustration, tier-call → tier). All numeric scores — Coverage (`coverage_one`), and User Effort / User Correction (`user_metrics`) — are computed **deterministically in code**, never by the LLM. The LLM only does intent extraction, match-finding, and per-message tagging.

```mermaid
flowchart TD
  subgraph S1 ["Stage 1 — extract_intents.py (one-time per task, cached)"]
    O["harbor_tasks/&lt;task&gt;/oracle_session.jsonl"]
    O --> O1["load_oracle_user_turns:<br/>skip turn 0 (instruction.md), interrupts,<br/>continuations, &lt;10-char acks"]
    O1 --> O2["Gemini-3.1-Pro + extract_intents_system.md<br/>temperature 0"]
    O2 --> O3["validate intent ids, fields, kinds"]
    O3 --> OC["harbor_tasks/&lt;task&gt;/oracle_intents.json<br/>(cached, idempotent — --force to refresh)"]
  end

  subgraph S2 ["Stage 2 — coverage_one.py (per trial)"]
    T["trial dir → load_trial_sim_msgs<br/>(episode-N/user_decision.json, has_message=true)"]
    OC -.cached intents.-> M
    T --> M["build_user_message:<br/>(intents, trial_msgs) → prompt"]
    M --> J["Gemini-3.1-Pro + coverage_system.md<br/>match-table output ONLY:<br/>per_intent[matched_trial_idx, confidence, rationale]<br/>+ unmatched_trial_msgs[trial_idx, category, rationale]"]
    J --> N["normalize_match_table:<br/>type-check + fill missing intent ids +<br/>contradiction guard (null match w/ confidence > 0 → 0)"]
    N --> COMP["compute_scores (code, not LLM):<br/>coverage_rate     = matched (conf≥0.5) / n_intents<br/>weighted_coverage = mean(confidence) over intents<br/>scope_precision   = unique matched trial idxs / n_trial_msgs<br/>overall_score = round(0.70·weighted + 0.30·scope_precision, 2)"]
    COMP --> V["trials_*/&lt;trial&gt;/intent_coverage_verdict.json<br/>(match_table + coverage scores, rounded 2dp)"]
  end

  subgraph S2b ["Stage 3 — tag_messages.py (per trial, SPLIT judge)"]
    T --> TAG["Gemini-3.1-Pro, two calls/trial:<br/>tag-call (tag_messages_system.md → tags+frustration)<br/>tier-call (tier_messages_system.md → tier)"]
    TAG --> V2["merged per trial_idx, augments verdict in place:<br/>trial_msg_tags: [{trial_idx, tags:[...], tier, frustration}]"]
    V2 -.read by.-> KG["user_metrics (code, not LLM):<br/>user_effort = Σ tier_weight over directive msgs<br/>user_correction = Σ (correction + 0.2·nudge)"]
  end

  subgraph S3 ["Stage 4 — run_batch.py (cohort orchestration)"]
    PLAN["plan.json: [{trial_dir, task_dir, out_name}, ...]"] --> POOL
    POOL["asyncio.Semaphore(workers=5)"] -.calls Stage 2 in parallel.-> J
    V --> SUMM["pipeline_logs/&lt;tag&gt;_summary.json:<br/>status counts + per-job overall_score + elapsed"]
  end
```

### Stage 1 — `extract_intents.py` (one-time per task, cached)

Reads `harbor_tasks/<task>/oracle_session.jsonl` (the canonical human session) and decomposes the post-instruction user turns into atomic **intent units**.

Why decompose? Long plan documents (the `cli-task-46c118` PR-review plan, the multi-paragraph turn in `gemini-voyager`) carry several independent intents per turn. Treating them as one atomic match would lose partial-coverage signal. The extractor runs Gemini-3.1-Pro with `temperature=0` against the prompt in `prompts/extract_intents_system.md`, then validates and writes `oracle_intents.json`.

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
python -m eval.user_behavior.extract_intents \
    --task-dir harbor_tasks/cli-task-2a55af
```

### Stage 2 — `coverage_one.py` (per trial)

For one trial, this:

1. Loads cached intents (auto-extracts if missing)
2. Loads sim messages from `<trial>/agent/episode-*/user_decision.json` (only `has_message=true` ones)
3. Sends `(intents, trial_msgs)` to Gemini-3.1-Pro with the prompt in `prompts/coverage_system.md`
4. Gets back **only a match table** — `per_intent` (matched_trial_idx + match_confidence + rationale) and `unmatched_trial_msgs` (category + rationale)
5. Computes aggregate scores **in code, not by the LLM** (see formulas below)

The LLM does pattern-matching; arithmetic is deterministic. This is the key design choice — the LLM never does the scoring math.

```bash
python -m eval.user_behavior.coverage_one \
    --trial-dir trials_deepseek_pilot_10_task_r1/cli-task-2a55af__LXqASZW \
    --task-dir  harbor_tasks/cli-task-2a55af
```

Output (`<trial>/intent_coverage_verdict.json`):

```jsonc
{
  "schema_version": 2,
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
  "overall_score":     0.50,
  "judge_model": "gemini/gemini-3.1-pro-preview",
  "elapsed_sec": 4.1,
  "schema_warnings": [],
  "trial_msg_tags": [
    {"trial_idx": 0, "tags": ["request"], "tier": "prescriptive", "frustration": 0},
    {"trial_idx": 4, "tags": ["nudge", "question"], "tier": "diagnostic", "frustration": 0}
  ]
}
```

`overall_score` = `round(0.70·0.28 + 0.30·1.00, 2)` = **0.50**. `trial_msg_tags` is added by Stage 3 (`tag_messages.py`), which also persists `user_effort`/`user_correction` (derived from it via `user_metrics.metrics_from_rows`) as top-level keys.

### Stage 3 — `tag_messages.py` (per trial, SPLIT judge)

A per-trial pass tags **every** sim message via **two separate LLM calls on the same model** (default Gemini-3.1-Pro @ temp 0):

1. **tag-call** (`prompts/tag_messages_system.md`) — multi-label `tags` (from `{request, correction, nudge, question, verification, workflow, approval, context}`) + `frustration`.
2. **tier-call** (`prompts/tier_messages_system.md`) — the specificity `tier` (`none`…`patch_level`) only.

The two are **merged per `trial_idx`** into `{trial_idx, tags, frustration, tier}` and written to `trial_msg_tags` in the **same** verdict file (popping any legacy `trial_msg_specificity`). `user_metrics.py` then derives **User Effort** and **User Correction** (formulas below).

**Why split.** Asking one call to emit tags *and* tier conflates the two judgments and over-tags `correction`. Separating them lets each call focus on one axis; a single Gemini split pass averaged with a GPT-5.5 split pass reproduces the old 3-way `adjudicate_3way.py` reconciliation to **±0.04 with identical ranking** (full table in `eval/result.md`). The split is therefore the canonical Stage 3; `adjudicate_3way.py` (Stage 3b) is retained only as the reference it was validated against. For the reconciled-equivalent, re-run with a second `--model` and average the per-cohort metrics (`scripts/_split_compute.py`).

```bash
python -m eval.user_behavior.tag_messages \
    --trials-root trials/canonical_full109/opencode_opus_r1 \
    --force --workers 16          # needs GEMINI_API_KEY; --force re-tags existing verdicts
```

> **Ordering matters:** `coverage_one` rewrites the *whole* verdict (dropping `trial_msg_tags`), so Stage 2 (coverage) must run **before** Stage 3 (tagging). `eval/run_eval.py` enforces this ordering.

### Stage 4 — `run_batch.py` (cohort-level wrapper)

Plan-file driven, asyncio.Semaphore concurrency control. Mirrors `eval/correctness/run_batch.py` shape so the two evaluators have parallel CLIs.

```bash
python -m eval.user_behavior.run_batch \
    --plan pipeline_logs/intent_coverage_plan.json \
    --workers 5 \
    --summary pipeline_logs/intent_coverage_summary.json
# Defaults to --model gemini/gemini-3.1-pro-preview (uses GEMINI_API_KEY).
# Pass --model anthropic/claude-opus-4-6 to fall back to Opus (needs
# CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY with budget).
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

Three user-side metrics, all deterministic. **Coverage** comes from `coverage_one.py` (off the match table); **User Effort** and **User Correction** come from `user_metrics.py` applied to `trial_msg_tags`.

### 1. User Coverage — `coverage_one.py`

```python
MATCH_CONFIDENCE_FLOOR_FOR_COVERED = 0.5
W_COVERAGE  = 0.70          # was 0.65
W_PRECISION = 0.30          # was 0.35

coverage_rate     = matched intents (conf ≥ 0.5) / n_intents          # "recall" (hard)
weighted_coverage = mean(match_confidence over all intents)           # soft recall
scope_precision   = unique trial idxs used as a match / n_trial_msgs  # "precision"
overall_score     = round(W_COVERAGE * weighted_coverage + W_PRECISION * scope_precision, 2)
```

All four metrics are rounded to **2 decimals** on write. `overall` is built from `weighted_coverage` (soft), **not** the `coverage_rate` recall column. Weight balance (0.70 / 0.30): coverage matters more than precision because **missing an oracle intent is a sim regression**, while a sim adding a legitimate extra question is fine.

Edge cases:
- `n_intents = 0` (oracle has no follow-up) — `coverage_rate = weighted_coverage = 1.0`; `scope_precision = 0` if any trial msg fired (means the sim invented intents) else `1.0`
- `n_trial_msgs = 0` (sim silent) — `scope_precision = 0`
- a single trial msg matching multiple intents counts ONCE in `scope_precision` (deliberate — discourages credit-stuffing)

### 2. User Effort & User Correction — `user_metrics.py` (from `trial_msg_tags`)

These are derived from the per-message multi-label tags (`tag_messages.py`), not from the coverage judge. `user_metrics.py` is the single source of truth for the taxonomy + weights:

```python
SPECIFICITY_WEIGHTS = {"none":0, "vague":1, "directional":2,
                       "diagnostic":3, "prescriptive":4, "patch_level":5}
DIRECTIVE_BEARING   = {"request", "verification", "correction", "nudge"}   # only these cost effort
FREE                = {"workflow", "approval", "context"}                  # 0 effort

# User Effort (= "User Input"): per message, the tier weight iff it carries a directive
user_effort     = Σ_msgs  tier_weight(tier)  if has_directive(tags)  else 0
# User Correction: explicit correction = 1, implicit nudge = 0.2
user_correction = Σ_msgs  ( 1·[correction in tags] + 0.2·[nudge in tags] )
```

Aggregated **per task (mean over reps), then across tasks** — the same way Coverage is. These replace the legacy single-label `trial_msg_specificity` / `effort_cost` that `coverage_one` used to emit: the *producer* moved to the multi-label `tag_messages` tagger (so old vs new cohorts must use the same tagger — re-tag old cohorts before comparing), but the formula (`Σ tier_weight` over directives) is unchanged. `eval/run_eval.py::_tag_metrics` computes these identically.

---

## Final report — `canonical_full109` per-model user-behavior metrics

Per-model user-side metrics on the `canonical_full109` set: **109 tasks × 2 replicates = 218 trials per model**, judged/tagged by the default **Gemini-3.1-Pro**. Each number is aggregated **per task (mean over reps), then across the 109 tasks** (`trials/canonical_full109/opencode_<model>_r{1,2}`). Coverage rounded to **2 decimals** (0.70/0.30 formula).

**Column definitions:**

```text
recall      = coverage_rate    = matched intents (conf ≥ 0.5) / n_intents
precision   = scope_precision  = unique matched trial msgs / n_trial_msgs
coverage    = overall_score    = round(weighted_coverage·0.70 + scope_precision·0.30, 2)
effort      = user_effort       = Σ tier_weight over directive msgs (per trial)   ↓ = less user input
correction  = user_correction   = Σ (correction + 0.2·nudge) (per trial)          ↓ = less pushback
```

| model | recall | precision | coverage | effort | correction |
|---|---|---|---|---|---|
| `claude-opus-4.8` | 0.73 | 0.67 | 0.70 | 10.85 | 1.58 |
| `claude-opus-4.6` | 0.74 | 0.70 | 0.72 | 11.45 | 1.78 |
| `glm-5.2`         | 0.72 | 0.67 | 0.70 | 11.49 | 1.62 |
| `glm-5.1`         | 0.74 | 0.72 | 0.72 | 11.20 | 1.66 |
| `deepseek-v4-pro` | 0.74 | 0.71 | 0.72 | 11.99 | 1.86 |
| `gpt-5.5`         | 0.65 | 0.62 | 0.64 | 12.22 | 2.11 |
| `minimax-2.7`     | 0.73 | 0.66 | 0.70 | 14.01 | 2.30 |

> **Why `coverage ≠ recall·0.70 + precision·0.30`.** The `recall` column is `coverage_rate` (hard — an intent counts only at confidence ≥ 0.5), but `coverage` is built from `weighted_coverage` (soft — mean match-confidence), which runs slightly below `coverage_rate`. Soft term per model: opus-4.8 0.71, opus-4.6 0.72, glm-5.2 0.71, glm-5.1 0.72, deepseek 0.73, gpt-5.5 0.64, minimax 0.72 — substitute into `·0.70 + precision·0.30` and `coverage` reconciles. `weighted_coverage` isn't its own column; it lives inside `coverage`.

**Tagger consistency.** All 7 cohorts were tagged by the current `tag_messages` tagger (old cohorts re-tagged 2026-06), so `effort`/`correction` are on one scale. The legacy single-label tagger ran ~2–3 effort-points higher (e.g. opus-4.6 was ≈14.5 under the old producer, ≈11.5 under the current one) — never mix tagger eras on the User-Effort axis.

**Diagnostic only — does not rank models.** These measure *sim fidelity + interaction load*, not agent quality; per [`eval/eval_design.md`](../eval_design.md) they never order the leaderboard. The ranking even inverts against capability: `gpt-5.5` trails `deepseek-v4-pro` on coverage (0.64 vs 0.72) yet **beats** it on `judge_score` (0.690 vs 0.679). Reading the effort/correction columns: opus-4.8 needs the least user input (10.85) and pushback (1.58); minimax the most (14.01 / 2.30). The headline ranking dimension remains `judge_score`.

---

## Empirical motivation — per-task sim consistency case studies (10 tasks × 3 cohorts)

The 10 tasks below are the [`eval/correctness/METHOD_AND_PILOT.md`](../correctness/METHOD_AND_PILOT.md) pilot set (DS-Pro coding agent + Gemini-3.1-Pro free-LLM user-sim, no graph constraint). For each task we show the verbatim sim trace across 3 cohorts (or 4 for `comfyui`), classify the cohort-to-cohort consistency, and report whether sim divergence affected the agent's score. These observations are the empirical basis for the validation tables that follow.

(Originally §Q1 of the pilot doc; moved here so this README is the canonical home for user-simulator analysis. The pilot doc retains the test.sh-vs-agentic-judge comparison only.)


### 1. `cli-task-2a55af` — **partial-converge**

- n cohorts: 3  ·  intervention count per cohort: [5, 13, 8]  ·  patch lines per cohort: [572, 486, 91]
- live σ=0.000  ·  clean σ=0.000  ·  judge σ=0.387

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (5 intv, 10 turns) ---
  t 1 [new_requirement] yeah let's do the fix for 1 first
  t 2 [new_requirement] ok, let's fix the ending next, what would you propose?
  t 4 [new_requirement] now handle: 2. .gemini/ directory not protected during rewind (MEDIUM) common.go:191 defines only claudeDir = '.claude' for skip/protect lis
  t 5 [new_requirement] 3. .gemini/ not skipped in collectUntrackedFiles() (LOW) Gemini's config directory would get collected as untracked files at session start -

--- cohort 2 (13 intv, 14 turns) ---
  t 1 [new_requirement] yeah let's do the fix for 1 first
  t 2 [new_requirement] yeah do it
  t 3 [new_requirement] now handle: 2. .gemini/ directory not protected during rewind (MEDIUM) common.go:191 defines only claudeDir = '.claude' for skip/protect lis
  t 4 [new_requirement] 3. .gemini/ not skipped in collectUntrackedFiles() (LOW) Gemini's config directory would get collected as untracked files at session start -

--- cohort 3 (8 intv, 10 turns) ---
  t 1 [redirect      ] wait, check if RestoreLogsOnly is hardcoded to Claude, and if .gemini/ is protected or skipped in collectUntrackedFiles. are you sure it's c
  t 2 [redirect      ] wait, look closer at RestoreLogsOnly and the transcript parsing, is there any hardcoded .claude or .jsonl stuff? and what about isProtectedP
  t 3 [redirect      ] wait, check common.go for isProtectedPath, doesn't it hardcode claudeDir = '.claude'? and look at how the session file path is resolved in m
  t 4 [redirect      ] wait, look at manual_commit_rewind.go around line 670 - isn't the session file path hardcoding .jsonl? and look at common.go around line 191

```

**Sim partially diverged — intervention count varies widely** (range 5–13). The longer cohort(s) raised follow-up issues other cohorts did not, contributing to score divergence.

- ⚠ **Score impact**: judge range 0.00-0.67 (Δ=0.67). Sim divergence likely contributing.

---

### 2. `cli-task-2f5833` — **partial-converge**

- n cohorts: 3  ·  intervention count per cohort: [2, 3, 3]  ·  patch lines per cohort: [247, 272, 285]
- live σ=0.126  ·  clean σ=0.126  ·  judge σ=0.032

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (2 intv, 6 turns) ---
  t 1 [new_requirement] If we find that there are carry over files, we should not delete the prompt.txt from the metadata directory
  t 2 [new_requirement] commit those changes...

--- cohort 2 (3 intv, 7 turns) ---
  t 1 [new_requirement] If we find that there are carry over files, we should not delete the prompt.txt from the metadata directory
  t 2 [redirect      ] If we find that there are carry over files, we should not delete the prompt.txt from the metadata directory
  t 3 [new_requirement] commit those changes...

--- cohort 3 (3 intv, 7 turns) ---
  t 1 [new_requirement] If we find that there are carry over files, we should not delete the prompt.txt from the metadata directory
  t 2 [redirect      ] add the cleanup then. but if we find that there are carry over files, we should not delete the prompt.txt from the metadata directory
  t 3 [new_requirement] commit those changes...

```

**Sim partially diverged but at similar depth**. Some cohorts opened with different first messages but converged on the same task scope.

- Score impact: judge range tight (0.63-0.69).

---

### 3. `cli-task-46c118` — **IDENTICAL**

- n cohorts: 3  ·  intervention count per cohort: [2, 2, 2]  ·  patch lines per cohort: [57, 52, 59]
- live σ=0.000  ·  clean σ=0.000  ·  judge σ=0.131

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (2 intv, 6 turns) ---
  t 1 [question      ] is IsPaneDead necessary / valuable?
  t 2 [new_requirement] commit and push

--- cohort 2 (2 intv, 6 turns) ---
  t 1 [question      ] is IsPaneDead necessary / valuable?
  t 2 [new_requirement] commit and push

--- cohort 3 (2 intv, 6 turns) ---
  t 1 [question      ] is IsPaneDead necessary / valuable?
  t 2 [new_requirement] commit and push

```

**Sim contributed 0 variance** (every cohort got the same 2-message correction sequence). Score variance is therefore 100% from agent randomness.

- ⚠ **Score impact**: judge range 0.69-0.93 (Δ=0.24). Sim divergence likely contributing.

---

### 4. `cli-task-7e3475` — **IDENTICAL** *(replaces `cli-task-4a9dde`; see [issue #159](https://github.com/Togetherbench/SWE-Together/issues/159))*

- n cohorts: 3  ·  intervention count per cohort: [2, 3, 2]  ·  patch lines per cohort: [210817, 210817, 210817]
- live σ=0.000  ·  clean σ=0.000  ·  judge σ=0.035

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (2 intv, 6 turns) ---
  t 1 [new_requirement] commit and push this
  t 2 [new_requirement] pull main and rebase this branch onto it and then push it

--- cohort 2 (3 intv, 7 turns) ---
  t 1 [new_requirement] commit and push this
  t 2 [new_requirement] pull main and rebase this branch onto it and then push it
  t 3 [redirect      ] wait no, the patch failed to apply so of course there's no diff. you need to actually get these changes onto a branch based on main and force push it.

--- cohort 3 (2 intv, 6 turns) ---
  t 1 [new_requirement] commit and push this
  t 2 [new_requirement] pull main and rebase this branch onto it and then push it

```

**Sim is effectively identical across cohorts** (every cohort opens with the same two messages verbatim; r2 adds one redirect when the rebase didn't take). Patch lines are byte-identical at 210,817 across all 3 cohorts — the diff is dominated by the rebase-introduced re-application of upstream commits, so post-patch state is fully deterministic. Score variance is therefore 100% from agent randomness (which is small here: judge σ=0.035).

- Score impact: judge range tight (0.89-0.95). Sim contributes 0 variance.

---

### 5. `cli-task-f76665` — **DIVERGENT**

- n cohorts: 3  ·  intervention count per cohort: [1, 7, 6]  ·  patch lines per cohort: [388, 476, 560]
- live σ=0.000  ·  clean σ=0.000  ·  judge σ=0.119

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (1 intv, 1 turns) ---
  t 1 [redirect      ] wait looking at the updated TestPostCommit_StaleActiveSession_NowCondenses... I'm struggling with this now, can you expand a bit the reasoni

--- cohort 2 (7 intv, 7 turns) ---
  t 1 [redirect      ] Wait, looking at TestPostCommit_StaleActiveSession_NotCondensed... I'm struggling with this now, can you expand a bit the reasoning on why a
  t 2 [question      ] is there a hook that fires on git commit tool calls? might be better for liveness signaling than a time threshold
  t 3 [question      ] i wonder if we could introduce a generic "alive" hook, that we configure in more places where hooks are called and by that get a better sign
  t 4 [question      ] would this work for non claude agents too? like opencode or gemini

--- cohort 3 (6 intv, 6 turns) ---
  t 1 [question      ] wait looking at TestPostCommit_StaleActiveSession_NotCondensed... why should a stale active session condense into an unrelated commit? I'm s
  t 2 [question      ] is there a hook that fires when the agent calls the git commit tool? that might be a better signal than a time threshold
  t 3 [new_requirement] I wonder if we could introduce a generic 'alive' hook, that we configure in more places where hooks are called and by that get a better sign
  t 4 [question      ] would that work for other agents? like OpenCode or Gemini?

```

**Sim fully diverged** — every cohort opened with a different first message, conversations don't overlap. Each trial is effectively measuring a different (agent, sim-path) pair.

- ⚠ **Score impact**: judge range 0.78-1.00 (Δ=0.22). Sim divergence likely contributing.

---

### 6. `cluefin-task-52eab9` — **front-converged**

- n cohorts: 3  ·  intervention count per cohort: [5, 5, 5]  ·  patch lines per cohort: [178, 181, 182]
- live σ=0.278  ·  clean σ=0.278  ·  judge σ=0.040

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (5 intv, 10 turns) ---
  t 1 [redirect      ] discussion은 없습니다. 수정해줘
  t 2 [new_requirement] uv.lock을 지금 commit에 합쳐줘
  t 3 [new_requirement] /commit
  t 4 [redirect      ] 직접 git commit 해줘. 메시지는 한국어로.

--- cohort 2 (5 intv, 11 turns) ---
  t 1 [redirect      ] discussion은 없습니다. 수정해줘
  t 2 [new_requirement] uv.lock을 지금 commit에 합쳐줘
  t 3 [redirect      ] uv.lock만 진행해줘
  t 4 [new_requirement] /commit

--- cohort 3 (5 intv, 9 turns) ---
  t 1 [redirect      ] discussion은 없습니다. 수정해줘
  t 2 [new_requirement] uv.lock을 지금 commit에 합쳐줘
  t 3 [redirect      ] uv.lock만 진행해줘
  t 4 [new_requirement] /commit

```

**Sim converged on the substantive correction** (first 1-2 messages identical) but diverged on slash-command / cleanup mechanics. Score variance not driven by sim.

- Score impact: judge range tight (0.93-1.00).

---

### 7. `comfyui-frontend-autoscale-layout` — **partial-converge**

- n cohorts: 4  ·  intervention count per cohort: [5, 4, 5, 3]  ·  patch lines per cohort: [132, 80, 176, 3208]
- live σ=0.225  ·  clean σ=0.144  ·  judge σ=0.053

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (5 intv, 9 turns) ---
  t 1 [redirect      ] Why did you add a magic number 10 in `const snapSize = settingStore.get('Comfy.SnapToGrid.GridSize') || 10`?
  t 2 [redirect      ] wait you didn't actually write any code to implement it yet. modify the code to make it respect always snap to grid
  t 3 [question      ] Are you sure that all 4 corners of each node are snapped to the grid?
  t 4 [question      ] Why it uses `lgNode.width` but not `lgNode.height`?

--- cohort 2 (4 intv, 8 turns) ---
  t 1 [question      ] Why did you add a magic number 10 in `const snapSize = settingStore.get('Comfy.SnapToGrid.GridSize') || 10`?
  t 2 [redirect      ] wait you haven't actually edited ensureCorrectLayoutScale.ts yet. go ahead and implement it.
  t 3 [question      ] Are you sure that all 4 corners of each node are snapped to the grid?
  t 4 [redirect      ] Run `pnpm build` and fix the error

--- cohort 2 (5 intv, 9 turns) ---
  t 1 [redirect      ] Why did you add a magic number 10 in `const snapSize = settingStore.get('Comfy.SnapToGrid.GridSize') || 10`?
  t 2 [question      ] Are you sure that all 4 corners of each node are snapped to the grid?
  t 3 [new_requirement] so implement it then
  t 4 [question      ] Why it uses `lgNode.width` but not `lgNode.height`?

--- cohort 3 (3 intv, 8 turns) ---
  t 2 [question      ] Are you sure that all 4 corners of each node are snapped to the grid?
  t 3 [question      ] Why it uses `lgNode.width` but not `lgNode.height`?
  t 4 [question      ] Run `pnpm build` and fix the error

```

**Sim partially diverged but at similar depth**. Some cohorts opened with different first messages but converged on the same task scope.

- Score impact: judge range tight (0.82-0.93).

---

### 8. `gemini-voyager-task-18a6ae` — **DIVERGENT**

- n cohorts: 3  ·  intervention count per cohort: [5, 4, 4]  ·  patch lines per cohort: [18414, 255, 17900]
- live σ=0.000  ·  clean σ=0.144  ·  judge σ=0.432

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (5 intv, 9 turns) ---
  t 1 [new_requirement] 好呀，就这么干吧。如果使用原生 Chrome i18n 的话，是不是会更好？然后会影响 Firefox 和 Safari 吗？
  t 2 [redirect      ] 等等，你光回答问题了，还没写那个去掉 description 的 vite 插件呢
  t 3 [question      ] 大概能减少多少体积呢？
  t 4 [question      ] 你确定这次提交不会对任何功能和任何平台造成任何影响吧？

--- cohort 2 (4 intv, 8 turns) ---
  t 1 [new_requirement] 那有没有办法把冗余的 description 字段在构建时去掉减小体积？比如写个 vite 插件？另外如果使用原生 Chrome i18n 的话，是不是会更好？然后会影响 Firefox 和 Safari 吗？
  t 2 [redirect      ] 你的回答断了，继续说。然后直接帮我把去掉 description 的 vite 插件实现了吧。
  t 3 [question      ] 你确定这次提交不会对任何功能和任何平台造成任何影响吧？
  t 4 [new_requirement] 继续说完。然后 bun run build你看看

--- cohort 3 (4 intv, 9 turns) ---
  t 1 [question      ] 展开说说，浪费在哪里？有什么具体的改进方案吗？
  t 2 [question      ] 好呀，就这么干吧。如果使用原生 Chrome i18n 的话，是不是会更好？然后会影响 Firefox 和 Safari 吗？
  t 4 [redirect      ] 你确定这次提交不会对任何功能和任何平台造成任何影响吧？
  t 5 [question      ] bun run build你看看

```

**Sim fully diverged** — every cohort opened with a different first message, conversations don't overlap. Each trial is effectively measuring a different (agent, sim-path) pair.

- ⚠ **Score impact**: judge range 0.00-0.86 (Δ=0.86). Sim divergence likely contributing.

---

### 9. `rudel-task-468289` — **IDENTICAL** *(replaces `rudel-task-d64e5a`; see [issue #159](https://github.com/Togetherbench/SWE-Together/issues/159))*

- n cohorts: 3  ·  intervention count per cohort: [2, 3, 2]  ·  patch lines per cohort: [335, 350, 381]
- live σ=0.000  ·  clean σ=0.000  ·  judge σ=0.118

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (2 intv, 6 turns) ---
  t 1 [new_requirement] seems to work please commit changes and open PR
  t 2 [new_requirement] Base directory for this skill: /Users/rafa/Obsession/rudel/.claude/skills/pr-creation

# PR Creation Checklist
…

--- cohort 2 (3 intv, 9 turns) ---
  t 1 [new_requirement] seems to work please commit changes and open PR
  t 2 [redirect      ] wait follow the pr creation checklist, run bun run verify first and review the diff
  t 5 [new_requirement] ok that's fine, we're done here

--- cohort 3 (2 intv, 6 turns) ---
  t 1 [new_requirement] seems to work please commit changes and open PR
  t 2 [new_requirement] Base directory for this skill: /Users/rafa/Obsession/rudel/.claude/skills/pr-creation

# PR Creation Checklist
…

```

**Sim opens identically across all 3 cohorts** (t1 verbatim everywhere). r1/r3 then deliver the PR-creation skill checklist; r2 nudges the agent to run verify first. Sim variance is small (overall σ=0.078); patch-quality variance is real and shows up at judge level (σ=0.118) because only r2 made meaningful progress on the optional ChartTooltip refactor. Same regime as `cli-task-46c118` — sim tight, agent noisy on secondary work.

- Score impact: judge range 0.70-0.93 (Δ=0.23). Spread is agent-side, not sim-side.

---

### 10. `sd-scripts-reg-image-dedup` — **partial-converge**

- n cohorts: 3  ·  intervention count per cohort: [5, 5, 7]  ·  patch lines per cohort: [112, 144, 139]
- live σ=0.087  ·  clean σ=0.087  ·  judge σ=0.214

**Sim messages (first 4 non-no-op per cohort):**

```
--- cohort 1 (5 intv, 9 turns) ---
  t 1 [new_requirement] ok refactor it to remove duplicate code in reg image balancing. handle the edge case of zero reg images. also fix the redundant double call 
  t 2 [redirect      ] wait no, for the double call fix, use an `update_counts: bool = True` parameter on `filter_registered_images_by_orig_resolution` -- DreamBoo
  t 3 [question      ] Why do we need to call register_regularization_images at two places, then call rebalance_regularization_images ? Can't we always register re
  t 4 [new_requirement] Ok I've did some cleanup. Now check another issue: In every dataset type, does every conditioning image correctly match the main image after

--- cohort 2 (5 intv, 10 turns) ---
  t 1 [new_requirement] Refactor it to remove duplicate code in reg imag balancing. Handle the edge case of zero reg images. Also fix the redundant double call to u
  t 3 [redirect      ] Use an `update_counts: bool = True` parameter on `filter_registered_images_by_orig_resolution` -- DreamBooth passes `False` so base skips th
  t 4 [question      ] Why do we need to call register_balanced_regularization_images at two places, then call rebalance_regularization_images ? Can't we always re
  t 5 [new_requirement] Ok I've did some cleanup. Now check another issue: In every dataset type, does every conditioning image correctly match the main image after

--- cohort 3 (7 intv, 11 turns) ---
  t 1 [new_requirement] Refactor it to remove duplicate code in reg imag balancing. Handle the edge case of zero reg images. Also fix the redundant double call to u
  t 2 [redirect      ] Don't remove `rebalance_regularization_images` -- it's needed when external code calls filter on an already-initialized dataset. Restore it 
  t 3 [question      ] Why do we need to call register_balanced_regularization_images at two places, then call rebalance_regularization_images ? Can't we always re
  t 4 [new_requirement] Ok I've did some cleanup. Now check another issue: In every dataset type, does every conditioning image correctly match the main image after

```

**Sim partially diverged but at similar depth**. Some cohorts opened with different first messages but converged on the same task scope.

- ⚠ **Score impact**: judge range 0.59-1.00 (Δ=0.41). Sim divergence likely contributing.


