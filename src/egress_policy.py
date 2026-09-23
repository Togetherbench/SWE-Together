"""Sandbox egress policy: default-deny with an explicit allowlist.

The task images defeat answer leakage by pointing ``github.com`` & co. at
``127.0.0.1`` in ``/etc/hosts`` (``environment/seal-dns.sh``). That is a hostname
*blocklist* enforced inside a container where the agent is root, and it was
evaded in every cohort: GitHub CDN/proxy mirrors (``cdn.jsdelivr.net/gh/…``,
``gh-proxy.com``, ``ghfast.top``), read-through proxies (``r.jina.ai``),
DNS-over-HTTPS + ``curl --resolve``, ``LD_PRELOAD`` resolver shims for git, and
search engines used to locate the upstream PR.

This module is the single source of truth for what a sandbox may reach. The
decision is made by the host-side egress proxy (``proxies/egress_proxy.py``);
the container itself has no route to anything (it runs in an unprivileged network
namespace whose only exit is that proxy), so nothing here can be undone from
inside.

Two facts shape the policy:

* Package registries are legitimately needed — 13–28 % of trials in the existing
  cohorts ran a successful ``pip``/``npm``/``cargo``/``apt`` download — so they
  are allowed.
* ``proxy.golang.org`` serves *any* GitHub repository verbatim, i.e.
  ``go mod download github.com/<task repo>@main`` is the fix. It is denied; the
  Go task images pre-populate the module cache and the sandbox runs with
  ``GOPROXY=off``.

Per-task additions come from ``task.toml``::

    [network]
    allow = ["download.pytorch.org"]

and are validated against :data:`LEAK_VECTORS` so a task cannot re-open GitHub.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

POLICY_VERSION = 2

#: Where the in-namespace relay listens; the sandbox's proxy env points here.
RELAY_HOST = "127.0.0.1"
RELAY_PORT = 3128

#: Where the enroot backend installs the per-job CA inside the container.
CA_CERT_PATH = "/etc/swt-egress-ca.pem"
CA_BUNDLE_PATH = "/etc/swt-egress-bundle.pem"

#: Sandbox-side stand-in for the OpenRouter key; the proxy swaps in the real one
#: on the ``/openrouter/`` route (and only for the pinned model).
OPENROUTER_PLACEHOLDER = "swt-egress-proxy"

#: Hosts every trial may reach, by group. ``llm`` is *not* here: which LLM API a
#: sandbox may reach depends on the run's backend (see :func:`llm_hosts`); for
#: OpenRouter runs it is none at all — the model is reached only through the
#: relay's model-pinned reverse route.
ALLOW_GROUPS: dict[str, frozenset[str]] = {
    "catalog": frozenset({
        "models.dev", "models.opencode.ai",  # opencode's model catalog (pricing + reasoning variants)
    }),
    "registries": frozenset({
        # Python
        "pypi.org", "files.pythonhosted.org",
        # Node
        "registry.npmjs.org", "registry.yarnpkg.com",
        # Rust
        "crates.io", "static.crates.io", "index.crates.io",
        # Debian/Ubuntu + NodeSource (opencode's apt fallback, `apt-get install ripgrep`)
        "archive.ubuntu.com", "security.ubuntu.com", "ports.ubuntu.com",
        "deb.debian.org", "security.debian.org", "deb.nodesource.com",
    }),
}

#: Native/proxied provider API hosts by model prefix (``src/runner.py`` base URLs,
#: Claude Code, codex OAuth). Only the prefix the run actually uses is allowed.
PROVIDER_HOSTS: dict[str, frozenset[str]] = {
    "anthropic": frozenset({"api.anthropic.com"}),
    "openai": frozenset({"api.openai.com"}),
    "codex": frozenset({"chatgpt.com", "auth.openai.com"}),
    "gemini": frozenset({"generativelanguage.googleapis.com"}),
    "google": frozenset({"generativelanguage.googleapis.com"}),
    "deepseek": frozenset({"api.deepseek.com"}),
    "glm": frozenset({"api.z.ai"}), "glmd": frozenset({"api.z.ai"}), "zai": frozenset({"api.z.ai"}),
    "minimax": frozenset({"api.minimax.io"}), "minimaxd": frozenset({"api.minimax.io"}),
    "ark": frozenset({"ark.cn-beijing.volces.com"}),
    "fireworks": frozenset({"api.fireworks.ai"}),
    "chutes": frozenset({"claude.chutes.ai"}),
    "xai": frozenset({"api.x.ai"}),
    "groq": frozenset({"api.groq.com"}),
    "mistral": frozenset({"api.mistral.ai"}),
}


def llm_hosts(llm_backend: str | None, model: str | None, aws_region: str | None) -> tuple[set[str], set[str]]:
    """``(hosts, suffixes)`` the run's LLM seat needs to reach by CONNECT.

    * ``openrouter`` → nothing: opencode is pointed at the relay's ``/openrouter/``
      route, which pins the model and injects the key. A CONNECT to
      ``openrouter.ai`` would let a shell call *any* model (``:online`` variants
      fetch the web) with a key found in the sandbox.
    * ``bedrock`` → the regional runtime endpoint (SigV4 cannot be injected).
    * ``native``/proxied → the one vendor host for the model's provider prefix.
    """
    hosts: set[str] = set()
    suffixes: set[str] = set()
    if llm_backend == "bedrock":
        suffixes.add(f"bedrock-runtime.{aws_region or 'us-west-2'}.amazonaws.com")
    elif llm_backend in (None, "native", "proxied") and model:
        prefix = model.split("/", 1)[0].lower() if "/" in model else ""
        hosts |= PROVIDER_HOSTS.get(prefix, frozenset())
    return hosts, suffixes

#: Known answer-leak vectors. Denied even if a task.toml asks for them, and the
#: reason is surfaced to the agent in the proxy's 403 body so the transcript shows
#: an explicit policy refusal rather than a network flake.
LEAK_VECTORS: dict[str, str] = {
    "github.com": "task source repository",
    "githubusercontent.com": "raw GitHub content",
    "githubassets.com": "GitHub",
    "github.io": "GitHub Pages",
    "ghcr.io": "GitHub container registry",
    "gitlab.com": "source forge",
    "bitbucket.org": "source forge",
    "codeberg.org": "source forge",
    "sourcegraph.com": "code search over GitHub",
    "cdn.jsdelivr.net": "CDN mirror of GitHub repositories",
    "unpkg.com": "CDN mirror of npm/GitHub content",
    "gh-proxy.com": "GitHub proxy",
    "ghproxy.com": "GitHub proxy",
    "ghproxy.net": "GitHub proxy",
    "ghfast.top": "GitHub proxy",
    "ghps.cc": "GitHub proxy",
    "kkgithub.com": "GitHub mirror",
    "fastgit.org": "GitHub mirror",
    "gitclone.com": "GitHub mirror",
    "githubfast.com": "GitHub mirror",
    "r.jina.ai": "read-through web proxy",
    "proxy.golang.org": "Go module proxy serves any GitHub repo verbatim",
    "sum.golang.org": "Go checksum db (module cache is pre-populated)",
    "goproxy.io": "Go module proxy",
    "goproxy.cn": "Go module proxy",
    "huggingface.co": "model hub (task images ship what they need)",
    "hf.co": "model hub",
    "hf-mirror.com": "model hub mirror",
    "cloudflare-dns.com": "DNS-over-HTTPS",
    "dns.google": "DNS-over-HTTPS",
    "dns.quad9.net": "DNS-over-HTTPS",
    "doh.opendns.com": "DNS-over-HTTPS",
    "duckduckgo.com": "web search",
    "bing.com": "web search",
    "google.com": "web search",
    "web.archive.org": "web archive of GitHub pages",
    "archive.org": "web archive",
}

#: Bare IP literals are never proxied: an IP was obtained out-of-band (DoH or a
#: hard-coded GitHub address) and there is no hostname to apply policy to.
_IP_LITERAL = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$|^\[?[0-9a-f:]+\]?$", re.I)
_HOSTNAME = re.compile(r"^(?=.{1,253}$)(?!-)[a-z0-9-]{1,63}(?<!-)(?:\.(?!-)[a-z0-9-]{1,63}(?<!-))*$", re.I)


@dataclass(frozen=True)
class Decision:
    allowed: bool
    host: str
    reason: str  # "allow:<group>" | "deny:<why>"

    @property
    def group(self) -> str | None:
        return self.reason.split(":", 1)[1] if self.allowed else None


@dataclass(frozen=True)
class EgressPolicy:
    allow_hosts: dict[str, str]  # host -> group
    allow_suffixes: dict[str, str]  # suffix -> group (matches host and subdomains)
    task_allow: frozenset[str] = field(default_factory=frozenset)
    version: int = POLICY_VERSION

    # ── decisions ──────────────────────────────────────────────────────────
    def decide(self, host: str) -> Decision:
        h = host.strip().rstrip(".").lower()
        if h.startswith("[") and h.endswith("]"):
            h = h[1:-1]
        if not h:
            return Decision(False, host, "deny:empty host")
        if _IP_LITERAL.match(h):
            return Decision(False, h, "deny:ip literal (no hostname to apply policy to)")
        if not _HOSTNAME.match(h):
            return Decision(False, h, "deny:malformed host")
        leak = leak_vector(h)
        if leak:
            return Decision(False, h, f"deny:{leak}")
        if h in self.task_allow:
            return Decision(True, h, "allow:task")
        if h in self.allow_hosts:
            return Decision(True, h, f"allow:{self.allow_hosts[h]}")
        for suffix, group in self.allow_suffixes.items():
            if h == suffix or h.endswith("." + suffix):
                return Decision(True, h, f"allow:{group}")
        return Decision(False, h, "deny:not in allowlist")

    # ── identity ───────────────────────────────────────────────────────────
    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "allow_hosts": dict(sorted(self.allow_hosts.items())),
            "allow_suffixes": dict(sorted(self.allow_suffixes.items())),
            "task_allow": sorted(self.task_allow),
            "leak_vectors": dict(sorted(LEAK_VECTORS.items())),
            "relay": f"{RELAY_HOST}:{RELAY_PORT}",
        }

    def digest(self) -> str:
        blob = json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(blob).hexdigest()[:16]

    def write(self, path: Path) -> None:
        d = self.to_dict()
        d["digest"] = self.digest()
        path.write_text(json.dumps(d, indent=1, sort_keys=True) + "\n")

    def with_task_allow(self, hosts: list[str]) -> "EgressPolicy":
        cleaned = validate_task_allow(hosts)
        return EgressPolicy(self.allow_hosts, self.allow_suffixes, frozenset(cleaned), self.version)


def leak_vector(host: str) -> str | None:
    """The :data:`LEAK_VECTORS` reason if ``host`` is, or is under, a known leak vector."""
    h = host.lower()
    for vector, why in LEAK_VECTORS.items():
        if h == vector or h.endswith("." + vector):
            return f"{vector} ({why})"
    return None


class TaskAllowError(ValueError):
    pass


def validate_task_allow(hosts: list[str]) -> list[str]:
    """Normalise a task's ``[network] allow`` list; reject leak vectors, IPs, wildcards."""
    out: list[str] = []
    for raw in hosts:
        if not isinstance(raw, str):
            raise TaskAllowError(f"[network] allow entries must be strings: {raw!r}")
        h = raw.strip().rstrip(".").lower()
        if "*" in h or "/" in h or ":" in h:
            raise TaskAllowError(f"[network] allow must list bare hostnames, got {raw!r}")
        if _IP_LITERAL.match(h) or not _HOSTNAME.match(h):
            raise TaskAllowError(f"[network] allow: not a hostname: {raw!r}")
        leak = leak_vector(h)
        if leak:
            raise TaskAllowError(f"[network] allow: {raw!r} is a known leak vector — {leak}")
        out.append(h)
    return sorted(set(out))


