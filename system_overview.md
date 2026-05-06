# System Overview

This document describes how SWE-Replay is built: the pipeline that produces
tasks, the harness that evaluates agents on them, and the design commitments
that keep results comparable across runs. For the research question and
published scores, see [README.md](README.md).

## Scope

The README answers *what the benchmark measures and what the current numbers
are*. This document answers *how the benchmark produces those numbers, and
where each decision lives in the code*. It is intended for contributors who
need to extend the pipeline, debug an eval run, or audit a result.

## Measurement

A trial evaluates one (model, task) pair and emits a score trajectory across
turns. The harness scores the sandbox state at three points:

| Turn label     | When                                  | What it measures                   |
| -------------- | ------------------------------------- | ---------------------------------- |
| `nop` (-1)     | Before the agent runs                 | Baseline — should be ≥ 0 but < 1   |
| `after_instruction` (0) | After the agent's first attempt | Single-turn ceiling (T0)      |
| `after_user_turn_N`     | After user-sim turn N           | Multi-turn accumulation       |

Score recording lives in
[`src/user_agent/user_enabled_claude_code.py`](src/user_agent/user_enabled_claude_code.py)
around line 306 (`_record_turn_score`). Each turn's reward is written to
`/logs/agent/episode-{turn}/turn_reward.json` inside the sandbox so the
trajectory can be reconstructed post hoc.

The headline metric is **multi-turn gain = Final − T0**. A well-designed task
should have a T0 ceiling below ~0.5 across capable models; otherwise the task
is measuring single-turn coding ability rather than the iterative correction
loop the benchmark targets.

## Pipeline

Four stages, each with a narrow script boundary:

```
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ 1. Ingest        │──►│ 2. Author task   │──►│ 3. Evaluate      │──►│ 4. Publish       │
│ session_collect. │   │ .claude/commands │   │ src/run_eval.py  │   │ scripts/, deploy │
└──────────────────┘   └──────────────────┘   └──────────────────┘   └──────────────────┘
  HuggingFace →          scaffold →              E2B sandbox →          S3 → Cloudflare →
  screened pool          tests → review          Harbor orchestrator    traces.togetherbench.com
```

### 1. Ingest — `scripts/screening/` (code) + `session_collection/` (data)

Raw sessions arrive from DataClaw on HuggingFace and pass through a Gemini-only
screening pipeline that enforces the benchmark's hard criteria: public repo,
specific base commit, no secrets, reconstructible outputs, and — the
constraint that distinguishes this benchmark — *at least three meaningful user
interventions*. Single-turn sessions are rejected at this stage because they
cannot exercise the correction loop the benchmark is built to test.

Stage 1 (`scripts/screening/screen_with_gemini.py`) — Gemini 3 Flash with
grounded search identifies the primary repo, star count, and whether the
session is actually modifying code. Stage 2 (`scripts/screening/llm_rescreen.py`)
— Gemini 3.1 Pro deep judge rules on whether the work is reproducible in a
clean Harbor task. Bulk session data and screening outputs live (gitignored)
under `session_collection/`; the scripts and design docs are tracked at
`scripts/screening/`.

### 2. Author task — `.claude/commands/`

```
harbor_tasks/<name>/
├── instruction.md            # Turn 1 user message
├── task.toml                 # difficulty, time budget, internet allowance
├── environment/Dockerfile    # clones upstream at base commit, synthesizes bug
├── tests/test.sh             # verifier → reward ∈ [0,1] to /logs/verifier/reward.txt
├── user_simulation_prompt.md # ground-truth anchors for the user sim
└── original_session.json     # provenance
```

See *Test quality* below for how `test.sh` is built and defended.

## Test quality

A verifier's job is to distinguish a real fix from a plausible-looking one.
Most of the work of running this benchmark is keeping `test.sh` ahead of the
agents trying to game it.

**Every check has a tier.** Gold + Silver ≥ 60% of reward, Bronze ≤ 40%.

| Tier | Rule | Example |
| --- | --- | --- |
| Gold | Numerical output verified against a reference library | quantize w/ `libggml`, dequant w/ agent code, compare within tolerance |
| Silver | Import + call + assert on output | `merged = Cache.merge([c1, c2]); assert merged.shape[0] == 2` |
| Bronze | AST/regex — only when code can't execute (Triton, CUDA C++, missing deps) | function exists AND body > 3 non-docstring stmts |

**P2P is the anti-theatrical mechanism — but it never carries weight.** If
the upstream repo has a CPU-safe subset of its own test suite, that subset
runs inside `test.sh` as a regression gate. The gate is **gating only**:
on failure it caps the trial reward to 0.0; on pass it contributes nothing
positive. (Pre-v0.4.3 the implementation was additive — a P2P pass added
~10–20% to the reward and an F2P pass on top of that hit the 1.0 ceiling,
indistinguishable from a perfect solve. Commit `c8bc168a` standardized the
weighted-replace formula across 30 verifiers.) If a manifest declares a
P2P_REGRESSION gate without a backing `command:` field, drop the entry —
decorative gates with `weight: 0.0` are clutter, not signal.

