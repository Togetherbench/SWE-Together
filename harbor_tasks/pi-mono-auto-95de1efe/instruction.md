Fix GitHub issue: https://github.com/badlogic/pi-mono/issues/2431

Read the issue carefully. Then independently trace the code to find and fix the root cause. Your fix should:

1. Prevent invalid extension provider registrations from crashing the application
2. Ensure no partial state is left behind when a registration fails (validate before mutate)
3. Handle errors at every call site where provider registration can fail — not just the obvious one
4. Update types and error reporting to identify which extension caused the error
5. Not break any existing tests (`npx vitest --run model-registry.test` and `npx vitest --run extensions-runner.test`)
