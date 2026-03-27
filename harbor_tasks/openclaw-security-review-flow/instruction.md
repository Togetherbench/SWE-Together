This is a massive project, you should look into its docs and online to understand the context on how this project is being used and why it's trending. Then your next task would be to assess this project for refactoring based on our own philosophy, and to address its shortcomings, like the prompt-injection type attack. Ideally I think this should become a multi-agent workflow where there are many different departments to go through, mirroring human like HR, security and such so that we can mitigate attack risk and break down task in order to let agents do them better

---

**Clarification: security first, full architecture can come later.**

Focus on building a prompt-injection security module in `src/security/`. The approach should be a **risk-tiered** system:

1. **Tool risk classification** (`src/security/risk-tiers.ts`): Classify tools by risk level. `bash`, `exec`, `delete` = **high risk**. `write`, `send` = **medium risk**. `read`, `search`, `grep`, `ls`, `view` = **low risk**. Include an `isBashDestructive(command)` helper that flags dangerous shell commands (`rm -rf`, `sudo`, `dd`, `chmod -R 777 /`, etc.) while passing safe ones (`ls`, `cat`, `echo`, `grep`, `git status`).

2. **Pattern-based injection detection** (`src/security/pattern-check.ts`): Fast regex detection (<5ms) for classic prompt injection phrases like "ignore all previous instructions", "disregard prior instructions", "forget your guidelines", "you are now a different AI", "new instructions:", "SYSTEM: override". Export a `checkPatterns(text)` function that returns whether the input is suspicious.

3. **Risk escalation** (`src/security/risk-classifier.ts`): Combine tool risk + pattern detection. If patterns are suspicious, escalate the risk tier (low->medium, medium->high, high stays high). Export `escalateRisk(tier)`.

4. **LLM reviewer** (`src/security/reviewer.ts`): For medium/high risk actions, use the same LLM endpoint (not a separate model) with a different system prompt to review the request. The reviewer has NO tools -- it can only output APPROVE/DENY/ESCALATE. It sees full conversation history to catch multi-turn manipulation. Export `REVIEWER_SYSTEM_PROMPT` as a string.

5. **Decision flow orchestrator** (`src/security/decision-flow.ts`): Main entry point. Low risk = pattern check only, auto-approve. Medium risk = pattern check + LLM reviewer. High risk = pattern check + LLM reviewer + always require human approval. Export `createSecurityDecisionFlow(config)` that returns an object with an `evaluate()` method.

6. **Index** (`src/security/index.ts`): Public exports for the module.

All files should be TypeScript and follow the project's existing patterns.
