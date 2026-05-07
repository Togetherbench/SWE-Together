#!/usr/bin/env python3
"""Canonical-patch oracle for scaffolded harbor tasks.

For each task in harbor_tasks/<name>/ that has a canonical patch (extracted by
step4_extract_canonical_patches.py): build the Dockerfile, apply the patch,
run tests/test.sh, parse the reward, and report whether the test gates
agree with the human's actual fix.

Verdict ladder:
  PASS         reward ≥ 0.70   (test rewards canonical fix as intended)
  WARN         0.50–0.70       (partially aligned; canonical didn't hit all gates)
  FAIL         < 0.50          (test misaligned with actual fix — likely over-narrow)
  PATCH_ERR    git apply failed (patch doesn't apply to buggy state — Dockerfile
                                may be on the wrong base commit)
  BUILD_ERR    docker build failed
  TIMEOUT      docker run > timeout
  ERROR        other
  SKIP         no canonical patch (61% have one)

Usage:
  python data-pipeline/scaffold/verify_canonical.py                    # all tasks with patches
  python data-pipeline/scaffold/verify_canonical.py --task <name>      # single task
  python data-pipeline/scaffold/verify_canonical.py --workers 4        # parallel docker builds
  python data-pipeline/scaffold/verify_canonical.py --dry-run          # show plan
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS_DIR = ROOT / "harbor_tasks"
SC_CANONICAL_PATCHES = (
    ROOT / "data-pipeline" / "screening" / "artifacts_swechat" / "canonical_patches"
)
LOG_DIR = ROOT / "data-pipeline" / "scaffold" / "logs"

BUILD_TIMEOUT = 600     # docker build
APPLY_TIMEOUT = 60      # git apply
RUN_TIMEOUT = 300       # tests/test.sh

# Verdict thresholds
PASS_THRESHOLD = 0.70
WARN_THRESHOLD = 0.50


def load_canonical_patch(sid: str) -> dict | None:
    p = SC_CANONICAL_PATCHES / f"{sid}.json"
    if not p.exists():
        return None
    try:
        return json.load(open(p))
    except Exception:
        return None


def task_session_id(task_name: str) -> str | None:
    p = HARBOR_TASKS_DIR / task_name / "original_session.json"
    if not p.exists():
        return None
    try:
        return json.load(open(p)).get("session_id")
    except Exception:
        return None


def detect_repo_workdir(dockerfile_path: Path) -> str:
    """Best-effort parse of WORKDIR or `git clone ... <dir>` from the Dockerfile.
    Falls back to /workspace/repo if we can't tell."""
    if not dockerfile_path.exists():
        return "/workspace/repo"
    workdir = None
    last_clone_target = None
    for line in dockerfile_path.read_text().splitlines():
        line = line.strip()
        if line.startswith("WORKDIR"):
            workdir = line.split(None, 1)[1].strip()
        elif "git clone" in line:
            # crude: last token that starts with /
            for tok in reversed(line.split()):
                if tok.startswith("/"):
                    last_clone_target = tok.rstrip("/")
                    break
    return workdir or last_clone_target or "/workspace/repo"


async def _run(cmd: list[str], timeout: int, cwd: Path | None = None,
               input_bytes: bytes | None = None) -> tuple[int, str, str]:
    """Run a subprocess with timeout, return (exit_code, stdout, stderr)."""
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.PIPE if input_bytes is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(cwd) if cwd else None,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(input=input_bytes), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "", f"TIMEOUT after {timeout}s"
    return proc.returncode, out.decode("utf-8", errors="replace"), err.decode("utf-8", errors="replace")


def classify(reward: float | None) -> str:
    if reward is None:
        return "ERROR"
    if reward >= PASS_THRESHOLD:
        return "PASS"
    if reward >= WARN_THRESHOLD:
        return "WARN"
    return "FAIL"


