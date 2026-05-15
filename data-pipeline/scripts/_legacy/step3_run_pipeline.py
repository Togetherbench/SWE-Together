#!/usr/bin/env python3

# ⚠️  DEPRECATED 2026-05-14 — moved to _legacy/ by dead-code audit.
# Targets data-pipeline/screening/ which does not exist; never run from this path.
# Keep for git history / archaeology only.

"""Single-stage SWE-chat → Harbor task scaffolder (E2B + DeepSeek-v4-pro).

Reads pre-fetched session JSONs from sessions_raw/ (populated by
step3_prefetch_viable.py) and hands each to a `claude -p` worker running inside
an E2B sandbox. Per task: spin sandbox → install claude-code → upload session
JSON + lint_tests.py + scaffold prompt → run claude-code against DeepSeek's
/anthropic endpoint → tar+harvest harbor_tasks/<name>/ back to local repo.

This script does NOT touch HF or parquet at run time — that's step3's job.
Run step3 first if any candidates are uncached.

Two input modes:
  --session-ids a,b,c          explicit session_ids (no screening required)
  --from-screening             read VIABLE candidates from step2_candidates.json

Outputs:
  harbor_tasks/<task>/                                 one dir per scaffolded task
  data-pipeline/scaffold/logs/<task>.json              per-task log
  data-pipeline/scaffold/logs/summary.json             run summary

Examples:
  # First, prefetch (once):
  python data-pipeline/screening/scripts/step3_prefetch_viable.py

  # Then, scaffold:
  python data-pipeline/scaffold/run_pipeline.py \\
      --session-ids 6a15955e-2329-4286-b213-af704b432131 --workers 1
  python data-pipeline/scaffold/run_pipeline.py --from-screening --limit 10 --workers 8
  python data-pipeline/scaffold/run_pipeline.py --from-screening --one-per-repo --workers 15
  python data-pipeline/scaffold/run_pipeline.py --from-screening --workers 8 \\
      --template harbor-scaffold-cc2-1-108-8c-4g  # use custom 8 vCPU pre-baked template
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import os
import re
import sys
import tarfile
import time
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

# ──────────────────────────────────────────────────────────────────────────────
# Paths + constants
# ──────────────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS_DIR = ROOT / "harbor_tasks"

SCREENING_DIR = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
SC_CANDIDATES = SCREENING_DIR / "step2_candidates.json"
SC_STEP1 = SCREENING_DIR / "step1_all_sessions.json"
SC_SESSIONS_DIR = SCREENING_DIR / "sessions_raw"

SCAFFOLD_DIR = ROOT / "data-pipeline" / "scaffold"
LOG_DIR = SCAFFOLD_DIR / "logs"
LINT_TESTS_PATH = ROOT / "scripts" / "lint_tests.py"

SWECHAT_HF_REPO = "SALT-NLP/SWE-chat"

# CC version pinned in CLAUDE.md (matches benchmark task images for reproducibility).
CC_VERSION = "2.1.108"

# Custom E2B template alias with claude-code pre-baked (built by build_template.py).
# When `--template` matches this prefix, we skip the per-sandbox npm install.
PREBAKED_TEMPLATE_PREFIX = "harbor-scaffold-"

# E2B + claude-code timeouts.
SANDBOX_TIMEOUT = 3600       # max sandbox lifetime (s)
INSTALL_TIMEOUT = 240        # npm install claude-code (only when template lacks it)
SCAFFOLD_TIMEOUT = 1800      # claude -p scaffold run
HARVEST_TIMEOUT = 60

DEFAULT_WORKERS = 8
DEFAULT_BUDGET = 5.0


# ──────────────────────────────────────────────────────────────────────────────
# Env loading
# ──────────────────────────────────────────────────────────────────────────────

def _load_env_from_dotenv() -> None:
    """Best-effort load of .env into os.environ (no override).

    Searches the worktree root first, then the parent git repo (worktrees
    inherit .env from the main checkout)."""
    candidates = [ROOT / ".env"]
    try:
        for d in [ROOT.parent, ROOT.parent.parent, ROOT.parent.parent.parent,
                  ROOT.parent.parent.parent.parent]:
            if (d / ".env").exists():
                candidates.append(d / ".env")
                break
    except Exception:
        pass
    for env_path in candidates:
        if not env_path.exists():
            continue
        for line in env_path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            os.environ.setdefault(k, v)


def _build_deepseek_env(deepseek_key: str) -> dict[str, str]:
    """Env vars per DeepSeek docs (no proxy — direct /anthropic).

    CC 2.1.108's model validator hits `GET /v1/models/<name>`; DeepSeek's
    /anthropic endpoint returns 200 there, so no proxy is needed."""
    return {
        "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
        "ANTHROPIC_AUTH_TOKEN": deepseek_key,
        "ANTHROPIC_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
        "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
        "CLAUDE_CODE_EFFORT_LEVEL": "max",
    }


# ──────────────────────────────────────────────────────────────────────────────
# Candidate loading + naming
# ──────────────────────────────────────────────────────────────────────────────

def load_step1_metadata() -> dict:
    """sid -> {repo, stars} lookup from step1_all_sessions.json (best-effort).

    step1 stores the repo as `project` ("owner/name") and stars under
    `_swechat_stars`. Falls back to first entry of `github_repos` if `project`
    is missing."""
    if not SC_STEP1.exists():
        return {}
    out = {}
    for r in json.load(open(SC_STEP1)):
        sid = r.get("session_id")
        if not sid:
            continue
        repo = r.get("project")
        if not repo:
            gh = r.get("github_repos") or []
            repo = gh[0] if gh else None
        out[sid] = {"stars": r.get("_swechat_stars", 0), "repo": repo}
    return out


def load_screening_candidates() -> list:
    """Load VIABLE candidates from step2_candidates.json + enrich with stars."""
    if not SC_CANDIDATES.exists():
        print(f"ERROR: {SC_CANDIDATES} not found — run screening step1+step2 first")
        return []
    candidates = json.load(open(SC_CANDIDATES))
    candidates = [c for c in candidates if c.get("verdict") == "VIABLE"]
    meta = load_step1_metadata()
    for c in candidates:
        sid = c["session_id"]
        c["_repo"] = c.get("repo") or "unknown"
        c["_summary"] = c.get("reason", "") or c.get("primary_deliverable", "")
        c["_confidence"] = "Pro" if c.get("verdict") == "VIABLE" else "?"
        c["_is_modifying"] = c.get("primary_deliverable") == "code_changes"
        c["_stars"] = meta.get(sid, {}).get("stars") or 0
    candidates.sort(key=lambda c: c.get("_stars", 0), reverse=True)
    return candidates


def synth_candidate(sid: str) -> dict:
    """Build a minimal candidate record for an explicitly-named session_id.

    Pulls repo/stars from step1 metadata if available; otherwise leaves them
    blank and the worker discovers the repo from the transcript itself."""
    meta = load_step1_metadata().get(sid, {})
    return {
        "session_id": sid,
        "_repo": meta.get("repo") or "unknown",
        "_summary": "(direct session_id — no screening summary)",
        "_confidence": "direct",
        "_is_modifying": True,
        "_stars": meta.get("stars") or 0,
    }


def jsonl_to_dataclaw_session(jsonl_path: Path, sid: str) -> dict:
    """Convert a SWE-chat Claude-Code transcript JSONL into the DataClaw schema
    the inline pipeline prompt expects.

    Used by step3_prefetch_viable.py via re-import; kept here so the scaffold
    package is the single source of truth for the conversion shape."""
    messages = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rtype = rec.get("type")
            msg = rec.get("message") or {}
            content = msg.get("content", "")
            ts = rec.get("timestamp", "")
            if rtype == "user":
                messages.append({"role": "user", "content": content,
                                 "timestamp": ts, "tool_uses": []})
            elif rtype == "assistant":
                tool_uses = []
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_uses.append({"tool": block.get("name", ""),
                                              "input": block.get("input", {})})
                messages.append({"role": "assistant", "content": content,
                                 "tool_uses": tool_uses, "timestamp": ts})
    return {"session_id": sid, "messages": messages}


def check_cached_sessions(candidates: list) -> tuple[list, list]:
    """Partition candidates into (cached, missing) by checking sessions_raw/<sid>.json.

    This script does NOT fetch from HF — it only reads the local cache populated
    by `data-pipeline/screening/scripts/step3_prefetch_viable.py`. This guarantees
    no concurrent HF/parquet IO when N workers run in parallel (the OOM path)."""
    cached, missing = [], []
    for c in candidates:
        if (SC_SESSIONS_DIR / f"{c['session_id']}.json").exists():
            cached.append(c)
        else:
            missing.append(c)
    return cached, missing


def generate_task_name(candidate: dict) -> str:
    repo = candidate.get("_repo") or "unknown/unknown"
    summary = candidate.get("_summary") or ""
    sid = candidate["session_id"]
    repo_short = re.sub(r"[^a-z0-9]", "-", repo.split("/")[-1].lower()).strip("-")[:25]
    summary_lower = summary.lower()
    action = "task"
    for kw in ["fix", "add", "implement", "refactor", "update", "migrate", "convert",
               "integrate", "optimize", "debug", "resolve", "patch", "support"]:
        if kw in summary_lower:
            action = kw
            break
    name = f"{repo_short}-{action}-{sid[:6]}"
    return re.sub(r"-+", "-", name).strip("-")


def get_existing_tasks() -> set:
    if not HARBOR_TASKS_DIR.exists():
        return set()
    return {d.name for d in HARBOR_TASKS_DIR.iterdir()
            if d.is_dir() and d.name != "README.md"}


def get_processed_session_ids() -> set:
    processed = set()
    if LOG_DIR.exists():
        for f in LOG_DIR.glob("*.json"):
            if f.name.startswith("summary"):
                continue
            try:
                log = json.load(open(f))
                if log.get("status") in ("success", "success_no_pr", "not_viable"):
                    processed.add(log.get("session_id", ""))
            except Exception:
                pass
    return processed


# ──────────────────────────────────────────────────────────────────────────────
# Scaffold prompt
# ──────────────────────────────────────────────────────────────────────────────

def build_prompt(candidate: dict, task_name: str) -> str:
    sid = candidate["session_id"]
    repo = candidate.get("_repo", "unknown")
    stars = candidate.get("_stars", 0)
    summary = candidate.get("_summary", "")
    is_modifying = candidate.get("_is_modifying", True)
    confidence = candidate.get("_confidence", "?")
    session_rel = (SC_SESSIONS_DIR / f"{sid}.json").relative_to(ROOT)

    return f"""You are converting a SWE-chat (SALT-NLP) coding session into a Harbor benchmark task.

