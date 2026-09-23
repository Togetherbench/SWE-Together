"""Host-side allowlisting egress proxy for sandboxed agents.

Topology (enroot backend)::

    container (netns: lo only)                     compute node (host netns)
    ┌────────────────────────────────┐             ┌─────────────────────────┐
    │ curl/pip/npm/cargo/opencode    │             │ EgressProxy             │
    │   HTTPS_PROXY=127.0.0.1:3128 ──┼─► relay ─unix socket─► decide(host)   │
    │                                │  (in netns, │   allow → CONNECT/forward│
    └────────────────────────────────┘   host fs)  │   deny  → 403 + reason   │
                                                   └─────────────────────────┘

The container has **no route** to anything but loopback, so the only way out is
this proxy, which applies :mod:`egress_policy` to the destination hostname of
every request. Enforcement is therefore outside the agent's reach even though it
is root inside the container.

Three request shapes are served:

* ``CONNECT host:port`` — TLS passthrough; the decision is made on the CONNECT
  host, bytes are piped untouched (no MITM).
* ``GET http://host/...`` (absolute-URI, plain HTTP) — forwarded with the request
  target rewritten to origin-form.
* ``/openrouter/...`` (origin-form) — a reverse route to ``https://openrouter.ai``
  that **injects** ``Authorization: Bearer <host key>``. opencode's openrouter
  provider is pointed at ``http://127.0.0.1:3128/openrouter/api/v1``, so the real
  API key never enters the sandbox (agents read ``OPENROUTER_API_KEY`` from the
  environment and called the API from a shell). The route
  is **model-pinned**: only ``POST /api/v1/chat/completions`` whose JSON ``model``
  is one of the run's configured models is forwarded, web plugins (``plugins``,
  ``:online`` variants, ``web_search_options``, non-function tools) are refused,
  and ``GET /api/v1/models`` is served without a credential. Without the pin the
  route was an open LLM gateway: agents called web-enabled ``:online`` models
  through it and had the *model* fetch the GitHub PR for them.

Relay ↔ proxy protocol: the relay sends one preamble line
``SWT1 {"trial": …, "log": …, "task_dir": …}\\n`` and then pipes bytes. ``log``
is the host path of the trial's ``agent/egress.log`` (JSON lines, one per
connection); ``task_dir`` selects the per-task policy.
"""
from __future__ import annotations

import json
import logging
import os
import re
import select
import socket
import ssl
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import egress_policy as ep

log = logging.getLogger(__name__)

PREAMBLE_MAGIC = b"SWT1 "
MAX_HEAD = 64 * 1024
MAX_LLM_BODY = 64 * 1024 * 1024  # long agentic contexts run to tens of MB
CONNECT_TIMEOUT_S = 15
IDLE_TIMEOUT_S = 600  # long-poll LLM streams stay busy; idle tunnels are reaped

_REQ_LINE = re.compile(rb"^([A-Z]+) (\S+) HTTP/1\.[01]\r\n")
_ABS_URI = re.compile(r"^https?://([^/:@\s]+)(?::(\d+))?(/.*)?$", re.I)
_HEADER_STRIP = ("proxy-connection", "proxy-authorization", "connection", "keep-alive")


@dataclass(frozen=True)
class ReverseRoute:
    prefix: str
    upstream: str
    credential_env: str | None
    #: (method, upstream path) pairs that may be forwarded at all
    endpoints: frozenset[tuple[str, str]]
    #: upstream paths that get the credential injected and the model pinned
    llm_paths: frozenset[str]


#: URL prefix inside the sandbox → upstream. Anything not listed is refused.
REVERSE_ROUTES: dict[str, ReverseRoute] = {
    "/openrouter/": ReverseRoute(
        prefix="/openrouter/", upstream="openrouter.ai", credential_env="OPENROUTER_API_KEY",
        endpoints=frozenset({("POST", "/api/v1/chat/completions"), ("GET", "/api/v1/models")}),
        llm_paths=frozenset({"/api/v1/chat/completions"}),
    ),
}

#: Request-body keys that turn a chat completion into a web fetch.
_LLM_BODY_FORBIDDEN_KEYS = ("plugins", "web_search_options", "web_search", "tools_web", "online")


class LLMRequestDenied(ValueError):
    pass


