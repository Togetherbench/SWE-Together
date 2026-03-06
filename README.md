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

## What Data Claw Enables

The key insight is that uploaded Claude Code sessions contain latent signals that current benchmarks ignore:

| Signal | What it tells you |
|--------|-------------------|
| Follow-up corrections | The first response missed something |
| Rephrasing the same ask | Agent didn't understand intent |
| Explicit dissatisfaction ("no", "that's not what I meant") | Quality failure |
| Abandonment without acceptance | Task failed silently |
| Long back-and-forth on simple tasks | Friction / efficiency failure |
| Quick acceptance after N turns | Minimum viable satisfaction point |

---

## The Novel Benchmark Architecture

Rather than `(task, golden_solution) → pass/fail`, you'd build:

```
(session_context, task_distribution, satisfaction_oracle) → multi-turn score
```

### Three components:

**1. Task Extraction**
From real sessions, extract what users actually wanted — not the literal first message, but the *revealed preference* after the whole session. A user who asks "add a button" then "make it blue" then "put it on the right" wanted a blue right-aligned button all along.

**2. Environment Replay**
The Docker/sandbox environment should reflect the user's actual repo state at session start, not a synthetic repo. Data Claw sessions uploaded to HuggingFace give you this — real codebases, real contexts.

**3. Satisfaction Simulation**
Instead of binary pass/fail, simulate a user who:
- Accepts if the solution matches revealed intent
- Issues correction turns based on the real session's correction patterns
- Scores on **turns-to-acceptance**, not just final correctness

---

## Key Research Questions

1. **Turn efficiency** — Can a better agent solve in 1 turn what the real session needed 5 turns for? This is a cleaner metric than pass/fail.
2. **Intent gap measurement** — How far is the first user message from their actual intent? This quantifies how underspecified real tasks are.
3. **Dissatisfaction taxonomy** — What categories of agent failure cause follow-up corrections? (Wrong semantics vs. wrong style vs. incomplete vs. regression)
4. **User patience distribution** — Some users give 1 correction then abandon; others iterate 20 times. An agent should be evaluated against the realistic distribution, not an infinitely patient oracle.

---

## Positioning vs. Existing Work

| Benchmark | What it tests | What it misses |
|-----------|--------------|----------------|
| SWE-bench | Can agent patch real GitHub issues? | Real user interaction, partial specs |
| TerminalBench | Can agent complete terminal tasks? | Multi-turn, user correction loop |
| WebArena | Can agent navigate web tasks? | Coding-specific, real sessions |
| **This work** | Can agent satisfy real users efficiently? | *(this is the gap we're filling)* |

---

## Potential Weaknesses to Address

- **Privacy** — Real sessions may contain sensitive code/data. Need a scrubbing pipeline.
- **Selection bias** — Users who upload sessions may not be representative.
- **Counterfactual problem** — You observe what the real agent did, not what an optimal agent would do. Need to separate "user corrected because agent failed" from "user corrected because they changed their mind."
- **Satisfaction oracle** — Simulating the correcting user is itself a hard ML problem — need to avoid circular evaluation.

---

## Repository Structure

```
multi-user-turn-codebench/
├── README.md                     # This file
└── session_collection/
    ├── README.md                 # Session data documentation
    ├── sessions_with_popular_repos.json   # 133 sessions on repos ≥ 20 stars
    └── github_stars_cache.json   # Star counts for all repos encountered
```

---

## Data Source

Sessions sourced from [Data Claw](https://github.com/banodoco/dataclaw) — a community dataset of real Claude Code interactions donated by users and published to HuggingFace.

Session filtering criteria: sessions that reference GitHub repositories with ≥ 20 stars, as a proxy for real-world, non-trivial codebases.
