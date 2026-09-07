#!/usr/bin/env python3
"""Host smoke checklist for the enroot backend.

Exercises EnrootContainer end to end against one real task image and prints a
pass/fail line per property the harness depends on. Run it once on any host you
intend to use (a login node is fine as a first check; the Slurm pilot via
scripts/slurm/launch.py is the authoritative test because compute nodes may run
a different enroot version).

Uses a throwaway image store and runtime under the tmpfs base (SWT_ENROOT_BASE,
default /dev/shm/swt) unless --store is given, and removes everything it created.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import shutil
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "src"))

from enroot_backend.container import EnrootContainer  # noqa: E402
from enroot_backend.hosts import write_hosts_file  # noqa: E402
from enroot_backend.images import ImageStore, docker_image_for_task  # noqa: E402
from enroot_backend.runtime import (  # noqa: E402
    EnrootRuntime, enroot_version, find_container_pids, register_cleanup,
)
from sandbox_config import enroot_base, load_dotenv  # noqa: E402

log = logging.getLogger("smoke")


class Check:
    def __init__(self) -> None:
        self.rows: list[tuple[bool, str, str]] = []

    def __call__(self, ok: bool, name: str, detail: str = "") -> None:
        self.rows.append((bool(ok), name, detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  — {detail}" if detail else ""))

    @property
    def failed(self) -> int:
        return sum(1 for ok, _, _ in self.rows if not ok)


async def run(args: argparse.Namespace) -> int:
    load_dotenv()
    user = os.environ.get("USER", "u")
    scratch = enroot_base() / user / "smoke"
    store_root = Path(args.store) if args.store else scratch / "store"
    os.environ.setdefault("ENROOT_TEMP_PATH", str(scratch / "import-tmp"))
    Path(os.environ["ENROOT_TEMP_PATH"]).mkdir(parents=True, exist_ok=True)
    print(f"enroot: {enroot_version()}   store: {store_root}   scratch: {scratch}")

    check = Check()
    register_cleanup()
    task_dir = REPO_ROOT / "tasks" / args.task
    t0 = time.time()
    sqsh = ImageStore(root=store_root).ensure_image(docker_image_for_task(task_dir))
    check(sqsh.is_file() and sqsh.stat().st_size > 50e6, "image import/present",
          f"{sqsh.name} {sqsh.stat().st_size / 1e6:.0f} MB in {time.time() - t0:.0f}s")

    rt = EnrootRuntime(base=scratch / "rt")
    hosts = write_hosts_file(rt.hosts_path, REPO_ROOT / "tasks")
    agent_dir = rt.root / "trial" / "agent"
    agent_dir.mkdir(parents=True, exist_ok=True)
    c = EnrootContainer(
        rt, sqsh, name_hint=args.task, workdir="/",
        mounts=[(agent_dir, "/logs/agent"), (hosts, "/etc/hosts")],
    )
    t0 = time.time()
    await c.create()
    check(c.rootfs.is_dir(), "enroot create", f"{c.name} in {time.time() - t0:.1f}s")
    try:
        r = await c.exec("id -u; echo $PATH; pwd", timeout=60)
        uid, path, cwd = (r.stdout.strip().splitlines() + ["", "", ""])[:3]
        check(uid == "0", "uid 0 inside (--root)", f"uid={uid}")
        check("/usr/local/bin" in path, "image ENV PATH visible (bash -c)", path[:80])
        check(r.stderr.strip() == "", "no enroot-mount stderr noise", repr(r.stderr[:60]))

        await c.exec("echo persisted > /tmp/x", timeout=60)
        r = await c.exec("cat /tmp/x", timeout=60)
        check(r.stdout.strip() == "persisted", "/tmp persists across execs")

        c.write_text("/tmp/model_proxy.py", "print('hello from host-written file')")
        r = await c.exec("python3 /tmp/model_proxy.py", timeout=60)
        check("hello" in r.stdout, "host write_text into /tmp visible in container")

        await c.exec("echo trace >> /logs/agent/opencode.txt", timeout=60)
        check((agent_dir / "opencode.txt").exists(), "/logs/agent bind mount reaches host dir")

        r = await c.exec("getent hosts github.com | awk '{print $1}'", timeout=60)
        check(r.stdout.strip().startswith("127.0.0.1"), "DNS sinkhole via /etc/hosts mount",
              r.stdout.strip())
        r = await c.exec(
            "curl -s -m 15 -o /dev/null -w '%{http_code}' https://openrouter.ai/api/v1/models",
            timeout=60,
        )
        check(r.stdout.strip() == "200", "egress to openrouter.ai", f"HTTP {r.stdout.strip()}")

        t0 = time.time()
        r = await c.exec(
            "nohup python3 -m http.server 4210 >/tmp/srv.log 2>&1 & "
            "for i in 1 2 3 4 5; do sleep 1; curl -s localhost:4210/ >/dev/null && echo ready && exit 0; done; exit 1",
            timeout=30,
        )
        check(r.return_code == 0 and time.time() - t0 < 15, "daemon-launch exec returns promptly",
              f"rc={r.return_code} {time.time() - t0:.1f}s")
        r = await c.exec("curl -s -m 3 -o /dev/null -w '%{http_code}' localhost:4210/", timeout=30)
        check(r.stdout.strip() == "200", "daemon survives to next exec (shared pid/net ns)")
        t0 = time.time()
        r = await c.exec("python3 -m http.server 4211 & sleep 1; echo ok", timeout=30)
        check(r.return_code == 0 and time.time() - t0 < 15,
              "UNREDIRECTED background process does not hang exec", f"{time.time() - t0:.1f}s")
        check(len(find_container_pids(c.name)) >= 2, "container processes discoverable by marker",
              f"{len(find_container_pids(c.name))} pids")

        if not args.skip_apt:
            r = await c.exec(
                "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 && echo ok",
                timeout=600,
            )
            check("ok" in r.stdout, "apt-get as root (agent installer prerequisite)")
    finally:
        await c.remove()
    check(not c.rootfs.exists(), "rootfs removed")
    check(not c.tmp_host_dir.exists(), "persistent /tmp dir removed")
    check(len(find_container_pids(c.name)) == 0, "no leftover container processes")

    print(f"\n{len(check.rows) - check.failed}/{len(check.rows)} checks passed")
    if not args.keep:
        shutil.rmtree(scratch, ignore_errors=True)
    return 1 if check.failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--task", default="desloppify-zone-classification",
                    help="task whose image to use (default: the smallest, 0.16 GB)")
    ap.add_argument("--store", default=None, help="use this image store instead of a throwaway")
    ap.add_argument("--skip-apt", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the scratch dir")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
