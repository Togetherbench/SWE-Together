"""Pure-Python unit tests for the enroot backend (no enroot binary required)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))

from enroot_backend import hosts, images  # noqa: E402
from enroot_backend.container import EnrootContainer, sanitize_name  # noqa: E402
from enroot_backend.runtime import EnrootRuntime, filter_stderr  # noqa: E402


# ── images ────────────────────────────────────────────────────────────────

def test_parse_docker_image():
    reg, repo, tag = images.parse_docker_image(
        "ghcr.io/togetherbench/multi-user-turn-codebench/cli-task-0ec2e9:6ed0e06f6418"
    )
    assert reg == "ghcr.io"
    assert repo == "togetherbench/multi-user-turn-codebench/cli-task-0ec2e9"
    assert tag == "6ed0e06f6418"


def test_parse_docker_image_defaults_tag():
    assert images.parse_docker_image("ghcr.io/o/n")[2] == "latest"


def test_image_id_includes_tag():
    assert (
        images.image_id("ghcr.io/togetherbench/multi-user-turn-codebench/cli-task-0ec2e9:6ed0e06f6418")
        == "cli-task-0ec2e9__6ed0e06f6418"
    )


def test_import_url_uses_hash_separator():
    url = images.import_url(
        "ghcr.io/togetherbench/multi-user-turn-codebench/cli-task-0ec2e9:6ed0e06f6418"
    )
    assert url == "docker://ghcr.io#togetherbench/multi-user-turn-codebench/cli-task-0ec2e9:6ed0e06f6418"
    assert "ghcr.io/" not in url


def test_docker_image_for_task_reads_toml(tmp_path):
    (tmp_path / "task.toml").write_text(
        '[environment]\ndocker_image = "ghcr.io/o/n:abc"\ncpus = 4\n'
    )
    assert images.docker_image_for_task(tmp_path) == "ghcr.io/o/n:abc"


def test_docker_image_for_task_missing_raises(tmp_path):
    (tmp_path / "task.toml").write_text("[environment]\ncpus = 4\n")
    with pytest.raises(images.EnrootImageUnavailable):
        images.docker_image_for_task(tmp_path)


def test_store_paths(tmp_path):
    store = images.ImageStore(root=tmp_path)
    assert store.path_for("x__1") == tmp_path / "swe_together" / "x__1.sqsh"
    assert store.store_path("x__1") == tmp_path / "_store" / "x__1.sqsh"
    assert store.lock_for("x__1") == tmp_path / "_locks" / "x__1.lock"
    assert not store.has("x__1")


def test_store_links_existing_bytes_without_import(tmp_path, monkeypatch):
    store = images.ImageStore(root=tmp_path, min_size_bytes=4)
    store.store.mkdir(parents=True)
    store.store_path("n__t").write_bytes(b"12345678")
    monkeypatch.setattr(store, "_import", lambda *a, **k: pytest.fail("must not import"))
    p = store.ensure_image("ghcr.io/o/n:t")
    assert p.is_symlink() and p.resolve() == store.store_path("n__t").resolve()
    assert store.has("n__t")


def test_shard_list_strides():
    items = [f"t{i}" for i in range(10)]
    assert images.shard_list(items, None) == items
    assert images.shard_list(items, "0/3") == ["t0", "t3", "t6", "t9"]
    assert images.shard_list(items, "2/3") == ["t2", "t5", "t8"]
    union = sorted(sum((images.shard_list(items, f"{k}/4") for k in range(4)), []))
    assert union == items


def test_shard_list_rejects_bad_spec():
    with pytest.raises(ValueError):
        images.shard_list(["a"], "3/3")


def test_rate_limit_and_fatal_markers():
    assert images.is_rate_limited("... error code: 429 ...")
    assert images.is_fatal("... manifest unknown ...")
    assert not images.is_fatal("network timeout")
    assert images.is_old_enroot_perm_failure(
        "tar: go/pkg/mod/golang.org/x/text@v0.31.0/message/catalog/gopre19.go: Cannot open: Permission denied"
    )
    assert not images.is_old_enroot_perm_failure("tar: Exiting with failure status due to previous errors")


# ── hosts ─────────────────────────────────────────────────────────────────

def test_sinkhole_entries_from_real_tasks():
    entries = hosts.sinkhole_entries(REPO_ROOT / "tasks")
    assert "github.com" in entries
    assert "huggingface.co" in entries
    assert "raw.githubusercontent.com" in entries
    assert not any(e.replace(".", "").isdigit() for e in entries)


def test_render_hosts_file_appends_sinkhole_and_localhost():
    text = hosts.render_hosts_file(["github.com", "hf.co"], base_hosts="10.0.0.1 somehost\n")
    lines = text.splitlines()
    assert lines[0] == "127.0.0.1 localhost"
    assert "10.0.0.1 somehost" in lines
    assert lines[-1] == "127.0.0.1 github.com hf.co"


# ── runtime / container ──────────────────────────────────────────────────

def test_filter_stderr_drops_mount_noise():
    s = "enroot-mount: foo\nreal warning\nenroot-mount: bar\n"
    assert filter_stderr(s) == "real warning"
    assert filter_stderr("clean") == "clean"


def test_sanitize_name():
    assert sanitize_name("cli-task-0ec2e9__abc.def") == "cli-task-0ec2e9__abc-def"
    assert len(sanitize_name("x" * 100)) == 40


def _container(tmp_path) -> EnrootContainer:
    rt = EnrootRuntime(base=tmp_path, job_id="j")
    return EnrootContainer(
        rt, tmp_path / "img.sqsh", name_hint="task-a",
        workdir="/workspace/repo",
        mounts=[(tmp_path / "agent", "/logs/agent"), (tmp_path / "hosts", "/etc/hosts")],
    )


def test_host_path_resolves_mounts_longest_prefix(tmp_path):
    c = _container(tmp_path)
    assert c.host_path("/tmp/model_proxy.py") == c.tmp_host_dir / "model_proxy.py"
    assert c.host_path("/tmp") == c.tmp_host_dir
    assert c.host_path("/logs/agent/opencode.txt") == tmp_path / "agent" / "opencode.txt"
    assert c.host_path("/etc/hosts") == tmp_path / "hosts"
    assert c.host_path("/logs/verifier/reward.txt") == c.rootfs / "logs/verifier/reward.txt"
    assert c.host_path("/installed-agent/install.sh") == c.rootfs / "installed-agent/install.sh"


def test_exec_argv_shape(tmp_path):
    c = _container(tmp_path)
    argv = c.build_exec_argv(
        "echo hi", cwd=None, env={"OPENROUTER_API_KEY": "k"},
        stdout_in_container="/tmp/.swt-io/1.out", stderr_in_container="/tmp/.swt-io/1.err",
    )
    assert argv[:4] == ["enroot", "start", "--root", "--rw"]
    mounts = [argv[i + 1] for i, a in enumerate(argv) if a == "--mount"]
    assert f"{tmp_path / 'agent'}:/logs/agent" in mounts
    assert f"{tmp_path / 'hosts'}:/etc/hosts" in mounts
    assert f"{c.tmp_host_dir}:/tmp" in mounts
    envs = [argv[i + 1] for i, a in enumerate(argv) if a == "-e"]
    assert f"SWT_CONTAINER={c.name}" in envs
    assert "OPENROUTER_API_KEY=k" in envs
    assert argv[-4:-1] == [c.name, "bash", "-c"]
    script = argv[-1]
    assert "cd /workspace/repo && echo hi" in script
    assert ">/tmp/.swt-io/1.out" in script and "2>/tmp/.swt-io/1.err" in script


def test_exec_argv_respects_cwd_override(tmp_path):
    c = _container(tmp_path)
    argv = c.build_exec_argv("pwd", cwd="/tmp", env=None)
    assert argv[-1].startswith("cd /tmp && pwd")


def test_container_name_prefix(tmp_path):
    c = _container(tmp_path)
    assert c.name.startswith("swt-task-a-")


# ── top-level sandbox switch ─────────────────────────────────────────────

def test_stage1_sandbox_precedence(monkeypatch):
    import sandbox_config as c

    monkeypatch.delenv("SWT_SANDBOX", raising=False)
    assert c.stage1_sandbox(None) == "e2b"
    monkeypatch.setenv("SWT_SANDBOX", "enroot")
    assert c.stage1_sandbox(None) == "enroot"
    assert c.stage1_sandbox("docker") == "docker"          # CLI wins
    with pytest.raises(SystemExit):
        c.stage1_sandbox("podman")
    monkeypatch.setenv("SWT_SANDBOX", "bogus")
    with pytest.raises(SystemExit):
        c.stage1_sandbox(None)


def test_judge_sandbox_follows_top_level(monkeypatch):
    import sandbox_config as c

    monkeypatch.delenv("JUDGE_SANDBOX", raising=False)
    monkeypatch.setenv("SWT_SANDBOX", "enroot")
    assert c.judge_sandbox() == "enroot"
    monkeypatch.setenv("SWT_SANDBOX", "docker")            # no docker judge → e2b
    assert c.judge_sandbox() == "e2b"
    monkeypatch.setenv("JUDGE_SANDBOX", "enroot")          # explicit override wins
    assert c.judge_sandbox() == "enroot"
    monkeypatch.setenv("JUDGE_SANDBOX", "docker")          # not a valid judge backend
    with pytest.raises(SystemExit):
        c.judge_sandbox()


def test_load_dotenv_does_not_override_process_env(tmp_path, monkeypatch):
    import sandbox_config as c

    env = tmp_path / ".env"
    env.write_text('# comment\nSWT_SANDBOX=enroot\nSWT_IMAGE_STORE="/x/store"\n\nBAD LINE\n')
    monkeypatch.setenv("SWT_SANDBOX", "docker")
    monkeypatch.delenv("SWT_IMAGE_STORE", raising=False)
    c.load_dotenv(env)
    assert os.environ["SWT_SANDBOX"] == "docker"
    assert c.image_store_root() == Path("/x/store")


def test_image_store_default_is_inside_repo(monkeypatch):
    import sandbox_config as c

    monkeypatch.delenv("SWT_IMAGE_STORE", raising=False)
    assert c.image_store_root() == REPO_ROOT / "enroot_images"


# ── judge sandbox selection ──────────────────────────────────────────────

def test_judge_backend_selection(monkeypatch):
    sys.path.insert(0, str(REPO_ROOT))
    from eval.correctness import judge_sandbox as js

    monkeypatch.delenv("JUDGE_SANDBOX", raising=False)
    monkeypatch.delenv("SWT_SANDBOX", raising=False)
    assert js.selected_backend() == "e2b"
    monkeypatch.setenv("JUDGE_SANDBOX", "enroot")
    assert js.selected_backend() == "enroot"
    monkeypatch.setenv("JUDGE_SANDBOX", "bogus")
    with pytest.raises(SystemExit):
        js.selected_backend()


def test_judge_e2b_prereq_requires_key(monkeypatch):
    from eval.correctness import judge_sandbox as js

    monkeypatch.delenv("E2B_API_KEY", raising=False)
    assert js.check_backend_prereqs("e2b")
    monkeypatch.setenv("E2B_API_KEY", "x")
    assert js.check_backend_prereqs("e2b") is None


def test_run_judge_alias_preserved_and_e2b_lazy():
    import importlib

    sys.modules.pop("e2b", None)
    from eval.correctness import sandbox

    importlib.reload(sandbox)
    assert sandbox.run_judge_in_e2b is sandbox.run_judge
    assert "e2b" not in sys.modules
