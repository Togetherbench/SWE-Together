"""Repair a trial's stored ``final.patch`` so it reflects the agent's real edits
and applies cleanly.

Two recording artefacts are corrected:

* **Run-generated junk.** ``capture_git_diff`` strips virtualenvs, module caches
  and similar before writing the patch; trials recorded before a filter gained a
  pattern still carry the unfiltered diff (``diff_polluted.flag`` marks the
  severe cases). The *current* filter is re-applied.
* **Lost trailing context line.** Older builds ``str.strip()``-ed the diff, so a
  last hunk ending on an empty source line lost its ``" "`` context line and
  ``git apply`` rejected the patch as corrupt; the judge then scored an
  unmodified workspace. The line is restored when the ``@@`` header proves it
  is missing.

The original is kept as ``final.patch.unfiltered``. A stale ``judge_verdict.json``
is retired (→ ``judge_verdict.polluted-N.json``) when junk was stripped, or when
the verdict shows the judge stumbled on the patch (apply failure / manual
application / "workspace unmodified"); a sound verdict on a patch that merely
lacked its trailing line is left in place.

Usage::

    python src/repair_polluted_patches.py trials/canonical_full109/opencode_fable51_r2 [...]
    python src/repair_polluted_patches.py --dry-run trials/canonical_full109/*_r*
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from user_agent.repo_diff import _strip_junk  # noqa: E402
from patch_normalize import _short_last_hunk, _rstrip_empty, banner_repos, _is_scratch, _SUBMODULE_RE, _BINARY_RE  # noqa: E402

UNFILTERED_SUFFIX = ".unfiltered"


def _nfiles(diff: str) -> int:
    return len(re.findall(r"^diff --git ", diff, re.M))


_STUMBLE_RE = re.compile(
    r"not applied|NOT applied|was not applied|patch_apply_failed|corrupt patch|"
    r"manually applied|applied (the )?(patch|diff|changes) manually|had to be manually|"
    r"HEAD is (still )?the base|original unmodified state|missing trailing newline",
    re.I,
)


def _judge_stumbled_on_patch(verdict_path: Path) -> bool:
    """True when the stored verdict shows the judge could not (cleanly) apply the
    patch — an apply error, or notes saying it applied the diff by hand or found
    the workspace unmodified."""
    try:
        v = json.loads(verdict_path.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if v.get("error") in ("patch_apply_failed", "verdict_read_failed"):
        return True
    return bool(_STUMBLE_RE.search(str(v.get("judge_notes") or "")))


def _old_judge_could_not_apply(raw: str) -> str:
    """Structural reasons the pre-fix judge sandbox (raw text, ``git apply`` in
    the first ``.git`` found, failure swallowed) could not have applied this
    patch, so its verdict graded an unmodified workspace. Empty string if none.

    * ``tmp-first``: the recorder listed an agent scratch clone under /tmp before
      the task repo, so the wrong section's hunks were applied to the task repo
      (arr-monitor-add-processes-flag: 12/14 trials judged 0.0 with verifier
      ≥ 0.83);
    * ``submodule``: a ``160000`` pointer block needs the submodule checked out;
    * ``binary``: ``Binary files ... differ`` placeholders cannot be applied.
    """
    reasons = []
    repos = banner_repos(raw)
    if repos and _is_scratch(repos[0]) and any(not _is_scratch(r) for r in repos):
        reasons.append("tmp-first")
    if _SUBMODULE_RE.search(raw):
        reasons.append("submodule")
    if _BINARY_RE.search(raw):
        reasons.append("binary")
    return "+".join(reasons)


def repair_trial(trial_dir: Path, *, dry_run: bool = False) -> dict | None:
    """Return a change record if the trial's patch or verdict needed repair, else None."""
    patch = trial_dir / "agent" / "final.patch"
    if not patch.is_file():
        return None
    raw = patch.read_text(errors="replace")
    stripped = _strip_junk(raw)
    # The stored patch keeps its original hunk headers: a header that is short
    # of its body is exactly what tells the judge (patch_normalize) that
    # trailing context was lost and lets it try both reconstructions. Only the
    # junk filter rewrites the stored text.
    clean = stripped
    unapplyable = _old_judge_could_not_apply(raw)
    short_hunk = _short_last_hunk(_rstrip_empty(stripped))[0] is not None
    patch_changed = clean != raw.rstrip("\n")
    verdict = trial_dir / "judge_verdict.json"
    # Retire the stored verdict when it graded something other than the agent's
    # edits: junk was in the patch, the old judge could not have applied it, or
    # the verdict itself shows the judge stumbled. Sound verdicts on a patch
    # that merely lacked its trailing line are left in place.
    junk_stripped = _nfiles(raw) != _nfiles(stripped)
    retire = verdict.exists() and (junk_stripped or bool(unapplyable) or _judge_stumbled_on_patch(verdict))
    if not patch_changed and not retire:
        return None
    rec = {
        "trial": trial_dir.name,
        "before_bytes": len(raw), "before_files": _nfiles(raw),
        "after_bytes": len(clean), "after_files": _nfiles(clean),
        "junk_stripped": junk_stripped,
        "short_last_hunk": short_hunk,
        "unapplyable_as_recorded": unapplyable,
        "verdict_retired": False,
    }
    if dry_run:
        rec["verdict_retired"] = retire
        return rec
    if patch_changed:
        backup = patch.with_name(patch.name + UNFILTERED_SUFFIX)
        if not backup.exists():
            patch.rename(backup)
        patch.write_text(clean + "\n")
    if retire:
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
