#!/usr/bin/env python3
"""Submit SWE-Together enroot jobs to Slurm.

Subcommands:

  prepull   import the task images into the .sqsh store (sbatch array on compute nodes)
  serve     self-hosting: a GPU job that runs `vllm serve` for a registry model and
            publishes slurm_logs/serve/<tag>_<date>/endpoint.json once healthy
  run       Stage 1: trials via src/run_eval.py --env-type enroot, sharded over an array
            (`--agent-backend vllm --serve-job <serve log dir>` chains on a serve job)
  judge     Stage 2: eval.run_eval with the enroot judge sandbox, one job
  cleanup   remove stale swt-* containers + the tmpfs base on THIS host

Every subcommand writes the rendered sbatch script under slurm_logs/<sub>/ and
prints the sbatch command; pass --submit to actually submit (dry-run by default,
matching launch.py).

Cluster settings are personal and are NOT in the repo. Put them in ``.env``
(gitignored) or pass flags::

    SLURM_QOS=...            # --qos
    SLURM_ACCOUNT=...        # --account
    SLURM_PARTITION=...      # --partition   (optional)
    SLURM_EXTRA="..."        # extra #SBATCH lines, ';'-separated (optional)
    SWT_CONDA_ENV=swetogether
    SWT_VLLM_CONDA_ENV=swt-vllm      # serve: env with vllm (scripts/serving/requirements-vllm.txt)
    SWT_VLLM_WEIGHTS_ROOT=/path      # serve: <root>/<hf repo> holds the downloaded weights
    SWT_VLLM_API_KEY=...             # optional: vllm --api-key; stays host-side (relay injects it)

What the scripts do: run on one node per array task, ``--gpus=0``, enroot tmpfs
paths under ``$SWT_ENROOT_BASE/$USER/$SLURM_JOB_ID``, a cleanup trap on
EXIT/TERM/INT, HTTP proxy variables unset, interpreter path resolved at submit
time. Never run enroot containers on a login node.

Examples::

  # one-task pilot
  python scripts/slurm/launch.py run --tag enroot-pilot1 \
      --tasks desloppify-zone-classification --shards 1 --workers 1 --submit

  # full cohort
  python scripts/slurm/launch.py prepull --submit
  python scripts/slurm/launch.py run --tag muse13_r1 --shards 12 --submit
  python scripts/slurm/launch.py judge --trials-root trials/muse13_r1 \
      --output-dir results/muse13 --model-tag muse13 --submit

  # self-hosted model (docs/self_hosting.md): one or more serve jobs; shards are
  # spread round-robin over the servers given, so sizing is servers × --workers streams
  python scripts/slurm/launch.py serve --model glm-5.3 --tag glm53a --submit
  python scripts/slurm/launch.py serve --model glm-5.3 --tag glm53b --submit
  python scripts/slurm/launch.py run --tag glm53_r1 --model glm-5.3 --agent-backend vllm \
      --serve-job slurm_logs/serve/glm53a_<date> --serve-job slurm_logs/serve/glm53b_<date> \
      --shards 12 --concurrent 6 --workers 2 --submit
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "src"))

from sandbox_config import enroot_base, load_dotenv  # noqa: E402

load_dotenv()

import bedrock_creds  # noqa: E402
import llm_config  # noqa: E402
import opencode_dist  # noqa: E402

DEFAULT_CONDA_ENV = os.environ.get("SWT_CONDA_ENV", "swetogether")
DEFAULT_MODEL = "openrouter/meta/muse-spark-1.3"
DEFAULT_USER_MODEL = "openrouter/google/gemini-3.1-pro-preview"
DEFAULT_TAG_MODEL = "openrouter/google/gemini-3.1-pro-preview"
LOG_ROOT = REPO_ROOT / "slurm_logs"
ENROOT_BASE = str(enroot_base())

#: Non-secret per-seat backend switches forwarded into the job script when set
#: on the launcher's command line. Credentials are never written to the script.
BACKEND_FLAG_VARS = {
    "agent_backend": "SWT_AGENT_BACKEND",
    "user_sim_backend": "SWT_USER_SIM_BACKEND",
    "judge_backend": "SWT_JUDGE_BACKEND",
    "tagger_backend": "SWT_TAGGER_BACKEND",
}

ENROOT_BLOCK = f"""
# ── enroot: everything on tmpfs, isolated per job, removed on exit ──────────
export SWT_ENROOT_BASE={ENROOT_BASE}
export ENROOT_TEMP_PATH={ENROOT_BASE}/$USER/$SLURM_JOB_ID/tmp
export ENROOT_DATA_PATH={ENROOT_BASE}/$USER/$SLURM_JOB_ID/data
export ENROOT_MAX_PROCESSORS=2
export ENROOT_MOUNT_HOME=n
export NVIDIA_VISIBLE_DEVICES=void
mkdir -p "$ENROOT_TEMP_PATH" "$ENROOT_DATA_PATH"
echo "enroot $(enroot version 2>&1 | head -1) on $(hostname); tmpfs free: $(df -h "$ENROOT_TEMP_PATH" | awk 'NR==2{{print $4}}')"

