"""Unit tests for the sandbox egress policy and the host-side egress proxy."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))

import egress_policy as ep  # noqa: E402


@pytest.fixture
def policy():
    # an OpenRouter run: no LLM host reachable by CONNECT; catalog + registries only
    return ep.default_policy(aws_region="us-west-2", llm_backend="openrouter", model="openrouter/x-ai/grok-4.7")


@pytest.fixture
def bedrock_policy():
    return ep.default_policy(aws_region="us-west-2", llm_backend="bedrock", model="bedrock/global.xai.grok-4.6")


# ── allow / deny decisions ─────────────────────────────────────────────────

@pytest.mark.parametrize("host,group", [
    ("models.dev", "catalog"),
    ("MODELS.OPENCODE.AI.", "catalog"),
    ("pypi.org", "registries"),
    ("files.pythonhosted.org", "registries"),
    ("registry.npmjs.org", "registries"),
    ("static.crates.io", "registries"),
    ("archive.ubuntu.com", "registries"),
    ("deb.nodesource.com", "registries"),
])
def test_allowlisted_hosts(policy, host, group):
    d = policy.decide(host)
    assert d.allowed and d.group == group, d


@pytest.mark.parametrize("host,why", [
    ("github.com", "github.com"),
    ("api.github.com", "github.com"),
    ("codeload.github.com", "github.com"),
    ("raw.githubusercontent.com", "githubusercontent.com"),
    ("patch-diff.githubusercontent.com", "githubusercontent.com"),
    ("cdn.jsdelivr.net", "CDN mirror"),
    ("gh-proxy.com", "GitHub proxy"),
    ("ghfast.top", "GitHub proxy"),
    ("r.jina.ai", "read-through"),
    ("proxy.golang.org", "Go module proxy"),
    ("sum.golang.org", "checksum"),
    ("huggingface.co", "model hub"),
    ("hf-mirror.com", "model hub"),
    ("cloudflare-dns.com", "DNS-over-HTTPS"),
    ("dns.google", "DNS-over-HTTPS"),
    ("html.duckduckgo.com", "web search"),
    ("www.bing.com", "web search"),
    ("www.google.com", "web search"),
    ("web.archive.org", "archive"),
    ("sourcegraph.com", "code search"),
])
def test_leak_vectors_denied(policy, host, why):
    d = policy.decide(host)
    assert not d.allowed
    assert d.reason.startswith("deny:") and why.lower() in d.reason.lower(), d


@pytest.mark.parametrize("host", [
    "example.com", "bedrock-runtime.eu-west-1.amazonaws.com", "s3.amazonaws.com",
    "npmjs.org", "evil-pypi.org", "pypi.org.evil.com", "storage.googleapis.com",
    # an OpenRouter run reaches its model only via the pinned route, never by CONNECT
    "openrouter.ai", "api.openai.com", "api.groq.com", "generativelanguage.googleapis.com",
    "bedrock-runtime.us-west-2.amazonaws.com",
])
def test_unknown_hosts_denied_by_default(policy, host):
    d = policy.decide(host)
    assert not d.allowed and d.reason == "deny:not in allowlist", d


@pytest.mark.parametrize("host", ["140.82.116.3", "[2606:50c0:8000::153]", "2606:50c0:8000::153", "127.0.0.1"])
def test_ip_literals_denied(policy, host):
    d = policy.decide(host)
    assert not d.allowed and "ip literal" in d.reason, d


@pytest.mark.parametrize("host", ["", "   ", "bad_host!", "-leading.com", "a..b"])
def test_garbage_denied(policy, host):
    assert not policy.decide(host).allowed


def test_suffix_match_does_not_leak_sideways(bedrock_policy):
    # a suffix rule matches the host and its subdomains only
    assert bedrock_policy.decide("bedrock-runtime.us-west-2.amazonaws.com").allowed
    assert bedrock_policy.decide("x.bedrock-runtime.us-west-2.amazonaws.com").allowed
    assert not bedrock_policy.decide("bedrock-runtime.us-west-2.amazonaws.com.evil.io").allowed
    assert not bedrock_policy.decide("openrouter.ai").allowed


def test_llm_hosts_follow_the_backend():
    pol = ep.default_policy(aws_region="eu-central-1", llm_backend="bedrock")
    assert pol.decide("bedrock-runtime.eu-central-1.amazonaws.com").allowed
    assert not pol.decide("bedrock-runtime.ap-south-1.amazonaws.com").allowed
    native = ep.default_policy(llm_backend="native", model="anthropic/claude-opus-4-6")
    assert native.decide("api.anthropic.com").allowed
    assert not native.decide("api.openai.com").allowed and not native.decide("openrouter.ai").allowed
    orr = ep.default_policy(llm_backend="openrouter", model="openrouter/x-ai/grok-4.7")
    assert not orr.decide("openrouter.ai").allowed and not orr.decide("api.anthropic.com").allowed


# ── per-task additions ─────────────────────────────────────────────────────

def test_task_allow_extends_policy(policy):
    pol = policy.with_task_allow(["download.pytorch.org", "Download.PyTorch.org"])
    d = pol.decide("download.pytorch.org")
    assert d.allowed and d.reason == "allow:task"
    assert pol.task_allow == frozenset({"download.pytorch.org"})


@pytest.mark.parametrize("bad", [
    ["github.com"], ["api.github.com"], ["cdn.jsdelivr.net"], ["proxy.golang.org"],
    ["mirror.ghproxy.com"], ["*.example.com"], ["example.com/path"], ["1.2.3.4"],
    ["host:443"], [42],
])
def test_task_allow_rejects_leak_vectors_and_junk(policy, bad):
    with pytest.raises(ep.TaskAllowError):
        policy.with_task_allow(bad)


def test_task_allow_from_toml(tmp_path):
    (tmp_path / "task.toml").write_text('version = "1.0"\n[network]\nallow = ["download.pytorch.org"]\n')
    assert ep.task_allow_from_toml(tmp_path) == ["download.pytorch.org"]
    pol = ep.policy_for_task(tmp_path, aws_region="us-west-2")
    assert pol.decide("download.pytorch.org").allowed
    assert pol.decide("github.com").allowed is False


def test_task_allow_absent(tmp_path):
    (tmp_path / "task.toml").write_text('version = "1.0"\n[environment]\nallow_internet = true\n')
    assert ep.task_allow_from_toml(tmp_path) == []
    assert ep.policy_for_task(tmp_path).task_allow == frozenset()
    assert ep.policy_for_task(tmp_path / "missing").task_allow == frozenset()


def test_task_allow_toml_leak_vector_rejected(tmp_path):
    (tmp_path / "task.toml").write_text('[network]\nallow = ["raw.githubusercontent.com"]\n')
    with pytest.raises(ep.TaskAllowError):
        ep.policy_for_task(tmp_path)


# ── identity / serialisation ───────────────────────────────────────────────

def test_digest_is_stable_and_sensitive(policy):
    same = ep.default_policy(aws_region="us-west-2", llm_backend="openrouter", model="openrouter/x-ai/grok-4.7")
    assert policy.digest() == same.digest()
    assert policy.digest() != ep.default_policy(aws_region="us-east-1", llm_backend="bedrock").digest()
    assert policy.digest() != policy.with_task_allow(["download.pytorch.org"]).digest()


def test_write(tmp_path, policy):
    out = tmp_path / "egress_policy.json"
    policy.write(out)
    import json
    d = json.loads(out.read_text())
    assert d["version"] == ep.POLICY_VERSION
    assert d["digest"] == policy.digest()
    assert d["leak_vectors"]["proxy.golang.org"].startswith("Go module proxy")
    assert d["allow_hosts"]["pypi.org"] == "registries" and "openrouter.ai" not in d["allow_hosts"]


# ── sandbox env ────────────────────────────────────────────────────────────

def test_sandbox_env_routes_via_relay_and_disables_goproxy():
    env = ep.sandbox_env()
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"):
        assert env[k] == f"http://{ep.RELAY_HOST}:{ep.RELAY_PORT}"
    assert "127.0.0.1" in env["NO_PROXY"] and "localhost" in env["NO_PROXY"]
    assert env["GOPROXY"] == "off"
    assert env["GOSUMDB"] == "off"


# ═══════════════════════════════════════════════════════════════════════════
# egress proxy
# ═══════════════════════════════════════════════════════════════════════════
import http.server  # noqa: E402
import time  # noqa: E402
import json  # noqa: E402
import socket  # noqa: E402
import threading  # noqa: E402

from proxies import egress_proxy as xp  # noqa: E402


def test_parse_request_head_and_destination():
    head = b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\nProxy-Connection: keep-alive\r\n\r\n"
    method, target, headers = xp.parse_request_head(head)
    assert (method, target) == ("CONNECT", "github.com:443")
    assert ("Host", "github.com:443") in headers
    assert xp.destination(method, target, headers) == ("github.com", 443, None, "")

    method, target, headers = xp.parse_request_head(b"GET http://pypi.org/simple/six/ HTTP/1.1\r\nHost: pypi.org\r\n\r\n")
    assert xp.destination(method, target, headers) == ("pypi.org", 80, None, "/simple/six/")
    assert xp.destination("GET", "https://pypi.org:8443", []) == ("pypi.org", 8443, None, "/")

    # origin-form under a reverse route
    assert xp.destination("POST", "/openrouter/api/v1/chat/completions", []) == (
        "openrouter.ai", 443, "/openrouter/", "/api/v1/chat/completions")


@pytest.mark.parametrize("head", [
    b"GARBAGE\r\n\r\n",
    b"GET /not-a-route HTTP/1.1\r\n\r\n",
    b"CONNECT nohostport HTTP/1.1\r\n\r\n",
    b"GET ftp://x/ HTTP/1.1\r\n\r\n",
])
def test_bad_requests_rejected(head):
    with pytest.raises(ValueError):
        m, t, h = xp.parse_request_head(head)
        xp.destination(m, t, h)


def test_rebuild_head_injects_auth_and_normalises():
    headers = [("Host", "127.0.0.1:3128"), ("Authorization", "Bearer swt-placeholder"),
               ("Proxy-Connection", "keep-alive"), ("Connection", "keep-alive"),
               ("Content-Type", "application/json"), ("Content-Length", "2")]
    out = xp._rebuild_head("POST", "/api/v1/chat/completions", headers, "openrouter.ai", "sk-real").decode()
    lines = out.split("\r\n")
    assert lines[0] == "POST /api/v1/chat/completions HTTP/1.1"
    assert "Host: openrouter.ai" in lines
    assert "Authorization: Bearer sk-real" in lines
    assert "Authorization: Bearer swt-placeholder" not in out
    assert "Proxy-Connection" not in out and "keep-alive" not in out
    assert lines[-3] == "Connection: close" and out.endswith("\r\n\r\n")
    assert "Content-Length: 2" in lines


def test_deny_response_shape(policy):
    resp = xp._deny_response("github.com", "deny:github.com (task source repository)", policy.digest())
    head, body = resp.split(b"\r\n\r\n", 1)
    assert head.startswith(b"HTTP/1.1 403 Forbidden")
    assert b"X-Egress-Policy: denied" in head
    d = json.loads(body)
    assert d["host"] == "github.com" and "task source repository" in d["reason"]
    assert d["policy"].startswith(f"swt-egress/{ep.POLICY_VERSION}/")


# ── live proxy over a unix socket ──────────────────────────────────────────

class _Upstream(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        got = len(self.rfile.read(n))
        body = json.dumps({"got": got}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        body = json.dumps({"path": self.path, "host": self.headers.get("Host"),
                           "auth": self.headers.get("Authorization")}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # silence
        pass


@pytest.fixture
def upstream():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Upstream)
    t = threading.Thread(target=srv.serve_forever, daemon=True); t.start()
    yield srv.server_address[1]
    srv.shutdown()


@pytest.fixture
def proxy(tmp_path, upstream):
    # "localhost" is a stand-in for an allowlisted registry; everything else is default policy.
    def resolver(task_dir):
        pol = ep.default_policy("us-west-2", llm_backend="openrouter", model="openrouter/x-ai/grok-4.7")
        return ep.EgressPolicy({**pol.allow_hosts, "localhost": "registries"}, pol.allow_suffixes)
    p = xp.EgressProxy(tmp_path / "egress.sock", policy_resolver=resolver, credentials={},
                       fallback_log=tmp_path / "fallback.log", llm_models={"x-ai/grok-4.7"})
    p.start()
    yield p
    p.stop()


def _via_proxy(sock_path, raw: bytes, preamble: dict | None = None, read_all=True) -> bytes:
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(str(sock_path))
    if preamble is not None:
        # the real relay writes the preamble first and pipes the request afterwards,
        # so the proxy's first recv() sees the preamble alone
        s.sendall(xp.PREAMBLE_MAGIC + json.dumps(preamble).encode() + b"\n")
        time.sleep(0.05)
    s.sendall(raw)
    out = b""
    try:
        while True:
            d = s.recv(65536)
            if not d:
                break
            out += d
            if not read_all:
                break
    except socket.timeout:
        pass
    s.close()
    return out


def test_allowed_absolute_uri_is_forwarded(proxy, upstream, tmp_path):
    logp = tmp_path / "trial" / "agent" / "egress.log"
    resp = _via_proxy(proxy.sock_path,
                      f"GET http://localhost:{upstream}/simple/six/ HTTP/1.1\r\nHost: localhost:{upstream}\r\n\r\n".encode(),
                      preamble={"trial": "t1", "log": str(logp)})
    assert resp.startswith(b"HTTP/1.0 200") or resp.startswith(b"HTTP/1.1 200")
    body = json.loads(resp.split(b"\r\n\r\n", 1)[1])
    assert body["path"] == "/simple/six/" and body["host"] == "localhost"
    rec = json.loads(logp.read_text().splitlines()[-1])
    assert rec["trial"] == "t1" and rec["decision"] == "allow" and rec["host"] == "localhost"
    assert rec["reason"] == "allow:registries" and rec["bytes_down"] > 0


def test_denied_host_gets_403_and_is_logged(proxy, tmp_path):
    logp = tmp_path / "t2.log"
    resp = _via_proxy(proxy.sock_path, b"CONNECT cdn.jsdelivr.net:443 HTTP/1.1\r\nHost: cdn.jsdelivr.net:443\r\n\r\n",
                      preamble={"trial": "t2", "log": str(logp)})
    assert resp.startswith(b"HTTP/1.1 403")
    assert b"X-Egress-Policy: denied" in resp
    d = json.loads(resp.split(b"\r\n\r\n", 1)[1])
    assert d["host"] == "cdn.jsdelivr.net" and "CDN mirror" in d["reason"]
    rec = json.loads(logp.read_text().splitlines()[-1])
    assert rec["decision"] == "deny" and rec["method"] == "CONNECT"


def test_ip_literal_connect_denied(proxy):
    resp = _via_proxy(proxy.sock_path, b"CONNECT 140.82.116.3:443 HTTP/1.1\r\n\r\n")
    assert resp.startswith(b"HTTP/1.1 403") and b"ip literal" in resp


def test_connect_tunnel_pipes_bytes(proxy, upstream):
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(str(proxy.sock_path))
    s.sendall(f"CONNECT localhost:{upstream} HTTP/1.1\r\nHost: localhost:{upstream}\r\n\r\n".encode())
    assert s.recv(1024).startswith(b"HTTP/1.1 200 Connection Established")
    s.sendall(b"GET /tunnelled HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    out = b""
    while True:
        d = s.recv(65536)
        if not d:
            break
        out += d
    s.close()
    assert b'"path": "/tunnelled"' in out


def test_no_preamble_logs_to_fallback(proxy, tmp_path):
    _via_proxy(proxy.sock_path, b"CONNECT github.com:443 HTTP/1.1\r\n\r\n")
    rec = json.loads((tmp_path / "fallback.log").read_text().splitlines()[-1])
    assert rec["trial"] == "-" and rec["decision"] == "deny"


def test_malformed_request_gets_400(proxy):
    resp = _via_proxy(proxy.sock_path, b"GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n")
    assert resp.startswith(b"HTTP/1.1 400")


def _online() -> bool:
    try:
        socket.create_connection(("openrouter.ai", 443), timeout=5).close()
        return True
    except OSError:
        return False


@pytest.mark.skipif(not _online(), reason="needs network to openrouter.ai")
def test_reverse_route_to_openrouter_live(tmp_path):
    p = xp.EgressProxy(tmp_path / "egress.sock", credentials={"OPENROUTER_API_KEY": "sk-or-v1-not-a-real-key"},
                       llm_backend="openrouter", model="openrouter/x-ai/grok-4.7", llm_models={"x-ai/grok-4.7"})
    p.start()
    try:
        resp = _via_proxy(p.sock_path, b"GET /openrouter/api/v1/models HTTP/1.1\r\nHost: 127.0.0.1:3128\r\n\r\n")
    finally:
        p.stop()
    head = resp.split(b"\r\n\r\n", 1)[0]
    assert head.startswith(b"HTTP/1.1 200"), head[:200]
    assert b'"data"' in resp  # the public models list came back through the TLS reverse route


def test_relay_script_renders_and_argv(tmp_path):
    script = xp.write_relay_script(tmp_path / "relay.py")
    assert script.stat().st_mode & 0o111
    meta = xp.write_relay_meta(tmp_path / "m.json", {"trial": "x"})
    argv = xp.relay_argv("python3", script, tmp_path / "egress.sock", meta)
    assert argv[0] == "python3" and argv[2].endswith("egress.sock")
    assert argv[3:5] == [ep.RELAY_HOST, str(ep.RELAY_PORT)]
    assert argv[5] == str(meta)
    compile(script.read_text(), str(script), "exec")


# ═══════════════════════════════════════════════════════════════════════════
# infra sentinel: egress integrity
# ═══════════════════════════════════════════════════════════════════════════
import eval_infra_sentinel as sentinel  # noqa: E402


def _trial(tmp_path, *, patch_bytes=5000, selftest=None, log_lines=None) -> Path:
    t = tmp_path / "task__abc123"
    (t / "agent").mkdir(parents=True)
    (t / "agent" / "final.patch").write_text("diff --git a/x b/x\n" + "+x\n" * (patch_bytes // 3))
    if selftest is not None:
        (t / "agent" / sentinel.EGRESS_SELFTEST_FILE).write_text(json.dumps(selftest))
    if log_lines is not None:
        (t / "agent" / sentinel.EGRESS_LOG_FILE).write_text("\n".join(json.dumps(l) for l in log_lines) + "\n")
    return t


def test_sentinel_legacy_trial_without_egress_artifacts_is_untouched(tmp_path):
    v = sentinel.classify_trial(_trial(tmp_path))
    assert v.status == "ok"
    assert sentinel.egress_log_summary(_trial(tmp_path / "b")) is None


def test_sentinel_flags_failed_selftest_even_with_real_patch(tmp_path):
    t = _trial(tmp_path, selftest={"ok": False, "checks": {"denied_hosts_get_403": False, "allowed_host_reachable": True},
                                   "policy_version": 1})
    v = sentinel.classify_trial(t)
    assert v.status == "infra_failed" and v.reason == "egress_policy_unenforced"
    assert "denied_hosts_get_403" in v.detail
    assert v.evidence["policy_version"] == 1


def test_sentinel_passing_selftest_and_clean_log_is_ok(tmp_path):
    t = _trial(tmp_path, selftest={"ok": True, "checks": {}}, log_lines=[
        {"host": "openrouter.ai", "decision": "allow"},
        {"host": "pypi.org", "decision": "allow"},
        {"host": "github.com", "decision": "deny"},
        {"host": "cdn.jsdelivr.net", "decision": "deny"},
        {"host": "cdn.jsdelivr.net", "decision": "deny"},
    ])
    assert sentinel.classify_trial(t).status == "ok"
    s = sentinel.egress_log_summary(t)
    assert s["allowed"] == 2 and s["denied"] == 3 and s["denied_hosts"]["cdn.jsdelivr.net"] == 2


def test_sentinel_flags_allowed_leak_vector(tmp_path):
    t = _trial(tmp_path, selftest={"ok": True, "checks": {}}, log_lines=[
        {"host": "raw.githubusercontent.com", "decision": "allow"},
    ])
    v = sentinel.classify_trial(t)
    assert v.status == "infra_failed" and v.reason == "egress_policy_violation"
    assert v.evidence["allowed_leak_vectors"] == {"raw.githubusercontent.com": 1}


def test_sentinel_denied_attempts_are_not_failures(tmp_path):
    t = _trial(tmp_path, selftest={"ok": True, "checks": {}},
               log_lines=[{"host": "github.com", "decision": "deny"}] * 40)
    assert sentinel.classify_trial(t).status == "ok"


def test_large_post_body_is_not_mistaken_for_a_large_head(proxy, upstream):
    """Regression: a first recv() of a full 64 KiB (small head + big body) tripped the head-size guard."""
    body = b'{"messages":"' + b"a" * 600_000 + b'"}'
    head = (f"POST http://localhost:{upstream}/v1 HTTP/1.1\r\nHost: localhost:{upstream}\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode()
    resp = _via_proxy(proxy.sock_path, head + body, preamble={"trial": "big"})
    assert resp.split(b"\r\n", 1)[0].endswith(b"200 OK"), resp[:200]


def test_oversized_head_still_rejected(proxy):
    head = b"GET http://localhost/ HTTP/1.1\r\nX-Pad: " + b"p" * (xp.MAX_HEAD + 10) + b"\r\n\r\n"
    resp = _via_proxy(proxy.sock_path, head)
    assert resp.startswith(b"HTTP/1.1 400") and b"head too large" in resp


# ── LLM route pinning ─────────────────────────────────────────────────────

def test_check_llm_body_pins_model_and_refuses_web():
    ok = xp.check_llm_body(b'{"model":"x-ai/grok-4.7","messages":[],"tools":[{"type":"function","function":{"name":"bash"}}]}',
                           frozenset({"x-ai/grok-4.7"}))
    assert ok == "x-ai/grok-4.7"
    for body, why in [
        (b'{"model":"google/gemini-2.5-flash:online","messages":[]}', "not pinned"),
        (b'{"model":"x-ai/grok-4.7:online","messages":[]}', "not pinned"),
        (b'{"model":"openai/gpt-4.1-mini","messages":[]}', "not pinned"),
        (b'{"model":"x-ai/grok-4.7","plugins":[{"id":"web"}]}', "plugin"),
        (b'{"model":"x-ai/grok-4.7","web_search_options":{}}', "plugin"),
        (b'{"model":"x-ai/grok-4.7","tools":[{"type":"web_search_preview"}]}', "non-function tool"),
        (b'{"messages":[]}', "no model"),
        (b'not json', "not JSON"),
        (b'[1,2]', "not an object"),
    ]:
        with pytest.raises(xp.LLMRequestDenied, match=why):
            xp.check_llm_body(body, frozenset({"x-ai/grok-4.7"}))
    with pytest.raises(xp.LLMRequestDenied, match="no pinned model"):
        xp.check_llm_body(b'{"model":"x-ai/grok-4.7"}', frozenset())


def _post_route(sock_path, path, body: bytes, extra_headers: str = "") -> bytes:
    head = (f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1:3128\r\nContent-Type: application/json\r\n"
            f"Authorization: Bearer swt-egress-proxy\r\n{extra_headers}Content-Length: {len(body)}\r\n\r\n").encode()
    return _via_proxy(sock_path, head + body, preamble={"trial": "pin"})


def test_route_refuses_foreign_model_before_contacting_upstream(proxy, tmp_path):
    resp = _post_route(proxy.sock_path, "/openrouter/api/v1/chat/completions",
                       b'{"model":"google/gemini-2.5-flash:online","messages":[{"role":"user","content":"x"}]}')
    assert resp.startswith(b"HTTP/1.1 403") and b"not pinned" in resp
    rec = json.loads((tmp_path / "fallback.log").read_text().splitlines()[-1])
    assert rec["decision"] == "deny" and "not pinned" in rec["reason"] and rec["bytes_down"] == 0


def test_route_refuses_unknown_endpoints_and_methods(proxy):
    resp = _via_proxy(proxy.sock_path, b"GET /openrouter/api/v1/key HTTP/1.1\r\nHost: x\r\n\r\n")
    assert resp.startswith(b"HTTP/1.1 403") and b"route endpoint" in resp
    resp = _via_proxy(proxy.sock_path, b"DELETE /openrouter/api/v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
    assert resp.startswith(b"HTTP/1.1 403")
    resp = _post_route(proxy.sock_path, "/openrouter/api/v1/models", b'{"model":"x-ai/grok-4.7"}')
    assert resp.startswith(b"HTTP/1.1 403")


def test_route_requires_content_length(proxy):
    head = (b"POST /openrouter/api/v1/chat/completions HTTP/1.1\r\nHost: x\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n")
    resp = _via_proxy(proxy.sock_path, head + b"0\r\n\r\n")
    assert resp.startswith(b"HTTP/1.1 400") and b"Content-Length" in resp


def test_selftest_includes_pin_check():
    from enroot_backend.netns import evaluate_selftest, selftest_script
    script = selftest_script()
    assert "gemini-2.5-flash:online" in script and "/openrouter/api/v1/models" in script
    good = "allowed=200\npin=403\nregistry_ok=200\nregistry_search=403\n" + "".join(f"denied{i}=403\n" for i in range(4)) + \
           "noproxy_exit=6\nresolve_exit=7\nhttps_proxy=http://127.0.0.1:3128\ngoproxy=off\n"
    assert evaluate_selftest(good)["ok"]
    assert not evaluate_selftest(good.replace("pin=403", "pin=200"))["ok"]


# ── registry path policy ───────────────────────────────────────────────────

def test_registry_decision_table():
    d = ep.DenyPackages(npm=["@mariozechner/pi-coding-agent", "pi-mono"], pypi=["mlx-lm"], crates=["router"])
    deny = lambda h, p: ep.registry_decision(h, "GET", p, d)
    assert "own npm package" in deny("registry.npmjs.org", "/@mariozechner%2fpi-coding-agent")
    assert "own npm package" in deny("registry.npmjs.org", "/@mariozechner/pi-coding-agent/-/pi-coding-agent-0.73.1.tgz")
    assert "own npm package" in deny("registry.yarnpkg.com", "/-/package/@mariozechner%2fpi-coding-agent/dist-tags")
    assert "search" in deny("registry.npmjs.org", "/-/v1/search?text=keywords:pi")
    assert deny("registry.npmjs.org", "/left-pad") is None
    assert deny("registry.npmjs.org", "/left-pad/-/left-pad-1.3.0.tgz") is None
    assert "own PyPI project" in deny("pypi.org", "/simple/MLX_LM/")
    assert "own PyPI project" in deny("pypi.org", "/pypi/mlx.lm/json")
    assert "own PyPI distribution" in deny("files.pythonhosted.org", "/packages/a/b/c/mlx_lm-0.31.0-py3-none-any.whl")
    assert deny("files.pythonhosted.org", "/packages/a/b/c/six-1.17.0-py2.py3-none-any.whl") is None
    assert deny("pypi.org", "/simple/six/") is None
    assert "own crate" in deny("static.crates.io", "/crates/router/router-1.0.0.crate")
    assert "own crate" in deny("index.crates.io", "/ro/ut/router")
    assert deny("index.crates.io", "/se/rd/serde") is None and deny("index.crates.io", "/config.json") is None
    assert "search" in deny("crates.io", "/api/v1/crates?q=router")
    assert deny("archive.ubuntu.com", "/ubuntu/pool/main/r/ripgrep/x.deb") is None
    assert ep.registry_decision("example.com", "GET", "/anything", d) is None
    empty = ep.DenyPackages()
    assert not empty and ep.registry_decision("registry.npmjs.org", "GET", "/pi-mono", empty) is None


def test_deny_packages_roundtrip():
    d = ep.DenyPackages.from_dict({"npm": ["@A/B"], "pypi": ["Foo_Bar.baz"], "crates": ["my_crate"]})
    assert d.npm == {"@a/b"} and d.pypi == {"foo-bar-baz"} and d.crates == {"my-crate"}
    assert ep.DenyPackages.from_dict(d.to_dict()).to_dict() == d.to_dict()


def test_workspace_scanner_script_runs_without_python(tmp_path):
    import subprocess
    (tmp_path / "package.json").write_text(json.dumps({"name": "@scope/root"}))
    (tmp_path / "packages" / "a").mkdir(parents=True)
    (tmp_path / "packages" / "a" / "package.json").write_text('{\n  "name": "pkg-a",\n  "private": true\n}\n')
    (tmp_path / "node_modules" / "left-pad").mkdir(parents=True)
    (tmp_path / "node_modules" / "left-pad" / "package.json").write_text(json.dumps({"name": "left-pad"}))
    (tmp_path / "pyproject.toml").write_text('[project]\nname = "my-py"\n')
    (tmp_path / "setup.py").write_text('from setuptools import setup\nsetup(name="legacy", version="1")\n')
    (tmp_path / "Cargo.toml").write_text("[package]\nname = 'my_crate'\n")
    # plain sh with a PATH that has no python at all
    out = subprocess.run(["sh", "-c", ep.workspace_packages_script(str(tmp_path))], capture_output=True, text=True,
                         env={"PATH": "/usr/bin:/bin"})
    assert "SWT_PKGSCAN_DONE" in out.stdout
    pk = ep.parse_workspace_packages(out.stdout)
    assert set(pk["npm"]) == {"@scope/root", "pkg-a", tmp_path.name}
    assert set(pk["pypi"]) == {"my-py", "legacy", tmp_path.name}
    assert set(pk["crates"]) == {"my_crate", tmp_path.name}


def test_opencode_config_is_rendered_host_side_without_python():
    import subprocess
    from user_agent.agents.user_enabled_opencode import patch_opencode_config, render_opencode_config_command
    cfg = patch_opencode_config({"provider": {"openrouter": {"models": {"x-ai/grok-4.7": {}}}}},
                                using_proxied_provider=False, disallowed_tools="WebFetch,WebSearch",
                                bedrock_region=None, openrouter_base_url="http://127.0.0.1:3128/openrouter/api/v1")
    assert cfg["provider"]["openrouter"]["options"]["baseURL"] == "http://127.0.0.1:3128/openrouter/api/v1"
    assert cfg["provider"]["openrouter"]["models"]["x-ai/grok-4.7"]["variants"]["high"] == {"reasoning": {"effort": "high"}}
    assert cfg["permission"]["tools"] == {"webfetch": "deny", "websearch": "deny"}
    cmd = render_opencode_config_command(cfg)
    assert "python" not in cmd
    import tempfile, os
    with tempfile.TemporaryDirectory() as home:
        subprocess.run(["sh", "-c", cmd + " && echo chained"], check=True, env={"HOME": home, "PATH": "/usr/bin:/bin"},
                       capture_output=True)
        written = json.loads((Path(home) / ".config" / "opencode" / "opencode.json").read_text())
    assert written == cfg


# ── registry TLS interception ──────────────────────────────────────────────

@pytest.fixture
def tls_upstream(tmp_path):
    """A TLS 'registry' on localhost with a self-signed cert the proxy is told to trust."""
    import ssl as _ssl
    from proxies.egress_ca import EgressCA
    server_ca = EgressCA(tmp_path / "upstream-ca")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Upstream)
    srv.socket = server_ca.server_context("localhost").wrap_socket(srv.socket, server_side=True)
    t = threading.Thread(target=srv.serve_forever, daemon=True); t.start()
    from proxies.egress_ca import client_tls_context
    trust = client_tls_context(str(server_ca.ca_pem))
    yield srv.server_address[1], trust
    srv.shutdown()


@pytest.fixture
def intercepting_proxy(tmp_path, tls_upstream):
    port, trust = tls_upstream

    def resolver(task_dir):
        pol = ep.default_policy("us-west-2", llm_backend="openrouter", model="openrouter/x-ai/grok-4.7")
        return ep.EgressPolicy({**pol.allow_hosts, "localhost": "registries"}, pol.allow_suffixes)
    # make "localhost" behave like the npm registry for the path policy
    ep.REGISTRY_HOSTS["localhost"] = "npm"
    p = xp.EgressProxy(tmp_path / "egress.sock", policy_resolver=resolver, credentials={},
                       fallback_log=tmp_path / "fallback.log", llm_models={"x-ai/grok-4.7"},
                       ca_dir=tmp_path / "proxy-ca", upstream_ssl_context=trust)
    p.start()
    yield p, port
    p.stop()
    ep.REGISTRY_HOSTS.pop("localhost", None)


def _connect_tls(proxy, port, path, preamble=None, trust_proxy_ca=True):
    import ssl as _ssl
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(str(proxy.sock_path))
    if preamble is not None:
        s.sendall(xp.PREAMBLE_MAGIC + json.dumps(preamble).encode() + b"\n"); time.sleep(0.05)
    s.sendall(f"CONNECT localhost:{port} HTTP/1.1\r\nHost: localhost:{port}\r\n\r\n".encode())
    assert s.recv(1024).startswith(b"HTTP/1.1 200")
    from proxies.egress_ca import client_tls_context
    ctx = proxy.ca.client_context() if trust_proxy_ca else client_tls_context()
    tls = ctx.wrap_socket(s, server_hostname="localhost")
    tls.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
    out = b""
    try:
        while True:
            d = tls.recv(65536)
            if not d:
                break
            out += d
    except (socket.timeout, OSError):
        pass
    tls.close()
    return out


def test_intercepted_registry_request_is_forwarded(intercepting_proxy, tmp_path):
    proxy, port = intercepting_proxy
    logp = tmp_path / "t.log"
    out = _connect_tls(proxy, port, "/left-pad", preamble={"trial": "t", "log": str(logp),
                                                           "deny_packages": {"npm": ["@mariozechner/pi-coding-agent"]}})
    assert b" 200 " in out.split(b"\r\n", 1)[0] and b'"path": "/left-pad"' in out
    rec = json.loads(logp.read_text().splitlines()[-1])
    assert rec["decision"] == "allow" and rec["inner_path"] == "/left-pad"


def test_intercepted_own_package_is_denied(intercepting_proxy, tmp_path):
    proxy, port = intercepting_proxy
    logp = tmp_path / "t2.log"
    out = _connect_tls(proxy, port, "/@mariozechner/pi-coding-agent/-/pi-coding-agent-0.73.1.tgz",
                       preamble={"trial": "t2", "log": str(logp), "deny_packages": {"npm": ["@mariozechner/pi-coding-agent"]}})
    assert out.startswith(b"HTTP/1.1 403") and b"own npm package" in out
    rec = json.loads(logp.read_text().splitlines()[-1])
    assert rec["decision"] == "deny" and "own npm package" in rec["reason"]
    # search is refused regardless of denylist
    out = _connect_tls(proxy, port, "/-/v1/search?text=pi", preamble={"trial": "t2", "log": str(logp)})
    assert out.startswith(b"HTTP/1.1 403") and b"search" in out


def test_client_that_distrusts_the_ca_fails_closed(intercepting_proxy):
    proxy, port = intercepting_proxy
    import ssl as _ssl
    with pytest.raises(_ssl.SSLError):
        _connect_tls(proxy, port, "/left-pad", trust_proxy_ca=False)


def test_ca_bundle_env_and_install_script():
    env = ep.sandbox_env()
    assert env["SSL_CERT_FILE"] == ep.CA_BUNDLE_PATH and env["NODE_EXTRA_CA_CERTS"] == ep.CA_CERT_PATH
    from enroot_backend.netns import ca_install_script
    assert ep.CA_CERT_PATH in ca_install_script() and "ca_bundle_ok" in ca_install_script()


def test_relay_meta_file_roundtrip(tmp_path):
    meta_path = xp.write_relay_meta(tmp_path / "m.json", {"trial": "x"})
    assert json.loads(meta_path.read_text()) == {"trial": "x"}
    argv = xp.relay_argv("python3", tmp_path / "relay.py", tmp_path / "egress.sock", meta_path)
    assert argv[-1] == str(meta_path)
