"""Slurm launcher: the `serve` subcommand and `run --serve-job` for the vllm backend
(rendered scripts only; nothing is submitted)."""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))


@pytest.fixture
def launch(monkeypatch, tmp_path):
    monkeypatch.setenv("SWT_VLLM_CONDA_ENV", "swetogether")
    monkeypatch.delenv("SWT_VLLM_ENDPOINT", raising=False)
    monkeypatch.delenv("SWT_VLLM_BASE_URL", raising=False)
    monkeypatch.delenv("SWT_VLLM_WEIGHTS_ROOT", raising=False)
    spec = importlib.util.spec_from_file_location("swt_launch_vllm", REPO_ROOT / "scripts" / "slurm" / "launch.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.LOG_ROOT = tmp_path / "slurm_logs"  # keep rendered scripts out of the repo
    # any resolvable interpreter will do for a dry run
    monkeypatch.setattr(mod, "_python_for_conda_env", lambda env: Path(sys.executable))
    return mod


def _run(mod, argv):
    old = sys.argv
    sys.argv = ["launch.py", *argv]
    try:
        rc = mod.main()
    finally:
        sys.argv = old
    assert rc == 0
    return rc


def test_header_gpus_and_preamble_without_enroot(launch, tmp_path):
    h = launch._header(job_name="x", log_dir=tmp_path, cpus=1, mem="1G", time_limit="1:00:00", qos=None,
                       account=None, partition=None, extra=None, array=None, gpus=8)
    assert "#SBATCH --gpus=8" in h
    default = launch._header(job_name="x", log_dir=tmp_path, cpus=1, mem="1G", time_limit="1:00:00", qos=None,
                             account=None, partition=None, extra=None, array=None)
    assert "#SBATCH --gpus=0" in default
    serve = launch._preamble(Path(sys.executable), "swt-vllm", enroot=False)
    assert "NVIDIA_VISIBLE_DEVICES" not in serve and "SWT_SANDBOX" not in serve and "enroot" not in serve.lower()
    trial = launch._preamble(Path(sys.executable), "swetogether")
    assert "NVIDIA_VISIBLE_DEVICES=void" in trial and "export SWT_SANDBOX=enroot" in trial


def test_serve_renders_a_gpu_job_with_the_recipe(launch, tmp_path, capsys):
    _run(launch, ["serve", "--model", "glm-5.3", "--tag", "glm53", "--max-model-len", "262144",
                  "--extra-vllm-args", "--max-num-seqs 32", "--weights", str(tmp_path / "w")])
    d = next((tmp_path / "slurm_logs" / "serve").glob("glm53_*"))
    script = (d / "job.sbatch").read_text()
    assert "#SBATCH --gpus=8" in script and "#SBATCH --job-name=swt-serve-glm53" in script
    assert "NVIDIA_VISIBLE_DEVICES" not in script and "ENROOT_TEMP_PATH" not in script
    assert '-m serving.vllm_server serve --model glm-5.3' in script
    assert f"--handoff {d / 'endpoint.json'}" in script and "--max-model-len 262144" in script
    assert "--extra --max-num-seqs 32" in script
    assert 'export VLLM_API_KEY="$SWT_VLLM_API_KEY"' in script  # only when the host has one
    assert "sk-" not in script
    out = capsys.readouterr().out
    assert "DRY RUN" in out and "handoff" in out


def test_serve_multi_node_spans_the_allocation_at_the_native_window(launch, tmp_path):
    w = tmp_path / "w"; w.mkdir(); (w / "config.json").write_text("{}")
    _run(launch, ["serve", "--model", "glm-5.3", "--tag", "glm53-1m", "--nodes", "2", "--weights", str(w),
                  "--extra-vllm-args", "--max-num-seqs 4"])
    d = next((tmp_path / "slurm_logs" / "serve").glob("glm53-1m_*"))
    script = (d / "job.sbatch").read_text()
    assert "#SBATCH --nodes=2" in script and "#SBATCH --gpus-per-node=8" in script and "#SBATCH --gpus=8" not in script
    assert "scontrol show hostnames" in script and 'HEAD="${HOSTS[0]}"' in script
    assert script.count("srun --nodes=1 --ntasks=1") == 2  # one headless worker loop + the head
    assert '--nnodes 2 --master-addr "$HEAD" --node-rank 0 --nodes "$NODE_LIST"' in script and '--node-rank "$i"' in script
    # --extra is a REMAINDER flag: the driver's multi-node flags must precede it
    assert script.index("--nnodes 2") < script.index("--extra") if "--extra" in script else True
    assert script.count("--max-model-len 1048576") == 2  # native window is the default for multi-node
    assert "/opt/amazon/ofi-nccl/lib" in script and "FI_PROVIDER=efa" in script
    assert 'DG_JIT_CACHE_DIR="/tmp/swt-deep-gemm-$SLURM_JOB_ID"' in script  # per-node JIT cache, not the shared $HOME one
    single = tmp_path / "slurm_logs" / "serve"
    _run(launch, ["serve", "--model", "glm-5.3", "--tag", "glm53-one", "--weights", str(w)])
    one = (next(single.glob("glm53-one_*")) / "job.sbatch").read_text()
    assert "#SBATCH --nodes=1" in one and "srun" not in one and "--nnodes" not in one and "--max-model-len" not in one


def test_serve_multi_node_preflight_checks_gpu_count_and_local_weights(launch, tmp_path, monkeypatch):
    w = tmp_path / "w"; w.mkdir(); (w / "config.json").write_text("{}")
    monkeypatch.setattr(launch, "_submit", lambda script, submit: 0)
    fake_env = tmp_path / "env" / "bin"; fake_env.mkdir(parents=True)
    (fake_env / "python").write_text(""); (fake_env / "vllm").write_text("")  # preflight only checks presence
    monkeypatch.setattr(launch, "_python_for_conda_env", lambda env: fake_env / "python")
    with pytest.raises(SystemExit, match="TP 16 x PP 1"):
        _run(launch, ["serve", "--model", "glm-5.3", "--tag", "x", "--nodes", "3", "--weights", str(w), "--submit"])
    with pytest.raises(SystemExit, match="local weights"):
        _run(launch, ["serve", "--model", "glm-5.3", "--tag", "y", "--nodes", "2", "--weights", "zai-org/GLM-5.3", "--submit"])


def test_serve_refuses_a_model_without_a_recipe(launch):
    with pytest.raises(SystemExit):
        _run(launch, ["serve", "--model", "gpt-6-sol", "--tag", "x"])


def test_run_with_serve_job_adds_dependency_and_endpoint(launch, tmp_path, capsys):
    serve_dir = tmp_path / "slurm_logs" / "serve" / "glm53_2026"
    serve_dir.mkdir(parents=True)
    (serve_dir / "job_id.txt").write_text("4242\n")
    _run(launch, ["run", "--tag", "glm53_r1", "--model", "glm-5.3", "--agent-backend", "vllm",
                  "--serve-job", str(serve_dir), "--shards", "2", "--workers", "3"])
    d = next((tmp_path / "slurm_logs" / "run").glob("glm53_r1_*"))
    script = (d / "job.sbatch").read_text()
    assert "#SBATCH --dependency=after:4242" in script
    assert "--model vllm/glm-5.3" in script and "export SWT_AGENT_BACKEND=vllm" in script
    assert f"SWT_VLLM_ENDPOINTS=({serve_dir / 'endpoint.json'})" in script
    assert '--vllm-endpoint "$SWT_VLLM_SHARD_ENDPOINT"' in script and "--vllm-wait-s 3600" in script
    assert "#SBATCH --gpus=0" in script and "ENROOT_TEMP_PATH" in script  # trials stay CPU + sandboxed
    assert "will wait for it" in capsys.readouterr().out


def test_run_spreads_shards_over_several_serve_jobs(launch, tmp_path):
    dirs = []
    for i, jid in enumerate(("4242", "4243", "4244")):
        d = tmp_path / "slurm_logs" / "serve" / f"glm53{i}_2026"; d.mkdir(parents=True)
        (d / "job_id.txt").write_text(jid + "\n"); dirs.append(d)
    argv = ["run", "--tag", "glm53_r1", "--model", "glm-5.3", "--agent-backend", "vllm", "--shards", "12", "--workers", "2"]
    for d in dirs:
        argv += ["--serve-job", str(d)]
    _run(launch, argv)
    script = (next((tmp_path / "slurm_logs" / "run").glob("glm53_r1_*")) / "job.sbatch").read_text()
    assert "#SBATCH --dependency=after:4242:4243:4244" in script
    assert "SWT_VLLM_ENDPOINTS=(" in script and all(str(d / "endpoint.json") in script for d in dirs)
    # shard i → server i mod 3
    assert 'SWT_VLLM_SHARD_ENDPOINT="${SWT_VLLM_ENDPOINTS[$(( ${SLURM_ARRAY_TASK_ID:-0} % ${#SWT_VLLM_ENDPOINTS[@]} ))]}"' in script
    assert "#SBATCH --array=0-11%12" in script


def test_run_with_published_handoff_checks_the_served_model(launch, tmp_path, monkeypatch):
    from serving import vllm_endpoint as ve
    serve_dir = tmp_path / "slurm_logs" / "serve" / "glm53_2026"
    serve_dir.mkdir(parents=True)
    (serve_dir / "job_id.txt").write_text("4242\n")
    (serve_dir / "endpoint.json").write_text(json.dumps({"base_url": "http://node:8000", "served_model": "glm-5.3", "job_id": "4242"}))
    monkeypatch.setattr(ve, "probe", lambda ep, key=None: ["other-model"])
    with pytest.raises(SystemExit, match="serves"):
        _run(launch, ["run", "--tag", "glm53_r1", "--model", "glm-5.3", "--agent-backend", "vllm", "--serve-job", str(serve_dir)])
    monkeypatch.setattr(ve, "probe", lambda ep, key=None: ["glm-5.3"])
    _run(launch, ["run", "--tag", "glm53_r2", "--model", "glm-5.3", "--agent-backend", "vllm", "--serve-job", str(serve_dir)])


def test_run_vllm_requires_an_endpoint_source_and_a_known_effort(launch, tmp_path):
    with pytest.raises(SystemExit, match="needs --serve-job"):
        _run(launch, ["run", "--tag", "x", "--model", "glm-5.3", "--agent-backend", "vllm"])
    serve_dir = tmp_path / "slurm_logs" / "serve" / "s"; serve_dir.mkdir(parents=True)
    with pytest.raises(SystemExit, match="reasoning efforts"):
        _run(launch, ["run", "--tag", "x", "--model", "glm-5.3", "--agent-backend", "vllm",
                      "--serve-job", str(serve_dir), "--reasoning-effort", "medium"])