## Session Info
- Session ID: {sid}
- Session file: {session_rel}
- GitHub repo: {repo} ({stars} stars)
- Task summary: {summary}
- Screening confidence: {confidence}, modifying code: {is_modifying}
- Target task name: {task_name}
- Target directory: harbor_tasks/{task_name}/

## Pipeline Steps (execute in order, stop on failure)

### Step 1: Screen the session
Read `{session_rel}` and check these 7 hard requirements:
1. Public GitHub repo with 20+ stars (repo: {repo}, {stars} stars)
2. User is modifying code IN the repo (not just pip install or import)
3. CPU-reproducible in Docker (no GPU unless strictly required — CUDA kernels, Triton ops, model inference needing GPU memory)
4. No private data, API keys, or credentials needed
5. No live PR/issue writes as primary deliverable
6. 3+ genuine user messages (skip auto-generated: <task-, [Request interrupted, "This session is being continued")
7. Has code modifications (Write/Edit/apply_patch tools used on repo files)

Extract Write/Edit file paths to verify the user is working ON the repo, not just referencing it.
If NOT VIABLE: print "NOT VIABLE: <reason>" and stop. Do not create any files.

### Step 2: Scaffold the task
Create `harbor_tasks/{task_name}/` with:

a) `original_session.json` — copy from {session_rel}

