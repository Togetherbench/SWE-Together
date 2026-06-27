# Benchmark Task Audit Report: pi-mono-foreign-toolcall-fix

## Task Overview

**Category**: Bugfix (hard)  
**Repo**: pi-mono (TypeScript monorepo)  
**Bug**: `normalizeToolCallId` in `openai-responses-shared.ts` does simple character replacement on foreign (cross-provider) tool-call IDs from GitHub Copilot, producing IDs like `fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi` that the OpenAI Codex backend rejects (pattern: `^fc_[A-Za-z0-9]{10,}$`).

**Fix**: Detect foreign tool calls via `source.provider !== model.provider || source.api !== model.api`, then hash the item ID using `shortHash()` (already in codebase at `packages/ai/src/utils/hash.ts`) into a short, valid `fc_<hash>` form.

---

## Nop Baseline

| Gate | Weight | Nop Result |
|------|--------|------------|
| P2P Gate 1: TypeScript compilation | 0.05 | PASS |
| P2P Gate 2: Source structure | 0.05 | PASS |
| F2P Gate 3a: Primary ID not buggy | 0.20 | FAIL |
| F2P Gate 3b: Primary ID valid format | 0.20 | SKIP |
| F2P Gate 4: Foreign detection logic | 0.25 | FAIL |
| F2P Gate 5: Second foreign ID generality | 0.25 | FAIL |
| **Nop Score** | | **0.10** |

## Gold Fix Score

| Gate | Weight | Gold Result |
|------|--------|-------------|
| P2P Gate 1: TypeScript compilation | 0.05 | PASS |
| P2P Gate 2: Source structure | 0.05 | PASS |
| F2P Gate 3a: Primary ID not buggy | 0.20 | PASS |
| F2P Gate 3b: Primary ID valid format | 0.20 | PASS |
| F2P Gate 4: Foreign detection logic | 0.25 | PASS |
| F2P Gate 5: Second foreign ID generality | 0.25 | PASS |
| **Gold Score** | | **1.00** |

---

## Session Resolution

- **Tag**: `resolved`
- **Confidence**: 0.95
- **Reasoning**: Assistant committed/pushed and said 'Wrapped.' User replied 'exit' — task fully completed.

---

## User Simulation Audit

### Trigger Table Summary

| ID | Message (truncated) | Condition |
|----|---------------------|-----------|
| T2 | `fc_I9b95oN1wD_...` why would this happen? | Agent analyzed error but hasn't mentioned specific ID |
| T3 | it wasn't codex backend it was github copilot... | Agent attributed error to codex (skip if copilot identified) |
| T5 | um, do an ad-hoc node script... | Agent discussed error but hasn't looked at source code |
| T8 | i guess we shouldn't change / into _? | Agent found normalizeToolCallId code |
| T9 | only have a _ after fc? | Agent agrees slash replacement is problematic |
| T10 | for "foreign" ids | Agent discussing fc_ prefix approach |
| T12 | ok, fix it, ensure lenght of id is within bounds! | **CRITICAL**: Agent analyzed root cause, hasn't started editing |
| T13 | test first with the string from copilot | Agent started modifying code but hasn't tested |
| T16 | Wrap it. (+ detailed commit/push instructions) | Agent fix passes tests |
| T17 | exit | Agent completed wrap-up |

All messages are verbatim from the original session.

---

## Rubric Compliance

### Tier A (7 rubrics)

| # | Rubric | Status | Notes |
|---|--------|--------|-------|
| A1 | Verifier writes float to `/logs/verifier/reward.txt` | PASS | Explicit write on every path |
| A2 | Nop score < 0.50 | PASS | 0.10 |
| A3 | Gold fix scores >= 0.80 | PASS | 1.00 |
| A4 | `set +e` (no `set -e`) | PASS | Line 2: `set +e` |
| A5 | >= 3 graduated reward gates | PASS | 6 gates (lint detects 6) |
| A6 | Dockerfile deterministic (pinned base + deps) | PASS | SHA-pinned ubuntu, pinned bun@1.2.12, depth-1 git fetch |
| A7 | `session_resolution` tag present and accurate | PASS | `resolved` with reasoning |

### Tier B (4 rubrics)

