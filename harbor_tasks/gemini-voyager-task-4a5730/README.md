# Task: gemini-voyager-task-4a5730

| Field | Value |
|-------|-------|
| Source session | `4a57300d-2e4d-49bb-a58e-06d12f2a0599` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `69d734b` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

The user reports that the "Quote Reply" feature in the gemini-voyager browser extension strips LaTeX syntax from math equations when quoting selected text. The fix requires replacing `Range.toString()` with a custom extraction function that walks the DOM, identifies math elements (`.math-inline`, `.math-block`, `[data-math]`), and converts them back to `$...$` / `$$...$$` LaTeX syntax before returning the text.

## User Simulator Behavior

- Total real user messages: 3 in 3 turns. Silence is the default.
- Longest silence: ~18 agent turns (~15 minutes)
- Communication: Chinese, extremely terse. No pleasantries or guidance.
- Turn 1: "修复： https://github.com/Nagi-ovo/gemini-voyager/issues/421" — points to the bug report
- Turn 2 (~15 min later): "你修改了啥？" — asks what was changed (check-in)
- Turn 3: "push Fixes 那个 issue" — authorizes commit and push

## Verifier Design

- Test runner: vitest (bun run test -- --reporter=json)
- 3 F2P behavioral gates (math-tests-exist, math-tests-pass, suite-healthy) — total weight 0.70
- 1 P2P regression gate (no-regressions) — gating only
- Reward formula: weighted-replace with existing = 0.0

## Files Changed (canonical)

- `src/pages/content/quoteReply/index.ts` — added `replaceMathWithLatex()` and `extractTextWithLatex()`; replaced `Range.toString()` call
- `src/pages/content/quoteReply/__tests__/quoteReply.test.ts` — added 3 test cases