b) `instruction.md` — first user message that implies code modification, verbatim. Skip auto-generated messages AND pure analysis questions ("what is X?", "how does this work?"). Pick the first turn where the user wants something CHANGED. Use it verbatim — do NOT edit, expand, or collapse multiple turns. Natural vagueness is intentional difficulty.

c) `task.toml`:
```toml
version = "1.0"
[metadata]
author_name = "Alex Li"
author_email = "alex@example.com"
difficulty = "medium"
category = "bugfix"
tags = ["{repo.split('/')[-1].lower()}", ...]
expert_time_estimate_min = 10.0
junior_time_estimate_min = 45.0
[verifier]
timeout_sec = 120.0
[agent]
timeout_sec = 3600.0
[environment]
build_timeout_sec = 600.0
allow_internet = true
cpus = 1
memory = "4G"
storage = "10G"
```
NOTE: `allow_internet` MUST live under `[environment]`, not `[agent]` (Harbor silently ignores misplaced flags).

d) `environment/Dockerfile`:
- Read the session to find the base commit (look for git clone, git checkout, git log in tool uses)
- Clone the repo at that exact commit
- For CPU tasks (default): use `ubuntu:24.04`, install `git curl ca-certificates python3 python3-pip python3-venv build-essential tmux asciinema`
- For GPU tasks (only when strictly required): use `FROM pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime` and `RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED`
- Install project dependencies (CPU-only PyTorch: `torch==2.6.0+cpu --index-url https://download.pytorch.org/whl/cpu`)
- Set PYTHONPATH, configure git, `mkdir -p /workspace /logs/verifier`
- WORKDIR to the repo directory
- If the Dockerfile ends with `USER agent`, FIRST add `RUN mkdir -p /installed-agent && chown agent:agent /installed-agent` so Harbor can install claude-code at runtime.

