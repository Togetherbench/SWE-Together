"""Judge execution failures must not enter correctness averages."""

import asyncio
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from eval.correctness import run_batch
from eval.run_eval import (
    aggregate_per_task,
    cross_task_rollup,
    join_trial_artefacts,
    main,
)


@pytest.mark.parametrize(
    "verdict",
    [
        {"error": "Required database fixture is unavailable"},
        {
            "error": "Required database fixture is unavailable",
            "goal_results": [{"id": "core", "met": True}],
        },
        {
            "error": "Required database fixture is unavailable",
            "judge_score": 1.0,
            "verdict": "equivalent",
            "goal_results": [{"id": "core", "met": True}],
        },
        {"error": "verdict_read_failed", "judge_score": 0.0},
    ],
)
def test_judge_error_stays_ungraded_through_aggregation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    verdict: dict,
) -> None:
    task = tmp_path / "task"
    task.mkdir()
    (task / "instruction.md").write_text("Implement the requested behavior.")
    (task / "canonical_goals.json").write_text(
        json.dumps(
            {
                "task_name": "task",
                "completeness_goals": [
                    {
                        "id": "core",
                        "goal": "Core behavior",
                        "tier": "core",
                        "weight": 1.0,
                    },
                ],
            }
        )
    )
    trial = tmp_path / "trial"
    (trial / "agent").mkdir(parents=True)
    source = Path(__file__).resolve().parents[1]
    (trial / "agent/final.patch").write_bytes(
        (
            source / "tasks/comfyui-lumina2-lora-prefix/corrected_reference.patch"
        ).read_bytes()
    )

    async def judge(**kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(
            verdict=verdict,
            sandbox_id="offline-judge-error-test",
            exit_code=0,
            judge_model="",
            judge_backend="",
        )

    monkeypatch.setattr(run_batch, "run_judge_in_e2b", judge)
    result = asyncio.run(
        run_batch._phase2_one(
            {"trial_dir": str(trial), "task_dir": str(task)},
            "",
            asyncio.Semaphore(1),
            None,
            False,
        )
    )
    saved = json.loads((trial / "judge_verdict.json").read_text())
    assert result["status"] == "verdict_error"
    assert result["judge_score"] is None
    assert saved["error"] == verdict["error"]
    assert "judge_score" not in saved
    assert saved.get("judge_reported_score") == verdict.get("judge_score")
    assert saved.get("goal_results") == verdict.get("goal_results")

    joined = join_trial_artefacts({"task": "task", "trial_dir": str(trial)})
    assert joined["judge_score"] is None
    assert joined["judge_error"] == verdict["error"]
    (aggregate,) = aggregate_per_task({"task": [joined]})
    assert aggregate["n_total"] == 1
    assert aggregate["n_scored"] == 0
    assert aggregate["mean_judge"] is None
    assert aggregate["pass_at_1"] is None
    rollup = cross_task_rollup([aggregate], denom_tasks=1)
    assert rollup["correctness_complete"] is False
    assert rollup["mean_judge_over_tasks"] is None
    assert rollup["pass_at_1_mean"] is None

    # Old error verdicts remain immutable and must also be excluded when read.
    original = json.dumps(verdict)
    (trial / "judge_verdict.json").write_text(original)
    assert (
        join_trial_artefacts({"task": "task", "trial_dir": str(trial)})["judge_score"]
        is None
    )
    assert (trial / "judge_verdict.json").read_text() == original


@pytest.mark.parametrize("include_error", [False, True])
def test_aggregate_preserves_real_zero_and_reports_missing_score(
    tmp_path: Path,
    include_error: bool,
) -> None:
    verdicts = [{"judge_score": 0.0}, {"judge_score": 1.0}]
    if include_error:
        verdicts.append({"error": "Required database fixture is unavailable"})
    joined = []
    for index, verdict in enumerate(verdicts):
        trial = tmp_path / str(index)
        trial.mkdir()
        (trial / "judge_verdict.json").write_text(json.dumps(verdict))
        joined.append(join_trial_artefacts({"task": "task", "trial_dir": str(trial)}))
    (aggregate,) = aggregate_per_task({"task": joined})
    assert aggregate["n_total"] == len(verdicts)
    assert aggregate["n_scored"] == 2
    assert aggregate["judge_scores_all"] == (
        [0.0, 1.0, None] if include_error else [0.0, 1.0]
    )
    assert aggregate["mean_judge"] == 0.5
    assert aggregate["pass_at_1"] == 0.5
    rollup = cross_task_rollup([aggregate], denom_tasks=1)
    assert rollup["correctness_complete"] is not include_error
    assert rollup["mean_judge_over_tasks"] == (None if include_error else 0.5)
    assert rollup["pass_at_1_mean"] == (None if include_error else 0.5)
    incomplete = cross_task_rollup([aggregate], denom_tasks=2)
    assert incomplete["correctness_complete"] is False
    assert incomplete["pass_at_1_mean"] is None


def test_aggregate_only_cli_does_not_resolve_model_credentials(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    tasks = tmp_path / "tasks"
    (tasks / "task").mkdir(parents=True)
    (tasks / "task/task.toml").write_text('version = "1.0"\n')
    trials = tmp_path / "trials"
    trial = trials / "task__replica"
    trial.mkdir(parents=True)
    (trial / "judge_verdict.json").write_text(
        json.dumps({"error": "verdict_read_failed"})
    )
    out = tmp_path / "report"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "eval.run_eval",
            "--only-aggregate",
            "--trials-root",
            str(trials),
            "--tasks-root",
            str(tasks),
            "--output-dir",
            str(out),
            "--tagger-backend",
            "offline-must-not-resolve",
            "--model-tag",
            "offline-check",
        ],
    )
    assert main() == 0
    report = json.loads((out / "eval_report.json").read_text())
    assert report["cross_task"]["correctness_complete"] is False
    assert report["cross_task"]["pass_at_1_mean"] is None
    assert report["per_task"][0]["n_scored"] == 0
    assert "n_scored" in (out / "eval_report.md").read_text()
