"""Unit tests for src/bedrock_creds.py (no network, no real credential tool)."""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))

import bedrock_creds as bc  # noqa: E402

FAKE_JSON = {
    "Version": 1,
    "AccessKeyId": "ASIAFAKEFAKEFAKEFAKE",
    "SecretAccessKey": "secret",
    "SessionToken": "token",
    "Expiration": "2099-01-01T00:00:00Z",
}


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in bc.CREDENTIAL_VARS + bc.REGION_VARS + (
        bc.EXPIRY_VAR, "SWT_AWS_CREDENTIAL_CMD", "SWT_AWS_LEASE", "SWT_AWS_REGION",
        "SWT_UCLOUD_CERT", "AWS_PROFILE", "AWS_CONFIG_FILE",
    ):
        monkeypatch.delenv(var, raising=False)


class _Recorder:
    def __init__(self, stdout: str, returncode: int = 0, stderr: str = ""):
        self.calls: list[dict] = []
        self.stdout, self.returncode, self.stderr = stdout, returncode, stderr

    def __call__(self, cmd, **kwargs):
        self.calls.append({"cmd": cmd, **kwargs})
        return subprocess.CompletedProcess(cmd, self.returncode, self.stdout, self.stderr)


def test_no_credentials_and_no_command(monkeypatch):
    assert bc.ensure_fresh() is False
    with pytest.raises(bc.CredentialError):
        bc.ensure_fresh(strict=True)


def test_mints_from_command_and_tracks_expiry(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool get-creds -d {lease} --output cli")
    monkeypatch.setenv("SWT_AWS_LEASE", "2h")
    rec = _Recorder(json.dumps(FAKE_JSON))
    monkeypatch.setattr(subprocess, "run", rec)

    assert bc.ensure_fresh(strict=True) is True
    assert rec.calls[0]["cmd"] == "fake-tool get-creds -d 2h --output cli"
    assert rec.calls[0]["shell"] is True
    import os
    assert os.environ["AWS_ACCESS_KEY_ID"] == FAKE_JSON["AccessKeyId"]
    assert os.environ["AWS_SESSION_TOKEN"] == "token"
    assert float(os.environ[bc.EXPIRY_VAR]) > time.time() + 3600
    for var in bc.REGION_VARS:
        assert os.environ[var] == "us-west-2"

    # Fresh → no second call.
    assert bc.ensure_fresh() is False
    assert len(rec.calls) == 1


def test_refreshes_when_expiring(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "old")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "old")
    monkeypatch.setenv(bc.EXPIRY_VAR, str(time.time() + 60))  # inside the margin
    rec = _Recorder(json.dumps(FAKE_JSON))
    monkeypatch.setattr(subprocess, "run", rec)
    assert bc.expiring() is True
    assert bc.ensure_fresh() is True
    import os
    assert os.environ["AWS_ACCESS_KEY_ID"] == FAKE_JSON["AccessKeyId"]


def test_static_credentials_without_command_are_left_alone(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "static")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "static")
    assert bc.ensure_fresh(strict=True) is False


def test_explicit_region_overrides_ambient_aws_region(monkeypatch):
    import os
    monkeypatch.setenv("AWS_REGION", "us-west-1")  # unrelated ambient value
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "static")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "static")
    bc.ensure_fresh()
    assert os.environ["AWS_REGION"] == "us-west-1"  # nothing configured → keep ambient
    monkeypatch.setenv("SWT_AWS_REGION", "us-west-2")
    bc.ensure_fresh()
    assert os.environ["AWS_REGION"] == os.environ["AWS_REGION_NAME"] == "us-west-2"


def test_cert_only_in_subprocess_env(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    monkeypatch.setenv("SWT_UCLOUD_CERT", "/certs/me.pem")
    rec = _Recorder(json.dumps(FAKE_JSON))
    monkeypatch.setattr(subprocess, "run", rec)
    bc.ensure_fresh(strict=True)
    sub_env = rec.calls[0]["env"]
    assert sub_env["THRIFT_TLS_CL_CERT_PATH"] == "/certs/me.pem"
    assert sub_env["THRIFT_TLS_CL_KEY_PATH"] == "/certs/me.pem"
    import os
    assert "THRIFT_TLS_CL_CERT_PATH" not in os.environ


def test_command_failure(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    monkeypatch.setattr(subprocess, "run", _Recorder("", returncode=3, stderr="access denied"))
    assert bc.ensure_fresh() is False
    with pytest.raises(bc.CredentialError, match="access denied"):
        bc.ensure_fresh(strict=True)


def test_log_noise_before_json_is_tolerated(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    noisy = "W0101 something\nINFO more\n" + json.dumps(FAKE_JSON)
    monkeypatch.setattr(subprocess, "run", _Recorder(noisy))
    assert bc.ensure_fresh(strict=True) is True


def test_missing_expiration_falls_back_to_lease(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    monkeypatch.setenv("SWT_AWS_LEASE", "1h")
    data = {k: v for k, v in FAKE_JSON.items() if k != "Expiration"}
    monkeypatch.setattr(subprocess, "run", _Recorder(json.dumps(data)))
    before = time.time()
    bc.ensure_fresh(strict=True)
    import os
    exp = float(os.environ[bc.EXPIRY_VAR])
    assert before + 3500 < exp < before + 3700


def test_profile_credential_process_fallback(monkeypatch, tmp_path):
    cfg = tmp_path / "config"
    cfg.write_text("[profile bedrock]\nregion = us-west-2\ncredential_process = fake-tool --profile-style\n")
    monkeypatch.setenv("AWS_CONFIG_FILE", str(cfg))
    monkeypatch.setenv("AWS_PROFILE", "bedrock")
    rec = _Recorder(json.dumps(FAKE_JSON))
    monkeypatch.setattr(subprocess, "run", rec)
    assert bc.ensure_fresh(strict=True) is True
    assert rec.calls[0]["cmd"] == "fake-tool --profile-style"


def test_aws_env_overlay_and_scrub(monkeypatch):
    monkeypatch.setenv("SWT_AWS_CREDENTIAL_CMD", "fake-tool")
    monkeypatch.setattr(subprocess, "run", _Recorder(json.dumps(FAKE_JSON)))
    overlay = bc.aws_env_overlay()
    assert set(overlay) == {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                            "AWS_REGION", "AWS_DEFAULT_REGION"}
    scrubbed = bc.scrubbed_env({"AWS_ACCESS_KEY_ID": "x", "AWS_SESSION_TOKEN": "y",
                                bc.EXPIRY_VAR: "1", "OPENROUTER_API_KEY": "keep", "PATH": "/bin"})
    assert scrubbed == {"OPENROUTER_API_KEY": "keep", "PATH": "/bin"}


def test_lease_parsing():
    assert bc._lease_seconds("4h") == 14400
    assert bc._lease_seconds("90m") == 5400
    assert bc._lease_seconds("30s") == 30
    assert bc._lease_seconds("120") == 120
