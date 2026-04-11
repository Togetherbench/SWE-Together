# Fix Summary: sd-scripts-sdxl-multires-dedup

## Nop Baseline
- Nop reward: **0.03** (only P2P T15 passes: 67 upstream tests, 1 skipped)
- All F2P tests fail on base: **YES**
- P2P weight: 3% (T15 only, target <= 10%)

## Changes Made

### 1. instruction.md (Modified)
- **Problem**: Original instruction was an advice-seeking question ("How to write the dataset config or modify the code to achieve this?"). Both Sonnet 4.6 and Haiku 4.5 interpreted it as a help request and responded with configuration advice without making any code changes (both scored 0.03).
- **Fix**: Revised to be directive about code changes while preserving task intent. Now explicitly requests 4 modifications (multi-resolution caching, skip_duplicate config, unwrap_model utility, isinstance fixes) with enough context to guide implementation but without spelling out exact method signatures.
- **Calibration**: An overly prescriptive version (Round 2) enabled both models to score 1.00, confirming the instruction must balance directiveness with discovery.

### 2. tests/test.sh — T4 fix (cache_batch_latents mock)
- **Problem**: Test passed `None` as vae argument, causing `cache_batch_latents` to crash on `vae.device` before reaching the mocked `_default_cache_batch_latents`. The mock was never invoked.
- **Fix**: Provided a `MockVae` object with `device`, `dtype`, and `encode()` attributes so the method reaches the mocked base call.

### 3. tests/test.sh — T7 fix (schema dict search)
- **Problem**: Test only searched module-level dicts via `dir(cu)`, but `DATASET_ASCENDABLE_SCHEMA` is a class attribute of `ConfigSanitizer`, invisible at module level.
- **Fix**: Added fallback that searches class-level dict attributes using `inspect.isclass()`.

### 4. tests/test.sh — T11 fix (unwrap_model AST)
- **Problem**: Test only accepted `try/except` or `hasattr` patterns for `_orig_mod` handling. `getattr(unwrapped, "_orig_mod", unwrapped)` is equally valid but wasn't recognized.
- **Fix**: Added `getattr` as an accepted pattern alongside `try/except` and `hasattr`.

### 5. tests/test.sh — T8 fix (dedup AST)
- **Problem**: `has_removal` check only recognized `pop/remove/del/comprehension`, not `continue`-based skip logic which is a valid dedup pattern.
- **Fix**: Added `ast.Continue` as a valid "removal" pattern.

## Agent Results (Round 1 — original instruction)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.03 | 0 | Explained config approach, no code changes |
| Haiku 4.5 | 0.03 | 0 | Explained config approach, no code changes |

## Agent Results (Round 2 — overly prescriptive instruction)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 1.00 | 4 | Full implementation following step-by-step recipe |
| Haiku 4.5 | 1.00 | 4 | Full implementation following step-by-step recipe |

## Agent Results (Final Round — balanced instruction)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 4 (strategy_sd.py, config_util.py, train_util.py, sdxl_original_unet.py) | 51 turns, implemented all features autonomously. Used `getattr` for unwrap_model. Clean 57-line diff. |
| Haiku 4.5 | **0.03** | 0 | 9 turns, entered planning mode. Created detailed plan but asked "Ready to proceed?" without implementing. |

### Per-Test Pass/Fail (Final Round)

| Test | Weight | Sonnet 4.6 | Haiku 4.5 |
|------|--------|-----------|----------|
| T1 multi_resolution grep | 0.03 | PASS | FAIL |
| T2 is_disk_cached 512 | 0.10 | PASS | FAIL |
| T3 is_disk_cached 1024 | 0.08 | PASS | FAIL |
| T4 cache_batch_latents | 0.10 | PASS | FAIL |
| T5 load_latents override | 0.08 | PASS | FAIL |
| T6 BaseDatasetParams field | 0.10 | PASS | FAIL |
| T7 schema dict | 0.08 | PASS | FAIL |
| T8 dedup AST | 0.03 | PASS | FAIL |
| T9 DreamBooth param | 0.08 | PASS | FAIL |
| T10 FineTuning/ControlNet | 0.08 | PASS | FAIL |
| T11 unwrap_model AST | 0.03 | PASS | FAIL |
| T12 unwrap normal path | 0.08 | PASS | FAIL |
| T13 unwrap compiled model | 0.08 | PASS | FAIL |
| T14 isinstance + _orig_mod | 0.02 | PASS | FAIL |
| T15 P2P upstream tests | 0.03 | PASS | PASS |

## Discrimination Analysis
- **Score gap: 0.97** (Sonnet 1.00 vs Haiku 0.03)
- **Is this meaningful?** YES — reflects a fundamental agentic capability difference:
  - **Sonnet 4.6** autonomously reads the codebase, identifies patterns from other strategy files, and implements all changes across 4 files in a single session.
  - **Haiku 4.5** consistently enters "planning mode" for complex multi-file tasks, creating detailed plans and asking for confirmation rather than executing. This was reproduced across 2 independent runs.
  - When given step-by-step instructions (Round 2), Haiku scored 1.00 — confirming the coding capability exists but the autonomous execution does not.
- **Confidence: HIGH** — consistent across multiple independent runs.

## Task Health
- **Solvable without user sim**: YES (Sonnet achieves 1.00 in single turn with directive instruction)
- **Recommended difficulty**: MEDIUM
- **Remaining concerns**:
  - Haiku's failure is behavioral (planning without executing) rather than a coding capability limitation. The instruction calibration is critical — too vague = both fail, too specific = both pass.
  - The current instruction sits at a good balance point for Sonnet vs Haiku discrimination.
  - T5's line-count threshold of 4 may still be arbitrary; a behavioral test checking actual latent loading would be more robust but is impractical without GPU/test data.
