# Agent Test Comparison Report

**Date:** 2026-03-29
**Task:** `sageattention-headdim-256` — Extend SageAttention to support `head_dim = 256`
**User Simulator Version:** 0.3.1
**Ground-truth user messages available:** 6 (max injected per run: 2)

## Test Configuration

| Parameter | Terminus | Claude Code |
|---|---|---|
| Agent type | `terminus` (in-process LLM) | `claude-code` (CLI + `--resume`) |
| Agent version | terminus-2 v2.0.0 | claude-code v2.1.87 |
| Action model | `anthropic/claude-sonnet-4-6` | `claude-sonnet-4-6` |
| User sim model | `anthropic/claude-opus-4-6` | `anthropic/claude-opus-4-6` |
| Trial ID | `sageattention-headdim-256__GsTXkPf` | `sageattention-headdim-256__q7RDf3S` |

## Results Summary

| Metric | Terminus | Claude Code |
|---|---|---|
| **Reward** | **1.0** | **1.0** |
| **Success** | Yes | Yes |
| Wall-clock time | ~199 s (~3.3 min) | ~776 s (~12.9 min) |
| Trajectory steps | 33 (16 agent + 16 tool + 1 user) | 1 external step (29 internal tool calls) |
| Agent episodes | 16 | 2 |
| User sim calls | 14 | 2 |
| User messages injected | 1 | 1 |

## Token Usage & Cost

### Action Agent (Sonnet 4.6)

| Metric | Terminus | Claude Code |
|---|---|---|
| Prompt tokens | 210,968 | 557,212 |
| Completion tokens | 5,593 | 662 |
| Cached tokens | 187,898 | 541,036 |
| Cache creation tokens | — | 162,466 |
| Reported cost (action agent) | $0.2258 | ~$0.83 (estimated) |

### User Simulator (Opus 4.6)

Both runs made LiteLLM calls to `claude-opus-4-6` for user simulation decisions. Terminus made 14 user-sim calls (13 no-op, 1 question); Claude Code made 2 calls (1 question, 1 no-op). User-sim cost is not separately tracked in the trajectory but is additional to the action agent cost above.

## User Simulation Behavior

### Terminus

The user simulator was consulted at every agent turn (14 times total). It waited silently for the first 12 turns while the agent explored the codebase and made changes. At **turn 13**, it injected a question:

> "Why do we need to make this change to `fused.cu`?"

The agent responded, and at turn 15 the user sim went silent again, allowing the task to complete.

**Action breakdown:** 13 no-op, 1 question

### Claude Code

The user simulator was consulted after the initial claude-code run completed all file edits in a single shot. At **turn 1**, it immediately asked:

> "Why do we need to make this change to fused.cu?"

After the agent responded via `--resume`, the user sim was consulted at turn 2 and decided to remain silent, ending the session.

**Action breakdown:** 1 question, 1 no-op

## Architecture Observations

### Terminus (In-Process LLM Agent)

- **Granular control:** Each LLM call produces one tool/action, giving the user simulator fine-grained turn-by-turn observation and injection points.
- **Lower cost:** Smaller context windows per call due to incremental tool outputs. Total prompt tokens ~211K vs ~557K.
- **Faster wall-clock:** ~3.3 min total execution. The tight loop between LLM → tool → user-sim → LLM is efficient.
- **Higher completion tokens:** The agent generates tool-call JSON at each step (5,593 completion tokens across 16 turns).

### Claude Code (CLI Agent + Resume)

- **Autonomous execution:** Claude Code manages its own tool loop internally (29 internal steps), reading files, writing edits, and verifying changes without external orchestration.
- **Coarser user-sim granularity:** The user simulator only sees snapshots after the entire claude run completes, not after individual file reads or edits.
- **Higher token cost:** The full conversation context is sent to the API at each internal step, leading to ~557K prompt tokens total. However, aggressive cache reuse (541K cached) reduces effective cost.
- **Slower wall-clock:** ~12.9 min — the CLI overhead (process startup, `--resume` session management) and larger context windows add latency.
- **Real session continuity:** The `--resume` flag provides genuine conversation continuity for multi-turn interactions, preserving claude-code's internal state.

## Conclusions

1. **Both agents achieved perfect score (1.0)** on this task, demonstrating that the user-simulation framework works correctly with both agent backends.

2. **Terminus is ~4x faster and ~4x cheaper** for this task, benefiting from tight in-process orchestration and smaller context windows.

3. **Claude Code provides higher autonomy** — it completed all file edits in a single shot without needing turn-by-turn orchestration, but at the cost of coarser user-sim visibility and higher token usage.

4. **User simulation converged identically** — both agents received the same user question ("Why do we need to make this change to `fused.cu`?") at the point where `fused.cu` modifications were visible, suggesting the user simulator's behavior is consistent across agent types.

5. **Trade-off:** Terminus offers better observability and lower cost for research/benchmarking. Claude Code offers a more realistic agentic coding workflow but with fewer user-sim injection points per run.
