# User Simulator Changelog

Each version is tagged in the code via `UserAgent.VERSION`. Trial logs record
which version produced them so results are always traceable.

## v1.0 — 2026-05-31

**Stabilization release: mini-swe-agent + opencode wrappers production-ready
across all base image families.**

v0.10–v0.11 introduced the two new harness wrappers (mini-swe-agent and
opencode); the eight follow-up PRs and the late-cycle local patches turned
them into runnable cohorts across the full benchmark. The pattern this cycle
was the same on every PR: a cohort would partially run, the failure mode
would only be visible in a small fraction of base-image families, and the fix
would close one entire diagonal of the matrix.

This release notes the cumulative state. Every PR below is already merged
unless flagged "**local**".

### Wrappers — features added this cycle

- **mini-swe-agent** (v0.10.0, #191): history-replay wrapper around the
  LiteLLM-based `mini-swe-agent` CLI. 4-section followup-prompt shape
  matching the codex wrapper. Per-turn trajectory archive pulled from
  sandbox via `env.download_file` so reasoning content survives across
  invocations. Drops `MSWEA_COST_TRACKING=ignore_errors` (v2's price table
  doesn't know `openai/gpt-5.5` or `openrouter/*` — benchmark correctness >
  cost reporting).
- **opencode** (v0.11.0, #191): native-resume wrapper, mirroring
  `claude_code`'s `--resume` via `opencode run --session=<id>`. Same parity
  features: repo config injection, structured trajectory snapshot,
  wall-clock timing, `_INCREMENTAL_NOTICE`, per-turn diff to user-sim.
  `_inject_opencode_flags` post-processes Harbor's command list to add
  `--variant=<reasoning_effort>` and OAuth env vars.
- **oauth_proxy.py** (#191, #192, #194, #196, **local**): in-sandbox proxy
  translating OpenAI Chat Completions ↔ ChatGPT private Responses API
  (`chatgpt.com/backend-api/codex/responses`). Lets LiteLLM-based runs route
  through ChatGPT-subscription billing. SSE translation covers text /
  tool_call / reasoning_text / reasoning_summary_text deltas. Two
  non-obvious correctness fixes from #191:
  1. ChatGPT Responses API rejects `role="tool"` — must translate to
     `{type:"function_call_output", call_id, output}` items, and assistant
     tool_calls to `{type:"function_call", ...}` items.
  2. Without `reasoning.summary` set, ChatGPT does NOT emit any
     `reasoning_summary_text.delta` even when `reasoning.effort` is on. Set
     `summary="auto"` whenever effort is present.
- **shared `litellm_proxy.py`** (#195): extracted from `user_enabled_claude_code`
  so mini-swe-agent and opencode wrappers route `minimaxd/`, `glmd/`, `ark/`,
  `fireworks/`, `deepseek/`, `openrouter/` through the same `localhost:4210`
  proxy. Includes `mask_proxied_model_name()` to rewrite e.g.
  `minimaxd/MiniMax-M2.7` → `anthropic/claude-sonnet-4-6` for Harbor's and
  opencode's hardcoded provider lists.

### Reasoning depth — what level, where it gets set

| layer | default after this cycle | where it lands |
|---|---|---|
| mini-swe-agent wrapper (#199) | `reasoning_effort="high"` | passed to Harbor `MiniSweAgent(reasoning_effort=...)` |
| opencode wrapper (#198, #199) | `reasoning_effort="high"` | `--variant=high` on `opencode run` |
| opencode `~/.config/opencode/opencode.json` (#196) | `provider.<name>.options.reasoning.effort=<value>` | written by `_opencode_thinking_patch_command()` before launch |
| opencode opus on OR (#197) | `provider.<name>.options.thinking.type="adaptive"` | belt-and-suspenders for #196: forces adaptive mode on Opus 4.6+ |
| Harbor `MiniSweAgent` (**local**) | `-c model.model_kwargs.extra_body.reasoning.max_tokens={8000,5000,2000}` | injected into mini-swe-agent's argv |

The Harbor-side switch (`reasoning.max_tokens` instead of
`reasoning.effort`) is empirically motivated: OR translates `max_tokens` to
Anthropic's explicit thinking budget, whereas `effort=high` is translated
conservatively (only ~50 reasoning tokens observed in 9 opus trials with
tool_use). `reasoning.max_tokens=8000` yields 117+ reasoning tokens in the
same conditions.

#196 also fixed an instrumentation gap: oauth_proxy didn't forward
`usage.reasoning_tokens` on `response.completed`, so trajectories showed 0
reasoning_tokens regardless of actual upstream thinking.

### Sandbox install / aiohttp — the long-tail debug story

The single nastiest bug class this cycle was "oauth_proxy port 4220 is
silently closed because aiohttp didn't import." It failed differently on
different base images and silently degraded to "the model wasn't trying"
when the symptom was actually "the proxy never started." Resolved
incrementally:

- **#192** — drop httpx from oauth_proxy. Pilot10 r3 surfaced
  `ModuleNotFoundError: No module named 'httpx'` (aiohttp was on the
  image; httpx wasn't, and `pip install … || true` swallowed the failure).
  Consolidated to aiohttp for both client and server.
- **#194** — cascade install paths for aiohttp on the **opencode** sandbox
  (`apt python3-aiohttp` → `ensurepip + pip --user` → `apt python3-pip + pip
  --user`). Pre-#192 PR also tried `pip install` but E2B's stripped
  `/usr/bin/python3` had no pip at all.
- **feb02e55** (**local**, mirrors #194 for mini-swe-agent) —
  `python3 /tmp/oauth_proxy.py` was failing with `ModuleNotFoundError: No
  module named 'aiohttp'` specifically on tasks built `FROM ubuntu:24.04`
  (moltis-task-ffe9ec, cli-task-c425e4, rudel-task-d64e5a, cli-task-4a9dde,
  amytis-task-e3714e). System python3 doesn't see `uv tool install`'s
  isolated venv. Switch the launch command to
  `~/.local/share/uv/tools/mini-swe-agent/bin/python` — guaranteed to have
  aiohttp because mini-swe-agent's litellm dep brought it. Fall back to
  system `python3` if the venv path is missing.

  Pre-fix symptom: 8/8 trials in `new29_mini_gpt_oauthRerun` produced
  41–65 byte empty patches and 6 retry messages
  ("InternalServerError: OpenAIException - Connection error" — litellm
  wrapping ECONNREFUSED). All recovered to 0.10–0.70 reward after the
  patch.

  ComfyUI / hyperswitch / sd-scripts base images happen to ship aiohttp in
  system Python (used by their web servers), which is why those tasks
  worked the whole time and the bug never surfaced on the original cohorts.

- **Harbor install script** (`install-mini-swe-agent.sh.j2`, **local**)
  — replace the conditional pip fallback with `uv tool install --force`
  unconditionally. The old `pip install --user` path triggered a
  `PosixPath('.') has an empty name` ValueError when mini-swe-agent was
  pip-installed into an activated venv (comfyui-dev, sd-scripts-dev). uv
  tool install puts mini-swe-agent in its own isolated env, sidestepping
  the venv/system-Python distinction entirely.

### Cap-rescue and timeout tuning

- **#200, `user_enabled_opencode.py`**: after `PER_EXEC_CAP_SEC` kills
  turn-0, `_TimeoutResult` drops the captured stdout — so the previous
  `_find_session_id()` returned None and the cap_rescue_pending resume
  loop never entered (49 cap events → 0 rescues observed before the fix).
  Fix: post-cap, `cat /logs/agent/opencode.txt` from the sandbox so the
  sessionID + early events are recoverable.
- **#200, subshell heredoc**: `_opencode_thinking_patch_command()` returned
  `<<'PYEOF'\n...\nPYEOF\n && opencode run …`. Bash refuses to chain `&&`
  onto the heredoc terminator. Wrapped in `(python3 - <<'PYEOF'\n…\nPYEOF\n)`
  so `(...) && opencode run` is one valid line. Before the fix, 49 trials'
  stdouts were silently truncated.
- **#200, external_directory auto-allow**: opencode's `permission.external_directory`
  defaults to "ask", which in our non-interactive runner means "auto-reject."
  Agents failed to read venvs and /tmp scratch files. Auto-allow
  `/workspace`, `/tmp`, `/opt`, `/root`, `/home`, `/proc`, `/usr`, `/logs`.
- **`exec_helpers.py`** (**local**): `PER_EXEC_CAP_SEC` 1200s → 1800s.
  Pilot10 audit found 4 trials wrapper-killed at 1200s (mini-Opus
  cli-task-2f5833 × 3 + mini-GPT cli-task-7e3475 × 1) where the model was
  legitimately progressing on a Go-project exploration. 1800s gives
  breathing room without compromising `TRIAL_BUDGET_SEC=7200` (still
  4 execs/trial).

### repo_diff.py — harbor-base fallback (#200, repo_diff.py)

`tag_harbor_base` only tags repos it discovers at setup time. If an agent
later clones a new repo into a discovered root (e.g.
`/home/user/repo`), the per-turn diff would scan it but the cumulative
section would be empty because `harbor-base` wasn't tagged there. Fix:
during per-turn capture, if `harbor-base` is missing in a discovered repo,
try `harbor-turn-0` then `HEAD_BEFORE` as fallbacks. Both incremental
and cumulative now record agent work in late-cloned repos.

Audit signature: 2/3 mini_ds reps for `pi-mono-auto-796a21ab` had
empty cumulative `final.patch` despite non-empty `turn-N.incremental.patch`
under `/home/user/repo`. The bug was pre-#200; fix is deployed.

### DeepSeek dual-route fix (`run_eval.py` + `litellm_proxy.py`, **local**)

Symptom on new29-diverse pilot (2026-05-29): every `deepseek/*` mini-swe-agent
trial returned 401 invalid x-api-key. Root cause: `mask_proxied_model_name()`
was rewriting `deepseek/deepseek-v4-pro` → `anthropic/claude-sonnet-4-6`,
and LiteLLM's anthropic provider dispatched to `api.anthropic.com` —
*not* the proxy at `localhost:4210` — because LiteLLM reads
`ANTHROPIC_API_BASE`, not `ANTHROPIC_BASE_URL`. The 401 was Anthropic
rejecting the (correct) DeepSeek key.

Fix is two-sided:
- `litellm_proxy.PROXIED_PROVIDER_PREFIXES`: drop `deepseek/` and
  `openrouter/`. Both are Harbor-recognized providers that LiteLLM and
  opencode route natively via `DEEPSEEK_API_KEY` / `OPENROUTER_API_KEY`.
  No masking, no proxy hop.
- `src/run_eval.py:build_agent_env`: under `provider == "deepseek"`,
  populate both the proxy env (so Claude Code still works via
  `ANTHROPIC_BASE_URL`) AND `DEEPSEEK_API_KEY` (so mini-swe-agent and
  opencode use the native deepseek provider directly).

### oauth_proxy — Responses-API body trimming (**local**)

ChatGPT's codex `/v1/responses` rejects bodies over ~1MB with
`{"error":"bad json: Request Entity Too Large"}`. Long multi-turn
conversations + tool history routinely cross this limit. OpenCode
surfaced it as `ContextOverflowError` and tore the whole session down —
even though the model's actual context window was fine.

Add `_truncate_responses_input()`: keep `instructions` + `tools` + the
last 8 input items, drop older history first until the serialized body
is under 800KB. Always preserves at least the tail (we'd rather forward
and let upstream 413 than ship an empty conversation).

### PR / commit ledger this cycle

| PR / commit | what it fixed |
|---|---|
| #191 (e8045a57) | initial wrappers (mini-swe-agent v0.10, opencode v0.11) + oauth_proxy |
| #192 (58a2bbc3) | drop httpx dep in oauth_proxy — silent install failure killed runs |
| #194 (49d348f4) | cascade install paths for aiohttp in opencode sandbox |
| #195 (5e9b5304) | shared litellm_proxy helper — mini/opencode route minimaxd/glmd/ark |
| #196 (c07213ed) | opencode thinking budget on OpenRouter + usage tokens |
| #197 (5c370287) | write `thinking.type=adaptive` into provider config |
| #198 (5f62ed6f) | opencode default effort "medium" → "high" |
| #199 (03fa243b) | mini + opencode default reasoning_effort = "high" |
| #200 (f9f72645) | opencode cap-rescue + max_tokens + external_directory + harbor-base fallback |
| feb02e55 | mini-swe-agent oauth_proxy launches via uv tool venv Python |
| **local** | DeepSeek dual-route, Responses-API body trim, PER_EXEC_CAP 1200→1800, install-mini-swe-agent uv-only path, Harbor mini_swe_agent.py max_tokens budget |

### Files touched (cumulative)

- `src/user_agent/user_enabled_mini_swe_agent.py` (NEW, #191; **local** patches)
- `src/user_agent/user_enabled_opencode.py` (NEW, #191; #192, #194, #196, #197, #198, #200)
- `src/user_agent/oauth_proxy.py` (NEW, #191; #192, #196, **local** patches)
- `src/user_agent/litellm_proxy.py` (NEW, #195; **local** PROXIED_PROVIDER_PREFIXES)
- `src/user_agent/exec_helpers.py` (**local** PER_EXEC_CAP bump)
- `src/run_eval.py` (#195; **local** deepseek dual-route)
- `src/user_agent/repo_diff.py` (#200)
- `external/harbor/src/harbor/agents/installed/mini_swe_agent.py` (**local** max_tokens budget)
- `external/harbor/src/harbor/agents/installed/install-mini-swe-agent.sh.j2` (**local** uv-only)

### Empirical signal — before vs. after the cycle

| baseline cohort | symptom | post-fix |
|---|---|---|
| `pilot10 × opencode × *` | 49/49 cap events → 0 rescues (#191 → #200) | cap-rescue restores sessionID, multi-turn resumes |
| `pilot10 × opencode × Opus` | 0 reasoning blocks in 9 trials (#191) | 117+ reasoning tokens per turn (#196 + #197 + Harbor max_tokens) |
| `pilot10 × opencode × gpt-5.5` | trials never produced dirs (#191) | aiohttp install cascade → runs complete (#194) |
| `new29 × opencode × MiniMax/GLM` | 10/10 "Unknown provider" exceptions (pre-#195) | masked, routed via litellm_proxy (#195) |
| `new29 × * × DeepSeek` | 100% 401 invalid x-api-key (pre-local DS fix) | DEEPSEEK_API_KEY native route + no mask (**local**) |
| `new29 × mini-swe × gpt-5.5 × ubuntu:24.04` | 8/8 empty 41–65b patches with ECONNREFUSED (pre-feb02e55) | 0.10–0.70 reward across reruns |
| `new29 × * × pi-mono-auto-796a21ab` | 2/3 mini_ds empty cumulative final.patch (pre-#200) | cumulative captures /home/user/repo (rerun verified) |

The benchmark is now mature on six harness × provider × image combinations
(mini-swe + opencode) × (gpt-5.5 + DeepSeek-v4-pro + Opus 4.6) × (ubuntu /
comfyui / hyperswitch / sd-scripts / pi-mono bases). v1.0 declares the
infrastructure stable enough to compare model capabilities rather than
debug harness symptoms.

## v0.11.0 — 2026-05-29

**OpenCode wrapper: second native-resume harness.**

Adds `UserEnabledOpenCode`, mirroring `UserEnabledClaudeCode` in shape but
running atop the open-source `opencode-ai` CLI rather than Anthropic's
`claude` binary. Same native-resume pattern (`opencode run --session=<id>`
continues the local-session store, replays prior history to the configured
model), so wrapper-side code is thin: thread the session_id captured from
the turn-0 JSON event stream, no manual history-replay (unlike codex /
gemini_cli / mini-swe-agent).

### Why two native-resume harnesses

We now ship two side-by-side reference harnesses that use the same
"server-side session id" abstraction:

| Wrapper | CLI | Provider lock-in | reasoning depth knob |
|---|---|---|---|
| `UserEnabledClaudeCode` | `claude` (Anthropic) | Anthropic by default; non-Anthropic via in-sandbox LiteLLM proxy + model rewrite | `CLAUDE_CODE_EFFORT_LEVEL` env |
| `UserEnabledOpenCode` | `opencode` (multi-provider, MIT) | First-class provider/model registry (12+ providers) | `--variant=<value>` per-`run` flag |

`opencode --variant` accepts arbitrary strings and forwards to the
provider; example values per OpenCode CLI source are `high / max / minimal`
(OpenAI-style reasoning effort levels). The wrapper passes whatever
`reasoning_effort` value the runner provides as-is; per-provider mapping
is OpenCode's responsibility.

### Wrapper feature parity

Same patches we landed for claude_code over v0.5–v0.10 are mirrored:

- ✅ Repo config file injection (CLAUDE.md, AGENTS.md, …) via shared `repo_config`
- ✅ Structured trajectory snapshot for user-sim (parses `step_start` /
  `step_finish` / `text` / `tool_use` event types → `[step] thinking /
  tool_call / result`)
- ✅ Wall-clock timing per turn (`_start_time` + `_turn_start_time`)
- ✅ `_INCREMENTAL_NOTICE` instruction prefix (claude-code-style; safe to
  add for native-resume harnesses because per-turn cost stays cheap when
  the underlying CLI keeps state)
- ✅ Per-turn incremental git diff → user-sim `code_changes_diff` channel
- ✅ Shared `repo_diff.py` (`tag_harbor_base`, `capture_git_diff`)
- ✅ `exec_with_budget` (PER_EXEC_CAP / TRIAL_BUDGET)
- ✅ Per-turn stdout archive (`opencode.txt.turn-<N>`) so cumulative
  `tee -a` rewrites don't lose individual turn data

### OAuth proxy reuse

`UserEnabledOpenCode.setup` reuses the same `MSWEA_USE_CODEX_OAUTH=1`
flag and the same `oauth_proxy.py` (introduced in v0.10.0) to route
`openai/gpt-5.5` traffic through ChatGPT-subscription OAuth. The proxy
sits on `127.0.0.1:4220` inside the sandbox; OpenCode's openai provider
respects `OPENAI_BASE_URL` so no additional integration is required.
`_inject_opencode_flags` post-processes Harbor's command list to set the
env vars on every `ExecInput` (Harbor's `OpenCode.create_run_agent_commands`
doesn't take a reasoning kwarg yet, so the same hook also splices
`--variant=<effort>` between `run` and `--format=json`).

### Runner / orchestrator changes

- **`src/run_eval.py`** — new `--agent-type opencode` branch:
  `OPENCODE_IMPORT_PATH = "user_agent.user_enabled_opencode:UserEnabledOpenCode"`.
  Forwards every provider key OpenCode's Harbor wrapper recognises
  (anthropic / openai / openrouter / deepseek / google / groq / mistral /
  xai / github / aws / azure) plus the OAuth-proxy switches.

### What this is NOT

- **Not a code review of OpenCode itself.** Wrapper assumes opencode-ai
  v0.6+ semantics for `--session` / `--continue` / `--format=json`. A
  version pin will land separately once we settle on a baseline.
- **Not a thinking-cost normalizer.** OpenCode's `--variant` semantics
  are provider-specific; comparing "Opus medium" via OpenCode against
  "Opus medium" via mini-swe-agent is not apples-to-apples (different
  request shapes / cache behavior). For cross-model fairness work, hold
  the harness constant.

## v0.10.0 — 2026-05-29

**Mini-SWE-Agent wrapper + ChatGPT-OAuth proxy + reasoning_effort plumbing.**

Adds a neutral, LiteLLM-based harness option to the cross-model cohort
(`UserEnabledMiniSweAgent`), routes gpt-5.x through a ChatGPT-subscription
OAuth proxy so OpenAI-billed runs can ride on the host's ChatGPT seat, and
threads `reasoning_effort` end-to-end so thinking-strength is the comparison
axis (instead of an unaligned provider default).

### New wrappers + modules

- **`src/user_agent/user_enabled_mini_swe_agent.py`** —
  `UserEnabledMiniSweAgent`, the third "history-replay" wrapper (after codex
  + gemini_cli). Re-invokes the in-sandbox `mini-swe-agent` CLI per turn
  with a structured followup prompt (same 4-section shape as codex's
  v0.9.0): `ORIGINAL TASK` + `CURRENT WORKSPACE STATE` (cumulative diff
  capped 20 KB) + `RECENT TOOL CALLS` (last 3 turns, 4 KB/turn cap) +
  `PRIOR USER MESSAGES`. Per-turn diff capture, ATIF trajectory snapshot
  for user-sim, and `_extract_and_append_tool_history(turn)` archive
  `mini-swe-agent.trajectory.turn-N.json` so prior-turn reasoning_content
  isn't lost when mini-swe-agent overwrites the live trajectory.json on
  the next turn.
  - `mswea_version="2.3.0"` pin: 2.3.x supports our multi-turn flow and
    is in LiteLLM's price table-ish (we still set `MSWEA_COST_TRACKING=
    ignore_errors` because v2 fails the price-lookup for `openrouter/...`
    + `openai/gpt-5.5`; benchmark correctness > cost reporting).
  - OAuth path (`MSWEA_USE_CODEX_OAUTH=1`): wrapper uploads
    `oauth_proxy.py` + host's `~/.codex/auth.json` to the sandbox at
    `/tmp/`, starts the proxy on `127.0.0.1:4220`, sets
    `OPENAI_BASE_URL=http://127.0.0.1:4220/v1` + `OPENAI_API_KEY=
    placeholder` per `mini-swe-agent` invocation. `_flush_proxy_log` pulls
    `/tmp/oauth_proxy.log` back to logs_dir at run-end so 4xx upstream
    bodies are debuggable.

- **`src/user_agent/oauth_proxy.py`** — minimal aiohttp proxy that
  translates **OpenAI Chat Completions** ↔ **ChatGPT private Responses API**
  at `https://chatgpt.com/backend-api/codex/responses`. Uses the host's
  codex OAuth credentials (lazy reload on 401). Streaming SSE translation
  (text deltas + function-call argument deltas). `reasoning_effort` lifts
  to `reasoning.effort`. Tools schema is flattened to the Responses shape.

  **Critical fix during smoke-test debugging:** the initial `messages →
  input` translation passed `role: "tool"` through unchanged for tool
  results, and `role: "assistant"` with `tool_calls` as a plain message
  with the calls embedded. Both are rejected by the codex backend with
  `Invalid value: 'tool'. Supported values are: 'assistant', 'system',
  'developer', and 'user'.` (param `input[N]`). The first model call of
  each turn worked; everything after the first tool result 422'd in a
  loop. Now translated to Responses-API item types:
    - `{role:"tool", tool_call_id, content}` →
      `{type:"function_call_output", call_id, output}`
    - `{role:"assistant", tool_calls:[...]}` → optional `{type:"message",
       role:"assistant", content}` + one `{type:"function_call", call_id,
       name, arguments}` per call
  Validated end-to-end (v10 GPT-5.5 OAuth smoke ran past turn 2 with no
  422; prior v7-v9 attempts all 422'd at the first tool result).

### `reasoning_effort` threading (end-to-end)

- `src/run_eval.py` — new `--reasoning-effort {low,medium,high}` CLI
  flag, forwarded to `UserEnabledMiniSweAgent(reasoning_effort=…)` via
  `user_sim_kwargs`. Only set when explicit (no default), so the
  prior-cohort "provider native default" runs stay reproducible.

- `UserEnabledMiniSweAgent.__init__` — pops `reasoning_effort` from
  kwargs and forwards to inner `MiniSweAgent`. Inner agent threads it as
  `-c model.model_kwargs.extra_body.reasoning_effort=<value>` to the
  in-sandbox `mini-swe-agent` CLI; LiteLLM dispatches per provider:
    - OpenAI / ChatGPT OAuth → `reasoning.effort=<value>` (proxy lifts it)
    - Anthropic (Opus 4.6 via OR) → `thinking.budget_tokens`
      (low=1024 / medium=4096 / high=16384)
    - DeepSeek-v4-pro → accepts the parameter but per
      [DeepSeek docs](https://api-docs.deepseek.com/api/create-chat-completion)
      `low` and `medium` are silently **mapped to `high`** (and `xhigh →
      max`). Net: DeepSeek has no usable level below `high`; for "all
      medium" cohorts DeepSeek is structurally one step heavier.

- **Companion fix — `external/harbor/src/harbor/agents/installed/mini_swe_agent.py`:**
  upstream Harbor's `reasoning_effort` threading emits `-c model.model_kwargs.
  extra_body.reasoning_effort=<v>` **without** a base config file. mini-
  swe-agent's CLI then interprets the dotted-key argument as a config
  file path, fails to load it, and the agent config falls back to an
  empty dict → Pydantic `ValidationError: 2 validation errors for
  InteractiveAgentConfig: system_template / instance_template Field
  required`. Net: agent silently runs with no system/instance template
  → user-sim sees a non-functional agent → all-redirect, reward=0,
  trial wallclock 3 min. Patched to materialize a one-key YAML
  (`model.model_kwargs.extra_body.reasoning_effort: <v>`) when no
  explicit `_config_yaml` is set, so the CLI gets a real `-c <file>`
  and the override applies cleanly.

### Runner / orchestrator changes

- **`src/run_eval.py`** — `--agent-type mini-swe-agent` branch:
  `MINI_SWE_AGENT_IMPORT_PATH = "user_agent.user_enabled_mini_swe_agent:
  UserEnabledMiniSweAgent"`. Forwards LiteLLM-relevant env vars
  (`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`,
  `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_BASE_URL`) plus the
  OAuth-proxy switches (`MSWEA_USE_CODEX_OAUTH`, `CODEX_HOST_AUTH_JSON`).
  Drops the claude-code-only env vars (`ANTHROPIC_*_MODEL`,
  `LITELLM_PROXY_*`, `PROXY_*`) to keep the LiteLLM dispatch clean.

### Empirical signal (cli-task-46c118 smoke, 1 trial each)

| Setup | reward | wall | reasoning behavior |
|---|---:|---:|---|
| mini-swe-agent + DeepSeek-v4-pro (native) | 1.00 | 20m39s | ~58 tok reasoning_content/msg, ~1.2K tok/turn (we observe; DeepSeek doesn't expose a knob below `high`) |
| mini-swe-agent + Opus-4.6 OR (no thinking) | 1.00 | 14m1s | `provider_specific_fields.reasoning = null`, no thinking budget — pure completion |
| mini-swe-agent + GPT-5.5 ChatGPT OAuth | (in flight at writeup) | — | proxy fix unblocks the multi-turn loop; previously all post-first-tool calls 422'd |

Token / cost recording remains weak: `MSWEA_COST_TRACKING=ignore_errors`
zeros `info.model_stats.instance_cost`. A follow-up should split this so
OAuth path stays `ignore_errors` (no usage upstream anyway — proxy
hard-codes `usage: 0/0/0`), while OR / DeepSeek paths keep LiteLLM's
real cost-tracking enabled so prompt/completion/reasoning token counts
survive in the trajectory.

## v0.9.0 — 2026-05-23

**Codex wrapper: structured followup prompt (diff + tool history).**

Fixes a class of multi-turn failures where the codex agent ran out of the
per-exec time cap (`PER_EXEC_CAP_SEC=1200`) re-exploring the codebase from
scratch on every follow-up turn — most visible on `comfyui-frontend-autoscale-layout`,
where all 3 reps produced empty patches in v0.5.1 pilot.

### Root cause

`claude_code` carries full agent tool history across turns via `claude --resume`
(server-side session continuation). Codex has no resume, so the wrapper
re-issues a fresh `codex exec` each turn. The previous followup prompt only
prepended the **last 3 KB of cumulative stdout** as "agent history" —
opaque JSON-stream slurry that gave the agent no useful state. The model
therefore rebuilt its mental model from zero every turn: re-grep, re-read
files, re-trace prior exploration. On heavy frontend repos this exceeded the
20-min per-exec cap → turn killed → no patch.

### Fix

[`_build_followup_instruction`](user_enabled_codex.py) now constructs a
structured prompt with three explicit state-restoration sections:

1. **`CURRENT WORKSPACE STATE`** — full cumulative `git diff vs harbor-base`
   (capped at 20 KB), read from `logs_dir/final.patch` which `capture_git_diff`
   already writes after each turn. The agent now sees exactly which files have
   been modified and what the edits look like.
2. **`RECENT TOOL CALLS`** — last 3 turns of compact tool-call log produced
   by the new `_extract_tool_calls_compact()`. Parses codex stream-json,
   extracts `command_execution` / `apply_patch` / `function_call`
   items, keeps each output's last 500 chars and caps total per-turn log at
   4 KB. On a real comfyui turn-0 with 272 KB of raw stream output, this
   compresses to ~3.7 KB while preserving every shell command + output tail
   (73× compression).
3. **`PRIOR USER MESSAGES`** — numbered list of just the user-sim messages
   (no agent stdout). Compact and structured.

Followup prompt size is comparable to before (~30 KB on a multi-turn task)
but signal density is dramatically higher.

### Storage additions

- `self._tool_history: list[str]` — one compact log per turn, appended in
  the `finally` block of turn-0 and every multi-turn exec.
- `self._last_cumulative_diff: str` — re-read from `logs_dir/final.patch`
  after each `_capture_git_diff`. No changes to the shared `repo_diff` API;
  `claude_code` and `gemini_cli` are unaffected.

### Module-level knobs

- `_TOOL_OUTPUT_CHAR_CAP = 500` — per single tool call
- `_TOOL_HISTORY_TURN_CAP = 4000` — per turn
- `_TOOL_HISTORY_TURNS_KEPT = 3` — only inject last N turns (older
  turns' net effect is already in the cumulative diff)
- `_CUM_DIFF_CHAR_CAP = 20000` — cumulative-diff section cap

### What this does NOT change

- `claude_code` wrapper: unchanged. Still uses `--resume`.
- `gemini_cli` wrapper: unchanged. Still uses full-history re-issue (could
  benefit from the same upgrade in a follow-up).
- Codex's `CODEX_USE_RESUME=1` opt-in path: unchanged. The new prompt
  structure only fires on the fallback (full re-issue) path.
- User-sim's `code_changes_diff` channel: unchanged (still uses
  `self._last_turn_diff` = incremental).

### Companion fix — per-turn diff capture: `git commit --no-verify`

Caught while smoke-testing the codex wrapper upgrade. The shared per-turn
diff-capture script (`repo_diff.py:_repo_discovery_cmd`, mirrored in
`user_enabled_claude_code.py:_capture_git_diff`) does `git add -A && git
commit --allow-empty -m "harbor-turn-N"` before computing `git diff
harbor-base HEAD`. On repos with husky/lint-staged pre-commit hooks (e.g.
`comfyui-frontend-autoscale-layout`), the hook fails in the sandbox (no
`pnpm install` for hook deps), the commit fails silently (stderr redirected
to `/dev/null`), `harbor-turn-N` never advances, and the diff returns
empty — **masking real agent edits across multiple turns**.

Empirical: cc+OR comfyui pilot trials show empty patches for turns 0-9,
non-empty only from turn 10 onward (the moment the hook happens to pass).
Codex's `file_change` mechanism never triggered a hook-passing edit so its
patches stayed empty through every turn.

Fix: add `--no-verify` to both `git commit` invocations (baseline tag +
per-turn). Applied to both `repo_diff.py` and `user_enabled_claude_code.py`
(claude_code has its own embedded copy of the script). Affects every
agent's diff capture; no behavior change for repos without commit hooks.

### Empirical signal (smoke test, 1 trial, comfyui task)

Followup prompt verified to contain all 4 new sections. With the old wrapper
all 3 reps produced 55-byte empty stubs across two separate pilot runs.
A full re-run is pending to quantify cohort-level impact.

## v0.8.0 — 2026-05-24

**Codex + Gemini-CLI user-sim enablement.**

Two new agent wrappers join `UserEnabledClaudeCode`, so the same user-sim +
ground-truth + per-turn-diff machinery now works against codex (OpenAI/codex
CLI) and gemini-cli (Google Gemini CLI). Both follow the
"sequential re-issue with conversation history" pattern (neither CLI has
`--resume`).

### New wrappers

- **`UserEnabledCodex`** ([src/user_agent/user_enabled_codex.py](user_enabled_codex.py))
  - Routes gpt-5.x through codex via three auth/backend paths:
    1. `--model openrouter/openai/gpt-5.x` → codex 0.117.0 + OR HTTP Chat Completions
       (0.117.0 pinned because newer codex requires the WebSocket Responses API
        that OpenRouter does not expose). Wrapper preserves the `openrouter/...`
        prefix so OR receives `openai/gpt-5.5`, not the bare leaf.
    2. `--model openai/gpt-5.x` + `OPENAI_BASE_URL` env (any OpenAI-compat
       backend). Cleanly handed off via the upstream `openai_base_url` config.toml
       block (harbor PR #1482).
    3. **ChatGPT subscription OAuth** (`CODEX_USE_HOST_AUTH=1`):
       overlays the host's `~/.codex/auth.json` into the in-sandbox
       `$CODEX_HOME/auth.json`, so the in-sandbox codex bills against the
       host user's ChatGPT subscription (flat cost) instead of pay-per-token
       API. `CODEX_VERSION=0.133.0` env var upgrades the in-sandbox codex past
       the 0.117.0 default (required for gpt-5.5 model name).
  - Opt-in `codex exec resume <thread_id>` path
    (`CODEX_USE_RESUME=1`) — captured but off by default until the
    verifier-flake regression is root-caused.

- **`UserEnabledGeminiCli`** ([src/user_agent/user_enabled_gemini_cli.py](user_enabled_gemini_cli.py))
  - Wraps `gemini --yolo --model=<model> --prompt=<msg>` with the same
    multi-turn / user-sim / per-turn-diff pipeline.
  - Setup auto-strips repo-level `.gemini/settings.json` (often ships
    project-level hooks like `entire-before-tool` that call `go`/`pre-commit`
    binaries not in our sandbox, deadlocking every tool call).
  - Sets `GEMINI_CLI_TRUST_WORKSPACE=true` so the CLI doesn't reject the
    workspace as "untrusted" in headless mode.

### Shared infrastructure (NEW)

- **`src/user_agent/exec_helpers.py`** — `exec_with_budget()` wraps every
  `environment.exec()` call with two guards:
  - `PER_EXEC_CAP_SEC = 1200` (20 min) — single-call ceiling via
    `asyncio.wait_for`, so a hung in-sandbox call dies fast.
  - `TRIAL_BUDGET_SEC = 7200` (2 h) — trial-wide wall-clock. Codex+gpt-5.5
    runs ~3× slower than claude_code+Opus; the budget guard caps that ratio
    without leaving the cohort exposed to multi-hour single tasks.
  - On timeout: returns a synthetic `_TimeoutResult` so the caller's
    `result.return_code` / `.stdout` paths still work, and the multi-turn
    loop can break gracefully and still capture `final.patch`.

  Without this, the v0.7.0 wrapper would hang silently — observed in early
  Gemini scout where one stuck `gemini exec` burned **6 h 36 min** on a
  single trial before manual kill.

- **`src/user_agent/repo_diff.py`** — shared per-turn diff capture
  (`tag_harbor_base()`, `capture_git_diff()`, `_repo_discovery_cmd()`).
  Extracted from the v0.7.0 claude_code wrapper so codex + gemini_cli
  inherit the same `patches/turn-N.{patch,incremental.patch}` artifacts +
  `_last_turn_diff` feed into `UserAgent.process(code_changes_diff=…)`.

### Runner / orchestrator changes

- **`src/runner.py`** — `--agent-type gemini-cli` added; existing
  Chutes/OpenRouter/Fireworks/GLM proxy branches gated on
  `agent_type == "claude-code"` so codex+OpenRouter no longer hijacks
  the claude-code proxy env (which would set `action_model =
  "claude-sonnet-4-6"` and corrupt the codex invocation). New
  `is_openrouter and agent_type == "codex"` branch sets `OPENAI_BASE_URL`
  on the host so the codex wrapper reads it.

- **`src/run_eval.py`** — `--agent-type {claude-code,codex}` flag added
  (default claude-code, backwards-compatible). When `--agent-type codex`,
  switches `import_path` to `UserEnabledCodex`, drops the claude-code-only
  env vars (`ANTHROPIC_*`, `LITELLM_PROXY_*`, `PROXY_*`), and forwards the
  codex-relevant host env vars (`CODEX_USE_HOST_AUTH`,
  `CODEX_HOST_AUTH_JSON`, `CODEX_VERSION`, `CODEX_USE_RESUME`,
  `OPENAI_BASE_URL`) into the trial's agent_env. Also pops the
  `version: "2.1.108"` kwarg (Claude Code's version, would otherwise pass
  into `install-codex.sh.j2`'s `{% if version %}` block and `npm install -g
  @openai/codex@2.1.108` would ETARGET).

- **`src/user_agent/__init__.py`** — note explaining the three wrappers are
  lazy-loaded via `import_path` to keep package import cheap.

### Upstream harbor changes (already merged, `1ef3ced6`)

- Backported harbor PR [#1482](https://github.com/harbor-framework/harbor/pull/1482):
  codex 0.118.0+ only honors `openai_base_url` from `$CODEX_HOME/config.toml`,
  not the env var; setup_command now appends the config.toml block when
  `OPENAI_BASE_URL` is set. MCP-servers config write switched from `>` to
  `>>` so it composes with the new block.
- Pinned `install-codex.sh.j2` to `@openai/codex@0.117.0` (last version
  whose HTTP Chat Completions fallback works with OpenRouter). Wrapper-side
  `CODEX_VERSION` env var triggers an in-sandbox upgrade after setup for
  flows that don't need OR (e.g. OpenAI direct + ChatGPT OAuth on
  gpt-5.5, which requires ≥0.118.0).

### Empirical scout results on cli-task-46c118

| Setup | reward | wall | cache hit | cost/trial |
|---|---:|---:|---:|---:|
| claude_code + Opus-4.6 (OAuth) | 1.00 | 7.0 min | server-side (Anthropic) | $0 (subscription) |
| codex + gpt-5.5 (OR direct, 0.117.0) | 0.80 | 16-26 min | 90.6% | ~$2.49 (OR pay-per-token) |
| codex + gpt-5.5 (OpenAI direct + ChatGPT OAuth, 0.133.0) | 0.80 | 21 min | 92% | $0 (subscription) |
| claude_code + gpt-5.5 (OR proxy) | 0.80 | 7.8 min | 23.6% (proxy drops `cache_control`) | ~$7.78 (OR pay-per-token) |

Validates the wrapper plumbing end-to-end across all four (model, harness, auth)
combinations; the speed/cost trade-offs above are structural to each
combination, not wrapper bugs.

## v0.7.0 — 2026-05-11

**Per-turn incremental git diff fed to user sim.**

The sim previously saw only the agent's self-narration (`thinking` / `text` /
`result` blocks) plus tool-call signatures (file paths and command prefixes).
Tool results — including Bash stdout, file contents, and the actual code
written by Edit/Write — were dropped by `_parse_stream_json`. The sim had no
independent channel to verify "I added X to Y" claims.

`UserEnabledClaudeCode._capture_git_diff` now:
- Tags the workspace state at the end of every turn (`harbor-turn-<N>`).
- Computes an incremental diff between the prior turn's tag and the
  current HEAD (vs `harbor-base` for turn 0).
- Writes `patches/turn-<N>.incremental.patch` alongside the existing
  cumulative `patches/turn-<N>.patch` (per-turn-replay infrastructure is
  unchanged).
- Stashes the incremental diff on `self._last_turn_diff` so the next
  `_consult_user` call passes it to `UserAgent.process(code_changes_diff=…)`.

`UserAgent._build_turn_summary` renders a new
`## Code changes (this turn)` section as a ```diff``` block when the
diff is non-empty. Not truncated by design — per-turn deltas are
naturally bounded by the agent's single-turn work; the dedup property of
`git diff` collapses redundant Edits on the same lines, so even busy
turns rarely exceed a few KB.

Implementation notes:
- The marker-commit dance (`git add -A && commit --allow-empty &&
  tag -f`) means agent commits get sandwiched between `harbor-turn-<N>`
  commits; the agent's own `git log` will show extra entries. Acceptable
  because the agent rarely inspects `git log` in coding tasks and our
  Dockerfiles pre-commit the workspace state under `harbor-base` already.
- Empty turns produce empty diffs, suppressed in the sim prompt.

## v0.6.0 — 2026-04-07

**Turn quality overhaul: dedup, timing, reasoning, tool_choice.**

Six fixes to the user simulator's turn presentation and decision reliability.

### Turn summary dedup (Fix 1 & 2)

Agent Activity and Terminal Output were byte-for-byte identical — both
called `_snapshot_recent_output()`. Now `_snapshot_latest_turn()` returns
separate `(trajectory, observation)`: trajectory is the full step log,
observation is the last few result/agent lines.

Additionally, Turn N previously re-sent all steps from turns 1..N (O(N²)
growth). Now only sends the latest turn's activity — prior turns are
already in conversation history. Step IDs are globally continuous (no
restart at `[1]` each turn).

Net impact: Turn 2 shrinks from ~54K to ~16K chars (~70% reduction).

### Timing in turn summaries (Fix 3)

`_build_turn_summary()` now includes `**Timing:** Elapsed: 52min, this
turn took 3min` so the LLM can match time-based triggers from session
analysis (e.g., "52min 15s after last assistant message").

### Reasoning preservation in history (Fix 4)

Only `decision.content` (the tool argument) was stored in conversation
history — Gemini's reasoning about *why* it made each decision was
discarded. `format_for_history()` now preserves reasoning + structured
decision, filtering internal prefixes and deduplicating.

### tool_choice=required (Fix 5)

Forces Gemini to always call a tool (`no-op`, `question`, `redirect`,
`new_requirement`, or `check_external`). Eliminates 1,269 text-as-no-op
cases per eval run. Maps to Gemini's `functionCallingConfig.mode = "ANY"`
via LiteLLM. Includes one retry if the provider silently ignores it.

### Smart fallback parser (Fix 6)

Replaces the all-or-nothing `_fallback_parse` (which silently dropped
203 real messages across 10,566 decisions). Now:
- Detects intended no-ops (model said "stayed silent" as text)
- Recovers `→ action: content` format from history leaking
- Recovers short (<500 char) non-reasoning text as redirect messages
- Defaults to no-op only for long reasoning text

Validated against 10,566 historical decisions: **202/203 recovered, 0
false positives**.

**E2E validation (3 tasks, claude-opus-4-6 + gemini-3.1-pro):**

| Task | Reward | Interventions |
|------|--------|---------------|
| banodoco-video-perf-optimize | 0.70 | 8 |
| qwen3-moe-gguf-dequant | 0.81 | 6 |
| comfyui-newbie-lumina-refactor | 0.04 | 1 |

## v0.5.2 — 2026-04-04

**Incremental CC turns + relaxed trigger interpretation.**

Two changes to increase user sim intervention opportunities on Claude Code:

### Incremental work instruction

Appends to the CC agent's instruction: "Work incrementally. After completing
each distinct sub-task, STOP and report what you did. Wait for user feedback
before proceeding." This creates more `--resume` checkpoints where the user
sim can intervene.

### Relaxed trigger interpretation

Injects global guidance into the user sim's system prompt telling it to apply
sim prompt triggers broadly: fire GT messages in sequence even if the exact
intermediate state described in the trigger isn't a perfect match, and check
whether completed work has issues rather than only looking for specific
intermediate states.

**A/B results (CC + Gemini, 3 tasks):**

| Task | GT | v0.5 msgs | v0.5.2 msgs | v0.5 reward | v0.5.2 reward |
|------|-----|-----------|-------------|-------------|---------------|
| sd-scripts | 4 | 3 | 3 | 0.93 | 0.93 |
| sageattention | 6 | 2 | 2 | 0.35 | 0.35 |
| **banodoco** | **27** | **3** | **5** | **0.70** | **0.55** |

Key finding: **banodoco went from 3 to 5 sim messages.** Previous run sent
GT turns 2, 3, 4 (early animation bugs). This run sent GT turns 2, 13, 14,
15, 16 (progressive timeline, speed, labels) — later GT turns that were
previously unreachable because CC completed too much per turn.

All 5 messages are verbatim GT quotes. The incremental instruction created
more checkpoints, and the relaxed triggers let the sim fire later-stage
GT messages that matched completed (not intermediate) work.

sd-scripts and sageattention unchanged — simple enough that the agent
completes the whole task in one sub-task regardless.

## v0.5.1 — 2026-04-04

**Wall-clock timing and GT session duration tracking.**

- Extract original session duration from `original_session.json`
  (`start_time`/`end_time` fields)
- Measure trial wall-clock time via `time.time()`
- Print speedup ratio (gt_duration / trial_time) after each trial
- Write `timing.json` to each trial directory

**Sample output:**
```
  wall_clock : 1222s (20.4m)
  gt_duration: 7279s (121.3m)
  speedup    : 5.96x
```

Speedup ratios observed: 4.4x (sd-scripts), 8.0x (sageattention), 6.0x
(banodoco). Agents are consistently 4–8x faster than real users.

## v0.5 — 2026-04-03

**Three changes to improve user simulation realism and cross-harness fairness.**

### Repo config file injection

All three agent harnesses (Terminus 2, Claude Code, Codex) now discover and
inject repo configuration files (CLAUDE.md, AGENTS.md, `.claude/`, `.ai/`,
`.cursor/`, `.cursorrules`, `.github/copilot-instructions.md`) into the
agent's instruction at the start of `run()`. ~20 of 45 task repos contain
such files. Previously only Claude Code auto-discovered them natively.

New file: `src/user_agent/repo_config.py`

### Structured output for Claude Code user sim

Claude Code's `_snapshot_recent_output()` now parses stream-json into
structured step summaries (`[step_id] thinking: ...`, `tool_call(Bash): ...`,
`agent: ...`) instead of passing raw JSON tail to the user sim. This matches
Terminus 2's trajectory format and is closer to what a real user sees.

Verified: 57,544 chars of raw JSON → 11 structured steps. In A/B testing,
structured output made the user sim more informed and more conservative —
fewer redundant follow-ups, same message quality.

### Soft message guidance (replaces hard cap)

Removed `max_messages` hard cap. Previously, restrictive caps in
`user_simulation_prompt.md` (e.g., "EXACTLY 0–2" when GT=6) suppressed
realistic simulation. Now the runner computes a GT-based guidance range
(`GT*0.5` – `GT*1.5`) and injects it as a soft target into the user sim's
system prompt. The user sim decides based on context, not an enforced ceiling.

**24-experiment comparison** (2 harnesses × 2 user models × 3 tasks, before/after)
documented in `src/user_agent/agent_test_comparison.md`.

Key results from the soft guidance A/B (hard cap → soft guidance):
- **openclaw** (GT=5): 0 msgs across all 4 configs → T2+Opus **3 msgs**, T2+Gemini **1 msg** (reward 0.21→0.86). Previously hard-capped or trigger-blocked; soft guidance let the sim send quality-check messages about AGENTS.md completeness.
- **sd-scripts** (GT=4): CC+Opus 2→**5 msgs** with natural progressive review. CC+Gemini and T2 configs unchanged (already within range).
- **sageattention** (GT=6): T2+Gemini 1→**2 msgs**. CC configs unchanged. Bottleneck is sim prompt trigger design, not cap.
- **openclaw CC harness** still gets 0 msgs — session ID parsing bug prevented resume turns. **Fixed**: `_find_session_id()` now parses from captured stdout (stream-json init event) instead of relying on `_get_session_dir()` which fails with multiple project directories. After fix, session IDs are found reliably but user sim still chooses no-op — CC completes the task in one autonomous turn, so the sim sees a finished result and has nothing to add (vs T2 which gives 10+ mid-task intervention points).

## v0.4.0 — 2026-03-29

**Feature: multi-turn user simulation for Claude Code and Codex**

Added `--agent-type` CLI option to `runner.py` to select the coding agent
backend. All three supported agent types get full user simulation:

- **`terminus`** (default) — `UserEnabledTerminus2`. In-process LLM agent;
  user sim injects messages directly into the chat history mid-loop.
- **`claude-code`** — `UserEnabledClaudeCode`. Runs Claude Code CLI, then
  uses `claude --resume <session_id>` to continue the conversation with
  simulated user messages. Real conversation continuity across turns.
- **`codex`** — `UserEnabledCodex`. Runs `codex exec`, then re-runs with
  accumulated conversation history prepended to the instruction (no native
  resume in Codex CLI).

**Shared user sim parameters** (all three agents):

| Parameter | Default | Source |
|-----------|---------|--------|
| `user_model_name` | `anthropic/claude-opus-4-6` | `--user-model` CLI / `user_model` in config.yaml |
| `user_temperature` | `0.5` | Hardcoded |
| `user_context_chars` | `3000` | `user_context_chars` in config.yaml |
| `max_messages` | GT count + 5 (cap 15) | Extracted from `user_simulation_prompt.md` or defaulted |
| `call_user_on_completion` | `true` | `call_user_on_completion` in config.yaml |

**Agent-specific parameters:**

| Parameter | terminus | claude-code | codex |
|-----------|----------|-------------|-------|
| Max agent turns | `1000000` (Terminus2 default) | `15` (`_MAX_RESUME_TURNS`) | `15` (`_MAX_RESUME_TURNS`) |
| Multi-turn mechanism | In-process chat injection | `claude --resume <session_id>` | Re-run `codex exec` with accumulated context |
| API key env var | Via LiteLLM (any provider) | `ANTHROPIC_API_KEY` | `OPENAI_API_KEY` |
| OpenRouter compatible | Yes (`openrouter/` prefix) | No (Anthropic API format) | Possibly (`OPENAI_BASE_URL`) |

Other Harbor-installed agents (`aider`, `swe-agent`, etc.) fall back to
single-shot mode without user simulation.

New files:
- `src/user_agent/user_enabled_claude_code.py`
- `src/user_agent/user_enabled_codex.py`

Also added `openai` to the provider map for Codex/OpenAI models, and
`agent_type` is configurable via `config.yaml`.

## v0.3.1 — 2026-03-27

**Fix: fallback_parse always returns no-op**

When the LLM responds with plain text instead of a tool call, treat it as
no-op. Previously, raw text was injected as a user message — this caused the
`[silent — no-op]` leak where 6/9 messages on amdgpu were internal markers
sent to the agent.

## v0.3.0 — 2026-03-27

**Major: conversation history + hard message cap**

Inspired by tau-bench/tau2-bench (Sierra Research). Three changes:

1. **Conversation history** — `self._messages` accumulates across turns. The
   LLM sees what it already said. Fixes the 13x repetition bug
   (sd-scripts-skip-resolution-tuple: 65 msgs → expected ~5).

2. **Hard message cap** (`max_messages`) — extracted from user_simulation_prompt.md
   or defaulted to GT count + 5. Enforced before the LLM call — no reliance on
   the LLM reading a Stats line.

3. **Removed `example_phrases` from persona** — these leaked GT messages
   permanently in the system prompt, causing repetition after GT exhaustion.

Also: removed `build_persona_from_analysis()` (analysis.json deprecated),
fixed runner to load `user_simulation_prompt.md` (not `analysis.md`),
softened completion-check nudge.

**A/B test results (10 tasks, pre-fallback-fix):**

| Task | Old | New | Delta |
|------|-----|-----|-------|
| amdgpu-kernel-619-compat (PROBLEM) | 0.0 | 0.56 | +0.56 |
| sd-scripts-skip-resolution-tuple (PROBLEM) | 0.8 | 0.75 | -0.05 |
| sd-scripts-fp8-lumina (PROBLEM) | 0.4 | 0.37 | -0.03 |
| sageattention-headdim-256 | 0.2 | 1.0 | +0.80 |
| nunchaku-awq-quantization | 0.7 | 1.0 | +0.30 |
| openclaw-security-review-flow | 0.6 | 0.75 | +0.15 |
| sd-scripts-dedup-early-exit | 0.85 | 1.0 | +0.15 |
| reigh-timeline-mode-cleanup | 0.5 | 0.6 | +0.10 |
| triton-amd-fp8-lowering | 1.0 | 1.0 | 0 |
| triton-msvc-c4267-warnings | 0.75 | 0.6 | -0.15 |

Average delta: +0.18. Note: sd-scripts-skip-resolution-tuple still had 32
leaked messages due to the fallback bug (fixed in v0.3.1).

## v0.2.0 — 2026-03-25

**Initial: stateless tool-calling simulator**

- Each LLM call is independent (no conversation history)
- Ground-truth messages shown as sliding window in prompt
- Stats line (`"54 calls, 9 messages sent"`) for self-regulation
- `example_phrases` in persona (all GT messages permanently visible)
- No hard message cap — relies on LLM compliance
- Known failure: 13x over-simulation on sd-scripts-skip-resolution-tuple
