# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 8
- **Session start**: 2026-01-25T00:27:02.885Z
- **Session end**: 2026-01-25T00:40:19.731Z
- **Session duration**: ~13 minutes
- **Intervention style**: Reactive — user corrects and directs after observing agent output
- **Target message count**: 8
- **Default**: SILENCE — only intervene when trigger conditions are met

## Context

The user is working in a TypeScript monorepo (`pi-mono`) containing multiple npm packages. They want to explore npm keyword search, then add a unique keyword `pi-package` to their published packages for discoverability, document it in markdown files, and commit/push the changes.

## Trigger Table

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has responded to the initial question about npm keyword search (at least one assistant message produced) | "so we can't search just by keywords?" | Verbatim from session. User probes whether keyword-only search is possible after agent explains npm search mechanics. |
| T3 | Agent has discussed keyword search limitations or provided npm search results | "ok, i think we should ensure that we have a unique keyword we can search for, how about pi-package?" | Verbatim from session. User proposes adding a unique keyword after learning about search limitations. |
| T4 | Agent has started modifying a package.json file (any file matching `*/package.json` has been edited) OR agent asks which packages to add the keyword to | "no, add it to ../pi-doom/ ../pi-package-test/ and ../pi-gitlab-duo/" | Verbatim from session. User corrects the agent's target — wants keyword in specific sibling repos, not the current package. Note: these directories may not exist in the container; agent must handle gracefully. |
| T5 | Agent has modified or attempted to modify package.json files to add the pi-package keyword | "then publish new versions of these" | Verbatim from session. User asks to publish after keyword was added. Agent may not have npm auth; it should attempt or explain limitations. |
| T6 | Agent has discussed or attempted publishing, OR agent reports that publishing is not possible | "ok, we should document this keyword in @packages/coding-agent/docs/extensions.md @packages/coding-agent/README.md and any other .md file that talks about pi packages." | Verbatim from session. User pivots to documentation after publish step. |
| T7 | Agent has modified at least one .md file under packages/coding-agent/ | "search" | Verbatim from session. User asks agent to search (npm search) to verify keyword discoverability. |
| T8 | Agent has performed an npm search or reported search results after documentation changes | "ok commit an dpush the changes in the working dir" | Verbatim from session (includes original typo). User asks agent to commit and push all changes. |