def task_allow_from_toml(task_dir: Path) -> list[str]:
    """``[network] allow`` from ``<task_dir>/task.toml`` (empty when absent)."""
    p = Path(task_dir) / "task.toml"
    if not p.is_file():
        return []
    with p.open("rb") as f:
        data = tomllib.load(f)
    hosts = (data.get("network") or {}).get("allow") or []
    if not isinstance(hosts, list):
        raise TaskAllowError(f"{p}: [network] allow must be a list")
    return validate_task_allow(hosts)


def default_policy(aws_region: str | None = None, llm_backend: str | None = None,
                   model: str | None = None) -> EgressPolicy:
    """The global policy: catalog + registries, plus the LLM hosts *this run's* backend needs."""
    hosts = {h: g for g, hs in ALLOW_GROUPS.items() for h in hs}
    suffixes: dict[str, str] = {}
    lh, ls = llm_hosts(llm_backend, model, aws_region)
    hosts.update({h: "llm" for h in lh})
    suffixes.update({s: "llm" for s in ls})
    return EgressPolicy(hosts, suffixes)


def policy_for_task(task_dir: Path | None, aws_region: str | None = None,
                    llm_backend: str | None = None, model: str | None = None) -> EgressPolicy:
    pol = default_policy(aws_region, llm_backend, model)
    if task_dir is not None:
        extra = task_allow_from_toml(Path(task_dir))
        if extra:
            log.info("egress: task %s allows %s", Path(task_dir).name, extra)
            pol = pol.with_task_allow(extra)
    return pol


