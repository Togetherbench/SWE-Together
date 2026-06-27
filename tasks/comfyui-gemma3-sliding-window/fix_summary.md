# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target ≤ 0.10)
- P2P-only weight: 10% (Tests 1 + 8)

## Session Resolution (Phase 1)
- Tag: ambiguous
- Confidence: 0.6
- Evidence: Assistant completed sliding window size change to 1024 and asked "Is there anything else you would like to verify or implement?" — no user response followed. Work appears done but no explicit acknowledgment.

## User-Sim Prompt Audit (Phase 2)
- Before: 4 rows (including Turn 1 which is instruction), generic sim triggers
- After: 3 trigger rows (T2-T4), all verbatim from original_session.json
- Action: REBUILT — removed Turn 1 (instruction.md implicit), rewrote trigger conditions to be observable/behavioral, verified message text is verbatim

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 90% weight from execution gates (exec + instantiation + forward pass). Only Test 4 (10%) is text-based. |
| test_not_tautological | A | PASS | Each F2P gate requires specific config values, correct layer attributes, working mask, and proper rope assignment. Empty/stub implementations fail. |
| solution_uniqueness_guard | A | PASS | Tests check behavioral outcomes (config pattern, layer attributes, mask values, rope selection). Accept any implementation approach. |
| no_solution_leakage | A | PASS | instruction.md shows existing buggy code + reference facts. Does not reveal exact patch. |
| pass_to_pass_coverage | A | PASS | Test 1 (syntax compile) and Test 8 (class structure) are P2P. |
| behavior_in_task_description | A | PASS | All test assertions (window=1024, pattern=6, sliding_window_pattern, rope theta) derivable from instruction.md reference facts. |
| no_hidden_solution_artifacts | A | PASS | No solution/ in Dockerfile. Container has no solve* files. |
| dockerfile_determinism | B | PARTIAL | Base image pinned to python:3.12.13-slim. Git commit pinned. pip deps installed via `pip install -e .` which resolves from PyPI at build time — not version-pinned. |
| no_network_during_tests | B | PASS | test.sh has no network calls. All deps baked at build time. |
| pinned_dependencies | B | PARTIAL | ComfyUI deps installed from setup.py without version pins. Pinning all transitive deps would require freezing ~100+ packages. |
| f2p_p2p_classification_correct | B | PASS | All tests labeled F2P/P2P in comments. F2P tests verified to fail on base. P2P tests pass on both base and gold. |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|-----------|-----------|-----|
| 1 (6 tests) | 1.00 | 1.00 | 0.00 |
| 2 (8 tests) | 1.00 | 0.70 | 0.30 |

### Discrimination Analysis
- Sonnet correctly: fixed config, swapped rope frequencies, implemented sliding window mask, left global layers unmodified
- Haiku correctly: fixed config, implemented sliding window mask
- Haiku bugs: (1) Did NOT swap rope frequency assignment (sliding still uses global freqs_cis[1]), (2) Applied sliding window mask to global layers via `isinstance(False, int)==True` causing `_create_sliding_window_mask(seq_len, False)` which crashes with bool tensor subtraction error
- Tests 6 (global layer) and 7 (rope frequency) catch these real behavioral bugs

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 3 (message-bearing episodes: T2 "softcap", T3 "config.json", plus sim-generated correction)
- Total episodes: 7 (3 with messages, 4 no-ops)
- Final reward: 0.80
- Notes: minimax-m2 agent with gemini-3.1-pro user sim. Sim correctly fired verbatim T2 and T3 messages.

## Changes Made
1. **test.sh**: Complete rewrite
   - Changed `set -euo pipefail` to `set +e`
   - Replaced 7 AST/grep pattern-matching tests with 8 behavioral execution tests
   - Added P2P regression guards (Tests 1, 8)
   - Added forward pass behavioral tests (Tests 5, 6, 7) using exec + mock approach
   - Added F2P/P2P labels to all tests
   - Weights sum to 1.00 with P2P at 0.10

2. **Dockerfile**: Pinned base image from `python:3.12-slim` to `python:3.12.13-slim`

3. **task.toml**: Updated session_resolution from "resolved" (0.7) to "ambiguous" (0.6) with reasoning

4. **user_simulation_prompt.md**: Rebuilt trigger table with verbatim messages, observable conditions, removed Turn 1 (implicit instruction)

## Confidence
- Overall: HIGH
- Remaining concerns:
  - pip dependencies not fully version-pinned (Tier B partial)
  - Sim-fire validation pending completion
