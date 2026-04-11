# Fix Summary

## Nop Baseline
- Nop reward: 0.00 (P2P weight: 0%)
- All F2P tests fail on base: YES (zones.py doesn't exist at base commit eba4ad1c)

## Agent Results (Round 1 -- before test fixes)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.56 | 9 (7 modified + 2 new: zones.py, zone_cmd.py) | Comprehensive implementation: zones.py with all required functions, per-language rules, CLI wiring, plan.py threading. 66 turns, $2.65 |
| Haiku 4.5 | 0.00 | 0 | Got stuck in plan mode (ExitPlanMode denied), never wrote code. Only explored codebase and created a plan. 21 turns, $0.55 |

### Round 1 Issues Identified
- **Sonnet lost 0.44 points** due to root-level path matching: test paths like `tests/test_main.py`, `vendor/lib.py` lack a parent directory, so COMMON_ZONE_RULES patterns like `/tests/`, `/vendor/` (which are substring matches) don't match. All 5 failing checks (2a, 3, 4, 5, 6) shared this root cause.
- **Haiku scored 0.00** because it entered Claude Code's plan mode and never executed code. This is a real model quality issue in Round 1, but was non-deterministic (Round 2 succeeded).

## Test Refinements

### Change 1: Fix test paths to use nested directories (Checks 2a, 2b, 3, 4, 5, 6)
**Why:** Test paths like `tests/test_main.py` and `vendor/lib.py` are root-level relative paths. The COMMON_ZONE_RULES in the instruction use `/tests/`, `/vendor/`, `/generated/` patterns, which are substring matches requiring a `/` before the directory name. Root-level paths don't have this leading `/`, causing all implementations following the instruction literally to fail -- not because they're wrong, but because the test paths don't match real-world nested project structures.

**What changed:**
- `tests/test_main.py` -> `project/tests/test_main.py`
- `tests/test_utils.py` -> `project/tests/test_utils.py`
- `vendor/lib.py` -> `lib/vendor/lib.py`
- `generated/schema.py` -> `build/generated/schema.py`
- Similar updates to `tests/test_a.py`, `vendor/v.py`, `generated/g.py`, `generated/gen.py`
- All references in Checks 2a, 2b, 3, 4, 5, 6 updated consistently

This aligns with how Check 1 already tests `_match_pattern` (e.g., `src/tests/test_foo.py`, `project/vendor/lib.js` -- both nested).

### Change 2: Remove PRODUCTION from ZONE_POLICIES requirement (Check 11)
**Why:** The test required `ZONE_POLICIES.get(Zone.PRODUCTION) is not None`, but PRODUCTION policy is functionally unnecessary -- `should_skip_finding` already returns `False` when the policy is `None`. Both Sonnet and Haiku independently omitted it. The instruction's `should_skip_finding` code snippet shows this graceful handling. Requiring PRODUCTION is overspecification (structural, not behavioral).

**What changed:** Removed the `missing_production` check from Check 11. The check still verifies TEST, GENERATED, and VENDOR zones have proper `skip_detectors`.

## Agent Results (Round 2 -- after test fixes, fresh containers)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 9 (7 modified + 2 new) | Complete, correct implementation. All 12 checks pass. 69 turns, $2.79 |
| Haiku 4.5 | **0.52** | 10 (8 modified + 2 new) | Actually implemented this time (75 turns, $0.83), but with significant bugs |

### Per-check breakdown (Round 2)

| Check | Weight | Description | Sonnet | Haiku | Haiku Failure Reason |
|-------|--------|-------------|--------|-------|---------------------|
| 1 | 0.15 | _match_pattern behavioral | PASS | PASS | -- |
| 2a | 0.08 | FileZoneMap classification + overrides | PASS | **FAIL** | Constructor takes `(zone_rules, base_path: Path)` instead of `(files, rules)` -- none of 3 flexible attempts work |
| 2b | 0.04 | FileZoneMap.counts() | PASS | **FAIL** | Same constructor issue cascades |
| 3 | 0.10 | adjust_potential | PASS | **FAIL** | Can't construct FileZoneMap |
| 4 | 0.10 | should_skip_finding | PASS | **FAIL** | Can't construct FileZoneMap |
| 5 | 0.08 | entry filtering | PASS | **FAIL** | Can't construct FileZoneMap |
| 6 | 0.08 | COMMON_ZONE_RULES content | PASS | **FAIL** | Missing `Zone.TEST` rule in COMMON_ZONE_RULES (only has VENDOR, GENERATED, SCRIPT) |
| 7 | 0.07 | per-language zone rules | PASS | PASS | -- |
| 8 | 0.07 | CLI zone subcommand | PASS | PASS | -- |
| 9 | 0.05 | zone_cmd.py non-stub | PASS | PASS | -- |
| 10 | 0.06 | plan.py + LangConfig | PASS | PASS | -- |
| 11 | 0.05 | ZONE_POLICIES structure | PASS | PASS | -- |
| 12 | 0.07 | phase runner integration | PASS | PASS | -- |

## Discrimination Analysis
- Score gap: **0.48** (Sonnet 1.00 vs Haiku 0.52)
- Is this meaningful? **YES** -- driven by two genuine quality differences:
  1. **FileZoneMap API design (0.38 points lost):** Haiku used `base_path: Path` as the second constructor arg instead of a file list, making the class fundamentally incompatible with the test's flexible constructor attempts. The instruction specifies `FileZoneMap` should accept files + rules + overrides, not a base path. This cascaded across 5 checks (2a, 2b, 3, 4, 5).
  2. **COMMON_ZONE_RULES completeness (0.08 points lost):** Haiku omitted `Zone.TEST` from COMMON_ZONE_RULES despite the instruction explicitly showing `ZoneRule(Zone.TEST, ["/tests/", "/test/", "/fixtures/"])`. This is a direct instruction-following failure.
- Confidence: **HIGH** -- failures are clearly attributable to model quality (API design comprehension, instruction following), not test artifacts

## Task Health
- Solvable without user sim: **YES** (both models implemented the full system in single-turn mode in Round 2)
- Recommended difficulty: **HARD** (multi-file implementation across 9+ files, requires understanding of zone classification design patterns)
- Remaining concerns:
  - Haiku's Round 1 failure (stuck in plan mode) suggests some non-determinism in whether Haiku actually implements vs. only plans. Round 2 succeeded normally with 75 turns.
  - The task is instruction-dense (200 lines of detailed specification). Weaker models may struggle with completeness more than correctness.
  - Both models share the same Check 11 omission pattern (no PRODUCTION in ZONE_POLICIES), confirming the removal was correct since it would penalize both equally without discriminating.
