# LLM backends per seat

SWE-Together makes model calls from four places — the *seats*. Each seat can be
served by a different backend, chosen independently.

| Seat | What it does | Runs where | Client that makes the call |
|---|---|---|---|
| `agent` | the coding agent under evaluation | inside the task sandbox | opencode (`--agent-type opencode`) |
| `user_sim` | the simulated user | host process (`src/run_eval.py`) | LiteLLM |
| `judge` | agentic correctness judge | a fresh sandbox per trial | `claude --print` (Claude Code) |
| `tagger` | message tagging (User Correction), intent coverage, intent extraction | host subprocesses (`eval.run_eval`) | LiteLLM |

| Backend | Served by | Credentials |
|---|---|---|
| `native` | the vendor's own API | `GEMINI_API_KEY`, `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY` |
| `openrouter` | OpenRouter | `OPENROUTER_API_KEY` |
| `bedrock` | AWS Bedrock | AWS credentials (see below) |
| `codex` | judge only: `codex exec` with ChatGPT OAuth | `~/.codex/auth.json` |

`native` reproduces the upstream defaults exactly, so a configuration that sets
nothing behaves as before.

## Choosing a backend

Precedence, highest first:

1. CLI flag: `--agent-backend`, `--user-sim-backend` (`src/run_eval.py`,
   `scripts/slurm/launch.py run`); `--judge-backend`, `--tagger-backend`
   (`eval.run_eval`, `scripts/slurm/launch.py judge`).
2. Plan file: a cohort's `agent_backend` (agent seat only), see
   `canonical_full109.json`.
3. `SWT_AGENT_BACKEND`, `SWT_USER_SIM_BACKEND`, `SWT_JUDGE_BACKEND`, `SWT_TAGGER_BACKEND`.
4. `SWT_LLM_BACKEND` — one value for every seat.
5. `native`.

For the judge, the maintainers' switches `JUDGE_VIA_OR=1` (→ `openrouter`,
model from `JUDGE_OR_MODEL`) and `JUDGE_VIA_CODEX=1` (→ `codex`) still work; an
explicit backend from 1, 3 or 4 wins over them.

## Naming models

A seat's model is either:

- a **registry name** — `gpt-5.6-sol`, `claude-opus-4.6`, `gemini-3.1-pro`, … —
  translated to the id the chosen backend expects; or
- a **fully-qualified string** with a provider prefix — `openrouter/meta/muse-spark-1.3`,
  `bedrock/global.openai.gpt-5.6-sol`, `gemini/gemini-3.1-pro-preview`,
  `anthropic/claude-opus-4-6` — used verbatim. The prefix then *is* the backend,
  so every existing plan file and command line keeps working.

The registry (`src/llm_config.py`, `MODEL_REGISTRY`):

| Registry name | `openrouter` | `bedrock` | `native` |
|---|---|---|---|
| `gpt-5.6-sol` (alias `gpt-5.6`), `-luna`, `-terra` | `openai/gpt-5.6-*` | `global.openai.gpt-5.6-*` | — |
| `claude-opus-4.6` | `anthropic/claude-opus-4.6` | `global.anthropic.claude-opus-4-6-v1` | `claude-opus-4-6` |
| `claude-opus-4.8` | `anthropic/claude-opus-4.8` | `global.anthropic.claude-opus-4-8` | `claude-opus-4-8` |
| `claude-fable-5`, `claude-fable-5.1` | `anthropic/claude-fable-5[.1]` | `global.anthropic.claude-fable-5[-1]` | `claude-fable-5[-1]` |
| `claude-haiku-4.5` | `anthropic/claude-haiku-4.5` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | `claude-haiku-4-5` |
| `gemini-3.1-pro` | `google/gemini-3.1-pro-preview` | — | `gemini-3.1-pro-preview` |
| `muse-spark-1.3` | `meta/muse-spark-1.3` | — | — |

