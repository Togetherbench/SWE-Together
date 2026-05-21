"""Trial-level infrastructure-failure sentinel.

A trial can finish with `verifier_result.rewards` populated and
`exception_info` null, yet still be a useless data point because the
agent never actually ran. This happens when the model provider returns
an HTTP error inside the sandbox (DeepSeek 402 "Insufficient Balance",
z.ai 429 rate-limit corruption, OpenRouter 401 auth break, etc.). From
Harbor's orchestrator perspective the trial succeeded; from a benchmark
perspective it's noise that has to be re-run.

This module reads a completed trial's artifacts and classifies it as
either ``ok`` (real result) or ``infra_failed`` (re-run needed). The
output is written as a sidecar at ``<trial>/trial_infra.json`` and is
consumed by :func:`run_eval.is_task_completed`, so ``--skip-existing``
reruns naturally pick up infra-failed trials.

Detectors are pure functions, ordered by specificity. The first match
wins; the verdict carries the matched reason plus structured evidence
for forensics. See ``scripts/audit_trial_infra.py`` for the CLI entry
point.
"""
from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SIDECAR_NAME = "trial_infra.json"
SIDECAR_VERSION = 1

# Patch sizes <= this are treated as "empty" (header-only stubs of the form
# `=== /workspace/repo (cumulative vs harbor-base) ===`). The longest such
# header observed in the v3 cohorts is ~80 B; 200 B gives plenty of slack.
EMPTY_PATCH_BYTES = 200

# Edit-class tool names that indicate the agent actually attempted to change
# code (vs only exploring with Read / Glob / Grep).
EDIT_TOOL_NAMES = frozenset({"Edit", "Write", "MultiEdit", "NotebookEdit"})

# Number of assistant turns we require before treating "zero edits" as
# meaningful — a 2-turn refusal isn't infra failure.
MIN_TURNS_FOR_NO_PROGRESS = 5

# Number of parse-failure assistant blocks that constitutes corruption. One
# could theoretically be a real edit; we've never seen ≥2 in a healthy run.
PARSE_FAILURE_THRESHOLD = 2


@dataclass
class TrialSignals:
    """Raw observations extracted from a trial — cheap to compute, fed to
    every detector."""

    patch_bytes: int = 0
    patch_missing: bool = True
    assistant_turn_count: int = 0
    assistant_texts: list[str] = field(default_factory=list)
    edit_tool_calls: int = 0
    all_tool_calls: int = 0
    api_retry_count: int = 0
    result_subtypes: list[str] = field(default_factory=list)


@dataclass
class InfraVerdict:
    status: str  # "ok" | "infra_failed"
    reason: str  # short identifier, e.g. "provider_402_balance"
    detail: str = ""  # human-readable one-liner
    signals: list[str] = field(default_factory=list)
    evidence: dict[str, Any] = field(default_factory=dict)
    version: int = SIDECAR_VERSION

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)


# ──────────────────────────────────────────────────────────────────────────
# Signal extraction
# ──────────────────────────────────────────────────────────────────────────


def _stream_signals(claude_code_path: Path) -> TrialSignals:
    """Parse claude-code.txt once, collect every signal a detector needs.

    Stream-parses JSONL so a multi-megabyte transcript doesn't blow the heap.
    Returns empty signals if the file is missing or unreadable.
    """
    sig = TrialSignals()
    if not claude_code_path.exists():
        return sig
    try:
        fh = claude_code_path.open("r", encoding="utf-8", errors="replace")
    except OSError:
        return sig
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = obj.get("type")
            if t == "assistant":
                sig.assistant_turn_count += 1
                msg = obj.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list):
                    for c in content:
                        if not isinstance(c, dict):
                            continue
                        ct = c.get("type")
                        if ct == "text":
                            txt = c.get("text") or ""
                            if txt:
                                # Cap each text we keep — detectors only need
                                # the first ~400 chars to match a prefix.
                                sig.assistant_texts.append(txt[:400])
                        elif ct == "tool_use":
                            sig.all_tool_calls += 1
                            if c.get("name") in EDIT_TOOL_NAMES:
                                sig.edit_tool_calls += 1
            elif obj.get("subtype") == "api_retry":
                sig.api_retry_count += 1
            elif t == "result":
                sub = obj.get("subtype")
                if sub:
                    sig.result_subtypes.append(sub)
    return sig


