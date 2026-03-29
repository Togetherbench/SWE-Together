"""Terminus2 wrapper that injects a simulated user into the action loop.

Every action turn, an LLM-powered UserAgent watches the trajectory and
decides whether to stay silent or send a message (question, redirect,
new requirement, etc.). Messages are injected as user turns in the chat,
so the action agent sees them exactly as it would see real human input.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.terminus_2.terminus_2 import Terminus2, Command
from harbor.llms.lite_llm import LiteLLM

from .user_agent import UserAgent, UserDecision

log = logging.getLogger(__name__)

_INTERACTION_NOTICE = (
    "\n\nNote: You are working with a human user who may send you "
    "additional messages, corrections, or new requirements during "
    "the task. If you receive a message from the user, read it "
    "carefully and adjust your approach accordingly."
)


class UserEnabledTerminus2(Terminus2):
    """Terminus2 + simulated user that can intervene every turn.

    The user simulator is an independent LLM that role-plays as the
    original human user. It sees a sliding window of the agent's recent
    activity (bounded by ``user_context_chars``) and picks one of:
    wait, question, redirect, new_requirement, check_external, interrupt.
    """

    def __init__(
        self,
        logs_dir: Path,
        model_name: str,
        *,
        user_model_name: str = "anthropic/claude-opus-4.5",
        user_api_base: str | None = None,
        user_api_key: str | None = None,
        user_temperature: float = 0.5,
        user_context_chars: int = 2000,
        original_user_messages: list[str] | None = None,
        session_analysis: str = "",
        max_messages: int | None = None,
        call_user_on_completion: bool = True,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)

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

    # ── trajectory snapshot ──────────────────────────────────────────

    def _snapshot_trajectory(self) -> str:
        """Return a tail-window of trajectory text within the context budget."""
        if not self._trajectory_steps:
            return "(nothing yet)"

        lines: list[str] = []
        chars = 0
        for step in reversed(self._trajectory_steps):
            sid = getattr(step, "step_id", "?")
            src = getattr(step, "source", "?")
            msg = (getattr(step, "message", "") or "")[:300]

            obs_text = ""
            obs = getattr(step, "observation", None)
            if obs and hasattr(obs, "results") and obs.results:
                obs_text = (getattr(obs.results[0], "content", "") or "")[:300]

            line = f"[{sid}] {src}: {msg}"
            if obs_text:
                line += f"\n  > {obs_text}"

            if chars + len(line) > self._ctx_budget and lines:
                break
            lines.append(line)
            chars += len(line) + 1

        lines.reverse()
        return "\n".join(lines)

    # ── simulated user call ──────────────────────────────────────────

    async def _consult_user(
        self, observation: str, analysis: str | None,
        turn: int, completing: bool,
        logging_dir: Path | None = None,
    ) -> UserDecision:
        decision = await self._sim_user.process(
            task_description=self._task_instruction,
            recent_trajectory=self._snapshot_trajectory(),
            latest_observation=observation[:self._ctx_budget],
            latest_analysis=analysis,
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
        """Write user_decision.json into the episode directory."""
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
        log.debug("Wrote user decision to %s", path)

    # ── main loop override ───────────────────────────────────────────

    async def _run_agent_loop(
        self,
        initial_prompt: str,
        chat,
        logging_dir: Path | None = None,
        original_instruction: str = "",
    ) -> int:
        if self._context is None:
            raise RuntimeError("Agent context is not set.")
        if self._session is None:
            raise RuntimeError("Session is not set.")

        self._task_instruction = original_instruction or initial_prompt
        prompt = initial_prompt + _INTERACTION_NOTICE

        for turn in range(self._max_episodes):
            self._n_episodes = turn + 1

            if not await self._session.is_session_alive():
                log.debug("Session ended at turn %d", turn)
                return turn + 1

            # Context summarization (inherited from Terminus2)
            if original_instruction and self._enable_summarize:
                summary = await self._check_proactive_summarization(
                    chat, original_instruction, self._session,
                )
                if summary:
                    handoff, refs = summary
                    self._pending_subagent_refs = refs
                    self._pending_handoff_prompt = handoff
                    prompt = handoff

            log_paths = self._setup_episode_logging(logging_dir, turn)

            # LLM call
            (
                commands, is_done, feedback, analysis, plan, llm_resp,
            ) = await self._handle_llm_interaction(
                chat, prompt, log_paths, original_instruction, self._session,
            )

            # Bookkeeping: subagent refs from summarization
            if self._pending_subagent_refs:
                from harbor.models.trajectories import Step, Observation, ObservationResult
                self._trajectory_steps.append(Step(
                    step_id=len(self._trajectory_steps) + 1,
                    timestamp=datetime.now(timezone.utc).isoformat(),
                    source="system",
                    message="Performed context summarization.",
                    observation=Observation(results=[
                        ObservationResult(
                            subagent_trajectory_ref=self._pending_subagent_refs,
                        )
                    ]),
                ))
                self._pending_subagent_refs = None

            if self._pending_handoff_prompt:
                from harbor.models.trajectories import Step
                if self._linear_history:
                    self._split_trajectory_on_summarization(
                        self._pending_handoff_prompt,
                    )
                else:
                    self._trajectory_steps.append(Step(
                        step_id=len(self._trajectory_steps) + 1,
                        timestamp=datetime.now(timezone.utc).isoformat(),
                        source="user",
                        message=self._pending_handoff_prompt,
                    ))
                self._pending_handoff_prompt = None

            # Trajectory content
            if self._save_raw_content_in_trajectory:
                _ = llm_resp.content
            else:
                parts = []
                if analysis:
                    parts.append(f"Analysis: {analysis}")
                if plan:
                    parts.append(f"Plan: {plan}")

            # Token tracking
            self._context.n_input_tokens = chat.total_input_tokens
            self._context.n_output_tokens = chat.total_output_tokens
            self._context.n_cache_tokens = chat.total_cache_tokens
            self._context.cost_usd = (
                chat.total_cost if chat.total_cost > 0 else None
            )

            # Parse errors → retry without consulting user
            if feedback and "ERROR:" in feedback:
                prompt = (
                    f"Previous response had parsing errors:\n{feedback}\n\n"
                    f"Please fix these issues and provide a proper "
                    f"{self._get_error_response_type()}."
                )
                continue

            # Execute commands
            _, terminal_output = await self._execute_commands(
                commands, self._session,
            )

            was_pending = self._pending_completion

            # Build observation text
            if is_done:
                if self._pending_completion:
                    observation = terminal_output
                else:
                    self._pending_completion = True
                    observation = self._get_completion_confirmation_message(
                        terminal_output,
                    )
            else:
                self._pending_completion = False
                if feedback and "WARNINGS:" in feedback:
                    observation = (
                        f"Previous response had warnings:\n{feedback}\n\n"
                        f"{self._limit_output_length(terminal_output)}"
                    )
                else:
                    observation = self._limit_output_length(terminal_output)

            # ── completion handling ──
            if is_done:
                if was_pending:
                    log.info(
                        "Task done. User sim stats: %s",
                        self._sim_user.get_stats(),
                    )
                    return turn + 1

                # First completion signal — let the user sim weigh in
                if self._check_on_completion:
                    dec = await self._consult_user(
                        observation, analysis, turn + 1, completing=True,
                        logging_dir=logging_dir,
                    )
                    if dec.has_message:
                        self._push_user_turn(chat, dec.format_for_injection())
                        prompt = dec.format_for_injection()
                        self._pending_completion = False
                        continue

                prompt = observation
                continue

            # ── normal turn: consult simulated user ──
            dec = await self._consult_user(
                observation, analysis, turn + 1, completing=False,
                logging_dir=logging_dir,
            )
            if dec.has_message:
                msg = dec.format_for_injection()
                self._push_user_turn(chat, msg)
                prompt = msg
                continue

            prompt = observation

        return self._n_episodes

    # ── chat injection ───────────────────────────────────────────────

    @staticmethod
    def _push_user_turn(chat, message: str):
        chat.messages.append({"role": "user", "content": message})
        log.info("Injected user turn: %.100s...", message)

    # ── public ───────────────────────────────────────────────────────

    def get_user_agent_stats(self) -> dict[str, Any]:
        return self._sim_user.get_stats()
