# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10% (Check 9 at 0.10)

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.90
- Evidence: Session ended with U12 "[Request interrupted by user for tool use]" while agent was writing a tree-sitter integration plan. U11 was a context-continuation summary, confirming the conversation ran out of context and was resumed before being interrupted again.

## User-Sim Prompt Audit (Phase 2)
- Before: 3 rows (only T2, T3 from original 3 genuine messages claim)
- After: 9 rows (T2-T10), all verbatim from original_session.json
- Rebuilt: Complete rebuild. The original sim prompt claimed only 3 genuine user messages but the session actually contains 9 substantive user messages after the instruction (U1, U3-U10). U2 was "[Request interrupted by user]" (skipped), U11 was a continuation summary (skipped), U12 was a final interruption (skipped). All trigger table messages are now verbatim quotes from the session.

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 15 checks use python3 heredocs, python3 -m pytest, or CLI invocations. 100% behavioral weight. |
| test_not_tautological | A | PASS | F2P checks (1,2,7) test real registration behavior with verification of DETECTORS dict, DIMENSIONS rebuild, and DETECTOR_TOOLS structure. Cannot pass with stubs. |
| solution_uniqueness_guard | A | PASS | Tests use inspect.signature() to dynamically discover factory parameters, try multiple calling strategies, and accept any working implementation. |
| no_solution_leakage | A | PASS | instruction.md is a feature plan (not a bug fix), so it contains implementation guidance by design. No exact patch code is leaked — the instruction describes what to build, not verbatim code to copy. |
| pass_to_pass_coverage | A | PASS | Check 9 (0.10 weight) runs the existing test suite (2053 tests) and verifies no regressions. |
| behavior_in_task_description | A | PASS | All tested concepts (register_detector, register_scoring_policy, generic_lang, FixerConfig, shared phases, langs command, fix_cmd) are explicitly described in instruction.md. |
| no_hidden_solution_artifacts | A | PASS | Dockerfile does not COPY solution/ into the image. Final line: "# Do NOT include test scripts or solutions in the image". |
| dockerfile_determinism | B | PASS | Ubuntu 24.04 pinned by digest (sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b). All pip deps version-pinned. |
| no_network_during_tests | B | PASS | test.sh runs no pip/npm/apt/curl/git commands. All deps baked into Docker image at build time. |
| pinned_dependencies | B | PASS | All pip deps version-pinned: Pillow==10.4.0, setuptools==75.8.0, PyYAML==6.0.2, bandit==1.8.3, defusedxml==0.7.1, pytest==8.3.4, ruff==0.9.7, mypy==1.14.1. |
| f2p_p2p_classification_correct | B | PASS | All 15 checks labeled with [F2P] or [P2P] in comments. Only Check 9 is P2P (passes at base with 2053 tests). All other checks are F2P (fail at base because no generic.py, no register_detector, etc. exist). |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|------------|-----------|-----|-------|
| 1 (old weights, sum=1.23) | 1.00 | 1.00 | 0.00 | Both capped at 1.0 due to excess weight |
| 2 (new weights, sum=1.00) | 1.00 | 0.754 | 0.246 | Normalized weights expose real quality differences |

### Discrimination analysis
Sonnet 4.6 (137 turns, 1296s, $6.10): Perfect score. All 15 checks pass. Created proper LangConfig objects with phases, implemented langs command with auto-fix suffix and shared-phase filtering.

Haiku 4.5 (99 turns, 321s, $0.94): Score 0.754. Three discriminating failures:
- **Check 3 (E2E generic_lang)**: 0.064/0.16. Factory returned object that wasn't a LangConfig and lacked phases, but did register detectors/policies. Missing 0.096.
- **Check 8 (langs command)**: 0/0.08. Did not implement the `langs` CLI subcommand. Missing 0.08.
- **Check 13 (langs formatting)**: 0/0.07. Depends on Check 8 — no langs command means no output to verify. Missing 0.07.

These failures reflect genuine quality differences: Haiku's generic_lang factory returns incomplete objects and it skips Step 5 (langs command) entirely.

### Weight normalization fix
The original test.sh had weights summing to 1.23 with a 1.0 cap. This allowed both models to score 1.0 despite Haiku missing 0.22 worth of checks. Normalizing to sum=1.00 exposed the real gap.

## Changes Made

### test.sh
1. Changed shebang from `#!/usr/bin/env bash` to `#!/bin/bash` (rubric compliance)
2. Normalized all check weights to sum to exactly 1.00 (was 1.23)
3. Added proper F2P/P2P classification comments for all 15 checks (rubric 11)
4. No structural changes to check logic — all behavioral verification preserved

### Dockerfile
1. Pinned Ubuntu base image with digest: `ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b` (rubric 8)

### task.toml
1. Updated session_resolution from "ambiguous" (0.75) to "cut_off" (0.90) with reasoning

### user_simulation_prompt.md
1. Complete rebuild: expanded from 3 trigger rows to 9 (T2-T10)
2. All messages are now verbatim from original_session.json
3. Updated calibration section to reflect correct count (9 genuine messages, not 3)
4. Updated session state graph to show full conversation flow

### instruction.md
- NOT modified (kept verbatim per never_change_user_messages rule)

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 12
- Total turns: 13
- Notes: Successfully validated with openrouter/minimax/minimax-m2 agent, openrouter/google/gemini-3.1-pro-preview user sim. Turn fire report confirmed all conditions working.

## Confidence
- Overall: HIGH
- Gap: 0.246 (well above 0.15 threshold)
- Remaining concerns:
  - The `langs` command (Step 5) is a moderate discriminator but inherently binary (implemented or not). Future runs may see Haiku implement it, narrowing the gap slightly.
  - Check 3's sub-scoring relies on the factory returning a LangConfig with proper phases — this is the strongest discriminator and tests real implementation quality.
  - Sonnet achieving 1.0 means the ceiling may be appropriate for stronger models but could be tightened further if needed.