def collect_signals(trial_dir: Path) -> TrialSignals:
    """Public entry: assemble all signals for a trial directory."""
    sig = _stream_signals(trial_dir / "agent" / "claude-code.txt")
    patch_path = trial_dir / "agent" / "final.patch"
    if patch_path.exists():
        sig.patch_missing = False
        try:
            sig.patch_bytes = patch_path.stat().st_size
        except OSError:
            sig.patch_bytes = 0
    return sig


# ──────────────────────────────────────────────────────────────────────────
# Detectors — each returns (matched, detail, evidence)
# ──────────────────────────────────────────────────────────────────────────


_API_ERR_PREFIX = re.compile(r"^\s*API Error:\s*(\d{3})\b")


def _provider_status_in_text(text: str) -> int | None:
    """Extract the HTTP status from CC's `API Error: <code> {...}` text."""
    m = _API_ERR_PREFIX.search(text)
    if m:
        return int(m.group(1))
    return None


def _detect_provider_402_balance(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    hits = [
        t for t in sig.assistant_texts
        if _provider_status_in_text(t) == 402 and "Insufficient Balance" in t
    ]
    if not hits:
        return False, "", {}
    return True, (
        f"Provider returned HTTP 402 Insufficient Balance "
        f"in {len(hits)}/{sig.assistant_turn_count} assistant turns"
    ), {"hit_count": len(hits), "sample": hits[0][:160]}


_QUOTA_HINTS = ("quota", "exceeded your current", "insufficient_quota", "RESOURCE_EXHAUSTED")


def _detect_provider_429_quota(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    hits = [
        t for t in sig.assistant_texts
        if _provider_status_in_text(t) == 429
        and any(h in t for h in _QUOTA_HINTS)
    ]
    if not hits:
        return False, "", {}
    return True, (
        f"Provider returned HTTP 429 with quota/exhaustion message "
        f"in {len(hits)}/{sig.assistant_turn_count} assistant turns"
    ), {"hit_count": len(hits), "sample": hits[0][:160]}


_AUTH_HINTS = ("User not found", "Invalid API key", "Unauthorized", "invalid_api_key")


def _detect_provider_401_auth(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    hits = [
        t for t in sig.assistant_texts
        if _provider_status_in_text(t) == 401
        and any(h in t for h in _AUTH_HINTS)
    ]
    if not hits:
        return False, "", {}
    return True, (
        f"Provider returned HTTP 401 with auth failure "
        f"in {len(hits)}/{sig.assistant_turn_count} assistant turns"
    ), {"hit_count": len(hits), "sample": hits[0][:160]}


_HTML_ERROR_PREFIXES = ("<!DOCTYPE html>", "<html", "<HTML")
_HTML_ERROR_STATUSES = ("502", "503", "504", "Server Error", "Bad Gateway", "Service Unavailable")


def _detect_provider_html_error(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    hits = []
    for t in sig.assistant_texts:
        head = t.lstrip()[:64]
        if any(head.startswith(p) for p in _HTML_ERROR_PREFIXES) and any(
            s in t for s in _HTML_ERROR_STATUSES
        ):
            hits.append(t)
    if not hits:
        return False, "", {}
    return True, (
        f"Provider returned an HTML error page (5xx) "
        f"in {len(hits)}/{sig.assistant_turn_count} assistant turns"
    ), {"hit_count": len(hits), "sample": hits[0][:160]}


_PARSE_FAILURE_LITERAL = "API Error: Failed to parse JSON"


def _detect_parse_failure_corruption(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    hits = sum(1 for t in sig.assistant_texts if t.strip() == _PARSE_FAILURE_LITERAL)
    if hits < PARSE_FAILURE_THRESHOLD:
        return False, "", {}
    return True, (
        f"CC fabricated 'Failed to parse JSON' responses {hits}× "
        f"(rate-limit / streaming corruption — see CLAUDE.md)"
    ), {"hit_count": hits, "api_retry_count": sig.api_retry_count}


def _detect_no_agent_progress(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    if sig.patch_bytes > EMPTY_PATCH_BYTES:
        return False, "", {}
    if sig.edit_tool_calls > 0:
        return False, "", {}
    if sig.assistant_turn_count < MIN_TURNS_FOR_NO_PROGRESS:
        return False, "", {}
    return True, (
        f"Agent produced no edits in {sig.assistant_turn_count} turns "
        f"(patch_bytes={sig.patch_bytes}, edit_calls=0)"
    ), {
        "patch_bytes": sig.patch_bytes,
        "assistant_turns": sig.assistant_turn_count,
        "all_tool_calls": sig.all_tool_calls,
        "api_retry_count": sig.api_retry_count,
    }


# Order matters: most specific provider signature first; the catch-all
# "no_agent_progress" detector runs last so a real provider error gets the
# precise reason in its sidecar instead of the generic one.
DETECTORS: list[tuple[str, Any]] = [
    ("provider_402_balance", _detect_provider_402_balance),
    ("provider_429_quota", _detect_provider_429_quota),
    ("provider_401_auth", _detect_provider_401_auth),
    ("provider_html_error", _detect_provider_html_error),
    ("parse_failure_corruption", _detect_parse_failure_corruption),
    ("no_agent_progress", _detect_no_agent_progress),
]


# ──────────────────────────────────────────────────────────────────────────
# Public API
# ──────────────────────────────────────────────────────────────────────────


def classify_trial(trial_dir: Path, strict: bool = False) -> InfraVerdict:
    """Inspect a completed trial directory and return an infra verdict.

    Cheap to call: O(file size of claude-code.txt) and a single stat() of
    final.patch. Safe to call before result.json exists (will return ok
    with zero signals).

    Gating predicate: a trial that produced a real patch (``patch_bytes >
    EMPTY_PATCH_BYTES``) is considered ``ok`` even if its transcript
    mentions provider errors. The semantics we want from ``infra_failed``
    is "rerunning this trial would likely produce different output";
    that's only true when the agent's work was actually cut short.
    Otherwise we'd waste money re-running trials that already produced
    useful diffs — exactly the case for the 78 glm51 trials that had
    transient ``Failed to parse JSON`` blips but still landed 2-8 edits.

    Set ``strict=True`` to disable the gating predicate (match the
    bare-spec OR: any provider error string OR empty patch → flag).
    Useful as a more sensitive audit pass.
    """
    sig = collect_signals(trial_dir)
    has_real_patch = sig.patch_bytes > EMPTY_PATCH_BYTES and not sig.patch_missing
    base_evidence = {
        "patch_bytes": sig.patch_bytes,
        "assistant_turn_count": sig.assistant_turn_count,
        "edit_tool_calls": sig.edit_tool_calls,
        "api_retry_count": sig.api_retry_count,
    }
    if has_real_patch and not strict:
        return InfraVerdict(
            status="ok", reason="", detail="",
            signals=[], evidence=base_evidence,
        )
    for name, detector in DETECTORS:
        matched, detail, evidence = detector(sig)
        if matched:
            return InfraVerdict(
                status="infra_failed",
                reason=name,
                detail=detail,
                signals=[name],
                evidence={**evidence, **base_evidence},
            )
    return InfraVerdict(
        status="ok", reason="", detail="",
        signals=[], evidence=base_evidence,
    )


def write_sidecar(trial_dir: Path, verdict: InfraVerdict) -> Path:
    """Persist the verdict to ``<trial>/trial_infra.json``. Idempotent."""
    path = trial_dir / SIDECAR_NAME
    path.write_text(verdict.to_json() + "\n")
    return path


def read_sidecar(trial_dir: Path) -> InfraVerdict | None:
    """Load a previously-written sidecar, if any. Returns None if missing,
    malformed, or written by a future schema version we don't understand."""
    path = trial_dir / SIDECAR_NAME
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict) or data.get("version") != SIDECAR_VERSION:
        return None
    try:
        return InfraVerdict(**data)
    except TypeError:
        return None


def classify_or_load(trial_dir: Path) -> InfraVerdict:
    """Return the cached sidecar if present, otherwise classify fresh.

    Used by ``is_task_completed`` to make ``--skip-existing`` cheap on
    re-invocation: the first run pays the parse cost, subsequent ones
    just read JSON.
    """
    cached = read_sidecar(trial_dir)
    if cached is not None:
        return cached
    return classify_trial(trial_dir)