cleanup() {{
    enroot list 2>/dev/null | grep '^swt-' | xargs -r -n1 enroot remove -f >/dev/null 2>&1 || true
    rm -rf "{ENROOT_BASE}/$USER/$SLURM_JOB_ID" || true
}}
trap cleanup EXIT TERM INT
"""


def _python_for_conda_env(env: str) -> Path:
    requested = Path(env).expanduser()
    if requested.is_absolute():
        candidate = requested / "bin" / "python"
    elif conda_exe := os.environ.get("CONDA_EXE"):
        candidate = Path(conda_exe).resolve().parent.parent / "envs" / env / "bin" / "python"
    else:
        candidate = Path(sys.executable).resolve()
    if not candidate.is_file():
        raise FileNotFoundError(
            f"cannot resolve Python for conda env {env!r}; expected {candidate}"
        )
    return candidate


def _header(
    *, job_name: str, log_dir: Path, cpus: int, mem: str, time_limit: str,
    qos: str | None, account: str | None, partition: str | None, extra: str | None,
    array: str | None, gpus: int = 0,
) -> str:
    lines = [
        "#!/bin/bash",
        f"#SBATCH --job-name={job_name}",
        "#SBATCH --nodes=1",
        "#SBATCH --ntasks-per-node=1",
        f"#SBATCH --cpus-per-task={cpus}",
        f"#SBATCH --mem={mem}",
        f"#SBATCH --gpus={gpus}",
        f"#SBATCH --time={time_limit}",
        f"#SBATCH --chdir={REPO_ROOT}",
    ]
    if qos:
        lines.append(f"#SBATCH --qos={qos}")
    if account:
        lines.append(f"#SBATCH --account={account}")
    if partition:
        lines.append(f"#SBATCH --partition={partition}")
    for directive in (extra or "").split(";"):
        directive = directive.strip()
        if directive:
            lines.append(f"#SBATCH {directive.removeprefix('#SBATCH').strip()}")
    if array:
        lines.append(f"#SBATCH --array={array}")
        lines.append(f"#SBATCH --output={log_dir}/%A_%a.out")
        lines.append(f"#SBATCH --error={log_dir}/%A_%a.err")
    else:
        lines.append(f"#SBATCH --output={log_dir}/%j.out")
        lines.append(f"#SBATCH --error={log_dir}/%j.err")
    return "\n".join(lines) + "\n"


def _sbatch_kwargs(args: argparse.Namespace) -> dict:
    return {
        "cpus": args.cpus, "mem": args.mem, "time_limit": args.time,
        "qos": args.qos, "account": args.account, "partition": args.partition,
        "extra": args.sbatch_extra,
    }


def _preamble(python_bin: Path, conda_env: str, *, enroot: bool = True) -> str:
    """Job preamble. ``enroot=False`` (the serve job) skips the sandbox block, whose
    ``NVIDIA_VISIBLE_DEVICES=void`` would hide the GPUs from the model server."""
    sandbox = f"export SWT_SANDBOX=enroot\n{ENROOT_BLOCK}" if enroot else ""
    return f"""
