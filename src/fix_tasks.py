#!/usr/bin/env python3
"""Fix benchmark tasks using Opus 4.6 as boss/audit agent inside E2B sandboxes.

Opus runs inside E2B with Docker access. It:
1. Reads the audit report, fixes task files (test.sh, Dockerfile, instruction, etc.)
2. Builds the task Docker image, runs nop test, checks reward
3. If anything fails, iterates (up to 3 rounds)
4. Optionally runs GLM 4.7 / Kimi K2.5 as test agents, compares their work

Usage:
    # Fix CRITICAL tasks (no agent testing)
    python src/fix_tasks.py --severity critical --workers 6

    # Fix specific tasks with agent testing
    python src/fix_tasks.py --tasks llama-cpp-lora-moe-rank1 --test-agents

    # Fix all non-LOW tasks
    python src/fix_tasks.py --workers 8

    # Dry run
    python src/fix_tasks.py --severity critical --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from e2b import AsyncSandbox, AsyncTemplate, Template
from e2b.sandbox.commands.command_handle import CommandExitException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("fix_tasks")


class _RateLimited(Exception):
    """Raised when an agent hits LLM rate limit — triggers retry at batch level."""
    pass


# Patterns that indicate a rate limit from the Anthropic API (or proxies).
# claude -p may embed these in stdout/stderr even on exit 0.
_RATE_LIMIT_PATTERNS = [
    "429",
    "rate limit",
    "rate_limit",
    "overloaded",
    "hit your limit",
    "too many requests",
    "resource_exhausted",
    "throttled",
]

# Patterns that indicate a transient sandbox/network error worth retrying.
_RETRIABLE_PATTERNS = [
    "peer closed connection",
    "connection reset by peer",
    "sandbox was closed",
    "sandbox timed out",
    "econnreset",
    "socket hang up",
]


def _looks_rate_limited(text: str) -> bool:
    """Return True if *text* contains any rate-limit indicator."""
    low = text.lower()
    return any(p in low for p in _RATE_LIMIT_PATTERNS)


def _looks_retriable(text: str) -> bool:
    """Return True if *text* looks like a transient sandbox/network failure."""
    low = text.lower()
    return any(p in low for p in _RETRIABLE_PATTERNS)

# Suppress noisy E2B/httpx logs
logging.getLogger("e2b").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)

REPO_ROOT = Path(__file__).resolve().parent.parent
TASKS_DIR = REPO_ROOT / "harbor_tasks"
REPORTS_DIR = REPO_ROOT / "debug_benchmark0408"
TEMPLATE_ALIAS = "harbor-worker-v2"

# Load .env
_env_path = REPO_ROOT / ".env"
if _env_path.exists():
    for line in _env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

@dataclass
class FixResult:
    task: str
    severity: str = ""
    status: str = ""          # ok, error, skipped
    fix_time: float = 0.0
    nop_reward: float = -1.0
    docker_build: bool = False
    agent_test_glm: float = -1.0
    agent_test_kimi: float = -1.0
    files_changed: list[str] = field(default_factory=list)
    error: str = ""
    sandbox_id: str = ""


# ---------------------------------------------------------------------------
# Sandbox helpers
# ---------------------------------------------------------------------------

SANDBOX_DEATH_PHRASES = [
    "peer closed",
    "sandbox was closed",
    "sandbox timed out",
    "sandbox not found",
    "timed out",
    "connection reset",
    "connection closed",
    "broken pipe",
    "econnreset",
    "socket hang up",
]


def _is_sandbox_dead(err_str: str) -> bool:
    """Check if an error indicates the sandbox has been killed or timed out."""
    lower = err_str.lower()
    return any(phrase in lower for phrase in SANDBOX_DEATH_PHRASES)


async def run_cmd(
    sandbox: AsyncSandbox, cmd: str, timeout: int = 0, user: str = "root"
) -> tuple[int, str, str]:
    """Run a command in the sandbox. Returns (exit_code, stdout, stderr).
    timeout=0 disables the command timeout (wait until sandbox lifetime expires)."""
    try:
        result = await sandbox.commands.run(cmd, timeout=timeout, user=user)
        return result.exit_code, result.stdout or "", result.stderr or ""
    except CommandExitException as e:
        return e.exit_code, e.stdout or "", e.stderr or ""
    except Exception as e:
        err_str = str(e)
        if _is_sandbox_dead(err_str):
            log.error("Sandbox appears dead: %s", err_str[:200])
        return -1, "", err_str


async def refresh_sandbox_timeout(sandbox: AsyncSandbox, timeout: int = 3600) -> None:
    """Refresh sandbox lifetime to prevent premature death during long operations.
    E2B set_timeout resets the countdown from NOW, not from creation time."""
    try:
        await sandbox.set_timeout(timeout)
    except Exception as e:
        log.warning("Failed to refresh sandbox timeout: %s", e)


async def ensure_template() -> str:
    try:
        exists = await AsyncTemplate.alias_exists(TEMPLATE_ALIAS)
    except Exception:
        exists = False
    if exists:
        return TEMPLATE_ALIAS
    raise RuntimeError(f"Template '{TEMPLATE_ALIAS}' not found.")


async def create_sandbox(
    timeout: int = 14400,
    test_agents: bool = False,
) -> AsyncSandbox:
    """Create sandbox with API keys for Opus + optional agent testing models."""
    envs = {
        "ANTHROPIC_API_KEY": os.environ.get("ANTHROPIC_API_KEY", ""),
        "ANTHROPIC_AUTH_TOKEN": os.environ.get("ANTHROPIC_API_KEY", ""),
    }
    # For agent testing + sim-fire validation: inject all model-proxy keys.
    # Harbor's run_eval.py uses MiniMax agent + Gemini user-sim; the boss prompt
    # also exercises Sonnet/Haiku. All models route through these keys.
    if test_agents or os.environ.get("_FIX_INJECT_MODEL_KEYS"):
        envs.update({
            "GLM_API_KEY": os.environ.get("GLM_API_KEY", ""),
            "OPENROUTER_API_KEY": os.environ.get("OPENROUTER_API_KEY", ""),
            "FIREWORKS_API_KEY": os.environ.get("FIREWORKS_API_KEY", ""),
            "GEMINI_API_KEY": os.environ.get("GEMINI_API_KEY", ""),
            "MINIMAX_API_KEY": os.environ.get("MINIMAX_API_KEY", ""),
            "GOOGLE_API_KEY": os.environ.get("GOOGLE_API_KEY", ""),
        })

    for attempt in range(6):
        try:
            sandbox = await AsyncSandbox.create(
                template=TEMPLATE_ALIAS,
                timeout=timeout,
                envs=envs,
                metadata={"owner": "fix_tasks", "pid": str(os.getpid())},
            )
            break
        except Exception as e:
            err_str = str(e).lower()
            if "429" in err_str or "rate limit" in err_str or "hit your limit" in err_str:
                wait = 30 * (attempt + 1)
                log.warning("E2B sandbox rate limited (attempt %d), waiting %ds", attempt + 1, wait)
                await asyncio.sleep(wait)
            else:
                raise
    else:
        raise RuntimeError("Failed to create sandbox after 6 rate-limit retries")

    # Explicitly extend sandbox lifetime (belt + suspenders with create timeout).
    # E2B set_timeout resets the countdown from NOW. Without this, the sandbox
    # may die earlier than expected if the create timeout wasn't fully applied.
    await refresh_sandbox_timeout(sandbox, timeout)

    # Wait for Docker daemon
    for _ in range(10):
        code, _, _ = await run_cmd(sandbox, "docker info", timeout=10)
        if code == 0:
            break
        await asyncio.sleep(2)

    await run_cmd(sandbox, "chown -R worker:worker /workspace /logs/verifier", timeout=10)
    await run_cmd(sandbox, "usermod -aG docker worker 2>/dev/null || true", timeout=5)

    return sandbox


def _is_backup_or_junk(rel: Path) -> bool:
    """Return True if a relative path looks like a backup, cache, or temp file."""
    name = rel.name
    name_lower = name.lower()
    # Junk suffixes
    if name_lower.endswith((".old", ".bak", ".orig", ".pyc")):
        return True
    # Backup-style substrings in filename
    if any(tag in name_lower for tag in ("_old", "_orig", "_bak", "_backup")):
        return True
    # fix_summary variants (fix_summary_old.md, fix_summary.md.old, etc.)
    # Keep the canonical fix_summary.md but skip any variant
    if name_lower.startswith("fix_summary") and name != "fix_summary.md":
        return True
    # Junk directory components anywhere in the path
    junk_dirs = {"__pycache__", ".mypy_cache", ".pytest_cache", "node_modules"}
    if junk_dirs & set(p.lower() for p in rel.parts):
        return True
    return False


# Only download these core task files back to the local tree
_DOWNLOAD_ALLOWLIST = {
    "tests/test.sh",
    "environment/Dockerfile",
    "instruction.md",
    "user_simulation_prompt.md",
    "task.toml",
    "fix_summary.md",
}


async def upload_task_files(sandbox: AsyncSandbox, task_path: Path) -> None:
    for f in task_path.rglob("*"):
        if not f.is_file():
            continue
        rel = f.relative_to(task_path)
        if _is_backup_or_junk(rel):
            log.debug("Skipping upload of backup/junk: %s", rel)
            continue
        remote = f"/workspace/task/{rel}"
        await sandbox.files.write(remote, f.read_bytes())
    await run_cmd(sandbox, "chmod +x /workspace/task/tests/test.sh 2>/dev/null || true")


async def download_changed_files(
    sandbox: AsyncSandbox, dest: Path
) -> list[str]:
    """Download only allowlisted task files that were actually modified."""
    changed = []
    for rel in sorted(_DOWNLOAD_ALLOWLIST):
        remote_path = f"/workspace/task/{rel}"
        local_path = dest / rel
        try:
            content = await sandbox.files.read(remote_path, format="bytes")
        except Exception:
            # File doesn't exist in sandbox (e.g. fix_summary.md on first run)
            continue
        local_path.parent.mkdir(parents=True, exist_ok=True)
        if local_path.exists() and local_path.read_bytes() == content:
            continue
        local_path.write_bytes(content)
        changed.append(rel)

    return changed


# ---------------------------------------------------------------------------
# Outer-repo tarball (for sim-fire validation — Harbor runner needs repo on disk)
# ---------------------------------------------------------------------------

REPO_TARBALL_PATH = Path("/tmp/multi_user_turn_codebench_repo.tar.gz")


def build_repo_tarball(force: bool = False) -> Path:
    """Build a gzipped tarball of the outer repo for sandbox upload.

    Excludes .git, trials-*, pipeline_logs, session_collection (large + irrelevant).
    Includes harbor_tasks, src, scripts, external/harbor, pyproject.toml, uv.lock, .env.
    """
    import subprocess
    if not force and REPO_TARBALL_PATH.exists():
        # Reuse if <30 min old (pipeline launches a batch — tarball fresh enough)
        age = time.time() - REPO_TARBALL_PATH.stat().st_mtime
        if age < 1800:
            log.info("Reusing repo tarball at %s (%d KB, age %.0fs)",
                     REPO_TARBALL_PATH, REPO_TARBALL_PATH.stat().st_size // 1024, age)
            return REPO_TARBALL_PATH
    log.info("Building repo tarball at %s", REPO_TARBALL_PATH)
    # .env must exist — Harbor runner inside sandbox needs model keys
    env_file = REPO_ROOT / ".env"
    includes = [
        "pyproject.toml", "uv.lock", "harbor_tasks", "src", "scripts",
        "external/harbor",
    ]
    if env_file.exists():
        includes.append(".env")
    subprocess.run([
        "tar", "czf", str(REPO_TARBALL_PATH),
        "--exclude=.venv*", "--exclude=.git", "--exclude=trials-*",
        "--exclude=trials", "--exclude=pipeline_logs",
        "--exclude=session_collection", "--exclude=logs", "--exclude=jobs",
        "--exclude=__pycache__", "--exclude=*.pyc", "--exclude=node_modules",
        "--exclude=original_session.json",  # only needed for tasks being worked on; uploaded via task dir
        *includes,
    ], check=True, cwd=REPO_ROOT)
    log.info("repo tarball built: %d KB", REPO_TARBALL_PATH.stat().st_size // 1024)
    return REPO_TARBALL_PATH


async def upload_repo_tarball(sandbox: AsyncSandbox, tarball_path: Path) -> None:
    """Upload repo tarball and extract to /workspace/repo/. Worker user owns the extraction."""
    data = tarball_path.read_bytes()
    log.info("Uploading repo tarball (%d KB) to sandbox", len(data) // 1024)
    await sandbox.files.write("/workspace/repo.tar.gz", data)
    code, _, err = await run_cmd(
        sandbox,
        "rm -rf /workspace/repo && mkdir -p /workspace/repo && "
        "tar xzf /workspace/repo.tar.gz -C /workspace/repo && "
        "chown -R worker:worker /workspace/repo",
        timeout=180,
    )
    if code != 0:
        raise RuntimeError(f"tarball extract failed: {err[:300]}")


# ---------------------------------------------------------------------------
# Boss agent prompt
# ---------------------------------------------------------------------------

BOSS_PROMPT = """# Benchmark Task Audit & Fix — Boss Agent

