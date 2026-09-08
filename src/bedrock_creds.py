"""Short-lived AWS credentials for the Bedrock backend.

Bedrock is called by three different programs — opencode inside the sandbox,
LiteLLM on the host, ``claude --print`` inside the judge sandbox — and none of
them is ours, so credentials are delivered the one way all three understand:
``AWS_ACCESS_KEY_ID`` / ``AWS_SECRET_ACCESS_KEY`` / ``AWS_SESSION_TOKEN`` (+ region)
in the environment. This module keeps those variables fresh in *this* process;
callers copy them into container exec environments via :func:`aws_env_overlay`.

Where credentials come from, in order:

1. Already in the environment and not about to expire → nothing to do.
2. ``SWT_AWS_CREDENTIAL_CMD`` — a shell command printing AWS ``credential_process``
   JSON (``{"Version":1,"AccessKeyId":…,"SecretAccessKey":…,"SessionToken":…,
   "Expiration":…}``). ``{lease}`` in the command is replaced by ``SWT_AWS_LEASE``
   (default ``4h``). This is how STS-minted credentials are obtained on clusters
   without an instance role; the command itself is site-specific and lives in
   ``.env``.
3. ``AWS_PROFILE`` whose profile has a ``credential_process`` line in
   ``AWS_CONFIG_FILE`` / ``~/.aws/config`` — run the same way. (Containers cannot
   see ``~/.aws``, hence materialising the values instead of passing the profile.)

Leases are tracked in ``SWT_AWS_EXPIRY_EPOCH`` and refreshed ``REFRESH_MARGIN_S``
before expiry. LiteLLM caches env credentials for 600 s, so the margin is set
so a refreshed value is always in place before the old one can fail.

``SWT_UCLOUD_CERT`` (optional): a client certificate some credential tools need;
exported as ``THRIFT_TLS_CL_CERT_PATH`` / ``THRIFT_TLS_CL_KEY_PATH`` only in the
credential command's own environment.
"""
from __future__ import annotations

import configparser
import json
import logging
import os
import shlex
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger(__name__)

CREDENTIAL_VARS: tuple[str, ...] = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")
REGION_VARS: tuple[str, ...] = ("AWS_REGION", "AWS_DEFAULT_REGION", "AWS_REGION_NAME")
EXPIRY_VAR = "SWT_AWS_EXPIRY_EPOCH"
#: Refresh this many seconds before the lease ends: LiteLLM's 600 s credential
#: cache plus the same again as safety.
REFRESH_MARGIN_S = 1200
DEFAULT_LEASE = "4h"
CMD_TIMEOUT_S = 90

#: Variables that must never be baked into a long-running job's environment.
SCRUB_VARS: tuple[str, ...] = CREDENTIAL_VARS + (EXPIRY_VAR,)

_lock = threading.Lock()


class CredentialError(RuntimeError):
    pass


def credentials_present(env: dict[str, str] | None = None) -> bool:
    e = os.environ if env is None else env
    return bool(e.get("AWS_ACCESS_KEY_ID") and e.get("AWS_SECRET_ACCESS_KEY"))


def expiry_epoch(env: dict[str, str] | None = None) -> float | None:
    e = os.environ if env is None else env
    raw = e.get(EXPIRY_VAR)
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def expiring(margin_s: int = REFRESH_MARGIN_S, now: float | None = None) -> bool:
    exp = expiry_epoch()
    if exp is None:
        return False
    return (now if now is not None else time.time()) >= exp - margin_s


def _credential_command() -> str | None:
    cmd = os.environ.get("SWT_AWS_CREDENTIAL_CMD", "").strip()
    if cmd:
        return cmd.replace("{lease}", os.environ.get("SWT_AWS_LEASE", DEFAULT_LEASE))
    profile = os.environ.get("AWS_PROFILE")
    if not profile:
        return None
    for candidate in (os.environ.get("AWS_CONFIG_FILE"), str(Path.home() / ".aws" / "config")):
        if not candidate or not Path(candidate).is_file():
            continue
        cp = configparser.ConfigParser()
        cp.read(candidate)
        for section in (f"profile {profile}", profile):
            if cp.has_section(section) and cp.has_option(section, "credential_process"):
                return cp.get(section, "credential_process")
    return None


def _command_env() -> dict[str, str]:
    env = dict(os.environ)
    cert = os.environ.get("SWT_UCLOUD_CERT")
    if cert:
        env.setdefault("THRIFT_TLS_CL_CERT_PATH", cert)
        env.setdefault("THRIFT_TLS_CL_KEY_PATH", cert)
    return env


