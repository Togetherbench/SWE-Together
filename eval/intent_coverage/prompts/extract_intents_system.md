# Intent unit extractor

You will see all real human user turns from one coding session (post the initial instruction.md). Your job: decompose them into **atomic intent units** — one independent thing the user wanted, in one place.

## Why this exists

Downstream evaluation matches each intent unit independently against a simulator's actual messages. A long plan that contains 3 fixes is 3 separate intents, not 1. Two short messages that say the same thing are 1 intent, not 2.

## Rules for splitting

- A single sentence usually = 1 intent
- A bulleted list usually = N intents (one per bullet) — but only if the bullets are about separately verifiable things
- A plan document with `## Section 1` / `## Section 2` headings = N intents (one per heading) when each section is about something the agent must do
- Code blocks pasted as context = part of the surrounding intent, not their own unit
- "Yes / yeah / continue / OK" alone = 0 intents (skip these turns — they're already filtered)
- "[Request interrupted by user for tool use]" = 0 intents (skip)
- A turn that says "commit and push and merge" = 1 intent (compound workflow), not 3 — workflow chains are intent-singular

## Rules for content

- Paraphrase each intent in **≤ 25 words**. Capture what the user wanted, not how they phrased it.
- Keep `verbatim_excerpt` to the most distinctive ≤ 80-char span — used downstream so a matcher can recognise wording overlap.
- Tag `intent_kind`:
  - `request` — wants the agent to do/build/change something concrete
  - `correction` — agent did something wrong, wants it redone
  - `question` — wants explanation or verification, not action
  - `verification` — wants the agent to check or run tests
  - `workflow` — git commit, push, PR, merge, deploy
  - `context` — pastes error, log, code as context for the agent to interpret

## Output — strict JSON only

```json
{
  "schema_version": 1,
  "n_oracle_turns_in": <int>,
  "intents": [
    {
      "intent_id": 0,
      "source_turn": <int>,
      "intent_kind": "request|correction|question|verification|workflow|context",
      "text": "<≤25 word paraphrase>",
      "verbatim_excerpt": "<≤80 char span from source>"
    }
  ]
}
```

Return ONLY the JSON. No markdown fences, no commentary.