**AST trash — what the linter (`src/lint_tests.py`) rejects:**

| Rule | Severity | What it catches |
| --- | --- | --- |
| `set-e-abort` | critical | `set -e` aborts on first failure; partial scores never accumulate |
| `no-reward-write` | critical | nothing written to `/logs/verifier/reward.txt` |
| `import-fallback` | critical | `try: import … except: ast.parse(…)` — a stub with the right keywords passes the fallback |
| `exists-fallback` | critical | `os.path.exists(f)` in an `except` block awards points — empty file scores |
| `self-referential` | critical | test reads a value from the agent's file and compares it to itself |
| `comment-injection` | warning | `grep` on source without stripping comments — agent adds a comment with the keyword |
| `ungated-structural` | warning | Bronze checks run even when behavioral/gate checks fail |
| `expensive-test` | warning | single test ≥ 0.30 of total — binary gate instead of graduated scoring |
| `conditional-gate` | warning | one test's pass/fail gates another's execution; failure cascades |
| `weight-sum` | warning / critical | weights don't sum to ~1.0 or exceed 1.0 without a `min(1.0, …)` cap |
| `no-gate` | warning | no syntax / compile gate, so garbage code still scores structural points |
| `no-f2p` | warning | no labeled fail-to-pass behavioral test |

**Iteration loop — how a task converges on a real verifier:**

```
                  ┌──────────────┐
  sessions_raw/ ─►│ /write-tests │─────► test.sh draft
                  └──────┬───────┘
                         │
                         ▼
                  ┌──────────────┐      critical?   ┌────────────────┐
                  │ lint_tests   ├───────yes───────►│ author fixes   │─┐
                  └──────┬───────┘                  └────────────────┘ │
                         │ clean                                       │
                         ▼                                             │
                  ┌──────────────┐                                     │
                  │ self-audit:  │  stub ≤ 0.30  ?                     │
                  │ • stub-game  │  alt-fix ≥ 0.70 ?                   │
                  │ • alt-fix    │  baseline low  ?                    │
                  │ • /review    │                                     │
                  └──────┬───────┘                                     │
                         │ pass                                        │
                         ▼                                             │
                  ┌──────────────┐                                     │
                  │ validate_    │  nop reward in (0, 1) on buggy      │
                  │ tasks (E2B)  │  base — catches "all-perfect"       │
                  └──────┬───────┘                                     │
                         │ pass                                        │
                         ▼                                             │
                  ┌──────────────┐  rate limits, flaky build,          │
                  │ fix_tasks    │  mis-scored buggy state             │
                  │ (Opus in E2B)├─────────retry / edit────────────────┘
                  └──────┬───────┘
                         │ stable
                         ▼
                  ┌──────────────┐  2-3 models on E2B;                 ┌─────────────┐
                  │ /run-eval    │  scores spread, not flat ───no────► │ harden test │
                  │ (smoke x N)  │  T0 < 0.5 across capable models     │  narrower   │
                  └──────┬───────┘                                     │  alt-fix    │
                         │ yes                                         └─────┬───────┘
                         ▼                                                   │
                     ship task  ◄────────────────────────────────────────────┘
```

The three self-audit gates are the load-bearing checks:

- **stub-game** — replace every function body with `pass`; max score ≤ 0.30.
- **alt-fix** — write a *different* valid fix than the session's; score ≥ 0.70.
  Failure means the verifier is too narrow (SWE-bench Verified's [35.5% narrow-test
  failure rate](https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/)
  is the cost of skipping this).
- **baseline** — `src/validate_tasks.py` runs `test.sh` on the untouched buggy
  state in E2B; a score of 1.0 here means the verifier is theatrical.

### 3. Evaluate — `src/run_eval.py`

A single async process drives Harbor's `LocalOrchestrator` across N concurrent
E2B sandboxes (default 25 workers). Replaces an earlier subprocess-per-trial
design that used ~300 MB of RAM per worker; the in-process version uses
~18 MB and scales to 100+ concurrent sandboxes on a 15 GB host.

For any run, the orchestrator:

1. Resolves the target model and its provider via `resolve_model()` in
   `src/runner.py`.
