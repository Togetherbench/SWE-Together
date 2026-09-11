"""Cached opencode CLI binaries for network-free agent setup.

Harbor's stock ``install-opencode.sh.j2`` runs ``apt-get update``, installs
Node from NodeSource and then ``npm i -g opencode-ai@<v>`` inside every trial
sandbox: five network round-trips to three services (the distro's apt mirror,
deb.nodesource.com, registry.npmjs.org) in order to obtain one file. The
``opencode-ai`` npm package is a thin wrapper around a self-contained ELF
binary (``opencode-linux-x64``, libc-only deps), so none of that is needed:
the binary runs on any glibc image, and every task image already ships
``curl`` and ``ca-certificates``.

This module fetches that platform tarball ONCE on the host, verifies the npm
``integrity`` digest, and stores the extracted binary under the image store::

    <SWT_IMAGE_STORE>/tools/opencode/<version>/<platform>/opencode

Trials then copy it in with ``environment.upload_file`` (already implemented
by every sandbox backend) instead of running the apt/npm pipeline. Setup
drops from ~25 s (and ≥360 s when a mirror degrades) to ~2 s, and a cohort no
longer depends on apt mirrors, NodeSource or npm being healthy.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from sandbox_config import image_store_root

NPM_REGISTRY = "https://registry.npmjs.org"
DEFAULT_PLATFORM = "linux-x64"
TOOLS_SUBDIR = Path("tools") / "opencode"


class OpencodeDistError(RuntimeError):
    pass


def cache_root() -> Path:
    return image_store_root() / TOOLS_SUBDIR


def binary_path(version: str, platform: str = DEFAULT_PLATFORM) -> Path:
    return cache_root() / version / platform / "opencode"


def cached_binary(version: str, platform: str = DEFAULT_PLATFORM) -> Path | None:
    """Return the cached binary for ``version`` if present and executable."""
    p = binary_path(version, platform)
    return p if p.is_file() and os.access(p, os.X_OK) else None


def _fetch_json(url: str, timeout: int = 60) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "swe-together/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _verify_integrity(blob: bytes, integrity: str) -> None:
    """Check an npm ``dist.integrity`` SRI string (``sha512-<base64>``)."""
    algo, _, digest_b64 = integrity.partition("-")
    if not algo or not digest_b64:
        raise OpencodeDistError(f"unparseable npm integrity string: {integrity!r}")
    try:
        h = hashlib.new(algo)
    except ValueError as exc:
        raise OpencodeDistError(f"unsupported integrity algorithm {algo!r}") from exc
    h.update(blob)
    if base64.b64encode(h.digest()).decode() != digest_b64:
        raise OpencodeDistError("opencode tarball failed npm integrity verification")


def ensure_cached(version: str, platform: str = DEFAULT_PLATFORM,
                  log=print) -> Path:
    """Download + verify + extract the opencode binary for ``version`` unless
    it is already in the cache. Runs on the host (login node), never inside a
    sandbox. Returns the binary path.

    Extraction goes through a temp dir + atomic rename so a concurrent caller
    (two launches for the same version) never sees a half-written binary.
    """
    dest = binary_path(version, platform)
    if cached := cached_binary(version, platform):
        return cached

    pkg = f"opencode-{platform}"
    meta = _fetch_json(f"{NPM_REGISTRY}/{pkg}/{version}")
    dist = meta.get("dist") or {}
    tarball, integrity = dist.get("tarball"), dist.get("integrity")
    if not tarball or not integrity:
        raise OpencodeDistError(f"npm metadata for {pkg}@{version} lacks tarball/integrity")

    log(f"opencode: fetching {pkg}@{version} → {dest}")
    req = urllib.request.Request(tarball, headers={"User-Agent": "swe-together/1.0"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        blob = resp.read()
    _verify_integrity(blob, integrity)

    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as tmp:
        tmp_tgz = Path(tmp) / "pkg.tgz"
        tmp_tgz.write_bytes(blob)
        with tarfile.open(tmp_tgz) as tf:
            member = next((m for m in tf.getmembers() if m.name.endswith("/bin/opencode")), None)
            if member is None:
                raise OpencodeDistError(f"{pkg}@{version} tarball has no bin/opencode")
            src = tf.extractfile(member)
            if src is None:
                raise OpencodeDistError(f"{pkg}@{version}: bin/opencode is not a regular file")
            tmp_bin = Path(tmp) / "opencode"
            with open(tmp_bin, "wb") as out:
                shutil.copyfileobj(src, out)
        tmp_bin.chmod(0o755)
        (Path(tmp) / "integrity.txt").write_text(integrity + "\n")
        os.replace(tmp_bin, dest)
        os.replace(Path(tmp) / "integrity.txt", dest.parent / "integrity.txt")
    return dest


def render_install_script(version: str) -> str:
    """Install script that assumes the binary has already been uploaded to
    ``/installed-agent/opencode``: link it onto PATH and print the version.
    No package manager, no network."""
    return (
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        "chmod 0755 /installed-agent/opencode\n"
        "ln -sf /installed-agent/opencode /usr/local/bin/opencode\n"
        "v=$(opencode --version)\n"
        f"[ \"$v\" = {json.dumps(version)} ] || {{ echo \"opencode version mismatch: $v\" >&2; exit 1; }}\n"
        "echo \"opencode $v (pre-fetched binary)\"\n"
    )


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Cache an opencode CLI binary for network-free trial setup.")
    ap.add_argument("version", help="opencode-ai release, e.g. 1.18.29")
    ap.add_argument("--platform", default=DEFAULT_PLATFORM)
    args = ap.parse_args(argv)
    try:
        path = ensure_cached(args.version, args.platform)
    except (OpencodeDistError, OSError, urllib.error.URLError) as exc:
        print(f"opencode_dist: {exc}")
        return 1
    print(f"opencode {args.version} ({args.platform}) cached at {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
