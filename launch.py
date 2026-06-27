#!/usr/bin/env python3
"""Launch a SWE-Together benchmark run from a plan JSON.

Two stages:

  run    - for each (model, replicate) cohort in the plan, run ``src/run_eval.py``
           to produce trials under ``<trials_root>/<model_tag>_r<k>/``.
  judge  - for each model, run ``eval.run_eval`` across its replicate trial dirs,
           writing per-trial verdicts in place + an aggregate report under
           ``<results_dir>/<model_tag>/``.

Plan format (see ``canonical_full109.json``)::

    {
      "name": "full109",
      "trials_root": "trials/canonical_full109",
      "tasks_root": "tasks",
      "models": {
        "<tag>": {"model": "...", "agent_type": "opencode",
                  "reasoning_effort": "high", "agent_timeout": 4800, "workers": 20}
      },
      "replicates": [1, 2],
      "tasks": ["task-a", "task-b", ...]   # optional; omit to run all of tasks_root
    }

Model strings are litellm/harbor-format and need the matching key in ``.env``.

Dry-run by default - prints the commands it would run. Pass ``--execute`` to launch.
Run it with the project venv so harbor is importable: ``.venv/bin/python``.

Examples::

    # Preview everything the plan would do
    .venv/bin/python launch.py canonical_full109.json

    # Produce trials for one cohort
    .venv/bin/python launch.py canonical_full109.json \
        --stage run --models opencode_opus --execute

    # Score every cohort once trials exist
    .venv/bin/python launch.py canonical_full109.json \
        --stage judge --execute
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


def _print_cmd(cmd: list[str]) -> None:
    """Print a command, abbreviating a long --tasks list so output stays readable."""
    parts = []
    i = 0
    while i < len(cmd):
        parts.append(str(cmd[i]))
        if cmd[i] == "--tasks" and i + 1 < len(cmd):
            n = len(str(cmd[i + 1]).split(","))
            parts.append(f"<{n} tasks>")
            i += 2
            continue
        i += 1
    print("  $ " + " ".join(parts))


def _run(cmd: list[str], execute: bool) -> int:
    _print_cmd(cmd)
    if not execute:
        return 0
    return subprocess.run(cmd, cwd=REPO_ROOT).returncode


def stage_run(plan: dict, models: dict, env_type: str | None, execute: bool) -> int:
    trials_root = REPO_ROOT / plan["trials_root"]
    tasks = plan.get("tasks") or []
    rc = 0
    for tag, cfg in models.items():
        for rep in plan.get("replicates", [1]):
            out = trials_root / f"{tag}_r{rep}"
            cmd = [
                sys.executable, str(REPO_ROOT / "src" / "run_eval.py"),
                "--model", cfg["model"],
                "--tag", f"{tag}_r{rep}",
                "--agent-type", cfg.get("agent_type", "opencode"),
                "--workers", str(cfg.get("workers", 20)),
                "--trials-dir", str(out),
                "--skip-existing",
            ]
            if env_type:
                cmd += ["--env-type", env_type]
            if cfg.get("agent_timeout"):
                cmd += ["--agent-timeout", str(cfg["agent_timeout"])]
            if cfg.get("reasoning_effort"):
                cmd += ["--reasoning-effort", str(cfg["reasoning_effort"])]
            if tasks:
                cmd += ["--tasks", ",".join(tasks)]
            print(f"\n[run] {tag} replicate {rep} -> {out.relative_to(REPO_ROOT)}")
            rc = _run(cmd, execute) or rc
    return rc


def stage_judge(plan: dict, models: dict, results_dir: str, execute: bool) -> int:
    trials_root = REPO_ROOT / plan["trials_root"]
    tasks_root = REPO_ROOT / plan.get("tasks_root", "tasks")
    rc = 0
    for tag in models:
        cmd = [sys.executable, "-m", "eval.run_eval"]
        for rep in plan.get("replicates", [1]):
            cmd += ["--trials-root", str(trials_root / f"{tag}_r{rep}")]
        out = REPO_ROOT / results_dir / tag
        cmd += [
            "--tasks-root", str(tasks_root),
            "--output-dir", str(out),
            "--model-tag", tag,
        ]
        print(f"\n[judge] {tag} -> {out.relative_to(REPO_ROOT)}")
        rc = _run(cmd, execute) or rc
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("plan", type=Path, help="Plan JSON, e.g. canonical_full109.json")
    ap.add_argument("--stage", choices=["run", "judge", "all"], default="all")
    ap.add_argument("--models", default=None,
                    help="Comma-separated subset of model tags (default: every model in the plan)")
    ap.add_argument("--env-type", default="e2b",
                    help="Sandbox for the run stage: e2b or docker (default: e2b)")
    ap.add_argument("--results-dir", default="results",
                    help="Where judge aggregates go (default: results/)")
    ap.add_argument("--execute", action="store_true",
                    help="Actually launch. Without it, commands are only printed (dry-run).")
    args = ap.parse_args()

    plan = json.loads(args.plan.read_text())
    models = plan["models"]
    if args.models:
        want = set(args.models.split(","))
        unknown = want - set(models)
        if unknown:
            sys.exit(f"unknown model tags: {sorted(unknown)} (have: {sorted(models)})")
        models = {k: v for k, v in models.items() if k in want}
    if not models:
        sys.exit("no models selected")

    if not args.execute:
        print("DRY RUN - printing commands only. Pass --execute to launch.\n")

    rc = 0
    if args.stage in ("run", "all"):
        print("== STAGE: run (produce trials) ==")
        rc = stage_run(plan, models, args.env_type, args.execute) or rc
    if args.stage in ("judge", "all"):
        print("\n== STAGE: judge (score trials) ==")
        rc = stage_judge(plan, models, args.results_dir, args.execute) or rc
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
