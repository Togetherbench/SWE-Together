# Multi-label message tagger

Tag each user-simulator message from a multi-turn coding session. **Multi-label** — one message can carry several tags (a skeptical question is BOTH `question` AND `nudge`; "fix X and also add Y" is BOTH `correction` AND `request`). Also rate `frustration` (0/1) and `tier`.

The 8 content tags fall in three layers; `frustration` is a separate axis.

## Corrective layer — does the user push back on the agent's work? (drives User Correction)

| tag | meaning |
|---|---|
| `correction` | **explicit**: ASSERTS the agent did wrong / incomplete / off-track → redo. Includes soft corrections that report a broken result ("we broke tests", "this is still failing") and corrections of a misunderstanding ("i meant X", "no, I'm saying Y"). Test: does it *assert* a defect? |
| `nudge` | **implicit**: only DOUBTS or implies the agent erred, without asserting it — a skeptical/leading question ("are you sure all 4 corners snap?", "proper fix or just a hack?", "shouldn't this be Y?"), a doubtful re-run ("run it again"), or an error/log pasted as a hint. Doubt, not a verdict. |

## Ask layer — non-corrective intent

| tag | meaning |
|---|---|
| `request` | new requirement / new scope ("now add X", "implement Y") |
| `question` | genuine info-seeking, no implied doubt ("what does X do?") |
| `verification` | neutral check / confirm, no implied doubt ("run the tests") |

## Free / mechanical — connective tissue, no corrective or new-scope content

| tag | meaning |
|---|---|
| `workflow` | git commit/push/PR, "continue", `/cmd` |
| `approval` | "ok", "yes do it", "go ahead", "lgtm" |
| `context` | pastes error / log / code / facts as background |

## Affect — separate, orthogonal axis

`frustration`: `0` neutral, `1` if venting / annoyed / profanity (regardless of content). Co-occurs with any tags.

## tier — specificity of the directive (drives User Intent)

`tier = "none"` UNLESS the message carries a directive (`request`, `verification`, `correction`, or `nudge`). A pure `question`/`approval`/`context` specifies nothing → `"none"` (NOT "vague"). When a directive IS present, rate how specific the payload is:

| tier | the user is | example |
|---|---|---|
| `vague` | "something is off, look around" | "this seems broken" |
| `directional` | "look in this area / module" | "check the import section" |
| `diagnostic` | names the wrong thing (cause/effect) | "you're using np.load instead of zipfile-stream read" |
| `prescriptive` | concrete fix recipe, names the right thing | "replace np.load with zipfile.ZipFile.open" |
| `patch_level` | ≥20 lines verbatim, or a full diff | (user writes the actual code) |

When uncertain between adjacent tiers, pick the **lower** one.

## Rules

- Every message gets **≥1 base tag** (base = the Ask + Free/mechanical tags). The Corrective layer rides ON a base act (`[question, nudge]`, `[request, correction]`).
- Judge by pragmatic **function, not punctuation**. A `?` doesn't make it a `question`; "run it again" can be a `nudge`.
- **New scope is `request`, not `correction`.** "wait, now also add dark mode" = `[request]`. "wait, that's the wrong approach, do Y" = `[correction]`. A message can be BOTH `[correction, request]` (fixes a mistake AND adds scope).
- A user apologizing for **their own** slip ("my bad, forgot to push the file") then asking = `[request]`, NOT correction.
- `correction` **asserts** a defect; `nudge` only **doubts** one. Between them: asserts → correction, doubts → nudge.

## Output — strict JSON only

```json
{"results": [
  {"trial_idx": <int>, "tags": ["..."], "frustration": 0, "tier": "none"}
]}
```

One entry per message shown, same `trial_idx`. No prose.
