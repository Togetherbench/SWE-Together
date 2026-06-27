# Fix Summary: nunchaku-svdq-reconstruction

## Nop Baseline
- Nop reward: 0.05 (target <= 0.10)
- P2P-only weight: 5% (P2P1=0.02, P2P2=0.02, P2P3=0.01)

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.9
- Evidence: Session ended after user Turn 4 ("No need to remove the temporary scripts. Just fix the function to reconstruct the weight and pass the tests.") with no agent response recorded. Agent had not completed reconstruction. Session truncated at ~29 min mark.

## User-Sim Prompt Audit (Phase 2)
- Before: 4 turns in narrative format, Turn 1 labeled "(adapted)" with "always send at session start" trigger
- After: 4 turns, Turn 1 corrected to "delivered via instruction.md, NOT sent by simulator", Turns 2-4 verified verbatim
- Action: VERIFIED + FIXED
  - Turn 1: Clarified as instruction.md turn; added verbatim original message; sim trigger set to NONE
  - Turn 2: Verbatim confirmed against original_session.json U1
  - Turn 3: Verbatim confirmed against original_session.json U2
  - Turn 4: Verbatim confirmed against original_session.json U3
- Updated calibration: "3 conditional messages (Turn 1 is instruction.md, Turns 2-4 sim-triggered)"

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All behavioral tests execute Python code (inline scripts); >80% reward from execution gates |
| test_not_tautological | A | PASS | Q/SC/LR use synthetic pack->unpack round-trip; F uses fresh random data; cannot pass with stubs |
| solution_uniqueness_guard | A | PASS | find_fn() accepts multiple naming conventions; call_* functions try multiple arg patterns |
| no_solution_leakage | A | PASS | instruction.md describes symptoms not fix; no permute indices revealed |
| pass_to_pass_coverage | A | PASS | P2P1-P2P3 (0.05 weight) pass on unmodified base and correct fix |
| behavior_in_task_description | A | PASS | All file paths, param names, and shapes match instruction.md |
| no_hidden_solution_artifacts | A | PASS | `find / -name 'solve*'` returns only sympy library files |
| dockerfile_determinism | B | PASS (FIXED) | Pinned ubuntu:24.04 to sha256 digest; pinned safetensors==0.7.0 |
| no_network_during_tests | B | PASS | No network calls in test.sh; deps baked at build time |
| pinned_dependencies | B | PASS (FIXED) | torch==2.6.0+cpu and safetensors==0.7.0 both pinned |
| f2p_p2p_classification_correct | B | PASS (FIXED) | Added [F2P]/[P2P] labels in test.sh header comments |

### Additional fixes applied:
- Shebang changed from `#!/usr/bin/env bash` to `#!/bin/bash`
- SC1-SC3: Accept both (N, K//G) compact and (N, K) expanded scale output
- QS1-QS3: Handle expanded scale format without shape mismatch crash
- Test weights rebalanced: Q1-Q3 increased 0.04->0.06 each; QS1-QS3 decreased 0.04->0.02 each (net neutral)

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| 1 (original weights) | 0.39 | 0.35 | 0.04 | QS integration too soft, compensating for Haiku's wrong Q |
| 2 (fixed SC + reweighted) | 0.57 | 0.31 | 0.26 | SC fix gave Sonnet credit; Q/QS reweight amplified real skill gap |

### Per-test breakdown (Round 2):

| Test | Weight | Sonnet | Haiku |
|------|--------|--------|-------|
| P2P1-P2P3 (sanity) | 0.05 | 3/3 | 3/3 |
| S1-S3 (structural) | 0.06 | 3/3 | 3/3 |
| Q1-Q3 (qweight unpack) | 0.18 | 3/3 | 0/3 |
| SC1-SC3 (scale unpack) | 0.06 | 3/3 | 0/3 |
| QS1-QS3 (qw+scale integration) | 0.06 | 3/3 | 2/3 |
| LR1-LR8 (lowrank unpack) | 0.32 | 4/8 | 4/8 |
| R1-R6 (full reconstruction) | 0.18 | 0/6 | 0/6 |
| TT (tight threshold) | 0.05 | 0/1 | 0/1 |
| RW1-RW3 (e2e reconstruct) | 0.06 | 0/3 | 0/3 |
| F1-F3 (fresh synthetic) | 0.18 | 0/3 | 0/3 |

### Discrimination analysis:
- **Sonnet excels at**: qweight unpack (correct 10D inverse permute using view(dtype=int32) approach), scale unpack (correct 7D inverse permute), QS integration
- **Haiku's weaknesses**: qweight unpack (incorrect byte recombination), scale unpack (just transpose, no inverse permute)
- **Both solve equally**: lowrank down=False (LR odd cases), structural requirements
- **Both fail equally**: lowrank down=True, full reconstruction, fresh synthetic
- Gap reflects genuine capability: Sonnet correctly reverse-engineers complex tensor permutations; Haiku only approximates

## Sim-Fire Validation (Phase 7)
- Status: ATTEMPTED (repo available, run_eval launched with minimax-m2 + gemini-3.1-pro)
- Notes: Sim conditions are restrictive by design (original user was hands-off); 0 fired turns is expected/correct behavior per audit analysis

## Confidence
- Overall: HIGH
- Nop baseline: 0.05 (stable, only P2P passes)
- Discrimination gap: 0.26 (robust, exceeds 0.15 by wide margin)
- Remaining concerns:
  - Both models fail hardest tests (R, TT, RW, F) — expected given task difficulty (original human also failed in 29 min)
  - down=True lowrank unsolved by both models — at upper bound of single-turn difficulty
  - Sim turns likely 0 (correct per original user behavior); conditions only fire on specific agent missteps that may not occur
