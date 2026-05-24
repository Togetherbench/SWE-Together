# User Simulator Changelog

Each version is tagged in the code via `UserAgent.VERSION`. Trial logs record
which version produced them so results are always traceable.

## v0.8.0 — 2026-05-24

**Codex + Gemini-CLI user-sim enablement.**

Two new agent wrappers join `UserEnabledClaudeCode`, so the same user-sim +
ground-truth + per-turn-diff machinery now works against codex (OpenAI/codex
CLI) and gemini-cli (Google Gemini CLI). Both follow the
"sequential re-issue with conversation history" pattern (neither CLI has
`--resume`).

### New wrappers

- **`UserEnabledCodex`** ([src/user_agent/user_enabled_codex.py](user_enabled_codex.py))
  - Routes gpt-5.x through codex via three auth/backend paths:
    1. `--model openrouter/openai/gpt-5.x` → codex 0.117.0 + OR HTTP Chat Completions
       (0.117.0 pinned because newer codex requires the WebSocket Responses API
        that OpenRouter does not expose). Wrapper preserves the `openrouter/...`
        prefix so OR receives `openai/gpt-5.5`, not the bare leaf.
    2. `--model openai/gpt-5.x` + `OPENAI_BASE_URL` env (any OpenAI-compat
       backend). Cleanly handed off via the upstream `openai_base_url` config.toml
       block (harbor PR #1482).
    3. **ChatGPT subscription OAuth** (`CODEX_USE_HOST_AUTH=1`):
       overlays the host's `~/.codex/auth.json` into the in-sandbox
       `$CODEX_HOME/auth.json`, so the in-sandbox codex bills against the
       host user's ChatGPT subscription (flat cost) instead of pay-per-token
       API. `CODEX_VERSION=0.133.0` env var upgrades the in-sandbox codex past
       the 0.117.0 default (required for gpt-5.5 model name).
  - Opt-in `codex exec resume <thread_id>` path
    (`CODEX_USE_RESUME=1`) — captured but off by default until the
    verifier-flake regression is root-caused.

- **`UserEnabledGeminiCli`** ([src/user_agent/user_enabled_gemini_cli.py](user_enabled_gemini_cli.py))
  - Wraps `gemini --yolo --model=<model> --prompt=<msg>` with the same
    multi-turn / user-sim / per-turn-diff pipeline.
  - Setup auto-strips repo-level `.gemini/settings.json` (often ships
    project-level hooks like `entire-before-tool` that call `go`/`pre-commit`
    binaries not in our sandbox, deadlocking every tool call).
  - Sets `GEMINI_CLI_TRUST_WORKSPACE=true` so the CLI doesn't reject the
    workspace as "untrusted" in headless mode.

### Shared infrastructure (NEW)

- **`src/user_agent/exec_helpers.py`** — `exec_with_budget()` wraps every
  `environment.exec()` call with two guards:
  - `PER_EXEC_CAP_SEC = 1200` (20 min) — single-call ceiling via
    `asyncio.wait_for`, so a hung in-sandbox call dies fast.
  - `TRIAL_BUDGET_SEC = 7200` (2 h) — trial-wide wall-clock. Codex+gpt-5.5
    runs ~3× slower than claude_code+Opus; the budget guard caps that ratio
    without leaving the cohort exposed to multi-hour single tasks.
  - On timeout: returns a synthetic `_TimeoutResult` so the caller's
    `result.return_code` / `.stdout` paths still work, and the multi-turn
    loop can break gracefully and still capture `final.patch`.

  Without this, the v0.7.0 wrapper would hang silently — observed in early
  Gemini scout where one stuck `gemini exec` burned **6 h 36 min** on a
  single trial before manual kill.

- **`src/user_agent/repo_diff.py`** — shared per-turn diff capture
  (`tag_harbor_base()`, `capture_git_diff()`, `_repo_discovery_cmd()`).
  Extracted from the v0.7.0 claude_code wrapper so codex + gemini_cli
  inherit the same `patches/turn-N.{patch,incremental.patch}` artifacts +
  `_last_turn_diff` feed into `UserAgent.process(code_changes_diff=…)`.

### Runner / orchestrator changes

- **`src/runner.py`** — `--agent-type gemini-cli` added; existing
  Chutes/OpenRouter/Fireworks/GLM proxy branches gated on
  `agent_type == "claude-code"` so codex+OpenRouter no longer hijacks
  the claude-code proxy env (which would set `action_model =
  "claude-sonnet-4-6"` and corrupt the codex invocation). New
  `is_openrouter and agent_type == "codex"` branch sets `OPENAI_BASE_URL`
  on the host so the codex wrapper reads it.

- **`src/run_eval.py`** — `--agent-type {claude-code,codex}` flag added
  (default claude-code, backwards-compatible). When `--agent-type codex`,
  switches `import_path` to `UserEnabledCodex`, drops the claude-code-only
  env vars (`ANTHROPIC_*`, `LITELLM_PROXY_*`, `PROXY_*`), and forwards the
  codex-relevant host env vars (`CODEX_USE_HOST_AUTH`,
  `CODEX_HOST_AUTH_JSON`, `CODEX_VERSION`, `CODEX_USE_RESUME`,
  `OPENAI_BASE_URL`) into the trial's agent_env. Also pops the
  `version: "2.1.108"` kwarg (Claude Code's version, would otherwise pass
  into `install-codex.sh.j2`'s `{% if version %}` block and `npm install -g
  @openai/codex@2.1.108` would ETARGET).

- **`src/user_agent/__init__.py`** — note explaining the three wrappers are
  lazy-loaded via `import_path` to keep package import cheap.

### Upstream harbor changes (already merged, `1ef3ced6`)

- Backported harbor PR [#1482](https://github.com/harbor-framework/harbor/pull/1482):
  codex 0.118.0+ only honors `openai_base_url` from `$CODEX_HOME/config.toml`,
  not the env var; setup_command now appends the config.toml block when
  `OPENAI_BASE_URL` is set. MCP-servers config write switched from `>` to
  `>>` so it composes with the new block.
- Pinned `install-codex.sh.j2` to `@openai/codex@0.117.0` (last version
  whose HTTP Chat Completions fallback works with OpenRouter). Wrapper-side
  `CODEX_VERSION` env var triggers an in-sandbox upgrade after setup for
  flows that don't need OR (e.g. OpenAI direct + ChatGPT OAuth on
  gpt-5.5, which requires ≥0.118.0).

### Empirical scout results on cli-task-46c118

| Setup | reward | wall | cache hit | cost/trial |
|---|---:|---:|---:|---:|
| claude_code + Opus-4.6 (OAuth) | 1.00 | 7.0 min | server-side (Anthropic) | $0 (subscription) |
| codex + gpt-5.5 (OR direct, 0.117.0) | 0.80 | 16-26 min | 90.6% | ~$2.49 (OR pay-per-token) |
| codex + gpt-5.5 (OpenAI direct + ChatGPT OAuth, 0.133.0) | 0.80 | 21 min | 92% | $0 (subscription) |
| claude_code + gpt-5.5 (OR proxy) | 0.80 | 7.8 min | 23.6% (proxy drops `cache_control`) | ~$7.78 (OR pay-per-token) |

Validates the wrapper plumbing end-to-end across all four (model, harness, auth)
combinations; the speed/cost trade-offs above are structural to each
combination, not wrapper bugs.

## v0.7.0 — 2026-05-11

**Per-turn incremental git diff fed to user sim.**

The sim previously saw only the agent's self-narration (`thinking` / `text` /
`result` blocks) plus tool-call signatures (file paths and command prefixes).
Tool results — including Bash stdout, file contents, and the actual code
written by Edit/Write — were dropped by `_parse_stream_json`. The sim had no
independent channel to verify "I added X to Y" claims.

`UserEnabledClaudeCode._capture_git_diff` now:
- Tags the workspace state at the end of every turn (`harbor-turn-<N>`).
- Computes an incremental diff between the prior turn's tag and the
  current HEAD (vs `harbor-base` for turn 0).
- Writes `patches/turn-<N>.incremental.patch` alongside the existing
  cumulative `patches/turn-<N>.patch` (per-turn-replay infrastructure is
  unchanged).
- Stashes the incremental diff on `self._last_turn_diff` so the next
  `_consult_user` call passes it to `UserAgent.process(code_changes_diff=…)`.

`UserAgent._build_turn_summary` renders a new
`## Code changes (this turn)` section as a ```diff``` block when the
diff is non-empty. Not truncated by design — per-turn deltas are
naturally bounded by the agent's single-turn work; the dedup property of
`git diff` collapses redundant Edits on the same lines, so even busy
turns rarely exceed a few KB.

Implementation notes:
- The marker-commit dance (`git add -A && commit --allow-empty &&
  tag -f`) means agent commits get sandwiched between `harbor-turn-<N>`
  commits; the agent's own `git log` will show extra entries. Acceptable
  because the agent rarely inspects `git log` in coding tasks and our
  Dockerfiles pre-commit the workspace state under `harbor-base` already.
- Empty turns produce empty diffs, suppressed in the sim prompt.

## v0.6.0 — 2026-04-07

**Turn quality overhaul: dedup, timing, reasoning, tool_choice.**

Six fixes to the user simulator's turn presentation and decision reliability.

### Turn summary dedup (Fix 1 & 2)

Agent Activity and Terminal Output were byte-for-byte identical — both
called `_snapshot_recent_output()`. Now `_snapshot_latest_turn()` returns
separate `(trajectory, observation)`: trajectory is the full step log,
observation is the last few result/agent lines.

Additionally, Turn N previously re-sent all steps from turns 1..N (O(N²)
growth). Now only sends the latest turn's activity — prior turns are
already in conversation history. Step IDs are globally continuous (no
restart at `[1]` each turn).

Net impact: Turn 2 shrinks from ~54K to ~16K chars (~70% reduction).

### Timing in turn summaries (Fix 3)

`_build_turn_summary()` now includes `**Timing:** Elapsed: 52min, this
turn took 3min` so the LLM can match time-based triggers from session
analysis (e.g., "52min 15s after last assistant message").

### Reasoning preservation in history (Fix 4)

Only `decision.content` (the tool argument) was stored in conversation
history — Gemini's reasoning about *why* it made each decision was
discarded. `format_for_history()` now preserves reasoning + structured
decision, filtering internal prefixes and deduplicating.

### tool_choice=required (Fix 5)

Forces Gemini to always call a tool (`no-op`, `question`, `redirect`,
`new_requirement`, or `check_external`). Eliminates 1,269 text-as-no-op
cases per eval run. Maps to Gemini's `functionCallingConfig.mode = "ANY"`
via LiteLLM. Includes one retry if the provider silently ignores it.

### Smart fallback parser (Fix 6)

Replaces the all-or-nothing `_fallback_parse` (which silently dropped
203 real messages across 10,566 decisions). Now:
- Detects intended no-ops (model said "stayed silent" as text)
- Recovers `→ action: content` format from history leaking
- Recovers short (<500 char) non-reasoning text as redirect messages
- Defaults to no-op only for long reasoning text

Validated against 10,566 historical decisions: **202/203 recovered, 0
false positives**.

**E2E validation (3 tasks, claude-opus-4-6 + gemini-3.1-pro):**

| Task | Reward | Interventions |
|------|--------|---------------|
| banodoco-video-perf-optimize | 0.70 | 8 |
| qwen3-moe-gguf-dequant | 0.81 | 6 |
| comfyui-newbie-lumina-refactor | 0.04 | 1 |

## v0.5.2 — 2026-04-04

**Incremental CC turns + relaxed trigger interpretation.**

Two changes to increase user sim intervention opportunities on Claude Code:

### Incremental work instruction

Appends to the CC agent's instruction: "Work incrementally. After completing
each distinct sub-task, STOP and report what you did. Wait for user feedback
before proceeding." This creates more `--resume` checkpoints where the user
sim can intervene.

### Relaxed trigger interpretation

Injects global guidance into the user sim's system prompt telling it to apply
sim prompt triggers broadly: fire GT messages in sequence even if the exact
intermediate state described in the trigger isn't a perfect match, and check
whether completed work has issues rather than only looking for specific
intermediate states.

**A/B results (CC + Gemini, 3 tasks):**

| Task | GT | v0.5 msgs | v0.5.2 msgs | v0.5 reward | v0.5.2 reward |
|------|-----|-----------|-------------|-------------|---------------|
| sd-scripts | 4 | 3 | 3 | 0.93 | 0.93 |
| sageattention | 6 | 2 | 2 | 0.35 | 0.35 |
| **banodoco** | **27** | **3** | **5** | **0.70** | **0.55** |

Key finding: **banodoco went from 3 to 5 sim messages.** Previous run sent
GT turns 2, 3, 4 (early animation bugs). This run sent GT turns 2, 13, 14,
15, 16 (progressive timeline, speed, labels) — later GT turns that were
previously unreachable because CC completed too much per turn.

All 5 messages are verbatim GT quotes. The incremental instruction created
more checkpoints, and the relaxed triggers let the sim fire later-stage
GT messages that matched completed (not intermediate) work.

sd-scripts and sageattention unchanged — simple enough that the agent
completes the whole task in one sub-task regardless.

## v0.5.1 — 2026-04-04

**Wall-clock timing and GT session duration tracking.**

- Extract original session duration from `original_session.json`
  (`start_time`/`end_time` fields)
- Measure trial wall-clock time via `time.time()`
- Print speedup ratio (gt_duration / trial_time) after each trial
- Write `timing.json` to each trial directory

**Sample output:**
```
  wall_clock : 1222s (20.4m)
  gt_duration: 7279s (121.3m)
  speedup    : 5.96x
```

Speedup ratios observed: 4.4x (sd-scripts), 8.0x (sageattention), 6.0x
(banodoco). Agents are consistently 4–8x faster than real users.

## v0.5 — 2026-04-03

**Three changes to improve user simulation realism and cross-harness fairness.**

### Repo config file injection

All three agent harnesses (Terminus 2, Claude Code, Codex) now discover and
inject repo configuration files (CLAUDE.md, AGENTS.md, `.claude/`, `.ai/`,
`.cursor/`, `.cursorrules`, `.github/copilot-instructions.md`) into the
agent's instruction at the start of `run()`. ~20 of 45 task repos contain
such files. Previously only Claude Code auto-discovered them natively.

New file: `src/user_agent/repo_config.py`

### Structured output for Claude Code user sim

Claude Code's `_snapshot_recent_output()` now parses stream-json into
structured step summaries (`[step_id] thinking: ...`, `tool_call(Bash): ...`,
`agent: ...`) instead of passing raw JSON tail to the user sim. This matches
Terminus 2's trajectory format and is closer to what a real user sees.

Verified: 57,544 chars of raw JSON → 11 structured steps. In A/B testing,
structured output made the user sim more informed and more conservative —
fewer redundant follow-ups, same message quality.

### Soft message guidance (replaces hard cap)

Removed `max_messages` hard cap. Previously, restrictive caps in
`user_simulation_prompt.md` (e.g., "EXACTLY 0–2" when GT=6) suppressed
realistic simulation. Now the runner computes a GT-based guidance range
(`GT*0.5` – `GT*1.5`) and injects it as a soft target into the user sim's
system prompt. The user sim decides based on context, not an enforced ceiling.

**24-experiment comparison** (2 harnesses × 2 user models × 3 tasks, before/after)
documented in `src/user_agent/agent_test_comparison.md`.

Key results from the soft guidance A/B (hard cap → soft guidance):
- **openclaw** (GT=5): 0 msgs across all 4 configs → T2+Opus **3 msgs**, T2+Gemini **1 msg** (reward 0.21→0.86). Previously hard-capped or trigger-blocked; soft guidance let the sim send quality-check messages about AGENTS.md completeness.
- **sd-scripts** (GT=4): CC+Opus 2→**5 msgs** with natural progressive review. CC+Gemini and T2 configs unchanged (already within range).
- **sageattention** (GT=6): T2+Gemini 1→**2 msgs**. CC configs unchanged. Bottleneck is sim prompt trigger design, not cap.
- **openclaw CC harness** still gets 0 msgs — session ID parsing bug prevented resume turns. **Fixed**: `_find_session_id()` now parses from captured stdout (stream-json init event) instead of relying on `_get_session_dir()` which fails with multiple project directories. After fix, session IDs are found reliably but user sim still chooses no-op — CC completes the task in one autonomous turn, so the sim sees a finished result and has nothing to add (vs T2 which gives 10+ mid-task intervention points).

## v0.4.0 — 2026-03-29

**Feature: multi-turn user simulation for Claude Code and Codex**

Added `--agent-type` CLI option to `runner.py` to select the coding agent
backend. All three supported agent types get full user simulation:

- **`terminus`** (default) — `UserEnabledTerminus2`. In-process LLM agent;
  user sim injects messages directly into the chat history mid-loop.
- **`claude-code`** — `UserEnabledClaudeCode`. Runs Claude Code CLI, then
  uses `claude --resume <session_id>` to continue the conversation with
  simulated user messages. Real conversation continuity across turns.
- **`codex`** — `UserEnabledCodex`. Runs `codex exec`, then re-runs with
  accumulated conversation history prepended to the instruction (no native
  resume in Codex CLI).

**Shared user sim parameters** (all three agents):

| Parameter | Default | Source |
|-----------|---------|--------|
| `user_model_name` | `anthropic/claude-opus-4-6` | `--user-model` CLI / `user_model` in config.yaml |
| `user_temperature` | `0.5` | Hardcoded |
| `user_context_chars` | `3000` | `user_context_chars` in config.yaml |
| `max_messages` | GT count + 5 (cap 15) | Extracted from `user_simulation_prompt.md` or defaulted |
| `call_user_on_completion` | `true` | `call_user_on_completion` in config.yaml |

**Agent-specific parameters:**

| Parameter | terminus | claude-code | codex |
|-----------|----------|-------------|-------|
| Max agent turns | `1000000` (Terminus2 default) | `15` (`_MAX_RESUME_TURNS`) | `15` (`_MAX_RESUME_TURNS`) |
| Multi-turn mechanism | In-process chat injection | `claude --resume <session_id>` | Re-run `codex exec` with accumulated context |
| API key env var | Via LiteLLM (any provider) | `ANTHROPIC_API_KEY` | `OPENAI_API_KEY` |
| OpenRouter compatible | Yes (`openrouter/` prefix) | No (Anthropic API format) | Possibly (`OPENAI_BASE_URL`) |

Other Harbor-installed agents (`aider`, `swe-agent`, etc.) fall back to
single-shot mode without user simulation.

New files:
- `src/user_agent/user_enabled_claude_code.py`
- `src/user_agent/user_enabled_codex.py`

Also added `openai` to the provider map for Codex/OpenAI models, and
`agent_type` is configurable via `config.yaml`.

## v0.3.1 — 2026-03-27

**Fix: fallback_parse always returns no-op**

When the LLM responds with plain text instead of a tool call, treat it as
no-op. Previously, raw text was injected as a user message — this caused the
`[silent — no-op]` leak where 6/9 messages on amdgpu were internal markers
sent to the agent.

## v0.3.0 — 2026-03-27

**Major: conversation history + hard message cap**

Inspired by tau-bench/tau2-bench (Sierra Research). Three changes:

1. **Conversation history** — `self._messages` accumulates across turns. The
   LLM sees what it already said. Fixes the 13x repetition bug
   (sd-scripts-skip-resolution-tuple: 65 msgs → expected ~5).

2. **Hard message cap** (`max_messages`) — extracted from user_simulation_prompt.md
   or defaulted to GT count + 5. Enforced before the LLM call — no reliance on
   the LLM reading a Stats line.

3. **Removed `example_phrases` from persona** — these leaked GT messages
   permanently in the system prompt, causing repetition after GT exhaustion.

Also: removed `build_persona_from_analysis()` (analysis.json deprecated),
fixed runner to load `user_simulation_prompt.md` (not `analysis.md`),
softened completion-check nudge.

**A/B test results (10 tasks, pre-fallback-fix):**

| Task | Old | New | Delta |
|------|-----|-----|-------|
| amdgpu-kernel-619-compat (PROBLEM) | 0.0 | 0.56 | +0.56 |
| sd-scripts-skip-resolution-tuple (PROBLEM) | 0.8 | 0.75 | -0.05 |
| sd-scripts-fp8-lumina (PROBLEM) | 0.4 | 0.37 | -0.03 |
| sageattention-headdim-256 | 0.2 | 1.0 | +0.80 |
| nunchaku-awq-quantization | 0.7 | 1.0 | +0.30 |
| openclaw-security-review-flow | 0.6 | 0.75 | +0.15 |
| sd-scripts-dedup-early-exit | 0.85 | 1.0 | +0.15 |
| reigh-timeline-mode-cleanup | 0.5 | 0.6 | +0.10 |
| triton-amd-fp8-lowering | 1.0 | 1.0 | 0 |
| triton-msvc-c4267-warnings | 0.75 | 0.6 | -0.15 |

Average delta: +0.18. Note: sd-scripts-skip-resolution-tuple still had 32
leaked messages due to the fallback bug (fixed in v0.3.1).

## v0.2.0 — 2026-03-25

**Initial: stateless tool-calling simulator**

- Each LLM call is independent (no conversation history)
- Ground-truth messages shown as sliding window in prompt
- Stats line (`"54 calls, 9 messages sent"`) for self-regulation
- `example_phrases` in persona (all GT messages permanently visible)
- No hard message cap — relies on LLM compliance
- Known failure: 13x over-simulation on sd-scripts-skip-resolution-tuple
