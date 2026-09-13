"""Tier-1 robustness fixes for the per-trial agent bootstrap:

1. opencode_dist: the pinned opencode binary is cached on the host and uploaded
   into the sandbox — no apt / NodeSource / npm at trial setup.
2. eval_infra_sentinel: a trial that Harbor aborted before the agent's first
   turn (AgentSetupTimeoutError) is ``infra_failed``, not a 0.0 model failure,
   and run_eval retries it.
3. run_eval --skip-existing archives the failed predecessor dirs of the tasks it
   re-runs, so the judge/aggregator never see two dirs for one replicate.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))
sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

import eval_infra_sentinel as sentinel  # noqa: E402
import opencode_dist  # noqa: E402


# ── helpers ───────────────────────────────────────────────────────────────

def _fake_tarball(binary: bytes = b"#!/bin/sh\necho 1.18.29\n") -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        info = tarfile.TarInfo("package/package.json")
        payload = b'{"name":"opencode-linux-x64"}'
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))
        info = tarfile.TarInfo("package/bin/opencode")
        info.size = len(binary)
        info.mode = 0o755
        tf.addfile(info, io.BytesIO(binary))
    return buf.getvalue()


def _sri(blob: bytes) -> str:
    return "sha512-" + base64.b64encode(hashlib.sha512(blob).digest()).decode()


def _setup_failed_trial(root: Path, name: str) -> Path:
    """Replica of what Harbor leaves behind on AgentSetupTimeoutError: result.json
    with exception_info, exception.txt, agent/install.sh — no transcript, no
    patch, no verifier."""
    t = root / name
    (t / "agent").mkdir(parents=True)
    (t / "agent" / "install.sh").write_text("#!/bin/bash\napt-get update\n")
    (t / "exception.txt").write_text("harbor.trial.trial.AgentSetupTimeoutError: Agent setup timed out after 360.0 seconds\n")
    (t / "result.json").write_text(json.dumps({
        "trial_name": name,
        "exception_info": {"exception_type": "AgentSetupTimeoutError",
                           "exception_message": "Agent setup timed out after 360.0 seconds"},
        "verifier_result": None,
    }))
    return t


def _completed_trial(root: Path, name: str, reward: float = 1.0) -> Path:
    t = root / name
    (t / "agent").mkdir(parents=True)
    (t / "agent" / "final.patch").write_text("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
    (t / "agent" / "opencode.txt").write_text(
        json.dumps({"type": "step_finish", "part": {"tokens": {"input": 1, "output": 1, "reasoning": 0, "cache": {"read": 0, "write": 0}}}}) + "\n")
    (t / "verifier").mkdir()
    (t / "verifier" / "reward.txt").write_text(f"{reward}\n")
    (t / "result.json").write_text(json.dumps({"trial_name": name, "exception_info": None,
                                               "verifier_result": {"rewards": {"reward": reward}}}))
    return t


# ── 1. opencode_dist ──────────────────────────────────────────────────────

def test_ensure_cached_downloads_verifies_and_extracts(tmp_path, monkeypatch):
    monkeypatch.setenv("SWT_IMAGE_STORE", str(tmp_path / "store"))
    blob = _fake_tarball()
    calls: list[str] = []

    def fake_fetch_json(url, timeout=60):
        calls.append(url)
        return {"dist": {"tarball": "https://registry.example/opencode-linux-x64-1.18.29.tgz",
                         "integrity": _sri(blob)}}

    class _Resp(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(opencode_dist, "_fetch_json", fake_fetch_json)
    monkeypatch.setattr(opencode_dist.urllib.request, "urlopen", lambda req, timeout=0: _Resp(blob))

    path = opencode_dist.ensure_cached("1.18.29")
    assert path == tmp_path / "store" / "tools" / "opencode" / "1.18.29" / "linux-x64" / "opencode"
    assert path.read_bytes().startswith(b"#!/bin/sh") and path.stat().st_mode & 0o111
    assert (path.parent / "integrity.txt").read_text().strip() == _sri(blob)
    assert calls == ["https://registry.npmjs.org/opencode-linux-x64/1.18.29"]

    # second call is a pure cache hit — no network
    monkeypatch.setattr(opencode_dist, "_fetch_json", lambda *a, **k: pytest.fail("network used on cache hit"))
    assert opencode_dist.ensure_cached("1.18.29") == path
    assert opencode_dist.cached_binary("1.18.29") == path
    assert opencode_dist.cached_binary("9.9.9") is None


def test_ensure_cached_rejects_bad_integrity(tmp_path, monkeypatch):
    monkeypatch.setenv("SWT_IMAGE_STORE", str(tmp_path / "store"))
    blob = _fake_tarball()

    class _Resp(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(opencode_dist, "_fetch_json",
                        lambda *a, **k: {"dist": {"tarball": "https://x/y.tgz", "integrity": _sri(b"tampered")}})
    monkeypatch.setattr(opencode_dist.urllib.request, "urlopen", lambda req, timeout=0: _Resp(blob))
    with pytest.raises(opencode_dist.OpencodeDistError, match="integrity"):
        opencode_dist.ensure_cached("1.18.29")
    assert opencode_dist.cached_binary("1.18.29") is None  # nothing half-written


def test_install_script_has_no_package_manager_and_pins_version():
    script = opencode_dist.render_install_script("1.18.29")
    for forbidden in ("apt-get", "nodesource", "npm ", "curl "):
        assert forbidden not in script, forbidden
    assert "/installed-agent/opencode" in script and "/usr/local/bin/opencode" in script
    assert '"1.18.29"' in script and "exit 1" in script


class _FakeEnv:
    def __init__(self):
        self.uploads: list[tuple[str, str]] = []
        self.commands: list[str] = []

    async def exec(self, command, cwd=None, env=None, timeout_sec=None):
        self.commands.append(command)
        from harbor.environments.base import ExecResult
        return ExecResult(stdout="opencode 1.18.29 (pre-fetched binary)\n", stderr="", return_code=0)

    async def upload_file(self, source_path, target_path):
        self.uploads.append((str(source_path), target_path))


def _make_agent(tmp_path, version):
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode
    return UserEnabledOpenCode(
        logs_dir=tmp_path / "logs", model_name="amazon-bedrock/global.openai.gpt-6-astra",
        user_model_name="openrouter/google/gemini-3.1-pro-preview", user_api_key="k",
        opencode_version=version,
    )


def test_wrapper_setup_uploads_cached_binary_instead_of_apt(tmp_path, monkeypatch):
    monkeypatch.setenv("SWT_IMAGE_STORE", str(tmp_path / "store"))
    binary = opencode_dist.binary_path("1.18.29")
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"ELF")
    binary.chmod(0o755)

    agent = _make_agent(tmp_path, "1.18.29")
    inner_setup_called = []

    async def _no_inner(env):
        inner_setup_called.append(env)
    monkeypatch.setattr(agent._inner, "setup", _no_inner)

    env = _FakeEnv()
    asyncio.run(agent._install_opencode(env))

    assert not inner_setup_called, "stock apt/npm path must not run when the binary is cached"
    assert [t for _, t in env.uploads] == ["/installed-agent/opencode", "/installed-agent/install.sh"]
    assert env.uploads[0][0] == str(binary)
    assert env.commands == ["mkdir -p /installed-agent", "bash /installed-agent/install.sh"]
    assert (tmp_path / "logs" / "setup" / "return-code.txt").read_text() == "0"
    assert "apt-get" not in (tmp_path / "logs" / "install.sh").read_text()
    assert agent.version() == "1.18.29"


def test_wrapper_setup_falls_back_when_binary_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("SWT_IMAGE_STORE", str(tmp_path / "store"))
    agent = _make_agent(tmp_path, "1.18.29")
    inner_setup_called = []

    async def _inner(env):
        inner_setup_called.append(env)
    monkeypatch.setattr(agent._inner, "setup", _inner)

    env = _FakeEnv()
    asyncio.run(agent._install_opencode(env))
    assert inner_setup_called == [env] and env.uploads == []


def test_launcher_default_version_matches_wrapper_pin():
    import importlib.util
    spec = importlib.util.spec_from_file_location("swt_launch", REPO_ROOT / "scripts" / "slurm" / "launch.py")
    launch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launch)
    import inspect
    from user_agent.agents.user_enabled_opencode import UserEnabledOpenCode
    pin = inspect.signature(UserEnabledOpenCode.__init__).parameters["opencode_version"].default
    assert launch.DEFAULT_OPENCODE_VERSION == pin == "1.18.29"


def test_every_opencode_cohort_in_plan_is_explicitly_pinned():
    """The default pin moved from 1.15.13 (paper) to 1.18.29; published cohorts must
    keep their own pin so re-running the plan reproduces the paper's rows."""
    plan = json.loads((REPO_ROOT / "canonical_full109.json").read_text())
    unpinned = [k for k, c in plan["models"].items() if c.get("agent_type") == "opencode" and "opencode_version" not in c]
    assert unpinned == [], unpinned
    paper = ("opencode_muse13", "opencode_opus48", "opencode_opus", "opencode_ds", "opencode_gpt", "opencode_mm27", "opencode_glm52", "opencode_glm51")
    assert {plan["models"][k]["opencode_version"] for k in paper} == {"1.15.13"}