def check_llm_body(body: bytes, allowed_models: frozenset[str]) -> str:
    """Return the pinned model name or raise :class:`LLMRequestDenied`."""
    try:
        req = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise LLMRequestDenied(f"llm body is not JSON ({exc.__class__.__name__})")
    if not isinstance(req, dict):
        raise LLMRequestDenied("llm body is not an object")
    model = req.get("model")
    if not isinstance(model, str) or not model:
        raise LLMRequestDenied("llm body has no model")
    if not allowed_models:
        raise LLMRequestDenied(f"no pinned model configured; refusing {model}")
    if model not in allowed_models or ":" in model:
        raise LLMRequestDenied(f"model not pinned for this run: {model}")
    for key in _LLM_BODY_FORBIDDEN_KEYS:
        if key in req:
            raise LLMRequestDenied(f"web/plugin field refused: {key}")
    tools = req.get("tools")
    if tools is not None:
        if not isinstance(tools, list):
            raise LLMRequestDenied("tools must be a list")
        for t in tools:
            if not isinstance(t, dict) or t.get("type") != "function":
                raise LLMRequestDenied(f"non-function tool refused: {str(t)[:60]}")
    return model


@dataclass
class ConnMeta:
    trial: str = "-"
    log_path: str | None = None
    task_dir: str | None = None
    deny_packages: ep.DenyPackages | None = None


def _pipe(a: socket.socket, b: socket.socket, counters: list[int]) -> None:
    """Bidirectional copy until either side closes or the tunnel idles out.

    TLS sockets may hold decrypted bytes the fd-level ``select`` cannot see, so
    those are drained first (``SSLSocket.pending``).
    """
    socks = [a, b]
    try:
        while True:
            ready = [s for s in socks if getattr(s, "pending", lambda: 0)()]
            if not ready:
                r, _, x = select.select(socks, [], socks, IDLE_TIMEOUT_S)
                if x or not r:
                    return
                ready = r
            for s in ready:
                data = s.recv(65536)
                if not data:
                    return
                dst = b if s is a else a
                dst.sendall(data)
                counters[0 if s is a else 1] += len(data)
    except (OSError, ValueError):
        return


def _shutdown(*socks: socket.socket) -> None:
    for s in socks:
        if s is None:
            continue
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            s.close()
        except OSError:
            pass


def parse_request_head(head: bytes) -> tuple[str, str, list[tuple[str, str]]]:
    """``(method, target, headers)`` from a raw HTTP/1.x request head (no body)."""
    m = _REQ_LINE.match(head)
    if not m:
        raise ValueError("malformed request line")
    method, target = m.group(1).decode(), m.group(2).decode("latin-1")
    headers: list[tuple[str, str]] = []
    for line in head[m.end():].split(b"\r\n"):
        if not line:
            break
        if b":" not in line:
            raise ValueError("malformed header")
        k, v = line.split(b":", 1)
        headers.append((k.decode("latin-1").strip(), v.decode("latin-1").strip()))
    return method, target, headers


def destination(method: str, target: str, headers: list[tuple[str, str]]) -> tuple[str, int, str | None, str]:
    """Resolve ``(host, port, reverse_prefix, path)`` for a request.

    ``reverse_prefix`` is set when the request is an origin-form path under
    :data:`REVERSE_ROUTES`; otherwise ``path`` is the origin-form target to send
    upstream (``None`` for CONNECT).
    """
    if method == "CONNECT":
        host, _, port = target.rpartition(":")
        if not host or not port.isdigit():
            raise ValueError("CONNECT target must be host:port")
        return host, int(port), None, ""
    m = _ABS_URI.match(target)
    if m:
        scheme_https = target.lower().startswith("https://")
        port = int(m.group(2)) if m.group(2) else (443 if scheme_https else 80)
        return m.group(1), port, None, m.group(3) or "/"
    if target.startswith("/"):
        for prefix, route in REVERSE_ROUTES.items():
            if target.startswith(prefix):
                return route.upstream, 443, prefix, "/" + target[len(prefix):]
        raise ValueError("origin-form request outside reverse routes")
    raise ValueError("unsupported request target")


def _rebuild_head(method: str, path: str, headers: list[tuple[str, str]], host: str,
                  inject_auth: str | None) -> bytes:
    out = [f"{method} {path} HTTP/1.1"]
    saw_host = False
    for k, v in headers:
        kl = k.lower()
        if kl in _HEADER_STRIP:
            continue
        if kl == "authorization" and inject_auth is not None:
            continue
        if kl == "host":
            out.append(f"Host: {host}")
            saw_host = True
            continue
        out.append(f"{k}: {v}")
    if not saw_host:
        out.insert(1, f"Host: {host}")
    if inject_auth is not None:
        out.append(f"Authorization: Bearer {inject_auth}")
    out.append("Connection: close")
    return ("\r\n".join(out) + "\r\n\r\n").encode("latin-1")


