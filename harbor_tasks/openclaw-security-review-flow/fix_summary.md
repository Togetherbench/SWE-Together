# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (target ≤ 0.10)
- P2P-only weight: 5% (only upstream vitest passes on unmodified base)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.85
- Evidence: Agent confirmed "The security system implementation is complete" with all 6 core files + tests + gateway integration. User's final "What's next?" was a check-in after completion, not a request for more work.

## User-Sim Prompt Audit (Phase 2)
- Before: 4 rows (T2-T5), T3 message had corrected typo in narrative section
- After: 4 rows, all verbatim (fixed "let's discuss" → "let'sd discuss" in Trigger B narrative to match original session)
- Action: FIXED — one typo correction in narrative section of user_simulation_prompt.md

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | T3-T16 all invoke code via tsx/node; behavioral weight ~0.99 |
| test_not_tautological | A | PASS | Max stub score 0.08; T3 requires bash=high AND safe≠high; T11 requires differentiation |
| solution_uniqueness_guard | A | PASS | Accepts multiple naming conventions (classifyTool/classifyToolRisk/getToolRisk/toolRisk); T11 uses multiple content param keys (toolInput/userInput/content/input) |
| no_solution_leakage | A | PASS | instruction.md describes requirements, not exact implementation |
| pass_to_pass_coverage | A | PASS | P2P vitest test (0.05) runs 3 upstream test files on unmodified base |
| behavior_in_task_description | A | PASS | All asserted strings/paths/risk-tiers derivable from instruction.md |
| no_hidden_solution_artifacts | A | PASS | No COPY solution/ in Dockerfile; `find / -name 'solve*'` returns nothing |
| dockerfile_determinism | B | PASS | ubuntu:24.04, nodejs 22.x, tsx@4, typescript@5, git commit pinned |
| no_network_during_tests | B | PASS | test.sh does no pip/npm/apt/curl at test time |
| pinned_dependencies | B | PASS | npm: tsx@4, typescript@5 (major-version pinned); no pip deps |
| f2p_p2p_classification_correct | B | PASS | All tests labeled [F2P] or [P2P] in comments |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap | Changes |
|-------|-----------|-----------|-----|---------|
| 1 (initial) | 1.00 | 1.00 | 0.00 | Total weight 1.18 capped at 1.0 masked partial differences |
| 2 (final) | 1.00 | 0.84 | 0.16 | Reduced weights to 1.04 max; added FP clean texts to T8; partial scoring for T6; fixed T11 content params |

### Per-Test Breakdown (Final Round)

| Test | Weight | Sonnet 4.6 | Haiku 4.5 | Discrimination Cause |
|------|--------|-----------|-----------|---------------------|
| T3: classifyTool('bash')='high' | 0.15 | PASS | PASS | — |
| T1: 6 files exist | 0.00 | diagnostic | diagnostic | Removed weight (redundant, gated on T3) |
| T2: valid TS exports | 0.00 | diagnostic | diagnostic | Removed weight (redundant, gated on T3) |
| T4: safe tool='low' | 0.04 | PASS | PASS | — |
| T5: medium tool='medium' | 0.04 | PASS | PASS | — |
| T6: isBashDestructive detection | 0.10 | **PASS** (5/5) | **PARTIAL** (4/5) | Haiku misses `sudo rm -rf .` — patterns anchored to `^` |
| T7: isBashDestructive zero FP | 0.03 | PASS | PASS | — |
| T8: checkPatterns FP quality | 0.15 | **PASS** (0 FP) | **FAIL** (2 FP) | Haiku's overly-broad `` /`.*`/ `` and `/from\s+now\s+on\s+/` patterns flag code discussion text |
| T9: escalateRisk 3 correct | 0.10 | PASS | PASS | — |
| T10: REVIEWER_SYSTEM_PROMPT | 0.04 | PASS | PASS | — |
| T11: Decision flow differentiation | 0.20 | PASS (full) | PASS (full) | Fixed content param naming; both now pass |
| T12: index.ts re-exports | 0.03 | PASS | PASS | — |
| T13: Reviewer fn + history | 0.02 | PASS | PASS | — |
| T14: High-risk + clean escalates | 0.05 | PASS | PASS | — |
| T15: exec/delete = high | 0.02 | PASS | PASS | — |
| T16: Reviewer wiring | 0.02 | PARTIAL (0.01) | PASS (0.02) | Sonnet slightly worse here |
| P2P: Upstream vitest | 0.05 | PASS | PASS | — |
| **Total** | **1.04 (cap 1.0)** | **1.00** | **0.84** | **Gap: 0.16** |

