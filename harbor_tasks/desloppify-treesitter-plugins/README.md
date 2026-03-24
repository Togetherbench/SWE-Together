# Task: desloppify-treesitter-plugins

| Field | Value |
|-------|-------|
| Source session | `7402f7a5-333f-4bda-853b-22454e76e3e9` |
| Repo | peteromallet/desloppify (2562 stars) |
| Base commit | `295d3215` |
| Ground truth | Commit `119be4db` (generic plugins first-class) + later tree-sitter commits |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 11 |
| Expert time estimate | 30 min |

## E2E Results (pre-hardening)

| Metric | Value |
|--------|-------|
| Reward | **0.75** |
| Sim msgs | 5 |
| Real msgs | 11 |

> Note: These results are from BEFORE test hardening. Tests have since been hardened to reduce gaming.

## Test Hardening Status

Partial credit at 0.75 -- agent completed the generic plugin registration but missed some integration points (scoring policy, narrative, shared phases). Tests may need hardening to distinguish partial from full implementations.

## User Simulator Behavior

- **Total real user messages: 11** in 250 turns. Silence is the default during long implementation stretches.
- **Longest silence: 87 agent turns** between session start and first follow-up.
- User provides a detailed 12,917-char plan upfront, then steers with short follow-up questions. Never repeats instructions.
- Most follow-ups are 1-sentence probing questions ("what about all the other tools?", "is this implementation beautiful?").
- Turn 1: Delivers comprehensive 5-step plan for making generic plugins first-class citizens.
- Turn 2 (after 87 turns): "can you find a random repo to test a random language?"
- Turn 3: "wait, i think we have a rust repo locally somewhere, test that" (redirect)
- Turn 4: "what about all the other tools?" (breadth check)
- Turn 5: "And do we track the quality of each language implementation?" (feature probe)
- Turn 7: "is this implementation beautiful?" (code quality challenge)
- Turn 9: "Is there a python package that does all that stuff?" (tree-sitter research)
- Session ended with user interruption during ExitPlanMode -- agent had written 18,255-char tree-sitter plan but zero implementation code.
- [Summary: 5 sim msgs vs 11 real msgs, 0.45x ratio]

## Traces

- [Simulated run (Opus)](https://together.lishengzhi.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/desloppify-treesitter-plugins/trials/desloppify-treesitter-plugins__XxABMYf)
- [Original session](https://together.lishengzhi.com/jobs/trials/tasks/original-session/original-session/original/claude-opus-4-6/desloppify-treesitter-plugins/trials/desloppify-treesitter-plugins__original)
