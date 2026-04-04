"""Claude Code agent wrapper with simulated user injection via --resume.

Multi-turn flow:
  1. Run `claude --print <instruction>` → agent completes first turn
  2. Parse session ID from JSONL logs
  3. Consult UserAgent — if it wants to intervene, run
     `claude --resume <session_id> --print <user_message>`
  4. Repeat until user sim is silent or max turns reached
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.installed.base import ExecInput
from harbor.agents.installed.claude_code import ClaudeCode
from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.llms.lite_llm import LiteLLM

from .repo_config import discover_repo_config_files
from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_MAX_RESUME_TURNS = 15


class UserEnabledClaudeCode(BaseAgent):
    """Claude Code + simulated user via sequential --resume invocations."""

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

        # Compose the real ClaudeCode agent for setup/commands
        self._inner = ClaudeCode(logs_dir=logs_dir, model_name=model_name, **kwargs)

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

    @staticmethod
    def name() -> str:
        return "user-enabled-claude-code"

    def version(self) -> str | None:
        return self._inner.version()

    async def setup(self, environment: BaseEnvironment) -> None:
        await self._inner.setup(environment)

    # ── session ID extraction ────────────────────────────────────────

    def _find_session_id(self) -> str | None:
        """Parse session ID from Claude Code output.

        Tries three sources in order:
        1. The stream-json stdout captured in _cumulative_output (most reliable —
           the init event always contains session_id)
        2. JSONL session logs on disk via _get_session_dir()
        3. Fallback to directory name

        Source 1 avoids the "Multiple session directories" bug in Harbor's
        _get_session_dir() which returns None when multiple project dirs exist.
        """
        # Source 1: parse from captured stdout (stream-json init event)
        for raw in self._cumulative_output:
            for line in raw.split("\n"):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    # The init event has {"type": "system", "subtype": "init", "session_id": "..."}
                    sid = event.get("session_id") or event.get("sessionId")
                    if isinstance(sid, str) and sid:
                        return sid
                except (json.JSONDecodeError, ValueError):
                    continue

        # Source 2: JSONL files on disk
        session_dir = self._inner._get_session_dir()
        if session_dir:
            for jsonl_file in session_dir.glob("*.jsonl"):
                with open(jsonl_file) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = json.loads(line)
                            sid = event.get("sessionId")
                            if isinstance(sid, str) and sid:
                                return sid
                        except json.JSONDecodeError:
                            continue
            # Source 3: directory name
            return session_dir.name

        return None

    # ── resume command builder ───────────────────────────────────────

    def _build_resume_command(self, session_id: str, user_message: str) -> list[ExecInput]:
        """Build claude --resume command to continue with a user message."""
        import shlex
        escaped_message = shlex.quote(user_message)

        # Reuse the inner agent's env setup
        initial_commands = self._inner.create_run_agent_commands("")
        if not initial_commands:
            return []

        # Use the env from the main run command (last one)
        run_env = initial_commands[-1].env or {}

        cli_flags = self._inner.build_cli_flags()
        extra_flags = (cli_flags + " ") if cli_flags else ""

        return [
            ExecInput(
                command=(
                    'export PATH="$HOME/.local/bin:$PATH"; '
                    f"claude --verbose --output-format=stream-json "
                    f"--permission-mode=bypassPermissions "
                    f"--resume {session_id} "
                    f"{extra_flags}"
                    f"--print -- {escaped_message} 2>&1 </dev/null | tee -a "
                    f"/logs/agent/claude-code.txt"
                ),
                env=run_env,
            ),
        ]

    # ── trajectory snapshot for user sim ─────────────────────────────

    @staticmethod
    def _parse_stream_json(raw: str) -> list[str]:
        """Parse Claude Code stream-json output into structured step summaries.

        Converts raw JSONL (thinking, tool_use, text, result) into a format
        similar to Terminus 2's trajectory steps, so the user simulator sees
        structured information instead of raw JSON noise.
        """
        steps: list[str] = []
        step_id = 0
        for line in raw.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue

            t = obj.get("type")

            if t == "assistant":
                for block in obj.get("message", {}).get("content", []):
                    bt = block.get("type")
                    if bt == "thinking":
                        step_id += 1
                        text = block.get("thinking", "")[:300]
                        steps.append(f"[{step_id}] thinking: {text}")
                    elif bt == "tool_use":
                        step_id += 1
                        name = block.get("name", "?")
                        inp = block.get("input", {})
                        # Show the most useful part of each tool call
                        if name in ("Bash", "bash"):
                            detail = inp.get("command", "")[:200]
                        elif name in ("Read", "read"):
                            detail = inp.get("file_path", "")
                        elif name in ("Edit", "edit"):
                            detail = inp.get("file_path", "")
                        elif name in ("Write", "write"):
                            detail = inp.get("file_path", "")
                        elif name in ("Grep", "grep"):
                            detail = f'pattern={inp.get("pattern", "")} path={inp.get("path", "")}'
                        elif name in ("Glob", "glob"):
                            detail = inp.get("pattern", "")
                        else:
                            detail = json.dumps(inp)[:200]
                        steps.append(f"[{step_id}] tool_call({name}): {detail}")
                    elif bt == "text":
                        step_id += 1
                        text = block.get("text", "")[:300]
                        steps.append(f"[{step_id}] agent: {text}")

            elif t == "result":
                step_id += 1
                result = obj.get("result", "")
                if isinstance(result, str):
                    steps.append(f"[{step_id}] result: {result[:300]}")
                else:
                    steps.append(f"[{step_id}] result: {json.dumps(result)[:300]}")

        return steps

    def _snapshot_recent_output(self) -> str:
        """Return a structured summary of agent activity within context budget.

        Parses Claude Code's stream-json output into structured steps (similar
        to Terminus 2's trajectory format), then returns the tail that fits
        within the context budget.
        """
        if not self._cumulative_output:
            return "(nothing yet)"

        # Parse the latest turn's raw output into structured steps
        all_steps: list[str] = []
        for raw in self._cumulative_output:
            all_steps.extend(self._parse_stream_json(raw))

        if not all_steps:
            # Fallback to raw tail if parsing yields nothing
            full = "\n".join(self._cumulative_output)
            return full[-self._ctx_budget:]

        # Walk backwards to fit within budget
        lines: list[str] = []
        chars = 0
        for step in reversed(all_steps):
            if chars + len(step) + 1 > self._ctx_budget and lines:
                break
            lines.append(step)
            chars += len(step) + 1
        lines.reverse()
        return "\n".join(lines)

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
        # Inject repo config files into the instruction
        config_content = await discover_repo_config_files(environment)
        if config_content:
            instruction = f"{instruction}\n\n{config_content}"

        self._task_instruction = instruction

        # Turn 0: initial run via inner agent's commands
        commands = self._inner.create_run_agent_commands(instruction)
        for i, exec_input in enumerate(commands):
            env = exec_input.env
            result = await environment.exec(
                command=f"set -o pipefail; {exec_input.command}",
                cwd=exec_input.cwd,
                env=env,
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

        # Multi-turn: resume loop
        session_id = self._find_session_id()
        if not session_id:
            log.warning("Could not find Claude Code session ID — skipping user sim turns")
            self._inner.populate_context_post_run(context)
            return

        log.info("Claude Code session ID: %s", session_id)

        for turn in range(1, _MAX_RESUME_TURNS + 1):
            observation = self._snapshot_recent_output()

            # Consult user sim (treat every completed claude run as a "completion")
            decision = await self._consult_user(
                observation, turn, completing=True, logging_dir=self.logs_dir,
            )

            if not decision.has_message:
                log.info("User sim silent at turn %d — ending", turn)
                break

            # Resume with user message
            user_msg = decision.format_for_injection()
            log.info("Resuming claude-code session with user message (turn %d)", turn)

            resume_commands = self._build_resume_command(session_id, user_msg)
            for j, exec_input in enumerate(resume_commands):
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

        # Post-run: build trajectory from session logs
        try:
            self._inner.populate_context_post_run(context)
        except Exception as e:
            log.warning("Failed to populate context post-run: %s", e)
