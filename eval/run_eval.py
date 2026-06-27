"""End-to-end eval orchestrator — runs the three-step protocol in
`eval/eval_design.md` against one (task, agent, sim) cohort of trial dirs,
then computes the final per-task metrics designed in that doc.

Pipeline:
  step 1   correctness    — Phase 1 (per-task frozen rubric, run-once cached
                            at tasks/<task>/canonical_goals.json) +
                            Phase 2 (per-trial scoring against the rubric in
                            an E2B sandbox)             → judge_verdict.json
  step 2   intent_coverage — LLM match-table             → intent_coverage_verdict.json
  step 2b  tag_messages    — per-message tags → intent_coverage_verdict.json::trial_msg_tags
                             drives User Correction (user_metrics)
  aggregate — compute per-task metrics over all replicate trials

One invocation = one (agent, sim) cohort of trials. The trials_root directory
holds k replicate runs across many tasks; we group by task name (the part
before `__` in the trial dir name) and aggregate within each group.

Usage:
    .venv/bin/python -m eval.run_eval \\
        --trials-root trials_eval_pilot_10_task_r1 \\
        --tasks-root  tasks \\
        --output-dir  pipeline_logs/run_judge_cmp_r1 \\
        --model-tag   ds-pro-gemini-3.1-pro \\
        --correctness-workers 50 \\
        --intent-coverage-workers 5

Each step writes per-trial verdicts in-place under the trial dir; re-running
is idempotent (existing verdicts are reused unless --force-<step> is passed).
Aggregation reads those verdicts and emits per-task summary JSON + Markdown.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
PY = sys.executable
sys.path.insert(0, str(REPO_ROOT))
from eval.user_behavior import user_metrics as kg  # taxonomy + User Correction metric

# Infra sentinel (src/, stdlib-only). Used to EXCLUDE infra-failed trials (agent
# never ran — provider/sandbox error) from scoring; non-infra failures score 0.
sys.path.insert(0, str(REPO_ROOT / "src"))
try:
    from eval_infra_sentinel import classify_or_load as _classify_infra  # noqa: E402
except Exception:
    _classify_infra = None

# Correctness pass bar.
SUCCESS_THRESHOLD = 0.85

logger = logging.getLogger("run_eval")


# ── plan discovery ───────────────────────────────────────────────────────────

def discover_jobs(
    trials_roots: list[Path],
    tasks_root: Path,
    coverage_names: list[str] | None = None,
    judge_names: list[str] | None = None,
) -> list[dict]:
    """Pair each trial dir under each `trials_roots` element with its task dir
    under `tasks_root` by prefix-matching the part before `__`.

    Trial dir names are sometimes truncated copies of the task name (e.g.
    `comfyui-frontend-autoscale-layou__abc` ↔ `comfyui-frontend-autoscale-layout`),
    so we match on `task_dir.name.startswith(prefix)` rather than equality.

    Per-root verdict-filename overrides: `coverage_names` and `judge_names`
    may be passed as parallel lists; each trial inherits the
    overrides of its root. The pilot uses this to read cohort-tagged coverage
    verdicts (`intent_coverage_verdict_v2_freeLLM_r{1,2,3}.json`) without
    renaming files on disk.
    """
    tasks_root = tasks_root.resolve()
    task_dirs = sorted(d for d in tasks_root.iterdir() if d.is_dir())
    if not task_dirs:
        raise SystemExit(f"no task dirs under {tasks_root}")

    if coverage_names and len(coverage_names) not in (1, len(trials_roots)):
        raise SystemExit("--coverage-out-name must be repeated to match --trials-root or given once")
    if judge_names and len(judge_names) not in (1, len(trials_roots)):
        raise SystemExit("--judge-out-name must be repeated to match --trials-root or given once")

    def _pick(names: list[str] | None, i: int, default: str) -> str:
        if not names:
            return default
        return names[i] if len(names) > 1 else names[0]

    jobs: list[dict] = []
    unpaired: list[str] = []
    for i, root in enumerate(trials_roots):
        root = root.resolve()
        cov_name = _pick(coverage_names, i, "intent_coverage_verdict.json")
        judge_name = _pick(judge_names, i, "judge_verdict.json")
        for trial in sorted(root.iterdir()):
            if not trial.is_dir() or "__" not in trial.name:
                continue
            prefix = trial.name.rsplit("__", 1)[0]
            match = next((t for t in task_dirs if t.name == prefix), None)
            if match is None:
                cands = [t for t in task_dirs if t.name.startswith(prefix)]
                if cands:
                    match = max(cands, key=lambda t: len(t.name))
            if match is None:
                unpaired.append(trial.name)
                continue
            jobs.append({
                "trial_dir": str(trial),
                "task_dir": str(match),
                "task": match.name,
                "cohort": root.name,
                "coverage_out_name": cov_name,
                "judge_out_name": judge_name,
            })
    if unpaired:
        logger.warning("dropped %d unpaired trial dirs: %s",
                       len(unpaired), unpaired[:5])
    return jobs


def write_plan(jobs: list[dict], plan_path: Path, out_name: str) -> Path:
    """Write the step-specific plan (with `out_name` injected) to disk and
    return its path. Each step batch runner reads {trial_dir, task_dir,
    out_name} jobs from a JSON list."""
    plan = [
        {"trial_dir": j["trial_dir"], "task_dir": j["task_dir"], "out_name": out_name}
        for j in jobs
    ]
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(json.dumps(plan, indent=2))
    return plan_path


# ── step runners (subprocess each batch CLI) ─────────────────────────────────

def _run_subprocess(cmd: list[str], step: str) -> int:
    logger.info("step %s: %s", step, " ".join(cmd))
    t0 = time.monotonic()
    rc = subprocess.call(cmd, cwd=REPO_ROOT)
    logger.info("step %s exited rc=%d elapsed=%.1fs", step, rc, time.monotonic() - t0)
    return rc


def run_step_correctness(plan: Path, summary: Path, workers: int,
                         force: bool, extra: list[str]) -> int:
    cmd = [
        PY, "-m", "eval.correctness.run_batch",
        "--plan", str(plan),
        "--workers", str(workers),
        "--summary", str(summary),
        *(["--force"] if force else []),
        *extra,
    ]
    return _run_subprocess(cmd, "1-correctness")


def run_step_intent_coverage(plan: Path, summary: Path, workers: int,
                             force: bool, model: str | None,
                             extra: list[str]) -> int:
    cmd = [
        PY, "-m", "eval.user_behavior.run_batch",
        "--plan", str(plan),
        "--workers", str(workers),
        "--summary", str(summary),
        *(["--force"] if force else []),
        *(["--model", model] if model else []),
        *extra,
    ]
    return _run_subprocess(cmd, "2-intent_coverage")


def run_step_tag_messages(trials_roots: list[Path], model: str, workers: int, force: bool) -> int:
    """Step 2b — per-message tagging → trial_msg_tags in each verdict. Pinned
    gemini-3.1-pro @ temp 0, versioned prompt; drives User Correction."""
    cmd = [PY, "-m", "eval.user_behavior.tag_messages",
           "--model", model, "--workers", str(workers), *(["--force"] if force else [])]
    for r in trials_roots:
        cmd += ["--trials-root", str(r)]
    return _run_subprocess(cmd, "2b-tag_messages")


# ── per-trial reads ──────────────────────────────────────────────────────────

def _load_json(p: Path) -> dict | None:
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def _tag_metrics(trial_msg_tags) -> dict:
    """User Correction (#correction + 0.2·nudge) from the per-message multi-label
    tags. Delegates to the single source of truth in user_metrics (same deriver
    tag_messages.py persists into the verdict), so aggregated and stored values are
    identical. Nones when untagged."""
    return kg.metrics_from_rows(trial_msg_tags)


def _trial_runtime_sec(trial_dir: Path) -> float | None:
    """Agent wall-clock per trial (seconds): result.json `agent_execution`
    (started_at→finished_at), falling back to timing.json::trial_wall_clock_sec."""
    ae = (_load_json(trial_dir / "result.json") or {}).get("agent_execution") or {}
    s, f = ae.get("started_at"), ae.get("finished_at")
    if s and f:
        try:
            return (datetime.fromisoformat(f.replace("Z", "+00:00"))
                    - datetime.fromisoformat(s.replace("Z", "+00:00"))).total_seconds()
        except (ValueError, TypeError):
            pass
    v = (_load_json(trial_dir / "timing.json") or {}).get("trial_wall_clock_sec")
    return float(v) if v is not None else None


def _trial_output_tokens(trial_dir: Path) -> int | None:
    """Output+reasoning tokens per trial, summed from the opencode event log
    (agent/opencode.txt `step_finish` rows). None for harnesses without it."""
    p = trial_dir / "agent" / "opencode.txt"
    if not p.exists():
        return None
    tot, found = 0, False
    for line in p.read_text().splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("type") == "step_finish":
            u = (e.get("part") or {}).get("tokens") or {}
            tot += (u.get("output") or 0) + (u.get("reasoning") or 0)
            found = True
    return tot if found else None


def _is_infra_failed(trial_dir: Path) -> bool:
    """True if the trial is an infrastructure failure (agent never really ran —
    provider/sandbox error). Such trials are excluded from scoring, not zeroed."""
    if _classify_infra is None:
        return False
    try:
        return _classify_infra(trial_dir).status == "infra_failed"
    except Exception:
        return False


def _effective_judge_score(trial_dir: Path, judge: dict):
    """Leaderboard scoring rule:
      - infra failure (agent never ran)                       → None  (excluded)
      - any non-infra failure (empty/no patch, verdict_read_   → 0.0   (a fail)
        failed, unjudged)
      - otherwise                                             → judge_score
    """
    if _is_infra_failed(trial_dir):
        return None
    score = judge.get("judge_score")
    if score is None or judge.get("error") == "verdict_read_failed":
        return 0.0
    return score


def join_trial_artefacts(job: dict) -> dict:
    """Read the three per-trial verdicts + reward.txt into one flat record.

    Uses the per-job verdict filenames recorded by `discover_jobs` so different
    trials roots can carry different verdict naming conventions (the pilot
    uses cohort-tagged coverage filenames).

    Missing inputs are tolerated — downstream aggregation guards on `None`.
    """
    trial_dir = Path(job["trial_dir"])
    judge = _load_json(trial_dir / job.get("judge_out_name", "judge_verdict.json")) or {}
    cov   = _load_json(trial_dir / job.get("coverage_out_name", "intent_coverage_verdict.json")) or {}

    reward_p = trial_dir / "verifier" / "reward.txt"
    test_reward: float | None = None
    if reward_p.exists():
        try:
            test_reward = float(reward_p.read_text().strip().splitlines()[0])
        except (ValueError, OSError):
            pass

    final_patch = trial_dir / "agent" / "final.patch"
    empty_patch = (not final_patch.exists()) or final_patch.stat().st_size == 0

    return {
        "task": job["task"],
        "cohort": job.get("cohort", ""),
        "trial_dir": str(trial_dir),
        "trial_id": trial_dir.name,
        # step 1 — correctness (infra-failed → None/excluded; non-infra fail → 0.0)
        "judge_score": _effective_judge_score(trial_dir, judge),
        "judge_score_raw": judge.get("judge_score"),
        "judge_verdict": judge.get("verdict"),
        "test_reward_raw": test_reward,
        "score_delta": judge.get("score_delta"),
        "judge_warnings": len(judge.get("schema_warnings") or []),
        "empty_patch": empty_patch,
        # trial cost
        "runtime_sec": _trial_runtime_sec(trial_dir),
        "output_tokens": _trial_output_tokens(trial_dir),
        # step 2 — intent_coverage (diagnostic)
        "overall_score": cov.get("overall_score"),
        "coverage_rate": cov.get("coverage_rate"),
        "scope_precision": cov.get("scope_precision"),
        "weighted_coverage": cov.get("weighted_coverage"),
        "coverage_warnings": len(cov.get("schema_warnings") or []),
        # step 2b — message tags → User Correction (#correction + 0.2·nudge)
        **_tag_metrics(cov.get("trial_msg_tags")),
    }


# ── correctness pass-rate metrics (judge-only, effort-free) ───────────────────

def _judge_scores(trials: list[dict]) -> list[float]:
    return [t["judge_score"] for t in trials if t.get("judge_score") is not None]


def pass_at_1(trials: list[dict], T: float = SUCCESS_THRESHOLD) -> float | None:
    """Single-run success probability: fraction of reps with judge_score ≥ T."""
    js = _judge_scores(trials)
    return (sum(1 for s in js if s >= T) / len(js)) if js else None


def stable_pass_rate(trials: list[dict], T: float = SUCCESS_THRESHOLD) -> float | None:
    """1.0 if the task's mean judge_score over reps clears T, else 0.0."""
    js = _judge_scores(trials)
    return (1.0 if statistics.fmean(js) >= T else 0.0) if js else None


def pass_squared(trials: list[dict], T: float = SUCCESS_THRESHOLD) -> float | None:
    """C(c,2)/C(n,2): a random pair of reps both clear T (canonical k=2 ⇒ both pass).
    None when fewer than 2 reps."""
    js = _judge_scores(trials)
    n = len(js)
    if n < 2:
        return None
    c = sum(1 for s in js if s >= T)
    return math.comb(c, 2) / math.comb(n, 2)


# ── per-task aggregation ─────────────────────────────────────────────────────

def aggregate_per_task(trials_by_task: dict[str, list[dict]]) -> list[dict]:
    rows: list[dict] = []
    for task, trials in sorted(trials_by_task.items()):
        judge_scores = [t["judge_score"] for t in trials if t.get("judge_score") is not None]

        mean_judge = statistics.fmean(judge_scores) if judge_scores else None
        var_judge  = statistics.pvariance(judge_scores) if len(judge_scores) >= 2 else 0.0
        p1, spr, p2 = pass_at_1(trials), stable_pass_rate(trials), pass_squared(trials)

        # benchmark fidelity diagnostics (per-task).
        empty_patch_rate = sum(1 for t in trials if t["empty_patch"]) / len(trials) if trials else 0.0
        any_warnings = sum(
            1 for t in trials
            if (t.get("judge_warnings") or 0) > 0 or (t.get("coverage_warnings") or 0) > 0
        )
        schema_warning_rate = any_warnings / len(trials) if trials else 0.0

        rows.append({
            "task": task,
            "n_total": len(trials),
            # correctness (judge)
            "mean_judge": round(mean_judge, 4) if mean_judge is not None else None,
            "var_judge": round(var_judge, 4),
            "pass_at_1":        round(p1, 4)  if p1  is not None else None,
            "stable_pass_rate": round(spr, 4) if spr is not None else None,
            "pass_sq":          round(p2, 4)  if p2  is not None else None,
            "judge_scores_all": [t.get("judge_score") for t in trials],
            "overall_scores_all": [t.get("overall_score") for t in trials],
            # User Correction (#correction + 0.2·nudge), from message tags
            "user_correction_mean": _safe_mean(t.get("user_correction") for t in trials),
            # trial cost (avg per trial)
            "runtime_sec_mean": _safe_mean(t.get("runtime_sec") for t in trials),
            "output_tokens_mean": _safe_mean(t.get("output_tokens") for t in trials),
            # diagnostics — Intent Coverage (sim-vs-oracle) + benchmark fidelity
            "coverage_mean": _safe_mean(t.get("overall_score") for t in trials),
            "empty_patch_rate": round(empty_patch_rate, 4),
            "schema_warning_rate": round(schema_warning_rate, 4),
        })
    return rows


def _safe_mean(xs) -> float | None:
    vs = [x for x in xs if x is not None]
    return round(statistics.fmean(vs), 4) if vs else None


def _rate(xs) -> float | None:
    vs = [x for x in xs if x is not None]
    return round(sum(1 for x in vs if x) / len(vs), 4) if vs else None


# ── cross-task rollup ────────────────────────────────────────────────────────

def cross_task_rollup(rows: list[dict], denom_tasks: int | None = None) -> dict:
    """Headline numbers. Pass-rate metrics divide by a FIXED `denom_tasks` (the full
    task set, e.g. 109) so tasks with no valid/passing result count as 0; the rest are
    means over the tasks actually present."""
    n_present = len(rows)
    denom = denom_tasks if denom_tasks else n_present
    def m(field: str) -> float | None:           # mean over present tasks
        vs = [r[field] for r in rows if r.get(field) is not None]
        return round(statistics.fmean(vs), 4) if vs else None
    def m_fixed(field: str) -> float | None:     # sum over present / fixed denom
        vs = [r[field] for r in rows if r.get(field) is not None]
        return round(sum(vs) / denom, 4) if denom else None
    return {
        "n_tasks": n_present,
        "denom_tasks": denom,
        "mean_judge_over_tasks": m("mean_judge"),
        "pass_at_1_mean": m_fixed("pass_at_1"),
        "stable_pass_rate_mean": m_fixed("stable_pass_rate"),
        "pass_sq_mean": m_fixed("pass_sq"),
        "user_correction_mean": m("user_correction_mean"),
        "runtime_sec_mean": m("runtime_sec_mean"),
        "output_tokens_mean": m("output_tokens_mean"),
        # diagnostics
        "coverage_mean": m("coverage_mean"),
        "empty_patch_rate_mean": m("empty_patch_rate"),
        "schema_warning_rate_mean": m("schema_warning_rate"),
    }


# ── Markdown report ──────────────────────────────────────────────────────────

def render_markdown(per_task: list[dict], rollup: dict, args) -> str:
    roots_label = ", ".join(p.name for p in args.trials_root) if isinstance(args.trials_root, list) else str(args.trials_root)
    lines = [
        f"# Eval run — {args.model_tag or roots_label}",
        "",
        f"- trials roots: `{roots_label}`",
        f"- tasks root: `{args.tasks_root}`",
        f"- n tasks: {rollup['n_tasks']}  (pass-rate denom: {rollup.get('denom_tasks', rollup['n_tasks'])})",
        f"- success threshold: judge_score ≥ {SUCCESS_THRESHOLD}",
        "- scoring: infra-failed trials excluded; non-infra failures (empty patch / unjudged) = 0",
        "",
        "## Headline (cross-task means)",
        "",
        "| metric | value |",
        "|---|---:|",
    ]
    for k in (
        "mean_judge_over_tasks",
        "pass_at_1_mean", "stable_pass_rate_mean", "pass_sq_mean",
        "user_correction_mean",
        "runtime_sec_mean", "output_tokens_mean",
        "coverage_mean",
        "empty_patch_rate_mean", "schema_warning_rate_mean",
    ):
        v = rollup.get(k)
        lines.append(f"| `{k}` | {v if v is not None else '—'} |")

    lines.extend([
        "",
        "## Per-task",
        "",
        "| task | n_total | mean_judge | pass@1 | stable | pass² | user_corr μ | runtime s | out tok | coverage | empty% | warn% |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for r in per_task:
        lines.append("| " + " | ".join([
            f"`{r['task']}`",
            f"{r['n_total']}",
            _fmt(r['mean_judge']),
            _fmt(r['pass_at_1']),
            _fmt(r['stable_pass_rate']),
            _fmt(r['pass_sq']),
            _fmt(r['user_correction_mean']),
            _num(r['runtime_sec_mean']),
            _num(r['output_tokens_mean']),
            _fmt(r['coverage_mean']),
            _pct(r['empty_patch_rate']),
            _pct(r['schema_warning_rate']),
        ]) + " |")
    return "\n".join(lines) + "\n"


def _fmt(x: Any) -> str:
    if x is None:
        return "—"
    if isinstance(x, float):
        return f"{x:.3f}"
    return str(x)


def _pct(x: Any) -> str:
    if x is None:
        return "—"
    return f"{x * 100:.1f}%"


def _num(x: Any) -> str:
    if x is None:
        return "—"
    return f"{x:,.0f}"


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--trials-root", type=Path, required=True, action="append",
                    help="Directory holding <task>__<id> trial dirs. Repeat to aggregate "
                         "across multiple cohorts as k replicates of the same (task, agent, sim).")
    ap.add_argument("--tasks-root", type=Path,
                    default=REPO_ROOT / "tasks",
                    help="Directory holding canonical task dirs (default: tasks/)")
    ap.add_argument("--output-dir", type=Path, required=True,
                    help="Directory to write plan, step summaries, and aggregate report")
    ap.add_argument("--model-tag", default="",
                    help="Label for this (agent, sim) cohort in the report header")

    # Verdict file names — pass once for the same name across all trials roots,
    # or pass repeated values to match the order of --trials-root (per-cohort overrides).
    ap.add_argument("--judge-out-name", action="append", default=None,
                    help="default: judge_verdict.json")
    ap.add_argument("--coverage-out-name", action="append", default=None,
                    help="default: intent_coverage_verdict.json")

    # Skip / force / per-step concurrency.
    ap.add_argument("--skip-correctness", action="store_true")
    ap.add_argument("--skip-intent-coverage", action="store_true")
    ap.add_argument("--skip-tag-messages", action="store_true")
    ap.add_argument("--force-tag-messages", action="store_true")
    ap.add_argument("--tag-workers", type=int, default=50)
    ap.add_argument("--tag-model", default="gemini/gemini-3.1-pro-preview",
                    help="LLM model for message tagging (pinned for reproducibility)")
    ap.add_argument("--only-aggregate", action="store_true",
                    help="Skip all three steps and just aggregate existing verdicts")
    ap.add_argument("--force-correctness", action="store_true")
    ap.add_argument("--force-intent-coverage", action="store_true")
    ap.add_argument("--correctness-workers", type=int, default=20)
    ap.add_argument("--intent-coverage-workers", type=int, default=5)
    ap.add_argument("--intent-coverage-model", default=None,
                    help="LLM model for intent_coverage (default: package default)")
    ap.add_argument("--denom-tasks", type=int, default=None,
                    help="Fixed task-count denominator for pass-rate metrics (default: "
                         "#task dirs under --tasks-root, e.g. 109). Missing / all-infra "
                         "tasks then count as 0.")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)

    jobs = discover_jobs(
        args.trials_root, args.tasks_root,
        coverage_names=args.coverage_out_name,
        judge_names=args.judge_out_name,
    )
    if not jobs:
        logger.error("no trial/task pairs found under %s ↔ %s",
                     args.trials_root, args.tasks_root)
        return 2
    logger.info("paired %d trial dirs across %d unique tasks (cohorts: %s)",
                len(jobs), len({j["task"] for j in jobs}),
                sorted({j["cohort"] for j in jobs}))

    if args.only_aggregate:
        args.skip_correctness = args.skip_intent_coverage = args.skip_tag_messages = True

    # Plans are step-CLI-format; per-cohort verdict filenames go through each
    # job's `*_out_name` field already so a single plan with mixed cohorts
    # works (each step CLI writes to the per-job out_name).
    # If you need to actually RUN a step across mixed cohorts, the step CLI
    # uses ONE out_name across the whole plan — write one plan per distinct
    # out_name in that case.
    distinct_judge = sorted({j["judge_out_name"] for j in jobs})
    distinct_cov   = sorted({j["coverage_out_name"] for j in jobs})

    def _plan_path(prefix: str, name: str, multi: bool) -> Path:
        return out / (f"plan_{prefix}_{Path(name).stem}.json" if multi
                      else f"plan_{prefix}.json")

    plan_correct_paths = [
        write_plan([j for j in jobs if j["judge_out_name"] == n],
                   _plan_path("correctness", n, len(distinct_judge) > 1), n)
        for n in distinct_judge
    ]
    plan_cov_paths = [
        write_plan([j for j in jobs if j["coverage_out_name"] == n],
                   _plan_path("intent_coverage", n, len(distinct_cov) > 1), n)
        for n in distinct_cov
    ]

    if not args.skip_correctness:
        for p in plan_correct_paths:
            rc = run_step_correctness(
                p, out / f"summary_{p.stem}.json",
                workers=args.correctness_workers, force=args.force_correctness,
                extra=[],
            )
            if rc != 0:
                logger.error("step 1 (correctness) failed rc=%d on %s — continuing", rc, p.name)

    if not args.skip_intent_coverage:
        for p in plan_cov_paths:
            rc = run_step_intent_coverage(
                p, out / f"summary_{p.stem}.json",
                workers=args.intent_coverage_workers, force=args.force_intent_coverage,
                model=args.intent_coverage_model, extra=[],
            )
            if rc != 0:
                logger.error("step 2 (intent_coverage) failed rc=%d on %s — continuing", rc, p.name)

    if not args.skip_tag_messages:
        rc = run_step_tag_messages(args.trials_root, model=args.tag_model,
                                   workers=args.tag_workers, force=args.force_tag_messages)
        if rc != 0:
            logger.error("step 2b (tag_messages) failed rc=%d — continuing", rc)

    # Aggregate — read every per-trial verdict and group by task.
    logger.info("aggregating per-task metrics from %d trials", len(jobs))
    flat = [join_trial_artefacts(j) for j in jobs]
    by_task: dict[str, list[dict]] = defaultdict(list)
    for t in flat:
        by_task[t["task"]].append(t)

    denom_tasks = args.denom_tasks
    if denom_tasks is None and args.tasks_root.is_dir():
        denom_tasks = sum(1 for d in args.tasks_root.iterdir() if d.is_dir()) or None
    per_task = aggregate_per_task(by_task)
    rollup   = cross_task_rollup(per_task, denom_tasks)

    report = {
        "model_tag": args.model_tag,
        "trials_roots": [str(p.resolve()) for p in args.trials_root],
        "tasks_root": str(args.tasks_root.resolve()),
        "cohorts": sorted({j["cohort"] for j in jobs}),
        "n_trials": len(flat),
        "success_threshold": SUCCESS_THRESHOLD,
        "cross_task": rollup,
        "per_task": per_task,
    }
    (out / "eval_report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    (out / "per_trial.json").write_text(json.dumps(flat, indent=2, ensure_ascii=False))
    (out / "eval_report.md").write_text(render_markdown(per_task, rollup, args))

    logger.info("wrote eval_report.{json,md} + per_trial.json under %s", out)
    print(f"\n→ {out / 'eval_report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
