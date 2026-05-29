"""Phase 1 of the agentic judge — derive canonical completeness rubrics per task.

Spawns one E2B sandbox per task, applies oracle.patch, runs Claude Code with the
phase-1 system prompt, and writes the resulting FROZEN rubric to
`harbor_tasks/<task>/canonical_goals.json`.

Phase 2 (per-trial scoring) then reads that file and grades each agent's
patch against it — same rubric across all coding-agent cohorts, so judge_score
deltas reflect agent quality rather than judge decomposition noise.

Auth: this script uses the same auth path as eval/correctness/run_batch.py:
- ANTHROPIC_API_KEY (pay-per-token) if set
- otherwise CLAUDE_CODE_OAUTH_TOKEN (subscription, OAuth)
- OPENROUTER_API_KEY routing via in-sandbox proxy: TODO follow-up

Usage:
    .venv/bin/python -m eval.correctness.generate_task_goals \\
        --tasks cli-task-2a55af cli-task-7e3475 ... \\
        --tasks-root harbor_tasks \\
        --workers 5

    # All under harbor_tasks (skipping ones that already have canonical_goals.json):
    .venv/bin/python -m eval.correctness.generate_task_goals --all
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
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from eval.correctness.sandbox import (  # noqa: E402
    JUDGE_TIMEOUT_SEC,
    JudgeInputs,
    JudgeRunResult,
    judge_timeout_for_task,
    run_judge_in_e2b,
)

log = logging.getLogger("generate_task_goals")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

TASKS_DIR = REPO_ROOT / "harbor_tasks"
PHASE1_PROMPT = (
    REPO_ROOT / "eval" / "correctness" / "prompts" / "judge_phase1_system.md"
).read_text()


def load_oracle_patch(task_dir: Path) -> str:
    """Pull the canonical grading patch from `oracle_session.jsonl::header._grading_patch`.

    Falls back to `reference_patch.json` for legacy tasks that haven't been
    migrated. Returns empty string only when neither artifact exists — caller
    should skip such tasks.
    """
    sess = task_dir / "oracle_session.jsonl"
    if sess.exists():
        sys.path.insert(0, str(REPO_ROOT / "data-pipeline" / "src"))
        try:
            from agent_session import AgentSession  # type: ignore
            s = AgentSession.load(sess)
            patch = s.grading_patch or ""
            if patch:
                return patch
        except Exception as e:
            log.warning("agent_session load failed for %s: %s", task_dir.name, e)
    rp = task_dir / "reference_patch.json"
    if rp.exists():
        try:
            return json.loads(rp.read_text()).get("patch", "") or ""
        except Exception:
            pass
    return ""


def load_tests_files(task_dir: Path) -> dict[str, bytes]:
    """Mirror eval/correctness/judge_one.py: read every file under tests/ as bytes."""
    out: dict[str, bytes] = {}
    tests_dir = task_dir / "tests"
    if not tests_dir.exists():
        return out
    for f in tests_dir.iterdir():
        if f.is_file():
            try:
                out[f.name] = f.read_bytes()
            except Exception as e:
                log.debug("skip tests/%s: %s", f.name, e)
    return out


def build_inputs(task_dir: Path) -> JudgeInputs | None:
    """Assemble JudgeInputs for phase-1 (decomposition) on this task."""
    readme = (task_dir / "README.md").read_text() if (task_dir / "README.md").exists() else ""
    usp = (task_dir / "user_simulation_prompt.md")
    user_sim = usp.read_text() if usp.exists() else ""

    oracle = load_oracle_patch(task_dir)
    if not oracle:
        log.warning("skip %s: no oracle patch (oracle_session.jsonl/reference_patch.json missing or empty)", task_dir.name)
        return None

    test_sh = (task_dir / "tests" / "test.sh")
    test_sh_text = test_sh.read_text() if test_sh.exists() else ""

    return JudgeInputs(
        readme=readme,
        user_sim_prompt=user_sim,
        oracle_patch=oracle,
        agent_patch="",  # not used in phase 1
        test_sh=test_sh_text,
        system_prompt=PHASE1_PROMPT,
        tests_files=load_tests_files(task_dir),
        phase=1,
    )


def validate_rubric(rubric: dict) -> list[str]:
    """Schema validation: weights sum to 1.0 (±0.01), ≥1 core, each goal has all fields."""
    warnings: list[str] = []
    if "error" in rubric:
        warnings.append(f"rubric write failed: {rubric.get('error')}")
        return warnings
    goals = rubric.get("completeness_goals", [])
    if not goals:
        warnings.append("no completeness_goals in rubric")
        return warnings
    required_fields = {"id", "goal", "tier", "weight", "rationale"}
    for i, g in enumerate(goals):
        missing = required_fields - set(g.keys() if isinstance(g, dict) else [])
        if missing:
            warnings.append(f"goal[{i}] missing fields: {sorted(missing)}")
    try:
        total = sum(float(g.get("weight", 0)) for g in goals)
        if abs(total - 1.0) > 0.01:
            warnings.append(f"weights sum to {total:.3f}, expected 1.0 (±0.01)")
    except (TypeError, ValueError) as e:
        warnings.append(f"non-numeric weight: {e}")
    if not any(g.get("tier") == "core" for g in goals if isinstance(g, dict)):
        warnings.append("no core-tier goal (≥1 required)")
    return warnings


async def generate_one(task_dir: Path, oauth_token: str, api_key: str | None,
                       force: bool) -> dict:
    """Phase-1 generate for a single task. Returns a summary dict."""
    out_path = task_dir / "canonical_goals.json"
    result: dict[str, Any] = {
        "task": task_dir.name,
        "out_path": str(out_path.relative_to(REPO_ROOT)),
    }
    if out_path.exists() and not force:
        result["status"] = "skipped_existing"
        return result

    inputs = build_inputs(task_dir)
    if inputs is None:
        result["status"] = "skipped_missing_input"
        return result

    effective_timeout = judge_timeout_for_task(task_dir.name)
    t0 = time.time()
    log.info("[%s] starting phase-1 judge in E2B sandbox", task_dir.name)
    try:
        run = await run_judge_in_e2b(
            task_name=task_dir.name,
            trial_id=f"{task_dir.name}__phase1",
            inputs=inputs,
            oauth_token=oauth_token,
            timeout_sec=effective_timeout,
            api_key=api_key,
        )
    except Exception as e:
        result["status"] = "sandbox_failed"
        result["error"] = str(e)[:500]
        return result

    elapsed = round(time.time() - t0, 1)
    result["elapsed_sec"] = elapsed
    result["judge_model"] = run.judge_model
    result["sandbox_id"] = run.sandbox_id
    result["judge_exit_code"] = run.exit_code

    rubric = run.verdict
    schema_warnings = validate_rubric(rubric)
    if schema_warnings:
        result["schema_warnings"] = schema_warnings
        for w in schema_warnings:
            log.warning("[%s] %s", task_dir.name, w)

    if "error" in rubric:
        result["status"] = "rubric_error"
        result["error"] = rubric.get("error")
        return result

    # Persist alongside the task — Phase 2 will read from here.
    out_path.write_text(json.dumps(rubric, indent=2, ensure_ascii=False) + "\n")
    result["status"] = "ok"
    result["n_goals"] = len(rubric.get("completeness_goals", []))
    log.info("[%s] OK — %d goals → %s  (%.1fs)",
             task_dir.name, result["n_goals"], result["out_path"], elapsed)
    return result


async def amain():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tasks", nargs="+", help="Specific task names (e.g. cli-task-2a55af)")
    ap.add_argument("--all", action="store_true", help="All tasks under harbor_tasks/")
    ap.add_argument("--tasks-root", type=Path, default=TASKS_DIR)
    ap.add_argument("--workers", type=int, default=5, help="Parallel sandbox count")
    ap.add_argument("--force", action="store_true", help="Overwrite existing canonical_goals.json")
    ap.add_argument("--summary", type=Path, default=None, help="Write JSON summary to this path")
    args = ap.parse_args()

    if not args.tasks and not args.all:
        ap.error("specify --tasks <names> or --all")

    if args.all:
        task_dirs = sorted(p for p in args.tasks_root.iterdir() if p.is_dir())
    else:
        task_dirs = [args.tasks_root / t for t in args.tasks]
        for td in task_dirs:
            if not td.is_dir():
                ap.error(f"task dir missing: {td}")

    api_key = os.environ.get("ANTHROPIC_API_KEY") or None
    oauth_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not (api_key or oauth_token):
        sys.exit("ERROR: need ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN")
    auth_kind = "ANTHROPIC_API_KEY (pay-per-token)" if api_key else "CLAUDE_CODE_OAUTH_TOKEN (subscription)"
    log.info("judge auth: %s", auth_kind)
    log.info("phase-1 over %d task(s), workers=%d", len(task_dirs), args.workers)

    sem = asyncio.Semaphore(args.workers)

    async def _bounded(td: Path) -> dict:
        async with sem:
            return await generate_one(td, oauth_token, api_key, args.force)

    results = await asyncio.gather(*[_bounded(td) for td in task_dirs])

    # Status tally
    from collections import Counter
    tally = Counter(r.get("status", "?") for r in results)
    log.info("done: %s", dict(tally))

    if args.summary:
        args.summary.write_text(json.dumps({
            "tasks": [r["task"] for r in results],
            "results": results,
            "tally": dict(tally),
        }, indent=2, ensure_ascii=False))
        log.info("summary → %s", args.summary)

    # Exit non-zero if any task ended in a failure status
    if tally.get("ok", 0) < len([r for r in results if r["status"] != "skipped_existing"]):
        return 1
    return 0


def main():
    sys.exit(asyncio.run(amain()))


if __name__ == "__main__":
    main()
