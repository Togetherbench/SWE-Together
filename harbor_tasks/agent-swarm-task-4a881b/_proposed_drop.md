# Proposed DROP: agent-swarm-task-4a881b

## One-sentence summary
The task's `instruction.md` is the body of a `/implement-plan` slash-command wrapper that references a plan file (`plans/2026-03-06-one-time-scheduled-tasks.md`) which is NOT shipped in the Docker sandbox, leaving any rubric forced to choose between (a) scoring the literal-text interpretation of instruction.md (build the wrapper itself) or (b) demanding specific feature semantics no agent can infer — the v3 rubric chose (b) and is therefore unfair by construction.

## Task-level defect that makes the rubric unfixable

The Dockerfile (`harbor_tasks/agent-swarm-task-4a881b/environment/Dockerfile`) clones `desplega-ai/agent-swarm` at commit `cc8c7f5` and does NOT stage the curator-side file `plans/2026-03-06-one-time-scheduled-tasks.md`. The agent's only signal is:

1. `instruction.md` — which reads verbatim as a specification for building the `implement-plan` wrapper + `implementing` skill (autonomy modes, argument parsing, skill invocation rules). The final line is `ARGUMENTS: plans/2026-03-06-one-time-scheduled-tasks.md` — a path that doesn't exist in the sandbox.
2. The filename token `one-time-scheduled-tasks` — a 4-word hint.
3. Existing repo structure under `src/scheduler/`, `src/tools/schedules/`, `src/be/migrations/`.

The oracle patch implements a full 6-phase one-time-scheduling feature (persistence migration, scheduler runtime, MCP tool, HTTP API, list filters with `hideCompleted=true` default, UI badges). NONE of the specific semantics the v3 rubric pins (two timing flavors, mutual-exclusion validation, default-on hide-completed flag, terminal-state update rejection, cron-recompute prohibition) are derivable from the three signals above. They were in the curator's plan file, not the agent's sandbox.

The reviewed trial `__Mxc2Stz` is exactly the literal-text reading: the Opus agent built the `plugin/commands/implement-plan.md` wrapper and `plugin/skills/implementing/skill.md` skill that instruction.md describes, plus bumped `package.json`. That patch scored `reward.txt=1.0` (degenerate verifier) but `judge_score=0.0` against v3 (because v3 explicitly bans that interpretation via `goal_0`). Neither interpretation is wrong — the task is genuinely ambiguous between them, and no rubric edit can resolve the ambiguity without either (i) shipping the plan file, or (ii) rewriting instruction.md to inline the feature spec.

## Verbatim Gemini quotes supporting drop

From `analysis/v3_rubric_audit_gemini_v2/agent-swarm-task-4a881b.json`:

> "The rubric explicitly admits the plan file is missing from the sandbox, yet goals 3, 4, 5, and 6 enforce highly specific feature requirements (e.g., 'Two timing flavors must both be supported', 'hide-already-fired-one-shots flag whose default behavior excludes terminal one-shot rows') that cannot possibly be inferred from the mere filename token `one-time-scheduled-tasks`. These are leaked from the oracle's patch, not derived from the user's utterances." (user_provenance FAIL)

> "The rubric completely drops the literal user ask in T0 (`instruction.md`), which reads as a specification for creating the `implement-plan` wrapper and `implementing` skill. Instead of scoring this valid interpretation, `goal_0` explicitly penalizes it as 'anti-effort'." (coverage_completeness FAIL)

> "The rubric actively penalizes the agent for following the literal text of `instruction.md` (which reads like a spec to create the `implement-plan` wrapper), forcing it instead to guess the contents of a missing file." (headline weakness)

> "The rubric scores specific feature details that were in the oracle's plan file but are completely missing from the agent's sandbox, making the rubric impossible to satisfy without oracle knowledge." (single_biggest_risk)

> "would_judge_fairly: NO"

The v3 author's own `_task_quality_flags.instruction_under_specified` already concedes the same point:

> "instruction.md only contains the slash-command wrapper text, not the plan content. The plan file plans/2026-03-06-one-time-scheduled-tasks.md is not in the Docker image. Agent must infer scope from the filename token `one-time-scheduled-tasks` plus repo exploration. This is the load-bearing fairness fact for v3 phrasing."

Rubric phrasing alone cannot fix a missing-input task. Either the input must be supplied, or the task must be dropped.

## Smallest plausible fix the task would need

Two coordinated edits would salvage it (the rubric alone is NOT enough):

1. **Ship the plan file in the Docker image.** Add to `environment/Dockerfile` (before `USER agent`):
   ```dockerfile
   COPY plan.md /workspace/agent-swarm/plans/2026-03-06-one-time-scheduled-tasks.md
   ```
   and stage the curator's actual plan markdown at `environment/plan.md`. With the plan in the sandbox, all the v3 specific-semantics goals (two timing flavors, hide-completed default, mutual-exclusion, etc.) become legitimately inferable.

2. **Rewrite instruction.md to forward to the plan**, not to spec the wrapper. Something like:
   > "Implement the plan at `plans/2026-03-06-one-time-scheduled-tasks.md`. Follow the phases described there."
   This removes the literal-text trap that invites the Opus interpretation. The `/desplega:implement-plan` slash-command body should NOT be the user-facing instruction.

3. **Then** rewrite the v3 rubric to drop `goal_0`'s blanket ban on wrapper-creation (no longer needed since the plan is now visible) and re-derive goals 3–6 with quote-anchors to the now-shipped plan content.

Without all three, the rubric is structurally unfair: the agent is asked to read a file that doesn't exist, and is then graded on specifics from that file.

## Recommendation

**DROP** for v3 rubric pass. The task can be re-included later if the curator backports the plan file into the Dockerfile and rewrites instruction.md; until then, no rubric can fairly judge submissions.