2. Builds an agent environment dict (`build_agent_env`, line 112 of
   `run_eval.py`) containing `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, and
   any provider-specific variables.
3. **Applies that dict to `os.environ`** — this is load-bearing. Harbor's
   `ClaudeCode.create_run_agent_commands()` reads env vars from `os.environ`
   at command-build time, not from the `AgentConfig.env` dict. A silent bug
   pre-2026-04-12 routed all non-Anthropic models to Anthropic because this
   update was missing; see the *Design invariants* section below.
4. Launches one E2B sandbox per trial. Inside the sandbox, a LiteLLM proxy
   listens on `localhost:4210` and translates OpenAI-format Claude-Code calls
   to the target provider (Fireworks, Z.AI, MiniMax, Chutes, OpenRouter,
   etc.). The Claude Code CLI itself always thinks it is talking to
   Anthropic; the proxy is what makes cross-provider evaluation possible.
5. Runs the agent through up to five user-sim turns. Scoring happens at
   turn −1 (nop baseline), turn 0 (after instruction), and after each user
   turn. The user simulator reads `user_simulation_prompt.md` and replies
   based on what remains undone relative to the ground-truth anchor.

Trial outputs land in `trials-<tag>/<task>/` with `trajectory.json`, per-turn
rewards, the full agent transcript, and the user-sim transcript.

### 4. Publish — `scripts/` + `deploy/`

Trials are uploaded to S3 (`t3.storageapi.dev`) via
`scripts/upload_traces.py`. Railway auto-deploys `deploy/start_viewer.py` on
push to `main`; Cloudflare fronts it at
[traces.togetherbench.com](https://traces.togetherbench.com). Immutable trial
data is cached for 24 h; index endpoints for 5 min.

## Design invariants

These are decisions that should not be changed casually. Each exists because
we have been burned by its absence.

**User simulator model defaults to Gemini 3.1 Pro and is treated as fixed
infrastructure.** The default `openrouter/google/gemini-3.1-pro-preview`
lives in `src/run_eval.py` and `src/runner.py`; the `--user-model` flag
exists for ablation but every published cohort uses the default. A
different user sim behaves differently — different trigger sensitivity,
different phrasing, different tolerance for partial solutions — and that
makes scores across runs incomparable. The benchmark measures *agent*
capability under consistent feedback; do not change the sim model when
producing comparable numbers.

**All agents use the `claude-code` adapter.** Harbor also supports Terminus
2, but only Claude Code is used here. Every target model — Opus, Sonnet,
Haiku, Kimi, MiniMax, GLM — runs through the Claude Code CLI and reaches its
actual provider via the in-sandbox LiteLLM proxy. Changing adapters across
models would conflate adapter quality with model quality.

**Non-Anthropic models must route through `localhost:4210`.** Every branch of
`build_agent_env()` sets `ANTHROPIC_BASE_URL=http://localhost:4210` because
Harbor/Claude-Code reads it from `os.environ`. Omitting it (or omitting the
`os.environ.update()` call that follows) causes the sandbox to connect
directly to `api.anthropic.com` using the host key, silently turning every
"Kimi" or "MiniMax" run into a Sonnet run with the wrong tag. All
non-Anthropic results in `trials-*` from before 2026-04-12 should be
considered suspect for this reason.

**Instruction prompts are never rewritten to harden tests.** If an agent
exploits a weak test, the fix is in `tests/test.sh`, not in
`instruction.md`. Rewriting the instruction to steer the agent away from a
loophole would bias the benchmark toward models that happen to parse our
phrasing the way we intend, rather than toward models that actually solve
the underlying problem.

**E2B, not local Docker.** WSL does not expose a Docker daemon in this
environment, and the eval depends on sandbox reproducibility across machines.
Any Dockerfile change requires an E2B template rebuild — the template hash
is content-addressed and stale caches will silently serve the old image.

## Known limitations

The benchmark is honest about where it is weak.

**Single-turn tasks still exist.** A subset of `harbor_tasks/` directories
are single-turn by design — the `user_simulation_prompt.md` explicitly tells
the user sim to send zero messages. These tasks measure coding ability but
not the correction loop, and they should not carry the SWE-Replay label.
Per the v0.4.3 audit (`analysis/V043_IMPROVEMENT_PLAN.md`): 26 all-zero, 3
all-perfect, and 8 tight-cluster (std < 0.05) tasks dilute the signal —
pruning them widens cohort spread from 0.16 to 0.24 (+50%) on a 60-task
suite. Pruning is active work tracked against the v0.4.3-prep branch.

**Some multi-turn tasks reach 1.0 with zero user interventions.** A handful
of tasks score 1.0 on models that never received a single user-sim reply.
Either the user sim's trigger conditions are too narrow, or the tests do
not actually require the later-turn work. The target ceiling for a
well-designed task is a T0 score below 0.5; anything meaningfully higher
is a signal that Turn 1's instruction is doing the work the user turns
were meant to do. Two tasks (`hyperswitch-8338`, `pi-mono-auto-41636ae5`)
are P0 in this category: their Dockerfiles pin to the *post-fix* commit,
giving every model 0.82–0.93 free credit.