def _run_credential_cmd(cmd: str) -> dict[str, str]:
    """Run a credential_process-style command and return its parsed JSON."""
    try:
        proc = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=CMD_TIMEOUT_S,
            env=_command_env(), check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise CredentialError(f"credential command timed out after {CMD_TIMEOUT_S}s: {cmd}") from exc
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout).strip()[-400:]
        raise CredentialError(f"credential command failed (exit {proc.returncode}): {tail}")
    # Tools may print log lines before the JSON; take the last JSON object on stdout.
    text = proc.stdout.strip()
    start = text.rfind("{")
    if start < 0:
        raise CredentialError(f"credential command printed no JSON: {text[-200:]!r}")
    try:
        data = json.loads(text[start:])
    except json.JSONDecodeError:
        # The last "{" may be nested; fall back to the first "{".
        data = json.loads(text[text.find("{"):])
    missing = [k for k in ("AccessKeyId", "SecretAccessKey") if not data.get(k)]
    if missing:
        raise CredentialError(f"credential JSON lacks {missing}: keys={sorted(data)}")
    return data


def _parse_expiration(value: str | None, lease: str) -> float:
    if value:
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            log.debug("unparseable Expiration %r; assuming the requested lease", value)
    return time.time() + _lease_seconds(lease)


def _lease_seconds(lease: str) -> int:
    units = {"s": 1, "m": 60, "h": 3600}
    lease = lease.strip().lower()
    if lease and lease[-1] in units:
        return int(float(lease[:-1]) * units[lease[-1]])
    return int(lease)


def apply_region_defaults() -> None:
    """Point every region variable the three Bedrock clients read at the configured region.

    An explicitly configured ``SWT_AWS_REGION`` overrides an ambient ``AWS_REGION``
    (login nodes often export one for unrelated services); otherwise existing
    values are kept.
    """
    explicit = os.environ.get("SWT_AWS_REGION")
    if explicit:
        for var in REGION_VARS:
            os.environ[var] = explicit
        return
    from llm_config import aws_region
    region = aws_region()
    for var in REGION_VARS:
        os.environ.setdefault(var, region)


def ensure_fresh(margin_s: int = REFRESH_MARGIN_S, strict: bool = False, force: bool = False) -> bool:
    """Make sure this process holds usable AWS credentials; return True if they were (re)minted.

    Idempotent and cheap when nothing needs doing, so callers invoke it before
    every Bedrock-bound step. With ``strict`` a failure raises
    :class:`CredentialError`; otherwise it is logged and False is returned.
    """
    with _lock:
        apply_region_defaults()
        if not force and credentials_present() and not expiring(margin_s):
            return False
        cmd = _credential_command()
        if cmd is None:
            if credentials_present():
                return False  # static credentials, no way (or need) to refresh
            msg = ("no AWS credentials: set SWT_AWS_CREDENTIAL_CMD (a credential_process-style "
                   "command) or AWS_PROFILE in .env, or export AWS_ACCESS_KEY_ID/"
                   "AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN")
            if strict:
                raise CredentialError(msg)
            log.warning(msg)
            return False
        try:
            data = _run_credential_cmd(cmd)
        except CredentialError as exc:
            if strict:
                raise
            log.warning("AWS credential refresh failed: %s", exc)
            return False
        os.environ["AWS_ACCESS_KEY_ID"] = data["AccessKeyId"]
        os.environ["AWS_SECRET_ACCESS_KEY"] = data["SecretAccessKey"]
        if data.get("SessionToken"):
            os.environ["AWS_SESSION_TOKEN"] = data["SessionToken"]
        else:
            os.environ.pop("AWS_SESSION_TOKEN", None)
        exp = _parse_expiration(data.get("Expiration"), os.environ.get("SWT_AWS_LEASE", DEFAULT_LEASE))
        os.environ[EXPIRY_VAR] = f"{exp:.0f}"
        log.info("AWS credentials refreshed (expire %s)",
                 datetime.fromtimestamp(exp, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        return True


def aws_env_overlay(margin_s: int = REFRESH_MARGIN_S) -> dict[str, str]:
    """Fresh AWS credential + region variables to merge into a container exec env."""
    ensure_fresh(margin_s)
    out = {k: os.environ[k] for k in CREDENTIAL_VARS if os.environ.get(k)}
    for var in ("AWS_REGION", "AWS_DEFAULT_REGION"):
        if os.environ.get(var):
            out[var] = os.environ[var]
    return out


def scrubbed_env(env: dict[str, str] | None = None) -> dict[str, str]:
    """A copy of ``env`` without credential material (for handing to a scheduler)."""
    source = os.environ if env is None else env
    return {k: v for k, v in source.items() if k not in SCRUB_VARS}


def describe_command() -> str:
    cmd = _credential_command()
    return " ".join(shlex.quote(p) for p in shlex.split(cmd)) if cmd else "(none)"
