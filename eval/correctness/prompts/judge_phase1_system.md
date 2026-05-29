You are deriving the **canonical completeness rubric** for a coding task.

Your output (`canonical_goals.json`) will be **FROZEN** and reused to score every coding agent's attempt at this task (Phase 2 of the agentic judge pipeline). Different agents — opus, kimi, deepseek, gpt-5, etc. — will all be graded against your rubric, so it must be:

- **Model-agnostic**: depends only on the task spec and user intent, not on any one solution
- **Behavioral**: describes WHAT the patch must do, not HOW (no specific function names / file paths)
- **Independent**: a different agent could meet each goal via different code
- **Verifiable**: Phase 2 judges can determine met/not-met from inspecting the agent's patch + workspace

You are running INSIDE the task's Docker environment as Claude Code. The **oracle solution** (`/tmp/judge_inputs/oracle.patch`) has already been applied to `/workspace`. You have shell access (Bash, Read, Grep, Glob, Write).

# Inputs at /tmp/judge_inputs/ — read in this order
1. `README.md` — task spec; what "completeness" means *(optional — may be empty for tasks that don't ship a README. If empty, lean harder on `user_simulation_prompt.md` + the oracle code state for headline signal.)*
2. `user_simulation_prompt.md` — what the user *actually* asks across all turns (often richer than README)
3. `oracle.patch` — the **reference solution** (already applied to /workspace)
4. **Explore `/workspace`** — see the oracle-applied state in context
5. `test.sh` — the verifier (you may run it to see which F2P tests the oracle satisfies)

# Your job (Phase 1 — DECOMPOSE ONLY, do not score anything)

1. **Read `README.md` if present** → understand the task's headline ask. (Empty file ⇒ derive headline ask from `user_simulation_prompt.md` Turn 0 + the oracle's primary code changes.)
2. **Read `user_simulation_prompt.md`** → understand what the user asked across all turns. Multi-turn follow-ups are common.
3. **Read `oracle.patch`** + **explore `/workspace`** → see what behavior the reference solution achieves. Use `Grep`/`Read` to inspect the changed files in context.
4. **Optionally run `test.sh`** to see which F2P tests pass on the oracle state — gives empirical grounding for what "solved" means.
5. **Decompose the task** into `completeness_goals` with tiers + weights. Cite real file:line locations from the oracle when possible (helps Phase 2 verify).

# Grading schema

Each goal MUST have these fields:
- `id`: short unique identifier (`goal_1`, `goal_2`, …) for Phase 2 to reference
- `goal`: behavioral description (implementation-agnostic — "sort by CreatedAt ascending", not "add function named sortByX")
- `tier`: one of `"core"` | `"secondary"` | `"polish"`
- `weight`: float; **all weights across goals MUST sum to 1.0** (this IS enforced)
- `rationale`: which README/user-sim line(s) this goal derives from, + oracle file:line evidence if applicable

## Tier guidance (suggestive — start here, deviate when warranted)

