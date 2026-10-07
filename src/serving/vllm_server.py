"""Server side of the ``vllm`` backend: run ``vllm serve`` for a registry model
inside the serving conda env, wait until it answers, publish the handoff file,
and take it down again.

    python -m serving.vllm_server serve --model glm-5.3 --weights <dir> \
        --port 8000 --max-model-len 262144 --handoff <log dir>/endpoint.json
    python -m serving.vllm_server stop --handoff <log dir>

Stdlib only: this runs where vLLM is installed, not where the benchmark is. The
API key (vLLM ``--api-key``) is read from ``VLLM_API_KEY``/``SWT_VLLM_API_KEY``
and passed through the environment, never on the command line.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from serving.registry import ServingSpec, serving_spec
from serving.vllm_endpoint import HANDOFF_NAME, MODELS_PATH, VllmEndpoint, handoff_path, read_handoff

HEALTH_PATH = "/health"


def build_serve_argv(spec: ServingSpec, *, weights: str, port: int, max_model_len: int | None,
                     extra: tuple[str, ...] = (), vllm_bin: str = "vllm", host: str = "0.0.0.0",
                     nnodes: int = 1, node_rank: int = 0, master_addr: str | None = None,
                     master_port: int = 29501) -> list[str]:
    """``vllm serve`` command line for ``spec``; the recipe's args come last so a
    caller's ``extra`` can still override them (vLLM takes the last value).

    With ``nnodes > 1`` the engine spans nodes through vLLM's Ray-free ``mp``
    executor: every node runs the same engine arguments, rank 0 serves the API and
    the others run ``--headless``. ``tensor_parallel * pipeline_parallel`` must equal
    the GPUs across all nodes.
    """
    argv = [vllm_bin, "serve", weights,
            "--served-model-name", spec.served_model_name,
            "--host", host, "--port", str(port),
            "--tensor-parallel-size", str(spec.tensor_parallel)]
    if spec.pipeline_parallel > 1 and nnodes > 1:
        argv += ["--pipeline-parallel-size", str(spec.pipeline_parallel)]
    if nnodes > 1:
        if not master_addr:
            raise ValueError("multi-node serving needs master_addr (the rank-0 host)")
        argv += ["--distributed-executor-backend", "mp", "--nnodes", str(nnodes), "--node-rank", str(node_rank),
                 "--master-addr", master_addr, "--master-port", str(master_port)]
        if node_rank > 0:
            argv.append("--headless")
    if max_model_len:
        argv += ["--max-model-len", str(max_model_len)]
    argv += list(spec.vllm_args)
    argv += list(extra)
    return argv


def _api_key() -> str | None:
    return os.environ.get("VLLM_API_KEY") or os.environ.get("SWT_VLLM_API_KEY") or None


def _get(url: str, api_key: str | None, timeout: float = 10.0) -> tuple[int, bytes]:
    req = urllib.request.Request(url)
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - loopback, our own server
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, b""


def wait_health(base_url: str, served_model: str, *, proc: subprocess.Popen | None, api_key: str | None,
                timeout_s: float, poll_s: float = 10.0, log=print) -> None:
    deadline = time.monotonic() + timeout_s
    last = ""
    while time.monotonic() < deadline:
        if proc is not None and proc.poll() is not None:
            raise SystemExit(f"vllm exited with status {proc.returncode} before becoming healthy")
        try:
            status, _ = _get(base_url + HEALTH_PATH, api_key, timeout=5)
            if status == 200:
                status, body = _get(base_url + MODELS_PATH, api_key, timeout=10)
                if status == 200:
                    ids = [m.get("id") for m in json.loads(body.decode("utf-8")).get("data", [])]
                    if served_model in ids:
                        log(f"vllm healthy: {base_url} serves {ids}")
                        return
                    raise SystemExit(f"vllm serves {ids}, expected {served_model!r}")
            msg = f"health {status}"
        except (urllib.error.URLError, OSError, ValueError) as exc:
            msg = f"not up yet ({exc.__class__.__name__})"
        if msg != last:
            log(f"waiting for vllm: {msg}")
            last = msg
        time.sleep(poll_s)
    raise SystemExit(f"vllm did not become healthy within {timeout_s:.0f}s")


def vllm_version(vllm_bin: str) -> str | None:
    try:
        out = subprocess.run([vllm_bin, "--version"], capture_output=True, text=True, timeout=120)
        return (out.stdout or out.stderr).strip().splitlines()[-1] if out.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return None


def write_handoff(path: Path, endpoint: VllmEndpoint) -> Path:
    """Atomic write so a reader never sees a partial file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(endpoint.to_dict(), indent=2) + "\n")
    tmp.replace(path)
    return path


