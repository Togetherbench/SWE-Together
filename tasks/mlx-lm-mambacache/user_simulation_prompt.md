# User Simulation Prompt: mlx-lm-mambacache

Source session: `dae75777-77a5-4ba3-81fd-4e46fab3ded8`

## Simulator Calibration

- **Total user messages (mlx-lm portion): ~15** across messages 931-1094 of a 2525-message session.
- **Session context**: This is a long multi-project session. The mlx-lm work starts at message 931 when the user discovers that `batch_generate` fails with `MambaCache` (hybrid models like Qwen3-Next). The user tasks the agent with verifying the limitation, researching a fix, implementing it, and creating a PR.
- **User style**: Delegates extensively via "deploy your subagent" pattern. Speaks in high-level directives. Expects comprehensive testing. Interrupts when unsatisfied with test coverage.
- **Correction pattern**: User adds scope mid-stream (msg 1064: "add the _lengths feature to our PR" after seeing PR #690), and redirects testing approach (msg 1094: "Wait test with actual model please").
- Target for simulation: 2 messages after Turn 1 (instruction.md = implicit first turn).

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has modified both `mlx_lm/models/cache.py` AND `mlx_lm/generate.py` (git diff shows changes to both files) AND has NOT yet created a test file under `tests/` | "Does our PR the same as https://github.com/ml-explore/mlx-lm/pull/690?" | Verbatim from session msg 1057. User checks for duplication with existing community PR. Agent should explain the difference (PR #690 adds _lengths for right padding, theirs adds merge/extract batching). |
| T3 | Agent has created or modified a test file matching `tests/test_*cache*.py` or `tests/test_*batch*.py` | "Wait test with actual model please" | Verbatim from session msg 1094. User wants real model testing. In Docker/Linux environment, MLX only runs on macOS/Apple Silicon so this is impossible. A good agent explains this limitation and proposes alternatives. |

## User Turns (with context)

**Turn 1** (msg 931 -- discovery):
  Context: User has been using Qwen3-Next-80B via local MLX fallback in a data pipeline. Batch + cache fails.
  Said: "It seems MLX LM lib doesnt allow us to run the model Qwen3-Next-80B (currently using) with batch and prompt caching. Can you deploy your subagent to verify this?"
  Why: User suspects a limitation but wants verification before acting.

**Turn 2** (msg 936 -- research directive):
  Context: Agent confirmed the limitation: `_merge_caches()` only handles KVCache/RotatingKVCache.
  Said: "Deploy 2 sub to verify 2 things: whether batch or cache is faster for our pipeline... whether it's possible for us to implement batching and caching into MLX itself for this model. If possible we can contribute a very positive PR to the community"
  Why: User wants both a practical recommendation AND to contribute upstream.

**Turn 3** (msg 942 -- implementation order):
  Context: Agent reports batch generation is 2-4x faster and implementation is feasible.
  Said: "yes draft the PR and thoroughly test its performance, with clear documentation, and also test by directly use the MLX model too"
  Why: Green light to implement. Emphasizes thorough testing + documentation.

**Turn 4** (msg 1057 -- scope comparison):
  Context: PR #739 has been created. User notices PR #690 exists.
  Said: "Does our PR the same as https://github.com/ml-explore/mlx-lm/pull/690?"
  Why: Checking for duplication with existing community work.

**Turn 5** (msg 1064 -- scope expansion):
  Context: Agent explains PR #690 adds _lengths for right padding, which is different from their batching work.
  Said: "add the _lengths feature to our PR"
  Why: User wants to incorporate the _lengths feature from PR #690 into their PR for completeness.

**Turn 6** (msg 1094 -- testing redirect):
  Context: Agent ran unit tests but user wants integration testing.
  Said: "Wait test with actual model please"
  Why: Unit tests pass but user wants real model validation.

## Overview

| Field | Value |
|-------|-------|
| **Model** | claude-opus-4-5-20251101 |
| **Repo** | ml-explore/mlx-lm |
| **Duration** | 2026-01-07 (within a multi-day session) |
| **User messages (mlx portion)** | ~15 |
| **Completion** | CLOSED (PR #739 closed, not merged -- superseded by community PRs) |
| **Base commit** | `298b67c` (last main commit before PR creation) |
| **Ground truth** | PR #739 commits: `035ea22` (batching) + `d5984bc` (_lengths) |

## Session State Graph

```
USER: "MLX LM doesnt allow batch + prompt caching with Qwen3-Next-80B"
  |
  |  User state: power user, running hybrid model locally
  |  User intent: VERIFY limitation, then FIX it
  |
  v
AGENT: Confirms limitation -- _merge_caches() only handles KVCache/RotatingKVCache
AGENT: "ValueError: <class 'mlx_lm.models.cache.MambaCache'> does not yet support batching with history"
  |
  v
USER: "Deploy 2 sub to verify: batch vs cache speed, and can we implement it?"
  |
  v
AGENT: Reports batch is 2-4x faster, implementation is feasible
  |
  v
USER: "yes draft the PR and thoroughly test"
  |
  |  User intent: ACTION -- implement merge/extract/prepare/finalize on ArraysCache,
  |  update CacheList, update _merge_caches in generate.py, write tests
  |
  v
AGENT: Implements ArraysCache.merge/extract/prepare/finalize, CacheList.merge/extract
AGENT: Updates _merge_caches() in generate.py
AGENT: Writes 15 unit tests in tests/test_mamba_cache_batching.py
AGENT: Creates PR #739
  |
  v
USER: "Does our PR the same as PR #690?"
  |
  v
AGENT: Explains PR #690 adds _lengths for right padding -- different feature
  |
  v
USER: "add the _lengths feature to our PR"
  |
  |  SCOPE EXPANSION: incorporate _lengths from PR #690
  |
  v
AGENT: Adds _lengths to ArraysCache.__init__, prepare(), make_mask(), merge/extract
AGENT: Adds 5 new mask tests with _lengths
  |
  v
USER: "Wait test with actual model please"
  |
  |  REDIRECT: wants real model testing, not just unit tests
  |
  v
AGENT: Runs integration test with Qwen3-Next-80B (all 4 scenarios pass)
  |
  v
[Session continues to use the fork in data pipeline work]
```

## What Each Transition Reveals

| Transition | What user saw | What it tells us |
|-----------|---------------|-----------------|
| Discovery -> Verify | MambaCache limitation confirmed | Agent correctly identified root cause in _merge_caches() |
| Verify -> Research | Batch 2-4x faster | Agent provided actionable performance data |
| Research -> Implement | PR drafted + tested | Agent delivered comprehensive implementation |
| Implement -> Compare PR #690 | Different scope | User has community awareness, checks for duplication |
| Compare -> Add _lengths | Scope creep | User wants comprehensive solution |
| _lengths -> Real model test | User redirects | Unit tests insufficient for user's confidence |

## User Preference Profile

| Dimension | Preference | Evidence |
|-----------|-----------|---------|
| Planning vs. execution | **Both** -- research first, then execute | Asked for verification before implementation |
| Autonomy | **High** -- "deploy your subagent" | Delegates entire implementation and testing |
| Communication | **Directive** | Short, action-oriented messages |
| Testing | **Thorough** -- unit + integration | Insisted on real model testing |
| Scope management | **Expansive** -- adds features mid-stream | Added _lengths from PR #690 |
