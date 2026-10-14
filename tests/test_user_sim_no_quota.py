"""The user simulator decides from the agent's behaviour, not from a message quota.

Until 2026-10-13 the per-task simulator context was followed by an auto-generated
"Message Guidance" block (a target message range derived from the original
session) and a "Trigger Interpretation" block that told the simulator to send the
next ground-truth message in order even when its trigger did not match. The
per-task prompts also carry their own "Target message count" calibration line.
All of that is gone from the prompt; this test pins the new contract.
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

import runner  # noqa: E402
from user_agent.user_agent import UserAgent, _SYSTEM_PROMPT  # noqa: E402

TASK_PROMPT = """# User Simulator Prompt: some-task

## Simulator Calibration

- **Total user messages**: 5 (initial task + 4 follow-ups)
- **Longest silence**: ~40 minutes
- **Target message count**: ~3-5 user messages for a competent agent.
| Target message count | 4 |

## User Turns

### Turn 2 (after ~30 agent turns)
- **Said**: `did you run the tests?`
"""


def test_session_context_has_no_message_quota():
    ctx = runner.session_analysis_note(TASK_PROMPT)
    task_part, note = ctx.split("## How the agent works here", 1)
    lower = task_part.lower()
    for banned in ("message guidance", "aim for", "messages** total", "in order",
                   "even if the trigger condition is not a perfect match", "target message count"):
        assert banned not in lower, banned
    # the per-task context itself survives (turns, triggers, calibration facts)
    assert "did you run the tests?" in ctx and "Total user messages" in ctx and "Longest silence" in ctx
    # the fixed workflow note overrides any count phrasing the task prompt may still use
    assert "no number of messages to reach" in note and "Message budget" in note
    assert "not a script" in note


def test_target_count_line_is_removed_in_both_markdown_shapes():
    ctx = runner.session_analysis_note(TASK_PROMPT)
    assert "~3-5 user messages" not in ctx
    assert "| Target message count | 4 |" not in ctx
    # nothing else was touched: line count drops by exactly the two removed lines
    kept = [l for l in TASK_PROMPT.splitlines() if "target message count" not in l.lower()]
    assert ctx.startswith("\n".join(kept))


def test_system_prompt_states_there_is_no_count():
    assert "no number of messages to reach" in _SYSTEM_PROMPT
    assert "Default to no-op" in _SYSTEM_PROMPT
    assert "ground truth" in _SYSTEM_PROMPT  # the "never mention" rule stays


def test_run_eval_and_runner_share_the_note():
    src = (REPO_ROOT / "src" / "run_eval.py").read_text()
    assert "session_analysis_note(" in src
    assert "Message Guidance" not in src and "Aim for" not in src
    assert "Message Guidance" not in (REPO_ROOT / "src" / "runner.py").read_text().split("SESSION_ANALYSIS_NOTE = (")[1]


def test_simulator_version_bumped_for_provenance():
    class _LLM:
        _model_name = "openrouter/google/gemini-3.1-pro-preview"
    assert UserAgent(_LLM()).get_stats()["version"] >= "0.12.0"  # 0.12.0 introduced the no-quota prompt


def test_text_fallback_strips_action_labels():
    # under tool_choice=auto a model may answer "action: message" as plain text;
    # the label must not leak into what the agent receives
    d = UserAgent._fallback_parse("new_requirement: ugh ok just implement from the title then")
    assert d.action == "new_requirement" and d.content == "ugh ok just implement from the title then"
    d = UserAgent._fallback_parse("→ redirect: wait, run the tests first")
    assert d.action == "redirect" and d.content == "wait, run the tests first"
    assert UserAgent._fallback_parse("no-op").action == "no-op"
    d = UserAgent._fallback_parse("can you also add a test for the empty case")
    assert d.has_message and "can you also" in d.content
