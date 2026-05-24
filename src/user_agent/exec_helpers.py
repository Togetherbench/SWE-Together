"""Bounded exec helper for sequential-rerun wrappers (codex, gemini_cli).

Why this exists: codex and gemini_cli have no `--resume` mechanism, so each
turn re-issues a fresh `codex exec` / `gemini` with the full conversation
history. Two failure modes have been observed where a single
`environment.exec()` blocks indefinitely:

  1. gpt-5.5 (reasoning model) via OpenRouter occasionally enters a "I'm
     still thinking…" stream that never emits a final answer — codex CLI
     waits for next token forever. Observed in gpt55_codex_scout_v3 r2/r3,
     both burned 3h25m wall-clock on a single stuck exec before being
     killed manually.
  2. Gemini 3.1 Pro CLI similarly hangs on complex multi-fix tasks
     (gemini31_scout_v3 turn-3 was stuck >50min before kill).

The wrappers' multi-turn loop has a `_TRIAL_BUDGET_SEC` guard, but that
fires *between* turns — if a single exec never returns, the guard never
gets a chance to run.

claude_code wrapper doesn't need this: `claude --resume` keeps each call
short (Anthropic only processes the new user message, not the full
re-prompt), and Anthropic API direct connection has no proxy hop.

Default caps:
  - TRIAL_BUDGET_SEC (3600) matches the `--agent-timeout 3600` runner.py
    arg that's standard across all our cohort scripts.
  - PER_EXEC_CAP_SEC (600) is a single-call ceiling: 10 minutes is well
    above the p99 turn duration observed for both codex and gemini, but
    bounded enough that a stuck call dies fast.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass

log = logging.getLogger(__name__)

TRIAL_BUDGET_SEC = 7200       # 2h. codex+gpt-5.5 is ~3× slower than claude_code+Opus.
                              # Opus p95 on Person A is 64 min, max 82 min; × 3 → 3-4h.
                              # 2h caps the long-tail without leaving the cohort exposed
                              # to a single 4h task; faster tasks (Opus median 6.5 min, codex
                              # ~20min) are unaffected.
PER_EXEC_CAP_SEC = 1200       # 20m, was 10m. Codex's longest legit single-exec on hard
                              # tasks is ~5-10 min (gpt-5.5 reasoning + 20+ shell commands).
                              # 20m gives ~2× safety margin without leaving truly stuck
                              # calls to burn the rest of the trial budget.


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
