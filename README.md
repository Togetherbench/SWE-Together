# SWE-Together

A benchmark derived from real multi-turn coding sessions, measuring **coding agent performance under iterative user interaction** — the loop that single-turn benchmarks ignore.

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

**165 tasks** under `harbor_tasks/` (trunk), all derived from **real recorded coding sessions** across four sourcing waves. Current per-source breakdown:

| source | count | wave |
|---|---|---|
| cli-* | 44 | SWE-chat (Stanford `SALT-NLP/SWE-chat`) |
| pi-mono-*, pi-excel-* | 23 | Pi-staging (`badlogic/pi-share-hf`) |
| hyperswitch-* | 17 | Hyperswitch (`archit11/claude_traces_hs`) |
| hand_curated | 11 | Manually rebuilt / upstream-PR-diff rescues |
| comfyui-* | 5 | DataClaw (ComfyUI ecosystem) |
| agent-swarm-*, amytis-*, sd-scripts-* | 3 each | DataClaw |
| cc-backend, dataclaw | 2 each | DataClaw |
| reigh-*, gemini-voyager-*, rudel-*, marin-*, moltis-*, nunchaku-*, etc. | 34 | DataClaw (`peteromallet/dataclaw` publishers, repos with 20+ GitHub stars) |

Of the 165, **142 have a real canonical patch** + **22 are `no_canonical` stubs** (older DataClaw bare-string exporter, pi-mono Hashline format, etc. — fundamentally not extractable from session replay) + **1 awaits oracle extraction** (`pi-mono-keybinding-scope`). Stubs still ship; they measure how well the user-sim can recover the agent with no canonical anchor.

