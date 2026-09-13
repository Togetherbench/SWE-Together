"""Re-derive a trial's ``final.patch`` after the junk filter changed.

``capture_git_diff`` strips run-generated directories (``.venv``, ``node_modules``,
language module caches, ...) before writing ``agent/final.patch``. When the
filter gains a new pattern, trials recorded earlier still carry the unfiltered
patch; where the pollution was severe, ``diff_polluted.flag`` marks them. This
tool re-applies the *current* filter to the stored cumulative patch and, if the
result differs, rewrites ``final.patch`` (keeping the original as
``final.patch.unfiltered``) and retires the stale judge verdict so the next judge
pass re-scores the trial on the agent's real edits.

Usage::

    python -m repair_polluted_patches trials/canonical_full109/opencode_fable51_r2 [...]
    python -m repair_polluted_patches --dry-run trials/canonical_full109/*_r*

Only trials whose filtered patch differs from the stored one are touched.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from user_agent.repo_diff import _strip_junk  # noqa: E402

UNFILTERED_SUFFIX = ".unfiltered"


def _nfiles(diff: str) -> int:
    return len(re.findall(r"^diff --git ", diff, re.M))


def repair_trial(trial_dir: Path, *, dry_run: bool = False) -> dict | None:
    """Return a change record if the trial's patch needed repair, else None."""
    patch = trial_dir / "agent" / "final.patch"
    if not patch.is_file():
        return None
    raw = patch.read_text(errors="replace")
    clean = _strip_junk(raw)
    if clean.strip() == raw.strip():
        return None
    rec = {
        "trial": trial_dir.name,
        "before_bytes": len(raw), "before_files": _nfiles(raw),
        "after_bytes": len(clean), "after_files": _nfiles(clean),
        "verdict_retired": False,
    }
    if dry_run:
        return rec
    backup = patch.with_name(patch.name + UNFILTERED_SUFFIX)
    if not backup.exists():
        patch.rename(backup)
    patch.write_text(clean + "\n")
    # The verdict (if any) judged the polluted patch; move it aside so the judge
    # launcher's skip-existing logic re-scores this trial.
    verdict = trial_dir / "judge_verdict.json"
    if verdict.exists():
        n = 1
        while (trial_dir / f"judge_verdict.polluted-{n}.json").exists():
            n += 1
        verdict.rename(trial_dir / f"judge_verdict.polluted-{n}.json")
        rec["verdict_retired"] = True
    flag = trial_dir / "agent" / "diff_polluted.flag"
    if flag.exists():
        flag.rename(flag.with_name("diff_polluted.repaired"))
    (trial_dir / "agent" / "patch_repair.json").write_text(json.dumps(rec, indent=1) + "\n")
    return rec


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("roots", nargs="+", type=Path, help="trial roots (dirs containing <task>__<id>/)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    changed = 0
    for root in args.roots:
        for trial in sorted(p for p in root.iterdir() if p.is_dir() and "__" in p.name):
            rec = repair_trial(trial, dry_run=args.dry_run)
            if rec:
                changed += 1
                print(f"{'would repair' if args.dry_run else 'repaired'} {root.name}/{rec['trial']}: "
                      f"{rec['before_bytes']/1e6:.1f} MB/{rec['before_files']} files -> "
                      f"{rec['after_bytes']/1e3:.1f} KB/{rec['after_files']} files"
                      f"{' (verdict retired)' if rec['verdict_retired'] else ''}")
    print(f"{changed} trial(s) {'need' if args.dry_run else 'had'} repair")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
