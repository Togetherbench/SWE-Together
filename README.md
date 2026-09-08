<h1 align="center">SWE-Together: Evaluating Coding Agents in Interactive User Sessions</h1>

<p align="center">
  <a href="https://arxiv.org/pdf/2606.29957"><img src="https://img.shields.io/badge/arXiv-2606.29957-b31b1b?logo=arxiv&logoColor=white" alt="arXiv"></a>
  <a href="https://togetherbench.com"><img src="https://img.shields.io/badge/Website-togetherbench.com-2563eb?logo=googlechrome&logoColor=white" alt="Website"></a>
  <a href="https://huggingface.co/datasets/yfwu/SWE-Together"><img src="https://img.shields.io/badge/%F0%9F%A4%97%20Dataset-SWE--Together-ffcc00" alt="Hugging Face Dataset"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green?logo=apache&logoColor=white" alt="License"></a>
</p>

---

**SWE-Together** reconstructs the multi-turn loop from real user–agent sessions, replaying each with a reactive **user simulator** that ask questions, new requirements etc and preserves the original users' intents. 

- **109 tasks**, each a first user message + a replayable interaction, run in a sandbox.
- Pluggable coding agents: **opencode, claude-code, codex, mini-swe-agent**.
- Reported axes: **correctness** (agentic judge), **User Correction** (how much the user had to push back the agent).

