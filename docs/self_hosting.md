# Self-hosting a model for the agent seat (`vllm` backend)

Run an open-weights model on the cluster and benchmark it with exactly the
same harness as a vendor-served one. Two Slurm jobs are involved:

```
launch.py serve  ──▶  GPU node: vllm serve <model>  ──▶  slurm_logs/serve/<tag>_<date>/endpoint.json
                                                                   │
launch.py run --agent-backend vllm --serve-job <that dir>          ▼
    CPU nodes: trial sandboxes ──▶ relay 127.0.0.1:3128/vllm/ ──▶ egress proxy ──▶ http://<node>:<port>
```

The trial sandbox only ever sees the relay; the proxy forwards to the server,
pins the model, and injects the server's API key (if any). Everything downstream
— user-sim, judge, aggregation, leaderboard — is unchanged.

## 1. One-time setup

**Serving environment** (vLLM has its own CUDA/torch pins; keep it separate
from the benchmark env):

```
conda create -n swt-vllm python=3.12 -y
conda run -n swt-vllm pip install -r scripts/serving/requirements-vllm.txt
conda run -n swt-vllm vllm --version
```

**Weights.** Download once to shared storage, laid out as `<root>/<hf repo>`:

```
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download zai-org/GLM-5.3 --local-dir <root>/zai-org/GLM-5.3
```

Large checkpoints (GLM-5.3 is ~750 GB of FP8 safetensors) are best downloaded
from a CPU Slurm allocation; check `config.json` and the shard count against the
repo's `model.safetensors.index.json` before serving.

**`.env`:**

```
SWT_VLLM_CONDA_ENV=swt-vllm
SWT_VLLM_WEIGHTS_ROOT=<root>
SWT_VLLM_API_KEY=<random string>     # optional; becomes vllm --api-key, injected by the relay
```

## 2. Registering a model

Two entries, both keyed by the registry name:

* `src/llm_config.py` — `ModelSpec("glm-5.3", vllm="glm-5.3")`: the served-model
  name (`vllm/glm-5.3` is the fully-qualified model string).
* `src/serving/registry.py` — a `ServingSpec`: HF repo, served name, the prompt
  window and max output to serve, the `reasoning_effort` values the chat
  template distinguishes, and the model's published `vllm serve` flags (take
  them from the vLLM recipe for the model).

The effort list matters: the benchmark runs `--reasoning-effort high`, and a
template that maps unknown values somewhere else would silently change the
setting. A run asking for an effort the spec does not list is refused.

## 3. Serve

```
python scripts/slurm/launch.py serve --model glm-5.3 --tag glm53 --max-model-len 262144 --submit
```

This submits a GPU job (`--gpus 8 --cpus 64 --mem 1000G --time 3-00:00:00` by
default) that runs `python -m serving.vllm_server serve …` inside the serving
env: it launches `vllm serve` with the recipe's flags, waits for `/health` and
`/v1/models`, writes `endpoint.json` to the serve log dir, and removes it again
when the server exits so a dead server never looks live. Follow
`slurm_logs/serve/glm53_<date>/<job>.out`; loading a ~750 GB model takes tens of
minutes (storage read + CUDA graph capture).

`--max-model-len` is the main capacity knob. The prompt window times the number
of concurrent agents must fit the node's KV budget; the recipe's context limit
is the upper bound, and the served value is written into `opencode.json` so the
agent's compaction matches what the server accepts. Extra flags go through
`--extra-vllm-args '--max-num-seqs 32'`.

Smoke-test from a login node before launching trials:

```
curl -s http://<node>:8000/v1/models
curl -s http://<node>:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"glm-5.3","reasoning_effort":"high","messages":[{"role":"user","content":"hi"}]}'
```

## 4. Run trials

```
python scripts/slurm/launch.py run --tag glm53_r1 --model glm-5.3 --agent-backend vllm \
    --serve-job slurm_logs/serve/glm53_<date> --shards 4 --workers 4 --submit
```

`--serve-job` does three things: a Slurm `--dependency=after:<serve job>` so the
array starts once the server job is running; `--vllm-endpoint <dir>/endpoint.json`
so `run_eval.py` knows where to look; and a login-node preflight that probes
`/v1/models` if the handoff already exists and fails if the served name differs.
Inside the job `run_eval.py` waits (`--vllm-wait-s`, default 3600 s) until the
server lists the model, then installs the `/vllm/` relay route and starts trials.
`--vllm-endpoint` (a handoff file, a serve dir, or a bare URL) or
`SWT_VLLM_ENDPOINT` can replace `--serve-job` when the server is managed by hand.

Concurrency: a single node serving a very large model will not sustain the
default 12 shards × 6 workers. Start around 4 × 4 and watch the server's
`/metrics` (running/waiting sequences, preemptions, time-to-first-token); raise
`--agent-timeout` if first-token latency climbs. Two replicates can run against
one server, or each against its own.

Judge and aggregate exactly as for any other cohort:

```
python scripts/slurm/launch.py judge --trials-root trials/glm53_r1 --trials-root trials/glm53_r2 \
    --output-dir results/glm53 --model-tag glm53 --submit
```

## 5. Stop

```
python -m serving.vllm_server stop --handoff slurm_logs/serve/glm53_<date>
```

(or `scancel <job>`). The handoff file is removed by the serve job on exit.

## What a trial records

* `agent/egress.log`: route decisions (`allow:llm-route`, the pinned `model`,
  `auth_injected`) — the only egress a vllm run's agent has for its model.
* The run manifest: `agent_backend: vllm`, `served_model`, the serve job id,
  port, `max_model_len` and vLLM version; policy v3 digest (includes the route).
  The node address stays in the local `endpoint.json`, not in the manifest.
* `opencode.json` inside the sandbox: a `vllm` provider with
  `baseURL http://127.0.0.1:3128/vllm/v1`, the placeholder key, `limit`
  (context/output) and the effort `variants`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `waiting for vLLM handoff` for a long time | server still loading; check the serve job's `.out`. If the serve job died the wait fails as soon as it leaves the queue. |
| `vLLM at … serves […], not 'glm-5.3'` | wrong `--served-model-name` or a different model on that port; stop and re-serve. |
| trials fail with 502 from the relay | server crashed mid-cohort; re-submit `serve`, then re-run the cohort with `--serve-job` (completed trials are skipped). |
| agent requests refused with `model not pinned` | the agent asked for a model other than the served one; nothing to fix — that is the pin working. |
| slow first tokens, agent timeouts | KV budget exhausted: lower `--max-model-len`, `--max-num-seqs`, or shards × workers. |
| tool calls / reasoning not parsed | check the recipe's `--tool-call-parser` / `--reasoning-parser`; try without speculative decoding (`--extra-vllm-args`) before changing anything else. |
