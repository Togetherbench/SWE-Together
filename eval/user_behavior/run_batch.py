"""Batch intent-coverage judge runner.

Reads a JSON plan file describing many trial × task pairs, runs the per-trial
coverage judge in parallel via an asyncio.Semaphore-bounded pool, writes per-trial
verdict files, and prints a summary at the end.

Usage:
    .venv/bin/python -m eval.user_behavior.run_batch \\
        --plan pipeline_logs/intent_coverage_plan.json \\
        --workers 5

Plan file shape (JSON list):
    [
      {"trial_dir": "<abs path>", "task_dir": "<abs path>",
       "out_name": "intent_coverage_verdict.json"},
      ...
    ]

No sandbox, no E2B. Just LLM API calls (default: anthropic/claude-sonnet-4-6),
so concurrency is bounded by ANTHROPIC_API_KEY rate limits rather than E2B.
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

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT / "external" / "harbor" / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from eval.user_behavior.coverage_one import (  # noqa: E402
    DEFAULT_MODEL, judge_one_trial, load_dotenv,
)


logger = logging.getLogger(__name__)


async def _run_one(job: dict, sem: asyncio.Semaphore, model: str) -> dict:
    async with sem:
        trial_dir = Path(job["trial_dir"]).resolve()
        task_dir = Path(job["task_dir"]).resolve()
        out_name = job.get("out_name", "intent_coverage_verdict.json")

        if not trial_dir.exists():
            return {**job, "status": "trial_dir_missing"}
        if not task_dir.exists():
            return {**job, "status": "task_dir_missing"}

        out_path = trial_dir / out_name
        if out_path.exists() and not job.get("force"):
            try:
                v = json.loads(out_path.read_text())
                logger.info("skip-existing %s (overall=%.3f)", trial_dir.name,
                            v.get("overall_score", float("nan")))
                return {**job, "status": "skip_existing", **{k: v.get(k) for k in
                        ("n_oracle_turns", "n_trial_msgs", "coverage_rate",
                         "weighted_coverage", "scope_precision", "overall_score")}}
            except (json.JSONDecodeError, OSError):
                pass

        t0 = time.monotonic()
        try:
            v = await judge_one_trial(
                trial_dir=trial_dir, task_dir=task_dir,
                model=model, out_name=out_name,
            )
            elapsed = time.monotonic() - t0
            logger.info("done %s elapsed=%.1fs overall=%.3f cov=%.2f scope=%.2f warn=%d",
                        trial_dir.name, elapsed,
                        v["overall_score"], v["coverage_rate"], v["scope_precision"],
                        len(v["schema_warnings"]))
            return {**job, "status": "ok", **{k: v.get(k) for k in
                    ("n_oracle_turns", "n_trial_msgs", "coverage_rate",
                     "weighted_coverage", "scope_precision", "overall_score",
                     "schema_warnings", "elapsed_sec")}}
        except Exception as exc:
            elapsed = time.monotonic() - t0
            logger.warning("fail %s after %.1fs: %s", trial_dir.name, elapsed, exc)
            return {**job, "status": "error", "error": f"{type(exc).__name__}: {exc}"}


async def amain() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=5,
                    help="Concurrent LLM calls (default: 5)")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--force", action="store_true",
                    help="Overwrite existing verdicts")
    ap.add_argument("--summary", type=Path, default=None,
                    help="Write a summary JSON here (default: alongside plan)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(REPO_ROOT)

    jobs = json.loads(args.plan.read_text())
    if args.force:
        for j in jobs: j["force"] = True
    logger.info("loaded %d jobs from %s (workers=%d, model=%s)",
                len(jobs), args.plan, args.workers, args.model)

    sem = asyncio.Semaphore(args.workers)
    t0 = time.monotonic()
    results = await asyncio.gather(*(_run_one(j, sem, args.model) for j in jobs))
    elapsed = time.monotonic() - t0

    # Status histogram
    statuses = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    logger.info("done in %.1fs; status: %s", elapsed, statuses)

    summary_path = args.summary or args.plan.with_suffix(".summary.json")
    summary = {
        "plan": str(args.plan),
        "model": args.model,
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
