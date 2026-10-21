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
| Total user messages | 5 genuine (out of 9 turns) |

**HARD LIMITS -- these override everything else:**
- **Message budget**: Send at most **7 messages total**. Stop after the 7th message even if work is incomplete.
- **No duplicate messages**: NEVER send the same message twice.

### HARD CAP: Maximum 6 messages

You may send **at most 6 messages** across the entire session. After sending 6 messages, you MUST choose `no-op`.
2. **HARD BUDGET: exactly 5 messages maximum.** You MUST count each message you send.
- **HARD MESSAGE CAP: Send at most 4 messages total during the entire session.** After sending 4 messages, always return silence.
1. Have I already sent 4 messages this session? -> **SILENCE** (hard cap reached)
- Target for simulation: ~1-2 messages in a normal run.
SILENCE for every subsequent turn. The real user sent exactly 4 messages --
never invent a fifth.

## User Turns

### Turn 2 (after ~30 agent turns)
- **Said**: `did you run the tests?`
- **Why**: 4 messages earlier the user had asked for a test run and the agent skipped it.
| T3 | agent claims done without running tests | `did you run the tests?` | FIRE ONCE |
"""


def test_session_context_has_no_message_quota():
    ctx = runner.session_analysis_note(TASK_PROMPT)
    task_part, note = ctx.split("## How the agent works here", 1)
    lower = task_part.lower()
    for banned in ("message guidance", "aim for", "messages** total", "in order",
                   "even if the trigger condition is not a perfect match", "target message count",
                   "total user messages", "message budget", "hard cap", "hard budget", "message cap",
                   "at most 6 messages", "at most 4 messages", "exactly 5 messages", "exactly 4 messages",
                   "must count each message", "after sending", "sent 4 messages this session",
                   "target for simulation"):
        assert banned not in lower, banned
    # the per-task context itself survives (turns, triggers, calibration facts)
    assert "did you run the tests?" in ctx and "Longest silence" in ctx
    assert "| T3 | agent claims done without running tests |" in ctx
    assert "4 messages earlier the user had asked" in ctx  # a count inside a trigger is not a quota
    assert "never invent a fifth." in ctx  # the line after a removed one is untouched
    assert "**No duplicate messages**" in ctx  # behavioural rules under a HARD LIMITS header stay
    # the fixed workflow note still tells the simulator there is no count to reach
    assert "no number of messages to reach" in note and "Message budget" in note
    assert "not a script" in note


def test_quota_lines_are_removed_whole_and_nothing_else_is_touched():
    ctx = runner.session_analysis_note(TASK_PROMPT)
    task_part = ctx.split("\n\n## How the agent works here", 1)[0]
    kept = task_part.splitlines()
    original = TASK_PROMPT.splitlines()
    # every surviving line is an original line, in the original order
    it = iter(original)
    for line in kept:
        assert line in it, line
    removed = [l for l in original if l not in set(kept)]
    assert len(removed) == 12, removed


def test_every_task_prompt_loses_its_quota_lines_but_keeps_its_turns():
    import re
    quota = re.compile(r"total user messages|target message count|message (budget|cap|quota)|"
                       r"hard (cap|budget|limit)|(at most|exactly|no more than) \d+ messages|must count", re.I)
    structural = re.compile(r"^#{2,3} Turn \d|\*\*Said\*\*|^\| T\d+ \|")
    prompts = sorted((REPO_ROOT / "tasks").glob("*/user_simulation_prompt.md"))
    assert len(prompts) >= 100
    for p in prompts:
        text = p.read_text()
        ctx = runner.session_analysis_note(text).split("\n\n## How the agent works here", 1)[0]
        kept = set(ctx.splitlines())
        for line in text.splitlines():
            if structural.search(line):
                assert line in kept, (p.parent.name, line)
        for line in ctx.splitlines():
            # a header introducing behavioural rules may keep the word; a count may not
            if quota.search(line) and not line.startswith("**HARD LIMITS"):
                raise AssertionError((p.parent.name, line))


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
