"""Sandbox backend selection shared by both pipeline stages.

One knob decides where trials and the judge run::

    SWT_SANDBOX=e2b      cloud microVMs (E2B_API_KEY)               [default]
    SWT_SANDBOX=docker   local Docker (Stage 1 only; the judge stays on E2B)
    SWT_SANDBOX=enroot   enroot containers on Slurm compute nodes (no API key)

Set it in ``.env`` or export it. Explicit CLI flags (``run_eval.py --env-type``,
``launch.py --env-type``) override it; ``JUDGE_SANDBOX`` overrides it for the
judge only.

Enroot settings (all optional, all read from ``.env`` / the environment):

    SWT_IMAGE_STORE    .sqsh image store root      (default: <repo>/enroot_images)
    SWT_ENROOT_BASE    tmpfs base for containers   (default: /dev/shm/swt)
"""
from __future__ import annotations

import os
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

SANDBOXES: tuple[str, ...] = ("e2b", "docker", "enroot")
DEFAULT_SANDBOX = "e2b"

#: The judge needs a fresh container per trial; Docker's compose-based backend in
#: Harbor has no equivalent here, so a docker Stage 1 still judges on E2B.
JUDGE_SANDBOXES: tuple[str, ...] = ("e2b", "enroot")


def load_dotenv(path: Path | None = None) -> None:
    """Load ``<repo>/.env`` into the environment without overriding existing vars."""
    env_file = path or REPO_ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _validate(value: str, allowed: tuple[str, ...], var: str) -> str:
    v = value.strip().lower()
    if v not in allowed:
        raise SystemExit(f"{var}={value!r}; expected one of {', '.join(allowed)}")
    return v


def stage1_sandbox(cli_value: str | None = None) -> str:
    """Sandbox for trials: CLI flag > SWT_SANDBOX > default."""
    if cli_value:
        return _validate(cli_value, SANDBOXES, "--env-type")
    return _validate(os.environ.get("SWT_SANDBOX", DEFAULT_SANDBOX), SANDBOXES, "SWT_SANDBOX")


def judge_sandbox() -> str:
    """Sandbox for the judge: JUDGE_SANDBOX > SWT_SANDBOX (docker → e2b) > default."""
    explicit = os.environ.get("JUDGE_SANDBOX")
    if explicit:
        return _validate(explicit, JUDGE_SANDBOXES, "JUDGE_SANDBOX")
    top = _validate(os.environ.get("SWT_SANDBOX", DEFAULT_SANDBOX), SANDBOXES, "SWT_SANDBOX")
    return "e2b" if top == "docker" else top


def image_store_root() -> Path:
    return Path(os.environ.get("SWT_IMAGE_STORE") or REPO_ROOT / "enroot_images").expanduser()


def enroot_base() -> Path:
    return Path(os.environ.get("SWT_ENROOT_BASE", "/dev/shm/swt"))
