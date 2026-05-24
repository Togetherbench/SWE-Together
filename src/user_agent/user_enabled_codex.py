"""Codex agent wrapper with simulated user injection via sequential runs.

Codex CLI has no --resume mechanism, so multi-turn works by re-running
`codex exec` with the accumulated conversation context prepended to the
instruction:

  Turn 0: codex exec "original instruction"
  Turn 1: codex exec "original instruction + agent output summary + user message"
  Turn N: codex exec "original instruction + full conversation history"

Functionally mirrors `user_enabled_claude_code` — per-turn git diff
capture, wall-clock timing, incremental-work notice, no-op streak
allowance — except the agent harness is Codex (no --resume), so each
turn re-issues a fresh `codex exec` with the full history.
"""

import json
import logging
import os
import shlex
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import ExecInput
from harbor.agents.installed.codex import Codex
from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.paths import EnvironmentPaths
from harbor.llms.lite_llm import LiteLLM

from .exec_helpers import TRIAL_BUDGET_SEC, exec_with_budget
from .repo_config import discover_repo_config_files
from .repo_diff import capture_git_diff, tag_harbor_base
from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15
_MAX_CONSECUTIVE_NOOPS = 4  # allow agent to continue N times without user input before stopping

_INCREMENTAL_NOTICE = (
    "\n\nIMPORTANT: Work incrementally. After completing each distinct "
    "sub-task (e.g., implementing one feature, fixing one bug, making one "
    "significant change), STOP and report what you did and what you plan "
    "to do next. Wait for user feedback before proceeding to the next "
    "sub-task. Do NOT implement everything in one go."
)


