# Session Collection Pipeline

## v0.4.3 Data Composition (101 tasks)

The published v0.4.3 benchmark contains **101 unique tasks** from 3 source cohorts:

| Cohort | Source | Raw sessions | After screening | Final tasks |
|--------|--------|-------------|-----------------|-------------|
| DataClaw | 32 HuggingFace datasets (community `dataclaw`-tagged) | 2,228 | 236 candidates → 46 scaffolded | **46** |
| Pi-staging | 29 HuggingFace datasets (`badlogic/pi-share-hf` ecosystem) | 2,397 | 507 candidates → 308 VIABLE → 32 scaffolded | **32** (31 `pi-mono-*` + 1 `pi-excel-*`) |
| Hyperswitch | 1 HuggingFace dataset (`archit11/claude_traces_hs`) | 784 | ~40 scaffolded → 23 after resolution audit | **23** |
| **Total** | | **5,409** | | **101** |

### Per-cohort provenance

**DataClaw (46 tasks)** — Screened via the `--source dataclaw` pipeline in this directory.

| HF dataset | Unique sessions |
|---|---|
| `peteromallet/dataclaw-peteromallet` | 503 |
| `woctordho/dataclaw` + `dataclaw-windows` | 536 |
| `segin/my-personal-codex-data` | 203 |
| Other unique donors (akenove, michaelwaves, tillg, etc.) | 656 |
| Peteromallet forks (deduped to 0 new) | 0 |
| **Total (32 datasets)** | **2,228** |

Funnel: 2,228 → regex/heuristic filter (stars ≥ 20, ≥3 user messages, GitHub repo identified) → 236 candidates → Gemini Pro viability screen → 46 scaffolded tasks.

Top-level HF dataset: https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates

**Pi-staging (32 tasks)** — Screened ad-hoc before the unified `--source` orchestrator existed.

Source: 29 HF datasets exported via `badlogic/pi-share-hf`. Top contributors: `badlogicgames/pi-mono` (627 sessions), `thomasmustier/pi-for-excel-sessions` (140 sessions). 507 candidates screened, 308 judged VIABLE, 32 scaffolded into Harbor tasks.

**Hyperswitch (23 tasks)** — Screened ad-hoc before the unified orchestrator.

Source: `archit11/claude_traces_hs` — ~784 Claude session traces on `juspay/hyperswitch` (Rust, 15K★). ~40 initially scaffolded, pruned to 23 after a resolution audit removed cut-off/incomplete sessions. The companion `archit11/claude_traces_hs2` is a re-export with extra log columns, not a separate wave.

### v0.4.3 task health (Opus 4.6 cohort)

| Status | DataClaw | Pi | Hyperswitch | Total |
|--------|----------|-----|-------------|-------|
| Scored (has reward) | 46 | 30 | 14 | 90 |
| Unrecoverable (no reward) | 0 | 2 | 9 | 11 |
| **Total** | **46** | **32** | **23** | **101** |

Of the 46 scored DataClaw tasks, 10 scored 0.0 across all 3 model cohorts (Opus 4.6, DeepSeek v4 Flash, DeepSeek v4 Pro) — likely broken verifiers or infeasible tasks. Effective DataClaw tasks with signal: **36**.

---

## SWE-chat expansion (`--source swechat`)

A new upstream source under active scaffolding:

- **Source**: https://huggingface.co/datasets/SALT-NLP/SWE-chat (Stanford SALT-NLP, 5,851 sessions, 205 repos, gated access)
- **Funnel**: 5,851 → step1 deterministic filter (≥3 prompts, ≥1 action, ≥10 stars, ≥30% agent) → 760 → step2 Gemini Pro viability → **329 candidates**
- **Scaffolded so far**: 14 tasks on main (post-v0.4.3)

Schema natively exposes `repo_id`, star count, `prompt_count`, `action_count`, `agent_percentage`, `user_persona`, and `session_success` — no LLM needed for step1.

---

## Screening Pipeline

Three steps, each accepting `--source {dataclaw,swechat}`.

```
step1_collect.py          step2_screen_with_llm.py       run_pipeline.py
deterministic filter  ──► Gemini 3.1 Pro viability  ──► Sonnet scaffold workers
(no LLM)                  judge                          (worktree-isolated)
```

### Step 1 — Deterministic filter

| Source | Filters |
|--------|---------|
| SWE-chat | `prompt_count >= 3`, `action_count > 0`, `stars >= 10`, `agent_percentage >= 30` |
| DataClaw | regex GitHub-repo extraction, async star lookup (≥20), language detection, ≥3 genuine user messages |

```bash
python data-pipeline/screening/scripts/step1_collect.py --source swechat \
    --out-dir data-pipeline/screening/artifacts_swechat/

python data-pipeline/screening/scripts/step1_collect.py --source dataclaw [--skip-stars]
```

### Step 2 — Gemini Pro viability judge

Single-stage Pro screen (Flash dropped — disagreed with Pro on 46% of SWE-chat sessions, added no signal). Each candidate is judged on: *"Is the coding work reproducible in a clean Harbor task?"*

Returns: `verdict` (VIABLE/NOT_VIABLE), `primary_deliverable`, `reproducible_in_harbor`, `reason`.

```bash
GEMINI_API_KEY=... python data-pipeline/screening/scripts/step2_screen_with_llm.py \
    --source swechat --workers 10 --out-dir data-pipeline/screening/artifacts_swechat/
```

### Step 3 — Sonnet scaffolding orchestrator

Spawns N parallel `claude -p --worktree` workers (default 4). Each runs: screen → scaffold → user_simulation_prompt → tests → validate → docker build → commit + PR.

```bash
python scripts/screening/run_pipeline.py --source swechat --limit 5 --workers 2 --budget 3
```

---

## Key files

| File | Role |
|---|---|
| `data-pipeline/screening/scripts/step1_collect.py` | Step 1 deterministic filter |
| `data-pipeline/screening/scripts/step2_screen_with_llm.py` | Step 2 Gemini Pro viability judge |
| `scripts/screening/run_pipeline.py` | Step 3 Sonnet scaffolding orchestrator |
| `scripts/screening/run_validate.py` | Quality validation (instruction, turns, tests, docker) |
| `scripts/screening/run_e2e_batch.py` | Parallel E2E evaluation runner |
| `data-pipeline/screening/artifacts_swechat/` | SWE-chat step1 + step2 outputs |
