"""LLM-powered user simulator for multi-turn coding evaluations.

Role-plays as the original user: watching the action agent work and deciding
when to send messages — questions, corrections, or new requirements.

Uses conversation history (accumulated across turns) so the LLM can see what
it already said. Uses tool-calling for structured decisions.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field

from .turn_end import TurnEnd

log = logging.getLogger(__name__)


# ── Persona ──────────────────────────────────────────────────────────────

@dataclass
class UserPersona:
    """Behavioral profile for the simulated user.

    Controls how the LLM role-plays: tone, verbosity, and known friction
    points that trigger intervention. Does NOT include example_phrases
    (those leaked ground-truth messages and caused repetition).
    """

    tone: str = "informal"
    verbosity: str = "terse"
    known_triggers: list[str] = field(default_factory=list)

    def render(self) -> str:
        """Render as markdown for inclusion in the system prompt."""
        parts = [
            "## Your Persona",
            f"Tone: {self.tone}. Verbosity: {self.verbosity}.",
            "You frequently make typos and use informal spelling like a human.",
        ]
        if self.known_triggers:
            parts.append("\nThings that make you step in:")
            parts.extend(f"  - {t}" for t in self.known_triggers)
        return "\n".join(parts)


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

    action: str  # no-op | question | redirect | new_requirement | check_external | message (text fallback, kind unknown)
    content: str = ""
    raw_response: str = ""

    _NO_OP_MARKERS = {
        "[silent — no-op]", "[no-op]", "[silent]", "no-op", "silent",
        "(i stayed silent and let the agent keep working.)",
        "i stayed silent and let the agent keep working.",
    }

    @property
    def has_message(self) -> bool:
        stripped = self.content.strip() if self.content else ""
        return (self.action != "no-op"
                and bool(stripped)
                and stripped.lower() not in self._NO_OP_MARKERS)

    def format_for_injection(self) -> str:
        return self.content

    # Prefixes that indicate internal/error state, not real model reasoning
    _INTERNAL_PREFIXES = ("error:", "fallback_noop:", "noop_guard:", "hard_cap_reached", "asked_still_silent:")

    def format_for_history(self) -> str:
        """Format the full decision for conversation history.

        Preserves the model's reasoning (raw_response) alongside the structured
        decision, so on subsequent turns the model can see *why* it made each
        prior choice — not just what it said.
        """
        parts: list[str] = []

        # Include reasoning if it's genuine model output (not internal markers)
        reasoning = self.raw_response.strip() if self.raw_response else ""
        if reasoning and not any(reasoning.startswith(p) for p in self._INTERNAL_PREFIXES):
            # Avoid duplicating content that's identical to the message
            if reasoning != self.content.strip():
                parts.append(reasoning)

        # Append the structured decision
        if self.has_message:
            parts.append(f"→ {self.action}: {self.content}")
        else:
            parts.append("→ no-op (silent)")

        return "\n\n".join(parts)


# ── System prompt ────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are role-playing as a human user collaborating with an AI coding agent.

You have:
1. **Your persona** — who you are, how you talk, what sets you off.
2. **Session analysis** — when you spoke in the original session, why, and what
   triggered each intervention.
3. **Conversation history** — you can see everything you and the agent have said
   so far. Use this to avoid repeating yourself.

## When to act

Default to no-op. Real users give instructions once, then go silent for
many turns while the agent works. You see what a user at the terminal sees:
the agent's report, the commands it ran and what they printed, and the diff.
Judge the report against that evidence — a claim like "all tests pass" is
only as good as the test output you can see. Only speak when:
- The session analysis describes a trigger that matches the current situation
- The agent is clearly stuck in a loop or going down the wrong path
- The agent presents its work as finished but missed requirements
  (decide from its report whether it is claiming to be done or pausing
  between steps — nobody tells you which)

The one exception to the no-op default: when the agent asks you something
(a decision, a value, permission, access, a file), answer it. "No", "can't
give you that, do X instead" and "just pick one" are all answers; silence
is not — a user who ignores a direct question ends the session. Your turn
summary says when the report ends in a question.

There is no number of messages to reach. The original user's messages are
context for what you care about and how you talk; do not send one because
the original user sent one at this point. If the agent is doing fine, stay
silent for the whole session.

NEVER repeat something you already said — check the conversation history.
If you've run out of things to say, choose no-op for every remaining turn.

## How to write

Your output IS the message the agent sees. Do NOT think out loud or analyze.

WRONG: "Looking at the session analysis, the agent has been spinning..."
RIGHT: "wait why haven't you started coding yet"

Rules:
- 1-2 sentences max. Casual language: "wait", "no", "hmm", "can you also..."
- Make typos occasionally. Don't be polished.
- NEVER mention "session analysis", "ground truth", or "turns/calls".
- The `content` parameter must be plain text only.
"""


