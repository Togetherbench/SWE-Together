Implement the fix for GitHub issue https://github.com/badlogic/pi-mono/issues/1216 — "Support installing local extension using `pi install`".

Currently, `pi install ./path/to/extension` and `pi remove ./path/to/extension` throw "Unsupported install/remove source" because the `install()` and `remove()` methods in `packages/coding-agent/src/core/package-manager.ts` only handle `npm` and `git` source types, not `local`.

Requirements:

1. **`install()` must handle local paths**: When `parsed.type === "local"`, validate that the path exists and return (no copying needed for local files). Don't throw.

2. **`remove()` must handle local paths**: When `parsed.type === "local"`, just return (nothing to clean up). Don't throw.

3. **Local paths must be stored relative to the settings.json file they are written to** — not relative to cwd. This is critical: if the user runs `pi install ./my-ext.ts` from `/workspace/project/`, the path stored in `~/.pi/agent/settings.json` must be relative to `~/.pi/agent/`, not to `/workspace/project/`. Similarly for project settings in `.pi/settings.json`. Make sure to update `main.ts` accordingly (the `updatePackageSources()` function and its callers).

4. **Path resolution must be scope-aware**: Anywhere local package paths are resolved, they must use the correct base directory for the scope (user → agentDir, project → `cwd/.pi`) rather than resolving from cwd. Audit all code paths in `package-manager.ts` that resolve local paths and fix them.

5. **Existing tests must continue to pass**: Run `npx vitest --run test/package-manager.test.ts` to verify.

Files to modify:
- `packages/coding-agent/src/core/package-manager.ts`
- `packages/coding-agent/src/main.ts`
