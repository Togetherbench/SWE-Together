#!/usr/bin/env python3
"""Step 5 — LLM (Gemini 3 Pro) screen of canonical patches + sessions for
benchmark viability, applied BEFORE we burn E2B sandboxes scaffolding tasks.

Per VIABLE candidate (from step2), we feed Gemini:
  - The session's first user message (the candidate "instruction")
  - The canonical patch from step4 (if available — 200/329 sessions have one)
  - Repo + size metadata
And ask: is this substantive engineering work suitable as a coding benchmark?

Output: data-pipeline/screening/artifacts_swechat/step5_patch_viability.json
        — per-session verdict (VIABLE / NOT_VIABLE / NEEDS_REVIEW) + reason.

Filters out cases where:
  - Patch is pure formatting (`go fmt`, `prettier --write`, whitespace)
  - Patch is version bumps / lockfile churn / generated files
  - Patch is docs-only or test-only (no code change to verify against)
  - Patch is a sweeping refactor touching too many files (>30) — too hard to reproduce
  - Session lacks a clear engineering ask (chat about an idea, save a haiku, etc.)
  - Task requires non-CPU resources (GPU, network APIs, secrets)

Usage:
  python data-pipeline/screening/scripts/step5_llm_screen_patches.py
  python data-pipeline/screening/scripts/step5_llm_screen_patches.py --limit 10  # smoke
  python data-pipeline/screening/scripts/step5_llm_screen_patches.py --workers 10
  python data-pipeline/screening/scripts/step5_llm_screen_patches.py --resume    # skip already-judged
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

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
CANDIDATES = ARTIFACTS / "step2_candidates.json"
SESSIONS_DIR = ARTIFACTS / "sessions_raw"
PATCHES_DIR = ARTIFACTS / "canonical_patches"
OUT_PATH = ARTIFACTS / "step5_patch_viability.json"

GEMINI_MODEL = "gemini-3.1-pro-preview"
MAX_INSTRUCTION_CHARS = 4000     # first user message excerpt
MAX_PATCH_CHARS = 25_000         # patch excerpt sent to Gemini
MAX_FILES_LISTED = 40            # files_changed listing cap
DEFAULT_WORKERS = 8


def _load_env() -> None:
    candidates = [ROOT / ".env"]
    for d in [ROOT.parent, ROOT.parent.parent, ROOT.parent.parent.parent,
              ROOT.parent.parent.parent.parent]:
        if (d / ".env").exists():
            candidates.append(d / ".env")
            break
    for env_path in candidates:
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _first_user_text(session: dict) -> str:
    for m in session.get("messages", []):
        if m.get("role") != "user":
            continue
        c = m.get("content", "")
        # Skip auto-generated continuations + tool-related noise
        if isinstance(c, str):
            text = c
        elif isinstance(c, list):
            parts = []
            for block in c:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text", ""))
                elif isinstance(block, str):
                    parts.append(block)
            text = "\n".join(parts)
        else:
            text = str(c)
        text = text.strip()
        if not text:
            continue
        if text.startswith("<task-") or text.startswith("[Request interrupted") \
                or text.startswith("This session is being continued"):
            continue
        return text[:MAX_INSTRUCTION_CHARS]
    return "(no user text found)"


def _build_judge_prompt(candidate: dict, session: dict, patch: dict | None) -> str:
    instr = _first_user_text(session)
    repo = candidate.get("_repo") or candidate.get("repo") or "unknown"
    stars = candidate.get("_stars", 0)
    n_msgs = len(session.get("messages", []))
    n_user = sum(1 for m in session.get("messages", []) if m.get("role") == "user")

    patch_block = ""
    if patch:
        files_changed = (patch.get("files_changed") or "").strip().splitlines()
        files_listed = "\n".join(files_changed[:MAX_FILES_LISTED])
        if len(files_changed) > MAX_FILES_LISTED:
            files_listed += f"\n... and {len(files_changed) - MAX_FILES_LISTED} more files"
        patch_text = (patch.get("patch") or "")[:MAX_PATCH_CHARS]
        truncated = " (TRUNCATED)" if len(patch.get("patch", "")) > MAX_PATCH_CHARS or patch.get("patch_truncated") else ""
        patch_block = f"""
# Canonical patch (the human's eventual commit)
- Commit SHA: {patch.get('commit_sha', '?')}
- Commit message (first line): {(patch.get('commit_message') or '').splitlines()[0] if patch.get('commit_message') else '(empty)'}
- Files changed: {patch.get('files_changed_count', 0)}
- Lines: +{patch.get('total_additions', 0)} / -{patch.get('total_deletions', 0)}
- Agent-authored %: {patch.get('agent_percentage', '?')}

