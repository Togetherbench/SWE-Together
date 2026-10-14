"""The simulator is no longer told that every turn is a completion attempt.

Every wrapper passed ``completing=True`` on every consult, and the prompt turned
it into "** The agent is signaling completion." — the trigger for "the agent
tries to finish but missed requirements". The prompt now states what the harness
actually knows (the agent stopped and is waiting; its stop reason when the
harness exposes one) and leaves done / pausing / blocked / asking to the
simulator's reading of the report.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent.turn_end import TurnEnd  # noqa: E402
from user_agent.user_agent import UserAgent, _SYSTEM_PROMPT  # noqa: E402


class _LLM:
    _model_name = "openrouter/google/gemini-3.1-pro-preview"


def test_prompt_no_longer_asserts_completion():
    ua = UserAgent(_LLM())
    body = ua._build_turn_summary("task", "[1] $ ls", "[2] agent: Migration done, moving on to the scheduler next.", None, 2, TurnEnd())
    assert "signaling completion" not in body
    assert "**Where the agent stopped:** The agent has stopped and is waiting for you." in body
    assert "has not been told it is done" in body


def test_turn_end_describes_only_what_the_harness_knows():
    assert TurnEnd().describe(3).startswith("The agent has stopped and is waiting for you.")
    assert "cut off by the time limit" in TurnEnd(stop_reason="cap", has_report=False).describe(1)
    assert "cut off at the output limit" in TurnEnd(stop_reason="length").describe(1)
    assert "ended with an error" in TurnEnd(stop_reason="error").describe(1)
    assert "stopped without saying anything" in TurnEnd(stop_reason="stop", has_report=False).describe(1)
    for te in (TurnEnd(), TurnEnd(stop_reason="stop"), TurnEnd(stop_reason="length")):
        assert "for you to judge" in te.describe(2) and "done" in te.describe(2)


def test_process_accepts_turn_end_and_tolerates_legacy_bool():
    import asyncio

    class _RecLLM:
        _model_name = "openrouter/google/gemini-3.1-pro-preview"
        last = None

        async def call(self, prompt, message_history=None, tools=None, **kw):
            _RecLLM.last = prompt

            class _R:
                content = ""
                tool_calls = [type("TC", (), {"function": type("F", (), {"name": "no-op", "arguments": "{}"})()})()]
            return _R()
    ua = UserAgent(_RecLLM())
    asyncio.run(ua.process("t", "traj", "obs", None, 1, TurnEnd(stop_reason="length")))
    assert "cut off at the output limit" in _RecLLM.last
    asyncio.run(ua.process("t", "traj", "obs", None, 2, True))  # legacy positional bool
    assert "signaling completion" not in _RecLLM.last and "waiting for you" in _RecLLM.last


def test_system_prompt_trigger_asks_the_simulator_to_judge():
    assert "nobody tells you which" in _SYSTEM_PROMPT
    assert "tries to finish" not in _SYSTEM_PROMPT


def test_no_wrapper_hardcodes_completion():
    agents = REPO_ROOT / "src" / "user_agent" / "agents"
    for p in agents.glob("user_enabled_*.py"):
        src = p.read_text()
        assert "completing=True" not in src and "is_completion_attempt" not in src.replace("always-True is_completion_attempt", ""), p.name
        assert '"turn_end": {"stop_reason": turn_end.stop_reason' in src, p.name


def test_opencode_wrapper_reads_stop_reason_from_the_stream(tmp_path):
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode
    w = UserEnabledOpenCode.__new__(UserEnabledOpenCode)
    stream = lambda reason, text=True: "\n".join(filter(None, [
        json.dumps({"type": "step_start", "part": {}}),
        json.dumps({"type": "text", "part": {"text": "Scheduler done. Next the API."}}) if text else "",
        json.dumps({"type": "step_finish", "part": {"reason": reason}}),
    ]))
    w._cumulative_output = [stream("stop")]
    assert w._latest_turn_end() == TurnEnd(stop_reason="stop", has_report=True)
    w._cumulative_output = [stream("length")]
    assert w._latest_turn_end() == TurnEnd(stop_reason="length", has_report=True)
    w._cumulative_output = [stream("stop", text=False)]
    assert w._latest_turn_end() == TurnEnd(stop_reason="stop", has_report=False)
    w._cumulative_output = []
    assert w._latest_turn_end() == TurnEnd(stop_reason=None, has_report=False)


def test_claude_code_parser_records_result_subtype():
    from user_agent.agents.user_enabled_claude_code import UserEnabledClaudeCode
    a = UserEnabledClaudeCode.__new__(UserEnabledClaudeCode)
    a._global_step_id = 0
    a._parse_stream_json(json.dumps({"type": "result", "subtype": "success", "result": "done"}))
    assert a._last_stop_reason == "stop"
    a._parse_stream_json(json.dumps({"type": "result", "subtype": "error_max_turns", "result": ""}))
    assert a._last_stop_reason == "length"
    a._parse_stream_json(json.dumps({"type": "result", "subtype": "error_during_execution", "result": ""}))
    assert a._last_stop_reason == "error"


def test_version_bumped():
    assert UserAgent(_LLM()).get_stats()["version"] == "0.14.0"
