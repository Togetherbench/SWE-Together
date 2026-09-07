"""Host-side enroot runtime: tmpfs paths, subprocess plumbing, process cleanup.

The facts below were measured on the cluster this was developed on and are
load-bearing (re-verify with ``scripts/slurm/smoke_enroot.py`` on yours):

* ``ENROOT_TEMP_PATH`` / ``ENROOT_DATA_PATH`` must be tmpfs. Lustre/NFS cannot host
  whiteout devices, and the failure message does not say so.
* enroot creates **no PID namespace**. A daemon left behind by one ``enroot start``
  survives the exec, survives ``enroot remove -f``, and must be killed by us. Every
  exec is tagged with ``SWT_CONTAINER=<name>`` so we can find its processes in
  ``/proc/*/environ``.
* Nothing here relies on enroot 4.x-only behaviour; 3.5.0 is the floor.
"""

from __future__ import annotations

import asyncio
import atexit
import logging
import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from types import FrameType

log = logging.getLogger(__name__)

CONTAINER_PREFIX = "swt-"
CONTAINER_ENV_MARKER = "SWT_CONTAINER"
MIN_FREE_GB_PER_CONTAINER = 8.0
REMOVE_TIMEOUT_S = 180.0
STDERR_NOISE_MARKERS = ("enroot-mount",)


class EnrootSetupError(RuntimeError):
    """The host cannot host a container right now (tmpfs missing/full, create failed).

    Distinct class name on purpose: Harbor's RetryConfig matches on
    ``type(e).__name__``, and this one is worth retrying after a backoff.
    """


class EnrootImageUnavailable(RuntimeError):
    """An image could not be found, imported, or validated. Not retryable."""


@dataclass
class CommandResult:
    stdout: str
    stderr: str
    return_code: int


class EnrootRuntime:
    """Paths and environment every ``enroot`` subprocess runs with.

    Layout (all under tmpfs)::

        <root>/tmp    ENROOT_TEMP_PATH
        <root>/data   ENROOT_DATA_PATH   (rootfs of each created container lives here)
        <root>/ctmp   per-container persistent /tmp sources, mounted over the
                      container's /tmp; kept outside data/ so `enroot list` ignores them
        <root>/hosts  generated /etc/hosts with the DNS sinkhole
    """

    def __init__(
        self,
        *,
        base: str | Path | None = None,
        job_id: str | None = None,
        max_processors: int = 2,
        mount_home: bool = False,
    ) -> None:
        job = job_id or os.environ.get("SLURM_JOB_ID") or f"local-{os.getpid()}"
        user = os.environ.get("USER", "unknown")
        if base is not None:
            base_path = Path(base)
        else:
            from sandbox_config import enroot_base
            base_path = enroot_base()
        self.job_id = job
        self.root = base_path / user / str(job)
        self.temp_path = self.root / "tmp"
        self.data_path = self.root / "data"
        self.ctmp_path = self.root / "ctmp"
        self.hosts_path = self.root / "hosts"
        self.max_processors = max_processors
        self.mount_home = mount_home
        self._prepared = False

    def prepare(self, *, min_free_gb: float = MIN_FREE_GB_PER_CONTAINER) -> None:
        for p in (self.temp_path, self.data_path, self.ctmp_path):
            p.mkdir(parents=True, exist_ok=True)
        for p in (self.temp_path, self.data_path):
            if not is_tmpfs(p):
                raise EnrootSetupError(
                    f"{p} is not on tmpfs. enroot cannot create whiteout devices on "
                    f"Lustre/NFS and fails with an unrelated-looking mount error. "
                    f"Point SWT_ENROOT_BASE at /dev/shm."
                )
        free = free_space_gb(self.temp_path)
        if free < min_free_gb:
            raise EnrootSetupError(
                f"only {free:.1f}GB free on {self.temp_path}; need at least "
                f"{min_free_gb}GB per container. Stale containers from a preempted "
                f"job are the usual cause (scripts/slurm/launch.py cleanup)."
            )
        self._prepared = True

    def as_env(self) -> dict[str, str]:
        env = dict(os.environ)
        env.update(
            {
                "ENROOT_TEMP_PATH": str(self.temp_path),
                "ENROOT_DATA_PATH": str(self.data_path),
                "ENROOT_MAX_PROCESSORS": str(self.max_processors),
                "ENROOT_MOUNT_HOME": "y" if self.mount_home else "n",
                "NVIDIA_VISIBLE_DEVICES": "void",
            }
        )
        return env

    def rootfs(self, name: str) -> Path:
        return self.data_path / name

    async def run(
        self,
        argv: list[str],
        *,
        timeout: float | None,
        stdout_path: Path | None = None,
        stderr_path: Path | None = None,
    ) -> CommandResult:
        """Run one enroot command. Never raises on non-zero exit.

        stdout/stderr go to files, not pipes: a background process inside the
        container that inherits a pipe keeps ``communicate()`` blocked forever
        (measured). The enroot child gets its own session so a timeout or
        cancellation can ``killpg`` it and everything it spawned that still
        shares the group.
        """
        own_out = stdout_path is None
        own_err = stderr_path is None
        if own_out:
            stdout_path = self.temp_path / f".run-{os.getpid()}-{time.monotonic_ns()}.out"
        if own_err:
            stderr_path = self.temp_path / f".run-{os.getpid()}-{time.monotonic_ns()}.err"
        assert stdout_path is not None and stderr_path is not None
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            with open(stdout_path, "wb") as out_f, open(stderr_path, "wb") as err_f:
                proc = await asyncio.create_subprocess_exec(
                    *argv,
                    stdin=asyncio.subprocess.DEVNULL,
                    stdout=out_f,
                    stderr=err_f,
                    env=self.as_env(),
                    start_new_session=True,
                )
                try:
                    if timeout is None:
                        rc = await proc.wait()
                    else:
                        rc = await asyncio.wait_for(proc.wait(), timeout=timeout)
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    _killpg(proc.pid)
                    try:
                        await asyncio.wait_for(proc.wait(), timeout=10)
                    except asyncio.TimeoutError:
                        pass
                    raise
            stdout = _read_text(stdout_path)
            stderr = filter_stderr(_read_text(stderr_path))
        finally:
            if own_out:
                stdout_path.unlink(missing_ok=True)
            if own_err:
                stderr_path.unlink(missing_ok=True)
        return CommandResult(stdout=stdout, stderr=stderr, return_code=rc)

    def run_sync(self, argv: list[str], *, timeout: float) -> CommandResult:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            env=self.as_env(),
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        return CommandResult(
            stdout=proc.stdout, stderr=filter_stderr(proc.stderr), return_code=proc.returncode
        )

    def describe(self) -> dict[str, str]:
        return {
            "job_id": self.job_id,
            "temp_path": str(self.temp_path),
            "data_path": str(self.data_path),
            "ctmp_path": str(self.ctmp_path),
        }


