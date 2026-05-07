#!/usr/bin/env python3
"""E2B-backed scaffold runner — N concurrent sandboxes, one per session, scaffolding
harbor tasks via claude-code driven by DeepSeek-v4-pro.

Per task:
  1. Create AsyncSandbox (default Ubuntu template, ~3s).
  2. Install claude-code@2.1.108 (~45s).
  3. Upload: session JSON, scaffold prompt, lint_tests.py.
  4. Run `claude -p` with the prompt as stdin and DeepSeek env vars
     (no proxy — DeepSeek's /anthropic endpoint passes CC's validator).
  5. tar + download harbor_tasks/<task>/ from sandbox.
  6. Untar into local repo + per-task log.
  7. Kill sandbox.

Usage:
  python data-pipeline/scaffold/run_e2b.py --from-screening --limit 1 --workers 1
  python data-pipeline/scaffold/run_e2b.py --from-screening --limit 50 --workers 15
  python data-pipeline/scaffold/run_e2b.py --session-ids <sid>,<sid> --workers 2
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import tarfile
import time
import io
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "data-pipeline" / "scaffold"))

# Reuse helpers from the local-mode pipeline (candidate loading, naming, prompt).
from run_pipeline import (  # type: ignore[import-not-found]
    SC_SESSIONS_DIR,
    HARBOR_TASKS_DIR,
    load_screening_candidates,
    synth_candidate,
    generate_task_name,
    check_cached_sessions,
    build_prompt,
    get_existing_tasks,
    get_processed_session_ids,
)

LOG_DIR = ROOT / "data-pipeline" / "scaffold" / "logs"
LINT_TESTS_PATH = ROOT / "scripts" / "lint_tests.py"

# CC version pinned in CLAUDE.md (matches benchmark task images for reproducibility).
CC_VERSION = "2.1.108"

# E2B + claude-code timeouts.
SANDBOX_TIMEOUT = 3600       # max sandbox lifetime (s)
INSTALL_TIMEOUT = 240        # npm install claude-code
SCAFFOLD_TIMEOUT = 1800      # claude -p scaffold run
HARVEST_TIMEOUT = 60

DEFAULT_WORKERS = 4
DEFAULT_BUDGET = 5.0


def _load_env_from_dotenv() -> None:
    """Best-effort load of .env into os.environ (no override).

    Searches the worktree root first, then the parent git repo (worktrees inherit
    .env from the main checkout)."""
    candidates = [ROOT / ".env"]
    try:
        # Walk up to the parent repo if we're in a worktree.
        for d in [ROOT.parent, ROOT.parent.parent, ROOT.parent.parent.parent, ROOT.parent.parent.parent.parent]:
            if (d / ".env").exists():
                candidates.append(d / ".env")
                break
    except Exception:
        pass
    for env_path in candidates:
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            os.environ.setdefault(k, v)


def _build_deepseek_env(deepseek_key: str) -> dict[str, str]:
    """Env vars per DeepSeek docs (no proxy — direct /anthropic)."""
    return {
        "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
        "ANTHROPIC_AUTH_TOKEN": deepseek_key,
        "ANTHROPIC_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
        "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
        "CLAUDE_CODE_EFFORT_LEVEL": "max",
    }


async def _run_one(
    candidate: dict,
    task_name: str,
    deepseek_key: str,
    sem: asyncio.Semaphore,
    budget: float,
) -> dict:
    sid = candidate["session_id"]
    log_file = LOG_DIR / f"{task_name}.json"
    started = datetime.now()
    result = {
        "session_id": sid,
        "task_name": task_name,
        "repo": candidate.get("_repo", "?"),
        "stars": candidate.get("_stars", 0),
        "status": "pending",
        "started_at": started.isoformat(),
    }
    ts = lambda: datetime.now().strftime("%H:%M:%S")

    async with sem:
        try:
            from e2b import AsyncSandbox
        except ImportError:
            result["status"] = "error"
            result["error"] = "e2b SDK not installed (pip install e2b)"
            return result

        sbx = None
        try:
            print(f"  [{ts()}] LAUNCH {task_name} (session {sid[:8]}…)")
            sbx = await AsyncSandbox.create(timeout=SANDBOX_TIMEOUT)
            result["sandbox_id"] = sbx.sandbox_id

            print(f"  [{ts()}] INSTALL claude-code@{CC_VERSION} for {task_name}")
            r = await sbx.commands.run(
                f"npm install -g @anthropic-ai/claude-code@{CC_VERSION}",
                timeout=INSTALL_TIMEOUT,
            )
            if r.exit_code != 0:
                result["status"] = "install_failed"
                result["error"] = ((r.stderr or "") + "\n" + (r.stdout or ""))[-800:]
                print(f"  [{ts()}] INSTALL FAILED for {task_name}: exit={r.exit_code}")
                return result

            session_json = (SC_SESSIONS_DIR / f"{sid}.json").read_bytes()
            base_prompt = build_prompt(candidate, task_name)
            scaffold_prompt = base_prompt + (
                "\n\n## E2B SANDBOX OVERRIDES (ignore the corresponding steps above)\n"
                "- **Skip Step 8 (Docker build).** This sandbox has no Docker daemon. "
                "Just write a syntactically valid Dockerfile; verification happens after harvest.\n"
                "- **Skip Step 10 (git push + gh pr create).** No git remote or GH auth here. "
                "The harness tars `harbor_tasks/{task_name}/` and ships it back to the host. "
                "After Step 9, exit with success — do NOT attempt to push or create a PR.\n"
            ).format(task_name=task_name)

            # Use ~/work as the repo root — /workspace isn't writable by the default
            # E2B sandbox user. Mirror the local pipeline's expected layout so the
            # session file lives at the relative path the prompt references.
            workdir = "/home/user/work"
            session_rel = f"data-pipeline/screening/artifacts_swechat/sessions_raw/{sid}.json"
            r = await sbx.commands.run(
                f"mkdir -p {workdir}/{Path(session_rel).parent} {workdir}/scripts {workdir}/harbor_tasks"
            )
            if r.exit_code != 0:
                result["status"] = "setup_failed"
                result["error"] = (r.stderr or r.stdout)[:500]
                return result
            await sbx.files.write(f"{workdir}/{session_rel}", session_json)
            await sbx.files.write(f"{workdir}/scripts/lint_tests.py", LINT_TESTS_PATH.read_bytes())
            await sbx.files.write(f"{workdir}/_scaffold_prompt.txt", scaffold_prompt.encode())

            # Initialise an empty git repo so claude can `git add` / track changes.
            await sbx.commands.run(
                f'cd {workdir} && git init -q && git config user.email scaffold@togetherbench.dev && '
                f'git config user.name "Scaffold Bot" && git add -A && git commit -q -m "seed: pre-scaffold" || true'
            )

            print(f"  [{ts()}] SCAFFOLD {task_name} (claude -p deepseek-v4-pro)")
            env = _build_deepseek_env(deepseek_key)
            cmd = (
                f"cd {workdir} && cat _scaffold_prompt.txt | "
                f"claude -p --dangerously-skip-permissions --max-budget-usd {budget}"
            )
            r = await sbx.commands.run(cmd, envs=env, timeout=SCAFFOLD_TIMEOUT)
            result["scaffold_exit_code"] = r.exit_code
            result["scaffold_stdout_tail"] = r.stdout[-2000:] if r.stdout else ""
            result["scaffold_stderr_tail"] = r.stderr[-500:] if r.stderr else ""

            if "NOT VIABLE" in (r.stdout or ""):
                result["status"] = "not_viable"
                for line in (r.stdout or "").splitlines():
                    if "NOT VIABLE" in line:
                        result["reason"] = line.strip()[:200]
                        break
                print(f"  [{ts()}] SKIP {task_name}: {result.get('reason', '?')[:80]}")
                return result

            if "Exceeded USD budget" in (r.stdout or "") or "Exceeded USD budget" in (r.stderr or ""):
                result["status"] = "budget_exceeded"
                print(f"  [{ts()}] BUDGET {task_name}")
                return result

            print(f"  [{ts()}] HARVEST {task_name}")
            tar_path = f"{workdir}/_out.tar"
            r = await sbx.commands.run(
                f"cd {workdir} && [ -d harbor_tasks/{task_name} ] && "
                f"tar -cf {tar_path} harbor_tasks/{task_name} && stat -c %s {tar_path} || echo MISSING",
                timeout=HARVEST_TIMEOUT,
            )
            if "MISSING" in (r.stdout or ""):
                result["status"] = "no_output"
                print(f"  [{ts()}] NOOUT {task_name} (no harbor_tasks/{task_name}/)")
                return result

            tar_bytes = await sbx.files.read(tar_path, format="bytes")
            result["tar_bytes"] = len(tar_bytes)

            with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tf:
                tf.extractall(ROOT, filter="data")
            local_dir = HARBOR_TASKS_DIR / task_name
            n_files = sum(1 for _ in local_dir.rglob("*") if _.is_file()) if local_dir.exists() else 0
            result["files_landed"] = n_files

            if r.exit_code == 0 and n_files > 0:
                result["status"] = "success"
                print(f"  [{ts()}] OK {task_name} ({n_files} files, {len(tar_bytes)//1024} KB)")
            else:
                result["status"] = "error"
                result["error"] = f"exit={r.exit_code}, files={n_files}"
                print(f"  [{ts()}] FAIL {task_name}: {result['error']}")

        except asyncio.TimeoutError:
            result["status"] = "timeout"
            result["error"] = f"Exceeded {SCAFFOLD_TIMEOUT}s"
            print(f"  [{ts()}] TIMEOUT {task_name}")
        except Exception as e:
            result["status"] = "error"
            result["error"] = f"{type(e).__name__}: {str(e)[:400]}"
            print(f"  [{ts()}] ERROR {task_name}: {result['error']}")
        finally:
            if sbx is not None:
                try:
                    await sbx.kill()
                except Exception:
                    pass
            result["finished_at"] = datetime.now().isoformat()
            result["elapsed_sec"] = (datetime.now() - started).total_seconds()
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            json.dump(result, open(log_file, "w"), indent=2)

        return result


async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--session-ids", help="Comma-separated SWE-chat session_ids")
    src.add_argument("--from-screening", action="store_true",
                     help="Load VIABLE candidates from step2_candidates.json (sorted by stars)")
    p.add_argument("--limit", type=int, default=0, help="Cap candidates (0=all)")
    p.add_argument("--offset", type=int, default=0, help="Skip first N (with --from-screening)")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS, help="Concurrent E2B sandboxes")
    p.add_argument("--budget", type=float, default=DEFAULT_BUDGET, help="USD budget per task (claude -p)")
    p.add_argument("--dry-run", action="store_true", help="Show plan without launching sandboxes")
    p.add_argument("--resume", action="store_true", help="Skip already-processed sessions")
    p.add_argument("--from-cached-only", action="store_true",
                   help="Drop candidates whose session JSON isn't in sessions_raw/ instead of aborting")
    p.add_argument("--one-per-repo", action="store_true",
                   help="Keep only the highest-starred VIABLE session per repo (max diversity)")
    args = p.parse_args()

    _load_env_from_dotenv()

    deepseek_key = os.environ.get("DEEPSEEK_API_KEY")
    e2b_key = os.environ.get("E2B_API_KEY") or os.environ.get("e2b_api_key")
    if not args.dry_run:
        if not deepseek_key:
            print("ERROR: DEEPSEEK_API_KEY missing (.env or env). Get one at https://platform.deepseek.com/api_keys")
            return 2
        if not e2b_key:
            print("ERROR: E2B_API_KEY missing (.env or env). Get one at https://e2b.dev/dashboard")
            return 2
        os.environ["E2B_API_KEY"] = e2b_key  # SDK reads from env

    if args.session_ids:
        sids = [s.strip() for s in args.session_ids.split(",") if s.strip()]
        candidates = [synth_candidate(sid) for sid in sids]
        print(f"Direct mode: {len(candidates)} session_ids")
    else:
        candidates = load_screening_candidates()
        if not candidates:
            return 2
        print(f"Loaded {len(candidates)} VIABLE candidates from screening (sorted by stars)")

    if args.one_per_repo:
        seen_repos: set[str] = set()
        deduped = []
        for c in candidates:
            r = c.get("_repo") or "unknown"
            if r in seen_repos:
                continue
            seen_repos.add(r)
            deduped.append(c)
        print(f"--one-per-repo: kept {len(deduped)} of {len(candidates)} (one session per repo)")
        candidates = deduped

    work_items = []
    seen = set()
    for c in candidates:
        name = generate_task_name(c)
        if name in seen:
            name = f"{name}-{c['session_id'][6:10]}"
        seen.add(name)
        work_items.append((c, name))

    if args.offset:
        work_items = work_items[args.offset:]
    if args.resume:
        processed = get_processed_session_ids()
        existing = get_existing_tasks()
        before = len(work_items)
        work_items = [(c, n) for c, n in work_items
                      if c["session_id"] not in processed and n not in existing]
        print(f"Resume: skipped {before - len(work_items)} already-processed")
    if args.limit:
        work_items = work_items[: args.limit]

    cached, missing = check_cached_sessions([c for c, _ in work_items])
    if missing:
        if args.from_cached_only:
            mset = {c["session_id"] for c in missing}
            work_items = [(c, n) for c, n in work_items if c["session_id"] not in mset]
            print(f"--from-cached-only: dropped {len(missing)} uncached")
        else:
            print(f"\nERROR: {len(missing)} candidates not cached at "
                  f"{SC_SESSIONS_DIR.relative_to(ROOT)}.")
            print("Run: python data-pipeline/screening/scripts/step3_prefetch_viable.py")
            return 2
    if not work_items:
        print("Nothing to scaffold.")
        return 0

    print(f"Will scaffold {len(work_items)} tasks with {args.workers} concurrent sandboxes")
    print(f"Budget/task: ${args.budget}, sandbox timeout: {SANDBOX_TIMEOUT//60} min, "
          f"scaffold timeout: {SCAFFOLD_TIMEOUT//60} min")

    if args.dry_run:
        print(f"\n{'#':>4} {'Task Name':<45} {'Repo':<35} {'Stars':>6}")
        print("-" * 95)
        for i, (c, name) in enumerate(work_items[:50]):
            print(f"{i+1:>4} {name:<45} {c.get('_repo', '?'):<35} {c.get('_stars', 0):>6}")
        if len(work_items) > 50:
            print(f"  ... and {len(work_items) - 50} more")
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(args.workers)
    start = time.time()
    print(f"\n{'='*60}")
    print(f"Starting E2B scaffold at {datetime.now().strftime('%H:%M:%S')}")
    print(f"{'='*60}\n")

    coros = [_run_one(c, name, deepseek_key, sem, args.budget) for c, name in work_items]
    results = await asyncio.gather(*coros, return_exceptions=False)

    elapsed = time.time() - start
    statuses: dict[str, int] = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1

    print(f"\n{'='*60}")
    print(f"Done in {elapsed/60:.1f} min")
    print(f"{'='*60}")
    for s, n in sorted(statuses.items()):
        print(f"  {s:20s}: {n}")

    successes = [r for r in results if r["status"] == "success"]
    if successes:
        print("\nSuccessful tasks:")
        for r in successes:
            print(f"  {r['task_name']}  ({r.get('files_landed', '?')} files, "
                  f"{r.get('elapsed_sec', 0):.0f}s)")

    summary = LOG_DIR / "summary_e2b.json"
    json.dump({
        "timestamp": datetime.now().isoformat(),
        "total": len(results),
        "statuses": statuses,
        "elapsed_sec": elapsed,
        "workers": args.workers,
        "budget_per_task": args.budget,
        "results": results,
    }, open(summary, "w"), indent=2)
    print(f"\nSummary: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
