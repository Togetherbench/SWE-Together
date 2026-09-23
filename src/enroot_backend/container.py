"""One enroot container: create, exec, file transfer, remove.

Shared by the Harbor ``EnrootEnvironment`` (Stage 1) and the judge sandbox
(Stage 2) so the container rules live in one place:

* ``enroot start --root --rw``: uid 0 inside, rootfs writes persist across
  execs. Harbor's agent installers (apt/npm) and E2B semantics (``user="root"``)
  both need this.
* ``--mount <ctmp>:/tmp``: enroot mounts a *fresh* tmpfs on ``/tmp`` for every
  start, which would lose ``/tmp/model_proxy.py``, ``/tmp/judge_inputs``, etc.
* ``bash -c`` (not ``-lc``): the image's Dockerfile ``ENV`` (PATH, GOPATH…) is
  injected by enroot from ``<rootfs>/etc/environment``; a login shell would run
  ``/etc/profile`` which resets PATH.
* The wrapped command's output is redirected to files inside the persistent
  ``/tmp`` and read back from the host. A background daemon that inherits a
  pipe blocks the parent forever; a file does not.
* With an ``egress`` namespace (Stage 1 agent trials), every ``enroot start`` is
  prefixed with ``nsenter`` into the container's user+network namespace and the
  proxy environment is injected; the container then has no route except the
  relay to the host-side egress proxy (``netns.py``).
"""

from __future__ import annotations

import logging
import shlex
import shutil
import uuid
from pathlib import Path, PurePosixPath

from .netns import EgressNamespace
from .runtime import (
    CONTAINER_ENV_MARKER,
    CONTAINER_PREFIX,
    CommandResult,
    EnrootRuntime,
    EnrootSetupError,
    kill_container_processes,
    track,
    untrack,
)

log = logging.getLogger(__name__)

CREATE_TIMEOUT_S = 1800.0
REMOVE_TIMEOUT_S = 180.0
_IO_DIR = ".swt-io"


def sanitize_name(text: str, limit: int = 40) -> str:
    safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in text)
    return safe[:limit].strip("-") or "task"


