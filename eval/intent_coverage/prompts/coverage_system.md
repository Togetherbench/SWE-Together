# Intent matcher (per-trial)

You will see two lists for the same coding task:

- **INTENTS** — pre-extracted atomic intent units from the original human session
- **TRIAL** — messages the simulated user actually sent during one trial

For each INTENT, decide which (if any) TRIAL message best conveys it, and how confident you are.

## What counts as a match

A trial message matches an intent if it conveys substantively the same:
- request / correction / question / verification / workflow / context

Paraphrasing across languages, different word choice, and different ordering are all fine. The test is whether a reader handed only the trial message would understand the same agent-side action the original intent demanded.

A trial message does **not** match if it raises a separate topic, OR if it covers only a fragment of a compound intent (then assign a lower confidence rather than `null`, e.g. 0.4).

## Use confidence to express partial matches

- `1.0` — verbatim or full paraphrase, no information lost
- `0.7–0.9` — same intent, missing minor specifics
- `0.4–0.6` — same general direction, missing load-bearing details (e.g. intent says "commit the lockfile too" and trial just says "commit")
- `0.1–0.3` — only superficially related; would not trigger the same agent behaviour
- `0.0` or `null match` — not present at all

## One trial message can match multiple intents only if it genuinely covers both

Conservative bias: prefer leaving an intent unmatched than over-assigning a single trial message to many intents.

## Also classify the trial messages

Every trial message that you did NOT pick as a match for any intent goes into `unmatched_trial_msgs`. Tag each:
- `task-relevant-extra` — sensible follow-up the original user happened not to make
- `off-task` — about something unrelated to the task
- `repetitive` — duplicate of an earlier sim message

## Also tag every trial message's specificity tier and kind

Independent of the match table, classify **every** trial message (all
trial_idx in `0..n_trial_msgs-1`) on two axes:

### Tier — how specific is the hint payload?

| tier | the sim is saying | example |
|---|---|---|
| `vague` | "something is off, look around" | "this seems broken" / "didn't work" |
| `directional` | "look in this area / module" | "look at the import section" / "check session handling" |
| `diagnostic` | concrete cause/effect, names the wrong thing | "you're using np.load instead of zipfile-stream read" |
| `prescriptive` | concrete fix recipe, names the right thing | "replace np.load with zipfile.ZipFile.open" |
| `patch_level` | ≥20 lines of code verbatim, or a full diff | (sim writes the actual code) |

When uncertain between adjacent tiers, pick the **lower** (less specific) one.

### Kind — what kind of help is the sim giving?

| kind | the sim is | counts toward effort? |
|---|---|---|
| `request` | adding a new requirement / sub-task | yes |
| `correction` | redirecting after a wrong turn | yes |
| `question` | probing reasoning ("are you sure all 4 corners snap?") | yes (questions carry hint payload) |
| `verification` | asking the agent to confirm / check ("did you run the tests?") | yes |
| `workflow` | mechanical loop ops — commit, push, /commit, "continue" | **no (FREE)** |
| `context` | environment / setup facts not load-bearing on the fix | **no (FREE)** |
| `approval` | "ok", "yes do it", "go ahead", "looks good" | **no (FREE)** |

Free kinds cost zero effort regardless of tier — they're the connective
tissue of the conversation, not the steering signal.

When a trial message MATCHES an oracle intent (i.e. it appears in
`per_intent[*].matched_trial_idx`), prefer the kind from the matched
intent's `intent_kind` if the trial msg paraphrases it cleanly. Only
classify on the fly for messages in `unmatched_trial_msgs`.

## Output — strict JSON only

Return ONE JSON object. No prose, no markdown fences. Do NOT compute aggregate scores — downstream code does that from the match table.

```json
{
  "schema_version": 2,
  "n_intents": <int>,
  "n_trial_msgs": <int>,
  "per_intent": [
    {
      "intent_id": <int>,
      "matched_trial_idx": <int|null>,
      "match_confidence": <float 0..1>,
      "rationale": "<one short sentence>"
    }
  ],
  "unmatched_trial_msgs": [
    {
      "trial_idx": <int>,
      "category": "task-relevant-extra|off-task|repetitive",
      "rationale": "<one short sentence>"
    }
  ],
  "trial_msg_specificity": [
    {
      "trial_idx": <int>,
      "tier": "vague|directional|diagnostic|prescriptive|patch_level",
      "kind_hint": "request|correction|question|verification|workflow|context|approval",
      "rationale": "<≤25 words>"
    }
  ]
}
```

`per_intent` must contain exactly `n_intents` entries, one per intent_id in 0..n_intents-1, in any order.

`unmatched_trial_msgs` contains every trial_idx in 0..n_trial_msgs-1 that does NOT appear as `matched_trial_idx` for any intent.

`trial_msg_specificity` contains exactly `n_trial_msgs` entries — one per trial_idx in 0..n_trial_msgs-1, in any order. **Every** trial msg gets a tier + kind_hint, matched and unmatched alike.
