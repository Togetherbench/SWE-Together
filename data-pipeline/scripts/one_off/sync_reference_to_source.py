#!/usr/bin/env python3
"""sync_reference_to_source.py

Sync up-to-date metadata from a harbor_tasks/<task>/reference_patch.json BACK
to its canonical source JSON (the file pointed to by _canonical_source_path).

Rationale: reference_patch.json is the artifact that audit/repair work edits
most often (because it lives alongside the task). The source canonical should
always reflect current reality, so when reference holds newer truth
(e.g., a remediated _reliability block or a freshly-added _review block),
we push it back.

Fields that get synced source-bound:
  - _reliability  (full block)
  - _review       (full block)
  - _fidelity     (rare — only if reference has it and source disagrees)
  - patch, files_changed_count, numstat (only if reference is the post-edit truth)

Fields that NEVER get synced (reference-layer-only):
  - _canonical_source_path
  - _sync_note
  - _triple_check_round2
  - _fix_applied
  - _verification_note / _fidelity_verified* (these can also be reference-only)

Default mode is --dry-run: prints the planned edits and exits.
Pass --commit to actually write.

Usage:
    python sync_reference_to_source.py <task_name>           # dry-run by default
    python sync_reference_to_source.py <task_name> --commit
    python sync_reference_to_source.py --all                 # all divergent tasks (dry-run)
    python sync_reference_to_source.py --all --commit        # write all
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HARBOR = REPO_ROOT / "harbor_tasks"

# Fields that may be pushed from reference -> source
SYNCABLE_FIELDS = ["_reliability", "_review", "_fidelity", "patch",
                   "files_changed_count", "numstat"]
# Fields that are exclusively reference-layer
REFERENCE_ONLY = {"_canonical_source_path", "_sync_note",
                  "_triple_check_round2", "_fix_applied"}


def load(p: Path):
    with p.open() as fh:
        return json.load(fh)


def dump(p: Path, d):
    with p.open("w") as fh:
        json.dump(d, fh, indent=2)
        fh.write("\n")


def plan_sync(ref: dict, src: dict) -> list[tuple[str, object, object]]:
    """Return [(field, old_source_value, new_value_from_ref), ...] for fields
    where reference has different (and non-None) data the source should adopt."""
    plan = []
    for f in SYNCABLE_FIELDS:
        rv = ref.get(f)
        sv = src.get(f)
        if rv is None:
            # Reference does not have this field; nothing to push.
            continue
        if rv == sv:
            continue
        # Push reference value to source
        plan.append((f, sv, rv))
    return plan


def sync_task(task: str, commit: bool) -> int:
    """Return number of fields synced for this task (0 = clean)."""
    task_dir = HARBOR / task
    ref_path = task_dir / "reference_patch.json"
    if not ref_path.exists():
        print(f"[skip] {task}: no reference_patch.json", file=sys.stderr)
        return 0
    ref = load(ref_path)
    ptr = ref.get("_canonical_source_path")
    if not ptr:
        print(f"[skip] {task}: reference lacks _canonical_source_path", file=sys.stderr)
        return 0
    src_path = REPO_ROOT / ptr
    if not src_path.exists():
        print(f"[skip] {task}: source path {ptr} does not exist", file=sys.stderr)
        return 0
    src = load(src_path)
    plan = plan_sync(ref, src)
    if not plan:
        return 0

    print(f"\n=== {task} ===")
    print(f"  source: {ptr}")
    for f, old, new in plan:
        oldstr = (json.dumps(old, default=str)[:120] if old is not None else "None")
        newstr = (json.dumps(new, default=str)[:120] if new is not None else "None")
        print(f"  - {f}")
        print(f"      OLD source: {oldstr}")
        print(f"      NEW (from ref): {newstr}")
    if commit:
        for f, _, new in plan:
            src[f] = new
        dump(src_path, src)
        print(f"  [WROTE] {src_path}")
    else:
        print(f"  [DRY-RUN] would write {len(plan)} fields")
    return len(plan)


def find_all_divergent() -> list[str]:
    """Scan all reference_patch.json files; return tasks needing sync."""
    tasks = []
    for ref_path in sorted(HARBOR.glob("*/reference_patch.json")):
        try:
            ref = load(ref_path)
        except Exception:
            continue
        ptr = ref.get("_canonical_source_path")
        if not ptr:
            continue
        src_path = REPO_ROOT / ptr
        if not src_path.exists():
            continue
        try:
            src = load(src_path)
        except Exception:
            continue
        if plan_sync(ref, src):
            tasks.append(ref_path.parent.name)
    return tasks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("task", nargs="?", help="Task name (e.g., pi-mono-auto-1b58dd4f)")
    ap.add_argument("--all", action="store_true", help="Sync all divergent tasks")
    ap.add_argument("--commit", action="store_true", help="Actually write (default: dry-run)")
    args = ap.parse_args()

    if not args.task and not args.all:
        ap.error("must pass <task> or --all")

    if args.all:
        tasks = find_all_divergent()
        print(f"Found {len(tasks)} divergent tasks")
    else:
        tasks = [args.task]

    total_fields = 0
    for t in tasks:
        total_fields += sync_task(t, commit=args.commit)

    print(f"\n=== DONE ===")
    print(f"Tasks processed: {len(tasks)}")
    print(f"Total fields synced: {total_fields}")
    print(f"Mode: {'COMMIT' if args.commit else 'DRY-RUN'}")


if __name__ == "__main__":
    main()
