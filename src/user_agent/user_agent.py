"""Simulated User Agent: LLM-powered human user simulator for multi-turn eval.

For each task in the multi-user-turn-codebench benchmark, we have a recording
of the real user's interaction (from analysis.json / analysis.md). This agent
uses an LLM to role-play as that user: it monitors the action agent's live
trajectory and decides when and how to intervene.
"""

import json
import logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# User persona (injected into system prompt per task)
# ---------------------------------------------------------------------------

@dataclass
class UserPersona:
    """Profile of the real user, extracted from analysis.json at task load time.

    Passed to the UserAgent at init so the LLM can role-play accurately.
    """
    # Communication style (derived from original messages)
    tone: str = "informal"                # informal / formal / mixed
    verbosity: str = "terse"              # terse / medium / verbose
    uses_typos: bool = False              # observed typos in original messages
    example_phrases: list[str] = field(default_factory=list)  # characteristic phrases

    # What triggers this user (from friction points)
    known_triggers: list[str] = field(default_factory=list)

    def to_prompt_section(self) -> str:
        """Render persona as a prompt section for the system prompt."""
        lines = ["## User Persona\n"]

        lines.append(f"Communication style: {self.tone}, {self.verbosity}.")
        if self.uses_typos:
            lines.append("You often have typos and informal spelling.")

        if self.example_phrases:
            lines.append("\nCharacteristic phrases from your real messages:")
            for phrase in self.example_phrases[:8]:
                lines.append(f'  - "{phrase}"')

        if self.known_triggers:
            lines.append("\nThings that specifically trigger you to intervene:")
            for trigger in self.known_triggers:
                lines.append(f"  - {trigger}")

        return "\n".join(lines)


def build_persona_from_analysis(analysis: dict) -> UserPersona:
    """Build a UserPersona from an analysis.json dict.

    Args:
        analysis: Parsed contents of a task's analysis.json file.
    """
    llm_analysis = analysis.get("llm_analysis", {})
    user_messages = analysis.get("user_messages", [])
    req_changes = llm_analysis.get("requirement_changes", {})
    friction = llm_analysis.get("key_friction_points", [])

    # Detect tone from messages
    has_typos = any(
        w in " ".join(user_messages).lower()
        for w in ["pleease", "instantl", "sould", "duplcation", "wontfixed",
                   "imrpove", "scorign"]
    )

    # Detect verbosity
    avg_len = (sum(len(m) for m in user_messages) / len(user_messages)
               if user_messages else 50)
    verbosity = "terse" if avg_len < 60 else "medium" if avg_len < 200 else "verbose"

    # Extract characteristic short phrases
    short_msgs = [m for m in user_messages if 5 < len(m) < 100][:8]

    return UserPersona(
        tone="informal" if has_typos else "mixed",
        verbosity=verbosity,
        uses_typos=has_typos,
        example_phrases=short_msgs,
        known_triggers=[fp[:150] for fp in friction[:5]],
    )


# ---------------------------------------------------------------------------
# Tool definitions — derived from real user message patterns
# ---------------------------------------------------------------------------

USER_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "wait",
            "description": (
                "Let the agent keep working. This is the DEFAULT — use it when "
                "the agent is doing routine work (installing, reading, testing) "
                "or making reasonable progress. Real users don't micromanage."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "question",
            "description": (
                "Ask the agent a question about what it's doing or its results. "
                "Real users ask things like: 'so what's dragging it down?', "
                "'why didn't we assess them?', 'what are the scores now?', "
                "'does this work for GRPO too?', 'wait why do we need a notebook?'. "
                "Questions probe the agent's reasoning or request status updates."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": (
                            "The question to ask. Write naturally — can be blunt, "
                            "skeptical, or curious. Often starts with 'why', 'what', "
                            "'how', 'does', 'is', 'can'."
                        ),
                    },
                },
                "required": ["content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "redirect",
            "description": (
                "The agent is going in the wrong direction or made a mistake. "
                "Correct it. Real examples: "
                "'wait, why didn't you launch one subagent for each one?', "
                "'no, check if everything is valid about it i mean', "
                "'wait hold on sanity check, why so many errors?', "
                "'that's a mistake, yeah fix, and then revert those scores'. "
                "Often starts with 'wait', 'no', 'stop', 'hold on'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": (
                            "The correction/redirect. Be direct like a real user — "
                            "point out the problem and say what to do instead."
                        ),
                    },
                },
                "required": ["content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "new_requirement",
            "description": (
                "Add a new requirement, expand scope, or pivot to the next sub-task. "
                "Real examples: "
                "'can you improve the stuff you mentioned re: deploying multiple agents', "
                "'let's also check if the lm_head.weight warning is actually benign', "
                "'can you see the other issues too, comment and close or fix', "
                "'Standardise them, remove this file_level abstraction'. "
                "This is how users iteratively direct long sessions."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": (
                            "The new requirement or direction. Can be a single "
                            "sentence or a few bullet points. Write as the user would."
                        ),
                    },
                },
                "required": ["content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_external",
            "description": (
                "Ask the agent to check something external — a PR, issue, comment, "
                "deployment, or other system the user is watching in parallel. "
                "Real examples: "
                "'check the PR, we got 2 automated responses from AI coding agents', "
                "'Check out Datta0's latest comments, just confirm dont code yet', "
                "'Is this fixed? https://github.com/.../issues/124', "
                "'Update on PR, please check latest comment'. "
                "This is common when users monitor GitHub/CI alongside the agent."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": (
                            "What to check and how to respond. Often includes "
                            "'check', 'look at', 'see if'. May include URLs, "
                            "issue numbers, or person names."
                        ),
                    },
                },
                "required": ["content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "interrupt",
            "description": (
                "Hard interrupt — stop the agent mid-action because it's about to "
                "waste significant effort or do something harmful. Use SPARINGLY. "
                "Real examples: user interrupted before agent published an untested "
                "script, or interrupted to prevent posting an un-reviewed PR comment. "
                "This maps to '[Request interrupted by user for tool use]' in the "
                "original sessions."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": (
                            "What to do instead after the interrupt. "
                            "Example: 'Wait you test run the GRPO script yet?'"
                        ),
                    },
                    "trigger_reason": {
                        "type": "string",
                        "description": "Why interruption is needed (for logging)",
                    },
                },
                "required": ["content", "trigger_reason"],
            },
        },
    },
]


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class UserDecision:
    """Result of a simulated-user invocation."""
    action: str  # wait, question, redirect, new_requirement, check_external, interrupt
    content: str = ""
    trigger_reason: str = ""
    raw_response: str = ""

    @property
    def has_message(self) -> bool:
        return self.action != "wait" and bool(self.content)

    def format_for_injection(self) -> str:
        """Format the user message for injection into the chat."""
        if self.action == "interrupt":
            return f"[Request interrupted by user for tool use]\n{self.content}"
        return self.content