Browse the task specs in the [dataset viewer](https://huggingface.co/datasets/yfwu/SWE-Together), or load them without cloning:

```python
from datasets import load_dataset
ds = load_dataset("yfwu/SWE-Together", split="test")   # 109 task specs
```

Each row is a task spec (instruction, repo, base commit, scoring targets, reference patch, user intents). The row's `docker_image` points at the task's prebuilt environment on GHCR and `task_id` maps back to `tasks/<task_id>/` here (Dockerfile + verifier + user-sim prompts) — that's what makes the task *runnable*.


<p align="center">
  <img src="assets/leaderboard.png" alt="SWE-Together leaderboard — pass@1, pass², judge score, user correction, tokens, and minutes across frontier coding agents" width="100%">
</p>



---

## Quickstart

### 1. Install

```bash
uv sync                  # creates .venv with harbor (editable) + deps
cp .env.example .env     # then fill in the keys you need (table below)
```

Run everything below with the project venv (`.venv/bin/python`) so harbor is importable.

### 2. Pick a sandbox

Trials (and the judge) run inside containers of the task images. Set `SWT_SANDBOX` in `.env`:

| `SWT_SANDBOX` | where trials run | needs |
|---|---|---|
| `e2b` (default) | E2B cloud sandboxes, scales to 100+ concurrent | an [E2B](https://e2b.dev) account (`E2B_API_KEY`) |
| `docker` | local Docker (judge still on E2B) | Docker + `E2B_API_KEY` |
| `enroot` | enroot containers on a Slurm cluster | `enroot` + Slurm, no sandbox account |

All task images are pulled from `ghcr.io/togetherbench/*` (public). Details, including the Slurm
launcher for `enroot`, are in [docs/sandboxes.md](docs/sandboxes.md).

### 3. Launch run

The launcher reads a plan and drives both stages. It is **dry-run by default** — it prints the commands; add `--execute` to actually run.

```bash
# Preview the full canonical run
.venv/bin/python launch.py canonical_full109.json

# Produce trials for one cohort, then score it
.venv/bin/python launch.py canonical_full109.json --stage run   --models opencode_opus48 --execute
.venv/bin/python launch.py canonical_full109.json --stage judge --models opencode_opus48 --execute
```

Trials land in `trials/canonical_full109/<tag>_r<k>/`; judge aggregates in `results/<tag>/`.

On a Slurm cluster with `SWT_SANDBOX=enroot`, submit the same two stages as batch jobs instead:

```bash
.venv/bin/python scripts/slurm/launch.py prepull --submit                       # import task images once
.venv/bin/python scripts/slurm/launch.py run   --tag opencode_opus48_r1 --submit
.venv/bin/python scripts/slurm/launch.py judge --trials-root trials/opencode_opus48_r1 \
    --output-dir results/opencode_opus48 --model-tag opencode_opus48 --submit
```

### 4. Optionally, run the two stages separately

```bash
# Stage 1 — agent solves the tasks (one cohort)
.venv/bin/python src/run_eval.py \
  --model openrouter/anthropic/claude-opus-4-8 \
  --tag opus48 --agent-type opencode \
  --workers 25 --agent-timeout 4800 \
  --trials-dir trials/opus48_r1
# (--env-type e2b|docker|enroot overrides SWT_SANDBOX; --dry-run to preview,
#  --tasks a,b for a subset, --skip-existing to resume, --shard k/n to split
#  across machines, rerun with --trials-dir trials/opus48_r2 for a replicate)

# Stage 2 — judge & score (repeat --trials-root per replicate)
.venv/bin/python -m eval.run_eval \
  --trials-root trials/opus48_r1 --trials-root trials/opus48_r2 \
  --tasks-root tasks --output-dir results/opus48 --model-tag opus48
```

---

## Environment keys

Most runs need only a subset; `.env.example` documents them all.

| key | used for |
|---|---|
| `SWT_SANDBOX` | `e2b` / `docker` / `enroot` — where trials and the judge run |
| `SWT_LLM_BACKEND`, `SWT_<SEAT>_BACKEND` | `native` / `openrouter` / `bedrock` per LLM seat (agent, user_sim, judge, tagger) — see [docs/llm_backends.md](docs/llm_backends.md) |
| `OPENROUTER_API_KEY` | the agent model (or the provider key matching your model) |
| `GEMINI_API_KEY` | user simulator + message tagging with the default `gemini/…` models |
| `ANTHROPIC_API_KEY` | the Step-1 agentic judge |
| `SWT_AWS_CREDENTIAL_CMD`, `SWT_AWS_REGION` | AWS credentials for the `bedrock` backend when the host has none |
| `E2B_API_KEY` | the sandbox (run **and** judge) when `SWT_SANDBOX=e2b` or `docker` |
| `SLURM_QOS`, `SLURM_ACCOUNT`, … | your cluster's submission settings when `SWT_SANDBOX=enroot` (kept in `.env`, never committed) |

**Single-key setup.** Everything can be routed through OpenRouter: set `JUDGE_VIA_OR=1` (judge →
`anthropic/claude-opus-4.6` on OpenRouter) and pass `--user-model openrouter/google/gemini-3.1-pro-preview`
to the run stage and `--tag-model openrouter/google/gemini-3.1-pro-preview` to the judge stage; then only
`OPENROUTER_API_KEY` is needed. With `SWT_SANDBOX=enroot` no sandbox account is needed either.

**Mixing backends.** Each of the four LLM seats can be served by a different backend — e.g. the agent
under test on AWS Bedrock (`--model gpt-5.6-sol --agent-backend bedrock`) with the user simulator, judge
and tagger unchanged on OpenRouter. Models can be given by short registry name and are translated to the
id each backend expects. Details, credentials and caveats: [docs/llm_backends.md](docs/llm_backends.md).


---

## How it works

Tasks are **progressively revealed**, not one-shot. The agent gets `instruction.md` as turn 0; a **user simulator** then watches it and replays the original session's follow-ups — clarifications, course-corrections, reviews — so a score reflects the whole interaction. Each cohort runs for multiple replicates.

Scoring centers on two axes:

- **Correctness** — an agentic judge decomposes each task into *weighted completeness goals* (frozen per task, so scores are comparable across cohorts) and marks the agent's patch against them, crediting near-misses fairly. Rolled up as `pass@1`, `stable_pass_rate`, and `pass²` at a `judge_score ≥ 0.85` bar.
- **User Correction** — `#correction + 0.2·nudge`, from per-message tags: how much the user had to push the agent back on track. 

---

## Tasks

Each task under `tasks/<name>/` carries its instruction, the user-simulation prompt, a Dockerized environment pinned to a base commit, a `tests/` gate suite, and a reference patch + frozen judge rubric. The launcher's plan (`canonical_full109.json`) lists the canonical 109; edit `models` / `replicates` / `tasks` there to define your own run.

---

## Citation

If you use SWE-Together, please cite our [paper](https://arxiv.org/pdf/2606.29957):

```bibtex
@article{wu2026swetogether,
  title   = {SWE-Together: Evaluating Coding Agents in Interactive User Sessions},
  author  = {Wu, Yifan and Zhao, Zhuokai and Li, Songlin and Lee, Ho Hin and Zhu, Jiacheng and Wu, Shirley and Yu, Tianhe and Li, Serena and Zhang, Lizhu and Fan, Xiangjun and Li, Shengzhi},
  year    = {2026},
  journal = {arXiv preprint arXiv:2606.29957},
  url     = {https://arxiv.org/pdf/2606.29957}
}
```
