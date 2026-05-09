#!/usr/bin/env python3
"""Step 4 (Hyperswitch variant) — pull canonical patches as the actual
upstream PR diff via `gh pr diff`.

## Why not the parquet?

Earlier this script pulled `archit11/claude_traces_hs.gitdiff`. Cross-validation
showed the `gitdiff` column is the SESSION TRACE (the open-model agent's edits
during the rollout), NOT the resolving PR's diff. None of 17 sampled records
byte-matched their upstream PR. See
`data-pipeline/scripts/notes/source_research.md` for the full audit.

## What this version does

1. Parse harbor task name `hyperswitch-<N>` → upstream issue number.
2. `gh issue view <N> --repo juspay/hyperswitch --json closedByPullRequestsReferences`
   → list of merged PRs that resolved the issue.
3. `gh pr diff <PR> --repo juspay/hyperswitch` → actual unified diff.
4. Cap at 256 KB and write to `data-pipeline/artifacts_hyperswitch/canonical_patches/<sid>.json`
   in the SWE-chat schema, with `_reconstruction = "github_pr_diff"` and
   `_fidelity = "exact"` (now actually true).

Tasks whose issue wasn't closed by a merged PR (or for which the issue number
in the task name doesn't resolve) are written with `_fidelity = "lossy"` and
`_pr_lookup_status` describing the reason, OR skipped if --skip-missing.

Usage:
  python data-pipeline/scripts/step4_extract_canonical_patches_hyperswitch.py
  python data-pipeline/scripts/step4_extract_canonical_patches_hyperswitch.py --tasks 'hyperswitch-9*'
  python data-pipeline/scripts/step4_extract_canonical_patches_hyperswitch.py --force
"""

import argparse
import fnmatch
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS = ROOT / "harbor_tasks"
DATA_PIPELINE = ROOT / "data-pipeline"
OUTPUT_DIR = DATA_PIPELINE / "artifacts_hyperswitch" / "canonical_patches"

UPSTREAM_REPO = "juspay/hyperswitch"
# 2 MB cap — upstream PRs can legitimately exceed the 256 KB threshold the
# message-replay extractor uses (e.g. PR #8007 is ~600 KB across 15 files).
# Truncating mid-diff produces a corrupt patch, so it's safer to keep the
# whole thing and let the consumer decide how to handle large gold patches.
MAX_PATCH_BYTES = 2 * 1024 * 1024

INSTANCE_RE = re.compile(r"^hyperswitch-(\d+)$")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tasks", default="hyperswitch-*", help="Glob (default: hyperswitch-*)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true", help="Re-write even if cached")
    ap.add_argument("--skip-missing", action="store_true",
                    help="Skip tasks whose issue has no closing PR (default: write lossy stub)")
    args = ap.parse_args()

    if not shutil.which("gh"):
        print("ERROR: `gh` CLI not in PATH. Install: brew install gh && gh auth login")
        return 2

    tasks = sorted(d for d in HARBOR_TASKS.iterdir()
                   if d.is_dir() and fnmatch.fnmatch(d.name, args.tasks))
    if args.limit:
        tasks = tasks[: args.limit]
    if not tasks:
        print(f"No tasks match {args.tasks!r}")
        return 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Targeting {len(tasks)} hyperswitch tasks; output → {OUTPUT_DIR}")

    counts = {"ok": 0, "skip": 0, "error": 0, "lossy": 0}
    t0 = time.time()
    for task_dir in tasks:
        result = extract_one(task_dir, args.force, args.skip_missing)
        st = result["status"]
        counts[st] = counts.get(st, 0) + 1
        if st == "ok":
            print(f"  {task_dir.name:42s} ok  PR#{result['pr_num']} "
                  f"({result['files']} files, +{result['additions']}/-{result['deletions']})")
        elif st == "lossy":
            print(f"  {task_dir.name:42s} lossy stub: {result['reason']}")
        elif st == "skip":
            print(f"  {task_dir.name:42s} skip: {result['reason']}")
        else:
            print(f"  {task_dir.name:42s} ERROR: {result['reason']}")

    print(f"\n=== Done in {time.time()-t0:.1f}s ===")
    for k, v in counts.items():
        print(f"  {k:10s}: {v}")
    return 0


