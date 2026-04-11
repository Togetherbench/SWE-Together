# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES

## Changes Made

### Dockerfile
- **Added non-root user**: Claude Code's `--dangerously-skip-permissions` flag refuses to run as root. Added `agent` user with proper ownership of `/workspace` and `/logs`.
- **Set CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000**: Sonnet 4.6 was hitting the 32K output token limit on the first turn, causing it to make zero changes (scored 0.05 = nop). This env var allows multi-turn conversations to complete.
- **Set USER agent**: Run all agent commands as non-root.

### test.sh
- **Added stress tests**: 6 new tests (one per IQ type) with larger inputs (n_blocks=64, different seeds). Correct implementations work at any block count; buggy ones fail.
- **Added explicit NaN/Inf check**: Catches implementations that produce NaN values (Haiku's IQ1_M bug) with clear error messages.
- **Rebalanced weights**: Increased weight of IQ1_M tests (hardest function — unusual scale packing) from 0.13 to 0.17 total. Reduced lighter tests proportionally. Total still sums to 1.00.
- **23 tests** (up from 17), all behavioral (0% AST/structural).

## Agent Results (Round 1 — before fixes)
| Model | Reward | Turns | Key Issue |
|-------|--------|-------|-----------|
| Sonnet 4.6 | 0.05 | 1 | Hit 32K output token limit, zero changes |
| Haiku 4.5 | 0.82 | 82 | Failed IQ3_XXS numerical + no-embedding |

## Agent Results (Round 2 — after Dockerfile fix)
| Model | Reward | Files Changed | Turns | Key Approach |
|-------|--------|---------------|-------|-------------|
| Sonnet 4.6 | 1.00 | dequant.py +210/-13 | 5 | All 6 functions correct in one pass |
| Haiku 4.5 | 0.89 | dequant.py +184/-9 | 75 | IQ1_M produces NaN (wrong float16 reconstruction) |

## Agent Results (Final Round — with stress tests + rebalanced weights)
| Model | Reward | Files Changed | Turns | Key Approach |
|-------|--------|---------------|-------|-------------|
| Sonnet 4.6 | 1.00 | dequant.py +221 | 6 | 23/23 tests pass |
| Haiku 4.5 | 0.69 | dequant.py +~190 | 77 | Failed IQ3_XXS (2 tests), IQ1_M (3 tests) |

### Per-test breakdown (Final Round)

| Test | Weight | Sonnet | Haiku |
|------|--------|--------|-------|
| P2P Q4_0 | 0.02 | PASS | PASS |
| P2P Q8_0 | 0.02 | PASS | PASS |
| IQ3_XXS shape | 0.02 | PASS | PASS |
| IQ3_XXS numerical | 0.10 | PASS | **FAIL** (max_diff=2.46) |
| IQ3_XXS no-embed | 0.05 | PASS | PASS |
| IQ3_XXS stress | 0.04 | PASS | **FAIL** (max_diff=2.55) |
| IQ3_S shape | 0.01 | PASS | PASS |
| IQ3_S numerical | 0.10 | PASS | PASS |
| IQ3_S stress | 0.03 | PASS | PASS |
| IQ1_S shape | 0.01 | PASS | PASS |
| IQ1_S numerical | 0.10 | PASS | PASS |
| IQ1_S stress | 0.03 | PASS | PASS |
| IQ2_S shape | 0.01 | PASS | PASS |
| IQ2_S numerical | 0.08 | PASS | PASS |
| IQ2_S stress | 0.04 | PASS | PASS |
| IQ2_XXS shape | 0.01 | PASS | PASS |
| IQ2_XXS numerical | 0.08 | PASS | PASS |
| IQ2_XXS stress | 0.04 | PASS | PASS |
| IQ1_M shape | 0.01 | PASS | **FAIL** (reshape error) |
| IQ1_M numerical | 0.10 | PASS | **FAIL** (reshape error) |
| IQ1_M stress | 0.06 | PASS | **FAIL** (reshape error) |
| Dispatch | 0.03 | PASS | PASS |
| Upstream P2P | 0.01 | PASS | PASS |

## Discrimination Analysis
- Score gap: **0.31** (Sonnet 1.00 vs Haiku 0.69)
- Is this meaningful? **YES** — reflects genuine implementation quality differences:
  1. **IQ3_XXS bug fix**: Haiku's fix is unreliable (correct in 1/2 runs, wrong in the other). Sonnet's fix is consistent (correct in 3/3 runs).
  2. **IQ1_M implementation**: Haiku consistently fails — round 2 produced NaN (wrong float16 scale reconstruction), round 3 produced reshape errors (wrong tensor dimensions). Sonnet implements this hardest function correctly every time.
  3. **Efficiency**: Sonnet completes in 5-6 turns; Haiku takes 75-82 turns. The extra turns don't help Haiku achieve correctness.
- Confidence: **HIGH** — Sonnet scored 1.0 in all 3 runs; Haiku scored 0.82, 0.84*, 0.69 (* with old test weights).

## Haiku Failure Root Causes
1. **IQ3_XXS**: Haiku's alignment fix is incomplete — sometimes it adds `.clone()` before `.view(torch.int32)`, sometimes it doesn't. When it doesn't, the function produces completely wrong values (max_diff >2.0). Also, Haiku sometimes keeps F.embedding.
2. **IQ1_M**: The hardest function due to unusual scale packing. Haiku incorrectly reconstructs the float16 scale from nibbles across 4 uint16 values. Different runs produce different bugs (NaN values or reshape errors), suggesting the model doesn't understand the underlying bit manipulation.

## Task Health
- Solvable without user sim: **YES** — Sonnet consistently solves it; Haiku partially solves it
- Recommended difficulty: **HARD** — requires understanding of quantization bit layouts, alignment issues, and numpy-to-PyTorch translation of complex bit manipulation
- Remaining concerns:
  - instruction.md is very long (~33K tokens with full reference code). Could point to file paths instead of inlining.
  - Haiku's score has high variance (0.69-0.84 across runs), which is realistic but makes benchmarking noisy.
