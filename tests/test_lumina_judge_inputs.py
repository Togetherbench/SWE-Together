"""Exercise the actual scorer's staged inputs and fail-closed verifier launcher."""

import asyncio
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
import sys

from eval.correctness import run_batch


TASK = Path(__file__).resolve().parents[1] / "tasks/comfyui-lumina2-lora-prefix"


def test_scorer_stages_requirements_without_historical_outcomes(tmp_path, monkeypatch):
    agent = tmp_path / "agent"
    agent.mkdir()
    (agent / "final.patch").write_bytes((TASK / "corrected_reference.patch").read_bytes())
    staged = []

    async def capture(**kwargs):
        staged.append(kwargs["inputs"])
        return SimpleNamespace(
            verdict={"goal_results": [{"id": f"goal_{i}", "met": True} for i in range(4)]},
            sandbox_id="offline-input-inspection", exit_code=0, judge_model="", judge_backend="",
        )

    monkeypatch.setattr(run_batch, "run_judge_in_e2b", capture)
    result = asyncio.run(run_batch._phase2_one(
        {"trial_dir": str(tmp_path), "task_dir": str(TASK)}, "", asyncio.Semaphore(1), None, False,
    ))
    assert result["status"] == "ok"
    assert result["judge_score"] == 1.0
    inputs, = staged
    rubric = json.loads(inputs.canonical_goals_json)
    assert [(g["id"], g["weight"]) for g in rubric["completeness_goals"]] == [
        ("goal_0", 0.0), ("goal_1", 0.6), ("goal_2", 0.25), ("goal_3", 0.15),
    ]
    text = inputs.readme + inputs.user_sim_prompt + inputs.canonical_goals_json + inputs.test_sh
    text += "\n".join(data.decode() for data in inputs.tests_files.values())
    for contamination in ("All four real model patches", "claude-sonnet-4-6", "Reward | **1.0**", "Max stub score"):
        assert contamination not in text
    assert "base_model.model.layers.0.attention.out.lora_A.weight" in inputs.readme
    assert "verify_behavior.py" in inputs.tests_files
    assert set(inputs.tests_files).isdisjoint({"authoring_history.md", "corrected_reference.patch"})
    assert (TASK / "instruction.md").read_text().strip() in inputs.readme


def test_verifier_setup_failure_removes_stale_reward(tmp_path):
    (tmp_path / "reward.txt").write_text("1.0\n")
    (tmp_path / "gates.json").write_text('{"passed": true}\n')
    result = subprocess.run(
        ["bash", str(TASK / "tests/test.sh")],
        env={**os.environ, "REPO_DIR": str(tmp_path), "LOGS_DIR": str(tmp_path),
             "VENV_PY": str(tmp_path / "missing-python")},
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert not (tmp_path / "reward.txt").exists()
    assert not (tmp_path / "gates.json").exists()


def test_cli_verifier_infrastructure_error_is_not_a_model_zero(tmp_path):
    (tmp_path / "reward.txt").write_text("1.0\n")
    checker = TASK.parent / "cli-task-70c88c/tests/verify_behavior.py"
    result = subprocess.run(
        [sys.executable, str(checker), "--repo", str(tmp_path / "missing-repo"), "--logs", str(tmp_path)],
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "FileNotFoundError" in result.stderr
    assert not (tmp_path / "reward.txt").exists()