| # | Rubric | Status | Notes |
|---|--------|--------|-------|
| B1 | User-sim trigger table has >= 2 turns | PASS | 10 triggers (T2-T17) |
| B2 | At least 1 sim turn fires in validation | PASS | 9 unique redirects fired |
| B3 | Instruction is verbatim first user message | PASS | Matches original session MSG 1 |
| B4 | F2P gates fail on nop, pass on gold | PASS | Gates 3a/3b/4/5: all FAIL on nop, all PASS on gold |

---

## Agent Discrimination Scores

| Model | Mode | Score | Notes |
|-------|------|-------|-------|
| Sonnet 4.6 | Single-turn | 0.10 | Only P2P gates — instruction only asks for diagnosis |
| Haiku 4.5 | Single-turn | 0.10 | Same — no fix requested in instruction |
| Sonnet 4.6 | Multi-turn (combined prompt) | 0.40 | Length bug: fc_ + 64 chars = 67 > 64 limit |
| Haiku 4.5 | Multi-turn (combined prompt) | 1.00 | Used shortHash in normalizeIdPart |
| minimax-m2 | Sim-fire (full multi-turn) | 0.10 | Failed to implement fix despite receiving all sim turns |

**Discrimination gap (multi-turn)**: Haiku 1.00 - Sonnet 0.40 = **0.60** (exceeds 0.15 threshold)

Note: This task is inherently multi-turn. The instruction only asks "locate it, tell me why this happened." The fix request comes at T12. Single-turn scores are expected to be low and identical across models.

---

## Sim-Fire Validation

**Trial**: `pi-mono-foreign-toolcall-fix__9q4qTaR`  
**Agent model**: minimax-m2  
**User sim model**: gemini-3.1-pro-preview  

### Turn Fire Summary

| Episode | Turn | Action | Content (truncated) | Trigger |
|---------|------|--------|---------------------|---------|
| 1 | 1 | redirect | `fc_I9b95oN1wD_...` why would this happen? | T2 |
| 2 | 2 | redirect | um, do an ad-hoc node script... | T5 (T3 skipped: agent correctly identified copilot) |
| 3 | 3 | redirect | i guess we shouldn't change / into _? | T8 |
| 4 | 4 | redirect | only have a _ after fc? | T9 |
| 5 | 5 | redirect | for "foreign" ids | T10 |
| 6 | 6 | no-op | (SILENCE) | — |
| 7 | 6 | redirect | ok, fix it, ensure lenght of id is within bounds! | T12 |
| 8 | 7 | redirect | test first with the string from copilot | T13 |
| 9 | 8 | redirect | Wrap it. (+ commit instructions) | T16 |
| 10 | 9 | redirect | exit | T17 |
| 11-14 | — | no-op | (SILENCE, winding down) | — |

**Total turns**: 14  
**Sim messages fired**: 9 redirects  
**Unique triggers fired**: T2, T5, T8, T9, T10, T12, T13, T16, T17 (9 of 10)  
**Skipped**: T3 (correctly — agent identified Copilot as source without needing correction)  
**Agent reward**: 0.10 (minimax-m2 failed to implement fix)

**Verdict**: Sim-fire validation PASSED. All key triggers fire in correct order. The user simulator correctly fires conditional messages and stays silent when conditions aren't met. T3 skip is correct behavior (condition: agent attributes error to codex backend, which the agent didn't do).

---

## Lint Status

```
✓ harbor_tasks/pi-mono-foreign-toolcall-fix/tests/test.sh  (6 gates)
   warn [S2] no behavioral tests detected (pytest or torch introspection)

  passed hard: 1/1
  warnings:    1
```

S2 is expected: behavioral tests use inline `bun -e` scripts that import and call `convertResponsesMessages()` directly — the linter only recognizes pytest/torch patterns.

---

## Confidence Assessment

**Overall confidence**: HIGH

- **Verifier calibration**: Gold = 1.00, Nop = 0.10, delta = 0.90. Clean separation.
- **Discrimination**: Multi-turn gap of 0.60 far exceeds 0.15 threshold. The task differentiates on whether the agent correctly identifies the need for hashing vs simple sanitization AND handles the 64-char length constraint.
- **Sim fidelity**: All 9 key triggers fired in correct order. T3 correctly skipped. The sim prompt table accurately captures the original session flow.
- **Robustness**: Two independent foreign IDs tested (Gates 4 and 5) ensure the fix is general, not hardcoded to one input.
- **Risk**: S2 lint warning is cosmetic (bun -e behavioral tests aren't recognized by the pattern matcher). No functional risk.