# ── 2. setup failures are infra, and retried ──────────────────────────────

def test_setup_failed_trial_is_infra_failed(tmp_path):
    t = _setup_failed_trial(tmp_path, "pi-mono-auto-4439324b__vBKhJnB")
    v = sentinel.classify_trial(t)
    assert v.status == "infra_failed"
    assert v.reason == "pre_agent_failure"
    assert v.evidence["exception_type"] == "AgentSetupTimeoutError"


def test_setup_script_nonzero_exit_is_infra_failed(tmp_path):
    """Harbor raises a bare RuntimeError when install.sh exits non-zero (apt
    exit 100 on an unreachable mirror) — same pre-agent class as the timeout."""
    t = _setup_failed_trial(tmp_path, "rudel-task-468289__oWBzf9N")
    (t / "result.json").write_text(json.dumps({
        "exception_info": {"exception_type": "RuntimeError",
                           "exception_message": "Agent setup failed with exit code 100. See logs in /x/agent/setup"},
        "verifier_result": None,
    }))
    v = sentinel.classify_trial(t)
    assert v.status == "infra_failed" and v.reason == "pre_agent_failure"
    assert v.evidence["exception_type"] == "AgentSetupError"


def test_unrelated_runtime_error_is_not_pre_agent(tmp_path):
    t = _completed_trial(tmp_path, "cli-task-30159a__YCCQ7vm")
    (t / "result.json").write_text(json.dumps({
        "exception_info": {"exception_type": "RuntimeError", "exception_message": "something else"},
        "verifier_result": {"rewards": {"reward": 1.0}},
    }))
    assert sentinel.classify_trial(t).status == "ok"


