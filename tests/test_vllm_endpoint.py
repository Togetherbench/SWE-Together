"""Unit tests for the self-hosted vLLM serving package (no GPU, no network)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))

from serving import registry as sr  # noqa: E402
from serving import vllm_endpoint as ve  # noqa: E402
from serving import vllm_server as vs  # noqa: E402

HANDOFF = {"base_url": "http://node-01:8000", "served_model": "glm-5.3", "node": "node-01", "port": 8000,
           "job_id": "123", "max_model_len": 262144, "vllm_version": "0.29.0"}


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in ve.ENDPOINT_ENV + (ve.CREDENTIAL_ENV, "VLLM_API_KEY"):
        monkeypatch.delenv(var, raising=False)


# ── handoff parsing ────────────────────────────────────────────────────────

def test_load_from_file_dir_url_and_env(tmp_path, monkeypatch):
    d = tmp_path / "serve"; d.mkdir()
    f = d / ve.HANDOFF_NAME; f.write_text(json.dumps(HANDOFF))
    for spec in (f, d, str(f), str(d)):
        ep = ve.load(spec)
        assert (ep.base_url, ep.served_model, ep.node, ep.port, ep.job_id) == ("http://node-01:8000", "glm-5.3", "node-01", 8000, "123")
        assert ep.max_model_len == 262144 and ep.vllm_version == "0.29.0"
    # a bare URL needs the served name; /v1 suffixes are normalised away
    ep = ve.load("http://node-02:9000/v1/", served_model="glm-5.3")
    assert (ep.base_url, ep.node, ep.port, ep.job_id) == ("http://node-02:9000", "node-02", 9000, None)
    with pytest.raises(ValueError):
        ve.load("http://node-02:9000")
    assert ve.load(None) is None
    assert ve.load(tmp_path / "missing.json") is None
    monkeypatch.setenv("SWT_VLLM_ENDPOINT", str(d))
    assert ve.load(None).base_url == "http://node-01:8000"
    monkeypatch.delenv("SWT_VLLM_ENDPOINT")
    monkeypatch.setenv("SWT_VLLM_BASE_URL", "http://node-03:8000")
    assert ve.load(None, served_model="glm-5.3").node == "node-03"


def test_handoff_rejects_junk(tmp_path):
    f = tmp_path / "e.json"
    f.write_text(json.dumps({"base_url": "node-01:8000", "served_model": "glm-5.3"}))
    with pytest.raises(ValueError):
        ve.read_handoff(f)
    f.write_text(json.dumps({"base_url": "http://node-01:8000"}))
    with pytest.raises(ValueError):
        ve.read_handoff(f)


# ── readiness ──────────────────────────────────────────────────────────────

def test_wait_ready_returns_once_model_is_listed(tmp_path):
    f = tmp_path / ve.HANDOFF_NAME; f.write_text(json.dumps(HANDOFF))
    calls = []

    def fake_probe(ep, key):
        calls.append(key)
        return ["glm-5.3"] if len(calls) > 1 else (_ for _ in ()).throw(OSError("refused"))
    msgs = []
    ep = ve.wait_ready(f, "glm-5.3", timeout_s=30, poll_s=0.01, api_key="k", probe_fn=fake_probe,
                       job_alive=lambda j: True, log=msgs.append)
    assert ep.base_url == "http://node-01:8000" and calls == ["k", "k"]
    assert any("not ready" in m for m in msgs) and msgs[-1].startswith("vLLM ready")


def test_wait_ready_fails_on_model_mismatch_dead_job_and_timeout(tmp_path):
    f = tmp_path / ve.HANDOFF_NAME; f.write_text(json.dumps(HANDOFF))
    with pytest.raises(SystemExit, match="serves"):
        ve.wait_ready(f, "glm-5.3", timeout_s=5, poll_s=0.01, probe_fn=lambda ep, k: ["other"], job_alive=lambda j: True)
    with pytest.raises(SystemExit, match="no longer in the queue"):
        ve.wait_ready(f, "glm-5.3", timeout_s=5, poll_s=0.01, probe_fn=lambda ep, k: (_ for _ in ()).throw(OSError()),
                      job_alive=lambda j: False)
    with pytest.raises(SystemExit, match="timed out"):
        ve.wait_ready(tmp_path / "never.json", "glm-5.3", timeout_s=0.05, poll_s=0.01, probe_fn=lambda ep, k: [])


# ── route + opencode provider ──────────────────────────────────────────────

def test_reverse_route_targets_the_handoff_server():
    ep = ve.VllmEndpoint(**HANDOFF)
    r = ve.reverse_route(ep)
    assert (r.prefix, r.scheme, r.upstream, r.port, r.credential_env) == ("/vllm/", "http", "node-01", 8000, "SWT_VLLM_API_KEY")
    assert ("POST", "/v1/chat/completions") in r.endpoints and ("GET", "/v1/models") in r.endpoints
    assert r.llm_paths == frozenset({"/v1/chat/completions"}) and r.idle_timeout_s == ve.ROUTE_IDLE_TIMEOUT_S


def test_opencode_provider_is_fully_explicit():
    block = ve.opencode_provider("glm-5.3", base_url="http://127.0.0.1:3128/vllm/v1", api_key="swt-egress-proxy")
    assert block["npm"] == "@ai-sdk/openai-compatible"
    assert block["options"] == {"baseURL": "http://127.0.0.1:3128/vllm/v1", "apiKey": "swt-egress-proxy"}
    m = block["models"]["glm-5.3"]
    assert m["reasoning"] is True and m["tool_call"] is True
    assert m["limit"] == {"context": 262144, "output": 65536}
    assert m["variants"] == {"low": {"reasoningEffort": "low"}, "high": {"reasoningEffort": "high"}, "max": {"reasoningEffort": "max"}}
    assert "medium" not in m["variants"]  # GLM-5.3's template would silently treat it as max
    capped = ve.opencode_provider("glm-5.3", base_url="u", api_key="k", max_model_len=131072)
    assert capped["models"]["glm-5.3"]["limit"] == {"context": 131072, "output": 65536}
    with pytest.raises(SystemExit):
        ve.opencode_provider("unknown-model", base_url="u", api_key="k")


# ── server driver ──────────────────────────────────────────────────────────

def test_build_serve_argv_follows_the_recipe_and_keeps_the_key_out():
    spec = sr.serving_spec("glm-5.3")
    argv = vs.build_serve_argv(spec, weights="/w/GLM-5.3", port=8000, max_model_len=262144,
                               extra=("--max-num-seqs", "32"), vllm_bin="/env/bin/vllm")
    assert argv[:3] == ["/env/bin/vllm", "serve", "/w/GLM-5.3"]
    s = " ".join(argv)
    for frag in ("--served-model-name glm-5.3", "--port 8000", "--tensor-parallel-size 8", "--max-model-len 262144",
                 "--kv-cache-dtype fp8", "--tool-call-parser glm47", "--reasoning-parser glm47",
                 "--enable-auto-tool-choice", "--speculative-config.method mtp", "--max-num-seqs 32"):
        assert frag in s, frag
    assert "api-key" not in s and "secret" not in s
    assert argv.index("--max-num-seqs") > argv.index("--kv-cache-dtype")  # extra args override the recipe


def test_write_handoff_is_atomic_and_roundtrips(tmp_path):
    ep = ve.VllmEndpoint(**HANDOFF)
    p = vs.write_handoff(tmp_path / "x" / ve.HANDOFF_NAME, ep)
    assert p.exists() and not p.with_suffix(".json.tmp").exists()
    assert ve.read_handoff(p) == ep


def test_wait_health_fails_fast_when_the_process_died(monkeypatch):
    class Dead:
        returncode = 3

        def poll(self):
            return 3
    with pytest.raises(SystemExit, match="exited with status 3"):
        vs.wait_health("http://127.0.0.1:1", "glm-5.3", proc=Dead(), api_key=None, timeout_s=5, poll_s=0.01, log=lambda m: None)