class UserEnabledCodex(BaseAgent):
    """Codex + simulated user via sequential codex exec invocations."""

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
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)

        self._inner = Codex(logs_dir=logs_dir, model_name=model_name, **kwargs)

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
        # Timing: wall-clock tracking for turn summaries
        self._start_time: float = 0.0
        self._turn_start_time: float = 0.0
        # Per-turn incremental git diff captured at end of the prior turn;
        # fed to user sim so it has an independent view of what the agent
        # actually wrote (vs the agent's self-narration).
        self._last_turn_diff: str = ""
        # codex thread_id captured from turn-0 stream-json output. When set,
        # we use `codex exec resume <id> "<msg>"` for follow-up turns instead
        # of building a full-history followup_instruction. With OpenAI direct
        # this leverages Responses-API server-side state for big token + wall
        # savings; on OpenRouter the savings are smaller (no true server state)
        # but the wrapper code is simpler.
        self._thread_id: str | None = None

    @staticmethod
    def name() -> str:
        return "user-enabled-codex"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)
        # Tag every git repo as `harbor-base` so per-turn `git diff` can
        # compare against the pre-agent state even after the agent runs
        # `git commit` mid-trial. See repo_diff for rationale.
        await tag_harbor_base(environment)

        # Optional codex version override (e.g. CODEX_VERSION=0.133.0 for
        # gpt-5.5 access — that model name is rejected by the 0.117.0
        # pinned in install-codex.sh.j2 because OpenAI's backend gates
        # newer models on a newer CLI). 0.117.0 is required for OpenRouter
        # (it's the last version with HTTP Chat Completions fallback for
        # the WS-Responses-only newer versions). So we keep 0.117.0 as the
        # template default and let ChatGPT-OAuth+OpenAI-direct runs
        # upgrade in-place.
        if codex_ver := os.environ.get("CODEX_VERSION"):
            log.info("CODEX_VERSION=%s: upgrading in-sandbox codex from 0.117.0", codex_ver)
            try:
                result = await environment.exec(
                    command=(
                        ". ~/.nvm/nvm.sh 2>/dev/null || true; "
                        f"npm install -g @openai/codex@{codex_ver} 2>&1 | tail -3; "
                        "codex --version"
                    ),
                    timeout_sec=120,
                )
                log.info("codex upgrade: rc=%s  %s", result.return_code, (result.stdout or "").strip())
            except Exception as e:
                log.warning("codex upgrade to %s failed: %s — proceeding with 0.117.0", codex_ver, e)

    # ── re-run command builder ───────────────────────────────────────

    def _build_followup_instruction(self, user_message: str) -> str:
        """Build a combined instruction with conversation history for re-run."""
        parts = [
            f"ORIGINAL TASK:\n{self._task_instruction}",
            "\nCONVERSATION HISTORY:",
        ]
        for entry in self._conversation_history:
            role = entry["role"].upper()
            parts.append(f"\n[{role}]:\n{entry['content']}")

        parts.append(f"\n[USER]:\n{user_message}")
        parts.append(
            "\nPlease continue working on the task, addressing the user's "
            "latest message above. The workspace already contains changes from "
            "previous turns — do NOT start over."
        )
        return "\n".join(parts)

    def _is_openrouter(self) -> bool:
        return bool(self.model_name and self.model_name.startswith("openrouter/"))

    def _resolve_model_and_env(self) -> tuple[str, dict[str, str]]:
        """Resolve the codex --model arg + env vars.

        OpenRouter requires the full provider/model path (e.g. `openai/gpt-5.5`)
        on its OpenAI-compat endpoint, so for `openrouter/openai/gpt-5.5` we
        strip just the `openrouter/` prefix instead of taking only the leaf.
        Also pins OPENAI_BASE_URL to OpenRouter's endpoint regardless of host
        env, so the in-sandbox codex never accidentally talks to OpenAI direct.
        """
        if not self.model_name:
            raise ValueError("Model name is required")

        env = {
            "OPENAI_API_KEY": os.environ.get("OPENAI_API_KEY", ""),
            "CODEX_HOME": EnvironmentPaths.agent_dir.as_posix(),
        }

        if self._is_openrouter():
            model = self.model_name.split("/", 1)[1]
            env["OPENAI_BASE_URL"] = "https://openrouter.ai/api/v1"
        else:
            model = self.model_name.split("/")[-1]
            if openai_base_url := os.environ.get("OPENAI_BASE_URL"):
                env["OPENAI_BASE_URL"] = openai_base_url
        return model, env

    @staticmethod
    def _parse_thread_id(stdout: str) -> str | None:
        """Extract thread_id from codex's stream-json output (`thread.started`)."""
        for line in stdout.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get("type") == "thread.started":
                tid = obj.get("thread_id")
                if isinstance(tid, str) and tid:
                    return tid
        return None

    def _build_rerun_commands_resume(self, user_msg: str) -> list[ExecInput]:
        """Build `codex exec resume <thread_id> <msg>` — server-side session continuation.

        Sends ONLY the new user message. Codex continues the thread it
        started in turn-0; on OpenAI direct the Responses API preserves
        server-side state and only the new message is billed as fresh input.
        Compare to ``_build_rerun_commands`` which re-issues the full
        TASK + HISTORY string every turn.
        """
        assert self._thread_id, "thread_id not yet captured"
        escaped_msg = shlex.quote(user_msg)
        model, env = self._resolve_model_and_env()
        cli_flags = self._inner.build_cli_flags()
        reasoning_flag = (cli_flags + " ") if cli_flags else ""

        return [
            ExecInput(
                command=(
                    "if [ -s ~/.nvm/nvm.sh ]; then . ~/.nvm/nvm.sh; fi; "
                    "codex exec "
                    "--dangerously-bypass-approvals-and-sandbox "
                    "--skip-git-repo-check "
                    f"--model {model} "
                    "--json "
                    "--enable unified_exec "
                    f"{reasoning_flag}"
                    f"resume {self._thread_id} "
                    f"{escaped_msg} "
                    f"2>&1 </dev/null | tee -a "
                    f"{EnvironmentPaths.agent_dir / 'codex.txt'}"
                ),
                env=env,
            ),
        ]

    def _build_rerun_commands(self, instruction: str) -> list[ExecInput]:
        """Build codex exec command with new instruction."""
        escaped_instruction = shlex.quote(instruction)
        model, env = self._resolve_model_and_env()

        cli_flags = self._inner.build_cli_flags()
        reasoning_flag = (cli_flags + " ") if cli_flags else ""

        return [
            ExecInput(
                command=(
                    "if [ -s ~/.nvm/nvm.sh ]; then . ~/.nvm/nvm.sh; fi; "
                    "codex exec "
                    "--dangerously-bypass-approvals-and-sandbox "
                    "--skip-git-repo-check "
                    f"--model {model} "
                    "--json "
                    "--enable unified_exec "
                    f"{reasoning_flag}"
                    "-- "
                    f"{escaped_instruction} "
                    f"2>&1 </dev/null | tee -a "
                    f"{EnvironmentPaths.agent_dir / 'codex.txt'}"
                ),
                env=env,
            ),
        ]

    # ── trajectory snapshot for user sim ─────────────────────────────

    def _snapshot_recent_output(self) -> str:
        if not self._cumulative_output:
            return "(nothing yet)"
        full = "\n".join(self._cumulative_output)
        if len(full) <= self._ctx_budget:
            return full
        return full[-self._ctx_budget:]

    # ── user simulation ──────────────────────────────────────────────

    async def _consult_user(
        self, observation: str, turn: int, completing: bool,
        logging_dir: Path | None = None,
    ) -> UserDecision:
        now = time.monotonic()
        elapsed_sec = now - self._start_time if self._start_time else 0
        turn_duration_sec = now - self._turn_start_time if self._turn_start_time else 0

        decision = await self._sim_user.process(
            task_description=self._task_instruction,
            recent_trajectory=self._snapshot_recent_output(),
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

    async def _capture_git_diff(self, environment, turn: int) -> None:
        """Snapshot per-turn git state; stash incremental for next user-sim turn."""
        self._last_turn_diff = await capture_git_diff(
            environment, logs_dir=self.logs_dir, turn=turn
        )

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

    # ── main run ─────────────────────────────────────────────────────

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        # Inject repo config files into the instruction
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        # Inject incremental-work notice so the agent stops after each sub-task
        # instead of completing everything in one autonomous run.
        instruction = instruction + _INCREMENTAL_NOTICE

        self._task_instruction = instruction
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: initial run via inner agent's commands. For OpenRouter,
        # the inner Codex builds `--model {leaf}` (e.g. gpt-5.5) and reads
        # OPENAI_BASE_URL from os.environ. Patch both so the in-sandbox codex
        # hits OpenRouter with the full provider/model path.
        commands = self._inner.create_run_agent_commands(instruction)
        if self._is_openrouter():
            full_model = self.model_name.split("/", 1)[1]  # e.g. "openai/gpt-5.5"
            bare_model = full_model.split("/")[-1]  # e.g. "gpt-5.5"
            for cmd in commands:
                cmd.command = cmd.command.replace(
                    f"--model {bare_model} ",
                    f"--model {full_model} ",
                )
                if cmd.env is None:
                    cmd.env = {}
                cmd.env["OPENAI_BASE_URL"] = "https://openrouter.ai/api/v1"

        # ChatGPT OAuth override: when CODEX_USE_HOST_AUTH=1, overwrite the
        # sandbox's synthetic API-key auth.json with the host user's
        # `~/.codex/auth.json` (which carries `auth_mode: chatgpt` + OAuth
        # tokens). This routes the in-sandbox codex to OpenAI's ChatGPT
        # subscription backend (flat-cost billing, Responses API server-side
        # thread state) instead of pay-per-token API key.
        host_auth_overlay_cmd = None
        if os.environ.get("CODEX_USE_HOST_AUTH") == "1":
            host_auth_path = os.environ.get("CODEX_HOST_AUTH_JSON",
                                            str(Path.home() / ".codex" / "auth.json"))
            try:
                auth_blob = Path(host_auth_path).read_text()
            except Exception as e:
                log.warning("CODEX_USE_HOST_AUTH=1 but cannot read %s: %s — skipping",
                            host_auth_path, e)
            else:
                # Use a delimiter unlikely to appear in JWTs (base64url ⊂ [A-Za-z0-9_-])
                heredoc_marker = "HOST_AUTH_JSON_EOF"
                host_auth_overlay_cmd = (
                    f'cat > "$CODEX_HOME/auth.json" <<\'{heredoc_marker}\'\n'
                    f'{auth_blob}\n'
                    f'{heredoc_marker}\n'
                    f'chmod 600 "$CODEX_HOME/auth.json"\n'
                )
                # Append to the setup command (first ExecInput is setup)
                if commands:
                    commands[0].command = commands[0].command + "\n" + host_auth_overlay_cmd
                log.info("CODEX_USE_HOST_AUTH=1: will overlay sandbox auth.json with host ChatGPT OAuth (auth_mode in host auth.json: %s)",
                         "chatgpt" if '"auth_mode"' in auth_blob and '"chatgpt"' in auth_blob else "?")

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

        # Capture thread_id from turn-0 stream-json output. Used by subsequent
        # turns to call `codex exec resume <id> <msg>` instead of full re-issue.
        # DEFAULT OFF: cli-task-46c118 scout with resume hit a verifier flake
        # (test.sh /tests not found after agent loop) we never tracked down —
        # likely codex 0.133.0 + heavy resume calls interacting badly with the
        # e2b sandbox lifecycle. Opt IN via CODEX_USE_RESUME=1 for further
        # experiments. Keep the resume code path live so it's easy to re-enable.
        if os.environ.get("CODEX_USE_RESUME") == "1":
            for output in self._cumulative_output:
                if tid := self._parse_thread_id(output):
                    self._thread_id = tid
                    log.info("captured codex thread_id: %s (will use `codex exec resume` for turns 1+)", tid)
                    break
            if not self._thread_id:
                log.info("thread_id not found in turn-0 output; falling back to full re-issue")

        # Record agent output in conversation history
        agent_output = self._snapshot_recent_output()
        self._conversation_history.append({"role": "agent", "content": agent_output})

        # Skip the multi-turn loop if turn-0 timed out — keep the per-turn
        # patch we captured and let post-run write final.patch + trajectory.
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
            observation = self._snapshot_recent_output()

            decision = await self._consult_user(
                observation, turn, completing=True, logging_dir=self.logs_dir,
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

            if self._thread_id:
                log.info("Resuming codex thread %s with user message (turn %d)",
                         self._thread_id, turn)
                rerun_commands = self._build_rerun_commands_resume(user_msg)
            else:
                log.info("Re-running codex with full history (turn %d) — thread_id unavailable", turn)
                followup = self._build_followup_instruction(user_msg)
                rerun_commands = self._build_rerun_commands(followup)

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

            if turn_timed_out:
                log.warning("turn %d hit per-exec timeout — stopping multi-turn loop", turn)
                break

            # Record this turn's output — truncated, NOT raw. A single misbehaved
            # turn can dump 100KB+ (e.g., agent runs 27 git/gh shell commands all
            # at once with full stdout captured). Without this cap the next turn's
            # followup_instruction balloons past e2b's exec-API request-body limit
            # and the wrapper crashes with InvalidArgumentException — verifier
            # never runs, no reward. The user simulator already sees a truncated
            # view via _snapshot_recent_output(), so feeding the agent the
            # snapshot version preserves the agent's view-of-itself consistently.
            new_output = self._snapshot_recent_output()
            self._conversation_history.append({"role": "agent", "content": new_output})

        # Final safety net — re-snapshot at run-end so even if all per-turn
        # captures somehow fail, final.patch reflects the very last state.
        try:
            await self._capture_git_diff(environment, turn=999)
        except Exception as e:
            log.debug("end-of-run patch capture failed: %s", e)

        # Post-run: build trajectory
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
