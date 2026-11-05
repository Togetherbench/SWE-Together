"""Regression checks for saved Native simulator parser failures."""

import json
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

MODULE_PATH = Path(__file__).resolve().parents[1] / "src/user_agent/user_agent.py"
SPEC = importlib.util.spec_from_file_location("_user_agent_validity_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
UserAgent = MODULE.UserAgent
UserDecision = MODULE.UserDecision


def _tool_response(content: str) -> SimpleNamespace:
    return SimpleNamespace(
        content="",
        tool_calls=[
            SimpleNamespace(
                function=SimpleNamespace(
                    name="redirect",
                    arguments=json.dumps({"content": content}),
                )
            )
        ],
    )


def test_tool_messages_about_silent_failures_are_delivered() -> None:
    simulator = UserAgent(llm=None, force_tool_choice=False)
    for content in (
        "we should log the sessions that are skipped, not just silently drop them",
        "why can this fail silently? please fix the logging",
        "silent data loss is the worst outcome; do A",
    ):
        decision = simulator._extract_decision(_tool_response(content))
        assert decision.action == "redirect"
        assert decision.has_message
        assert decision.content == content


def test_only_whole_noop_markers_are_suppressed() -> None:
    simulator = UserAgent(llm=None, force_tool_choice=False)
    for content in ("silent", "no-op", "no op", "noop", "→ no-op (silent)", "→ no-op: Go on"):
        decision = simulator._extract_decision(_tool_response(content))
        assert decision.action == "no-op"
        assert not decision.has_message
        fallback = simulator._fallback_parse(content)
        assert fallback.action == "no-op"
        assert not fallback.has_message


def test_fallback_preserves_real_message_and_hides_internal_marker() -> None:
    decision = UserAgent._fallback_parse("we should not silently skip this")
    assert decision.action == "redirect"
    assert decision.has_message
    assert decision.format_for_history() == "→ redirect: we should not silently skip this"
    assert "fallback_recovered:" not in decision.format_for_history()


def test_real_model_reasoning_remains_in_history() -> None:
    decision = UserDecision(action="redirect", content="fix it", raw_response="The agent missed the log.")
    assert decision.format_for_history() == "The agent missed the log.\n\n→ redirect: fix it"