def _deny_response(host: str, reason: str, policy_digest: str) -> bytes:
    body = json.dumps({
        "error": "egress denied by sandbox policy",
        "host": host,
        "reason": reason,
        "policy": f"swt-egress/{ep.POLICY_VERSION}/{policy_digest}",
    }).encode()
    return (
        b"HTTP/1.1 403 Forbidden\r\n"
        b"Content-Type: application/json\r\n"
        b"X-Egress-Policy: denied\r\n"
        b"Connection: close\r\n"
        + f"Content-Length: {len(body)}\r\n\r\n".encode() + body
    )


def _content_length(headers: list[tuple[str, str]]) -> int | None:
    for k, v in headers:
        if k.lower() == "content-length":
            try:
                return int(v)
            except ValueError:
                return None
    return None


def _bad_request(msg: str) -> bytes:
    body = json.dumps({"error": msg}).encode()
    return (b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)


def _read_http_head(conn: socket.socket, initial: bytes = b"") -> tuple[bytes, bytes]:
    """``(head_with_terminator, leftover)`` from a plain or TLS socket."""
    buf = initial
    while b"\r\n\r\n" not in buf:
        if len(buf) > MAX_HEAD:
            raise ValueError("request head too large")
        chunk = conn.recv(65536)
        if not chunk:
            raise ConnectionError("client closed before request head")
        buf += chunk
    head, sep, rest = buf.partition(b"\r\n\r\n")
    if len(head) > MAX_HEAD:
        raise ValueError("request head too large")
    return head + sep, rest


