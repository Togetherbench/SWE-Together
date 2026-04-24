# User Simulation Prompt

## Simulator Calibration

- **Total user messages**: 9
- **Session start**: 2026-01-31T22:10:19.484Z
- **Session end**: 2026-01-31T22:26:54.073Z
- **Intervention style**: Reactive — user corrects after observing agent output
- **Target message count**: 8 (excluding Turn 1 = instruction.md)
- **Default**: SILENCE — only intervene when trigger conditions are met

## Trigger Table

Turn 1 is the instruction.md content (implicit first turn, not in this table).

| ID | Condition | Message | Notes |
|----|-----------|---------|-------|
| T2 | Agent has produced a PR review mentioning dependencies or photon without clarifying whether a new dependency was added | "so this did add a new dependency? we already have some image processing dependency, and i think we moved away from photon" | verbatim from session; user questions dependency story |
| T3 | Agent has finished initial review output (Good/Bad/Ugly sections visible) | "so, good to merge?" | verbatim from session; user asks for merge recommendation |
| T4 | Agent has recommended merge or discussed code changes without addressing placement of conversion logic | "i'm actually a bit confused by the place where the conversion happens, why doesn't this happen soley in the clipboard code path?" | verbatim from session; user questions architectural placement |
| T5 | Agent has responded to T4 without specifically mentioning interactive-mode.ts as the location | "like why is it in the interactive-mode.ts?" | verbatim from session; follow-up to T4 |
| T6 | Agent has explained why conversion is in interactive-mode.ts, possibly suggesting a wrapper or abstraction | "we don't need a wrapper, no? readClipboardImage should just ensure it returns a supported image format" | verbatim from session; user rejects wrapper approach |
| T7 | Agent has suggested using an external library or photon for the conversion | "no, just implement locally we do it ourselves" | verbatim from session; user rejects external dependency |
| T8 | Agent has made code changes to clipboard-image.ts or interactive-mode.ts (git diff shows modified files) | "alright, tested it works, commit and push. also made a fix so npm run dev works for coding-agent, can commit that as well" | verbatim from session; user confirms working + requests commit |
| T9 | Agent has committed and pushed changes (git log shows new commits) | "did you add a proper changelog entry attributed to the contributor? you should" | verbatim from session; user checks changelog attribution |
