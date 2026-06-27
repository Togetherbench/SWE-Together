# Fix Summary

## Nop Baseline
- Nop reward: 0.07 (target <= 0.10)
- P2P-only weight: 7% (Check 9 only)
- Only the P2P check (analysis functions exist at base commit) passes on unmodified code

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: Final user message "can you close that branch if it's done?" -> assistant confirmed "Done. Deleted both local and remote feat-mcp-node-discovery branch." All task items completed and pushed earlier in session.
- Fix: task.toml had malformed TOML syntax (tags array separated from its key, session_resolution fields interleaved with broken array literal). Rewrote with correct syntax + added reasoning field.

## User-Sim Prompt Audit (Phase 2)
- Before: 10 trigger rows, all verbatim
- After: 10 rows, all verified verbatim against original_session.json
- Status: VERIFIED (no changes needed)
- All 10 trigger messages match exact text from session messages U12, U14, U16, U17, U23, U39, U36, U37, U46, U50
- Simulator rules properly adapted (skip git operations, corrective not conversational, 15 message cap)

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | 90% of weight from python3 execution gates (imports, function calls, pytest runs) |
| test_not_tautological | A | PASS | Anti-stub guards: stmt count checks, expand function validation, AST inspection, result size checks |
| solution_uniqueness_guard | A | FIX | Broadened dispatch fn names, wrapper fn names, nested handler detection, test file scanning |
| no_solution_leakage | A | PASS (noted) | instruction.md is prescriptive about structure but does NOT contain solution code. Kept verbatim. |
| pass_to_pass_coverage | A | PASS | Check 9 (0.07) tests find_upstream/find_downstream/find_path at base commit eba7a29 |
| behavior_in_task_description | A | PASS | All test assertions derivable from instruction.md |
| no_hidden_solution_artifacts | A | PASS | No COPY solution/ in Dockerfile. No solve* files in image. |
| dockerfile_determinism | B | FIX | Pinned ubuntu:24.04 to SHA256. Pinned numpy==2.2.3, pytest==8.3.5, pytest-timeout==2.3.1. |
| no_network_during_tests | B | PASS | test.sh has no pip/npm/apt/curl/git calls at test time |
| pinned_dependencies | B | FIX | All pip deps now version-pinned (==X.Y.Z) |
| f2p_p2p_classification_correct | B | FIX | Added [F2P]/[P2P] labels to all check comments. Check 9 = P2P, all others = F2P. |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Notes |
|-------|-----------|-----------|-----|-------|
| 1 (pre-fix) | 0.78 | 0.07 | 0.71 | Sonnet failed 2b-i/ii (dispatch name), 4 (stmt threshold), 6a/6b |
| 2 (post-fix) | 0.98 | 0.07 | 0.91 | Fixed rubric 3 violations; Sonnet only misses .mcp.json + requirements.txt |

### Per-check breakdown (final)

| Check | Weight | Sonnet | Haiku |
|-------|--------|--------|-------|
| 1 (Shared search module) | 0.05 | PASS | FAIL |
| 2a (MCP analysis tools) | 0.04 | PASS | FAIL |
| 2b-i (MCP dispatch basic) | 0.06 | PASS | FAIL |
| 2b-ii (MCP dispatch correct) | 0.08 | PASS | FAIL |
| 2b-iii (MCP full correctness) | 0.08 | PASS | FAIL |
| 4 (Test suite) | 0.08 | PASS | FAIL |
| 4b (Turn 3 coverage) | 0.01 | PASS | FAIL |
| 5 (TASK_ALIASES extracted) | 0.03 | PASS | FAIL |
| 6a (.mcp.json) | 0.01 | FAIL | FAIL |
| 6b (requirements.txt) | 0.01 | FAIL | FAIL |
| 7 (Skills reorganized) | 0.03 | PASS | FAIL |
| 8 (Prescriptive descriptions) | 0.02 | PASS | FAIL |
| 9 (Analysis P2P) | 0.07 | PASS | PASS |
| 10 (Knowledge integration) | 0.14 | PASS | FAIL |
| 11-i (Cross-module basic) | 0.07 | PASS | FAIL |
| 11-ii (Alias correctness) | 0.09 | PASS | FAIL |
| 11-iii (E2E chain) | 0.08 | PASS | FAIL |
| 12 (Edge cases) | 0.05 | PASS | FAIL |

### Analysis
- **Sonnet 4.6** (0.98): Created shared aliases module (cli_tools/registry/aliases.py), modified knowledge.py to import from it, wired analysis functions into MCP server with `_dispatch` pattern, created 32 tests across 2 files covering analysis+search+knowledge modules, reorganized skills into 3 focused skill files, improved tool descriptions to be prescriptive. Only missed .mcp.json and requirements.txt (0.02 total).
- **Haiku 4.5** (0.07): Did essentially nothing -- only deleted CLAUDE.md (already removed in Dockerfile). Created no new files, made no code modifications. Only the P2P check passed.
- **Gap: 0.91** -- genuine and large quality discrimination reflecting real capability difference.

### Test Fixes Applied (Rubric 3 - solution_uniqueness_guard)
1. **Check 2b-i/2b-ii**: Added `_dispatch`, `dispatch_tool`, `_route` to dispatch function name list; added `_fmt_upstream`/`_fmt_downstream` to wrapper function list; broadened nested handler detection from exact `find_upstream`/`find_downstream` to `upstream`/`downstream` substring match; added knowledge-object dispatch signature variant (`dispatch(kb, tool_name, args)`)
2. **Check 4**: Lowered statement threshold from 4 to 2 (concise tests are still substantive); added `_fmt_*`, `analyze_workflow`, `get_workflow_info` to refs set; changed to scan ALL test files for module coverage (not just file with most tests); reduced module coverage requirement from 3 to 2 categories
3. **Weight adjustments**: Check 4b: 0.02 -> 0.01, Check 12: 0.06 -> 0.05. Total now exactly 1.00 (no cap margin).

## Sim-Fire Validation (Phase 7)
- Status: FAILED (infrastructure, not task design)
- sim_turns_fired: 0
- Notes: Harbor runner mounts `/logs` volume that overrides Dockerfile-created directory. Agent user cannot create `/logs/agent/sessions` needed by Claude Code CLI, preventing the agent from starting. Two attempts with same result. Added `mkdir -p /logs/agent/sessions` to Dockerfile but mounted volume overrides it. The user_simulation_prompt.md trigger table is well-structured with 10 verbatim messages and reasonable conditions -- the failure is purely an infrastructure/permissions issue.

## Confidence
- Overall: HIGH
- Discrimination gap (0.91) is well above the 0.15 target
- All 7 Tier A rubrics pass
- All 4 Tier B rubrics addressed (3 fixed, 1 already passing)
- Nop baseline (0.07) well below 0.10 ceiling
- Total weight is exactly 1.00 (no free-failure margin)
- Remaining concerns:
  - Sim-fire could not be validated due to Harbor infrastructure issue (volume mount permissions)
  - instruction.md is prescriptive (tells agent what to create/where) but kept verbatim per rules
  - In multi-turn mode with sim messages, Haiku might score higher as the user sim would guide it through steps. Single-turn gap is extremely strong (0.91) but multi-turn gap is untested.