set -euo pipefail
eval "$(conda shell.bash hook)"
conda activate {conda_env}
PYTHON_BIN={shlex.quote(str(python_bin))}
if [ ! -x "$PYTHON_BIN" ]; then echo "python not found: $PYTHON_BIN" >&2; exit 1; fi
# A login-node HTTP proxy inherited into the job can block registry/API domains that
# compute nodes reach directly.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
export PYTHONUNBUFFERED=1
export PYTHONPATH={shlex.quote(str(REPO_ROOT / "src"))}:${{PYTHONPATH:-}}
{sandbox}
"""


def _write_script(sub: str, name: str, content: str) -> tuple[Path, Path]:
    ts = datetime.now().strftime("%Y-%m-%d__%H-%M-%S")
    log_dir = LOG_ROOT / sub / f"{name}_{ts}"
    log_dir.mkdir(parents=True, exist_ok=True)
    script = log_dir / "job.sbatch"
    script.write_text(content)
    script.chmod(0o755)
    return script, log_dir


def _submit(script: Path, submit: bool) -> int:
    print(f"script: {script}")
    if not submit:
        print("DRY RUN — re-run with --submit to launch:")
        print(f"  $ sbatch {script}")
        return 0
    # sbatch exports the submitting environment into the job (--export=ALL).
    # Short-lived AWS credentials must not ride along: the job would inherit a
    # lease that expires mid-run. It mints its own from SWT_AWS_CREDENTIAL_CMD.
    res = subprocess.run(
        ["sbatch", str(script)], capture_output=True, text=True, env=bedrock_creds.scrubbed_env(),
    )
    sys.stdout.write(res.stdout)
    sys.stderr.write(res.stderr)
    if res.returncode == 0:
        job = res.stdout.strip().rsplit(" ", 1)[-1]
        (script.parent / "job_id.txt").write_text(job + "\n")
        print(f"logs: {script.parent}/{job}*.{{out,err}}")
    return res.returncode


def _common_sbatch_args(p: argparse.ArgumentParser, *, cpus: int, mem: str, time_limit: str,
                        conda_env: str | None = None) -> None:
    p.add_argument("--cpus", type=int, default=cpus)
    p.add_argument("--mem", default=mem)
    p.add_argument("--time", default=time_limit)
    p.add_argument("--qos", default=os.environ.get("SLURM_QOS") or None,
                   help="default: $SLURM_QOS from .env")
    p.add_argument("--account", default=os.environ.get("SLURM_ACCOUNT") or None,
                   help="default: $SLURM_ACCOUNT from .env")
    p.add_argument("--partition", default=os.environ.get("SLURM_PARTITION") or None,
                   help="default: $SLURM_PARTITION from .env")
    p.add_argument("--sbatch-extra", default=os.environ.get("SLURM_EXTRA") or None,
                   help="extra #SBATCH directives, ';'-separated; use the = form, e.g. "
                        "--sbatch-extra='--constraint=x86;--exclusive' (default: $SLURM_EXTRA)")
    p.add_argument("--conda-env", default=conda_env or DEFAULT_CONDA_ENV,
                   help=f"conda env name or absolute prefix (default: {conda_env or '$SWT_CONDA_ENV or swetogether'})")
    p.add_argument("--submit", action="store_true", help="actually run sbatch (default: dry-run)")


# ── prepull ───────────────────────────────────────────────────────────────

def cmd_prepull(args: argparse.Namespace) -> int:
    py = _python_for_conda_env(args.conda_env)
    array = f"0-{args.shards - 1}%{args.concurrent}"
    body = (
        f'"$PYTHON_BIN" -m enroot_backend.images prepull '
        f"--tasks-root {shlex.quote(args.tasks_root)} "
        f'--shard "${{SLURM_ARRAY_TASK_ID:-0}}/{args.shards}"'
        + (f" --tasks {shlex.quote(args.tasks)}" if args.tasks else "")
        + (f" --store {shlex.quote(args.store)}" if args.store else "")
        + "\n"
    )
    script, log_dir = _write_script("prepull", "prepull", "")
    content = _header(
        job_name="swt-prepull", log_dir=log_dir, array=array, **_sbatch_kwargs(args),
    ) + _preamble(py, args.conda_env) + body
    script.write_text(content)
    return _submit(script, args.submit)


def _backend_exports(args: argparse.Namespace) -> str:
    """`export SWT_<SEAT>_BACKEND=...` lines for backends chosen on the launcher CLI."""
    lines = []
    for attr, var in BACKEND_FLAG_VARS.items():
        value = getattr(args, attr, None)
        if value:
            lines.append(f"export {var}={shlex.quote(value)}")
    return "".join(line + "\n" for line in lines)


def _bedrock_preflight(models: list[str]) -> None:
    """Fail fast on the login node when a seat runs on Bedrock but credentials cannot be minted.

    The job re-mints on start; this only catches misconfiguration before an
    8-hour job is queued. Also warns when an agent id is not in opencode's
    catalog (reasoning variants would silently be dropped).
    """
    if not any(llm_config.is_bedrock(m) for m in models):
        return
    try:
        bedrock_creds.ensure_fresh(strict=True)
    except bedrock_creds.CredentialError as exc:
        raise SystemExit(f"bedrock preflight: {exc}") from exc
    print(f"bedrock preflight: credentials OK (command: {bedrock_creds.describe_command()}), "
          f"region {llm_config.aws_region()}")
    for m in models:
        llm_config.warn_if_uncatalogued(m)


# The wrapper's pin when a cohort does not set opencode_version (see
# UserEnabledOpenCode.__init__). Kept in sync by tests/test_setup_robustness.py.
DEFAULT_OPENCODE_VERSION = "1.18.29"


def _opencode_preflight(agent_type: str, version: str | None) -> None:
    """Make sure the pinned opencode binary is in the image-store cache so trials
    install it with a file copy instead of apt + NodeSource + npm. Downloads on
    the login node (verified against npm's integrity digest) if missing."""
    if agent_type != "opencode":
        return
    version = version or DEFAULT_OPENCODE_VERSION
    try:
        path = opencode_dist.ensure_cached(version)
    except Exception as exc:  # network / integrity / fs — surface, don't queue a doomed job
        raise SystemExit(f"opencode preflight: could not cache opencode {version}: {exc}") from exc
    print(f"opencode preflight: {version} cached at {path}")


def _egress_preflight(no_enforcement: bool) -> None:
    """Fail fast when the login node cannot build the default-deny sandbox namespace.

    Compute nodes run the same image, so a login-node failure predicts a job that
    dies at its first trial (the enroot backend refuses to run porous).
    """
    if no_enforcement:
        print("egress preflight: SKIPPED — --no-egress-enforcement (containers on the host network)")
        return
    from enroot_backend.netns import namespaces_supported
    ok, why = namespaces_supported()
    if not ok:
        raise SystemExit(f"egress preflight: cannot create an unprivileged user+network namespace ({why})")
    import egress_policy
    pol = egress_policy.default_policy(llm_config.aws_region())
    print(f"egress preflight: namespaces OK; policy v{egress_policy.POLICY_VERSION} "
          f"digest {pol.digest()} ({len(pol.allow_hosts)} hosts + {len(pol.allow_suffixes)} suffixes allowlisted)")


# ── serve (self-hosted model) ──────────────────────────────────────────────

DEFAULT_VLLM_CONDA_ENV = os.environ.get("SWT_VLLM_CONDA_ENV", "swt-vllm")


def _weights_dir(spec, explicit: str | None) -> str:
    """Local weights dir: explicit flag > $SWT_VLLM_WEIGHTS_ROOT/<hf repo> > the HF repo id
    (vLLM then downloads into its own cache, which needs internet on the node)."""
    if explicit:
        return explicit
    root = os.environ.get("SWT_VLLM_WEIGHTS_ROOT")
    if root:
        cand = Path(root) / spec.hf_repo
        if cand.is_dir():
            return str(cand)
    return spec.hf_repo


def cmd_serve(args: argparse.Namespace) -> int:
    from serving import registry as serving_registry
    from serving import vllm_endpoint as vllm_ep
    spec = serving_registry.serving_spec(args.model)
    ms = llm_config.lookup(args.model)
    if ms is None or ms.vllm != spec.served_model_name:
        raise SystemExit(f"{args.model}: registry entry and serving recipe disagree on the served name")
    py = _python_for_conda_env(args.conda_env)
    vllm_bin = py.parent / "vllm"
    weights = _weights_dir(spec, args.weights)
    script, log_dir = _write_script("serve", args.tag, "")
    handoff = log_dir / vllm_ep.HANDOFF_NAME
    cmd = [
        '"$PYTHON_BIN"', "-m", "serving.vllm_server", "serve",
        "--model", shlex.quote(args.model),
        "--weights", shlex.quote(weights),
        "--port", str(args.port),
        "--handoff", shlex.quote(str(handoff)),
        "--health-timeout", str(args.health_timeout),
        "--vllm-bin", shlex.quote(str(vllm_bin)),
    ]
    if args.max_model_len:
        cmd += ["--max-model-len", str(args.max_model_len)]
    if args.extra_vllm_args:
        cmd += ["--extra", args.extra_vllm_args]
    local_weights = Path(weights).is_dir()
    body = (
        ("export HF_HUB_OFFLINE=1\n" if local_weights else "")
        + 'if [ -n "${SWT_VLLM_API_KEY:-}" ]; then export VLLM_API_KEY="$SWT_VLLM_API_KEY"; fi\n'
        + f"echo \"serving {spec.served_model_name} from {weights} on $(hostname)\"\n"
        + " ".join(cmd) + "\n"
    )
    content = _header(
        job_name=f"swt-serve-{args.tag}", log_dir=log_dir, array=None, gpus=args.gpus, **_sbatch_kwargs(args),
    ) + _preamble(py, args.conda_env, enroot=False) + body
    script.write_text(content)
    print(f"serve: {spec.served_model_name} ({spec.hf_repo}) weights={weights} tp={spec.tensor_parallel} "
          f"max_model_len={args.max_model_len or 'model default'}")
    print(f"handoff → {handoff}")
    if args.submit:
        if not vllm_bin.is_file():
            raise SystemExit(f"serve preflight: {vllm_bin} not found; create the serving env "
                             f"(scripts/serving/requirements-vllm.txt) or pass --conda-env")
        if local_weights and not (Path(weights) / "config.json").is_file():
            raise SystemExit(f"serve preflight: {weights} has no config.json (download incomplete?)")
        if not local_weights:
            print(f"serve preflight: {weights} is not a local directory; vLLM will download it on the node")
        if args.gpus < spec.tensor_parallel:
            raise SystemExit(f"serve preflight: recipe needs tensor_parallel={spec.tensor_parallel} GPUs, --gpus {args.gpus}")
    return _submit(script, args.submit)


def _vllm_preflight(agent, serve_jobs: list[str] | None, endpoint: str | None,
                    reasoning_effort: str | None = None) -> list[tuple[str, str | None]]:
    """For a vllm agent: locate the endpoint source(s) and the serve job(s) to depend on.

    Returns ``[(endpoint_spec, dependency_job_id), ...]`` — one per serve job (shards
    are dealt round-robin across them) or a single entry for ``--vllm-endpoint``.
    If a handoff already exists the server is probed from the login node so a
    wrong served name fails here.
    """
    if agent.backend != "vllm":
        return []
    from serving import registry as serving_registry
    from serving import vllm_endpoint as vllm_ep
    served = llm_config.pinned_route_model(agent.model)
    recipe = serving_registry.spec_for_served_name(served)
    if recipe is None:
        raise SystemExit(f"vllm preflight: no serving recipe for {served!r} (src/serving/registry.py)")
    if reasoning_effort and reasoning_effort not in recipe.efforts:
        raise SystemExit(f"vllm preflight: {served} distinguishes reasoning efforts {recipe.efforts}; "
                         f"--reasoning-effort {reasoning_effort!r} would be mapped silently by its chat template")
    sources: list[tuple[str | None, str | None]] = []
    for serve_job in serve_jobs or []:
        sj = Path(serve_job)
        if not sj.is_absolute():
            sj = REPO_ROOT / sj
        if not sj.is_dir():
            raise SystemExit(f"vllm preflight: --serve-job {serve_job} is not a serve log dir")
        jid = sj / "job_id.txt"
        sources.append((str(sj / vllm_ep.HANDOFF_NAME), jid.read_text().strip() if jid.is_file() else None))
    if endpoint:
        sources.append((endpoint, None))
    if not sources:
        if not any(os.environ.get(v) for v in vllm_ep.ENDPOINT_ENV):
            raise SystemExit("vllm preflight: --agent-backend vllm needs --serve-job <serve log dir> (repeatable), "
                             "--vllm-endpoint, or SWT_VLLM_ENDPOINT")
        sources.append((None, None))
    for spec, job_id in sources:
        ep = vllm_ep.load(spec, served)
        if ep is None:
            print(f"vllm preflight: handoff not published yet ({spec or 'env'}); the job will wait for it"
                  + (f" (dependency on serve job {job_id})" if job_id else ""))
            continue
        try:
            ids = vllm_ep.probe(ep, os.environ.get(vllm_ep.CREDENTIAL_ENV))
        except Exception as exc:  # noqa: BLE001 - any failure here is "not reachable from the login node"
            print(f"vllm preflight: {ep.base_url} not reachable from here ({exc.__class__.__name__}); the job will wait")
        else:
            if served not in ids:
                raise SystemExit(f"vllm preflight: {ep.base_url} serves {ids}, not {served!r}")
            print(f"vllm preflight: {ep.base_url} serves {served} (job {ep.job_id or '?'})")
    return [(spec or "", job_id) for spec, job_id in sources]


# ── run (Stage 1) ───────────────────────────────────────────────────────────────────

def cmd_run(args: argparse.Namespace) -> int:
    py = _python_for_conda_env(args.conda_env)
    trials_dir = (REPO_ROOT / (args.trials_dir or f"trials/{args.tag}")).resolve()
    # Resolve registry names here too, so the preflight sees the real ids and
    # the sbatch script records exactly what will run.
    agent = llm_config.resolve_seat_model(
        "agent", args.model, llm_config.seat_backend("agent", args.agent_backend))
    user = llm_config.resolve_seat_model(
        "user_sim", args.user_model, llm_config.seat_backend("user_sim", args.user_sim_backend))
    print(f"agent: {agent.model} [{agent.backend}]   user_sim: {user.model} [{user.backend}]")
    vllm_sources = _vllm_preflight(agent, args.serve_job, args.vllm_endpoint, args.reasoning_effort)
    cmd = [
        '"$PYTHON_BIN"', "src/run_eval.py",
        "--model", shlex.quote(agent.model),
        "--user-model", shlex.quote(user.model),
        "--tag", shlex.quote(args.tag),
        "--agent-type", shlex.quote(args.agent_type),
        "--env-type", "enroot",
        "--workers", str(args.workers),
        "--trials-dir", shlex.quote(str(trials_dir)),
        "--skip-existing",
        "--shard", f'"${{SLURM_ARRAY_TASK_ID:-0}}/{args.shards}"',
    ]
    if args.agent_timeout:
        cmd += ["--agent-timeout", str(args.agent_timeout)]
    if args.agent_timeout_note:
        cmd += ["--agent-timeout-note", shlex.quote(args.agent_timeout_note)]
    if args.trial_budget:
        cmd += ["--trial-budget", str(args.trial_budget)]
    if args.reasoning_effort:
        cmd += ["--reasoning-effort", args.reasoning_effort]
    if args.opencode_version:
        cmd += ["--opencode-version", shlex.quote(args.opencode_version)]
    if args.tasks:
        cmd += ["--tasks", shlex.quote(args.tasks)]
    if args.store:
        cmd += ["--image-store", shlex.quote(args.store)]
    if args.no_egress_enforcement:
        cmd += ["--no-egress-enforcement"]
    if args.allow_porous_sandbox:
        cmd += ["--allow-porous-sandbox"]
    endpoint_specs = [spec for spec, _ in vllm_sources if spec]
    prelude = ""
    if endpoint_specs:
        # shard i talks to server i mod N — several serve jobs spread one cohort's load
        prelude = ("SWT_VLLM_ENDPOINTS=(" + " ".join(shlex.quote(e) for e in endpoint_specs) + ")\n"
                   'SWT_VLLM_SHARD_ENDPOINT="${SWT_VLLM_ENDPOINTS[$(( ${SLURM_ARRAY_TASK_ID:-0} % ${#SWT_VLLM_ENDPOINTS[@]} ))]}"\n')
        cmd += ["--vllm-endpoint", '"$SWT_VLLM_SHARD_ENDPOINT"', "--vllm-wait-s", str(args.vllm_wait_s)]
    if args.extra:
        cmd += [args.extra]
    body = _backend_exports(args) + prelude + " ".join(cmd) + "\n"

    array = f"0-{args.shards - 1}%{args.concurrent or args.shards}"
    sbatch = _sbatch_kwargs(args)
    serve_job_ids = [jid for _, jid in vllm_sources if jid]
    if serve_job_ids:
        # start only once every serve job is running; run_eval then waits for health
        dep = "--dependency=after:" + ":".join(serve_job_ids)
        sbatch["extra"] = f"{sbatch['extra']};{dep}" if sbatch.get("extra") else dep
    script, log_dir = _write_script("run", args.tag, "")
    content = _header(
        job_name=f"swt-run-{args.tag}", log_dir=log_dir, array=array, **sbatch,
    ) + _preamble(py, args.conda_env) + body
    script.write_text(content)
    print(f"trials → {trials_dir}")
    if args.submit:
        _egress_preflight(args.no_egress_enforcement)
        _bedrock_preflight([agent.model, user.model])
        _opencode_preflight(args.agent_type, args.opencode_version)
    return _submit(script, args.submit)


# ── judge (Stage 2) ───────────────────────────────────────────────────────

def cmd_judge(args: argparse.Namespace) -> int:
    py = _python_for_conda_env(args.conda_env)
    cmd = ['"$PYTHON_BIN"', "-m", "eval.run_eval"]
    for r in args.trials_root:
        cmd += ["--trials-root", shlex.quote(str((REPO_ROOT / r).resolve()))]
    cmd += [
        "--tasks-root", shlex.quote(str((REPO_ROOT / args.tasks_root).resolve())),
        "--output-dir", shlex.quote(str((REPO_ROOT / args.output_dir).resolve())),
        "--model-tag", shlex.quote(args.model_tag),
        "--correctness-workers", str(args.correctness_workers),
        "--intent-coverage-workers", str(args.intent_coverage_workers),
        "--tag-model", shlex.quote(args.tag_model),
        "--intent-coverage-model", shlex.quote(args.tag_model),
    ]
    if args.extra:
        cmd += [args.extra]
    body = _backend_exports(args)
    if args.store:
        body += f"export SWT_IMAGE_STORE={shlex.quote(args.store)}\n"
    body += " ".join(cmd) + "\n"

    script, log_dir = _write_script("judge", args.model_tag, "")
    content = _header(
        job_name=f"swt-judge-{args.model_tag}", log_dir=log_dir, array=None, **_sbatch_kwargs(args),
    ) + _preamble(py, args.conda_env) + body
    script.write_text(content)
    if args.submit:
        judge = llm_config.judge_model(args.judge_backend)
        tagger = llm_config.resolve_seat_model(
            "tagger", args.tag_model, llm_config.seat_backend("tagger", args.tagger_backend))
        print(f"judge: {judge.model} [{judge.backend}]   tagger: {tagger.model} [{tagger.backend}]")
        _bedrock_preflight([judge.model, tagger.model])
    return _submit(script, args.submit)


# ── cleanup (this host) ───────────────────────────────────────────────────

def cmd_cleanup(args: argparse.Namespace) -> int:
    import shutil
    from enroot_backend.runtime import EnrootRuntime, remove_stale

    base = enroot_base() / os.environ.get("USER", "unknown")
    if not base.exists():
        print(f"nothing under {base}")
        return 0
    for job_dir in sorted(base.iterdir()):
        rt = EnrootRuntime(base=enroot_base(), job_id=job_dir.name)
        removed = remove_stale(rt)
        print(f"{job_dir.name}: removed {len(removed)} container(s) {removed}")
        if not args.keep_dirs:
            shutil.rmtree(job_dir, ignore_errors=True)
    return 0


# ── main ──────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("prepull", help="import task images into the .sqsh store")
    p.add_argument("--tasks-root", default="tasks")
    p.add_argument("--tasks", default=None, help="comma-separated subset")
    p.add_argument("--store", default=None)
    p.add_argument("--shards", type=int, default=8)
    p.add_argument("--concurrent", type=int, default=4)
    _common_sbatch_args(p, cpus=8, mem="64G", time_limit="04:00:00")
    p.set_defaults(func=cmd_prepull)

    p = sub.add_parser("serve", help="self-hosting: run vllm serve for a registry model (GPU job)")
    p.add_argument("--model", required=True, help="registry name with a serving recipe (e.g. glm-5.3)")
    p.add_argument("--tag", required=True, help="names slurm_logs/serve/<tag>_<date>/ (the --serve-job dir)")
    p.add_argument("--weights", default=None,
                   help="local weights dir (default: $SWT_VLLM_WEIGHTS_ROOT/<hf repo>, else the HF repo id)")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--max-model-len", type=int, default=None,
                   help="prompt window to serve (default: the recipe's context limit)")
    p.add_argument("--extra-vllm-args", default="", help="appended to vllm serve, e.g. '--max-num-seqs 32'")
    p.add_argument("--health-timeout", type=int, default=3600, help="seconds to wait for the server to load")
    p.add_argument("--gpus", type=int, default=8)
    _common_sbatch_args(p, cpus=64, mem="1000G", time_limit="3-00:00:00", conda_env=DEFAULT_VLLM_CONDA_ENV)
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("run", help="Stage 1 trials (sharded sbatch array)")
    p.add_argument("--tag", required=True)
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help="registry name (gpt-5.6-sol) or provider/model string")
    p.add_argument("--agent-backend", default=None, choices=list(llm_config.BACKENDS),
                   help="backend for a registry-named --model (default: $SWT_AGENT_BACKEND > "
                        "$SWT_LLM_BACKEND > native)")
    p.add_argument("--user-model", default=DEFAULT_USER_MODEL)
    p.add_argument("--user-sim-backend", default=None, choices=list(llm_config.backends_for("user_sim")))
    p.add_argument("--agent-type", default="opencode",
                   choices=["claude-code", "codex", "mini-swe-agent", "opencode"])
    p.add_argument("--agent-timeout", type=int, default=4800)
    p.add_argument("--reasoning-effort", default="high", choices=["low", "medium", "high"])
    p.add_argument("--opencode-version", default=None,
                   help="opencode-ai release for the sandbox (default: the wrapper's canonical pin)")
    p.add_argument("--tasks", default=None, help="comma-separated subset (default: all)")
    p.add_argument("--trials-dir", default=None, help="default: trials/<tag>")
    p.add_argument("--store", default=None)
    p.add_argument("--shards", type=int, default=12)
    p.add_argument("--concurrent", type=int, default=None, help="array %% limit (default: shards)")
    p.add_argument("--workers", type=int, default=6, help="concurrent trials per array task")
    p.add_argument("--extra", default="", help="extra args appended to run_eval.py")
    p.add_argument("--no-egress-enforcement", action="store_true",
                   help="debugging only: containers on the host network (refused for trials/canonical_*)")
    p.add_argument("--allow-porous-sandbox", action="store_true",
                   help="knowingly run a leaderboard trials root without enforced egress")
    p.add_argument("--serve-job", action="append", default=None, metavar="SERVE_DIR",
                   help="vllm backend: a serve job's slurm_logs/serve/<tag>_<date> dir; adds a Slurm "
                        "dependency on it and points run_eval at its endpoint.json. Repeat to spread the "
                        "cohort's shards round-robin over several servers")
    p.add_argument("--vllm-endpoint", default=None,
                   help="vllm backend: endpoint.json / serve dir / base URL (alternative to --serve-job)")
    p.add_argument("--vllm-wait-s", type=int, default=3600, help="vllm backend: how long run_eval waits for health")
    p.add_argument("--agent-timeout-note", default=None,
                   help="why --agent-timeout differs from the protocol default; recorded in the run manifest")
    p.add_argument("--trial-budget", type=int, default=None,
                   help="wrapper wall-clock budget per trial (TRIAL_BUDGET_SEC, default 5400 s); raise with "
                        "--agent-timeout when the LLM endpoint is slower than a vendor API")
    _common_sbatch_args(p, cpus=32, mem="128G", time_limit="08:00:00")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("judge", help="Stage 2 judge + aggregation (single job)")
    p.add_argument("--trials-root", action="append", required=True)
    p.add_argument("--tasks-root", default="tasks")
    p.add_argument("--output-dir", required=True)
    p.add_argument("--model-tag", required=True)
    p.add_argument("--correctness-workers", type=int, default=16)
    p.add_argument("--intent-coverage-workers", type=int, default=5)
    p.add_argument("--tag-model", default=DEFAULT_TAG_MODEL,
                   help="LLM for message tagging + intent coverage (registry name or LiteLLM string)")
    p.add_argument("--tagger-backend", default=None, choices=list(llm_config.backends_for("tagger")))
    p.add_argument("--judge-backend", default=None, choices=list(llm_config.JUDGE_BACKENDS),
                   help="where `claude --print` gets its model (default: $SWT_JUDGE_BACKEND > "
                        "$SWT_LLM_BACKEND > JUDGE_VIA_OR/JUDGE_VIA_CODEX > native)")
    p.add_argument("--store", default=None)
    p.add_argument("--extra", default="")
    _common_sbatch_args(p, cpus=64, mem="256G", time_limit="08:00:00")
    p.set_defaults(func=cmd_judge)

    p = sub.add_parser("cleanup", help="remove stale swt-* containers on this host")
    p.add_argument("--keep-dirs", action="store_true")
    p.set_defaults(func=cmd_cleanup)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