You are a senior QA engineer auditing and fixing a benchmark task. You have
full access to Docker inside this sandbox. Your job is to make this task
actually work correctly.

## Task files
All task files are at `/workspace/task/`:
- `tests/test.sh` — verifier script (writes reward to /logs/verifier/reward.txt)
- `environment/Dockerfile` — builds the task Docker image
- `instruction.md` — what the agent reads
- `user_simulation_prompt.md` — user simulator instructions
- `task.toml` — metadata

## Audit report (from prior analysis)
{report}

## Your process — follow these phases IN ORDER

### Phase 1: Fix
Read the audit report and ALL task files carefully. Fix every issue identified:
- Missing dependencies in Dockerfile → add them (CPU-only torch, etc.)
- test.sh bugs → fix NameErrors, regex issues, stdout parsing, scoring math
- venv PATH issues → add `export PATH="/workspace/venv/bin:$PATH"` after `set +e`
- Narrow tests → broaden to accept valid alternative implementations
- Instruction-test contradictions → align them
- User sim issues → fix message caps, remove out-of-scope triggers
- AGENTS.md / CLAUDE.md blocking agents → add `RUN rm -f AGENTS.md CLAUDE.md` to Dockerfile
- Timeout issues → increase in task.toml if needed

### Phase 2: Validate Docker build
```bash
cd /workspace/task/environment && docker build -t task-env .
```
If it fails, diagnose and fix. Iterate until it builds.

