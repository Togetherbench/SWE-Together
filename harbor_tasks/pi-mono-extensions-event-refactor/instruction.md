Analyze and fix GitHub issue: https://github.com/badlogic/pi-mono/issues/1280

Steps:

1. Read the issue in full, including all comments and linked issues/PRs.

2. Read all related code files in full (no truncation). The key files are in `packages/coding-agent/src/core/extensions/`.

3. Trace the code path and identify the actual root cause of the bug.

4. Implement the fix. The core problem is in how `tool_result` events are handled in the extension runner - multiple handlers clobber each other. Fix both the runner and any callers.

5. Make sure to clean up types properly - the fix should be type-safe and not leave stale casts or imports.

6. After implementing, commit your changes.
