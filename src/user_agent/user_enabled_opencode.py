"""OpenCode wrapper with simulated user injection via `--session=<id>` resume.

OpenCode (the opencode-ai npm CLI) is a multi-provider coding agent with
first-class session resume — `opencode run --session=<id>` reconnects the
CLI's local session store, replays prior history to the model, and continues
the conversation. From the wrapper's POV this is structurally identical to
claude_code's `--resume`, so this file is much closer to
`user_enabled_claude_code.py` than to `user_enabled_codex.py` or
`user_enabled_mini_swe_agent.py` (which do wrapper-side history-replay
because their CLIs have no native resume).

Multi-turn pattern:

  Turn 0: opencode --model=<provider/model> run --format=json -- <instruction>
          → parse `sessionID` from the stdout JSON event stream
  Turn N: opencode --model=<provider/model> run --session=<sid>
                   --format=json -- <user_message>

The `--format=json` event stream emits one JSON object per line; we parse
`step_start` / `step_finish` / `text` / `tool_use` events into a structured
trajectory snapshot for the user simulator, mirroring the same `[step]
thinking / tool_call / result` shape we use for claude_code + mini-swe-agent.

Each turn's `opencode run` overwrites `/logs/agent/opencode.txt` by default
(Harbor's `tee` is non-append). We append (`tee -a`) so the final file
contains the full multi-turn event stream, and we additionally archive each
turn's stdout to `opencode.txt.turn-<N>` so prior turns' events survive even
if `opencode.txt` is later truncated for any reason.
"""

from __future__ import annotations

import json
import logging
import os
import shlex
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import ExecInput
from harbor.agents.installed.opencode import OpenCode
from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.llms.lite_llm import LiteLLM

from .exec_helpers import TRIAL_BUDGET_SEC, exec_with_budget
from .litellm_proxy import launch_litellm_proxy, mask_proxied_model_name
from .repo_config import discover_repo_config_files
from .repo_diff import capture_git_diff, tag_harbor_base
from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15
_MAX_CONSECUTIVE_NOOPS = 4
_OPENCODE_LOG = "/logs/agent/opencode.txt"


def _normalize_content(raw_content: Any) -> str:
    """Stringify an OpenCode content field (string, dict, list of parts, None)."""
    if raw_content is None:
        return ""
    if isinstance(raw_content, str):
        return raw_content
    if isinstance(raw_content, list):
        parts = []
        for part in raw_content:
            if isinstance(part, dict):
                parts.append(part.get("text") or part.get("content") or "")
            else:
                parts.append(str(part))
        return "\n".join(p for p in parts if p)
    if isinstance(raw_content, dict):
        return raw_content.get("text") or raw_content.get("content") or str(raw_content)
    return str(raw_content)


