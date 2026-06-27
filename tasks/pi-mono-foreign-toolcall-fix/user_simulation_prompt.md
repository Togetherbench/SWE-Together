# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 17
- **Session start**: 2026-03-22T03:59:48.873Z
- **Session end**: 2026-03-22T04:40:47.009Z
- **Intervention style**: Reactive — user corrects after observing agent output, then directs fix
- **Target message count**: 5-8 (subset of original 17 — many turns are rapid-fire refinements)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

The table below contains verbatim user messages from the original session.
Fire them in order (T2 first, then T3 if applicable, etc.) — never skip ahead.
Only fire a message if its condition is met. If no condition is met, stay SILENT.

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has read the JSONL file and produced analysis about the error (mentions "Invalid", "tool call", or the error message) but has NOT yet referenced the specific ID `fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi` | fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi\n\nwhy would this happen?\n\nuser started with openai-codex/gpt then switched to github-copilot/gpt, why would that error happen after the last message? | verbatim from session — gives the agent the specific problematic ID |
| T3 | Agent has attributed the error to the "codex" backend rather than identifying github-copilot as the source of the foreign ID | it wasn't codex backend it was github copilot backend that fucked up | verbatim correction — skip if agent already identified copilot |
| T5 | Agent has discussed the error cause but has NOT looked at the source code in packages/ai/src/providers/ | um, do an ad-hoc node script see @packages/ai/test/stream.test.ts how to get the codex backend oauth api key shit, then construct a synthetic context and do a complete call and see if you can repro | verbatim — directs agent toward the codebase |
| T8 | Agent has found normalizeToolCallId or the ID normalization code and is discussing the character replacement issue | i guess we shouldn't change / into _? | verbatim — design hint |
| T9 | Agent agrees the slash-to-underscore replacement is problematic | only have a _ after fc? | verbatim — design refinement |
| T10 | Agent is discussing the fc_ prefix approach | for "foreign" ids | verbatim — scopes the fix to foreign IDs only |
| T12 | Agent has identified the root cause (normalizeToolCallId doing simple character replacement on foreign tool-call IDs) OR has produced analysis of why the error occurs, AND has NOT started modifying packages/ai/src/providers/openai-responses-shared.ts | ok, fix it, ensure lenght of id is within bounds! | verbatim — critical: green light to implement fix |
| T13 | Agent has started modifying openai-responses-shared.ts but has NOT yet run any tests | test first with the string from copilot | verbatim — directs testing order |
| T16 | Agent has implemented the fix AND tests pass | Wrap it.\n\nAdditional instructions: \n\nDetermine context from the conversation history first.\n\nRules for context detection:\n- If the conversation already mentions a GitHub issue or PR, use that existing context.\n- If the work came from `/is` or `/pr`, assume the issue or PR context is already known from the conversation and from the analysis work already done.\n- If there is no GitHub issue or PR in the conversation history, treat this as non-GitHub work.\n\nUnless I explicitly override something in this request, do the following in order:\n\n1. Add or update the relevant package changelog entry under `## [Unreleased]` using the repo changelog rules.\n2. If this task is tied to a GitHub issue or PR and a final issue or PR comment has not already been posted in this session, draft it in my tone, preview it, and post exactly one final comment.\n3. Commit only files you changed in this session.\n4. If this task is tied to exactly one GitHub issue, include `closes #<issue>` in the commit message. If it is tied to multiple issues, stop and ask which one to use. If it is not tied to any issue, do not include `closes #` or `fixes #` in the commit message.\n5. Check the current git branch. If it is not `main`, stop and ask what to do. Do not push from another branch unless I explicitly say so.\n6. Push the current branch.\n\nConstraints:\n- Never stage unrelated files.\n- Never use `git add .` or `git add -A`.\n- Run required checks before committing if code changed.\n- Do not open a PR unless I explicitly ask.\n- If this is not GitHub issue or PR work, do not post a GitHub comment.\n- If a final issue or PR comment was already posted in this session, do not post another one unless I explicitly ask. | verbatim — wrap-up |
| T17 | Agent has completed the wrap-up (committed, pushed, or attempted to) | exit | verbatim — end session |

## Notes

- Turns T4, T6, T7, T11, T14, T15 are omitted from the trigger table because they are rapid-fire refinements during a debugging session that are unlikely to match cleanly in sim evaluation. Their content is preserved here for reference but should not be fired.
- T12 is the MOST CRITICAL turn — it transitions from analysis to implementation. Its condition is intentionally broad so it fires after any reasonable analysis.
- The task is inherently multi-turn: instruction.md asks only "locate it, tell me why this happened." The fix request comes at T12.
