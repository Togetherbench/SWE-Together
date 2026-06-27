# Task: gemini-voyager-task-16a5c7

| Field | Value |
|-------|-------|
| Source session | `16a5c736-9609-48fb-8a10-a4595c039b21` |
| Repo | Nagi-ovo/gemini-voyager (7668 stars) |
| Base commit | `75c76ffc` (parent of session commit) |
| Difficulty | easy |
| Category | bugfix |
| Real user msgs | 4 |

## Summary

Google sent a trademark complaint about "Gemini Voyager" using the GEMINI trademark without authorization. The user needs to rename the extension's user-facing strings from "Gemini Voyager" to "Voyager" to comply — specifically the extension name in locale files, export footers, and the prompt manager title. GitHub files, console log prefixes, and internal identifiers should remain unchanged.

## User Simulator Behavior
- Total real user messages: 4 in 8 turns. Silence is the default.
- Longest silence: ~75 seconds between user messages
- Turn 1: Forwards trademark notice, asks for rename, specifies scope (extension only, not GitHub)
- Turn 2: "google drive 这个不用改吧" — further narrows scope
- Turn 3: "只做最必要的" — only the most necessary changes
- Turn 4: "你再检查一下会不会有什么问题" — requests final sanity check
- User is Chinese-speaking, knowledgeable about Chrome extensions. Tends to give broad instructions then iteratively narrow.

## Test Plan
- Behavioral (gold): No "Gemini Voyager" in locale message values, export footers, or prompt title
- Behavioral (silver): "Voyager" appears as extName in ≥5 locale files
- Structural (bronze): Test file expectations match production changes
- P2P regression: Key source files exist (no deletions allowed)