### Phase 3: Run nop test
Run test.sh on the unmodified base commit (no fix applied):
```bash
rm -f /logs/verifier/reward.txt
docker run --rm \
  -v /workspace/task/tests:/tests:ro \
  -v /logs/verifier:/logs/verifier \
  task-env bash /tests/test.sh
cat /logs/verifier/reward.txt
```
The nop reward should be LOW (< 0.50). If it's high, your F2P tests aren't
testing the right behavioral change. If reward.txt is missing or empty,
test.sh has a bug. Fix and re-run until nop < 0.50.

### Phase 4: Iterate
If Phase 2 or 3 failed, go back to Phase 1 with the error output. You have
up to 3 full cycles. Each time, read the docker/test output carefully and
make targeted fixes.

{agent_test_section}

## Rules
- Do NOT change the task's fundamental intent
- Behavioral tests (F2P) are primary — keep and fix them
- test.sh MUST write a float to /logs/verifier/reward.txt
- Scoring = PASS/TOTAL, capped at 1.0
- If Dockerfile changes are needed, make them (note: E2B template rebuild needed later)
- Be thorough — read files before editing, verify syntax with `bash -n`

## Final output
After all phases, write a summary to `/workspace/task/fix_summary.md` with:
- What you changed and why
- Docker build: pass/fail
- Nop reward achieved
- Agent test results (if run)
- Any remaining concerns
"""

AGENT_TEST_SECTION = """
### Phase 5: Agent smoke test (SEQUENTIAL — GLM 5.1 then GLM 4.7)

Test the task with two real agents to verify the task is solvable and scores
make sense. Run them SEQUENTIALLY (not parallel) to stay within memory limits.

**API keys are available as environment variables:**
- `$GLM_API_KEY` — for Z.AI (GLM models) via `https://api.z.ai/api/anthropic`
- `$OPENROUTER_API_KEY` — for OpenRouter models

**For each model, follow this exact sequence:**

#### Agent 1: GLM 5.1
```bash
# 1. Start fresh container from the task image
docker rm -f agent-glm51 2>/dev/null || true
docker run -d --name agent-glm51 -v /logs/verifier:/logs/verifier task-env sleep 3600

# 2. Install Claude Code CLI inside the container
docker exec agent-glm51 bash -c "curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null"
docker exec agent-glm51 bash -c 'echo "export PATH=\\$HOME/.local/bin:\\$PATH" >> ~/.bashrc'

# 3. Copy instruction into the container's workspace
docker cp /workspace/task/instruction.md agent-glm51:/workspace/instruction.md

# 4. Run the agent (Claude Code CLI talking to GLM 5.1 via Z.AI proxy)
docker exec -e ANTHROPIC_API_KEY="$GLM_API_KEY" \
  -e ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic" \
  -e PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  agent-glm51 bash -c "cd /workspace && cat instruction.md | claude -p --dangerously-skip-permissions --model glm-5.1 --output-format json 2>/dev/null" \
  > /workspace/agent_glm51_output.json 2>&1

# 5. Run verifier on the agent's work
rm -f /logs/verifier/reward.txt
docker exec agent-glm51 bash -c "mkdir -p /logs/verifier"
docker cp /workspace/task/tests/test.sh agent-glm51:/tests/test.sh
docker exec agent-glm51 bash /tests/test.sh
# Copy reward back
docker cp agent-glm51:/logs/verifier/reward.txt /logs/verifier/reward.txt 2>/dev/null || true
GLM51_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "-1")
echo "GLM 5.1 reward: $GLM51_REWARD"

# 6. Save trace for review
docker exec agent-glm51 bash -c "find /workspace -name '*.py' -newer /workspace/instruction.md -type f" > /workspace/glm51_changed_files.txt 2>/dev/null

# 7. Cleanup
docker rm -f agent-glm51
```

#### Agent 2: GLM 4.7
```bash
# Same flow but with glm-4.7
docker rm -f agent-glm47 2>/dev/null || true
docker run -d --name agent-glm47 -v /logs/verifier:/logs/verifier task-env sleep 3600
docker exec agent-glm47 bash -c "curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null"
docker exec agent-glm47 bash -c 'echo "export PATH=\\$HOME/.local/bin:\\$PATH" >> ~/.bashrc'
docker cp /workspace/task/instruction.md agent-glm47:/workspace/instruction.md

docker exec -e ANTHROPIC_API_KEY="$GLM_API_KEY" \
  -e ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic" \
  -e PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  agent-glm47 bash -c "cd /workspace && cat instruction.md | claude -p --dangerously-skip-permissions --model glm-4.7 --output-format json 2>/dev/null" \
  > /workspace/agent_glm47_output.json 2>&1

rm -f /logs/verifier/reward.txt
docker exec agent-glm47 bash -c "mkdir -p /logs/verifier"
docker cp /workspace/task/tests/test.sh agent-glm47:/tests/test.sh
docker exec agent-glm47 bash /tests/test.sh
docker cp agent-glm47:/logs/verifier/reward.txt /logs/verifier/reward.txt 2>/dev/null || true
GLM47_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "-1")
echo "GLM 4.7 reward: $GLM47_REWARD"

docker exec agent-glm47 bash -c "find /workspace -name '*.py' -newer /workspace/instruction.md -type f" > /workspace/glm47_changed_files.txt 2>/dev/null
docker rm -f agent-glm47
```

#### Analysis
After both agents finish, compare:
- Did both agents get non-zero scores? If both score 0, something is still wrong with the task.
- Is there score discrimination (GLM 5.1 > GLM 4.7, or vice versa)?
- Read the agent output JSONs — did they actually attempt the task or hit errors?
- Read the changed files lists — did they modify the right files?

If both agents fail with errors (not low scores from wrong solutions, but actual crashes/timeouts),
the task environment likely has issues. Diagnose and fix.

Write all findings to `/workspace/task/fix_summary.md` including both reward scores.
"""

NO_AGENT_TEST_SECTION = """
### (Agent testing skipped — use --test-agents to enable)
"""

# ---------------------------------------------------------------------------
# Round 3: F2P/P2P strictness prompt
# ---------------------------------------------------------------------------

F2P_P2P_PROMPT = """# F2P/P2P Test Quality Audit — Round 3

You are auditing the test quality of a benchmark task. The task files are at
`/workspace/task/`. A prior fix pass already addressed major bugs. Now your
job is to ensure **test scoring integrity**.

## Audit report (from prior analysis)
{report}

