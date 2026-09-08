"""Unit tests for the per-seat LLM backend configuration (src/llm_config.py)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))

import llm_config as lc  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in list(lc.SEAT_BACKEND_VARS.values()) + [
        lc.GLOBAL_BACKEND_VAR, "JUDGE_VIA_OR", "JUDGE_VIA_CODEX", "JUDGE_OR_MODEL",
        "SWT_JUDGE_MODEL", "CODEX_JUDGE_MODEL", "SWT_AWS_REGION", "AWS_REGION",
        "SWT_BEDROCK_SMALL_FAST_MODEL",
    ]:
        monkeypatch.delenv(var, raising=False)


# ── registry ──────────────────────────────────────────────────────────────

def test_registry_ids_use_expected_grammar():
    for name, spec in lc.MODEL_REGISTRY.items():
        assert spec.canonical == name
        if spec.bedrock:
            # Bedrock ids are inference profiles as listed by models.dev.
            assert spec.bedrock.startswith("global."), spec.bedrock
        if spec.openrouter:
            assert "/" in spec.openrouter and " " not in spec.openrouter
        if spec.native:
            assert spec.native_provider in lc.NATIVE_PREFIXES
        assert spec.backends(), f"{name} offers no backend"


def test_registry_targets_present():
    assert lc.MODEL_REGISTRY["gpt-5.6-sol"].bedrock == "global.openai.gpt-5.6-sol"
    assert lc.MODEL_REGISTRY["gpt-5.6-sol"].supports_temperature is False
    assert lc.MODEL_REGISTRY["claude-fable-5.1"].bedrock == "global.anthropic.claude-fable-5-1"
    assert lc.MODEL_REGISTRY["claude-opus-4.6"].openrouter == "anthropic/claude-opus-4.6"
    assert lc.MODEL_REGISTRY["gemini-3.1-pro"].bedrock is None
    assert lc.lookup("claude-opus-4-6") is lc.MODEL_REGISTRY["claude-opus-4.6"]
    assert lc.lookup("nope") is None


# ── backend precedence ────────────────────────────────────────────────────

def test_seat_backend_default_is_native():
    assert lc.seat_backend("agent") == "native"


def test_seat_backend_precedence(monkeypatch):
    monkeypatch.setenv(lc.GLOBAL_BACKEND_VAR, "openrouter")
    assert lc.seat_backend("agent") == "openrouter"
    monkeypatch.setenv("SWT_AGENT_BACKEND", "bedrock")
    assert lc.seat_backend("agent") == "bedrock"
    assert lc.seat_backend("user_sim") == "openrouter"  # global still applies elsewhere
    assert lc.seat_backend("agent", plan_value="openrouter") == "openrouter"
    assert lc.seat_backend("agent", cli_value="native", plan_value="openrouter") == "native"


def test_seat_backend_validation():
    with pytest.raises(SystemExit):
        lc.seat_backend("agent", cli_value="azure")
    with pytest.raises(SystemExit):
        lc.seat_backend("agent", cli_value="codex")  # codex is judge-only
    assert lc.seat_backend("judge", cli_value="codex") == "codex"
    with pytest.raises(ValueError):
        lc.seat_backend("driver")


# ── resolution ────────────────────────────────────────────────────────────

def test_resolve_registry_name_per_backend():
    r = lc.resolve_seat_model("agent", "gpt-5.6-sol", "bedrock")
    assert r.model == "bedrock/global.openai.gpt-5.6-sol" and r.backend == "bedrock"
    assert r.supports_temperature is False
    r = lc.resolve_seat_model("agent", "gpt-5.6-sol", "openrouter")
    assert r.model == "openrouter/openai/gpt-5.6-sol"
    r = lc.resolve_seat_model("user_sim", "gemini-3.1-pro", "native")
    assert r.model == "gemini/gemini-3.1-pro-preview" and r.backend == "native"
    r = lc.resolve_seat_model("judge", "claude-opus-4.6", "native")
    assert r.model == "anthropic/claude-opus-4-6"


def test_resolve_unsupported_combination_lists_alternatives():
    with pytest.raises(SystemExit) as ei:
        lc.resolve_seat_model("user_sim", "gemini-3.1-pro", "bedrock")
    assert "openrouter" in str(ei.value) and "native" in str(ei.value)
    with pytest.raises(SystemExit):
        lc.resolve_seat_model("agent", "muse-spark-1.3", "native")


def test_resolve_fully_qualified_passthrough_overrides_backend():
    r = lc.resolve_seat_model("agent", "openrouter/meta/muse-spark-1.3", "bedrock")
    assert r.model == "openrouter/meta/muse-spark-1.3" and r.backend == "openrouter"
    assert r.spec is lc.MODEL_REGISTRY["muse-spark-1.3"]
    r = lc.resolve_seat_model("agent", "bedrock/global.openai.gpt-5.6-sol", "native")
    assert r.backend == "bedrock" and r.supports_temperature is False
    r = lc.resolve_seat_model("agent", "anthropic/claude-opus-4-6", "openrouter")
    assert r.backend == "native"


def test_resolve_unknown_bare_name_passes_through():
    r = lc.resolve_seat_model("agent", "some-new-model", "openrouter")
    assert r.model == "some-new-model" and r.spec is None and r.supports_temperature is True


# ── translations ──────────────────────────────────────────────────────────

def test_backend_of_and_is_bedrock():
    assert lc.backend_of("bedrock/x") == "bedrock"
    assert lc.backend_of("openrouter/a/b") == "openrouter"
    assert lc.backend_of("gemini/g") == "native"
    assert lc.backend_of("codex/gpt-5.5") == "codex"
    assert lc.is_bedrock("bedrock/x") and not lc.is_bedrock("openrouter/x")


def test_to_opencode_model():
    assert lc.to_opencode_model("bedrock/global.openai.gpt-5.6-sol") == "amazon-bedrock/global.openai.gpt-5.6-sol"
    assert lc.to_opencode_model("openrouter/meta/muse-spark-1.3") == "openrouter/meta/muse-spark-1.3"


def test_to_litellm_model():
    assert lc.to_litellm_model("bedrock/global.anthropic.claude-opus-4-6-v1") == \
        "bedrock/converse/global.anthropic.claude-opus-4-6-v1"
    assert lc.to_litellm_model("bedrock/converse/x") == "bedrock/converse/x"
    assert lc.to_litellm_model("bedrock/invoke/x") == "bedrock/invoke/x"
    assert lc.to_litellm_model("openrouter/google/gemini-3.1-pro-preview") == "openrouter/google/gemini-3.1-pro-preview"


def test_to_claude_code_model():
    assert lc.to_claude_code_model("bedrock/global.anthropic.claude-opus-4-6-v1") == "global.anthropic.claude-opus-4-6-v1"
    assert lc.to_claude_code_model("openrouter/anthropic/claude-opus-4.6") == "anthropic/claude-opus-4.6"
    assert lc.to_claude_code_model("anthropic/claude-opus-4-6") == "claude-opus-4-6"


def test_region_and_small_fast_defaults(monkeypatch):
    assert lc.aws_region() == lc.DEFAULT_AWS_REGION
    monkeypatch.setenv("SWT_AWS_REGION", "eu-west-1")
    assert lc.aws_region() == "eu-west-1"
    assert lc.bedrock_small_fast_model() == lc.DEFAULT_BEDROCK_SMALL_FAST_MODEL


# ── judge ─────────────────────────────────────────────────────────────────

def test_judge_default_is_native_opus():
    j = lc.judge_model()
    assert j.backend == "native" and j.model == "anthropic/claude-opus-4-6"


def test_judge_legacy_via_or(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_OR", "1")
    j = lc.judge_model()
    assert j.backend == "openrouter" and j.model == "openrouter/anthropic/claude-opus-4.6"
    monkeypatch.setenv("JUDGE_OR_MODEL", "anthropic/claude-opus-4.8")
    assert lc.judge_model().model == "openrouter/anthropic/claude-opus-4.8"


def test_judge_legacy_via_codex(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_CODEX", "1")
    j = lc.judge_model()
    assert j.backend == "codex" and j.model == "codex/gpt-5.5"
    monkeypatch.setenv("CODEX_JUDGE_MODEL", "gpt-5.6")
    assert lc.judge_model().model == "codex/gpt-5.6"


def test_judge_explicit_backend_wins_over_legacy(monkeypatch):
    monkeypatch.setenv("JUDGE_VIA_OR", "1")
    j = lc.judge_model(cli_backend="bedrock")
    assert j.backend == "bedrock" and j.model == "bedrock/global.anthropic.claude-opus-4-6-v1"
    monkeypatch.setenv("SWT_JUDGE_BACKEND", "native")
    assert lc.judge_model().model == "anthropic/claude-opus-4-6"


def test_judge_rejects_non_claude(monkeypatch):
    monkeypatch.setenv("SWT_JUDGE_MODEL", "gpt-5.6-sol")
    with pytest.raises(SystemExit):
        lc.judge_model(cli_backend="bedrock")


# ── catalog check (offline) ───────────────────────────────────────────────

def test_check_models_dev_offline(monkeypatch):
    import urllib.request

    def boom(*a, **k):
        raise OSError("no network")

    monkeypatch.setattr(urllib.request, "urlopen", boom)
    assert lc.check_models_dev("amazon-bedrock", "global.openai.gpt-5.6-sol") == "offline"
