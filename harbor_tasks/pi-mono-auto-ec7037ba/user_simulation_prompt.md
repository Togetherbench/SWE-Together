# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 8
- **Session start**: 2026-01-21T22:26:01.331Z
- **Session end**: 2026-01-21T22:48:34.005Z
- **Session duration**: ~22 minutes
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 8
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

Turn 1 is the initial instruction (instruction.md) — not included in the trigger table.

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has modified at least one CHANGELOG.md file and reported findings | "double check that all attributions are correct by locating the issues/prs via gh cli" | verbatim from session; 233s gap; user wants agent to verify PR authors via GitHub API |
| T3 | Agent has run gh commands to check PR attributions and reported results | "where's the terrobe pr?" | verbatim from session; 55s gap; user noticed agent missed @terrorobe's PR #888 |
| T4 | Agent has acknowledged or fixed the terrorobe attribution | "how many more cl entries did you fuck up?" | verbatim from session; 25s gap; user suspects more attribution errors |
| T5 | Agent has fixed additional attribution errors and reported corrections | "commit and push" | verbatim from session; 67s gap; user satisfied with fixes |
| T6 | Agent has committed changes (git commit output visible) | "then do a new patch release" | verbatim from session; 11s gap; user wants a version bump release |
| T7 | Agent has started or completed a release process | "i aborted the release, it seems the feature we merged doesn't work? https://github.com/badlogic/pi-mono/pull/882 i type @packages which completes to \"@packages/ \" (note the space) and the auto-complete file list disappears. isn't this supposed to not add a space and tab should keep replacing things? oh, maybe the user does completion with enter.\n\nnope, enter will also add a space and not continue auto-completing. what it does do though is that if i delete the space and hit tab again, i get auto-completion for the child folders.\n\nwhy do we add a space if we select an entry with tab or enter? hm, what would be a good pattern for this" | verbatim from session; 467s gap; user discovered autocomplete bug in PR #882 |
| T8 | Agent has modified packages/tui/src/autocomplete.ts to fix the trailing space issue for directory completions | "ok commit and push" | verbatim from session; 495s gap; user approves the fix |
