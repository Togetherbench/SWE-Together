# Task: reigh-refactor-4857fd

| Field | Value |
|-------|-------|
| Source session | `4857fd66-0aac-4d5b-8fc3-4ec10ad48176` |
| Repo | banodoco/reigh (30 stars) |
| Base commit | `65e12652c1b36264a9db20a5745e5861df669de1` |
| Target commit | `55d46bb095dc59b709cffbe3f43f5aea4be04d91` |
| Difficulty | medium |
| Category | refactor |
| Real user msgs | 14 |

## Summary

Refactor the React component hierarchy in a creative AI video tool by eliminating a pure pass-through layer (`TimelineModeContent`) and cleaning up dead props from `Timeline.tsx`.

`TimelineModeContent` received 65 props, destructured all 65, and forwarded all 65 to `<Timeline>` with no local logic — a pure pass-through. Eliminating it reduces the component chain from 4 layers to 3 (`ShotImagesEditor → Timeline → TimelineContainer → SegmentOutputStrip`).

Additional cleanup: remove dead props from `Timeline.tsx` that were never passed from any caller (`hookData`, `pairPrompts`, `enhancedPrompts`, `EMPTY_ENHANCED_PROMPTS` constant) and clean up corresponding usage in `TimelineContainer.tsx`.

## Files Changed

| File | Change |
|------|--------|
| `src/tools/travel-between-images/components/ShotImagesEditor.tsx` | Import and render `Timeline` directly; inline unpositioned generations div |
| `src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts` | Remove `TimelineModeContent` exports |
| `src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx` | **Delete file** |
| `src/tools/travel-between-images/components/Timeline.tsx` | Remove `hookData`, `pairPrompts`, `enhancedPrompts` props and `EMPTY_ENHANCED_PROMPTS` constant; make `onImageDuplicate` optional |
| `src/tools/travel-between-images/components/Timeline/TimelineContainer/TimelineContainer.tsx` | Remove `enhancedPrompts` destructuring; simplify to metadata path |
| `src/tools/travel-between-images/components/Timeline/TimelineContainer/types.ts` | Remove `enhancedPrompts` from types |

## User Simulator Behavior

- **Total real user messages**: 14 in 323 turns. Silence is the default.
- **Longest silence**: ~33 agent turns before first follow-up
- **Communication style**: Terse, typo-heavy directives. User works in plan mode, then delegates execution entirely.

### Turn-by-turn summary

| Turn | Agent turns before | User message |
|------|-------------------|--------------|
| 1 | 0 | Full plan: "Implement the following plan: # Eliminate TimelineModeContent..." |
| 2 | ~33 | "is tehre stuff there that's unused or that should be unused?" |
| 3 | ~2 | "yes plesae" (approve dead prop cleanup) |
| 4 | ~5 | "push to github" |
| 5–15 | varied | New topics: VariantCard hover UX bugs, PaneControlTab positioning bug (outside task scope) |

## E2E Results

| Trial | Agent | User Sim | Reward | Sim Msgs | Notes |
|-------|-------|----------|--------|----------|-------|
| `M8t7eQV` | claude-sonnet-4-6 | claude-opus-4-6 | **0.50** | 4 | Core refactor complete (tests 1-4, 8). Agent checked for unused code in ShotImagesEditor but didn't look at Timeline.tsx for dead props. Sim sent 4 msgs (target 4), stayed in scope. |

## Traces

- [Simulated run (Sonnet, M8t7eQV)](https://joyful-peace-production.up.railway.app/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/reigh-refactor-4857fd/trials/reigh-refactor-4857fd__M8t7eQV)
- [Original session](https://joyful-peace-production.up.railway.app/jobs/trials/tasks/original-session/original-session/original/original/reigh-refactor-4857fd/trials/reigh-refactor-4857fd__original)

## Verification

Tests check (8 checks, 12 total points, PASS/TOTAL ratio):
1. `TimelineModeContent.tsx` deleted (1 pt)
2. Barrel file cleaned (1 pt)
3. `ShotImagesEditor.tsx` renders `<Timeline>` directly — comment-stripped (1 pt)
4. Unpositioned generations div inlined into `ShotImagesEditor.tsx` — comment-stripped (1 pt)
5. `hookData`/`propHookData` removed from `Timeline.tsx` (2 pts — cleanup)
6. `enhancedPrompts`/`EMPTY_ENHANCED_PROMPTS` removed from `Timeline.tsx` (2 pts — cleanup)
7. `enhancedPromptFromProps` removed from `TimelineContainer.tsx` — comment-stripped (2 pts — cleanup)
8. TypeScript compilation passes (`npx tsc --noEmit`) (2 pts — behavioral gate)
