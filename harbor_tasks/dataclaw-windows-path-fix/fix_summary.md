# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10% (test5_regression_unix)
- F2P tests 1-4 all FAIL on unmodified code, P2P test5 passes

## Session Resolution (Phase 1)
- Tag: cut_off
- Confidence: 0.70
- Evidence: Final user message was a question ("What providers (Claude Code/Codex...) need `_build_project_name`?"); assistant answered but no user acknowledgment or "done" signal followed. Session simply ended after the assistant's response.

## User-Sim Prompt Audit (Phase 2)
- Before: 5 rows (Turn 1-5), all verbatim, but generic trigger conditions ("Intervene IF agent has produced output related to this turn's context")
- After: 4 rows (T2-T5; T1 is the instruction), all verbatim, with specific observable conditions
- Action: Rebuilt trigger table with observable state-based conditions while preserving exact verbatim messages from original_session.json

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | All 5 tests invoke Python functions via `from dataclaw.parser import _build_project_name` and `from dataclaw.anonymizer import anonymize_path, anonymize_text`. 100% of reward weight from execution gates. |
| test_not_tautological | A | PASS | Each F2P gate checks specific return values; empty/stub functions would fail (e.g., `r1 == "myapp"`, `"alice" not in r1`). |
| solution_uniqueness_guard | A | PASS | Tests check behavioral outputs (return values contain/don't contain strings), not code patterns. Any correct implementation passes. |
| no_solution_leakage | A | PASS | instruction.md describes the symptom ("fix path handling that only works with Unix-style paths to also handle Windows paths") without revealing the fix. |
| pass_to_pass_coverage | A | PASS | Test 5 (P2P, 10%) tests Unix path regression — passes on both unmodified base and correct fix. |
| behavior_in_task_description | A | PASS | instruction.md mentions "Unix-style paths (like /Users/alice/...)" and "Windows paths (like C:\Users\alice\...)"; tests use these exact patterns. |
| no_hidden_solution_artifacts | A | PASS | Verified: `docker run --rm task-env find / -name 'solve*' -type f` returns empty. No solution/ directory copied. |
| dockerfile_determinism | B | PASS | Base image pinned: `python:3.12-slim@sha256:804ddf3251a60bbf9c92e73b7566c40428d54d0e79d3428194edf40da6521286`. All pip deps pinned with `==X.Y.Z`. |
| no_network_during_tests | B | PASS | test.sh only runs Python code — no pip/npm/apt/curl/git at test time. All deps baked into image. |
| pinned_dependencies | B | PASS | All 22 pip dependencies version-pinned (e.g., `PyYAML==6.0.3`, `typing_extensions==4.15.0`). |
| f2p_p2p_classification_correct | B | PASS | Tests 1-4 labeled F2P in comments, test 5 labeled P2P. Verified: F2P tests fail on base (nop=0.10), P2P test passes on both base and gold. |

### Hard Rules
- `set +e`: YES (line 2)
- Reward to `/logs/verifier/reward.txt`: YES (line 173)
- >= 3 reward gates: YES (5 gates with partial credit)
- Shebang `#!/bin/bash`: YES (line 1)
- Python execution gate: YES (all tests call Python functions directly)

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap  |
|-------|-----------|-----------|------|
| 1     | 1.00      | 0.60      | 0.40 |

### Per-test breakdown
| Test | Weight | Sonnet 4.6 | Haiku 4.5 |
|------|--------|-----------|-----------|
| 1. `_build_project_name` basic Windows | 25% | PASS | FAIL |
| 2. `_build_project_name` Windows edge cases | 15% | PASS | FAIL |
| 3. `anonymize_path` Windows backslash | 25% | PASS | PASS |
| 4. `anonymize_text` Windows backslash | 25% | PASS | PASS |
| 5. Regression Unix paths (P2P) | 10% | PASS | PASS |

### Analysis
- **Sonnet** (1.00): Fixed all 4 areas — `_build_project_name` (parser), `anonymize_path`, `anonymize_text` (anonymizer), plus `cli.py` hardcoded paths and `_extract_project_path_from_sessions`. Correctly handled Windows drive-letter prefix stripping in encoded directory names.
- **Haiku** (0.60): Fixed `anonymize_path` and `anonymize_text` correctly but failed to handle the Windows drive-letter prefix in `_build_project_name`. Used `Path.parts` instead of string splitting but didn't add logic to recognize a single-letter first path component as a drive letter.
- Gap of 0.40 well exceeds the 0.15 target. The discrimination is meaningful: `_build_project_name` requires understanding the encoding semantics (colons stripped from drive letters in directory names), which is harder than the straightforward backslash normalization in the anonymizer.

## Sim-Fire Validation (Phase 7)
- Status: INCONCLUSIVE
- sim_turns_fired: 0 (no_session_jsonl)
- Notes: Infrastructure validated — container builds, `/installed-agent` and `/logs/agent/sessions` directories created, Claude Code installed and agent started with instruction. The minimax model (openrouter/minimax/minimax-m2) timed out before completing the task, so no session data was captured. This is a model performance issue, not an infrastructure or trigger-condition issue.

## Changes Made
1. **task.toml**: Updated `session_resolution` from "resolved" to "cut_off" (0.70 confidence) with reasoning.
2. **user_simulation_prompt.md**: Rebuilt trigger table with observable state-based conditions; messages remain verbatim from original_session.json.
3. **environment/Dockerfile**: Pinned base image with sha256 digest, pinned all 22 pip dependencies with `==X.Y.Z` versions, added `/installed-agent` and `/logs/agent/sessions` directories for harbor framework compatibility, added `safe.directory` git config.
4. **tests/test.sh**: No changes needed — already well-structured with behavioral tests, proper F2P/P2P labels, partial scoring, and `set +e`.

## Confidence
- Overall: HIGH
- Remaining concerns:
  - Sim-fire validation was inconclusive due to model timeout (not infrastructure). A re-run with a faster model or longer timeout would validate trigger firing.
  - The 0.40 gap is robust and reflects genuine capability difference (parser vs anonymizer-only fixes).
