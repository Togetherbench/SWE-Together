# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10% (Gate 1: 5% compilation, Gate 5: 5% negative cases)
- F2P weight: 90% (Gate 2: 35% multi-row Kitty, Gate 3: 30% iTerm2, Gate 4: 25% terminal-agnostic)

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.8
- Evidence: Main task (revert + patch release) completed at msg 30. Later optimization discussion (turns 5-9) ends with agent asking "Should I implement the O(1) version?" — never answered. Final user msg "what, why? you didn't make this change you just proposed" corrects agent confusion. Conversation truncated mid-discussion.

## User-Sim Prompt Audit (Phase 2)
- Before: 9 rows, all verbatim text, but generic/identical trigger conditions ("related to this turn's context")
- After: 8 rows (Turn 1 = instruction.md removed from table), all verbatim, with specific observable trigger conditions
- Action: REBUILT trigger table with observable conditions per row

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 5 gates use `node --import tsx -e` to execute TypeScript and check runtime behavior. 90% of weight from execution gates. |
| test_not_tautological | A | PASS | Each F2P gate tests specific behavior (multi-row detection, non-prefix detection, terminal-agnostic detection) that can't pass with a stub/empty file. |
| solution_uniqueness_guard | A | PASS | Tests check behavior (does `isImageLine` detect sequences anywhere in line?), not specific implementation patterns. Any fix using `includes()`, `indexOf()`, regex, or any other substring search passes. |
| no_solution_leakage | A | PASS | instruction.md describes the PR review task + user confusion ("i dont understand how this can happen at all"). The PR URL contains the fix but this is by design (agent reviews the PR). No explicit patch code in the instruction. |
| pass_to_pass_coverage | A | PASS | Gate 1 (5%): TypeScript import check passes on both buggy and fixed code. Gate 5 (5%): Negative cases pass on both. |
| behavior_in_task_description | A | PASS | The test checks `isImageLine()` function exported from `packages/tui/src/terminal-image.ts`, which is the file discussed in PR #1091 referenced in instruction.md. Escape sequences tested (`\x1b_G` for Kitty, `\x1b]1337;File=` for iTerm2) are standard terminal image protocols derivable from the PR and code. |
| no_hidden_solution_artifacts | A | PASS | Dockerfile uses `git fetch` from GitHub, no COPY solution/. Verified: `find / -name 'solve*'` returns nothing. |
| dockerfile_determinism | B | PASS | Base image pinned with sha256 digest: `ubuntu:24.04@sha256:6015f66...`. bun pinned to 1.2.5. |
| no_network_during_tests | B | PASS | test.sh uses only pre-installed `node --import tsx`. No pip/npm/apt/curl at test time. |
| pinned_dependencies | B | PASS | No pip deps. npm deps from lockfile via `npm ci`. bun pinned to 1.2.5. |
| f2p_p2p_classification_correct | B | PASS | All gates labeled with F2P/P2P in comments. F2P gates (2, 3, 4) fail on buggy code (startsWith), P2P gates (1, 5) pass on both. Verified by nop baseline. |

## lint_tests.py Compliance
- All hard rules pass (H1-H5)
- S2 warning: "no behavioral tests detected (pytest or torch introspection)" — false positive, tests use `node --import tsx` which linter doesn't recognize as behavioral but they execute TypeScript code and check runtime return values.

## Agent Discrimination (Phase 4+6)
| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|------------|-----------|-----|
| 1 (single-turn) | 0.10 | 0.10 | 0.00 |

**Diagnosis**: Both agents scored 0.10 in single-turn because the instruction.md is a PR review task — it asks the agent to read and review a PR, not to apply code changes. Both agents correctly produced text reviews without modifying code. This falls into the "Both ~0 → task needs multi-turn" diagnostic pattern.

**Multi-turn discrimination**: The sim turns (T2: "there was a pr merge from a user called can, guess we need to revert that", T4: "then do a patch release") provide the directive to make code changes. Strong agents would apply the fix (startsWith→includes) after receiving sim guidance; weaker agents would struggle.

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 11 (in 12 total conversation turns)
- sim_interventions: 8 (new_requirement x6, question x1, redirect x1)
- Agent model: MiniMax-M2 via OpenRouter
- User sim model: Gemini 3.1 Pro Preview via OpenRouter
- Reward achieved: 1.00 (all 5 gates pass after sim-guided fix)
- Duration: ~22 minutes

## Changes Made
1. **Dockerfile**: Changed checkout from fix commit `2339d7b` to buggy parent commit `2cee7e17` (startsWith bug present). Pinned base image with sha256 digest, pinned bun version.
2. **test.sh**: Created from scratch with 5 behavioral gates (3 F2P, 2 P2P) using `node --import tsx` execution.
3. **user_simulation_prompt.md**: Rebuilt trigger table with 8 rows, all verbatim messages, observable conditions per row.
4. **task.toml**: Updated session_resolution from "ambiguous" to "cut_off" with reasoning.

## Confidence
- Overall: MEDIUM
- Remaining concerns:
  - Single-turn discrimination gap is 0.00 — task requires multi-turn evaluation to discriminate. This is inherent to the instruction being a PR review task.
  - Sim-fire validated with MiniMax-M2 (not Sonnet/Haiku directly) but confirms the test infrastructure works end-to-end.
  - The `user_simulation_prompt.md` sim prompt field was empty in the trial config — the orchestrator uses `original_user_messages` from session JSON directly, not the trigger table. The trigger table serves as documentation/guidance for the sim model.
