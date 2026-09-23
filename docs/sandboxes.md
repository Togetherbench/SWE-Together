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
  `github.com`, `huggingface.co`, … at `127.0.0.1`. On enroot it is superseded by
  the enforced egress namespace below (the sinkhole stays as defence in depth);
  on e2b/docker it is the only control and is **known to be bypassable**.

### Enforced egress: the container has no network except an allowlisting proxy

The hostname sinkhole can be, and was, defeated by agents — via
GitHub CDN mirrors (`cdn.jsdelivr.net/gh/…`, `gh-proxy.com`, `ghfast.top`),
read-through proxies (`r.jina.ai`), DNS-over-HTTPS + `curl --resolve`,
`LD_PRELOAD` resolver shims for `git`, search engines used to locate the task's
own PR. It was a *blocklist* enforced inside a container where the agent is root.

The enroot backend now enforces a **default-deny allowlist from outside the
container**:

```
container (unprivileged user+net namespace: loopback only)     compute node
  curl / pip / npm / cargo / git / opencode                    EgressProxy (src/proxies/egress_proxy.py)
    HTTPS_PROXY=http://127.0.0.1:3128 ──► relay ──unix socket──► decide(host) per src/egress_policy.py
                                                                 allow → CONNECT / forward
                                                                 deny  → 403 {"error": "egress denied", "reason": …}
```

* `unshare -Urn` creates the namespace; the relay process is its holder and every
  `enroot start` is prefixed with `nsenter -t <relay> -U -n`. Inside there is no
  route at all: `curl --noproxy '*'` exits 6/7, `--resolve host:443:<ip>` exits 7,
  DoH resolvers are simply unreachable. Nothing the agent does as in-container
  root changes this — the only exit is a unix socket it cannot see.
* **Policy** (`src/egress_policy.py`, one place): allow the model catalog
  (`models.dev`, `models.opencode.ai`) and, by `CONNECT`, only the LLM host the
  run's backend needs (Bedrock's regional endpoint, or the one vendor API for a
  native run — nothing for OpenRouter runs, see below); allow package registries (`pypi.org`, `files.pythonhosted.org`,
  `registry.npmjs.org`, `crates.io`, Ubuntu/Debian apt mirrors, NodeSource).
  Deny everything else. Known leak vectors are denied *with a reason* that the
  agent sees in the 403 body: GitHub and its CDNs/proxies, `r.jina.ai`, search
  engines, DoH, Hugging Face, and **`proxy.golang.org`** — the Go module proxy
  serves any GitHub repository verbatim (`go mod download github.com/<task
  repo>@main` is the fix), so the sandbox runs with `GOPROXY=off` and Go task
  images pre-populate their module cache. A task may extend the list via
  `task.toml` `[network] allow = ["download.pytorch.org"]`; leak vectors are
  rejected at load time. The policy digest is recorded per trial.
* **Credentials leave the sandbox.** opencode's openrouter provider is pointed at
  `http://127.0.0.1:3128/openrouter/api/v1`; the proxy injects the real
  `Authorization` header and the sandbox only ever holds a placeholder
  `OPENROUTER_API_KEY` (agents were observed reading the real key from the
  environment and calling the OpenRouter API from a shell). `GITHUB_TOKEN` is never forwarded.
  Bedrock STS credentials still enter the sandbox in this phase.
* **The LLM route is model-pinned.** Only `POST /api/v1/chat/completions` whose
  JSON `model` is the run's agent model is forwarded; `:online` variants,
  `plugins`, `web_search_options` and non-function tools are refused, and no
  `CONNECT` to `openrouter.ai` (or any other vendor API) is allowed for an
  OpenRouter run. Without this the route was an open LLM gateway: agents called
  web-enabled `:online` models through it and had *that* model fetch the GitHub
  PR for them.
* **Registry TLS is intercepted and the task's own packages are denied.** The
  proxy terminates TLS for registry hosts with a per-job CA
  (`src/proxies/egress_ca.py`; the bundle is installed in the container and every
  client is pointed at it via `SSL_CERT_FILE`/`PIP_CERT`/`NODE_EXTRA_CA_CERTS`/…),
  so it sees `GET /@scope/pkg/-/pkg-1.2.3.tgz`. At trial start the workspace's
  manifests (`package.json`, `pyproject.toml`, `setup.py`, `Cargo.toml`) are
  scanned into `agent/egress_task_packages.json`, and any version of those
  packages — plus registry search endpoints — is refused (`403`, reason
  `task's own npm package …`). Agents were observed downloading a newer release
  of the task's own package — the fix, in a tarball — from npm/PyPI. A client
  that drops the CA bundle fails TLS to the proxy: fail closed. Node's native
  `fetch` ignores `HTTPS_PROXY` and therefore has no route (npm/pnpm/bun/curl/
  pip/cargo/git all honour it).