Asking for a combination the registry does not offer (`gemini-3.1-pro` on
`bedrock`) fails at startup with the backends that do offer it. To add a model,
add one `ModelSpec` entry. GPT-5.6 and the Fable models reject a `temperature`
field; the registry marks them `supports_temperature=False` and the user-sim
omits the parameter for them.

Internally every seat ends up with one fully-qualified string; the three
clients spell the Bedrock route differently and `llm_config` translates:
opencode gets `amazon-bedrock/<id>`, LiteLLM gets `bedrock/converse/<id>`,
Claude Code gets the bare `<id>` with `CLAUDE_CODE_USE_BEDROCK=1`.

### Why the `global.` Bedrock ids

Bedrock serves these models only through inference profiles (`us.…`,
`global.…`); the bare `openai.gpt-5.6-sol` is rejected ("on-demand throughput
isn't supported"). opencode derives reasoning variants and pricing from the
[models.dev](https://models.dev) catalog, whose `amazon-bedrock` section lists
the `global.` profiles — an id that misses the catalog silently runs with
reasoning off. The registry uses the catalogued ids, and the launcher warns
when a hand-written `bedrock/…` id is not in the catalog.

## AWS credentials

All three Bedrock clients read the standard variables `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `AWS_REGION`. If your host has
ambient credentials (instance role, exported variables), nothing else is needed.
Otherwise `src/bedrock_creds.py` mints them on demand from **one** of:

```
SWT_AWS_CREDENTIAL_CMD="<tool> ... -d {lease} --output cli"   # prints credential_process JSON
AWS_PROFILE=<profile with a credential_process line>
```

`{lease}` is replaced by `SWT_AWS_LEASE` (default `4h`). Credentials are
refreshed 20 minutes before they expire — LiteLLM caches credentials for 10
minutes, so a refreshed value is always in place before the old one can fail.
`SWT_AWS_REGION` (default `us-west-2`) sets every region variable the clients
read. `SWT_UCLOUD_CERT` is an optional client certificate some credential tools
need; it is exported only into the credential command's environment.

Where the credentials go:

- **agent**: copied into the container's exec environment on turn 0 *and every
  resume turn* (`UserEnabledOpenCode._refresh_agent_env`), so a trial that
  outlives a lease keeps working.
- **judge**: rebuilt per trial from the host environment (`llm_config.judge_auth_envs`).
- **user_sim / tagger**: read from the host process environment by LiteLLM.
- **Slurm**: the launcher scrubs `AWS_*` from the environment it hands to
  `sbatch` — otherwise Slurm's `--export=ALL` would freeze a lease into an
  8-hour job — and each job mints its own credentials on start. Nothing
  credential-like is ever written into a job script.

`~/.aws` profiles are not visible inside containers, which is why values are
materialised rather than a profile name being passed through.

### Claude Fable on Bedrock

Fable 5 / 5.1 calls fail with `data retention mode 'default' is not available
for this model` until the AWS **account's** Bedrock data-retention mode is set
to `provider_data_share` in the calling region (an account-admin action:
`aws bedrock put-account-data-retention --mode provider_data_share --region …`).
No request field bypasses it. Once the account is opted in, the registry entries
work unchanged.

Notes from enabling it for the Fable cohorts:

- The setting is per account **and per calling region**; `global.*` inference
  profiles route across regions, but the check is made against the region of
  the caller (`SWT_AWS_REGION`), so only that one region needs the opt-in.
- It is a policy decision — Fable prompts and outputs are shared with the
  provider for up to 30 days; other models on the account are unaffected — so
  it belongs to the account owner, not to whoever holds the invocation role.
- Older AWS CLIs (< ~2.35) lack `put-account-data-retention`; a SigV4-signed
  `PUT https://bedrock.<region>.amazonaws.com/data-retention` with body
  `{"mode":"provider_data_share"}` does the same (`awscurl` works too).
  `GET` on the same path reads the current mode.
- Propagation is not instant: for ~15 minutes after the flip a small fraction
  of calls (2 of ~60 in the canary) still returned the old error. opencode does
  not retry a 400, so run the 1-task smoke test until it completes with zero
  such errors before launching a cohort.

## Reasoning effort on Bedrock

The benchmark runs opencode with `--variant=<effort>`; the config patch the
wrapper writes (`build_opencode_config_patch_script`) declares explicit variants
for the `amazon-bedrock` provider in the shape opencode's Bedrock SDK expects
(`reasoningConfig: {type: adaptive, maxReasoningEffort: <effort>}`), which the SDK
turns into `reasoning.effort` for OpenAI models and `thinking: adaptive` +
`output_config.effort` for Anthropic models. Accepted efforts: GPT-5.6
`none|low|medium|high|xhigh|max`; Claude `low|high|max`.

**opencode ≥ 1.18.26 is required for OpenAI models on Bedrock.** Earlier
releases (including the benchmark's canonical pin, 1.15.13) detect OpenAI
models by `modelId.startsWith("openai.")`, which is false for inference-profile
ids, and send a field Bedrock rejects (HTTP 400 `Unknown parameter:
'reasoningConfig'`). Pin per cohort with `opencode_version` in the plan file or
`--opencode-version`; the version is recorded in each trial's `config.json` and
in the run manifest. Cohorts without the field keep the canonical pin.

### Accounting caveats for GPT models on Bedrock

- Bedrock returns GPT reasoning as encrypted `redactedContent` and Claude
  thinking as signed blocks; opencode's `step_finish.tokens.reasoning` is
  therefore `0` for every Bedrock trial even when reasoning is on (the
  `reasoning` events are present). Bedrock's `outputTokens` already includes
  the hidden reasoning/thinking tokens (verified live: a one-character answer
  bills 170–500 output tokens at effort high and ~5 at effort none), so the
  per-trial `output_tokens` = output + reasoning stays comparable with
  OpenRouter cohorts, where the two are reported separately.
- opencode's `step_finish.cost` prices `tokens.input` in full and adds the cache
  read on top, but Bedrock's `inputTokens` for GPT models already *excludes*
  cached tokens (Anthropic-style accounting, verified live). Reported cost is
  therefore inflated on cache-heavy agentic trials — roughly 6× on the pilot
  ($9.57 reported vs ≈$1.47 at list price) and ~8× on the full GPT-5.6 Sol
  cohort ($7.7k reported vs ≈$0.93k; 97.7% cache-hit rate). Use the token
  counts with the models.dev `amazon-bedrock` prices for a bill estimate, or
  AWS billing.

## Operational notes from the first Bedrock cohort (GPT-5.6 Sol, 2×109)

- **Throttling is an HTTP 400, and opencode will not retry it.** Bedrock
  signals token-rate throttling for GPT-5.6 as `400 {"message":"Too many
  tokens, please wait before trying again."}`, not 429. opencode 1.18.x maps
  that body to `ContextOverflowError`, which its retry logic explicitly skips,
  so a throttled step is lost. The wrapper compensates: a turn that ended with
  only throttle errors is re-issued, a turn interrupted mid-way is resumed with
  a synthetic continue, both with backoff (`_THROTTLE_BACKOFF_SEC`); retries are
  counted in `agent/throttle_retries.txt`. Onset is load-dependent: 18
  concurrent trials (`--shards 12 --concurrent 3`) ran two full replicates with
  zero throttling, 24 throttled after a few minutes, 48+ heavily. Chain
  replicates with a Slurm dependency instead of running them side by side.
- **Images inside tool results are rejected for OpenAI models.** Bedrock
  accepts an image as a plain user-message part but returns `400 This model
  doesn't support the image field for user messages` when the same image sits
  inside a `toolResult` block. opencode's `read` tool attaches image files as
  base64 and its Bedrock adapter keeps tool-result images inside the tool
  result, so once the agent reads a `.png`/`.jpg` every later call in that
  session fails (the offending message stays in history). 3 of 218 trials were
  affected, one fatally (`infra_failed`). There is no opencode setting for this;
  the available mitigation is a `permission.read` deny on image globs for
  Bedrock + OpenAI seats, which is a protocol deviation and was not applied.
- **The judge runs without prompt caching.** Opus 4.6 on Bedrock reported zero
  cache reads for every `cache_control` form and inference profile we tried
  (Sonnet 4.6 caches normally), so each Claude Code turn re-reads the whole
  context. Verdicts took ~1.6× longer than via OpenRouter with a heavy tail, and
  5 of 214 first-pass verdicts hit the 50-turn cap or the 1200 s timeout (0 of
  218 via OpenRouter). To re-judge failures, move each failed
  `judge_verdict.json` aside and re-run the judge launcher: existing verdicts
  are skipped, so only the missing ones are judged and the report is rebuilt.

## Operational notes from the Fable cohorts (Fable 5.1 and Fable 5, 2×109 each)

- **Anthropic models on Bedrock were error-free at the same concurrency.** Both
  cohorts ran 218/218 trials at 18 concurrent (`--shards 12 --concurrent 3`)
  with zero API errors of any kind and zero throttle retries, and prompt
  caching worked for the agent (~98% cache-hit rate). The 18-trial ceiling was
  set by GPT-5.6's throttling, not by Anthropic quota.
- **A Slurm `OUT_OF_MEMORY` on a shard is not necessarily a lost shard.** The
  container's `/tmp` is tmpfs and counts toward the job's memory cgroup; on
  `mlx-lm-mambacache` the agent downloaded a 42 GB model checkpoint into it,
  which tripped the 128 GB limit at job exit — after every trial in the shard
  had finished and written its verifier reward. Check `trial_infra.json` and
  `verifier/reward.txt` for the shard's trials before treating the flag as a
  failure.
- **Judge max-turn failures recur on the same tasks.** `cli-task-e5813e` hit
  Claude Code's 50-turn cap for GPT-5.6, Fable 5.1 and Fable 5 alike; a second
  pass recovered most verdicts (Fable 5: 2/2, Fable 5.1: 3/4, GPT-5.6: 4/5) and
  the residual is scored 0.0 per the leaderboard rule.
- **Cost differs between the two Fables mainly through the cache-read rate.**
  At list price Fable 5 came to ≈$3.9k and Fable 5.1 ≈$1.8k for similar token
  volumes: Fable 5's cache reads are billed at $1/M vs $0.25/M, and cache reads
  are ~98% of input tokens on agentic trials.

## Verdict provenance

Each `judge_verdict.json` records `judge_model` (unchanged spelling:
`claude-opus-4-6`, `or:anthropic/claude-opus-4.6`, `codex:gpt-5.5`, and now
`bedrock:global.anthropic.claude-opus-4-6-v1`) plus a `judge_backend` field.

## Example: an agent on Bedrock, everything else on OpenRouter

`.env`:

```
SWT_LLM_BACKEND=openrouter
SWT_AWS_CREDENTIAL_CMD="<tool> get-creds <account> -r <role> -d {lease} --output cli"
SWT_AWS_REGION=us-west-2
```

Plan file cohort:

```json
"opencode_gpt56": {"model": "gpt-5.6-sol", "agent_backend": "bedrock",
                   "agent_type": "opencode", "opencode_version": "1.18.29",
                   "reasoning_effort": "high", "agent_timeout": 4800, "workers": 6}
```

Slurm:

```
python scripts/slurm/launch.py run   --tag gpt56_r1 --model gpt-5.6-sol --agent-backend bedrock \
                                     --opencode-version 1.18.29 --submit
python scripts/slurm/launch.py judge --trials-root trials/gpt56_r1 --output-dir results/gpt56 \
                                     --model-tag gpt56 --submit           # judge + tagger via SWT_LLM_BACKEND
python scripts/slurm/launch.py judge ... --judge-backend bedrock          # judge on Bedrock instead
```

The launcher runs a preflight when any seat is on Bedrock: it mints credentials
on the login node (fail fast) and warns about ids missing from the models.dev
catalog.
