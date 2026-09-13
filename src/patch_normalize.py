"""Make a harness-recorded patch applicable with ``git apply``.

``capture_git_diff`` writes ``agent/final.patch`` with two artefacts that plain
``git apply`` rejects:

* a ``=== <repo> (cumulative vs harbor-base) ===`` banner line per repo section
  ("unrecognized input");
* in patches recorded before ``repo_diff._trim_diff``, a last hunk whose trailing
  blank context line (a lone ``" "``) was eaten by ``str.strip()``, leaving the
  hunk one line short of its ``@@`` header ("corrupt patch at line N").

Both are properties of the recording, not of the agent's work, so the judge
normalises them before applying and the repair tool rewrites stored patches.
Kept free of harness imports so ``eval/`` can use it without pulling in Harbor.
"""
from __future__ import annotations

import re

BANNER_RE = re.compile(r"^=== .* ===$")
_HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")


def strip_banners(diff: str) -> str:
    return "\n".join(l for l in diff.split("\n") if not BANNER_RE.match(l))


def restore_trailing_context(diff: str) -> str:
    """Re-add a final blank context line when the last hunk is exactly one
    context line short of what its header declares."""
    lines = diff.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    hunks = [i for i, l in enumerate(lines) if l.startswith("@@")]
    if not hunks:
        return "\n".join(lines)
    m = _HUNK_RE.match(lines[hunks[-1]])
    if not m:
        return "\n".join(lines)
    old_n, new_n = int(m.group(1) or 1), int(m.group(2) or 1)
    body = [l for l in lines[hunks[-1] + 1:] if not l.startswith("\\ ")]
    old = sum(1 for l in body if l[:1] in (" ", "-"))
    new = sum(1 for l in body if l[:1] in (" ", "+"))
    if (old, new) == (old_n - 1, new_n - 1):
        lines.append(" ")
    return "\n".join(lines)


def normalize_for_git_apply(diff: str) -> str:
    """Banner-free, trailing-context-complete, newline-terminated patch text.
    Returns ``""`` for an empty/whitespace-only input."""
    if not diff.strip():
        return ""
    return restore_trailing_context(strip_banners(diff)) + "\n"