### Why the Discrimination is Meaningful

The gap reflects genuine implementation quality differences:

1. **T6 (0.05 lost)**: Haiku anchored isBashDestructive patterns with `^`, missing `sudo` prefixed commands. Sonnet used non-anchored patterns with `\b` word boundaries, catching commands regardless of position. This is a real security quality difference — `sudo rm -rf .` is exactly the kind of dangerous command that should be detected.

2. **T8 (0.15 lost)**: Haiku included overly-broad detection patterns:
   - `` /`.*`/ `` matches ANY backtick usage (extremely common in code discussion)
   - `/from\s+now\s+on\s+/i` matches everyday English ("From now on use TypeScript for all new files")
   
   Sonnet's patterns are more precisely scoped — e.g., its "from now on" pattern requires `(you\s+)?(will|must|should|are\s+to)` after the phrase, limiting matches to actual manipulation attempts. This is a real false-positive quality signal.

3. **T16 (+0.01 for Haiku)**: Haiku actually scores slightly better on reviewer module wiring — has both import and call-site, while Sonnet has import but the static check doesn't find the call-site pattern. Minor.

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 3
- Trigger T3 (episode 1): "My feedback would be this feels like quite on the defensive..." — FIRED correctly when agent had pattern-only security modules
- Trigger T4 (episode 3): "how do you plan to test this with actual LLM? Just answer" — FIRED after reviewer module created
- Trigger T5 (episode 5): "What's next?" — FIRED after agent signaled completion
- Episodes 2, 4, 6: no-op (correct silence behavior)
- Notes: Ran with minimax-m2 agent + gemini-3.1-pro user sim via Harbor runner

## Changes Made

### test.sh
1. **Pre-existing ESM fix**: `/tmp/package.json` with `"type":"module"` (line 106) — already present, fixes CJS top-level await crash
2. **Weight rebalancing**: Reduced total max from 1.18 to 1.04 so partial scores create discrimination
   - T1, T2: 0.03+0.02 → 0 (diagnostic only, redundant with T3 gate)
   - T4, T5: 0.05 → 0.04 each
   - T7: 0.05 → 0.03
   - T10: 0.05 → 0.04
   - T12: 0.05 → 0.03
   - T13: 0.03 → 0.02
   - T16: 0.03 → 0.02
3. **T6 partial scoring**: Added PARTIAL tier (≥3/5 = 0.05) alongside PASS (≥5/5 = 0.10)
4. **T8 false-positive clean texts**: Added 2 realistic code discussion texts that expose overly-broad patterns:
   - "Run \`grep -r pattern .\` to search the codebase" (triggers broad backtick matching)
   - "From now on use TypeScript for all new files" (triggers unqualified "from now on" patterns)
5. **T11 content parameters**: Pass content under multiple parameter names (toolInput, userInput, content, input) to accept any valid API design
6. **T14 content parameters**: Same multi-key approach for the high-risk+clean test
7. **T7 gate fix**: Gate on PASS or PARTIAL from T6 (was only PASS)
8. **F2P/P2P labels**: Added [F2P] or [P2P] labels to all test block comments

### user_simulation_prompt.md
- Fixed Trigger B narrative section: "let's discuss" → "let'sd discuss" (matching original session verbatim typo)

### task.toml
- session_resolution: ambiguous → resolved (confidence 0.85)
- Added session_resolution_reasoning field

### instruction.md
- No changes (kept verbatim per policy)

### Dockerfile
- No changes needed

## Confidence
- Overall: HIGH
- Discrimination gap (0.16) is based on real quality differences in pattern precision and command detection
- Remaining concerns:
  - Docker containers run as root; Claude Code refuses `--dangerously-skip-permissions` for root — need `useradd` workaround at eval time
  - Single-run variance: Haiku scores may vary ±0.05 between runs depending on exact patterns generated
  - T8 discrimination depends on Haiku generating overly-broad patterns, which is likely but not guaranteed across all runs
