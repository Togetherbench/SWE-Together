#!/usr/bin/env python3
"""Single-stage SWE-chat → Harbor task scaffolder.

Reads pre-fetched session JSONs from sessions_raw/ (populated by
step3_prefetch_viable.py) and hands each to a `claude -p` worker (one git
worktree each) running the inline scaffolding pipeline (screen → scaffold →
user-sim → tests → docker → README → PR).

This script does NOT touch HF or parquet at run time — that's step3's job. Run
step3 first if any candidates are uncached.

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
  python data-pipeline/scaffold/run_pipeline.py --from-screening --limit 10 --workers 4
  python data-pipeline/scaffold/run_pipeline.py --from-screening --from-cached-only --workers 4
"""

import argparse
import asyncio
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS_DIR = ROOT / "harbor_tasks"

SCREENING_DIR = ROOT / "data-pipeline" / "screening" / "artifacts_swechat"
SC_CANDIDATES = SCREENING_DIR / "step2_candidates.json"
SC_STEP1 = SCREENING_DIR / "step1_all_sessions.json"
SC_SESSIONS_DIR = SCREENING_DIR / "sessions_raw"

SCAFFOLD_DIR = ROOT / "data-pipeline" / "scaffold"
LOG_DIR = SCAFFOLD_DIR / "logs"

SWECHAT_HF_REPO = "SALT-NLP/SWE-chat"

