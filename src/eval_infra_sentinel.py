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

# Agent-transcript filenames across the harnesses we run (Claude Code,
# opencode, mini-swe-agent). Exactly one of these is the real transcript for
# a given trial; a present-but-empty one means the harness launched but the
# agent produced nothing (e.g. the opencode-gpt launch-hang: 0-byte
# opencode.txt, 9 tasks × 3 reps in the lite70 cohort).
AGENT_TRANSCRIPT_NAMES = ("claude-code.txt", "opencode.txt", "mini-swe-agent.txt")


def _is_empty_transcript(path: Path) -> bool:
    """True iff the file exists and is empty (0 bytes, or whitespace-only for
    a tiny file). A *missing* file is NOT empty — that's the pre-result /
    incomplete-artifacts case handled elsewhere."""
    try:
        size = path.stat().st_size
    except OSError:
        return False
    if size == 0:
        return True
    if size <= 16:  # cheap whitespace-only check without reading big files
        try:
            return path.read_text(errors="replace").strip() == ""
        except OSError:
            return False
    return False


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
    # opencode-only: step-finish events whose reason == "error" (the codex
    # OAuth backend 503/429/overloaded that ends a turn with 0 tokens).
    backend_error_turns: int = 0
    result_subtypes: list[str] = field(default_factory=list)
    transcript_present_but_empty: bool = False
    empty_transcript_names: list[str] = field(default_factory=list)


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


_OPENCODE_EDIT_TOOLS = frozenset({"edit", "write", "patch", "apply_patch", "multiedit"})


def _stream_signals_opencode(opencode_path: Path) -> TrialSignals:
    """Parse opencode.txt (a different JSONL schema than claude-code.txt).

    Opencode emits one JSON object per event: ``type`` in {step_start,
    step_finish, tool_use, text, reasoning}. A turn ends with a
    ``step_finish`` carrying ``part.reason`` (``tool-calls`` on success,
    ``error`` when the model call failed — the codex OAuth 503/429 case,
    which also shows ``tokens.output == 0``). Edit-class tools live under
    ``part.tool``. Without this, the sentinel saw zero signals for every
    opencode trial and ``no_agent_progress`` could never fire.
    """
    sig = TrialSignals()
    if not opencode_path.exists():
        return sig
    try:
        fh = opencode_path.open("r", encoding="utf-8", errors="replace")
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
            part = obj.get("part") if isinstance(obj.get("part"), dict) else {}
            if t == "tool_use":
                sig.all_tool_calls += 1
                tool = part.get("tool") or obj.get("tool")
                if tool in _OPENCODE_EDIT_TOOLS:
                    sig.edit_tool_calls += 1
            elif t == "step_finish":
                sig.assistant_turn_count += 1
                if part.get("reason") == "error":
                    sig.backend_error_turns += 1
            elif t == "text":
                txt = part.get("text") or obj.get("text") or ""
                if isinstance(txt, str) and txt:
                    sig.assistant_texts.append(txt[:400])
    return sig


def collect_signals(trial_dir: Path) -> TrialSignals:
    """Public entry: assemble all signals for a trial directory."""
    sig = _stream_signals(trial_dir / "agent" / "claude-code.txt")
    # opencode / mini-swe-agent don't write claude-code.txt, so the CC parse
    # above sees zero turns. Fall back to the opencode transcript so the
    # progress/backend-error detectors have real signals to work with.
    if sig.assistant_turn_count == 0 and sig.all_tool_calls == 0:
        oc = _stream_signals_opencode(trial_dir / "agent" / "opencode.txt")
        sig.assistant_turn_count = oc.assistant_turn_count
        sig.assistant_texts = oc.assistant_texts
        sig.edit_tool_calls = oc.edit_tool_calls
        sig.all_tool_calls = oc.all_tool_calls
        sig.backend_error_turns = oc.backend_error_turns
    patch_path = trial_dir / "agent" / "final.patch"
    if patch_path.exists():
        sig.patch_missing = False
        try:
            sig.patch_bytes = patch_path.stat().st_size
        except OSError:
            sig.patch_bytes = 0
    # Present-but-empty agent transcript = harness launched, agent produced
    # nothing. Checked across all harness transcript names because opencode /
    # mini-swe-agent don't write claude-code.txt (so _stream_signals above
    # sees zero turns and the no_agent_progress detector can't fire for them).
    agent_dir = trial_dir / "agent"
    present = [agent_dir / n for n in AGENT_TRANSCRIPT_NAMES if (agent_dir / n).exists()]
    if present and all(_is_empty_transcript(p) for p in present):
        sig.transcript_present_but_empty = True
        sig.empty_transcript_names = [p.name for p in present]
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


