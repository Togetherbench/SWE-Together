#!/usr/bin/env python3
"""Submit SWE-Together enroot jobs to Slurm.

Subcommands:

  prepull   import the task images into the .sqsh store (sbatch array on compute nodes)
  run       Stage 1: trials via src/run_eval.py --env-type enroot, sharded over an array
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
    array: str | None,
) -> str:
    lines = [
        "#!/bin/bash",
        f"#SBATCH --job-name={job_name}",
        "#SBATCH --nodes=1",
        "#SBATCH --ntasks-per-node=1",
        f"#SBATCH --cpus-per-task={cpus}",
        f"#SBATCH --mem={mem}",
        "#SBATCH --gpus=0",
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


def _preamble(python_bin: Path, conda_env: str) -> str:
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
export SWT_SANDBOX=enroot
{ENROOT_BLOCK}
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


def _common_sbatch_args(p: argparse.ArgumentParser, *, cpus: int, mem: str, time_limit: str) -> None:
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
    p.add_argument("--conda-env", default=DEFAULT_CONDA_ENV,
                   help="conda env name or absolute prefix (default: $SWT_CONDA_ENV or swetogether)")
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
    if args.reasoning_effort:
        cmd += ["--reasoning-effort", args.reasoning_effort]
    if args.opencode_version:
        cmd += ["--opencode-version", shlex.quote(args.opencode_version)]
    if args.tasks:
        cmd += ["--tasks", shlex.quote(args.tasks)]
    if args.store:
        cmd += ["--image-store", shlex.quote(args.store)]
    if args.extra:
        cmd += [args.extra]
    body = _backend_exports(args) + " ".join(cmd) + "\n"

    array = f"0-{args.shards - 1}%{args.concurrent or args.shards}"
    script, log_dir = _write_script("run", args.tag, "")
    content = _header(
        job_name=f"swt-run-{args.tag}", log_dir=log_dir, array=array, **_sbatch_kwargs(args),
    ) + _preamble(py, args.conda_env) + body
    script.write_text(content)
    print(f"trials → {trials_dir}")
    if args.submit:
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

    p = sub.add_parser("run", help="Stage 1 trials (sharded sbatch array)")
    p.add_argument("--tag", required=True)
    p.add_argument("--model", default=DEFAULT_MODEL,
                   help="registry name (gpt-5.6-sol) or provider/model string")
    p.add_argument("--agent-backend", default=None, choices=list(llm_config.BACKENDS),
                   help="backend for a registry-named --model (default: $SWT_AGENT_BACKEND > "
                        "$SWT_LLM_BACKEND > native)")
    p.add_argument("--user-model", default=DEFAULT_USER_MODEL)
    p.add_argument("--user-sim-backend", default=None, choices=list(llm_config.BACKENDS))
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
    p.add_argument("--tagger-backend", default=None, choices=list(llm_config.BACKENDS))
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
