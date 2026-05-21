"""Single-trial agentic judge CLI.

Usage:
    .venv/bin/python -m eval.correctness.judge_one \\
        --trial-dir ~/Downloads/release_v0.4.4.3/extracted/trials_deepseek_v4_pro_swerb/cli-task-2c3e30__oS6jWHt \\
        --task-dir  harbor_tasks/cli-task-2c3e30

Requires .env with E2B_API_KEY, GHCR_USER, GHCR_TOKEN, and the host process
env to have CLAUDE_CODE_OAUTH_TOKEN exported (extract via keychain).
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

from eval.correctness.sandbox import JudgeInputs, run_judge_in_e2b


REPO_ROOT = Path(__file__).resolve().parents[2]
SYSTEM_PROMPT_PATH = Path(__file__).parent / "prompts" / "judge_system.md"


_WEIGHT_TOL = 0.01
_ALLOWED_TIERS = {"core", "secondary", "polish"}
_REQUIRED_GOAL_FIELDS = {"goal", "tier", "weight", "met", "evidence"}


def _validate_schema(verdict: dict) -> list[str]:
    """Hard schema invariants only. Soft heuristics (goal count, per-tier weight
    ranges) live in the prompt as suggestions and are NOT enforced here.

    Hard rules:
      - completeness_goals is a non-empty list
      - each goal has all required fields, well-typed
      - tier ∈ {core, secondary, polish}
      - weight is numeric
      - at least one 'core' goal (anchor for the primary task)
      - weights sum to 1.0 (±0.01)
      - judge_score == sum(weight × met) (±0.01)
      - verdict bucket consistent with judge_score:
          ≥0.85 → equivalent | 0.30–0.85 → partial | <0.30 → incorrect
        (override: 'gameable' verdict allowed at any score, forces score=0.0)
    """
    warnings: list[str] = []

    if verdict.get("verdict") == "gameable":
        if verdict.get("judge_score", 0.0) != 0.0:
            warnings.append(f"verdict='gameable' but judge_score={verdict['judge_score']} (expected 0.0)")
        return warnings

    goals = verdict.get("completeness_goals") or []
    if not goals:
        warnings.append("no completeness_goals listed")
        return warnings

    total_weight = 0.0
    has_core = False
    for i, g in enumerate(goals):
        if not isinstance(g, dict):
            warnings.append(f"goal[{i}] is not a dict")
            continue
        missing = _REQUIRED_GOAL_FIELDS - g.keys()
        if missing:
            warnings.append(f"goal[{i}] missing required fields: {sorted(missing)}")
        w = g.get("weight")
        tier = g.get("tier")
        met = g.get("met")
        if not isinstance(w, (int, float)):
            warnings.append(f"goal[{i}] weight={w!r} is not numeric")
            continue
        if tier not in _ALLOWED_TIERS:
            warnings.append(f"goal[{i}] tier={tier!r} not in {sorted(_ALLOWED_TIERS)}")
        if not isinstance(met, bool):
            warnings.append(f"goal[{i}] met={met!r} is not a bool")
        if tier == "core":
            has_core = True
        total_weight += float(w)

    if not has_core:
        warnings.append("no 'core' tier goal — at least one required")

    if abs(total_weight - 1.0) > _WEIGHT_TOL:
        warnings.append(f"weights sum to {total_weight:.3f}, expected 1.0 (±{_WEIGHT_TOL})")

    expected = sum(
        float(g.get("weight", 0)) * (1 if g.get("met") else 0)
        for g in goals if isinstance(g, dict)
    )
    actual = verdict.get("judge_score", 0.0)
    if abs(round(expected, 2) - round(float(actual), 2)) > _WEIGHT_TOL:
        warnings.append(f"judge_score={actual} != sum(weight×met)={round(expected, 2)}")

    score = float(verdict.get("judge_score", 0.0))
    bucket = verdict.get("verdict")
    if score >= 0.85 and bucket != "equivalent":
        warnings.append(f"score={score} ≥0.85 but verdict={bucket!r} (expected 'equivalent')")
    elif 0.30 <= score < 0.85 and bucket != "partial":
        warnings.append(f"score={score} in [0.30,0.85) but verdict={bucket!r} (expected 'partial')")
    elif score < 0.30 and bucket != "incorrect":
        warnings.append(f"score={score} <0.30 but verdict={bucket!r} (expected 'incorrect')")

    return warnings


def load_dotenv() -> None:
    """Load .env into os.environ.setdefault — process env wins."""
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


def load_inputs(trial_dir: Path, task_dir: Path) -> JudgeInputs:
    readme_p = task_dir / "README.md"
    if not readme_p.exists():
        raise FileNotFoundError(
            f"task {task_dir.name} has no README.md — skipping per policy"
        )

    usp_p = task_dir / "user_simulation_prompt.md"
    user_sim = usp_p.read_text() if usp_p.exists() else ""

    agent_patch_p = trial_dir / "agent" / "final.patch"
    if not agent_patch_p.exists():
        raise FileNotFoundError(f"trial {trial_dir.name} has no agent/final.patch")
    agent_patch = agent_patch_p.read_text()
    # Empty / header-only patches (e.g. just the `=== repo/ ===` marker) are
    # not informative — the judge can't evaluate work that doesn't exist in
    # the patch. ~72% of v0.4.4.3 DS Pro trials hit this; their rewards came
    # from per-turn replay against earlier turn snapshots, not the final state.
    # Skip with an explicit reason so the batch summary surfaces it.
    if len(agent_patch.strip()) < 100:
        raise FileNotFoundError(
            f"trial {trial_dir.name} has empty agent/final.patch "
            f"({len(agent_patch)} chars) — likely a replay-scored trial; skipping"
        )

    tests_dir_p = task_dir / "tests"
    test_sh_p = tests_dir_p / "test.sh"
    test_sh = test_sh_p.read_text() if test_sh_p.exists() else ""

    # Read every file in tests/ as bytes so the judge can run the canonical
    # test.sh end-to-end (install_config.json + log_parsers.py + swe_constants.py
    # + test.sh + test_manifest.yaml). We hand sandbox.py bytes so binary files
    # would survive too, even though all 5 here are text in practice.
    tests_files: dict[str, bytes] = {}
    if tests_dir_p.is_dir():
        for p in tests_dir_p.iterdir():
            if p.is_file():
                tests_files[p.name] = p.read_bytes()

    ref_p = task_dir / "reference_patch.json"
    if ref_p.exists():
        ref = json.loads(ref_p.read_text())
        oracle_patch = ref.get("patch", "") or ""
    else:
        oracle_patch = ""

    system_prompt = SYSTEM_PROMPT_PATH.read_text()

    return JudgeInputs(
        readme=readme_p.read_text(),
        user_sim_prompt=user_sim,
        oracle_patch=oracle_patch,
        agent_patch=agent_patch,
        test_sh=test_sh,
        system_prompt=system_prompt,
        tests_files=tests_files,
    )


async def amain() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trial-dir", required=True, type=Path)
    ap.add_argument("--task-dir", required=True, type=Path)
    ap.add_argument("--out", default="judge_verdict.json",
                    help="filename inside --trial-dir (default: judge_verdict.json)")
    ap.add_argument("--timeout-sec", type=int, default=600)
    ap.add_argument("--max-turns", type=int, default=50)
    ap.add_argument("--force", action="store_true",
                    help="overwrite existing verdict file")
    ap.add_argument("--save-stdout", action="store_true",
                    help="also save judge stdout to <trial>/judge_stdout.txt for debug")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    load_dotenv()
    for k in ("E2B_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"):
        if not os.environ.get(k):
            print(f"ERROR: {k} not set (check .env or shell export)", file=sys.stderr)
            return 2

    if not args.trial_dir.is_dir():
        print(f"ERROR: trial dir not found: {args.trial_dir}", file=sys.stderr)
        return 2
    if not args.task_dir.is_dir():
        print(f"ERROR: task dir not found: {args.task_dir}", file=sys.stderr)
        return 2

    out_path = args.trial_dir / args.out
    if out_path.exists() and not args.force:
        print(f"already exists (use --force): {out_path}", file=sys.stderr)
        return 0

    try:
        inputs = load_inputs(args.trial_dir, args.task_dir)
    except FileNotFoundError as e:
        print(f"SKIP: {e}", file=sys.stderr)
        return 0

    task_name = args.task_dir.name
    trial_id = args.trial_dir.name
    print(f"judging {trial_id} on {task_name}...")

    t0 = time.time()
    result = await run_judge_in_e2b(
        task_name=task_name,
        trial_id=trial_id,
        inputs=inputs,
        oauth_token=os.environ["CLAUDE_CODE_OAUTH_TOKEN"],
        timeout_sec=args.timeout_sec,
        max_turns=args.max_turns,
    )
    elapsed = time.time() - t0

    # Enrich the verdict with metadata the judge agent doesn't know about
    verdict = dict(result.verdict)
    verdict.setdefault("task", task_name)
    verdict.setdefault("trial_id", trial_id)

    # Read test.sh's reward for cross-reference
    reward_p = args.trial_dir / "verifier" / "reward.txt"
    if reward_p.exists():
        try:
            verdict["test_reward_raw"] = float(reward_p.read_text().strip())
        except ValueError:
            pass

    judge_score = verdict.get("judge_score")
    test_reward = verdict.get("test_reward_raw")
    if judge_score is not None and test_reward is not None:
        delta = judge_score - test_reward
        if abs(delta) < 1e-6:
            verdict["direction"] = "unchanged"
        elif delta > 0:
            verdict["direction"] = "upgrade"
        else:
            verdict["direction"] = "downgrade"
        verdict["score_delta"] = round(delta, 4)

    verdict["judge_elapsed_sec"] = round(elapsed, 1)
    verdict["sandbox_id"] = result.sandbox_id
    verdict["judge_exit_code"] = result.exit_code

    # Schema validation — log warnings on weighted-tier violations
    schema_warnings = _validate_schema(verdict)
    if schema_warnings:
        verdict["schema_warnings"] = schema_warnings
        for w in schema_warnings:
            print(f"  WARN: {w}", file=sys.stderr)

    out_path.write_text(json.dumps(verdict, indent=2))
    print(f"wrote {out_path}")

    if args.save_stdout:
        (args.trial_dir / "judge_stdout.txt").write_text(result.stdout)
        (args.trial_dir / "judge_stderr.txt").write_text(result.stderr)

    print(
        f"  task={task_name} trial={trial_id}\n"
        f"  test_reward={test_reward}  judge_score={judge_score}  "
        f"verdict={verdict.get('verdict')}  direction={verdict.get('direction')}\n"
        f"  elapsed={elapsed:.1f}s  sandbox={result.sandbox_id}"
    )
    return 0 if "error" not in verdict else 1


def main() -> int:
    return asyncio.run(amain())


if __name__ == "__main__":
    raise SystemExit(main())