* **Self-test before turn 0** (`agent/egress_selftest.json`): from inside the
  container, an allowlisted host must answer 200, four leak vectors must get 403
  from the proxy, and both `--noproxy` and `--resolve <ip>` bypasses must have no
  route. Any failure aborts the trial as `infra_failed(egress_policy_unenforced)`;
  a run never silently proceeds porous. Every proxied connection is logged to
  `agent/egress.log` (JSON lines: host, decision, reason, bytes); an *allowed*
  connection to a leak vector is `infra_failed(egress_policy_violation)`. Denied
  attempts are not failures — they are counted as `egress_denied_attempts` in
  `per_trial.json` (internal metric).
* `src/run_eval.py` starts one proxy per process (`<runtime root>/egress.sock`)
  and refuses a **leaderboard trials root** (`trials/canonical_*`) on any backend
  without enforcement unless `--allow-porous-sandbox` is passed; both that flag
  and `egress_enforced` are recorded in the run manifest.
  `--no-egress-enforcement` exists for debugging only. `scripts/slurm/launch.py
  run` preflights namespace support on the login node.

Enforcement matrix:

| Backend | Egress control | Leaderboard cohorts |
|---|---|---|
| enroot | namespace + allowlisting proxy (default) | yes |
| docker | `allow_internet` only (all-or-nothing; `network_mode: none` would also cut the LLM API) | refused without `--allow-porous-sandbox` |
| e2b | `allow_internet_access` only (all-or-nothing) | refused without `--allow-porous-sandbox` |
| judge sandbox | unrestricted (needs `claude.ai` installer + LLM API; it holds the oracle patch anyway) | n/a |

Trials recorded before this change ran on the sinkhole alone; they carry neither
`egress_selftest.json` nor `egress.log` and the sentinel leaves them untouched.

### opencode is installed from a cached binary, not from apt/npm

Harbor's stock `install-opencode.sh.j2` runs `apt-get update`, installs Node
from NodeSource and `npm i -g opencode-ai@<v>` inside every trial — five network
round-trips to three services to obtain one file. On 2026-09-11
`archive.ubuntu.com` stalled (30–60 s per request, then timeouts) and 16 trials
across two cohorts died at setup (`AgentSetupTimeoutError` after 360 s) before
the agent ever ran; nothing else in the pipeline was affected.

`opencode-ai` is a thin npm wrapper around a self-contained ELF binary
(`opencode-linux-x64`, libc-only), and every task image already ships `curl` and
`ca-certificates`, so the wrapper now (`src/opencode_dist.py`):

1. caches the binary once on the host under
   `<SWT_IMAGE_STORE>/tools/opencode/<version>/linux-x64/opencode`, verifying the
   npm `integrity` digest (`python src/opencode_dist.py 1.18.29`; the Slurm
   launcher does this in its preflight for `--opencode-version` / the wrapper's
   default pin);
2. uploads it into the sandbox with `environment.upload_file` and runs a
   three-line script that symlinks it onto `PATH` and checks `opencode --version`.

Setup drops from ~25 s (and ≥360 s when a mirror degrades) to a few seconds and no
longer depends on apt mirrors, NodeSource or the npm registry. If no cached
binary exists for the pinned version the wrapper logs a warning and falls back to
the stock apt/npm script, so unpinned or un-cached setups behave as before.

### Setup failures are infrastructure, not model failures

A trial Harbor aborts before the agent's first turn (`AgentSetupTimeoutError`,
`EnrootSetupError`) has no transcript at all, so the transcript-based sentinel
detectors cannot fire and the empty patch used to be scored **0.0** against the
model. `src/eval_infra_sentinel.py` now classifies such trials as
`infra_failed` (`pre_agent_failure`), which the leaderboard excludes, and
`src/run_eval.py` retries `AgentSetupTimeoutError` like the other transient
sandbox errors.

On relaunch, `--skip-existing` re-runs those tasks and **archives** the failed
predecessor dirs to `<trials_dir>/_failed/` first (no `__` in the name, so the
judge and aggregator ignore them); previously the failed dir stayed next to the
re-run and counted as an extra 0.0 replicate.

### The graded diff excludes run-generated files, and the user-sim diff is bounded