## git --name-status:
```
{files_listed}
```

## Patch{truncated}:
```diff
{patch_text}
```
"""
    else:
        patch_block = "\n# Canonical patch: NONE (this session has no committed patch in commits.parquet)\n"

    return f"""You are a SENIOR engineer reviewing whether a SWE-chat coding session is suitable for inclusion in a coding benchmark.

# Repo
- {repo} ({stars} stars)
- Session has {n_msgs} total messages, {n_user} user messages.

# First user message (would become the task instruction.md):
```
{instr}
```
{patch_block}

# Your job
Decide whether this session is a viable Harbor benchmark task. A viable task is:
- **Substantive engineering**: real code change that affects program behavior — NOT pure formatting (gofmt, prettier --write, whitespace), version bumps, lockfile churn, generated files (bundle.js, dist/), pure docs/comments edits, or test-only additions.
- **Atomic enough**: the change should be coherent and bounded. A 100-file refactor sweep is too hard to reproduce; reject patches touching > 30 files.
- **Has a clear behavioral signature**: you can write fail-to-pass test gates around it (function added with specific I/O, bug fixed in observable way, output changes deterministically).
- **CPU-reproducible in Docker**: no GPU requirement, no private services / API keys / secrets, no network beyond `git clone`.
- **Test runs in <120s**: rules out tasks needing >2-min test suites.
- **The instruction is a real engineering ask**, not "save this haiku to a file" or "explain this code".

Output exactly this JSON (no markdown fences, no preamble):
{{
  "verdict": "VIABLE" | "NOT_VIABLE" | "NEEDS_REVIEW",
  "category": "substantive" | "formatting_only" | "version_bump" | "docs_only" | "test_only" | "generated_files" | "too_large_refactor" | "non_engineering_ask" | "needs_gpu" | "needs_secrets" | "no_patch_no_signal" | "other",
  "confidence": 0.0..1.0,
  "reason": "<one or two sentences explaining the verdict>"
}}