### Step 3: Discover CI/CD test commands
Inspect `.github/workflows/` in the cloned repo (or fetch from GitHub) to extract the canonical test/build commands. Look for:
- Cargo (`cargo test`, `cargo check`) — Rust
- Pytest (`pytest`, `python -m pytest`) — Python
- Vitest / Jest (`npm test`, `npm run test:unit`, `vitest run`) — TS/JS
- Go (`go test ./...`) — Go
- Make (`make test`, `make check`) — generic

Record what you found at the top of `tests/test.sh` as a comment so future maintainers know the upstream CI source. If the repo has no CI workflows, fall back to language defaults and note it.

### Step 4: Extract user_simulation_prompt.md
Create `harbor_tasks/{task_name}/user_simulation_prompt.md` — the user simulator prompt.

Key principle: describe user BEHAVIOR (what they did), not CHARACTER (what they felt).

Required sections:
1. Simulator Calibration (first): total user messages, longest silence, communication pattern, target message count
2. User Turns: for each genuine user message: Turn N (after X agent turns), Context, Said (first 300 chars), Why
3. Overview table (metadata)

Design rules:
- instruction.md = first user turn verbatim
- Default is SILENCE — don't encourage intervention
- WRONG: "Patience: ~4 min" → RIGHT: "User silently cancelled after ~4 min of no output"

### Step 5: Write tests
Create `harbor_tasks/{task_name}/tests/test.sh` and `tests/test_manifest.yaml` — gaming-resistant verification.

Rules:
- >=60% behavioral (Gold/Silver), <=40% structural (Bronze)
- Core bug = hard behavioral test worth >=0.15
- Use AST nodes, never string/regex on source code
- Anti-stub: reject `def f(): pass` (body depth > 3 meaningful statements)
- set +e, accumulate reward, write to /logs/verifier/reward.txt
- F2P gates with weights summing to ≤1.0; P2P_REGRESSION gates are gating-only (zero on fail), no positive weight
- Use the **weighted-replace** reward formula (NEVER additive — that hits the R001 lint and silently inflates):
  ```python
  if p2p_failed or not f2p_any_pass:
      reward = 0.0
  else:
      inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))
      reward = existing * inner_weight
      for gid, w in WEIGHTS.items():
          if verdicts.get(gid):
              reward += float(w)
  ```
- chmod +x

