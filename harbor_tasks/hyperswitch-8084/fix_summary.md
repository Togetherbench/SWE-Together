# Fix Summary

## Nop Baseline
- Nop reward: 0.00 (P2P weight: 0%)
- All F2P tests fail on base: YES (all 10 tests fail on unmodified code)

## Agent Results (Round 1 = Final)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 1.00 | routing.rs (10 ins, 146 del) | Removed all 26 cfg(not(release))/cfg(release) pairs, kept auth::auth_type() calls. 12 turns, ~245s |
| Haiku 4.5 | 0.00 | (none) | Created a correct plan identifying all 26 pairs and the right fix, but asked "Ready to proceed?" without implementing. 11-12 turns, ~70-110s |

## Haiku Re-run (verification)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Haiku 4.5 (run 2) | 0.00 | (none) | Same behavior: planned correctly, asked for confirmation, never implemented |

## Test Design
- **10 tests total**, all F2P (fail on base, pass after fix)
- Tests 1-4: Tiered thresholds for `#[cfg(not(feature = "release"))]` removal (<=23, <=15, <=7, <=2 remaining)
- Test 5: All cfg(not(release)) removed AND auth::auth_type() preserved (>=30 calls)
- Tests 6-9: Tiered thresholds for `#[cfg(feature = "release")]` removal (<=23, <=15, <=7, <=2 remaining)
- Test 10: All cfg(release) removed AND auth::auth_type() preserved (>=30 calls)

### Per-test pass/fail breakdown
| Test | Sonnet 4.6 | Haiku 4.5 |
|------|-----------|-----------|
| cfg(not(release)) <= 23 | PASS | FAIL |
| cfg(not(release)) <= 15 | PASS | FAIL |
| cfg(not(release)) <= 7 | PASS | FAIL |
| cfg(not(release)) <= 2 | PASS | FAIL |
| All cfg(not(release)) removed + auth preserved | PASS | FAIL |
| cfg(release) <= 23 | PASS | FAIL |
| cfg(release) <= 15 | PASS | FAIL |
| cfg(release) <= 7 | PASS | FAIL |
| cfg(release) <= 2 | PASS | FAIL |
| All cfg(release) removed + auth preserved | PASS | FAIL |

## Test Refinements
- Fixed `grep -c` exit code handling (returns 1 when count=0, causing fallback to fire)
- Switched from `bc` to `awk` for score calculation (bc not available in container)
- Added non-root user to Dockerfile (Claude Code refuses --dangerously-skip-permissions as root)
- Verifier runs as `--user root` to write to mounted `/logs/verifier`

## Discrimination Analysis
- Score gap: 1.00 (Sonnet: 1.00 vs Haiku: 0.00)
- Is this meaningful? **YES** - reflects genuine behavioral difference in agentic capability:
  - Sonnet correctly identifies the pattern and implements all 26 changes autonomously in a single turn
  - Haiku correctly analyzes the problem and creates a plan, but enters "plan mode" and asks for user confirmation before implementing, which never comes in single-turn piped execution
  - This is consistent across 2 independent Haiku runs
  - Both models understood the task correctly; the difference is in execution follow-through
- Confidence: **HIGH** (consistent across runs, clear behavioral difference)

## Task Health
- Solvable without user sim: YES (Sonnet solves it perfectly in single turn)
- Recommended difficulty: MEDIUM (requires understanding cfg feature flags and making 26 consistent edits to one file)
- Remaining concerns:
  - Haiku's 0 score is due to planning-without-implementing behavior, not inability to understand the task
  - A multi-turn setup with user confirmation might allow Haiku to also complete the task
  - The tiered test structure would provide partial credit if a model implemented some but not all changes
