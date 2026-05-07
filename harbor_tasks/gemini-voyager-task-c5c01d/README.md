# Task: gemini-voyager-task-c5c01d

| Field | Value |
|-------|-------|
| Source session | `c5c01d3f-dbb6-436c-9179-17702671f6c0` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `4e9d91695130a0dcde1c1f93cf41151c42e6ea52` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 5 |

## Summary

Implement a snow effect feature for the Gemini Voyager Chrome extension. The user provides a detailed implementation plan following the `sidebarAutoHide` pattern: popup toggle -> chrome.storage.sync -> content script -> enable/disable. The effect renders a fullscreen canvas snow animation with varied particles, proper lifecycle management, and no interaction blocking.

## User Simulator Behavior
- Total real user messages: 5 in 230 turns. Silence is the default.
- Longest silence: 79 agent turns (~31 min) after initial specification
- Turn 1: User provides detailed implementation plan (English)
- Turn 2: Aesthetic feedback — snowflakes too big, too few (Chinese)
- Turn 3: Scope question — Gemini-only? Reference recent commit (Chinese)
- Turn 4: Follow-up — validation of referenced commit (Chinese)
- Turn 5: Visual quality feedback — 3 specific issues with snow appearance (Chinese)

## Key Files Modified
| File | Change |
|------|--------|
| `src/core/types/common.ts` | Add `GV_SNOW_EFFECT` storage key |
| `src/locales/*/messages.json` | Add `snowEffect`/`snowEffectHint` translation keys |
| `src/pages/popup/Popup.tsx` | Add snow effect toggle UI |
| `src/pages/content/snowEffect/index.ts` | **New** — snow effect content script |
| `src/pages/content/index.tsx` | Register snow effect module |
| `src/pages/content/snowEffect/__tests__/snowEffect.test.ts` | **New** — tests |
