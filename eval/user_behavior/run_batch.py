"""Batch user-behavior runner — fans out `measure_one_trial` across a plan file.

No LLM calls, no E2B; the per-trial work is pure file I/O on existing
artefacts so this is concurrency-cheap. We keep the async-pool shape to mirror
`eval/intent_coverage/run_batch.py` and `eval/correctness/run_batch.py` so the
three evaluators have the same CLI.

Usage:
    .venv/bin/python -m eval.user_behavior.run_batch \\
        --plan pipeline_logs/user_behavior_plan.json \\
        --workers 16

Plan file shape (JSON list):
    [
      {"trial_dir": "<abs path>", "task_dir": "<abs path>",
       "out_name": "user_behavior_verdict.json"},
      ...
    ]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any

from eval.user_behavior.behavior_one import measure_one_trial

logger = logging.getLogger(__name__)


async def _run_one(job: dict, sem: asyncio.Semaphore) -> dict:
    async with sem:
        trial_dir = Path(job["trial_dir"]).resolve()
        task_dir = Path(job["task_dir"]).resolve()
        out_name = job.get("out_name", "user_behavior_verdict.json")

        if not trial_dir.exists():
            return {**job, "status": "trial_dir_missing"}
        if not task_dir.exists():
            return {**job, "status": "task_dir_missing"}

        out_path = trial_dir / out_name
        if out_path.exists() and not job.get("force"):
            try:
                v = json.loads(out_path.read_text())
                return {**job, "status": "skip_existing",
                        **{k: v.get(k) for k in
                           ("intervention_count", "effort_cost",
                            "hard_cap_abandon", "specificity_present")}}
            except (json.JSONDecodeError, OSError):
                pass

        t0 = time.monotonic()
        try:
            v = await asyncio.to_thread(
                measure_one_trial, trial_dir, task_dir, out_name
            )
            elapsed = time.monotonic() - t0
            logger.info(
                "done %s elapsed=%.2fs intv=%d effort=%s cap=%s",
                trial_dir.name, elapsed,
                v["intervention_count"], v["effort_cost"], v["hard_cap_abandon"],
            )
            return {**job, "status": "ok",
                    **{k: v.get(k) for k in
                       ("intervention_count", "no_op_count", "effort_cost",
                        "hard_cap_abandon", "specificity_present",
                        "per_tier_count", "per_action_count", "elapsed_sec")}}
        except Exception as exc:
            elapsed = time.monotonic() - t0
            logger.warning("fail %s after %.2fs: %s", trial_dir.name, elapsed, exc)
            return {**job, "status": "error",
                    "error": f"{type(exc).__name__}: {exc}"}


async def amain() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=16,
                    help="Concurrent file-I/O workers (default: 16)")
    ap.add_argument("--force", action="store_true",
                    help="Overwrite existing verdicts")
    ap.add_argument("--summary", type=Path, default=None,
                    help="Write a summary JSON here (default: alongside plan)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    jobs = json.loads(args.plan.read_text())
    if args.force:
        for j in jobs:
            j["force"] = True
    logger.info("loaded %d jobs from %s (workers=%d)",
                len(jobs), args.plan, args.workers)

    sem = asyncio.Semaphore(args.workers)
    t0 = time.monotonic()
    results = await asyncio.gather(*(_run_one(j, sem) for j in jobs))
    elapsed = time.monotonic() - t0

    statuses: dict[str, int] = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    logger.info("done in %.1fs; status: %s", elapsed, statuses)

    summary_path = args.summary or args.plan.with_suffix(".summary.json")
    summary: dict[str, Any] = {
        "plan": str(args.plan),
        "workers": args.workers,
        "elapsed_sec": elapsed,
        "n_jobs": len(jobs),
        "status_counts": statuses,
        "results": results,
    }
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    logger.info("summary → %s", summary_path)
    return 0 if statuses.get("error", 0) == 0 else 1


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