def _detect_empty_transcript(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    """Harness wrote a transcript file but it's empty (0 bytes). The agent
    never produced output — e.g. the opencode-gpt launch-hang. Distinct from
    a *missing* transcript (pre-result / incomplete artifacts), which stays
    ok at this layer."""
    if not sig.transcript_present_but_empty:
        return False, "", {}
    return True, (
        f"Agent transcript present but empty: {sig.empty_transcript_names} "
        f"— harness launched but produced no output (patch is empty too)"
    ), {"empty_transcripts": sig.empty_transcript_names}


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


def _detect_opencode_backend_error(sig: TrialSignals) -> tuple[bool, str, dict[str, Any]]:
    """opencode step(s) ended with reason=error — the codex OAuth backend
    returning 503/429/overloaded (turn ends with 0 output tokens). Reaches
    this detector only when the patch is empty (gated in classify_trial), so
    a trial that errored on some turns but still produced a real diff stays
    ``ok``. This is the dominant opencode-gpt failure: ~50% of the gpt cohort
    at 50 workers were silent codex errors the sentinel previously missed."""
    if sig.backend_error_turns < 1:
        return False, "", {}
    return True, (
        f"opencode backend errored on {sig.backend_error_turns}/"
        f"{sig.assistant_turn_count} step(s) (codex 503/429/overloaded — "
        f"turn ended with 0 tokens) and the patch is empty"
    ), {
        "backend_error_turns": sig.backend_error_turns,
        "assistant_turns": sig.assistant_turn_count,
        "patch_bytes": sig.patch_bytes,
    }


# Order matters: most specific provider signature first; the catch-all
# "no_agent_progress" detector runs last so a real provider error gets the
# precise reason in its sidecar instead of the generic one.
DETECTORS: list[tuple[str, Any]] = [
    ("empty_transcript", _detect_empty_transcript),
    ("provider_402_balance", _detect_provider_402_balance),
    ("provider_429_quota", _detect_provider_429_quota),
    ("provider_401_auth", _detect_provider_401_auth),
    ("provider_html_error", _detect_provider_html_error),
    ("parse_failure_corruption", _detect_parse_failure_corruption),
    ("opencode_backend_error", _detect_opencode_backend_error),
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


# ──────────────────────────────────────────────────────────────────────────
# Batch-audit detectors (from analysis/INFRA_BUG_CHECKLIST.md)
#
# A richer 13-detector pass that operates on trial-dir contents directly
# (vs the 6 transcript-based detectors above used for per-cell
# classification). Used by the batch CLI to report bug-category counts +
# rerun-worthy candidates across many trials at once.
#
# Conceptual relationship to the per-cell sentinel above:
#   - The per-cell sentinel (classify_trial) classifies ONE trial as
#     ok / infra_failed for the canonical state machine. Cheap, sidecar-
#     cached, ~6 transcript pattern detectors.
#   - These batch detectors (BUG_DETECTORS below) cover ~13 specific
#     bug classes from the checklist, including non-transcript signals
#     (result.json fields, exit_status across turn-N.json files, patch
#     capture gaps, etc.). Used by the CLI for cohort-level reporting.
# ──────────────────────────────────────────────────────────────────────────

import glob as _glob
import subprocess as _subprocess
from collections import defaultdict as _defaultdict


def _expand_roots(args: list[str]) -> list[Path]:
    """Accept glob patterns or explicit dir names. Filter to existing dirs."""
    out: list[Path] = []
    for a in args:
        for m in _glob.glob(a) if ("*" in a or "?" in a) else [a]:
            p = Path(m)
            if p.is_dir():
                out.append(p)
    return sorted(set(out))


def _iter_trials(roots: list[Path]):
    for root in roots:
        for t in root.iterdir():
            if t.is_dir() and not t.name.startswith("_"):
                yield t


def _read_text(path: Path, limit: int | None = None) -> str:
    """Best-effort text read for detector snippets."""
    if not path.exists():
        return ""
    try:
        txt = path.read_text(errors="ignore")
    except Exception:
        return ""
    if limit is not None:
        return txt[:limit]
    return txt


def _trial_text(trial: Path, limit_per_file: int = 200_000) -> str:
    """Concatenate the high-signal logs/transcripts for string detectors."""
    parts = [
        _read_text(trial / "trial.log", limit_per_file),
        _read_text(trial / "agent" / "mini-swe-agent.txt", limit_per_file),
        _read_text(trial / "agent" / "opencode.txt", limit_per_file),
        _read_text(trial / "agent" / "claude-code.txt", limit_per_file),
    ]
    for stderr in trial.glob("agent/command-*/*stderr.txt"):
        parts.append(_read_text(stderr, 50_000))
    return "\n".join(p for p in parts if p)


def _result_exception_type(trial: Path) -> str:
    try:
        data = json.loads((trial / "result.json").read_text(errors="ignore"))
    except Exception:
        return ""
    exc = data.get("exception_info")
    if not isinstance(exc, dict):
        return ""
    return str(exc.get("exception_type") or "")


def _patch_is_empty_or_missing(patch: Path) -> bool:
    if not patch.exists():
        return True
    try:
        return patch.stat().st_size <= EMPTY_PATCH_BYTES
    except OSError:
        return True


def _has_real_turn_patch(trial: Path) -> bool:
    for patch in trial.glob("agent/patches/*.patch"):
        txt = _read_text(patch, 500_000)
        if txt.startswith("diff --git ") or "\ndiff --git " in txt:
            return True
    return False


# ── Individual bug detectors ─────────────────────────────────────────────


def detect_A1_venv_pip(trial: Path) -> bool:
    """A1: mini-swe-agent install fail on venv-activated image."""
    tlog = trial / "trial.log"
    if not tlog.exists():
        return False
    if "Agent setup failed" not in tlog.read_text(errors="ignore"):
        return False
    stderr = trial / "agent" / "setup" / "stderr.txt"
    return stderr.exists() and "Can not perform a '--user' install" in stderr.read_text(errors="ignore")


def detect_A1b_minisweagent_posixpath(trial: Path) -> bool:
    """A1 variant: mini-swe-agent CLI PosixPath('.') startup crash."""
    msa_txt = trial / "agent" / "mini-swe-agent.txt"
    if not msa_txt.exists():
        return False
    txt = msa_txt.read_text(errors="ignore")[:50_000]
    return "PosixPath" in txt and "empty name" in txt


def detect_A2_e2b_429(trial: Path) -> bool:
    """A2: E2B 100-sandbox cap saturation + retry exhausted."""
    tlog = trial / "trial.log"
    return tlog.exists() and "429: Rate limit" in tlog.read_text(errors="ignore")


def detect_A3_verifier_timeout(trial: Path) -> bool:
    """A3: 600s verifier test.sh timeout."""
    tlog = trial / "trial.log"
    return tlog.exists() and "Verifier execution timed out" in tlog.read_text(errors="ignore")


def detect_B1_mini_badrequest(trial: Path) -> int:
    """B1: mini-swe-agent BadRequestError turns (codex OAuth empty BadRequest)."""
    n = 0
    for tj in trial.glob("agent/mini-swe-agent.trajectory.turn-*.json"):
        try:
            j = json.loads(tj.read_text(errors="ignore"))
            if j.get("info", {}).get("exit_status") == "BadRequestError":
                n += 1
        except Exception:
            pass
    return n


def detect_B2_opencode_413(trial: Path) -> bool:
    """B2: opencode RequestEntityTooLarge (codex backend ~1MB body cap)."""
    oc = trial / "agent" / "opencode.txt"
    if not oc.exists():
        return False
    txt = oc.read_text(errors="ignore")
    return "Request Entity Too Large" in txt or "ContextOverflowError" in txt


def detect_B3_opencode_typeval(trial: Path) -> bool:
    """B3: opencode Type validation failed (oauth_proxy raw 503 leak)."""
    oc = trial / "agent" / "opencode.txt"
    return oc.exists() and "Type validation failed" in oc.read_text(errors="ignore")


def detect_B4_per_exec_cap(trial: Path) -> bool:
    """B4: PER_EXEC_CAP_SEC 1800s wall-clock cap hit."""
    try:
        res = _subprocess.run(
            ["grep", "-rlE", "exec capped at 1800s", str(trial)],
            capture_output=True, text=True, timeout=10,
        )
        return bool(res.stdout.strip())
    except Exception:
        return False


def detect_B6_outer_agent_timeout(trial: Path) -> bool:
    """B6: Harbor-level agent timeout (AgentTimeoutError after --agent-timeout)."""
    return _result_exception_type(trial) == "AgentTimeoutError"


def detect_B7_provider_or_proxy_error(trial: Path) -> bool:
    """B7: Provider/proxy failure that can leave no patch without result.exception_info."""
    txt = _trial_text(trial)
    needles = (
        "InternalServerError: OpenAIException - Connection error",
        "litellm.InternalServerError",
        "litellm.RateLimitError",
        "API Error: 429",
        "API Error: 402",
        "API Error: 401",
        "Insufficient Balance",
        "Too Many Requests",
        "rate_limit_exceeded",
    )
    return any(n in txt for n in needles)


def detect_B8_tool_or_env_access_mismatch(trial: Path) -> bool:
    """B8: Tool/environment mismatch (external_directory denied, pwsh missing)."""
    txt = _trial_text(trial)
    return (
        ("permission requested:" in txt and "external_directory" in txt)
        or "The user rejected permission to use this specific tool call" in txt
        or "pwsh: command not found" in txt
    )


def detect_B9_final_patch_capture_gap(trial: Path) -> bool:
    """B9: final.patch empty/missing, but turn patches contain real git diffs."""
    return _patch_is_empty_or_missing(trial / "agent" / "final.patch") and _has_real_turn_patch(trial)


def detect_B10_missing_result_or_artifacts(trial: Path) -> bool:
    """B10: Trial dir incomplete enough that normal post-run artifacts are absent."""
    if (trial / "result.json").exists():
        return False
    has_agent_patch = (trial / "agent" / "final.patch").exists()
    has_agent_transcript = any(
        (trial / "agent" / name).exists()
        for name in ("mini-swe-agent.txt", "opencode.txt", "claude-code.txt")
    )
    has_reward = (trial / "verifier" / "reward.txt").exists()
    return (not has_agent_patch and not has_agent_transcript) or (has_reward and not has_agent_transcript)


def detect_B11_empty_transcript(trial: Path) -> bool:
    """B11: agent transcript file present but empty (0 bytes) — the harness
    launched but the agent produced no output. Distinct from B10 (transcript
    *missing*): here result.json + a (0-byte) transcript both exist, so the
    trial looks complete but is a dead data point. This is the opencode-gpt
    launch-hang (9 lite70 tasks, 3/3 reps each, ~12% of the gpt cohort)."""
    agent = trial / "agent"
    present = [agent / n for n in AGENT_TRANSCRIPT_NAMES if (agent / n).exists()]
    if not present:
        return False
    return all(_is_empty_transcript(p) for p in present)


# ──────────────────────────────────────────────────────────────────────
# Rerun policy
# ──────────────────────────────────────────────────────────────────────
# A trial is rerun-worthy iff it carries at least one INFRA code from
# INFRA_CODES_RERUN_WORTH AND (no reward.txt OR empty/missing patch).
# Trials with infra signals that still produced a useful patch + reward
# DO NOT need rerun — the model recovered through transient infra noise.

INFRA_CODES_RERUN_WORTH = ("B2", "B3", "B7", "B8", "B9", "B10", "B11", "A2")
INFRA_CODES_FAIR_ZERO   = ("B4", "B6", "A1", "A1b", "B1", "A3")

BUG_DETECTORS: list[tuple[str, str, Any]] = [
    ("A1", "venv pip --user install fail (mini-swe-agent setup)", detect_A1_venv_pip),
    ("A1b", "mini-swe-agent CLI PosixPath('.') startup crash", detect_A1b_minisweagent_posixpath),
    ("A2", "E2B 429 rate-limit retry exhausted (>100 concurrent sandboxes)", detect_A2_e2b_429),
    ("A3", "Verifier 600s test.sh timeout", detect_A3_verifier_timeout),
    ("B2", "opencode RequestEntityTooLarge (codex body cap)", detect_B2_opencode_413),
    ("B3", "opencode Type validation failed (oauth_proxy 503 leak)", detect_B3_opencode_typeval),
    ("B4", "PER_EXEC_CAP_SEC 1800s wall-clock cap hit", detect_B4_per_exec_cap),
    ("B6", "Harbor outer AgentTimeoutError (--agent-timeout)", detect_B6_outer_agent_timeout),
    ("B7", "provider/proxy connection/rate-limit/auth/balance error", detect_B7_provider_or_proxy_error),
    ("B8", "tool/env access mismatch (external_dir denied, pwsh missing)", detect_B8_tool_or_env_access_mismatch),
    ("B9", "final.patch empty but turn patches contain real git diffs", detect_B9_final_patch_capture_gap),
    ("B10", "missing result.json / incomplete trial artifacts", detect_B10_missing_result_or_artifacts),
    ("B11", "agent transcript present but empty (harness launched, no output)", detect_B11_empty_transcript),
]


def classify_rerun_worthiness(trial: Path) -> dict:
    """Return {'codes': sorted_codes, 'worth_rerun': bool, 'reason': str}.

    Rerun-worthy = (≥1 INFRA_CODES_RERUN_WORTH code present)
                   AND (no reward.txt OR empty/missing patch).
    """
    codes: set[str] = set()
    for code, _, fn in BUG_DETECTORS:
        try:
            if fn(trial):
                codes.add(code)
        except Exception:
            pass
    reward_path = trial / "verifier" / "reward.txt"
    patch_path  = trial / "agent" / "final.patch"
    has_reward = reward_path.exists()
    empty_patch = _patch_is_empty_or_missing(patch_path)

    infra_codes = {c for c in codes if c in INFRA_CODES_RERUN_WORTH}
    if not infra_codes:
        return {"codes": sorted(codes), "worth_rerun": False,
                "reason": "no infra-class signal (model failure or clean)"}
    if has_reward and not empty_patch:
        return {"codes": sorted(codes), "worth_rerun": False,
                "reason": f"infra ({sorted(infra_codes)}) was absorbed — model still produced reward + patch"}
    if not has_reward:
        return {"codes": sorted(codes), "worth_rerun": True,
                "reason": f"infra ({sorted(infra_codes)}) + no reward.txt"}
    return {"codes": sorted(codes), "worth_rerun": True,
            "reason": f"infra ({sorted(infra_codes)}) + empty patch"}


def partition_rerun_candidates(trials):
    """Iter over (trial, classification) tuples for batch scripts."""
    for t in trials:
        yield t, classify_rerun_worthiness(t)


# ──────────────────────────────────────────────────────────────────────────
# CLI — batch infra audit (was scripts/_run_infra_audit.py before merge)
# ──────────────────────────────────────────────────────────────────────────

_CLI_DOC = """Automated infra-bug audit for a batch of trial dirs.

Usage:
    python src/eval_infra_sentinel.py 'trials_new29_*'
    python src/eval_infra_sentinel.py trials_my_cohort_r1 trials_my_cohort_r2

Detects every bug catalogued in analysis/INFRA_BUG_CHECKLIST.md and reports
counts + sample trials. Exit code = number of bug categories with hits.
Suitable for CI / post-batch sanity check.
"""


def _cli_main(argv: list[str]) -> int:
    if not argv:
        print(_CLI_DOC)
        return 0
    roots = _expand_roots(argv)
    if not roots:
        print(f"no matching trial-root dirs for: {argv}")
        return 0
    print(f"Auditing {len(roots)} trial-root dirs: {[r.name for r in roots]}")
    trials = list(_iter_trials(roots))
    print(f"Total trials: {len(trials)}\n")

    findings = _defaultdict(list)
    b1_total = 0
    for t in trials:
        for code, _, fn in BUG_DETECTORS:
            if fn(t):
                findings[code].append(str(t))
        b1_total += detect_B1_mini_badrequest(t)

    print("=" * 72)
    print(f"{'BUG':<6}  {'HITS':>5}  DESCRIPTION")
    print("-" * 72)
    n_with_hits = 0
    for code, desc, _ in BUG_DETECTORS:
        hits = len(findings[code])
        if hits:
            n_with_hits += 1
            print(f"{code:<6}  {hits:>5}  {desc}")
            for sample in findings[code][:3]:
                print(f"           sample: {sample}")
        else:
            print(f"{code:<6}  {'-':>5}  {desc}")
    if b1_total:
        n_with_hits += 1
        print(f"B1     {b1_total:>5}  mini-swe-agent BadRequestError turn-level count")
    else:
        print(f"B1     {'-':>5}  mini-swe-agent BadRequestError turn-level count")
    print("=" * 72)
    if n_with_hits == 0:
        print("✓ all detectors clean")
    else:
        print(f"⚠ {n_with_hits} bug categories with hits — see analysis/INFRA_BUG_CHECKLIST.md")

    rerun_worth = []
    fair_zero_infra = []
    for t in trials:
        cls = classify_rerun_worthiness(t)
        if cls["worth_rerun"]:
            rerun_worth.append((t, cls))
        elif cls["codes"] and any(c in INFRA_CODES_FAIR_ZERO for c in cls["codes"]):
            fair_zero_infra.append((t, cls))
    print(f"\n{'─' * 72}")
    print(f"Rerun-worthy infra failures: {len(rerun_worth)}")
    for t, cls in rerun_worth[:20]:
        print(f"  {t.parent.name}/{t.name}  codes={cls['codes']}  {cls['reason']}")
    if len(rerun_worth) > 20:
        print(f"  … and {len(rerun_worth) - 20} more")
    print(f"Fair-zero (model didn't finish): {len(fair_zero_infra)}")
    print("─" * 72)
    return n_with_hits


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(_cli_main(_sys.argv[1:]))
