"""Per-container network namespace whose only exit is the egress proxy.

``enroot start`` shares the host network namespace and gives the agent root, so
nothing applied *inside* the container (``/etc/hosts``, iptables) can be trusted.
Instead every container runs inside an unprivileged user+network namespace that
holds nothing but loopback::

    unshare -Urn --map-root-user  →  relay (127.0.0.1:3128 ⇄ <root>/egress.sock)
                                   →  nsenter -t <relay pid> -U -n  enroot start …

The relay process *is* the namespace holder: it is started once per container,
every exec enters its namespaces with ``nsenter``, and if it dies the container
has no network at all (fail closed — ``EnrootContainer.exec`` refuses to run).
It runs in the host mount namespace, so it can reach the proxy's unix socket,
which is never mounted into the container.

Measured on the development cluster (kernel 6.12, enroot 4.0.1, unprivileged user
namespaces enabled): inside the namespace ``curl --noproxy '*'`` exits 6/7 (no
DNS, no route), ``--resolve host:443:<ip>`` exits 7, python reports ``Network is
unreachable``; via the relay the allowlisted hosts answer normally.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import egress_policy as ep
from proxies.egress_proxy import relay_argv, write_relay_meta, write_relay_script

from .runtime import CONTAINER_ENV_MARKER, EnrootSetupError

log = logging.getLogger(__name__)

RELAY_READY_TIMEOUT_S = 15.0
_IP_CANDIDATES = ("/usr/sbin/ip", "/sbin/ip", "/bin/ip", "/usr/bin/ip")


def _ip_binary() -> str:
    found = shutil.which("ip")
    if found:
        return found
    for cand in _IP_CANDIDATES:
        if os.access(cand, os.X_OK):
            return cand
    raise EnrootSetupError("iproute2 `ip` not found on the host; needed to bring up loopback in the sandbox namespace")


def namespaces_supported() -> tuple[bool, str]:
    """Can this host create an unprivileged user+network namespace with loopback up?"""
    for tool in ("unshare", "nsenter"):
        if shutil.which(tool) is None:
            return False, f"{tool} not found"
    try:
        ip = _ip_binary()
    except EnrootSetupError as exc:
        return False, str(exc)
    try:
        proc = subprocess.run(
            ["unshare", "-Urn", "--map-root-user", "sh", "-c", f"{ip} link set lo up && readlink /proc/self/ns/net"],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"unshare failed: {exc}"
    if proc.returncode != 0:
        return False, f"unshare -Urn failed (rc={proc.returncode}): {proc.stderr.strip()[-200:]}"
    return True, "ok"


class EgressNamespace:
    """The relay/holder process of one container's network namespace."""

    def __init__(
        self,
        *,
        container_name: str,
        sock_path: Path,
        relay_script: Path,
        meta: dict,
        log_dir: Path,
        python: str | None = None,
    ) -> None:
        self.container_name = container_name
        self.sock_path = Path(sock_path)
        self.relay_script = Path(relay_script)
        self.meta = dict(meta)
        self.log_dir = Path(log_dir)
        self.python = python or sys.executable
        self._proc: subprocess.Popen | None = None

    @property
    def _stdout_path(self) -> Path:
        return self.log_dir / f"{self.container_name}.relay.out"

    @property
    def meta_path(self) -> Path:
        return self.log_dir / f"{self.container_name}.meta.json"

    def update_meta(self, **fields) -> None:
        """Extend the relay preamble (read by the relay on every connection)."""
        self.meta.update(fields)
        write_relay_meta(self.meta_path, self.meta)

    @property
    def pid(self) -> int | None:
        return self._proc.pid if self._proc else None

    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def start(self) -> None:
        if not self.sock_path.exists():
            raise EnrootSetupError(f"egress proxy socket missing: {self.sock_path}")
        if not self.relay_script.is_file():
            write_relay_script(self.relay_script)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        ip = _ip_binary()
        write_relay_meta(self.meta_path, self.meta)
        relay = " ".join(_q(a) for a in relay_argv(self.python, self.relay_script, self.sock_path, self.meta_path))
        argv = ["unshare", "-Urn", "--map-root-user", "--", "sh", "-c", f"{ip} link set lo up && exec {relay}"]
        env = dict(os.environ)
        env[CONTAINER_ENV_MARKER] = self.container_name  # so kill_container_processes() finds it
        out = open(self._stdout_path, "wb")
        try:
            self._proc = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                env=env, start_new_session=True,
            )
        finally:
            out.close()
        deadline = time.monotonic() + RELAY_READY_TIMEOUT_S
        while time.monotonic() < deadline:
            if self._proc.poll() is not None:
                break
            try:
                if b"relay ready" in self._stdout_path.read_bytes():
                    log.info("egress namespace for %s up (relay pid %d)", self.container_name, self._proc.pid)
                    return
            except OSError:
                pass
            time.sleep(0.05)
        tail = ""
        try:
            tail = self._stdout_path.read_text(errors="replace")[-400:]
        except OSError:
            pass
        self.stop()
        raise EnrootSetupError(
            f"egress relay for {self.container_name} did not come up within {RELAY_READY_TIMEOUT_S}s: {tail!r}"
        )

    def exec_prefix(self) -> list[str]:
        if not self.alive():
            raise EnrootSetupError(
                f"egress relay for {self.container_name} is not running; refusing to exec "
                "outside the network namespace (fail closed)"
            )
        assert self._proc is not None
        return ["nsenter", "-t", str(self._proc.pid), "-U", "-n", "--preserve-credentials", "--"]

    def stop(self) -> None:
        if self._proc is None:
            return
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                try:
                    self._proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
        self._proc = None

    def describe(self) -> dict:
        return {
            "relay_pid": self.pid,
            "sock": str(self.sock_path),
            "meta": self.meta,
            "relay": f"{ep.RELAY_HOST}:{ep.RELAY_PORT}",
            "policy_version": ep.POLICY_VERSION,
        }


