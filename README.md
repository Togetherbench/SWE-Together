# SWE-Together

A benchmark derived from real multi-turn coding sessions, measuring **coding agent performance under iterative user correction** — the loop that single-turn benchmarks ignore.

**Live traces:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials)

---

## The Gap

Current coding agent benchmarks assume a Platonic ideal solver: one prompt, one solution. Real users are embedded in a correction loop — they have partial specs, discover requirements iteratively, and satisfaction is revealed incrementally.

```
Single-turn benchmarks:          Real coding sessions:
─────────────────────            ──────────────────────
Task prompt → Solution           Task prompt → Agent attempt
      ↓                                ↓
  Pass/Fail                      User: "no that's wrong, also..."
                                       ↓
                                 Agent attempt 2
                                       ↓
                                 User: "close but can you also..."
                                       ↓
                                 ... (N turns) → User accepts / abandons
```

## Benchmark

**101 tasks** under `harbor_tasks/` (v0.4.3-prep), all derived from **real recorded coding sessions** across three sourcing waves: DataClaw publishers via `peteromallet/dataclaw` (46 tasks), the `pi_staging` harvest of `pi-share-hf` exports (32 tasks: 31 `pi-mono-*` + 1 `pi-excel-*`), and `archit11/claude_traces_hs` Hyperswitch traces (23 tasks). DataClaw sessions are filtered to repos with 20+ GitHub stars. No synthetic tasks. Each task has a Docker environment, a natural-language instruction (the real user's first message, verbatim), and a deterministic verifier with `F2P` (weighted) and `P2P_REGRESSION` (gating) gate types.

The key differentiator: an **LLM-powered user simulator** (Gemini 3.1 Pro by default) watches the agent work and injects corrections, redirects, and new requirements based on the original session's ground truth — recreating the multi-turn correction loop. Headline metric is **multi-turn gain = Final − T0**, scored at three checkpoints (`nop`, `after_instruction`, `after_user_turn_N`).

### Results — v0.4.3 (5 cohorts × ~100 tasks)

> **Benchmark version:** `togetherbench@0.4.3` (101 tasks on `v0.4.3-prep`, user sim v0.6.0). Full numbers in `analysis/V043_REPORT.md`.
>
> Results are tied to a specific benchmark version. The task set, user simulator, and test scripts all change between versions; always reference the version when citing results.

**Clean mean** (broken trials excluded):

| rank | cohort | model | clean_mean | n |
|---|---|---|---|---|
| 1 | opus46_high      | `anthropic/claude-opus-4-6` (effort=high)    | **0.4961** | 91 |
| 2 | deepseek_v4_flash | `deepseek/deepseek-v4-flash`                 | **0.4728** | 93 |
| 3 | deepseek_v4_pro   | `deepseek/deepseek-v4-pro`                   | **0.4465** | 93 |
| 4 | minimax27        | `minimaxd/MiniMax-M2.7`                       | **0.4084** | 96 |
| 5 | minimax25        | `minimaxd/MiniMax-M2.5`                       | **0.3333** | 97 |

**Shared-task fair comparison** (n=89 tasks attempted by every cohort):

| rank | cohort | mean |
|---|---|---|
| 1 | opus46_high       | 0.4858 |
| 2 | deepseek_v4_flash | 0.4506 |
| 3 | deepseek_v4_pro   | 0.4449 |
| 4 | minimax27         | 0.3916 |
| 5 | minimax25         | 0.3367 |

**User-turn behaviour** (all cohorts run through the same v0.6.0 sim):

| cohort | avg turns | intervene% | no-op% |
|---|---|---|---|
| deepseek_v4_flash | 9.46 | 43.4% | 45.1% |
| deepseek_v4_pro   | 7.74 | 41.4% | 44.1% |
| minimax25         | 10.17 | 47.8% | 41.4% |
| minimax27         | 9.67 | 42.0% | 45.9% |

DeepSeek runs the longest sessions with the most no-ops (agent mostly on-track); MiniMax cohorts intervene more (agent outputs need correction more often).

> Opus 4.7 was tested but excluded from the leaderboard: CC v2.1.108 sends `thinking.type=enabled`, while Opus 4.7 only accepts `thinking.type=adaptive` → all trials 400'd. Opus 4.6 with `effort=high` is the canonical Anthropic baseline for v0.4.3.

---

## Quick Start

### Setup

```bash
git clone https://github.com/Togetherbench/SWE-Together.git
cd SWE-Together

# Install dependencies (use uv, not pip)
uv sync
```

Pin to a release tag (`git checkout v0.4.3-…`) when reproducing published numbers — the task set, user simulator, and test scripts evolve.

### Running the full eval (production path)

`src/run_eval.py` is the production async evaluator. It drives Harbor's `LocalOrchestrator` across N concurrent E2B sandboxes (default 25 workers), launches the in-sandbox LiteLLM proxy per trial, and writes per-cohort `trials_<cohort>_v043/<task>__<id>/` directories.

```bash
# Anthropic (no proxy needed)
ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model anthropic/claude-opus-4-6 --effort high \
    --cohort opus46_high

# DeepSeek (Anthropic-compat via proxy)
DEEPSEEK_API_KEY=<key> ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model deepseek/deepseek-v4-flash --cohort deepseek_v4_flash

# MiniMax direct (Anthropic-compat via proxy)
MINIMAX_API_KEY=<key> ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model minimaxd/MiniMax-M2.7 --cohort minimax27

# z.ai GLM direct (Anthropic-compat via proxy)
ZAI_API_KEY=<key> ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model glmd/glm-5.1 --cohort glmd

# ARK (Volcengine — Bearer auth)
ARK_API_KEY=<key> ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model ark/kimi-k2.6 --cohort ark_kimi
```

Default user-sim model: `openrouter/google/gemini-3.1-pro-preview`. See `src/run_eval.py:build_agent_env` for every supported provider prefix.

### Running a single task (debugging)

```bash
ANTHROPIC_API_KEY=<key> uv run python src/runner.py \
    --task sageattention-headdim-256 \
    --model anthropic/claude-sonnet-4-6
```

Trial output: `trials/<task>__<id>/verifier/reward.txt`.

### Building the leaderboard

```bash
uv run python scripts/build_leaderboard.py \
    --cohorts trials_opus46_high_v043 trials_deepseek_v4_flash_v043 \
              trials_deepseek_v4_pro_v043 trials_minimax27_v043 trials_minimax25_v043 \
    --out analysis/v043_leaderboard
```

Produces `v043_leaderboard.{json,md}` with clean-mean, shared-task, and discriminating-task tables.

### Viewing traces

**Hosted:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials) — includes Trajectory, User Simulation Prompt, and Agent Logs tabs.

