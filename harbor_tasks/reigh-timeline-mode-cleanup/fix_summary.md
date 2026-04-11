# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5% -- only T5/tsc passes on base commit)
- All F2P tests fail on base: YES

## Agent Results (Round 1 -- original tests)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.68 | ShotImagesEditor.tsx, index.ts, TimelineModeContent.tsx (deleted) | Core refactor only; skipped dead code cleanup section |
| Haiku 4.5 | 0.68 | ShotImagesEditor.tsx, index.ts, TimelineModeContent.tsx (deleted) | Core refactor only; skipped dead code cleanup section |

### Round 1 Analysis
Both models produced virtually identical code. The core refactor (TMC elimination, prop remapping, unpositioned div inlining) was executed flawlessly by both. Neither model attempted the "Dead code cleanup" section at the bottom of the instruction -- both stopped after verifying tsc passed.

Test failures (identical for both):
- T12 (15 pts): hookData + pairPrompts still in Timeline.tsx interface
- T13 (12 pts): enhancedPrompts + EMPTY_ENHANCED_PROMPTS not cleaned from Timeline.tsx/TimelineContainer
- T15 (5 pts): Changes not committed (no commit instruction in single-turn mode)

## Test Refinements

### Changes made to test.sh:
1. **T15 fixed**: Now accepts both committed AND uncommitted changes. Single-turn agents with no "commit" instruction shouldn't be penalized for not committing. Both models get +5.
2. **T11 reduced**: 13 -> 10 pts (still tests unpositioned div inlining)
3. **T12 reduced**: 15 -> 10 pts (dead prop cleanup -- hookData + pairPrompts)
4. **T13 reduced**: 12 -> 8 pts (dead prop cleanup -- enhancedPrompts)
5. **T17 added (6 pts)**: Prop value correctness checks using TypeScript AST. Verifies that renamed props receive the correct VALUE expressions (e.g., `frameSpacing={batchVideoFrames}`, not just that `frameSpacing` exists as a prop name).
6. **T18 added (6 pts)**: Conditional adapter pattern preservation. Checks that `onAddToShot`, `onCreateShot`, `onAddToShotWithoutPosition` retain their `? handleAdapter : undefined` patterns.

### Changes made to Dockerfile:
1. Added non-root `agent` user (required because Claude Code refuses `--dangerously-skip-permissions` as root)
2. Claude Code CLI installed as non-root user

### Point redistribution:
- Original: T1-T16 = 100 pts (T12=15, T13=12, T11=13)
- Final: T1-T18 = 100 pts (T12=10, T13=8, T11=10, T17=6, T18=6)
- Dead code cleanup total: 27 -> 18 pts (still meaningful but not 27% of total)
- Prop value/adapter checks: 0 -> 12 pts (new granularity)

## Agent Results (Final Round -- Round 2)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | ShotImagesEditor.tsx, index.ts, TMC.tsx (deleted), **Timeline.tsx**, **TimelineContainer.tsx**, **types.ts** | Full refactor + dead code cleanup in 43 turns ($1.32) |
| Haiku 4.5 | **0.82** | ShotImagesEditor.tsx, index.ts, TMC.tsx (deleted) | Core refactor only; did not touch Timeline.tsx or TimelineContainer/ in 31 turns ($0.27) |

### Per-test breakdown (Round 2):
| Test | Pts | Sonnet 4.6 | Haiku 4.5 |
|------|-----|-----------|-----------|
| T1: TMC deleted | 2 | PASS | PASS |
| T2: Barrel cleaned | 2 | PASS | PASS |
| T3: No TMC refs | 3 | PASS | PASS |
| T4: JSX structure | 3 | PASS | PASS |
| T5: tsc passes | 5 | PASS | PASS |
| T6: frameSpacing | 6 | PASS | PASS |
| T7: onTimelineChange | 6 | PASS | PASS |
| T8: onSegmentFrameCountChange | 8 | PASS | PASS |
| T9: onClearEnhancedPrompt + onDragStateChange | 7 | PASS | PASS |
| T10: onPairClick + onRegisterTrailingUpdater | 7 | PASS | PASS |
| T11: Unpositioned div | 10 | PASS | PASS |
| T12: hookData + pairPrompts cleanup | 10 | **PASS** | FAIL |
| T13: enhancedPrompts cleanup | 8 | **PASS** | FAIL |
| T14: onOpenSegmentSlot adapter | 3 | PASS | PASS |
| T15: Changes applied | 5 | PASS | PASS |
| T16: allGenerations + shotGenerations | 3 | PASS | PASS |
| T17: Prop value correctness | 6 | PASS | PASS |
| T18: Conditional adapter patterns | 6 | PASS | PASS |
| **Total** | **100** | **100** | **82** |

## Discrimination Analysis
- Score gap: **0.18** (Sonnet 1.00 vs Haiku 0.82)
- Is this meaningful? **YES** -- Sonnet completed the full instruction including the "Dead code cleanup" section, modifying Timeline.tsx and TimelineContainer/ to remove dead props (hookData, pairPrompts, enhancedPrompts, EMPTY_ENHANCED_PROMPTS). Haiku completed only the core refactor and stopped. This reflects a genuine difference in instruction-following thoroughness.
- The gap comes entirely from T12+T13 (18 pts) which test whether the agent reads and executes the final section of a multi-part instruction.
- Confidence: **HIGH** -- The gap is consistent with the expected capability difference. Sonnet took 43 turns and $1.32 to complete the full task; Haiku took 31 turns and $0.27 but stopped after the easier parts. Haiku consistently failed T12/T13 across both rounds (0% success). Sonnet succeeded in Round 2 (50% success over 2 runs).

## Task Health
- Solvable without user sim: **YES** (Sonnet scored 1.00 in single-turn mode)
- Recommended difficulty: **MEDIUM** (core refactor is straightforward; dead code cleanup requires deeper analysis)
- Remaining concerns:
  - Sonnet's dead code cleanup success is not 100% consistent (succeeded in Round 2 but not Round 1)
  - Haiku consistently fails T12/T13 across both rounds
  - The instruction is long; the dead code cleanup section at the end may get deprioritized by weaker models
  - T17/T18 (prop value checks) pass for both models -- the core refactor is too well-specified to differentiate on those alone
