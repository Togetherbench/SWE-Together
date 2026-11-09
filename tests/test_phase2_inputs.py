"""Check the scoring boundary without running a judge or changing task assets."""

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from eval.correctness import run_batch


@pytest.mark.parametrize(
    "task_name",
    [
        "cli-task-408b8c",
        "rudel-task-491983",
        "gemini-voyager-task-4bddaf",
    ],
)
@pytest.mark.parametrize("judge_error", [False, True])
def test_phase2_stages_contract_without_authoring_notes(
    tmp_path, monkeypatch, task_name, judge_error
):
    source = Path(__file__).resolve().parents[1] / "tasks" / task_name
    task = tmp_path / task_name
    task.mkdir()
    instruction = (source / "instruction.md").read_text()
    (task / "instruction.md").write_text(instruction)
    (task / "README.md").write_text("AUTHOR_OUTCOME_SENTINEL: all patches passed")
    (task / "user_simulation_prompt.md").write_text("Existing source-turn context")
    rubric = json.loads((source / "canonical_goals.json").read_text())
    rubric["decomposition_notes"] = "AUTHOR_OUTCOME_SENTINEL: expected ranking"
    for goal in rubric["completeness_goals"]:
        goal["rationale"] = "AUTHOR_OUTCOME_SENTINEL: author explanation"
    rubric_text = json.dumps(rubric)
    (task / "canonical_goals.json").write_text(rubric_text)
    trial = tmp_path / "trial"
    (trial / "agent").mkdir(parents=True)
    (trial / "agent/final.patch").write_bytes(
        (
            source.parent / "comfyui-lumina2-lora-prefix/corrected_reference.patch"
        ).read_bytes()
    )
    staged = []

    async def capture(**kwargs):
        staged.append(kwargs["inputs"])
        verdict = (
            {"error": "Required local database fixture is unavailable"}
            if judge_error
            else {
                "goal_results": [
                    {"id": g["id"], "met": True} for g in rubric["completeness_goals"]
                ]
            }
        )
        return SimpleNamespace(
            verdict=verdict,
            sandbox_id="offline-staging-test",
            exit_code=0,
            judge_model="",
            judge_backend="",
        )

    monkeypatch.setattr(run_batch, "run_judge_in_e2b", capture)
    result = asyncio.run(
        run_batch._phase2_one(
            {"trial_dir": str(trial), "task_dir": str(task)},
            "",
            asyncio.Semaphore(1),
            None,
            False,
        )
    )
    assert result["status"] == ("verdict_error" if judge_error else "ok")
    (inputs,) = staged
    assert inputs.readme == instruction
    projected = json.loads(inputs.canonical_goals_json)
    assert projected["completeness_goals"] == [
        {key: goal[key] for key in ("id", "goal", "tier", "weight")}
        for goal in rubric["completeness_goals"]
    ]
    assert "AUTHOR_OUTCOME_SENTINEL" not in inputs.readme + inputs.canonical_goals_json
    assert inputs.user_sim_prompt == "Existing source-turn context"
    assert (task / "canonical_goals.json").read_text() == rubric_text
    saved = json.loads((trial / "judge_verdict.json").read_text())
    assert saved["judge_input_protocol"] == "score_only_goals_v2"
    if judge_error:
        assert "judge_score" not in saved
        assert result["judge_score"] is None
    else:
        assert result["judge_score"] == 1.0


def test_phase2_refuses_unreadable_verifier_input(tmp_path, monkeypatch):
    task = tmp_path / "task"
    (task / "tests").mkdir(parents=True)
    (task / "instruction.md").write_text("Implement the requested behavior.")
    (task / "canonical_goals.json").write_text(
        json.dumps(
            {
                "task_name": "task",
                "completeness_goals": [
                    {
                        "id": "goal_0",
                        "goal": "Required behavior",
                        "tier": "core",
                        "weight": 1.0,
                    }
                ],
            }
        )
    )
    verifier = task / "tests/verify_behavior.py"
    verifier.write_text("raise AssertionError('The behavior is missing')\n")
    trial = tmp_path / "trial"
    (trial / "agent").mkdir(parents=True)
    source = Path(__file__).resolve().parents[1]
    (trial / "agent/final.patch").write_bytes(
        (
            source / "tasks/comfyui-lumina2-lora-prefix/corrected_reference.patch"
        ).read_bytes()
    )
    read_bytes = Path.read_bytes

    def unreadable(path):
        if path == verifier:
            raise PermissionError("Verifier input is unreadable")
        return read_bytes(path)

    calls = []

    async def judge(**kwargs):
        calls.append(kwargs)
        return SimpleNamespace(
            verdict={"goal_results": [{"id": "goal_0", "met": True}]},
            sandbox_id="offline-staging-test",
            exit_code=0,
            judge_model="",
            judge_backend="",
        )

    monkeypatch.setattr(Path, "read_bytes", unreadable)
    monkeypatch.setattr(run_batch, "run_judge_in_e2b", judge)
    with pytest.raises(PermissionError, match="Verifier input is unreadable"):
        asyncio.run(
            run_batch._phase2_one(
                {"trial_dir": str(trial), "task_dir": str(task)},
                "",
                asyncio.Semaphore(1),
                None,
                False,
            )
        )
    assert calls == []
    assert not (trial / "judge_verdict.json").exists()


@pytest.mark.parametrize("protocol", [None, "author_notes_v1", "score_only_goals_v2"])
def test_phase2_cached_verdict_requires_matching_input_protocol(
    tmp_path, monkeypatch, protocol
):
    trial = tmp_path / "trial"
    trial.mkdir()
    verdict = {"judge_score": 1.0}
    if protocol is not None:
        verdict["judge_input_protocol"] = protocol
    saved = trial / "judge_verdict.json"
    original = json.dumps(verdict)
    saved.write_text(original)
    calls = []

    async def judge(**kwargs):
        calls.append(kwargs)
        raise AssertionError("Cached input validation must precede any judge call")

    monkeypatch.setattr(run_batch, "run_judge_in_e2b", judge)
    call = run_batch._phase2_one(
        {"trial_dir": str(trial), "task_dir": str(tmp_path / "unused-task")},
        "",
        asyncio.Semaphore(1),
        None,
        False,
    )
    if protocol == "score_only_goals_v2":
        assert asyncio.run(call)["status"] == "skipped_existing"
    else:
        with pytest.raises(ValueError, match="judge input protocol"):
            asyncio.run(call)
    assert saved.read_text() == original
    assert calls == []
