Investigate parallel tool execution vs interactive tools stalling in this repo.

Goal:
1) Confirm whether the issue exists and where.
2) Propose multiple solution options, with tradeoffs, and consult oracle for architecture feedback.

Scope and constraints:
- Repo: /Users/alioudiallo/code/src/github.com/aliou/pi-mono
- Do not implement code changes yet.
- Produce an investigation + design memo only.
- Be concise but technically complete.
- Read full files you inspect.

What to inspect first:
- packages/agent/src/agent-loop.ts
- packages/agent/src/types.ts
- packages/agent/src/agent.ts
- packages/coding-agent/src/modes/interactive/interactive-mode.ts
- packages/coding-agent/src/core/extensions/runner.ts
- packages/coding-agent/docs/extensions.md
- relevant tests/changelog entries about parallel tool execution

Tasks:
1. Confirm behavior
   - Trace exact execution path for tool calls in sequential vs parallel modes.
   - Confirm default mode and where set.
   - Verify whether interactive UI calls (select/confirm/input/editor/custom) are concurrency-safe.
   - Identify concrete stall/race mechanism (if present), with code references and line ranges.
   - Check tests/docs: what is covered and what is missing.

2. Reproduction plan
   - Provide a minimal reproducible scenario (extension/tool flow) that would trigger the stall.
   - If no automated repro exists, provide a deterministic manual repro.

3. Solution options
   Propose at least 4 options, including:
   - A) Global serialize of interactive dialogs (UI mutex/queue)
   - B) Mark tools as interactive and force sequential execution for those calls
   - C) Hybrid scheduler (parallel non-interactive, serialized interactive)
   - D) Fallback/error strategy when concurrent interactive requests occur
   For each option include:
   - What changes where (files/functions)
   - Correctness/risk
   - UX impact
   - Backward compatibility
   - Complexity
   - Test strategy

4. Oracle consultation
   - Before calling oracle, state explicitly that you are consulting oracle and why.
   - Ask oracle to review root-cause reasoning and compare the options.
   - Include oracle feedback verbatim-ish summary and whether you agree/disagree.

5. Recommendation
   - Give a ranked recommendation (1st/2nd choice), with rationale.
   - Provide phased rollout plan and safety checks.
   - List unresolved questions at the end.

Output format:
- Executive summary
- Evidence (with file:path#line refs)
- Reproduction
- Option matrix
- Oracle feedback
- Final recommendation
- Unresolved questions
