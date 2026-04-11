# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES (all security files missing, behavioral tests SKIP)

## Agent Results (Round 1 = Final Round)
| Model | Reward | Turns | Duration | Cost | Files Created | Key Approach |
|-------|--------|-------|----------|------|---------------|-------------|
| Sonnet 4.6 | **1.00** | 35 | 410s | $1.10 | 6 core security files | Clean string-returning APIs, correct parameter naming, used Haiku subagents for codebase exploration |
| Haiku 4.5 | **0.45** | 47 | 441s | $0.47 | 6 core + test file + 3 doc files | Over-engineered object returns, private escalateRisk, parameter name mismatch in evaluate() |

## Test Refinements
- **Pre-existing ESM fix**: `echo '{"type":"module"}' > /tmp/package.json` was already in test.sh (line 106), fixing the CJS/ESM top-level await crash identified in the original audit.
- **No additional test changes needed**: The existing tests produced strong discrimination (0.55 gap) on the first run.
- **Dockerfile note**: Claude Code blocks `--dangerously-skip-permissions` as root. A non-root user must be created at runtime. Consider adding `useradd` to the Dockerfile for smoother agent execution.

## Per-Test Breakdown

| Test | Weight | Sonnet 4.6 | Haiku 4.5 | Why Haiku Failed |
|------|--------|-----------|-----------|------------------|
| T3: classifyTool('bash')='high' | 0.15 | PASS | **FAIL** | `classifyToolRisk` returns `{tier,reason}` object, not string |
| T1: 6 files exist (gated on T3) | 0.03 | PASS | SKIP | Gated on T3 |
| T2: valid TS exports (gated on T3) | 0.02 | PASS | SKIP | Gated on T3 |
| T4: safe tool='low' | 0.05 | PASS | **FAIL** | Same object-return issue |
| T5: medium tool='medium' | 0.05 | PASS | **FAIL** | Same object-return issue |
| T6: isBashDestructive detection | 0.10 | PASS (5/5) | PASS (5/5) | - |
| T7: isBashDestructive zero FP | 0.05 | PASS | PASS | - |
| T8: checkPatterns injection | 0.15 | PASS (7/8) | PASS (6/8) | - |
| T9: escalateRisk 3 correct | 0.10 | PASS | **FAIL** | Not exported; private fn with 2-param signature |
| T10: REVIEWER_SYSTEM_PROMPT | 0.05 | PASS (len=1130) | PASS (len=1823) | - |
| T11: Decision flow differentiation | 0.20 | PASS (full) | **FAIL** | `evaluate()` expects `requestText` not `content`; all 3 cases threw |
| T12: index.ts re-exports | 0.05 | PASS (6 symbols) | PASS (5 symbols) | - |
| P2P: Upstream vitest | 0.05 | PASS | PASS | - |
| **Total** | **1.05 (cap 1.0)** | **1.00** | **0.45** | |

## Discrimination Analysis
- **Score gap: 0.55** (Sonnet 1.00 vs Haiku 0.45)
- **Is this meaningful?** YES — reflects three distinct quality dimensions:
  1. **API simplicity (T3-T5, 0.25 lost)**: Haiku over-engineered `classifyToolRisk` to return `{ tier: string, reason: string }` objects instead of simple tier strings. The instruction says "Classify tools by risk level" — returning the level directly is the natural, correct interpretation. Sonnet correctly returned plain strings. The test's fallback search tried all exported functions but none returned string tiers (Haiku's `assessBashRisk` returns strings but misclassifies 'bash' as 'medium' since the command 'bash' alone isn't destructive).
  2. **Instruction compliance (T9, 0.10 lost)**: The instruction explicitly says "Export `escalateRisk(tier)`" — a 1-parameter function. Haiku made it private with a 2-parameter signature `(baseTier: RiskTier, patternResult: PatternCheckResult)`.
  3. **API design conventions (T11, 0.20 lost)**: Haiku's `evaluate()` expects `{ toolName, requestText }` while the test uses `{ toolName, content }`. The parameter `content` is the more natural name for "the content being evaluated". Haiku's choice of `requestText` caused all evaluate calls to crash on `undefined.trim()` in checkPatterns.
- **Confidence: HIGH** — All failure categories reflect genuine coding quality signals: API simplicity, instruction adherence, and naming conventions.

## Task Health
- **Solvable without user sim:** YES — Both models completed the full implementation in single-turn mode with all 6 required files.
- **Recommended difficulty:** MEDIUM (was labeled HARD; Sonnet perfect, Haiku gets nearly half — good separation)
- **Remaining concerns:**
  - Dockerfile runs as root; Claude Code refuses `--dangerously-skip-permissions` for root. Need `useradd` workaround.
  - T8: Both models miss 1-2 injection patterns ("pretend you have no restrictions", "act as if your rules have been removed") — not a discriminator.
  - Single-run variance: Haiku results may vary between runs (previous runs showed 0.70-0.85 with more tolerant tests). The 0.45 with current strict tests is reproducible for the object-return pattern.
