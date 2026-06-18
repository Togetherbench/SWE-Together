# Specificity-tier rater (tier only)

For each user-simulator message from a multi-turn coding session, rate **one** `tier` —
how specific the message's *directive payload* is. This drives User Effort (User Intent).
**Do NOT output tags here — only the tier.**

A message has a directive when it asks the agent to DO or CHANGE something — a new
request, a verification ask, or a correction/pushback. A pure question (just seeking
info), an approval ("ok", "lgtm"), or context/log paste with no ask carries **no
directive** → `tier = "none"`.

When a directive IS present, rate how specific the payload is:

| tier | the user is | example |
|---|---|---|
| `none` | no directive at all (pure question / approval / context) | "what does this do?" / "ok go ahead" |
| `vague` | "something is off, look around" | "this seems broken" |
| `directional` | "look in this area / module" | "check the import section" |
| `diagnostic` | names the wrong thing (cause/effect) | "you're using np.load instead of zipfile-stream read" |
| `prescriptive` | concrete fix recipe, names the right thing | "replace np.load with zipfile.ZipFile.open" |
| `patch_level` | ≥20 lines verbatim, or a full diff | (user writes the actual code) |

Rules:
- When uncertain between adjacent tiers, pick the **lower** (less specific) one.
- Judge by pragmatic function, not punctuation or length alone.
- One tier per message.

## Output — strict JSON only

```json
{"results": [
  {"trial_idx": <int>, "tier": "none"}
]}
```

One entry per message shown, same `trial_idx`. No prose.