`capture_git_diff` (`src/user_agent/repo_diff.py`) diffs the repo against the
`harbor-base` tag after every turn and strips run-generated directories before
writing `agent/final.patch`. The filter covers virtualenvs, `node_modules`,
caches, and **language module caches** (`.go/`, `pkg/mod`, `.cargo`, `.npm`,
`.pnpm-store`, `.m2`, …). The last group matters because a task image may point a
package manager *into* the repo: `cli-fix-2026-0` shipped
`GOPATH=/workspace/repo/.go`, so any `go build` dropped ~7k vendored files into
the working tree and the cumulative diff grew to 270–370 MB. Two such trials
(Fable 5.1 r2, Opus 4.8 r2) had passed the verifier (1.0) but were judged
**0.0 "incorrect"** on the module-cache noise; a third overflowed the user-sim's
request limit and OOM-killed a shard.

Three guards now apply:

1. the filter above (the task's Dockerfile was also fixed to keep `GOPATH`
   outside the repo);
2. the per-turn incremental diff handed to the simulated user is capped at
   `USER_SIM_DIFF_MAX_CHARS` (200 k chars) with a truncation marker — it is a
   context hint, not the graded artefact, and unbounded it produced 70–125 MB
   prompts;
3. a trial still carrying `agent/diff_polluted.flag` (cumulative diff spanning
   > 300 files) is **skipped by the judge** and **refused by the aggregator**
   instead of being scored 0.0. `python src/repair_polluted_patches.py
   <trials_root>…` re-applies the current filter to stored patches, keeps the
   original as `final.patch.unfiltered`, retires the stale `judge_verdict.json`
   (→ `judge_verdict.polluted-N.json`) and clears the flag, so the next judge
   pass re-scores the trial on the agent's real edits. Flags that turn out to be
   genuine agent output (e.g. a generated fixture tree) are renamed to
   `diff_polluted.agent-edits` by hand after review.

### Recorded patches must apply cleanly in the judge sandbox

Investigating the re-judge exposed a second, older defect in the same path.
The diff text was `str.strip()`-ed before being written, so whenever the last
hunk ended on an **empty source line** its blank context line (a lone space)
was removed and the hunk came out one line shorter than its `@@` header — 232
of 1,941 recorded patches. `git apply` rejects such a patch as *corrupt*; the
judge sandbox chained the apply as `git apply … && chmod … || true`, so the
failure was swallowed, the judge was told the patch "has already been applied",
and it scored an **unmodified workspace**. Most judges noticed and applied the
diff by hand (38 verdicts say so), but several scored 0.0 on work that had
passed the verifier.

Fixes: `repo_diff` trims only empty lines (`_trim_diff`) instead of stripping;
`src/patch_normalize.py` builds the patch the judge applies from the recorded
diff — the **task repo's section only** (agents often clone scratch copies under
`/tmp`, and older recordings listed those first), with **submodule-pointer and
`Binary files … differ` blocks removed** (unapplyable and not gradable) and a
short last hunk repaired by shrinking its header (with an end-of-file fallback
candidate). The judge sandbox applies in the repo the recorder named (falling
back to the shallowest `.git`, never `find | head -1`, which picked a nested
submodule for the nunchaku tasks), tries the candidates with `git apply --check`
and no longer masks an apply failure (`patch_apply_failed` is reported instead).
The repair tool applies the same normalisation to stored patches and retires
verdicts that graded something other than the agent's edits: junk in the patch,
a patch the old judge could not have applied (scratch-clone-first, submodule,
binary), or notes showing the judge stumbled ("applied manually", "workspace
unmodified"). On `arr-monitor-add-processes-flag` 12 of 14 published trials had
been judged 0.0 with verifier ≥ 0.83 for exactly this reason.

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

**enroot < 4.0 cannot import the Go-based `cli-*` task images.** Their layers
contain a read-only Go module cache (`/go/pkg/mod`, directories `r-x`, files
`r--`). enroot 3.x extracts layers with plain `tar -px`, which applies a
directory's read-only mode as soon as the directory entry is seen and then fails
on the files inside it (`tar: …/gopre19.go: Cannot open: Permission denied`).
enroot 4.0 added `--delay-directory-restore` to the same `tar` call and is
unaffected. `prepull` reports these as import failures; import those images on a
host with enroot ≥ 4.0 (the login node here) into the same store — the `.sqsh`
format is compatible and the 3.5.0 compute nodes run them fine. `python -m
enroot_backend.images verify` lists what is still missing.

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
