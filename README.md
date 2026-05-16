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

**166 tasks** under `harbor_tasks/` (`togetherbench@0.4.5` trunk), all derived from **real recorded coding sessions** across four sourcing waves. Per-source breakdown:

| source wave | tasks | family prefixes in `harbor_tasks/` |
|---|---:|---|
| **SWE-chat** (Stanford `SALT-NLP/SWE-chat`) | **77** | `cli-*` (44), `gemini-voyager-*` (9), `rudel-*` (6), `agent-swarm-*` (3), `amytis-*` (3), `moltis-*` (3), `cc-backend-*` (2), `marin-*` (2), `no-magic-*` (2), `cluefin-*`, `light-protocol-*`, `lock-code-manager-*` |
| **Pi-staging** (`badlogic/pi-share-hf`) | **27** | `pi-mono-*`, `pi-excel-*` |
| **Hyperswitch** (`archit11/claude_traces_hs`) | **17** | `hyperswitch-*` |
| **DataClaw + misc** (`peteromallet/dataclaw` publishers, repos with 20+ GitHub stars) | **45** | `reigh-*` (9), `comfyui-*` (8), `sd-scripts-*` (5), `nunchaku-*` (3), `dataclaw-*` (3), `banodoco-*` (2), `sageattention-*` (2), `triton-*` (2), `unsloth-*` (2), `desloppify-*` (2), plus singletons |

> **Naming convention — read this if a family looks misplaced.** SWE-chat task directories inherit the **upstream GitHub repo's name** as the family prefix (e.g., `rudel-*` ← `obsessiondb/rudel`, `gemini-voyager-*` ← `Nagi-ovo/gemini-voyager`, `moltis-*` ← `moltis-org/moltis`). They do *not* carry a `swechat-` prefix. The authoritative source check is session-id overlap with `data-pipeline/artifacts_swechat/step1_all_sessions.json` (760 records), not the task-name prefix.

Original wave contributions before drops were larger (~255 candidate tasks); the current 166 reflect the post-curator (88 verifier-touches in v0.4.3.x), post-DROP-9 (v0.4.3.2), and post-v0.4.4.3 audit cleanup.

No synthetic tasks. Each task has a Docker environment, a natural-language instruction (the real user's first message, verbatim), and a deterministic verifier. Two verifier families coexist (counts reflect which scoring path each task's `tests/test.sh` actually executes):

