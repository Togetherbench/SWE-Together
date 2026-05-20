"""End-to-end eval orchestrator — runs the three-step protocol in
`eval/eval_design.md` against one (task, agent, sim) cohort of trial dirs,
then computes the final per-task metrics designed in that doc.

Pipeline:
  step 1   correctness    — E2B sandboxed agentic judge → judge_verdict.json
  step 2   intent_coverage — LLM match-table             → intent_coverage_verdict.json
  step 3   user_behavior   — pure file I/O panel         → user_behavior_verdict.json
  aggregate — apply step-2 filter, compute Block 1 / 1' / 3 metrics per task

One invocation = one (agent, sim) cohort of trials. The trials_root directory
holds k replicate runs across many tasks; we group by task name (the part
before `__` in the trial dir name) and aggregate within each group.

Usage:
    .venv/bin/python -m eval.run_eval \\
        --trials-root trials_eval_pilot_10_task_r1 \\
        --tasks-root  harbor_tasks \\
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
import os
import statistics
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
PY = sys.executable

# Mirror eval_design.md §"Filter protocol (step 2)" — keep in sync with
# intent_coverage/METHOD_AND_PILOT.md::disentangle_correctness.
SIGMA_K       = 1.0
ABS_FLOOR     = 0.50
MAGNITUDE_GAP = 0.10

# Block 1 — Capability constants (eval_design.md §"Block 1").
SUCCESS_THRESHOLD = 0.85
EFFORT_AUC_MAX_K  = 10

logger = logging.getLogger("run_eval")


# ── plan discovery ───────────────────────────────────────────────────────────

def discover_jobs(
    trials_roots: list[Path],
    tasks_root: Path,
    coverage_names: list[str] | None = None,
    judge_names: list[str] | None = None,
    behavior_names: list[str] | None = None,
) -> list[dict]:
    """Pair each trial dir under each `trials_roots` element with its task dir
    under `tasks_root` by prefix-matching the part before `__`.

    Trial dir names are sometimes truncated copies of the task name (e.g.
    `comfyui-frontend-autoscale-layou__abc` ↔ `comfyui-frontend-autoscale-layout`),
    so we match on `task_dir.name.startswith(prefix)` rather than equality.

    Per-root verdict-filename overrides: `coverage_names`, `judge_names`, and
    `behavior_names` may be passed as parallel lists; each trial inherits the
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
    if behavior_names and len(behavior_names) not in (1, len(trials_roots)):
        raise SystemExit("--behavior-out-name must be repeated to match --trials-root or given once")

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
        beh_name = _pick(behavior_names, i, "user_behavior_verdict.json")
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
                "behavior_out_name": beh_name,
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
        PY, "-m", "eval.intent_coverage.run_batch",
        "--plan", str(plan),
        "--workers", str(workers),
        "--summary", str(summary),
        *(["--force"] if force else []),
        *(["--model", model] if model else []),
        *extra,
    ]
    return _run_subprocess(cmd, "2-intent_coverage")


def run_step_user_behavior(plan: Path, summary: Path, workers: int,
                           force: bool, extra: list[str]) -> int:
    cmd = [
        PY, "-m", "eval.user_behavior.run_batch",
        "--plan", str(plan),
        "--workers", str(workers),
        "--summary", str(summary),
        *(["--force"] if force else []),
        *extra,
    ]
    return _run_subprocess(cmd, "3-user_behavior")


# ── per-trial reads ──────────────────────────────────────────────────────────

def _load_json(p: Path) -> dict | None:
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


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
    beh   = _load_json(trial_dir / job.get("behavior_out_name", "user_behavior_verdict.json")) or {}

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
        # step 1 — correctness
        "judge_score": judge.get("judge_score"),
        "judge_verdict": judge.get("verdict"),
        "test_reward_raw": test_reward,
        "score_delta": judge.get("score_delta"),
        "judge_warnings": len(judge.get("schema_warnings") or []),
        "empty_patch": empty_patch,
        # step 2 — intent_coverage
        "overall_score": cov.get("overall_score"),
        "coverage_rate": cov.get("coverage_rate"),
        "scope_precision": cov.get("scope_precision"),
        "weighted_coverage": cov.get("weighted_coverage"),
        "coverage_warnings": len(cov.get("schema_warnings") or []),
        # step 3 — user_behavior
        "intervention_count": beh.get("intervention_count"),
        "no_op_count": beh.get("no_op_count"),
        "effort_cost": beh.get("effort_cost"),
        "matched_intents": beh.get("matched_intents"),
        "effort_per_matched_intent": beh.get("effort_per_matched_intent"),
        "hard_cap_abandon": beh.get("hard_cap_abandon"),
        "specificity_present": beh.get("specificity_present"),
        "per_action_count": beh.get("per_action_count") or {},
        "per_tier_count": beh.get("per_tier_count") or {},
    }


