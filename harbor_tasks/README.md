# Harbor Tasks

Benchmark tasks derived from real multi-turn coding sessions. Each task has a Docker environment, instructions, and automated verification.

**Live trace viewer**: https://joyful-peace-production.up.railway.app/jobs/trials

## Task Registry

| Task | Source Session | Repo | User Msgs | Original Status | Difficulty | Description |
|------|---------------|------|-----------|-----------------|------------|-------------|
| `desloppify-review-fixes` | `489211c5` | peteromallet/desloppify | 5 | Completed | medium | Fix 3 bugs: ID collision (#56), missing dimensions (#57), reminder integration (#55) |
| `desloppify-go-plugin` | `96345f53` | peteromallet/desloppify | 2 | Failed | hard | Upgrade Go plugin from generic to full class-based implementation (PR #128 recovery) |
| `comfyui-fp8-newbie` | `c53e4e72` | Comfy-Org/ComfyUI | 2 | Partial | medium | Add fp8 quantized Gemma support to NewBie dual CLIP encoder |
| `desloppify-zone-classification` | `8706443a` | peteromallet/desloppify | 14 | Completed | hard | Implement complete zone classification system (6 components) |
| `unsloth-idefics3-fix` | `a6fe6467` | unslothai/unsloth | 23 | Incomplete | hard | Add Idefics3 VLM support — hit unsloth_zoo hook compatibility bug |
| `desloppify-treesitter-plugins` | `7402f7a5` | peteromallet/desloppify | 11 | Partial | hard | Make generic language plugins first-class citizens + tree-sitter integration |
| `vibecomfy-mcp-server` | `97c34bb6` | peteromallet/VibeComfy | 50 | Completed | hard | Integrate MCP server for ComfyUI node discovery |
| `unsloth-zoo-vllm-fix` | `bc295ce4` | unslothai/unsloth-zoo | 39 | Completed | medium | Fix UnboundLocalError in vllm_utils for LFM2/Mamba hybrid models |
| `mlx-lm-mambacache` | `dae75777` | ml-explore/mlx-lm | 15 | Completed | hard | Add MambaCache batching support for batch_generate |

### Status definitions

- **Completed** — the real user + agent finished the task in the original session
- **Incomplete** — session ended before the task was done (blocking bug, user gave up)
- **Partial** — some phases done, others not started
- **Failed** — agent didn't accomplish the task (user cancelled or session ended with no progress)

### Conversion status

| Task | instruction.md | analysis.md | Dockerfile | test.sh | Verified |
|------|:-:|:-:|:-:|:-:|:-:|
| `desloppify-review-fixes` | done | done | done | done | done |
| `desloppify-go-plugin` | done | done | done | done | done |
| `comfyui-fp8-newbie` | done | done | done | done | done |
| `desloppify-zone-classification` | done | done | PR #14 | PR #14 | PR #14 |
| `unsloth-idefics3-fix` | done | done | PR #13 | PR #13 | PR #13 |
| `desloppify-treesitter-plugins` | done | done | PR #12 | PR #12 | PR #12 |
| `vibecomfy-mcp-server` | done | done | PR #15 | PR #15 | PR #15 |
| `unsloth-zoo-vllm-fix` | done | done | PR #16 | PR #16 | PR #16 |
| `mlx-lm-mambacache` | done | done | PR #17 | PR #17 | PR #17 |

### E2E Results (Opus 4.6, minimal instruction)

| Task | Reward | Sim msgs | Real msgs |
|------|--------|----------|-----------|
| desloppify-review-fixes | **1.00** | 6 | 5 |
| desloppify-go-plugin | **1.00** | 16 | 2 |
| comfyui-fp8-newbie | **1.00** | 6 | 2 |
| desloppify-treesitter-plugins | **0.75** | 5 | 11 |
| desloppify-zone-classification | **0.55** | 5 | 14 |
| unsloth-idefics3-fix | 0.00 | 3 | 23 |
| vibecomfy-mcp-server | 0.30 | 26 | 50 |
| unsloth-zoo-vllm-fix | **1.00** | 15 | 39 |
| mlx-lm-mambacache | **1.00** | 4 | 15 |

### Dataset exhaustion

All 133 sessions from the DataClaw corpus have been evaluated. The 9 tasks above represent the complete viable yield:
- 23 desloppify sessions → 5 tasks (capped for diversity)
- 25 private-project sessions → 0 tasks (repos not public)
- 25 sessions with <3 user messages → 0 tasks
- 16 sessions with no code modifications → 0 tasks
- Remaining → rejected for GPU requirements, local forks, or rebase tasks

### Rejected candidates

| Session | Repo | Msgs | Reason |
|---------|------|------|--------|
| `a48813b3` | radix-ui/primitives | 25 | Main repo (banodoco/Reigh) is private |
| `fd44efbf` | mattdesl/gifenc | 22 | Main repo (banodoco/Reigh) is private |
| `ses_37751` | woct0rdho/triton-windows | 10 | Rebase conflict resolution — not reproducible in Docker |
| `0c813ccf` | thu-ml/SageAttention | 10 | Rebase task — not reproducible |
| 3 desloppify sessions | peteromallet/desloppify | 13-18 | Diversity cap (5 already) |

## How to run

```bash
# Single-turn (agent only)
harbor run -p harbor_tasks/<task> -a claude-code -m claude-opus-4-6 -n 1

# Multi-turn (with simulated user)
.venv/bin/python src/runner.py --config src/config.yaml --task <task>
```

## How to add a new task

1. Find a session in `session_collection/session_analysis.md` with harbor score >= 0.5 and 5+ user messages
2. Run `/extract-analysis-md` prompt or manually create analysis.md following `.claude/prompts/extract-analysis-md.md`
3. Create task directory under `harbor_tasks/` with analysis.md, instruction.md, original_session.json
4. Build Dockerfile, synthesize buggy state, write test.sh
5. Validate: Docker builds, buggy baseline scores > 0, agent run scores > baseline
6. Update this README
