# TogetherBench

A benchmark derived from real multi-turn coding sessions, measuring **coding agent performance under iterative user correction** — the loop that single-turn benchmarks ignore.

**Live traces:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials)

---

## The Gap

Current coding agent benchmarks assume a Platonic ideal solver: one prompt, one solution. Real users are embedded in a correction loop — they have partial specs, discover requirements iteratively, and satisfaction is revealed incrementally.

```
Single-turn benchmarks:          Real coding sessions:
─────────────────────            ──────────────────────
Task prompt → Solution           Task prompt → Agent attempt
      ↓                                ↓
  Pass/Fail                      User: "no that's wrong, also..."
                                       ↓
                                 Agent attempt 2
                                       ↓
                                 User: "close but can you also..."
                                       ↓
                                 ... (N turns) → User accepts / abandons
```

## Benchmark

**45 tasks** derived from 2,228 real coding sessions (DataClaw). Each task has a Docker environment, a natural-language instruction (the real user's first message), and a deterministic verifier.

The key differentiator: an **LLM-powered user simulator** watches the agent work and injects corrections, redirects, and new requirements based on the original session's behavior — recreating the multi-turn correction loop.

### Results

> **Benchmark version:** `togetherbench@0.1.0` (45 tasks, commit `842f44f`, user sim v0.3.1)
>
> Results are tied to a specific benchmark version. The task set, user simulator, and test scripts can change between versions. Always reference the version when citing results.

| Model | Tasks Scored | Avg Reward | Perfect (1.0) | Zero (0.0) | Agent Timeouts |
|-------|-------------|-----------|---------------|-----------|----------------|
| **Sonnet 4.6** | 39 | **0.784** | 15 | 1 | 5 |
| **Kimi K2.5** | 38 | **0.663** | 13 | 2 | 13 |

Kimi has 2.6x more agent timeouts (OpenRouter latency). Timed-out tasks still receive partial credit from the verifier. 6-7 tasks have no trial yet (Docker build failures or new tasks without Dockerfiles).

---

## Quick Start

### Setup

```bash
# Clone at a specific release version
git clone https://github.com/findalexli/multi-user-turn-codebench.git
cd multi-user-turn-codebench
git checkout v0.1.0   # Pin to a release — results are only comparable within the same version

# Install dependencies
uv sync
```

### Running against a pinned version

Results are only meaningful when compared against the same benchmark version. Always pin to a release tag:

```bash
# Check which version you're on
cat registry.json | python3 -c "import json,sys; d=json.load(sys.stdin)['datasets'][0]; print(f\"{d['name']}@{d['version']} ({d['task_count']} tasks, sim v{d['user_sim_version']})\")"
# → togetherbench@0.1.0 (45 tasks, sim v0.3.1)
```

### Running a single task

```bash
ANTHROPIC_API_KEY=<key> .venv/bin/python src/runner.py \
    --task sageattention-headdim-256 \
    --model anthropic/claude-sonnet-4-6 \
    --user-model anthropic/claude-opus-4-6

# Or with Kimi via OpenRouter
OPENROUTER_API_KEY=<key> ANTHROPIC_API_KEY=<key> .venv/bin/python src/runner.py \
    --task sageattention-headdim-256 \
    --model openrouter/moonshotai/kimi-k2.5 \
    --user-model anthropic/claude-opus-4-6

# Using Claude Code as the coding agent (with user sim via --resume)
ANTHROPIC_API_KEY=<key> .venv/bin/python src/runner.py \
    --task sageattention-headdim-256 \
    --model anthropic/claude-sonnet-4-6 \
    --user-model anthropic/claude-opus-4-6 \
    --agent-type claude-code

# Using Codex as the coding agent (with user sim via sequential re-runs)
OPENAI_API_KEY=<key> ANTHROPIC_API_KEY=<key> .venv/bin/python src/runner.py \
    --task sageattention-headdim-256 \
    --model openai/o3 \
    --user-model anthropic/claude-opus-4-6 \
    --agent-type codex
```

### Running the full test suite

Run all tasks by iterating over `harbor_tasks/`:

```bash
for task in harbor_tasks/*/; do
    task_name=$(basename "$task")
    .venv/bin/python src/runner.py \
        --task "$task_name" \
        --model anthropic/claude-sonnet-4-6 \
        --user-model anthropic/claude-opus-4-6 &
done
wait
```

Results are written to `trials/<task>__<id>/verifier/reward.txt`.

### Viewing traces

**Hosted:** [traces.togetherbench.com](https://traces.togetherbench.com/jobs/trials) — includes Trajectory, User Simulation Prompt, and Agent Logs tabs.

Each trace shows a sim version badge (e.g., `User Sim v0.3.1 · 3/11 msgs`) indicating which simulator version produced the trial and how many messages it sent.

**Local:**
```bash
.venv/bin/python deploy/start_viewer.py
# Open http://localhost:9876
```

---

## Task Structure

Each task under `harbor_tasks/<name>/` contains:

| File | Purpose |
|------|---------|
| `instruction.md` | Agent reads this — the real user's first message, verbatim |
| `task.toml` | Metadata (difficulty, timeouts, resources) |
| `environment/Dockerfile` | Clones repo at specific commit, installs deps, synthesizes buggy state |
| `tests/test.sh` | Deterministic verifier returning 0.0–1.0 reward |
| `user_simulation_prompt.md` | Drives the user simulator — per-turn triggers, calibration, behavioral description |
| `original_session.json` | Raw session data (provenance) |

---

## User Simulator

The user simulator (`src/user_agent/`) is an LLM that role-plays as the original human user. It watches the agent's terminal output and decides when to intervene.

### Architecture (v0.4.0)

- **Multi-agent support** — `--agent-type` selects the coding agent backend:
  - `terminus` (default) — in-process LLM agent; user sim injects messages directly into chat history
  - `claude-code` — Claude Code CLI; multi-turn via `claude --resume <session_id>`
  - `codex` — Codex CLI; multi-turn via sequential re-runs with accumulated context
  - Other Harbor-installed agents (`aider`, `swe-agent`, etc.) — single-shot, no user sim
- **Conversation history** — accumulated across turns (tau-bench pattern). The LLM sees what it already said.
- **Hard message cap** — extracted from the task prompt or defaulted to GT count + 5. Enforced programmatically, never relying on LLM self-regulation.
- **Tool-calling for structured output** — the sim picks one of: `no-op`, `question`, `redirect`, `new_requirement`, `check_external`.
- **State-conditional triggers** — each user turn in `user_simulation_prompt.md` has a trigger condition (e.g., "ONLY send if agent tries `sudo dkms build`").

### Version History

| Version | Key Change | Repetition Rate | Clean Rate |
|---------|-----------|----------------|------------|
| v0.2 | Stateless — each LLM call independent | 16.7% | 37.5% |
| v0.3.0 | Conversation history + hard cap | 1.2% | 72.7% |
| v0.3.1 | Fixed fallback_parse leak | **0%** | **72.7%** |
| v0.4.0 | Multi-agent support (Claude Code, Codex) | — | — |

See `src/user_agent/CHANGELOG.md` for full details.

---

## Trial Output

```
trials/<task>__<id>/
├── config.json                     # Serialized trial config
├── user_simulation_prompt.md       # Copy of the sim prompt used
├── agent/
│   ├── trajectory.json             # Enriched ATIF trajectory (pre-built for fast viewing)
│   ├── episode-N/
│   │   ├── prompt.txt              # Terminal output the agent saw
│   │   ├── response.txt            # Agent's response (analysis + commands)
│   │   ├── debug.json              # Token/parsing debug info
│   │   └── user_decision.json      # Sim decision (action, content, version, stats)
│   └── recording.cast              # asciinema terminal recording
└── verifier/
    ├── test-stdout.txt             # test.sh stdout
    └── reward.txt                  # Final score (0.0–1.0)
```

---

## Data Pipeline

```
2,228 raw sessions (DataClaw, 32 HF datasets)
    ↓ GPT-5.4 quick screen + Opus 4.6 deep screen
69 VIABLE sessions
    ↓ scaffold-task + write-tests + validate-task
45 Harbor benchmark tasks
    ↓ run_full_eval.py (Sonnet 4.6 + Kimi K2.5)
317 trial directories → traces.togetherbench.com
```

The data pipeline is documented in the sections above.

---

## Versioning

Benchmark results are only meaningful when tied to a specific version. Three things can change between versions: the **task set** (tasks added/removed), the **user simulator** (how the simulated user behaves), and the **tests** (what the verifier checks).

### What constitutes a version

| Component | How it's tracked |
|-----------|-----------------|
| Task set | Git commit hash — task files are immutable at a given commit |
| Task integrity | SHA-256 directory hash per task (stored in every `trial/config.json` via Harbor) |
| User simulator | `UserAgent.VERSION` (e.g., `"0.3.1"`) — logged in every `user_decision.json` |
| Test scripts | Part of the task directory hash |
| Harness (Harbor) | `harbor.__version__` in `config.json` |

### Release format

```
togetherbench@0.1.0
  Tasks: 45
  Commit: 842f44f
  User sim: v0.3.1
  Harbor: 0.1.45
```

When citing results, always include the benchmark version:

> "Sonnet 4.6 scored 0.784 avg reward on togetherbench@0.1.0 (45 tasks, user sim v0.3.1)"

### Version history

| Version | Date | Tasks | User Sim | Key changes |
|---------|------|-------|----------|-------------|
| `@0.1.0` | 2026-03-28 | 45 | v0.3.1 | Initial release. Conversation history + hard cap. Sonnet 0.784, Kimi 0.663. |

---

## Data Source

Sessions sourced from [DataClaw](https://github.com/banodoco/dataclaw) — a community dataset of real coding agent interactions. Filtered for repos with 20+ GitHub stars. Dataset: [alexshengzhili/dataclaw-harbor-candidates](https://huggingface.co/datasets/alexshengzhili/dataclaw-harbor-candidates) (2,228 sessions).