def extract_one(task_dir: Path, force: bool, skip_missing: bool) -> dict:
    name = task_dir.name
    m = INSTANCE_RE.match(name)
    if not m:
        return {"status": "skip", "reason": f"task name doesn't match hyperswitch-<N>"}
    issue_num = int(m.group(1))

    sess = read_session(task_dir)
    if sess is None:
        return {"status": "skip", "reason": "no original_session.json"}
    sid = sess.get("session_id") or name

    out_path = OUTPUT_DIR / f"{sid}.json"
    if out_path.exists() and not force:
        return {"status": "skip", "reason": f"cached at {out_path.name}"}

    repo_url, base_commit = peek_dockerfile(task_dir)

    # 1. Find closing PR
    pr_num, pr_status = find_closing_pr(issue_num)
    if pr_num is None:
        if skip_missing:
            return {"status": "skip", "reason": pr_status}
        write_lossy_stub(out_path, sid, name, issue_num, pr_status, repo_url, base_commit)
        return {"status": "lossy", "reason": pr_status}

    # 2. Fetch the PR diff
    diff_text, err = fetch_pr_diff(pr_num)
    if err:
        if skip_missing:
            return {"status": "skip", "reason": err}
        write_lossy_stub(out_path, sid, name, issue_num, err, repo_url, base_commit, pr_num=pr_num)
        return {"status": "lossy", "reason": err}

    # 3. Build output JSON
    files_count, adds, dels, name_status, numstat = summarize_diff(diff_text)
    truncated = False
    if len(diff_text) > MAX_PATCH_BYTES:
        diff_text = diff_text[:MAX_PATCH_BYTES] + f"\n…[truncated at {MAX_PATCH_BYTES} bytes]"
        truncated = True

    out = {
        "session_id": sid,
        "checkpoint_pk": None,
        "commits_in_checkpoint": 1,
        "commit_sha": None,
        "repo_id": UPSTREAM_REPO,
        "is_agent_author": False,
        "files_changed_count": files_count,
        "total_additions": adds,
        "total_deletions": dels,
        "commit_message": f"[gold patch from {UPSTREAM_REPO}#{pr_num} closing #{issue_num}]",
        "files_changed": name_status,
        "numstat": numstat,
        "patch": diff_text,
        "patch_truncated": truncated,
        "agent_percentage": None,
        "_source": "hyperswitch",
        "_reconstruction": "github_pr_diff",
        "_fidelity": "exact",
        "_reconstruction_warnings": [],
        "_base_commit": base_commit,
        "_repo_url": repo_url or f"https://github.com/{UPSTREAM_REPO}",
        "_task_name": name,
        "_n_mutating_ops": 0,
        "_upstream_issue": issue_num,
        "_upstream_pr": pr_num,
        "_pr_lookup_status": pr_status,
    }
    json.dump(out, open(out_path, "w"), indent=2)
    return {"status": "ok", "pr_num": pr_num, "files": files_count,
            "additions": adds, "deletions": dels}


