# Task: sd-scripts-fix-ses_38

| Field | Value |
|-------|-------|
| Source session | `ses_3863f2d10ffeYja949H9XJGyyK` |
| Repo | kohya-ss/sd-scripts (13000 stars) |
| Base commit | `e21a7736f8fdd2477836edf254105518beb9790e` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 4 |

## User Simulator Behavior
- Total real user messages: 4 in 48 turns. Silence is the default.
- Longest silence: ~17 agent turns (between Turn 3 and Turn 4)
- Turn 1 (initial): "In the last commit, we enable multi-resolution dataset for SD1/SDXL. Now your task is to improve backward compatibility..."
- Turn 2 (after 3 agent turns): "Read `git diff HEAD~` to see the last commit" (redirect to use git context)
- Turn 3 (after 5 agent turns): "We only need to add backward compatibility for SD1/SDXL. Or you can implement it in the base class..."
- Turn 4 (after 17 agent turns): "Considering that npz file is a zip, you may read the saved entry in the zip file as a stream and only decode the array header."

## Task Summary
The agent must add backward compatibility for legacy cached latents in kohya-ss/sd-scripts.

Starting from a state where `SdSdxlLatentsCachingStrategy` uses resolution-suffixed npz keys (e.g. `latents_64x64`), the agent must implement a fallback: when the resolution-suffixed key is not found, check for the unsuffixed `latents` key and validate its shape. The key constraint is that size validation must be **metadata-only** (header-only read from the zip stream), not a full array decompression.

Files to modify:
- `library/strategy_base.py` — add header-only npz shape reader + fallback logic in `_default_is_disk_cached_latents_expected`
- `library/strategy_sd.py` — no changes required if fallback is implemented in base class

## E2E Eval Results

| Run | Model | Reward | Sim msgs | Notes |
|-----|-------|--------|----------|-------|
| 1 (2026-03-23) | claude-sonnet-4-6 | **1.00** | 4/4 ✓ | All 10 tests pass (old test suite, equal weights) |
| 2 (2026-03-26) | claude-sonnet-4-6 | **0.30** | 4/4 | Fallback implemented but no header-only reads (weighted tests, 12 checks) |
| 3 (2026-03-26) | claude-sonnet-4-6 | **0.95** | 5/4 | Full solution with header-only reads; T1 missed (method name) |

### Test Discrimination (weighted scoring, 12 tests, 100pts)
| Agent behavior | Expected score |
|---|---|
| Baseline (no changes) | 0.10 |
| Fallback only (np.load, no header-only) | 0.25–0.35 |
| Full solution (fallback + header-only reads) | 0.90–1.00 |

### Scoring Breakdown
- Structural (20%): T1(5), T2(5), T3(5), T9(5)
- Behavioral fallback (25%): T4(5), T6(5), T7(5), T8(5), T10(5)
- Behavioral header-only (55%): T5(15), T11(20), T12(20)

## Traces
- [Simulated run (iter 3)](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/sd-scripts-fix-ses_38/trials/sd-scripts-fix-ses_38__KK5hGjY)
- [Simulated run (iter 2)](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/sd-scripts-fix-ses_38/trials/sd-scripts-fix-ses_38__ib8eQCC)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/sd-scripts-fix-ses_38/trials/sd-scripts-fix-ses_38__original)