## Your goals

### Goal 1: F2P tests must score EXACTLY 0 on base commit
Every fail-to-pass (F2P) test should FAIL on the unmodified base commit.
If any F2P test passes on nop, it's not testing a real behavioral change —
it's either vacuously true, testing the wrong thing, or has a bug.

### Goal 2: P2P tests must be real and comprehensive
Pass-to-pass (P2P) tests should verify that upstream functionality works
on the base commit. Check that:
- P2P tests actually run (not skipped due to missing deps)
- P2P tests test real functionality (not just "file exists" or "ast parses")
- If a P2P test always fails (missing dep, wrong import), either fix the
  dep in Dockerfile or remove the test and redistribute its weight
- P2P weight should be ≤ 20% of total (behavioral F2P should dominate)

### Goal 3: Nop score = sum of P2P weights only
After fixing, the nop reward should equal exactly the sum of P2P test weights.
No F2P test should contribute to the nop score.

## Process

1. Read `tests/test.sh` carefully — understand every test, its type (F2P vs P2P),
   and its weight
2. Read `environment/Dockerfile` — check if all P2P deps are installed
3. Build Docker: `cd /workspace/task/environment && docker build -t task-env .`
4. Run nop test:
   ```bash
   rm -f /logs/verifier/reward.txt
   docker run --rm -v /workspace/task/tests:/tests:ro -v /logs/verifier:/logs/verifier task-env bash /tests/test.sh
   cat /logs/verifier/reward.txt
   ```
5. Analyze the output — which tests passed? Which failed? Are F2P tests all failing?
6. Fix any issues found
7. Re-run nop test to verify
8. Iterate until nop = P2P weight sum (typically 0.05-0.15)

## Rules
- Do NOT change the task's intent or make tests easier
- F2P tests should test BEHAVIORAL changes, not structural patterns
- If a test is vacuously true (passes without any agent work), either fix it
  to properly check behavior or remove it
- Keep total weights summing to ~1.0
- Write summary to `/workspace/task/fix_summary.md`

{agent_test_section}
"""


# ---------------------------------------------------------------------------
# Full audit prompt: MERGED pipeline — test hardening + user-sim + rubrics + sim-fire
# ---------------------------------------------------------------------------

FULL_AUDIT_PROMPT = """# Full Task Audit: Unified Test + Sim-Prompt + Rubric Enforcement

You are a senior QA engineer. Task files at `/workspace/task/`. The outer
benchmark repo (harbor + run_eval.py + other tasks) is at `/workspace/repo/`
if the tarball was uploaded. You have Docker-in-docker, API keys for Anthropic,
OpenRouter, Gemini, MiniMax. Sandbox lifetime is 6 hours.

## What this task owns (you edit these)
- `/workspace/task/tests/test.sh` — verifier
- `/workspace/task/environment/Dockerfile` — task env
- `/workspace/task/user_simulation_prompt.md` — multi-turn sim trigger table
- `/workspace/task/task.toml` — metadata (add session_resolution field)
- `/workspace/task/fix_summary.md` — YOUR final report

## What you DO NOT change (read-only source of truth)
- `/workspace/task/instruction.md` — the first user message, kept verbatim per
  `never_change_user_messages` rule. Only edit if the instruction is literally
  broken (e.g. contains `<tool_result>` envelopes, references a dead link).
  If you do edit, document the reason in fix_summary.md.
- `/workspace/task/original_session.json` — the recorded session, evidence source.

