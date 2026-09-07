"""``.sqsh`` image store for SWE-Together task images.

Layout (``SWT_IMAGE_STORE``, default ``<repo>/enroot_images``)::

    <root>/_store/<image_id>.sqsh          the bytes, once
    <root>/swe_together/<image_id>.sqsh    symlink into _store
    <root>/_locks/<image_id>.lock          per-id flock (root level: shared across benchmarks)
    <root>/_store/<image_id>.sqsh.partial  in-flight import

The ``_store`` + per-benchmark-symlink layout lets several benchmarks share one
store root without duplicating bytes; point ``SWT_IMAGE_STORE`` at an existing
store that uses the same convention to reuse it.

``image_id`` is ``<task>__<tag>``; the tag is the 12-hex content hash in
``task.toml``, so an image bump produces a new id and never reuses stale bytes.

Import URL grammar: ``docker://ghcr.io#togetherbench/...:<tag>`` — the registry is
separated by ``#``. ``docker://ghcr.io/owner/image`` is parsed as a Docker Hub
image and fails with 401.

Run as a module for the prepull CLI::

    ENROOT_TEMP_PATH=/dev/shm/... python -m enroot_backend.images prepull \
        --tasks-root tasks --shard 0/8
"""

from __future__ import annotations

import argparse
import fcntl
import logging
import os
import re
import subprocess
import sys
import time
import tomllib
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from .runtime import EnrootImageUnavailable, is_tmpfs

logger = logging.getLogger(__name__)

BENCHMARK = "swe_together"

#: Smallest task image observed is ~0.16 GB compressed (~400 MB sqsh).
MIN_IMAGE_BYTES = 50 * 1024 * 1024
IMPORT_TIMEOUT_S = 3600.0
LOCK_TIMEOUT_S = 2400.0
IMPORT_RETRIES = 3
IMPORT_BACKOFF_S = 20.0
RATE_LIMIT_RETRIES = 6
RATE_LIMIT_BACKOFF_S = (60.0, 180.0, 420.0, 900.0, 900.0, 900.0)
RATE_LIMIT_MARKERS = (
    "error code: 429", "429 Too Many Requests", "toomanyrequests",
    "rate limit", "pull rate limit",
)
FATAL_MARKERS = (
    "401 Unauthorized", "manifest unknown", "name unknown",
    "repository does not exist", "not found",
)

_DOCKER_REF = re.compile(r"^(?P<registry>[^/]+)/(?P<repo>.+?)(?::(?P<tag>[^:/]+))?$")


# ── reference helpers ────────────────────────────────────────────────────

def parse_docker_image(ref: str) -> tuple[str, str, str]:
    """``ghcr.io/owner/name:tag`` → (registry, repo, tag)."""
    m = _DOCKER_REF.match(ref.strip())
    if not m:
        raise ValueError(f"unparseable docker image reference: {ref!r}")
    return m.group("registry"), m.group("repo"), m.group("tag") or "latest"


def image_id(docker_image: str) -> str:
    _, repo, tag = parse_docker_image(docker_image)
    return f"{repo.rsplit('/', 1)[-1]}__{tag}"


def import_url(docker_image: str) -> str:
    registry, repo, tag = parse_docker_image(docker_image)
    return f"docker://{registry}#{repo}:{tag}"


def docker_image_for_task(task_dir: Path) -> str:
    toml_path = Path(task_dir) / "task.toml"
    with open(toml_path, "rb") as f:
        cfg = tomllib.load(f)
    image = (cfg.get("environment") or {}).get("docker_image")
    if not image:
        raise EnrootImageUnavailable(
            f"{toml_path} has no [environment].docker_image; enroot cannot build Dockerfiles"
        )
    return image


# ── store ─────────────────────────────────────────────────────────────────