**Buggy state is reverse-engineered, not captured live.** Base commits are
pinned and the synthesis is deterministic, but the regex-based removal in
`synthesize_buggy_state.py` is fragile against upstream refactors. Tasks
that clone from squash-merged PR branches depend on GitHub retaining
orphaned commits — we should mirror or tag these for durability.

**Source-session resolution is uneven.** Per the 2026-04-21 audit
(`scripts/lint/session_resolution_audit.py`), of the 140 tasks scaffolded
during v0.4.0, **~25% have low-fidelity ground truth** — the original
session ended on a rate limit, ran out of credits mid-debug, or stalled
without confirming a fix. Distribution: 86 resolved (61%), 31 cut_off
(22%), 19 ambiguous (14%), 4 stuck (3%). Hyperswitch dominates `cut_off`
(~20 of 31 — the Rust scaffolding wave). Each task carries a
`session_resolution` field in `task.toml [metadata]` so downstream
analyses can filter or weight accordingly. An evaluated agent's
"failure" on a `cut_off` task may reflect baseline incompleteness rather
than capability.

**Verifier accepts multiple approaches by design.** Tests are written to
accept both the session's approach and the merged PR's approach. This is
correct on fairness grounds (per the SWE-bench Verified critique) but means
a partial solution that matches one path may score above its true merit.

**Information-leakage surface.** `synthesize_buggy_state.py` is deleted at
Docker build time, and `tests/test.sh` is mounted only after the agent
exits. But the Dockerfile and the upstream PR are both public on GitHub,
and `allow_internet = true` is required so Harbor can install the agent
itself. A sufficiently motivated agent with web access could in principle
locate the benchmark repo and read the intended diff. We treat this as an
accepted limitation rather than a solved problem.

## Codebase map

```
harbor_tasks/         # 101 self-contained task directories
base_images/          # 5 cluster Dockerfiles (comfyui, hyperswitch, pi-mono, reigh, sd-scripts)
                      #   inherited by 100+ thin-child task images; CC v2.1.108 baked here
sessions_raw/         # raw DataClaw + pi-mono + hyperswitch sessions (provenance only)
session_collection/   # ingest + screening data (gitignored; fetch from HF dataset alexshengzhili/dataclaw-harbor-candidates)
scripts/screening/    # ingest + screening code (Gemini-only judge)
src/
  run_eval.py         # in-process batch evaluator (Harbor LocalOrchestrator)
  runner.py           # model resolution, user-sim wiring, single-task CLI
  user_agent/         # Claude Code adapter wrapper; per-turn scoring + LiteLLM proxy launcher
                      #   user_enabled_claude_code.py launches the in-sandbox proxy on :4210
  lint_tests.py       # static anti-gaming linter for test.sh files
  validate_tasks.py   # E2B nop-baseline validation (catches all-perfect bugs)
  fix_tasks.py        # boss-agent (Opus in E2B) iterative task-hardening loop
scripts/
  build_leaderboard.py        # cohort → clean_mean / shared / discriminating tables
  per_turn_replay.py          # replay verifier on each turn's cumulative patch
  per_turn_replay_sweep.py    # cohort-wide replay (concurrency-capped at 5)
  user_sim_stats.py           # avg turns / intervene% / no-op% per cohort
  generate_v043_report.py     # compose V043_REPORT.md from JSON outputs
  finalize_v043.sh            # full release orchestrator: stats → leaderboard → replay
                              #                            → report → tar.zst → gh release
  audit_v043_uploads.py       # S3 upload-coverage audit (per-cohort, per-trial-file)
  sanitize_traces.py          # strip secrets before upload (path-aware since v0.4.2)
  upload_traces.py            # S3 publish
analysis/
  V043_REPORT.md              # release report
  V043_RELEASE_NOTES.md       # public release notes
  V043_IMPROVEMENT_PLAN.md    # post-v0.4.3 roadmap
  v043_leaderboard.{json,md}  # canonical leaderboard
deploy/
  start_viewer.py             # Railway entrypoint for traces.togetherbench.com
  railway.toml                # Railway config
.claude/commands/             # screen-session, scaffold-task, write-tests, review-task,
                              #   validate-task, run-eval — the authoring workflow
external/harbor/              # vendored Harbor (TerminalBench harness)
trials_<cohort>_v043/         # v0.4.3 per-cohort trial dirs
release_assets_v043/          # tar.zst per cohort, uploaded to GitHub release
```

## Version + reproducibility

Each eval run stamps its outputs with the git SHA, tag (or `untagged`), and
tree-clean flag (`run_eval.py` around line 460). Published results in
README.md pin a specific version tag (`togetherbench@0.4.3`, GitHub release
`v0.4.3-20260501`). Results should always be cited alongside the version
that produced them — the task set, the verifier logic, the user-sim model
(currently v0.6.0), and the Claude Code binary (pinned to 2.1.108 in every
task image) all affect scores and all evolve.
