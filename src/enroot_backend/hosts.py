"""DNS-sinkhole ``/etc/hosts`` for enroot trials.

The task images defeat answer leakage by appending ``127.0.0.1 github.com
huggingface.co …`` to ``/etc/hosts`` at shell start (``environment/seal-dns.sh``).
enroot bind-mounts the host's ``/etc/hosts`` read-only, so that append silently
fails; instead we generate one hosts file from the canonical entry list and mount
it over ``/etc/hosts`` on every Stage-1 exec. Applied to all tasks, including the
10 whose image lacks the script.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

log = logging.getLogger(__name__)

_ENTRIES_RE = re.compile(r"_entries='([^']+)'")


def sinkhole_entries(tasks_root: Path) -> list[str]:
    """Hostnames sinkholed by ``tasks/*/environment/seal-dns.sh`` (union, sorted)."""
    per_task: dict[str, frozenset[str]] = {}
    for script in sorted(Path(tasks_root).glob("*/environment/seal-dns.sh")):
        m = _ENTRIES_RE.search(script.read_text())
        if not m:
            continue
        tokens = m.group(1).split()
        hosts = frozenset(t for t in tokens if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", t))
        per_task[script.parent.parent.name] = hosts
    if not per_task:
        raise FileNotFoundError(f"no environment/seal-dns.sh found under {tasks_root}")
    variants = set(per_task.values())
    if len(variants) > 1:
        log.warning(
            "seal-dns.sh entry lists differ across %d tasks (%d variants); using the union",
            len(per_task), len(variants),
        )
    return sorted(set().union(*variants))


def render_hosts_file(entries: list[str], base_hosts: str | None = None) -> str:
    base = base_hosts if base_hosts is not None else _read_host_etc_hosts()
    lines = [ln for ln in base.splitlines() if ln.strip()]
    if not any(ln.split()[0] == "127.0.0.1" and "localhost" in ln.split() for ln in lines):
        lines.insert(0, "127.0.0.1 localhost")
    lines.append("# SWE-Together DNS sinkhole (from tasks/*/environment/seal-dns.sh)")
    lines.append("127.0.0.1 " + " ".join(entries))
    return "\n".join(lines) + "\n"


def write_hosts_file(path: Path, tasks_root: Path) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_hosts_file(sinkhole_entries(tasks_root)))
    return path


def _read_host_etc_hosts() -> str:
    try:
        return Path("/etc/hosts").read_text()
    except OSError:
        return "127.0.0.1 localhost\n"
