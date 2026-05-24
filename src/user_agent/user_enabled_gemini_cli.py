"""Gemini CLI agent wrapper with simulated user injection via sequential runs.

Gemini CLI (like Codex) has no `--resume`, so multi-turn works by
re-running `gemini` with the accumulated conversation context prepended
to the prompt. Functionally mirrors `user_enabled_codex` and
`user_enabled_claude_code` — per-turn git diff capture, wall-clock
timing, incremental-work notice, no-op streak allowance.
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
from harbor.agents.installed.gemini_cli import GeminiCli
from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.llms.lite_llm import LiteLLM

from .exec_helpers import TRIAL_BUDGET_SEC, exec_with_budget
from .repo_config import discover_repo_config_files
from .repo_diff import DEFAULT_REPO_ROOTS, capture_git_diff, tag_harbor_base
from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15
_MAX_CONSECUTIVE_NOOPS = 4

_INCREMENTAL_NOTICE = (
    "\n\nIMPORTANT: Work incrementally. After completing each distinct "
    "sub-task (e.g., implementing one feature, fixing one bug, making one "
    "significant change), STOP and report what you did and what you plan "
    "to do next. Wait for user feedback before proceeding to the next "
    "sub-task. Do NOT implement everything in one go."
)

# Env vars Gemini CLI honors — mirror the auth_vars list in
# harbor.agents.installed.gemini_cli.GeminiCli.create_run_agent_commands.
_GEMINI_AUTH_VARS = (
    "GEMINI_API_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "GOOGLE_CLOUD_LOCATION",
    "GOOGLE_GENAI_USE_VERTEXAI",
    "GOOGLE_API_KEY",
)


class UserEnabledGeminiCli(BaseAgent):
    """Gemini CLI + simulated user via sequential gemini invocations."""

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

        self._inner = GeminiCli(logs_dir=logs_dir, model_name=model_name, **kwargs)

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
        self._start_time: float = 0.0
        self._turn_start_time: float = 0.0
        self._last_turn_diff: str = ""

    @staticmethod
    def name() -> str:
        return "user-enabled-gemini-cli"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)
        await self._strip_workspace_gemini_settings(environment)
        await tag_harbor_base(environment)

    async def _strip_workspace_gemini_settings(self, environment) -> None:
        """Delete task-level `.gemini/settings.json` files in every repo root.

        Many tasks ship a repo-level `.gemini/settings.json` configuring
        project hooks (`entire-before-tool`, `entire-before-agent`, etc.)
        that call binaries like `go` or `pre-commit` which aren't in our
        sandbox. Each failed hook blocks the agent's tool call, deadlocking
        the trial — and the agent can't repair it because the deletion
        itself triggers the failing hook.
        Strip surgically: only `settings.json`, leave `.gemini/agents/`,
        `.gemini/skills/`, `.gemini/commands/` alone (those at most emit
        validation warnings; they don't block tool execution). The eval's
        own ~/.gemini/settings.json (written by install-gemini-cli.sh.j2)
        is outside DEFAULT_REPO_ROOTS so isn't touched.
        """
        cmd = (
            'set +e\n'
            f'ROOTS="{DEFAULT_REPO_ROOTS}"\n'
            'if [ -n "${HARBOR_REPO_PATHS:-}" ]; then\n'
            '  ROOTS="$ROOTS $(echo "$HARBOR_REPO_PATHS" | tr ":" " ")"\n'
            'fi\n'
            'EXISTING=""\n'
            'for r in $ROOTS; do [ -e "$r" ] && EXISTING="$EXISTING $r"; done\n'
            '[ -z "$EXISTING" ] && exit 0\n'
            'find $EXISTING -maxdepth 4 -type f '
            '-path "*/.gemini/settings.json" -print -delete 2>/dev/null\n'
        )
        try:
            result = await environment.exec(
                command=cmd, cwd="/", env={}, timeout_sec=30,
            )
            if result.stdout and result.stdout.strip():
                log.info(
                    "Stripped task-level .gemini/settings.json: %s",
                    result.stdout.strip().split("\n"),
                )
        except Exception as e:
            log.debug("strip workspace gemini settings failed: %s", e)

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

    def _build_rerun_commands(self, instruction: str) -> list[ExecInput]:
        """Build `gemini --yolo` command — mirrors GeminiCli.create_run_agent_commands."""
        escaped_instruction = shlex.quote(instruction)

        if not self.model_name or "/" not in self.model_name:
            raise ValueError("Model name must be in the format provider/model_name")

        model = self.model_name.split("/")[-1]

        env: dict[str, str] = {}
        for var in _GEMINI_AUTH_VARS:
            if var in os.environ:
                env[var] = os.environ[var]
        # Gemini CLI refuses to run outside a "trusted" workspace by default
        # (gemini-cli-task-46c118 scout showed every turn erroring with
        # "Gemini CLI is not running in a trusted directory"). Override via
        # env var so YOLO mode actually runs.
        env["GEMINI_CLI_TRUST_WORKSPACE"] = "true"

        cli_flags = self._inner.build_cli_flags()
        extra_flags = (cli_flags + " ") if cli_flags else ""

        return [
            ExecInput(
                command=(
                    ". ~/.nvm/nvm.sh; "
                    f"gemini --yolo {extra_flags}--model={model} "
                    f"--prompt={escaped_instruction} "
                    f"2>&1 </dev/null | stdbuf -oL tee -a /logs/agent/gemini-cli.txt"
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
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        instruction = instruction + _INCREMENTAL_NOTICE

        self._task_instruction = instruction
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: initial run via inner agent's commands. Inject the
        # workspace-trust override here too — GeminiCli.create_run_agent_commands
        # only forwards the auth-var family, not GEMINI_CLI_TRUST_WORKSPACE.
        commands = self._inner.create_run_agent_commands(instruction)
        for exec_input in commands:
            if exec_input.env is None:
                exec_input.env = {}
            exec_input.env["GEMINI_CLI_TRUST_WORKSPACE"] = "true"
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
            log.info("Re-running gemini with user message (turn %d)", turn)
            self._turn_start_time = time.monotonic()

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

            # Truncated, not raw — see user_enabled_codex for rationale.
            new_output = self._snapshot_recent_output()
            self._conversation_history.append({"role": "agent", "content": new_output})

        try:
            await self._capture_git_diff(environment, turn=999)
        except Exception as e:
            log.debug("end-of-run patch capture failed: %s", e)

        # Post-run: build trajectory from gemini-cli session log
        try:
            cleanup_cmds = self._inner.create_cleanup_commands()
            for exec_input in cleanup_cmds:
                await environment.exec(
                    command=exec_input.command,
                    cwd=exec_input.cwd,
                    env=exec_input.env,
                    timeout_sec=exec_input.timeout_sec,
                )
        except Exception as e:
            log.debug("gemini cleanup commands failed: %s", e)

        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
