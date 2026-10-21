"""The harness tells the simulator when the agent's report ends by asking the
user something, and a silent answer to a question is asked once more.

In the 0.14.0 pilot (Sonnet 5.5 simulator, GPT-6.1 Sol agent) the simulator
answered 44% of the agent's explicit requests, against 64% for the same agent
under the previous prompt with the same model, and 13 of 218 sessions ended
with the agent asking for help on three or more of its last four reports —
follow-up intent recall fell 0.667 -> 0.553 while a stronger agent's did not.
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent.turn_end import TurnEnd, report_asks_user  # noqa: E402
from user_agent.user_agent import UserAgent, _SYSTEM_PROMPT  # noqa: E402


# ── detector ────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("report", [
    # shapes observed in the pilot reports
    "[2] agent: Both remain blocked with HTTP 403. To continue, enable network access to github.com, or provide an export of the PR. Please provide the remote URL and target branch so I can continue.",
    "[1] agent: The consolidation and cleanup are complete and committed. Should I audit the remaining transcript utilities for more cleanup, or move to another task?",
    "Next is **Step 2: `tests/test_secrets.py`**. Paused here as requested. Shall I proceed?",
    "Push is still blocked: no remote is configured and HEAD is detached. What remote URL and target branch should I use?",
    "Go ahead with map-only?",
    "Proceed?**",
    "Can you enable access to `cdn.sheetjs.com`? No repository files or dependency versions were changed.",
    "Do you want all five marked as **accepted risks (`wontfix`)**, or actually fixed? They're still present in the code, so marking them fixed would be inaccurate.",
    "Is it stored in a local `.env` file or another credential store? Tell me the location, **not the key itself**, so I can determine how to load it securely.",
    "Awaiting your go-ahead per your incremental-work instruction.",
    "Please share your local test and lint results, and I'll address any failures.",
    "Let me know which approach you prefer.",
    "May I use `17a37bd1..HEAD` as the audit range? Next I'll inspect each commit and report missing entries before editing.",
])
def test_reports_that_ask_the_user_are_detected(report):
    assert report_asks_user(report)


@pytest.mark.parametrize("report", [
    "[2] agent: Final check passed: all 5 settings tests pass, and the working tree is clean. No further changes were needed; the `enable` fix is complete.",
    "Build, vet, gofmt, unit tests, and integration tests all pass, but lint is the one CI gate I couldn't verify.",
    "Next: implement that wiring in one focused edit. Pausing here for your feedback, as requested.",
    "I'll diagnose it first, report the findings, and wait for your feedback before implementing the fix, as requested.",
    # code and URLs, not questions
    "The proposed mapping's `\"off\"` key would just be an internal lookup key for `options.reasoning ?? \"off\"`, not a new public thinking level.",
    "Results could not be retrieved. [Search on npm](https://www.npmjs.com/search?q=keywords%3Api-package)",
    "```ts\nthinking?: \"minimal\" | \"low\" | \"high\";\n```\nYou omit it or pass `undefined`.",
    # a question answered within the same report, long before the end
    "Should the loader honour the ignore package? Yes: it already does in three other loaders, so I reused that path. " + "Implemented, tested, committed. " * 30,
    "", None,
])
def test_reports_that_do_not_ask_are_not_flagged(report):
    assert not report_asks_user(report)


def test_detector_rates_on_real_pilot_reports_are_plausible():
    """A smoke check on the stored pilot prompts, when present: a fifth to a
    quarter of consults end in a request, under every simulator and agent."""
    import glob
    import re
    roots = glob.glob(str(REPO_ROOT / "trials" / "canonical_full109" / "simv2_gpt61sol_r1"))
    if not roots:
        pytest.skip("pilot trials not present")
    files = glob.glob(f"{roots[0]}/*/agent/episode-*/user_sim_prompt.json")[:400]
    if len(files) < 100:
        pytest.skip("too few pilot prompts")
    n = hits = 0
    for f in files:
        tc = json.load(open(f))["turn_content"]
        i = tc.find("## Agent's report to you")
        if i < 0:
            continue
        rep = re.split(r"\n## |\nRespond by calling", tc[i + 24:])[0]
        n += 1
        hits += report_asks_user(rep)
    assert 0.10 <= hits / n <= 0.40, hits / n


# ── TurnEnd.describe ────────────────────────────────────────────────────────

def test_describe_states_the_question_as_a_fact_and_asks_for_an_answer():
    d = TurnEnd(stop_reason="stop", has_report=True, asks_user=True).describe(3)
    assert d.startswith("The agent has stopped and is waiting for you.")
    assert "ends by asking you for something" in d
    assert "Answer it." in d
    assert "say so and tell it what to do instead" in d
    assert "stays silent when asked ends the session" in d
    assert "for you to judge" not in d  # the harness is not leaving this one open


def test_describe_without_a_question_is_unchanged():
    d = TurnEnd(stop_reason="stop", has_report=True).describe(3)
    assert "for you to judge" in d and "asking you" not in d
    assert TurnEnd().asks_user is False


def test_system_prompt_makes_answering_the_exception_to_no_op():
    assert "The one exception to the no-op default" in _SYSTEM_PROMPT
    assert "silence\nis not" in _SYSTEM_PROMPT or "silence is not" in _SYSTEM_PROMPT.replace("\n", " ")
    assert "ends the session" in _SYSTEM_PROMPT
    assert "The agent explicitly asks you something" not in _SYSTEM_PROMPT  # no longer one bullet among four


# ── retry on silence ────────────────────────────────────────────────────────

def _tool(name, content=None):
    args = json.dumps({"content": content}) if content is not None else "{}"
    return type("TC", (), {"function": type("F", (), {"name": name, "arguments": args})()})()


class _ScriptedLLM:
    _model_name = "bedrock/global.anthropic.claude-sonnet-5-5"

    def __init__(self, answers):
        self.answers = list(answers)
        self.prompts = []

    async def call(self, prompt, message_history=None, tools=None, **kw):
        self.prompts.append(prompt)
        tc = self.answers.pop(0)

        class _R:
            content = ""
            tool_calls = [tc]
        return _R()


def _run(ua, turn_end):
    return asyncio.run(ua.process("task", "[1] $ ls", "[2] agent: Which remote should I push to?", None, 2, turn_end))


def test_silent_answer_to_a_question_is_asked_once_more_and_the_answer_stands():
    llm = _ScriptedLLM([_tool("no-op"), _tool("redirect", "no remote here, just leave it committed locally")])
    ua = UserAgent(llm)
    d = _run(ua, TurnEnd(asks_user=True))
    assert d.has_message and d.content == "no remote here, just leave it committed locally"
    assert len(llm.prompts) == 2
    assert "ends by asking you for something" in llm.prompts[0]        # the fact, first time
    assert "you chose to say nothing" in llm.prompts[1]                 # the retry note, second time
    assert ua.get_stats()["asked_retry_count"] == 1
    assert ua.message_count == 1 and ua.wait_count == 0


def test_second_silence_is_accepted_and_recorded():
    llm = _ScriptedLLM([_tool("no-op"), _tool("no-op")])
    ua = UserAgent(llm)
    d = _run(ua, TurnEnd(asks_user=True))
    assert not d.has_message and d.action == "no-op"
    assert d.raw_response.startswith("asked_still_silent:")
    assert len(llm.prompts) == 2
    assert ua.get_stats()["asked_retry_count"] == 1
    # the marker is internal and must not be echoed into the simulator's history
    assert "asked_still_silent" not in ua._messages[-1]["content"]


def test_no_retry_when_the_agent_did_not_ask_or_the_simulator_answered():
    llm = _ScriptedLLM([_tool("no-op")])
    ua = UserAgent(llm)
    d = _run(ua, TurnEnd(asks_user=False))
    assert not d.has_message and len(llm.prompts) == 1 and ua.get_stats()["asked_retry_count"] == 0

    llm = _ScriptedLLM([_tool("question", "did the tests pass?")])
    ua = UserAgent(llm)
    d = _run(ua, TurnEnd(asks_user=True))
    assert d.has_message and len(llm.prompts) == 1 and ua.get_stats()["asked_retry_count"] == 0


# ── wrappers ────────────────────────────────────────────────────────────────

def test_every_wrapper_passes_asks_user_from_the_observation():
    agents = REPO_ROOT / "src" / "user_agent" / "agents"
    for p in sorted(agents.glob("user_enabled_*.py")):
        src = p.read_text()
        assert "report_asks_user(observation)" in src, p.name
    for name in ("user_enabled_opencode.py", "user_enabled_claude_code.py"):
        src = (agents / name).read_text()
        assert '"asks_user": turn_end.asks_user' in src, name


def test_opencode_turn_end_flags_a_question_in_the_observation():
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode
    a = UserEnabledOpenCode.__new__(UserEnabledOpenCode)
    a._cumulative_output = ["\n".join(json.dumps(e) for e in [
        {"type": "step_start", "part": {}},
        {"type": "text", "part": {"text": "Push is blocked: no remote. Which remote URL should I use?"}},
        {"type": "step_finish", "part": {"reason": "stop"}},
    ])]
    te = a._latest_turn_end("[1] agent: Push is blocked: no remote. Which remote URL should I use?")
    assert te == TurnEnd(stop_reason="stop", has_report=True, asks_user=True)
    te = a._latest_turn_end("[1] agent: All tests pass; the fix is complete.")
    assert te.asks_user is False and te.has_report is True
