"""Text-fallback parsing and the per-turn record, after the simulator stopped
replaying ground-truth messages.

Under tool_choice=auto (the Claude 5.5 endpoints reject `required`) the
simulator sometimes answers in prose instead of a tool call. In the Sonnet 5.5
smoke trials this happened on 5 of 71 consults, with the label written as
"new_requirement: ...", "→ redirect: ...", or nothing at all. The parser has to
recover the message without leaking the label to the agent, and must not invent
a kind for an unlabelled message.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent.user_agent import UserAgent, UserDecision  # noqa: E402


class _LLM:
    _model_name = "bedrock/global.anthropic.claude-sonnet-5-5"


@pytest.mark.parametrize("text, action, content", [
    # shapes observed in the Sonnet 5.5 smoke trials
    ("new_requirement: ugh ok the file prob wasnt committed. just implement from the title then.",
     "new_requirement", "ugh ok the file prob wasnt committed. just implement from the title then."),
    ("→ redirect: ok nice. bump tha version, commit the changes and push",
     "redirect", "ok nice. bump tha version, commit the changes and push"),
    ("redirect: nah skip the refactor, thats out of scope", "redirect", "nah skip the refactor, thats out of scope"),
    # markdown and punctuation variants Claude uses for the same thing
    ("**redirect**: wait check transformers.rs", "redirect", "wait check transformers.rs"),
    ("**question:** did you run the tests?", "question", "did you run the tests?"),
    ("[check_external] look at the PR comments", "check_external", "look at the PR comments"),
    ("Redirect — wait, you also need to add idefics3", "redirect", "wait, you also need to add idefics3"),
    ("Question - what does the migration do?", "question", "what does the migration do?"),
    ("_new_requirement_: also add dark mode", "new_requirement", "also add dark mode"),
])
def test_labelled_text_is_recovered_without_the_label(text, action, content):
    d = UserAgent._fallback_parse(text)
    assert d.action == action
    assert d.content == content
    assert d.has_message
    assert d.raw_response.startswith("fallback_recovered:")
    for label in ("redirect", "question", "new_requirement", "check_external"):
        assert not d.content.lower().startswith(label)


def test_unlabelled_text_is_a_message_of_unknown_kind():
    d = UserAgent._fallback_parse("yeah go check ProjectDetailPage and handle the NOT_FOUND case there too")
    assert d.has_message
    assert d.content == "yeah go check ProjectDetailPage and handle the NOT_FOUND case there too"
    assert d.action == "message"  # not `redirect`: the model did not say it was a correction


@pytest.mark.parametrize("text", [
    "question for you: why did you skip the tests?",
    "redirect the output to a file please",
    "redirect-all traffic to the new handler",
    "question is whether the cache works at all",
])
def test_a_message_that_merely_starts_with_a_label_word_is_kept_whole(text):
    d = UserAgent._fallback_parse(text)
    assert d.action == "message"
    assert d.content == text


@pytest.mark.parametrize("text", [
    "no-op",
    "→ no-op (silent)",
    "I'll stay silent and let the agent keep working.",
    "Looking at the session analysis, the agent is making progress so I should wait.",
    "",
])
def test_silence_and_reasoning_stay_silent(text):
    d = UserAgent._fallback_parse(text)
    assert d.action == "no-op"
    assert not d.has_message


def test_fallback_message_is_injected_verbatim_and_logged_as_recovered():
    d = UserAgent._fallback_parse("**redirect**: wait check transformers.rs")
    assert d.format_for_injection() == "wait check transformers.rs"
    # the history keeps the structured decision, not the raw labelled text
    assert d.format_for_history().endswith("→ redirect: wait check transformers.rs")


def test_per_turn_record_has_no_ground_truth_cursor():
    ua = UserAgent(_LLM(), original_user_messages=["a", "b", "c"])
    stats = ua.get_stats()
    assert stats["ground_truth_total"] == 3
    assert "ground_truth_consumed" not in stats
    assert not hasattr(ua, "_cursor")
    assert not hasattr(ua, "advance_original_index")
    for wrapper in ("user_enabled_agent", "user_enabled_claude_code", "user_enabled_codex",
                    "user_enabled_mini_swe_agent", "user_enabled_opencode"):
        src = (REPO_ROOT / "src" / "user_agent" / "agents" / f"{wrapper}.py").read_text()
        assert "advance_original_index" not in src, wrapper
        assert '"cursor"' not in src and "ground_truth_remaining" not in src, wrapper


def test_version_records_the_parser_change():
    assert UserAgent(_LLM()).get_stats()["version"] == "0.15.1"
    assert json.dumps(UserDecision(action="message", content="x").action) == '"message"'
