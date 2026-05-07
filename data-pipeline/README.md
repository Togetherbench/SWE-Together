# Session Collection Pipeline

End-to-end pipeline that turns multi-turn coding sessions from upstream HuggingFace datasets into reproducible Harbor benchmark tasks. Two upstream sources are wired in: **DataClaw** (32 community `dataclaw`-tagged HF datasets) and **SWE-chat** (Stanford `SALT-NLP/SWE-chat`).

## v0.4.3 Data Composition (101 tasks)

| Cohort | Source | Raw sessions | After screening | Final tasks |
|--------|--------|-------------|-----------------|-------------|
| DataClaw | 32 HuggingFace datasets (community `dataclaw`-tagged) | 2,228 | 236 candidates → 46 scaffolded | **46** |
| Pi-staging | 29 HuggingFace datasets (`badlogic/pi-share-hf` ecosystem) | 2,397 | 507 candidates → 308 VIABLE → 32 scaffolded | **32** (31 `pi-mono-*` + 1 `pi-excel-*`) |
| Hyperswitch | 1 HuggingFace dataset (`archit11/claude_traces_hs`) | 784 | ~40 scaffolded → 23 after resolution audit | **23** |
| **Total** | | **5,409** | | **101** |

### Per-cohort provenance

**DataClaw (46 tasks)** — Screened via the `--source dataclaw` pipeline below.

| HF dataset | Unique sessions |
|---|---|
| `peteromallet/dataclaw-peteromallet` | 503 |
| `woctordho/dataclaw` + `dataclaw-windows` | 536 |
| `segin/my-personal-codex-data` | 203 |
| Other unique donors (akenove, michaelwaves, tillg, etc.) | 656 |
| Peteromallet forks (deduped to 0 new) | 0 |
| **Total (32 datasets)** | **2,228** |

Funnel: 2,228 → regex/heuristic filter (stars ≥ 20, ≥3 user messages, GitHub repo identified) → 236 candidates → Gemini Pro viability screen → 46 scaffolded tasks. Top-level HF index: https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates

**Pi-staging (32 tasks)** — Screened ad-hoc before the unified `--source` orchestrator existed. 29 HF datasets via `badlogic/pi-share-hf`. Top contributors: `badlogicgames/pi-mono` (627), `thomasmustier/pi-for-excel-sessions` (140). 507 → 308 VIABLE → 32 scaffolded.

**Hyperswitch (23 tasks)** — Also pre-orchestrator. Source `archit11/claude_traces_hs` — ~784 Claude session traces on `juspay/hyperswitch` (Rust, 15K★). ~40 initially scaffolded, pruned to 23 after a resolution audit removed cut-off sessions. The companion `archit11/claude_traces_hs2` is a re-export with extra log columns, not a separate wave.

### v0.4.3 task health (Opus 4.6 cohort)

| Status | DataClaw | Pi | Hyperswitch | Total |
|--------|----------|-----|-------------|-------|
| Scored (has reward) | 46 | 30 | 14 | 90 |
| Unrecoverable (no reward) | 0 | 2 | 9 | 11 |
| **Total** | **46** | **32** | **23** | **101** |

Of the 46 scored DataClaw tasks, 10 scored 0.0 across all 3 model cohorts (Opus 4.6, DeepSeek v4 Flash, DeepSeek v4 Pro) — likely broken verifiers or infeasible tasks. Effective DataClaw tasks with signal: **36**.

---

## Pipeline Overview

```
upstream HF dataset
     │
     ▼
┌─────────────────┐    ┌──────────────────────┐    ┌──────────────────┐
│ Step 1: collect │ ─► │ Step 2: LLM viability│ ─► │ Step 3: scaffold │
│ deterministic   │    │ Gemini 3.1 Pro       │    │ E2B + DeepSeek   │
│ rule-based      │    │ judge per session    │    │ → harbor_tasks/  │
└─────────────────┘    └──────────────────────┘    └──────────────────┘
       no LLM              one Pro call/session       claude-code -p
```