def test_agent_timeout_with_patch_is_not_infra(tmp_path):
    """Ordinary budget exhaustion (agent ran, produced a patch) must stay `ok`."""
    t = _completed_trial(tmp_path, "mlx-lm-mambacache__Dodqy2e", reward=0.0)
    (t / "result.json").write_text(json.dumps({
        "exception_info": {"exception_type": "AgentTimeoutError"},
        "verifier_result": {"rewards": {"reward": 0.0}},
    }))
    assert sentinel.classify_trial(t).status == "ok"


def test_run_eval_retries_setup_timeouts():
    import run_eval
    src = Path(run_eval.__file__).read_text()
    block = src[src.index("retry_config = RetryConfig("):src.index("orchestrator = LocalOrchestrator(")]
    assert '"AgentSetupTimeoutError"' in block


# ── 3. --skip-existing archives failed predecessors ───────────────────────

def test_skip_existing_reruns_and_archives_setup_failures(tmp_path):
    import run_eval
    root = tmp_path / "trials"
    _setup_failed_trial(root, "pi-mono-auto-4439324b__vBKhJnB")
    _completed_trial(root, "cli-task-30159a__YCCQ7vm")
    # long task name: trial dir uses Harbor's 32-char truncation
    _setup_failed_trial(root, "pi-mono-extensions-event-refacto__3UHcCdA")

    assert run_eval.is_task_completed("pi-mono-auto-4439324b", root) is False
    assert run_eval.is_task_completed("cli-task-30159a", root) is True
    assert run_eval.is_task_completed("pi-mono-extensions-event-refactor", root) is False

    todo = [t for t in ("pi-mono-auto-4439324b", "cli-task-30159a", "pi-mono-extensions-event-refactor")
            if not run_eval.is_task_completed(t, root)]
    moved = run_eval.archive_incomplete_trials(todo, root)
    assert moved == 2
    live = sorted(p.name for p in root.iterdir())
    assert live == ["_failed", "cli-task-30159a__YCCQ7vm"]
    archived = sorted(p.name for p in (root / "_failed").iterdir())
    assert archived == ["pi-mono-auto-4439324b__vBKhJnB", "pi-mono-extensions-event-refacto__3UHcCdA"]
    # the archive itself is invisible to the completion check
    assert run_eval.is_task_completed("pi-mono-auto-4439324b", root) is False


def test_archive_never_touches_completed_trials(tmp_path):
    import run_eval
    root = tmp_path / "trials"
    _completed_trial(root, "cli-task-30159a__YCCQ7vm")
    assert run_eval.archive_incomplete_trials(["cli-task-30159a"], root) == 0
    assert (root / "cli-task-30159a__YCCQ7vm").is_dir() and not (root / "_failed").exists()


def test_eval_discovery_ignores_failed_archive(tmp_path):
    """eval/run_eval.py's discover_jobs only takes dirs containing '__'."""
    src = (REPO_ROOT / "eval" / "run_eval.py").read_text()
    assert 'if not trial.is_dir() or "__" not in trial.name:' in src
    assert "__" not in run_eval_failed_dir_name()


def run_eval_failed_dir_name() -> str:
    import run_eval
    return run_eval.FAILED_ARCHIVE_DIR