- **Manifest F2P/P2P** (123 tasks): per-task `tests/test_manifest.yaml` with `F2P` and `P2P_REGRESSION`/`P2P` gates. The target scoring semantics are unweighted F2P coverage with bounded P2P penalty, computed centrally from `gates.json`; legacy weighted-replace and `P2P_GATING` verifiers are being migrated.
- **SWE-rebench-style** (39 tasks): per-task `tests/install_config.json` declares `test_cmd` + `FAIL_TO_PASS` + `log_parser`. The verifier runs the test command, parses stdout with one of 76 log parsers vendored from [SWE-rebench-V2](https://github.com/swerebench/swerebench-v2) (MIT), and scores by `FAIL_TO_PASS` pass rate. See `data-pipeline/scaffold/build_swerebench_configs.py`.
- 4 remaining tasks use bespoke source-grep verifiers (no manifest, no `install_config.json`).

Note: 62 additional tasks have an `install_config.json` on disk from an earlier migration sweep but their active `test.sh` still routes through the manifest path — the `install_config.json` is informational, not load-bearing for those.

The key differentiator: an **LLM-powered user simulator** (Gemini 3.1 Pro by default) watches the agent work and injects corrections, redirects, and new requirements based on the original session's ground truth — recreating the multi-turn correction loop. The headline metric is the **final reward** (0.0–1.0) returned by each trial's verifier after the simulator-driven loop completes; the per-(model, task) mean of that single number is what the leaderboard ranks on.

### Results — `togetherbench@0.4.5` (6 models, 6,166 trials across 13 cohort dirs)

Per-(model, task) deduped, latest trial wins, audit-excluded trials filtered (161 DeepSeek HTTP 402 billing failures + 35 rate-limit-corrupted; full audit in `analysis/V044_RELEASE_NOTES.md`). Recomputed against the 166-task v0.4.5 trunk from `analysis/v044_leaderboard.json` selected trials.

| rank | model | provider | **headline mean** (n) | ≥5/6 (n=161) | strict 6/6 (n=74) |
|---|---|---|---|---|---|
| 1 | **Opus 4.6** | `anthropic/claude-opus-4-6` (OAuth subscription) | **0.3877** (164) | **0.3803** | 0.3910 |
| 2 | **DeepSeek V4 Pro** | `deepseek/deepseek-v4-pro` | **0.3868** (167) | 0.3775 | **0.4049** |
| 3 | DeepSeek V4 Flash | `deepseek/deepseek-v4-flash` | 0.3660 (168) | 0.3568 | 0.3918 |
| 4 | MiniMax M2.7 | `minimaxd/MiniMax-M2.7` | 0.3545 (167) | 0.3449 | 0.3738 |
| 5 | MiniMax M2.5 | `minimaxd/MiniMax-M2.5` | 0.3250 (167) | 0.3312 | 0.3616 |
| 6 | GLM 5.1 | `glmd/glm-5.1` (z.ai direct) | 0.3162 (78) | 0.3055 | 0.3096 |

Top two (Opus, DS Pro) are within **0.0009** on the headline and **0.014** on strict 6/6 — statistical tie within bootstrap noise.

> **Results are tied to a specific benchmark version.** Task set, user simulator, and test scripts all change between versions; always cite the version. Audit context — Opus 4.6 trials use OAuth subscription billing (`CLAUDE_CODE_OAUTH_TOKEN`, `sk-ant-oat01-...`); DS Pro/Flash had a billing window hit during the swerb runs (161 HTTP 402 trials filtered). See `analysis/V044_RELEASE_NOTES.md` for full per-cohort audit + the OAuth routing patch in `src/run_eval.py:build_agent_env`.

---

## Quick Start

### Setup

```bash
git clone https://github.com/Togetherbench/SWE-Replay.git
cd SWE-Replay

# Install dependencies (use uv, not pip)
uv sync
```

Pin to a release tag (`git checkout v0.4.5`) when reproducing published numbers — the task set, user simulator, and test scripts evolve.

### Running the full eval (production path)

`src/run_eval.py` is the production async evaluator. It drives Harbor's `LocalOrchestrator` across N concurrent E2B sandboxes, launches the in-sandbox LiteLLM proxy per trial, and writes per-cohort `trials_<tag>/<task>__<id>/` directories.

```bash
# Generic invocation (substitute model + env var per provider table below)
<API_KEY_ENV>=<key> uv run python src/run_eval.py \
    --model <provider>/<model> --tag <cohort_tag> --workers <N>
```

| provider prefix | API key env var | workers | notes |
|---|---|---|---|
| `anthropic/` | `ANTHROPIC_API_KEY` (`sk-ant-api03-…`) | 10 | pay-per-token |
| `anthropic/` (subscription) | `CLAUDE_CODE_OAUTH_TOKEN` (`sk-ant-oat01-…` from `claude setup-token`) | 10 | free under Claude Pro/Max; script auto-detects `oat01` prefix and routes via Bearer auth |
| `deepseek/` | `DEEPSEEK_API_KEY` | 10 | direct Anthropic-compat via in-sandbox proxy |
| `minimaxd/` | `MINIMAX_API_KEY` | 1 | api.minimax.io/anthropic — needs serial |
| `glmd/` | `GLM_API_KEY` | 2 | z.ai direct; Beijing peak hours can throttle (see CLAUDE.md) |
| `ark/` | `ARK_API_KEY` | 1 | Volcengine Bearer auth; 5h quota window resets at 12:32 +0800 |

Default user-sim model: `openrouter/google/gemini-3.1-pro-preview` (needs `OPENROUTER_API_KEY` in `.env`). See `src/run_eval.py:build_agent_env` for every supported provider prefix.

### Running a single task (debugging)

```bash
ANTHROPIC_API_KEY=<key> uv run python src/runner.py \
    --task sageattention-headdim-256 \
    --model anthropic/claude-sonnet-4-6
```

Trial output: `trials/<task>__<id>/verifier/reward.txt`.

### Building / updating the leaderboard

The leaderboard is built by `scripts/finalize_v044.sh` (script name still pinned to v044): replay every captured agent patch against the current `tests/test.sh` in fresh E2B sandboxes (no model re-runs), per-(model, task) dedup using the latest trial by `started_at`, exclude rate-limit-corrupted + DeepSeek HTTP 402 trials, write `analysis/v044_leaderboard.json` (`headline_latest` + `apples_to_apples_5_of_6` + `apples_to_apples_6_of_6`), optional tarball + GitHub release upload.

```bash
bash scripts/finalize_v044.sh              # full pipeline
bash scripts/finalize_v044.sh --no-replay  # use on-disk reward.txt as-is
bash scripts/finalize_v044.sh --no-upload  # local rebuild only
```

Legacy `v0.4.3` builder for reproducing the older five-cohort leaderboard: `scripts/build_leaderboard.py --cohorts trials_<model>_v043 ... --out analysis/v043_leaderboard`.

### Viewing traces

**Hosted:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials) — Trajectory, User Simulation Prompt, and Agent Logs tabs. All 13 v0.4.5 cohort dirs are uploaded (sanitized via `scripts/sanitize_traces.py`); browse by trial name (e.g., `cli-task-14ee15__abcd123`).