#: Environment every sandboxed process gets so well-behaved clients (curl, pip,
#: npm, cargo, git, python urllib, node fetch via undici's env support) route via
#: the relay. Clients that ignore it simply have no route.
def sandbox_env() -> dict[str, str]:
    url = f"http://{RELAY_HOST}:{RELAY_PORT}"
    return {
        "HTTP_PROXY": url, "HTTPS_PROXY": url, "http_proxy": url, "https_proxy": url,
        "ALL_PROXY": url, "all_proxy": url,
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        # Go: modules are pre-populated in the task images; the proxy is a leak vector.
        "GOPROXY": "off", "GOFLAGS": "-mod=mod", "GONOSUMDB": "*", "GONOSUMCHECK": "1", "GOSUMDB": "off",
        # cargo honours HTTPS_PROXY for the sparse index but shells out to git for
        # git dependencies; the git CLI reads the same variables.
        "CARGO_NET_GIT_FETCH_WITH_CLI": "true",
        # Registry TLS is terminated by the proxy with the per-job CA; every client
        # gets the bundle (system roots + CA) or, for Node, the CA as an extra root.
        "SSL_CERT_FILE": CA_BUNDLE_PATH, "REQUESTS_CA_BUNDLE": CA_BUNDLE_PATH,
        "CURL_CA_BUNDLE": CA_BUNDLE_PATH, "PIP_CERT": CA_BUNDLE_PATH,
        "GIT_SSL_CAINFO": CA_BUNDLE_PATH, "CARGO_HTTP_CAINFO": CA_BUNDLE_PATH,
        "NIX_SSL_CERT_FILE": CA_BUNDLE_PATH, "NODE_EXTRA_CA_CERTS": CA_CERT_PATH,
        "SWT_EGRESS_POLICY_VERSION": str(POLICY_VERSION),
    }