class ImageStore:
    def __init__(
        self,
        benchmark: str = BENCHMARK,
        *,
        root: str | Path | None = None,
        min_size_bytes: int = MIN_IMAGE_BYTES,
    ) -> None:
        from sandbox_config import image_store_root

        self.benchmark = benchmark
        self.root = Path(root) if root is not None else image_store_root()
        self.dir = self.root / benchmark
        self.store = self.root / "_store"
        self.locks = self.root / "_locks"
        self.min_size_bytes = min_size_bytes

    def path_for(self, image_id_: str) -> Path:
        return self.dir / f"{image_id_}.sqsh"

    def store_path(self, image_id_: str) -> Path:
        return self.store / f"{image_id_}.sqsh"

    def partial_for(self, image_id_: str) -> Path:
        return self.store / f"{image_id_}.sqsh.partial"

    def lock_for(self, image_id_: str) -> Path:
        return self.locks / f"{image_id_}.lock"

    def has(self, image_id_: str) -> bool:
        return _size_or_zero(self.path_for(image_id_)) >= self.min_size_bytes

    def in_store(self, image_id_: str) -> bool:
        return _size_or_zero(self.store_path(image_id_)) >= self.min_size_bytes

    def sqsh_for_docker_image(self, docker_image: str) -> Path:
        return self.path_for(image_id(docker_image))

    def sqsh_for_task(self, task_dir: Path) -> Path:
        return self.sqsh_for_docker_image(docker_image_for_task(task_dir))

    def ensure_image(
        self,
        docker_image: str,
        *,
        timeout: float = IMPORT_TIMEOUT_S,
        lock_timeout: float = LOCK_TIMEOUT_S,
    ) -> Path:
        """Return a usable ``.sqsh`` for ``docker_image``, importing only if needed.

        Safe under concurrent callers for the same id: exactly one imports, the
        rest wait on the flock and then just link.
        """
        iid = image_id(docker_image)
        path = self.path_for(iid)
        if self.has(iid):
            return path

        self.dir.mkdir(parents=True, exist_ok=True)
        self.store.mkdir(parents=True, exist_ok=True)
        self.locks.mkdir(parents=True, exist_ok=True)

        if self.in_store(iid):
            self._link_from_store(iid)
            return path

        with _flock(self.lock_for(iid), timeout=lock_timeout) as acquired:
            if not acquired:
                raise EnrootImageUnavailable(
                    f"timed out after {lock_timeout:.0f}s waiting for another task to "
                    f"import {iid}; a previous job may have died holding the lock "
                    f"(check for a stale {self.partial_for(iid).name})."
                )
            if self.in_store(iid):
                logger.info("%s was imported by another task while we waited", iid)
            else:
                self._import(iid, import_url(docker_image), timeout=timeout)
            self._link_from_store(iid)

        if not self.has(iid):
            raise EnrootImageUnavailable(f"{iid} still missing or too small after import")
        return path

    def _link_from_store(self, iid: str) -> None:
        link = self.path_for(iid)
        target = self.store_path(iid)
        if link.is_symlink() and link.resolve() == target.resolve():
            return
        link.unlink(missing_ok=True)
        link.symlink_to(target)

    def _import(self, iid: str, url: str, *, timeout: float) -> None:
        partial = self.partial_for(iid)
        final = self.store_path(iid)
        partial.unlink(missing_ok=True)

        temp = os.environ.get("ENROOT_TEMP_PATH", "/dev/shm")
        if not is_tmpfs(Path(temp)):
            raise EnrootImageUnavailable(
                f"ENROOT_TEMP_PATH={temp} is not tmpfs; enroot import cannot unpack "
                f"layers on Lustre. Export ENROOT_TEMP_PATH under /dev/shm."
            )
        env = {**os.environ, "ENROOT_TEMP_PATH": temp, "NVIDIA_VISIBLE_DEVICES": "void"}

        last = ""
        attempt = 0
        throttled = 0
        max_attempts = IMPORT_RETRIES
        while attempt < max_attempts:
            attempt += 1
            started = time.time()
            logger.info("importing %s from %s (attempt %d/%d)", iid, url, attempt, max_attempts)
            proc = subprocess.run(
                ["enroot", "import", "-o", str(partial), url],
                capture_output=True, text=True, check=False, env=env, timeout=timeout,
                stdin=subprocess.DEVNULL,
            )
            if proc.returncode == 0 and _size_or_zero(partial) >= self.min_size_bytes:
                os.replace(partial, final)
                logger.info(
                    "imported %s (%.2fGB) in %.0fs",
                    iid, _size_or_zero(final) / 1024**3, time.time() - started,
                )
                return

            output = (proc.stderr or "") + (proc.stdout or "")
            last = output[-600:]
            partial.unlink(missing_ok=True)

            if is_fatal(output):
                logger.warning("%s cannot be imported from %s: %s", iid, url, last.strip()[-160:])
                break
            if is_rate_limited(output):
                max_attempts = max(max_attempts, RATE_LIMIT_RETRIES)
                wait = RATE_LIMIT_BACKOFF_S[min(throttled, len(RATE_LIMIT_BACKOFF_S) - 1)]
                throttled += 1
                logger.warning(
                    "registry rate-limited %s; waiting %.0fs before retry %d/%d",
                    iid, wait, attempt + 1, max_attempts,
                )
                if attempt < max_attempts:
                    time.sleep(wait)
                continue
            logger.warning("import of %s failed (rc=%d): %s", iid, proc.returncode, last.strip()[-200:])
            if attempt < max_attempts:
                time.sleep(IMPORT_BACKOFF_S * attempt)

        raise EnrootImageUnavailable(
            f"could not import {iid} from {url} after {attempt} attempt(s): {last.strip()}"
        )


