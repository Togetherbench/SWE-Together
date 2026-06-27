# Task: gemini-voyager-task-72a86c

| Field | Value |
|-------|-------|
| Source session | `72a86ca0-ec56-45a9-9f97-c841875b5e96` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `38c33258f0ca3863e1b08fe65bf37a26352ac355` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 4 |

## Task Summary

Implement platform-appropriate modifier key display in a Chrome extension UI. On macOS, modifier keys like Ctrl should be displayed as ⌘ (Cmd), and all modifier symbols (Meta→⌘, Alt→⌥, Ctrl→⌃, Shift→⇧) should use macOS conventions. On other platforms, keep the text labels. Also add discoverability for the Ctrl/⌘+I input collapse shortcut, and update all 11 locale files to use a `{modifier}` placeholder instead of hardcoded "Ctrl".

## Key changes required
- Add `isMac()` and `getModifierKey()` utilities to `src/core/utils/browser.ts`
- Update `formatShortcut()` in `KeyboardShortcutService.ts` for platform-aware modifier display
- Replace hardcoded "Ctrl" with `{modifier}` placeholder in all locale files (11 locales)
- Add `inputCollapseShortcutHint` translation key for Ctrl/⌘+I discoverability
- Wire up `getModifierKey()` in Popup.tsx to dynamically replace `{modifier}`
- Add unit tests for the new functions

## User Simulator Behavior
- Total real user messages: 4 in 258 turns. Silence is the default.
- Longest silence: ~188 agent turns (~20 min)
- Turn 1: Detailed implementation plan (instruction.md)
- Turn 2: "ctrl i 是否应该加在 popup 里指示?" — asks about popup discoverability
- Turn 3: "好，vitepress 文档里没有的话也加上" — requests VitePress docs update
- Turn 4: "bun run format 然后提交" — requests format and commit

## Verification Gating
- 6 F2P gates (behavioral + structural), 0 P2P_REGRESSION gates
- Weighted-replace reward formula, Σ weights = 1.00
- CI source: `.github/workflows/ci.yml` (bun run test, bun run build:chrome)
