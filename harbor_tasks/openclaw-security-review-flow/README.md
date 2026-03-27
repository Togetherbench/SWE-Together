# Task: openclaw-implement-b7594a

| Field | Value |
|-------|-------|
| Source session | `b7594a27-0496-43a2-9696-44d14f2df71d` |
| Repo | OpenClaw/OpenClaw (350 stars) |
| Base commit | `17287bc8d01b12a293e0452a76b1c117dd1e42c1` |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 13 |

## User Simulator Behavior

- Total real user messages: 13 in ~50 agent turns. Silence is the default.
- Longest silence: ~15 agent turns (agent implements full TDD + implementation before user responds).
- Turn-by-turn summary:
  - **Turn 1**: Initial task — research OpenClaw, assess for refactoring, address prompt injection, design multi-agent architecture
  - **Turn 2** (after ~10 agent turns, ~6hr gap): "security first, full architecture can come later" — scope narrowing
  - **Turn 3** (after ~8 agent turns): "yes, proceed" — contract approval
  - **Turn 4** (after ~8 agent turns): "how do you plan to test this with actual LLM? Just answer" — design question
  - **Turn 5** (after 1 agent turn): "I still dont understand how it works exactly" — clarification
  - **Turn 6** (immediately): Major pivot — "using LLM as security also to review" — reject pure pattern-matching
  - **Turn 7** (after 1 agent turn): "Let's think through this carefully, what would be the best approach for our philosophy?"
  - **Turn 8** (after 1 agent turn, ~3.8hr gap): Approve risk-tiered + same-LLM-reviewer approach
  - **Turn 9** (after 1 agent turn): "Yes" — approve updated plan
  - **Turn 10** (after ~15 agent turns): "yes, proceed" — approve to TDD phase
  - **Turn 11** (after ~10 agent turns): "yes, start with tests" / "yes, implement them"
  - **Turn 12** (after ~15 agent turns): "yes, proceed with gateway integration"
  - **Turn 13** (after ~10 agent turns): "What's next?"

## Task Description

The agent must implement a security module for the OpenClaw project to protect against prompt injection attacks. Key deliverables in `src/security/`:

- **`risk-tiers.ts`** — Tool risk classification (`classifyTool`, `isBashDestructive`)
- **`pattern-check.ts`** — Fast regex-based injection detection (`checkPatterns`)
- **`risk-classifier.ts`** — Request classifier combining tool risk + pattern escalation (`classifyRequest`, `escalateRisk`)
- **`reviewer.ts`** — LLM reviewer with same API endpoint, different system prompt, NO tools (`REVIEWER_SYSTEM_PROMPT`, `createReviewer`)
- **`decision-flow.ts`** — Main security orchestrator (`createSecurityDecisionFlow` with `evaluate()`)
- **`index.ts`** — Public exports
- **`gateway-integration.ts`** — Bridge to OpenClaw gateway
- **`audit-log.ts`** — Security logging and metrics
- **`approval-manager.ts`** — Human approval for high-risk operations

## Architecture

Risk-tiered security model:
1. **Low risk** (read, search): Pattern check only → auto-approve (<5ms)
2. **Medium risk** (write, send): Pattern check + LLM reviewer → auto-approve if confident
3. **High risk** (delete, exec, bash): Pattern check + LLM reviewer + human approval ALWAYS

The LLM reviewer reuses the existing API endpoint with a security-focused system prompt and NO tools (verdict-only: APPROVE/DENY/ESCALATE). Full conversation history visible to detect multi-turn manipulation.

## Verifier

11 tests: 80% behavioral (Tests 4-11), 20% structural (Tests 1-3).
- Core behavioral tests use `tsx` to import and execute pure functions from `risk-tiers.ts` and `pattern-check.ts`
- Higher-level files (reviewer.ts, decision-flow.ts) use structural fallback if openclaw imports are unavailable

## E2E Results

| Trial | Model | Reward | Sim msgs | Notes |
|-------|-------|--------|----------|-------|
| hsRx4q7 | claude-sonnet-4-6 | 0.80 | 10 | success |

## Traces

- [Simulated run](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-sonnet-4-6/openclaw-implement-b7594a/trials/openclaw-implement-b7594a__hsRx4q7)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/openclaw-implement-b7594a/trials/openclaw-implement-b7594a__original)
