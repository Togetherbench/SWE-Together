"""Protocol defaults for the non-agent LLM seats and their provenance.

Since 2026-10-13 the user simulator and the tagger / intent-coverage seats default
to Claude Sonnet 5.5 on Bedrock (earlier cohorts: Gemini 3.1 Pro via OpenRouter).
Every stage must agree on the default, and every artefact must record which
simulator / judge / tagger produced it so cohorts from both eras stay distinguishable.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

SONNET = "bedrock/global.anthropic.claude-sonnet-5-5"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _argparse_default(path: Path, flag: str) -> str:
    """Default of ``flag`` as declared in the module's argparse setup (no import side effects)."""
    src = path.read_text()
    i = src.index(f'"{flag}"')
    j = src.index("default=", i)
    k = src.index(",", j)
    return src[j + len("default="):k].strip().strip('"')


def test_every_stage_defaults_to_sonnet_55_on_bedrock():
    assert _argparse_default(REPO_ROOT / "src" / "run_eval.py", "--user-model") == SONNET
    assert _argparse_default(REPO_ROOT / "eval" / "run_eval.py", "--tag-model") == SONNET
    launch = _load(REPO_ROOT / "scripts" / "slurm" / "launch.py", "launch_mod")
    assert launch.DEFAULT_USER_MODEL == SONNET and launch.DEFAULT_TAG_MODEL == SONNET
    coverage = _load(REPO_ROOT / "eval" / "user_behavior" / "coverage_one.py", "coverage_one_mod")
    assert coverage.DEFAULT_MODEL == SONNET
    plan = json.loads((REPO_ROOT / "canonical_full109.json").read_text())
    assert plan["user_model"] == SONNET


def test_sonnet_default_resolves_on_bedrock_for_both_seats():
    import llm_config as lc
    for seat in ("user_sim", "tagger"):
        r = lc.resolve_seat_model(seat, SONNET, "openrouter")  # prefix wins over the env backend
        assert r.backend == "bedrock" and r.model == SONNET
        # the 5.5 endpoints reject `temperature` and `tool_choice: required`; callers must adapt
        assert not r.supports_temperature and not r.supports_forced_tool_choice
    assert lc.to_litellm_model(SONNET) == "bedrock/converse/global.anthropic.claude-sonnet-5-5"
    assert lc.spec_for("bedrock/converse/global.anthropic.claude-sonnet-5-5") is lc.MODEL_REGISTRY["claude-sonnet-5.5"]
    assert lc.spec_for("openrouter/google/gemini-3.1-pro-preview") is lc.MODEL_REGISTRY["gemini-3.1-pro"]
    assert lc.spec_for("bedrock/global.unknown.model") is None


def test_user_sim_adapts_tool_choice_to_the_model():
    from user_agent.user_agent import UserAgent

    class _LLM:
        def __init__(self, name):
            self._model_name = name
    assert UserAgent(_LLM("bedrock/converse/global.anthropic.claude-sonnet-5-5"))._tool_choice == "auto"
    assert UserAgent(_LLM("openrouter/google/gemini-3.1-pro-preview"))._tool_choice == "required"
    assert UserAgent(_LLM("some/unknown-model"))._tool_choice == "required"
    assert UserAgent(_LLM(SONNET), force_tool_choice=True)._tool_choice == "required"


def test_tagger_drops_temperature_for_models_that_reject_it(monkeypatch):
    sys.path.insert(0, str(REPO_ROOT))
    from eval.user_behavior import coverage_one
    seen = {}

    class _FakeLiteLLM:
        def __init__(self, model_name, temperature):
            seen[model_name] = temperature
    monkeypatch.setattr(coverage_one, "LiteLLM", _FakeLiteLLM)
    monkeypatch.setattr(coverage_one, "_prepare_model", lambda m: m.replace("bedrock/", "bedrock/converse/", 1) if m.startswith("bedrock/") and "/converse/" not in m else m)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    coverage_one._make_llm(SONNET, 0.0)
    coverage_one._make_llm("openrouter/google/gemini-3.1-pro-preview", 0.0)
    assert seen == {"bedrock/converse/global.anthropic.claude-sonnet-5-5": None,
                    "openrouter/google/gemini-3.1-pro-preview": 0.0}


def test_per_trial_records_seat_models(tmp_path):
    ev = _load(REPO_ROOT / "eval" / "run_eval.py", "eval_run_eval_mod")
    t = tmp_path / "cli-task-30159a__abc1234"
    (t / "agent").mkdir(parents=True)
    (t / "config.json").write_text(json.dumps({"agent": {"kwargs": {"user_model_name": SONNET}}}))
    (t / "judge_verdict.json").write_text(json.dumps(
        {"judge_score": 0.9, "verdict": "pass", "judge_model": "bedrock:global.anthropic.claude-opus-4-6-v1"}))
    (t / "intent_coverage_verdict.json").write_text(json.dumps(
        {"overall_score": 0.8, "judge_model": SONNET, "trial_msg_tags": []}))
    row = ev.join_trial_artefacts({"task": "cli-task-30159a", "cohort": "x_r1", "trial_dir": str(t)})
    assert row["user_sim_model"] == SONNET
    assert row["judge_model"] == "bedrock:global.anthropic.claude-opus-4-6-v1"
    assert row["coverage_model"] == SONNET
    # a pre-switch trial (no sim model in config) degrades to None rather than a guess
    (t / "config.json").write_text(json.dumps({"agent": {"kwargs": {}}}))
    assert ev.join_trial_artefacts({"task": "cli-task-30159a", "cohort": "x_r1", "trial_dir": str(t)})["user_sim_model"] is None
