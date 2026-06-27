# Fix Summary

## Nop Baseline
- Nop reward: 0.03 (target <= 0.10)
- P2P-only weight: 3% (T15 upstream test suite only)

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.85
- Evidence: User asked "Why is it not a problem in C:\musubi-tuner?" at 03:42 UTC; assistant gave a partial compile+LoRA explanation at 03:43 UTC with no user follow-up. All core features were implemented but the final Prodigy LR investigation was unresolved. Previously incorrectly tagged as "ambiguous".

## User-Sim Prompt Audit (Phase 2)
- Before: 12 rows (Turns 2-12), all with verbatim messages from original_session.json
- After: 12 rows, all verbatim (verified against session)
- Status: VERIFIED (no changes needed)
- Note: U2 ("Also examine: Does C:\musubi-tuner\ implement...") correctly skipped as it references an inaccessible private path

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 82% behavioral weight (T2-T7, T9-T10, T12-T13, T15-T16 all invoke python3/pytest) |
| test_not_tautological | A | PASS | Each F2P gate requires specific code changes; stubs/pass/empty fail all gates |
| solution_uniqueness_guard | A | PASS | Tests check behavior (kwarg passing, function delegation) not specific variable names; T11 accepts try/except OR hasattr OR getattr patterns |
| no_solution_leakage | A | PASS | instruction.md describes what to implement (multi-resolution, skip_duplicate, unwrap_model, isinstance fixes) but not exact patch code |
| pass_to_pass_coverage | A | PASS | T15 runs upstream pytest suite; passes on base (67 passed) and correct fix |
| behavior_in_task_description | A | PASS | All asserted strings (multi_resolution, skip_duplicate_bucketed_images, unwrap_model_for_sampling, _orig_mod, strategy_sd.py, sdxl_original_unet.py) derivable from instruction.md |
| no_hidden_solution_artifacts | A | PASS | Dockerfile uses git clone (no COPY), no solve/solution files in image |
| dockerfile_determinism | B | PASS | Base image pinned to python:3.12.8-slim-bookworm, all pip deps version-pinned |
| no_network_during_tests | B | PASS | test.sh runs fully offline; all deps baked into image at build time |
| pinned_dependencies | B | PASS | All 25 pip deps version-pinned (==X.Y.Z), torch pinned to CPU wheel |
| f2p_p2p_classification_correct | B | PASS | All 18 tests labeled F2P/P2P in header comment; T15 is P2P (verified passes on base); all F2P tests fail on base commit |

## Changes Made

### Dockerfile (environment/Dockerfile)
1. **Fixed path mismatch**: Changed clone target from `/workspace/repo` to `/workspace/sd-scripts` to match test.sh paths
2. **Fixed commit**: Used correct base commit `609d1292f6` (from original session) instead of `ae72efb92b`
3. **Added venv**: Created `/workspace/venv` matching test.sh's `$PYTHON` reference
4. **Pinned base image**: `python:3.12.8-slim-bookworm` instead of `python:3.12-slim`
5. **Pinned all pip deps**: 25 packages with exact versions (==X.Y.Z)
6. **Added libgl1**: Required by opencv-python (cv2) for test imports
7. **CPU-only PyTorch**: `torch==2.6.0+cpu` from PyTorch CPU index

### test.sh (tests/test.sh)
1. **Fixed shebang**: `#!/usr/bin/env bash` -> `#!/bin/bash`
2. **Normalized weights**: Total was 1.11, now exactly 1.00 (T2: 0.10->0.08, T3: 0.08->0.06, T4: 0.10->0.08, T6: 0.10->0.08, T7: 0.08->0.06, T10: 0.08->0.07)
3. **Added F2P/P2P labels**: All 18 tests now have F2P or P2P classification in comments

### task.toml
1. **Fixed syntax error**: Tags array was broken across lines
2. **Updated session_resolution**: Changed from "ambiguous" (confidence 0.6) to "cut_off" (confidence 0.85) with proper reasoning

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|-----------|-----------|-----|
| 1 (final) | 0.93 | 0.03 | 0.90 |

### Sonnet 4.6 (0.93)
- Passed T1-T15 + T18 (all multi-resolution, skip_duplicate, unwrap_model, isinstance fixes)
- Failed T16 (0.04): KeyError fallback - function propagated KeyError instead of handling it (multi-turn feature, requires sim Turn 6)
- Failed T17 (0.03): bucket_manager reset comment - never reached (multi-turn feature, requires sim Turn 9)
- Single-turn score near ceiling (0.93/1.00)

### Haiku 4.5 (0.03)
- Only T15 (P2P) passed - identical to nop baseline
- Haiku spent 18 turns in planning mode, creating a comprehensive implementation plan but never executing any code changes
- Genuine capability gap: Haiku couldn't move from analysis to implementation

### Per-Test Results (Final Round)

| Test | Weight | Type | Sonnet 4.6 | Haiku 4.5 |
|------|--------|------|-----------|----------|
| T1 multi_resolution grep | 0.03 | F2P | PASS | FAIL |
| T2 is_disk_cached 512 | 0.08 | F2P | PASS | FAIL |
| T3 is_disk_cached 1024 | 0.06 | F2P | PASS | FAIL |
| T4 cache_batch_latents | 0.08 | F2P | PASS | FAIL |
| T5 load_latents override | 0.08 | F2P | PASS | FAIL |
| T6 BaseDatasetParams field | 0.08 | F2P | PASS | FAIL |
| T7 schema dict | 0.06 | F2P | PASS | FAIL |
| T8 dedup AST | 0.03 | F2P | PASS | FAIL |
| T9 DreamBooth param | 0.08 | F2P | PASS | FAIL |
| T10 FineTuning/ControlNet | 0.07 | F2P | PASS | FAIL |
| T11 unwrap_model AST | 0.03 | F2P | PASS | FAIL |
| T12 unwrap normal path | 0.08 | F2P | PASS | FAIL |
| T13 unwrap compiled model | 0.08 | F2P | PASS | FAIL |
| T14 isinstance + _orig_mod | 0.02 | F2P | PASS | FAIL |
| T15 P2P upstream tests | 0.03 | P2P | PASS | PASS |
| T16 KeyError fallback | 0.04 | F2P | FAIL | FAIL |
| T17 bucket_manager reset | 0.03 | F2P | FAIL | FAIL |
| T18 unwrap-before-isinstance | 0.04 | F2P | PASS | FAIL |

### Discrimination Analysis
- **Gap of 0.90 is legitimate** and reflects a real capability difference
- Sonnet executed a complex multi-file feature implementation across 4 Python files (strategy_sd.py, config_util.py, train_util.py, sdxl_original_unet.py)
- Haiku got stuck in planning/analysis mode without any code modifications
- This is consistent with known Haiku limitations on complex autonomous implementation tasks

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 1 (confirmed)
- Agent model: openrouter/minimax/minimax-m2
- User sim model: openrouter/google/gemini-3.1-pro-preview
- Episode 1: Turn 8 fired (bucket_manager stale state KeyError redirect)
- Notes: Sim correctly detected the agent had completed prior features and fired the bucket_manager error turn. Trial was still running at report time but confirmed sim_turns_fired >= 1.

## Confidence
- Overall: HIGH
- Remaining concerns:
  - T16/T17 scores depend on multi-turn sim interactions that single-turn agents can't reach (by design - these are sim-only features)
  - Haiku's 0.03 (nop-equivalent) score may not persist if Haiku is updated; the planning-only behavior is version-specific
  - Bitsandbytes GLIBCXX warning in test output is cosmetic (doesn't affect results since train_util imports still work)