# ── filter (step 2 clean) ────────────────────────────────────────────────────

def clean_trials(trials: list[dict]) -> tuple[list[dict], list[dict]]:
    """`eval_design.md` §"Filter protocol (step 2)".

    3-AND per the prose (preferred — protects the gemini-voyager case):
      drop iff (o < median - σ) AND (o < abs_floor) AND (median - o > gap)

    abs_floor is a true AND guard, NOT a floor on the threshold via max(),
    so a healthy trial (o ≥ 0.50) is never dropped no matter how low the
    relative threshold goes when σ is large. See §"Pitfall" in
    `intent_coverage/METHOD_AND_PILOT.md`.
    """
    overalls = [t["overall_score"] for t in trials if t["overall_score"] is not None]
    if len(overalls) < 2:
        return list(trials), []
    median = statistics.median(overalls)
    sd     = statistics.pstdev(overalls)
    relative_threshold = median - SIGMA_K * sd

    kept, dropped = [], []
    for t in trials:
        o = t["overall_score"]
        if o is None:
            kept.append(t)                          # can't judge → keep, flag elsewhere
            continue
        is_outlier = (
            o < relative_threshold
            and o < ABS_FLOOR
            and (median - o) > MAGNITUDE_GAP
        )
        (dropped if is_outlier else kept).append(t)
    if not kept:                                    # safety: never drop everything
        best = max(trials, key=lambda t: (t["overall_score"] or 0))
        kept, dropped = [best], [t for t in trials if t is not best]
    return kept, dropped


# ── Block 1 — effort-aware metrics ───────────────────────────────────────────

def success_at_k(trials: list[dict], k: int) -> float | None:
    """`mean(judge_score ≥ SUCCESS_THRESHOLD over trials with effort_cost ≤ k)`.

    Returns None when no trial has a numeric effort_cost ≤ k.
    """
    eligible = [
        t for t in trials
        if t.get("effort_cost") is not None
        and t.get("judge_score") is not None
        and t["effort_cost"] <= k
    ]
    if not eligible:
        return None
    return sum(1 for t in eligible if t["judge_score"] >= SUCCESS_THRESHOLD) / len(eligible)


def effort_auc(trials: list[dict], max_k: int = EFFORT_AUC_MAX_K) -> float | None:
    """Area under success-vs-effort curve, normalised to [0, 1]."""
    curve = []
    for k in range(max_k + 1):
        s = success_at_k(trials, k)
        curve.append(0.0 if s is None else s)
    if not any(s > 0 for s in curve):
        # If we have no effort_cost data at all, AUC is meaningless.
        if all(t.get("effort_cost") is None for t in trials):
            return None
    return sum(curve) / (max_k + 1)


def min_effort_to_success_median(trials: list[dict]) -> float | None:
    """P50 of `min(effort_cost)` over successful trials. Reports None if no
    trial succeeded or no trial has effort_cost recorded."""
    successful = [
        t["effort_cost"] for t in trials
        if t.get("effort_cost") is not None
        and t.get("judge_score") is not None
        and t["judge_score"] >= SUCCESS_THRESHOLD
    ]
    if not successful:
        return None
    return statistics.median(successful)


# ── per-task aggregation ─────────────────────────────────────────────────────