class UserEnabledOpenCode(BaseAgent):
    """OpenCode + simulated user via `opencode run --session=<id>` resumes.

    Functionally mirrors `user_enabled_claude_code` (native-resume path) —
    per-turn git diff capture, wall-clock timing, no-op streak allowance —
    except the inner harness is OpenCode (multi-provider, JSON event stream).
    """

    SUPPORTS_ATIF: bool = True

    def __init__(
        self,
        logs_dir: Path,
        model_name: str | None = None,
        *,
        user_model_name: str = "anthropic/claude-opus-4-6",
        user_api_base: str | None = None,
        user_api_key: str | None = None,
        user_temperature: float = 0.5,
        user_context_chars: int = 3000,
        original_user_messages: list[str] | None = None,
        session_analysis: str = "",
        max_messages: int | None = None,
        call_user_on_completion: bool = True,
        # Default to `high` so missed launcher flags don't silently disable
        # thinking on agentic trials. Matches Anthropic adaptive-thinking's
        # recommended default for complex / multi-turn tasks (see
        # https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking).
        reasoning_effort: str | None = "high",
        opencode_version: str | None = None,
        **kwargs,
    ):
        # `minimaxd/`, `glmd/`, `ark/`, etc. are our naming convention for
        # provider-direct routing via the in-sandbox proxy on localhost:4210.
        # Harbor's OpenCode (and the underlying `opencode-ai` CLI inside the
        # sandbox) reject these prefixes ("Unknown provider minimaxd"). Mask
        # to "anthropic/claude-sonnet-4-6"; opencode's anthropic provider hits
        # ANTHROPIC_BASE_URL=localhost:4210, and the proxy rewrites the body
        # model field to MiniMax-M2.7 / glm-5.1 / etc. before forwarding.
        inner_model_name = mask_proxied_model_name(model_name)
        self._using_proxied_provider = inner_model_name != model_name
        if self._using_proxied_provider:
            log.info(
                "opencode: masking model %r → %r for Harbor + opencode CLI (proxy handles real routing)",
                model_name, inner_model_name,
            )
        super().__init__(logs_dir=logs_dir, model_name=inner_model_name, **kwargs)

        # Drop kwargs the inner OpenCode doesn't accept, then construct it.
        # `version` is forwarded to install-opencode.sh.j2 via Harbor's
        # `_template_variables` to pin the in-sandbox `opencode-ai@<v>` install.
        kwargs.pop("version", None)
        inner_kwargs: dict[str, Any] = dict(kwargs)
        if opencode_version:
            inner_kwargs["version"] = opencode_version
        self._inner = OpenCode(
            logs_dir=logs_dir, model_name=inner_model_name, **inner_kwargs,
        )
        # reasoning_effort: OpenCode's --variant flag toggles "reasoning
        # variants" but its semantics are provider-specific (anthropic
        # extended-thinking budget, openai reasoning.effort, …). We thread
        # the value into the resume command directly when set; on turn 0 we
        # rely on Harbor's existing invocation, since the inner agent
        # doesn't yet accept a reasoning kwarg.
        self._reasoning_effort = reasoning_effort

        self._sim_user = UserAgent(
            llm=LiteLLM(
                model_name=user_model_name,
                api_base=user_api_base,
                api_key=user_api_key,
                temperature=user_temperature,
            ),
            original_user_messages=original_user_messages,
            session_analysis=session_analysis,
            max_messages=max_messages,
        )
        self._ctx_budget = max(500, user_context_chars)
        self._check_on_completion = call_user_on_completion
        self._task_instruction = ""
        self._cumulative_output: list[str] = []
        self._start_time: float = 0.0
        self._turn_start_time: float = 0.0
        # Per-turn incremental git diff (vs prior turn's tag) fed to user-sim
        # as an independent view of what the agent actually wrote this turn.
        self._last_turn_diff: str = ""

    @staticmethod
    def name() -> str:
        return "user-enabled-opencode"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)
        # Tag every git repo as `harbor-base` so per-turn `git diff` can
        # show only the agent's edits, even when a Dockerfile post-checkout
        # `git commit` lands mid-trial. See repo_diff for rationale.
        await tag_harbor_base(environment)
        # Launch the in-sandbox LiteLLM-compat proxy on localhost:4210 when
        # we're routing through a provider-direct path (minimaxd/, glmd/,
        # ark/, fireworks/, deepseek/, openrouter/). build_agent_env in
        # src/run_eval.py already set LITELLM_PROXY_MODEL + PROXY_TARGET_URL
        # + ANTHROPIC_BASE_URL=http://localhost:4210 in the agent env; the
        # helper picks those up and starts the proxy. No-op when env vars
        # aren't set (direct Anthropic or codex-oauth runs).
        await launch_litellm_proxy(environment, self.logs_dir)
        # OAuth proxy path (MSWEA_USE_CODEX_OAUTH reused as the universal
        # "use host ChatGPT subscription" flag): drop oauth_proxy.py +
        # ~/.codex/auth.json into the sandbox, start the proxy on
        # 127.0.0.1:4220. OpenCode's openai provider will then route via
        # the proxy through OPENAI_BASE_URL injected at command-build time.
        if os.environ.get("MSWEA_USE_CODEX_OAUTH") == "1":
            await self._launch_codex_oauth_proxy(environment)

    async def _launch_codex_oauth_proxy(self, environment: BaseEnvironment) -> None:
        """Mirror of mini-swe-agent wrapper's proxy launch. The two harnesses
        intentionally share `oauth_proxy.py` so a single Chat-Completions ↔
        ChatGPT-Responses translator covers both code paths."""
        host_auth_path = os.environ.get(
            "CODEX_HOST_AUTH_JSON", str(Path.home() / ".codex" / "auth.json")
        )
        host_proxy_path = Path(__file__).parent / "oauth_proxy.py"
        if not Path(host_auth_path).exists():
            log.warning("MSWEA_USE_CODEX_OAUTH=1 but %s not found — proxy not started",
                        host_auth_path)
            return
        if not host_proxy_path.exists():
            log.warning("oauth_proxy.py not found at %s — proxy not started",
                        host_proxy_path)
            return
        staged_auth = self.logs_dir / "codex-auth.json"
        staged_proxy = self.logs_dir / "oauth_proxy.py"
        staged_auth.write_text(Path(host_auth_path).read_text())
        staged_proxy.write_text(host_proxy_path.read_text())
        await environment.upload_file(
            source_path=staged_auth, target_path="/tmp/codex-auth.json",
        )
        await environment.upload_file(
            source_path=staged_proxy, target_path="/tmp/oauth_proxy.py",
        )
        # Harbor's opencode install brings nvm/node but no Python deps; the
        # base E2B image's /usr/bin/python3 may be stripped (no pip, no aiohttp).
        # We need aiohttp for oauth_proxy.py's HTTP server + client. Cascade
        # through install strategies — mirrors install-mini-swe-agent.sh.j2's
        # proven recipe. Each branch's failure feeds the next; the final
        # `import aiohttp` is the authoritative gate.
        start_cmd = (
            # 1. apt path — fastest if running as root (template-time setups)
            # or where agent has passwordless sudo. python3-aiohttp gives us
            # the lib in one shot without ever touching pip.
            "(apt-get install -y -qq python3-aiohttp 2>/dev/null "
            "  || sudo -n apt-get install -y -qq python3-aiohttp 2>/dev/null "
            # 2. Bootstrap pip via ensurepip (stdlib), then pip install aiohttp
            # to user site-packages.
            "  || (python3 -m ensurepip --user 2>/dev/null; "
            "      python3 -m pip install --user --quiet --break-system-packages aiohttp 2>/dev/null) "
            # 3. Bring pip in via apt, then pip install.
            "  || (apt-get install -y -qq python3-pip 2>/dev/null "
            "      || sudo -n apt-get install -y -qq python3-pip 2>/dev/null; "
            "      python3 -m pip install --user --quiet --break-system-packages aiohttp 2>/dev/null) "
            ") >/tmp/oauth_proxy_install.log 2>&1; "
            # 4. Gate — verify importability. Surface the install log on failure
            # so we can see which strategy ran and why it didn't land aiohttp.
            'if ! python3 -c "import aiohttp" 2>/tmp/oauth_proxy_import.err; then '
            '  echo "ERROR: aiohttp not importable in sandbox python3 — proxy cannot start" >&2; '
            '  echo "--- install log ---" >&2; '
            "  cat /tmp/oauth_proxy_install.log >&2 2>/dev/null; "
            '  echo "--- import error ---" >&2; '
            "  cat /tmp/oauth_proxy_import.err >&2 2>/dev/null; "
            "  exit 1; "
            "fi; "
            "nohup python3 /tmp/oauth_proxy.py "
            "  --port 4220 --auth-json /tmp/codex-auth.json "
            "  > /tmp/oauth_proxy.log 2>&1 & "
            "for i in $(seq 1 20); do "
            "  sleep 1; "
            "  curl -sf http://127.0.0.1:4220/health > /dev/null 2>&1 && "
            "  echo 'oauth_proxy ready' && exit 0; "
            "done; "
            "echo 'WARNING: oauth_proxy not healthy after 20s' >&2; "
            "tail -30 /tmp/oauth_proxy.log >&2; exit 1"
        )
        result = await environment.exec(command=start_cmd, timeout_sec=120)
        if result.return_code != 0:
            log.warning("oauth_proxy start failed: rc=%s\n%s",
                        result.return_code, (result.stderr or result.stdout)[-2000:])
        else:
            log.info("oauth_proxy launched in sandbox on 127.0.0.1:4220")
        self._oauth_proxy_env = environment

    async def _flush_proxy_log(self) -> None:
        """Pull /tmp/oauth_proxy.log back to host for offline debug."""
        env = getattr(self, "_oauth_proxy_env", None)
        if env is None:
            return
        try:
            result = await env.exec(
                command="cat /tmp/oauth_proxy.log 2>/dev/null | tail -200",
                timeout_sec=15,
            )
            (self.logs_dir / "oauth_proxy.log").write_text(result.stdout or "(empty)")
            log.info("oauth_proxy.log saved (%d bytes)", len(result.stdout or ""))
        except Exception as e:
            log.debug("failed to pull proxy log: %s", e)

    # ── session ID extraction ─────────────────────────────────────────

    def _find_session_id(self) -> str | None:
        """Parse `sessionID` from the captured opencode JSON event stream.

        OpenCode emits `{type:"step_start", sessionID:"ses_…"}` (and other
        event types carrying the same sessionID) on its first turn. We scan
        cumulative stdout in order and return the first non-empty ID.
        """
        for raw in self._cumulative_output:
            for line in raw.split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                sid = event.get("sessionID") or event.get("session_id")
                if isinstance(sid, str) and sid:
                    return sid
        return None

    # ── command post-processing (variant flag + OAuth env injection) ──

    def _inject_opencode_flags(self, commands: list[ExecInput]) -> list[ExecInput]:
        """Post-process Harbor's `opencode run` commands so they match our
        wrapper's settings:

        - Inject `--variant=<reasoning_effort>` between `run` and the rest
          of the args, so turn-0 uses the same reasoning depth as resume
          turns (Harbor's builder doesn't accept a reasoning kwarg yet).
        - When OAuth proxy is on, inject `OPENAI_BASE_URL` + a placeholder
          `OPENAI_API_KEY` so OpenCode's openai provider routes through the
          in-sandbox proxy on 127.0.0.1:4220.
        """
        oauth_on = os.environ.get("MSWEA_USE_CODEX_OAUTH") == "1"
        for c in commands:
            if "opencode --model=" in c.command and "run --format=json" in c.command:
                # `--thinking` makes OpenCode emit `{type:"reasoning", part:{
                # text:…}}` events into the JSON stream — without it, non-
                # interactive runs suppress reasoning entirely (run.ts:251
                # defaults thinking=false in non-interactive mode). The model
                # is still thinking per --variant; this flag only controls
                # whether the trace shows up in our opencode.txt capture.
                extra = "--thinking "
                if self._reasoning_effort:
                    extra += f"--variant={shlex.quote(self._reasoning_effort)} "
                # Patch opencode.json to enable per-provider thinking config so
                # OpenRouter/Anthropic actually consumes a thinking budget
                # (without this, --variant maps to nothing for OR providers
                # and the model runs with thinking disabled — `tokens.reasoning`
                # in step_finish events is reported as 0 despite --thinking).
                patch_cfg = self._opencode_thinking_patch_command()
                c.command = c.command.replace(
                    "run --format=json", f"run {extra}--format=json", 1,
                )
                if patch_cfg:
                    c.command = f"{patch_cfg} && {c.command}"
            if oauth_on:
                if c.env is None:
                    c.env = {}
                c.env["OPENAI_BASE_URL"] = "http://127.0.0.1:4220/v1"
                c.env["OPENAI_API_KEY"] = "placeholder"
        return commands

    def _opencode_thinking_patch_command(self) -> str | None:
        """Build a shell command that adds per-provider thinking config to
        ~/.config/opencode/opencode.json.

        Two things written into every provider entry's `options`:

        1. `reasoning.effort` — OpenRouter's effort knob. OR forwards it to
           the underlying provider (OpenAI: `reasoning_effort` natively;
           Anthropic 4.6: should map to adaptive `thinking + output_config`,
           per Anthropic's adaptive-thinking docs).

        2. `thinking: {type: "adaptive"}` — belt-and-suspenders for Anthropic
           Claude 4.6 family. Per the docs, `type:"enabled"` with
           `budget_tokens:N` is **deprecated** on 4.6 and **rejected** on 4.7+,
           and **manual mode has no interleaved thinking on Opus 4.6**.
           Setting `thinking.type=adaptive` here explicitly ensures the
           Anthropic provider gets the adaptive request even if OR's
           effort→thinking translation defaults to legacy budget_tokens
           (OR's behaviour for this is undocumented as of this writing).

        Harbor's opencode config writer only registers the model name and
        leaves provider options empty, so without this patch:
          - `--variant=<effort>` is silently ignored on the OR path
          - Opus runs with thinking off (`tokens.reasoning: 0`)
          - Even when thinking *is* on, lack of interleaved means inter-tool
            reasoning is impossible on agentic workflows (the very thing we
            run in this benchmark).

        The same config write also removes a benchmark-only footgun: OpenCode
        defaults `external_directory` to "ask", but our non-interactive runner
        has no approval UI, so legitimate reads of `/workspace/venv`, `/tmp`,
        `/proc`, etc. are auto-rejected.
        """
        # `high` is Anthropic adaptive-thinking's documented default (per
        # https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking).
        # For agentic coding, the docs recommend high: "Claude always thinks.
        # Provides deep reasoning on complex tasks." Medium "may skip thinking
        # for very simple queries", which on a 13-turn agentic trial means the
        # model skips reasoning on most tool-result observations.
        effort = self._reasoning_effort or "high"
        # Switched from reasoning.effort to reasoning.max_tokens after empirical
        # OR test: effort='high' yields ~50 reasoning tokens on Opus 4.6 + tool_use,
        # but reasoning.max_tokens=8000 yields 117+ tokens. OR translates max_tokens
        # to Anthropic's explicit thinking budget; effort is translated more
        # conservatively when tool_use is present.
        _budget_map = {"low": 2000, "medium": 5000, "high": 8000}
        max_tokens = _budget_map.get(effort, 8000)
        # python3 instead of jq — guaranteed present in the base images.
        # Heredoc avoids shell-quoting hell around the embedded JSON literal.
        script = (
            "import json, pathlib, os\n"
            "p = pathlib.Path.home()/'.config/opencode/opencode.json'\n"
            "cfg = json.loads(p.read_text()) if p.exists() else {}\n"
            "prov = cfg.setdefault('provider', {})\n"
            "for name in list(prov):\n"
            "    opts = prov[name].setdefault('options', {})\n"
            f"    opts['reasoning'] = {{'max_tokens': {max_tokens}}}\n"
            "perm = cfg.get('permission')\n"
            "if perm != 'allow':\n"
            "    if not isinstance(perm, dict):\n"
            "        perm = {'*': perm} if isinstance(perm, str) else {}\n"
            "    ext = perm.get('external_directory')\n"
            "    if ext != 'allow':\n"
            "        if not isinstance(ext, dict):\n"
            "            ext = {'*': ext} if isinstance(ext, str) else {}\n"
            "        for pattern in [\n"
            "            '/workspace/**', '/tmp/**', '/var/tmp/**',\n"
            "            '/opt/**', '/root/**', '/home/**',\n"
            "            '/proc/**', '/usr/**', '/logs/**',\n"
            "        ]:\n"
            "            ext.setdefault(pattern, 'allow')\n"
            "        perm['external_directory'] = ext\n"
            "    cfg['permission'] = perm\n"
            "p.parent.mkdir(parents=True, exist_ok=True)\n"
            "p.write_text(json.dumps(cfg, indent=2))\n"
        )
        # Subshell wrap is load-bearing: the caller chains this with
        # `... && opencode run ...`. A bare heredoc can't be chained — bash
        # requires the closer (PYEOF) alone on its line, but `&&` can't start
        # a line. Wrapping in `(...)` puts `)` on its own line to close the
        # heredoc and lets `) && opencode` sit on one valid line.
        return f"(python3 - <<'PYEOF'\n{script}PYEOF\n)"

    # ── resume command builder ────────────────────────────────────────

    def _build_resume_command(self, session_id: str, user_message: str) -> ExecInput:
        """Build `opencode run --session=<id>` to continue with a user message.

        We append (`tee -a`) to the same opencode.txt the inner agent uses
        for turn 0, so the final file holds the multi-turn event stream.
        """
        escaped_message = shlex.quote(user_message)
        # Reuse the env (provider keys + OPENCODE_FAKE_VCS) the inner sets up
        # on turn 0. Harbor's create_run_agent_commands stores it on the
        # final ExecInput; we already cached that during turn-0 exec.
        env = getattr(self, "_inner_run_env", {}) or {}

        # `--thinking` flag matches the turn-0 injection (see
        # _inject_opencode_flags): force reasoning events into the JSON
        # stream so we can quantify thinking strength offline.
        # `--variant` is the provider-agnostic reasoning effort toggle.
        flags = "--thinking "
        if self._reasoning_effort:
            flags += f"--variant={shlex.quote(self._reasoning_effort)} "

        return ExecInput(
            command=(
                ". ~/.nvm/nvm.sh; "
                f"opencode --model={self._inner.model_name} run "
                f"--session={shlex.quote(session_id)} {flags}"
                f"--format=json -- {escaped_message} "
                f"2>&1 </dev/null | stdbuf -oL tee -a {_OPENCODE_LOG}"
            ),
            env=env,
        )

    # ── trajectory snapshot for user sim ──────────────────────────────

    def _snapshot_recent_output(self) -> str:
        """Raw-stdout fallback (last `_ctx_budget` chars of cumulative log)."""
        if not self._cumulative_output:
            return "(nothing yet)"
        full = "\n".join(self._cumulative_output)
        if len(full) <= self._ctx_budget:
            return full
        return full[-self._ctx_budget:]

    def _snapshot_latest_turn(self) -> tuple[str, str]:
        """Parse the LATEST turn's opencode JSON event stream → structured
        (trajectory, observation).

        Each turn writes its own block to opencode.txt; we walk the latest
        per-turn capture (stored in `command-{turn}-0/stdout.txt` already)
        but for simplicity we reuse the most-recent `_cumulative_output`
        entry, which equals the latest turn's stdout block by construction.

        Format mirrors claude_code / mini-swe-agent snapshots:
            [step] thinking: …
            [step] tool_call(name, args): …
            [step] result: …
        """
        if not self._cumulative_output:
            tail = self._snapshot_recent_output()
            return tail, tail

        # Latest turn's events are the last entry appended to cumulative_output
        latest_raw = self._cumulative_output[-1]
        steps: list[str] = []
        observation_lines: list[str] = []
        step_id = 0
        current_turn_open = False

        for line in latest_raw.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            etype = event.get("type")
            part = event.get("part") or {}

            if etype == "step_start":
                step_id += 1
                current_turn_open = True
                continue
            if etype == "step_finish":
                current_turn_open = False
                fin = part.get("cost") or part.get("tokens")
                if fin:
                    steps.append(f"[{step_id}] step_finish: {json.dumps(fin)[:150]}")
                continue
            if etype == "text" and current_turn_open:
                text = _normalize_content(part.get("text") or part)
                if not text.strip():
                    continue
                snippet = text.strip()
                if len(snippet) > 300:
                    snippet = snippet[:300] + "…"
                steps.append(f"[{step_id}] thinking: {snippet}")
                observation_lines.append(f"[{step_id}] agent: {text.strip()[:500]}")
                continue
            if etype == "tool_use" and current_turn_open:
                name = part.get("tool") or part.get("name") or "?"
                args = part.get("input") or part.get("arguments") or {}
                if not isinstance(args, str):
                    args = json.dumps(args)
                if len(args) > 200:
                    args = args[:200] + "…"
                steps.append(f"[{step_id}] tool_call({name}): {args}")
                result = part.get("output") or part.get("result") or ""
                if isinstance(result, dict):
                    result = json.dumps(result)
                if result:
                    result = str(result)
                    if len(result) > 500:
                        result = "…[truncated]…\n" + result[-500:]
                    steps.append(f"[{step_id}] result: {result}")
                    observation_lines.append(f"[{step_id}] result: {str(result)[:500]}")
                continue
            # error / other event types — quietly skipped, mirrors mini-swe-agent

        if not steps:
            tail = self._snapshot_recent_output()
            return tail, tail

        trajectory = "\n".join(steps)
        if len(trajectory) > self._ctx_budget * 2:
            trajectory = "…[earlier steps elided]…\n" + trajectory[-self._ctx_budget * 2:]

        observation = ("\n".join(observation_lines[-5:])
                       if observation_lines
                       else trajectory[-self._ctx_budget:])
        return trajectory, observation

    def _archive_turn_stdout(self, turn: int, stdout: str) -> None:
        """Persist the per-turn opencode event stream so prior turns' steps
        survive even if /logs/agent/opencode.txt is later truncated.
        Mirrors the trajectory-archive guarantee in
        user_enabled_mini_swe_agent.
        """
        if not stdout:
            return
        try:
            (self.logs_dir / f"opencode.txt.turn-{turn}").write_text(stdout)
        except Exception as e:
            log.debug("opencode turn-%d archive failed: %s", turn, e)

    async def _recover_opencode_log_after_cap(self, environment, turn: int) -> bool:
        """Recover OpenCode's live JSON stream after exec_with_budget kills a turn."""
        try:
            oc_read = await environment.exec(
                command=f"cat {_OPENCODE_LOG}",
                timeout_sec=10,
            )
            stdout = getattr(oc_read, "stdout", "")
            if stdout:
                self._cumulative_output.append(stdout)
                self._archive_turn_stdout(turn, stdout)
                log.info(
                    "Recovered %d bytes of opencode.txt from sandbox post-cap",
                    len(stdout),
                )
                return True
        except Exception as e:
            log.warning("Failed to recover opencode.txt post-cap: %s", e)
        return False

    # ── user simulation ───────────────────────────────────────────────

    async def _consult_user(
        self, trajectory: str, observation: str, turn: int, completing: bool,
        logging_dir: Path | None = None,
    ) -> UserDecision:
        now = time.monotonic()
        elapsed_sec = now - self._start_time if self._start_time else 0
        turn_duration_sec = now - self._turn_start_time if self._turn_start_time else 0

        decision = await self._sim_user.process(
            task_description=self._task_instruction,
            recent_trajectory=trajectory,
            latest_observation=observation[:self._ctx_budget],
            latest_analysis=None,
            step_count=turn,
            is_completion_attempt=completing,
            total_steps_so_far=turn,
            elapsed_sec=elapsed_sec,
            turn_duration_sec=turn_duration_sec,
            code_changes_diff=self._last_turn_diff,
        )
        if decision.has_message:
            self._sim_user.advance_original_index(1)
            log.info("User sim intervenes at turn %d: %s", turn, decision.action)
        else:
            log.debug("User sim waits at turn %d", turn)

        self._log_user_decision(logging_dir, turn, decision, completing)
        return decision

    def _log_user_decision(
        self, logging_dir: Path | None, turn: int,
        decision: UserDecision, completing: bool,
    ):
        if logging_dir is None:
            return
        episode_dir = logging_dir / f"episode-{turn}"
        episode_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "turn": turn,
            "is_completion_attempt": completing,
            "action": decision.action,
            "has_message": decision.has_message,
            "content": decision.content,
            "raw_response": decision.raw_response[:500] if decision.raw_response else "",
            "cursor": self._sim_user._cursor,
            "ground_truth_remaining": len(self._sim_user._ground_truth) - self._sim_user._cursor,
            "stats": self._sim_user.get_stats(),
        }
        path = episode_dir / "user_decision.json"
        path.write_text(json.dumps(record, indent=2, ensure_ascii=False))

    # ── per-turn diff capture ─────────────────────────────────────────

    async def _capture_git_diff(self, environment, turn: int) -> None:
        """Per-turn incremental + cumulative diff capture.

        Shared with mini-swe-agent + codex + gemini wrappers via repo_diff.
        Stashes the incremental result on `self._last_turn_diff` so the
        next `_consult_user` call passes it to `UserAgent.process(
        code_changes_diff=…)`.
        """
        self._last_turn_diff = await capture_git_diff(
            environment, logs_dir=self.logs_dir, turn=turn
        )

    # ── main run ──────────────────────────────────────────────────────

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        # Inject repo config files (CLAUDE.md, AGENTS.md, …) into the task.
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        # Incremental-work instruction (mirrors claude_code v0.5.2): force the
        # agent to STOP after each sub-task instead of completing the whole
        # task in one autonomous run. This creates more --session resume
        # checkpoints so the user simulator has actual intervention points
        # rather than seeing one finished result and choosing no-op.
        #
        # We add this for native-resume harnesses (claude_code, opencode)
        # but NOT for history-replay ones (codex, gemini_cli,
        # mini-swe-agent) — per a prior validation: on history-replay
        # paths the per-turn cost compounds because each turn re-sends the
        # full history, so the extra checkpoints are net-negative.
        _INCREMENTAL_NOTICE = (
            "\n\nIMPORTANT: Work incrementally. After completing each distinct "
            "sub-task (e.g., implementing one feature, fixing one bug, making one "
            "significant change), STOP and report what you did and what you plan "
            "to do next. Wait for user feedback before proceeding to the next "
            "sub-task. Do NOT implement everything in one go."
        )
        instruction = instruction + _INCREMENTAL_NOTICE

        self._task_instruction = instruction
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: initial run via inner agent's commands.
        commands = self._inner.create_run_agent_commands(instruction)
        commands = self._inject_opencode_flags(commands)
        # Remember the env from the last command (the actual `opencode run`)
        # so resume invocations get the same provider keys + OPENCODE_FAKE_VCS.
        if commands:
            self._inner_run_env = commands[-1].env or {}

        turn0_timed_out = False
        try:
            for i, exec_input in enumerate(commands):
                result, timed_out = await exec_with_budget(
                    environment, exec_input, start_time=self._start_time,
                )
                if result.stdout:
                    self._cumulative_output.append(result.stdout)

                command_dir = self.logs_dir / f"command-0-{i}"
                command_dir.mkdir(parents=True, exist_ok=True)
                (command_dir / "command.txt").write_text(exec_input.command)
                (command_dir / "return-code.txt").write_text(str(result.return_code))
                if result.stdout:
                    (command_dir / "stdout.txt").write_text(result.stdout)
                if result.stderr:
                    (command_dir / "stderr.txt").write_text(result.stderr)
                if timed_out:
                    turn0_timed_out = True
                    break
        finally:
            await self._capture_git_diff(environment, turn=0)
            # Archive turn-0 events under a stable name (the run command is
            # the LAST in `commands`; its stdout is the freshest entry).
            if self._cumulative_output:
                self._archive_turn_stdout(0, self._cumulative_output[-1])

        if turn0_timed_out:
            log.warning("turn-0 hit per-exec timeout — attempting cap-rescue")
            # exec_helpers._TimeoutResult drops captured stdout on cap, so the
            # sessionID emitted early in opencode's JSON stream never made it
            # into self._cumulative_output. Recover it by reading the
            # in-sandbox opencode.txt directly (the `tee -a` chain has been
            # writing events to it in real time, so the file contains
            # everything emitted before cap killed the parent process).
            # Without this, _find_session_id() returns None, the function
            # short-circuits, and the cap_rescue_pending loop below is never
            # entered (49 cap events → 0 rescues in the new29 capRescue
            # pilot until this fix).
            await self._recover_opencode_log_after_cap(environment, turn=0)

        # Find session ID from turn-0 output. Required for resume.
        session_id = self._find_session_id()
        if not session_id:
            log.warning("Could not find OpenCode sessionID — skipping user sim turns")
            try:
                self._inner.populate_context_post_run(context)
            except Exception as e:
                log.warning("Failed to populate context post-run: %s", e)
            return
        log.info("OpenCode session ID: %s", session_id)

        # Multi-turn loop via `opencode run --session=<sid> -- <msg>`.
        # If turn-0 hit the per-exec cap, do NOT abandon — sessionID is in
        # opencode.txt and agent state is persisted in opencode's sqlite session
        # store. We can pick up where it left off via --session=<id>. Inject a
        # synthetic "please continue" as the first user message (bypassing the
        # user-sim consult on turn 1 since there's no completed agent turn to
        # judge yet). This rescues the entire turn-0 work that would otherwise
        # be lost when slow models (e.g., Opus on cli-task-2f5833) overshoot
        # the 1800s cap.
        consecutive_noops = 0
        cap_rescue_pending = turn0_timed_out
        for turn in range(1, _MAX_RESUME_TURNS + 1):
            elapsed = time.monotonic() - self._start_time
            if elapsed > TRIAL_BUDGET_SEC:
                log.warning(
                    "Trial budget exceeded (%.0fs > %ds) — stopping at turn %d",
                    elapsed, TRIAL_BUDGET_SEC, turn,
                )
                break
            if cap_rescue_pending:
                # Bypass user-sim consult once: turn-0 was killed by per-exec
                # cap, but sessionID survived. Resume the agent with a
                # synthetic "please continue" message — equivalent to user
                # noticing the interrupt and prompting agent to resume.
                log.info(
                    "Cap-rescue at turn %d: turn-0 was cut by per-exec cap, "
                    "resuming via session_id=%s with synthetic 'continue'",
                    turn, session_id,
                )
                user_msg = "Your previous run was interrupted. Please continue with the task from where you left off."
                cap_rescue_pending = False
            else:
                trajectory, observation = self._snapshot_latest_turn()
                decision = await self._consult_user(
                    trajectory, observation, turn, completing=True, logging_dir=self.logs_dir,
                )
                if not decision.has_message:
                    consecutive_noops += 1
                    if consecutive_noops >= _MAX_CONSECUTIVE_NOOPS:
                        log.info("User sim silent %d consecutive times at turn %d — ending",
                                 consecutive_noops, turn)
                        break
                    log.info("User sim no-op at turn %d (streak %d/%d) — resuming agent",
                             turn, consecutive_noops, _MAX_CONSECUTIVE_NOOPS)
                    user_msg = "continue"
                else:
                    consecutive_noops = 0
                    user_msg = decision.format_for_injection()

            self._turn_start_time = time.monotonic()
            log.info("Resuming OpenCode session with user message (turn %d)", turn)
            resume_cmd = self._build_resume_command(session_id, user_msg)

            turn_timed_out = False
            try:
                result, timed_out = await exec_with_budget(
                    environment, resume_cmd, start_time=self._start_time,
                )
                if result.stdout:
                    self._cumulative_output.append(result.stdout)

                command_dir = self.logs_dir / f"command-{turn}-0"
                command_dir.mkdir(parents=True, exist_ok=True)
                (command_dir / "command.txt").write_text(resume_cmd.command)
                (command_dir / "return-code.txt").write_text(str(result.return_code))
                if result.stdout:
                    (command_dir / "stdout.txt").write_text(result.stdout)
                if result.stderr:
                    (command_dir / "stderr.txt").write_text(result.stderr)
                if timed_out:
                    turn_timed_out = True
            finally:
                await self._capture_git_diff(environment, turn=turn)
                if self._cumulative_output:
                    self._archive_turn_stdout(turn, self._cumulative_output[-1])

            if turn_timed_out:
                log.warning(
                    "turn %d hit per-exec timeout — attempting session resume on next turn",
                    turn,
                )
                await self._recover_opencode_log_after_cap(environment, turn=turn)
                cap_rescue_pending = True
                continue

        # Final safety net — re-snapshot at run-end so final.patch reflects
        # the very last workspace state regardless of per-turn-capture state.
        try:
            await self._capture_git_diff(environment, turn=999)
        except Exception as e:
            log.debug("end-of-run patch capture failed: %s", e)

        # Pull OAuth proxy log back from sandbox for offline debug
        await self._flush_proxy_log()

        # Post-run: populate trajectory via inner agent (parses opencode.txt
        # into ATIF; this is why we used `tee -a` rather than per-turn-only
        # files — Harbor's parser walks the full event stream in one pass).
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