## Goal
Produce a benchmark task that:
1. Discriminates Sonnet 4.6 vs Haiku 4.5 with gap ≥ 0.15
2. Passes ALL 7 Tier A rubrics + 4 Tier B rubrics (from audit report below)
3. Has an accurate session_resolution tag and a verbatim user-sim trigger table
4. Survives sim-fire validation (Harbor's real runner fires ≥1 sim turn)

## Audit report (task-specific context + rubrics)
{report}

## THE 9 PHASES — execute in order, budget time per phase

═══════════════════════════════════════════════════════════════════════════
PHASE 0 — Orient (budget: 5 min)
═══════════════════════════════════════════════════════════════════════════

Read these files into your head before doing anything:
```bash
cat /workspace/task/instruction.md
cat /workspace/task/tests/test.sh
cat /workspace/task/environment/Dockerfile
head -200 /workspace/task/user_simulation_prompt.md
cat /workspace/task/task.toml
# Session: only check tail (full file can be huge)
wc -l /workspace/task/original_session.json
python3 -c "
import json
s = json.load(open('/workspace/task/original_session.json'))
msgs = s.get('messages', [])
users = [m for m in msgs if m.get('role')=='user']
print(f'Total messages: {len(msgs)}, user turns: {len(users)}')
for i,m in enumerate(users[:5]):
    c = m.get('content','')
    if isinstance(c, list): c = ' '.join(x.get('text','') for x in c if isinstance(x,dict))
    print(f'  [U{i}] ({m.get(\"timestamp\",\"?\")[:19]}): {str(c)[:150]}')
print('  ...')
if len(users)>5:
    for i,m in enumerate(users[-2:]):
        c = m.get('content','')
        if isinstance(c, list): c = ' '.join(x.get('text','') for x in c if isinstance(x,dict))
        print(f'  [U{len(users)-2+i}] ({m.get(\"timestamp\",\"?\")[:19]}): {str(c)[:150]}')
"
```

═══════════════════════════════════════════════════════════════════════════
PHASE 1 — Session-resolution tag (budget: 5 min)
═══════════════════════════════════════════════════════════════════════════

Classify how the recorded session ENDED (not how the agent performed):
- `resolved` — user acknowledged done or final ask was satisfied
- `cut_off` — conversation truncated mid-work (timeout/context/user disconnect)
- `stuck` — agent was looping or error-bouncing; user gave up
- `ambiguous` — too unclear to classify

Look at:
- Final 3-4 user messages (tone, content)
- Final assistant message (did it announce completion?)
- Any explicit "looks good" / "that works" / "thanks"

Append to `/workspace/task/task.toml` under `[metadata]` (PRESERVE existing fields):
```toml
session_resolution = "resolved"              # one of above
session_resolution_confidence = 0.9          # 0.0-1.0
session_resolution_reasoning = "final user said 'perfect, thanks'"
```

═══════════════════════════════════════════════════════════════════════════
PHASE 2 — User-sim prompt audit + backfill (budget: 15 min)
═══════════════════════════════════════════════════════════════════════════

The user_simulation_prompt.md drives multi-turn evaluation. Each row in the
trigger table must:
- Have a **Message** that is VERBATIM from original_session.json (exact text
  of a real user message, optionally trimmed but never reworded).
- Have a **Condition** that tests observable agent state (file counts, files
  edited, outputs matching patterns) — NOT speculation about intent.
- NOT fabricate user turns that never happened.

### Check current state
```bash
head -200 /workspace/task/user_simulation_prompt.md
```

### Decide:
- If the file has **0 trigger rows** OR contains garbage (tool_result envelopes,
  fabricated messages) → **REBUILD** the trigger table from original_session.json
- If rows exist but some messages look paraphrased/invented → **FIX** those rows
- If rows look correct → **VERIFY** each against session, leave alone if clean

### Rebuilding the trigger table
Extract substantive user messages (skip `<tool_result>` content, skip acks like
"ok", "yes", skip `<task-` auto-envelopes). Generate 1 row per substantive turn
AFTER the first (Turn 1 = instruction.md = implicit first turn, not in table).

Row schema:
```
| ID | Condition | Message | Notes |
| T2 | agent has written tests/test_api.py but has not added edge-case coverage for empty input | "also make sure it handles an empty string — that was the bug we saw in prod" | verbatim from session |
| T3 | agent declared task done after making X change | "looks good but the tests in ci are still red" | verbatim |
```

Preserve the **Simulator Calibration** section at the top (total msgs, session
duration, intervention style).

═══════════════════════════════════════════════════════════════════════════
PHASE 3 — Build Docker + nop baseline (budget: 10 min, Rust up to 30 min)
═══════════════════════════════════════════════════════════════════════════

```bash
cd /workspace/task/environment && docker build -t task-env . 2>&1 | tail -30
```

If build fails → fix Dockerfile (missing deps, wrong base), rebuild.

Nop test (empty agent, just run verifier):
```bash
rm -f /logs/verifier/reward.txt
docker run --rm \
  -v /workspace/task/tests:/tests:ro \
  -v /logs/verifier:/logs/verifier \
  task-env bash /tests/test.sh 2>&1 | tail -40
cat /logs/verifier/reward.txt
```

Target: nop ≤ 0.10 (only P2P regression guards pass on unmodified code).

═══════════════════════════════════════════════════════════════════════════
PHASE 4 — Run Sonnet 4.6 + Haiku 4.5 agents (budget: 30-60 min)
═══════════════════════════════════════════════════════════════════════════

Run each agent in its own fresh container copied from task-env. Use the
following PATTERN for each model:

```bash
# Sonnet (use claude-sonnet-4-6); Haiku (use claude-haiku-4-5-20251001)
MODEL=claude-sonnet-4-6
NAME=agent-sonnet
docker rm -f $NAME 2>/dev/null || true
docker run -d --name $NAME task-env sleep 7200
docker exec $NAME bash -c "curl -fsSL https://claude.ai/install.sh | bash 2>/dev/null"
docker cp /workspace/task/instruction.md $NAME:/workspace/instruction.md
docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  $NAME bash -c 'cd /workspace && cat instruction.md | claude -p --dangerously-skip-permissions --model '"$MODEL"' --output-format json 2>/dev/null' \
  > /workspace/trace_${MODEL}.json 2>&1
docker exec $NAME bash -c "cd /workspace && git diff 2>/dev/null" > /workspace/trace_${MODEL}_diff.txt
docker cp /workspace/task/tests/test.sh $NAME:/tests/test.sh
docker exec $NAME bash -c "mkdir -p /logs/verifier && bash /tests/test.sh" > /workspace/trace_${MODEL}_verifier.txt 2>&1
docker cp $NAME:/logs/verifier/reward.txt /workspace/reward_${MODEL}.txt 2>/dev/null
cat /workspace/reward_${MODEL}.txt
```

On rate limit (429): wait 60s and retry once; then continue with the data
you have.

═══════════════════════════════════════════════════════════════════════════
PHASE 5 — Rubric enforcement (budget: 15 min)
═══════════════════════════════════════════════════════════════════════════

Apply ALL 11 rubrics to `tests/test.sh`. The audit report above names them;
here's the checklist. For each violation, FIX the test.sh (preserving intent):

### Tier A — reward-integrity killers (FIX if violated)
1. **tests_verify_behavior_not_text** — tests INVOKE code (cargo check/test,
   python3 -c, node -e, bun test). Grep-only checks don't count. At least
   50% of reward weight must come from compilation/execution gates.
2. **test_not_tautological** — no gate should pass on a `pass` / empty /
   `return None` stub. Each F2P gate must test REAL behavior.
3. **solution_uniqueness_guard** — accept ANY behaviorally-correct fix,
   not just the gold patch's variable names. Broaden regexes if too narrow.
4. **no_solution_leakage** — instruction.md must not reveal the exact patch.
   If it does (rare, we kept verbatim), note in fix_summary but don't edit.
5. **pass_to_pass_coverage** — include ≥1 P2P test (passes on unmodified
   base AND on correct fix). Guards against regression / delete-to-pass.
6. **behavior_in_task_description** — every literal string/file-path/SHA
   the test asserts must be derivable from instruction.md. If instruction
   names `.onnx` but tests check for `.safetensors`, the tests are wrong.
7. **no_hidden_solution_artifacts** — Dockerfile must NOT `COPY solution/`
   into the image. Test: `docker run --rm task-env find / -name 'solve*'
   -type f 2>/dev/null | head`. Should return nothing task-specific.

### Tier B — important
8. **dockerfile_determinism** — no `:latest` tags. Pin base image + deps.
9. **no_network_during_tests** — test.sh must not `pip/npm/apt install` at
   test time; deps must be baked into image at build time.
10. **pinned_dependencies** — all pip deps version-pinned (`==X.Y.Z`).
11. **f2p_p2p_classification_correct** — test.sh should label which gates
    are F2P vs P2P in comments.

### Hard rules (from prior audits)
- `set +e` (NEVER `set -e` — breaks partial scoring)
- Write reward to `/logs/verifier/reward.txt`
- ≥3 reward gates with partial credit
- Shebang `#!/bin/bash`
- Language-specific execution gates:
  - Rust: `cargo check` or `cargo test` as a gate (≥0.2 weight)
  - TypeScript: `npx tsc --noEmit` or `bun test`
  - Python: `python3 -m pytest` or `python3 -c "import ..."`

═══════════════════════════════════════════════════════════════════════════
PHASE 6 — Iterate until discrimination (budget: 60-90 min, max 4 loops)
═══════════════════════════════════════════════════════════════════════════

```
REPEAT up to 4 times:
  1. Analyze traces from Sonnet + Haiku
  2. Identify WHY scores are same/wrong (see diagnosis below)
  3. Fix tests/Dockerfile
  4. docker build -t task-env .   (rebuild)
  5. Re-run nop (must stay ≤ 0.10)
  6. Re-run Sonnet + Haiku in fresh containers
  7. Compare: is gap ≥ 0.15 AND reflective of real quality?
     → yes: STOP, you're done
     → no: continue
```

### Diagnostic patterns
- BETTER impl scored LOWER → test too narrow, broaden
- WORSE impl scored SAME → test doesn't check enough, add behavioral gates
- Both 0 → task too hard single-turn (needs sim) → note "needs multi-turn"
- Both 1.0 → task too easy → tighten
- Scores differ for WRONG reason (lucky pattern) → fix test

═══════════════════════════════════════════════════════════════════════════
PHASE 7 — Sim-fire validation (budget: 30 min, OPTIONAL if repo not available)
═══════════════════════════════════════════════════════════════════════════

Only run this if `/workspace/repo/` exists AND the outer-repo tarball extracted
successfully. Skip gracefully otherwise.

```bash
if [ -d /workspace/repo/src ] && [ -f /workspace/repo/pyproject.toml ]; then
  TASK_ID=$(basename /workspace/task)
  # Sync current edited task files back into the repo's harbor_tasks/
  mkdir -p /workspace/repo/harbor_tasks/${TASK_ID}
  cp -r /workspace/task/* /workspace/repo/harbor_tasks/${TASK_ID}/

  cd /workspace/repo
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh -s -- -q
  export PATH="/root/.local/bin:$PATH"

  # Persist model keys to .env (run_eval uses dotenv)
  python3 -c "
import os, pathlib
keys = ['ANTHROPIC_API_KEY','OPENROUTER_API_KEY','GEMINI_API_KEY','MINIMAX_API_KEY']
pathlib.Path('.env').write_text('\\n'.join(f'{k}={os.environ.get(k,\"\")}' for k in keys if os.environ.get(k))+'\\n')
"

  uv sync --quiet 2>&1 | tail -5

  TRIAL_DIR=/workspace/trials-${TASK_ID}
  rm -rf "$TRIAL_DIR"; mkdir -p "$TRIAL_DIR"

  set -a; source .env; set +a
  timeout 1500 uv run python src/run_eval.py \
    --model anthropic/claude-sonnet-4-6 \
    --user-model openrouter/google/gemini-3.1-pro-preview \
    --tag "probe-${TASK_ID}" \
    --env-type docker \
    --workers 1 \
    --trials-dir "$TRIAL_DIR" \
    --tasks "$TASK_ID" 2>&1 | tail -40

  uv run python scripts/lint/turn_fire_report.py "$TRIAL_DIR" --json /tmp/tfr.json 2>&1 | tail -5
  cat /tmp/tfr.json
else
  echo "sim-fire SKIPPED — repo tarball not available"
fi
```

If sim-fire shows `sim_turns_fired == 0`, examine trial logs — check whether
the sim CONDITIONS in user_simulation_prompt.md are too restrictive or reference
state the agent never reaches. Edit one obvious condition, re-run once.

═══════════════════════════════════════════════════════════════════════════
PHASE 8 — Final report (budget: 5 min)
═══════════════════════════════════════════════════════════════════════════

Write `/workspace/task/fix_summary.md`:

```markdown
# Fix Summary

## Nop Baseline
- Nop reward: X.XX (target ≤ 0.10)
- P2P-only weight: X%

## Session Resolution (Phase 1)
- Tag: resolved | cut_off | stuck | ambiguous
- Confidence: 0.0-1.0
- Evidence: <final user msg / assistant msg snippet>

## User-Sim Prompt Audit (Phase 2)
- Before: X rows, Y verbatim
- After: X rows, all verbatim
- Rebuilt/fixed/verified: <which>

## Rubric Compliance (Phase 5)
| Rubric | Tier | Status | Notes |
| tests_verify_behavior_not_text | A | PASS | calls python3 -m pytest |
| test_not_tautological | A | PASS/FIX | ... |
... (all 11)

## Agent Discrimination (Phase 4+6)
| Round | Sonnet 4.6 | Haiku 4.5 | Gap |
| 1     | 0.XX       | 0.XX      | 0.XX |
| final | 0.XX       | 0.XX      | 0.XX |

## Sim-Fire Validation (Phase 7)
- Status: PASSED | SKIPPED | FAILED
- sim_turns_fired: N
- Notes: ...

## Confidence
- Overall: HIGH | MEDIUM | LOW
- Remaining concerns: ...
```

Clean up:
```bash
docker rm -f agent-sonnet agent-haiku 2>/dev/null || true
```

═══════════════════════════════════════════════════════════════════════════

## If something goes catastrophically wrong
- Sandbox running out of disk → `docker system prune -af`
- Claude rate limit persists → record the data you have, write fix_summary,
  stop early. Partial progress is still valuable.
- A phase exceeds its budget by 2x → wrap it up and move on.

## What "done" looks like
- nop ≤ 0.10, discrimination gap ≥ 0.15
- fix_summary.md committed to `/workspace/task/fix_summary.md`
- All 11 rubrics addressed (PASS or documented exception)
- session_resolution tag in task.toml
- user_simulation_prompt.md rows all verbatim
"""


# ---------------------------------------------------------------------------
# Per-task fix
# ---------------------------------------------------------------------------

async def fix_one_task(
    task_name: str,
    report_text: str,
    severity: str,
    sem: asyncio.Semaphore,
    test_agents: bool = False,
    prompt_mode: str = "boss",
) -> FixResult:
    result = FixResult(task=task_name, severity=severity)
    task_path = TASKS_DIR / task_name

    if not task_path.exists():
        result.status = "error"
        result.error = f"Task dir not found: {task_path}"
        return result

    async with sem:
        t0 = time.time()
        sandbox = None
        try:
            log.info("[%s] Creating sandbox...", task_name)
            inject_keys = test_agents or prompt_mode == "full_audit"
            if inject_keys:
                os.environ["_FIX_INJECT_MODEL_KEYS"] = "1"
            # Bump to 21600s (6hr) to give Rust + sim-fire room to finish
            sandbox = await create_sandbox(timeout=21600, test_agents=inject_keys)
            result.sandbox_id = sandbox.sandbox_id

            # Upload task files
            log.info("[%s] Uploading task files...", task_name)
            await upload_task_files(sandbox, task_path)

            # Upload outer-repo tarball for sim-fire validation phase.
            # full_audit mode exercises Harbor's run_eval.py inside the sandbox.
            if prompt_mode == "full_audit" and REPO_TARBALL_PATH.exists():
                log.info("[%s] Uploading outer-repo tarball for sim-fire phase...", task_name)
                try:
                    await upload_repo_tarball(sandbox, REPO_TARBALL_PATH)
                except Exception as e:
                    log.warning("[%s] Tarball upload failed (sim-fire will be skipped): %s",
                                task_name, str(e)[:200])

            # Refresh sandbox lifetime before long-running agent
            # E2B set_timeout resets the countdown from NOW. Without this,
            # the sandbox countdown started at creation time keeps ticking
            # during upload, and we lose precious seconds.
            await refresh_sandbox_timeout(sandbox, 21600)

            # Build prompt
            agent_section = AGENT_TEST_SECTION if test_agents else NO_AGENT_TEST_SECTION
            if prompt_mode == "full_audit":
                # Use .replace() instead of .format() because the merged prompt
                # contains bash heredocs with embedded Python f-strings ({expr})
                # that would be misinterpreted as format placeholders.
                prompt = FULL_AUDIT_PROMPT.replace("{report}", report_text)
            elif prompt_mode == "f2p":
                prompt = F2P_P2P_PROMPT.format(
                    report=report_text,
                    agent_test_section=agent_section,
                )
            else:
                prompt = BOSS_PROMPT.format(
                    report=report_text,
                    agent_test_section=agent_section,
                )
            await sandbox.files.write("/workspace/fix_prompt.md", prompt.encode())

            # Run Opus boss agent
            log.info("[%s] Running Opus 4.6 boss agent...", task_name)
            code, stdout, stderr = await run_cmd(
                sandbox,
                "cat /workspace/fix_prompt.md | claude -p "
                "--dangerously-skip-permissions --model claude-opus-4-6 "
                "--output-format json 2>/dev/null",
                timeout=0,  # no command timeout — sandbox lifetime (14400s) is the limit
                user="worker",
            )

            fix_time = time.time() - t0

            combined = stdout + stderr

            # Check for rate limits — even on exit 0 the output may
            # contain 429 messages from internal claude -p retries that
            # eventually gave up.
            if _looks_rate_limited(combined):
                result.status = "rate_limited"
                result.error = "Rate limited"
                log.warning("[%s] Rate limited after %.0fs", task_name, fix_time)
                # Download partial work before raising
                dest = TASKS_DIR / task_name
                result.files_changed = await download_changed_files(sandbox, dest)
                result.fix_time = time.time() - t0
                raise _RateLimited(task_name)

            if code != 0:
                # Check if sandbox died (peer closed, timeout, etc.)
                if code == -1 and _is_sandbox_dead(combined):
                    result.status = "sandbox_died"
                    result.error = f"Sandbox died after {fix_time:.0f}s: {combined[:200]}"
                    log.error("[%s] Sandbox died: %s", task_name, combined[:100])
                    result.fix_time = time.time() - t0
                    # Cannot download files from dead sandbox
                    return result

                # Check for retriable transient errors
                if _looks_retriable(combined):
                    result.status = "error"
                    result.error = f"Retriable: {combined[:200]}"
                    log.warning("[%s] Retriable error after %.0fs: %s", task_name, fix_time, combined[:100])
                    dest = TASKS_DIR / task_name
                    result.files_changed = await download_changed_files(sandbox, dest)
                    result.fix_time = time.time() - t0
                    raise _RateLimited(task_name)  # re-use retry path

                result.status = "error"
                result.error = f"claude -p exit {code}: {combined[:300]}"
                log.error("[%s] Boss agent failed: %s", task_name, result.error[:100])

                # Still try to download whatever was changed
                dest = TASKS_DIR / task_name
                result.files_changed = await download_changed_files(sandbox, dest)
                result.fix_time = time.time() - t0
                return result

            log.info("[%s] Boss agent completed in %.0fs", task_name, fix_time)

            # Refresh sandbox lifetime — agent may have taken hours, and we
            # still need time to read results and download files.
            await refresh_sandbox_timeout(sandbox, 600)

            # Read fix summary if it exists
            try:
                summary = await sandbox.files.read(
                    "/workspace/task/fix_summary.md", format="text"
                )
                log.info("[%s] Fix summary:\n%s", task_name, summary[:500])
            except Exception:
                pass

            # Read final nop reward (Opus should have run it)
            result.nop_reward = -1.0
            try:
                reward_text = await sandbox.files.read(
                    "/logs/verifier/reward.txt", format="text"
                )
                result.nop_reward = float(reward_text.strip())
            except Exception:
                pass

            # Download fixed files
            log.info("[%s] Downloading fixed files...", task_name)
            dest = TASKS_DIR / task_name
            result.files_changed = await download_changed_files(sandbox, dest)

            if result.files_changed:
                result.status = "ok"
                result.docker_build = True  # Opus validated this
                log.info(
                    "[%s] Fixed! %d files changed, nop=%.2f: %s",
                    task_name, len(result.files_changed), result.nop_reward,
                    ", ".join(result.files_changed[:5]),
                )
            else:
                result.status = "no_changes"
                log.info("[%s] No files changed", task_name)

        except _RateLimited:
            # Propagate to the caller so it can re-queue
            result.fix_time = time.time() - t0
            raise

        except Exception as e:
            err_str = str(e)
            # Check if this exception itself indicates a retriable condition
            if _looks_rate_limited(err_str) or _looks_retriable(err_str):
                result.status = "rate_limited" if _looks_rate_limited(err_str) else "error"
                result.error = err_str[:300]
                log.warning("[%s] Retriable exception: %s", task_name, err_str[:100])
                raise _RateLimited(task_name)
            if _is_sandbox_dead(err_str):
                result.status = "sandbox_died"
                result.error = f"Sandbox died: {err_str[:300]}"
                log.error("[%s] Sandbox died (exception): %s", task_name, err_str[:100])
            else:
                result.status = "error"
                result.error = err_str[:300]
                log.error("[%s] Exception: %s", task_name, e)

        finally:
            if sandbox:
                try:
                    await sandbox.kill()
                except Exception:
                    pass

        result.fix_time = time.time() - t0
        return result


# ---------------------------------------------------------------------------
# Report parsing
# ---------------------------------------------------------------------------

def parse_severity(report_text: str) -> str:
    for pattern in [
        r'\*\*Severity:\s*([^*\n]+)',
        r'Severity:\s*\*?\*?([A-Z0-9/_ -]+)',
        r'Severity:\s*([^\n]+)',
    ]:
        m = re.search(pattern, report_text)
        if m:
            raw = m.group(1).strip().upper()
            if "CRITICAL" in raw or "P0" in raw:
                return "critical"
            if "HIGH" in raw:
                return "high"
            if "MEDIUM" in raw:
                return "medium"
            if "LOW" in raw or "OK" in raw:
                return "low"
    if re.search(r'BROKEN|CRITICAL|P0', report_text[:500], re.IGNORECASE):
        return "critical"
    if re.search(r'TOO EASY|ZERO DISCRIM|NEEDS REWORK', report_text[:500], re.IGNORECASE):
        return "high"
    return "unknown"


def load_reports() -> dict[str, tuple[str, str]]:
    reports = {}
    for f in sorted(REPORTS_DIR.glob("*_report.md")):
        task = f.name.replace("_report.md", "")
        text = f.read_text()
        sev = parse_severity(text)
        reports[task] = (sev, text)
    return reports


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main():
    parser = argparse.ArgumentParser(description="Fix benchmark tasks with Opus boss agent in E2B")
    parser.add_argument("--tasks", default=None, help="Comma-separated task names")
    parser.add_argument("--severity", default=None, help="Filter: critical,high,medium,low")
    parser.add_argument("--workers", type=int, default=8, help="Max concurrent sandboxes")
    parser.add_argument("--test-agents", action="store_true",
                        help="Run GLM 4.7 + Kimi K2.5 as test agents after fixing")
    parser.add_argument("--prompt", default="boss", choices=["boss", "f2p", "full_audit"],
                        help="Prompt mode: boss (full fix), f2p (F2P/P2P strictness), full_audit (fix + agent test)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-low", action="store_true", default=True)
    parser.add_argument("--rebuild-tarball", action="store_true",
                        help="Force rebuild the outer-repo tarball (otherwise reuse if <30min old)")
    args = parser.parse_args()

    reports = load_reports()
    log.info("Loaded %d audit reports", len(reports))

    # Filter tasks
    if args.tasks:
        task_names = [t.strip() for t in args.tasks.split(",")]
    else:
        task_names = sorted(reports.keys())

    if args.severity:
        allowed = {s.strip().lower() for s in args.severity.split(",")}
        task_names = [t for t in task_names if reports.get(t, ("unknown", ""))[0] in allowed]

    if args.skip_low:
        task_names = [t for t in task_names if reports.get(t, ("unknown", ""))[0] not in ("low",)]

    # Print plan
    print(f"\n{'='*70}")
    print(f"Benchmark Task Fixer — Opus 4.6 Boss Agent")
    print(f"{'='*70}")
    print(f"Tasks:       {len(task_names)}")
    print(f"Workers:     {args.workers}")
    print(f"Test agents: {args.test_agents}")
    print(f"{'='*70}")

    by_sev = {}
    for t in task_names:
        sev = reports.get(t, ("unknown", ""))[0]
        by_sev.setdefault(sev, []).append(t)
    for sev in ["critical", "high", "medium", "low", "unknown"]:
        if sev in by_sev:
            print(f"\n  {sev.upper()} ({len(by_sev[sev])}):")
            for t in by_sev[sev]:
                print(f"    {t}")
    print(f"\n{'='*70}\n")

    if args.dry_run:
        return

    await ensure_template()

    # Build repo tarball ONCE for the whole batch (shared across workers).
    # Only needed for full_audit mode (sim-fire phase).
    if args.prompt == "full_audit":
        try:
            build_repo_tarball(force=args.rebuild_tarball)
        except Exception as e:
            log.warning("Repo tarball build failed (sim-fire phase will be skipped): %s", e)

    # Kill any stale fix_tasks sandboxes from prior crashed runs.
    # IMPORTANT: only kill sandboxes tagged metadata.owner == "fix_tasks" so
    # we don't destroy other projects' concurrent E2B work on the same API key.
    log.info("Cleaning up stale fix_tasks sandboxes...")
    try:
        p = AsyncSandbox.list()
        all_sbs = []
        while p.has_next:
            items = await p.next_items()
            all_sbs.extend(items)
            if not items:
                break
        owned = [sb for sb in all_sbs
                 if sb.metadata and sb.metadata.get("owner") == "fix_tasks"]
        unowned_count = len(all_sbs) - len(owned)
        if owned:
            log.warning("Found %d stale fix_tasks sandboxes, killing... (%d unowned sandboxes from other projects preserved)",
                        len(owned), unowned_count)
            for sb in owned:
                try:
                    await AsyncSandbox.kill(sb.sandbox_id)
                except Exception:
                    pass
            await asyncio.sleep(5)
            log.info("Stale sandbox cleanup done")
        else:
            log.info("No stale fix_tasks sandboxes found (%d total active, all from other projects)",
                     unowned_count)
    except Exception as e:
        log.warning("Sandbox cleanup failed (non-fatal): %s", e)

    sem = asyncio.Semaphore(args.workers)
    max_retries = 3

    # Queue-based dispatch with retry support
    queue: asyncio.Queue[tuple[str, int]] = asyncio.Queue()
    for task_name in task_names:
        await queue.put((task_name, 0))

    results: list[FixResult] = []
    results_lock = asyncio.Lock()
    total = len(task_names)
    done_count = 0

    async def _worker():
        nonlocal done_count
        while True:
            try:
                task_name, retries = queue.get_nowait()
            except asyncio.QueueEmpty:
                return

            sev, report_text = reports.get(task_name, ("unknown", ""))
            try:
                r = await fix_one_task(
                    task_name=task_name,
                    report_text=report_text,
                    severity=sev,
                    sem=sem,
                    test_agents=args.test_agents,
                    prompt_mode=args.prompt,
                )
                async with results_lock:
                    results.append(r)
                    done_count += 1
                    log.info("Progress: %d/%d done", done_count, total)

            except _RateLimited:
                if retries < max_retries:
                    wait = 60 * (retries + 1)  # 60s, 120s, 180s
                    log.info(
                        "[%s] Rate limited / retriable — re-queuing (retry %d/%d, backoff %ds)",
                        task_name, retries + 1, max_retries, wait,
                    )
                    await asyncio.sleep(wait)
                    await queue.put((task_name, retries + 1))
                else:
                    log.error("[%s] Exhausted %d retries, recording failure", task_name, max_retries)
                    r = FixResult(task=task_name, severity=sev, status="rate_limited",
                                  error=f"Rate limited after {max_retries} retries")
                    async with results_lock:
                        results.append(r)
                        done_count += 1

            except Exception as e:
                log.error("[%s] Unhandled worker error: %s", task_name, e)
                r = FixResult(task=task_name, severity=sev, status="error", error=str(e)[:300])
                async with results_lock:
                    results.append(r)
                    done_count += 1

    start = time.time()

    # Spawn workers — they pull from the shared queue and exit when it's empty.
    # Re-queued items are picked up by whichever worker finishes next.
    workers = [asyncio.create_task(_worker()) for _ in range(min(args.workers, len(task_names)))]
    # Workers exit on QueueEmpty, but re-queued items may arrive after that.
    # Keep cycling until the queue is drained and all workers are idle.
    while done_count < total:
        # Wait for all current workers to finish their current item
        await asyncio.gather(*workers)
        # If items were re-queued, spin up new workers for them
        if not queue.empty():
            pending = queue.qsize()
            workers = [asyncio.create_task(_worker()) for _ in range(min(args.workers, pending))]
        else:
            break

    elapsed = time.time() - start

    # Summary
    ok = [r for r in results if r.status == "ok"]
    no_change = [r for r in results if r.status == "no_changes"]
    failed = [r for r in results if r.status in ("error", "rate_limited", "sandbox_died")]

    print(f"\n{'='*70}")
    print(f"Fix Summary ({elapsed/60:.0f} min)")
    print(f"{'='*70}")
    print(f"  Fixed:        {len(ok)}")
    print(f"  No changes:   {len(no_change)}")
    print(f"  Failed:       {len(failed)}")

    print(f"\n{'Task':<45} {'Sev':>8} {'Status':>12} {'Nop':>6} {'Files':>6} {'Time':>6}")
    print("-" * 88)
    for r in sorted(results, key=lambda x: x.task):
        nop = f"{r.nop_reward:.2f}" if r.nop_reward >= 0 else "-"
        fc = str(len(r.files_changed)) if r.files_changed else "-"
        t = f"{r.fix_time/60:.0f}m"
        print(f"  {r.task:<43} {r.severity:>8} {r.status:>12} {nop:>6} {fc:>6} {t:>6}")
        if r.error:
            print(f"    ERROR: {r.error[:80]}")

    # Save results
    results_path = REPO_ROOT / "pipeline_logs" / "fix-tasks-results.json"
    results_path.parent.mkdir(exist_ok=True)
    results_data = [
        {
            "task": r.task, "severity": r.severity, "status": r.status,
            "fix_time": r.fix_time, "nop_reward": r.nop_reward,
            "docker_build": r.docker_build, "files_changed": r.files_changed,
            "error": r.error,
        }
        for r in results
    ]
    results_path.write_text(json.dumps(results_data, indent=2))
    log.info("Results saved to %s", results_path)


if __name__ == "__main__":
    asyncio.run(main())