class EnrootContainer:
    def __init__(
        self,
        runtime: EnrootRuntime,
        image_path: str | Path,
        *,
        name_hint: str,
        workdir: str = "/",
        mounts: list[tuple[str | Path, str]] | None = None,
        persist_tmp: bool = True,
        egress: EgressNamespace | None = None,
    ) -> None:
        self.runtime = runtime
        self.image_path = Path(image_path)
        self.workdir = workdir
        self.persist_tmp = persist_tmp
        # When set, every exec runs inside this container's network namespace and
        # the only way out is the egress proxy (see netns.py). None = host network
        # (the judge sandbox, which sees the oracle patch anyway).
        self.egress = egress
        self._extra_mounts: list[tuple[Path, str]] = [
            (Path(h), c) for h, c in (mounts or [])
        ]
        self.name = self._new_name(name_hint)
        self._hint = name_hint
        self._created = False
        self.exec_count = 0

    def _new_name(self, hint: str) -> str:
        return f"{CONTAINER_PREFIX}{sanitize_name(hint)}-{uuid.uuid4().hex[:8]}"

    # ── paths ─────────────────────────────────────────────────────────

    @property
    def rootfs(self) -> Path:
        return self.runtime.rootfs(self.name)

    @property
    def tmp_host_dir(self) -> Path:
        return self.runtime.ctmp_path / self.name

    def mounts(self) -> list[tuple[Path, str]]:
        m = list(self._extra_mounts)
        if self.persist_tmp:
            m.append((self.tmp_host_dir, "/tmp"))
        return m

    def host_path(self, container_path: str) -> Path:
        """Host location of a container path, honouring bind mounts.

        Longest-prefix match over the registered mounts, else the rootfs. Without
        this, writing ``/tmp/x`` host-side would land *under* the /tmp mount and be
        invisible inside the container.
        """
        cpath = PurePosixPath(container_path)
        best: tuple[int, Path, PurePosixPath] | None = None
        for host, cont in self.mounts():
            cont_p = PurePosixPath(cont)
            if cpath == cont_p or cont_p in cpath.parents:
                depth = len(cont_p.parts)
                if best is None or depth > best[0]:
                    best = (depth, host, cont_p)
        if best is None:
            return self.rootfs / cpath.relative_to("/")
        _, host, cont_p = best
        rel = cpath.relative_to(cont_p)
        return host / rel if str(rel) != "." else host

    # ── lifecycle ─────────────────────────────────────────────────────

    async def create(self, *, max_attempts: int = 3) -> "EnrootContainer":
        if self._created:
            return self
        if not self.image_path.is_file():
            raise EnrootSetupError(f"image not found: {self.image_path}")
        self.runtime.prepare()

        last = ""
        for attempt in range(max_attempts):
            if attempt:
                self.name = self._new_name(self._hint)
            res = await self.runtime.run(
                ["enroot", "create", "--name", self.name, str(self.image_path)],
                timeout=CREATE_TIMEOUT_S,
            )
            if res.return_code == 0 and self.rootfs.is_dir():
                break
            last = res.stderr or res.stdout
            if "File already exists" in last:
                log.warning("container name %s exists; retrying with a new name", self.name)
                continue
            raise EnrootSetupError(
                f"enroot create failed for {self.image_path.name}: {last.strip()[-500:]}"
            )
        else:
            raise EnrootSetupError(
                f"enroot create failed for {self.image_path.name} after "
                f"{max_attempts} attempt(s): {last.strip()[-500:]}"
            )

        self._created = True
        track(self.name, self.runtime)
        # Mountpoints must exist in the rootfs before `--mount` targets them, and
        # the persistent /tmp source must exist host-side.
        for _, cont in self.mounts():
            target = self.rootfs / PurePosixPath(cont).relative_to("/")
            if PurePosixPath(cont).suffix or cont == "/etc/hosts":
                target.parent.mkdir(parents=True, exist_ok=True)
                if not target.exists():
                    target.touch()
            else:
                target.mkdir(parents=True, exist_ok=True)
        if self.persist_tmp:
            self.tmp_host_dir.mkdir(parents=True, exist_ok=True)
            (self.tmp_host_dir / _IO_DIR).mkdir(exist_ok=True)
        if self.egress is not None:
            self.egress.container_name = self.name
            try:
                self.egress.start()
            except EnrootSetupError:
                await self.remove()
                raise
        log.info("created container %s from %s%s", self.name, self.image_path.name,
                 f" (egress namespace, relay pid {self.egress.pid})" if self.egress else "")
        return self

    async def remove(self) -> None:
        if not self._created:
            return
        if self.egress is not None:
            self.egress.stop()
        try:
            n = kill_container_processes(self.name)
            if n:
                log.info("killed %d leftover process(es) of %s", n, self.name)
        except Exception as exc:  # noqa: BLE001
            log.warning("process cleanup for %s failed: %s", self.name, exc)
        try:
            res = await self.runtime.run(
                ["enroot", "remove", "-f", self.name], timeout=REMOVE_TIMEOUT_S,
            )
            if res.return_code != 0:
                log.warning("enroot remove %s: %s", self.name, res.stderr[-300:])
        except Exception as exc:  # noqa: BLE001
            log.warning("enroot remove %s raised: %s", self.name, exc)
        finally:
            shutil.rmtree(self.tmp_host_dir, ignore_errors=True)
            self._created = False
            untrack(self.name)

    # ── exec ──────────────────────────────────────────────────────────

    def build_exec_argv(
        self,
        command: str,
        *,
        cwd: str | None,
        env: dict[str, str] | None,
        stdout_in_container: str | None = None,
        stderr_in_container: str | None = None,
    ) -> list[str]:
        argv: list[str] = []
        merged_env: dict[str, str] = {}
        if self.egress is not None:
            argv += self.egress.exec_prefix()
            merged_env.update(sandbox_egress_env())
        merged_env.update(env or {})
        argv += ["enroot", "start", "--root", "--rw"]
        for host, cont in self.mounts():
            argv += ["--mount", f"{host}:{cont}"]
        argv += ["-e", f"{CONTAINER_ENV_MARKER}={self.name}"]
        for k, v in merged_env.items():
            argv += ["-e", f"{k}={v}"]
        script = f"cd {shlex.quote(cwd or self.workdir)} && {command}"
        if stdout_in_container and stderr_in_container:
            script = (
                f"{{ {script}\n}} >{shlex.quote(stdout_in_container)} "
                f"2>{shlex.quote(stderr_in_container)}"
            )
        argv += [self.name, "bash", "-c", script]
        return argv

    async def exec(
        self,
        command: str,
        *,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> CommandResult:
        if not self._created:
            raise EnrootSetupError(f"container {self.name} has not been created")
        self.exec_count += 1
        tag = f"{self.exec_count:04d}-{uuid.uuid4().hex[:6]}"

        # Route the command's own output through files in the persistent /tmp so
        # a daemon the command leaves behind can't hold our pipe open. The enroot
        # process itself also writes to files (runtime.run) for the same reason.
        if self.persist_tmp:
            c_out = f"/tmp/{_IO_DIR}/{tag}.out"
            c_err = f"/tmp/{_IO_DIR}/{tag}.err"
            h_out = self.tmp_host_dir / _IO_DIR / f"{tag}.out"
            h_err = self.tmp_host_dir / _IO_DIR / f"{tag}.err"
        else:
            c_out = c_err = None
            h_out = h_err = None

        argv = self.build_exec_argv(
            command, cwd=cwd, env=env,
            stdout_in_container=c_out, stderr_in_container=c_err,
        )
        try:
            res = await self.runtime.run(argv, timeout=timeout)
        except BaseException:
            if h_out is not None and h_err is not None:
                h_out.unlink(missing_ok=True)
                h_err.unlink(missing_ok=True)
            raise

        if h_out is not None and h_err is not None:
            stdout = _read(h_out) + res.stdout
            stderr = _read(h_err) + res.stderr
            h_out.unlink(missing_ok=True)
            h_err.unlink(missing_ok=True)
        else:
            stdout, stderr = res.stdout, res.stderr
        return CommandResult(stdout=stdout, stderr=stderr, return_code=res.return_code)

    # ── file transfer (host-side, mount-aware) ────────────────────────

    def copy_in(self, src: str | Path, dst_container: str) -> None:
        dst = self.host_path(dst_container)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    def copy_in_dir(self, src_dir: str | Path, dst_container: str) -> None:
        dst = self.host_path(dst_container)
        dst.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src_dir, dst, dirs_exist_ok=True)

    def copy_out(self, src_container: str, dst: str | Path) -> None:
        src = self.host_path(src_container)
        if not src.is_file():
            raise FileNotFoundError(src_container)
        Path(dst).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    def copy_out_dir(self, src_container: str, dst_dir: str | Path) -> None:
        src = self.host_path(src_container)
        if not src.is_dir():
            raise FileNotFoundError(src_container)
        Path(dst_dir).mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst_dir, dirs_exist_ok=True)

    def write_text(self, container_path: str, content: str) -> None:
        p = self.host_path(container_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)

    def write_bytes(self, container_path: str, content: bytes) -> None:
        p = self.host_path(container_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content)

    def read_text(self, container_path: str) -> str:
        return self.host_path(container_path).read_text()

    def __repr__(self) -> str:
        return f"EnrootContainer(name={self.name!r}, created={self._created})"


def sandbox_egress_env() -> dict[str, str]:
    import egress_policy
    return egress_policy.sandbox_env()


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""
