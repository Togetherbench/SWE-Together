# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (target <= 0.10)
- P2P-only weight: 5% (Gate 6: on main with clean working tree)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: Final user said "No, just making sure. It seemed like my instruction interrupted your work and you prematurely committed. Sorry." Assistant confirmed "All good — I was finished and the commit matches the request."

## User-Sim Prompt Audit (Phase 2)
- Before: 14 rows, 14 verbatim messages but ALL trigger conditions were generic ("Intervene IF agent has produced output related to this turn's context")
- After: 13 rows (Turn 1 excluded as instruction.md), all verbatim, all with observable state conditions
- Action: REBUILT trigger table — replaced generic conditions with observable state-based conditions (e.g., "Agent has attempted to merge PRs", "Agent has modified arr-monitor.py argparse section")
- Added: Role description, session duration, proper Simulator Calibration section

## Critical Fix: Missing Mock `gh` CLI
- The Dockerfile had `COPY gh /usr/local/bin/gh` but `environment/gh` did not exist
- Docker build would fail without this file
- Created comprehensive mock `gh` CLI script that simulates:
  - `gh pr list` (text and JSON output)
  - `gh pr view` (individual PR details)
  - `gh pr merge` (actual merge in bare origin repo with conflict detection)
  - `gh pr close`, `gh auth status`, `gh repo view`
- Mock correctly handles the merge conflict between PR #3 (ignore-nfo-and-dll-transfers) and PR #4 (fix-ignore-exe-extension)

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | Gates 1-3 use python3 -m py_compile and AST parsing (55% weight) |
| test_not_tautological | A | PASS | All F2P gates test real behavior (merge state, AST values, branch existence) |
| solution_uniqueness_guard | A | PASS | Tests check behavioral outcomes, not specific code patterns |
| no_solution_leakage | A | PASS | instruction.md says only "Merge all open PRs and clean up feature branches" |
| pass_to_pass_coverage | A | PASS | Gate 6 (5pts) is P2P — passes on base and after fix |
| behavior_in_task_description | A | PASS | Extensions .exe/.nfo/.msi are discoverable from PR content during task |
| no_hidden_solution_artifacts | A | PASS | No solution/ in Dockerfile, no solve* files in image |
| dockerfile_determinism | B | PASS | Pinned python:3.12.8-slim-bookworm, psutil==6.1.1 |
| no_network_during_tests | B | PASS | test.sh only accesses local bare repo; no pip/npm/apt at test time |
| pinned_dependencies | B | PASS | psutil==6.1.1 |
| f2p_p2p_classification_correct | B | PASS | All 7 gates labeled [F2P] or [P2P] in test.sh comments |

## Agent Discrimination (Phase 4+6)
| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
|-------|-----------|-----------|-----|
| 1     | 0.80      | 0.05      | 0.75 |

### Sonnet Analysis (0.80)
- Successfully merged all 3 PRs via `gh pr merge`
- Correctly resolved the IGNORE_EXTENSIONS conflict (combined .nfo, .exe, .msi)
- Used `--delete-branch` to clean up remote branches
- **Missed**: Did not delete local feature branches (-20 pts, Gate 4)
- All other gates passed (1, 2, 3, 5, 6, 7)

### Haiku Analysis (0.05)
- Listed PRs correctly via `gh pr list`
- **Did not actually merge any PRs** — asked for confirmation instead of acting
- Only Gate 6 (P2P: on main, clean tree) passed
- Demonstrates classic Haiku failure: over-cautious, requests confirmation instead of executing

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 12 (out of 13 total turns)
- Reward: 0.70 (minimax-m2 agent, gemini-3.1-pro-preview user sim)
- Notes: Sim triggers fired successfully — user sim delivered follow-up requests (document flag, add short options, commit/push). Required Dockerfile fix: added /logs/agent/sessions dir and set agent UID to 1002 to match harbor mount ownership.

## Changes Made
1. **Created** `environment/gh` — mock GitHub CLI (was missing, blocking Docker build)
2. **Updated** `environment/Dockerfile` — pinned base image to python:3.12.8-slim-bookworm, psutil to 6.1.1
3. **Updated** `tests/test.sh` — added F2P/P2P labels to all 7 gates
4. **Rebuilt** `user_simulation_prompt.md` — replaced generic triggers with observable state conditions
5. **Updated** `task.toml` — added session_resolution_reasoning field
6. **Fixed** PR numbering in mock gh to match test.sh comments (PR#2=feature, PR#3=nfo, PR#4=exe)
7. **Fixed** Dockerfile: added /logs/agent/sessions dir and set agent UID=1002 for harbor mount compatibility

## Confidence
- Overall: HIGH
- Nop baseline well under threshold (0.05)
- Discrimination gap massive (0.75), driven by genuine capability difference
- All 7 Tier A rubrics pass, all 4 Tier B rubrics pass
- Remaining concerns: none significant — task discriminates strongly in correct direction
