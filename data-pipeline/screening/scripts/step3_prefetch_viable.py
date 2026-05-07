#!/usr/bin/env python3
"""Step 3 — serial prefetch of every VIABLE session's transcript into local JSON.

Run this ONCE after step1+step2. After it completes, scaffold workers (in
data-pipeline/scaffold/run_pipeline.py) read from `sessions_raw/<sid>.json`
locally and never touch HF or parquet at run time — eliminating the
concurrent-parquet-load OOM that bit us under WORKERS≥4.

What it does:
  1. Reads `step2_candidates.json`, keeps `verdict == "VIABLE"`.
  2. For each, downloads `transcripts/<sid>.jsonl` from HF (SALT-NLP/SWE-chat).
     hf_hub_download is range-cached; serial loop, ~50 MB peak RAM total.
  3. Converts the JSONL to the DataClaw-shaped session dict the scaffold
     prompt expects, writes to `sessions_raw/<sid>.json`.
  4. Skips sessions whose JSON already exists (idempotent).

Usage:
  python data-pipeline/screening/scripts/step3_prefetch_viable.py
  python data-pipeline/screening/scripts/step3_prefetch_viable.py --limit 50
  python data-pipeline/screening/scripts/step3_prefetch_viable.py --force  # re-fetch
"""

import argparse
import json
import sys
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
CANDIDATES = ARTIFACTS / "step2_candidates.json"
SESSIONS_DIR = ARTIFACTS / "sessions_raw"
HF_REPO = "SALT-NLP/SWE-chat"


def jsonl_to_dataclaw_session(jsonl_path: Path, sid: str) -> dict:
    """SWE-chat transcript JSONL -> DataClaw-shaped session dict (matches the
    schema the scaffold prompt reads).

    Each JSONL line is one Anthropic API event ({type, message, ...}). We map:
      - type=user      -> {role:"user", content, tool_uses:[]}
      - type=assistant -> {role:"assistant", content, tool_uses:[…extracted…]}
    """
    messages = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rtype = rec.get("type")
            msg = rec.get("message") or {}
            content = msg.get("content", "")
            ts = rec.get("timestamp", "")
            if rtype == "user":
                messages.append({"role": "user", "content": content, "timestamp": ts, "tool_uses": []})
            elif rtype == "assistant":
                tool_uses = []
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_uses.append({
                                "tool": block.get("name", ""),
                                "input": block.get("input", {}),
                            })
                messages.append({
                    "role": "assistant",
                    "content": content,
                    "tool_uses": tool_uses,
                    "timestamp": ts,
                })
    return {"session_id": sid, "messages": messages}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--limit", type=int, default=0, help="Cap (0=all VIABLE)")
    p.add_argument("--force", action="store_true", help="Re-fetch even if cached")
    args = p.parse_args()

    if not CANDIDATES.exists():
        print(f"ERROR: {CANDIDATES} not found — run step1+step2 first")
        return 1

    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        print("ERROR: huggingface_hub not installed (pip install huggingface_hub)")
        return 1

    candidates = json.load(open(CANDIDATES))
    viable = [c for c in candidates if c.get("verdict") == "VIABLE"]
    print(f"Loaded {len(candidates)} candidates ({len(viable)} VIABLE)")
    if args.limit:
        viable = viable[: args.limit]
        print(f"Capped to first {len(viable)}")

    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    n_existing = n_fetched = n_failed = 0
    failed = []
    for i, c in enumerate(viable, 1):
        sid = c["session_id"]
        out = SESSIONS_DIR / f"{sid}.json"
        if out.exists() and not args.force:
            n_existing += 1
            continue
        try:
            tpath = hf_hub_download(HF_REPO, f"transcripts/{sid}.jsonl", repo_type="dataset")
            session = jsonl_to_dataclaw_session(Path(tpath), sid)
            json.dump(session, open(out, "w"), indent=2, default=str, ensure_ascii=False)
            n_fetched += 1
            if n_fetched % 25 == 0:
                print(f"  [{i}/{len(viable)}] fetched={n_fetched} cached={n_existing} failed={n_failed}")
        except Exception as e:
            n_failed += 1
            failed.append({"sid": sid, "repo": c.get("repo", "?"), "error": str(e)[:200]})
            print(f"  WARN {sid[:8]}… ({c.get('repo', '?')}): {str(e)[:120]}")

    print(f"\n=== Done ===")
    print(f"  Already cached: {n_existing}")
    print(f"  Newly fetched:  {n_fetched}")
    print(f"  Failed:         {n_failed}")
    print(f"  Output dir:     {SESSIONS_DIR}")

    if failed:
        log = ARTIFACTS / "step3_prefetch_failures.json"
        json.dump(failed, open(log, "w"), indent=2)
        print(f"  Failures log:   {log}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
