#!/usr/bin/env python3
"""Run step5 (Gemini patch screen) on sessions that step2 rejected, to test
whether step2's session-only Gemini judge was over-strict relative to step5's
session+patch judge.

Pipeline for each step2-rejected sid:
  1. Download transcripts/<sid>.jsonl from HF (serial, ~3s each)
  2. Convert to DataClaw schema, cache to sessions_raw/<sid>.json
  3. Look up canonical_checkpoint_pk → commits.parquet → patch
  4. Drop sessions whose checkpoint has multiple commits (single-commit only)
  5. Apply step5's Gemini judge (concurrent)

Output: data-pipeline/screening/artifacts_swechat/step5_recovered_from_rejected.json

Usage:
  python data-pipeline/screening/scripts/recover_step2_rejected.py
  python data-pipeline/screening/scripts/recover_step2_rejected.py --workers 30 --limit 20
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path
from datetime import datetime

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
STEP1 = ARTIFACTS / "step1_all_sessions.json"
STEP2 = ARTIFACTS / "step2_candidates.json"
SESSIONS_DIR = ARTIFACTS / "sessions_raw"
PATCHES_DIR = ARTIFACTS / "canonical_patches"
OUT_PATH = ARTIFACTS / "step5_recovered_from_rejected.json"
HF_REPO = "SALT-NLP/SWE-chat"

DEFAULT_WORKERS = 30


def _load_env():
    for d in [ROOT, ROOT.parent, ROOT.parent.parent, ROOT.parent.parent.parent,
              ROOT.parent.parent.parent.parent]:
        env = d / ".env"
        if env.exists():
            for line in env.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
            break


# Reuse step3's jsonl→dataclaw converter
sys.path.insert(0, str(ROOT / "data-pipeline" / "scaffold"))
from run_pipeline import jsonl_to_dataclaw_session, _build_deepseek_env  # type: ignore[import-not-found]
sys.path.insert(0, str(ROOT / "data-pipeline" / "screening" / "scripts"))
from step5_llm_screen_patches import _build_judge_prompt, judge_one  # type: ignore[import-not-found]


async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                   help="Concurrent Gemini calls during screening")
    p.add_argument("--limit", type=int, default=0, help="Cap (0=all rejected)")
    p.add_argument("--skip-prefetch", action="store_true",
                   help="Use only sessions+patches already cached locally")
    args = p.parse_args()

    _load_env()
    if not os.environ.get("GEMINI_API_KEY"):
        print("ERROR: GEMINI_API_KEY missing")
        return 2

    # Compute the 431 step2-rejected sids
    step1 = json.load(open(STEP1))
    step2 = json.load(open(STEP2))
    s1_sids = {r["session_id"] for r in step1 if r.get("session_id")}
    viable_sids = {c["session_id"] for c in step2 if c.get("verdict") == "VIABLE"}
    rejected_sids = s1_sids - viable_sids
    print(f"step1 records: {len(s1_sids)}, step2 VIABLE: {len(viable_sids)}, "
          f"step2-rejected: {len(rejected_sids)}")

    if args.limit:
        rejected_sids = set(list(rejected_sids)[: args.limit])

    # Prefetch jsonls (serial, idempotent)
    if not args.skip_prefetch:
        try:
            from huggingface_hub import hf_hub_download
        except ImportError:
            print("ERROR: huggingface_hub not installed")
            return 2
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        n_existing = n_fetched = n_failed = 0
        print(f"\n[prefetch] downloading jsonls for {len(rejected_sids)} sessions ...")
        t0 = time.time()
        for i, sid in enumerate(rejected_sids, 1):
            out = SESSIONS_DIR / f"{sid}.json"
            if out.exists():
                n_existing += 1
                continue
            try:
                tpath = hf_hub_download(HF_REPO, f"transcripts/{sid}.jsonl", repo_type="dataset")
                session = jsonl_to_dataclaw_session(Path(tpath), sid)
                json.dump(session, open(out, "w"), indent=2, default=str, ensure_ascii=False)
                n_fetched += 1
            except Exception as e:
                n_failed += 1
                if n_failed <= 5:
                    print(f"  WARN {sid[:8]}…: {str(e)[:100]}")
            if i % 50 == 0:
                print(f"  [{i}/{len(rejected_sids)}] cached={n_existing} fetched={n_fetched} failed={n_failed}")
        print(f"  done: {n_existing} cached, {n_fetched} fetched, {n_failed} failed ({time.time()-t0:.1f}s)")

    # Extract canonical patches for these sids (single-commit only, same as step4)
    print(f"\n[patches] joining sessions × commits for rejected sids ...")
    t0 = time.time()
    try:
        from huggingface_hub import hf_hub_download
        import pyarrow.parquet as pq
    except ImportError:
        print("ERROR: pyarrow not installed")
        return 2

    sf = hf_hub_download(HF_REPO, "sessions.parquet", repo_type="dataset")
    sdf = pq.read_table(
        sf,
        columns=["session_id", "canonical_checkpoint_pk", "agent_percentage", "files_touched_count"],
        filters=[("session_id", "in", list(rejected_sids))],
    ).to_pandas()
    checkpoint_pks = sdf["canonical_checkpoint_pk"].dropna().unique().tolist()
    print(f"  {len(sdf)} sessions, {len(checkpoint_pks)} checkpoints")

    cf = hf_hub_download(HF_REPO, "commits.parquet", repo_type="dataset")
    cdf = pq.read_table(
        cf,
        columns=["commit_sha", "checkpoint_pk", "patch", "files_changed_count",
                 "total_additions", "total_deletions", "commit_message",
                 "files_changed", "is_agent_author"],
        filters=[("checkpoint_pk", "in", checkpoint_pks)],
    ).to_pandas()
    print(f"  {len(cdf)} commits ({time.time()-t0:.1f}s)")

    # Per session: pick canonical patch (single-commit checkpoints only)
    PATCHES_DIR.mkdir(parents=True, exist_ok=True)
    n_patch_written = n_multi_skip = n_no_patch = 0
    for _, srow in sdf.iterrows():
        sid = srow["session_id"]
        out = PATCHES_DIR / f"{sid}.json"
        if out.exists():
            continue  # already cached (e.g., from earlier step4 run)
        ckpt = srow["canonical_checkpoint_pk"]
        if not ckpt:
            continue
        matches = cdf[cdf["checkpoint_pk"] == ckpt]
        if len(matches) > 1:
            n_multi_skip += 1
            continue
        if matches.empty:
            n_no_patch += 1
            continue
        with_patch = matches[matches["patch"].notna() & (matches["patch"].str.len() > 0)]
        if with_patch.empty:
            n_no_patch += 1
            continue
        best = with_patch.iloc[0]
        patch_text = best["patch"]
        truncated = False
        if len(patch_text) > 256 * 1024:
            patch_text = patch_text[:256 * 1024] + "\n…[truncated]"
            truncated = True
        out_data = {
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
            "agent_percentage": float(srow["agent_percentage"]) if srow.get("agent_percentage") is not None else None,
        }
        json.dump(out_data, open(out, "w"), indent=2, default=str)
        n_patch_written += 1
    print(f"  patches: {n_patch_written} written, {n_multi_skip} multi-commit-skipped, {n_no_patch} no-patch")

    # Build candidate stubs for step5 (it expects {"session_id", "_repo", "_stars"})
    s1_meta = {r["session_id"]: r for r in step1}
    candidates = []
    for sid in rejected_sids:
        meta = s1_meta.get(sid, {})
        candidates.append({
            "session_id": sid,
            "_repo": meta.get("project") or "unknown",
            "_stars": meta.get("_swechat_stars", 0),
        })
    # Skip ones where session JSON didn't cache (the failed prefetches)
    candidates = [c for c in candidates if (SESSIONS_DIR / f"{c['session_id']}.json").exists()]
    print(f"\n[gemini] {len(candidates)} sessions ready for step5 judge (with concurrent={args.workers})")

    sem = asyncio.Semaphore(args.workers)
    started = time.time()
    n_done = 0
    async def _wrapped(c):
        nonlocal n_done
        r = await judge_one(c, sem)
        n_done += 1
        if n_done % 20 == 0 or n_done == len(candidates):
            print(f"  [{datetime.now().strftime('%H:%M:%S')}] {n_done}/{len(candidates)}")
        return r

    coros = [_wrapped(c) for c in candidates]
    results = await asyncio.gather(*coros)
    elapsed = time.time() - started

    verdicts: dict[str, int] = {}
    cats: dict[str, int] = {}
    for r in results:
        verdicts[r.get("verdict","?")] = verdicts.get(r.get("verdict","?"), 0) + 1
        cats[r.get("category","?")] = cats.get(r.get("category","?"), 0) + 1
    print(f"\n=== Done in {elapsed/60:.1f} min ===")
    print(f"Verdicts (on {len(results)} step2-REJECTED sessions):")
    for v, n in sorted(verdicts.items(), key=lambda kv: -kv[1]):
        print(f"  {v:<14s} {n}")
    print(f"\nCategories:")
    for c, n in sorted(cats.items(), key=lambda kv: -kv[1]):
        print(f"  {c:<24s} {n}")

    out = {
        "timestamp": datetime.now().isoformat(),
        "model": "gemini-3.1-pro-preview",
        "input": "step1 - step2_VIABLE",
        "total": len(results),
        "verdicts": verdicts,
        "categories": cats,
        "results": results,
    }
    json.dump(out, open(OUT_PATH, "w"), indent=2)
    print(f"\nSaved: {OUT_PATH}")

    # Headline: how many recovered as VIABLE?
    recovered = [r for r in results if r.get("verdict") == "VIABLE"]
    print(f"\n>>> RECOVERED: {len(recovered)} step2-rejected sessions are NOW Gemini-VIABLE per step5")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
