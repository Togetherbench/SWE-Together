#!/usr/bin/env python3
"""Step 5 (trial variant) — derive `session.jsonl` v2.0 from a model trial.

Input layout (Harbor + user-sim native capture):
  <trial_dir>/
    agent/
      claude-code.txt          (raw CLI transcript; JSONL appended by Harbor)
      patches/turn-N.patch     (cumulative diff vs harbor-base, per turn)
      patches/turn-N.incremental.patch
      final.patch              (last cumulative)
    verifier/
      reward.txt
      gates.json

Output:
  <trial_dir>/session.jsonl    schema agent_session/2.0, _kind: trial

This minimal first cut populates per-turn rows from the captured cumulative
patches. Richer per-turn fields (user_message, ops list, files_*) are out of
scope here and can be added in a follow-up by parsing claude-code.txt against
the existing step5 op taxonomy. The grading_patch is determined by the trial's
final cumulative diff (last turn).

Usage:
  python data-pipeline/scripts/step5_trials.py <trial_dir> [--task <name>] [--model <id>] [--cohort <name>]
  python data-pipeline/scripts/step5_trials.py --all <cohort_root>
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "data-pipeline" / "src"))

from agent_session import AgentSession, make_header, make_turn  # noqa: E402

TURN_RE = re.compile(r"turn-(\d+)\.patch$")
INC_RE = re.compile(r"turn-(\d+)\.incremental\.patch$")
HEADER_LINE_RE = re.compile(r"^=== \S+/ ===\s*$", re.MULTILINE)


def _strip_workspace_headers(text: str) -> str:
    """Strip the per-workspace `=== repo/ ===` separators that the user-sim
    interleaves between repo blocks. The result is a clean unified diff
    suitable for `git apply`."""
    if not text:
        return text
    return HEADER_LINE_RE.sub("", text).strip() + "\n"


def _count_diff_stats(diff_text: str) -> tuple[int, int, int]:
    """Return (files_changed, additions, deletions) for a unified diff."""
    if not diff_text:
        return 0, 0, 0
    files = sum(1 for ln in diff_text.splitlines() if ln.startswith("diff --git "))
    additions = sum(
        1 for ln in diff_text.splitlines()
        if ln.startswith("+") and not ln.startswith("+++")
    )
    deletions = sum(
        1 for ln in diff_text.splitlines()
        if ln.startswith("-") and not ln.startswith("---")
    )
    return files, additions, deletions


def _read_turn_patches(trial_dir: Path) -> list[tuple[int, str, str]]:
    """Return [(turn, cumulative_text, incremental_text)] sorted by turn."""
    patches_dir = trial_dir / "agent" / "patches"
    if not patches_dir.is_dir():
        return []
    cum: dict[int, str] = {}
    inc: dict[int, str] = {}
    for p in patches_dir.iterdir():
        m_inc = INC_RE.search(p.name)
        m_cum = TURN_RE.search(p.name) if not m_inc else None
        if m_inc:
            inc[int(m_inc.group(1))] = _strip_workspace_headers(p.read_text(errors="ignore"))
        elif m_cum:
            cum[int(m_cum.group(1))] = _strip_workspace_headers(p.read_text(errors="ignore"))
    out: list[tuple[int, str, str]] = []
    for turn in sorted(cum.keys()):
        out.append((turn, cum.get(turn, ""), inc.get(turn, "")))
    return out


def _build_session(
    trial_dir: Path,
    *,
    task: str,
    model: str,
    cohort: str,
    trial_id: str,
    harness_version: str | None = None,
) -> AgentSession:
    turn_data = _read_turn_patches(trial_dir)

    # Header carries trial identity and the verifier reward if we can read it.
    verifier_path = trial_dir / "verifier" / "reward.txt"
    verifier_reward: float | None = None
    if verifier_path.is_file():
        try:
            verifier_reward = float(verifier_path.read_text().strip())
        except Exception:
            verifier_reward = None

    header_extra: dict = {
        "_model": model,
        "_cohort": cohort,
        "_trial_id": trial_id,
    }
    if harness_version:
        header_extra["_harness_version"] = harness_version

    header = make_header(
        kind="trial",
        task_name=task,
        status="canonical" if turn_data else "skip",
        **header_extra,
    )
    if verifier_reward is not None:
        header["_final_reward"] = verifier_reward

    turns: list[dict] = []
    for turn, cum_text, inc_text in turn_data:
        files, additions, deletions = _count_diff_stats(cum_text)
        row = make_turn(
            turn=turn,
            cumulative_patch=cum_text if cum_text.strip() else None,
            cumulative_files_changed_count=files,
            cumulative_additions=additions,
            cumulative_deletions=deletions,
            replay_warnings_this_turn=[],
        )
        turns.append(row)

    return AgentSession(header=header, turns=turns)


def derive_one(
    trial_dir: Path,
    *,
    task: str | None = None,
    model: str | None = None,
    cohort: str | None = None,
    trial_id: str | None = None,
) -> Path:
    """Write `<trial_dir>/session.jsonl` and return its path."""
    # Infer task / model / cohort / trial_id from path layout if not provided.
    # Convention: trials/<cohort>/<task>/<trial_id>/
    parts = trial_dir.resolve().parts
    if cohort is None and len(parts) >= 4:
        cohort = parts[-3]
    if task is None and len(parts) >= 3:
        task = parts[-2]
    if trial_id is None:
        trial_id = trial_dir.name
    if model is None and cohort:
        # Cohort names like `v044_opus46_unified` → middle token approximates model.
        model = cohort

    if not (task and model and cohort and trial_id):
        raise ValueError(
            f"insufficient identity (task={task!r}, model={model!r}, "
            f"cohort={cohort!r}, trial_id={trial_id!r}); "
            "pass --task/--model/--cohort or use a `trials/<cohort>/<task>/<trial_id>/` path."
        )

    session = _build_session(
        trial_dir,
        task=task,
        model=model,
        cohort=cohort,
        trial_id=trial_id,
    )
    out_path = trial_dir / "session.jsonl"
    session.write(out_path)
    return out_path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trial_dir", type=Path, nargs="?",
                    help="Path to a single trial directory")
    ap.add_argument("--all", type=Path,
                    help="Cohort root: derive session.jsonl for every "
                         "trial subdirectory found under it.")
    ap.add_argument("--task", help="Override task name inference")
    ap.add_argument("--model", help="Override model id inference")
    ap.add_argument("--cohort", help="Override cohort inference")
    args = ap.parse_args()

    if args.all:
        # Look for `agent/patches/` subdirs anywhere under the cohort root.
        roots = sorted(
            p.parent.parent for p in args.all.rglob("agent/patches")
            if p.is_dir()
        )
        if not roots:
            print(f"[warn] no trial dirs found under {args.all}", file=sys.stderr)
            return 1
        ok = fail = 0
        for r in roots:
            try:
                out = derive_one(r)
                ok += 1
                try:
                    rel = out.relative_to(REPO)
                except ValueError:
                    rel = out  # cohort lives outside the repo — print absolute
                print(f"  OK {rel}")
            except Exception as e:
                fail += 1
                print(f"  ERR {r}: {e}", file=sys.stderr)
        print(f"\n[step5_trials] {ok} ok, {fail} failed")
        return 0 if fail == 0 else 1

    if args.trial_dir is None:
        ap.error("either trial_dir or --all is required")

    out = derive_one(
        args.trial_dir,
        task=args.task,
        model=args.model,
        cohort=args.cohort,
    )
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