Two version indicators appear on every page:
- **Bottom-right pill — `benchmark: togetherbench@<version>`** — the release the trial data was published against. Click to jump to the GitHub release. Programmatic: `GET /api/version` → `{"benchmark_version": "v0.4.5", "release_url": "..."}`. Bump by editing `BENCHMARK_VERSION` in `deploy/patched_server.py` and redeploying.
- **Per-trial sim badge — `User Sim v0.6.0 · 5/11 msgs`** — which simulator version produced this trial and how many messages it sent.

`src/run_eval.py` auto-uploads after each cohort run (set `BUCKET_ENDPOINT` / `BUCKET_NAME` / `BUCKET_ACCESS_KEY` / `BUCKET_SECRET_KEY` in `.env`). For batch re-uploads (e.g., after a credential rotation), see `scripts/upload_traces.py` or use the inline pattern in `src/run_eval.py:_sanitize_and_upload`.

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

- **Claude Code harness only.** Every target model runs through CC CLI v2.1.108 (baked into every task image) and reaches its provider via the in-sandbox LiteLLM proxy on `localhost:4210`. Mixing harnesses would conflate harness quality with model quality.
- **User-sim model: Gemini 3.1 Pro** (`openrouter/google/gemini-3.1-pro-preview`). Best GT coverage, lower cost than Claude. See `src/user_agent/agent_test_comparison.md`.
- **Multi-turn via `claude --resume`** — each sim turn appends a message to the existing CC session. CC is instructed to "work incrementally — stop and report after each sub-task" for more intervention checkpoints.
- **Structured tool output via `tool_choice=required`** — sim picks one of `no-op`, `question`, `redirect`, `new_requirement`, `check_external`. Eliminated ~1,269 text-as-no-op cases per eval vs. v0.5.x.
- **Other v0.6.0 wins**: repo config injection (CLAUDE.md, AGENTS.md, `.claude/`, `.cursor/` prepended to agent instruction), soft message guidance (`GT × 0.5`–`GT × 1.5` range replacing hard cap), wall-clock + GT-duration tracking (agents are 4–8× faster than real users), conversation history with LLM reasoning preserved.

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
~11,000 raw sessions across 4 sourcing waves:
  ├─ SALT-NLP/SWE-chat         5,851  (Stanford gated HF dataset; largest wave, added post-v0.4.3)
  ├─ pi_staging harvest        2,397  (29 HF datasets, top: badlogicgames/pi-mono 627)
  ├─ new_dataclaw harvest      ~2,014 (16+ DataClaw publishers; top: woctordho, peteromallet, segin)
  └─ archit11/claude_traces_hs   ~784 (third-party HF research dataset on juspay/hyperswitch)
    ↓ Step 1: rule-based filter (stars ≥10 for SWE-chat, ≥20 for DataClaw; ≥3 user msgs; public repo) — no LLM
    ↓ Step 2: Gemini 3.1 Pro session viability judge (single stage)
    ↓ Step 4 [SWE-chat only]: extract canonical patch from commits.parquet
                              (single-commit checkpoints — 170/329 high-trust subset)
    ↓ Step 5 [SWE-chat only]: Gemini 3.1 Pro patch-aware viability judge
                              (filter formatting / lockfile / refactor-too-large)
    ↓ Step 3: E2B + DeepSeek-v4-pro scaffold (claude -p in 8-vCPU sandbox)
                              (10-step inline prompt: screen → scaffold → tests → audit)
    ↓ build_swerebench_configs.py [optional]: migrate test.sh to install_config.json
                              + vendored SWE-rebench log parsers (68 tasks so far)
