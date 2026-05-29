"""Ad-hoc Phase 2 batch runner over `--trials-root` directories.

⚠️  This is the ad-hoc CLI for scoring arbitrary trial-root trees. For the
    canonical pipeline use `eval.correctness.run_batch` instead — it auto-runs
    Phase 1 for any task missing a rubric, accepts plan files from
    `eval/run_eval.py`, and writes to the canonical `judge_verdict.json`.

    This file remains because it's convenient for cohort-replay sweeps where you
    just want to point at a folder of trial dirs without authoring a plan file.
    By default it writes to `judge_verdict_phase2.json` (NOT the canonical
    filename) so you can compare side-by-side with an existing legacy verdict;
    pass `--out-name judge_verdict.json` to overwrite the canonical instead.

For each (task, trial) pair: read `harbor_tasks/<task>/canonical_goals.json`
(produced by Phase 1, frozen) and ask the judge to mark met:true/false per
goal. judge_score is mechanically derived from the rubric weights × met flags.

Usage:
    .venv/bin/python -m eval.correctness.run_phase2_batch \\
        --trials-root trails_pilot10/trials_deepseek_pilot_10_task_r1 \\
        --trials-root trails_pilot10/trials_deepseek_pilot_10_task_r2 \\
        --trials-root trails_pilot10/trials_deepseek_pilot_10_task_r3 \\
        --tasks-root harbor_tasks \\
        --workers 10
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
    judge_timeout_for_task,
    run_judge_in_e2b,
)

log = logging.getLogger("phase2")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

PHASE2_PROMPT = (
    REPO_ROOT / "eval" / "correctness" / "prompts" / "judge_phase2_system.md"
).read_text()


def load_tests_files(task_dir: Path) -> dict[str, bytes]:
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


def task_for_trial(trial_dir: Path, tasks_root: Path | None = None) -> str:
    """Map trial dir name back to its full task name.

    Harbor/E2B truncates task dirnames to 32 chars in the template alias —
    so a trial dir like `comfyui-frontend-autoscale-layou__abc` (32 chars
    before `__`) corresponds to the full task `comfyui-frontend-autoscale-layout`
    on disk. Handle that here by prefix-matching against tasks_root entries
    when the exact name doesn't exist.
    """
    raw = trial_dir.name.split("__")[0]
    if tasks_root is None:
        return raw
    if (tasks_root / raw).is_dir():
        return raw
    # Truncated → find unique prefix match in tasks_root
    matches = [p.name for p in tasks_root.iterdir()
               if p.is_dir() and p.name.startswith(raw)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        log.warning("trial %s truncated name %r matches %d tasks: %s — using first",
                    trial_dir.name, raw, len(matches), matches)
        return matches[0]
    return raw  # no match; caller will skip via "missing rubric"


def derive_judge_score(rubric: dict, goal_results: list[dict]) -> tuple[float, str]:
    """Compute judge_score mechanically from frozen weights × met flags.

    Returns (score, verdict_bucket). Verdict thresholds match the prompt:
      ≥0.85 equivalent | 0.30-0.85 partial | <0.30 incorrect
    """
    weight_by_id = {g["id"]: float(g["weight"]) for g in rubric.get("completeness_goals", [])}
    met_by_id = {r["id"]: bool(r.get("met")) for r in goal_results}
    score = round(sum(w * (1.0 if met_by_id.get(gid, False) else 0.0)
                      for gid, w in weight_by_id.items()), 2)
    if score >= 0.85:
        return score, "equivalent"
    if score >= 0.30:
        return score, "partial"
    return score, "incorrect"


async def judge_one_trial(trial_dir: Path, task_dir: Path,
                          oauth_token: str, api_key: str | None,
                          out_name: str, force: bool) -> dict:
    task = task_dir.name
    out_path = trial_dir / out_name
    result: dict[str, Any] = {
        "trial_dir": str(trial_dir),
        "task": task,
        "out_name": out_name,
    }
    if out_path.exists() and not force:
        result["status"] = "skipped_existing"
        return result

    # Frozen rubric (Phase 1 output)
    rubric_path = task_dir / "canonical_goals.json"
    if not rubric_path.exists():
        result["status"] = "skipped_no_rubric"
        result["reason"] = f"missing {rubric_path.relative_to(REPO_ROOT)} (run Phase 1 first)"
        return result
    rubric_text = rubric_path.read_text()
    try:
        rubric = json.loads(rubric_text)
    except Exception as e:
        result["status"] = "rubric_parse_error"
        result["error"] = str(e)
        return result

    # Trial materials
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
    usp = (task_dir / "user_simulation_prompt.md")
    user_sim = usp.read_text() if usp.exists() else ""
    test_sh = (task_dir / "tests" / "test.sh")
    test_sh_text = test_sh.read_text() if test_sh.exists() else ""

    inputs = JudgeInputs(
        readme=readme,
        user_sim_prompt=user_sim,
        oracle_patch="",  # phase 2 doesn't apply oracle
        agent_patch=agent_patch,
        test_sh=test_sh_text,
        system_prompt=PHASE2_PROMPT,
        tests_files=load_tests_files(task_dir),
        phase=2,
        canonical_goals_json=rubric_text,
    )

    timeout = judge_timeout_for_task(task)
    t0 = time.time()
    try:
        run = await run_judge_in_e2b(
            task_name=task,
            trial_id=trial_dir.name,
            inputs=inputs,
            oauth_token=oauth_token,
            timeout_sec=timeout,
            api_key=api_key,
        )
    except Exception as e:
        result["status"] = "sandbox_failed"
        result["error"] = str(e)[:500]
        return result
    elapsed = round(time.time() - t0, 1)

    verdict = run.verdict
    # Mechanical re-derivation: trust the rubric weights, not whatever score the
    # judge guesses. Lets us catch self-contradicting judge output.
    if isinstance(verdict, dict) and "goal_results" in verdict:
        score, bucket = derive_judge_score(rubric, verdict["goal_results"])
        # Preserve the judge-reported values for comparison but make the
        # mechanically-derived ones authoritative.
        verdict["judge_reported_score"] = verdict.get("judge_score")
        verdict["judge_reported_verdict"] = verdict.get("verdict")
        verdict["judge_score"] = score
        verdict["verdict"] = bucket

    # Standard metadata
    verdict["task"] = task
    verdict["trial_id"] = trial_dir.name
    reward_p = trial_dir / "verifier" / "reward.txt"
    if reward_p.exists():
        try:
            verdict["test_reward_raw"] = float(reward_p.read_text().strip())
        except Exception:
            pass
    if verdict.get("judge_score") is not None and verdict.get("test_reward_raw") is not None:
        delta = float(verdict["judge_score"]) - float(verdict["test_reward_raw"])
        verdict["score_delta"] = round(delta, 4)
        verdict["direction"] = ("unchanged" if abs(delta) < 1e-6
                                else "upgrade" if delta > 0 else "downgrade")
    verdict["judge_elapsed_sec"] = elapsed
    verdict["sandbox_id"] = run.sandbox_id
    verdict["judge_exit_code"] = run.exit_code
    if run.judge_model:
        verdict["judge_model"] = run.judge_model
    verdict["judge_phase"] = 2
    verdict["rubric_n_goals"] = len(rubric.get("completeness_goals", []))

    out_path.write_text(json.dumps(verdict, indent=2, ensure_ascii=False))
    result["status"] = "ok" if "error" not in verdict else "verdict_error"
    result["judge_score"] = verdict.get("judge_score")
    result["verdict"] = verdict.get("verdict")
    result["elapsed_sec"] = elapsed
    log.info("[%s] %s score=%s verdict=%s elapsed=%.1fs",
             trial_dir.name, result["status"], result.get("judge_score"),
             result.get("verdict"), elapsed)
    return result


async def amain():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--trials-root", action="append", required=True,
                    help="Directory of <task>__<id> trial dirs (repeat for k replicates)")
    ap.add_argument("--tasks-root", type=Path, default=REPO_ROOT / "harbor_tasks")
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--force", action="store_true",
                    help="Overwrite existing phase-2 verdict files")
    ap.add_argument("--out-name", default="judge_verdict_phase2.json",
                    help="Filename inside each trial dir (default: judge_verdict_phase2.json)")
    ap.add_argument("--summary", type=Path, default=None,
                    help="Write JSON run-summary to this path")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY") or None
    oauth_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    or_key = os.environ.get("OPENROUTER_API_KEY", "")
    judge_via_or = os.environ.get("JUDGE_VIA_OR") == "1"
    judge_via_codex = os.environ.get("JUDGE_VIA_CODEX") == "1"
    if not (api_key or oauth_token or (judge_via_or and or_key) or judge_via_codex):
        sys.exit("ERROR: need ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, "
                 "JUDGE_VIA_OR=1+OPENROUTER_API_KEY, or JUDGE_VIA_CODEX=1")
    if judge_via_or and or_key:
        auth_kind = "OpenRouter (claude --print → OR /v1/messages)"
    elif judge_via_codex:
        auth_kind = "codex via host ChatGPT OAuth"
    elif api_key:
        auth_kind = "ANTHROPIC_API_KEY (pay-per-token)"
    else:
        auth_kind = "CLAUDE_CODE_OAUTH_TOKEN (subscription)"
    log.info("judge auth: %s", auth_kind)

    # Collect all trial dirs across cohorts
    trial_jobs: list[tuple[Path, Path]] = []
    for root in args.trials_root:
        rp = Path(root)
        if not rp.is_dir():
            log.warning("trials-root not found: %s", rp)
            continue
        for trial in sorted(rp.iterdir()):
            if not trial.is_dir():
                continue
            task = task_for_trial(trial, args.tasks_root)
            task_dir = args.tasks_root / task
            if not task_dir.is_dir():
                log.warning("[%s] task dir missing for %r: %s", trial.name, task, task_dir)
                continue
            trial_jobs.append((trial, task_dir))

    log.info("queued %d trials, workers=%d", len(trial_jobs), args.workers)
    sem = asyncio.Semaphore(args.workers)

    async def _bounded(td: Path, tk: Path) -> dict:
        async with sem:
            return await judge_one_trial(td, tk, oauth_token, api_key,
                                         args.out_name, args.force)

    results = await asyncio.gather(*[_bounded(td, tk) for td, tk in trial_jobs])

    from collections import Counter
    tally = Counter(r.get("status", "?") for r in results)
    log.info("done: %s", dict(tally))
    if args.summary:
        args.summary.write_text(json.dumps(
            {"results": results, "tally": dict(tally)},
            indent=2, ensure_ascii=False))
        log.info("summary → %s", args.summary)


def main():
    asyncio.run(amain())


if __name__ == "__main__":
    main()