async def verify_one(task_name: str, sem: asyncio.Semaphore) -> dict:
    out: dict = {"task_name": task_name, "verdict": "pending"}
    task_dir = HARBOR_TASKS_DIR / task_name
    sid = task_session_id(task_name)
    out["session_id"] = sid
    if not sid:
        out["verdict"] = "SKIP"
        out["reason"] = "no original_session.json"
        return out

    canonical = load_canonical_patch(sid)
    if not canonical:
        out["verdict"] = "SKIP"
        out["reason"] = "no canonical patch (this session has none in step4)"
        return out
    out["commit_sha"] = canonical.get("commit_sha")
    out["agent_percentage"] = canonical.get("agent_percentage")
    out["files_changed_count"] = canonical.get("files_changed_count")

    dockerfile = task_dir / "environment" / "Dockerfile"
    test_sh = task_dir / "tests" / "test.sh"
    if not dockerfile.exists() or not test_sh.exists():
        out["verdict"] = "SKIP"
        out["reason"] = "missing Dockerfile or tests/test.sh"
        return out

    workdir = detect_repo_workdir(dockerfile)
    out["workdir"] = workdir

    async with sem:
        ts = lambda: datetime.now().strftime("%H:%M:%S")
        started = time.time()
        image_tag = f"verify-{task_name.lower()}"

        # 1. docker build
        print(f"  [{ts()}] BUILD {task_name}")
        code, _, err = await _run(
            ["docker", "build", "-q", "-t", image_tag, str(task_dir / "environment")],
            timeout=BUILD_TIMEOUT,
        )
        if code != 0:
            out["verdict"] = "BUILD_ERR"
            out["reason"] = err.strip()[-400:] or "docker build failed"
            print(f"  [{ts()}] BUILD_ERR {task_name}")
            return out

        # 2. write the patch + test.sh into a tmpdir to mount.
        # Put under $HOME so colima's VM can mount it (macOS default TMPDIR
        # at /var/folders/... is not mapped into the colima VM).
        verify_root = Path.home() / ".cache" / "harbor-verify"
        verify_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=f"verify-{task_name}-", dir=str(verify_root)) as td:
            tdp = Path(td)
            (tdp / "patch.diff").write_text(canonical.get("patch", ""))
            shutil.copy(test_sh, tdp / "test.sh")
            # Also copy test_manifest.yaml if it exists (test.sh sometimes reads it)
            manifest = task_dir / "tests" / "test_manifest.yaml"
            if manifest.exists():
                shutil.copy(manifest, tdp / "test_manifest.yaml")

            # 3. docker run: cd workdir, git apply patch (best-effort, --3way), run test.sh
            print(f"  [{ts()}] RUN   {task_name}")
            inner = (
                f"set -e; "
                f"cd {workdir}; "
                f"cp -r /verify/test.sh /tmp/test.sh && chmod +x /tmp/test.sh; "
                f"if [ -f /verify/test_manifest.yaml ]; then mkdir -p /workspace/task/tests && cp /verify/test_manifest.yaml /workspace/task/tests/; fi; "
                f"git apply --3way --whitespace=nowarn /verify/patch.diff 2>/tmp/apply_err.log "
                f"  || git apply --reject --whitespace=nowarn /verify/patch.diff 2>>/tmp/apply_err.log "
                f"  || (echo 'PATCH_APPLY_FAILED' && cat /tmp/apply_err.log; exit 33); "
                f"mkdir -p /logs/verifier; "
                f"bash /tmp/test.sh; "
                f"echo '---REWARD---'; cat /logs/verifier/reward.txt 2>/dev/null || echo MISSING"
            )
            code, stdout, stderr = await _run(
                ["docker", "run", "--rm", "-v", f"{tdp}:/verify:ro",
                 image_tag, "bash", "-c", inner],
                timeout=BUILD_TIMEOUT + RUN_TIMEOUT + APPLY_TIMEOUT,
            )

            if "PATCH_APPLY_FAILED" in stdout:
                out["verdict"] = "PATCH_ERR"
                # extract some diagnostic
                tail = stdout.split("PATCH_APPLY_FAILED", 1)[-1][:600]
                out["reason"] = f"git apply failed: {tail.strip()[:400]}"
                print(f"  [{ts()}] PATCH_ERR {task_name}")
                out["elapsed_sec"] = time.time() - started
                return out

            if code == 124 or "TIMEOUT" in stderr:
                out["verdict"] = "TIMEOUT"
                out["reason"] = stderr.strip()[-200:]
                print(f"  [{ts()}] TIMEOUT {task_name}")
                out["elapsed_sec"] = time.time() - started
                return out

            # 4. parse reward from output
            reward = None
            if "---REWARD---" in stdout:
                tail = stdout.rsplit("---REWARD---", 1)[1].strip()
                if tail and tail != "MISSING":
                    try:
                        reward = float(tail.splitlines()[0].strip())
                    except ValueError:
                        pass
            out["reward"] = reward
            out["verdict"] = classify(reward)
            out["test_stdout_tail"] = stdout[-1500:]
            if code != 0 and reward is None:
                out["verdict"] = "ERROR"
                out["reason"] = (stderr or stdout)[-400:]

        out["elapsed_sec"] = time.time() - started
        emoji = {"PASS":"✓", "WARN":"~", "FAIL":"✗", "PATCH_ERR":"!",
                 "BUILD_ERR":"!", "TIMEOUT":"⏱", "ERROR":"?"}.get(out["verdict"], "?")
        rwd = f"{out.get('reward', '?'):>5}" if out.get("reward") is not None else "  -  "
        print(f"  [{ts()}] {emoji} {out['verdict']:9s} reward={rwd}  {task_name}")
        return out


