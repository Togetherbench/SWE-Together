# Fix Summary

## Nop Baseline
- Nop reward: **0.10** (P2P weight: 10%)
- All F2P tests fail on base: **YES**

## Changes Made to Task Files

### 1. `tests/test.sh` — Weight rebalancing and anti-pattern gating
**Problem**: Nop scored 0.18 (> 0.10 limit). B3, B8, B9 passed on buggy nop state because the buggy NewBie code produced correct shapes and used CLIP embeddings.

**Fix**:
- Gated B3, B8, B9 on `antipatterns_removed` check — these tests now fail if `_pop_unexpected_kwargs`, `_fallback_operations`, or `try/except` in `_forward` still exist
- Adjusted weights: B3: 0.02→0.04, B10: 0.06→0.05, P2P: 0.06→0.05
- New weight distribution: F2P=90%, P2P=10% (was 82%/18%)
- Total still sums to 1.00

### 2. `instruction.md` — Made directive for single-turn use
**Problem**: Original instruction was purely analytical ("analyze", "do you think", "can we minimize") — agents just analyzed without implementing code changes.

**Fix**: Rewrote instruction to be implementation-directed while leaving behavioral details (like `t = 1.0 - timesteps`, return `-img`, `CONDRegular`) for the agent to discover by reading the Lumina code. This creates natural discrimination: stronger models infer correct behavior from code, weaker models miss subtleties.

### 3. `CLAUDE.md` — Added to workspace
Instructs agents to directly edit files rather than entering plan mode or asking for confirmation.

### 4. Prior fixes already in place
- `cap_feat_dim=256` already in COMMON_ARGS (audit Bug 1 was pre-fixed)
- `pip install av` already in Dockerfile (audit Bug 2 was pre-fixed)

## Agent Results (Round 4 — Final)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 3 files, -250/+52 lines | Inherited from NextDiT, correctly inferred `t=1-ts`, `-img`, `CONDRegular` from Lumina code |
| Haiku 4.5 | **0.61** | 3 files, -162/+68 lines | Inherited from NextDiT, but missed `t=1-ts` inversion and `CONDCrossAttn→CONDRegular` fix |

### Per-test breakdown (Round 4)

| Test | Weight | Sonnet 4.6 | Haiku 4.5 | What it checks |
|------|--------|-----------|-----------|----------------|
| S2 | 0.04 | PASS | PASS | No anti-pattern helpers, no nn.init |
| S3 | 0.03 | PASS | PASS | No try/except in _forward |
| S4 | 0.07 | PASS | **FAIL** | model_base.py: no apply_model, no CONDCrossAttn |
| B3 | 0.04 | PASS | PASS | _forward correct output shape + no anti-patterns |
| B4 | 0.20 | PASS | PASS | return -img at ts=0.3 |
| B5 | 0.16 | PASS | PASS | return -img at ts=0.7 |
| B6 | 0.16 | PASS | **FAIL** | t=1.0-timesteps (ts=0.3→t_embedder sees 0.7) |
| B7 | 0.16 | PASS | **FAIL** | t=1.0-timesteps (ts=0.8→t_embedder sees 0.2) |
| B8 | 0.02 | PASS | PASS | clip_text_pooled influences output |
| B9 | 0.02 | PASS | PASS | clip_img_pooled influences output |
| B10 | 0.05 | PASS | PASS | Base NextDiT still works |
| P2P | 0.05 | PASS | PASS | ComfyUI upstream unit tests |

## Earlier Rounds (for context)

### Round 2 (very explicit instruction with all hints)
| Model | Reward | Notes |
|-------|--------|-------|
| Sonnet 4.6 | 0.24 | Had tensor `or` bug (`x or y` on tensors), broke behavioral tests |
| Haiku 4.5 | 0.10 | Didn't implement (just planned) — nop score |

### Round 3 (very explicit instruction with all behavioral hints)
| Model | Reward | Notes |
|-------|--------|-------|
| Sonnet 4.6 | 1.00 | Perfect |
| Haiku 4.5 | 0.93 | Only missed CONDCrossAttn fix (instruction was too explicit, reduced discrimination) |

## Discrimination Analysis
- Score gap: **0.39** (Sonnet 1.00 - Haiku 0.61)
- Is this meaningful? **YES** — the gap reflects genuine capability differences:
  - **`t = 1.0 - timesteps`** (0.32 reward): Sonnet correctly inferred this convention by studying Lumina's `_forward` which uses `1.0 - timesteps` while the buggy NewBie code passes raw timesteps. Haiku didn't catch this.
  - **`CONDCrossAttn → CONDRegular`** (0.07 reward): Sonnet compared with `Lumina2.extra_conds` and fixed the conditioning type. Haiku assumed it was already correct without verifying.
- Confidence: **HIGH** — the failures are consistent (Haiku always misses timestep inversion and CONDCrossAttn fix when not explicitly told)

## Task Health
- Solvable without user sim: **YES** (with directive instruction and CLAUDE.md)
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - Sonnet showed variability across runs (0.24 in round 2 due to `or`-on-tensors bug, 1.0 in rounds 3 and 4) — may warrant multiple runs
  - Instruction was substantially rewritten from original analytical format. Original instruction designed for multi-turn with user sim.
  - CLAUDE.md is needed to prevent agents from entering plan mode
