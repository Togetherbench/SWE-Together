#!/usr/bin/env python3
"""Streaming scaffold orchestrator: pre-seed a fixed list of Gemini-VIABLE sids,
AND simultaneously run Gemini screen on a "candidate pool" (e.g. step2-rejected
sids), feeding any newly-VIABLE results into the same scaffold queue as they
land. Single event loop, two concurrency budgets.

Output is identical to run_pipeline.py: harbor_tasks/<name>/ with the 8
standard files, per-task JSON in data-pipeline/scaffold/logs/.

Usage:
  python data-pipeline/scaffold/run_continuous.py \\
      --seed-sids /tmp/scaffold_batch3_sids.txt \\
      --rescreen-source step2-rejected \\
      --scaffold-workers 50 --gemini-workers 30 \\
      --template harbor-scaffold-cc2-1-108-8c-4g
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "data-pipeline" / "scaffold"))
sys.path.insert(0, str(ROOT / "data-pipeline" / "screening" / "scripts"))

from run_pipeline import (  # type: ignore
    _load_env_from_dotenv, _run_one_attempt, _run_one,
    synth_candidate, generate_task_name, get_existing_tasks,
    SC_SESSIONS_DIR, jsonl_to_dataclaw_session,
)
from step5_llm_screen_patches import judge_one  # type: ignore

ARTIFACTS = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
STEP1 = ARTIFACTS / "step1_all_sessions.json"
STEP2 = ARTIFACTS / "step2_candidates.json"
PATCHES_DIR = ARTIFACTS / "canonical_patches"
LOG_DIR = ROOT / "data-pipeline" / "scaffold" / "logs"
SUMMARY_PATH = LOG_DIR / "continuous_summary.json"
HF_REPO = "SALT-NLP/SWE-chat"


def _load_step1_meta() -> dict:
    if not STEP1.exists():
        return {}
    out = {}
    for r in json.load(open(STEP1)):
        sid = r.get("session_id")
        if sid:
            out[sid] = r
    return out


async def _prefetch_session_jsonl(sid: str) -> bool:
    """Fetch session jsonl from HF (serial-safe; pyarrow/HF cache handles concurrent OK).
    Returns True if cached, False on failure."""
    out = SC_SESSIONS_DIR / f"{sid}.json"
    if out.exists():
        return True
    try:
        from huggingface_hub import hf_hub_download
        # huggingface_hub is sync; offload to thread
        loop = asyncio.get_event_loop()
        tpath = await loop.run_in_executor(
            None, lambda: hf_hub_download(HF_REPO, f"transcripts/{sid}.jsonl", repo_type="dataset")
        )
        session = jsonl_to_dataclaw_session(Path(tpath), sid)
        json.dump(session, open(out, "w"), indent=2, default=str, ensure_ascii=False)
        return True
    except Exception as e:
        return False


async def _extract_canonical_patch(sid: str, sessions_df, commits_df) -> bool:
    """Pull the canonical patch (single-commit only) from cached parquet frames."""
    out = PATCHES_DIR / f"{sid}.json"
    if out.exists():
        return True
    matching_session = sessions_df[sessions_df["session_id"] == sid]
    if matching_session.empty:
        return False
    ckpt = matching_session.iloc[0]["canonical_checkpoint_pk"]
    if not ckpt:
        return False
    matches = commits_df[commits_df["checkpoint_pk"] == ckpt]
    if len(matches) != 1:
        return False  # skip multi-commit
    with_patch = matches[matches["patch"].notna() & (matches["patch"].str.len() > 0)]
    if with_patch.empty:
        return False
    best = with_patch.iloc[0]
    patch_text = best["patch"]
    truncated = False
    if len(patch_text) > 256 * 1024:
        patch_text = patch_text[:256 * 1024] + "\n…[truncated]"
        truncated = True
    json.dump({
        "session_id": sid,
        "checkpoint_pk": ckpt,
        "commits_in_checkpoint": 1,
        "commit_sha": best["commit_sha"],
        "is_agent_author": bool(best["is_agent_author"]),
        "files_changed_count": int(best["files_changed_count"]) if best["files_changed_count"] else 0,
        "total_additions": int(best["total_additions"]) if best["total_additions"] else 0,
        "total_deletions": int(best["total_deletions"]) if best["total_deletions"] else 0,
        "commit_message": best["commit_message"] or "",
        "files_changed": best["files_changed"] or "",
        "patch": patch_text,
        "patch_truncated": truncated,
        "agent_percentage": float(matching_session.iloc[0]["agent_percentage"]) if matching_session.iloc[0].get("agent_percentage") is not None else None,
    }, open(out, "w"), indent=2, default=str)
    return True


async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--seed-sids", required=True,
                   help="Path to file with comma-or-newline-separated session_ids (the pre-vetted batch 3 slate)")
    p.add_argument("--rescreen-source", choices=["step2-rejected", "none"], default="step2-rejected",
                   help="Which extra pool to Gemini-screen. step2-rejected = the 431 sids step2 rejected")
    p.add_argument("--scaffold-workers", type=int, default=50)
    p.add_argument("--gemini-workers", type=int, default=30)
    p.add_argument("--budget", type=float, default=5.0)
    p.add_argument("--template", default="harbor-scaffold-cc2-1-108-8c-4g")
    p.add_argument("--rescreen-limit", type=int, default=0, help="Cap rescreen pool (0=all)")
    args = p.parse_args()

    _load_env_from_dotenv()
    deepseek_key = os.environ.get("DEEPSEEK_API_KEY")
    e2b_key = os.environ.get("E2B_API_KEY") or os.environ.get("e2b_api_key")
    gemini_key = os.environ.get("GEMINI_API_KEY")
    if not deepseek_key or not e2b_key or not gemini_key:
        print(f"ERROR: missing keys (deepseek={bool(deepseek_key)} e2b={bool(e2b_key)} gemini={bool(gemini_key)})")
        return 2
    os.environ["E2B_API_KEY"] = e2b_key

    # 1. Load seed sids (Gemini-pre-vetted)
    seed_path = Path(args.seed_sids)
    raw = seed_path.read_text().replace("\n", ",")
    seed_sids = [s.strip() for s in raw.split(",") if s.strip()]
    print(f"Seed: {len(seed_sids)} pre-vetted sids from {seed_path.name}")

    # 2. Build the rescreen pool
    rescreen_sids: list[str] = []
    if args.rescreen_source == "step2-rejected":
        s1_sids = {r["session_id"] for r in json.load(open(STEP1))}
        s2_viable = {c["session_id"] for c in json.load(open(STEP2)) if c.get("verdict") == "VIABLE"}
        rescreen_sids = sorted(s1_sids - s2_viable)
        if args.rescreen_limit:
            rescreen_sids = rescreen_sids[: args.rescreen_limit]
        print(f"Rescreen pool: {len(rescreen_sids)} step2-rejected sids")

    # 3. Set up shared queue + dedup
    scaffold_queue: asyncio.Queue = asyncio.Queue()
    seen_in_queue: set[str] = set()
    existing_tasks = get_existing_tasks()

    def enqueue(sid: str, source: str) -> bool:
        if sid in seen_in_queue:
            return False
        # Skip if a harbor_tasks/<name>/ already exists (resume semantics)
        cand_for_name = synth_candidate(sid)
        name = generate_task_name(cand_for_name)
        if name in existing_tasks:
            return False
        seen_in_queue.add(sid)
        scaffold_queue.put_nowait((sid, source))
        return True

    # Pre-seed
    for sid in seed_sids:
        enqueue(sid, "seed")
    print(f"Pre-seeded queue with {scaffold_queue.qsize()} tasks (after dedup vs existing harbor_tasks/)")

    # 4. Pre-load parquet frames once (cheap with pushdown + already cached locally)
    sessions_df = None
    commits_df = None
    if rescreen_sids:
        print("\nLoading parquet frames for canonical patch extraction (cached, fast)…")
        from huggingface_hub import hf_hub_download
        import pyarrow.parquet as pq
        sf = hf_hub_download(HF_REPO, "sessions.parquet", repo_type="dataset")
        sessions_df = pq.read_table(
            sf,
            columns=["session_id", "canonical_checkpoint_pk", "agent_percentage", "files_touched_count"],
            filters=[("session_id", "in", rescreen_sids)],
        ).to_pandas()
        ckpts = sessions_df["canonical_checkpoint_pk"].dropna().unique().tolist()
        cf = hf_hub_download(HF_REPO, "commits.parquet", repo_type="dataset")
        commits_df = pq.read_table(
            cf,
            columns=["commit_sha", "checkpoint_pk", "patch", "files_changed_count",
                     "total_additions", "total_deletions", "commit_message",
                     "files_changed", "is_agent_author"],
            filters=[("checkpoint_pk", "in", ckpts)],
        ).to_pandas()
        print(f"  {len(sessions_df)} sessions, {len(commits_df)} commits loaded")

    # 5. Define async producers + consumers
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    s1_meta = _load_step1_meta()
    counters = {"scaffold_done": 0, "scaffold_err": 0, "scaffold_not_viable": 0,
                "gemini_viable": 0, "gemini_not_viable": 0, "gemini_error": 0}
    results: list[dict] = []
    rescreen_complete_event = asyncio.Event()

    scaffold_sem = asyncio.Semaphore(args.scaffold_workers)
    gemini_sem = asyncio.Semaphore(args.gemini_workers)

    def ts() -> str:
        return datetime.now().strftime("%H:%M:%S")

    async def gemini_producer():
        """Screen each rescreen sid: prefetch jsonl + extract patch + run Gemini judge.
        On VIABLE, enqueue to scaffold_queue."""
        if not rescreen_sids:
            rescreen_complete_event.set()
            return
        print(f"  [{ts()}] gemini_producer: starting on {len(rescreen_sids)} sids")
        n_done = 0

        async def screen_one(sid: str):
            nonlocal n_done
            try:
                # Prep: prefetch jsonl + extract canonical patch
                if not await _prefetch_session_jsonl(sid):
                    counters["gemini_error"] += 1
                    return
                if commits_df is not None:
                    await _extract_canonical_patch(sid, sessions_df, commits_df)

                meta = s1_meta.get(sid, {})
                cand = {
                    "session_id": sid,
                    "_repo": meta.get("project") or "unknown",
                    "_stars": meta.get("_swechat_stars", 0),
                }
                r = await judge_one(cand, gemini_sem)
                v = r.get("verdict", "ERROR")
                if v == "VIABLE":
                    counters["gemini_viable"] += 1
                    if enqueue(sid, "rescreen"):
                        print(f"  [{ts()}] +VIABLE  {sid[:8]}…  ({cand['_repo']})  → enqueued (queue size: {scaffold_queue.qsize()})")
                elif v == "NOT_VIABLE":
                    counters["gemini_not_viable"] += 1
                else:
                    counters["gemini_error"] += 1
            except Exception as e:
                counters["gemini_error"] += 1
                print(f"  [{ts()}] gemini_producer ERROR {sid[:8]}…: {type(e).__name__}: {str(e)[:120]}")
            finally:
                n_done += 1
                if n_done % 25 == 0 or n_done == len(rescreen_sids):
                    print(f"  [{ts()}] rescreen progress: {n_done}/{len(rescreen_sids)} | "
                          f"viable={counters['gemini_viable']} not_viable={counters['gemini_not_viable']} err={counters['gemini_error']}")

        coros = [screen_one(sid) for sid in rescreen_sids]
        await asyncio.gather(*coros)
        rescreen_complete_event.set()
        print(f"  [{ts()}] gemini_producer: DONE — {counters['gemini_viable']} VIABLE / {counters['gemini_not_viable']} NOT_VIABLE / {counters['gemini_error']} ERROR")

    async def scaffold_consumer(consumer_id: int):
        """Consume scaffold_queue until both: queue is empty AND rescreen done."""
        while True:
            try:
                sid, source = await asyncio.wait_for(scaffold_queue.get(), timeout=2.0)
            except asyncio.TimeoutError:
                if rescreen_complete_event.is_set() and scaffold_queue.empty():
                    return
                continue

            cand = synth_candidate(sid)
            name = generate_task_name(cand)
            try:
                r = await _run_one(cand, name, deepseek_key, scaffold_sem,
                                   args.budget, args.template)
                r["queue_source"] = source
                results.append(r)
                status = r.get("status", "?")
                if status == "success":
                    counters["scaffold_done"] += 1
                elif status in ("not_viable",):
                    counters["scaffold_not_viable"] += 1
                else:
                    counters["scaffold_err"] += 1
            except Exception as e:
                counters["scaffold_err"] += 1
                print(f"  [{ts()}] consumer{consumer_id} ERROR {name}: {type(e).__name__}: {str(e)[:120]}")
            finally:
                scaffold_queue.task_done()

    print(f"\n{'='*60}")
    print(f"Starting at {ts()} | scaffold-workers={args.scaffold_workers} gemini-workers={args.gemini_workers}")
    print(f"Template: {args.template}, budget/task: ${args.budget}")
    print(f"{'='*60}\n")

    start = time.time()
    consumers = [asyncio.create_task(scaffold_consumer(i)) for i in range(args.scaffold_workers)]
    producer = asyncio.create_task(gemini_producer())

    # Periodic status reporter
    async def reporter():
        while True:
            await asyncio.sleep(60)
            print(f"  [{ts()}] STATUS  queue={scaffold_queue.qsize()}  "
                  f"scaffolded={counters['scaffold_done']}+{counters['scaffold_err']}err+{counters['scaffold_not_viable']}nv  "
                  f"rescreen_viable={counters['gemini_viable']} (rescreen_done={rescreen_complete_event.is_set()})")
            if rescreen_complete_event.is_set() and scaffold_queue.empty():
                # Allow time for in-flight scaffolds to finish
                pass

    rep_task = asyncio.create_task(reporter())

    await producer
    await asyncio.gather(*consumers)
    rep_task.cancel()

    elapsed = time.time() - start
    print(f"\n{'='*60}")
    print(f"All done in {elapsed/60:.1f} min")
    print(f"{'='*60}")
    print(f"  scaffold success:    {counters['scaffold_done']}")
    print(f"  scaffold not_viable: {counters['scaffold_not_viable']}")
    print(f"  scaffold errors:     {counters['scaffold_err']}")
    print(f"  rescreen viable:     {counters['gemini_viable']}  (added to queue mid-run)")
    print(f"  rescreen not_viable: {counters['gemini_not_viable']}")
    print(f"  rescreen errors:     {counters['gemini_error']}")

    json.dump({
        "timestamp": datetime.now().isoformat(),
        "elapsed_sec": elapsed,
        "counters": counters,
        "scaffold_workers": args.scaffold_workers,
        "gemini_workers": args.gemini_workers,
        "template": args.template,
        "results": results,
    }, open(SUMMARY_PATH, "w"), indent=2)
    print(f"\nSummary: {SUMMARY_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