class EgressProxy:
    """One instance per host process (Slurm job); serves every trial's relay."""

    def __init__(self, sock_path: Path, aws_region: str | None = None,
                 credentials: dict[str, str] | None = None,
                 fallback_log: Path | None = None,
                 policy_resolver: Callable[[str | None], ep.EgressPolicy] | None = None,
                 llm_backend: str | None = None, model: str | None = None,
                 llm_models: frozenset[str] | set[str] | None = None,
                 ca_dir: Path | None = None,
                 upstream_ssl_context: ssl.SSLContext | None = None):
        self.sock_path = Path(sock_path)
        self.aws_region = aws_region
        self.llm_backend = llm_backend
        self.model = model
        #: OpenRouter model ids the ``/openrouter/`` route will forward (the agent's,
        #: plus any small/title model the harness uses). Empty = route refuses all.
        self.llm_models = frozenset(llm_models or ())
        #: CA used to terminate TLS for registry hosts; None disables interception
        #: (registry CONNECTs then pass as opaque tunnels — tests only).
        self.ca = None
        if ca_dir is not None:
            from proxies.egress_ca import EgressCA
            self.ca = EgressCA(ca_dir)
        self._upstream_ssl = upstream_ssl_context or ssl.create_default_context()
        self.credentials = credentials if credentials is not None else dict(os.environ)
        self.fallback_log = fallback_log
        self._resolver = policy_resolver or self._default_resolver
        self._policies: dict[str | None, ep.EgressPolicy] = {}
        self._lock = threading.Lock()
        self._server: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self.connections = 0

    # ── policy ─────────────────────────────────────────────────────────────
    def _default_resolver(self, task_dir: str | None) -> ep.EgressPolicy:
        return ep.policy_for_task(Path(task_dir) if task_dir else None, self.aws_region,
                                  self.llm_backend, self.model)

    def policy(self, task_dir: str | None) -> ep.EgressPolicy:
        with self._lock:
            pol = self._policies.get(task_dir)
            if pol is None:
                pol = self._resolver(task_dir)
                self._policies[task_dir] = pol
            return pol

    # ── lifecycle ──────────────────────────────────────────────────────────
    def start(self) -> None:
        self.sock_path.parent.mkdir(parents=True, exist_ok=True)
        if self.sock_path.exists():
            self.sock_path.unlink()
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(self.sock_path))
        os.chmod(self.sock_path, 0o600)
        srv.listen(256)
        srv.settimeout(1.0)
        self._server = srv
        self._thread = threading.Thread(target=self._accept_loop, name="egress-proxy", daemon=True)
        self._thread.start()
        log.info("egress proxy listening on %s", self.sock_path)

    def stop(self) -> None:
        self._stop.set()
        if self._server:
            _shutdown(self._server)
        if self._thread:
            self._thread.join(timeout=5)
        try:
            self.sock_path.unlink()
        except OSError:
            pass

    def __enter__(self) -> "EgressProxy":
        self.start()
        return self

    def __exit__(self, *exc) -> None:
        self.stop()

    def _accept_loop(self) -> None:
        assert self._server is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    # ── per-connection ─────────────────────────────────────────────────────
    def _read_head(self, conn: socket.socket) -> tuple[ConnMeta, bytes, bytes]:
        """Preamble (optional), request head, and any body bytes already received.

        The size guard applies to the *head* only: a large POST (an LLM request
        with a long context) legitimately arrives as head + hundreds of KB of
        body in the same stream.
        """
        buf = b""
        conn.settimeout(CONNECT_TIMEOUT_S)

        def fill() -> None:
            nonlocal buf
            while b"\r\n\r\n" not in buf:
                if len(buf) > MAX_HEAD:
                    raise ValueError("request head too large")
                chunk = conn.recv(65536)
                if not chunk:
                    raise ConnectionError("client closed before request head")
                buf += chunk

        fill()
        meta = ConnMeta()
        if buf.startswith(PREAMBLE_MAGIC):
            line, _, buf = buf.partition(b"\n")
            try:
                d = json.loads(line[len(PREAMBLE_MAGIC):].decode())
                meta = ConnMeta(str(d.get("trial") or "-"), d.get("log"), d.get("task_dir"),
                                ep.DenyPackages.from_dict(d.get("deny_packages")))
            except (ValueError, AttributeError):
                raise ValueError("bad relay preamble")
            fill()
        head, sep, rest = buf.partition(b"\r\n\r\n")
        if len(head) > MAX_HEAD:
            raise ValueError("request head too large")
        return meta, head + sep, rest

    def _handle(self, conn: socket.socket) -> None:
        t0 = time.time()
        meta = ConnMeta()
        record: dict = {"ts": round(t0, 3)}
        upstream: socket.socket | None = None
        counters = [0, 0]
        try:
            meta, head, body0 = self._read_head(conn)
            record["trial"] = meta.trial
            method, target, headers = parse_request_head(head)
            record.update(method=method, target=target[:200])
            host, port, reverse_prefix, path = destination(method, target, headers)
            pol = self.policy(meta.task_dir)
            # A reverse route is its own policy (endpoint + model pinning below); the
            # host allowlist governs CONNECT / absolute-URI traffic only.
            decision = ep.Decision(True, host, "allow:llm-route") if reverse_prefix is not None else pol.decide(host)
            record.update(host=decision.host, port=port, decision="allow" if decision.allowed else "deny",
                          reason=decision.reason)
            if not decision.allowed:
                conn.sendall(_deny_response(decision.host, decision.reason, pol.digest()))
                return
            token = None
            if reverse_prefix is not None:
                # Validate everything about an LLM-route request before touching upstream.
                route = REVERSE_ROUTES[reverse_prefix]
                if (method, path) not in route.endpoints:
                    record.update(decision="deny", reason=f"deny:llm route endpoint {method} {path}")
                    conn.sendall(_deny_response(decision.host, record["reason"], pol.digest()))
                    return
                if path in route.llm_paths:
                    clen = _content_length(headers)
                    if clen is None or clen < 0 or clen > MAX_LLM_BODY:
                        raise ValueError("llm request needs a Content-Length within limits")
                    conn.settimeout(IDLE_TIMEOUT_S)
                    while len(body0) < clen:
                        chunk = conn.recv(min(1 << 20, clen - len(body0)))
                        if not chunk:
                            raise ConnectionError("client closed mid-body")
                        body0 += chunk
                    try:
                        record["model"] = check_llm_body(body0[:clen], self.llm_models)
                    except LLMRequestDenied as exc:
                        record.update(decision="deny", reason=f"deny:{exc}")
                        conn.sendall(_deny_response(decision.host, record["reason"], pol.digest()))
                        return
                    token = self.credentials.get(route.credential_env) if route.credential_env else None
                    record["auth_injected"] = bool(token)
            upstream = socket.create_connection((decision.host, port), timeout=CONNECT_TIMEOUT_S)
            if reverse_prefix is not None:
                upstream = self._upstream_ssl.wrap_socket(upstream, server_hostname=decision.host)
                upstream.sendall(_rebuild_head(method, path, headers, decision.host, token))
            elif method == "CONNECT" and self.ca is not None and decision.host in ep.REGISTRY_HOSTS:
                # Registry: terminate TLS, inspect the request, then re-encrypt upstream.
                conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                conn = self.ca.server_context(decision.host).wrap_socket(conn, server_side=True)
                conn.settimeout(CONNECT_TIMEOUT_S)
                head, body0 = _read_http_head(conn)
                in_method, in_target, in_headers = parse_request_head(head)
                record.update(inner_method=in_method, inner_path=in_target[:200])
                why = ep.registry_decision(decision.host, in_method, in_target,
                                           meta.deny_packages or ep.DenyPackages())
                if why:
                    record.update(decision="deny", reason=why)
                    conn.sendall(_deny_response(decision.host, why, pol.digest()))
                    return
                upstream = self._upstream_ssl.wrap_socket(upstream, server_hostname=decision.host)
                upstream.sendall(_rebuild_head(in_method, in_target, in_headers, decision.host, None))
            elif method == "CONNECT":
                conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            else:
                why = ep.registry_decision(decision.host, method, path, meta.deny_packages or ep.DenyPackages())
                if why:
                    record.update(decision="deny", reason=why)
                    conn.sendall(_deny_response(decision.host, why, pol.digest()))
                    return
                upstream.sendall(_rebuild_head(method, path, headers, decision.host, None))
            if body0:
                upstream.sendall(body0)
                counters[0] += len(body0)
            conn.settimeout(None)
            upstream.settimeout(None)
            _pipe(conn, upstream, counters)
        except (ValueError, ConnectionError) as exc:
            record.setdefault("decision", "error")
            record["error"] = str(exc)[:200]
            try:
                conn.sendall(_bad_request(str(exc)))
            except OSError:
                pass
        except OSError as exc:
            record.setdefault("decision", "error")
            record["error"] = f"io: {exc}"[:200]
            try:
                conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
        finally:
            record.update(bytes_up=counters[0], bytes_down=counters[1], dur_ms=int((time.time() - t0) * 1000))
            # Log before closing: the client sees EOF on close and may read the log immediately.
            self._log(meta, record)
            _shutdown(conn, upstream)

    def _log(self, meta: ConnMeta, record: dict) -> None:
        line = json.dumps(record, separators=(",", ":")) + "\n"
        path = Path(meta.log_path) if meta.log_path else self.fallback_log
        if path is None:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with self._lock, path.open("a") as f:
                f.write(line)
        except OSError as exc:
            log.debug("egress log write failed (%s): %s", path, exc)


