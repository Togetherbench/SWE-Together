# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target ≤ 0.10)
- P2P-only weight: 10% (model_registry_p2p 0.05 + extension_runner_p2p 0.05)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: Final user said "push anyway", assistant confirmed "Pushed." with commit hash e0f85a3b. Task completed successfully.

## User-Sim Prompt Audit (Phase 2)
- Before: 8 rows (included Turn 1 = instruction.md), all with generic conditions "agent has produced output related to this turn's context"
- After: 7 rows (Turn 1 removed per rules), all verbatim messages, conditions rewritten with observable agent state checks
- Action: Rebuilt trigger table — removed Turn 1 (implicit instruction), added concrete observable conditions for each trigger

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 7 gates use vitest (TypeScript execution). 0 grep-only tests. |
| test_not_tautological | A | PASS | All F2P gates fail on base (nop=0.10), each tests real behavioral constraint |
| solution_uniqueness_guard | A | PASS | Tests check behavioral outcomes (throws, no crash, no partial state) not specific code patterns |
| no_solution_leakage | A | PASS | instruction.md describes symptom (crash from invalid provider registration). Does not leak the fix. |
| pass_to_pass_coverage | A | PASS | 2 P2P gates: model-registry.test (0.05) + extensions-runner.test (0.05) |
| behavior_in_task_description | A | PASS | All assertions derive from instruction.md requirements (#1-5) |
| no_hidden_solution_artifacts | A | PASS | Dockerfile clones from git, no COPY solution/. `find / -name 'solve*'` returns empty. .dockerignore added. |
| dockerfile_determinism | B | PASS | ubuntu:24.04 (exact tag), bun@1.1.43 (pinned), Node 20.x via nodesource |
| no_network_during_tests | B | PASS | No pip/npm/apt/curl/git in test.sh. All deps baked at build time. |
| pinned_dependencies | B | PASS | No Python pip deps (TypeScript task). bun pinned to 1.1.43. |
| f2p_p2p_classification_correct | B | PASS | All gates labeled [F2P] or [P2P]. Verified against nop and both agents. |

## Changes Made

### task.toml
- Fixed broken TOML syntax (tags field split across lines, mixed with session_resolution)
- Added session_resolution = "resolved" with confidence 0.95 and reasoning

### Dockerfile
- Pinned bun: `bun@latest` → `bun@1.1.43`
- Pre-built dependency packages (ai, agent, tui) to avoid network calls at test time
- Added `.dockerignore` excluding `solution/` and `tests/`

### test.sh (complete rewrite)
- Fixed shebang: `#!/usr/bin/env bash` → `#!/bin/bash`
- Fixed: `set -euo pipefail` → `set +e`
- Removed 3 grep-only tests (violated tests_verify_behavior_not_text)
- Added `add_reward()` helper (lint H3 requirement)
- Added nop baseline doc comment (lint S1)
- Added F2P/P2P labels to all gates
- Added Test 7: refresh() resilience (Sonnet/Haiku discriminator)
- 7 gates total, all behavioral vitest-based

### user_simulation_prompt.md
- Removed Turn 1 (implicit instruction.md)
- Observable conditions on all 7 triggers
- Added persona section
- All messages verified verbatim against original_session.json

## Agent Discrimination (Phase 4+6)
| Round | Sonnet 4.6 | Haiku 4.5 | Gap  |
|-------|-----------|-----------|------|
| 1     | 0.95      | 0.95      | 0.00 |
| final | 0.95      | 0.75      | 0.20 |

### Per-test breakdown (final):
| Test | Type | Weight | Sonnet | Haiku |
|------|------|--------|--------|-------|
| 1. model-registry tests | P2P | 0.05 | PASS | PASS |
| 2. extension-runner tests | P2P | 0.05 | PASS | PASS |
| 3. Core crash fix (streamSimple+refresh) | F2P | 0.20 | PASS | PASS |
| 4. Atomicity (no partial state) | F2P | 0.10 | PASS | PASS |
| 5. Runner integration (bindCore+emitError) | F2P | 0.20 | PASS | PASS |
| 6. Post-bind error handling | F2P | 0.15 | PASS | PASS |
| 7. refresh() resilience | F2P | 0.20 | PASS | FAIL |

Key discriminator: Sonnet wrapped the `refresh()` loop in try/catch, while Haiku left it unprotected. This maps to instruction requirement #3: "Handle errors at every call site where provider registration can fail."

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 15 (7 user sim turns across 15 sim interactions)
- Agent reward in eval: 0.95
- Actions detected: new_requirement, new_requirement, new_requirement, redirect, redirect, redirect, new_requirement
- Notes: Sim highly active. minimax-m2 agent + gemini-3.1-pro sim. 16 min eval time.

## Confidence
- Overall: HIGH
- Nop ≤ 0.10: ✓ (0.10)
- Gap ≥ 0.15: ✓ (0.20)
- All 11 rubrics: PASS
- Remaining concern: Lint S2 warning — linter's behavioral test detection is Python-focused, doesn't recognize vitest
