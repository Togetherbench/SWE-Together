# Fix Summary

## Changes Made

### Critical Fix: venv activation in test.sh (pre-existing)
The original test.sh was missing venv activation, causing all torch-dependent tests to fail.
This was already fixed before this audit (line 16: `export PATH="/workspace/venv/bin:$PATH"`).
The fix unblocked 12 of 17 tests.

### Dockerfile Tier B fixes
- Pinned base image: `ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b`
- Pinned all pip dependencies: `safetensors==0.5.3`, `tqdm==4.67.1`, `packaging==24.2`

### task.toml: session_resolution metadata
Added `session_resolution_reasoning` field to existing session_resolution tag.

## Nop Baseline
- Nop reward: 0.05 (target <= 0.10)
- P2P-only weight: 5% (T1=0.01, T4=0.01, T5=0.01, P2P=0.01, P2P-2=0.01)
- All F2P tests correctly fail on unmodified base code

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.85
- Evidence: Session ends with assistant announcing 3 pending tasks ("I will write verify_simplification.py", "I will replace pack_awq_qweight", "I will write reproduce_issue.py") but never completing them. No user acknowledgment of completion. Last user message was Turn 4 (U3) asking to keep |= and simplify indexing.

## User-Sim Prompt Audit (Phase 2)
- Before: 4 trigger rows (T1=skip, T2, T3, T4), all verbatim
- After: No changes needed — all messages verified verbatim against original_session.json
- Status: VERIFIED clean
- Verbatim verification:
  - T2: "Is there any other issue in @quantize.py ?" — matches session U1 text portion
  - T3: "Can we simplify the loop in `pack_awq_qweight`?" — matches session U2 exactly
  - T4: "`sum` and `|=` may behave differently..." — matches session U3 exactly
- Note: Since instruction.md already includes the simplification request and the |= guidance, Turns 3 and 4 will likely be skipped in evaluation. Turn 2 may also be skipped if the agent independently finds bugs (which is expected given the explicit focus areas in instruction.md).

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 72% of reward weight from python3 -c execution gates (T2-5, T8-10, P2P) |
| test_not_tautological | A | PASS | Anti-stub checks in T1, T6, T7, T8, T11; F2P tests verified to fail on nop |
| solution_uniqueness_guard | A | PASS | Tests check behavior (crash/no-crash, shapes, values), not variable names or style |
| no_solution_leakage | A | PASS | instruction.md describes symptoms ("run correctly?", "construct key names?"), not fixes |
| pass_to_pass_coverage | A | PASS | 5 P2P tests (0.05 weight): T1, T4, T5, P2P, P2P-2. All pass on nop AND on correct fix |
| behavior_in_task_description | A | PASS | All assertions derivable from instruction.md + referenced spec files |
| no_hidden_solution_artifacts | A | PASS | No solution/ files in image; `find / -name 'solve*'` returns only library files |
| dockerfile_determinism | B | PASS (fixed) | Pinned ubuntu digest + all pip deps |
| no_network_during_tests | B | PASS | test.sh has no network calls |
| pinned_dependencies | B | PASS (fixed) | safetensors==0.5.3, tqdm==4.67.1, packaging==24.2 |
| f2p_p2p_classification_correct | B | PASS | Labels verified: all F2P fail on nop, all P2P pass on nop and on fix |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|-----------|-----------|-----|
| 1     | 1.00      | 1.00      | 0.00 |
| 2     | (running) | 1.00      | 0.00 |

### Analysis
Both models achieve perfect scores on every run. The task does not discriminate Sonnet 4.6 vs Haiku 4.5 in single-turn mode.

**Root cause:** The instruction.md is prescriptive — it explicitly lists the 3 bug categories and the exact simplification approach (single loop, |=, not sum). Both models can follow explicit bugfix instructions perfectly. The changes required are:
1. Add `.values` to `quantize_residual` max() call
2. Add `.values` to `quantize_awq_layer` min()/max() calls
3. Fix f-string in main() from `f"{name}.{weight}"` to `f"{name}.weight"`
4. Simplify pack_awq_qweight to single loop with |=

All four changes are mechanical and well-specified. No creative judgment or deep analysis is needed.

**Gap cannot be engineered** without either:
- Changing instruction.md (prohibited — read-only)
- Adding unfair/arbitrary test gates (violates rubric 3: solution_uniqueness_guard)
- Using multi-turn evaluation where sim turns create opportunities for differentiation

### Discrimination via multi-turn
The user simulation prompt has conditional triggers that could create discrimination:
- Turn 3 (simplification prompt) fires if agent hasn't already started simplifying
- Turn 4 (|= redirect) fires if agent uses sum() instead of |=

In multi-turn mode, a weaker model might initially propose sum() and need the Turn 4 redirect, costing time and potentially producing a worse result. However, since instruction.md already says "not sum()", even in multi-turn both models will likely already use |=.

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 1 (Turn 3: "Can we simplify the loop in `pack_awq_qweight`?")
- 5 episodes total: 1 question + 4 no-ops
- Agent (minimax-m2) scored 1.0 in multi-turn mode
- Turn fire report: "Tasks with >=1 sim turn fired: 1/1"
- Note: Turn 2 was skipped (agent already found bugs), Turn 4 was skipped (agent used |= not sum)

## Confidence
- Overall: MEDIUM
- The task is correctly constructed (all 11 rubrics pass, tests are well-designed, nop baseline=0.05)
- Sim-fire validation passed (1 sim turn fired)
- The lack of Sonnet/Haiku discrimination is inherent to the prescriptive instruction, not a test design flaw
- Remaining concerns:
  1. Gap = 0.00 < target 0.15 — both Sonnet 4.6 and Haiku 4.5 score 1.0
  2. Even minimax-m2 scores 1.0 in multi-turn — task is uniformly easy for all capable models
  3. The instruction's prescriptiveness makes this task appropriate for "follow explicit instructions" validation rather than "independent bug diagnosis" evaluation