# ── registries: path-level policy ────────────────────────────────────────────
#
# Registry hosts are allowlisted but TLS-intercepted by the proxy, which applies
# these rules to the decrypted request. Two things are refused:
#
# * any artefact of the **task's own packages** (every version — the repo is in
#   the workspace; a registry copy can only be a different, possibly fixed,
#   release). Names are scanned from the workspace manifests at trial start.
# * registry **search** endpoints, which agents used to discover the task's
#   packages and their release history.

REGISTRY_HOSTS: dict[str, str] = {
    "registry.npmjs.org": "npm", "registry.yarnpkg.com": "npm",
    "pypi.org": "pypi", "files.pythonhosted.org": "pypi_files",
    "crates.io": "crates", "index.crates.io": "crates_index", "static.crates.io": "crates_dl",
}

_PEP503 = re.compile(r"[-_.]+")


def norm_pypi(name: str) -> str:
    return _PEP503.sub("-", name).lower()


def norm_npm(name: str) -> str:
    return name.replace("%2f", "/").replace("%2F", "/").lower()


def norm_crate(name: str) -> str:
    return name.replace("_", "-").lower()


class DenyPackages:
    """The per-trial set of package names that must not come from a registry."""

    def __init__(self, npm: list[str] | None = None, pypi: list[str] | None = None,
                 crates: list[str] | None = None) -> None:
        self.npm = frozenset(norm_npm(n) for n in (npm or []) if n)
        self.pypi = frozenset(norm_pypi(n) for n in (pypi or []) if n)
        self.crates = frozenset(norm_crate(n) for n in (crates or []) if n)

    @classmethod
    def from_dict(cls, d: dict | None) -> "DenyPackages":
        d = d or {}
        return cls(d.get("npm"), d.get("pypi"), d.get("crates"))

    def to_dict(self) -> dict:
        return {"npm": sorted(self.npm), "pypi": sorted(self.pypi), "crates": sorted(self.crates)}

    def __bool__(self) -> bool:
        return bool(self.npm or self.pypi or self.crates)


_NPM_TARBALL = re.compile(r"^/(@[^/]+/)?([^/]+)/-/", re.I)
_PYPI_FILE = re.compile(r"^/packages/[^/]+/[^/]+/[^/]+/([^/]+)$")
_DIST_NAME = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_.]*?)-\d")


