# Sandboxes

Every trial runs the coding agent inside an isolated container built from the
task's prebuilt image (`ghcr.io/togetherbench/multi-user-turn-codebench/<task>:<tag>`,
all public). The judge later re-applies the agent's patch inside a fresh container
of the same image. Three backends are supported; pick one with a single switch.

## Choosing a backend

Set `SWT_SANDBOX` in `.env` (or pass `--env-type` to `launch.py` / `src/run_eval.py`,
which overrides it):

| `SWT_SANDBOX` | Trials run in… | Judge runs in… | Needs | Best for |
|---|---|---|---|---|
| `e2b` (default) | E2B cloud microVMs | E2B | `E2B_API_KEY`; Pro tier for the 90-min trial budget and 4-CPU templates | No local infra; the published leaderboard setup |
| `docker` | local Docker via compose | E2B | Docker + `E2B_API_KEY` for the judge | Small local runs |
| `enroot` | enroot containers on Slurm compute nodes | enroot | `enroot` ≥ 3.5, Slurm, tmpfs (`/dev/shm`) | Clusters; no sandbox account, unlimited concurrency |

`JUDGE_SANDBOX=e2b|enroot` overrides the judge alone (rarely needed).

The selection logic lives in `src/sandbox_config.py`; it is the only place that
knows the defaults, so it is also where to read the precedence rules.

## Common behaviour (all backends)

* The agent runs as **root** inside the container (Harbor's agent installers need
  `apt`/`npm`), the task's `tests/test.sh` runs inside the same container, and
  `/logs/{agent,verifier,artifacts}` end up in `trials/<run>/<task>__<id>/`.
* Each trial is capped at `TRIAL_BUDGET_SEC` (5400 s) with `PER_EXEC_CAP_SEC`
  (1800 s) per agent turn (`src/user_agent/exec_helpers.py`).
* Task images ship a **DNS sinkhole** (`environment/seal-dns.sh`) that points
  `github.com`, `huggingface.co`, … at `127.0.0.1` so the agent cannot fetch the
  upstream fix. Every backend must keep it in force.

## e2b

Nothing to configure beyond `E2B_API_KEY`. The first run builds one E2B template
per task (alias `tb-<task>__<dirhash>`; `HARBOR_TEAM_PREFIX` namespaces them) and
subsequent runs reuse it. `--force-build` rebuilds a template.

## docker

Requires `docker compose`. Harbor bind-mounts the trial directory, so logs are live.
The judge (`eval/correctness/`) has no Docker implementation and falls back to E2B.

## enroot

Designed for Slurm clusters where Docker is unavailable. All code is in
`src/enroot_backend/`; nothing outside it (and a one-line `EnvironmentType.ENROOT`
enum entry in the vendored Harbor) knows about enroot.

```
src/enroot_backend/
  runtime.py      tmpfs paths, async subprocess plumbing, process cleanup
  container.py    EnrootContainer: create / exec / host-side file transfer / remove
  images.py       .sqsh image store + `python -m enroot_backend.images prepull|verify`
  hosts.py        DNS-sinkhole /etc/hosts generated from tasks/*/environment/seal-dns.sh
  environment.py  Harbor BaseEnvironment adapter (Stage 1)
eval/correctness/judge_sandbox.py   EnrootJudgeSandbox (Stage 2), same primitives
scripts/slurm/launch.py             sbatch renderer: prepull | run | judge | cleanup
scripts/slurm/smoke_enroot.py       checklist to validate a host before a real run
```

### How a trial maps onto enroot

| Harbor expectation | enroot implementation |
|---|---|
| root shell, writable rootfs across many `exec` calls | `enroot start --root --rw` |
| `/logs/*` visible on the host | `--mount trial_dir/agent:/logs/agent` (and verifier, artifacts) → `is_mounted=True` |
| files written to `/tmp` persist between execs (proxy script, judge inputs) | enroot gives every `start` a fresh `/tmp` tmpfs, so a per-container host dir is mounted over `/tmp` |
| DNS sinkhole | enroot binds the host `/etc/hosts` read-only; a generated hosts file is mounted over it (`hosts.py`) |
| upload/download files | host-side `shutil` into the rootfs at `$ENROOT_DATA_PATH/<name>/`, mount-aware (`container.host_path`) |
| container teardown kills everything | enroot has **no PID namespace**; background daemons survive `enroot remove`. Every exec is tagged `-e SWT_CONTAINER=<name>` and `remove()` kills matching PIDs from `/proc/*/environ` first |
| exec returns when the command exits | a background process holding the exec's stdout pipe would block forever; command output is redirected to files inside the persistent `/tmp` and read back |

