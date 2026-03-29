# User Simulator Changelog

Each version is tagged in the code via `UserAgent.VERSION`. Trial logs record
which version produced them so results are always traceable.

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