def registry_decision(host: str, method: str, path: str, deny: DenyPackages) -> str | None:
    """A ``deny:`` reason for a registry request, or None when it may proceed."""
    kind = REGISTRY_HOSTS.get(host.lower())
    if kind is None:
        return None
    p = path.split("?", 1)[0]
    query = path[len(p):]
    if kind == "npm":
        if p.startswith("/-/v1/search") or p.startswith("/-/all") or p.startswith("/search"):
            return "deny:npm registry search"
        segs = [s for s in p.split("/") if s]
        name = None
        if segs:
            if segs[0] == "-" and len(segs) >= 3 and segs[1] == "package":
                name = segs[2]
            elif segs[0].startswith("@") and len(segs) >= 2 and "/" not in segs[0] and "%2f" not in segs[0].lower():
                name = f"{segs[0]}/{segs[1]}"
            else:
                name = segs[0]
        if name and norm_npm(name) in deny.npm:
            return f"deny:task's own npm package {norm_npm(name)}"
        m = _NPM_TARBALL.match(p)
        if m and norm_npm((m.group(1) or "") + m.group(2)) in deny.npm:
            return f"deny:task's own npm package {norm_npm((m.group(1) or '') + m.group(2))}"
        return None
    if kind == "pypi":
        if p.startswith("/search") or (p == "/" and "q=" in query):
            return "deny:pypi search"
        segs = [s for s in p.split("/") if s]
        if len(segs) >= 2 and segs[0] in ("simple", "pypi", "project", "p"):
            if norm_pypi(segs[1]) in deny.pypi:
                return f"deny:task's own PyPI project {norm_pypi(segs[1])}"
        return None
    if kind == "pypi_files":
        m = _PYPI_FILE.match(p)
        if m:
            dm = _DIST_NAME.match(m.group(1))
            if dm and norm_pypi(dm.group(1)) in deny.pypi:
                return f"deny:task's own PyPI distribution {norm_pypi(dm.group(1))}"
        return None
    if kind in ("crates", "crates_index", "crates_dl"):
        if kind == "crates" and (p.startswith("/api/v1/crates") and ("q=" in query or p.rstrip("/") == "/api/v1/crates")):
            return "deny:crates.io search"
        segs = [s for s in p.split("/") if s]
        name = None
        if kind == "crates_dl" and len(segs) >= 2 and segs[0] == "crates":
            name = segs[1]
        elif kind == "crates" and len(segs) >= 4 and segs[:3] == ["api", "v1", "crates"]:
            name = segs[3]
        elif kind == "crates_index" and segs and segs[-1] != "config.json":
            name = segs[-1]
        if name and norm_crate(name) in deny.crates:
            return f"deny:task's own crate {norm_crate(name)}"
        return None
    return None


#: Shell run inside the container at trial start to list the workspace's own
#: package names. POSIX sh + find/sed/tr only (several task images have no python3).
#: Output: one line per ``kind<TAB>name``; the host turns it into the denylist.
_PKGSCAN_TEMPLATE = r"""set +e
ROOT=__ROOT__
find "$ROOT" -maxdepth 7 \( -name node_modules -o -name .git -o -name target -o -name dist -o -name build -o -name .venv -o -name venv -o -name vendor -o -name site-packages -o -name __pycache__ -o -name .tox -o -name .cache \) -prune -o -type f \( -name package.json -o -name pyproject.toml -o -name setup.py -o -name setup.cfg -o -name Cargo.toml \) -print 2>/dev/null | while IFS= read -r f; do
  case "$f" in
    */package.json) tr ',{}' '\n\n\n' < "$f" | sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/npm\t\1/p' | head -1 ;;
    */pyproject.toml) sed -n "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/pypi\t\1/p" "$f" ;;
    */setup.py) tr ',()' '\n\n\n' < "$f" | sed -n "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/pypi\t\1/p" ;;
    */setup.cfg) sed -n 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/pypi\t\1/p' "$f" | head -1 ;;
    */Cargo.toml) sed -n "s/^[[:space:]]*name[[:space:]]*=[[:space:]]*[\"']\([^\"']*\)[\"'].*/crates\t\1/p" "$f" ;;
  esac
done
b=$(basename "$ROOT"); printf 'npm\t%s\npypi\t%s\ncrates\t%s\n' "$b" "$b" "$b"
echo SWT_PKGSCAN_DONE
"""


def workspace_packages_script(workdir: str) -> str:
    import shlex
    return _PKGSCAN_TEMPLATE.replace("__ROOT__", shlex.quote(workdir))


def parse_workspace_packages(stdout: str) -> dict[str, list[str]]:
    """``kind<TAB>name`` lines from :func:`workspace_packages_script` → denylist dict."""
    out: dict[str, set[str]] = {"npm": set(), "pypi": set(), "crates": set()}
    for line in stdout.splitlines():
        if "\t" not in line:
            continue
        kind, _, name = line.partition("\t")
        name = name.strip()
        if kind in out and 0 < len(name) < 200 and not name.startswith("$") and "{" not in name:
            out[kind].add(name)
    return {k: sorted(v) for k, v in out.items()}
