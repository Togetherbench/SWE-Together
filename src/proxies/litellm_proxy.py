"""In-sandbox LiteLLM-compat reverse proxy launcher.

Used by `user_enabled_{claude_code,mini_swe_agent,opencode}.py` to spin up the
`localhost:4210` proxy that translates an Anthropic-compat client (CC, LiteLLM,
opencode's anthropic provider) onto a real upstream like MiniMax, GLM, ARK,
DeepSeek, or OpenRouter.

The proxy itself is a stdlib http.server that:
  - Reads `LITELLM_PROXY_MODEL` / `PROXY_TARGET_URL` / `PROXY_API_KEY` / etc.
    from the env that `src/run_eval.py:build_agent_env` already injected.
  - Rewrites the `model` field in POST bodies to the real target.
  - Streams SSE chunks via Transfer-Encoding: chunked (CC's parser requires
    real streaming, not buffered Content-Length).
  - Has a fallback path to OpenRouter on 429 (and ARK Bearer auth detection).
  - z.ai silent-throttle detection + retry.

Behaviour matches what `user_enabled_claude_code.py` shipped historically;
extracting here so mini-swe-agent + opencode can use the same proxy and route
`minimaxd/`, `glmd/`, `ark/`, `deepseek/`, etc. without each wrapper duplicating
~280 lines of proxy-script generation.

Usage:

    from proxies.litellm_proxy import launch_litellm_proxy

    async def setup(self, environment):
        await self._inner.setup(environment)
        await launch_litellm_proxy(environment, self.logs_dir)
        # … rest of setup
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)


def _proxy_script_source(*, proxy_port: str, target_url: str, proxy_api_key: str,
                         proxy_model: str, is_openrouter_target: bool,
                         fallback_url: str, fallback_key: str,
                         fallback_model: str) -> str:
    """Generate the proxy.py source from per-trial config.

    Kept verbatim from `user_enabled_claude_code.py`'s historical inline
    string so behaviour is identical across all callers — the only change is
    that the format-string substitutions now come from helper args instead
    of being inlined in the caller. Any future tuning to the proxy (e.g.
    new fallback strategies, more provider quirks) should happen here.
    """
    return f'''#!/usr/bin/env python3
"""Reverse proxy: remaps model, forwards to target API, falls back to OpenRouter on 429."""
import http.server, urllib.request, ssl, json, sys, threading, time

TARGET = "{target_url}"
PORT = {proxy_port}
API_KEY = "{proxy_api_key}"
REMAP_MODEL = "{proxy_model}"
IS_OPENROUTER = {is_openrouter_target}

FALLBACK_URL = "{fallback_url}"
FALLBACK_KEY = "{fallback_key}"
FALLBACK_MODEL = "{fallback_model}"
MAX_RETRIES = 2
RETRY_DELAY = 5
UPSTREAM_TIMEOUT = 600

class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _build_request(self, url, body, is_or):
        is_anthropic_route = REMAP_MODEL.startswith("anthropic/")
        is_zai_route = REMAP_MODEL.startswith("z-ai/")
        strip_beta = is_or and not is_anthropic_route and not is_zai_route
        is_ark = "volces.com" in TARGET
        headers = {{}}
        for k, v in self.headers.items():
            k_lower = k.lower()
            # accept-encoding: NEVER forward. litellm/httpx advertises gzip;
            # MiniMax compresses non-streaming JSON bodies; we strip the
            # content-encoding RESPONSE header below but stream the raw
            # (compressed) bytes — the client then dies with "'utf-8' codec
            # can't decode byte 0x8b in position 1" (gzip magic) and the
            # whole agent turn fails. 71% of mini_mm27 lite70 trials zeroed
            # this way (2026-06-05). Force identity so upstream never
            # compresses. Streaming SSE (claude-code, opencode) was immune —
            # event-streams don't get gzipped — which is why this hid for
            # months.
            if k_lower in ("host", "content-length", "accept-encoding"):
                continue
            if strip_beta and k_lower == "anthropic-beta":
                continue
            headers[k] = v
        headers["Accept-Encoding"] = "identity"
        if is_or:
            headers["Authorization"] = f"Bearer {{FALLBACK_KEY}}"
            headers["HTTP-Referer"] = "https://togetherbench.com"
            headers["X-Title"] = "togetherbench-eval"
            for h in ("x-api-key", "X-Api-Key"):
                headers.pop(h, None)
        elif is_ark:
            headers["Authorization"] = f"Bearer {{API_KEY}}"
            for h in ("x-api-key", "X-Api-Key"):
                headers.pop(h, None)
        else:
            headers["x-api-key"] = API_KEY
        return urllib.request.Request(url, data=body, headers=headers, method="POST")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(length)

        body_primary = raw_body
        if REMAP_MODEL:
            try:
                data = json.loads(raw_body)
                data["model"] = REMAP_MODEL
                if IS_OPENROUTER and REMAP_MODEL.startswith("z-ai/"):
                    data["provider"] = {{"only": ["z-ai"]}}
                body_primary = json.dumps(data).encode()
            except (json.JSONDecodeError, KeyError):
                pass

        url = TARGET + self.path
        ctx = ssl.create_default_context()

        for attempt in range(MAX_RETRIES + 1):
            req = self._build_request(url, body_primary, IS_OPENROUTER)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=UPSTREAM_TIMEOUT) as resp:
                    first_chunk = resp.read1(8192)
                    if (b"event: error" in first_chunk
                            and (b'"code":"1302"' in first_chunk
                                 or b"Rate limit" in first_chunk
                                 or b"rate limit" in first_chunk)):
                        if attempt < MAX_RETRIES:
                            print(f"[proxy] z.ai silent throttle (attempt {{attempt+1}}/{{MAX_RETRIES+1}}), retrying in {{RETRY_DELAY}}s...", flush=True)
                            time.sleep(RETRY_DELAY)
                            continue
                        elif FALLBACK_URL and FALLBACK_MODEL:
                            print(f"[proxy] z.ai silent throttle exhausted, falling back to OpenRouter/{{FALLBACK_MODEL}}", flush=True)
                            break
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        if k.lower() in ("content-encoding", "content-length", "transfer-encoding"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    if first_chunk:
                        self.wfile.write(f"{{len(first_chunk):x}}\\r\\n".encode() + first_chunk + b"\\r\\n")
                        self.wfile.flush()
                    while True:
                        chunk = resp.read1(8192)
                        if not chunk:
                            self.wfile.write(b"0\\r\\n\\r\\n")
                            break
                        self.wfile.write(f"{{len(chunk):x}}\\r\\n".encode() + chunk + b"\\r\\n")
                        self.wfile.flush()
                    return
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < MAX_RETRIES:
                    print(f"[proxy] 429 from primary (attempt {{attempt+1}}), retrying in {{RETRY_DELAY}}s...", flush=True)
                    e.read()
                    time.sleep(RETRY_DELAY)
                    continue
                elif e.code == 429 and FALLBACK_URL and FALLBACK_MODEL:
                    print(f"[proxy] 429 from primary, falling back to OpenRouter/{{FALLBACK_MODEL}}", flush=True)
                    e.read()
                    break
                else:
                    resp_body = e.read()
                    self.send_response(e.code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(resp_body)))
                    self.end_headers()
                    self.wfile.write(resp_body)
                    return
            except Exception as e:
                err = json.dumps({{"error": {{"message": str(e), "type": "proxy_error"}}}}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
                return

        if FALLBACK_URL and FALLBACK_MODEL:
            try:
                data = json.loads(raw_body)
                data["model"] = FALLBACK_MODEL
                body_fb = json.dumps(data).encode()
            except:
                body_fb = raw_body
            fb_url = FALLBACK_URL + self.path
            req = self._build_request(fb_url, body_fb, True)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=UPSTREAM_TIMEOUT) as resp:
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        if k.lower() in ("content-encoding", "content-length", "transfer-encoding"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    while True:
                        chunk = resp.read1(8192)
                        if not chunk:
                            self.wfile.write(b"0\\r\\n\\r\\n")
                            break
                        self.wfile.write(f"{{len(chunk):x}}\\r\\n".encode() + chunk + b"\\r\\n")
                        self.wfile.flush()
                    return
            except urllib.error.HTTPError as e:
                resp_body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)
            except Exception as e:
                err = json.dumps({{"error": {{"message": str(e), "type": "fallback_error"}}}}).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            body = b'{{"status":"ok"}}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        pass

server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Proxy)
server.daemon_threads = True
print(f"Proxy listening on port {{PORT}}")
server.serve_forever()
'''


async def launch_litellm_proxy(environment: Any, logs_dir: Path) -> bool:
    """Launch the LiteLLM-compat proxy in the sandbox when LITELLM_PROXY_MODEL
    is set. Returns True iff the proxy started AND responded to /health.

    No-op when LITELLM_PROXY_MODEL is unset (caller uses native upstream).
    Safe to call from any wrapper's setup() — the env-var gate makes it a
    cheap pass-through for direct-Anthropic runs.
    """
    proxy_model = os.environ.get("LITELLM_PROXY_MODEL")
    if not proxy_model:
        return False

    proxy_port = os.environ.get("LITELLM_PROXY_PORT", "4210")
    target_url = os.environ.get("PROXY_TARGET_URL", "https://openrouter.ai/api")
    proxy_api_key = os.environ.get("PROXY_API_KEY") or os.environ.get("OPENROUTER_API_KEY", "")
    is_openrouter_target = "openrouter" in target_url
    fallback_url = os.environ.get("PROXY_FALLBACK_URL", "")
    fallback_key = os.environ.get("PROXY_FALLBACK_KEY", "")
    fallback_model = os.environ.get("PROXY_FALLBACK_MODEL", "")

    log.info(
        "Starting LiteLLM proxy in sandbox: model=%s port=%s target=%s fallback=%s",
        proxy_model, proxy_port, target_url, fallback_url or "none",
    )

    proxy_script = _proxy_script_source(
        proxy_port=proxy_port, target_url=target_url,
        proxy_api_key=proxy_api_key, proxy_model=proxy_model,
        is_openrouter_target=is_openrouter_target,
        fallback_url=fallback_url, fallback_key=fallback_key,
        fallback_model=fallback_model,
    )

    proxy_path = logs_dir / "model_proxy.py"
    proxy_path.write_text(proxy_script)
    await environment.upload_file(
        source_path=proxy_path, target_path="/tmp/model_proxy.py",
    )

    setup_cmd = (
        f"nohup python3 /tmp/model_proxy.py > /tmp/proxy.log 2>&1 & "
        f"for i in $(seq 1 15); do "
        f"  sleep 1; "
        f"  curl -s http://localhost:{proxy_port}/health > /dev/null 2>&1 && "
        f"  echo 'Proxy ready on port {proxy_port}' && exit 0; "
        f"done; "
        f"echo 'WARNING: proxy not healthy after 15s' >&2; "
        f"cat /tmp/proxy.log >&2; exit 1"
    )
    result = await environment.exec(command=setup_cmd)
    if result.return_code != 0:
        log.warning("LiteLLM proxy start failed: %s", result.stderr or result.stdout)
        return False
    log.info("LiteLLM proxy started successfully on port %s", proxy_port)
    return True


# ──────────────────────────────────────────────────────────────────────
# Model-name remap (Harbor's validator rejects our `minimaxd/`, `glmd/`,
# `ark/` etc. prefixes because they're not in PROVIDER_MODEL_NAMES).
# Wrappers that bake in a Harbor agent (mini-swe-agent, opencode) call
# `mask_proxied_model_name()` BEFORE constructing the inner agent so the
# Harbor validator sees a placeholder it accepts. The proxy then rewrites
# the model field at the network layer (build_agent_env already wired the
# real target into PROXY_TARGET_URL + LITELLM_PROXY_MODEL).
# ──────────────────────────────────────────────────────────────────────

# Provider prefixes that route through our in-sandbox proxy. Anything in
# this list gets masked to a Harbor-recognized placeholder for the inner
# agent; the proxy handles the real routing.
PROXIED_PROVIDER_PREFIXES: tuple[str, ...] = (
    "minimaxd/",
    "glmd/",
    "ark/",
    "fireworks/",
    # NOTE: openrouter/ and deepseek/ removed — both are Harbor-recognized
    # providers (see external/harbor/.../agents/utils.py PROVIDER_API_KEY_VARS)
    # that LiteLLM, Harbor, and opencode all route natively via OPENROUTER_API_KEY
    # / DEEPSEEK_API_KEY. Masking them produced "anthropic/claude-sonnet-4-6",
    # which LiteLLM's anthropic provider dispatched to api.anthropic.com (it
    # reads ANTHROPIC_API_BASE, NOT ANTHROPIC_BASE_URL — so the proxy at
    # localhost:4210 was bypassed) → 401 invalid x-api-key on every trial.
    # See new29-diverse pilot diagnosis (2026-05-29): same failure mode on
    # mini-Opus pilot10 reruns first surfaced this for openrouter/.
    "chutes/",
    "glm/",
)

# Placeholder model name that Harbor's get_api_key_var_names_from_model_name
# accepts, and that LiteLLM / opencode's anthropic provider know how to dispatch
# (they'll then hit ANTHROPIC_BASE_URL=localhost:4210, where the proxy rewrites
# to the real model).
PROXY_PLACEHOLDER_MODEL = "anthropic/claude-sonnet-4-6"


def mask_proxied_model_name(model_name: str | None) -> str | None:
    """If `model_name` uses one of our proxied prefixes, return the placeholder.
    Otherwise return the input unchanged.

    Use case: `super().__init__(model_name=mask_proxied_model_name(model_name))`
    in user_enabled_{mini_swe_agent,opencode}.UserEnabled* — keeps Harbor's
    model-name validator happy while the proxy does the real routing.
    """
    if not model_name:
        return model_name
    if any(model_name.startswith(p) for p in PROXIED_PROVIDER_PREFIXES):
        return PROXY_PLACEHOLDER_MODEL
    return model_name
