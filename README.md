# multi-user-turn-codebench

A dataset and benchmark framework derived from real multi-turn Claude Code sessions, focused on measuring **coding agent performance in the presence of iterative user correction** — the loop that current benchmarks ignore.

---

## Core Problem Statement

Current coding agent benchmarks (TerminalBench, SWE-bench, etc.) have a fundamental distribution mismatch:

```
Benchmark reality:           Real Claude Code reality:
─────────────────            ──────────────────────────
Task prompt → Solution       Task prompt → Agent attempt
      ↓                            ↓
  Pass/Fail                    User: "no that's wrong, also..."
                                     ↓
                              Agent attempt 2
                                     ↓
                              User: "close but can you also..."
                                     ↓
                              ... (N turns)
                                     ↓
                              User accepts / abandons
```

The benchmark assumes a Platonic ideal solver. Real users are embedded in a correction loop — they have partial specs, they discover what they want as they go, and satisfaction is revealed incrementally.

---

## What We Built

### 1. Session Corpus (133 real sessions)

133 real multi-turn coding sessions from [Data Claw](https://github.com/banodoco/dataclaw), filtered for repos with ≥20 GitHub stars. Spans Claude, Gemini, Codex, MiniMax, and GLM models.

### 2. Session Analysis Pipeline

`analyze_sessions.py` processes all 133 sessions in two phases:

- **Phase 1 (deterministic):** Extracts user messages, tool usage stats, CLAUDE.md/SKILL.md content, dissatisfaction signals, language detection
- **Phase 2 (Gemini 3 Pro Preview):** Sends full conversation trajectory for task summarization, requirement change detection, completion verification, and friction point identification

**Dissatisfaction signals extracted:**
- `[Request interrupted by user]` text markers — 164 across 34 sessions (Claude Code format)
- `[Request interrupted by user for tool use]` — 97 of those, indicating tool-specific interruptions
- `status: "cancelled"` on tool_uses — 16 across 12 sessions (Gemini format)
- These signals are format-specific and [documented in detail](session_collection/friction_analysis.md)

### 3. Harbor Benchmark Tasks

4 sessions converted to [Harbor](https://github.com/laude-institute/harbor) (TerminalBench harness) format with Docker environments, instructions, and test scripts:

| Task | Source Session | Description | Opus Score |
|------|---------------|-------------|------------|
| `unsloth-dev` | `2c7c75dd` | Add Idefics3 support + fix kwargs-only hook across 2 repos | **1.00** |
| `desloppify` | `5b7dfc2a` | Parallel review orchestration to improve code quality score | **0.85** (timed out) |
| `vllm-pr-review` | `bc295ce4` | PR review, debugging 3 bug categories, and collaboration | **0.64** |
| `comfyui-fp8-newbie` | `c53e4e72` | Add fp8 quantized Gemma support to NewBie dual CLIP encoder | **1.00** |

#### Running tasks with Harbor

Install [Harbor](https://github.com/laude-institute/harbor) and run any task:

```bash
harbor run -p harbor_tasks/<task> -a claude-code -m claude-opus-4-6 -n 1
```

**Note:** Use `claude-opus-4-6` (not `anthropic/claude-opus-4-6`) — Harbor's claude-code adapter passes the model name directly to the Claude Code CLI which expects the short form.

Each task includes:
- `task.toml` — Harbor metadata (difficulty, timeouts, resources)
- `instruction.md` — Agent-facing task description
- `environment/Dockerfile` — Reproducible Docker environment with synthesized buggy state
- `tests/test.sh` — Deterministic verifier outputting a 0.0–1.0 reward score
- `analysis.md` / `analysis.json` — Conversion analysis and session provenance

### Running with Simulated User (runner.py)

`src/runner.py` wraps Harbor's `Terminus2` agent with a simulated user (`UserEnabledTerminus2`) that watches the action agent and injects messages based on ground-truth user interactions.

```bash
# 1. One-time setup
uv sync

# 2. Configure src/config.yaml
cat src/config.yaml
#   task: dataclaw-add-8d7f4a
#   model: gemini/gemini-3.1-pro-preview        # action agent
#   user_model: gemini/gemini-3.1-pro-preview   # user simulator
#   user_context_chars: 3000
#   call_user_on_completion: true

# 3. Run with Gemini
GEMINI_API_KEY=<key> uv run python src/runner.py --config src/config.yaml

# 4. Run with Anthropic
ANTHROPIC_API_KEY=<key> uv run python src/runner.py \
    --config src/config.yaml \
    --model anthropic/claude-opus-4-6 \
    --user-model anthropic/claude-haiku-4-5

# 5. Mixed providers (action=Gemini, user=Anthropic)
GEMINI_API_KEY=<k1> ANTHROPIC_API_KEY=<k2> uv run python src/runner.py \
    --config src/config.yaml \
    --model gemini/gemini-3.1-pro-preview \
    --user-model anthropic/claude-haiku-4-5

# 6. OpenRouter
OPENROUTER_API_KEY=<key> uv run python src/runner.py \
    --config src/config.yaml \
    --model openrouter/google/gemini-2.5-flash
```

### Viewing Traces

We patch Harbor's viewer to reconstruct full trajectories from Terminus2's per-episode files (`prompt.txt`, `response.txt`, `user_decision.json`). This shows agent reasoning, bash commands, terminal output, and user simulator interventions in the Trajectory tab.

```bash
# Start the patched viewer (must use local venv, not global harbor CLI)
.venv/bin/python -c "
import uvicorn
from harbor.viewer import create_app
from pathlib import Path
app = create_app(
    jobs_dir=Path('.'),
    static_dir=Path('external/harbor/src/harbor/viewer/static'),
)
uvicorn.run(app, host='127.0.0.1', port=8080)
"
```

Open http://127.0.0.1:8080 → **trials** → pick a trial → **Trajectory** tab.

**Hosted viewer** (no local setup needed): https://traces.togetherbench.com/jobs/trials

You can also export traces to Hugging Face Datasets format:

```bash
harbor traces export --path trials/
harbor traces export --path trials/ --sharegpt   # ShareGPT format
```

### Trial Output

Trial output is saved to `trials/<task>__<id>/`:
```
trials/desloppify__rDwLgZ3/
├── config.json                     # Serialized trial config
├── agent/
│   ├── episode-N/
│   │   ├── prompt.txt              # Prompt sent to action agent
│   │   ├── response.txt            # Action agent response
│   │   ├── debug.json              # Token/parsing debug info
│   │   └── user_decision.json      # User agent decision (action, content, cursor, stats)
│   ├── trajectory.json             # Full trajectory
│   └── recording.cast              # asciinema terminal recording
└── verifier/
    ├── test-stdout.txt             # test.sh stdout
    └── reward.txt                  # Final score (0.0–1.0)
```

---

## User Simulator Findings

The simulated user is driven by an LLM that reads `analysis.md` (session analysis with calibration data and enriched user turns) and decides when to intervene. Key design decisions:

- **instruction.md = first user turn, verbatim** — the agent starts with exactly what the real user typed
- **analysis.md = simulator prompt** — describes user behavior (not character), with exact message counts and silence gaps
- **Silence is the default** — real users give instructions once then wait 10-100+ turns

### User simulator calibration results (Opus 4.6)

| Task | Sim msgs | Real msgs | Ratio | Voice quality |
|------|----------|-----------|-------|---------------|
| comfyui-fp8-newbie | 6 | 2 | 3x | Good, on-topic |

Before calibration, the simulator sent 39-55 messages per session (11-27x the real user). The fix involved:
1. **Bug fix**: Harbor's LiteLLM wrapper was dropping `tool_calls`, causing analyst-voice output
2. **analysis.md calibration**: Added message counts, silence gaps, and enriched user turns with context
3. **Prompt tuning**: "Default to no-op, say it once, never repeat"

See [PR #11](https://github.com/findalexli/multi-user-turn-codebench/pull/11) for before/after traces.

---

## Key Findings

**From 133 sessions analyzed:**

| Metric | Value |
|--------|-------|
| Total user messages (filtered) | 2,498 |
| Tasks completed by agent | 69 (52%) |
| Tasks partially completed | 51 (38%) |
| Tasks failed | 12 (9%) |
| User satisfied | 36 (27%) |
| Sessions with dissatisfaction signals | 46 (35%) |
| Sessions with code modifications | 70 (53%) |
| Sessions with CLAUDE.md | 40 (30%) |
| Top Harbor candidates (score ≥ 0.8) | 41 |

**Friction analysis (from qualitative LLM review):**

| Friction Level | Sessions | % |
|----------------|----------|---|
| None | 58 | 44% |
| Low | 41 | 31% |
| Medium | 18 | 14% |
| High | 16 | 12% |

---

## Dissatisfaction Signal Format

User dissatisfaction is logged differently by each CLI:

| Format | Signal | Mechanism |
|--------|--------|-----------|
| Claude Code (UUID sessions) | `[Request interrupted by user]` | Text marker injected as user message |
| Claude Code (for tool use) | `[Request interrupted by user for tool use]` | Same, but during tool planning |
| Gemini CLI | `status: "cancelled"` on tool_uses | Structured field on tool entry |
| All formats | Natural language rejections | "no, don't do that" — requires LLM to detect |

See [friction_analysis.md](session_collection/friction_analysis.md) for full documentation.

---

## Data Source

Sessions sourced from [Data Claw](https://github.com/banodoco/dataclaw) — a community dataset of real coding agent interactions donated by users and published to HuggingFace.

Filtering criteria: sessions referencing GitHub repositories with ≥20 stars, as a proxy for real-world, non-trivial codebases.
