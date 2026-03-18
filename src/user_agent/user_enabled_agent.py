"""Harness: Terminus2 with simulated user turn injection.

Integrates the UserAgent (LLM-powered user simulator) into the Terminus2
action loop. Every N action steps, the UserAgent observes the action agent's
trajectory and decides whether to inject a user message — simulating a real
human collaborator who watches the agent work and intervenes when needed.

This enables multi-turn evaluation: instead of giving the agent a single
instruction and letting it run to completion, we simulate the back-and-forth
of a real coding session where the user provides feedback, corrections,
and new requirements based on what the agent is doing.
"""

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from harbor.agents.terminus_2.terminus_2 import Terminus2, Command
from harbor.environments.base import BaseEnvironment
from harbor.llms.lite_llm import LiteLLM
from harbor.models.agent.context import AgentContext

from .user_agent import UserAgent, UserDecision, UserPersona

logger = logging.getLogger(__name__)


class UserEnabledTerminus2(Terminus2):
    """Terminus2 action agent with an LLM-powered simulated user.

    The simulated user monitors the action agent's trajectory and periodically
    decides whether to inject a user message — simulating a real human
    collaborator who watches the agent work and intervenes when needed.

    Data flow per episode:
        Agent LLM → parse commands → execute in terminal → get observation
          → call UserAgent every N steps
            → if wait:            prompt = observation (normal flow)
            → if question:        inject into chat, prompt = question
            → if redirect:        inject into chat, prompt = correction
            → if new_requirement: inject into chat, prompt = requirement
            → if check_external:  inject into chat, prompt = request
            → if interrupt:       inject "[interrupted]" + msg, prompt = msg
    """

    def __init__(
        self,
        logs_dir: Path,
        model_name: str,
        # Simulated user config
        user_model_name: str = "anthropic/claude-opus-4.5",
        user_api_base: str | None = None,
        user_api_key: str | None = None,
        user_temperature: float = 0.5,
        user_context_chars: int = 2000,
        original_user_messages: list[str] | None = None,
        user_persona: UserPersona | None = None,
        call_user_on_completion: bool = True,
        **kwargs,
    ):
        super().__init__(logs_dir=logs_dir, model_name=model_name, **kwargs)

        # Simulated user LLM
        self._user_llm = LiteLLM(
            model_name=user_model_name,
            api_base=user_api_base,
            api_key=user_api_key,
            temperature=user_temperature,
        )
        self._user_agent = UserAgent(
            llm=self._user_llm,
            original_user_messages=original_user_messages,
            persona=user_persona,
        )

        # Config
        self._user_context_chars = max(500, user_context_chars)
        self._call_user_on_completion = call_user_on_completion

        # State (reset per run)
        self._original_instruction: str = ""

    # ------------------------------------------------------------------
    # Trajectory context for simulated user
    # ------------------------------------------------------------------

    def _build_recent_trajectory(self) -> str:
        """Build a compact summary of recent trajectory steps within context budget.

        Fills backwards from the most recent step until user_context_chars is
        reached, so the user agent always sees the latest activity.
        """
        if not self._trajectory_steps:
            return "(no steps yet)"

        budget = self._user_context_chars
        parts: list[str] = []
        used = 0

        for step in reversed(self._trajectory_steps):
            step_id = getattr(step, "step_id", "?")
            source = getattr(step, "source", "?")
            msg = getattr(step, "message", "") or ""
            if len(msg) > 300:
                msg = msg[:300] + "..."

            obs_text = ""
            obs = getattr(step, "observation", None)
            if obs and hasattr(obs, "results") and obs.results:
                obs_text = getattr(obs.results[0], "content", "") or ""
                if len(obs_text) > 300:
                    obs_text = obs_text[:300] + "..."

            entry = f"[Step {step_id}] ({source}): {msg}"
            if obs_text:
                entry += f"\n  → Output: {obs_text}"

            if used + len(entry) > budget and parts:
                break
            parts.append(entry)
            used += len(entry) + 1  # +1 for newline

        parts.reverse()
        return "\n".join(parts)

    # ------------------------------------------------------------------
    # Simulated user invocation
    # ------------------------------------------------------------------

    async def _call_user_agent(
        self,
        observation: str,
        analysis: str | None,
        step_count: int,
        is_completion_attempt: bool,
    ) -> UserDecision:
        """Call the simulated user and return its decision."""
        decision = await self._user_agent.process(
            task_description=self._original_instruction,
            recent_trajectory=self._build_recent_trajectory(),
            latest_observation=observation[:self._user_context_chars],
            latest_analysis=analysis,
            step_count=step_count,
            is_completion_attempt=is_completion_attempt,
            total_steps_so_far=step_count,
        )

        if decision.has_message:
            self._user_agent.advance_original_index(1)
            logger.info(
                f"Simulated user intervenes at step {step_count}: "
                f"action={decision.action}"
            )
        else:
            logger.debug(f"Simulated user waits at step {step_count}")

        return decision

    # ------------------------------------------------------------------
    # Override: _run_agent_loop
    # ------------------------------------------------------------------

    async def _run_agent_loop(
        self,
        initial_prompt: str,
        chat,
        logging_dir: Path | None = None,
        original_instruction: str = "",
    ) -> int:
        """Override agent loop to integrate the simulated user.

        Changes vs base Terminus2:
        1. After each action step, calls simulated user to decide on intervention
        2. If simulated user sends a message, injects it into chat history as
           a user turn and overrides the next prompt
        """
        if self._context is None:
            raise RuntimeError("Agent context is not set.")
        if self._session is None:
            raise RuntimeError("Session is not set.")

        self._original_instruction = original_instruction or initial_prompt

        # Inform the action agent that a user may send messages
        _USER_NOTICE = (
            "\n\nNote: You are working with a human user who may send you "
            "additional messages, corrections, or new requirements during "
            "the task. If you receive a message from the user, read it "
            "carefully and adjust your approach accordingly."
        )
        initial_prompt = initial_prompt + _USER_NOTICE

        prompt = initial_prompt

        for episode in range(self._max_episodes):
            self._n_episodes = episode + 1

            if not await self._session.is_session_alive():
                logger.debug("Session has ended")
                return episode + 1

            # Check proactive summarization
            if original_instruction and self._enable_summarize:
                proactive_summary_result = await self._check_proactive_summarization(
                    chat, original_instruction, self._session
                )
                if proactive_summary_result:
                    handoff_prompt, subagent_refs = proactive_summary_result
                    self._pending_subagent_refs = subagent_refs
                    self._pending_handoff_prompt = handoff_prompt
                    prompt = handoff_prompt

            logging_paths = self._setup_episode_logging(logging_dir, episode)

            # Track tokens
            tokens_before_input = chat.total_input_tokens
            tokens_before_output = chat.total_output_tokens
            tokens_before_cache = chat.total_cache_tokens
            cost_before = chat.total_cost

            # Handle LLM interaction
            (
                commands,
                is_task_complete,
                feedback,
                analysis,
                plan,
                llm_response,
            ) = await self._handle_llm_interaction(
                chat, prompt, logging_paths, original_instruction, self._session
            )

            # Handle pending subagent refs (summarization)
            if self._pending_subagent_refs:
                from harbor.models.trajectories import Step, Observation, ObservationResult
                self._trajectory_steps.append(
                    Step(
                        step_id=len(self._trajectory_steps) + 1,
                        timestamp=datetime.now(timezone.utc).isoformat(),
                        source="system",
                        message="Performed context summarization.",
                        observation=Observation(
                            results=[
                                ObservationResult(
                                    subagent_trajectory_ref=self._pending_subagent_refs
                                )
                            ]
                        ),
                    )
                )
                self._pending_subagent_refs = None

            if self._pending_handoff_prompt:
                from harbor.models.trajectories import Step
                if self._linear_history:
                    self._split_trajectory_on_summarization(self._pending_handoff_prompt)
                else:
                    self._trajectory_steps.append(
                        Step(
                            step_id=len(self._trajectory_steps) + 1,
                            timestamp=datetime.now(timezone.utc).isoformat(),
                            source="user",
                            message=self._pending_handoff_prompt,
                        )
                    )
                self._pending_handoff_prompt = None

            # Build trajectory message
            if self._save_raw_content_in_trajectory:
                message_content = llm_response.content
            else:
                message_parts = []
                if analysis:
                    message_parts.append(f"Analysis: {analysis}")
                if plan:
                    message_parts.append(f"Plan: {plan}")
                message_content = "\n".join(message_parts) if message_parts else ""

            # Update context
            self._context.n_input_tokens = chat.total_input_tokens
            self._context.n_output_tokens = chat.total_output_tokens
            self._context.n_cache_tokens = chat.total_cache_tokens
            self._context.cost_usd = chat.total_cost if chat.total_cost > 0 else None

            # Handle parsing errors
            if feedback and "ERROR:" in feedback:
                prompt = (
                    f"Previous response had parsing errors:\n{feedback}\n\n"
                    f"Please fix these issues and provide a proper "
                    f"{self._get_error_response_type()}."
                )
                continue

            # Execute commands
            timeout_occurred, terminal_output = await self._execute_commands(
                commands, self._session
            )

            was_pending_completion = self._pending_completion

            # Build observation
            if is_task_complete:
                if self._pending_completion:
                    observation = terminal_output
                else:
                    self._pending_completion = True
                    observation = self._get_completion_confirmation_message(terminal_output)
            else:
                self._pending_completion = False
                if feedback and "WARNINGS:" in feedback:
                    observation = (
                        f"Previous response had warnings:\n{feedback}\n\n"
                        f"{self._limit_output_length(terminal_output)}"
                    )
                else:
                    observation = self._limit_output_length(terminal_output)

            # Check task completion
            if is_task_complete:
                if was_pending_completion:
                    logger.info(
                        f"Task complete. Simulated user stats: "
                        f"{self._user_agent.get_stats()}"
                    )
                    return episode + 1
                # First completion — before confirming, let simulated user check
                if self._call_user_on_completion:
                    decision = await self._call_user_agent(
                        observation=observation,
                        analysis=analysis,
                        step_count=episode + 1,
                        is_completion_attempt=True,
                    )
                    if decision.has_message:
                        user_msg = decision.format_for_injection()
                        self._inject_user_message(chat, user_msg)
                        prompt = user_msg
                        self._pending_completion = False
                        continue
                prompt = observation
                continue

            # === SIMULATED USER: called every turn ===
            decision = await self._call_user_agent(
                observation=observation,
                analysis=analysis,
                step_count=episode + 1,
                is_completion_attempt=False,
            )
            if decision.has_message:
                user_msg = decision.format_for_injection()
                self._inject_user_message(chat, user_msg)
                prompt = user_msg
                continue

            prompt = observation

        return self._n_episodes

    # ------------------------------------------------------------------
    # Message injection
    # ------------------------------------------------------------------

    def _inject_user_message(self, chat, message: str) -> None:
        """Inject a user message into the chat history."""
        chat.messages.append({"role": "user", "content": message})
        logger.info(f"Injected user message: {message[:100]}...")

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get_user_agent_stats(self) -> dict[str, Any]:
        """Get simulated-user statistics."""
        return self._user_agent.get_stats()
