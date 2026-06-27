"""Build an E2B template from a task's Dockerfile, working around E2B parser bugs.

E2B's `Template().from_dockerfile()` parses ENV instructions literally — `${PATH}`
is captured as the literal string instead of expanding from the prior PATH. This
breaks any Dockerfile that does `ENV PATH="/new/bin:${PATH}"`, which is most
of our task Dockerfiles (Go, Cargo, Bun installs all do this).

Fix: preprocess the Dockerfile to substitute `${VAR}` and `$VAR` references in
ENV instructions with their already-resolved values (tracking a small env-var
table as we parse).

Usage:
    .venv/bin/python -m eval.correctness.build_template <task-name>
    # or programmatically:
    from eval.correctness.build_template import build_one
    asyncio.run(build_one("cli-task-2c3e30"))
"""
from __future__ import annotations

import asyncio
import os
import re
import sys
import tomllib
from pathlib import Path

from e2b import AsyncTemplate, Template

REPO_ROOT = Path(__file__).resolve().parents[2]
TASKS_DIR = REPO_ROOT / "tasks"

# Standard Ubuntu base PATH — used as the starting point for PATH expansion
# since `FROM ubuntu:24.04` provides this.
_UBUNTU_BASE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Match $VAR or ${VAR}
_VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")


def _expand_vars(value: str, env: dict[str, str]) -> str:
    """Expand $VAR and ${VAR} references using the env dict."""
    def repl(m: re.Match) -> str:
        name = m.group(1) or m.group(2)
        return env.get(name, m.group(0))
    return _VAR_RE.sub(repl, value)


def _merge_continuations(text: str) -> list[str]:
    """Merge Dockerfile line continuations (trailing `\\`) into single logical lines."""
    logical: list[str] = []
    buf = ""
    for raw_line in text.splitlines():
        # Strip trailing whitespace but preserve indent for readability
        line = raw_line.rstrip()
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        logical.append(buf)
        buf = ""
    if buf:
        logical.append(buf)
    return logical


def preprocess_dockerfile(dockerfile_text: str) -> str:
    """Walk the Dockerfile, expanding env var refs in ENV instructions.

    Only ENV is preprocessed; RUN instructions are left alone (they execute in a
    real shell at build time and expand vars naturally).

    Handles multi-line ENV with backslash continuations:
        ENV PATH="/usr/local/go/bin:$PATH" \\
            GOPATH="/go" \\
            GOMODCACHE="/go/pkg/mod"
    becomes a single ENV with three pairs, with $PATH and $GOPATH expanded.
    """
    env: dict[str, str] = {"PATH": _UBUNTU_BASE_PATH}
    out_lines: list[str] = []
    for logical_line in _merge_continuations(dockerfile_text):
        line = logical_line
        stripped = line.lstrip()
        if stripped.upper().startswith("ENV "):
            body = stripped[4:]
            if "=" in body:
                pairs = re.findall(r'(\w+)=("[^"]*"|\S+)', body)
                rewritten_parts = []
                for k, v in pairs:
                    v_unq = v.strip('"').strip("'")
                    v_expanded = _expand_vars(v_unq, env)
                    env[k] = v_expanded
                    rewritten_parts.append(f'{k}={v_expanded}')
                line = f"ENV {' '.join(rewritten_parts)}"
            else:
                parts = body.split(None, 1)
                if len(parts) == 2:
                    k, v = parts
                    v_expanded = _expand_vars(v.strip('"').strip("'"), env)
                    env[k] = v_expanded
                    line = f"ENV {k}={v_expanded}"
        out_lines.append(line)
    return "\n".join(out_lines) + "\n"


def load_task_resources(task_dir: Path) -> tuple[int, int]:
    """Return (cpu_count, memory_mb) from task.toml."""
    task_toml = task_dir / "task.toml"
    cfg = tomllib.loads(task_toml.read_text())
    env_cfg = cfg.get("environment", {}) or {}
    cpus = int(env_cfg.get("cpus", 4))
    mem_raw = env_cfg.get("memory", "4G")
    if isinstance(mem_raw, str):
        unit = mem_raw[-1].upper()
        n = int(mem_raw[:-1])
        if unit == "G":
            mem_mb = n * 1024
        elif unit == "M":
            mem_mb = n
        else:
            mem_mb = int(mem_raw)
    else:
        mem_mb = int(mem_raw)
    return cpus, mem_mb


async def build_one(task_name: str, *, force: bool = False) -> str:
    """Build (or rebuild) the E2B template for one task. Returns the alias."""
    from eval.correctness.sandbox import template_alias

    task_dir = TASKS_DIR / task_name
    if not task_dir.is_dir():
        raise FileNotFoundError(f"task dir not found: {task_dir}")

    dockerfile_path = task_dir / "environment" / "Dockerfile"
    if not dockerfile_path.exists():
        raise FileNotFoundError(f"Dockerfile not found: {dockerfile_path}")

    alias = template_alias(task_name)
    if not force and await AsyncTemplate.alias_exists(alias):
        print(f"[{task_name}] template already exists: {alias}")
        return alias

    cpus, memory_mb = load_task_resources(task_dir)
    raw = dockerfile_path.read_text()
    preprocessed = preprocess_dockerfile(raw)

    print(f"[{task_name}] building template={alias} cpus={cpus} memory={memory_mb}MB")
    template = Template().from_dockerfile(dockerfile_content_or_path=preprocessed)
    await AsyncTemplate.build(
        template=template,
        alias=alias,
        cpu_count=cpus,
        memory_mb=memory_mb,
    )
    print(f"[{task_name}] build complete")
    return alias


def _load_dotenv() -> None:
    env_file = REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


async def amain() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("task_name")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    _load_dotenv()
    if not os.environ.get("E2B_API_KEY"):
        print("ERROR: E2B_API_KEY not set", file=sys.stderr)
        return 2
    await build_one(args.task_name, force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain()))
