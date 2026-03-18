"""LLM-powered user simulator for multi-turn coding evaluations.

Given a task's ground-truth user interaction (from analysis.json), this module
role-plays as that user: watching the action agent work and deciding when to
send messages — questions, corrections, or new requirements.

The simulator uses tool-calling to produce structured decisions, keeping the
interface clean for the harness that injects messages into the chat.
"""

import json
import logging
from dataclasses import dataclass, field

log = logging.getLogger(__name__)


# ── Persona ──────────────────────────────────────────────────────────────

@dataclass
class UserPersona:
    """Behavioral profile extracted from the original session's analysis.json.

    Controls how the LLM role-plays: tone, verbosity, characteristic phrases,
    and known friction points that trigger intervention.
    """

    tone: str = "informal"
    verbosity: str = "terse"
    example_phrases: list[str] = field(default_factory=list)
    known_triggers: list[str] = field(default_factory=list)

    def render(self) -> str:
        """Render as markdown for inclusion in the system prompt."""
        parts = [
            "## Your Persona",
            f"Tone: {self.tone}. Verbosity: {self.verbosity}.",
            "You frequently make typos and use informal spelling like a human.",
        ]
        if self.example_phrases:
            parts.append("\nPhrases you actually said:")
            parts.extend(f'  - "{p}"' for p in self.example_phrases)
        if self.known_triggers:
            parts.append("\nThings that make you step in:")
            parts.extend(f"  - {t}" for t in self.known_triggers)
        return "\n".join(parts)


def build_persona_from_analysis(analysis: dict) -> UserPersona:
    """Construct a persona from parsed analysis.json contents."""
    llm_info = analysis.get("llm_analysis", {})
    msgs = analysis.get("user_messages", [])
    friction = llm_info.get("key_friction_points", [])

    avg_len = sum(len(m) for m in msgs) / max(len(msgs), 1)
    verbosity = "terse" if avg_len < 60 else ("medium" if avg_len < 200 else "verbose")

    return UserPersona(
        tone="informal",
        verbosity=verbosity,
        example_phrases=[m for m in msgs if len(m) > 5],
        known_triggers=friction,
    )


# ── Tool schema ──────────────────────────────────────────────────────────

ACTIONS = [
    ("no-op", "Let the agent keep working. DEFAULT — use when the agent is "
     "doing routine work or making reasonable progress. Only step in "
     "when it matters.", {}),

    ("question", "Ask about what the agent is doing or its results. "
     "Examples: 'so what's dragging it down?', 'why didn't we assess them?', "
     "'what are the scores now?'. Probes reasoning or requests status.",
     {"content": ("string", "The question — natural, can be blunt or curious.")}),

    ("redirect", "The agent went wrong, made a mistake, or is about to waste "
     "effort. Correct its course. This includes cases where you'd stop the "
     "agent mid-action to change direction. "
     "Examples: 'wait, why didn't you launch one subagent for each one?', "
     "'no, check if everything is valid', 'Wait you test run the GRPO script yet?', "
     "'wait hold on sanity check, why so many errors?'. "
     "Usually starts with 'wait'/'no'/'stop'/'hold on'.",
     {"content": ("string", "Point out the problem and say what to do instead.")}),

    ("new_requirement", "Add scope, pivot, or move to next sub-task. "
     "Examples: 'can you improve the deploying multiple agents stuff', "
     "'let's also check if the lm_head warning is benign'. Iterative direction.",
     {"content": ("string", "The new requirement — 1 sentence or a few bullets.")}),

    ("check_external", "Ask the agent to check a PR, issue, deployment, etc. "
     "Examples: 'check the PR, we got 2 automated responses', "
     "'Is this fixed? https://github.com/.../issues/124'.",
     {"content": ("string", "What to check. May include URLs or names.")}),
]


def _build_tool_defs() -> list[dict]:
    """Convert compact ACTIONS table into OpenAI function-calling format."""
    tools = []
    for name, desc, params in ACTIONS:
        props = {}
        required = []
        for pname, (ptype, pdesc) in params.items():
            props[pname] = {"type": ptype, "description": pdesc}
            required.append(pname)
        tools.append({
            "type": "function",
            "function": {
                "name": name,
                "description": desc,
                "parameters": {
                    "type": "object",
                    "properties": props,
                    **({"required": required} if required else {}),
                },
            },
        })
    return tools


TOOL_DEFS = _build_tool_defs()


# ── Decision dataclass ───────────────────────────────────────────────────

@dataclass
class UserDecision:
    """What the simulated user decided to do this turn."""

    action: str  # no-op | question | redirect | new_requirement | check_external
    content: str = ""
    raw_response: str = ""

    @property
    def has_message(self) -> bool:
        return self.action != "no-op" and bool(self.content)

    def format_for_injection(self) -> str:
        return self.content


# ── System prompt ────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are role-playing as a human user collaborating with an AI coding agent.

