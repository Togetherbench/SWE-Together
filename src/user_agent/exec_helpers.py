"""Bounded exec helper for the multi-turn wrappers.

Why this exists: a single `environment.exec()` can block indefinitely —
e.g. gpt-5.5 (reasoning) via OpenRouter occasionally enters an "I'm still
thinking…" stream that never emits a final answer, so the codex CLI waits
for the next token forever (observed in gpt55_codex_scout_v3 r2/r3, each
burned 3h25m wall-clock on one stuck exec before being killed manually).

The wrappers' multi-turn loop has a `_TRIAL_BUDGET_SEC` guard, but that
fires *between* turns — if a single exec never returns, the guard never
gets a chance to run.

All wrappers — including claude_code — now run turns through this, so a
slow/stuck turn is capped per-exec and cap-rescued (resume on next turn)
rather than killing the trial.

Default caps (shared by every harness):
  - PER_EXEC_CAP_SEC (1800) — per-turn single-call ceiling (30m).
  - TRIAL_BUDGET_SEC (5400) — total per-trial budget (90m), set equal to
    the E2B sandbox lifetime so the wrapper's own budget is the real
    ceiling and stops cleanly, instead of the sandbox dying mid-trial.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass

log = logging.getLogger(__name__)

import os

TRIAL_BUDGET_SEC = int(os.environ.get("TRIAL_BUDGET_SEC", "5400"))
PER_EXEC_CAP_SEC = int(os.environ.get("PER_EXEC_CAP_SEC", "1800"))


@dataclass
class _TimeoutResult:
    """ExecResult-shaped synthetic for the timeout case.

    Mirrors the attributes the wrappers read off harbor's exec result
    (`return_code`, `stdout`, `stderr`) so callers don't need a branch.
    """
    return_code: int = -1
    stdout: str = ""
    stderr: str = ""


async def exec_with_budget(environment, exec_input, *, start_time: float):
    """Run one ExecInput with the trial-budget + per-exec cap.

    Wraps the underlying `environment.exec()` in `asyncio.wait_for` so a
    hung sandbox call can't burn the whole trial.

    Returns ``(result, timed_out)``. On timeout, ``result`` is a synthetic
    ``_TimeoutResult`` with ``return_code=-1`` and a diagnostic stderr —
    callers can keep their existing ``result.stdout`` / ``result.stderr``
    / ``result.return_code`` paths and decide whether to ``break`` the
    multi-turn loop based on ``timed_out``.

    `set -o pipefail; ...` is prepended to the command (matching what
    every existing call-site already does).
    """
    elapsed = time.monotonic() - start_time
    remaining = max(TRIAL_BUDGET_SEC - elapsed, 1.0)
    cap_sec = int(min(remaining, PER_EXEC_CAP_SEC))

    try:
        result = await asyncio.wait_for(
            environment.exec(
                command=f"set -o pipefail; {exec_input.command}",
                cwd=exec_input.cwd,
                env=exec_input.env,
                timeout_sec=cap_sec,
            ),
            # +30s slack so e2b's own timeout_sec fires first if respected
            timeout=cap_sec + 30,
        )
        return result, False
    except asyncio.TimeoutError:
        msg = (
            f"[wrapper] exec capped at {cap_sec}s "
            f"(trial budget remaining {int(remaining)}s) — abandoning call"
        )
        log.warning(msg)
        return _TimeoutResult(stderr=msg), True
