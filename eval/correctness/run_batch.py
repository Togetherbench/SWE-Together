"""Canonical correctness step — Phase 1 (rubric, once per task) + Phase 2 (per trial).

This is the agentic judge for `eval/eval_design.md` Step 1. Two phases:

  **Phase 1** — `generate_task_goals.generate_one` — runs **once per task**:
      reads task spec + oracle patch, derives per-task `canonical_goals.json`
      (frozen rubric of weighted goals). Same rubric is re-used across every
      cohort + replicate, so judge_score deltas reflect agent quality rather
      than judge decomposition noise. Cached at
      `harbor_tasks/<task>/canonical_goals.json`.

  **Phase 2** — per-trial scoring — runs **once per trial**:
      reads the frozen rubric, marks each goal `met: true/false` against the
      agent's patch, and writes `judge_verdict.json` with
      `judge_score = sum(weight × met)` mechanically derived.

This runner reads a plan file describing many (trial, task, out_name) jobs.
At startup it runs Phase 1 for any unique task lacking a rubric, then Phase 2
in an asyncio.Semaphore-bounded sandbox pool.

Usage (matches the legacy single-pass CLI for orchestrator drop-in):
    .venv/bin/python -m eval.correctness.run_batch --plan plan.json --workers 50

Plan file shape (JSON list):
    [
      {"trial_dir": "<abs path>", "task_dir": "<abs path>",
       "out_name": "judge_verdict.json"},
      ...
    ]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

from eval.correctness.sandbox import (  # noqa: E402
    JudgeInputs,
    judge_timeout_for_task,
    run_judge_in_e2b,
)
from eval.correctness.generate_task_goals import generate_one as _phase1_generate_one
from eval.correctness._env import load_dotenv  # shared .env loader

REPO_ROOT = Path(__file__).resolve().parents[2]
PHASE2_PROMPT = (
    REPO_ROOT / "eval" / "correctness" / "prompts" / "judge_phase2_system.md"
).read_text()

log = logging.getLogger(__name__)


def _load_tests_files(task_dir: Path) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    td = task_dir / "tests"
    if not td.exists():
        return out
    for f in td.iterdir():
        if f.is_file():
            try:
                out[f.name] = f.read_bytes()
            except Exception:
                pass
    return out


def _derive_judge_score(rubric: dict, goal_results: list[dict]) -> tuple[float, str]:
    """Mechanical re-derivation: trust the rubric weights, not whatever score the
    judge guesses. Lets us catch self-contradicting judge output."""
    weight_by_id = {g["id"]: float(g["weight"])
                    for g in rubric.get("completeness_goals", [])}
    met_by_id = {r["id"]: bool(r.get("met")) for r in goal_results}
    score = round(sum(w * (1.0 if met_by_id.get(gid, False) else 0.0)
                      for gid, w in weight_by_id.items()), 2)
    if score >= 0.85:
        return score, "equivalent"
    if score >= 0.30:
        return score, "partial"
    return score, "incorrect"


async def _ensure_rubrics(task_dirs: set[Path], oauth_token: str,
                          api_key: str | None, workers: int,
                          force: bool) -> list[dict]:
    """Phase 1 pre-pass — generate canonical_goals.json for any task missing one.

    Phase 1 is **once per task, frozen**. Without --force-rubric, tasks that
    already have a rubric are skipped (no LLM call) so this is a near-noop on
    well-warmed task suites."""
    pending = sorted(
        td for td in task_dirs
        if force or not (td / "canonical_goals.json").exists()
    )
    if not pending:
        log.info("Phase 1: all %d tasks already have canonical_goals.json", len(task_dirs))
        return []
    log.info("Phase 1: generating rubrics for %d task(s) (workers=%d, force=%s)",
             len(pending), workers, force)
    sem = asyncio.Semaphore(workers)

    async def _bounded(td: Path) -> dict:
        async with sem:
            return await _phase1_generate_one(td, oauth_token, api_key, force)

    return await asyncio.gather(*[_bounded(td) for td in pending])


async def _phase2_one(job: dict, oauth_token: str, sem: asyncio.Semaphore,
                      api_key: str | None, force: bool) -> dict:
    trial_dir = Path(job["trial_dir"]).expanduser()
    task_dir = Path(job["task_dir"]).expanduser()
    out_name = job.get("out_name") or "judge_verdict.json"
    out_path = trial_dir / out_name
    result: dict[str, Any] = {
        "trial_dir": str(trial_dir),
        "task_dir": str(task_dir),
        "out_name": out_name,
    }

    if out_path.exists() and not force:
        result["status"] = "skipped_existing"
        return result

    rubric_path = task_dir / "canonical_goals.json"
    if not rubric_path.exists():
        result["status"] = "skipped_no_rubric"
        result["reason"] = f"Phase 1 did not produce {rubric_path.relative_to(REPO_ROOT)}"
        return result
    rubric_text = rubric_path.read_text()
    try:
        rubric = json.loads(rubric_text)
    except json.JSONDecodeError as e:
        result["status"] = "rubric_parse_error"
        result["error"] = str(e)
        return result

    agent_patch_p = trial_dir / "agent" / "final.patch"
    if not agent_patch_p.exists():
        result["status"] = "skipped_no_patch"
        return result
    agent_patch = agent_patch_p.read_text()
    if len(agent_patch.strip()) < 100:
        result["status"] = "skipped_empty_patch"
        result["patch_bytes"] = len(agent_patch)
        return result

    readme = (task_dir / "README.md").read_text() if (task_dir / "README.md").exists() else ""
    usp = task_dir / "user_simulation_prompt.md"
    user_sim = usp.read_text() if usp.exists() else ""
    test_sh_p = task_dir / "tests" / "test.sh"
    test_sh_text = test_sh_p.read_text() if test_sh_p.exists() else ""

    inputs = JudgeInputs(
        readme=readme,
        user_sim_prompt=user_sim,
        oracle_patch="",  # not used in Phase 2
        agent_patch=agent_patch,
        test_sh=test_sh_text,
        system_prompt=PHASE2_PROMPT,
        tests_files=_load_tests_files(task_dir),
        phase=2,
        canonical_goals_json=rubric_text,
    )

    timeout = judge_timeout_for_task(task_dir.name)
    async with sem:
        t0 = time.time()
        log.info("start %s out=%s timeout=%ds", trial_dir.name, out_name, timeout)
        try:
            sb = await run_judge_in_e2b(
                task_name=task_dir.name,
                trial_id=trial_dir.name,
                inputs=inputs,
                oauth_token=oauth_token,
                timeout_sec=timeout,
                api_key=api_key,
            )
        except Exception as e:
            result["status"] = "sandbox_failed"
            result["error"] = str(e)[:500]
            log.warning("sandbox_failed %s: %s", trial_dir.name, result["error"])
            return result
        elapsed = round(time.time() - t0, 1)

    verdict = dict(sb.verdict) if isinstance(sb.verdict, dict) else {"error": "non-dict verdict"}
    # Mechanical score re-derivation from frozen rubric weights × met flags.
    if "goal_results" in verdict:
        score, bucket = _derive_judge_score(rubric, verdict["goal_results"])
        verdict["judge_reported_score"] = verdict.get("judge_score")
        verdict["judge_reported_verdict"] = verdict.get("verdict")
        verdict["judge_score"] = score
        verdict["verdict"] = bucket

    verdict.setdefault("task", task_dir.name)
    verdict.setdefault("trial_id", trial_dir.name)
    reward_p = trial_dir / "verifier" / "reward.txt"
    if reward_p.exists():
        try:
            verdict["test_reward_raw"] = float(reward_p.read_text().strip())
        except ValueError:
            pass
    js = verdict.get("judge_score")
    tr = verdict.get("test_reward_raw")
    if js is not None and tr is not None:
        d = float(js) - float(tr)
        verdict["score_delta"] = round(d, 4)
        verdict["direction"] = ("unchanged" if abs(d) < 1e-6
                                else "upgrade" if d > 0 else "downgrade")
    verdict["judge_elapsed_sec"] = elapsed
    verdict["sandbox_id"] = sb.sandbox_id
    verdict["judge_exit_code"] = sb.exit_code
    if sb.judge_model:
        verdict["judge_model"] = sb.judge_model
    verdict["judge_phase"] = 2
    verdict["rubric_n_goals"] = len(rubric.get("completeness_goals", []))

    out_path.write_text(json.dumps(verdict, indent=2, ensure_ascii=False))
    result["status"] = "ok" if "error" not in verdict else "verdict_error"
    result["judge_score"] = verdict.get("judge_score")
    result["test_reward_raw"] = verdict.get("test_reward_raw")
    result["verdict"] = verdict.get("verdict")
    result["direction"] = verdict.get("direction")
    result["elapsed_sec"] = elapsed
    log.info("done %s score=%s verdict=%s elapsed=%.1fs",
             trial_dir.name, result.get("judge_score"),
             result.get("verdict"), elapsed)
    return result


async def amain() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--plan", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--out-name", default="judge_verdict.json",
                    help="default filename inside each trial dir "
                         "(plan entries' own out_name takes precedence)")
    ap.add_argument("--force", action="store_true",
                    help="Re-run Phase 2 over existing per-trial verdict files. "
                         "Does NOT regenerate the frozen Phase 1 rubric — "
                         "use --force-rubric for that.")
    ap.add_argument("--force-rubric", action="store_true",
                    help="Re-run Phase 1 even when canonical_goals.json exists. "
                         "Use only when intentionally rebuilding rubrics.")
    ap.add_argument("--phase1-workers", type=int, default=5,
                    help="Concurrency cap for Phase 1 pre-pass (default: 5).")
    ap.add_argument("--skip-phase1", action="store_true",
                    help="Skip the Phase 1 pre-pass entirely; trials whose task "
                         "is missing canonical_goals.json will report "
                         "skipped_no_rubric.")
    ap.add_argument("--summary", type=Path, default=None,
                    help="Write JSON run-summary to this path "
                         "(default: <plan>.summary.json)")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    load_dotenv()
    if not os.environ.get("E2B_API_KEY"):
        print("ERROR: E2B_API_KEY not set", file=sys.stderr)
        return 2
    api_key = os.environ.get("ANTHROPIC_API_KEY") or None
    oauth = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if not (api_key or oauth):
        print("ERROR: need ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN",
              file=sys.stderr)
        return 2
    auth_kind = ("ANTHROPIC_API_KEY (pay-per-token)" if api_key
                 else "CLAUDE_CODE_OAUTH_TOKEN (subscription)")
    log.info("judge auth: %s", auth_kind)

    if not args.plan.exists():
        print(f"ERROR: plan not found: {args.plan}", file=sys.stderr)
        return 2
    jobs = json.loads(args.plan.read_text())
    if not isinstance(jobs, list):
        print("ERROR: plan must be a JSON list", file=sys.stderr)
        return 2
    for j in jobs:
        if not j.get("out_name"):
            j["out_name"] = args.out_name

    # Phase 1 pre-pass — generate any missing rubrics. Cached on disk under
    # `harbor_tasks/<task>/canonical_goals.json`; on a warmed suite this is a
    # near-noop (all tasks report `skipped_existing`).
    phase1_results: list[dict] = []
    if not args.skip_phase1:
        task_dirs = {Path(j["task_dir"]).expanduser() for j in jobs}
        phase1_results = await _ensure_rubrics(
            task_dirs, oauth, api_key, args.phase1_workers, args.force_rubric,
        )
        p1_tally = Counter(r.get("status", "?") for r in phase1_results)
        if p1_tally:
            log.info("Phase 1 tally: %s", dict(p1_tally))

    # Phase 2 — per-trial scoring.
    log.info("Phase 2: %d trial job(s), workers=%d", len(jobs), args.workers)
    sem = asyncio.Semaphore(args.workers)
    t0 = time.time()
    tasks = [
        asyncio.create_task(_phase2_one(j, oauth, sem, api_key, args.force))
        for j in jobs
    ]
    results = await asyncio.gather(*tasks)
    elapsed = time.time() - t0

    summary_path = args.summary or args.plan.with_suffix(".summary.json")
    summary = {
        "plan": str(args.plan),
        "workers": args.workers,
        "phase1_workers": args.phase1_workers,
        "force": args.force,
        "force_rubric": args.force_rubric,
        "skip_phase1": args.skip_phase1,
        "elapsed_sec": round(elapsed, 1),
        "n_jobs": len(jobs),
        "phase1_results": phase1_results,
        "phase2_results": results,
    }
    summary_path.write_text(json.dumps(summary, indent=2))

    p2_tally = Counter(r.get("status", "?") for r in results)
    print(f"\nwrote summary to {summary_path}")
    print(f"\nDone in {elapsed:.1f}s")
    if phase1_results:
        p1_tally = Counter(r.get("status", "?") for r in phase1_results)
        print(f"  Phase 1: {dict(p1_tally)}")
    for k, v in sorted(p2_tally.items()):
        print(f"  Phase 2 {k}: {v}")
    return 0


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