For SWE-chat, a small post-step-2 helper (`swechat_postprocess_after_step2.py`) prefetches transcripts from HF into local JSON before step 3 runs — see its own section below. DataClaw doesn't need this since its raw sessions are already on disk after step 1.

A separate one-time helper, `build_template.py`, bakes a custom E2B template (`harbor-scaffold-cc2-1-108-8c-4g`) so step 3 can skip per-sandbox `npm install` of `claude-code`. Run it once per CC version bump.

---

## Step 1 — `scripts/step1_collect.py`

**Deterministic rule-based filter, no LLM.** Pulls upstream sessions, applies hard thresholds, emits one JSON record per surviving session. Both upstream paths produce the same output schema so step 2 is upstream-agnostic.

### `--source swechat`

1. `hf_hub_download` of `sessions.parquet` + `repositories.parquet` from `SALT-NLP/SWE-chat` (gated — needs `huggingface-cli login`).
2. Star count flattened out of `repo_github_metadata` JSON.
3. Filters (each prints to a funnel summary):
   - `prompt_count >= 3`
   - `action_count > 0`
   - `stars >= --min-stars` (default 10)
   - `agent_percentage >= --min-agent-percentage` (default 30)
4. Optional `--per-repo-cap N` (top-N by `session_success` per repo) and `--limit N`.
5. Latest funnel: 5,851 → **760 candidates**.

```bash
python data-pipeline/scripts/step1_collect.py --source swechat \
    --out-dir data-pipeline/artifacts_swechat/
```

### `--source dataclaw`

DataClaw has no native repo/star/action columns, so step 1 does much more work:

1. Walk a hard-coded list of 32 HF datasets, dedupe by `session_id`.
2. Per session: regex-extract GitHub repo URLs from the transcript, count "genuine" (non-auto-generated) user messages, detect non-English (CJK ratio), tally tool usage.
3. Async GitHub API for star counts (`github_stars_cache.json` persists, retried on 403).
4. Outputs three files: `all_sessions.json` (all screened), `candidates.json` (passes basic + stars), `sessions_with_popular_repos.json` (index of `_repo` x `stars`).

```bash
python data-pipeline/scripts/step1_collect.py --source dataclaw [--skip-stars]
```

---

## Step 2 — `scripts/step2_screen_with_llm.py`

**Single-stage Gemini 3.1 Pro per-session viability judge.** The earlier Flash → Pro two-stage flow was simplified after Flash and Pro disagreed on 46% of SWE-chat sessions and Flash added no signal beyond what SWE-chat already exposes natively.

The model is asked: *"Is the coding work in this session reproducible in a clean Harbor task, or is it fundamentally about external state (PR creation, push, issue triage)?"* Inputs to the prompt include repo + stars, first 3 + last user messages, file edits (top 15), bash commands (top 20), tool distribution.

Returns:

| Field | Values |
|---|---|
| `verdict` | `VIABLE` \| `NOT_VIABLE` |
| `primary_deliverable` | `code_changes` \| `pr_creation` \| `issue_triage` \| `analysis_only` \| `deployment_ops` \| `other` |
| `reproducible_in_harbor` | `true` \| `false` |
| `reason` | 1-sentence rationale |

A session ending in `git push origin main` is still considered Harbor-reproducible — the push step gets dropped during scaffolding.

### `--source swechat`

Re-evaluates **every** step1 candidate. ThreadPoolExecutor with `--workers 10`, checkpointed every 25 calls, supports `--resume`.

```bash
GEMINI_API_KEY=... python data-pipeline/scripts/step2_screen_with_llm.py \
    --source swechat --workers 10 --out-dir data-pipeline/artifacts_swechat/
```

Outputs:
- `step2_screening.json` — full Pro response per session (audit trail)
- `step2_candidates.json` — final `verdict==VIABLE AND reproducible_in_harbor==true` subset
- `step2_run_config.json` — model, workers, source

Latest result: 760 step1 → **329 candidates**.