MAX_WORKERS = 4
MAX_BUDGET_PER_TASK = 5.0
TASK_TIMEOUT = 1800


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
    the inline pipeline prompt expects."""
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
                messages.append({"role": "user", "content": content, "timestamp": ts, "tool_uses": []})
            elif rtype == "assistant":
                tool_uses = []
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            tool_uses.append({"tool": block.get("name", ""), "input": block.get("input", {})})
                messages.append({
                    "role": "assistant", "content": content,
                    "tool_uses": tool_uses, "timestamp": ts,
                })
    return {"session_id": sid, "messages": messages}


def check_cached_sessions(candidates: list) -> tuple[list, list]:
    """Partition candidates into (cached, missing) by checking sessions_raw/<sid>.json.

    This script does NOT fetch from HF — it only reads the local cache populated
    by `data-pipeline/screening/scripts/step3_prefetch_viable.py`. This guarantees
    no concurrent HF/parquet IO when N workers run in parallel (the OOM path)."""
    cached = []
    missing = []
    for c in candidates:
        if (SC_SESSIONS_DIR / f"{c['session_id']}.json").exists():
            cached.append(c)
        else:
            missing.append(c)
    return cached, missing


def generate_task_name(candidate: dict) -> str:
    repo = candidate.get("_repo", "unknown/unknown") or "unknown/unknown"
    summary = candidate.get("_summary", "") or ""
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
    return {d.name for d in HARBOR_TASKS_DIR.iterdir() if d.is_dir() and d.name != "README.md"}


def get_processed_session_ids() -> set:
    processed = set()
    if LOG_DIR.exists():
        for f in LOG_DIR.glob("*.json"):
            if f.name == "summary.json":
                continue
            try:
                log = json.load(open(f))
                if log.get("status") in ("success", "success_no_pr", "not_viable"):
                    processed.add(log.get("session_id", ""))
            except Exception:
                pass
    return processed


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

### Step 3: Discover CI/CD test commands (NEW)
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


async def run_one(candidate: dict, task_name: str, sem: asyncio.Semaphore, budget: float) -> dict:
    sid = candidate["session_id"]
    log_file = LOG_DIR / f"{task_name}.json"
    result = {
        "session_id": sid,
        "task_name": task_name,
        "repo": candidate.get("_repo", "?"),
        "stars": candidate.get("_stars", 0),
        "status": "pending",
        "started_at": datetime.now().isoformat(),
    }

    async with sem:
        prompt = build_prompt(candidate, task_name)
        ts = lambda: datetime.now().strftime("%H:%M:%S")
        print(f"  [{ts()}] START {task_name} (session {sid[:8]}…)")

        try:
            proc = await asyncio.create_subprocess_exec(
                "claude", "-p",
                "--worktree", task_name,
                "--dangerously-skip-permissions",
                "--effort", "high",
                "--max-budget-usd", str(budget),
                "--model", "sonnet",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            try:
                stdout, stderr = await asyncio.wait_for(
                    proc.communicate(prompt.encode()),
                    timeout=TASK_TIMEOUT,
                )
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                result["status"] = "timeout"
                result["error"] = f"Exceeded {TASK_TIMEOUT}s timeout"
                print(f"  [{ts()}] TIMEOUT {task_name}")
                json.dump(result, open(log_file, "w"), indent=2)
                return result

            stdout_text = stdout.decode("utf-8", errors="replace")
            stderr_text = stderr.decode("utf-8", errors="replace")

            result["exit_code"] = proc.returncode
            result["stdout_tail"] = stdout_text[-2000:]
            result["stderr_tail"] = stderr_text[-500:] if stderr_text else ""

            if "NOT VIABLE" in stdout_text:
                result["status"] = "not_viable"
                for line in stdout_text.split("\n"):
                    if "NOT VIABLE" in line:
                        result["reason"] = line.strip()[:200]
                        break
                print(f"  [{ts()}] SKIP {task_name}: {result.get('reason', '?')[:80]}")
            elif "Exceeded USD budget" in stdout_text or "Exceeded USD budget" in stderr_text:
                result["status"] = "budget_exceeded"
                print(f"  [{ts()}] BUDGET {task_name}")
            elif proc.returncode == 0:
                if "github.com" in stdout_text and "/pull/" in stdout_text:
                    result["status"] = "success"
                    for line in stdout_text.split("\n"):
                        if "github.com" in line and "/pull/" in line:
                            result["pr_url"] = line.strip()
                            break
                    print(f"  [{ts()}] OK {task_name} → {result.get('pr_url', 'PR created')}")
                elif (HARBOR_TASKS_DIR / task_name).exists():
                    result["status"] = "success_no_pr"
                    print(f"  [{ts()}] OK {task_name} (task created, PR may need manual push)")
                else:
                    result["status"] = "unknown"
                    print(f"  [{ts()}] ??? {task_name} (exit 0 but no task dir)")
            else:
                result["status"] = "error"
                result["error"] = stderr_text[:500] or stdout_text[-500:]
                print(f"  [{ts()}] FAIL {task_name} (exit {proc.returncode})")

        except Exception as e:
            result["status"] = "error"
            result["error"] = str(e)[:500]
            print(f"  [{ts()}] ERROR {task_name}: {e}")

        result["finished_at"] = datetime.now().isoformat()
        json.dump(result, open(log_file, "w"), indent=2)

        if result["status"] in ("not_viable", "timeout", "error", "budget_exceeded"):
            wt_path = ROOT / ".claude" / "worktrees" / task_name
            if wt_path.exists():
                try:
                    cleanup = await asyncio.create_subprocess_exec(
                        "git", "worktree", "remove", str(wt_path), "--force",
                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                    )
                    await cleanup.wait()
                except Exception:
                    pass

        return result


async def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--session-ids", help="Comma-separated SWE-chat session_ids")
    src.add_argument("--from-screening", action="store_true",
                     help="Load VIABLE candidates from step2_candidates.json")
    p.add_argument("--limit", type=int, default=0, help="Cap candidates (0=all)")
    p.add_argument("--offset", type=int, default=0, help="Skip first N (only with --from-screening)")
    p.add_argument("--workers", type=int, default=MAX_WORKERS, help="Parallel claude -p workers")
    p.add_argument("--budget", type=float, default=MAX_BUDGET_PER_TASK, help="USD budget per task")
    p.add_argument("--dry-run", action="store_true", help="Show plan without invoking claude")
    p.add_argument("--resume", action="store_true", help="Skip already-processed sessions")
    p.add_argument("--from-cached-only", action="store_true",
                   help="Drop candidates whose session JSON isn't in sessions_raw/. "
                        "Default behavior: abort if any candidate is missing (forcing you to "
                        "run step3_prefetch_viable.py first).")
    args = p.parse_args()

    if args.session_ids:
        sids = [s.strip() for s in args.session_ids.split(",") if s.strip()]
        candidates = [synth_candidate(sid) for sid in sids]
        print(f"Direct mode: {len(candidates)} session_ids")
    else:
        candidates = load_screening_candidates()
        if not candidates:
            return
        print(f"Loaded {len(candidates)} VIABLE candidates from screening (sorted by stars)")

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
        print(f"Skipped first {args.offset}")

    if args.resume:
        processed = get_processed_session_ids()
        existing = get_existing_tasks()
        before = len(work_items)
        work_items = [(c, n) for c, n in work_items
                      if c["session_id"] not in processed and n not in existing]
        print(f"Resume: skipped {before - len(work_items)} already-processed")

    if args.limit:
        work_items = work_items[: args.limit]

    print(f"Will process {len(work_items)} candidates with {args.workers} workers")

    if args.dry_run:
        print(f"\n{'#':>4} {'Task Name':<45} {'Repo':<35} {'Stars':>6}")
        print("-" * 95)
        for i, (c, name) in enumerate(work_items[:50]):
            print(f"{i+1:>4} {name:<45} {c.get('_repo', '?'):<35} {c.get('_stars', 0):>6}")
        if len(work_items) > 50:
            print(f"  ... and {len(work_items) - 50} more")
        return

    cached, missing = check_cached_sessions([c for c, _ in work_items])
    if missing:
        if args.from_cached_only:
            missing_sids = {c["session_id"] for c in missing}
            work_items = [(c, n) for c, n in work_items if c["session_id"] not in missing_sids]
            print(f"--from-cached-only: dropped {len(missing)} uncached, {len(work_items)} remaining")
        else:
            print(f"\nERROR: {len(missing)} of {len(missing) + len(cached)} candidates are not in")
            print(f"  {SC_SESSIONS_DIR.relative_to(ROOT)}")
            print(f"\nRun this once first (serial, ~5–15 min for 329 sessions):")
            print(f"  python data-pipeline/screening/scripts/step3_prefetch_viable.py")
            print(f"\nOr pass --from-cached-only to scaffold only what's already cached.")
            print(f"\nFirst few missing: {[c['session_id'][:8] + '…' for c in missing[:5]]}")
            return
    if not work_items:
        print("Nothing to scaffold (all candidates dropped).")
        return

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(args.workers)
    start = time.time()

    print(f"\n{'='*60}")
    print(f"Starting scaffold pipeline at {datetime.now().strftime('%H:%M:%S')}")
    print(f"Workers: {args.workers} | Budget/task: ${args.budget}")
    print(f"{'='*60}\n")

    tasks = [run_one(c, name, sem, args.budget) for c, name in work_items]
    results = await asyncio.gather(*tasks)

    elapsed = time.time() - start
    statuses = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1

    print(f"\n{'='*60}")
    print(f"Pipeline complete in {elapsed/60:.1f} minutes")
    print(f"{'='*60}")
    for status, count in sorted(statuses.items()):
        print(f"  {status}: {count}")

    successes = [r for r in results if r["status"].startswith("success")]
    if successes:
        print("\nSuccessful tasks:")
        for r in successes:
            print(f"  {r['task_name']} → {r.get('pr_url', 'created')}")

    summary_path = LOG_DIR / "summary.json"
    json.dump({
        "timestamp": datetime.now().isoformat(),
        "total": len(results),
        "statuses": statuses,
        "elapsed_sec": elapsed,
        "results": results,
    }, open(summary_path, "w"), indent=2)
    print(f"\nFull results: {summary_path}")


if __name__ == "__main__":
    asyncio.run(main())
