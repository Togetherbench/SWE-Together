#!/usr/bin/env python3
"""Nop validation for harbor tasks via E2B sandboxes.

Spins up each task's E2B sandbox, uploads test.sh, runs it on the base commit
(no agent fix applied), and checks that the score is reasonable.

This catches:
  - ALL-PERFECT bugs (score = 1.0 on unfixed code)
  - Environment issues (test.sh crashes, no reward file)
  - Broken tests (score = 0.0 when some structural checks should pass)

Usage:
    python src/validate_tasks.py                         # validate all
    python src/validate_tasks.py --tasks "comfyui-*"     # glob pattern
    python src/validate_tasks.py --workers 10             # concurrency
    python src/validate_tasks.py --json                   # machine-readable
"""

from __future__ import annotations

import argparse
import asyncio
import fnmatch
import json
import os
import sys
import time
from pathlib import Path

from dirhash import dirhash
from e2b import AsyncSandbox, AsyncTemplate

TASKS_DIR = Path(__file__).parent.parent / "harbor_tasks"
os.environ.setdefault("E2B_API_KEY", os.environ.get("E2B_API_KEY", ""))


def get_template_name(task_name: str) -> str:
    """Compute E2B template alias matching harbor's convention."""
    env_dir = TASKS_DIR / task_name / "environment"
    h = dirhash(str(env_dir), "sha256")[:8]
    return f"{task_name}__{h}".replace(".", "-")


async def validate_task(
    task_name: str, semaphore: asyncio.Semaphore, timeout: int = 120
) -> dict:
    """Run test.sh on base commit (nop) and return the reward."""
    test_sh = TASKS_DIR / task_name / "tests" / "test.sh"
    if not test_sh.exists():
        return {"task": task_name, "verdict": "skip", "reason": "no test.sh"}

    template_name = get_template_name(task_name)

    async with semaphore:
        start = time.time()
        sandbox = None
        try:
            # Check template exists
            if not await AsyncTemplate.alias_exists(template_name):
                return {
                    "task": task_name,
                    "verdict": "fail_build",
                    "reason": f"template {template_name} not found",
                    "time": 0,
                }

            # Create sandbox
            sandbox = await AsyncSandbox.create(
                template=template_name, timeout=300
            )

            # Create verifier dirs (may need sudo for root-owned paths)
            await sandbox.commands.run(
                "sudo mkdir -p /logs/verifier /logs/agent && sudo chmod 777 /logs/verifier /logs/agent"
            )

            # Upload test.sh
            content = test_sh.read_text()
            await sandbox.files.write("/tests/test.sh", content)
            await sandbox.commands.run("chmod +x /tests/test.sh")

            # Run test.sh (nop — no fix applied)
            result = await sandbox.commands.run(
                "cd /workspace && bash /tests/test.sh 2>&1",
                timeout=timeout,
            )

            # Read reward
            try:
                reward_content = await sandbox.files.read("/logs/verifier/reward.txt")
                reward = float(reward_content.strip())
            except Exception:
                reward = None

            elapsed = time.time() - start

            # Determine verdict
            if reward is None:
                verdict = "error"
                reason = "no reward.txt written"
            elif reward >= 0.95:
                verdict = "fail_nop_high"
                reason = f"nop score {reward:.2f} — tests don't catch bugs"
            elif reward == 0.0:
                verdict = "warn_nop_zero"
                reason = "nop score 0.00 — possible env issue or expected"
            elif reward < 0.50:
                verdict = "pass"
                reason = f"nop score {reward:.2f}"
            else:
                verdict = "warn_nop_mid"
                reason = f"nop score {reward:.2f} — higher than expected"

            return {
                "task": task_name,
                "verdict": verdict,
                "reward": reward,
                "reason": reason,
                "exit_code": result.exit_code,
                "time": round(elapsed, 1),
            }

        except Exception as e:
            elapsed = time.time() - start
            error_msg = str(e)[:300]
            return {
                "task": task_name,
                "verdict": "error",
                "reason": error_msg,
                "time": round(elapsed, 1),
            }
        finally:
            if sandbox:
                try:
                    await sandbox.kill()
                except Exception:
                    pass


async def main():
    parser = argparse.ArgumentParser(description="Nop-validate harbor tasks via E2B")
    parser.add_argument("--tasks", help="Glob pattern (e.g., 'comfyui-*')")
    parser.add_argument("--workers", type=int, default=10, help="Concurrency")
    parser.add_argument("--timeout", type=int, default=120, help="Per-task timeout (s)")
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    if not os.environ.get("E2B_API_KEY"):
        print("E2B_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    tasks = sorted(
        d.name
        for d in TASKS_DIR.iterdir()
        if d.is_dir() and (d / "tests" / "test.sh").exists()
    )
    if args.tasks:
        tasks = [t for t in tasks if fnmatch.fnmatch(t, args.tasks)]

    if not tasks:
        print("No tasks found.")
        sys.exit(1)

    if not args.json_output:
        print(f"Validating {len(tasks)} tasks (workers={args.workers}, timeout={args.timeout}s)\n")

    semaphore = asyncio.Semaphore(args.workers)
    results = await asyncio.gather(
        *[validate_task(t, semaphore, args.timeout) for t in tasks]
    )

    if args.json_output:
        json.dump(results, sys.stdout, indent=2)
        print()
        return

    # Print results grouped by verdict
    by_verdict = {}
    for r in results:
        by_verdict.setdefault(r["verdict"], []).append(r)

    for verdict in ["pass", "warn_nop_zero", "warn_nop_mid", "fail_nop_high", "fail_build", "error", "skip"]:
        items = by_verdict.get(verdict, [])
        if not items:
            continue
        icon = {"pass": "OK", "warn_nop_zero": "??", "warn_nop_mid": "!!", "fail_nop_high": "XX", "fail_build": "XX", "error": "XX", "skip": "--"}[verdict]
        print(f"\n{icon} {verdict.upper()} ({len(items)}):")
        for r in sorted(items, key=lambda x: x["task"]):
            reward_str = f" reward={r['reward']:.2f}" if r.get("reward") is not None else ""
            time_str = f" ({r.get('time', 0):.0f}s)" if r.get("time") else ""
            print(f"  {r['task']:50s}{reward_str}{time_str}  {r.get('reason', '')}")

    # Summary
    total = len(results)
    passed = len(by_verdict.get("pass", []))
    warns = len(by_verdict.get("warn_nop_zero", [])) + len(by_verdict.get("warn_nop_mid", []))
    fails = len(by_verdict.get("fail_nop_high", [])) + len(by_verdict.get("fail_build", [])) + len(by_verdict.get("error", []))

    print(f"\n{'='*60}")
    print(f"  {total} tasks validated")
    print(f"  {passed} passed, {warns} warnings, {fails} failures")
    print(f"{'='*60}")


if __name__ == "__main__":
    asyncio.run(main())