166 Harbor benchmark tasks  (v0.4.5 trunk; was 167 at v0.4.4.3, 172 at v0.4.4.4-pr132; post curator + DROP-9 + audit drops)
    ↓ src/run_eval.py (in-process Harbor LocalOrchestrator, concurrent E2B sandboxes;
                        per-provider concurrency caps: anthropic/deepseek=10, glm=2, mm=1)
    ↓ scripts/finalize_v044.sh (replay all captured patches against latest test.sh →
                                 per-(model, task) latest-trial dedup → exclude rate-limit
                                 corrupted + DS 402 billing → tar.zst → gh release upload)
v0.4.5 trunk: 13 cohort dirs, 6 models. Latest leaderboard recomputed from
              analysis/v044_leaderboard.json::selected_trials filtered to the
              166-task trunk (1 task dropped since v0.4.4.4-pr132).
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
togetherbench@0.4.5
  Tasks: 166 (recomputed leaderboard from v0.4.4.4-pr132 selected trials)
  User sim: v0.6.0
  CC binary: 2.1.108 (pinned in image)
  Cohorts: 13 trial dirs across 6 models
    Opus 4.6:           opus46_v043 + opus46_or_swerb + opus46_v044_fill
    DeepSeek V4 Pro:    deepseek_v4_pro_{v043,swerb}
    DeepSeek V4 Flash:  deepseek_v4_flash_{v043,swerb}
    MiniMax M2.5/M2.7:  minimax{25,27}_v043 + minimax_m{25,27}_swerb
    GLM 5.1:            glm51_swerb + glm51_v044_fill