### Settings (`.env`)

```
SWT_SANDBOX=enroot
SWT_IMAGE_STORE=/shared/path/enroot_images   # default: <repo>/enroot_images
SWT_ENROOT_BASE=/dev/shm/swt                 # must be tmpfs
SLURM_QOS=...      SLURM_ACCOUNT=...         # site-specific, never committed
SLURM_PARTITION=... SLURM_EXTRA="--constraint=x;--exclusive"   # optional
SWT_CONDA_ENV=swetogether                    # env name or absolute prefix on compute nodes
```

`ENROOT_TEMP_PATH`/`ENROOT_DATA_PATH` **must be tmpfs**: Lustre/NFS cannot create
the whiteout devices enroot needs, and the error message does not say so. The
runtime asserts this and refuses to start otherwise.

### Image store

`enroot import` converts each Docker image to a `.sqsh` once; containers are then
created from it in ~2 s. Layout:

```
<SWT_IMAGE_STORE>/_store/<task>__<tag>.sqsh        the bytes
<SWT_IMAGE_STORE>/swe_together/<task>__<tag>.sqsh  symlink into _store
<SWT_IMAGE_STORE>/_locks/<task>__<tag>.lock        per-image flock
```

The tag is the image's content hash from `task.toml`, so a task-image bump never
reuses stale bytes. All 109 images total ~98 GB compressed (~130 GB as `.sqsh`).
Import on compute nodes with `launch.py prepull`; a missing image is imported on
demand at trial start (slower, and it holds a worker slot).

### Workflow

```bash
# 0. validate the host once (login node is fine for this)
python scripts/slurm/smoke_enroot.py

# 1. import all task images (sbatch array; ~20 min)
python scripts/slurm/launch.py prepull --submit

# 2. trials: one array, trials strided over shards, N concurrent trials per array task
python scripts/slurm/launch.py run --tag muse13_r1 --shards 12 --workers 6 --submit
python scripts/slurm/launch.py run --tag muse13_r2 --shards 12 --workers 6 --submit

# 3. judge + aggregate (single job)
python scripts/slurm/launch.py judge \
    --trials-root trials/muse13_r1 --trials-root trials/muse13_r2 \
    --output-dir results/muse13 --model-tag muse13 --submit
```

Every subcommand is a dry-run without `--submit` and writes the rendered script to
`slurm_logs/<sub>/<name>_<timestamp>/job.sbatch` for inspection. `run` passes
`--skip-existing`, so resubmitting a shard resumes: finished trials are kept,
trials flagged `infra_failed` by the sentinel are redone.

Sizing defaults (`run`): 32 CPU / 128 GB / 8 h per array task with 6 concurrent
trials. Container rootfs lives on tmpfs, which is charged to the job's memory
cgroup, so budget roughly 4 GB process + 8 GB rootfs per concurrent trial.

### Running enroot without the launcher

`src/run_eval.py --env-type enroot --shard k/n …` and `python -m eval.run_eval …`
(with `SWT_SANDBOX=enroot`) work from any shell on a compute node, as long as
`ENROOT_TEMP_PATH`/`ENROOT_DATA_PATH` point at tmpfs. The launcher only adds the
sbatch header, the tmpfs exports, and a cleanup trap that removes `swt-*`
containers on exit or preemption. `launch.py cleanup` removes leftovers by hand.

## Adding another backend

Stage 1: subclass `harbor.environments.base.BaseEnvironment` (see
`src/enroot_backend/environment.py` for the smallest complete example) and select
it with `EnvironmentConfig(import_path="module:Class", kwargs={...})` in
`src/run_eval.py:build_trial_config`. Stage 2: implement the four-method
`JudgeSandbox` protocol in `eval/correctness/judge_sandbox.py`. Then add the name
to `SANDBOXES` in `src/sandbox_config.py`.
