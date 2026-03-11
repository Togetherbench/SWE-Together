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

3 sessions converted to [Harbor](https://github.com/laude-institute/harbor) (TerminalBench harness) format with Docker environments, instructions, and test scripts:

| Task | Source Session | Description | Opus Score |
|------|---------------|-------------|------------|
| `unsloth-dev` | `2c7c75dd` | Add Idefics3 support + fix kwargs-only hook across 2 repos | **1.00** |
| `desloppify` | `5b7dfc2a` | Parallel review orchestration to improve code quality score | **0.85** (timed out) |
| `vllm-pr-review` | `bc295ce4` | PR review, debugging 3 bug categories, and collaboration | **0.64** |

Run with: `harbor run -p harbor_tasks/<task> -a claude-code -m anthropic/claude-opus-4-6 -n 1`

---

## Repository Structure

```
multi-user-turn-codebench/
├── README.md
├── analyze_sessions.py                 # Full analysis pipeline (Gemini 3 Pro)
├── session_analysis_results.json       # Analysis output for all 133 sessions
├── harbor_candidates.md                # Ranked Harbor task candidates with detail cards
│
├── harbor_tasks/                       # Harbor-compatible benchmark tasks
│   ├── desloppify/
│   │   ├── task.toml                   # Harbor task definition
│   │   ├── instruction.md              # Task description for agent
│   │   ├── environment/Dockerfile      # Docker environment
│   │   ├── tests/test.sh              # Verification script
│   │   └── original_session.json       # Source session data
│   ├── unsloth-dev/
│   │   └── ...
│   └── vllm-pr-review/
│       └── ...
│
├── sessions_raw/                       # 133 raw session JSON files (45MB)
│
└── session_collection/
    ├── sessions_with_popular_repos.json # Session metadata index
    ├── friction_analysis.md            # Friction signal methodology & findings
    ├── github_stars_cache.json         # Cached star counts
    └── README.md                       # Data documentation
```

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