### `--source dataclaw` — rescue mode

Only re-runs Pro on regex-rejected `NOT_VIABLE` sessions from step 1. On the v0.4.3 selection run, Pro rescued **44 of 236** regex-rejects (18% false-positive rate on the original Stage-1 reject set).

```bash
GEMINI_API_KEY=... python data-pipeline/scripts/step2_screen_with_llm.py --source dataclaw
```

---

## SWE-chat post-step-2 — `scripts/swechat_postprocess_after_step2.py`

**One-time prefetch of every VIABLE SWE-chat transcript into local JSON.** Not a new screening stage — it just resolves the lazy-fetch path so step 3 workers never call HF at run time (eliminates the concurrent-parquet-load OOM seen at WORKERS≥4).

What it does:
1. Reads `step2_candidates.json`, keeps `verdict == "VIABLE"`.
2. For each, downloads `transcripts/<sid>.jsonl` from `SALT-NLP/SWE-chat` (serial loop, ~50 MB peak RAM).
3. Converts each JSONL to the DataClaw-shaped session dict (`{session_id, messages: [...]}`) so step 3's prompt is upstream-agnostic.
4. Writes to `artifacts_swechat/sessions_raw/<sid>.json`. Skips files that already exist (idempotent; `--force` overrides).

```bash
python data-pipeline/scripts/swechat_postprocess_after_step2.py
python data-pipeline/scripts/swechat_postprocess_after_step2.py --limit 50
python data-pipeline/scripts/swechat_postprocess_after_step2.py --force
```

DataClaw doesn't need this step — its raw session JSONs are already on local disk from step 1.

---

## Step 3 — `scripts/step3_run_pipeline.py`

**E2B-backed scaffold orchestrator.** Each VIABLE candidate gets its own AsyncSandbox, where `claude -p` (driven by DeepSeek-v4-pro) runs an inline 10-step scaffolding prompt. Output `harbor_tasks/<task>/` is tarred out of the sandbox onto the host. Up to `--workers N` candidates run concurrently (default 4; up to 15 with the pre-baked template).

### Host-side per-task flow

```
LAUNCH ─► [INSTALL] ─► UPLOAD ─► SEED ─► SCAFFOLD ─► HARVEST ─► KILL
 ~3s        ~45s        ~2s       ~1s    5–25 min    ~5s        ~1s
```