def _q(s: str) -> str:
    import shlex
    return shlex.quote(s)


# ── in-container self-test ───────────────────────────────────────────────────

SELFTEST_ALLOWED_URL = f"http://{ep.RELAY_HOST}:{ep.RELAY_PORT}/openrouter/api/v1/models"
SELFTEST_PIN_URL = f"http://{ep.RELAY_HOST}:{ep.RELAY_PORT}/openrouter/api/v1/chat/completions"
SELFTEST_DENIED_URLS = (
    "https://cdn.jsdelivr.net/gh/hutusi/amytis@main/README.md",
    "https://github.com/",
    "https://proxy.golang.org/github.com/badlogic/pi-mono/@v/list",
    "https://r.jina.ai/https://github.com/",
)


def selftest_script() -> str:
    """Shell run *inside* the container; prints one ``key=value`` per line.

    For HTTPS targets curl tunnels through the proxy with CONNECT; a refused
    tunnel shows up as ``%{http_connect}`` (403) while ``%{http_code}`` is 000.
    The allowed probe uses the relay's LLM route (plain HTTP, no credential), and
    the pin probe posts a web-enabled foreign model to it, which must be refused.
    """
    lines = [
        "set +e",
        f"echo allowed=$(curl -s -o /dev/null -w '%{{http_code}}' --noproxy '*' --max-time 25 {SELFTEST_ALLOWED_URL})",
        "echo pin=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 25 -X POST "
        "-H 'Content-Type: application/json' -H 'Authorization: Bearer swt-egress-proxy' "
        "-d '{\"model\":\"google/gemini-2.5-flash:online\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' "
        f"{SELFTEST_PIN_URL})",
    ]
    for i, url in enumerate(SELFTEST_DENIED_URLS):
        lines.append(f"echo denied{i}=$(curl -s -o /dev/null -w '%{{http_connect}}' --max-time 15 {url})")
    lines += [
        # registry TLS is intercepted: a plain tunnel would return npm's 200 here
        "echo registry_ok=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 https://registry.npmjs.org/left-pad)",
        "echo registry_search=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 'https://registry.npmjs.org/-/v1/search?text=left-pad')",
        "curl -s -o /dev/null --noproxy '*' --max-time 5 https://cdn.jsdelivr.net/ ; echo noproxy_exit=$?",
        "curl -s -o /dev/null --noproxy '*' --resolve github.com:443:140.82.116.3 --max-time 5 https://github.com/ ; echo resolve_exit=$?",
        "echo https_proxy=$HTTPS_PROXY",
        "echo goproxy=$GOPROXY",
    ]
    return "\n".join(lines)


def evaluate_selftest(stdout: str) -> dict:
    """Parse the self-test output; ``ok`` is True only when every check holds."""
    kv: dict[str, str] = {}
    for line in stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    checks = {
        "allowed_host_reachable": kv.get("allowed") == "200",
        "llm_route_pinned": kv.get("pin") == "403",
        "registry_tls_intercepted": kv.get("registry_ok") == "200" and kv.get("registry_search") == "403",
        "denied_hosts_get_403": all(kv.get(f"denied{i}") == "403" for i in range(len(SELFTEST_DENIED_URLS))),
        # 6 = could not resolve, 7 = could not connect: both mean "no path but the proxy"
        "no_route_without_proxy": kv.get("noproxy_exit") in {"6", "7"},
        "no_route_to_ip_literal": kv.get("resolve_exit") in {"6", "7"},
        "proxy_env_present": kv.get("https_proxy", "") == f"http://{ep.RELAY_HOST}:{ep.RELAY_PORT}",
        "goproxy_off": kv.get("goproxy") == "off",
    }
    return {"ok": all(checks.values()), "checks": checks, "raw": kv, "policy_version": ep.POLICY_VERSION}


def write_selftest_result(path: Path, result: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")


# ── CA trust inside the container ────────────────────────────────────────────

def ca_install_script() -> str:
    """Build the CA bundle (system roots + per-job CA) the sandbox env points at.

    The CA file itself is copied into the rootfs by the environment before this
    runs. Also appended to the system bundle for clients that ignore the env.
    """
    ca, bundle = ep.CA_CERT_PATH, ep.CA_BUNDLE_PATH
    return (
        f"set -e; test -s {ca}; "
        f"for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem "
        f"/etc/ssl/ca-bundle.pem; do if [ -s \"$b\" ]; then cat \"$b\" {ca} > {bundle}; "
        f"grep -q 'SWE-Together egress' \"$b\" 2>/dev/null || cat {ca} >> \"$b\" 2>/dev/null || true; break; fi; done; "
        f"[ -s {bundle} ] || cp {ca} {bundle}; chmod 644 {ca} {bundle}; echo ca_bundle_ok"
    )
