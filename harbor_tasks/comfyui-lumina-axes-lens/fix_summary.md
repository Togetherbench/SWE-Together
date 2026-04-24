# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (target ≤ 0.10)
- P2P-only weight: 5% (T1=0.01 + P2P=0.04)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.90
- Evidence: User accepted implementation without correction, then asked conceptual follow-up ("What's the difference between the implementations with and without axes_lens?"). Agent explained. Session ended naturally.

## User-Sim Prompt Audit (Phase 2)
- Before: 5 turns documented, all verbatim from session
- After: 5 turns, all verbatim — verified match against original_session.json
- Status: VERIFIED (no changes needed)
- Trigger conditions are well-designed: Turn 2 fires only if agent wrongly concludes "no problems"; Turn 3 fires only on explicit pause; Turn 5 fires on task completion

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 91% weight from behavioral tests (python3 execution) |
| test_not_tautological | A | PASS | Stub (pass/return None) scores 0.05; trivial wrapper fails T13 |
| solution_uniqueness_guard | A | PASS | Runtime discovery accepts any class name with axes_lens param; T2/T3 have import fallback |
| no_solution_leakage | A | PASS | instruction.md says "Implement axes_lens" — no patch details |
| pass_to_pass_coverage | A | PASS | T1 (0.01, valid Python) + P2P (0.04, EmbedND+NextDiT upstream) = 0.05 |
| behavior_in_task_description | A | PASS | All assertions derivable from instruction.md (axes_lens, EmbedND, model.py) |
| no_hidden_solution_artifacts | A | PASS | Dockerfile doesn't COPY solution/; find returns only sympy/solvers |
| dockerfile_determinism | B | PASS | Pinned ubuntu:24.04 to SHA digest; all pip deps pinned ==X.Y.Z; torch CPU index |
| no_network_during_tests | B | PASS | test.sh uses only local Python/torch; no pip/npm/curl at test time |
| pinned_dependencies | B | PASS | All pip deps version-pinned (torch==2.6.0+cpu, etc.) |
| f2p_p2p_classification_correct | B | PASS | Comments label each gate as P2P/F2P; classifications verified against nop baseline |

### Hard Rules
- ✓ `set +e` (line 35)
- ✓ Reward written to `/logs/verifier/reward.txt`
- ✓ 15 reward gates with partial credit
- ✓ Shebang `#!/bin/bash`
- ✓ Python execution gates (`python3 <<` heredocs)
- ✓ lint_tests.py: PASS (0 violations, 0 warnings)

## Agent Discrimination (Phase 4+6)

| Round | Image | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|-------|-----------|-----------|-----|
| 1 | original (unpinned) | 0.55 | 0.05 | 0.50 |
| 2 (final) | pinned deps | 0.55 | 0.05 | 0.50 |

### Sonnet 4.6 Analysis (both rounds: 0.55)
- Created `EmbedNDAxesLens` (R1) / `EmbedND` (R2) class
- Both used normalization approach: `rope(ids[..., i] / axes_lens[i], ...)`
- This changes RoPE values for ALL positions (not just OOB), producing max_diff ~1.98
- Passes: structural (T1-T4), instantiation (T5-T6), shape (T7), value range (T8), different state (T13), purity (T16), P2P
- Fails: numerical matching against EmbedND (T9-T11, T15) — fundamentally wrong algorithm
- Score correctly reflects: structure right, math wrong

### Haiku 4.5 Analysis (both rounds: 0.05)
- R1: Got stuck in plan mode (ExitPlanMode tool denied), produced only a plan
- R2: Made no code changes (only model_management.py CPU patch)
- Score = nop baseline, correctly reflecting zero implementation

### Discrimination Quality
- Gap: 0.50 — well above 0.15 threshold
- Genuine signal: Sonnet implements (wrong algorithm, good structure); Haiku doesn't implement
- Consistent across two independent runs with different Docker images

## Changes Made

### test.sh
1. Fixed shebang: `#!/usr/bin/env bash` → `#!/bin/bash` (hard rule compliance)
2. Added nop baseline comment: `# Nop score: 0.05 (T1 + P2P only)`

### Dockerfile
1. Pinned base image: `ubuntu:24.04` → `ubuntu:24.04@sha256:c4a8d5503dfb...`
2. Separated torch install to CPU-specific index: `torch==2.6.0+cpu`, `torchvision==0.21.0+cpu`
3. Pinned all pip deps to exact versions (==X.Y.Z)

### task.toml
1. Added `session_resolution_reasoning` field
2. Updated confidence: 0.85 → 0.90

### instruction.md
- No changes (kept verbatim per never_change_user_messages rule)

### user_simulation_prompt.md
- No changes (verified all messages are verbatim from session)

## Sim-Fire Validation (Phase 7)
- Status: FAILED (infrastructure)
- sim_turns_fired: 0
- Agent model: minimax-m2 (via OpenRouter)
- User sim model: gemini-3.1-pro-preview (via OpenRouter)
- Error: AgentTimeoutError after 20 min
- Root cause: Minimax-m2 agent timed out. Container had permission issues with /logs/agent/sessions that prevented session JSONL capture. No sim turns could fire because the agent never reached completion state.
- Notes: This is an infrastructure issue, not a task configuration issue. The user_simulation_prompt.md trigger conditions are correctly specified (verified against original_session.json). In the direct Sonnet/Haiku runs, the instruction-based single-turn evaluation worked correctly.

## Confidence
- Overall: HIGH
- Discrimination gap: 0.50 (very strong, exceeds 0.15 by 3.3x)
- Remaining concerns:
  - Sonnet consistently chooses normalization approach (0.55) rather than precomputation (would score ~0.95+). This suggests the instruction's terseness biases toward incorrect interpretations.
  - Haiku consistently fails to implement anything — gap is partly from Haiku's inability, not just Sonnet's capability.
  - Both models miss the correct precomputation approach, which the original audit found in GLM 5.1 (0.95).