### Step 6: Self-audit with lint_tests.py
Run from the repo root:
```
python3 scripts/lint_tests.py --task {task_name} --fail-on HIGH
```
Must exit 0. Common HIGH findings:
- R001 additive formula → switch to weighted-replace
- R002 `trap … EXIT` → drop the trap (it clobbers later reward writes)
- R004 WEIGHTS sum out of `(0, 1.0]`
- R006 single F2P gate with weight > 0.50 (split into ≥3 gates)

If lint fails HIGH, fix and re-run before proceeding.

### Step 7: Validate instruction ↔ test alignment
Apply the logic of `/validate-task` inline:
1. Does instruction.md imply code modification? If it's a pure question, find a different turn from the session that asks for changes. NEVER collapse multiple turns into a spec.
2. Is the test reachable from the instruction? Test SHOULD cover more than the instruction asks (intentional difficulty). Flag if it requires external knowledge (GitHub issues, URLs with allow_internet=false).
3. Environment issues: Windows paths in a Linux container? Fix paths only — do not expand instruction scope.

### Step 8: Build and verify Docker image
Run: `docker build -t harbor-{task_name} harbor_tasks/{task_name}/environment/`
This MUST succeed. Common issues: wrong repo URL or commit hash (verify with `git ls-remote`), missing deps, wrong Python version.
After build: `docker run --rm harbor-{task_name} python3 -c "import sys; print(sys.version)"`

### Step 9: Write README.md
```markdown
# Task: {task_name}

| Field | Value |
|-------|-------|
| Source session | `{sid}` |
| Repo | {repo} ({stars} stars) |
| Base commit | `<hash>` |
| Difficulty | medium/hard |
| Category | bugfix/feature/refactor |
| Real user msgs | N |

## User Simulator Behavior
- Total real user messages: N in M turns. Silence is the default.
- Longest silence: X agent turns
- Turn-by-turn summary
```

### Step 10: Commit and create PR
1. git add harbor_tasks/{task_name}/
2. git commit -m "Add task: {task_name}"
3. git push origin HEAD
4. gh pr create --title "Add task: {task_name}" --body "$(cat harbor_tasks/{task_name}/README.md)"

## Reference
Look at existing tasks in harbor_tasks/ (e.g., comfyui-fp8-newbie, mlx-lm-mambacache) for examples.