#: Second ask when the agent's report ended in a question and the simulator
#: chose silence. Not a quota and not a script: it names the one fact the
#: harness knows and leaves the content of the answer to the simulator.
_ASKED_RETRY_NOTE = (
    "The agent's report above ends by asking you for something, and you chose to say "
    "nothing. A user who is asked a direct question answers it, even if the answer is "
    "no, or that what it asks for is not available and it should proceed differently. "
    "Answer the agent now with one of the message tools; choose no-op only if the "
    "question was already answered earlier in this conversation."
)


# ── UserAgent ───────────────────────────────────────────────────────────────────────

def _supports_forced_tool_choice(model_name: str | None) -> bool:
    if not model_name:
        return True
    try:
        import llm_config
    except ImportError:  # the sim can run outside the repo's src path
        return True
    spec = llm_config.spec_for(model_name)
    return spec.supports_forced_tool_choice if spec else True


class UserAgent:
    """Simulated user that watches an action agent and decides when to talk.

    Maintains conversation history across turns (like tau-bench) so the LLM
    can see what it already said. Each call produces exactly one UserDecision.
    """

    # 0.12.0 (2026-10-13): no message quota — the prompt no longer states a count
    # or asks for ground-truth messages in order; recorded per trial in
    # user_decision.json → stats.version so cohorts can be told apart.
    # 0.13.0 (2026-10-14): the simulator sees the terminal — commands with their
    # output, files touched, tool errors (user_agent.turn_view) — instead of tool
    # names only.
    # 0.14.0 (2026-10-14): the prompt no longer asserts "the agent is signaling
    # completion" on every turn; it states what the harness knows (stop reason,
    # waiting) and leaves done/pausing/blocked/asking to the simulator.
    # 0.15.0 (2026-10-21): the harness states when the report ends by asking the
    # user something (TurnEnd.asks_user); the system prompt makes answering the
    # one exception to the no-op default; a silent answer to a question is asked
    # once more. Pilot of 0.14.0 showed the simulator answering 44% of the agent's
    # requests (64% before) and 13/218 sessions ending while the agent was asking.
    # 0.15.1 (2026-10-21): text-fallback parsing accepts the label shapes seen
    # from Claude under tool_choice=auto (**bold**, [bracketed], dash separators)
    # and no longer guesses `redirect` for unlabelled text; the ground-truth
    # cursor, unused since 0.12.0, is gone from the per-turn record.
    VERSION = "0.15.1"

    def __init__(self, llm, original_user_messages=None, persona=None,
                 session_analysis="", max_messages=None, force_tool_choice=None):
        self._llm = llm
        self._ground_truth = original_user_messages or []
        self._persona = persona or UserPersona()
        self.max_messages = max_messages  # hard cap (None = no cap)
        # `tool_choice=required` is the cleanest way to get exactly one decision; the
        # Claude 5.5 endpoints reject it, so those run with `auto` and the prompt
        # carries the "call exactly one tool" instruction instead. Derived from the
        # registry entry of the sim model unless the caller decides explicitly.
        if force_tool_choice is None:
            force_tool_choice = _supports_forced_tool_choice(getattr(llm, "_model_name", None))
        self._tool_choice = "required" if force_tool_choice else "auto"

        parts = [self._persona.render()]
        if session_analysis:
            parts.append(f"\n## Session Analysis\n{session_analysis}")
        parts.append(f"\n{_SYSTEM_PROMPT}")
        self._sys = "\n".join(parts)

        # Conversation history — accumulated across turns (tau-bench pattern)
        self._messages: list[dict[str, str]] = []

        # counters
        self.total_calls = 0
        self.wait_count = 0
        self.message_count = 0
        self.asked_retry_count = 0
        self._counts: dict[str, int] = {}

        # exact prompt sent on the most recent process() call (for logging)
        self.last_turn_content: str = ""
        self.last_messages_sent: list[dict[str, str]] = []

    # ── public ──

    async def process(
        self,
        task_description: str,
        recent_trajectory: str,
        latest_observation: str,
        latest_analysis: str | None,
        step_count: int,
        turn_end: "TurnEnd | bool | None" = None,
        total_steps_so_far: int = 0,
        elapsed_sec: float = 0.0,
        turn_duration_sec: float = 0.0,
        code_changes_diff: str = "",
    ) -> UserDecision:
        self.total_calls += 1

        # Hard cap — never trust the LLM to count
        if self.max_messages and self.message_count >= self.max_messages:
            decision = UserDecision(action="no-op", raw_response="hard_cap_reached")
            self.wait_count += 1
            self._counts["no-op"] = self._counts.get("no-op", 0) + 1
            return decision

        # Build turn summary — passed as prompt (not pre-appended) so
        # LiteLLM doesn't create an empty trailing user message that
        # triggers Anthropic's "cache_control on empty text" error.
        # Legacy callers passed a bool meaning "the agent is signalling completion";
        # that was always True in practice. It is now a TurnEnd describing only what
        # the harness knows (stop reason, whether there was a report).
        if not isinstance(turn_end, TurnEnd):
            turn_end = TurnEnd()
        turn_content = self._build_turn_summary(
            task_description, recent_trajectory, latest_observation,
            latest_analysis, step_count, turn_end,
            elapsed_sec, turn_duration_sec, code_changes_diff,
        )

        # Prepend system message in-band (as a "system" role message) so
        # litellm/Anthropic handlers extract it properly.  Passing system= as
        # a kwarg gets silently dropped by drop_params when it's not in the
        # provider's supported params list.
        history_with_sys = [{"role": "system", "content": self._sys}] + self._messages

        # Stash the EXACT prompt sent to the user-sim LLM this turn so the
        # wrapper can persist it (episode-N/user_sim_prompt.json). The runtime
        # prompt is otherwise never logged — downstream tools (the trajectory
        # visualizer, debugging) had to reconstruct it by replaying the parse.
        # `turn_content` is the final user message; `messages` is the full array.
        self.last_turn_content = turn_content
        self.last_messages_sent = history_with_sys + [
            {"role": "user", "content": turn_content}
        ]

        try:
            resp = await self._llm.call(
                prompt=turn_content,
                message_history=history_with_sys,
                tools=TOOL_DEFS,
                tool_choice=self._tool_choice,
            )
            decision = self._extract_decision(resp)

            # If the model returned text despite being asked for a tool call,
            # retry once with an explicit instruction (some providers ignore
            # tool_choice; the `auto` path relies on the prompt alone).
            if decision.raw_response.startswith("fallback_noop:"):
                log.info("UserAgent: no tool call returned (tool_choice=%s), retrying", self._tool_choice)
                resp = await self._llm.call(
                    prompt=turn_content + "\n\nYou MUST call one of the provided tools.",
                    message_history=history_with_sys,
                    tools=TOOL_DEFS,
                )
                decision = self._extract_decision(resp)

            # The agent asked the user something and the simulator chose silence.
            # Ask once more, naming the fact: a human who is asked a direct
            # question answers it (even with "no"), and silence here ends the
            # session. The second answer stands whatever it is.
            if turn_end.asks_user and not decision.has_message:
                log.info("UserAgent: agent asked, simulator silent — one retry")
                self.asked_retry_count += 1
                resp = await self._llm.call(
                    prompt=turn_content + "\n\n" + _ASKED_RETRY_NOTE,
                    message_history=history_with_sys,
                    tools=TOOL_DEFS,
                    tool_choice=self._tool_choice,
                )
                retry = self._extract_decision(resp)
                if retry.has_message:
                    decision = retry
                else:
                    decision = UserDecision(action="no-op", raw_response=f"asked_still_silent:{retry.raw_response[:160]}")
        except Exception as exc:
            log.warning("UserAgent call failed: %s", exc)
            decision = UserDecision(action="no-op", raw_response=f"error: {exc}")

        # Append this turn's user message + sim response to history for continuity.
        # Store the full response (reasoning + decision) so the model can see
        # its own prior thought process on subsequent turns.
        self._messages.append({"role": "user", "content": turn_content})
        self._messages.append({"role": "assistant", "content": decision.format_for_history()})
        if decision.has_message:
            self.message_count += 1
        else:
            self.wait_count += 1

        self._counts[decision.action] = self._counts.get(decision.action, 0) + 1
        return decision

    def get_stats(self) -> dict:
        return {
            "version": self.VERSION,
            "total_calls": self.total_calls,
            "wait_count": self.wait_count,
            "message_count": self.message_count,
            "asked_retry_count": self.asked_retry_count,
            "action_breakdown": dict(self._counts),
            "ground_truth_total": len(self._ground_truth),
            "max_messages": self.max_messages,
        }

    # ── prompt building ──

    @staticmethod
    def _format_duration(seconds: float) -> str:
        """Format seconds into human-readable duration like '2min 30s' or '1h 15min'."""
        if seconds < 60:
            return f"{seconds:.0f}s"
        minutes = seconds / 60
        if minutes < 60:
            return f"{minutes:.0f}min {seconds % 60:.0f}s"
        hours = int(minutes // 60)
        remaining_min = int(minutes % 60)
        return f"{hours}h {remaining_min}min"

    def _build_turn_summary(
        self, task, trajectory, observation, analysis,
        step, turn_end: TurnEnd,
        elapsed_sec=0.0, turn_duration_sec=0.0,
        code_changes_diff: str = "",
    ) -> str:
        sections = [f"## Turn {step}"]

        # Timing context so the LLM can match time-based triggers
        if elapsed_sec > 0:
            timing_parts = [f"Elapsed: {self._format_duration(elapsed_sec)}"]
            if turn_duration_sec > 0:
                timing_parts.append(f"this turn took {self._format_duration(turn_duration_sec)}")
            sections.append(f"**Timing:** {', '.join(timing_parts)}")

        sections.append(f"**Where the agent stopped:** {turn_end.describe(step)}")

        if self.total_calls == 1:
            # First call — include the (near-)full task description. The old
            # 400-char cap hid the requirements for 62% of tasks (median ~1200),
            # making the "agent tried to finish but missed requirements" trigger
            # unjudgeable. Shown once on turn 1; history carries it forward.
            # A generous 16K safety cap (≈ p95 of instruction length) only
            # guards the long tail — a handful of tasks run 80K–440K chars and
            # would otherwise blow up every cached turn.
            sections.append(f"\n## Task\n{task[:16000]}")

        sections.append(
            f"\n## What you saw in the terminal (this turn)\n"
            f"Commands the agent ran with their output, files it touched, tool errors, "
            f"and its intermediate remarks — check its report below against this.\n{trajectory}"
        )
        sections.append(f"\n## Agent's report to you\n{observation}")

        # Per-turn incremental git diff — what actually changed on disk this
        # turn (vs end of prior turn). This is the sim's independent channel
        # to verify the agent's self-narration. Not truncated by design: the
        # consumer (UserEnabledClaudeCode._capture_git_diff) already produces
        # a per-turn delta, so even a busy turn rarely exceeds a few KB.
        if code_changes_diff:
            sections.append(
                f"\n## Code changes (this turn)\n```diff\n{code_changes_diff}\n```"
            )

        if analysis:
            sections.append(f"\n## Agent's thinking\n{analysis[:300]}")

        sections.append(
            "\nRespond by calling exactly ONE of the provided tools (no prose). "
            "Default to no-op unless you have a clear, new reason to speak."
        )
        return "\n".join(sections)

    # ── response parsing ──

    def _extract_decision(self, response) -> UserDecision:
        raw = response.content or ""
        calls = getattr(response, "tool_calls", None)
        if not calls:
            return self._fallback_parse(raw)

        tc = calls[0]
        # litellm returns ChatCompletionMessageToolCall objects or dicts
        if hasattr(tc, "function"):
            fn = tc.function
            name = getattr(fn, "name", "wait") if hasattr(fn, "name") else fn.get("name", "wait")
            raw_args = getattr(fn, "arguments", "{}") if hasattr(fn, "arguments") else fn.get("arguments", "{}")
        else:
            fn = tc.get("function", {})
            name = fn.get("name", "wait")
            raw_args = fn.get("arguments", "{}")

        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
        except json.JSONDecodeError:
            args = {}

        content = args.get("content", "")

        # Guard: LLM sometimes calls a message tool (question/redirect) but
        # puts a no-op marker as the content — catch and convert to no-op.
        _NOOP_MARKERS = ("silent", "no-op", "no op", "stayed silent", "let the agent")
        if name != "no-op" and content and any(m in content.lower() for m in _NOOP_MARKERS):
            log.info("UserAgent: converting %s(%r) to no-op (content looks like no-op)", name, content[:60])
            return UserDecision(action="no-op", raw_response=f"noop_guard:{content}")

        return UserDecision(
            action=name,
            content=content,
            raw_response=raw,
        )

    @staticmethod
    def _fallback_parse(text: str) -> UserDecision:
        """Parse a plain-text response when the model didn't use tool calling.

        Tries to recover real messages before defaulting to no-op.
        The old approach silently dropped ~200 messages across eval runs.
        """
        stripped = text.strip()
        lower = stripped.lower()

        # Obvious no-ops — model said "silent" as text instead of tool call
        _NOOP_PHRASES = (
            "(i stayed silent", "i stayed silent", "stayed silent",
            "no-op", "noop", "[silent", "silent —",
            "→ no-op", "let the agent keep working",
        )
        if any(lower.startswith(p) or p in lower for p in _NOOP_PHRASES):
            return UserDecision(action="no-op", raw_response=f"fallback_noop:{stripped[:200]}")

        # Model wrote the decision as text, either in our history format
        # ("→ action: content") or as a labelled line — the latter shows up when
        # tool_choice is `auto`. Claude writes the label in several shapes
        # ("redirect:", "**redirect**:", "[redirect]", "Redirect — ..."); the
        # label is recovered as the action and removed so it never reaches the
        # agent as part of the message.
        # Separators: ":" / "—" / "–" always; a plain "-" only when spaced
        # ("Redirect - wait"), so "redirect-all traffic..." stays a message.
        m = re.match(
            r"(?:→\s*)?[*_\[]*\s*(redirect|question|new_requirement|check_external)"
            r"(?:\s*(?::|—|–|\s-)\s*[*_\]]*|\s*[*_\]]+\s*(?::|—|–|-)?)\s*(.*)",
            stripped, re.DOTALL | re.IGNORECASE,
        )
        if m:
            action, content = m.group(1).lower(), m.group(2).strip()
            if content:
                log.info("UserAgent: recovered %s from text fallback", action)
                return UserDecision(action=action, content=content, raw_response=f"fallback_recovered:{stripped[:200]}")

        # Model returned what looks like a real user message (not reasoning).
        # Heuristic: short text (<500 chars) without analysis/reflection markers
        # is likely an intended message. Longer text is usually reasoning/thinking.
        _REASONING_MARKERS = (
            "session analysis", "ground truth", "looking at", "reflecting",
            "i need to check", "let me wait", "the agent has", "the agent is",
            "according to", "i should", "i'll wait",
        )
        is_reasoning = any(m in lower for m in _REASONING_MARKERS)

        if not is_reasoning and len(stripped) < 500 and stripped:
            # Unlabelled text: the model chose not to say which kind of message
            # this is, so the record does not pretend to know either (the old
            # default of `redirect` made every such message look like a
            # correction in the per-turn log).
            log.info("UserAgent: recovered message from text fallback (%d chars)", len(stripped))
            return UserDecision(action="message", content=stripped, raw_response=f"fallback_recovered:{stripped[:200]}")

        # Default: treat as no-op (model was thinking aloud, not messaging)
        return UserDecision(action="no-op", raw_response=f"fallback_noop:{stripped[:200]}")