def aggregate_per_task(trials_by_task: dict[str, list[dict]]) -> list[dict]:
    rows: list[dict] = []
    for task, trials in sorted(trials_by_task.items()):
        kept, dropped = clean_trials(trials)
        judge_scores = [t["judge_score"] for t in kept if t.get("judge_score") is not None]

        mean_judge = statistics.fmean(judge_scores) if judge_scores else None
        var_judge  = statistics.pvariance(judge_scores) if len(judge_scores) >= 2 else 0.0

        # Block 1' — sim-verbosity diagnostic, averaged over kept trials.
        epmi = [t.get("effort_per_matched_intent") for t in kept
                if t.get("effort_per_matched_intent") is not None]
        epmi_mean = statistics.fmean(epmi) if epmi else None

        # Block 3 — benchmark fidelity diagnostics (per-task).
        empty_patch_rate = sum(1 for t in trials if t["empty_patch"]) / len(trials) if trials else 0.0
        any_warnings = sum(
            1 for t in trials
            if (t.get("judge_warnings") or 0) > 0 or (t.get("coverage_warnings") or 0) > 0
        )
        schema_warning_rate = any_warnings / len(trials) if trials else 0.0

        rows.append({
            "task": task,
            "n_total": len(trials),
            "n_surviving": len(kept),
            "n_dropped": len(dropped),
            "dropped_trial_ids": [t["trial_id"] for t in dropped],
            # step 2 — cleaned correctness
            "mean_judge": round(mean_judge, 4) if mean_judge is not None else None,
            "var_judge": round(var_judge, 4),
            "judge_scores_kept": [t.get("judge_score") for t in kept],
            "judge_scores_all": [t.get("judge_score") for t in trials],
            "overall_scores_all": [t.get("overall_score") for t in trials],
            # Block 1 — effort-aware capability
            "success_at_0":  success_at_k(kept, 0),
            "success_at_3":  success_at_k(kept, 3),
            "success_at_10": success_at_k(kept, 10),
            "effort_auc":    effort_auc(kept),
            # Block 1' — secondary
            "min_effort_to_success_p50": min_effort_to_success_median(kept),
            "effort_per_matched_intent_mean": (round(epmi_mean, 4) if epmi_mean is not None else None),
            # behavior panel — surviving subset
            "intervention_count_mean": _safe_mean(t.get("intervention_count") for t in kept),
            "hard_cap_abandon_rate": _rate(t.get("hard_cap_abandon") for t in kept),
            "specificity_present": any(t.get("specificity_present") for t in kept),
            # Block 3 — benchmark fidelity
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

def cross_task_rollup(rows: list[dict]) -> dict:
    """Block 1 + Block 3 numbers averaged over tasks. The headline reads here."""
    def m(field: str) -> float | None:
        vs = [r[field] for r in rows if r.get(field) is not None]
        return round(statistics.fmean(vs), 4) if vs else None
    return {
        "n_tasks": len(rows),
        "mean_judge_over_tasks": m("mean_judge"),
        "success_at_0_mean": m("success_at_0"),
        "success_at_3_mean": m("success_at_3"),
        "success_at_10_mean": m("success_at_10"),
        "effort_auc_mean": m("effort_auc"),
        "intervention_count_mean": m("intervention_count_mean"),
        "hard_cap_abandon_rate_mean": m("hard_cap_abandon_rate"),
        "empty_patch_rate_mean": m("empty_patch_rate"),
        "schema_warning_rate_mean": m("schema_warning_rate"),
        "n_specificity_populated_tasks": sum(1 for r in rows if r.get("specificity_present")),
    }


# ── Markdown report ──────────────────────────────────────────────────────────

def render_markdown(per_task: list[dict], rollup: dict, args) -> str:
    roots_label = ", ".join(p.name for p in args.trials_root) if isinstance(args.trials_root, list) else str(args.trials_root)
    lines = [
        f"# Eval run — {args.model_tag or roots_label}",
        "",
        f"- trials roots: `{roots_label}`",
        f"- tasks root: `{args.tasks_root}`",
        f"- n tasks: {rollup['n_tasks']}",
        f"- success threshold: judge_score ≥ {SUCCESS_THRESHOLD}",
        f"- filter: σ_k={SIGMA_K}, abs_floor={ABS_FLOOR}, gap={MAGNITUDE_GAP}",
        "",
        "## Headline (cross-task means)",
        "",
        "| metric | value |",
        "|---|---:|",
    ]
    for k in (
        "mean_judge_over_tasks",
        "success_at_0_mean", "success_at_3_mean", "success_at_10_mean",
        "effort_auc_mean",
        "intervention_count_mean", "hard_cap_abandon_rate_mean",
        "empty_patch_rate_mean", "schema_warning_rate_mean",
    ):
        v = rollup.get(k)
        lines.append(f"| `{k}` | {v if v is not None else '—'} |")

    lines.extend([
        "",
        "## Per-task (after step-2 filter)",
        "",
        "| task | n_total | n_surv | mean_judge | var_judge | s@0 | s@3 | s@10 | AUC | intv μ | empty% | warn% |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for r in per_task:
        lines.append("| " + " | ".join([
            f"`{r['task']}`",
            f"{r['n_total']}",
            f"{r['n_surviving']}",
            _fmt(r['mean_judge']),
            _fmt(r['var_judge']),
            _fmt(r['success_at_0']),
            _fmt(r['success_at_3']),
            _fmt(r['success_at_10']),
            _fmt(r['effort_auc']),
            _fmt(r['intervention_count_mean']),
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
                    default=REPO_ROOT / "harbor_tasks",
                    help="Directory holding canonical task dirs (default: harbor_tasks/)")
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
    ap.add_argument("--behavior-out-name", action="append", default=None,
                    help="default: user_behavior_verdict.json")

    # Skip / force / per-step concurrency.
    ap.add_argument("--skip-correctness", action="store_true")
    ap.add_argument("--skip-intent-coverage", action="store_true")
    ap.add_argument("--skip-user-behavior", action="store_true")
    ap.add_argument("--only-aggregate", action="store_true",
                    help="Skip all three steps and just aggregate existing verdicts")
    ap.add_argument("--force-correctness", action="store_true")
    ap.add_argument("--force-intent-coverage", action="store_true")
    ap.add_argument("--force-user-behavior", action="store_true")
    ap.add_argument("--correctness-workers", type=int, default=20)
    ap.add_argument("--intent-coverage-workers", type=int, default=5)
    ap.add_argument("--user-behavior-workers", type=int, default=16)
    ap.add_argument("--intent-coverage-model", default=None,
                    help="LLM model for intent_coverage (default: package default)")
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
        behavior_names=args.behavior_out_name,
    )
    if not jobs:
        logger.error("no trial/task pairs found under %s ↔ %s",
                     args.trials_root, args.tasks_root)
        return 2
    logger.info("paired %d trial dirs across %d unique tasks (cohorts: %s)",
                len(jobs), len({j["task"] for j in jobs}),
                sorted({j["cohort"] for j in jobs}))

    if args.only_aggregate:
        args.skip_correctness = args.skip_intent_coverage = args.skip_user_behavior = True

    # Plans are step-CLI-format; per-cohort verdict filenames go through each
    # job's `*_out_name` field already so a single plan with mixed cohorts
    # works (each step CLI writes to the per-job out_name).
    # If you need to actually RUN a step across mixed cohorts, the step CLI
    # uses ONE out_name across the whole plan — write one plan per distinct
    # out_name in that case.
    distinct_judge = sorted({j["judge_out_name"] for j in jobs})
    distinct_cov   = sorted({j["coverage_out_name"] for j in jobs})
    distinct_beh   = sorted({j["behavior_out_name"] for j in jobs})

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
    plan_beh_paths = [
        write_plan([j for j in jobs if j["behavior_out_name"] == n],
                   _plan_path("user_behavior", n, len(distinct_beh) > 1), n)
        for n in distinct_beh
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

    if not args.skip_user_behavior:
        for p in plan_beh_paths:
            rc = run_step_user_behavior(
                p, out / f"summary_{p.stem}.json",
                workers=args.user_behavior_workers, force=args.force_user_behavior,
                extra=[],
            )
            if rc != 0:
                logger.error("step 3 (user_behavior) failed rc=%d on %s — continuing", rc, p.name)

    # Aggregate — read every per-trial verdict and group by task.
    logger.info("aggregating per-task metrics from %d trials", len(jobs))
    flat = [join_trial_artefacts(j) for j in jobs]
    by_task: dict[str, list[dict]] = defaultdict(list)
    for t in flat:
        by_task[t["task"]].append(t)

    per_task = aggregate_per_task(by_task)
    rollup   = cross_task_rollup(per_task)

    report = {
        "model_tag": args.model_tag,
        "trials_roots": [str(p.resolve()) for p in args.trials_root],
        "tasks_root": str(args.tasks_root.resolve()),
        "cohorts": sorted({j["cohort"] for j in jobs}),
        "n_trials": len(flat),
        "filter": {"sigma_k": SIGMA_K, "abs_floor": ABS_FLOOR,
                   "magnitude_gap": MAGNITUDE_GAP},
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
