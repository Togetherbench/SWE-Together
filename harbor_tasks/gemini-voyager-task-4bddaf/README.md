# Task: gemini-voyager-task-4bddaf

| Field | Value |
|-------|-------|
| Source session | `4bddaf90-966f-4caf-90c8-e01cfe2e9c26` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `8ff844f0e8d94184023077d21e4fd70cbe2db5cc` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 5 |

## Task Summary

Add section reordering to the Chrome extension popup. Each settings section card should have up/down arrow buttons that appear on hover, allowing users to customize the display order. The order must persist via `chrome.storage.sync`.

## User Simulator Behavior

- **Total real user messages**: 5 in 258 turns. Silence is the default.
- **Longest silence**: 82 agent turns (~2.5 hours) between initial request and first check-in.
- **Turn-by-tun summary**:
  1. **Initial request** — User asks for popup section reorder with up/down buttons and a maintainable order array (in Chinese, terse)
  2. **Typo progress check** — After 82 turns of silence, user sends a typo'd "what did you implement"
  3. **Correction** — Immediately corrects the typo
  4. **Docs question** — After agent explains the implementation, asks about Vitepress documentation
  5. **Plugin approval** — Agrees to use a changelog plugin, asks about search

## Verification Gates

### F2P (≥1 must pass)
- **F2P_TYPECHECK** (0.15): TypeScript compilation succeeds
- **F2P_STORAGE_KEY** (0.15): Storage key for popup section order exists in `src/core/types/common.ts`
- **F2P_SECTION_ARRAY** (0.15): Array of ≥10 section IDs exists in `src/pages/popup/Popup.tsx`

### P2P (weighted scoring)
- **P2P_REORDER_UI** (0.20): Up/down button controls with hover visibility, disabled-at-boundary logic
- **P2P_MOVE_LOGIC** (0.15): Function handles section reordering with array manipulation and state updates
- **P2P_STORAGE_SAVE** (0.10): Section order persisted to `chrome.storage.sync`
- **P2P_I18N** (0.05): `moveSectionUp` / `moveSectionDown` keys in `en/messages.json`

### P2P_REGRESSION (diagnostic/penalty only)
- **P2P_REGRESSION_TESTS**: Existing Vitest test suite passes

## Project Setup

- **Runtime**: Bun
- **Build**: Vite (Chrome extension)
- **Tests**: Vitest (`bun run test`)
- **Typecheck**: `tsc --noEmit` (`bun run typecheck`)
- **CI reference**: `.github/workflows/ci.yml`
