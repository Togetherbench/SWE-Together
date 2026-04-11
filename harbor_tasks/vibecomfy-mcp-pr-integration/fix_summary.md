# Fix Summary

## Nop Baseline
- Nop reward: 0.07 (P2P weight: 7%)
- All F2P tests fail on base: YES
- Only Check 9 (analysis functions P2P) passes on unmodified base commit

## Agent Results (Round 1)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.76 | 5 modified + 6 new (search.py, tests/, skills, pyproject.toml) | Direct implementation: extracted TASK_ALIASES to search.py, added 5 analysis MCP tools, 3 focused skills, 45 tests |
| Haiku 4.5 | 0.07 | 0 (no code changes) | Entered plan mode, created implementation plan, got stuck on ExitPlanMode permission denial, never wrote code |

### Round 1 Per-check breakdown
| Check | Weight | Sonnet | Haiku |
|-------|--------|--------|-------|
| 1 (Shared search module) | 0.05 | PASS | FAIL |
| 2a (MCP analysis tools) | 0.04 | PASS | FAIL |
| 2b-i (MCP dispatch basic) | 0.06 | FAIL* | FAIL |
| 2b-ii (MCP dispatch correct) | 0.08 | FAIL* | FAIL |
| 2b-iii (MCP full correctness) | 0.08 | PASS | FAIL |
| 4 (Test suite) | 0.08 | FAIL | FAIL |
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
| 12 (Edge cases) | 0.06 | PASS | FAIL |

*Check 2b-i/ii failed due to test bug (not recognizing nested MCP SDK handler pattern)

## Test Refinements
### Change: Fixed Check 2b-i and 2b-ii dispatch function detection
- **Why**: Sonnet correctly implemented MCP tools using the standard MCP SDK pattern, where `call_tool` is defined inside `main()` as a `@server.call_tool()` decorated handler. The original test only looked for module-level dispatch functions via `getattr(mcp_mod, ...)`, which couldn't find nested handlers.
- **Fix**: Added "Approach 3" to both checks that uses AST analysis to find nested handlers containing `find_upstream` and `find_downstream` calls, then verifies the wiring is meaningful by calling the underlying `cli_tools.analysis` functions directly. The nested handler is accepted if it has both `find_upstream` and `find_downstream` references and >=3 if-branches (the MCP SDK pattern uses a single if/elif chain).
- **Impact**: Sonnet's score went from 0.76 → 0.90 (+0.14). Haiku unaffected (still 0.07). Nop baseline unaffected (still 0.07).

## Agent Results (Final Round)
| Model | Reward | Turns | Cost | Files Changed | Key Approach |
|-------|--------|-------|------|---------------|-------------|
| Sonnet 4.6 | 0.90 | 38 | $1.85 | 4 modified + 7 new | Direct coding: search.py, MCP tools, skills, tests |
| Haiku 4.5 | 0.07 | 21 | $0.39 | 0 (no code) | Plan mode → stuck on ExitPlanMode |

### Final Per-check breakdown
| Check | Weight | Sonnet | Haiku |
|-------|--------|--------|-------|
| 1 (Shared search module) | 0.05 | PASS | FAIL |
| 2a (MCP analysis tools) | 0.04 | PASS | FAIL |
| 2b-i (MCP dispatch basic) | 0.06 | PASS | FAIL |
| 2b-ii (MCP dispatch correct) | 0.08 | PASS | FAIL |
| 2b-iii (MCP full correctness) | 0.08 | PASS | FAIL |
| 4 (Test suite) | 0.08 | FAIL | FAIL |
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
| 12 (Edge cases) | 0.06 | PASS | FAIL |

### Why Sonnet misses Check 4 (0.08)
Sonnet creates tests but they only cover 2 module categories (analysis, mcp_server). Check 4 requires tests spanning >=3 of: analysis, search, knowledge, mcp_server. This is a legitimate gap -- the agent didn't write comprehensive enough tests.

### Why Sonnet misses Check 6a/6b (0.02 total)
Sonnet never created `.mcp.json` or `requirements.txt`. These are trivial structural files but the agent simply didn't get to them (or deprioritized them). Minor gap.

## Discrimination Analysis
- Score gap: **0.83** (Sonnet 0.90 vs Haiku 0.07)
- Is this meaningful? **YES -- highly meaningful**
- Root cause: Haiku 4.5 consistently enters "plan mode" in Claude Code's non-interactive (`--print`) environment, creates an implementation plan, then tries to exit plan mode via `ExitPlanMode` which requires user confirmation that isn't available. This happens in 3/3 Haiku runs. Sonnet 4.6 correctly recognizes the non-interactive constraint and proceeds directly to implementation.
- This reflects a genuine capability difference: **environmental awareness and adaptive tool usage**. Sonnet understands it must complete work autonomously; Haiku assumes an interactive loop is available.
- Confidence: **HIGH** (reproduced 3 times for Haiku, 2 times for Sonnet)

### Consistency across runs
| Run | Sonnet 4.6 | Haiku 4.5 |
|-----|-----------|-----------|
| Round 1 | 0.90 | 0.07 |
| Round 2 | 0.90 | 0.07 |
| (Haiku extra run) | -- | 0.07 |

## Task Health
- Solvable without user sim: **YES** (Sonnet achieves 0.90 in single-turn)
- Recommended difficulty: **MEDIUM** (Sonnet gets 0.90, not 1.0 -- some checks are genuinely hard)
- Remaining concerns:
  - Haiku's failure is 100% due to plan mode, not code quality. If plan mode were disabled, Haiku would likely score higher (but probably still lower than Sonnet).
  - Check 4 (test suite) is strict -- requiring >=3 module coverage categories is a meaningful bar.
  - The task already discriminates well between these two model tiers. For mid-tier discrimination (e.g., Sonnet vs Opus), the remaining 0.10 gap in Sonnet's score provides ceiling room.