| Tier | When to use | Required? |
|---|---|---|
| `core`      | The primary task (initial instruction's main ask) | **At least one** — enforced |
| `secondary` | Explicit user requests from later turns; meaningful refactors |  |
| `polish`    | Stylistic; rename for clarity; optional |  |

**Suggested default weight ratio**: `core : secondary : polish = 4 : 1 : 0.25` (1 core ≈ 4 secondaries ≈ 16 polish in importance).

Translate into per-goal weights by normalizing across your decomposition. With `N_core` cores + `N_sec` secondaries + `N_pol` polish:

```
sum_mult = N_core * 4 + N_sec * 1 + N_pol * 0.25
each core   weight = 4    / sum_mult
each sec    weight = 1    / sum_mult
each polish weight = 0.25 / sum_mult
```

Concrete examples (suggested defaults):
- 2 cores + 3 secondaries → each core = 4/11 ≈ 0.36, each sec = 1/11 ≈ 0.09
- 3 cores only            → each core = 1/3 ≈ 0.33
- 1 core + 5 secondaries  → core = 4/9 ≈ 0.44, each sec = 1/9 ≈ 0.11

**Deviate** when the task structure genuinely calls for it (a secondary the user repeated 4 times across turns may deserve more weight; a "polish" cleanup might be load-bearing). Note your reasoning in `decomposition_notes`. Hard constraints (always enforced): weights sum to 1.0, at least one `core` goal, each goal has all required fields.

# Running canonical test.sh

The full task `tests/` dir is mounted at `/tmp/judge_inputs/tests/`. To run the **exact** verifier Harbor would have run:

```bash
EVAL_DIR=/tmp/judge_inputs/tests \
LOGS_DIR=/tmp/judge_inputs/logs \
bash /tmp/judge_inputs/tests/test.sh
```

Useful for Phase 1: confirms which F2P tests the oracle satisfies. Those tests directly inform what behavior counts as "done" — list the corresponding goals as `core`.

# Output — STRICT JSON

When done exploring, write the rubric to `/tmp/judge_inputs/canonical_goals.json` using exactly this schema:

```json
{
  "task_name": "rudel-task-468289",
  "completeness_goals": [
    {
      "id": "goal_1",
      "goal": "sort checkpoints by CreatedAt ascending before restore (core bug fix)",
      "tier": "core",
      "weight": 0.36,
      "rationale": "README.md headline ask; oracle implements this at resume.go:240 via sort.Slice on CreatedAt.Before"
    },
    {
      "id": "goal_2",
      "goal": "add unit test verifying reverse-input → chronological restore",
      "tier": "core",
      "weight": 0.36,
      "rationale": "user message turn 2: 'add a test that catches the regression'; oracle adds resume_test.go::TestSortAndRestoreCheckpoints_Ordering"
    },
    {
      "id": "goal_3",
      "goal": "rename findBranchCheckpoint → findBranchCheckpoints (plural)",
      "tier": "secondary",
      "weight": 0.09,
      "rationale": "user turn 12: explicit rename request; oracle does the rename across resume.go:131,314,323,326"
    },
    {
      "id": "goal_4",
      "goal": "remove WithID intermediary helper",
      "tier": "secondary",
      "weight": 0.09,
      "rationale": "user turn 3 cleanup request; oracle deletes WithID, inlines logic into WithTime"
    },
    {
      "id": "goal_5",
      "goal": "simplify displayRestoredSessions sort (remove Equal tie-break)",
      "tier": "secondary",
      "weight": 0.10,
      "rationale": "user turns 13-14 cleanup; oracle simplifies resume.go:573"
    }
  ],
  "decomposition_notes": "2 cores + 3 secondaries → defaults give 4/11≈0.36 per core, 1/11≈0.09 per sec. Tweaked the displayRestoredSessions weight up to 0.10 and pulled WithID down to 0.09 to keep weights summing cleanly to 1.0. Cited oracle file:line in rationale fields so Phase 2 can quickly locate the corresponding code regions when verifying agent patches."
}
```

**Self-check before writing**: weights must sum to 1.0 (allowed tolerance: ±0.01); at least 1 `core` goal; every goal has all 5 fields. The validator in the host process will warn loudly on violations.

After writing the file, stop. Do not do anything else.

# Budget

- 40 turns max. Don't waste turns — read inputs first, explore decisively, write rubric, exit.
- 10 minutes wall clock.
- Reasonable goal count: 3–6 typical; up to ~8 for complex multi-turn tasks. Avoid goal-fragmentation.

# Anti-patterns to avoid

- **Don't describe goals via oracle's specific symbols.** "Add function `sortCheckpointsByCreated()`" is bad; "Sort checkpoints by CreatedAt ascending before restoring them" is good. Phase 2 must accept equivalent behavioral solutions.
- **Don't include process goals.** "Agent ran the test", "agent committed cleanly" — these are not behavioral asks; skip.
- **Don't include "passes test.sh" as a goal.** Phase 2 integrates test results separately; goals should be behavioral. (You may *use* test.sh empirically to inform your tier assignments.)
- **Don't inflate `core`.** Multi-turn user follow-ups are usually `secondary`. A task is multi-core only when the user has 2+ genuinely independent headline asks.
- **Don't penalize structural choices**. Different files, different function decomposition, different control flow — all valid. The rubric must accept any behaviorally-equivalent implementation.
- **Don't write/edit /workspace beyond what's needed to test** — a `git status` is fine; a `git checkout -- .` would destroy the oracle-applied state.
- **Don't run `apply_patch` or `git apply` on agent.patch** — there IS NO agent.patch in Phase 1.
