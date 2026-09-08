"""Host-seat backends: judge auth envs / labels / auth gate, tagger model preparation,
and the eval dotenv loader delegation.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT))

import llm_config as lc  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in list(lc.SEAT_BACKEND_VARS.values()) + [
        lc.GLOBAL_BACKEND_VAR, "JUDGE_VIA_OR", "JUDGE_VIA_CODEX", "JUDGE_OR_MODEL", "SWT_JUDGE_MODEL",
        "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION",
        "SWT_AWS_REGION", "SWT_BEDROCK_SMALL_FAST_MODEL", "SWT_AWS_CREDENTIAL_CMD", "SWT_AWS_EXPIRY_EPOCH",
    ]:
        monkeypatch.delenv(var, raising=False)


# ── judge auth envs: byte-identical to the pre-refactor branches ──────────

def test_judge_auth_openrouter_matches_legacy_env_tuple(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_OR", "1")
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    j = lc.judge_model()
    assert lc.judge_auth_envs(j) == {
        "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
        "ANTHROPIC_AUTH_TOKEN": "sk-or-test",
        "ANTHROPIC_API_KEY": "",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "anthropic/claude-opus-4.6",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "anthropic/claude-opus-4.6",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "anthropic/claude-opus-4.6",
    }
    assert lc.judge_model_label(j) == "or:anthropic/claude-opus-4.6"
    assert lc.to_claude_code_model(j.model) == "anthropic/claude-opus-4.6"


def test_judge_auth_native_key_and_oauth():
    j = lc.judge_model()
    assert j.backend == "native"
    assert lc.judge_auth_envs(j, {"ANTHROPIC_API_KEY": "sk-ant-api03-x"}) == {"ANTHROPIC_API_KEY": "sk-ant-api03-x"}
    assert lc.judge_auth_envs(j, {"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-y"}) == {"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-y"}
    assert lc.judge_auth_envs(j, {}) == {"CLAUDE_CODE_OAUTH_TOKEN": ""}
    assert lc.judge_model_label(j) == "claude-opus-4-6"
    assert lc.to_claude_code_model(j.model) == "claude-opus-4-6"


def test_judge_auth_codex_is_empty(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_CODEX", "1")
    j = lc.judge_model()
    assert j.backend == "codex" and lc.judge_auth_envs(j) == {}
    assert lc.judge_model_label(j) == "codex:gpt-5.5"


def test_judge_auth_bedrock(monkeypatch):
    monkeypatch.setenv("SWT_JUDGE_BACKEND", "bedrock")
    monkeypatch.setenv("SWT_AWS_REGION", "us-west-2")
    env = {"AWS_ACCESS_KEY_ID": "ASIAFAKE", "AWS_SECRET_ACCESS_KEY": "s", "AWS_SESSION_TOKEN": "t",
           "AWS_REGION": "us-west-2", "ANTHROPIC_API_KEY": "must-not-leak", "OPENROUTER_API_KEY": "nor-this"}
    j = lc.judge_model()
    assert j.model == "bedrock/global.anthropic.claude-opus-4-6-v1"
    out = lc.judge_auth_envs(j, env)
    assert out == {
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "AWS_ACCESS_KEY_ID": "ASIAFAKE", "AWS_SECRET_ACCESS_KEY": "s", "AWS_SESSION_TOKEN": "t",
        "AWS_REGION": "us-west-2",
        "ANTHROPIC_MODEL": "global.anthropic.claude-opus-4-6-v1",
        "ANTHROPIC_SMALL_FAST_MODEL": lc.DEFAULT_BEDROCK_SMALL_FAST_MODEL,
        "ANTHROPIC_API_KEY": "",
    }
    assert "ANTHROPIC_BASE_URL" not in out and "ANTHROPIC_AUTH_TOKEN" not in out
    assert lc.judge_model_label(j) == "bedrock:global.anthropic.claude-opus-4-6-v1"
    assert lc.to_claude_code_model(j.model) == "global.anthropic.claude-opus-4-6-v1"


def test_explicit_backend_beats_legacy_switch(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_OR", "1")
    monkeypatch.setenv("SWT_JUDGE_BACKEND", "native")
    assert lc.judge_model().backend == "native"
    # ...and the global switch too, unless the judge var is set
    monkeypatch.delenv("SWT_JUDGE_BACKEND")
    monkeypatch.setenv(lc.GLOBAL_BACKEND_VAR, "openrouter")
    assert lc.judge_model().backend == "openrouter"


# ── auth gate ─────────────────────────────────────────────────────────────

def test_check_judge_auth(monkeypatch):
    monkeypatch.setenv("SWT_JUDGE_BACKEND", "openrouter")
    assert "OPENROUTER_API_KEY" in lc.check_judge_auth(lc.judge_model())
    monkeypatch.setenv("OPENROUTER_API_KEY", "k")
    assert lc.check_judge_auth(lc.judge_model()) is None

    monkeypatch.setenv("SWT_JUDGE_BACKEND", "native")
    assert "ANTHROPIC_API_KEY" in lc.check_judge_auth(lc.judge_model())
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "t")
    assert lc.check_judge_auth(lc.judge_model()) is None

    monkeypatch.setenv("SWT_JUDGE_BACKEND", "bedrock")
    assert "bedrock" in lc.check_judge_auth(lc.judge_model())  # no creds, no command
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "static")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "static")
    assert lc.check_judge_auth(lc.judge_model()) is None


# ── sandbox.py uses the shared resolution ─────────────────────────────────

def test_sandbox_constants_preserved():
    from eval.correctness import sandbox
    assert sandbox.JUDGE_MODEL_CLAUDE == "claude-opus-4-6"
    assert sandbox.JUDGE_MODEL_CODEX_DEFAULT == "gpt-5.5"
    assert sandbox.run_judge_in_e2b is sandbox.run_judge
    from dataclasses import fields
    assert {f.name for f in fields(sandbox.JudgeRunResult)} >= {"judge_model", "judge_backend"}


# ── tagger seat ───────────────────────────────────────────────────────────

def test_prepare_model_translates_bedrock_and_leaves_others(monkeypatch):
    from eval.user_behavior.coverage_one import _prepare_model
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "static")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "static")
    assert _prepare_model("bedrock/global.anthropic.claude-opus-4-6-v1") == "bedrock/converse/global.anthropic.claude-opus-4-6-v1"
    assert _prepare_model("openrouter/google/gemini-3.1-pro-preview") == "openrouter/google/gemini-3.1-pro-preview"
    assert _prepare_model("gemini/gemini-3.1-pro-preview") == "gemini/gemini-3.1-pro-preview"


def test_tagger_seat_resolution(monkeypatch):
    r = lc.resolve_seat_model("tagger", "gemini-3.1-pro", lc.seat_backend("tagger"))
    assert r.model == "gemini/gemini-3.1-pro-preview"  # native default = today's literal
    monkeypatch.setenv("SWT_TAGGER_BACKEND", "openrouter")
    r = lc.resolve_seat_model("tagger", "gemini-3.1-pro", lc.seat_backend("tagger"))
    assert r.model == "openrouter/google/gemini-3.1-pro-preview"
    with pytest.raises(SystemExit):
        lc.resolve_seat_model("tagger", "gemini-3.1-pro", "bedrock")


# ── eval dotenv delegation strips quotes ──────────────────────────────────

def test_eval_env_loader_strips_quotes(monkeypatch, tmp_path):
    import importlib
    from eval.correctness import _env
    monkeypatch.setattr(_env, "REPO_ROOT", tmp_path)
    (tmp_path / ".env").write_text('SWT_TEST_QUOTED="some-tool get-creds -d {lease}"\nSWT_TEST_PLAIN=x\n')
    monkeypatch.delenv("SWT_TEST_QUOTED", raising=False)
    monkeypatch.delenv("SWT_TEST_PLAIN", raising=False)
    _env.load_dotenv()
    import os
    assert os.environ["SWT_TEST_QUOTED"] == "some-tool get-creds -d {lease}"
    assert os.environ["SWT_TEST_PLAIN"] == "x"
    importlib.reload(_env)
