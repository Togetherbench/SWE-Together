"""Codex agent wrapper with simulated user injection via sequential runs.

Codex CLI has no --resume mechanism, so multi-turn works by re-running
`codex exec` with the accumulated conversation context prepended to the
instruction:

  Turn 0: codex exec "original instruction"
  Turn 1: codex exec "original instruction + agent output summary + user message"
  Turn N: codex exec "original instruction + full conversation history"
"""

import json
import logging
import os
import shlex
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

from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15


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

    @staticmethod
    def name() -> str:
        return "user-enabled-codex"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)

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
        """Build codex exec command with new instruction."""
        escaped_instruction = shlex.quote(instruction)

        if not self.model_name:
            raise ValueError("Model name is required")

        model = self.model_name.split("/")[-1]

        env = {
            "OPENAI_API_KEY": os.environ.get("OPENAI_API_KEY", ""),
            "CODEX_HOME": EnvironmentPaths.agent_dir.as_posix(),
        }

        if openai_base_url := os.environ.get("OPENAI_BASE_URL"):
            env["OPENAI_BASE_URL"] = openai_base_url

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
        decision = await self._sim_user.process(
            task_description=self._task_instruction,
            recent_trajectory=self._snapshot_recent_output(),
            latest_observation=observation[:self._ctx_budget],
            latest_analysis=None,
            step_count=turn,
            is_completion_attempt=completing,
            total_steps_so_far=turn,
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

    # ── main run ─────────────────────────────────────────────────────

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        self._task_instruction = instruction

        # Turn 0: initial run via inner agent's commands
        commands = self._inner.create_run_agent_commands(instruction)
        for i, exec_input in enumerate(commands):
            result = await environment.exec(
                command=f"set -o pipefail; {exec_input.command}",
                cwd=exec_input.cwd,
                env=exec_input.env,
                timeout_sec=exec_input.timeout_sec,
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

        # Record agent output in conversation history
        agent_output = self._snapshot_recent_output()
        self._conversation_history.append({"role": "agent", "content": agent_output})

        # Multi-turn: sequential re-run loop
        for turn in range(1, _MAX_RESUME_TURNS + 1):
            observation = self._snapshot_recent_output()

            decision = await self._consult_user(
                observation, turn, completing=True, logging_dir=self.logs_dir,
            )

            if not decision.has_message:
                log.info("User sim silent at turn %d — ending", turn)
                break

            user_msg = decision.format_for_injection()
            self._conversation_history.append({"role": "user", "content": user_msg})
            log.info("Re-running codex with user message (turn %d)", turn)

            followup = self._build_followup_instruction(user_msg)
            rerun_commands = self._build_rerun_commands(followup)

            for j, exec_input in enumerate(rerun_commands):
                result = await environment.exec(
                    command=f"set -o pipefail; {exec_input.command}",
                    cwd=exec_input.cwd,
                    env=exec_input.env,
                    timeout_sec=exec_input.timeout_sec,
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

            # Record this turn's output
            new_output = self._cumulative_output[-1] if self._cumulative_output else ""
            self._conversation_history.append({"role": "agent", "content": new_output})

        # Post-run: build trajectory
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
