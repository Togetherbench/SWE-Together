# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10%

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: User said "ok, comimt and push the fix"; agent committed (92fdb53c) and pushed to main. Session ended cleanly with agent reporting success.
- Fix: Corrected broken TOML syntax in task.toml (malformed `tags` field spanning multiple lines, missing quotes).

## User-Sim Prompt Audit (Phase 2)
- Before: 7 rows, all verbatim messages but vague trigger conditions ("agent has produced output related to this turn's context")
- After: 6 trigger rows (T2–T7; T1 = instruction.md), all verbatim messages preserved
- Action: REBUILT trigger conditions with observable, specific state checks (e.g., "Agent has renamed command from quit to shutdown", "Agent has modified shutdown-command.ts handler but NOT modified interactive-mode.ts")
- Messages remain verbatim from original_session.json

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | Uses `npx tsgo --noEmit` (compilation), `node -e` with mock execution (behavioral), `npm run build` (build integration). 90% weight from execution gates. |
| test_not_tautological | A | PASS | All F2P gates fail on base (nop=0.10). Gates test real behavior: handler execution with mocks, Proxy-based property access tracking, compiled output verification. |
| solution_uniqueness_guard | A | PASS | Verified: alternative fix without `void` keyword scores 1.00. Tests check behavior (shutdown called when idle) not specific syntax. |
| no_solution_leakage | A | PASS | instruction.md only asks about extension examples — does not reveal the shutdownHandler bug or fix. |
| pass_to_pass_coverage | A | PASS | P2P Gate 1 (tsgo --noEmit) passes on unmodified base and on correct fix (0.10 weight). |
| behavior_in_task_description | A | PASS | File paths tested (interactive-mode.ts, shutdown-command.ts) are derivable from instruction.md's reference to extensions/ directory and from user sim messages. |
| no_hidden_solution_artifacts | A | PASS | No solution/ directory. `find / -name 'solve*'` returns nothing. Dockerfile does not COPY solution/. |
| dockerfile_determinism | B | PASS | Base image pinned (ubuntu:24.04), bun pinned (1.2.5), Node from nodesource setup_20.x (major version pinned). |
| no_network_during_tests | B | PASS | test.sh uses only local tools (npx tsgo, node -e, npm run build). No pip/npm install/apt/curl/wget at test time. All deps baked into image. |
| pinned_dependencies | B | PASS | No pip deps. npm deps locked via package-lock.json (npm ci). bun pinned to 1.2.5. |
| f2p_p2p_classification_correct | B | PASS | Each gate labeled with F2P/P2P in comments. P2P Gate 1 verified to pass at base. F2P Gates 2-4 verified to fail at base. |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| 1 (single-turn) | 0.10 | 0.10 | 0.00 | Both correctly answered info question without code changes |

**Diagnosis**: This is fundamentally a multi-turn task. The initial instruction ("check @packages/coding-agent/examples/extensions/ name me a simple example that registers a simple slash command") is an information/exploration request. Neither agent makes code changes in single-turn mode — both correctly answer the question. The bugfix (modifying shutdownHandler in interactive-mode.ts) only emerges through the multi-turn conversation where the user reports the /quit conflict, renaming to /shutdown, TUI garbling, and redirects to fix in core agent code.

**Multi-turn discrimination**: In multi-turn (with user sim), the task requires the agent to:
1. Understand the shutdown-command.ts extension and its conflict
2. Rename the command from "quit" to "shutdown"
3. Realize `ctx.shutdown()` doesn't actually trigger clean TUI shutdown
4. Understand the user's redirect to fix in core agent code (not extension)
5. Find and modify the shutdownHandler in interactive-mode.ts
6. Add conditional immediate shutdown when session is idle

This multi-step debugging chain, requiring code navigation across ~4000-line interactive-mode.ts and understanding of async shutdown semantics, should discriminate strongly between models.

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 8
- Agent model (sim-fire): minimax-m2 via Claude Code
- User sim model: gemini-3.1-pro-preview
- Agent score: 0.10 (couldn't fix the bug — only P2P passed)
- All 5 user follow-up turns were delivered by the sim
- Verifier correctly scored the result

## Gold Fix Verification
- Gold fix applied: `shutdownHandler` in interactive-mode.ts line 1069 — added `if (!this.session.isStreaming) { void this.shutdown(); }` after setting `this.shutdownRequested = true`
- Gold fix score: 1.00 (all 4 gates pass)
- Alternative fix score: 1.00 (same fix without `void` keyword — solution_uniqueness_guard verified)

## Confidence
- Overall: MEDIUM
- Remaining concerns:
  - Single-turn discrimination gap is 0.00 (both score 0.10) because this is inherently a multi-turn task
  - Multi-turn sim-fire validation passed (8 turns fired), and weaker model (minimax-m2) scored 0.10, confirming the task discriminates by capability
  - Full Sonnet vs Haiku multi-turn comparison not performed (would require running both through the full Harbor pipeline with user sim)
  - Recommend running full multi-turn eval with Sonnet vs Haiku to confirm gap >= 0.15 in that setting
