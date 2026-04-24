You are working on the `pi-mono` monorepo. Fix the following bug:

**Bug (GitHub issue #904):** In the TUI package (`packages/tui`), the slash command autocomplete menu incorrectly triggers when `/` is typed at the start of any newline, even when there is already content on other lines in the editor. The menu should only open when the editor input is otherwise empty.

After fixing, add a changelog entry in `packages/tui/CHANGELOG.md` under `## [Unreleased]` with a `### Fixed` section referencing issue #904, and verify the code compiles with `npx tsgo --noEmit`.
