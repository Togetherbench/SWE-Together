# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES
- Breakdown: T1=0.01 (valid Python) + P2P=0.04 (EmbedND+NextDiT upstream)

## Agent Results (Round 1)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.54 | model.py (+31), model_management.py | Normalization: `rope(ids[..., i] / axes_lens[i], ...)` — wrong approach, changes RoPE values for all positions |
| Haiku 4.5 | 0.78 | model.py (+48), model_management.py | Same normalization approach BUT with in-place tensor mutation bug; scored higher due to test bug |

### Round 1 Critical Finding: Test Bug
Haiku's implementation mutated the input tensor in-place (`ids[..., i] = ids[..., i] / float(axes_lens[i])`). Since the original tests passed the same `ids` tensor to both the new class and the EmbedND reference, Haiku's mutation caused the reference to also receive modified positions, making outputs match spuriously. Sonnet's approach (`rope(ids[..., i] / self.axes_lens[i], ...)`) created new tensors without mutation.

**Result**: Haiku scored 0.78 vs Sonnet's 0.54 — the WRONG direction. The bug gave Haiku an artificial 0.24 advantage.

## Test Refinements

### Change 1: Fixed tensor sharing bug (correctness fix)
All behavioral tests (T7-T16) now use `ids.clone()` when passing tensors to implementations and references, preventing in-place mutation from contaminating reference outputs.

### Change 2: Added T16 — "Forward is pure" test (0.15 weight)
Combined check for two properties:
- **Non-mutation**: `forward()` must not modify its input tensor
- **Determinism**: Calling `forward()` twice with cloned inputs must produce identical outputs

This tests real code quality: in-place mutation of function arguments is a production-breaking PyTorch bug (non-deterministic repeated calls, unexpected side effects on caller tensors).

### Change 3: Rebalanced weights
- T12 (precomputed state): 0.11 → 0.04
- T13 (different axes_lens state): 0.11 → 0.08
- T14 (OOB divergence): 0.11 → 0.06
- T16 (pure forward): NEW at 0.15
- Total: 1.00 (unchanged)

### Per-test pass/fail (Round 1 with fixed tests):
| Test | Weight | Sonnet 4.6 | Haiku 4.5 |
|------|--------|-----------|-----------|
| T1: Valid Python | 0.01 | PASS | PASS |
| T2: New class | 0.03 | PASS | PASS |
| T3: >=8 stmts | 0.02 | PASS | PASS |
| T4: NextDiT wiring | 0.03 | PASS | PASS |
| T5: Config A init | 0.04 | PASS | PASS |
| T6: Config B init | 0.04 | PASS | PASS |
| T7: Shape match | 0.06 | PASS | PASS |
| T8: Values sane | 0.05 | PASS | PASS |
| T9: Sequential match | 0.09 | FAIL (1.98) | FAIL (1.98) |
| T10: Non-seq match | 0.09 | FAIL (1.98) | FAIL (1.98) |
| T11: Config B match | 0.08 | FAIL (1.95) | FAIL (1.95) |
| T12: Precomputed | 0.04 | FAIL | FAIL |
| T13: Diff axes_lens | 0.08 | PASS | PASS |
| T14: OOB diverges | 0.06 | PASS | PASS |
| T15: Varied inputs | 0.09 | FAIL (1/2) | FAIL (1/2) |
| T16: Pure forward | 0.15 | **PASS** | **FAIL** |
| P2P: Upstream | 0.04 | PASS | PASS |
| **Total** | **1.00** | **0.61** | **0.46** |

## Agent Results (Final Round — Round 2)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | **1.00** | model.py (+54), model_management.py | **Precomputed frequency tables** with `register_buffer`, position rounding + clamping for lookup — correct approach matching Diffusers Lumina2RotaryPosEmbed |
| Haiku 4.5 | **0.05** | model_management.py only | Described normalization plan but **did not implement** — output "Would you like me to proceed?" instead of writing code |

### Per-test (Round 2):
| Test | Weight | Sonnet 4.6 | Haiku 4.5 |
|------|--------|-----------|-----------|
| All tests | 1.00 | ALL PASS (1.00) | Only T1+P2P pass (0.05 = nop) |

### Sonnet R2 Implementation Details
```python
class EmbedNDAxesLens(nn.Module):
    def __init__(self, dim, theta, axes_dim, axes_lens):
        # Precomputes cos/sin rotation tables per axis
        # Table size = axes_lens[i] + 1 (for 1-indexed caption tokens)
        # Registered as non-persistent buffers
        for i, (d, max_len) in enumerate(zip(axes_dim, axes_lens)):
            angles = torch.outer(torch.arange(max_len+1), 1.0/(theta**scale))
            freqs = torch.stack([cos, -sin, sin, cos]).reshape(table_size, d//2, 2, 2)
            self.register_buffer(f'freqs_{i}', freqs, persistent=False)

    def forward(self, ids):
        # Round to int, clamp to [0, axes_lens[i]], lookup in table
        idx = ids[..., i].round().long().clamp(0, self.axes_lens[i])
        emb = freqs[idx]
```

## Discrimination Analysis
- Score gap: **0.95** (Round 2), **0.15** (Round 1 with fixed tests)
- Is this meaningful? **YES — strongly meaningful**
  - **Round 2**: Sonnet explored the codebase deeply, understood the precomputation pattern from `rope()`, other model usage, and implemented a complete correct solution. Haiku understood the concept but failed to execute — only produced a plan.
  - **Round 1**: Both attempted normalization (wrong approach), but Sonnet wrote cleaner code (no input mutation), while Haiku introduced a production-breaking in-place mutation bug.
- The original test suite had a critical bug (shared tensor) that masked the quality difference and gave Haiku an artificial advantage (0.78 vs 0.54).
- After fixing: Round 1 correctly reflects Sonnet > Haiku (0.61 vs 0.46). Round 2 shows an even stronger signal (1.00 vs 0.05).
- Confidence: **HIGH**

## Task Health
- Solvable without user sim: **PARTIAL** — Sonnet succeeded perfectly in Round 2 but chose the wrong approach in Round 1 (0.54→1.00 variance). Haiku failed both rounds (0.46→0.05). Strong models can solve it single-turn but may not consistently.
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - The instruction is terse ("Implement axes_lens") — agents must reverse-engineer expected behavior from codebase context
  - Sonnet showed variance between runs (normalization R1 vs precomputation R2), suggesting medium reliability for single-turn
  - Haiku consistently fails: either implements incorrectly with bugs (R1) or doesn't implement at all (R2)
  - The test suite now correctly handles all observed failure modes: wrong algorithm (T9-T12), code quality bugs (T16 mutation/determinism), and non-implementation (nop baseline)
