# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (P2P weight: 10%)
- All F2P tests fail on base: YES
- Only Check 9 (existing tests pass) scores on unmodified base commit

## Agent Results (Round 1 = Final)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 11 modified + 14 new | Complete 5-step implementation; `generic_lang()` registers via `registry_state._registry` (returns None); proper `langs` CLI command |
| Haiku 4.5 | **0.83** | 7 modified + 13 new | 4/5 steps completed; `generic_lang()` returns class (scoping bug prevents instantiation); no `langs` CLI command |

## Per-Check Breakdown

| Check | Weight | Sonnet 4.6 | Haiku 4.5 | Notes |
|-------|--------|-----------|-----------|-------|
| 1: register_detector() | 0.10 | PASS (0.10) | PASS (0.10) | Both implemented correctly |
| 2: register_scoring_policy() | 0.10 | PASS (0.10) | PASS (0.10) | Both implemented correctly |
| 3: E2E generic_lang | 0.20 | 5/5 (0.20) | 2/5 (0.08) | Sonnet: proper LangConfig via get_lang(); Haiku: returns class (not LangConfig), no phases/security |
| 4: FixerConfig | 0.10 | PASS (0.10) | PASS (0.10) | Sonnet via Strategy 3 (plugin); Haiku via Strategy 2 (_make_generic_fixer) |
| 5: Agent test file | 0.10 | 23/23 (0.10) | 21/21 (0.10) | Both wrote quality test files |
| 6: Shared phases | 0.10 | PASS (0.10) | PASS (0.10) | Both added security + subjective + duplicates |
| 7: DETECTOR_TOOLS refresh | 0.05 | PASS (0.05) | PASS (0.05) | Both implemented auto-refresh via callback |
| 8: Langs command | 0.05 | PASS (0.05) | FAIL (0.00) | Haiku didn't implement Step 5 (langs CLI) |
| 9: Existing tests P2P | 0.10 | PASS (0.10) | PASS (0.10) | Sonnet: 2054 pass; Haiku: 2053 pass |
| 10: Lang plugins load | 0.10 | 5/5 (0.10) | 5/5 (0.10) | Both created 11 language plugins |

## Test Refinements
- **No changes were needed to test.sh, Dockerfile, or task.toml**
- The existing test suite already had robust Strategy B fallbacks (using `get_lang()`) for Checks 3, 4, 6, and 10
- Check 9's pipe bug (from original audit) was already fixed — redirects to file, captures exit code properly
- Check 3's signature probing was already enhanced with `inspect.signature()` + multiple fallback strategies
- All 10 checks are reachable (no broken tests)

## Discrimination Analysis
- **Score gap: 0.17** (Sonnet 1.00 vs Haiku 0.83)
- **Is this meaningful? YES** — The gap reflects two genuine quality differences:
  1. **Architecture integration (Check 3, 0.12 delta)**: Sonnet's `generic_lang()` properly integrates with the existing discovery/resolution system by registering in `registry_state._registry` and returning None. The test's fallback to `get_lang()` then returns a full LangConfig with all phases. Haiku's factory returns a class that isn't a LangConfig instance, has a scoping bug preventing instantiation, and doesn't fall through to the proper resolution path. This reflects Sonnet's better understanding of the existing codebase architecture.
  2. **Task completeness (Check 8, 0.05 delta)**: Sonnet implemented all 5 steps including the `langs` CLI command with parser wiring and registry registration. Haiku stopped after Step 4, not implementing the user-facing command. This reflects Sonnet's better ability to complete complex multi-step tasks end-to-end.
- **Confidence: HIGH** — The differences are structural (architecture choices, completeness), not accidental (pattern matching, lucky formatting).

## Task Health
- **Solvable without user sim: YES** — Both agents completed 83-100% of the task in single-turn mode without any user simulator messages. The "Work incrementally... STOP" instruction in the prompt does not prevent single-turn completion.
- **Recommended difficulty: HARD** — 5-step multi-file feature implementation requiring understanding of existing framework architecture (registry, discovery, resolution, scoring, narrative systems).
- **Remaining concerns:**
  - Sonnet achieving 1.0 means the ceiling may be too easy for the strongest models — could add harder behavioral checks (e.g., verify scoring actually produces non-zero dimension scores, verify narrative generates actions)
  - Both agents created `plugin_*.py` files (single-file convention) rather than `go/__init__.py` packages — the discovery system handles both, so this is a valid approach
  - Agent runtime: Sonnet ~13 min, Haiku ~9 min — well within the 30-min timeout