# ── helpers ───────────────────────────────────────────────────────────────

@contextmanager
def _flock(path: Path, *, timeout: float, poll: float = 2.0) -> Iterator[bool]:
    """Exclusive advisory lock; yields False on timeout instead of hanging forever."""
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + timeout
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    acquired = False
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    break
                time.sleep(poll)
        yield acquired
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def _size_or_zero(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def is_rate_limited(output: str) -> bool:
    lowered = output.lower()
    return any(m.lower() in lowered for m in RATE_LIMIT_MARKERS)


def is_fatal(output: str) -> bool:
    lowered = output.lower()
    return any(m.lower() in lowered for m in FATAL_MARKERS)


def shard_list(items: list[str], shard: str | None) -> list[str]:
    """``items[k::n]`` for ``shard="k/n"``; identity when None."""
    if not shard:
        return list(items)
    k, n = (int(x) for x in shard.split("/"))
    if n <= 0 or not (0 <= k < n):
        raise ValueError(f"bad shard spec {shard!r}; expected k/n with 0 <= k < n")
    return list(items)[k::n]


def task_dirs(tasks_root: Path, only: list[str] | None = None) -> list[Path]:
    dirs = sorted(
        d for d in Path(tasks_root).iterdir()
        if d.is_dir() and (d / "task.toml").exists()
    )
    if only:
        want = set(only)
        dirs = [d for d in dirs if d.name in want]
    return dirs


# ── CLI ───────────────────────────────────────────────────────────────────

def _cmd_prepull(args: argparse.Namespace) -> int:
    store = ImageStore(root=args.store)
    only = [t.strip() for t in args.tasks.split(",")] if args.tasks else None
    dirs = shard_list([str(d) for d in task_dirs(Path(args.tasks_root), only)], args.shard)
    logger.info("prepull: %d task(s) in shard %s → %s", len(dirs), args.shard or "all", store.dir)
    failures: list[str] = []
    for i, d in enumerate(dirs, 1):
        d = Path(d)
        try:
            image = docker_image_for_task(d)
        except Exception as exc:  # noqa: BLE001
            logger.error("[%d/%d] %s: %s", i, len(dirs), d.name, exc)
            failures.append(d.name)
            continue
        iid = image_id(image)
        if store.has(iid):
            logger.info("[%d/%d] %s present", i, len(dirs), iid)
            continue
        if args.dry_run:
            logger.info("[%d/%d] would import %s ← %s", i, len(dirs), iid, import_url(image))
            continue
        try:
            store.ensure_image(image)
        except Exception as exc:  # noqa: BLE001
            logger.error("[%d/%d] %s FAILED: %s", i, len(dirs), iid, exc)
            failures.append(d.name)
    if failures:
        logger.error("%d image(s) failed: %s", len(failures), ", ".join(failures))
        return 1
    return 0


def _cmd_verify(args: argparse.Namespace) -> int:
    store = ImageStore(root=args.store)
    only = [t.strip() for t in args.tasks.split(",")] if args.tasks else None
    missing: list[str] = []
    total = 0
    for d in task_dirs(Path(args.tasks_root), only):
        image = docker_image_for_task(d)
        iid = image_id(image)
        if store.has(iid):
            total += _size_or_zero(store.path_for(iid))
        else:
            missing.append(iid)
    print(f"present: {len(task_dirs(Path(args.tasks_root), only)) - len(missing)}  "
          f"missing: {len(missing)}  bytes: {total / 1024**3:.1f} GB")
    for m in missing:
        print(f"  missing {m}")
    return 1 if missing else 0


def main(argv: list[str] | None = None) -> int:
    from sandbox_config import image_store_root, load_dotenv

    load_dotenv()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--store", default=None,
                    help=f"store root (default: $SWT_IMAGE_STORE or {image_store_root()})")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("prepull", "verify"):
        p = sub.add_parser(name)
        p.add_argument("--tasks-root", default="tasks")
        p.add_argument("--tasks", default=None, help="comma-separated subset")
        if name == "prepull":
            p.add_argument("--shard", default=None, help="k/n")
            p.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    return _cmd_prepull(args) if args.cmd == "prepull" else _cmd_verify(args)


if __name__ == "__main__":
    sys.exit(main())