async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--task", action="append", default=None,
                   help="Verify only this task (repeatable). Default: all tasks with patches.")
    p.add_argument("--workers", type=int, default=2,
                   help="Concurrent docker builds (default 2; docker on macOS is slow)")
    p.add_argument("--dry-run", action="store_true",
                   help="List tasks that would be verified, then exit")
    args = p.parse_args()

    # Sanity: docker available?
    if not args.dry_run:
        if shutil.which("docker") is None:
            print("ERROR: `docker` not on PATH. Verify_canonical needs Docker locally.")
            return 2

    # Build target list
    if args.task:
        targets = args.task
    else:
        targets = sorted(d.name for d in HARBOR_TASKS_DIR.iterdir()
                         if d.is_dir() and d.name != "README.md")

    # Pre-classify: which have patches, which don't
    have_patch, no_patch = [], []
    for t in targets:
        sid = task_session_id(t)
        if sid and load_canonical_patch(sid):
            have_patch.append(t)
        else:
            no_patch.append(t)

    print(f"Tasks scanned: {len(targets)}  |  with canonical patch: {len(have_patch)}  |  without: {len(no_patch)}")
    if args.dry_run:
        print(f"\nWould verify (have patch):")
        for t in have_patch[:50]:
            print(f"  ✓ {t}")
        if len(have_patch) > 50:
            print(f"  ... and {len(have_patch)-50} more")
        print(f"\nWould skip (no patch):")
        for t in no_patch[:20]:
            print(f"  · {t}")
        if len(no_patch) > 20:
            print(f"  ... and {len(no_patch)-20} more")
        return 0

    if not have_patch:
        print("Nothing to verify — no tasks have canonical patches.")
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(args.workers)
    start = time.time()

    print(f"\n{'='*60}")
    print(f"Verifying {len(have_patch)} tasks with {args.workers} concurrent docker workers")
    print(f"{'='*60}\n")

    coros = [verify_one(t, sem) for t in have_patch]
    results = await asyncio.gather(*coros, return_exceptions=False)

    # Summary
    verdicts: dict[str, int] = {}
    for r in results:
        verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
    elapsed = time.time() - start

    print(f"\n{'='*60}")
    print(f"Done in {elapsed/60:.1f} min")
    print(f"{'='*60}")
    for v, n in sorted(verdicts.items()):
        print(f"  {v:<10s} {n}")

    summary = LOG_DIR / "verify_canonical_summary.json"
    json.dump({
        "timestamp": datetime.now().isoformat(),
        "tasks_with_patch": len(have_patch),
        "tasks_no_patch": len(no_patch),
        "elapsed_sec": elapsed,
        "verdicts": verdicts,
        "results": results,
    }, open(summary, "w"), indent=2)
    print(f"\nSummary: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
