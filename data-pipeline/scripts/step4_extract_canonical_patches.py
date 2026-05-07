#!/usr/bin/env python3
"""Step 4 — extract canonical (human-shipped) patches per VIABLE session.

Joins SWE-chat sessions.parquet → commits.parquet via canonical_checkpoint_pk
to recover the patch the user eventually committed. Writes one JSON per session
into `canonical_patches/<sid>.json` so the scaffold pipeline + oracle verifier
can read them locally without parquet IO.

By default we **skip multi-commit checkpoints** (~9% of viable sessions).
Per Entire CLI docs (sessions-and-checkpoints.md): when one checkpoint has
multiple commits, the extras are typically follow-up cleanup (`go fmt`,
test fixes) the user did in the same session. The largest patch isn't always
the canonical one. Filtering to single-commit checkpoints gives bullet-proof
session→patch alignment. Pass --include-multi-commit to opt back in.

Verified on 2026-05-06: 200/329 viable sessions have any patch;
170/329 (52%) come from single-commit checkpoints (high-trust subset).

Usage:
  python data-pipeline/screening/scripts/step4_extract_canonical_patches.py
  python data-pipeline/screening/scripts/step4_extract_canonical_patches.py --force
  python data-pipeline/screening/scripts/step4_extract_canonical_patches.py --include-multi-commit
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
CANDIDATES = ARTIFACTS / "step2_candidates.json"
PATCHES_DIR = ARTIFACTS / "canonical_patches"
HF_REPO = "SALT-NLP/SWE-chat"

# Cap stored patches at 256 KB. The p99 in our 348-commit sample is 1.4 MB
# (one outlier refactor); huge patches are unlikely to be useful as oracle
# tests anyway and bloat the cache. Truncated patches are flagged for the
# verifier so it can skip them.
MAX_PATCH_BYTES = 256 * 1024


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--force", action="store_true", help="Re-extract even if cached")
    p.add_argument("--limit", type=int, default=0, help="Cap (0=all VIABLE)")
    p.add_argument("--include-multi-commit", action="store_true",
                   help="Also include checkpoints with >1 commits (default: skip; default keeps "
                        "only bullet-proof single-commit alignment)")
    args = p.parse_args()

    if not CANDIDATES.exists():
        print(f"ERROR: {CANDIDATES} not found — run step1+step2 first")
        return 2
    try:
        from huggingface_hub import hf_hub_download
        import pyarrow.parquet as pq
    except ImportError as e:
        print(f"ERROR: missing dep ({e}); install huggingface_hub + pyarrow")
        return 2

    candidates = json.load(open(CANDIDATES))
    viable = [c for c in candidates if c.get("verdict") == "VIABLE"]
    if args.limit:
        viable = viable[: args.limit]
    viable_sids = {c["session_id"] for c in viable}
    print(f"Targeting {len(viable_sids)} VIABLE session_ids")

    PATCHES_DIR.mkdir(parents=True, exist_ok=True)
    if not args.force:
        already = {p.stem for p in PATCHES_DIR.glob("*.json")}
        viable_sids -= already
        print(f"  ({len(already)} already cached, fetching {len(viable_sids)} fresh)")
    if not viable_sids:
        print("Nothing to do.")
        return 0

    # Step 1: sessions.parquet → canonical_checkpoint_pk per session
    print("\n[1/3] downloading sessions.parquet ...")
    t0 = time.time()
    sf = hf_hub_download(HF_REPO, "sessions.parquet", repo_type="dataset")
    sessions_table = pq.read_table(
        sf,
        columns=["session_id", "canonical_checkpoint_pk", "agent_percentage",
                 "files_touched_count", "duration_seconds"],
        filters=[("session_id", "in", list(viable_sids))],
    )
    sdf = sessions_table.to_pandas()
    has_ckpt = sdf["canonical_checkpoint_pk"].notna().sum()
    checkpoint_pks = sdf["canonical_checkpoint_pk"].dropna().unique().tolist()
    print(f"  {len(sdf)} sessions loaded, {has_ckpt} with checkpoint, "
          f"{len(checkpoint_pks)} unique checkpoints ({time.time()-t0:.1f}s)")

    if not checkpoint_pks:
        print("No checkpoints to query — done.")
        return 0

    # Step 2: commits.parquet → patches per checkpoint (predicate-pushdown)
    print("\n[2/3] downloading commits.parquet (1 GB; pyarrow filter at read) ...")
    t0 = time.time()
    cf = hf_hub_download(HF_REPO, "commits.parquet", repo_type="dataset")
    commits_table = pq.read_table(
        cf,
        columns=["commit_sha", "checkpoint_pk", "repo_id", "is_agent_author",
                 "files_changed_count", "total_additions", "total_deletions",
                 "patch", "commit_message", "agent_changes",
                 "files_changed", "numstat", "author_date", "user_id"],
        filters=[("checkpoint_pk", "in", checkpoint_pks)],
    )
    cdf = commits_table.to_pandas()
    print(f"  {len(cdf)} commits loaded ({time.time()-t0:.1f}s)")

    # Build session_id → row from sessions df
    session_meta = {row["session_id"]: row for _, row in sdf.iterrows()}

    # Step 3: pick best commit per session, write JSON
    print(f"\n[3/3] writing canonical_patches/<sid>.json ...")
    n_written = n_no_patch = n_no_commits = n_truncated = n_multi_skipped = 0
    failures = []
    for sid, srow in session_meta.items():
        ckpt = srow["canonical_checkpoint_pk"]
        if not ckpt:
            n_no_commits += 1
            failures.append({"sid": sid, "reason": "no canonical_checkpoint_pk"})
            continue
        matches = cdf[cdf["checkpoint_pk"] == ckpt]
        if matches.empty:
            n_no_commits += 1
            failures.append({"sid": sid, "reason": f"no commits for checkpoint {ckpt}"})
            continue

        # Filter out multi-commit checkpoints unless explicitly opted in.
        # Per Entire CLI docs: multi-commit checkpoints are sessions where the
        # user did follow-up cleanup commits (gofmt/test fixes/etc) all linked
        # to the same checkpoint via the trailer. Picking "the largest" is a
        # heuristic that fails ~9% of the time.
        n_commits_for_ckpt = len(matches)
        if n_commits_for_ckpt > 1 and not args.include_multi_commit:
            n_multi_skipped += 1
            failures.append({"sid": sid, "reason":
                f"multi-commit checkpoint {ckpt} ({n_commits_for_ckpt} commits) — skipped for trust; "
                f"pass --include-multi-commit to include"})
            continue

        # Pick the commit with the largest non-empty patch (heuristic: when in
        # the multi-commit case via opt-in, take the largest).
        with_patch = matches[matches["patch"].notna() & (matches["patch"].str.len() > 0)]
        if with_patch.empty:
            n_no_patch += 1
            failures.append({"sid": sid, "reason": f"checkpoint {ckpt} has commits but all patches empty"})
            continue

        best = with_patch.loc[with_patch["patch"].str.len().idxmax()]
        patch_text = best["patch"]
        truncated = False
        if len(patch_text) > MAX_PATCH_BYTES:
            patch_text = patch_text[:MAX_PATCH_BYTES] + f"\n…[truncated at {MAX_PATCH_BYTES} bytes]"
            truncated = True
            n_truncated += 1

        out = {
            "session_id": sid,
            "checkpoint_pk": ckpt,
            "commits_in_checkpoint": int(n_commits_for_ckpt),
            "commit_sha": best["commit_sha"],
            "repo_id": best["repo_id"],
            "is_agent_author": bool(best["is_agent_author"]),
            "files_changed_count": int(best["files_changed_count"]) if best["files_changed_count"] else 0,
            "total_additions": int(best["total_additions"]) if best["total_additions"] else 0,
            "total_deletions": int(best["total_deletions"]) if best["total_deletions"] else 0,
            "commit_message": best["commit_message"] or "",
            "files_changed": best["files_changed"] or "",
            "numstat": best["numstat"] or "",
            "patch": patch_text,
            "patch_truncated": truncated,
            "agent_percentage": float(srow["agent_percentage"]) if srow.get("agent_percentage") is not None else None,
        }
        json.dump(out, open(PATCHES_DIR / f"{sid}.json", "w"), indent=2, default=str)
        n_written += 1
        if n_written % 25 == 0:
            print(f"  wrote {n_written} so far …")

    print(f"\n=== Done ===")
    print(f"  wrote:                  {n_written}")
    print(f"  truncated to {MAX_PATCH_BYTES//1024} KB:   {n_truncated}")
    print(f"  multi-commit skipped:   {n_multi_skipped}  (use --include-multi-commit to keep)")
    print(f"  no patch in commit:     {n_no_patch}")
    print(f"  no commit/checkpoint:   {n_no_commits}")
    print(f"  output dir:             {PATCHES_DIR}")

    if failures:
        log = ARTIFACTS / "step4_extraction_failures.json"
        json.dump(failures, open(log, "w"), indent=2)
        print(f"  failures log:         {log}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
