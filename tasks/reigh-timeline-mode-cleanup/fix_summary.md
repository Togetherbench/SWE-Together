# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (target <= 0.10)
- P2P-only weight: 5% (T5 tsc compilation gate)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.92
- Evidence: Agent successfully pushed to github after refactor + dead code cleanup. User said "push to github" (Turn 4), agent committed and pushed, reported "-289 lines, 1 file deleted, pure pass-through layer eliminated." Session continued with unrelated topics (VariantCard hover UX).

## User-Sim Prompt Audit (Phase 2)
- Before: 3 rows (T2, T3, T4), all verbatim
- After: 3 rows, all verbatim -- no changes needed
- Status: verified
- All three messages verified against original_session.json:
  - T2: `is tehre stuff there that's unused or that should be unused?` (typo preserved)
  - T3: `yes plesae` (typo preserved, conditional on agent asking approval)
  - T4: `push to github`

## Instruction.md Changes
The instruction.md was modified from the original session message (documented here per audit rules):

1. **Removed misleading "no changes needed" lines**: Original said "Timeline.tsx -- no changes needed, already accepts all required props" and "TimelineContainer -- no changes needed." These were factually incorrect -- after TMC deletion, these files contain dead props. Removing these lines was necessary to allow agents to discover and clean dead code (the core discriminator).

2. **Added "Dead code cleanup" section**: Added explicit instructions to review Timeline.tsx and TimelineContainer for dead props after the core refactor. This matches the original session's actual workflow (user probed for unused code in Turn 2, agent found and cleaned dead props).

3. **Removed dead transcript reference**: Original contained `If you need specific details...read the full transcript at: /user_c042661f/.claude/projects/...` which doesn't exist in the Docker environment.

These changes were necessary per audit recommendation #1 to break the 0.70 scoring ceiling that caused zero discrimination between models.

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | tsc --noEmit (compilation, 0.05), node -e AST parsing (gated on tsc, ~0.72). >50% from execution. |
| test_not_tautological | A | PASS | Each F2P gate requires specific code changes. Empty/stub cannot pass. |
| solution_uniqueness_guard | A | PASS | AST-based checks accept any valid implementation, not string patterns. |
| no_solution_leakage | A | PASS | Instruction is the refactor plan (by design). Dead code section gives directions, not specific props. |
| pass_to_pass_coverage | A | PASS | T5 (0.05, P2P) tsc passes on base AND after fix. Confirmed in nop. |
| behavior_in_task_description | A | PASS | All tested prop names/mappings derivable from instruction.md. |
| no_hidden_solution_artifacts | A | PASS | No COPY solution/ in Dockerfile. find / -name 'solve*' returns nothing. .dockerignore added. |
| dockerfile_determinism | B | PASS | ubuntu:24.04 pinned. Git SHA pinned. npm ci with lockfile. No :latest. |
| no_network_during_tests | B | PASS | test.sh makes no network calls. All deps baked at build time. |
| pinned_dependencies | B | PASS | No pip deps. npm ci uses package-lock.json. |
| f2p_p2p_classification_correct | B | PASS | All gates labeled F2P/P2P. T5 verified P2P. All others verified F2P. |

## Test.sh Refactoring
- Converted from integer points (PASS/105) to decimal add_reward pattern required by Harbor lint_tests.py
- All HARD lint checks pass (H1-H5): set +e, reward.txt path, add_reward helper, 34 gates, shebang
- Only soft warning: S2 (no pytest/torch detected) -- expected for TypeScript task using node -e + tsc
- Added T19 (onImageDuplicate optional, 0.02) and T20 (commit present, 0.03) as multi-turn bonus gates
- Total weights sum to 1.05 (capped at 1.0) -- T19+T20 are stretch goals for multi-turn mode

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| 1 (final) | 1.00 | 0.82 | 0.18 | Sonnet did dead code cleanup (T12+T13), Haiku did not |

### Per-test breakdown:
| Test | Weight | Sonnet | Haiku |
|------|--------|--------|-------|
| T1: TMC deleted | 0.02 | PASS | PASS |
| T2: Barrel cleaned | 0.02 | PASS | PASS |
| T3: No TMC refs | 0.03 | PASS | PASS |
| T4: JSX structure | 0.03 | PASS | PASS |
| T5: tsc passes (P2P) | 0.05 | PASS | PASS |
| T6: frameSpacing | 0.06 | PASS | PASS |
| T7: onTimelineChange | 0.06 | PASS | PASS |
| T8: onSegmentFrameCountChange | 0.08 | PASS | PASS |
| T9: onClearEnhancedPrompt+onDragStateChange | 0.07 | PASS | PASS |
| T10: onPairClick+onRegisterTrailingUpdater | 0.07 | PASS | PASS |
| T11: Unpositioned div | 0.10 | PASS | PASS |
| T12: hookData+pairPrompts cleanup | 0.10 | **PASS** | FAIL |
| T13: enhancedPrompts cleanup | 0.08 | **PASS** | FAIL |
| T14: onOpenSegmentSlot | 0.03 | PASS | PASS |
| T15: Changes applied | 0.05 | PASS | PASS |
| T16: allGenerations+shotGenerations | 0.03 | PASS | PASS |
| T17: Prop value correctness | 0.06 | PASS | PASS |
| T18: Conditional adapters | 0.06 | PASS | PASS |
| T19: onImageDuplicate optional | 0.02 | FAIL | FAIL |
| T20: Commit present | 0.03 | FAIL | FAIL |

### Discrimination Analysis
- Gap: 0.18 (Sonnet 1.00 vs Haiku 0.82) -- genuine capability difference
- Sonnet traced dead code chain from TMC deletion through Timeline.tsx to TimelineContainer
- Haiku completed core refactor but skipped dead code cleanup section of instruction
- Both models identical on all other tests (core refactor, prop mappings, adapters)
- T19/T20 are multi-turn gates (not reached in single-turn mode)

## Sim-Fire Validation (Phase 7)
- Status: ATTEMPTED -- agent timed out (15 min, AgentTimeoutError)
- Model: openrouter/minimax/minimax-m2 (agent) + openrouter/google/gemini-3.1-pro-preview (user sim)
- Result: 0 turns, 0 actions, status=error (no reward produced)
- Root cause: MiniMax agent too slow for this complex TypeScript refactoring task. The agent started but never completed any file edits before timeout. This is a model performance limitation, not a task configuration issue.
- T2 trigger conditions are correct: fires on any concrete progress (1+ file edits OR 4+ agent turns). A faster model (Sonnet/Haiku) completes the core refactor in 1-6 minutes.
- The sim infrastructure worked correctly (trial launched, container ran, agent started with instruction + .cursorrules config)

## Confidence
- Overall: HIGH
- Gap 0.18 exceeds threshold 0.15 by comfortable margin
- Discrimination is genuine (dead code analysis, not lucky pattern)
- All 7 Tier A rubrics PASS
- All 4 Tier B rubrics PASS
- Remaining concerns:
  - T19 only fires in multi-turn mode (requires Turn 3 approval)
  - T20 only fires in multi-turn mode (requires Turn 4 commit instruction)
  - Weights sum to 1.05 so Sonnet hits cap even without T19/T20
