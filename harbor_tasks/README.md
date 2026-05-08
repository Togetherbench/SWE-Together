# Harbor Tasks

Benchmark tasks derived from real multi-turn coding sessions. Each task ships with a Docker environment, a natural-language instruction (the original user's first message, verbatim), and a deterministic verifier. The user simulator (`src/user_agent/`, currently v0.6.0) drives the multi-turn correction loop on top.

**Live trace viewer**: https://traces.togetherbench.com/jobs/trials

## Suite snapshot — 190 tasks (post-v0.4.3, 2026-05-07)

| Source | Tasks | Notes |
|---|---:|---|
| **SWE-chat** (Stanford `SALT-NLP/SWE-chat`) | **122** | Largest wave, added post-v0.4.3 via PR #119. Of which **68 use SWE-rebench-style scoring** (see below). |
| **Pi-staging** (`badlogic/pi-share-hf` exports) | **32** | 31 `pi-mono-*` + 1 `pi-excel-*`. From the v0.4.3 wave. |
| **Hyperswitch** (`archit11/claude_traces_hs`) | **23** | Rust, single repo (`juspay/hyperswitch`). From the v0.4.3 wave. |
| **DataClaw** (`peteromallet/dataclaw` publishers) | **13** | Surviving tasks after the v0.4.3 audit + post-release pruning. |

Full provenance + screening funnel: see [`data-pipeline/README.md`](../data-pipeline/README.md).

## Two scoring tiers

Tasks coexist in two scoring formats:

### 1. Legacy F2P / P2P (122 tasks)
Per-task `tests/test.sh` + `tests/test_manifest.yaml` declares `F2P` (weighted) and `P2P_REGRESSION` (gating) gates. Reward uses the **weighted-replace formula**:
```
reward = legacy_score * inner_share + Σ(passed F2P weights)
```
where `inner_share = max(0, 1 − Σ F2P_weights)`. Naturally bounded to `[0, 1]`. P2P_REGRESSION gates can cap reward to 0.0 when a regression check fails. See [CLAUDE.md](../CLAUDE.md) §"Score formula" for the full spec.

### 2. SWE-rebench-style (68 tasks, all SWE-chat)
Per-task `tests/install_config.json` declares `language`, `log_parser`, `test_cmd`, `repo_dir`, `FAIL_TO_PASS` (test names extracted from the canonical patch's added test functions). The verifier:
1. Runs `test_cmd` and tees output to a log
2. Parses the log via the named parser (one of 76 vendored from [SWE-rebench-V2](https://github.com/swerebench/swerebench-v2), MIT)
3. Scores `passed_FAIL_TO_PASS / len(FAIL_TO_PASS)`, or overall pass rate when FAIL_TO_PASS is empty (38/68)

`tests/log_parsers.py` + `tests/swe_constants.py` are copied alongside `test.sh` so Harbor's `tests/` → `/tests` mount makes the parser available at runtime — no orchestrator change needed.

| Language | Tasks | Parser |
|---|---:|---|
| Go | 42 | `parse_log_gotest` |
| TypeScript (vitest via bun) | 22 | `parse_log_vitest` |
| TypeScript (vitest via pnpm) | 1 | `parse_log_vitest` |
| Rust | 4 | `parse_log_cargo` |

Migrate or generate via:
```bash
python data-pipeline/scaffold/build_swerebench_configs.py             # all eligible tasks
python data-pipeline/scaffold/build_swerebench_configs.py --task <name>
python data-pipeline/scaffold/build_swerebench_configs.py --dry-run
```

The legacy `tests/test.sh` + `tests/test_manifest.yaml` are preserved per task as `*.legacy.bak` (gitignored — recoverable from git history).

## Per-task layout

```
harbor_tasks/<task>/
├── instruction.md            # Agent reads this — the real user's first message, verbatim
├── task.toml                 # difficulty, [agent].timeout_sec, [environment].cpus / memory_mb / allow_internet
├── environment/
│   └── Dockerfile            # Clones repo at a pinned commit, installs deps, synthesizes buggy state
├── tests/
│   ├── test.sh               # Verifier — emits 0.0–1.0 reward
│   ├── test_manifest.yaml    # F2P / P2P_REGRESSION gates  (legacy tier)
│   ├── install_config.json   # log_parser config            (SWE-rebench tier)
│   ├── log_parsers.py        # Vendored parsers             (SWE-rebench tier)
│   └── swe_constants.py
├── user_simulation_prompt.md # Drives the user simulator — per-turn triggers, GT anchoring
├── original_session.json     # Raw session data (provenance)
└── README.md                 # Per-task notes (source session, repo, base commit, difficulty)
```

## How to run

```bash
# Single trial via Harbor CLI (no user simulator, single-turn)
harbor run -p harbor_tasks/<task> -a claude-code -m claude-opus-4-6 -n 1

# Single trial with user simulator (driven by src/runner.py)
ANTHROPIC_API_KEY=<key> uv run python src/runner.py \
    --task <task> --model anthropic/claude-sonnet-4-6

# Full async eval across N concurrent E2B sandboxes
ANTHROPIC_API_KEY=<key> uv run python src/run_eval.py \
    --model anthropic/claude-opus-4-6 --tag opus46 \
    --tasks <task1>,<task2>,... --workers 20 --env-type e2b
```

Trial output lands at `trials/<task>__<id>/` with `agent/`, `verifier/reward.txt`, and the user-sim decisions. See [`README.md`](../README.md) §"Running the full eval" for every supported `--model` provider prefix.

## How to add a new task

1. **Screen a session** — `/screen-session <session-id>` (7 hard requirements: public repo, ≥3 user msgs, no secrets, CPU-reproducible, etc.)
2. **Scaffold** — `/scaffold-task <name>` creates `harbor_tasks/<name>/` with instruction.md, user_simulation_prompt.md, task.toml, Dockerfile
3. **Write tests** — `/write-tests <name>` for the legacy F2P/P2P tier, OR run `build_swerebench_configs.py --task <name>` for the SWE-rebench-style tier
4. **Review** — `/review-task <name>` audits gaming-resistance + instruction/test alignment
5. **Validate** — `/validate-task <name>` runs buggy baseline + alt-fix in E2B; verifier should score `(0, 1)` on buggy state and `≥0.7` on alt-fix
6. **Eval** — `/run-eval <name>` runs full E2E with the user simulator (up to 5 iterations, opens a PR when done)

The bulk-scaffolding path for SWE-chat is automated end-to-end via `data-pipeline/scripts/step3_run_pipeline.py` (E2B + DeepSeek). See [`data-pipeline/README.md`](../data-pipeline/README.md).

## Versioning + reproducibility

Per-task contents are immutable at a given commit. The Claude Code CLI is pinned to **2.1.108** in every task image (`base_images/<cluster>/Dockerfile`) so eval runs across days use the same harness binary. See [CLAUDE.md](../CLAUDE.md) §"Claude Code harness version" for the bump procedure.

Benchmark version metadata is captured in every trial's `config.json` (Harbor version, task SHA-256, user-sim version). Always cite results with the version tag — task set, simulator, and tests evolve.
