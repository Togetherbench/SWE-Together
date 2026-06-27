# Task: comfyui-wanvideowrapper-fix-167b3c

| Field | Value |
|-------|-------|
| Source session | `167b3c69-fb33-43fb-80ff-367a81c81ce4` |
| Repo | `kijai/ComfyUI-WanVideoWrapper` (650 stars) |
| Base commit | `b06c7d2d6d9bda2cdb6f61e1476f4db37d309f17` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 4 |

## Task Description

Fix a Triton kernel error that occurs on Windows with AMD GPU in the SageAttention implementation. The file `ultravico/sageattn/attn_qk_int8_per_block.py` contains `_attn_fwd_inner()`, a `@triton.jit` function that loads `k_scale` via a mutating pointer:

```python
k_scale = tl.load(K_scale_ptr)   # bare load, no block index
...
K_scale_ptr += 1                  # pointer mutation at loop end
```

Triton's AMD WMMA backend cannot handle this pointer mutation pattern, producing:
```
LLVM ERROR: operation destroyed but still has uses
```

The fix replaces the mutating pointer pattern with an indexed load from a stable base pointer:
```python
k_scale = tl.load(K_scale_ptr + (start_n // BLOCK_N))
# (remove K_scale_ptr += 1)
```

## User Simulator Behavior

- Total real user messages: 4 in 15 turns. Silence is the default.
- Longest silence: 8 agent turns (between user messages 3 and 4)
- Turn-by-turn summary:
  1. **Turn 1 (index 0):** Reports Triton LLVM error on Windows/AMD GPU with full error output
  2. **Turn 2 (index 4, after 3 agent turns):** Asks "Why is this modification needed?" — brief clarification
  3. **Turn 3 (index 6, after 1 agent turn):** Asks how to fix it in this repo rather than Triton kernel — scope clarification
  4. **Turn 4 (index 15, after 8 agent turns):** Asks "Why is this edit needed?" — explanation request

## Scoring

| Test | Weight | Type | Description |
|------|--------|------|-------------|
| 1 | 0.10 | silver | Mock-import module, verify functions callable + signatures |
| 2 | 0.05 | structural | Anti-stub: `_attn_fwd_inner` has real body (for loop + 8 stmts) |
| 3 | 0.25 | AST-semantic | CORE: bare `tl.load(K_scale_ptr)` removed AND indexed load present |
| 4 | 0.20 | AST-semantic | Correct index: `start_n` used in k_scale load offset |
| 5 | 0.15 | AST-semantic | `K_scale_ptr += 1` removed AND for-loop preserved |
| 6 | 0.10 | AST-semantic | `K_ptrs`/`V_ptrs` updates preserved (no regression) |
| 7 | 0.10 | AST-semantic | `_attn_fwd` still calls `_attn_fwd_inner` (interface intact) |
| 8 | 0.05 | structural | `_attn_fwd` has substantial body (≥10 stmts) |

Baseline (buggy) score: **0.40** | Fixed score: **1.00**

## E2E Eval Results

| Run | Model | Reward | Sim messages | Real messages |
|-----|-------|--------|--------------|---------------|
| 2026-03-26 | claude-sonnet-4-6 | **0.40** | 6 | 4 |
| 2026-03-23 | claude-sonnet-4-6 | **1.00** | 5 | 4 |

Notes:
- 2026-03-26: Hardened user_simulation_prompt.md to prevent answer leaking. Sim no longer reveals fix pattern. Reward = baseline (agent tried wrong approach: `.to(tl.float32)` cast instead of indexed loads).
- 2026-03-23: Old run — sim leaked exact fix code from user_simulation_prompt.md Overview Table, inflating reward.

## Traces

- [Simulated run (2026-03-26)](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/comfyui-wanvideowrapper-fix-167b3c/trials/comfyui-wanvideowrapper-fix-167b__5Xy6nwe)
- [Simulated run (2026-03-23)](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/comfyui-wanvideowrapper-fix-167b3c/trials/comfyui-wanvideowrapper-fix-167b__2Xvvgda)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/comfyui-wanvideowrapper-fix-167b3c/trials/comfyui-wanvideowrapper-fix-167b3c__original)
