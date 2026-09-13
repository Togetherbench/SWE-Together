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
    """Primary repair for a last hunk that is exactly one context line short of
    its header: drop the unknowable whitespace-only line and shrink the ``@@``
    counts so the hunk is self-consistent. Context carries no change, so the
    applied result is identical — unless the lost line was the hunk's only
    trailing context, in which case git anchors the hunk at end-of-file and
    rejects it; see :func:`apply_candidates` for the fallback."""
    lines = _rstrip_empty(diff)
    hi, counts = _short_last_hunk(lines)
    if hi is None:
        return "\n".join(lines)
    lines[hi] = _rewrite_hunk_counts(lines[hi], *counts)
    return "\n".join(lines)


def _rstrip_empty(diff: str) -> list[str]:
    lines = diff.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def _short_last_hunk(lines: list[str]) -> tuple[int | None, tuple[int, int]]:
    """Index of the last hunk header and the body's (old, new) counts when that
    hunk is exactly one context line short of its header; ``(None, (0, 0))``
    otherwise."""
    hunks = [i for i, l in enumerate(lines) if l.startswith("@@")]
    if not hunks:
        return None, (0, 0)
    hi = hunks[-1]
    m = _HUNK_RE.match(lines[hi])
    if not m:
        return None, (0, 0)
    old_n, new_n = int(m.group(1) or 1), int(m.group(2) or 1)
    body = [l for l in lines[hi + 1:] if not l.startswith("\\ ")]
    old = sum(1 for l in body if l[:1] in (" ", "-"))
    new = sum(1 for l in body if l[:1] in (" ", "+"))
    if (old, new) == (old_n - 1, new_n - 1):
        return hi, (old, new)
    return None, (0, 0)


def _rewrite_hunk_counts(header: str, old: int, new: int) -> str:
    m = re.match(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$", header)
    return f"@@ -{m.group(1)},{old} +{m.group(2)},{new} @@{m.group(3)}"


def apply_candidates(diff: str) -> list[str]:
    """Patch texts to try in order with ``git apply``. The first is the primary
    normalisation; when a trailing context line is missing a second candidate
    re-adds it as an empty line (right when the lost line was genuinely empty,
    e.g. a blank line at end of file). Both are exact reconstructions of what
    the agent changed; they differ only in the unknowable whitespace line."""
    if not diff.strip():
        return []
    base = strip_banners(diff)
    out = [restore_trailing_context(base) + "\n"]
    lines = _rstrip_empty(base)
    hi, _ = _short_last_hunk(lines)
    if hi is not None:
        out.append("\n".join(lines + [" "]) + "\n")
    return out


def normalize_for_git_apply(diff: str) -> str:
    """Banner-free, trailing-context-complete, newline-terminated patch text.
    Returns ``""`` for an empty/whitespace-only input."""
    if not diff.strip():
        return ""
    return restore_trailing_context(strip_banners(diff)) + "\n"