No synthetic tasks. Each task has a Docker environment, a natural-language instruction (**the real user's first non-trivial message, byte-verbatim modulo PII redaction**, CI-enforced via [`tests/test_instruction_verbatim.py`](tests/test_instruction_verbatim.py)), and a deterministic verifier. Two verifier families coexist:

- **Manifest F2P/P2P** (122 tasks): per-task `tests/test_manifest.yaml` with `F2P` and `P2P_REGRESSION`/`P2P` gates. The target scoring semantics are unweighted F2P coverage with bounded P2P penalty, computed centrally from `gates.json`; legacy weighted-replace and `P2P_GATING` verifiers are being migrated.
- **SWE-rebench-style** (68 tasks): per-task `tests/install_config.json` declares `test_cmd` + `FAIL_TO_PASS` + `log_parser`. The verifier runs the test command, parses stdout with one of 76 log parsers vendored from [SWE-rebench-V2](https://github.com/swerebench/swerebench-v2) (MIT), and scores by `FAIL_TO_PASS` pass rate. See `data-pipeline/scaffold/build_swerebench_configs.py`.

The key differentiator: an **LLM-powered user simulator** (Gemini 3.1 Pro by default) watches the agent work and injects corrections, redirects, and new requirements based on the original session's ground truth — recreating the multi-turn correction loop.


## Quick Start

### Setup

```bash
git clone https://github.com/Togetherbench/SWE-Together.git
cd SWE-Together

# Install dependencies (use uv, not pip)
uv sync

# Configure env — required keys live in .env at the repo root
cp .env.example .env   # create one if missing
# Then populate the keys you need (see "Environment" below).
```

### Canonical eval pipeline (always use this path)

[`eval/eval_design.md`](eval/eval_design.md) is the authoritative spec for how we measure model performance. The production flow is two binaries, not one:

1. **`src/run_eval.py` — generate trials.** For each (task, agent, sim) cohort, runs Harbor + the user simulator inside E2B and writes `trials/<cohort>/<task>__<id>/` with `agent/final.patch`, `verifier/reward.txt`, `agent/claude-code.txt`, `session.jsonl`. **This is Step 0 — trial production only. The `reward.txt` it writes is Block 3 (benchmark fidelity), not the leaderboard ranking dimension.**
2. **`eval/run_eval.py` — score those trials canonically.** Reads the trial dirs, runs the three-step protocol from `eval_design.md`, writes verdicts in-place, and emits per-task / per-cohort aggregates.

```text
Step 1  correctness       → judge_verdict.json           (Opus-4.6 in E2B, judge_score ∈ [0,1])
Step 2  intent_coverage   → intent_coverage_verdict.json (Opus-4.6 match-table + effort_cost)
Step 3  user_behavior     → user_behavior_verdict.json   (no-LLM panel, free)
aggregate                 → per-task success@{0,3,10}, effort_AUC, mean/var judge_score after the Step-2 clean filter
```

Headline ranking lives in `judge_score` (Step 1), filtered by the Step-2 clean rule on `intent_coverage.overall_score`. Never rank on `reward.txt` directly — it's noisier than the judge and per the [SWE-bench Verified critique](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/) ~35% of test failures are narrow-test false negatives the judge catches.

**Replicate count (`k`):**
- **Pilot / scout runs: `k=1` is fine** — fastest signal on whether infra is healthy (no auth/rate-limit/sandbox issues), what the empty-patch rate looks like post-#159, which tasks are broken vs. saturating.
- **Canonical leaderboard: `k=3` minimum**. Per `eval_design.md` §"Filter protocol (step 2)", the clean filter operates within the k replicates of each (task, agent) pair, so k=1 gives you no variance estimate and no filtering signal.

**Don't conflate `src/run_eval.py` output with canonical eval.** If someone says "we ran the eval," ask which: Step 0 only (`reward.txt`), or Step 0 + `eval/run_eval.py` (`judge_verdict.json` + aggregates). Only the latter is leaderboard-grade.

#### Recommended driver: plan JSON + canonical launcher

A canonical run is a matrix of (model × replicate × task) cells. Declare it once as a plan JSON; let the state-machine driver figure out what's done, what's missing, and what to launch next:

```bash
# 1) See what would launch (dry-run — also runs env preflight per cohort)
python scripts/canonical_launch_lite.py

# 2) Launch Step 0 for every cohort that still has missing cells
python scripts/canonical_launch_lite.py --launch step0

# 3) After Step 0 finishes across replicates, launch Step 1+2+3 per model
python scripts/canonical_launch_lite.py --launch eval

# 4) Both in one shot (drives until all 1260 cells are at STEP3_DONE)
python scripts/canonical_launch_lite.py --launch all

# 5) Watch progress
python scripts/canonical_status.py scripts/canonical_plan_lite70.json

# 6) Optional: batch infra audit over the trials root
python scripts/canonical_launch_lite.py --audit-after
```

The plan ([`scripts/canonical_plan_lite70.json`](scripts/canonical_plan_lite70.json)) declares 70 tasks × 6 cohorts × 3 reps = 1,260 cells. The state machine ([`src/canonical_tracker.py`](src/canonical_tracker.py)) classifies each cell as `NOT_STARTED` / `STEP0_INFRA_FAIL` / `STEP0_OK` / `STEP1_DONE` / `STEP2_DONE` / `STEP3_DONE` by reading disk, and re-running the launcher only acts on cells that still need work — `--skip-existing` is sentinel-aware, so infra-failed trials are auto-rerun. Single source of truth: edit the plan to change task list, model routing, workers, etc.; the launcher reads it directly.

#### Manual invocation (debugging / one-off)

If you want to drive a single cohort by hand without the state machine:

```bash
# Scout / pilot: Step 0 only, k=1
DEEPSEEK_API_KEY=<key> uv run python src/run_eval.py \
    --model deepseek/deepseek-v4-flash --tag ds_flash_pilot \
    --tasks cli-task-2a55af,cli-task-2f5833,cli-task-46c118,cli-task-7e3475,cli-task-f76665,cluefin-task-52eab9,comfyui-frontend-autoscale-layout,gemini-voyager-task-18a6ae,rudel-task-468289,sd-scripts-reg-image-dedup \
    --workers 10

# Canonical: Step 0 (×k) + Step 1+2+3 over the trial dirs
for k in 1 2 3; do
  ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
      --model anthropic/claude-opus-4-6 --tag opus46_r${k} --workers 10
done
ANTHROPIC_API_KEY=<key> uv run python -m eval.run_eval \
    --trials-root trials/opus46_r1 \
    --trials-root trials/opus46_r2 \
    --trials-root trials/opus46_r3 \
    --tasks-root  harbor_tasks \
    --output-dir  pipeline_logs/opus46_canonical \
    --model-tag   opus46-gemini-3.1-pro \
    --correctness-workers 50 --intent-coverage-workers 5
```

### Running the full eval (production path)

`src/run_eval.py` is the production async evaluator (Step 0 above — generates trials). It drives Harbor's `LocalOrchestrator` across N concurrent E2B sandboxes (default 20 workers), launches the in-sandbox LiteLLM proxy per trial, and writes per-cohort `trials_<tag>/<task>__<id>/` directories. To turn its output into a canonical leaderboard, hand the trial dirs to `eval/run_eval.py` per the section above.

```bash
# Anthropic — pay-per-token API key (sk-ant-api03-...)
ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model anthropic/claude-opus-4-6 \
    --tag opus46 --workers 10

# Anthropic — subscription billing via OAuth setup-token (FREE under Pro/Max plan)
#   First: claude setup-token   → prints sk-ant-oat01-... long-lived token
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-... uv run python src/run_eval.py \
    --model anthropic/claude-opus-4-6 \
    --tag opus46_oauth --workers 10
# (the script auto-detects oat01 prefix; pops ANTHROPIC_API_KEY/BASE_URL
#  from os.environ so Harbor doesn't leak them into the sandbox)

# DeepSeek (direct Anthropic-compat via in-sandbox proxy, WORKERS=10 OK)
DEEPSEEK_API_KEY=<key> uv run python src/run_eval.py \
    --model deepseek/deepseek-v4-flash --tag ds_flash --workers 10

# MiniMax direct (api.minimax.io/anthropic, WORKERS=1 — minimaxd needs serial)
MINIMAX_API_KEY=<key> uv run python src/run_eval.py \
    --model minimaxd/MiniMax-M2.7 --tag mm27 --workers 1

# z.ai GLM direct (Anthropic-compat via proxy, WORKERS=2 — Beijing peak hours
# can throttle even at single concurrency; see CLAUDE.md "glm51 (z.ai) concurrency")
GLM_API_KEY=<key> uv run python src/run_eval.py \
    --model glmd/glm-5.1 --tag glm51 --workers 2

# ARK (Volcengine — Bearer auth, 5h quota window resetting at 12:32 +0800)
ARK_API_KEY=<key> uv run python src/run_eval.py \
    --model ark/kimi-k2.6 --tag ark_kimi --workers 1
```

Default user-sim model: `openrouter/google/gemini-3.1-pro-preview` (uses `OPENROUTER_API_KEY` from `.env`). See `src/run_eval.py:build_agent_env` for every supported provider prefix.

### Running a single task (debugging)

```bash
ANTHROPIC_API_KEY=<key> uv run python src/runner.py \
    --task sageattention-headdim-256 \
    --model anthropic/claude-sonnet-4-6
```

Trial output: `trials/<task>__<id>/verifier/reward.txt`.


### Viewing traces

**Hosted:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials) — includes Trajectory, User Simulation Prompt, and Agent Logs tabs. All 13 v0.4.4.3 cohort dirs are uploaded (sanitized for API key leaks via `scripts/sanitize_traces.py`); browse by trial name (e.g., `cli-task-14ee15__abcd123`).

Each trace shows a sim version badge (e.g., `User Sim v0.6.0 · 5/11 msgs`) indicating which simulator version produced the trial and how many messages it sent.

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
| `instruction.md` | Agent reads this — the real user's first non-trivial message, CI-enforced byte-verbatim (modulo PII redaction). See [Canonical patches + instruction.md](#canonical-patches--instructionmd) below. |
| `task.toml` | Metadata (difficulty, timeouts, resources) |
| `environment/Dockerfile` | Clones repo at specific commit, installs deps, synthesizes buggy state |
| `tests/test.sh` | Deterministic verifier returning 0.0–1.0 reward |
| `tests/test_manifest.yaml` | Weighted F2P/P2P gate declarations (used by the verifier — present on all 165 tasks) |
| `user_simulation_prompt.md` | Drives the user simulator — per-turn triggers, calibration, behavioral description |
| `oracle_session.jsonl` | Canonical session in unified [`agent_session/2.0` schema](data-pipeline/agent_session.schema.json) — JSONL with header row + per-turn rows. Header carries `_grading_patch` (authoritative diff for scoring) plus extraction metadata; turn rows carry per-turn `cumulative_patch` snapshots. Supersedes `reference_patch.json` + `per_turn_coding_agent_action.jsonl` as the primary read path; legacy files remain on disk while consumers finish migrating. |
| `oracle_audit.json` | Human-edited review sidecar (`_review`, `_review_history`, `_reliability`). The pipeline never overwrites this — re-running extraction clobbers `oracle_session.jsonl` but leaves audit alone, retiring the legacy bidirectional sync. |
| `original_session.json` | Raw session data (provenance) |
| `reference_patch.json` | **Legacy primary, retained as fallback.** `eval/correctness/generate_task_goals.py` reads it when `oracle_session.jsonl` is missing; the deprecated `eval/correctness/judge_one.py` still reads it directly. Not GC'd until both consumers fully cut over to the v2.0 schema. |
| `per_turn_coding_agent_action.jsonl` | **Legacy per-turn source, retained as fallback.** Still consumed by `data-pipeline/scripts/step6_replay_per_turn_patches.py` for per-turn replay augmentation. Superseded by `oracle_session.jsonl` turn rows but not yet GC'd. |
| `oracle_intents.json` | **Eval-pipeline cache.** Written on first invocation of `eval/intent_coverage/extract_intents.py` — frozen oracle-intent list reused across every cohort × replicate for Step 2 (intent coverage). |
| `canonical_goals.json` | **Eval-pipeline cache.** Written on first invocation of `eval/correctness/generate_task_goals.py` (Phase 1) — frozen weighted-completeness rubric reused across every cohort × replicate for Step 1 (agentic judge). |

---

## Canonical patches + `instruction.md`

The benchmark ships canonical (oracle) sessions in the unified [`agent_session/2.0`](data-pipeline/agent_session.schema.json) JSONL schema — same shape as model trial outputs (see [Trial Output](#trial-output) below).

- **Per-task oracle** — `harbor_tasks/<task>/oracle_session.jsonl`. JSONL with one header row + N turn rows. Header carries `_grading_patch` (authoritative diff for scoring), `_extraction.method`, `_fidelity`, `_source`, base/repo metadata. Turn rows carry per-turn `cumulative_patch` snapshots from message replay. 164 total: 142 with grading patches (`_status: canonical`) + 22 stubs (`_status: no_canonical`). One task (`pi-mono-keybinding-scope`) currently awaits oracle extraction.
- **Audit sidecar** — `harbor_tasks/<task>/oracle_audit.json`. Human-edited only: `_review`, `_review_history[*kind=round1|round2|...]`, `_reliability`. The extraction pipeline never writes this file, so the legacy bidirectional `sync_reference_to_source.py` is retired.
- **Extraction staging** — `data-pipeline/artifacts_<source>/canonical_patches/<session_id>.json` (147 source artifacts). Step4 writes here; `migrate_oracle_to_v2.py` promotes to the per-task `oracle_session.jsonl` form.

**Read API** (used by every scoring/replay script):
```python
from agent_session import AgentSession
session = AgentSession.load(path)
patch   = session.grading_patch  # returns None for no_canonical stubs
```

The `grading_patch` property is policy-aware: returns `None` for stubs (so they can't accidentally participate in scoring) and walks turn rows backward past empty trailing turns for trials (matches `replay_all_against_latest`'s `_has_substantive_diff` logic — fixes the empty-`final.patch` bug from issue #146). CI-enforced by [`tests/test_agent_session_conformance.py`](tests/test_agent_session_conformance.py) (7 invariants × 164 tasks with oracle = 1148 cases) + [`tests/test_agent_session_negative.py`](tests/test_agent_session_negative.py) (18 reject-bad-input cases).

### Verbatim policy (CI-locked)

```
instruction.md == sanitize_pii(extract_first_non_trivial_user_text(messages))
```

Only allowed transforms:
- PII sanitization: `/Users/<name>/...` → `<HOST_PATH>`, emails → `<EMAIL>`
- Skip messages matching narrow `TRIVIAL_PATTERNS`: `EMPTY`, `INTERRUPT_TOOL`/`INTERRUPT` (Claude Code artifacts), `CAVEAT_ONLY`, `COMMAND_NAME_ONLY`, `COMMAND_STANZA` (slash-command protocol stanzas, with `<command-args>` body extraction when prose is present)

Enforced via [`tests/test_instruction_verbatim.py`](tests/test_instruction_verbatim.py) — 178 parametrized tests in 0.4s. 165/165 active tasks pass.

### Schema, audit, tooling

- **`data-pipeline/canonical_patch.schema.json`** — v1.0.0 JSON Schema (draft 2020-12) with closed enums on `_extraction.method` (6 values), `_fidelity` (6 values), `_status`.
- **`data-pipeline/EXTRACTION.md`** — definitive 1245-line walkthrough: two-layer storage, the 3-stage extractor waterfall (hyperswitch PR-diff → upstream-commit-shortcut → message-replay), curation patterns, failure modes, current state.
- **`data-pipeline/scripts/step4_extract_canonical_patches.py`** — the single unified extractor (consolidated 2026-05-15).
- **`data-pipeline/scripts/one_off/`** — re-runnable tooling: `recover_codex_stubs.py` (Codex camelCase extractor), `sync_reference_to_source.py`, `audit_schema.py`, `enforce_instruction_verbatim.py`, `smell_canonical_patches.py`.
- **`scripts/patch_stats.py`** — stdlib-only CLI dashboard (~40ms): per-source/fidelity/method histograms, audit-verdict coverage, reliability flags, patch-size stats. Run anytime.
- **`scripts/build_patch_report.py`** — generates a single-file HTML report (~25 MB) with per-task side-by-side diff via `diff2html`, original-session viewer, instruction-vs-first-user-turn mismatch detection, F2P gate weights, audit pills. Gitignored (regenerable, ~10s); host via static-site CDN if needed.

### Verification stack (5 layers)

| Layer | Coverage | What |
|---|---|---|
| Smell test (mechanical) | 144/144 source | `data-pipeline/scripts/one_off/smell_canonical_patches.py` — schema, numstat coherence, parse |
| `_review` (round-1 per-task) | 154/166 | subagent review at promote time |
| `_triple_check` (round-1 independent) | 49/166 | AI-touched canonicals only (curated / verified set) |
| `_triple_check_round2` (adversarial) | 163/166 | 9-subagent sweep; 0 unresolved FLAGs |
| End-to-end (apply + run test.sh + reward=1.0) | manual, spot-checked | The only layer that catches patch-body bugs (REDACTED tokens, SyntaxErrors, etc.) — see [`EXTRACTION.md` §8.4](data-pipeline/EXTRACTION.md) for the recipe |

---

## User Simulator

The user simulator (`src/user_agent/`) is an LLM that role-plays as the original human user. It watches the agent's terminal output and decides when to intervene.

### Architecture (v0.6.0)

- **Claude Code harness only.** Every target model — Opus, Sonnet, MiniMax, GLM, DeepSeek, Kimi, … — runs through Claude Code CLI v2.1.108 (baked into every task image) and reaches its provider via the in-sandbox LiteLLM proxy on `localhost:4210`. Mixing harnesses across models would conflate harness quality with model quality.
- **User-sim model: Gemini 3.1 Pro** (default `openrouter/google/gemini-3.1-pro-preview`). Best GT coverage, most realistic turn structure, lower cost than Claude.
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
trials/<cohort>/<task>__<id>/
├── config.json                     # Serialized trial config
├── user_simulation_prompt.md       # Copy of the sim prompt used
├── agent/
│   ├── claude-code.txt             # Raw CC CLI transcript (JSONL appended by Harbor)
│   ├── patches/turn-N.patch        # Cumulative diff vs harbor-base, per turn
│   ├── patches/turn-N.incremental.patch  # Delta between turn N-1 and N
│   ├── final.patch                 # Last cumulative diff (UNRELIABLE — overwritten per turn,
│                                   #   can end up empty when wrap-up turns produce no diff;
│                                   #   see issue #146 + the session.jsonl derivative below)
│   ├── trajectory.json             # Enriched ATIF trajectory (pre-built for fast viewing)
│   ├── episode-N/
│   │   ├── prompt.txt              # Terminal output the agent saw
│   │   ├── response.txt            # Agent's response (analysis + commands)
│   │   ├── debug.json              # Token/parsing debug info
│   │   └── user_decision.json      # Sim decision (action, content, version, stats)
│   └── recording.cast              # asciinema terminal recording
├── session.jsonl                   # NEW: derived agent_session/2.0 view of the trial — produced
│                                   #   by `python data-pipeline/scripts/step5_trials.py <trial_dir>`.
│                                   #   Same JSONL shape as harbor_tasks/<task>/oracle_session.jsonl;
│                                   #   load via AgentSession(...).grading_patch to get the
│                                   #   real diff (walks past empty trailing turns, fixes #146).
└── verifier/
    ├── test-stdout.txt             # test.sh stdout
    ├── gates.json                  # Per-gate verdicts (when test_manifest.yaml is used)
    └── reward.txt                  # Final score (0.0–1.0)
```

---

## Scoring + replay scripts

The same `agent_session/2.0` schema covers oracle (canonical) sessions and model trial outputs, so a single read API drives every replay/scoring path:

| Script | Layer | What it does | Retry |
|---|---|---|---|
| [`src/run_eval.py`](src/run_eval.py) | Orchestrator | Production eval — Harbor LocalOrchestrator + user-sim + per-trial concurrency | `RetryConfig` (PR #149): `RateLimitException`, `TimeoutException`, `ConnectTimeout`, `AddTestsDirError`; backoff 60→300s × 5 |
| [`scripts/oracle_replay.py`](scripts/oracle_replay.py) | Direct E2B SDK | Score every `harbor_tasks/*/oracle_session.jsonl::_grading_patch` against the latest verifier in fresh E2B sandboxes. Answers "can the oracle actually score 1.0?" | `_sandbox_create_with_retry` — strict superset of PR #149 (10 exception classes, same backoff). Permanent-pattern short-circuit on E2B 404 ("template not found", "404:") |
| [`scripts/candidate_replay.py`](scripts/candidate_replay.py) | Direct E2B SDK | Unified-schema analog of `replay_all_against_latest.py`. Scores each trial's `session.jsonl::grading_patch` instead of walking `agent/patches/turn-N.patch` | Inherits from `oracle_score_one` |
| [`scripts/replay_all_against_latest.py`](scripts/replay_all_against_latest.py) | Direct E2B SDK | Legacy bulk replay against `agent/patches/turn-N.patch` (pre-schema) | Same retry shim |
| [`data-pipeline/scripts/step5_trials.py`](data-pipeline/scripts/step5_trials.py) | Local | Derives `session.jsonl` per trial from captured `agent/patches/` + `agent/claude-code.txt`. Use `--all <cohort_root>` to batch | N/A (local-only, no E2B) |

**Retry layering**: orchestrator-side (`src/run_eval.py`) and direct-SDK (`oracle_replay.py` / `candidate_replay.py`) are parallel call paths — never nested. `tests/test_oracle_replay_retry.py` covers the full decision matrix (11 cases including the v0.4.4 transient failure modes: `SandboxException: 400 i/o timeout`, `ConnectError SSL: UNEXPECTED_EOF`, `RemoteProtocolError: Server disconnected`).

**E2B template aliasing** — `HARBOR_TEAM_PREFIX="tb"` (default since PR #149; mirrored by `candidate_replay._resolve_alias`). Aliases are `tb-<task>__<dirhash(env_dir, sha256)[:8]>` with `.` → `-` substitution, scoped to togetherbench's E2B namespace (no shichaopei collision).

---

## Data Pipeline

```
~11,000 raw sessions across 4 sourcing waves:
  ├─ SALT-NLP/SWE-chat         5,851  (Stanford gated HF dataset; largest wave, added post-v0.4.3)
  ├─ pi_staging harvest        2,397  (29 HF datasets, top: badlogicgames/pi-mono 627)
  ├─ new_dataclaw harvest      ~2,014 (16+ DataClaw publishers; top: woctordho, peteromallet, segin)
  └─ archit11/claude_traces_hs   ~784 (third-party HF research dataset on juspay/hyperswitch)
    ↓ Step 1: rule-based filter (stars ≥20, ≥3 user msgs, public repo) — no LLM
    ↓ Step 2: Gemini 3.1 Pro session viability judge (single stage)
    ↓ Step 4 [SWE-chat only]: extract canonical patch from commits.parquet
                              (single-commit checkpoints — 170/329 high-trust subset)
    ↓ Step 5 [SWE-chat only]: Gemini 3.1 Pro patch-aware viability judge
                              (filter formatting / lockfile / refactor-too-large)
    ↓ Step 3: E2B + DeepSeek-v4-pro scaffold (claude -p in 8-vCPU sandbox)
                              (10-step inline prompt: screen → scaffold → tests → audit)
    ↓ build_swerebench_configs.py [optional]: migrate test.sh to install_config.json
                              + vendored SWE-rebench log parsers (68 tasks so far)
165 Harbor benchmark tasks  (current trunk: 142 real canonicals + 22 stubs + 1 awaiting oracle)
    ↓ src/run_eval.py (in-process Harbor LocalOrchestrator, concurrent E2B sandboxes;
                        per-provider concurrency caps: anthropic/deepseek=10, glm=2, mm=1)
    ↓ scripts/finalize_v044.sh (replay all captured patches against latest test.sh →
                                 per-(model, task) latest-trial dedup → exclude rate-limit
                                 corrupted + DS 402 billing → tar.zst → gh release upload)
v0.4.3 release: 5 cohorts, ~490 trials, 99 unique tasks scored (101-task suite at the time)
v0.4.4.x consolidation: 13 cohort dirs, 6 models, 932 unique (model,task) pairs across
                         168 audit-corrected tasks; v0.4.4.3 added Opus subscription-OAuth
                         + GLM fill cohorts and DeepSeek HTTP 402 / rate-limit exclusions
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
togetherbench@0.4.4.3
  Tasks: 173 (168 unique scored after audit exclusions)
  Commit: a24b94b1a
  User sim: v0.6.0
  CC binary: 2.1.108 (pinned in image)
  Cohorts: 13 trial dirs across 6 models
    Opus 4.6:           opus46_v043 + opus46_or_swerb + opus46_v044_fill
    DeepSeek V4 Pro:    deepseek_v4_pro_{v043,swerb}
    DeepSeek V4 Flash:  deepseek_v4_flash_{v043,swerb}
    MiniMax M2.5/M2.7:  minimax{25,27}_v043 + minimax_m{25,27}_swerb
    GLM 5.1:            glm51_swerb + glm51_v044_fill

togetherbench@0.4.5.0  (data-integrity release — not yet rerun against models)
  Tasks: 166 (144 real canonicals + 22 no_canonical stubs)
  Commit: f880e843b  (PR #137)
  User sim: v0.6.0
  CC binary: 2.1.108
  Changes vs 0.4.4.3:
    - instruction.md byte-verbatim policy CI-locked (178 tests)
    - 3 previously-stub Codex-format tasks recovered to real canonicals
    - 4 broken canonicals fixed (REDACTED token, SyntaxError, over-narrow
      F2P gates, mocked-then-rebound platform import)
    - canonical_patch.schema.json v1.0.0 published
    - 6 enforcement-policy + 7 audit FLAGs all resolved or annotated
    - Schema normalized: 16 method spellings → 6, 10 fidelity values → 6
    - Source/reference layer divergences: 132 → 0
    - data-pipeline/EXTRACTION.md: definitive 1245-line walkthrough
```

When citing results, always include the benchmark version:

> "DeepSeek V4 Pro scored 0.4013 avg reward on togetherbench@0.4.4.3 (n=169 tasks, user sim v0.6.0, audit-corrected)"

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
| `@0.4.4`–`@0.4.4.3` | 2026-05-10–11 | 173 | v0.6.0 | **Replay-only consolidation + audit corrections.** Single coherent leaderboard across 13 cohort dirs; per-(model, task) latest-trial dedup; auditor's preserved-pre-rescue bug closed (202 trials drop honestly instead of inheriting inflated scores); strict-fresh policy (every committed reward from a v17 latest-test.sh execution). v0.4.4.2 added Opus + GLM **fill runs** (Opus 30 new tasks via `claude setup-token` subscription billing; GLM 21 new tasks via z.ai direct). v0.4.4.3 added two systematic-bias exclusions: **DeepSeek HTTP 402 billing failures (162 trials)** + **rate-limit-corruption trials (38)** — DS Pro then took #1. |
| **`@0.4.5.0`** | **2026-05-16** | **166** | **v0.6.0** | **Data-integrity release** (PR #137, not yet rerun against models). instruction.md byte-verbatim policy CI-locked (178 parametrized tests); 3 Codex-format stubs recovered to real canonicals via new `recover_codex_stubs.py`; 4 broken canonicals fixed (REDACTED token, Python SyntaxError, over-narrow F2P gates, broken-mock verifier) found by end-to-end pass that metadata audits missed; v1.0.0 JSON Schema published; format vocab normalized (16 method spellings → 6, 10 fidelity values → 6); source/reference divergences 132 → 0; `data-pipeline/EXTRACTION.md` is the definitive pipeline doc. |

**Roadmap to v0.4.5.1+**:
1. **Re-run all 6 cohorts against v0.4.5.0 task set** to refresh the leaderboard with the data-integrity fixes baked in (verbatim instructions, fixed canonicals, etc.).
2. **Re-run DeepSeek swerb with valid billing** to recover the 162 excluded trials.
3. **GLM 5.1 fill remaining 71 tasks** when z.ai's account-level throttling eases.
4. **Verifier-quality pass** for the 34 all-zero tasks and 6 all-one tasks. See `analysis/V044_RELEASE_NOTES.md` "Harness audit" section.
5. **Wire `tests/test_instruction_verbatim.py` + `smell_canonical_patches.py` into CI** (currently runnable locally; not yet in GitHub Actions).
6. **Promote `FAIL_TO_PASS` / `PASS_TO_PASS` to top-level `reference_patch.json` fields** for zero-friction SWE-bench JSONL export.
7. **Build the 3-pane patch viewer** (gold patch | model patch | per-turn timeline) — the unique-to-us UX gap per `data-pipeline/EXTRACTION.md` Appendix D.

---

## Data Source

DataClaw-source sessions come from the distributed publishing ecosystem of [peteromallet/dataclaw](https://github.com/peteromallet/dataclaw) — a CLI that exports Claude Code / Codex / Pi conversation history to Hugging Face as redacted datasets (every export tagged `dataclaw`; discoverable at [`?other=dataclaw`](https://huggingface.co/datasets?other=dataclaw)). DataClaw sessions are filtered to repos with 20+ GitHub stars. Our consolidated screening snapshot lives at [`alexshengzhili/dataclaw-harbor-candidates`](https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates) (1,468 rows as of 2026-05-06; was 2,228 at 2026-03-24 audit). Pi-ecosystem and Hyperswitch sessions come from `pi-share-hf` exports and `archit11/claude_traces_hs` respectively (see Data Pipeline above).
