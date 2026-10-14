"""What the simulated user sees of the agent's work in one turn.

The simulator role-plays a human sitting at the terminal while the agent works.
That human sees the agent's narration, the commands it runs and their output
scrolling past, and which files it opens or edits; they do not read every file
the agent reads or every grep hit. ``render_turn`` turns a harness-neutral
event list into exactly that view, so a model's narration can be checked
against what actually happened (a test run that failed, a command that errored,
"No files found") instead of being taken at its word.

Events are ``("text", step_id, narration)`` or ``("tool", step_id, (name,
args_json, result_text))`` plus the optional ``("tool_meta", step_id, dict)``
carrying ``status`` / ``exit`` / ``error`` where the harness reports them.
All three native-resume wrappers (opencode, claude-code, mini-swe-agent) feed
this one renderer so the simulator gets the same shape of input whatever the
harness.
"""
from __future__ import annotations

import json
import re

#: Visible output per shell command (tail; the conclusion and any error come last).
BASH_OUTPUT_TAIL = 600
#: Visible chars of a non-shell tool's one-line status ("Edit applied", "Found 8 matches").
STATUS_LINE_MAX = 160
#: Narration snippets inside the activity log (the final report is shown whole elsewhere).
THINKING_SNIPPET = 300

_SHELL_TOOLS = {"bash", "shell", "run_terminal_cmd", "execute_command", "run_command"}
_READ_TOOLS = {"read", "read_file", "view", "cat", "open"}
_SEARCH_TOOLS = {"grep", "glob", "search", "find", "list", "ls", "rg", "codebase_search"}
_EDIT_TOOLS = {"edit", "write", "multiedit", "apply_patch", "patch", "str_replace_editor",
               "str_replace_based_edit_tool", "create_file", "write_file", "edit_file"}
_CONTENT_KEYS = ("command", "cmd", "filePath", "file_path", "path", "pattern", "query", "description")
_SEARCH_KEYS = ("pattern", "query", "path", "filePath", "description")


def _parse_args(args) -> dict:
    if isinstance(args, dict):
        return args
    if isinstance(args, str) and args.strip():
        try:
            parsed = json.loads(args)
            return parsed if isinstance(parsed, dict) else {"value": parsed}
        except (json.JSONDecodeError, ValueError):
            return {"value": args}
    return {}


def _first_line(s: str, limit: int) -> str:
    s = (s or "").strip().splitlines()[0] if (s or "").strip() else ""
    return s if len(s) <= limit else s[:limit] + "…"


def _tail(s: str, limit: int) -> str:
    s = (s or "").rstrip()
    if len(s) <= limit:
        return s
    return "…[earlier output elided]…\n" + s[-limit:]


def _target(args: dict, keys: tuple[str, ...] = _CONTENT_KEYS) -> str:
    for k in keys:
        v = args.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def _strip_read_wrapper(result: str) -> str:
    # opencode wraps file reads as <path>…</path><type>file</type><content>…; the
    # human sees "opened the file", not its contents.
    m = re.search(r"<type>(\w+)</type>", result or "")
    return f"opened ({m.group(1)})" if m else ""


def render_tool(name: str, args, result: str, meta: dict | None = None) -> list[str]:
    """Lines describing one tool call as a terminal-watching human would see it."""
    a = _parse_args(args)
    meta = meta or {}
    result = result or ""
    status = meta.get("status")
    error = meta.get("error")
    lines: list[str] = []
    lname = (name or "?").lower()

    if lname in _SHELL_TOOLS:
        cmd = _first_line(_target(a), 200) or "(command)"
        exit_code = meta.get("exit")
        tag = f" → exit {exit_code}" if exit_code not in (None, "") else ""
        lines.append(f"$ {cmd}{tag}")
        if error:
            lines.append(f"  error: {_first_line(str(error), STATUS_LINE_MAX)}")
        if result.strip():
            lines.append("  " + _tail(result, BASH_OUTPUT_TAIL).replace("\n", "\n  "))
        return lines

    target = _first_line(_target(a, _SEARCH_KEYS if lname in _SEARCH_TOOLS else _CONTENT_KEYS), 120)
    if lname in _READ_TOOLS:
        what = _strip_read_wrapper(result)
        lines.append(f"[{name}] {target}" + (f" — {what}" if what else ""))
    elif lname in _SEARCH_TOOLS:
        lines.append(f"[{name}] {target}" if target else f"[{name}]")
        if status == "error" or error:
            lines.append(f"  error: {_first_line(str(error or result), STATUS_LINE_MAX)}")
        elif result.strip():
            lines.append(f"  {_first_line(result, STATUS_LINE_MAX)}")
    elif lname in _EDIT_TOOLS:
        lines.append(f"[{name}] {target}" if target else f"[{name}]")
        first = _first_line(str(error or result), STATUS_LINE_MAX)
        if first:
            lines.append(f"  {'error: ' if (status == 'error' or error) else ''}{first}")
    else:
        lines.append(f"[{name}] {target}" if target else f"[{name}]")
        if status == "error" or error:
            lines.append(f"  error: {_first_line(str(error or result), STATUS_LINE_MAX)}")
        elif result.strip():
            lines.append(f"  {_first_line(result, STATUS_LINE_MAX)}")
    return lines


def render_turn(events: list[tuple], ctx_budget: int) -> tuple[str, str]:
    """(trajectory, observation) for the simulator from one turn's events.

    The agent's final narration is the observation (its report to the user,
    shown whole up to 3000 chars); everything before it — intermediate
    narration, commands and their output, files touched — is the activity log,
    tail-capped at ``ctx_budget * 2`` so the most recent steps survive.
    """
    last_text_idx = None
    for i, ev in enumerate(events):
        if ev[0] == "text":
            last_text_idx = i

    steps: list[str] = []
    pending_meta: dict | None = None
    for i, ev in enumerate(events):
        kind, sid, payload = ev[0], ev[1], ev[2]
        if kind == "tool_meta":
            pending_meta = payload
            continue
        if kind == "text":
            if i == last_text_idx:
                continue
            snippet = payload if len(payload) <= THINKING_SNIPPET else payload[:THINKING_SNIPPET] + "…"
            steps.append(f"[{sid}] agent: {snippet}")
            pending_meta = None
            continue
        name, args, result = payload
        for line in render_tool(name, args, result, pending_meta):
            steps.append(f"[{sid}] {line}")
        pending_meta = None

    trajectory = "\n".join(steps) if steps else "(no intermediate steps)"
    if len(trajectory) > ctx_budget * 2:
        trajectory = "…[earlier steps elided]…\n" + trajectory[-ctx_budget * 2:]

    if last_text_idx is not None:
        sid, report = events[last_text_idx][1], events[last_text_idx][2]
        observation = f"[{sid}] agent: {report[:3000]}"
    else:
        observation = "(no agent narration this turn)"
        for ev in reversed(events):
            if ev[0] == "tool" and ev[2][2]:
                observation = f"[{ev[1]}] last command output: {_tail(str(ev[2][2]), 500)}"
                break
    return trajectory, observation
