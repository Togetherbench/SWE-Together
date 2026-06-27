# Task: mlx-lm-mambacache

| Field | Value |
|-------|-------|
| Source session | `dae75777-77a5-4ba3-81fd-4e46fab3ded8` |
| Repo | ml-explore/mlx-lm |
| Base commit | `298b67c` (last main commit before PR creation) |
| Ground truth | PR #739 commits: `035ea22` (batching) + `d5984bc` (_lengths) |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 15 |
| Expert time estimate | 30 min |

## E2E Results (pre-hardening)

| Metric | Value |
|--------|-------|
| Reward | **1.00** |
| Sim msgs | 4 |
| Real msgs | 15 |

> Note: These results are from BEFORE test hardening. Tests have since been hardened to reduce gaming.

## Test Hardening Status

Not yet hardened -- reward of 1.00 with low sim/real ratio (0.27x) suggests the agent completed the core task efficiently. Tests verify structural properties of ArraysCache batching methods (merge, extract, prepare, finalize) and CacheList updates.

## User Simulator Behavior

- **Total real user messages: ~15** across messages 931-1094 of a 2525-message session.
- This is extracted from a long multi-project session. The mlx-lm work starts when the user discovers `batch_generate` fails with `MambaCache` for hybrid models like Qwen3-Next.
- User delegates extensively via "deploy your subagent" pattern. Speaks in high-level directives. Expects comprehensive testing.
- Turn 1: "MLX LM lib doesnt allow us to run the model Qwen3-Next-80B with batch and prompt caching. Can you deploy your subagent to verify this?"
- Turn 2: "Deploy 2 sub to verify: batch vs cache speed, and can we implement it?"
- Turn 3: "yes draft the PR and thoroughly test its performance"
- Turn 4: "Does our PR the same as PR #690?" (checking for duplication)
- Turn 5: "add the _lengths feature to our PR" (scope expansion)
- Turn 6: "Wait test with actual model please" (testing redirect -- unit tests insufficient)
- [Summary: 4 sim msgs vs 15 real msgs, 0.27x ratio]

## Traces

- [Simulated run (Opus)](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/mlx-lm-mambacache/trials/mlx-lm-mambacache__x8b7NPg)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/claude-opus-4-5-20251101/mlx-lm-mambacache/trials/mlx-lm-mambacache__original)
