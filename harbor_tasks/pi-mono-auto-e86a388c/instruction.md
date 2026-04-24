Analyze GitHub issue(s): https://github.com/badlogic/pi-mono/issues/886 please locate the PR by the issue contributor with that strictResponses crap. then check openai-responses.ts and where i fucked up porting that over. it should implement what the guy had by default, without the need for that strictResponses compat flag

Steps:

1. Read the issue in full, including all comments and linked issues/PRs.
2. Find the PR by the issue contributor that adds `strictResponsesPairing`.
3. Read the PR's code changes to understand the fix approach.
4. Read `packages/ai/src/providers/openai-responses.ts`, specifically the `convertMessages` function.
5. Read `packages/ai/src/providers/transform-messages.ts` to understand how cross-model messages are handled.
6. Implement the fix in `convertMessages`: handle same-provider different-model handoff in OpenAI Responses API so the strict response pairing works by default (no opt-in flag needed).
7. Make sure the code compiles: `cd packages/ai && npx tsc --noEmit -p tsconfig.build.json`
8. Commit your changes.
