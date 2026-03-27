# Task: banodoco-wrapped-task-894a74

| Field | Value |
|-------|-------|
| Source session | `894a7453-11b3-423c-9dd6-46acb9419849` |
| Repo | xliry/banodoco-wrapped (35 stars) |
| Base commit | `13a06f8` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 27 |

## User Simulator Behavior

- Total real user messages: 27 in ~50 agent turns. Silence is the default.
- Longest silence: ~10 agent turns during ModelTrends animation iteration phase.
- Turn-by-turn summary:

| Turn | After N agent turns | Summary |
|------|---------------------|---------|
| 1 | 0 (initial) | Request TopGenerations row virtualization — load only 4 rows at a time, release previous rows on scroll |
| 2 | ~3 | "Is this well structured? Will it work well on mobile?" — quality review of TopGenerations implementation |
| 3 | ~5 | "git pull to get latest, also 'The Rise & Fall of Models' should probably play when you go into the section and the animation kinda completes before the end" |
| 4 | ~8 | "also the animation doesn't run the whole way, it feels like it completes before it's completed" |
| 5 | ~10 | "still happens...also why on the first load does it not 'play from the left'" |
| 6 | ~11 | "is there a max duration on the animation or something?" |
| 7 | ~13 | "could you make it ease out smoothly in terms of the speed" |
| 8 | ~14 | "it is good but it looks a bit choppy/low frame rate" |
| 9 | ~15 | "now it's too wavy" |
| 10 | ~16 | "it fluctuates weirdly as it's loading now...Uncaught ReferenceError: Cannot access 'normalizedData' before initialization" |
| 11 | ~20 | "is this well-structured? easy to reason about?" |
| 12 | ~22 | "that looks good but can you only show the times that actually have entries / so the timeline should reveal as the data comes in" |
| 13 | ~24 | "make it half the speed" |
| 14 | ~25 | "could you make the transitions of the Y axis feel smooth?" |
| 15-16 | ~26-27 | "try easing" / "more easssing" |
| 17 | ~30 | "when a new model comes in could you show a label...ideally appearing on its segment" |
| 18 | ~33 | "make it last long and then 'follow' the centre of that model along the X axis" |
| 19 | ~35 | Pastes ReferenceError for 'displayData' before initialization |

## What Needs to Be Fixed

The repo is cloned at commit `13a06f8` — the state just before a live coding session. Two components need work:

### 1. `components/TopGenerations.tsx` — Row Virtualization
- **Current state**: Renders ALL month sections with all videos at once (heavy load)
- **Required**: Only render ~4 rows at a time using IntersectionObserver; release invisible rows; use placeholder divs to maintain scroll position

### 2. `components/ModelTrends.tsx` — Animation Improvements
- **Current bugs**:
  - `useState(data.length)` — animation starts at the end, never plays from left
  - `const STEP_MS = 180` — constant speed (no ease-out)
  - No auto-play on scroll (requires manual Play button click)
  - No data normalization (values may not sum to 100%)
  - Y-axis `domain={[0, 'auto']}` — rescales during animation

- **Required**:
  - IntersectionObserver auto-play when section scrolls into view
  - Animation starts from 0 (empty chart), builds left-to-right
  - Ease-out timing (fast start, slow finish)
  - Normalize data so each month sums to 100%
  - Fixed Y-axis domain `[0, 100]`

## Baseline Score

`0.20` — tests 4 (no TS errors in task files) and 8 (`npm run build`) pass at base commit.

## E2E Evaluation Results

| Field | Value |
|-------|-------|
| Agent model | claude-sonnet-4-6 |
| User sim model | claude-opus-4-6 |
| Reward | **0.80** (8/10 tests) |
| User sim messages | 8 (of 28 ground-truth available) |
| Agent episodes | 68 |
| Agent timeout | 1200s (hit timeout) |
| Date | 2026-03-22 |

### Test Results

| # | Test | Result |
|---|------|--------|
| 1 | TopGenerations.tsx uses IntersectionObserver for lazy row loading | PASS |
| 2 | ModelTrends.tsx uses IntersectionObserver for auto-play on scroll | PASS |
| 3 | ModelTrends.tsx has variable animation speed (ease-out) | PASS |
| 4 | No new TypeScript errors in task files | FAIL (agent introduced type conversion error) |
| 5 | Animation does NOT initialize at data.length | PASS |
| 6 | Data normalization (values sum to ~100%) | PASS |
| 7 | Y-axis has fixed domain [0, 100] | PASS |
| 8 | Production build succeeds (npm run build) | FAIL (agent broke canvas-confetti import in Timeline.tsx) |
| 9 | TopGenerations.tsx renders only visible rows | PASS |
| 10 | ModelTrends auto-play is complete and non-trivial | PASS |

### User Sim Message Summary

The user simulator sent 8 messages over 68 agent turns, consuming 8 of 28 ground-truth messages. Messages included quality review questions, animation feedback, and a redirect to unfinished work. The simulator correctly stayed silent during productive stretches (default silence behavior).

## Traces

- [Simulated run](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/banodoco-wrapped-task-894a74/trials/banodoco-wrapped-task-894a74__BK2yuHa)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/banodoco-wrapped-task-894a74/trials/banodoco-wrapped-task-894a74__original)
