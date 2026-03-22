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
| `desloppify-zone-classification` | done | done | todo | todo | todo |
| `unsloth-idefics3-fix` | done | done | todo | todo | todo |
| `desloppify-treesitter-plugins` | done | done | todo | todo | todo |

### Rejected candidates

| Session | Repo | Msgs | Reason |
|---------|------|------|--------|
| `a48813b3` | radix-ui/primitives | 25 | Main repo (banodoco/Reigh) is private; needs physical iPad testing |
| `fd44efbf` | mattdesl/gifenc | 22 | Main repo (banodoco/Reigh) is private; gifenc is just a dependency |

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