# ── in-namespace relay ───────────────────────────────────────────────────────

RELAY_SOURCE = r'''#!/usr/bin/env python3
"""TCP→unix relay: the only exit from the sandbox's network namespace.

Runs inside the trial's network namespace (loopback only) but with the host
filesystem, so it can reach the egress proxy's unix socket. Sends a one-line
preamble naming the trial, then pipes bytes. The preamble is re-read from a JSON
file on every connection so the harness can extend it (e.g. with the package
denylist scanned from the workspace) after the relay has started.
"""
import json, select, socket, sys, threading

SOCK, HOST, PORT, META_PATH = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


def preamble():
    try:
        with open(META_PATH) as f:
            meta = json.load(f)
    except (OSError, ValueError):
        meta = {}
    return b"SWT1 " + json.dumps(meta, separators=(",", ":")).encode() + b"\n"


def pipe(a, b):
    try:
        while True:
            r, _, x = select.select([a, b], [], [a, b], 900)
            if x or not r:
                return
            for s in r:
                d = s.recv(65536)
                if not d:
                    return
                (b if s is a else a).sendall(d)
    except (OSError, ValueError):
        return
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def serve(c):
    u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        u.settimeout(10)
        u.connect(SOCK)
        u.sendall(preamble())
        u.settimeout(None)
    except OSError:
        c.close(); u.close()
        return
    pipe(c, u)


ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((HOST, PORT))
ls.listen(256)
sys.stdout.write("relay ready\n"); sys.stdout.flush()
while True:
    c, _ = ls.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
'''


def write_relay_script(path: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(RELAY_SOURCE)
    path.chmod(0o755)
    return path


def write_relay_meta(path: Path, meta: dict) -> Path:
    """Atomically (re)write the relay's preamble metadata."""
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(meta, separators=(",", ":")))
    tmp.replace(path)
    return path


def relay_argv(python: str, script: Path, sock_path: Path, meta_path: Path) -> list[str]:
    return [python, str(script), str(sock_path), ep.RELAY_HOST, str(ep.RELAY_PORT), str(meta_path)]
