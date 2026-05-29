"""Codex agent wrapper with simulated user injection via sequential runs.

Codex CLI has no --resume mechanism, so multi-turn works by re-running
`codex exec` with the accumulated conversation context prepended to the
instruction:

  Turn 0: codex exec "original instruction"
  Turn 1: codex exec "original instruction + agent output summary + user message"
  Turn N: codex exec "original instruction + full conversation history"

Functionally mirrors `user_enabled_claude_code` — per-turn git diff
capture, wall-clock timing, no-op streak allowance — except the agent
harness is Codex (whose `--resume` we use when CODEX_USE_RESUME=1).
Also: codex does NOT get CC's incremental-work notice (see top-of-file
NOTE) because gpt-5.5's per-turn cost makes extra checkpoints expensive.
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

# NOTE: _INCREMENTAL_NOTICE removed for codex (was a port of CC's v0.5.2 fix —
# see CHANGELOG). Reasoning: CC's per-turn cost is tiny (~seconds), so extra
# checkpoints are free; codex+gpt-5.5 spends 5-20+ min per turn, so forcing
# more sub-task boundaries amplifies cap-hit risk on hard tasks (e.g. comfyui).
# Keeping CC's incremental notice; codex relies on the relaxed-trigger v0.5.2
# guidance (still in src/run_eval.py) to drive user-sim engagement without
# manipulating the agent's own working style.

# Followup-prompt budget knobs. claude_code carries full tool history across
# turns via `claude --resume`; codex has no resume so we manually reconstruct
# state in the prompt. These caps balance "enough state for the model to
# avoid re-exploring" against "small enough to fit + not blow PER_EXEC_CAP".
_TOOL_CALL_TYPES = frozenset({
    "command_execution", "function_call", "apply_patch", "local_shell",
})
_TOOL_OUTPUT_CHAR_CAP = 500     # per single tool call
_TOOL_HISTORY_TURN_CAP = 4000   # per turn (sum of tool-call entries)
_TOOL_HISTORY_TURNS_KEPT = 3    # only inject last N turns of tool log
_CUM_DIFF_CHAR_CAP = 20000      # cumulative-diff section in followup


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
        codex_version: str = "0.133.0",
        reasoning_effort: str = "medium",
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)

        # Pin the in-sandbox codex CLI version for reproducibility. Upstream
        # Codex.install() does `npm install -g @openai/codex@{_version or 'latest'}`,
        # so passing version= here ensures every trial gets the exact same CLI
        # regardless of when @latest moves. 0.133.0 is the minimum that
        # accepts the gpt-5.5 model name (older versions reject it).
        # `kwargs.pop("version", None)` defensively drops a stray cc-style
        # `version` (e.g. "2.1.108") if run_eval still forwards one.
        kwargs.pop("version", None)
        # reasoning_effort default = "medium" (was upstream default "high").
        # gpt-5.5 + high reasoning spends 15-25 min on hard turns; medium
        # cuts that ~30-50% with marginal quality loss on tool-use heavy
        # multi-turn tasks. caller can override via constructor kwarg.
        kwargs.pop("reasoning_effort", None)
        self._inner = Codex(
            logs_dir=logs_dir, model_name=model_name,
            version=codex_version, reasoning_effort=reasoning_effort, **kwargs,
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
        # Timing: wall-clock tracking for turn summaries
        self._start_time: float = 0.0
        self._turn_start_time: float = 0.0
        # Per-turn incremental git diff captured at end of the prior turn;
        # fed to user sim so it has an independent view of what the agent
        # actually wrote (vs the agent's self-narration).
        self._last_turn_diff: str = ""
        # Cumulative diff (vs harbor-base) read from logs_dir/final.patch after
        # each _capture_git_diff. Injected into followup prompts so the codex
        # agent knows what files it already changed and doesn't re-explore.
        self._last_cumulative_diff: str = ""
        # Compact per-turn tool-call log extracted from codex stream-json
        # output. Without this, follow-up turns have no record of the prior
        # turn's shell commands and reconstruct state from scratch — the root
        # cause of comfyui-style timeouts where the agent re-greps the entire
        # codebase every turn.
        self._tool_history: list[str] = []
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

    # ── re-run command builder ───────────────────────────────────────

    @staticmethod
    def _extract_tool_calls_compact(stdout: str) -> str:
        """Parse codex stream-json output → compact tool-call log.

        Codex emits one JSON event per line; `item.completed` with
        type==command_execution|function_call|apply_patch|local_shell carries
        the tool call's command and aggregated stdout. We extract just those,
        cap each output at _TOOL_OUTPUT_CHAR_CAP chars, and cap total turn
        log at _TOOL_HISTORY_TURN_CAP. Result is a compact log the agent can
        re-read to know what it already tried — without re-running it.
        """
        out_lines: list[str] = []
        total_size = 0
        for line in stdout.split("\n"):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get("type") != "item.completed":
                continue
            item = obj.get("item") or {}
            if item.get("type") not in _TOOL_CALL_TYPES:
                continue
            cmd = (item.get("command") or item.get("name") or "")
            if len(cmd) > 200:
                cmd = cmd[:200] + "..."
            out = (item.get("aggregated_output") or item.get("output") or "").strip()
            if len(out) > _TOOL_OUTPUT_CHAR_CAP:
                out = "...[truncated]...\n" + out[-_TOOL_OUTPUT_CHAR_CAP:]
            exit_code = item.get("exit_code")
            entry = f"$ {cmd}\n[exit={exit_code}] {out}"
            if total_size + len(entry) > _TOOL_HISTORY_TURN_CAP:
                out_lines.append("... [more tool calls elided] ...")
                break
            out_lines.append(entry)
            total_size += len(entry) + 1
        return "\n".join(out_lines).strip() or "(no tool calls recorded)"

    def _build_followup_instruction(self, user_message: str) -> str:
        """Build a followup prompt with workspace state + tool history.

        Codex has no `--resume`, so each follow-up `codex exec` starts cold.
        The previous design prepended raw cumulative stdout (3 KB tail) and
        let the agent rediscover its own work — on heavy repos this blew
        past the PER_EXEC_CAP because the model re-greps everything.

        This version gives the agent three structured signals:
          1. CURRENT WORKSPACE STATE — cumulative git diff (truncated)
             so the agent sees exactly which files have been modified
          2. RECENT TOOL CALLS — last N turns' shell-command log
             (compact) so the agent sees what it already tried
          3. PRIOR USER MESSAGES — list-form (short)
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

    def _build_setup_command(self) -> str:
        """Replicate the codex `setup_command` from old harbor codex.py.

        Upstream Harbor (≥ master after Codex.run() refactor) does this inline
        inside Codex.run() and no longer exposes `create_run_agent_commands`.
        We rebuild it here so our wrapper can keep its [setup, exec] two-step
        command list and apply the host_auth_overlay between them.

        The setup writes a synthetic api-key auth.json (later overwritten by
        host_auth_overlay if CODEX_USE_HOST_AUTH=1) plus config.toml for
        openai_base_url (codex 0.118+ only honors it from config, not env).
        """
        setup = (
            "mkdir -p /tmp/codex-secrets\n"
            'cat >/tmp/codex-secrets/auth.json <<EOF\n'
            '{\n  "OPENAI_API_KEY": "${OPENAI_API_KEY}"\n}\n'
            'EOF\n'
            'mkdir -p "$CODEX_HOME"\n'
            'ln -sf /tmp/codex-secrets/auth.json "$CODEX_HOME/auth.json"\n'
        )
        # codex 0.118.0+ only honors openai_base_url from config.toml, not env.
        if os.environ.get("OPENAI_BASE_URL") or self._is_openrouter():
            setup += (
                '\ncat >>"$CODEX_HOME/config.toml" <<TOML\n'
                'openai_base_url = "${OPENAI_BASE_URL}"\n'
                "TOML\n"
            )
        return setup

    def _build_turn0_commands(self, instruction: str) -> list[ExecInput]:
        """Build turn-0 command list: [setup, codex exec].

        Replaces `self._inner.create_run_agent_commands(instruction)` which
        was removed when upstream Harbor's Codex agent dropped the
        command-list API in favor of an in-process `run()` method. Our
        wrapper needs the list form to (a) inject the host_auth_overlay
        between setup and exec, and (b) drive each step through
        `exec_with_budget` for our per-exec timeout cap.
        """
        _, env = self._resolve_model_and_env()
        setup_input = ExecInput(command=self._build_setup_command(), env=env)
        exec_inputs = self._build_rerun_commands(instruction)
        return [setup_input, *exec_inputs]

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
        """Snapshot per-turn git state; stash incremental for user-sim AND
        cumulative for next followup prompt.

        capture_git_diff() returns the incremental diff and writes both
        incremental + cumulative to logs_dir/patches/. We re-read the
        cumulative from logs_dir/final.patch (always overwritten with the
        latest cumulative) so we can inject it into the next followup —
        giving the codex agent visibility into what files it already changed
        (parity with claude_code's --resume tool-history).
        """
        self._last_turn_diff = await capture_git_diff(
            environment, logs_dir=self.logs_dir, turn=turn
        )
        final_patch = self.logs_dir / "final.patch"
        try:
            self._last_cumulative_diff = final_patch.read_text() if final_patch.exists() else ""
        except Exception as e:
            log.debug("failed to read cumulative diff at turn %d: %s", turn, e)
            self._last_cumulative_diff = ""

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
        self._start_time = time.monotonic()
        self._turn_start_time = self._start_time

        # Turn 0: build [setup, codex exec] ourselves. Upstream Harbor's
        # Codex agent no longer exposes `create_run_agent_commands` (it moved
        # to an in-process Codex.run() that doesn't return a command list).
        # We mirror the old setup+exec shape so the post-processing below
        # (OpenRouter model rename, host_auth_overlay injection) still works.
        commands = self._build_turn0_commands(instruction)
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
        turn0_stdout_parts: list[str] = []
        try:
            for i, exec_input in enumerate(commands):
                result, timed_out = await exec_with_budget(
                    environment, exec_input, start_time=self._start_time,
                )
                if result.stdout:
                    self._cumulative_output.append(result.stdout)
                    turn0_stdout_parts.append(result.stdout)

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
            # Extract compact tool-call log from this turn's codex stream-json
            # output. Injected into next followup so the agent sees what it
            # already tried. Concat across all commands in the turn.
            if turn0_stdout_parts:
                self._tool_history.append(
                    self._extract_tool_calls_compact("\n".join(turn0_stdout_parts))
                )

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
            turn_stdout_parts: list[str] = []
            try:
                for j, exec_input in enumerate(rerun_commands):
                    result, timed_out = await exec_with_budget(
                        environment, exec_input, start_time=self._start_time,
                    )
                    if result.stdout:
                        self._cumulative_output.append(result.stdout)
                        turn_stdout_parts.append(result.stdout)

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
                # Extract compact tool-call log for this turn, append to
                # history so next turn's followup includes it.
                if turn_stdout_parts:
                    self._tool_history.append(
                        self._extract_tool_calls_compact("\n".join(turn_stdout_parts))
                    )

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