| # | Stage | Code | Notes |
|---|---|---|---|
| 1 | **Launch** | `AsyncSandbox.create(template=..., timeout=3600)` | Default Ubuntu image. With `--template harbor-scaffold-cc2-1-108-8c-4g`, sandbox spec is 8 vCPU / 4 GB / `claude-code` pre-baked. Records `sandbox_id` in the per-task log. |
| 2 | **Install** *(skipped if template pre-baked)* | `npm install -g @anthropic-ai/claude-code@2.1.108` | `INSTALL_TIMEOUT = 240 s`. Failure → status `install_failed`, exits early. |
| 3 | **Upload** | `sbx.files.write(...)` × 3 | Workdir is `/home/user/work` (the default `user` can't write `/workspace`). Files: `session_collection/.../sessions_raw/<sid>.json` (the prefetched DataClaw-shaped JSON), `scripts/lint_tests.py` (host copy), `_scaffold_prompt.txt` (the per-task prompt). |
| 4 | **Seed** | `git init && git add -A && git commit -m "seed: pre-scaffold"` | Lets `claude -p` produce diffs and `git add` later. Identity is `Scaffold Bot <scaffold@togetherbench.dev>`. |
| 5 | **Scaffold** | `cat _scaffold_prompt.txt \| claude -p --dangerously-skip-permissions --max-budget-usd <budget>` | `SCAFFOLD_TIMEOUT = 1800 s`. Runs with DeepSeek env vars (next sub-section). The model executes 10 inline sub-steps; sub-step 1 may emit `NOT VIABLE: <reason>` and exit. The host watches stdout for `NOT VIABLE` (→ `not_viable`) and `Exceeded USD budget` (→ `budget_exceeded`). |
| 6 | **Harvest** | `tar -cf _out.tar harbor_tasks/<task_name>` then `sbx.files.read(...)` | If the directory is missing → `no_output`. Otherwise tar bytes are read back to the host, `tarfile.extractall(ROOT, filter="data")` lands the task into `harbor_tasks/<task_name>/`. `files_landed` is logged. |
| 7 | **Kill** | `await sbx.kill()` in a `finally` block | Always runs, even on timeout/exception. Writes `result` (status + timestamps + tar size + log tails) to `artifacts_swechat/logs/<task>.json`. |

### DeepSeek env vars passed to `claude -p`

Without these, `claude-code` would talk to `api.anthropic.com`. DeepSeek's `/anthropic` endpoint passes CC's client-side `/v1/models/<name>` validator, so no LiteLLM proxy is needed. All three model tiers map to DeepSeek so internal CC code paths can't accidentally fall through to Anthropic.

```
ANTHROPIC_BASE_URL              = https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN            = $DEEPSEEK_API_KEY
ANTHROPIC_MODEL                 = deepseek-v4-pro
ANTHROPIC_DEFAULT_OPUS_MODEL    = deepseek-v4-pro
ANTHROPIC_DEFAULT_SONNET_MODEL  = deepseek-v4-pro
ANTHROPIC_DEFAULT_HAIKU_MODEL   = deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL      = deepseek-v4-flash
CLAUDE_CODE_EFFORT_LEVEL        = max
```

### Inline scaffolding prompt — what the agent does in the sandbox

The host-side prompt (`build_prompt(...)`) hands the model a 10-step plan. Sub-steps 8 and 10 are explicitly **disabled** in E2B mode (no Docker daemon, no git remote / GH auth) and are deferred to the host post-harvest (or skipped entirely).

| # | Sub-step | What gets produced |
|---|---|---|
| 1 | **Screen** | Read `sessions_raw/<sid>.json`, check 7 hard requirements (public repo + 20★, modifies repo code, CPU-reproducible, no creds, no live PR write, ≥3 genuine user msgs, real Write/Edit/apply_patch on repo files). Failure → `print("NOT VIABLE: <reason>")` and exit. |
| 2 | **Scaffold** | `harbor_tasks/<task>/{original_session.json, instruction.md, task.toml, environment/Dockerfile}`. `instruction.md` is the first user turn that asks for code change, **verbatim**. `task.toml` puts `allow_internet = true` under `[environment]` (Harbor silently ignores it under `[agent]`). Dockerfile pins the upstream commit; for `USER agent` images, prepends `mkdir -p /installed-agent && chown agent:agent /installed-agent`. |
| 3 | **Discover CI** | Inspect `.github/workflows/` to find canonical test commands (`cargo test`, `pytest`, `vitest run`, `go test ./...`, `make test`). Recorded as a comment at the top of `tests/test.sh`. |
| 4 | **User-sim prompt** | `user_simulation_prompt.md` — Simulator Calibration (msg count, longest silence, target msgs) + per-turn entries (Turn N, Context, Said, Why). Describes user **behavior**, not character; default tone is silence. |
| 5 | **Write tests** | `tests/test.sh` + `tests/test_manifest.yaml`. ≥60% behavioral / ≤40% structural. Anti-stub via AST checks (no string regex on source). F2P weights sum ≤1.0; P2P_REGRESSION is gating-only. Reward formula is **weighted-replace**, never additive (R001 lint check). |
| 6 | **Self-audit** | `python3 scripts/lint_tests.py --task <name> --fail-on HIGH` must exit 0. If a HIGH finding (R001/R002/R004/R006) — fix and re-run. |
| 7 | **Validate alignment** | Inline `/validate-task`: instruction implies code modification? Test reachable from the instruction without external knowledge? Env issues (Windows paths, broken URLs) fixed without expanding scope? |
| 8 | **Docker build** | *Disabled in E2B (no Docker daemon).* Sandbox just writes a syntactically valid Dockerfile; build verification happens post-harvest on the host. |
| 9 | **README.md** | Per-task `README.md`: source session, repo, base commit, difficulty, real-user-msg count, simulator behavior summary. |
| 10 | **Commit + PR** | *Disabled in E2B (no remote, no GH auth).* Harness tars the task back to the host instead. `git push` / `gh pr create` happen on the host (or in the human review step). |

### Inputs

Two mutually exclusive modes:

```bash
# Direct: scaffold specific session_ids (no screening required)
python data-pipeline/scripts/step3_run_pipeline.py \
    --session-ids <sid>,<sid> --workers 2

# Bulk: read VIABLE candidates from step2_candidates.json (sorted by stars)
python data-pipeline/scripts/step3_run_pipeline.py --from-screening --limit 50 --workers 15

# With pre-baked template (skips ~45 s install per sandbox)
python data-pipeline/scripts/step3_run_pipeline.py --from-screening --workers 15 \
    --template harbor-scaffold-cc2-1-108-8c-4g
```

Useful flags:
- `--one-per-repo` — keep only the highest-starred session per repo (for diversity)
- `--from-cached-only` — drop candidates whose JSON isn't in `sessions_raw/` (instead of aborting)
- `--resume` — skip sessions already in the per-task log
- `--budget` — USD per task (default $5)

### Outputs

- `harbor_tasks/<task>/` — one directory per scaffolded task (committed to repo)
- `data-pipeline/artifacts_swechat/logs/<task>.json` — per-task log (sandbox id, exit code, status, files landed)
- `data-pipeline/artifacts_swechat/logs/summary_e2b.json` — run summary

Status values: `success` / `not_viable` / `budget_exceeded` / `install_failed` / `setup_failed` / `no_output` / `timeout` / `error`.

---

## One-time setup — `scripts/build_template.py`

Bakes a custom E2B template once per CC version bump. After it succeeds, step 3 calls `AsyncSandbox.create(template='harbor-scaffold-cc2-1-108-8c-4g')` and skips the per-sandbox npm install (~45 s × N tasks).

```bash
python data-pipeline/scripts/build_template.py             # checks alias, builds if missing
python data-pipeline/scripts/build_template.py --rebuild   # bust cache, force fresh build
```

Template specs: 8 vCPU, 4 GB RAM, `claude-code@2.1.108` (matches the pin in `CLAUDE.md` for benchmark reproducibility).

---

## Layout

```
data-pipeline/
├── README.md                          ← this file
├── scripts/
│   ├── step1_collect.py               ← rule-based filter (both upstreams)
│   ├── step2_screen_with_llm.py       ← Gemini Pro viability judge
│   ├── swechat_postprocess_after_step2.py  ← SWE-chat-only transcript prefetch
│   ├── step3_run_pipeline.py          ← E2B + DeepSeek scaffold orchestrator
│   └── build_template.py              ← one-time E2B template builder
├── artifacts_dataclaw/
│   └── funnel.md                      ← DataClaw funnel report
└── artifacts_swechat/
    ├── funnel.md                      ← SWE-chat funnel report
    ├── step1_all_sessions.json        ← step 1 output (pre-LLM)
    ├── step1_run_config.json
    ├── step2_screening.json           ← step 2 full Pro responses
    ├── step2_candidates.json          ← step 2 VIABLE subset (input to step 3)
    ├── step2_run_config.json
    ├── sessions_raw/<sid>.json        ← gitignored; populated by post-step-2 prefetch
    └── logs/                          ← gitignored; per-task scaffold logs
```

## Open issues

- **Per-repo concentration in SWE-chat candidates.** After the 2026-05-06 step1 relaxation the top repo is `entireio/cli` (122/329, 37 %); the top 5 repos own 80 %. Use `--per-repo-cap` at step 1 or `--one-per-repo` at step 3 to diversify before scaffolding.
- **Simulator compliance.** The LLM user simulator loses track of message count over long sessions; root cause is internal-state drift.