Be strict — if the patch is mostly trivia (lockfiles, formatting, regen), mark NOT_VIABLE.
NEEDS_REVIEW only if you genuinely can't tell (e.g., patch is borderline, or no patch + thin session).
"""


async def judge_one(candidate: dict, sem: asyncio.Semaphore) -> dict:
    sid = candidate["session_id"]
    session_path = SESSIONS_DIR / f"{sid}.json"
    if not session_path.exists():
        return {"session_id": sid, "verdict": "ERROR",
                "reason": "session JSON not cached", "_input_chars": 0}
    try:
        session = json.load(open(session_path))
    except Exception as e:
        return {"session_id": sid, "verdict": "ERROR",
                "reason": f"session parse: {e}", "_input_chars": 0}

    patch = None
    pp = PATCHES_DIR / f"{sid}.json"
    if pp.exists():
        try:
            patch = json.load(open(pp))
        except Exception:
            pass

    prompt = _build_judge_prompt(candidate, session, patch)

    async with sem:
        try:
            from google import genai
            from google.genai import types
        except ImportError:
            return {"session_id": sid, "verdict": "ERROR",
                    "reason": "google-genai not installed (pip install google-genai)",
                    "_input_chars": len(prompt)}

        client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
        # Structured output via response_schema — guarantees valid JSON parsable
        # by parsed on the SDK side. Saves us a regex-extract dance.
        schema = types.Schema(
            type=types.Type.OBJECT,
            required=["verdict", "category", "confidence", "reason"],
            properties={
                "verdict": types.Schema(
                    type=types.Type.STRING,
                    enum=["VIABLE", "NOT_VIABLE", "NEEDS_REVIEW"],
                ),
                "category": types.Schema(
                    type=types.Type.STRING,
                    enum=["substantive", "formatting_only", "version_bump",
                          "docs_only", "test_only", "generated_files",
                          "too_large_refactor", "non_engineering_ask",
                          "needs_gpu", "needs_secrets", "no_patch_no_signal",
                          "other"],
                ),
                "confidence": types.Schema(type=types.Type.NUMBER),
                "reason": types.Schema(type=types.Type.STRING),
            },
        )
        try:
            resp = await client.aio.models.generate_content(
                model=GEMINI_MODEL,
                contents=prompt,
                config=types.GenerateContentConfig(
                    temperature=0.0,
                    # Gemini 3.1 Pro burns ~500 thinking tokens before emitting
                    # the structured-output JSON, so we need a generous output
                    # cap to avoid mid-key truncation.
                    max_output_tokens=10_000,
                    response_mime_type="application/json",
                    response_schema=schema,
                ),
            )
        except Exception as e:
            return {"session_id": sid, "verdict": "ERROR",
                    "reason": f"gemini call: {type(e).__name__}: {str(e)[:200]}",
                    "_input_chars": len(prompt)}

    raw = (resp.text or "").strip()
    try:
        out = json.loads(raw)
    except Exception as e:
        return {"session_id": sid, "verdict": "ERROR",
                "reason": f"json parse despite schema: {type(e).__name__}: {raw[:300]}",
                "_input_chars": len(prompt)}

    out["session_id"] = sid
    out["repo"] = candidate.get("_repo") or candidate.get("repo")
    out["has_patch"] = patch is not None
    out["_input_chars"] = len(prompt)
    if patch:
        out["files_changed_count"] = patch.get("files_changed_count", 0)
        out["total_additions"] = patch.get("total_additions", 0)
        out["total_deletions"] = patch.get("total_deletions", 0)
    return out


async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--limit", type=int, default=0, help="Cap (0=all VIABLE)")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                   help="Concurrent Gemini calls (default 8)")
    p.add_argument("--resume", action="store_true",
                   help="Skip session_ids already in step5_patch_viability.json")
    args = p.parse_args()

    _load_env()
    if not os.environ.get("GEMINI_API_KEY"):
        print("ERROR: GEMINI_API_KEY missing. Get one at https://aistudio.google.com/apikey")
        return 2

    if not CANDIDATES.exists():
        print(f"ERROR: {CANDIDATES} not found — run step1+step2 first")
        return 2

    candidates = json.load(open(CANDIDATES))
    viable = [c for c in candidates if c.get("verdict") == "VIABLE"]
    print(f"Loaded {len(viable)} VIABLE candidates from step2")

    # Enrich repo info from step1 metadata (mirror load_screening_candidates)
    sys.path.insert(0, str(ROOT / "data-pipeline" / "scaffold"))
    from run_pipeline import load_step1_metadata  # type: ignore[import-not-found]
    meta = load_step1_metadata()
    for c in viable:
        sid = c["session_id"]
        c["_repo"] = c.get("repo") or "unknown"
        c["_stars"] = meta.get(sid, {}).get("stars") or 0

    # Resume support
    existing = {}
    if args.resume and OUT_PATH.exists():
        for r in json.load(open(OUT_PATH)).get("results", []):
            existing[r["session_id"]] = r
        before = len(viable)
        viable = [c for c in viable if c["session_id"] not in existing]
        print(f"Resume: skipped {before - len(viable)} already-judged")

    if args.limit:
        viable = viable[: args.limit]

    if not viable:
        print("Nothing to judge.")
        return 0

    print(f"Will judge {len(viable)} sessions with {args.workers} concurrent Gemini calls")
    print(f"Model: {GEMINI_MODEL}")
    print()

    sem = asyncio.Semaphore(args.workers)
    started = time.time()
    results = []
    n_done = 0

    async def _wrapped(c):
        nonlocal n_done
        r = await judge_one(c, sem)
        n_done += 1
        emoji = {"VIABLE": "✓", "NOT_VIABLE": "✗", "NEEDS_REVIEW": "?", "ERROR": "!"}.get(r.get("verdict"), "?")
        repo = r.get("repo", "?")
        cat = r.get("category", "")
        if n_done % 10 == 0 or n_done == len(viable):
            print(f"  [{datetime.now().strftime('%H:%M:%S')}] {n_done}/{len(viable)} done")
        return r

    coros = [_wrapped(c) for c in viable]
    results = await asyncio.gather(*coros)

    # Merge with existing if resuming
    if existing:
        results = list(existing.values()) + results

    # Summary
    verdicts: dict[str, int] = {}
    cats: dict[str, int] = {}
    for r in results:
        verdicts[r.get("verdict","?")] = verdicts.get(r.get("verdict","?"), 0) + 1
        cats[r.get("category","?")] = cats.get(r.get("category","?"), 0) + 1

    elapsed = time.time() - started
    print(f"\n=== Done in {elapsed/60:.1f} min ===")
    print(f"Verdicts:")
    for v, n in sorted(verdicts.items(), key=lambda kv: -kv[1]):
        print(f"  {v:<14s} {n}")
    print(f"\nCategories (NOT_VIABLE breakdown):")
    for c, n in sorted(cats.items(), key=lambda kv: -kv[1]):
        print(f"  {c:<24s} {n}")

    out = {
        "timestamp": datetime.now().isoformat(),
        "model": GEMINI_MODEL,
        "total": len(results),
        "verdicts": verdicts,
        "categories": cats,
        "results": results,
    }
    json.dump(out, open(OUT_PATH, "w"), indent=2)
    print(f"\nSaved: {OUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