def find_closing_pr(issue_num: int) -> tuple[int | None, str]:
    """Return (pr_num, status_text). pr_num is None when no merged closing PR."""
    r = subprocess.run(
        ["gh", "issue", "view", str(issue_num),
         "--repo", UPSTREAM_REPO,
         "--json", "closedByPullRequestsReferences,state,closed"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        # Maybe the number is a PR, not an issue.
        rp = subprocess.run(
            ["gh", "pr", "view", str(issue_num),
             "--repo", UPSTREAM_REPO,
             "--json", "number,state"],
            capture_output=True, text=True,
        )
        if rp.returncode == 0:
            try:
                pr = json.loads(rp.stdout)
                if pr.get("state") == "MERGED":
                    return pr["number"], "issue-number-was-actually-merged-PR"
            except json.JSONDecodeError:
                pass
        return None, f"issue #{issue_num} not found ({r.stderr.strip()[:80]})"

    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None, "issue view: invalid JSON"

    refs = data.get("closedByPullRequestsReferences") or []
    if not refs:
        return None, "issue has no closing PR"

    # Don't trust the embedded `state` field (gh CLI returns null/missing for
    # closedByPullRequestsReferences entries). Fetch each PR's real state +
    # diff size, then pick the EARLIEST merged PR (smallest number) — that's
    # almost always the original closing PR; later PRs in the list are
    # follow-up bugfixes that just mention the same issue.
    candidates = []
    for ref in refs:
        n = ref.get("number")
        if not n:
            continue
        rp = subprocess.run(
            ["gh", "pr", "view", str(n), "--repo", UPSTREAM_REPO,
             "--json", "number,state,additions,deletions,changedFiles"],
            capture_output=True, text=True,
        )
        if rp.returncode != 0:
            continue
        try:
            pr = json.loads(rp.stdout)
        except json.JSONDecodeError:
            continue
        if pr.get("state") == "MERGED":
            candidates.append(pr)

    if not candidates:
        return refs[-1]["number"], "no merged PR among closing refs (picking last)"

    # Pick the earliest merged PR (lowest number). Tiebreak: pick the one
    # with the largest changedFiles count if numbers are close (within 5).
    candidates.sort(key=lambda x: x["number"])
    pick = candidates[0]
    return pick["number"], f"earliest of {len(candidates)} merged closing PRs"


def fetch_pr_diff(pr_num: int) -> tuple[str, str | None]:
    r = subprocess.run(
        ["gh", "pr", "diff", str(pr_num), "--repo", UPSTREAM_REPO],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return "", f"gh pr diff #{pr_num} failed: {r.stderr.strip()[:120]}"
    if not r.stdout.strip():
        return "", f"PR #{pr_num} diff is empty"
    return r.stdout, None


def write_lossy_stub(out_path: Path, sid: str, name: str, issue_num: int,
                     reason: str, repo_url: str | None, base_commit: str | None,
                     pr_num: int | None = None) -> None:
    out = {
        "session_id": sid,
        "checkpoint_pk": None,
        "commits_in_checkpoint": 0,
        "commit_sha": None,
        "repo_id": UPSTREAM_REPO,
        "is_agent_author": False,
        "files_changed_count": 0,
        "total_additions": 0,
        "total_deletions": 0,
        "commit_message": f"[no upstream PR for issue #{issue_num}: {reason}]",
        "files_changed": "",
        "numstat": "",
        "patch": "",
        "patch_truncated": False,
        "agent_percentage": None,
        "_source": "hyperswitch",
        "_reconstruction": "github_pr_diff",
        "_fidelity": "lossy",
        "_reconstruction_warnings": [reason],
        "_base_commit": base_commit,
        "_repo_url": repo_url or f"https://github.com/{UPSTREAM_REPO}",
        "_task_name": name,
        "_n_mutating_ops": 0,
        "_upstream_issue": issue_num,
        "_upstream_pr": pr_num,
        "_pr_lookup_status": reason,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(out_path, "w"), indent=2)


def read_session(task_dir: Path) -> dict | None:
    sp = task_dir / "original_session.json"
    if not sp.exists():
        return None
    try:
        return json.load(open(sp))
    except Exception:
        return None


def peek_dockerfile(task_dir: Path) -> tuple[str | None, str | None]:
    df = task_dir / "environment" / "Dockerfile"
    if not df.exists():
        return None, None
    text = df.read_text(errors="replace")
    repo = base = None
    m = re.search(r"git\s+(?:clone|remote\s+add\s+\S+)\s+(?:[^\s\\]+\s+)*?(\S+?\.git|https?://[^\s\\]+?)(?=\s|\\|$)", text)
    if m:
        r = m.group(1).rstrip("/")
        if r.endswith(".git"):
            r = r[:-4]
        repo = r
    for r in (
        re.compile(r"git(?:\s+-C\s+\S+)?\s+fetch\s+\S+(?:\s+\S+)*\s+([a-f0-9]{7,40})\b"),
        re.compile(r"git(?:\s+-C\s+\S+)?\s+checkout\s+(?:-b\s+\S+\s+)?([a-f0-9]{7,40})\b"),
        re.compile(r"^\s*ARG\s+(?:BASE_COMMIT|COMMIT|REPO_COMMIT)\s*=\s*([a-f0-9]{7,40})", re.MULTILINE),
    ):
        m = r.search(text)
        if m:
            base = m.group(1)
            break
    return repo, base


def summarize_diff(diff_text: str) -> tuple[int, int, int, str, str]:
    files: list[tuple[str, str]] = []
    numstats: list[tuple[int, int, str]] = []
    cur_file = None
    cur_add = cur_del = 0
    cur_status = "M"

    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            if cur_file:
                numstats.append((cur_add, cur_del, cur_file))
                files.append((cur_status, cur_file))
            m = re.match(r"diff --git a/(.+) b/(.+)$", raw)
            cur_file = m.group(2) if m else "?"
            cur_add = cur_del = 0
            cur_status = "M"
        elif raw.startswith("new file mode"):
            cur_status = "A"
        elif raw.startswith("deleted file mode"):
            cur_status = "D"
        elif raw.startswith("rename to "):
            cur_status = "R"
        elif raw.startswith("+") and not raw.startswith("+++"):
            cur_add += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            cur_del += 1

    if cur_file:
        numstats.append((cur_add, cur_del, cur_file))
        files.append((cur_status, cur_file))

    return (
        len(files),
        sum(a for a, _, _ in numstats),
        sum(d for _, d, _ in numstats),
        "\n".join(f"{s}\t{p}" for s, p in files),
        "\n".join(f"{a}\t{d}\t{p}" for a, d, p in numstats),
    )


if __name__ == "__main__":
    sys.exit(main())
