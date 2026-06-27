# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10%
- All F2P tests fail on unmodified base code: YES

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.85
- Evidence: Session ended while user was still asking questions about `image_model` usage (U15: "Where is it used in the whole ComfyUI repo?"). No completion acknowledgment. User was mid-exploration in turns 14-16 (out of scope for task).

## User-Sim Prompt Audit (Phase 2)
- Before: 8 trigger rows (T4, T5, T6, T7, T8, T9, T10, T12)
- After: 8 trigger rows, all verbatim (verified against original_session.json)
- Status: VERIFIED (no changes needed)
- T4=U3 (verbatim), T5=U4 (trimmed prefix), T6=U5 (verbatim), T7=U6 (verbatim), T8=U7 (trimmed prefix), T9=U8 (trimmed prefix), T10=U9 (verbatim), T12=U11 (verbatim)
- Skipped messages: U1/U2 (PowerShell corrections, irrelevant), U10/U13 (user-made external edits), U12/U14/U15 (out of scope)

## Changes Made

### 1. `tests/test.sh` - Weight rebalancing + shebang fix
**Problem**: Nop scored 0.18 (> 0.10 limit) because P2P weights totaled 0.18.
**Fix**: Reduced P2P weights (B3: 0.02->0.01, B8: 0.02->0.01, B9: 0.02->0.01, B10: 0.06->0.03, P2P: 0.06->0.04) and redistributed to F2P behavioral tests (B4: 0.20->0.22, B5: 0.16->0.18, B6: 0.16->0.18, B7: 0.16->0.18). Also fixed shebang from `#!/usr/bin/env bash` to `#!/bin/bash`.

### 2. `environment/Dockerfile` - Pinned dependencies
**Problem**: Base image and pip deps not version-pinned (Tier B rubric violations).
**Fix**: Pinned ubuntu:24.04 to sha256 digest, pinned all pip dependencies to ==X.Y.Z versions (transformers==5.5.4, safetensors==0.7.0, aiohttp==3.13.5, einops==0.8.2, pyyaml==6.0.3, Pillow==12.2.0, scipy==1.17.1, tqdm==4.67.3, psutil==7.2.2, tokenizers==0.22.2, sentencepiece==0.2.1, pytest==9.0.3, pytest-timeout==2.4.0, av==17.0.1).

### 3. `task.toml` - Session resolution tag
Updated from ambiguous (0.7) to cut_off (0.85) with reasoning.

### 4. `instruction.md` - NOT changed (kept verbatim)
The instruction is analytical in nature ("analyze", "do you think", "can we minimize"). This is by design for multi-turn evaluation where T4 ("You may completely rewrite the PR") triggers coding. Single-turn evaluation requires the combined prompt to achieve discrimination.

### 5. Prior fixes already in place
- `cap_feat_dim=256` already in COMMON_ARGS (audit Bug 1 was pre-fixed)
- `pip install av` already in Dockerfile (audit Bug 2 was pre-fixed)

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 76% of reward from Python execution gates (model instantiation + forward pass) |
| test_not_tautological | A | PASS | B4-B7 (0.76 weight) require actual -img return and t=1-timesteps behavior |
| solution_uniqueness_guard | A | PASS | Tests check behaviors not variable names; accepts any correct implementation |
| no_solution_leakage | A | PASS | instruction.md describes symptoms (anti-patterns, conventions) not fixes |
| pass_to_pass_coverage | A | PASS | B3, B8, B9, B10, P2P upstream tests (0.10 weight) pass on both base and fix |
| behavior_in_task_description | A | PASS | All tested behaviors derivable from instruction + git diff |
| no_hidden_solution_artifacts | A | PASS | No solve*/solution* files in image (only library files) |
| dockerfile_determinism | B | PASS | Base image pinned to sha256 digest, all deps version-pinned |
| no_network_during_tests | B | PASS | No pip/npm/apt/curl/git in test.sh |
| pinned_dependencies | B | PASS | All pip deps use ==X.Y.Z |
| f2p_p2p_classification_correct | B | PASS | All F2P tests fail on base, all P2P tests pass on both base and fix |

## Agent Discrimination (Phase 4+6)
| Round | Prompt | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|--------|-----------|-----------|-----|
| 1 (instruction only) | Original instruction.md | 0.10 (no code changes) | 0.10 (no code changes) | 0.00 |
| 2 (instruction + T4) | instruction + T4 combined | 1.00 | 0.10 (no code) | 0.90 |
| 3 (imperative v2) | instruction + T4 + "go ahead" | 1.00 | 0.14 | 0.86 |

### Round 3 detail (final, both agents implemented changes):
| Test | Weight | Sonnet 4.6 | Haiku 4.5 | What it checks |
|------|--------|-----------|-----------|----------------|
| S2 | 0.04 | PASS | FAIL (nn.init) | No anti-pattern helpers, no nn.init |
| S3 | 0.03 | PASS | FAIL (try/except) | No try/except in _forward |
| S4 | 0.07 | PASS | FAIL (CONDCrossAttn) | model_base.py fixes |
| S5 | 0.04 | PASS | PASS | operations.Linear + operations.RMSNorm |
| B3 | 0.01 | PASS | PASS | _forward correct shape |
| B4 | 0.22 | PASS | FAIL (-img) | return -img at ts=0.3 |
| B5 | 0.18 | PASS | FAIL (-img) | return -img at ts=0.7 |
| B6 | 0.18 | PASS | FAIL (t=1-ts) | t=1.0-timesteps (ts=0.3->0.7) |
| B7 | 0.18 | PASS | FAIL (t=1-ts) | t=1.0-timesteps (ts=0.8->0.2) |
| B8 | 0.01 | PASS | PASS | clip_text_pooled influences output |
| B9 | 0.01 | PASS | PASS | clip_img_pooled influences output |
| B10 | 0.03 | PASS | PASS | Base NextDiT still works |
| P2P | 0.04 | PASS | PASS | ComfyUI upstream unit tests |

Discrimination analysis: The 0.86 gap reflects genuine capability differences:
- **return -img** (0.40 reward): Sonnet inferred Lumina convention from code; Haiku kept `return img`
- **t = 1.0 - timesteps** (0.36 reward): Sonnet compared with Lumina's _forward; Haiku passed raw timesteps
- **nn.init removal** (0.04): Sonnet removed; Haiku retained
- **try/except removal** (0.03): Sonnet removed; Haiku retained
- **CONDCrossAttn -> CONDRegular** (0.07): Sonnet fixed model_base.py; Haiku left as-is

## Sim-Fire Validation (Phase 7)
- Status: PASSED (manual verification)
- sim_turns_fired: 4 (T4, scope redirect, T5, T6)
- Trial timed out at 1500s (minimax-m2 agent was slow), but sim trigger mechanism confirmed working
- Episode 1: T4 fired ("Now use git diff...") after agent's initial analysis
- Episode 5: Scope redirect fired when agent tried to merge into Lumina
- Episode 7: T5 fired ("Do we need to init model parameters?")
- Episode 8: T6 fired ("But there is no nn.init in Lumina...")
- Automated turn_fire_report couldn't detect turns due to timeout, but user_decision.json files confirm

## Confidence
- Overall: HIGH
- Discrimination gap: 0.86 (target >= 0.15)
- Task requires multi-turn (instruction alone is analytical; T4 triggers coding)
- For single-turn benchmarking, a combined prompt (instruction + T4 + imperative directive) is needed
- Remaining concerns:
  - Task is inherently multi-turn; single-turn with original instruction.md produces no discrimination
  - Sim-fire trial was terminated by timeout; full reward was not computed in sim context
