# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10% (Gate 0: tsc 5%, Gate 1: same-model 5%)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: Final user message U23 was "yes, ready to commit" confirming task completion and satisfaction

## User-Sim Prompt Audit (Phase 2)
- Before: 24 rows, all verbatim but with generic conditions ("Intervene IF agent has produced output related to this turn's context")
- After: 22 substantive rows (dropped T13 file-path-only message), all verbatim, with specific observable state conditions
- Action: REBUILT trigger conditions — replaced generic intent-based conditions with observable state checks (file modifications, diff patterns, agent behavior)

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 6 gates are execution-based: tsc compilation + 5 bun tests importing and invoking convertMessages |
| test_not_tautological | A | PASS | F2P gates fail on unmodified base code (verified: orphaned fc_ IDs, orphaned reasoning) |
| solution_uniqueness_guard | A | PASS | Tests check behavioral outcome (no orphaned fc_ IDs), accept: id=undefined, non-fc_ id, paired reasoning, or function_call→message conversion |
| no_solution_leakage | A | PASS | instruction.md describes symptom and general fix direction but not exact code patch |
| pass_to_pass_coverage | A | PASS | 2 P2P gates: Gate 0 (tsc compilation), Gate 1 (same-model reasoning+function_call preservation) |
| behavior_in_task_description | A | PASS | All test assertions derivable from instruction: cross-model handoff, strict pairing, convertMessages function, openai-responses.ts |
| no_hidden_solution_artifacts | A | PASS | No solution/ directory, no solve* files in Docker image |
| dockerfile_determinism | B | PASS | ubuntu:24.04 (specific tag), bun@1.2.5 (pinned, was @latest), npm ci with lockfile |
| no_network_during_tests | B | PASS | test.sh uses only bun (pre-installed) and tsc (pre-installed via npm ci); no pip/npm/apt/curl at test time |
| pinned_dependencies | B | PASS | N/A for pip (TypeScript task); npm deps pinned via package-lock.json (npm ci) |
| f2p_p2p_classification_correct | B | PASS | All gates labeled with [F2P] or [P2P] in comments; F2P gates verified fail on base, P2P verified pass on both |

## Agent Discrimination (Phase 4+6)
| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| 1 (5 gates) | 0.75 | 0.75 | 0.00 | Both fixed same-provider cross-model via transform-messages.ts isSameProviderAndApi |
| final (6 gates) | 0.85 | 0.65 | 0.20 | Added Gate 5 (orphaned reasoning). Sonnet added shouldReplayReasoning guard; Haiku did not |

### Detailed gate breakdown:
| Gate | Weight | Type | Sonnet | Haiku | Description |
|------|--------|------|--------|-------|-------------|
| G0: tsc | 0.05 | P2P | PASS | PASS | TypeScript compilation |
| G1: same-model | 0.05 | P2P | PASS | PASS | Same-model reasoning+fc preserved |
| G2: cross-model | 0.35 | F2P | PASS | PASS | Cross-model same-provider fc handling |
| G3: cross-provider | 0.15 | F2P | FAIL | FAIL | Cross-provider fc handling (neither handled) |
| G4: differential | 0.20 | F2P | PASS | PASS | fc ID differs between same/cross model |
| G5: orphan reasoning | 0.20 | F2P | PASS | FAIL | Reasoning without following content prevented |

### Fix approaches:
- **Haiku**: Modified only `transform-messages.ts` — changed `isSameModel` to `isSameProviderAndApi` for thinking signature preservation. Partial fix: handles same-provider cross-model but not cross-provider.
- **Sonnet**: Modified both files — same `isSameProviderAndApi` change in transform-messages.ts PLUS added `shouldReplayReasoning` guard in convertMessages to prevent orphaned reasoning items. More comprehensive fix.

## Sim-Fire Validation (Phase 7)
- Status: PASSED (5 sim turns fired)
- sim_turns_fired: 5 (manually verified from episode directories)
- turn_fire_report.py status: "unknown" (eval timed out before completion, but episodes confirmed)
- Episodes fired:
  1. T2 (redirect): thinkingSignature/abort scenario
  2. T3 (question): about the other PR
  3. T4 (new_requirement): extend reasoning replay test
  4. T5 (new_requirement): commit test and discuss fix
  5. T6 (new_requirement): add orphaned toolResult test
- All messages were verbatim from original_session.json

## Changes Made
1. **task.toml**: Fixed broken TOML formatting (tags field), added session_resolution with reasoning
2. **user_simulation_prompt.md**: Rebuilt trigger table with observable state conditions (was generic intent-based)
3. **tests/test.sh**: Complete rewrite from grep-based to behavioral execution tests using bun + convertMessages import
4. **environment/Dockerfile**: Pinned bun version (1.2.5, was @latest), added /tests directory creation

## Confidence
- Overall: HIGH
- Remaining concerns:
  - Gate 3 (cross-provider) neither model handles — this may indicate the instruction doesn't sufficiently prompt for this scenario (it focuses on "same provider different model")
  - Sim-fire eval timed out before verifier ran — the report script shows -1 turns, but manual inspection confirms 5 episodes
  - ubuntu:24.04 could be pinned to a digest for stricter determinism
