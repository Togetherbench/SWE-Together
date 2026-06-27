# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target ≤ 0.10)
- P2P-only weight: 10% (Gate 1: tsgo compilation)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.90
- Evidence: Final user message "ok, docs are in order?" followed by assistant updating packages/tui/README.md and packages/coding-agent/README.md with new EditorOptions and getter/setter docs. Session ended naturally.

## User-Sim Prompt Audit (Phase 2)
- Before: 11 rows, all had generic triggers ("Intervene IF agent has produced output related to this turn's context")
- After: 10 rows (T2-T11), all verbatim messages from original_session.json, with specific observable conditions
- Action: REBUILT trigger table — replaced generic conditions with specific observable state checks (e.g., "agent has produced a PR review", "agent has modified a file to change default padding to 0")

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 5 gates use execution: tsgo --noEmit, bun run. 100% weight from compilation/execution. |
| test_not_tautological | A | PASS | All F2P gates fail on base (nop=0.10). Stub/empty files won't satisfy bun runtime checks. |
| solution_uniqueness_guard | A | PASS | Gate 2 accepts getPaddingX/setPaddingX, getPadding/setPadding, get/set accessors, and other naming. Gate 4 accepts editorPaddingX, editorPadding, editor_padding variants. |
| no_solution_leakage | A | PASS | instruction.md is a PR review task — no mention of paddingX, setter/getter, or specific fix. Coding instructions come from multi-turn sim. |
| pass_to_pass_coverage | A | PASS | Gate 1 (tsgo --noEmit) passes on base commit AND after correct fix. |
| behavior_in_task_description | A | PASS | Tests check for padding getter/setter, requestRender trigger, settings integration — all derivable from sim turn messages. |
| no_hidden_solution_artifacts | A | PASS | Verified: `find / -name 'solve*'` returns nothing. No solution/ directory in image. |
| dockerfile_determinism | B | PASS | ubuntu:24.04 pinned by SHA256 digest, bun pinned at 1.3.13. |
| no_network_during_tests | B | PASS | test.sh only runs tsgo and bun locally. No pip/npm/apt/curl/git at test time. |
| pinned_dependencies | B | PASS | npm deps managed by lockfile (npm ci), bun pinned at 1.3.13. No pip deps. |
| f2p_p2p_classification_correct | B | PASS | Each gate labeled in test.sh comments. Gate 1 = P2P, Gates 2-5 = F2P. All F2P gates verified to fail on base. |

## Agent Discrimination (Phase 4+6)

Testing used a condensed multi-turn prompt (simulating sim turns T4-T9 in a single message) since the actual instruction.md is a PR review that doesn't produce code changes single-turn.

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| R1 (instruction.md only) | 0.10 | 0.10 | 0.00 | Both only did PR review, no code changes |
| R2 (explicit combined prompt) | 1.00 | 1.00 | 0.00 | Too explicit — told exact files |
| R3 (realistic combined prompt) | 1.00 | 0.55 | 0.45 | Good discrimination |

### R3 Discrimination Analysis
- **Sonnet** (1.00): Implemented getter/setter accessors on Editor, setter calls requestRender, added EditorOptions interface, wired up editorPaddingX setting, render() uses paddingX. 102 turns, $2.83.
- **Haiku** (0.55): Used setPadding/getPadding (naming accepted by broadened tests), BUT setter does NOT call requestRender (Gate 3 fail), and did NOT add editorPaddingX as a configurable setting (Gate 4 fail). 54 turns, $0.53.
- Haiku's failures are legitimate: requestRender was explicitly requested by the user, and making it a setting was a direct user instruction.

## Sim-Fire Validation (Phase 7)
- Status: PARTIAL — trial timed out but sim turns fired
- sim_turns_fired: 3 (T2: "ok, merge via gh cli ...", T3: "pull from origin so i can test it", T4: "ok, i hate the default padding...")
- Trial was terminated by timeout (1500s) during T4 processing
- Evidence: 4 episodes created (episode-1 through episode-4), command files show verbatim user messages being sent via `claude --resume`
- The turn_fire_report.py showed 0 because it couldn't parse the truncated trial, but manual inspection confirms 3+ sim turns fired
- Notes: The full multi-turn evaluation (all 10 sim turns) would need more than 25 minutes. Task timeout may need increase for full evaluation.

## Files Changed
- `task.toml` — Fixed malformed TOML, added session_resolution fields
- `user_simulation_prompt.md` — Rebuilt trigger table with verbatim messages and specific observable conditions
- `environment/Dockerfile` — Pinned ubuntu:24.04 by SHA256 digest, pinned bun@1.3.13 (was @latest)
- `tests/test.sh` — Created from scratch with 5 behavioral gates

## Confidence
- Overall: HIGH
- Remaining concerns:
  - Sim-fire timed out before completing all turns — full multi-turn evaluation needs longer timeout
  - Single-turn instruction.md (PR review) produces no code changes — discrimination requires multi-turn sim
  - The `allow_internet = true` setting is needed for PR review but adds nondeterminism from GitHub API
