Analyze and fix GitHub issue: https://github.com/badlogic/pi-mono/issues/1745

1. Read the issue in full, including all comments and linked issues/PRs.
2. Do not trust analysis written in the issue. Independently verify behavior and derive your own analysis from the code and execution path.
3. Trace the code path through the source code and identify the actual root cause.
4. Implement a fix:
   - Follow the existing patterns and architecture in the codebase (study how other provider-specific behaviors are handled via the compat layer)
   - Only affect the specific model(s) that need different values — NOT all models on the same provider. Other Groq models like `openai/gpt-oss-20b` accept standard reasoning_effort values and must not be changed.
   - Update the custom-provider documentation at `packages/coding-agent/docs/custom-provider.md`
5. Ensure TypeScript compilation passes after your changes (`npm run check` or `npx tsgo --noEmit`).
