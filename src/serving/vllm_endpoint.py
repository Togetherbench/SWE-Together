"""Consumer side of a self-hosted vLLM server: the handoff file, readiness, the
egress reverse route and the opencode provider block.

The serve job writes ``endpoint.json`` (see :mod:`serving.vllm_server`); trial
jobs resolve it with :func:`load`, wait for the server with :func:`wait_ready`,
and derive from it (a) the relay route the sandbox may use and (b) the provider
entry opencode needs because the model is not in any public catalog.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

from serving.registry import ServingSpec, spec_for_served_name

HANDOFF_NAME = "endpoint.json"
ROUTE_PREFIX = "/vllm/"
CREDENTIAL_ENV = "SWT_VLLM_API_KEY"
#: self-hosted servers may queue a long prefill before the first streamed byte
ROUTE_IDLE_TIMEOUT_S = 1800
ENDPOINT_ENV = ("SWT_VLLM_ENDPOINT", "SWT_VLLM_BASE_URL")
CHAT_PATH = "/v1/chat/completions"
MODELS_PATH = "/v1/models"


@dataclass(frozen=True)
class VllmEndpoint:
    base_url: str  # http://<node>:<port>, no trailing slash, no /v1
    served_model: str
    node: str | None = None
    port: int | None = None
    job_id: str | None = None
    max_model_len: int | None = None
    vllm_version: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def models_url(self) -> str:
        return self.base_url + MODELS_PATH


def _normalise_base_url(url: str) -> str:
    u = urlsplit(url.strip())
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError(f"vLLM endpoint must be an http(s) URL with a host: {url!r}")
    path = u.path.rstrip("/")
    if path.endswith("/v1"):
        path = path[: -len("/v1")]
    return f"{u.scheme}://{u.netloc}{path}"


def read_handoff(path: Path) -> VllmEndpoint:
    data = json.loads(Path(path).read_text())
    if not data.get("base_url") or not data.get("served_model"):
        raise ValueError(f"{path}: handoff needs base_url and served_model")
    u = urlsplit(data["base_url"])
    return VllmEndpoint(
        base_url=_normalise_base_url(data["base_url"]), served_model=data["served_model"],
        node=data.get("node") or u.hostname, port=data.get("port") or u.port,
        job_id=str(data["job_id"]) if data.get("job_id") is not None else None,
        max_model_len=data.get("max_model_len"), vllm_version=data.get("vllm_version"),
    )


def handoff_path(spec: str | Path) -> Path | None:
    """``endpoint.json`` for a handoff file or a serve log dir; ``None`` for URLs."""
    s = str(spec)
    if s.startswith(("http://", "https://")):
        return None
    p = Path(s).expanduser()
    return p / HANDOFF_NAME if p.is_dir() or not p.suffix else p


def load(spec: str | Path | None, served_model: str | None = None) -> VllmEndpoint | None:
    """Resolve an endpoint from a handoff file, a serve log dir, a bare URL, or the
    environment (``SWT_VLLM_ENDPOINT`` path/dir, ``SWT_VLLM_BASE_URL`` URL). Returns
    ``None`` when nothing is configured; a URL needs ``served_model``.
    """
    if spec is None:
        for var in ENDPOINT_ENV:
            if os.environ.get(var):
                spec = os.environ[var]
                break
    if spec is None:
        return None
    hp = handoff_path(spec)
    if hp is None:
        if not served_model:
            raise ValueError("a bare endpoint URL needs the served model name")
        base = _normalise_base_url(str(spec))
        u = urlsplit(base)
        return VllmEndpoint(base_url=base, served_model=served_model, node=u.hostname, port=u.port)
    if not hp.exists():
        return None
    return read_handoff(hp)


def probe(endpoint: VllmEndpoint, api_key: str | None = None, timeout: float = 10.0) -> list[str]:
    """Served model ids from ``GET /v1/models`` (raises on any failure)."""
    req = urllib.request.Request(endpoint.models_url, headers={"Accept": "application/json"})
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - internal, host-configured URL
        data = json.loads(resp.read().decode("utf-8"))
    return [m.get("id") for m in data.get("data", []) if isinstance(m, dict)]


def _slurm_job_alive(job_id: str) -> bool | None:
    try:
        out = subprocess.run(["squeue", "-h", "-j", job_id, "-o", "%T"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return bool(out.stdout.strip())


def wait_ready(spec: str | Path | None, served_model: str, *, timeout_s: float = 3600, poll_s: float = 15,
               api_key: str | None = None, probe_fn: Callable[[VllmEndpoint, str | None], list[str]] | None = None,
               job_alive: Callable[[str], bool | None] | None = None,
               log: Callable[[str], None] | None = None) -> VllmEndpoint:
    """Block until the handoff exists and the server lists ``served_model``.

    Slurm's ``after:`` dependency fires when the serve job *starts*; loading a
    large model takes much longer, so the trial job waits here. If the serve job
    disappears from the queue the wait fails immediately.
    """
    probe_fn = probe_fn or probe
    job_alive = job_alive or _slurm_job_alive
    say = log or (lambda m: None)
    deadline = time.monotonic() + timeout_s
    last = ""
    while True:
        ep = load(spec, served_model)
        if ep is None:
            msg = f"waiting for vLLM handoff ({spec or 'env'})"
        else:
            try:
                served = probe_fn(ep, api_key)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                served, msg = None, f"vLLM at {ep.base_url} not ready: {exc.__class__.__name__}"
            if served is not None:
                if served_model in served:
                    say(f"vLLM ready at {ep.base_url}: serving {served_model}")
                    return ep
                raise SystemExit(f"vLLM at {ep.base_url} serves {served}, not {served_model!r}")
            if ep.job_id and job_alive(ep.job_id) is False:
                raise SystemExit(f"serve job {ep.job_id} is no longer in the queue; {msg}")
        if msg != last:
            say(msg)
            last = msg
        if time.monotonic() >= deadline:
            raise SystemExit(f"timed out after {timeout_s:.0f}s: {msg}")
        time.sleep(poll_s)


def reverse_route(endpoint: VllmEndpoint, credential_env: str | None = CREDENTIAL_ENV):
    """The relay route for this server (imports the proxy lazily: the serve env lacks it)."""
    from proxies.egress_proxy import ReverseRoute
    return ReverseRoute.for_upstream(
        ROUTE_PREFIX, endpoint.base_url, credential_env=credential_env,
        endpoints=frozenset({("POST", CHAT_PATH), ("GET", MODELS_PATH)}),
        llm_paths=frozenset({CHAT_PATH}), idle_timeout_s=ROUTE_IDLE_TIMEOUT_S,
    )


def opencode_provider(served_model: str, *, base_url: str, api_key: str,
                      max_model_len: int | None = None, spec: ServingSpec | None = None) -> dict:
    """opencode ``provider.vllm`` block for a self-hosted model.

    Everything is explicit because models.dev has no entry: without ``limit``
    opencode cannot plan compaction, without ``tool_call`` tools are disabled, and
    the ``variants`` are what ``--variant=<effort>`` selects — each sends
    ``reasoning_effort`` (``reasoningEffort`` in @ai-sdk/openai-compatible terms).
    """
    spec = spec or spec_for_served_name(served_model)
    if spec is None:
        raise SystemExit(f"no serving recipe for served model {served_model!r}")
    context = min(spec.context, max_model_len) if max_model_len else spec.context
    model: dict = {
        "name": served_model,
        "reasoning": True,
        "tool_call": True,
        "limit": {"context": context, "output": min(spec.output, context)},
        "variants": {eff: {"reasoningEffort": eff} for eff in spec.efforts},
    }
    if spec.chat_template_kwargs:
        model["options"] = {"chat_template_kwargs": dict(spec.chat_template_kwargs)}
    return {
        "npm": "@ai-sdk/openai-compatible",
        "name": "vLLM (self-hosted)",
        "options": {"baseURL": base_url, "apiKey": api_key},
        "models": {served_model: model},
    }
