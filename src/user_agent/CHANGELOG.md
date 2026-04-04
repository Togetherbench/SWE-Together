# User Simulator Changelog

Each version is tagged in the code via `UserAgent.VERSION`. Trial logs record
which version produced them so results are always traceable.

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
