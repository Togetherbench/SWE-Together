"""Clean-sandbox replay: spin fresh E2B sandbox per trial, apply final.patch,
run test.sh inside, write reward to trial_dir/verifier/reward.replay.txt.

No LLM. Just sandbox + git apply + bash test.sh. This is the "what would
test.sh score on a clean buggy state + ONLY this patch" measurement that
the production leaderboard's finalize_v044.sh does, but we keep the original
reward.txt intact (write to a parallel file) so polluted vs clean can be
compared side-by-side.

Usage:
    .venv/bin/python -m eval.agentic.clean_replay \
        --trial-list /tmp/eligible_trials.txt \
        --workers 5
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
from typing import Optional

from e2b import AsyncSandbox

from eval.agentic.judge_one import load_dotenv
from eval.agentic.sandbox import template_alias, SANDBOX_BUFFER_SEC

log = logging.getLogger(__name__)
REPO_ROOT = Path(__file__).resolve().parents[2]
TASKS_DIR = REPO_ROOT / "harbor_tasks"


async def replay_one(
    trial_dir: Path,
    *,
    sandbox_timeout_sec: int = 300,
    sem: Optional[asyncio.Semaphore] = None,
    force: bool = False,
) -> dict:
    """Apply final.patch to a fresh sandbox, run test.sh, return reward."""
    task_name = trial_dir.name.rsplit("__", 1)[0]
    # Harbor truncates dir names to 30 chars; pick the longest matching real task dir
    real_task_name = task_name
    if not (TASKS_DIR / task_name).exists():
        for cand in sorted(TASKS_DIR.iterdir()):
            if cand.is_dir() and cand.name.startswith(task_name):
                real_task_name = cand.name
                break
    task_dir = TASKS_DIR / real_task_name
    out_path = trial_dir / "verifier" / "reward.replay.txt"
    base = {"trial": trial_dir.name, "task": real_task_name}

    if out_path.exists() and not force:
        try:
            base["reward"] = float(out_path.read_text().strip())
        except ValueError:
            base["reward"] = None
        base["status"] = "skipped_existing"
        return base

    final_patch = trial_dir / "agent" / "final.patch"
    if not final_patch.exists() or len(final_patch.read_text().strip()) < 50:
        base["status"] = "skipped_no_patch"
        return base

    tests_dir = task_dir / "tests"
    if not (tests_dir / "test.sh").exists():
        base["status"] = "skipped_no_test_sh"
        return base

    patch_bytes = final_patch.read_bytes()
    tests_files = {p.name: p.read_bytes() for p in tests_dir.iterdir() if p.is_file()}

    alias = template_alias(real_task_name)

    async def _run() -> dict:
        log.info("spawn %s template=%s", trial_dir.name, alias)
        t0 = time.time()
        sb = await AsyncSandbox.create(
            template=alias,
            timeout=sandbox_timeout_sec + SANDBOX_BUFFER_SEC,
            allow_internet_access=True,
        )
        sandbox_id = sb.sandbox_id
        try:
            await sb.files.write("/tmp/agent.patch", patch_bytes)
            apply = await sb.commands.run(
                "set -e; cd /workspace 2>/dev/null || cd /; "
                "REPO=$(find . -maxdepth 3 -name '.git' -type d 2>/dev/null | head -1 | xargs -I{} dirname {}); "
                "if [ -z \"$REPO\" ]; then echo 'NO_GIT_REPO_FOUND' >&2; exit 1; fi; "
                "cd \"$REPO\" && git apply --whitespace=nowarn /tmp/agent.patch && "
                "chmod -R a+rwX /workspace 2>/dev/null || true",
                timeout=120, user="root",
            )
            if apply.exit_code != 0:
                return {**base, "status": "patch_apply_failed",
                        "stderr": (apply.stderr or "")[-2000:],
                        "sandbox_id": sandbox_id}

            # Use Harbor's canonical paths: tests at /tests, logs at /logs/verifier.
            # Several tasks (comfyui, cluefin) hard-code /logs/verifier even when
            # given LOGS_DIR env var — bypassing LOGS_DIR avoids that footgun.
            tests_root = "/tests"
            logs_root = "/logs/verifier"
            await sb.commands.run(f"mkdir -p {tests_root} {logs_root}",
                                  timeout=10, user="root")
            for name, content in tests_files.items():
                await sb.files.write(f"{tests_root}/{name}", content)
            await sb.commands.run(f"chmod +x {tests_root}/test.sh", timeout=10, user="root")

            from e2b.sandbox.commands.command_handle import CommandExitException
            try:
                res = await sb.commands.run(
                    f"bash {tests_root}/test.sh",
                    timeout=sandbox_timeout_sec, user="root",
                )
                stdout, stderr = res.stdout, res.stderr
                exit_code = res.exit_code
            except CommandExitException as e:
                stdout = getattr(e, "stdout", "") or ""
                stderr = getattr(e, "stderr", "") or str(e)
                exit_code = getattr(e, "exit_code", 1)

            reward_str = None
            try:
                reward_str = await sb.files.read(f"{logs_root}/reward.txt")
            except Exception:
                pass

            elapsed = time.time() - t0
            result = {**base, "elapsed_sec": round(elapsed, 1),
                      "sandbox_id": sandbox_id, "test_exit_code": exit_code}
            if reward_str:
                try:
                    reward = float(reward_str.strip())
                    result["reward"] = reward
                    result["status"] = "ok"
                    out_path.write_text(f"{reward}\n")
                    # also dump test stdout for audit
                    (trial_dir / "verifier" / "test-stdout.replay.txt").write_text(stdout)
                    return result
                except ValueError:
                    pass
            result["status"] = "no_reward_written"
            result["stdout_tail"] = stdout[-500:]
            result["stderr_tail"] = (stderr or "")[-500:]
            return result
        finally:
            try: await sb.kill()
            except Exception: pass

    if sem is None:
        return await _run()
    async with sem:
        return await _run()


async def amain() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trial-list", required=True, type=Path,
                    help="file with one trial dir per line (relative to repo root)")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--sandbox-timeout-sec", type=int, default=300)
    ap.add_argument("--force", action="store_true",
                    help="re-run even if reward.replay.txt exists")
    ap.add_argument("--out", type=Path,
                    default=REPO_ROOT / "logs" / "clean_replay_results.json")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv()
    if not os.environ.get("E2B_API_KEY"):
        print("ERROR: E2B_API_KEY not set", file=sys.stderr); return 2

    trial_paths = [Path(p.strip()) for p in args.trial_list.read_text().splitlines() if p.strip()]
    trial_paths = [p if p.is_absolute() else REPO_ROOT / p for p in trial_paths]
    print(f"queued {len(trial_paths)} trials, workers={args.workers}", flush=True)

    sem = asyncio.Semaphore(args.workers)
    t0 = time.time()
    results = await asyncio.gather(*[replay_one(p, sandbox_timeout_sec=args.sandbox_timeout_sec,
                                                 sem=sem, force=args.force)
                                     for p in trial_paths])
    elapsed = time.time() - t0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"elapsed_sec": round(elapsed, 1),
                                    "n": len(results), "results": results}, indent=2))
    counts: dict = {}
    for r in results:
        counts[r.get("status", "?")] = counts.get(r.get("status", "?"), 0) + 1
    print(f"\nDone in {elapsed:.1f}s")
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    print(f"wrote summary to {args.out}")
    return 0


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
