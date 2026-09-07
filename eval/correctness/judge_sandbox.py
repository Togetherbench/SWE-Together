"""Sandbox backends for the agentic judge.

`run_judge` in ``sandbox.py`` needs four operations from a sandbox: write a file,
run a command, read a file, tear down. ``E2BJudgeSandbox`` wraps the E2B SDK
exactly as the judge used it before; ``EnrootJudgeSandbox`` reuses the Stage-1
enroot primitives (``src/enroot_backend``).

Selection follows the top-level ``SWT_SANDBOX`` switch (``src/sandbox_config.py``);
``JUDGE_SANDBOX`` overrides it for the judge alone.
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

log = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parents[2]
TASKS_DIR = REPO_ROOT / "tasks"
if str(REPO_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "src"))

from sandbox_config import judge_sandbox as selected_backend  # noqa: E402,F401


def check_backend_prereqs(backend: str) -> str | None:
    """Return an error message if the backend cannot run here, else None."""
    if backend == "e2b":
        if not os.environ.get("E2B_API_KEY"):
            return "E2B_API_KEY not set (or choose SWT_SANDBOX=enroot / JUDGE_SANDBOX=enroot)"
        return None
    from enroot_backend.runtime import enroot_available
    if not enroot_available():
        return "judge sandbox is enroot but the `enroot` binary is not on PATH"
    return None


@dataclass
class CmdResult:
    stdout: str
    stderr: str
    exit_code: int


class JudgeSandbox(Protocol):
    sandbox_id: str

    async def write(self, path: str, content: str | bytes) -> None: ...
    async def run(self, cmd: str, *, timeout: int, cwd: str | None = None,
                  user: str | None = None) -> CmdResult: ...
    async def read(self, path: str) -> str: ...
    async def kill(self) -> None: ...


# ── E2B ───────────────────────────────────────────────────────────────────

class E2BJudgeSandbox:
    def __init__(self, sb, envs: dict[str, str]):
        self._sb = sb
        self._envs = envs
        self.sandbox_id: str = sb.sandbox_id

    @classmethod
    async def create(cls, template: str, envs: dict[str, str], timeout_sec: int,
                     buffer_sec: int) -> "E2BJudgeSandbox":
        from e2b import AsyncSandbox

        last_err: Exception | None = None
        for attempt in range(3):
            try:
                log.info("spawning E2B sandbox: template=%s (attempt %d)", template, attempt + 1)
                sb = await AsyncSandbox.create(
                    template=template,
                    envs=envs,
                    timeout=timeout_sec + buffer_sec,
                    allow_internet_access=True,
                )
                return cls(sb, envs)
            except Exception as e:  # noqa: BLE001
                msg = str(e)
                if ("ProtocolError" in type(e).__name__ or "SEND_SETTINGS" in msg
                        or "ConnectionState.CLOSED" in msg):
                    last_err = e
                    wait = 2 ** attempt
                    log.warning("sandbox spawn ProtocolError attempt %d, retrying in %ds: %s",
                                attempt + 1, wait, msg[:120])
                    await asyncio.sleep(wait)
                    continue
                raise
        raise last_err or RuntimeError("sandbox spawn failed after retries")

    async def write(self, path: str, content: str | bytes) -> None:
        await self._sb.files.write(path, content)

    async def run(self, cmd: str, *, timeout: int, cwd: str | None = None,
                  user: str | None = None) -> CmdResult:
        from e2b.sandbox.commands.command_handle import CommandExitException
        kwargs: dict = {"timeout": timeout}
        if cwd:
            kwargs["cwd"] = cwd
        if user:
            kwargs["user"] = user
        try:
            r = await self._sb.commands.run(cmd, **kwargs)
            return CmdResult(r.stdout or "", r.stderr or "", r.exit_code)
        except CommandExitException as e:
            return CmdResult(getattr(e, "stdout", "") or "", getattr(e, "stderr", "") or str(e),
                             getattr(e, "exit_code", 1))

    async def read(self, path: str) -> str:
        return await self._sb.files.read(path)

    async def kill(self) -> None:
        await self._sb.kill()


# ── enroot ────────────────────────────────────────────────────────────────

class EnrootJudgeSandbox:
    """Judge inside an enroot container of the task image.

    Root, persistent /tmp (the judge prompts hardcode /tmp/judge_inputs), no DNS
    sinkhole (the judge may legitimately fetch upstream docs, matching E2B's
    ``allow_internet_access=True``). ``envs`` (the model auth tuple) is injected on
    every exec via ``-e`` since a container has no sandbox-level env.
    """

    def __init__(self, container, envs: dict[str, str]):
        self._c = container
        self._envs = envs
        self.sandbox_id: str = container.name

    @classmethod
    async def create(cls, task_name: str, envs: dict[str, str]) -> "EnrootJudgeSandbox":
        from enroot_backend.container import EnrootContainer
        from enroot_backend.images import ImageStore, docker_image_for_task
        from enroot_backend.runtime import EnrootRuntime, register_cleanup

        register_cleanup()
        task_dir = TASKS_DIR / task_name
        sqsh = await asyncio.to_thread(
            ImageStore().ensure_image, docker_image_for_task(task_dir)
        )
        container = EnrootContainer(
            EnrootRuntime(), sqsh, name_hint=f"judge-{task_name}", workdir="/",
            mounts=[], persist_tmp=True,
        )
        await container.create()
        return cls(container, envs)

    async def write(self, path: str, content: str | bytes) -> None:
        if isinstance(content, bytes):
            self._c.write_bytes(path, content)
        else:
            self._c.write_text(path, content)

    async def run(self, cmd: str, *, timeout: int, cwd: str | None = None,
                  user: str | None = None) -> CmdResult:
        # user is ignored: enroot execs are always root (--root), which is what
        # every E2B call site here wanted anyway. Claude Code refuses
        # --dangerously-skip-permissions as root unless IS_SANDBOX=1 — the same
        # switch Harbor's claude_code adapter sets for containerised runs.
        env = {"IS_SANDBOX": "1", **self._envs}
        r = await self._c.exec(cmd, cwd=cwd, env=env, timeout=float(timeout))
        return CmdResult(r.stdout, r.stderr, r.return_code)

    async def read(self, path: str) -> str:
        return self._c.read_text(path)

    async def kill(self) -> None:
        await self._c.remove()


# ── factory ───────────────────────────────────────────────────────────────

async def open_judge_sandbox(
    *,
    task_name: str,
    e2b_template: str,
    envs: dict[str, str],
    timeout_sec: int,
    buffer_sec: int,
) -> JudgeSandbox:
    backend = selected_backend()
    if backend == "enroot":
        return await EnrootJudgeSandbox.create(task_name, envs)
    return await E2BJudgeSandbox.create(e2b_template, envs, timeout_sec, buffer_sec)
