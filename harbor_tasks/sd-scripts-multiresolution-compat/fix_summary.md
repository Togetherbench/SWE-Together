# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES
- CANARY passes: YES (synthesis and git commit are working correctly)

## Environment Fixes (Verified)
The Dockerfile contains both critical fixes from the audit:
1. **Synthesis step** (lines 75-115): Patches `strategy_sd.py` with `multi_resolution=True` calls and `load_latents_from_disk` override
2. **Git commit step** (lines 129-131): Commits synthesis as "Enable multi-resolution dataset for SD1/SDXL" so agents see it via `git diff HEAD~`

Both verified working: CANARY test passes, `git diff HEAD~` shows the expected 1-file, 9-insertion diff in `library/strategy_sd.py`.

## Agent Results (Prior Run)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| GLM 5.1 | 0.80 | strategy_base.py (+56/-15) | Header-only reader + fallback in `is_disk_cached` but NOT in `load_latents_from_disk` |
| GLM 4.7 | 1.00 | strategy_base.py (+123/-25) | Header-only reader + fallback with shape validation in BOTH paths |

## Current Run: API Exhausted
- **Both GLM 5.1 and GLM 4.7**: Persistent 429 error — "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-04-15 13:30:05"
- Attempted 3+ retries per model with exponential backoff — all failed with same limit error
- This is a hard quota cap, not a transient rate limit

## Simulated Solution Validation
Since agents couldn't run, I validated test discrimination with manually crafted solutions:

| Solution | Reward | Description |
|----------|--------|-------------|
| Nop (unmodified) | 0.05 | Only P2P tests T8(1), T9(1), T10(3) pass |
| Mediocre (np.load fallback) | 0.57 | Basic fallback using np.load — passes T1-T4b, T8-T10, T12 but fails T5(22), T6(12), T7(5), T11(4) |
| Perfect (header-only) | 1.00 | Full header-only reader with zipfile + numpy.lib.format — all 13 tests pass |

### Simulated Per-Test Breakdown
| Test | Nop | Mediocre | Perfect | Points |
|------|-----|----------|---------|--------|
| CANARY | PASS | PASS | PASS | gate |
| T1: accept correct-shape legacy | SKIP | PASS | PASS | 13 |
| T2: load legacy npz | FAIL | PASS | PASS | 10 |
| T3: reject wrong-shape (is_cached) | SKIP | PASS | PASS | 5 |
| T4: reject wrong-shape (load) | SKIP | PASS | PASS | 12 |
| T4b: reject resolution-mismatch | SKIP | PASS | PASS | 8 |
| T5: truncated correct shape | SKIP | **FAIL** | PASS | 22 |
| T6: truncated wrong shape | SKIP | **FAIL** | PASS | 12 |
| T7: header reader method | FAIL | **FAIL** | PASS | 5 |
| T8: suffixed npz works | PASS | PASS | PASS | 1 |
| T9: suffixed preferred | PASS | PASS | PASS | 1 |
| T10: upstream tests | PASS | PASS | PASS | 3 |
| T11: zip/stream approach | FAIL | **FAIL** | PASS | 4 |
| T12: fallback enablement | FAIL | PASS | PASS | 4 |

## Test Refinements Applied (from prior run)
1. **T1**: Reduced from 18pts to 13pts (basic acceptance is less discriminating)
2. **T4**: Increased from 5pts to 12pts (load-path shape rejection is key quality differentiator)
3. **T4b (NEW)**: Added 8pt test for resolution-mismatch rejection in load path
4. **T5**: Reduced from 27pts to 22pts
5. **T6**: Reduced from 17pts to 12pts

### Rationale
The quality gap between models centers on `load_latents_from_disk` shape validation. Stronger agents validate shapes in BOTH `is_disk_cached_latents_expected` AND `load_latents_from_disk`; weaker agents only validate in the former. Reweighting amplifies this genuine correctness gap.

## Discrimination Analysis
- **Prior agent gap**: 0.20 (GLM 4.7: 1.00, GLM 5.1: 0.80)
- **Simulated gap (mediocre vs perfect)**: 0.43
- Is this meaningful? **YES** — The test suite discriminates on three axes:
  1. **Fallback implementation** (T1-T4b, 48pts): Does the agent add backward-compatible fallback?
  2. **Header-only reading** (T5-T7, 39pts): Does the agent use numpy.lib.format for metadata-only reads (as the instruction specifies)?
  3. **Structural quality** (T11-T12, 8pts): Does the implementation use proper zip/stream patterns?
- Confidence: **HIGH** — discrimination is based on genuine implementation quality, not accidental patterns

## NumPy API Note
NumPy 2.4.3 in the Docker image uses `read_array_header_1_0`/`read_array_header_2_0` (not the older `_read_array_header`). The instruction hint "You may use private API in numpy (e.g., `numpy.lib.format`)" is sufficient for agents to discover this. Test T11's `has_header_read` check correctly matches via the `"read_array_header"` substring.

## Task Health
- Solvable without user sim: **YES**
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - GLM API weekly/monthly limit exhaustion prevented fresh agent runs (resets 2026-04-15)
  - Prior run data confirms the tests work and discriminate (0.20 gap with real agents)
  - Simulated validation confirms broader discrimination potential (0.43 gap between np.load vs header-only approaches)
  - Nop baseline (0.05) is healthy — no false positives from unmodified code
