# Fix Summary

## Nop Baseline
- Nop reward: 0.03 (target <= 0.10)
- P2P-only weight: 3% (Check P2P = 0.03)
- All F2P checks fail at baseline, P2P passes

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: Final user said "yes" to version bump, assistant said "Pushed." — session ended naturally with all work completed

## User-Sim Prompt Audit (Phase 2)
- Before: 0 trigger table rows (narrative only, no formal table)
- After: 2 rows (T2, T3), all verbatim from original session
- Action: REBUILT trigger table with | ID | Condition | Message | Notes | format
- T2 verbatim: "Did you test it in react + python to see how it actually works?"
- T3 verbatim: "And is this now beautifully and elegantly structured?"
- Added HARD CONSTRAINT preventing Turns 4-14 (out-of-scope) from being sent
- Default behavior: SILENCE (matches original session's 122-turn autonomous gap)

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 16+ checks use python3 -c execution gates (~95% behavioral weight) |
| test_not_tautological | A | PASS | Every check has non-trivial assertions; stubs/empty files fail all gates |
| solution_uniqueness_guard | A | PASS | Flexible constructor signatures, accepts _match_pattern or match_pattern, filter_entries or should_skip_finding |
| no_solution_leakage | A | PASS | instruction.md describes the implementation plan (this IS the task — it's a feature implementation, not a bug fix). No hidden patch. |
| pass_to_pass_coverage | A | PASS (ADDED) | Added Check P2P (0.03): tests basic desloppify import, LangConfig import, generate_findings import, CLI --help. Passes at base commit eba4ad1c. |
| behavior_in_task_description | A | PASS | All tested APIs (_match_pattern, FileZoneMap, counts(), adjust_potential, etc.) explicitly specified in instruction.md |
| no_hidden_solution_artifacts | A | PASS | Dockerfile checks out pre-zone commit eba4ad1c. No solution/ directory. `find / -name 'solve*'` returns nothing. |
| dockerfile_determinism | B | PASS | ubuntu:24.04 (exact tag), all pip deps pinned with ==X.Y.Z |
| no_network_during_tests | B | PASS | test.sh uses only local python3 -c imports, no network calls |
| pinned_dependencies | B | PASS | Pillow==10.4.0, setuptools==75.8.0, PyYAML==6.0.2, pytest==8.3.4 |
| f2p_p2p_classification_correct | B | PASS (ADDED) | Added F2P/P2P labels in test.sh header comments; Check P2P explicitly labeled PASS-TO-PASS |

## Changes Made to test.sh
1. **Added P2P regression guard** (Check P2P, weight 0.03): Tests that `import desloppify`, `LangConfig`, `generate_findings`, and `python3 -m desloppify --help` still work after agent changes. Passes on unmodified base commit.
2. **Updated header comments** with tier breakdown including P2P and structural checks 13-16.
3. **Note**: The original audit's concern about `counts()` narrowness (Check 2) was already addressed — `counts()` IS specified in instruction.md lines 78-80. Test was already split into 2a (classification, 0.08) and 2b (counts, 0.04) for partial credit.

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|------------|-----------|-----|
| 1     | 1.00       | 0.58      | 0.42 |

### Sonnet 4.6 (1.00) — all checks pass
- 57 turns, 721s duration
- Perfect implementation: all pattern types, FileZoneMap with overrides, counts(), adjust_potential, should_skip_finding, zone rules, CLI, phase runner integration, narrative awareness

### Haiku 4.5 (0.58) — key failures
- 58 turns, 230s duration
- Failed Check 1 (0.15): dot_pattern (.test.) not handled in _match_pattern
- Failed Checks 2a-5 (0.36): FileZoneMap classification broken — `'str' object has no attribute 'patterns'` error when using COMMON_ZONE_RULES with FileZoneMap (rules defined correctly as ZoneRule objects, but classify method iterates incorrectly)
- Failed Check 10 (0.06): generate_findings missing zone_overrides parameter
- Passed: COMMON_ZONE_RULES content (Check 6), per-language rules (7), CLI zone (8), zone_cmd.py (9), ZONE_POLICIES (11), phase runner integration (12), narrative (13), cmd_zone actions (14), scan.py wiring (15), application depth (16), P2P (P2P)

### Discrimination analysis
The 0.42 gap is genuine and reflects real implementation quality differences:
- Sonnet correctly implemented the `_match_pattern` function including all 6 pattern types (dot patterns, etc.)
- Sonnet's FileZoneMap properly uses ZoneRule.patterns for classification
- Haiku's FileZoneMap had a bug iterating rule patterns (tried `.patterns` on a string)
- Haiku skipped threading `zone_overrides` through `generate_findings`

## Sim-Fire Validation (Phase 7)
- Status: PASSED (sim turns fired, trial timed out before verifier)
- sim_turns_fired: 2
- T2 fired: "Did you test it in react + python to see how it actually works?" (verbatim, episode-1)
- T3 fired: "And is this now beautifully and elegantly structured?" (verbatim, episode-2)
- Episode 3: no-op (correct silence after in-scope turns exhausted)
- Notes: Trial timed out at 1500s (minimax-m2 agent was slow). Verifier didn't run, but sim-fire validation succeeded — both trigger table rows fired correctly with verbatim messages. turn_fire_report.py showed "unknown" status due to timeout, but manual inspection of user_decision.json files confirms 2 sim turns.

## Confidence
- Overall: HIGH
- Discrimination gap 0.42 exceeds target 0.15 significantly
- All 11 rubrics pass
- Nop baseline 0.03 well within 0.10 target
- Remaining concerns:
  - Haiku's 0.58 could vary across runs due to LLM non-determinism
  - The task is complex (6-part implementation) which inherently creates variance
  - The "STOP and wait" instruction in instruction.md could fragment single-turn runs, but both agents completed in single-turn piped mode which avoids this issue