```

When citing results, always include the benchmark version:

> "Opus 4.6 scored 0.3877 avg reward on togetherbench@0.4.5 (n=164 tasks, user sim v0.6.0, audit-corrected)"

### Version history

| Version | Date | Tasks | User Sim | Key changes |
|---------|------|-------|----------|-------------|
| `@0.1.0` | 2026-03-28 | 45  | v0.3.1 | Initial release. Conversation history + hard cap. Sonnet 0.784, Kimi 0.663. |
| `@0.2.0` | 2026-04-11 | 40  | v0.5.2 | Test-quality overhaul: 100% P2P coverage, nop-validation linter, viewer compat. |
| `@0.3.0–0.3.2` | 2026-04-24 | 40  | v0.5.2 | Coverage-audit pipeline + session-resolution metadata; 25% of tasks tagged low-fidelity. |
| `@0.4.0` | 2026-04-29 | 127 | v0.6.0 | 140-task expansion (TS/Rust/Py/C). 5 cluster base images, GHCR pipeline. CC pin to 2.1.108. |
| `@0.4.1–0.4.2` | 2026-04-30 | 127 | v0.6.0 | F2P weight normalization, Rust toolchain symlinks, REBUILD_TOKEN cache-bust, OR proxy SSE streaming, prompt-cache restored, sanitize-traces secret-leak fix. |
| `@0.4.3` | 2026-05-01 | 101 | v0.6.0 | 5 cohorts (Opus 4.6, DeepSeek×2, MiniMax×2). Score-formula fix (additive→weighted-replace). P2P_REGRESSION semantics split. ARK Bearer auth. DeepSeek direct. |
| `@0.4.3.1`–`@0.4.3.3` | 2026-05-07–09 | 190→172 | v0.6.0 | SWE-chat expansion (89 new tasks, PR #119); SWE-rebench scoring introduced (68 tasks); degenerate-ceiling rescue (88 verifier-touches); 9 final DROPs after curator pass. |
| `@0.4.4`–`@0.4.4.3` | 2026-05-10–11 | 167 | v0.6.0 | Replay-only consolidation + audit corrections. Single coherent leaderboard across 13 cohort dirs; per-(model, task) latest-trial dedup; auditor's preserved-pre-rescue bug closed; strict-fresh policy. v0.4.4.2 added Opus + GLM fill runs (Opus 30 new tasks via `claude setup-token`; GLM 21 new tasks via z.ai direct). v0.4.4.3 added two systematic-bias exclusions: **DeepSeek HTTP 402 billing failures (161 trials)** + **rate-limit-corruption trials (35)** — DS Pro briefly took #1. |
| `@0.4.4.4-pr132` | 2026-05-12 | 172 | v0.6.0 | Intermediate snapshot used to generate `analysis/v044_leaderboard.json` (`selected_trials` + `headline_latest`). |
| **`@0.4.5`** | **2026-05-16** | **166** | **v0.6.0** | **Task-set cleanup + leaderboard recomputation.** Dropped `pi-mono-keybinding-scope` (curator follow-up). Source attribution corrected: SWE-chat 77 (was undercounted as 45) / Pi 27 / Hyperswitch 17 / DataClaw+misc 45 — 13 SWE-chat families inherit upstream-repo names with no `swechat-` prefix. Leaderboard recomputed from `v044_leaderboard.json::selected_trials` filtered to current trunk: Opus 4.6 and DS Pro tied at the top (0.3877 vs 0.3868). |

**Roadmap to v0.4.6**:
1. **Re-run DeepSeek swerb with valid billing** to recover the 161 excluded trials.
2. **GLM 5.1 fill remaining ~88 tasks** when z.ai throttling eases (lifts n=78 → ~166).
3. **Verifier-quality pass** for the all-zero and degenerate-ceiling tasks. See `analysis/V044_RELEASE_NOTES.md` "Harness audit" section.

---

## Data Source

DataClaw-source sessions come from the distributed publishing ecosystem of [peteromallet/dataclaw](https://github.com/peteromallet/dataclaw) — a CLI that exports Claude Code / Codex / Pi conversation history to Hugging Face as redacted datasets (every export tagged `dataclaw`; discoverable at [`?other=dataclaw`](https://huggingface.co/datasets?other=dataclaw)). DataClaw sessions are filtered to repos with 20+ GitHub stars. Our consolidated screening snapshot lives at [`alexshengzhili/dataclaw-harbor-candidates`](https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates) (1,468 rows as of 2026-05-06; was 2,228 at 2026-03-24 audit). Pi-ecosystem and Hyperswitch sessions come from `pi-share-hf` exports and `archit11/claude_traces_hs` respectively (see Data Pipeline above).
