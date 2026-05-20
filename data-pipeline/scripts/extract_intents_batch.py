#!/usr/bin/env python3
"""Batch wrapper around `eval.intent_coverage.extract_intents.extract_one`.

Walks `harbor_tasks/` (or any --tasks-root), finds tasks that have
`oracle_session.jsonl` but no `oracle_intents.json`, and runs Stage 1 of
the intent-coverage pipeline concurrently. Mirrors `eval/intent_coverage/run_batch.py`.

Existing `oracle_intents.json` files are skipped (idempotent). Pass --force
to refresh all targets.

Usage:
    .venv/bin/python data-pipeline/scripts/extract_intents_batch.py \\
        --tasks-root harbor_tasks \\
        --workers 5
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
for p in (REPO_ROOT, REPO_ROOT / "external" / "harbor" / "src"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from eval.intent_coverage.extract_intents import (  # noqa: E402
    DEFAULT_MODEL, extract_one, load_dotenv,
)

logger = logging.getLogger(__name__)


async def _run_one(
    task_dir: Path,
    sem: asyncio.Semaphore,
    model: str,
    out_name: str,
    force: bool,
) -> dict:
    async with sem:
        t0 = time.monotonic()
        try:
            result = await extract_one(
                task_dir=task_dir, model=model, out_name=out_name, force=force,
            )
            elapsed = time.monotonic() - t0
            n_intents = len(result.get("intents", []))
            logger.info(
                "done %s elapsed=%.1fs n_intents=%d turns_in=%d",
                task_dir.name, elapsed, n_intents,
                result.get("n_oracle_turns_in", 0),
            )
            return {
                "task": task_dir.name,
                "status": "ok",
                "n_intents": n_intents,
                "n_oracle_turns_in": result.get("n_oracle_turns_in", 0),
                "extractor_model": result.get("extractor_model"),
                "elapsed_sec": round(elapsed, 1),
            }
        except Exception as exc:
            elapsed = time.monotonic() - t0
            logger.warning("fail %s after %.1fs: %s", task_dir.name, elapsed, exc)
            return {
                "task": task_dir.name,
                "status": "error",
                "error": f"{type(exc).__name__}: {exc}",
                "elapsed_sec": round(elapsed, 1),
            }


def _discover_tasks(tasks_root: Path, out_name: str, force: bool) -> tuple[list[Path], list[str], list[str]]:
    """Return (todo, skipped_existing, skipped_no_session)."""
    todo, skip_existing, no_session = [], [], []
    for d in sorted(tasks_root.iterdir()):
        if not d.is_dir() or d.name.startswith("_") or d.name == "README.md":
            continue
        if not (d / "oracle_session.jsonl").exists():
            no_session.append(d.name)
            continue
        if (d / out_name).exists() and not force:
            skip_existing.append(d.name)
            continue
        todo.append(d)
    return todo, skip_existing, no_session


async def amain() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tasks-root", type=Path, default=REPO_ROOT / "harbor_tasks")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--out-name", default="oracle_intents.json")
    ap.add_argument("--force", action="store_true",
                    help="Re-extract even when oracle_intents.json already exists")
    ap.add_argument("--summary", type=Path, default=None,
                    help="Write a summary JSON here (default: pipeline_logs/extract_intents_summary.json)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(REPO_ROOT)

    tasks_root = args.tasks_root.resolve()
    if not tasks_root.is_dir():
        logger.error("tasks-root not a directory: %s", tasks_root)
        return 2

    todo, skip_existing, no_session = _discover_tasks(tasks_root, args.out_name, args.force)
    logger.info(
        "discovery: todo=%d skip_existing=%d no_session=%d (root=%s, force=%s)",
        len(todo), len(skip_existing), len(no_session), tasks_root, args.force,
    )
    if not todo:
        logger.info("nothing to do; exit 0")
        return 0

    sem = asyncio.Semaphore(args.workers)
    t0 = time.monotonic()
    results = await asyncio.gather(*(
        _run_one(d, sem, args.model, args.out_name, args.force) for d in todo
    ))
    elapsed = time.monotonic() - t0

    statuses: dict[str, int] = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    logger.info("done in %.1fs; status: %s", elapsed, statuses)

    summary_path = args.summary or (REPO_ROOT / "pipeline_logs" / "extract_intents_summary.json")
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary = {
        "tasks_root": str(tasks_root),
        "model": args.model,
        "workers": args.workers,
        "elapsed_sec": round(elapsed, 1),
        "n_todo": len(todo),
        "n_skip_existing": len(skip_existing),
        "n_no_session": len(no_session),
        "status_counts": statuses,
        "results": results,
        "skipped_existing": skip_existing,
        "no_session": no_session,
    }
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    logger.info("summary → %s", summary_path)
    return 0 if statuses.get("error", 0) == 0 else 1


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