Each trace shows a sim version badge (e.g., `User Sim v0.6.0 · 5/11 msgs`) indicating which simulator version produced the trial and how many messages it sent.

**Local:**
```bash
.venv/bin/python deploy/start_viewer.py
# Open http://localhost:9876
```

---

## Task Structure

Each task under `harbor_tasks/<name>/` contains:

| File | Purpose |
|------|---------|
| `instruction.md` | Agent reads this — the real user's first message, verbatim |
| `task.toml` | Metadata (difficulty, timeouts, resources) |
| `environment/Dockerfile` | Clones repo at specific commit, installs deps, synthesizes buggy state |
| `tests/test.sh` | Deterministic verifier returning 0.0–1.0 reward |
| `user_simulation_prompt.md` | Drives the user simulator — per-turn triggers, calibration, behavioral description |
| `original_session.json` | Raw session data (provenance) |

---

## User Simulator

The user simulator (`src/user_agent/`) is an LLM that role-plays as the original human user. It watches the agent's terminal output and decides when to intervene.

### Architecture (v0.6.0)

- **Claude Code harness only.** Every target model — Opus, Sonnet, MiniMax, GLM, DeepSeek, Kimi, … — runs through Claude Code CLI v2.1.108 (baked into every task image) and reaches its provider via the in-sandbox LiteLLM proxy on `localhost:4210`. Mixing harnesses across models would conflate harness quality with model quality.
- **User-sim model: Gemini 3.1 Pro** (default `openrouter/google/gemini-3.1-pro-preview`). Best GT coverage, most realistic turn structure, lower cost than Claude. See `src/user_agent/agent_test_comparison.md`.
- **Multi-turn via `claude --resume`** — each user-sim turn appends a message to the existing CC session. The CC agent is instructed to "work incrementally — stop and report after each sub-task" so there are more intervention checkpoints for the sim.
- **Repo config file injection** — CLAUDE.md, AGENTS.md, `.claude/`, `.ai/`, `.cursor/` are discovered and prepended to the agent instruction for cross-harness parity.
- **Structured tool output** — the sim picks one of: `no-op`, `question`, `redirect`, `new_requirement`, `check_external`. v0.6.0 forces this via `tool_choice=required` (Gemini's `functionCallingConfig.mode = "ANY"`), eliminating ~1,269 text-as-no-op cases per eval run.
- **Soft message guidance** — GT-based range (`GT × 0.5` – `GT × 1.5`) replaces the old hard `max_messages` cap; the sim decides based on context.
- **Wall-clock timing** — each trial records agent wall-clock time, GT session duration, and speedup ratio. Agents are consistently 4–8× faster than real users.
- **Conversation history** — accumulated across turns (tau-bench pattern), with the LLM's reasoning preserved (not just the tool argument).

### Version History

| Version | Key Change |
|---------|-----------|
| v0.2    | Stateless — each LLM call independent |
| v0.3.0  | Conversation history + hard message cap |
| v0.3.1  | Fixed fallback_parse leak |
| v0.4.0  | Multi-agent support (Claude Code, Codex) |
| v0.5    | Structured output, soft guidance, repo config injection, session ID fix |
| v0.5.1  | Wall-clock timing and GT session duration tracking |
| v0.5.2  | Incremental CC turns + relaxed trigger interpretation |
| **v0.6.0** | **Turn-quality overhaul** — turn-summary dedup (-70% chars on Turn 2), reasoning preserved in history, `tool_choice=required`, smart fallback parser (recovered 202/203 historical text-only decisions, 0 false positives), elapsed-time field in turn summary |

See `src/user_agent/CHANGELOG.md` for full per-version details.

---

## Trial Output

```
trials/<task>__<id>/
├── config.json                     # Serialized trial config
├── user_simulation_prompt.md       # Copy of the sim prompt used
├── agent/
│   ├── trajectory.json             # Enriched ATIF trajectory (pre-built for fast viewing)
│   ├── episode-N/
│   │   ├── prompt.txt              # Terminal output the agent saw
│   │   ├── response.txt            # Agent's response (analysis + commands)
│   │   ├── debug.json              # Token/parsing debug info
│   │   └── user_decision.json      # Sim decision (action, content, version, stats)
│   └── recording.cast              # asciinema terminal recording
└── verifier/
    ├── test-stdout.txt             # test.sh stdout
    └── reward.txt                  # Final score (0.0–1.0)
```

---

## Data Pipeline

```
~5,200 raw sessions across 3 sourcing waves:
  ├─ pi_staging harvest        2,397  (29 HF datasets, top: badlogicgames/pi-mono 627, thomasmustier/pi-for-excel 140)
  ├─ new_dataclaw harvest      ~2,014 (16+ DataClaw publishers; top: woctordho, gutenbergpbc, REXX-NEW, peteromallet, segin)
  └─ archit11/claude_traces_hs   ~784 (third-party HF research dataset on juspay/hyperswitch)
    ↓ GPT-5.4 quick screen + Opus 4.6 deep screen + session-resolution audit (~$179 total)
~862 viable sessions (after filtering for 3+ meaningful interventions, public repo,
                       no secrets, reconstructible outputs, resolved/scoped enough)
    ↓ scripts/screening/run_pipeline.py (fans out to /scaffold-task + /write-tests via 4 parallel Claude workers)
    ↓ Opus boss-agent fan-out in E2B (~$1.16/task; iterate test.sh + Dockerfile)
    ↓ Tier-A rubric enforcement (lint_tests.py + write-tests.md)
101 Harbor benchmark tasks  (current trunk: 44 TS, 30 Python, 23 Rust, 4 C/C++)
    ↓ src/run_eval.py (in-process Harbor LocalOrchestrator, 25 concurrent E2B sandboxes)
    ↓ scripts/finalize_v043.sh (user_sim_stats → build_leaderboard → per_turn_replay
                                 → generate_v043_report → tar.zst → gh release upload)
v0.4.3 release: 5 cohorts, ~490 trials, 99 unique tasks scored
```

A task ships only when (a) its buggy state scores in `(0, 1)` on the verifier (not all-zero, not all-perfect), (b) an alternative valid fix scores ≥0.7 (verifier accepts diverse approaches per the [SWE-bench Verified critique](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)), and (c) a stub solution scores ≤0.3 (verifier doesn't reward shape-only output). See `system_overview.md` for the full author iteration loop.

---

## Versioning

Benchmark results are only meaningful when tied to a specific version. Five things can change between versions: the **task set**, the **user simulator**, the **test scripts**, the **harness (Harbor)**, and the **Claude Code CLI binary**.

### What constitutes a version

| Component | How it's tracked |
|-----------|-----------------|
| Task set | Git commit hash — task files are immutable at a given commit |
| Task integrity | SHA-256 directory hash per task (stored in every `trial/config.json` via Harbor) |
| User simulator | `UserAgent.VERSION` (e.g., `"0.6.0"`) — logged in every `user_decision.json` |
| Test scripts | Part of the task directory hash |
| Harness (Harbor) | `harbor.__version__` in `config.json` |
| **Claude Code CLI** | **Pinned to `2.1.108`**, baked into every task image (5 cluster `base_images/*/Dockerfile` + raw task Dockerfiles). The CC binary is part of the image hash — eval runs across different days use the exact same binary. See `CLAUDE.md` §"Claude Code harness version — pinned to 2.1.108" for the bump procedure. |

### Release format

```
togetherbench@0.4.3
  Tasks: 101 (99 unique scored)
  Commit: e4469d88…
  User sim: v0.6.0
  Cohorts: opus46_high, deepseek_v4_flash, deepseek_v4_pro, minimax27, minimax25
```

When citing results, always include the benchmark version:

> "Opus 4.6 (effort=high) scored 0.4858 avg reward on togetherbench@0.4.3 shared-89 (101 tasks, user sim v0.6.0)"

### Version history

| Version | Date | Tasks | User Sim | Key changes |
|---------|------|-------|----------|-------------|
| `@0.1.0` | 2026-03-28 | 45  | v0.3.1 | Initial release. Conversation history + hard cap. Sonnet 0.784, Kimi 0.663. |
| `@0.2.0` | 2026-04-11 | 40  | v0.5.2 | Test-quality overhaul: 100% P2P coverage, nop-validation linter, viewer compat. |
| `@0.3.0–0.3.2` | 2026-04-24 | 40  | v0.5.2 | Coverage-audit pipeline + session-resolution metadata; 25% of tasks tagged low-fidelity. |
| `@0.4.0` | 2026-04-29 | 127 | v0.6.0 | 140-task expansion (TS/Rust/Py/C). 5 cluster base images, GHCR pipeline. CC pin to 2.1.108. |
| `@0.4.1–0.4.2` | 2026-04-30 | 127 | v0.6.0 | F2P weight normalization, Rust toolchain symlinks, REBUILD_TOKEN cache-bust, OR proxy SSE streaming, prompt-cache restored, sanitize-traces secret-leak fix. |
| **`@0.4.3`** | **2026-05-01** | **101** | **v0.6.0** | **5 cohorts (Opus 4.6, DeepSeek×2, MiniMax×2). Score-formula fix (additive→weighted-replace). P2P_REGRESSION semantics split (Option 1 enforce / Option 2 drop). `allow_internet` placement enforcement. ARK Bearer auth. DeepSeek direct.** |

**Roadmap (per `analysis/V043_IMPROVEMENT_PLAN.md`)**: prune to ~60-task suite by deleting 26 all-zero / 3 all-perfect / 8 tight-cluster tasks; widens cohort spread from 0.16 → 0.24 (+50%). Re-pin `hyperswitch-8338` and `pi-mono-auto-41636ae5` (both currently pinned to post-fix commits, giving free credit). Finish per-turn replay sweep for `minimax25 / minimax27 / opus46_high` (~750 patches, 8–16h E2B).

---

## Data Source

DataClaw-source sessions come from the distributed publishing ecosystem of [peteromallet/dataclaw](https://github.com/peteromallet/dataclaw) — a CLI that exports Claude Code / Codex / Pi conversation history to Hugging Face as redacted datasets (every export tagged `dataclaw`; discoverable at [`?other=dataclaw`](https://huggingface.co/datasets?other=dataclaw)). DataClaw sessions are filtered to repos with 20+ GitHub stars. Our consolidated screening snapshot lives at [`alexshengzhili/dataclaw-harbor-candidates`](https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates) (1,468 rows as of 2026-05-06; was 2,228 at 2026-03-24 audit). Pi-ecosystem and Hyperswitch sessions come from `pi-share-hf` exports and `archit11/claude_traces_hs` respectively (see Data Pipeline above).
