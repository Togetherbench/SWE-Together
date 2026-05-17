#!/usr/bin/env python3
"""Step 5 — per-turn agent activity extractor.

For each harbor task with `original_session.json`, segment the session into
turns bounded by *real* user messages, and for each turn emit a structured
summary of what the agent did: tool calls, files touched, bash commands,
agent text/thinking.

Distinction from step4 (canonical-patch extractor): step4 collapses the
whole session into one final patch. This script preserves the *temporal*
structure so the intention-graph builder can see what happened between
user message N and N+1.

Turn boundary rule: a new turn begins at a `role: user` message whose
content is plain text (or list-of-text blocks) with NO `tool_result`
blocks. Tool-result messages are agent activity, not user turns.

Input:  harbor_tasks/<task>/original_session.json
Output: harbor_tasks/<task>/per_turn_coding_agent_action.json (default)
        --output-dir overrides the destination root.

Usage:
  python data-pipeline/scripts/step5_extract_per_turn_ops.py
  python data-pipeline/scripts/step5_extract_per_turn_ops.py --tasks 'agent-swarm-*'
  python data-pipeline/scripts/step5_extract_per_turn_ops.py --limit 5 --force
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS = ROOT / "harbor_tasks"

# Tool taxonomy — kept aligned with step4_extract_canonical_patches.py so a
# given tool name is classified the same way in both pipelines.
WRITE_TOOLS = {"write", "create_file", "write_file"}
EDIT_TOOLS = {"edit", "str_replace_editor", "string_replace", "replace"}
MULTI_EDIT_TOOLS = {"multiedit"}
NOTEBOOK_EDIT_TOOLS = {"notebookedit"}
APPLY_PATCH_TOOLS = {"apply_patch", "applypatch"}
READ_TOOLS = {"read", "view", "open_file"}
# `exec_command`/`shell_exec` are Codex/OpenCode equivalents of Bash.
# `cmd` shows up in some early DataClaw exports.
BASH_TOOLS = {"bash", "shell", "execute_bash", "run_command",
              "exec_command", "execute_command", "shell_exec", "cmd"}
SEARCH_TOOLS = {"grep", "glob", "ripgrep", "toolsearch", "search"}
TEST_TOOLS = {"run_tests", "pytest", "test"}
MUTATING_TOOLS = WRITE_TOOLS | EDIT_TOOLS | MULTI_EDIT_TOOLS | NOTEBOOK_EDIT_TOOLS | APPLY_PATCH_TOOLS

# `apply_patch` envelopes carry their target paths inside the patch body
# (V4A format: `*** Update File: <path>`). Extract them so files_edited
# is populated even when the tool_use has no top-level file_path field.
APPLY_PATCH_FILE_RE = re.compile(
    r"^\*\*\*\s+(?:Update|Add|Delete)\s+File:\s+(.+?)\s*$",
    re.MULTILINE,
)

# Mirrors step4: paths the agent uses for its own scratchpad — never part
# of the canonical patch, also not useful as files_touched signal.
AGENT_INTERNAL_PATH_FRAGMENTS = (
    "/.claude/", "/.cursor/", "/.aider/", "/.vscode/",
    "/node_modules/", "/__pycache__/", "/.pytest_cache/", "/.mypy_cache/",
    "/.ruff_cache/", "/dist/", "/build/", "/.next/cache/",
)

INLINE_TOOL_USE_RE = re.compile(
    r'<tool_use\s+id="[^"]*"\s*>\s*(\{.*?\})\s*</tool_use>',
    re.DOTALL,
)

# Heuristic markers the agent text uses to signal "I think I'm done".
# Captured per-turn so the intention graph can spot completion-claim turns
# without re-prompting an LLM.
COMPLETION_MARKERS = (
    r"\b(?:i'?ve|i have)\s+(?:completed|finished|implemented|done|fixed|resolved)\b",
    r"\b(?:task|change|fix|implementation)\s+(?:is\s+)?(?:complete|done|finished)\b",
    r"\ball (?:tests|checks)\s+pass(?:ing|ed)?\b",
    r"\bsuccessfully\s+(?:implemented|completed|added)\b",
    r"\bready\s+(?:for\s+)?review\b",
    r"\bshould\s+(?:now\s+)?work\b",
)
COMPLETION_RE = re.compile("|".join(COMPLETION_MARKERS), re.IGNORECASE)


# ---------------------------------------------------------------------------
# Message classification
# ---------------------------------------------------------------------------

def is_real_user_turn(msg: dict) -> tuple[bool, str]:
    """Return (is_real_user, text). Real-user = user-role with plain-text
    content (or text-only content blocks), NOT a tool_result delivery."""
    if not isinstance(msg, dict) or msg.get("role") != "user":
        return False, ""
    c = msg.get("content")
    if isinstance(c, str):
        return bool(c.strip()), c.strip()
    if isinstance(c, list):
        text_parts: list[str] = []
        for b in c:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "tool_result":
                return False, ""  # any tool_result block disqualifies
            if bt == "text":
                t = (b.get("text") or "").strip()
                if t:
                    text_parts.append(t)
        if text_parts:
            return True, "\n".join(text_parts)
    return False, ""


def _pick(d: dict, *keys: str) -> str:
    for k in keys:
        v = d.get(k)
        if v:
            return v
    return ""


def _is_agent_internal(path: str) -> bool:
    p = path.replace("\\", "/")
    return any(frag in p for frag in AGENT_INTERNAL_PATH_FRAGMENTS)


# ---------------------------------------------------------------------------
# Per-message tool-use extraction (3 schemas, identical to step4)
# ---------------------------------------------------------------------------

def extract_tool_uses(msg: dict) -> list[dict]:
    """Yield normalized {tool, input} ops from one message, handling all
    three known session schemas: flat `tool_uses` array (DataClaw, cli,
    amytis, cc-backend, agent-swarm), nested content blocks (pi-mono),
    inline `<tool_use>{json}</tool_use>` markup (hyperswitch).

    Same dedup discipline as step4.normalize_messages: prefer the flat
    projection when both shapes are present (they're duplicates).
    """
    if not isinstance(msg, dict):
        return []
    c = msg.get("content")
    flat = msg.get("tool_uses") or []
    nested = [
        b for b in (c or [])
        if isinstance(b, dict) and b.get("type") == "tool_use"
    ] if isinstance(c, list) else []

    ops: list[dict] = []
    if flat:
        for tu in flat:
            tool = (tu.get("tool") or tu.get("name") or "").strip()
            inp = tu.get("input")
            if isinstance(inp, str):
                inp = {"_str": inp}
            ops.append({"tool": tool, "input": inp or {}})
    elif nested:
        for b in nested:
            ops.append({
                "tool": (b.get("name") or "").strip(),
                "input": b.get("input") or {},
            })
    elif isinstance(c, str) and "<tool_use" in c:
        for m in INLINE_TOOL_USE_RE.finditer(c):
            try:
                payload = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            ops.append({
                "tool": (payload.get("name") or "").strip(),
                "input": payload.get("arguments") or payload.get("input") or {},
            })
    return ops


def extract_text(msg: dict) -> tuple[str, str]:
    """Return (text, thinking) blocks from an assistant message."""
    c = msg.get("content")
    if not isinstance(c, list):
        return "", ""
    text_parts: list[str] = []
    think_parts: list[str] = []
    for b in c:
        if not isinstance(b, dict):
            continue
        bt = b.get("type")
        if bt == "text":
            t = (b.get("text") or "").strip()
            if t:
                text_parts.append(t)
        elif bt == "thinking":
            t = (b.get("thinking") or b.get("text") or "").strip()
            if t:
                think_parts.append(t)
    return "\n\n".join(text_parts), "\n\n".join(think_parts)


# ---------------------------------------------------------------------------
# Per-op summarization (tool → semantic action + target)
# ---------------------------------------------------------------------------

def summarize_op(op: dict) -> dict:
    """Classify one tool_use into a coarse semantic label + target.

    Returns:
      {kind: read|edit|write|bash|search|test|other,
       tool: <original tool name>,
       target: <path or command snippet>,
       detail: <short additional context, e.g. "edit count=3">}
    """
    tool_raw = op.get("tool", "")
    tool = tool_raw.lower()
    inp = op.get("input") if isinstance(op.get("input"), dict) else {}

    target = ""
    detail = ""
    kind = "other"

    if tool in MUTATING_TOOLS:
        target = _pick(inp, "file_path", "path", "filePath")
        if tool in WRITE_TOOLS:
            kind = "write"
            content = inp.get("content") or inp.get("file_text") or inp.get("text") or ""
            detail = f"size={len(content)}"
        elif tool in EDIT_TOOLS or tool in MULTI_EDIT_TOOLS:
            kind = "edit"
            edits = inp.get("edits")
            if isinstance(edits, list):
                detail = f"edits={len(edits)}"
            elif inp.get("replace_all") or inp.get("replaceAll"):
                detail = "replace_all"
        elif tool in APPLY_PATCH_TOOLS:
            kind = "edit"
            detail = "apply_patch"
            # V4A patch envelope: surface file paths from inside the body
            # so the per-turn record still names the files touched even
            # when the tool_use lacks a top-level file_path.
            patch_text = (
                inp.get("patch") or inp.get("patchText")
                or inp.get("input") or inp.get("_str") or ""
            )
            paths = APPLY_PATCH_FILE_RE.findall(patch_text) if isinstance(patch_text, str) else []
            if paths and not target:
                target = paths[0]
            if len(paths) > 1:
                detail = f"apply_patch:{len(paths)}_files"
            # Stash extra paths so _accumulate can populate files_edited
            # with the full set, not just the head.
            if len(paths) > 1:
                return {"kind": kind, "tool": tool_raw, "target": target,
                        "detail": detail, "extra_paths": paths[1:]}
        elif tool in NOTEBOOK_EDIT_TOOLS:
            kind = "edit"
            detail = "notebook"
    elif tool in READ_TOOLS:
        kind = "read"
        target = _pick(inp, "file_path", "path", "filePath")
    elif tool in BASH_TOOLS:
        kind = "bash"
        cmd = (inp.get("command") or inp.get("_str") or "").strip()
        target = cmd[:200]
        # Heuristic re-tag: test-runner shell calls show up as bash but the
        # intention graph wants to see them as "ran tests".
        if re.search(r"\b(?:pytest|jest|vitest|cargo\s+test|go\s+test|npm\s+test)\b", cmd):
            kind = "test"
    elif tool in SEARCH_TOOLS:
        kind = "search"
        target = _pick(inp, "pattern", "query", "path")
        detail = _pick(inp, "path") if target != _pick(inp, "path") else ""
    elif tool in TEST_TOOLS:
        kind = "test"
        target = _pick(inp, "file_path", "path")
    else:
        # Unknown — best-effort target
        target = _pick(inp, "file_path", "path", "command", "query", "pattern")

    return {"kind": kind, "tool": tool_raw, "target": target, "detail": detail}


# ---------------------------------------------------------------------------
# Turn segmentation + summarization
# ---------------------------------------------------------------------------

def segment_turns(messages: list[dict]) -> list[dict]:
    """Walk messages, split at real-user boundaries, summarize each turn."""
    turns: list[dict] = []
    cur: dict | None = None

    for i, m in enumerate(messages):
        if not isinstance(m, dict):
            continue
        is_user, text = is_real_user_turn(m)
        if is_user:
            if cur is not None:
                cur["msg_range"][1] = i
                turns.append(cur)
            cur = _new_turn(turn_idx=len(turns), msg_start=i, user_text=text)
            continue
        if cur is None:
            # Session opens with assistant activity before any real user
            # message. Rare, but cleanly handled: synthesize a turn 0 with
            # empty user_message so the graph builder still sees the ops.
            cur = _new_turn(turn_idx=0, msg_start=i, user_text="")
        _accumulate(cur, m)

    if cur is not None:
        cur["msg_range"][1] = len(messages)
        turns.append(cur)
    return turns


def _new_turn(*, turn_idx: int, msg_start: int, user_text: str) -> dict:
    return {
        "turn": turn_idx,
        "user_message": user_text,
        "user_message_chars": len(user_text),
        "msg_range": [msg_start, msg_start],  # [start_inclusive, end_exclusive] — end filled at boundary
        "agent_text": "",
        "agent_thinking_chars": 0,  # we keep a length, not the full text — thinking blocks are huge
        "ops": [],
        "files_read": [],
        "files_edited": [],
        "files_written": [],
        "bash_commands": [],
        "test_invocations": [],
        "n_tool_calls": 0,
        "n_mutating_ops": 0,
        "completion_signaled": False,
    }


def _accumulate(turn: dict, msg: dict):
    role = msg.get("role")
    if role == "assistant":
        text, thinking = extract_text(msg)
        if text:
            turn["agent_text"] = (turn["agent_text"] + "\n\n" + text).strip() if turn["agent_text"] else text
            if not turn["completion_signaled"] and COMPLETION_RE.search(text):
                turn["completion_signaled"] = True
        if thinking:
            turn["agent_thinking_chars"] += len(thinking)

    for op in extract_tool_uses(msg):
        summary = summarize_op(op)
        kind = summary["kind"]
        target = summary["target"]
        extra = summary.pop("extra_paths", None)
        turn["ops"].append(summary)
        turn["n_tool_calls"] += 1

        # Count mutating ops by kind, not by target — Codex apply_patch
        # envelopes can carry the file paths inside the patch body, and
        # even when path extraction fails the mutation still happened.
        if kind in ("edit", "write"):
            turn["n_mutating_ops"] += 1
            bucket = "files_edited" if kind == "edit" else "files_written"
            paths = []
            if target:
                paths.append(target)
            if extra:
                paths.extend(extra)
            for p in paths:
                if _is_agent_internal(p):
                    continue
                if p not in turn[bucket]:
                    turn[bucket].append(p)
        elif kind == "read" and target and not _is_agent_internal(target):
            if target not in turn["files_read"]:
                turn["files_read"].append(target)
        elif kind == "bash" and target:
            turn["bash_commands"].append(target)
        elif kind == "test" and target:
            turn["test_invocations"].append(target)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def extract_one(task_dir: Path, output_dir: Path | None, force: bool) -> dict:
    task_name = task_dir.name
    session_path = task_dir / "original_session.json"
    out_path = (output_dir or task_dir) / "per_turn_coding_agent_action.json" if output_dir else (task_dir / "per_turn_coding_agent_action.json")
    result = {"task": task_name, "status": "?"}

    if not session_path.exists():
        result.update(status="skip", reason="no original_session.json")
        return result

    if out_path.exists() and not force:
        result.update(status="cached", path=str(out_path))
        return result

    try:
        session = json.load(open(session_path))
    except Exception as e:
        result.update(status="error", reason=f"session load: {e}")
        return result

    messages = session.get("messages") or []
    if not messages:
        result.update(status="skip", reason="empty messages array")
        return result

    turns = segment_turns(messages)
    if not turns:
        result.update(status="skip", reason="no turns detected (no real-user messages)")
        return result

    n_mut = sum(t["n_mutating_ops"] for t in turns)
    if n_mut == 0:
        # Still emit — the intention graph builder may still use the
        # conversational structure even when no file edits survived export.
        # Just flag it.
        result["zero_mutating_warning"] = True

    out = {
        "session_id": session.get("session_id") or task_name,
        "task_name": task_name,
        "turn_count": len(turns),
        "total_tool_calls": sum(t["n_tool_calls"] for t in turns),
        "total_mutating_ops": n_mut,
        "schema_version": "1.0",
        "turns": turns,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(out_path, "w"), indent=2, ensure_ascii=False)

    result.update(
        status="ok",
        path=str(out_path),
        turns=len(turns),
        tool_calls=out["total_tool_calls"],
        mutating=n_mut,
    )
    return result


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--tasks", default="*",
                    help="Glob over harbor_tasks/<pattern>/ (default: all)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true",
                    help="Re-extract even if cached")
    ap.add_argument("--output-dir", default=None,
                    help="Write per_turn_coding_agent_action.json under this "
                         "dir instead of the task dir (preserves a sidecar "
                         "layout). When set, files land at "
                         "<output-dir>/<task>/per_turn_coding_agent_action.json.")
    args = ap.parse_args()

    candidates = [d for d in HARBOR_TASKS.iterdir()
                  if d.is_dir() and fnmatch.fnmatch(d.name, args.tasks)
                  and not d.name.startswith("_")]
    candidates.sort()
    if args.limit:
        candidates = candidates[: args.limit]

    print(f"Targeting {len(candidates)} tasks")
    if args.output_dir:
        print(f"Output root: {args.output_dir}/")
    else:
        print(f"Output: per_turn_coding_agent_action.json in each task dir")

    counts: dict[str, int] = {}
    t0 = time.time()
    for i, task_dir in enumerate(candidates, 1):
        out_dir = Path(args.output_dir) / task_dir.name if args.output_dir else None
        r = extract_one(task_dir, out_dir, args.force)
        st = r["status"]
        counts[st] = counts.get(st, 0) + 1
        if st == "ok":
            extra = " [zero-edits!]" if r.get("zero_mutating_warning") else ""
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} ok "
                  f"(turns={r['turns']}, calls={r['tool_calls']}, edits={r['mutating']}){extra}")
        elif st in ("skip", "cached"):
            tail = r.get("reason") or Path(r.get("path", "")).name
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} {st}: {tail}")
        else:
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} ERROR: {r.get('reason', '?')}")

    print(f"\n=== Done in {time.time()-t0:.1f}s ===")
    for k, v in sorted(counts.items()):
        print(f"  {k:10s}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