# ── process cleanup ──────────────────────────────────────────────────────

def find_container_pids(name: str) -> list[int]:
    """PIDs whose environment carries ``SWT_CONTAINER=<name>``.

    Only processes we own have a readable ``/proc/<pid>/environ``; that is
    exactly the set enroot started for us (same uid, no user namespace remap on
    the host side).
    """
    needle = f"{CONTAINER_ENV_MARKER}={name}".encode()
    me = os.getpid()
    pids: list[int] = []
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == me:
            continue
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                environ = f.read()
        except OSError:
            continue
        if needle in environ.split(b"\0"):
            pids.append(pid)
    return pids


def kill_container_processes(name: str, *, grace_sec: float = 2.0) -> int:
    """SIGTERM then SIGKILL everything tagged with this container. Returns count."""
    pids = find_container_pids(name)
    if not pids:
        return 0
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
            except PermissionError:
                log.warning("cannot signal pid %d for container %s", pid, name)
        if sig == signal.SIGTERM:
            deadline = time.time() + grace_sec
            while time.time() < deadline and find_container_pids(name):
                time.sleep(0.2)
            pids = find_container_pids(name)
            if not pids:
                break
    return len(pids)


_LIVE: dict[str, EnrootRuntime] = {}
_CLEANUP_REGISTERED = False


def track(name: str, runtime: EnrootRuntime) -> None:
    _LIVE[name] = runtime


def untrack(name: str) -> None:
    _LIVE.pop(name, None)


def remove_container_sync(name: str, runtime: EnrootRuntime) -> None:
    """Best-effort synchronous teardown used by atexit/signal handlers."""
    try:
        kill_container_processes(name)
    except Exception:  # noqa: BLE001
        pass
    try:
        subprocess.run(
            ["enroot", "remove", "-f", name],
            capture_output=True, check=False, timeout=REMOVE_TIMEOUT_S,
            env=runtime.as_env(),
        )
    except Exception:  # noqa: BLE001
        pass
    try:
        import shutil
        shutil.rmtree(runtime.ctmp_path / name, ignore_errors=True)
    except Exception:  # noqa: BLE001
        pass


def _cleanup_all() -> None:
    for name, runtime in list(_LIVE.items()):
        remove_container_sync(name, runtime)
        _LIVE.pop(name, None)


def register_cleanup() -> None:
    """Remove leftover containers on exit or SIGTERM (Slurm preemption)."""
    global _CLEANUP_REGISTERED
    if _CLEANUP_REGISTERED:
        return
    _CLEANUP_REGISTERED = True
    atexit.register(_cleanup_all)

    def handler(signum: int, frame: FrameType | None) -> None:
        log.warning("signal %s received; removing %d container(s)", signum, len(_LIVE))
        _cleanup_all()
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, handler)
        except (ValueError, OSError):
            pass


def list_containers(runtime: EnrootRuntime) -> list[str]:
    try:
        res = runtime.run_sync(["enroot", "list"], timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    return [line.strip() for line in res.stdout.splitlines() if line.strip()]


def remove_stale(runtime: EnrootRuntime, prefix: str = CONTAINER_PREFIX) -> list[str]:
    """Remove leftover containers carrying ``prefix`` under this runtime's data path."""
    removed: list[str] = []
    for name in list_containers(runtime):
        if not name.startswith(prefix):
            continue
        remove_container_sync(name, runtime)
        removed.append(name)
    return removed


# ── small helpers ────────────────────────────────────────────────────────

def is_tmpfs(path: Path) -> bool:
    try:
        out = subprocess.run(
            ["stat", "-f", "-c", "%T", str(path)],
            capture_output=True, text=True, check=False, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return out.stdout.strip() in {"tmpfs", "ramfs"}


def free_space_gb(path: Path) -> float:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1024**3


def filter_stderr(stderr: str) -> str:
    """Drop the ``enroot-mount`` chatter a *successful* start writes to stderr."""
    if not stderr or not any(m in stderr for m in STDERR_NOISE_MARKERS):
        return stderr
    return "\n".join(
        line for line in stderr.splitlines()
        if not any(m in line for m in STDERR_NOISE_MARKERS)
    )


def enroot_available() -> bool:
    import shutil
    return shutil.which("enroot") is not None


def enroot_version() -> str:
    try:
        out = subprocess.run(
            ["enroot", "version"], capture_output=True, text=True, check=False, timeout=30
        )
        return (out.stdout or out.stderr).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return f"unavailable: {exc}"


def _killpg(pid: int) -> None:
    try:
        os.killpg(os.getpgid(pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def _read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""
