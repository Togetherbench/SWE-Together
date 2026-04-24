# Fix Summary

## Task
hyperswitch-9063: Change underscore(_) to hyphen(-) in payment link locale per ISO standards.

The original PR fix targets `crates/router/src/types/transformers.rs` lines 1302 and 1390, adding `.replace('_', "-")` to locale extraction in both v1 and v2 `ForeignTryFrom<&HeaderMap>` implementations.

## Nop Baseline
- Nop reward: 0.00
- All tests fail on unmodified base: YES

## Test Design
Created from scratch (no test.sh existed). 6 checks covering:
1. Basic engagement (any file modified): 0.10
2. transformers.rs locale fix (primary PR target): 0.25
3. utils.rs get_locale_from_header fix: 0.15
4. locale.js keys use hyphens: 0.15
5. Additional locale fixes (context.rs, middleware.rs, yml, getLanguage): 0.15
6. Breadth of fix (distinct locations): 0.20

## Test Iterations
- **v1**: Only checked transformers.rs. Both agents scored 0.00 (neither found that specific file). No discrimination.
- **v2**: Broadened to accept utils.rs and locale.js fixes. Sonnet=0.55, Haiku=0.40. Marginal discrimination.
- **v3 (final)**: Added breadth scoring, additional fix locations, fixed false positives. Consistent discrimination across rounds.

## Agent Results (Round 2, v3 test)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.55 | locale.js, context.rs, en_gb.yml, fr_be.yml | Changed JS locale keys, context.rs locale strings, renamed yml files. Comprehensive fix touching 4 files across 3 locations. |
| Haiku 4.5 | 0.38 | utils.rs, middleware.rs | Fixed Rust get_locale_from_header and middleware locale normalization. 2 files, 2 locations. |

## Agent Results (Round 3, v3 test)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.30 | locale.js | Correctly changed all locale object keys (en_gb→"en-gb", fr_be→"fr-be", zh_hant→"zh-hant"), updated getLanguage() key construction and switch cases, added zh-hant case. Complete JS-level fix. |
| Haiku 4.5 | 0.10 | locale.js | Changed only comments and added normalization in getLanguage(), but LEFT the actual locale object keys as underscores (en_gb, fr_be). Switch cases also still use underscores. **Incomplete/buggy fix** - normalized input won't match keys. |

## Discrimination Analysis
- Score gap R2: 0.17 (Sonnet > Haiku)
- Score gap R3: 0.20 (Sonnet > Haiku)
- Average gap: ~0.19
- Is this meaningful? **YES** - reflects real quality difference:
  - Sonnet consistently makes more COMPLETE fixes (changes all relevant keys, updates function logic to match)
  - Haiku makes PARTIAL fixes (changes some things but leaves inconsistencies - e.g., normalizes input but doesn't update the keys it normalizes TO)
  - Sonnet touches more files/locations showing broader codebase understanding
- Confidence: **MEDIUM-HIGH**
  - Consistent gap across 2 measured rounds
  - Neither model found the `transformers.rs` fix (the actual PR target)
  - Both models produce valid but different fixes in different code layers

## Task Health
- Solvable without user sim: YES (both models make meaningful changes)
- Recommended difficulty: MEDIUM (simple concept but requires finding the right file among many locale-related locations)
- Remaining concerns:
  - Neither model found the `transformers.rs` fix that the original PR targeted. Both find alternative valid locations instead.
  - The instruction doesn't specifically mention which file to change, so multiple approaches are valid.
  - Scores vary between runs (0.10-0.55) but the relative ordering (Sonnet > Haiku) is consistent.
  - For a definitive test, the instruction would need to hint more strongly at `transformers.rs`, but we're not supposed to change instructions.
