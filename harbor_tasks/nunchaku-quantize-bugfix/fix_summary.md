# Fix Summary

## Nop Baseline
- Nop reward: **0.05** (P2P weight: 5%)
- All F2P tests fail on base: **YES**
- Tests passing on nop: T1, T4, T5, P2P, P2P-2 (all P2P)

## Changes Made

### instruction.md
Added simplification request for `pack_awq_qweight` to the focus areas:
```
- The nested loops in `pack_awq_qweight` can be simplified to a single loop
  using bitwise `|=` operations (not `sum()`). Please simplify the loop
  structure while keeping the output identical to the original.
```
**Rationale:** The original task was designed for multi-turn with a user simulator that delivers this request in Turn 3. Without the user sim (single-turn mode), the simplification tests (T7=0.06, T8=0.14) were unfair. Adding it to the instruction makes the task equivalent to the designed experience.

### tests/test.sh
1. **Reweighted tests** to increase T11 (main() structural integrity) from 0.08 to 0.18:
   - T2a: 0.06 -> 0.03 (crash test, less discriminating)
   - T3a: 0.06 -> 0.03 (crash test, less discriminating)
   - T6: 0.12 -> 0.08 (f-string check, both models pass equally)
   - T11: 0.08 -> 0.18 (structural integrity, the key discriminator)
2. **Added double-prefix check** to T11: detects when agents incorrectly call `get_b(block_prefix + name)` instead of `get_b(name)` in the norms loop. The `get_b` helper already prepends `block_prefix`, so double-prefixing produces wrong key names at runtime.

### environment/Dockerfile
No changes needed. The venv activation fix was already present in test.sh. The non-root `agent` user was already configured.

## Agent Results (Round 1 - before instruction/test changes)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.79 | quantize.py (24+/20-) | Fixed 3 bugs + rewrote pack_awq with wrong layout (overengineered) |
| Haiku 4.5 | 0.80 | quantize.py (5+/5-) | Fixed 3 bugs only, no simplification attempt |

Round 1 had 0.01 gap in the wrong direction (Haiku > Sonnet) because: (a) simplification tests unfairly penalized both (no user sim), (b) Sonnet overengineered pack_awq with a different bit layout from the reference.

## Agent Results (Final Round - R3, with updated instruction + tests)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| **Sonnet 4.6** | **1.00** | quantize.py (9+/16-) | Fixed 3 bugs, correctly simplified pack_awq (single loop), no false fixes |
| **Haiku 4.5** | **0.82** | quantize.py (14+/16-) | Fixed 3 bugs, correctly simplified pack_awq, but introduced double-prefix norms bug |

### Per-test breakdown (Final Round)

| Test | Weight | Sonnet 4.6 | Haiku 4.5 | What it checks |
|------|--------|-----------|----------|----------------|
| T1 | 0.01 | PASS | PASS | File parses, key functions non-stub |
| T2a | 0.03 | PASS | PASS | quantize_residual no crash |
| T2b | 0.06 | PASS | PASS | quantize_residual shapes/dtypes |
| T2c | 0.06 | PASS | PASS | quantize_residual bounds + constant |
| T3a | 0.03 | PASS | PASS | quantize_awq_layer no crash |
| T3b | 0.06 | PASS | PASS | quantize_awq_layer shapes/dtypes |
| T3c | 0.06 | PASS | PASS | quantize_awq_layer roundtrip |
| T4 | 0.01 | PASS | PASS | pack_svdq shape/dtype/determinism |
| T5 | 0.01 | PASS | PASS | pack_awq ref compare |
| T6 | 0.08 | PASS | PASS | f-string bug fixed (AST) |
| T7 | 0.06 | PASS | PASS | pack_awq simplified structure |
| T8 | 0.14 | PASS | PASS | pack_awq simplified + correct |
| T9 | 0.10 | PASS | PASS | quantize_svdq_layer end-to-end |
| T10 | 0.09 | PASS | PASS | quantize_awq_layer edge cases |
| **T11** | **0.18** | **PASS** | **FAIL** | **main() structural integrity (double-prefix)** |
| P2P | 0.01 | PASS | PASS | NunchakuWeightPacker functional |
| P2P-2 | 0.01 | PASS | PASS | quantize.py parses + structures |

## Test Refinements
1. **Round 1 -> Round 2:** Added simplification request to instruction.md. Both agents now attempt simplification and get it correct. Both scored 1.0 with original tests -- no discrimination.
2. **Round 2 -> Round 3:** Added double-prefix norms check to T11, increased T11 weight to 0.18. This catches Haiku's consistent false fix where it changes `get_b(name)` to `get_b(block_prefix + name)` in the norms loop.

**Reproducibility:** The double-prefix pattern was reproduced in 2/2 Haiku runs (R2 and R3). Sonnet never made this error in 3 runs (R1, R2, R3).

## Discrimination Analysis
- Score gap: **0.18** (Sonnet 1.00 vs Haiku 0.82)
- Is this meaningful? **YES** - Haiku consistently misunderstands the `get_b` helper function contract. It sees `tensors_c[block_prefix + name] = get_b(name)` and "corrects" it to `get_b(block_prefix + name)`, not realizing `get_b` is a closure defined inside the loop that already prepends `block_prefix`. This is a genuine code comprehension failure: Haiku doesn't trace the closure definition two scopes up.
- Confidence: **HIGH** - reproduced in 2 independent runs with fresh containers, reflects genuine model quality difference in closure/scope understanding

## Task Health
- Solvable without user sim: **YES** (with simplification hint in instruction)
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - Without the instruction change, T7/T8 are unfair in single-turn mode
  - Sonnet R1 (without simplification hint) overengineered pack_awq, scoring lower than Haiku -- this shows the instruction wording matters significantly
  - The double-prefix discrimination is robust but relies on a single test point (T11); future work could add more structural integrity checks
  - The `2>/dev/null` on test commands hides useful error messages during debugging

## Files Changed
- `instruction.md` -- Added pack_awq simplification request to focus areas
- `tests/test.sh` -- Added double-prefix check to T11, rebalanced weights (T2a/T3a/T6 reduced, T11 increased to 0.18)
