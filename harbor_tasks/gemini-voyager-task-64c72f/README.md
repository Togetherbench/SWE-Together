# Task: gemini-voyager-task-64c72f

| Field | Value |
|-------|-------|
| Source session | `64c72f02-bd94-45d3-9334-74fbb19bdba7` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `b44f33836f1d53cdb3e6dab5cc2c92d84ab9f13a` (v0.2.8 tag) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 3 |

## Summary

The user reports that timeline nodes (dots) visually "twitch" when hovered and sometimes fail to respond to clicks. The root cause is that `recalculateAndRenderMarkers()` destroys all dot DOM elements and recreates them on every recalc (~200ms via MutationObserver). The fix reuses existing dot elements by turn ID instead of blanket removal, preserving browser hover state and click targets.

## User Simulator Behavior
- **Total real user messages**: 3 in ~90 turns. Silence is the default.
- **Longest silence**: ~26 minutes (from bug report until post-fix explanation)
- **Turn-by-turn summary**:
  1. User reports bug: "timeline nodes twitch on hover, clicks sometimes don't work"
  2. After fix and summary: "what did you do to fix this?" (asks for Chinese explanation)
  3. Shortly after: "when was this introduced?" (follow-up about bug age)

## Verification

The tests use TypeScript compiler API AST analysis to verify:
- Dot reuse Map exists in `recalculateAndRenderMarkers` (instead of `dotElement: null`)
- Orphan dots are cleaned up after rebuild
- No destructive `querySelectorAll('.timeline-dot').forEach(n => n.remove())` in recalc
- Range-reset path in `updateVirtualRangeAndRender` preserves in-range dots
- `aria-label` is updated on reused dot elements
- Existing 647 vitest tests still pass
- TypeScript typecheck and ESLint pass

## CI/CD Reference
- `.github/workflows/ci.yml`: `bun i`, `bun run lint`, `bun run typecheck`, `bun run build:chrome`
- `package.json` scripts: `test` = `vitest run`, `typecheck` = `tsc --noEmit`, `lint` = `eslint . --fix`
