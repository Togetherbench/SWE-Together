#!/usr/bin/env python3
"""Step 6 — augment per-turn ops with cumulative replay patches.

For each harbor task with `per_turn_coding_agent_action.jsonl` (from step5),
clone the upstream repo at base_commit, replay each turn's mutating ops in
order against the work tree, and capture cumulative `git diff HEAD` at every
turn boundary. Diffs are written back into the same JSONL.

Reuses step4 verbatim for Dockerfile parsing, repo cloning, op replay, and
diff capture. The only new piece is `normalize_messages_with_idx`, which
tags each op with its source message index so we can bucket by step5's
existing `msg_range` instead of replaying the whole session in one shot.

Output schema bumps to 1.1. Per-turn additions:
  cumulative_patch, cumulative_files_changed_count, cumulative_additions,
  cumulative_deletions, replay_warnings_this_turn,
  _cumulative_patch_truncated (only when the 256 KB cap kicks in).

Header (denormalized into every row) additions:
  repo_url, base_commit, replay_status ("ok" | "skip:<reason>"),
  total_replay_warnings.

Usage:
  python data-pipeline/scripts/step6_replay_per_turn_patches.py
  python data-pipeline/scripts/step6_replay_per_turn_patches.py --tasks 'cli-task-*'
  python data-pipeline/scripts/step6_replay_per_turn_patches.py --workers 8 --force
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib
import json
import multiprocessing as mp
import sys
import tempfile
import time
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS = ROOT / "harbor_tasks"
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Reuse step4 so the two scripts can never diverge on op semantics.
step4 = importlib.import_module("step4_extract_canonical_patches")
parse_task_dockerfile = step4.parse_task_dockerfile
clone_at_commit = step4.clone_at_commit
replay_ops = step4.replay_ops
capture_diff = step4.capture_diff
INLINE_TOOL_USE_RE = step4.INLINE_TOOL_USE_RE
SED_I_RE = step4.SED_I_RE
ALL_MUTATING = step4.ALL_MUTATING

MAX_PATCH_BYTES = 256 * 1024  # match step4's cap
SCHEMA_VERSION_OUT = "1.1"

SUMMARY_FILE = "per_turn_coding_agent_action.jsonl"

# Every key that may appear at the row level as a denormalized header
# rather than per-turn data. Used both for writing (these go on every row)
# and reading (these get split off into the summary's top-level fields).
# step5 only populates the first three; step6 adds the rest.
HEADER_FIELDS = (
    "task_name", "session_id", "schema_version",
    "repo_url", "base_commit", "replay_status",
    "total_replay_warnings",
)
_HEADER_SET = frozenset(HEADER_FIELDS)

CUMULATIVE_FIELDS = (
    "cumulative_patch", "cumulative_files_changed_count",
    "cumulative_additions", "cumulative_deletions",
)


def normalize_messages_with_idx(session: dict) -> list[dict]:
    """Op stream tagged with source message index.

    Schema-selection mirrors step4: when a message carries both flat
    `tool_uses` AND nested `content[].tool_use`, take only the flat
    projection — they're duplicates and emitting both double-applies
    every edit.
    """
    ops: list[dict] = []
    for i, m in enumerate(session.get("messages", [])):
        if not isinstance(m, dict):
            continue
        role = m.get("role", "?")
        c = m.get("content")
        flat = m.get("tool_uses") or []
        nested = [
            b for b in (c or [])
            if isinstance(b, dict) and b.get("type") == "tool_use"
        ] if isinstance(c, list) else []

        if flat:
            for tu in flat:
                inp = tu.get("input")
                if isinstance(inp, str):
                    inp = {"_str": inp}
                ops.append({
                    "_msg_idx": i, "role": role,
                    "tool": tu.get("tool") or tu.get("name") or "",
                    "input": inp or {},
                })
        elif nested:
            for b in nested:
                ops.append({
                    "_msg_idx": i, "role": role,
                    "tool": b.get("name", ""),
                    "input": b.get("input") or {},
                })
        elif isinstance(c, str) and "<tool_use" in c:
            for m2 in INLINE_TOOL_USE_RE.finditer(c):
                try:
                    payload = json.loads(m2.group(1))
                except json.JSONDecodeError:
                    continue
                ops.append({
                    "_msg_idx": i, "role": role,
                    "tool": payload.get("name", ""),
                    "input": payload.get("arguments") or payload.get("input") or {},
                })
    return ops


def _truncate_patch(text: str) -> tuple[str, bool]:
    raw = text.encode("utf-8")
    if len(raw) <= MAX_PATCH_BYTES:
        return text, False
    return raw[:MAX_PATCH_BYTES].decode("utf-8", errors="ignore") + "\n... [truncated]\n", True


def _turn_could_mutate(turn_ops: list[dict]) -> bool:
    """True iff some op in this turn might touch the work tree.

    Lets us skip `git diff` on read-only turns (~half of long sessions).
    Conservative: anything in step4's mutating set, plus any `bash` op —
    step4 replays `sed -i` literally and flags other shell mutations
    (`cat >`, `tee`) as sneak edits, so it's not safe to fast-path bash.
    """
    for op in turn_ops:
        tool = (op.get("tool") or "").lower()
        if tool in ALL_MUTATING or tool == "bash":
            return True
    return False


def _zero_fill_turns(turns: list[dict]):
    for t in turns:
        for k in CUMULATIVE_FIELDS:
            t[k] = "" if k == "cumulative_patch" else 0
        t["replay_warnings_this_turn"] = []


def _read_summary(jsonl_path: Path) -> dict:
    """Reconstruct an in-memory summary from a JSONL emitted by step5 or
    step6. Header fields are read off the first row (they're denormalized
    identically on every row); everything else becomes turn data."""
    with open(jsonl_path, encoding="utf-8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    if not rows:
        return {"turns": []}
    summary = {k: rows[0][k] for k in HEADER_FIELDS if k in rows[0]}
    summary["turns"] = [
        {k: v for k, v in r.items() if k not in _HEADER_SET}
        for r in rows
    ]
    return summary


def _write_jsonl(summary: dict, jsonl_path: Path):
    header = {k: summary[k] for k in HEADER_FIELDS if k in summary}
    tmp = jsonl_path.with_suffix(jsonl_path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for t in summary.get("turns", []):
            f.write(json.dumps({**header, **t}, ensure_ascii=False) + "\n")
    tmp.replace(jsonl_path)


def _finalize(summary: dict, turns: list[dict], summary_path: Path, *,
              replay_status: str, repo_url: str | None = None,
              base_commit: str | None = None,
              total_warnings: int | None = None):
    """Stamp header fields and write the JSONL atomically. `total_warnings
    is None` marks a skip path — the per-turn cumulative_* fields get
    zero-filled so the schema stays uniform for downstream consumers."""
    summary["repo_url"] = repo_url
    summary["base_commit"] = base_commit
    summary["replay_status"] = replay_status
    summary["schema_version"] = SCHEMA_VERSION_OUT
    if total_warnings is None:
        _zero_fill_turns(turns)
    else:
        summary["total_replay_warnings"] = total_warnings
    _write_jsonl(summary, summary_path)


def replay_for_task(task_dir: Path, force: bool) -> dict:
    task_name = task_dir.name
    summary_path = task_dir / SUMMARY_FILE
    session_path = task_dir / "original_session.json"
    dockerfile = task_dir / "environment" / "Dockerfile"

    if not summary_path.exists():
        return {"task": task_name, "status": "skip",
                "reason": f"no {SUMMARY_FILE} (run step5 first)"}
    if not session_path.exists():
        return {"task": task_name, "status": "skip",
                "reason": "no original_session.json"}

    summary = _read_summary(summary_path)
    if summary.get("schema_version") == SCHEMA_VERSION_OUT and not force:
        return {"task": task_name, "status": "cached"}

    turns = summary.get("turns") or []
    if not turns:
        return {"task": task_name, "status": "skip",
                "reason": "no turns in summary"}

    repo_url, base_commit, repo_path_hint = parse_task_dockerfile(dockerfile)
    if not (repo_url and base_commit):
        _finalize(summary, turns, summary_path,
                  replay_status="skip:no_dockerfile_repo",
                  repo_url=repo_url, base_commit=base_commit)
        return {"task": task_name, "status": "skip",
                "reason": f"no repo_url/sha (repo={repo_url}, sha={base_commit})"}

    with open(session_path, encoding="utf-8") as f:
        session = json.load(f)
    ops = normalize_messages_with_idx(session)

    with tempfile.TemporaryDirectory(prefix="step6-replay-") as td:
        work = Path(td) / "repo"
        ok, err = clone_at_commit(repo_url, base_commit, work)
        if not ok:
            _finalize(summary, turns, summary_path,
                      replay_status=f"skip:clone_failed:{err}",
                      repo_url=repo_url, base_commit=base_commit)
            return {"task": task_name, "status": "skip",
                    "reason": f"clone failed: {err}"}

        total_warnings = 0
        truncated_turns = 0
        last_diff: dict | None = None
        for t in turns:
            r_start, r_end = t.get("msg_range") or [0, 0]
            turn_ops = [o for o in ops if r_start <= o["_msg_idx"] < r_end]
            warnings = replay_ops(turn_ops, work, repo_path_hint) if turn_ops else []
            # step4 emits "no file-mutating ops" when zero edits land —
            # that's the normal state for ask/explore/test-only turns
            # and shouldn't show up in the per-turn warning log.
            warnings = [w for w in warnings if "no file-mutating ops" not in w]
            total_warnings += len(warnings)

            # Recompute the diff only when this turn could have changed
            # the work tree; otherwise carry the previous snapshot forward.
            if last_diff is None or _turn_could_mutate(turn_ops):
                diff = capture_diff(work)
                patch_text, truncated = _truncate_patch(diff["patch"])
                last_diff = {
                    "cumulative_patch": patch_text,
                    "cumulative_files_changed_count": diff["files_changed_count"],
                    "cumulative_additions": diff["total_additions"],
                    "cumulative_deletions": diff["total_deletions"],
                    "_cumulative_patch_truncated": truncated,
                }

            for k in CUMULATIVE_FIELDS:
                t[k] = last_diff[k]
            t["replay_warnings_this_turn"] = warnings
            if last_diff["_cumulative_patch_truncated"]:
                t["_cumulative_patch_truncated"] = True
                truncated_turns += 1

        _finalize(summary, turns, summary_path,
                  replay_status="ok", repo_url=repo_url, base_commit=base_commit,
                  total_warnings=total_warnings)

        return {
            "task": task_name, "status": "ok",
            "turns": len(turns), "warnings": total_warnings,
            "final_files": turns[-1]["cumulative_files_changed_count"],
            "truncated_turns": truncated_turns,
        }


def _safe(fn, *args) -> dict:
    try:
        return fn(*args)
    except Exception as e:
        task = args[0].name if isinstance(args[0], Path) else "?"
        return {"task": task, "status": "error",
                "reason": f"{type(e).__name__}: {e}"}


def _pool_worker(arg: tuple[str, bool]) -> dict:
    """spawn-Pool entrypoint. Takes a (path, force) tuple — Path is not
    pickled across the process boundary, just the string."""
    return _safe(replay_for_task, Path(arg[0]), arg[1])


def _print_result(i: int, n: int, r: dict, counts: dict[str, int]):
    st = r["status"]
    counts[st] = counts.get(st, 0) + 1
    prefix = f"  [{i}/{n}] {r['task']:50s}"
    if st == "ok":
        extra = f", trunc={r['truncated_turns']}" if r.get("truncated_turns") else ""
        print(f"{prefix} ok (turns={r['turns']}, final_files={r['final_files']}, "
              f"warns={r['warnings']}{extra})")
    elif st in ("skip", "cached"):
        print(f"{prefix} {st}: {r.get('reason', '')}")
    else:
        print(f"{prefix} ERROR: {r.get('reason', '?')}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--tasks", default="*",
                    help="Glob over harbor_tasks/<pattern>/ (default: all)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true",
                    help="Re-replay even when schema_version is already 1.1")
    ap.add_argument("--workers", type=int, default=1,
                    help="Cross-task parallel workers. Safe once step4's bare-"
                         "clone cache (~/.cache/canonical-patches/repos/) is "
                         "warm. Default 1.")
    args = ap.parse_args()

    candidates = sorted(
        d for d in HARBOR_TASKS.iterdir()
        if d.is_dir() and fnmatch.fnmatch(d.name, args.tasks)
        and not d.name.startswith("_")
    )
    if args.limit:
        candidates = candidates[: args.limit]
    print(f"Targeting {len(candidates)} tasks")

    counts: dict[str, int] = {}
    t0 = time.time()
    n = len(candidates)

    if args.workers <= 1:
        for i, d in enumerate(candidates, 1):
            _print_result(i, n, _safe(replay_for_task, d, args.force), counts)
    else:
        payload = [(str(d), args.force) for d in candidates]
        with mp.get_context("spawn").Pool(args.workers) as pool:
            for i, r in enumerate(pool.imap_unordered(_pool_worker, payload), 1):
                _print_result(i, n, r, counts)

    print(f"\n=== Done in {time.time()-t0:.1f}s ===")
    for k, v in sorted(counts.items()):
        print(f"  {k:10s}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
