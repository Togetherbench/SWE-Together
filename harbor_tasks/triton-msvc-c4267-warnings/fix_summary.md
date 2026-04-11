# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (structural T1-T5 = 0.025, P2P T18 = 0.025)
- All F2P tests fail on base: YES (all behavioral + structural fix tests fail)

## Test Changes Made

### 1. Fix 1 behavioral: Use-site local variable pattern support
**Problem**: When an agent fixes the narrowing by introducing a local variable
(`unsigned idxU = static_cast<unsigned>(idx)`) and passing `idxU` to
lowerBarrier/lowerCallOp, the test extracted `idxU` as the expression but
couldn't compile it because `idxU` is undefined in the synthetic test program.

**Fix**: Added extraction step 2b that:
- Scans the lambda body for direct cast expressions of `idx` to unsigned types
- Resolves simple identifier args (e.g. `idxU`) back to their RHS definitions
  (e.g. `static_cast<unsigned>(idx)`) by searching for `unsigned VAR = EXPR;` patterns
- Outputs resolved expressions to `/tmp/fix1_cast_exprs.txt`
- `try_fix1` also tries these cast expressions

This correctly handles both capture-site and use-site fix approaches.

### 2. CLAUDE.md development guidelines
Added a CLAUDE.md to the triton workspace (via Dockerfile) with general C++
development guidance:
- Cross-platform build context (Linux + Windows MSVC)
- Guidance to grep the entire file for similar patterns when fixing narrowing warnings
- Note that MSVC error logs may only surface one instantiation while the same
  root cause appears at multiple call sites

This creates consistent discrimination: agents that follow the guidance and
search thoroughly find all narrowing sites; agents that stop after the obvious
fix miss additional sites.

## Agent Results (Round 1 — no CLAUDE.md)

| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.55 | 1 line | C-style cast at capture site: `idx = (unsigned)idx` |
| Haiku 4.5 | 0.07 | 4 lines | Local var `idxU` + use-site casts (test couldn't detect) |

Note: Haiku's 0.07 was a false negative — its fix was valid but the test
couldn't handle the intermediate variable pattern. After test fix, both scored 0.55.

## Agent Results (Round 2 — no CLAUDE.md, test fixed)

| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| Sonnet 4.6 | 0.55 | 1 line | `static_cast<unsigned>(idx)` at capture site |
| Haiku 4.5 | 0.55 | 2 lines | Inline `static_cast<unsigned>(idx)` at both call sites |

No discrimination — both find Fix 1 only, miss Fix 2.

## Agent Results (Final — with CLAUDE.md, 2 consistent runs)

| Model | Reward | Turns | Cost | Lines Changed | Key Approach |
|-------|--------|-------|------|---------------|-------------|
| Sonnet 4.6 | 0.55 | 8-14 | $0.13-0.21 | 1 | Capture-site cast only; dismissed other sites |
| Haiku 4.5 | 1.00 | 14-16 | $0.12 | 6-7 | Fixed ALL narrowing sites (4-6 locations) |

### Per-test breakdown (final round)

| Test | Weight | Sonnet | Haiku |
|------|--------|--------|-------|
| T1-T5 (structural) | 0.025 | PASS | PASS |
| T6-T10 (Fix1 behavioral) | 0.48 | PASS | PASS |
| T11 (Fix1 structural) | 0.02 | PASS | PASS |
| T12-T16 (Fix2 behavioral) | 0.48 | FAIL | PASS |
| T17 (Fix2 structural) | 0.02 | FAIL | PASS |
| T18 (P2P) | 0.025 | PASS | PASS |

### Haiku's complete fix (6 narrowing sites):
1. `lowerBarrier(op, numWarps, static_cast<unsigned>(idx), ...)` — Fix 1 use-site
2. `lowerCallOp(callOp, numWarps, static_cast<unsigned>(idx), ...)` — Fix 1 use-site
3. `op->getResult(static_cast<unsigned>(i))` — Fix 2
4. `toErase.set(static_cast<unsigned>(i))` — Additional narrowing site
5. `region->getArgument(static_cast<unsigned>(i))` — Additional narrowing site
6. `LLVM::GEPArg(static_cast<int32_t>(j))` — Additional narrowing site

### Sonnet's reasoning error
Sonnet investigated the other sites but dismissed them with incorrect reasoning:
> "The other enumerate usages (lines 246, 498) pass size_t to function arguments,
> which triggers C4244 (suppressed by /wd4244 in the compile flags)"

This is **incorrect**: the error is C4267 (size_t narrowing), not C4244. The MSVC
flags include `/wd4244` but NOT `/wd4267`. Sonnet confused the two warning codes
and incorrectly rationalized that the other sites were already handled.

## Discrimination Analysis
- Score gap: **0.45** (Haiku 1.0 vs Sonnet 0.55)
- Is this meaningful? **YES** — reflects a genuine behavioral difference:
  - **Haiku**: More responsive to repo guidelines (CLAUDE.md), systematically searches
    for all similar patterns, fixes everything without over-analyzing
  - **Sonnet**: More "confident" — fixes the obvious site, investigates others but
    makes an incorrect analysis (C4244 vs C4267 confusion) and dismisses them
- Consistent across 2 runs with CLAUDE.md (iterations 3 and 4)
- Direction: **Haiku > Sonnet** (unexpected but genuine)
- Confidence: **HIGH** for the behavioral difference, MEDIUM for generalizability

### Why the weaker model scores higher
The CLAUDE.md guidance to "grep the entire file for similar patterns" effectively
tests instruction-following thoroughness rather than raw analytical ability. Haiku
follows this guidance literally and fixes every `size_t → unsigned` site. Sonnet's
stronger analytical capabilities actually work against it: it over-reasons about
which warnings are suppressed (incorrectly) and stops early.

This is a known pattern in capability evaluation: "overthinking" can cause stronger
models to rationalize away correct solutions that simpler models would have applied.

## Task Health
- Solvable without user sim: **PARTIAL**
  - Fix 1: YES (both models find it consistently)
  - Fix 2: Only with CLAUDE.md (Haiku) or user simulator redirect
  - Without CLAUDE.md: both score 0.55, no discrimination
- Recommended difficulty: **MEDIUM**
- Remaining concerns:
  - Without CLAUDE.md, task produces no discrimination in single-turn
  - With CLAUDE.md, discrimination direction is Haiku > Sonnet (counterintuitive)
  - Originally designed for multi-turn with user simulator for best discrimination
  - The CLAUDE.md tests instruction-following + thoroughness, not depth of analysis
