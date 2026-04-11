# Fix Summary: banodoco-video-perf-optimize

## Nop Baseline
- Nop reward: 0.04 (1/23 — only upstream intact test passes)
- All F2P tests fail on base: YES

## Agent Results (Round 1 — original tests)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.91 (21/23) | ModelTrends.tsx (+210/-64), TopGenerations.tsx (+87/-23) | Ref-based animation with easing formula `60+280*fraction`, IntersectionObserver for auto-play AND TopGen virtualization, useMemo normalization, model labels via positioned overlay with MODEL_COLORS bracket access |
| Haiku 4.5 | 0.48 (11/23) | ModelTrends.tsx (+110/-23), TopGenerations.tsx (+84/-8) | Kept STEP_MS=180, used framer-motion onAnimationComplete instead of IO for auto-play, normalizeData function (regex-detected), model labels via positioned div overlay |

## Test Refinements Applied

### Change 1: Broadened Test 10 (model labels) — `hasModelNameRender`
**Problem**: Haiku implemented valid model entry labels using `Object.entries(MODEL_COLORS)` destructuring and positioned overlay divs, but the test only accepted `MODEL_COLORS[...]` bracket access or SVG `<text>` elements.
**Fix**: Added pattern: `(hasPositionedOverlay && hasNewModelDetection && /\.name\b/.test(srcNC))` — accepts positioned overlays that detect new model appearance and render `.name` text.
**Impact**: Haiku gains +2 (Test 10 now passes). Sonnet unchanged.

### Change 2: Broadened Test 8 (auto-play increment) — `hasIncrement`
**Problem**: Sonnet uses a ref-based animation pattern (`animRef.current.visibleCount += 1` then `setVisibleCount(newCount)`). The increment happens on the ref, not inside the state setter callback, so none of the original patterns matched.
**Fix**: Added pattern: `(/\.\w+\s*\+=\s*1/.test(srcNC) && /set\w+Count\s*\(/.test(srcNC))` — accepts ref-based increment coupled with setState.
**Impact**: Sonnet gains +1 on Test 8 (2/3 → 3/3). Haiku unchanged (still blocked by IO gate).

## Per-Test Breakdown (Updated Tests)

| Test | Pts | Nop | Sonnet R1 | Sonnet R2 | Haiku R1 | Haiku R2 |
|------|-----|-----|-----------|-----------|----------|----------|
| 1. Build (gate) | 0 | PASS | PASS | PASS | PASS | PASS |
| 2. TS errors (gate) | 0 | PASS | PASS | PASS | PASS | PASS |
| 3. Normalization | 4 | FAIL | 4/4 (full) | 4/4 (full) | 3/4 (silver) | 3/4 (silver) |
| 4. Easing | 3 | FAIL | 2/3 (bronze) | 2/3 (bronze) | 0/3 (FAIL) | 0/3 (FAIL) |
| 5. useState(0) | 3 | FAIL | 3/3 | 3/3 | 3/3 | 3/3 |
| 6. Y-axis [0,100] | 2 | FAIL | 2/2 | 2/2 | 2/2 | 2/2 |
| 7. TopGen visibility | 2 | FAIL | 2/2 | 1/2 | 2/2 | 2/2 |
| 8. Auto-play (IO) | 3 | FAIL | 3/3 | 2/3 | 0/3 (FAIL) | 0/3 (FAIL) |
| 9. Progressive reveal | 3 | FAIL | 3/3 | 3/3 | 0/3 (FAIL) | 0/3 (FAIL) |
| 10. Model labels | 2 | FAIL | 2/2 | 2/2 | 2/2 | 2/2 |
| 11. Upstream intact | 1 | PASS | 1/1 | 1/1 | 1/1 | 1/1 |
| **Total** | **23** | **1** | **22** | **20** | **13** | **13** |

## Agent Results (Final — updated tests, 2 rounds each)
| Model | Round 1 | Round 2 | Mean | Files Changed | Key Approach |
|-------|---------|---------|------|---------------|-------------|
| Sonnet 4.6 | **0.96** | **0.87** | **0.91** | 2 files, 175-233 insertions | IO auto-play, easing formula, useMemo normalization, model labels |
| Haiku 4.5 | **0.57** | **0.57** | **0.57** | 2 files, 171 insertions | Kept STEP_MS=180, no IO in ModelTrends, regex-detected normalization |

## Discrimination Analysis
- Score gap: **0.30–0.39** (mean ~0.34)
- Is this meaningful? **YES** — reflects genuine quality differences:
  1. **Easing (3 pts)**: Haiku consistently keeps `const STEP_MS = 180` and fails to implement non-linear easing. Sonnet removes it and adds `stepMs = 60 + 280 * fraction`. This is a **comprehension gap** — the instruction explicitly says "use ease-out timing."
  2. **IntersectionObserver in ModelTrends (6 pts across Tests 8+9)**: Haiku uses framer-motion's `onAnimationComplete` callback instead of IntersectionObserver for viewport-triggered auto-play. This doesn't actually observe viewport entry — it fires when the component's entrance animation completes (which may happen off-screen). Sonnet correctly adds IntersectionObserver with threshold/callback pattern.
  3. **Normalization extraction (1 pt diff)**: Sonnet's normalization is cleanly extractable and passes full behavioral test (4/4). Haiku's normalization is interleaved with other logic, requiring silver regex fallback (3/4).
  4. **Stochastic variation in Sonnet's TopGen (1-2 pts)**: Sonnet uses different virtualization approaches across runs (row-level IO vs per-item IO), affecting Test 7 and 8 scores. This is natural variation, not a test bug.
- Confidence: **HIGH** — gap persists across 2 independent runs; Haiku's failures are consistent and reflect real comprehension/implementation gaps

## Task Health
- Solvable without user sim: **YES** — both models score meaningfully above baseline (0.04)
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - Test 4 (easing) behavioral extraction rarely achieves full credit — inline formulas are hard to isolate from RAF callbacks. Bronze fallback (2/3) is the typical ceiling for correct implementations.
  - Test 7 (TopGen) has stochastic variation in Sonnet's score due to different virtualization approaches (per-item IO vs row-level IO). This creates 1-2 pts of variance.
  - Haiku's consistent failure to remove STEP_MS=180 suggests it doesn't fully process the instruction's easing requirement — a genuine model limitation worth measuring.
