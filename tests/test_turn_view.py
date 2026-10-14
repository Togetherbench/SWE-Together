"""The simulated user sees what a human at the terminal sees (user_agent.turn_view).

Before: the activity log showed tool names only (`tool_call(bash)`), so the
simulator could not check the agent's report against anything but the diff.
Now: commands with exit code and output tail, files touched, search hits or
"No files found", edit/tool errors — and not the contents of files the agent
read, which a human watching the terminal would not read either.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from user_agent import turn_view  # noqa: E402
from user_agent.turn_view import render_tool, render_turn  # noqa: E402


def test_shell_command_shows_exit_code_and_output_tail():
    out = "\n".join(f"line {i}" for i in range(200)) + "\nFAIL tests/test_x.py::test_y - AssertionError"
    lines = render_tool("bash", json.dumps({"command": "pytest -q"}), out, {"status": "completed", "exit": 1})
    assert lines[0] == "$ pytest -q → exit 1"
    body = "\n".join(lines[1:])
    assert body.endswith("FAIL tests/test_x.py::test_y - AssertionError")
    assert "…[earlier output elided]…" in body and "line 0\n" not in body
    assert len(body) <= turn_view.BASH_OUTPUT_TAIL + 200


def test_shell_error_without_output_is_visible():
    lines = render_tool("bash", json.dumps({"command": "make build"}), "", {"status": "error", "error": "Tool execution aborted"})
    assert lines == ["$ make build", "  error: Tool execution aborted"]


def test_file_read_shows_the_file_not_its_contents():
    secret = "<path>/w/app.py</path>\n<type>file</type>\n<content>\n1: DB_PASSWORD = 'hunter2'\n</content>"
    lines = render_tool("read", json.dumps({"filePath": "/w/app.py"}), secret, {"status": "completed"})
    assert lines == ["[read] /w/app.py — opened (file)"]
    assert "hunter2" not in "\n".join(lines)


def test_search_and_edit_show_one_line_status_and_errors():
    assert render_tool("grep", json.dumps({"pattern": "NOT_FOUND", "path": "/w/src"}), "Found 8 matches\n/w/src/a.ts: ...", {"status": "completed"}) \
        == ["[grep] NOT_FOUND", "  Found 8 matches"]
    assert render_tool("glob", json.dumps({"pattern": "plans/*.md"}), "No files found", {"status": "completed"}) \
        == ["[glob] plans/*.md", "  No files found"]
    assert render_tool("grep", json.dumps({"pattern": "x"}), "", {"status": "error", "error": "ripgrep execution failed"}) \
        == ["[grep] x", "  error: ripgrep execution failed"]
    assert render_tool("edit", json.dumps({"filePath": "/w/a.ts", "oldString": "secret-old", "newString": "secret-new"}),
                       "Edit applied successfully.", {"status": "completed"}) == ["[edit] /w/a.ts", "  Edit applied successfully."]
    err = render_tool("edit", json.dumps({"filePath": "/w/a.ts", "oldString": "zzz"}), "",
                      {"status": "error", "error": "Could not find oldString in the file"})
    assert err == ["[edit] /w/a.ts", "  error: Could not find oldString in the file"]
    # edit arguments (old/new strings) are never shown — a human sees the diff instead
    assert "secret-old" not in "\n".join(render_tool("edit", json.dumps({"filePath": "/w/a.ts", "oldString": "secret-old"}), "ok", {}))


def test_render_turn_partitions_report_and_activity_and_keeps_the_tail():
    events = [
        ("text", 1, "Let me look at the scheduler."),
        ("tool_meta", 1, {"status": "completed", "exit": 0}),
        ("tool", 1, ("bash", json.dumps({"command": "ls src"}), "a.ts\nb.ts")),
        ("tool_meta", 2, {"status": "completed", "exit": 1}),
        ("tool", 2, ("bash", json.dumps({"command": "bun test"}), "3 pass\n1 fail")),
        ("text", 3, "All tests pass. Done."),
    ]
    traj, obs = render_turn(events, ctx_budget=3000)
    assert obs == "[3] agent: All tests pass. Done."
    assert "All tests pass. Done." not in traj  # the report is not duplicated into the log
    assert "[1] agent: Let me look at the scheduler." in traj
    assert "[2] $ bun test → exit 1" in traj and "1 fail" in traj
    # tail cap keeps the most recent steps
    many = [("tool_meta", i, {"exit": 0}) if k == 0 else ("tool", i, ("bash", json.dumps({"command": f"cmd{i}"}), "x" * 400))
            for i in range(60) for k in (0, 1)]
    traj, _ = render_turn(many, ctx_budget=1000)
    assert traj.startswith("…[earlier steps elided]…") and "cmd59" in traj and len(traj) <= 2000 + 40


def test_turn_without_narration_surfaces_last_command_output():
    events = [("tool_meta", 1, {"exit": 0}), ("tool", 1, ("bash", json.dumps({"command": "pytest"}), "12 passed"))]
    _, obs = render_turn(events, ctx_budget=3000)
    assert obs == "[1] last command output: 12 passed"


def test_all_native_resume_wrappers_use_the_shared_view():
    for name in ("user_enabled_opencode", "user_enabled_claude_code", "user_enabled_mini_swe_agent"):
        src = (REPO_ROOT / "src" / "user_agent" / "agents" / f"{name}.py").read_text()
        assert "render_turn(events, self._ctx_budget)" in src, name
        assert "_SHOW_TOOL_RESULTS" not in src and "_SHOW_TOOL_ARGS" not in src, name


def test_claude_code_parser_pairs_tool_results(tmp_path):
    from user_agent.agents.user_enabled_claude_code import UserEnabledClaudeCode
    agent = UserEnabledClaudeCode.__new__(UserEnabledClaudeCode)
    agent._global_step_id = 0
    raw = "\n".join([
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "tu_1", "name": "Bash", "input": {"command": "pytest -q"}}]}}),
        json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "tu_1", "content": "2 failed, 10 passed", "is_error": True}]}}),
        json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "All green."}]}}),
    ])
    events = agent._parse_stream_json(raw)
    kinds = [e[0] for e in events]
    assert kinds == ["tool_meta", "tool", "text"]
    assert events[0][2]["status"] == "error"
    assert events[1][2] == ("Bash", json.dumps({"command": "pytest -q"}), "2 failed, 10 passed")
    traj, obs = render_turn(events, 3000)
    assert "2 failed, 10 passed" in traj and obs.endswith("All green.")


def test_prompt_frames_the_activity_as_the_terminal_view():
    from user_agent.user_agent import UserAgent, _SYSTEM_PROMPT

    class _LLM:
        _model_name = "openrouter/google/gemini-3.1-pro-preview"
    ua = UserAgent(_LLM())
    from user_agent.turn_end import TurnEnd
    body = ua._build_turn_summary("task", "[1] $ pytest → exit 1\n  1 failed", "[2] agent: all tests pass", None, 2, TurnEnd())
    assert "## What you saw in the terminal (this turn)" in body and "## Agent's report to you" in body
    assert "Judge the report against that evidence" in _SYSTEM_PROMPT
    assert ua.get_stats()["version"] >= "0.13.0"  # 0.13.0 introduced the terminal view
