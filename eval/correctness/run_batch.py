"""Batch agentic judge runner.

Reads a JSON plan file describing many trial × out_name jobs, runs them in
parallel via an asyncio.Semaphore-bounded pool, writes per-trial verdict files,
and prints a summary at the end.

Usage:
    .venv/bin/python -m eval.correctness.run_batch --plan plan.json --workers 50

Plan file shape (JSON list):
    [
      {"trial_dir": "<abs path>", "task_dir": "<abs path>",
       "out_name": "judge_verdict_run1.json"},
      ...
    ]

Each job becomes one E2B sandbox. WORKERS=50 means at most 50 sandboxes alive
concurrently; the rest queue.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any

from eval.correctness.judge_one import _validate_schema, load_dotenv, load_inputs
from eval.correctness.sandbox import run_judge_in_e2b, judge_timeout_for_task

log = logging.getLogger(__name__)


async def _one(job: dict, oauth_token: str, sem: asyncio.Semaphore,
               *, timeout_sec: int, max_turns: int, force: bool,
               api_key: str | None = None) -> dict:
    trial_dir = Path(job["trial_dir"]).expanduser()
    task_dir = Path(job["task_dir"]).expanduser()
    out_name = job["out_name"]
    out_path = trial_dir / out_name
    result: dict[str, Any] = {
        "trial_dir": str(trial_dir),
        "task_dir": str(task_dir),
        "out_name": out_name,
    }

    if out_path.exists() and not force:
        result["status"] = "skipped_existing"
        return result

    try:
        inputs = load_inputs(trial_dir, task_dir)
    except FileNotFoundError as e:
        result["status"] = "skipped_missing_input"
        result["reason"] = str(e)
        return result

    # Per-task budget override for heavy-build tasks (e.g. Go monorepos that
    # spend most of their judge sandbox on `go build` + `go test`).
    effective_timeout = max(timeout_sec, judge_timeout_for_task(task_dir.name))
    async with sem:
        t0 = time.time()
        log.info("start %s out=%s timeout=%ds", trial_dir.name, out_name, effective_timeout)
        try:
            sb_result = await run_judge_in_e2b(
                task_name=task_dir.name,
                trial_id=trial_dir.name,
                inputs=inputs,
                oauth_token=oauth_token,
                timeout_sec=effective_timeout,
                max_turns=max_turns,
                api_key=api_key,
            )
        except Exception as e:
            result["status"] = "error"
            result["reason"] = f"{type(e).__name__}: {e}"
            log.warning("error %s: %s", trial_dir.name, result["reason"])
            return result

        elapsed = time.time() - t0
        verdict = dict(sb_result.verdict)
        verdict.setdefault("task", task_dir.name)
        verdict.setdefault("trial_id", trial_dir.name)
        reward_p = trial_dir / "verifier" / "reward.txt"
        if reward_p.exists():
            try:
                verdict["test_reward_raw"] = float(reward_p.read_text().strip())
            except ValueError:
                pass
        js = verdict.get("judge_score")
        tr = verdict.get("test_reward_raw")
        if js is not None and tr is not None:
            d = float(js) - float(tr)
            verdict["direction"] = "unchanged" if abs(d) < 1e-6 else ("upgrade" if d > 0 else "downgrade")
            verdict["score_delta"] = round(d, 4)
        verdict["judge_elapsed_sec"] = round(elapsed, 1)
        verdict["sandbox_id"] = sb_result.sandbox_id
        verdict["judge_exit_code"] = sb_result.exit_code

        warnings = _validate_schema(verdict)
        if warnings:
            verdict["schema_warnings"] = warnings

        out_path.write_text(json.dumps(verdict, indent=2))
        result["status"] = "ok" if "error" not in verdict else "verdict_error"
        result["judge_score"] = verdict.get("judge_score")
        result["test_reward_raw"] = verdict.get("test_reward_raw")
        result["verdict"] = verdict.get("verdict")
        result["direction"] = verdict.get("direction")
        result["elapsed_sec"] = round(elapsed, 1)
        result["schema_warnings"] = warnings
        log.info(
            "done %s score=%s verdict=%s elapsed=%.1fs",
            trial_dir.name, result["judge_score"], result["verdict"], elapsed,
        )
        return result


async def amain() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--timeout-sec", type=int, default=600)
    ap.add_argument("--max-turns", type=int, default=50)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--summary", type=Path, default=None,
                    help="write JSON summary of all results (default: <plan>.summary.json)")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    load_dotenv()
    # Require E2B_API_KEY always; require AT LEAST ONE of (ANTHROPIC_API_KEY,
    # CLAUDE_CODE_OAUTH_TOKEN). When both present, ANTHROPIC_API_KEY wins
    # (independent pay-per-token quota).
    if not os.environ.get("E2B_API_KEY"):
        print("ERROR: E2B_API_KEY not set", file=sys.stderr)
        return 2
    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")):
        print("ERROR: need ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN", file=sys.stderr)
        return 2

    if not args.plan.exists():
        print(f"ERROR: plan not found: {args.plan}", file=sys.stderr)
        return 2
    jobs = json.loads(args.plan.read_text())
    if not isinstance(jobs, list):
        print("ERROR: plan must be a JSON list", file=sys.stderr)
        return 2

    print(f"queued {len(jobs)} jobs, workers={args.workers}")
    sem = asyncio.Semaphore(args.workers)
    oauth = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    api_key = os.environ.get("ANTHROPIC_API_KEY") or None
    auth_kind = "ANTHROPIC_API_KEY (pay-per-token)" if api_key else "CLAUDE_CODE_OAUTH_TOKEN (subscription)"
    print(f"judge auth: {auth_kind}")
    t0 = time.time()

    tasks = [
        asyncio.create_task(_one(
            j, oauth, sem,
            timeout_sec=args.timeout_sec,
            max_turns=args.max_turns,
            force=args.force,
            api_key=api_key,
        ))
        for j in jobs
    ]
    results = await asyncio.gather(*tasks)
    elapsed = time.time() - t0

    summary_path = args.summary or args.plan.with_suffix(".summary.json")
    summary = {
        "plan": str(args.plan),
        "workers": args.workers,
        "elapsed_sec": round(elapsed, 1),
        "n_jobs": len(jobs),
        "results": results,
    }
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nwrote summary to {summary_path}")

    # Stdout table
    counts: dict[str, int] = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"\nDone in {elapsed:.1f}s")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    return 0


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