You have:
1. **Your persona** (above) — who you are, how you talk, what sets you off.
2. **The task** — what you originally wanted done.
3. **Ground-truth messages** — the real user's interatctions from the recorded session.
4. **The agent's live trajectory** — what it's been doing right now.

## When to act

Your ground-truth messages show when and why you actually spoke up. Use them
as your primary guide for timing and content. Most turns you say nothing.

## How to write

- Match the persona's tone, vocabulary, and typo habits.
- Be direct — real users don't write paragraphs.
- Reference context naturally: "wait, why did you..." not "I observe that..."
"""


# ── UserAgent ────────────────────────────────────────────────────────────

class UserAgent:
    """Simulated user that watches an action agent and decides when to talk.

    Backed by an LLM with tool-calling. Each call produces exactly one
    UserDecision: wait (do nothing) or one of the message actions.
    """

    def __init__(self, llm, original_user_messages=None, persona=None):
        self._llm = llm
        self._ground_truth = original_user_messages or []
        self._persona = persona or UserPersona()
        self._cursor = 0  # index into _ground_truth

        self._sys = self._persona.render() + "\n\n" + _SYSTEM_PROMPT

        # counters
        self.total_calls = 0
        self.wait_count = 0
        self.message_count = 0
        self._counts: dict[str, int] = {}

    # ── public ──

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
        self.total_calls += 1

        prompt = self._compose_prompt(
            task_description, recent_trajectory, latest_observation,
            latest_analysis, step_count, is_completion_attempt,
            total_steps_so_far,
        )

        try:
            resp = await self._llm.call(
                prompt=prompt, system=self._sys, tools=TOOL_DEFS,
            )
            decision = self._extract_decision(resp)
        except Exception as exc:
            log.warning("UserAgent call failed: %s", exc)
            decision = UserDecision(action="no-op", raw_response=f"error: {exc}")

        self._counts[decision.action] = self._counts.get(decision.action, 0) + 1
        if decision.action == "no-op":
            self.wait_count += 1
        elif decision.has_message:
            self.message_count += 1

        return decision

    def advance_original_index(self, n: int = 1):
        self._cursor = min(self._cursor + n, len(self._ground_truth))

    def get_stats(self) -> dict:
        return {
            "total_calls": self.total_calls,
            "wait_count": self.wait_count,
            "message_count": self.message_count,
            "action_breakdown": dict(self._counts),
            "ground_truth_total": len(self._ground_truth),
            "ground_truth_consumed": self._cursor,
        }

    # ── prompt building ──

    def _compose_prompt(
        self, task, trajectory, observation, analysis,
        step, is_completion, total_steps,
    ) -> str:
        sections = [f"## Task\n{task[:400]}"]
        sections.append(f"\n## Turn {step} (total: {total_steps})")

        if is_completion:
            sections.append(
                "\n** The agent wants to finish. Check whether all your "
                "original requirements have been addressed."
            )

        sections.append(f"\n## What the agent has been doing\n{trajectory}")
        sections.append(f"\n## Latest output\n{observation}")

        if analysis:
            sections.append(f"\n## Agent's thinking\n{analysis[:300]}")

        upcoming = self._peek_ground_truth(5)
        if upcoming:
            sections.append(
                "\n## Reference: what you actually said (ground truth)\n"
                "Adapt these to the current situation — don't copy verbatim."
            )
            for idx, msg in upcoming:
                sections.append(f"  [{idx + 1}] {msg}")

        sections.append(
            f"\n## Stats: {self.total_calls} calls, "
            f"{self.message_count} messages sent, "
            f"{len(self._ground_truth) - self._cursor} ground-truth remaining"
        )
        sections.append(
            "\nPick ONE tool. `wait` unless you'd genuinely step in here."
        )
        return "\n".join(sections)

    def _peek_ground_truth(self, n: int) -> list[tuple[int, str]]:
        end = min(self._cursor + n, len(self._ground_truth))
        return [
            (i, self._ground_truth[i][:500])
            for i in range(self._cursor, end)
        ]

    # ── response parsing ──

    def _extract_decision(self, response) -> UserDecision:
        raw = response.content or ""
        calls = getattr(response, "tool_calls", None)
        if not calls:
            return self._fallback_parse(raw)

        tc = calls[0]
        fn = tc.get("function", {})
        name = fn.get("name", "wait")
        raw_args = fn.get("arguments", "{}")
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
        except json.JSONDecodeError:
            args = {}

        return UserDecision(
            action=name,
            content=args.get("content", ""),
            raw_response=raw,
        )

    @staticmethod
    def _fallback_parse(text: str) -> UserDecision:
        low = text.lower()
        if any(kw in low for kw in ("wait", "continue", "let it")):
            return UserDecision(action="wait", raw_response="fallback")
        if text.strip():
            return UserDecision(
                action="question", content=text,
                raw_response=text,
            )
        return UserDecision(action="wait", raw_response="empty")
