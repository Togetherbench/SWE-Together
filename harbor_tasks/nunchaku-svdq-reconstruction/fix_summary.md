# Fix Summary: nunchaku-svdq-reconstruction

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES (only P2P1-P2P3 pass on buggy baseline)

## Agent Results (Round 1 / Final)
| Model | Reward | Turns | Duration | Files Changed | Key Approach |
|-------|--------|-------|----------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 41 | ~21 min | reconstruct_weight.py (105 ins, 47 del) | Correctly reverse-engineered all 3 packing permutations (qweight, scale, lowrank), derived inverse permutes, proper reconstruction formula |
| Haiku 4.5 | **0.05** | 78 | ~11 min | reconstruct_weight.py (29 ins, 21 del) | Failed to add scale/lowrank unpack functions, wrong qweight inverse permute, wrong reconstruction formula |

## Per-Test Breakdown

| Test | Weight | Sonnet 4.6 | Haiku 4.5 |
|------|--------|------------|-----------|
| P2P1-P2P3 (sanity) | 0.05 | 3/3 PASS | 3/3 PASS |
| S1-S3 (structural) | 0.06 | 3/3 PASS | 0/3 FAIL |
| Q1-Q3 (qweight unpack) | 0.12 | 3/3 PASS | 0/3 FAIL |
| SC1-SC3 (scale unpack) | 0.06 | 3/3 PASS | 0/3 FAIL |
| QS1-QS3 (qw+scale integration) | 0.12 | 3/3 PASS | 0/3 FAIL |
| LR1-LR8 (lowrank unpack) | 0.32 | 7/8 PASS | 0/8 FAIL |
| R1-R6 (full reconstruction) | 0.18 | 6/6 PASS | 0/6 FAIL |
| TT (tight threshold) | 0.05 | 1/1 PASS | 0/1 FAIL |
| F1-F3 (fresh synthetic) | 0.18 | 3/3 PASS | 0/3 FAIL |

## Test Refinements
No changes were made to test.sh. The existing test design already provides excellent discrimination:

### Current Weight Distribution (total: 1.14, capped at 1.0)
| Tier | Tests | Weight | Purpose |
|------|-------|--------|---------|
| Always pass | P2P1-3 | 0.05 | Sanity (parse, torch, upstream packer) |
| Easy | S1-3 | 0.06 | Structural (file, functions, non-stub) |
| Medium | Q1-3 | 0.12 | Qweight unpack (10D permutation inverse) |
| Medium | SC1-3 | 0.06 | Scale unpack (7D permutation inverse) |
| Medium | QS1-3 | 0.12 | QW+SC integration (no LR needed) |
| **Hard** | **LR1-8** | **0.32** | **Lowrank unpack (both directions, 4 shapes)** |
| Hard | R1-6 | 0.18 | Full reconstruction per param |
| Hard | TT | 0.05 | Tight threshold (diff < 0.01) |
| Hard | F1-3 | 0.18 | Fresh synthetic data |

## Discrimination Analysis
- Score gap: **0.95** (Sonnet 1.00 vs Haiku 0.05)
- Is this meaningful? **YES** - reflects fundamental capability differences:
  - **Sonnet** correctly reverse-engineered 10-dimensional tensor reshape + permute operations for all 3 packing types, derived correct inverse permutations, structured solution with proper helper functions, and iterated to a working solution in 41 turns.
  - **Haiku** failed to add required scale and lowrank unpack functions (only modified qweight unpack), applied the forward permutation thinking it was self-inverse (it's not), used a wrong reconstruction formula (`low_rank - residual` instead of `(residual + low_rank) / smooth`), and gave up after 78 turns claiming ~10x error.
- The task tests genuine reverse-engineering capability: understanding complex GPU memory layout packing, deriving mathematical inverses, and multi-step code implementation.
- Confidence: **HIGH**

## Task Health
- Solvable without user sim: **YES** (Sonnet solved it completely in single-turn)
- Recommended difficulty: **HARD**
- Remaining concerns:
  - LR8 test (rank=32) is slightly beyond the task's data (rank=16) - Sonnet failed it but score still capped at 1.0. This test adds robustness against overfitting to rank=16.
  - The original audit identified issues (missing `quantize_nunchaku_borrow.py` reference, `weight.pt` vs `weight_approx.pt` confusion) but these appear to have already been fixed in the current instruction.md.
  - The expert time estimate of 20 min is validated by Sonnet completing it in ~21 min.
