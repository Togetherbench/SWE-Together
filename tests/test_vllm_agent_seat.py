"""Agent-seat plumbing for the self-hosted `vllm` backend: resolve_model,
build_agent_env, the opencode provider block, the Harbor adapter, the egress
self-test probe and the relay-route selection in run_eval.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

import egress_policy as ep  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in ("SWT_EGRESS_ENFORCED", "SWT_VLLM_BASE_URL", "SWT_VLLM_ENDPOINT", "SWT_VLLM_API_KEY",
                "SWT_VLLM_MAX_MODEL_LEN", "VLLM_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY"):
        monkeypatch.delenv(var, raising=False)


def test_resolve_model_vllm_needs_no_host_key():
    import runner
    model, key, var = runner.resolve_model("vllm/glm-5.3")
    assert model == "vllm/glm-5.3" and key == ep.LLM_ROUTE_PLACEHOLDER and var == "VLLM_API_KEY"


def test_build_agent_env_vllm_sets_only_the_placeholder():
    import run_eval
    env = run_eval.build_agent_env("vllm/glm-5.3", "vllm/glm-5.3", ep.LLM_ROUTE_PLACEHOLDER)
    assert env == {"VLLM_API_KEY": ep.LLM_ROUTE_PLACEHOLDER}


def _wrapper(model_name: str):
    """A UserEnabledOpenCode-like object with just what the config path reads."""
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode

    class _Inner:
        def __init__(self):
            self.model_name = model_name
            self.mcp_servers = []

    obj = UserEnabledOpenCode.__new__(UserEnabledOpenCode)
    obj._inner = _Inner()
    obj._using_proxied_provider = False
    obj._disallowed_tools = None
    return obj


def test_opencode_config_for_vllm_points_at_the_relay_route(monkeypatch):
    from user_agent.agents.user_enabled_opencode import render_opencode_config_command
    monkeypatch.setenv("SWT_EGRESS_ENFORCED", "1")
    monkeypatch.setenv("SWT_VLLM_MAX_MODEL_LEN", "200000")
    w = _wrapper("vllm/glm-5.3")
    assert w._is_vllm_agent() and not w._is_openrouter_agent() and not w._is_bedrock_agent()
    cmd = w._opencode_thinking_patch_command()
    with tempfile.TemporaryDirectory() as home:
        subprocess.run(["sh", "-c", cmd], check=True, env={"HOME": home, "PATH": "/usr/bin:/bin"}, capture_output=True)
        cfg = json.loads((Path(home) / ".config" / "opencode" / "opencode.json").read_text())
    prov = cfg["provider"]["vllm"]
    assert prov["npm"] == "@ai-sdk/openai-compatible"
    assert prov["options"] == {"baseURL": "http://127.0.0.1:3128/vllm/v1", "apiKey": ep.LLM_ROUTE_PLACEHOLDER}
    m = prov["models"]["glm-5.3"]
    assert m["limit"] == {"context": 200000, "output": 65536} and m["tool_call"] is True
    assert m["variants"]["high"] == {"reasoningEffort": "high"} and "reasoningConfig" not in json.dumps(m)
    assert "openrouter" not in cfg["provider"] and "amazon-bedrock" not in cfg["provider"]
    assert cfg["permission"]["external_directory"]["/workspace/**"] == "allow"


def test_opencode_config_for_vllm_without_enforcement_uses_the_server_directly(monkeypatch):
    monkeypatch.setenv("SWT_VLLM_BASE_URL", "http://node-01:8000")
    monkeypatch.setenv("SWT_VLLM_API_KEY", "sk-real")
    blk = _wrapper("vllm/glm-5.3")._vllm_provider_block()
    assert blk["options"] == {"baseURL": "http://node-01:8000/v1", "apiKey": "sk-real"}


def test_harbor_adapter_accepts_the_vllm_provider(monkeypatch):
    """Harbor's OpenCode adapter raises for providers it does not know; `vllm`
    must be accepted and forward only VLLM_API_KEY."""
    import harbor.agents.installed.opencode as hoc
    monkeypatch.setenv("VLLM_API_KEY", ep.LLM_ROUTE_PLACEHOLDER)
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-real")
    oc = hoc.OpenCode.__new__(hoc.OpenCode)
    oc.model_name = "vllm/glm-5.3"
    monkeypatch.setattr(hoc.OpenCode, "_build_register_skills_command", lambda self: None, raising=False)
    monkeypatch.setattr(hoc.OpenCode, "_build_register_config_command", lambda self: None, raising=False)
    cmds = oc.create_run_agent_commands("do the task")
    assert cmds and "opencode --model=vllm/glm-5.3" in cmds[-1].command
    env = cmds[-1].env
    assert env.get("VLLM_API_KEY") == ep.LLM_ROUTE_PLACEHOLDER and "OPENROUTER_API_KEY" not in env
    bad = hoc.OpenCode.__new__(hoc.OpenCode)
    bad.model_name = "nosuchprovider/x"
    with pytest.raises(ValueError, match="Unknown provider"):
        bad.create_run_agent_commands("x")


def test_selftest_probes_the_installed_route():
    from enroot_backend.netns import selftest_script
    default = selftest_script()
    assert "/openrouter/api/v1/models" in default and "/vllm/" not in default
    vllm = selftest_script(["/vllm/"])
    assert "/vllm/v1/models" in vllm and "/vllm/v1/chat/completions" in vllm and "/openrouter/" not in vllm
    assert "gemini-2.5-flash:online" in vllm  # the pin probe still posts a foreign web model


def test_opencode_env_scrubs_vendor_keys_for_a_self_hosted_run(monkeypatch, tmp_path):
    """Under enforcement a vllm run forwards no vendor key into the sandbox."""
    import run_eval
    monkeypatch.setenv("SWT_EGRESS_ENFORCED", "1")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-real")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-oa-real")
    task_dir = REPO_ROOT / "tasks" / "arr-monitor-add-processes-flag"
    cfg = run_eval.build_trial_config(
        task_dir=task_dir, action_model="vllm/glm-5.3", user_model="openrouter/google/gemini-3.1-pro-preview",
        user_key="k", user_api_base=None, agent_env={"VLLM_API_KEY": ep.LLM_ROUTE_PLACEHOLDER}, trials_dir=tmp_path,
        env_type="enroot", agent_timeout=4800, user_context_chars=3000, call_user_on_completion=True,
        agent_type="opencode", reasoning_effort="high", opencode_version="1.18.29")
    assert cfg.agent.model_name == "vllm/glm-5.3"
    env = cfg.agent.env
    assert env["VLLM_API_KEY"] == ep.LLM_ROUTE_PLACEHOLDER
    assert "OPENROUTER_API_KEY" not in env and "OPENAI_API_KEY" not in env and "GITHUB_TOKEN" not in env