## Important
- Do NOT create empty/stub files. Every file must have real content.
- If you cannot determine the base commit from the session, mark as NOT VIABLE.
- If the session is about a private repo or needs credentials, mark as NOT VIABLE.
"""


# ──────────────────────────────────────────────────────────────────────────────
# E2B per-task runner
# ──────────────────────────────────────────────────────────────────────────────

async def _run_one(
    candidate: dict,
    task_name: str,
    deepseek_key: str,
    sem: asyncio.Semaphore,
    budget: float,
    template: str | None,
) -> dict:
    sid = candidate["session_id"]
    log_file = LOG_DIR / f"{task_name}.json"
    started = datetime.now()
    result = {
        "session_id": sid,
        "task_name": task_name,
        "repo": candidate.get("_repo", "?"),
        "stars": candidate.get("_stars", 0),
        "status": "pending",
        "started_at": started.isoformat(),
    }
    ts = lambda: datetime.now().strftime("%H:%M:%S")
    cc_prebaked = bool(template and template.startswith(PREBAKED_TEMPLATE_PREFIX))

    async with sem:
        try:
            from e2b import AsyncSandbox
        except ImportError:
            result["status"] = "error"
            result["error"] = "e2b SDK not installed (pip install e2b)"
            return result

        sbx = None
        try:
            print(f"  [{ts()}] LAUNCH {task_name} (session {sid[:8]}…)")
            create_kwargs: dict = {"timeout": SANDBOX_TIMEOUT}
            if template:
                create_kwargs["template"] = template
            sbx = await AsyncSandbox.create(**create_kwargs)
            result["sandbox_id"] = sbx.sandbox_id

            # Skip npm install when the template has claude-code pre-baked.
            if cc_prebaked:
                print(f"  [{ts()}] (claude-code pre-baked in template, skipping install)")
            else:
                print(f"  [{ts()}] INSTALL claude-code@{CC_VERSION} for {task_name}")
                r = await sbx.commands.run(
                    f"npm install -g @anthropic-ai/claude-code@{CC_VERSION}",
                    timeout=INSTALL_TIMEOUT,
                )
                if r.exit_code != 0:
                    result["status"] = "install_failed"
                    result["error"] = ((r.stderr or "") + "\n" + (r.stdout or ""))[-800:]
                    print(f"  [{ts()}] INSTALL FAILED for {task_name}: exit={r.exit_code}")
                    return result

            session_json = (SC_SESSIONS_DIR / f"{sid}.json").read_bytes()
            base_prompt = build_prompt(candidate, task_name)
            scaffold_prompt = base_prompt + (
                "\n\n## E2B SANDBOX OVERRIDES (ignore the corresponding steps above)\n"
                "- **Skip Step 8 (Docker build).** This sandbox has no Docker daemon. "
                "Just write a syntactically valid Dockerfile; verification happens after harvest.\n"
                "- **Skip Step 10 (git push + gh pr create).** No git remote or GH auth here. "
                "The harness tars `harbor_tasks/{task_name}/` and ships it back to the host. "
                "After Step 9, exit with success — do NOT attempt to push or create a PR.\n"
            ).format(task_name=task_name)

            # Use ~/work as the repo root — /workspace isn't writable by the default
            # E2B sandbox user. Mirror the local pipeline's expected layout so the
            # session file lives at the relative path the prompt references.
            workdir = "/home/user/work"
            session_rel = f"data-pipeline/screening/artifacts_swechat/sessions_raw/{sid}.json"
            r = await sbx.commands.run(
                f"mkdir -p {workdir}/{Path(session_rel).parent} {workdir}/scripts {workdir}/harbor_tasks"
            )
            if r.exit_code != 0:
                result["status"] = "setup_failed"
                result["error"] = (r.stderr or r.stdout)[:500]
                return result
            await sbx.files.write(f"{workdir}/{session_rel}", session_json)
            await sbx.files.write(f"{workdir}/scripts/lint_tests.py", LINT_TESTS_PATH.read_bytes())
            await sbx.files.write(f"{workdir}/_scaffold_prompt.txt", scaffold_prompt.encode())

            await sbx.commands.run(
                f'cd {workdir} && git init -q && git config user.email scaffold@togetherbench.dev && '
                f'git config user.name "Scaffold Bot" && git add -A && git commit -q -m "seed: pre-scaffold" || true'
            )

            print(f"  [{ts()}] SCAFFOLD {task_name} (claude -p deepseek-v4-pro)")
            env = _build_deepseek_env(deepseek_key)
            cmd = (
                f"cd {workdir} && cat _scaffold_prompt.txt | "
                f"claude -p --dangerously-skip-permissions --max-budget-usd {budget}"
            )
            r = await sbx.commands.run(cmd, envs=env, timeout=SCAFFOLD_TIMEOUT)
            result["scaffold_exit_code"] = r.exit_code
            result["scaffold_stdout_tail"] = r.stdout[-2000:] if r.stdout else ""
            result["scaffold_stderr_tail"] = r.stderr[-500:] if r.stderr else ""

            if "NOT VIABLE" in (r.stdout or ""):
                result["status"] = "not_viable"
                for line in (r.stdout or "").splitlines():
                    if "NOT VIABLE" in line:
                        result["reason"] = line.strip()[:200]
                        break
                print(f"  [{ts()}] SKIP {task_name}: {result.get('reason', '?')[:80]}")
                return result

            if "Exceeded USD budget" in (r.stdout or "") or "Exceeded USD budget" in (r.stderr or ""):
                result["status"] = "budget_exceeded"
                print(f"  [{ts()}] BUDGET {task_name}")
                return result

            print(f"  [{ts()}] HARVEST {task_name}")
            tar_path = f"{workdir}/_out.tar"
            r = await sbx.commands.run(
                f"cd {workdir} && [ -d harbor_tasks/{task_name} ] && "
                f"tar -cf {tar_path} harbor_tasks/{task_name} && stat -c %s {tar_path} || echo MISSING",
                timeout=HARVEST_TIMEOUT,
            )
            if "MISSING" in (r.stdout or ""):
                result["status"] = "no_output"
                print(f"  [{ts()}] NOOUT {task_name} (no harbor_tasks/{task_name}/)")
                return result

            tar_bytes = await sbx.files.read(tar_path, format="bytes")
            result["tar_bytes"] = len(tar_bytes)

            with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tf:
                tf.extractall(ROOT, filter="data")
            local_dir = HARBOR_TASKS_DIR / task_name
            n_files = sum(1 for _ in local_dir.rglob("*") if _.is_file()) if local_dir.exists() else 0
            result["files_landed"] = n_files

            if r.exit_code == 0 and n_files > 0:
                result["status"] = "success"
                print(f"  [{ts()}] OK {task_name} ({n_files} files, {len(tar_bytes)//1024} KB)")
            else:
                result["status"] = "error"
                result["error"] = f"exit={r.exit_code}, files={n_files}"
                print(f"  [{ts()}] FAIL {task_name}: {result['error']}")

        except asyncio.TimeoutError:
            result["status"] = "timeout"
            result["error"] = f"Exceeded {SCAFFOLD_TIMEOUT}s"
            print(f"  [{ts()}] TIMEOUT {task_name}")
        except Exception as e:
            result["status"] = "error"
            result["error"] = f"{type(e).__name__}: {str(e)[:400]}"
            print(f"  [{ts()}] ERROR {task_name}: {result['error']}")
        finally:
            if sbx is not None:
                try:
                    await sbx.kill()
                except Exception:
                    pass
            result["finished_at"] = datetime.now().isoformat()
            result["elapsed_sec"] = (datetime.now() - started).total_seconds()
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            json.dump(result, open(log_file, "w"), indent=2)

        return result


# ──────────────────────────────────────────────────────────────────────────────
# CLI / orchestrator
# ──────────────────────────────────────────────────────────────────────────────

async def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--session-ids", help="Comma-separated SWE-chat session_ids")
    src.add_argument("--from-screening", action="store_true",
                     help="Load VIABLE candidates from step2_candidates.json (sorted by stars)")
    p.add_argument("--limit", type=int, default=0, help="Cap candidates (0=all)")
    p.add_argument("--offset", type=int, default=0,
                   help="Skip first N (with --from-screening)")
    p.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                   help="Concurrent E2B sandboxes")
    p.add_argument("--budget", type=float, default=DEFAULT_BUDGET,
                   help="USD budget per task (claude -p)")
    p.add_argument("--dry-run", action="store_true",
                   help="Show plan without launching sandboxes")
    p.add_argument("--resume", action="store_true",
                   help="Skip already-processed sessions")
    p.add_argument("--from-cached-only", action="store_true",
                   help="Drop candidates whose session JSON isn't in sessions_raw/ instead of aborting")
    p.add_argument("--one-per-repo", action="store_true",
                   help="Keep only the highest-starred VIABLE session per repo (max diversity)")
    p.add_argument("--template", default=None,
                   help="E2B template alias (default: E2B base; use a 'harbor-scaffold-*' "
                        "alias built by build_template.py to skip the per-sandbox npm install)")
    args = p.parse_args()

    _load_env_from_dotenv()

    deepseek_key = os.environ.get("DEEPSEEK_API_KEY")
    e2b_key = os.environ.get("E2B_API_KEY") or os.environ.get("e2b_api_key")
    if not args.dry_run:
        if not deepseek_key:
            print("ERROR: DEEPSEEK_API_KEY missing (.env or env). Get one at https://platform.deepseek.com/api_keys")
            return 2
        if not e2b_key:
            print("ERROR: E2B_API_KEY missing (.env or env). Get one at https://e2b.dev/dashboard")
            return 2
        os.environ["E2B_API_KEY"] = e2b_key

    if args.session_ids:
        sids = [s.strip() for s in args.session_ids.split(",") if s.strip()]
        candidates = [synth_candidate(sid) for sid in sids]
        print(f"Direct mode: {len(candidates)} session_ids")
    else:
        candidates = load_screening_candidates()
        if not candidates:
            return 2
        print(f"Loaded {len(candidates)} VIABLE candidates from screening (sorted by stars)")

    if args.one_per_repo:
        seen_repos: set[str] = set()
        deduped = []
        for c in candidates:
            r = c.get("_repo") or "unknown"
            if r in seen_repos:
                continue
            seen_repos.add(r)
            deduped.append(c)
        print(f"--one-per-repo: kept {len(deduped)} of {len(candidates)} (one session per repo)")
        candidates = deduped

    work_items = []
    seen = set()
    for c in candidates:
        name = generate_task_name(c)
        if name in seen:
            name = f"{name}-{c['session_id'][6:10]}"
        seen.add(name)
        work_items.append((c, name))

    if args.offset:
        work_items = work_items[args.offset:]
    if args.resume:
        processed = get_processed_session_ids()
        existing = get_existing_tasks()
        before = len(work_items)
        work_items = [(c, n) for c, n in work_items
                      if c["session_id"] not in processed and n not in existing]
        print(f"Resume: skipped {before - len(work_items)} already-processed")
    if args.limit:
        work_items = work_items[: args.limit]

    cached, missing = check_cached_sessions([c for c, _ in work_items])
    if missing:
        if args.from_cached_only:
            mset = {c["session_id"] for c in missing}
            work_items = [(c, n) for c, n in work_items if c["session_id"] not in mset]
            print(f"--from-cached-only: dropped {len(missing)} uncached")
        else:
            print(f"\nERROR: {len(missing)} candidates not cached at "
                  f"{SC_SESSIONS_DIR.relative_to(ROOT)}.")
            print("Run: python data-pipeline/screening/scripts/step3_prefetch_viable.py")
            return 2
    if not work_items:
        print("Nothing to scaffold.")
        return 0

    template_label = args.template or "(E2B default)"
    print(f"Will scaffold {len(work_items)} tasks with {args.workers} concurrent sandboxes")
    print(f"Template: {template_label}, budget/task: ${args.budget}, "
          f"sandbox timeout: {SANDBOX_TIMEOUT//60} min, scaffold timeout: {SCAFFOLD_TIMEOUT//60} min")

    if args.dry_run:
        print(f"\n{'#':>4} {'Task Name':<45} {'Repo':<35} {'Stars':>6}")
        print("-" * 95)
        for i, (c, name) in enumerate(work_items[:50]):
            print(f"{i+1:>4} {name:<45} {c.get('_repo', '?'):<35} {c.get('_stars', 0):>6}")
        if len(work_items) > 50:
            print(f"  ... and {len(work_items) - 50} more")
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(args.workers)
    start = time.time()
    print(f"\n{'='*60}")
    print(f"Starting E2B scaffold at {datetime.now().strftime('%H:%M:%S')}")
    print(f"{'='*60}\n")

    coros = [_run_one(c, name, deepseek_key, sem, args.budget, args.template)
             for c, name in work_items]
    results = await asyncio.gather(*coros, return_exceptions=False)

    elapsed = time.time() - start
    statuses: dict[str, int] = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1

    print(f"\n{'='*60}")
    print(f"Done in {elapsed/60:.1f} min")
    print(f"{'='*60}")
    for s, n in sorted(statuses.items()):
        print(f"  {s:20s}: {n}")

    successes = [r for r in results if r["status"] == "success"]
    if successes:
        print("\nSuccessful tasks:")
        for r in successes:
            print(f"  {r['task_name']}  ({r.get('files_landed', '?')} files, "
                  f"{r.get('elapsed_sec', 0):.0f}s)")

    summary = LOG_DIR / "summary.json"
    json.dump({
        "timestamp": datetime.now().isoformat(),
        "total": len(results),
        "statuses": statuses,
        "elapsed_sec": elapsed,
        "workers": args.workers,
        "template": args.template,
        "budget_per_task": args.budget,
        "results": results,
    }, open(summary, "w"), indent=2)
    print(f"\nSummary: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
