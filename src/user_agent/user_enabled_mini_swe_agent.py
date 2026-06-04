"""Mini-SWE-Agent wrapper with simulated user injection via sequential runs.

Mini-SWE-Agent (princeton-nlp/mini-swe-agent) is a minimal, LiteLLM-based
SWE-Bench harness — no provider-specific tool stack, no built-in resume, no
custom system prompt: just `bash` + `edit`-style tool calls dispatched by a
LiteLLM-routed model. That makes it the cleanest "neutral" harness for our
cross-model benchmark: every cohort sees the same tools and the same prompt
scaffolding, with the only variable being the model itself.

Multi-turn pattern (no native --resume):

  Turn 0: mini-swe-agent --model=… --task="<instruction>"
  Turn 1: re-issue with combined ORIGINAL TASK + CURRENT WORKSPACE STATE
          (cumulative diff) + RECENT TOOL CALLS + PRIOR USER MESSAGES + new msg
  Turn N: same pattern, capped by _MAX_RESUME_TURNS

The followup-prompt structure (diff + tool-call log + user msgs) is the same
fallback path our codex wrapper uses when `codex exec resume` isn't available
— here it's the only path.
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
from harbor.agents.installed.mini_swe_agent import MiniSweAgent
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
_MAX_CONSECUTIVE_NOOPS = 4  # allow agent to continue N times without user input before stopping


def _normalize_content(raw_content: Any) -> str:
    """Normalize an LLM message content field (string, list of parts, None).

    Mini-swe-agent's trajectory uses OpenAI-flavored messages where `content`
    can be a string, a list of {type, text|tool_use|...} parts, or None when
    only `tool_calls` is set on the assistant message.
    """
    if raw_content is None:
        return ""
    if isinstance(raw_content, str):
        return raw_content
    if isinstance(raw_content, list):
        parts = []
        for part in raw_content:
            if isinstance(part, dict):
                parts.append(part.get("text", str(part)))
            else:
                parts.append(str(part))
        return "\n".join(parts)
    return str(raw_content)

# Followup-prompt budget knobs. mini-swe-agent has no server-side state so we
# manually reconstruct context every turn — caps balance "enough state to
# avoid re-exploring" against "small enough to fit + not blow PER_EXEC_CAP".
_TOOL_OUTPUT_CHAR_CAP = 500     # per single tool call
_TOOL_HISTORY_TURN_CAP = 4000   # per turn (sum of tool-call entries)
_TOOL_HISTORY_TURNS_KEPT = 3    # only inject last N turns of tool log
_CUM_DIFF_CHAR_CAP = 20000      # cumulative-diff section in followup


class UserEnabledMiniSweAgent(BaseAgent):
    """Mini-SWE-Agent + simulated user via sequential `mini-swe-agent` invocations.

    Functionally mirrors `user_enabled_codex` (history-replay path) — per-turn
    git diff capture, wall-clock timing, no-op streak allowance — except the
    inner harness is mini-swe-agent (LiteLLM-backed, no resume).
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
        # `high` is the Anthropic adaptive-thinking documented default and the
        # recommended setting for agentic coding (see
        # https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking).
        # Other providers (OpenAI gpt-5.5, DeepSeek-Reasoner, etc.) accept the
        # same level keyword. None used to mean "skip the flag, take provider
        # default" — but provider defaults vary and silently degrade quality
        # on tool-use heavy workloads (the agent benchmark). Default to `high`
        # so missed launcher flags don't silently disable thinking.
        reasoning_effort: str | None = "high",
        mswea_version: str = "2.3.0",
        **kwargs,
    ):
        # `minimaxd/`, `glmd/`, `ark/`, etc. are our naming convention for
        # provider-direct routing via the in-sandbox proxy on localhost:4210.
        # Harbor's MiniSweAgent calls `get_api_key_var_names_from_model_name`
        # against a hardcoded provider list that rejects these prefixes
        # ("ValueError: Unknown model"). Mask to a Harbor-recognized
        # placeholder ("anthropic/claude-sonnet-4-6"); LiteLLM sees that name
        # + the ANTHROPIC_BASE_URL we set in build_agent_env, hits the proxy
        # at localhost:4210, which rewrites the body's model field to the real
        # target before forwarding to api.minimax.io / api.z.ai / etc.
        inner_model_name = mask_proxied_model_name(model_name)
        self._using_proxied_provider = inner_model_name != model_name
        if self._using_proxied_provider:
            log.info(
                "mini-swe-agent: masking model %r → %r for Harbor validator (proxy handles real routing)",
                model_name, inner_model_name,
            )
        super().__init__(logs_dir=logs_dir, model_name=inner_model_name, **kwargs)

        # Pin the in-sandbox mini-swe-agent CLI version for reproducibility.
        # Harbor's install template reads `{{ version }}` from this kwarg via
        # `_template_variables`, so passing version= here ensures every trial
        # installs the exact same pip release. 2.3.0 is the current pinned
        # version (v2 series — verified to support multi-turn user-sim flow).
        # Drops any incoming cc-style `version` (e.g. "2.1.108") that
        # run_eval might forward.
        kwargs.pop("version", None)
        # reasoning_effort defaults to None → upstream MiniSweAgent skips the
        # `-c model.model_kwargs.extra_body.reasoning_effort=...` flag, so the
        # model runs at its provider's native default reasoning level. Callers
        # pin "low"/"medium"/"high" explicitly when they want a sweep.
        kwargs.pop("reasoning_effort", None)
        self._inner = MiniSweAgent(
            logs_dir=logs_dir, model_name=inner_model_name,
            version=mswea_version,
            reasoning_effort=reasoning_effort, **kwargs,
        )

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
        self._conversation_history: list[dict[str, str]] = []
        # Wall-clock tracking for turn summaries
        self._start_time: float = 0.0
        self._turn_start_time: float = 0.0
        # Per-turn incremental git diff captured at end of the prior turn;
        # fed to user sim so it has an independent view of what the agent
        # actually wrote (vs the agent's self-narration).
        self._last_turn_diff: str = ""
        # Cumulative diff (vs harbor-base) read from logs_dir/final.patch after
        # each _capture_git_diff. Injected into followup prompts so the agent
        # knows what files it already changed and doesn't re-explore.
        self._last_cumulative_diff: str = ""
        # Compact per-turn tool-call log extracted from mini-swe-agent
        # trajectory JSON. Without this, follow-up turns have no record of
        # the prior turn's tool calls.
        self._tool_history: list[str] = []

    @staticmethod
    def name() -> str:
        return "user-enabled-mini-swe-agent"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)
        # Tag every git repo as `harbor-base` so per-turn `git diff` can
        # show only the agent's edits, even if a Dockerfile post-checkout
        # `git commit` mid-trial. See repo_diff for rationale.
        await tag_harbor_base(environment)
        # Launch the in-sandbox LiteLLM-compat proxy on localhost:4210 when
        # we're routing through a provider-direct path (minimaxd/, glmd/,
        # ark/, fireworks/, deepseek/, openrouter/). build_agent_env in
        # src/run_eval.py already set LITELLM_PROXY_MODEL + PROXY_TARGET_URL
        # + ANTHROPIC_BASE_URL=http://localhost:4210 in the agent env; the
        # helper picks those up and starts the proxy. No-op when the env vars
        # aren't set (direct Anthropic or codex-oauth runs).
        await launch_litellm_proxy(environment, self.logs_dir)
        # If MSWEA_USE_CODEX_OAUTH=1, drop our oauth_proxy.py + host's
        # ~/.codex/auth.json into the sandbox and start the proxy on
        # 127.0.0.1:4220. LiteLLM clients in the sandbox then route through
        # it via OPENAI_BASE_URL injected in _build_run_commands().
        if os.environ.get("MSWEA_USE_CODEX_OAUTH") == "1":
            await self._launch_codex_oauth_proxy(environment)

    async def _launch_codex_oauth_proxy(self, environment: BaseEnvironment) -> None:
        """Upload oauth_proxy.py + auth.json into the sandbox, start daemon."""
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
        # Stage in logs_dir so upload_file can see it, then upload + start.
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
        # mini-swe-agent install brings in aiohttp + httpx as litellm/openai
        # deps, BUT they land in uv's isolated tool venv
        # (~/.local/share/uv/tools/mini-swe-agent/lib/python3.12/site-packages/)
        # which system `python3` cannot see. Bare ubuntu:24.04 images (moltis,
        # cli-task-c425e4, rudel, cli-task-4a9dde, amytis) have no aiohttp in
        # system site-packages → `python3 /tmp/oauth_proxy.py` dies immediately
        # with ModuleNotFoundError, leaving port 4220 closed and every LiteLLM
        # call returning "OpenAIException - Connection error". ComfyUI/hyperswitch
        # bases ship aiohttp in system Python (used by their web servers) so
        # those tasks happened to work. Fix: run oauth_proxy via mini-swe-agent's
        # bundled venv Python which is guaranteed to have aiohttp.
        start_cmd = (
            'export PATH="$HOME/.local/bin:$PATH"; '
            'PROXY_PY="$HOME/.local/share/uv/tools/mini-swe-agent/bin/python"; '
            '[ -x "$PROXY_PY" ] || PROXY_PY=python3; '
            'nohup "$PROXY_PY" /tmp/oauth_proxy.py '
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
        result = await environment.exec(command=start_cmd, timeout_sec=60)
        if result.return_code != 0:
            log.warning("oauth_proxy start failed: rc=%s\n%s",
                        result.return_code, (result.stderr or result.stdout)[-2000:])
        else:
            log.info("oauth_proxy launched in sandbox on 127.0.0.1:4220")
        # Stash a reference so cleanup_proxy_log can pull /tmp/oauth_proxy.log
        # back to logs_dir at end-of-run for offline debugging.
        self._oauth_proxy_env = environment

    async def _flush_proxy_log(self) -> None:
        """Pull /tmp/oauth_proxy.log back from sandbox for offline debug.

        Called from `run()` on its way out so even on error we can see what
        the proxy saw upstream (4xx body, refused tool calls, etc.).
        """
        env = getattr(self, "_oauth_proxy_env", None)
        if env is None:
            return
        try:
            result = await env.exec(
                command="cat /tmp/oauth_proxy.log 2>/dev/null | tail -200",
                timeout_sec=15,
            )
            log_dump = self.logs_dir / "oauth_proxy.log"
            log_dump.write_text(result.stdout or "(empty)")
            log.info("oauth_proxy.log saved to %s (%d bytes)",
                     log_dump, len(result.stdout or ""))
        except Exception as e:
            log.debug("failed to pull proxy log: %s", e)

    # ── tool-call extraction (from mini-swe-agent trajectory JSON) ────

    def _build_run_commands(self, instruction: str) -> list[ExecInput]:
        """Wrap upstream's `create_run_agent_commands` to inject env vars
        the wrapper requires across every turn.

        Currently sets:
        - `MSWEA_COST_TRACKING=ignore_errors`: mini-swe-agent v2 calls
          LiteLLM's `_calculate_cost` after every model response, which
          raises RuntimeError when the model isn't in LiteLLM's price
          table (e.g. `openrouter/openai/gpt-5.5` as of 2026-05). Without
          this, even a fully-successful exec dies with `RuntimeError:
          This model isn't mapped yet`. Cost reporting is nice-to-have;
          benchmark correctness comes first.
        """
        cmds = self._inner.create_run_agent_commands(instruction)
        oauth_on = os.environ.get("MSWEA_USE_CODEX_OAUTH") == "1"
        for c in cmds:
            if c.env is None:
                c.env = {}
            c.env.setdefault("MSWEA_COST_TRACKING", "ignore_errors")
            if oauth_on:
                # Route LiteLLM through the in-sandbox proxy → ChatGPT OAuth
                c.env["OPENAI_BASE_URL"] = "http://127.0.0.1:4220/v1"
                c.env["OPENAI_API_KEY"] = "placeholder"
            if self._using_proxied_provider:
                # Route LiteLLM's anthropic provider to the in-sandbox proxy
                # on localhost:4210 (launched in setup() when
                # LITELLM_PROXY_MODEL is set). The masked model name
                # ("anthropic/claude-sonnet-4-6") makes LiteLLM pick the
                # anthropic provider, which resolves its endpoint from
                # ANTHROPIC_API_BASE (canonical, all versions) falling back
                # to ANTHROPIC_BASE_URL (≥1.82.x). We exec the inner agent's
                # commands ourselves (exec_with_budget), bypassing Harbor's
                # BaseInstalledAgent.run() extra_env merge — so without this
                # injection LiteLLM dispatches to api.anthropic.com with the
                # placeholder key and 401s every call (mm27 smoke,
                # 2026-06-03; same class as the deepseek 401s of 2026-05-29).
                # LiteLLM appends "/v1/messages" to the base itself.
                c.env["ANTHROPIC_API_BASE"] = "http://localhost:4210"
                c.env["ANTHROPIC_BASE_URL"] = "http://localhost:4210"
        return cmds

    @staticmethod
    def _extract_tool_calls_compact(trajectory_path: Path) -> str:
        """Parse mini-swe-agent trajectory JSON → compact tool-call log.

        mini-swe-agent writes a v2 trajectory with a `messages` array of
        {role, content, tool_calls?}. We extract tool calls + their results
        from the assistant + tool messages, cap per-call output, total cap.
        """
        if not trajectory_path.exists():
            return "(no trajectory recorded)"
        try:
            data = json.loads(trajectory_path.read_text())
        except (json.JSONDecodeError, ValueError):
            return "(trajectory parse failed)"
        messages = data.get("messages") or []
        out_lines: list[str] = []
        total = 0
        i = 0
        while i < len(messages):
            msg = messages[i]
            role = msg.get("role")
            if role == "assistant":
                for tc in msg.get("tool_calls") or []:
                    fn = (tc.get("function") or {})
                    name = fn.get("name", "?")
                    args = fn.get("arguments", "")
                    if len(args) > 200:
                        args = args[:200] + "..."
                    # Find the matching tool result in the next message(s)
                    result = ""
                    if i + 1 < len(messages) and messages[i + 1].get("role") == "tool":
                        result = str(messages[i + 1].get("content") or "")
                        if len(result) > _TOOL_OUTPUT_CHAR_CAP:
                            result = "...[truncated]...\n" + result[-_TOOL_OUTPUT_CHAR_CAP:]
                    entry = f"$ {name}({args})\n{result}"
                    if total + len(entry) > _TOOL_HISTORY_TURN_CAP:
                        out_lines.append("... [more tool calls elided] ...")
                        i = len(messages)
                        break
                    out_lines.append(entry)
                    total += len(entry) + 1
            i += 1
        return "\n".join(out_lines).strip() or "(no tool calls recorded)"

    # ── followup-prompt builder (history-replay path) ─────────────────

    def _build_followup_instruction(self, user_message: str) -> str:
        """Build a followup prompt with workspace state + tool history.

        mini-swe-agent has no `--resume`, so each follow-up `mini-swe-agent`
        run starts cold. We give the model three structured signals:
          1. CURRENT WORKSPACE STATE — cumulative git diff (truncated)
          2. RECENT TOOL CALLS — last N turns' tool log (compact)
          3. PRIOR USER MESSAGES — list form
        followed by the new user message.
        """
        parts = [f"ORIGINAL TASK:\n{self._task_instruction}"]

        cum = self._last_cumulative_diff.strip()
        if cum:
            if len(cum) > _CUM_DIFF_CHAR_CAP:
                cum = (cum[:_CUM_DIFF_CHAR_CAP]
                       + f"\n... [cumulative diff truncated at {_CUM_DIFF_CHAR_CAP} chars] ...")
            parts.append(
                "\nCURRENT WORKSPACE STATE (cumulative diff vs original — "
                "these changes are already on disk):\n" + cum
            )
        else:
            parts.append("\nCURRENT WORKSPACE STATE: (no changes on disk yet)")

        if self._tool_history:
            kept = self._tool_history[-_TOOL_HISTORY_TURNS_KEPT:]
            base = max(0, len(self._tool_history) - _TOOL_HISTORY_TURNS_KEPT)
            sections = [f"--- Turn {base + i} ---\n{t}" for i, t in enumerate(kept)]
            parts.append("\nRECENT TOOL CALLS (commands you already ran):\n"
                         + "\n\n".join(sections))

        prior_user_msgs = [e["content"] for e in self._conversation_history
                           if e["role"] == "user"]
        if prior_user_msgs:
            msgs_str = "\n".join(f"  {i+1}. {m}" for i, m in enumerate(prior_user_msgs))
            parts.append(f"\nPRIOR USER MESSAGES (in order):\n{msgs_str}")

        parts.append(f"\nLATEST USER MESSAGE:\n{user_message}")
        parts.append(
            "\nContinue working on the task. The workspace already contains the "
            "changes shown in the diff above — only re-read files you need to "
            "modify further. Do NOT re-explore the codebase from scratch; trust "
            "the diff and tool-call log above."
        )
        return "\n".join(parts)

    # ── trajectory snapshot for user sim ─────────────────────────────

    def _snapshot_recent_output(self) -> str:
        """Raw-stdout fallback for callers that don't need structure
        (e.g. the codex-style followup prompt builder, which already does
        its own structured parsing)."""
        if not self._cumulative_output:
            return "(nothing yet)"
        full = "\n".join(self._cumulative_output)
        if len(full) <= self._ctx_budget:
            return full
        return full[-self._ctx_budget:]

    def _snapshot_latest_turn(self) -> tuple[str, str]:
        """Return (trajectory, observation) for the LATEST turn's mini-swe-agent
        run, parsed from its trajectory JSON.

        - trajectory: structured step summary
              `[step] thinking: ...`
              `[step] tool_call(name, args): ...`
              `[step] result: ...`
        - observation: the last few `result` / `agent` lines (what the agent
          actually produced), so user_sim sees outcomes not every shell call.

        Prior turns are already in the user-sim's conversation history; only
        the latest turn's trajectory.json is parsed (mini-swe-agent rewrites
        its --output file on every run, so each trajectory.json IS the
        latest turn). Ports v0.5 #2 to mini-swe-agent.
        """
        traj_path = self._find_trajectory_path()
        if not traj_path or not traj_path.exists():
            # Fallback: raw stdout tail
            tail = self._snapshot_recent_output()
            return tail, tail

        try:
            data = json.loads(traj_path.read_text())
        except (json.JSONDecodeError, ValueError):
            tail = self._snapshot_recent_output()
            return tail, tail

        messages = data.get("messages") or []
        steps: list[str] = []
        observation_lines: list[str] = []
        step_id = 0
        i = 0
        while i < len(messages):
            msg = messages[i]
            role = msg.get("role")
            if role == "assistant":
                step_id += 1
                content = _normalize_content(msg.get("content"))
                # mini-swe-agent often packs reasoning + the tool call into the
                # assistant message text; surface it as thinking.
                if content.strip():
                    snippet = content.strip()
                    if len(snippet) > 300:
                        snippet = snippet[:300] + "…"
                    steps.append(f"[{step_id}] thinking: {snippet}")
                for tc in msg.get("tool_calls") or []:
                    fn = (tc.get("function") or {})
                    name = fn.get("name", "?")
                    args = fn.get("arguments", "")
                    if len(args) > 200:
                        args = args[:200] + "…"
                    steps.append(f"[{step_id}] tool_call({name}): {args}")
                if not msg.get("tool_calls") and content.strip():
                    # No tool call — pure agent message, this IS observation material.
                    observation_lines.append(f"[{step_id}] agent: {content.strip()[:500]}")
            elif role == "tool":
                content = _normalize_content(msg.get("content"))
                if len(content) > 500:
                    content = "…[truncated]…\n" + content[-500:]
                steps.append(f"[{step_id}] result: {content}")
                observation_lines.append(f"[{step_id}] result: {content[:500]}")
            i += 1

        if not steps:
            tail = self._snapshot_recent_output()
            return tail, tail

        trajectory = "\n".join(steps)
        if len(trajectory) > self._ctx_budget * 2:
            # Keep tail — last steps matter more for "what just happened".
            trajectory = "…[earlier steps elided]…\n" + trajectory[-self._ctx_budget * 2:]

        observation = ("\n".join(observation_lines[-5:])
                       if observation_lines
                       else trajectory[-self._ctx_budget:])
        return trajectory, observation

    def _find_trajectory_path(self) -> Path | None:
        """Locate the most recent mini-swe-agent trajectory JSON.

        Harbor pulls back files from the sandbox to `logs_dir`; the exact
        filename varies across versions. Check known candidates in order.
        """
        for candidate in [
            self.logs_dir / "mini-swe-agent.trajectory.json",
            self.logs_dir / "trajectory.json",
            self.logs_dir / "mini-swe-agent" / "trajectory.json",
        ]:
            if candidate.exists():
                return candidate
        return None

    # ── user simulation ──────────────────────────────────────────────

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

    # ── per-turn diff capture ────────────────────────────────────────

    async def _capture_git_diff(self, environment, turn: int) -> None:
        """Snapshot per-turn git state; stash incremental for user-sim AND
        cumulative for next followup prompt."""
        self._last_turn_diff = await capture_git_diff(
            environment, logs_dir=self.logs_dir, turn=turn
        )
        final_patch = self.logs_dir / "final.patch"
        try:
            self._last_cumulative_diff = final_patch.read_text() if final_patch.exists() else ""
        except Exception as e:
            log.debug("failed to read cumulative diff at turn %d: %s", turn, e)
            self._last_cumulative_diff = ""

    async def _extract_and_append_tool_history(self, environment, turn: int) -> None:
        """Pull mini-swe-agent's trajectory JSON directly from the sandbox,
        archive it as `mini-swe-agent.trajectory.turn-N.json`, and append a
        compact tool-call log for the followup prompt.

        On E2B the trial dir is not bind-mounted to the host (Harbor mirrors
        the agent_dir only at run-end via `download_dir`), so the on-host
        copy of `mini-swe-agent.trajectory.json` doesn't exist yet during
        per-turn finally blocks. We therefore pull the file ourselves via
        `environment.download_file` straight into the per-turn archive path
        — that guarantees the archive captures THIS turn's content, before
        the next turn overwrites the sandbox file.
        """
        sandbox_path = str(self._inner._mini_swe_agent_trajectory_path)
        archive = self.logs_dir / f"mini-swe-agent.trajectory.turn-{turn}.json"
        try:
            await environment.download_file(sandbox_path, archive)
        except Exception as e:
            # Common in the wild: file doesn't exist yet (mini-swe-agent
            # crashed at config-load before writing trajectory). Don't fail
            # the whole turn over it — just record an empty tool log.
            log.debug("trajectory pull failed at turn=%d: %s", turn, e)
            self._tool_history.append("(trajectory not yet written by mini-swe-agent)")
            return
        if not archive.exists() or archive.stat().st_size == 0:
            self._tool_history.append("(trajectory empty)")
            return
        self._tool_history.append(self._extract_tool_calls_compact(archive))

    # ── main run ─────────────────────────────────────────────────────

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        # Inject repo config files into the instruction (CLAUDE.md, AGENTS.md, …)
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        self._task_instruction = instruction
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: initial run via inner agent's commands
        commands = self._build_run_commands(instruction)

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
            await self._extract_and_append_tool_history(environment, turn=0)

        # Record agent output in conversation history (snapshot, not raw)
        agent_output = self._snapshot_recent_output()
        self._conversation_history.append({"role": "agent", "content": agent_output})

        if turn0_timed_out:
            log.warning("turn-0 hit per-exec timeout; skipping multi-turn loop")

        # Multi-turn: sequential re-run loop
        consecutive_noops = 0
        for turn in range(1, _MAX_RESUME_TURNS + 1):
            if turn0_timed_out:
                break
            elapsed = time.monotonic() - self._start_time
            if elapsed > TRIAL_BUDGET_SEC:
                log.warning(
                    "Trial budget exceeded (%.0fs > %ds) — stopping at turn %d",
                    elapsed, TRIAL_BUDGET_SEC, turn,
                )
                break
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

            self._conversation_history.append({"role": "user", "content": user_msg})
            self._turn_start_time = time.monotonic()

            log.info("Re-running mini-swe-agent with full history (turn %d)", turn)
            followup = self._build_followup_instruction(user_msg)
            rerun_commands = self._build_run_commands(followup)

            turn_timed_out = False
            try:
                for j, exec_input in enumerate(rerun_commands):
                    result, timed_out = await exec_with_budget(
                        environment, exec_input, start_time=self._start_time,
                    )
                    if result.stdout:
                        self._cumulative_output.append(result.stdout)

                    command_dir = self.logs_dir / f"command-{turn}-{j}"
                    command_dir.mkdir(parents=True, exist_ok=True)
                    (command_dir / "command.txt").write_text(exec_input.command)
                    (command_dir / "return-code.txt").write_text(str(result.return_code))
                    if result.stdout:
                        (command_dir / "stdout.txt").write_text(result.stdout)
                    if result.stderr:
                        (command_dir / "stderr.txt").write_text(result.stderr)
                    if timed_out:
                        turn_timed_out = True
                        break
            finally:
                await self._capture_git_diff(environment, turn=turn)
                await self._extract_and_append_tool_history(environment, turn=turn)

            if turn_timed_out:
                log.warning("turn %d hit per-exec timeout — stopping multi-turn loop", turn)
                break

            # Record this turn's output (snapshot, not raw) so subsequent
            # followup prompts have a consistent agent view-of-itself.
            new_output = self._snapshot_recent_output()
            self._conversation_history.append({"role": "agent", "content": new_output})

        # Final safety net — re-snapshot at run-end so even if all per-turn
        # captures somehow fail, final.patch reflects the very last state.
        try:
            await self._capture_git_diff(environment, turn=999)
        except Exception as e:
            log.debug("end-of-run patch capture failed: %s", e)

        # Pull oauth_proxy log back if it was launched
        await self._flush_proxy_log()

        # Post-run: populate trajectory via inner agent
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