def _node_name() -> str:
    return os.environ.get("SLURMD_NODENAME") or socket.getfqdn()


def cmd_serve(args: argparse.Namespace) -> int:
    spec = serving_spec(args.model)
    weights = args.weights or spec.hf_repo
    vllm_bin = args.vllm_bin or shutil.which("vllm") or "vllm"
    api_key = _api_key()
    nodes = [n for n in (args.nodes or "").split(",") if n]
    argv = build_serve_argv(spec, weights=weights, port=args.port, max_model_len=args.max_model_len,
                            extra=tuple(args.extra or ()), vllm_bin=vllm_bin, nnodes=args.nnodes,
                            node_rank=args.node_rank, master_addr=args.master_addr, master_port=args.master_port)
    env = dict(os.environ)
    if api_key:
        env["VLLM_API_KEY"] = api_key
    is_head = args.node_rank == 0
    handoff = Path(args.handoff)
    if is_head and handoff.exists():
        handoff.unlink()
    print(f"launching (node rank {args.node_rank}/{args.nnodes}):", " ".join(argv), flush=True)
    proc = subprocess.Popen(argv, env=env)

    def _forward(signum, _frame):
        proc.send_signal(signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _forward)
    if not is_head:
        # headless worker: no API server here, so nothing to probe or publish
        return proc.wait()
    base_url = f"http://{_node_name()}:{args.port}"
    try:
        wait_health(base_url, spec.served_model_name, proc=proc, api_key=api_key, timeout_s=args.health_timeout)
        ep = VllmEndpoint(base_url=base_url, served_model=spec.served_model_name, node=_node_name(), port=args.port,
                          job_id=os.environ.get("SLURM_JOB_ID"), max_model_len=args.max_model_len,
                          vllm_version=vllm_version(vllm_bin), nnodes=args.nnodes,
                          pipeline_parallel=spec.pipeline_parallel if args.nnodes > 1 else 1,
                          nodes=nodes or None)
        write_handoff(handoff, ep)
        print(f"handoff written: {handoff}\n{json.dumps(ep.to_dict(), indent=2)}", flush=True)
        return proc.wait()
    finally:
        # a dead server must never look live to a trial job
        if handoff.exists():
            handoff.unlink()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()


def cmd_stop(args: argparse.Namespace) -> int:
    hp = handoff_path(args.handoff)
    if hp is None or not hp.exists():
        print(f"no handoff at {args.handoff}; nothing to stop", file=sys.stderr)
        return 1
    ep = read_handoff(hp)
    if not ep.job_id:
        print(f"{hp} has no job_id; cancel the serve job by hand", file=sys.stderr)
        return 1
    print(f"scancel {ep.job_id} ({ep.base_url})")
    return subprocess.call(["scancel", ep.job_id])


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run vllm serve for a registry model and publish the handoff")
    s.add_argument("--model", required=True, help="registry canonical name with a serving recipe (e.g. glm-5.3)")
    s.add_argument("--weights", help="local weights dir or HF repo id (default: the recipe's HF repo)")
    s.add_argument("--port", type=int, default=8000)
    s.add_argument("--max-model-len", type=int, default=None)
    s.add_argument("--handoff", required=True, help=f"path of the {HANDOFF_NAME} to publish")
    s.add_argument("--health-timeout", type=float, default=3600, help="seconds to wait for the server")
    s.add_argument("--vllm-bin", default=None)
    s.add_argument("--nnodes", type=int, default=1, help="nodes the engine spans (vLLM mp multi-node)")
    s.add_argument("--node-rank", type=int, default=0, help="this node's rank; rank 0 serves the API and publishes the handoff")
    s.add_argument("--master-addr", default=None, help="rank-0 host (required when --nnodes > 1)")
    s.add_argument("--master-port", type=int, default=29501)
    s.add_argument("--nodes", default=None, help="comma-separated hostnames of all nodes, recorded in the handoff")
    s.add_argument("--extra", nargs=argparse.REMAINDER, help="extra vllm serve args (after --extra)")
    s.set_defaults(fn=cmd_serve)
    t = sub.add_parser("stop", help="scancel the serve job named in a handoff file or dir")
    t.add_argument("--handoff", required=True)
    t.set_defaults(fn=cmd_stop)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