@dataclass
class OriginalUserTurn:
    """A user message from the original session with context."""
    index: int
    content: str


# ---------------------------------------------------------------------------
# System prompt (base — persona section is prepended per task)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT_BASE = """\
You are simulating a human user who is collaborating with an AI coding agent \
on a software engineering task.

You have access to:
1. **Your persona** — who you are, your style, your triggers (see above).
2. **The task description** — what you originally wanted.
3. **The original user messages** — the real interventions from the ground-truth \
session. These show your personality, priorities, and intervention patterns.
4. **The action agent's trajectory** — what the agent has been doing right now.

## Timing Rules

- **Wait during routine work**: installs, file reads, test runs, standard debugging
- **Intervene at milestones**: after the agent shows results, completes a sub-task, \
or is about to take a significant action (posting, pushing, publishing)
- **Intervene on mistakes**: when the agent does something you'd notice is wrong
- **Add requirements naturally**: when a sub-task finishes and the session should \
progress to the next thing the original user cared about
- **Pace yourself**: the original user sent ~1 message per 10-50 agent turns. \
Don't intervene every time you're called.

## Message Style

Write as the user, not as an AI:
- Match their tone, vocabulary, and typo patterns from the persona
- Be direct — real users don't write paragraphs
- Reference context naturally: "wait, why did you..." not "I observe that..."
- Can be a single word ("continue") or a compound instruction with context
"""


# ---------------------------------------------------------------------------
# UserAgent
# ---------------------------------------------------------------------------

class UserAgent:
    """LLM-powered simulated user for multi-turn evaluation.

    Uses tool-calling to produce structured decisions. Fed with:
    - A UserPersona (from analysis.json) for style/behavior matching
    - Ground-truth user messages as reference for content and timing
    """

    def __init__(
        self,
        llm,
        original_user_messages: list[str] | None = None,
        persona: UserPersona | None = None,
    ):
        """
        Args:
            llm: A LiteLLM (or compatible) instance.
            original_user_messages: Ground-truth user messages from
                analysis.json["user_messages"].
            persona: User persona built from analysis.json. If None,
                a default persona is used.
        """
        self._llm = llm
        self._original_messages = original_user_messages or []
        self._persona = persona or UserPersona()
        self._next_original_idx = 0

        # Build system prompt with persona
        self._system_prompt = self._build_system_prompt()

        # Stats
        self.total_calls = 0
        self.wait_count = 0
        self.message_count = 0
        self.interrupt_count = 0
        self._action_counts: dict[str, int] = {}

    def _build_system_prompt(self) -> str:
        """Build system prompt with persona section prepended."""
        persona_section = self._persona.to_prompt_section()
        return persona_section + "\n\n" + SYSTEM_PROMPT_BASE

    async def process(
        self,
        task_description: str,
        recent_trajectory: str,
        latest_observation: str,
        latest_analysis: str | None,
        step_count: int,
        is_completion_attempt: bool,
        total_steps_so_far: int = 0,
    ) -> UserDecision:
        """Decide whether and how to intervene as the user."""
        self.total_calls += 1

        prompt = self._build_prompt(
            task_description=task_description,
            recent_trajectory=recent_trajectory,
            latest_observation=latest_observation,
            latest_analysis=latest_analysis,
            step_count=step_count,
            is_completion_attempt=is_completion_attempt,
            total_steps_so_far=total_steps_so_far,
        )

        try:
            response = await self._llm.call(
                prompt=prompt,
                system=self._system_prompt,
                tools=USER_TOOLS,
            )
            decision = self._parse_response(response)
        except Exception as e:
            logger.warning(f"UserAgent LLM call failed: {e}")
            decision = UserDecision(action="wait", trigger_reason=f"LLM error: {e}")

        # Update stats
        self._action_counts[decision.action] = (
            self._action_counts.get(decision.action, 0) + 1
        )
        if decision.action == "wait":
            self.wait_count += 1
        elif decision.action == "interrupt":
            self.interrupt_count += 1
        elif decision.has_message:
            self.message_count += 1

        return decision

    def _build_prompt(
        self,
        task_description: str,
        recent_trajectory: str,
        latest_observation: str,
        latest_analysis: str | None,
        step_count: int,
        is_completion_attempt: bool,
        total_steps_so_far: int,
    ) -> str:
        """Build the user prompt for the LLM.

        Trajectory and observation are already truncated by the harness
        to fit user_context_chars before being passed here.
        """
        task_desc = task_description[:400]
        analysis = (latest_analysis[:300] if latest_analysis and len(latest_analysis) > 300
                     else latest_analysis or "(none)")

        upcoming_msgs = self._get_upcoming_original_messages(n=5)

        parts = [
            f"## Task\n{task_desc}",
            f"\n## Step {step_count} (total steps so far: {total_steps_so_far})",
        ]

        if is_completion_attempt:
            parts.append(
                "\n⚠️ COMPLETION ATTEMPT: The agent is trying to mark the task as done. "
                "Consider whether all the original user's requirements have been met."
            )

        parts.append(f"\n## Recent Agent Steps\n{recent_trajectory}")
        parts.append(f"\n## Latest Terminal Output\n{latest_observation}")
        parts.append(f"\n## Agent's Reasoning\n{analysis}")

        if upcoming_msgs:
            parts.append(
                "\n## Original User Messages (reference)\n"
                "These are the REAL user's next interventions from the ground-truth "
                "session. Use them as guidance for tone, timing, and content — but "
                "adapt to what the current agent is actually doing.\n"
            )
            for msg in upcoming_msgs:
                parts.append(f"### Original Message {msg.index + 1}\n```\n{msg.content}\n```")

        # Stats context
        parts.append(
            f"\n## Your Stats So Far\n"
            f"Calls: {self.total_calls}, Messages sent: {self.message_count}, "
            f"Original messages remaining: "
            f"{len(self._original_messages) - self._next_original_idx}"
        )

        parts.append(
            "\n## Decision\n"
            "Call ONE tool. `wait` is the default. Only intervene if the user "
            "would genuinely step in at this point."
        )

        return "\n".join(parts)

    def _get_upcoming_original_messages(self, n: int = 5) -> list[OriginalUserTurn]:
        """Get the next N original user messages as reference."""
        result = []
        for i in range(self._next_original_idx,
                       min(self._next_original_idx + n, len(self._original_messages))):
            msg = self._original_messages[i]
            result.append(OriginalUserTurn(index=i, content=msg[:500]))
        return result

    def advance_original_index(self, n: int = 1) -> None:
        """Advance the original message pointer after a message is used."""
        self._next_original_idx = min(
            self._next_original_idx + n,
            len(self._original_messages),
        )

    def _parse_response(self, response) -> UserDecision:
        """Parse the LLM response into a UserDecision."""
        raw = response.content or ""

        tool_calls = getattr(response, "tool_calls", None)
        if not tool_calls:
            return self._parse_from_content(raw)

        tool_call = tool_calls[0]
        fn_name = tool_call.get("function", {}).get("name", "wait")
        args_str = tool_call.get("function", {}).get("arguments", "{}")

        try:
            args = json.loads(args_str) if isinstance(args_str, str) else args_str
        except json.JSONDecodeError:
            args = {}

        if fn_name == "wait":
            return UserDecision(
                action="wait",
                trigger_reason=args.get("reason", ""),
                raw_response=raw,
            )

        # All non-wait tools have content + optional trigger_reason
        return UserDecision(
            action=fn_name,
            content=args.get("content", ""),
            trigger_reason=args.get("trigger_reason", ""),
            raw_response=raw,
        )

    def _parse_from_content(self, content: str) -> UserDecision:
        """Fallback: try to extract decision from raw text content."""
        lower = content.lower()
        if any(w in lower for w in ["wait", "continue", "let it"]):
            return UserDecision(action="wait", trigger_reason="fallback to wait")
        if content.strip():
            return UserDecision(
                action="question",
                content=content,
                trigger_reason="parsed from raw content",
                raw_response=content,
            )
        return UserDecision(action="wait", trigger_reason="empty response")

    def get_stats(self) -> dict:
        return {
            "total_calls": self.total_calls,
            "wait_count": self.wait_count,
            "message_count": self.message_count,
            "interrupt_count": self.interrupt_count,
            "action_breakdown": dict(self._action_counts),
            "original_messages_total": len(self._original_messages),
            "original_messages_consumed": self._next_original_idx,
        }
