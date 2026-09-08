"""Agent-seat plumbing for the Bedrock backend: resolve_model, build_agent_env,
the opencode.json patch script, credential overlay on exec envs, launcher scrub.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

import bedrock_creds as bc  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in bc.CREDENTIAL_VARS + bc.REGION_VARS + (bc.EXPIRY_VAR, "SWT_AWS_CREDENTIAL_CMD", "SWT_AWS_REGION"):
        monkeypatch.delenv(var, raising=False)


def _fake_creds(monkeypatch, key="ASIAFAKE", token="tok"):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", key)
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "secret")
    monkeypatch.setenv("AWS_SESSION_TOKEN", token)


# ── runner.resolve_model ──────────────────────────────────────────────────

def test_resolve_model_bedrock_is_keyless(monkeypatch):
    import runner
    _fake_creds(monkeypatch)
    model, key, var = runner.resolve_model("bedrock/global.openai.gpt-5.6-sol")
    assert model == "bedrock/global.openai.gpt-5.6-sol" and key == "" and var == ""


def test_resolve_model_bedrock_fails_without_credentials(monkeypatch):
    import runner
    with pytest.raises(SystemExit):
        runner.resolve_model("bedrock/global.openai.gpt-5.6-sol")


def test_resolve_model_openrouter_still_requires_key(monkeypatch):
    import runner
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    with pytest.raises(SystemExit):
        runner.resolve_model("openrouter/meta/muse-spark-1.3")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    assert runner.resolve_model("openrouter/meta/muse-spark-1.3")[1] == "sk-or-test"


# ── run_eval.build_agent_env ──────────────────────────────────────────────

def test_build_agent_env_bedrock_sets_region_only(monkeypatch):
    import run_eval
    monkeypatch.setenv("SWT_AWS_REGION", "us-west-2")
    env = run_eval.build_agent_env("bedrock/global.openai.gpt-5.6-sol", "bedrock/global.openai.gpt-5.6-sol", "")
    assert env == {"AWS_REGION": "us-west-2", "AWS_DEFAULT_REGION": "us-west-2"}
    assert "ANTHROPIC_API_KEY" not in env


def test_build_agent_env_openrouter_unchanged():
    import run_eval
    env = run_eval.build_agent_env("openrouter/meta/muse-spark-1.3", "openrouter/meta/muse-spark-1.3", "sk-or-x")
    assert env["OPENROUTER_API_KEY"] == "sk-or-x"


# ── opencode.json patch script ────────────────────────────────────────────

def _run_patch(tmp_path, seed: dict, **kwargs) -> dict:
    from user_agent.agents.user_enabled_opencode import build_opencode_config_patch_script
    home = tmp_path / "home"
    cfg_path = home / ".config" / "opencode" / "opencode.json"
    cfg_path.parent.mkdir(parents=True)
    cfg_path.write_text(json.dumps(seed))
    script = build_opencode_config_patch_script(
        using_proxied_provider=kwargs.get("using_proxied_provider", False),
        disallowed_tools=kwargs.get("disallowed_tools"),
        bedrock_region=kwargs.get("bedrock_region"),
    )
    subprocess.run([sys.executable, "-"], input=script, text=True, check=True,
                   env={"HOME": str(home), "PATH": "/usr/bin:/bin"})
    return json.loads(cfg_path.read_text())


def test_patch_bedrock_variants_and_region(tmp_path):
    cfg = _run_patch(
        tmp_path,
        {"provider": {"amazon-bedrock": {"models": {"global.openai.gpt-5.6-sol": {}}}}},
        bedrock_region="us-west-2",
    )
    entry = cfg["provider"]["amazon-bedrock"]["models"]["global.openai.gpt-5.6-sol"]
    assert entry["reasoning"] is True
    assert set(entry["variants"]) == {"none", "low", "medium", "high", "xhigh", "max"}
    assert entry["variants"]["high"] == {"reasoningConfig": {"type": "adaptive", "maxReasoningEffort": "high"}}
    assert cfg["provider"]["amazon-bedrock"]["options"]["region"] == "us-west-2"
    assert cfg["permission"]["external_directory"]["/workspace/**"] == "allow"


def test_patch_openrouter_unchanged(tmp_path):
    cfg = _run_patch(tmp_path, {"provider": {"openrouter": {"models": {"meta/muse-spark-1.3": {}}}}})
    entry = cfg["provider"]["openrouter"]["models"]["meta/muse-spark-1.3"]
    assert entry["reasoning"] is True
    assert set(entry["variants"]) == {"none", "minimal", "low", "medium", "high", "xhigh"}
    assert entry["variants"]["high"] == {"reasoning": {"effort": "high"}}
    assert "options" not in cfg["provider"]["openrouter"]


def test_patch_anthropic_gets_no_variants(tmp_path):
    cfg = _run_patch(tmp_path, {"provider": {"anthropic": {"models": {"claude-opus-4-6": {}}}}},
                     using_proxied_provider=True, disallowed_tools="WebFetch,WebSearch")
    entry = cfg["provider"]["anthropic"]["models"]["claude-opus-4-6"]
    assert entry == {"reasoning": True}
    assert cfg["provider"]["anthropic"]["options"]["baseURL"] == "http://localhost:4210/v1"
    assert cfg["permission"]["tools"] == {"webfetch": "deny", "websearch": "deny"}


def test_patch_region_not_written_for_other_providers(tmp_path):
    cfg = _run_patch(tmp_path, {"provider": {"openrouter": {"models": {"x/y": {}}}}}, bedrock_region="us-west-2")
    assert "amazon-bedrock" not in cfg["provider"]


# ── wrapper credential overlay ────────────────────────────────────────────

class _FakeInner:
    def __init__(self, model_name):
        self.model_name = model_name


def _wrapper_stub(model_name):
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode
    w = object.__new__(UserEnabledOpenCode)
    w._inner = _FakeInner(model_name)
    return w


def test_refresh_agent_env_overlays_for_bedrock_only(monkeypatch):
    _fake_creds(monkeypatch, key="ASIA-1", token="tok-1")
    monkeypatch.setenv("SWT_AWS_REGION", "us-west-2")
    w = _wrapper_stub("amazon-bedrock/global.openai.gpt-5.6-sol")
    env = w._refresh_agent_env({"OPENCODE_FAKE_VCS": "git", "AWS_ACCESS_KEY_ID": "stale"})
    assert env["OPENCODE_FAKE_VCS"] == "git"
    assert env["AWS_ACCESS_KEY_ID"] == "ASIA-1" and env["AWS_SESSION_TOKEN"] == "tok-1"
    assert env["AWS_REGION"] == "us-west-2"

    # Refreshed host credentials show up on the next call (resume turns).
    _fake_creds(monkeypatch, key="ASIA-2", token="tok-2")
    assert w._refresh_agent_env(env)["AWS_ACCESS_KEY_ID"] == "ASIA-2"

    other = _wrapper_stub("openrouter/meta/muse-spark-1.3")
    assert other._refresh_agent_env({"OPENROUTER_API_KEY": "k"}) == {"OPENROUTER_API_KEY": "k"}


# ── per-cohort opencode version ───────────────────────────────────────────

def test_build_trial_config_records_opencode_version(monkeypatch, tmp_path):
    import run_eval
    task_dir = REPO_ROOT / "tasks" / "arr-monitor-add-processes-flag"
    common = dict(task_dir=task_dir, action_model="bedrock/global.openai.gpt-5.6-sol",
                  user_model="openrouter/google/gemini-3.1-pro-preview", user_key="k", user_api_base=None,
                  agent_env={}, trials_dir=tmp_path, env_type="enroot", agent_timeout=4800,
                  user_context_chars=3000, call_user_on_completion=True, agent_type="opencode",
                  reasoning_effort="high")
    pinned = run_eval.build_trial_config(**common, opencode_version="1.18.29")
    assert pinned.agent.kwargs["opencode_version"] == "1.18.29"
    assert pinned.agent.model_name == "amazon-bedrock/global.openai.gpt-5.6-sol"
    # Default cohorts keep the wrapper's canonical pin: nothing is written.
    default = run_eval.build_trial_config(**common)
    assert "opencode_version" not in default.agent.kwargs


def _load_module(name: str, path: Path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_plan_launcher_forwards_opencode_version(monkeypatch):
    plan_launch = _load_module("swt_plan_launch", REPO_ROOT / "launch.py")
    seen = []
    monkeypatch.setattr(plan_launch, "_run", lambda cmd, execute: seen.append(cmd) or 0)
    plan = {"trials_root": "trials/x", "replicates": [1], "user_model": "openrouter/google/gemini-3.1-pro-preview"}
    models = {
        "gpt56": {"model": "gpt-5.6-sol", "agent_backend": "bedrock", "opencode_version": "1.18.29"},
        "muse": {"model": "openrouter/meta/muse-spark-1.3"},
    }
    plan_launch.stage_run(plan, models, "enroot", execute=False)
    gpt, muse = seen
    assert gpt[gpt.index("--opencode-version") + 1] == "1.18.29"
    assert gpt[gpt.index("--agent-backend") + 1] == "bedrock"
    assert "--opencode-version" not in muse and "--agent-backend" not in muse

def test_harbor_opencode_forwards_session_token(monkeypatch, tmp_path):
    from harbor.agents.installed.opencode import OpenCode
    _fake_creds(monkeypatch, key="ASIA-h", token="tok-h")
    monkeypatch.setenv("AWS_REGION", "us-west-2")
    agent = OpenCode(logs_dir=tmp_path, model_name="amazon-bedrock/global.openai.gpt-5.6-sol")
    cmds = agent.create_run_agent_commands("hi")
    env = cmds[-1].env
    assert env["AWS_SESSION_TOKEN"] == "tok-h" and env["AWS_ACCESS_KEY_ID"] == "ASIA-h"
    assert "--model=amazon-bedrock/global.openai.gpt-5.6-sol" in cmds[-1].command


# ── launcher scrub ────────────────────────────────────────────────────────

def test_launcher_submit_scrubs_aws_credentials(monkeypatch, tmp_path):
    launch = _load_module("swt_slurm_launch", REPO_ROOT / "scripts" / "slurm" / "launch.py")
    _fake_creds(monkeypatch, key="ASIA-scrub")
    monkeypatch.setenv(bc.EXPIRY_VAR, "123")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-keep")
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["env"] = kwargs["env"]
        return subprocess.CompletedProcess(cmd, 0, "Submitted batch job 42\n", "")

    monkeypatch.setattr(launch.subprocess, "run", fake_run)
    script = tmp_path / "job.sbatch"
    script.write_text("#!/bin/bash\n")
    assert launch._submit(script, submit=True) == 0
    assert "AWS_ACCESS_KEY_ID" not in seen["env"] and bc.EXPIRY_VAR not in seen["env"]
    assert seen["env"]["OPENROUTER_API_KEY"] == "sk-or-keep"
    assert (tmp_path / "job_id.txt").read_text().strip() == "42"
