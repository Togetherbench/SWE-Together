"""Per-trial user-behavior panel.

Step 3 of the three-step protocol in `eval/eval_design.md`:

> On the surviving trials, run a panel of user-behavior measurements — user
> effort, per-tier specificity distribution, intervention count, abandonment /
> give-up rate, etc. These are not aggregated into the correctness number; they
> sit alongside it so a reader can see *how* the sim got the agent to the
> score it got.

No LLM calls. Reads:
  - `<trial>/agent/episode-*/user_decision.json` — sim actions, has_message,
    cumulative stats, hard-cap signal
  - `<trial>/intent_coverage_verdict.json` — `trial_msg_specificity` (tier +
    kind_hint per sim msg) and `effort_cost` (per the §Proposal schema
    extension). Optional — gracefully degrades if absent.
  - `<task>/oracle_intents.json` — oracle intent_kind per intent (for the
    per-kind reconciliation pass)

Writes `<trial>/user_behavior_verdict.json`. Mirrors the per-trial output
shape of `eval/intent_coverage/coverage_one.py`.

Usage:
    .venv/bin/python -m eval.user_behavior.behavior_one \\
        --trial-dir trials_eval_pilot_10_task_r1/cli-task-2a55af__LXqASZW \\
        --task-dir  harbor_tasks/cli-task-2a55af
"""
from __future__ import annotations

import argparse
import json
import logging
import time
from pathlib import Path
from typing import Any

# All tier/kind aggregations (`per_tier_count`, `per_tier_fraction`,
# `per_kind_count`) plus the `effort_cost` scalar are computed by
# `eval/intent_coverage/coverage_one.py` and passthrough-read here — see
# eval_design.md §B. This file's role per its docstring is the no-LLM file-I/O
# panel (intervention_count, hard_cap_abandon, per_action_count).

# Sim action vocabulary — must match `src/user_agent/user_agent.py::ACTIONS`.
ACTION_NAMES: tuple[str, ...] = (
    "no-op", "question", "redirect", "new_requirement", "check_external",
)


def _load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def load_episodes(trial_dir: Path) -> list[dict]:
    """Load every `episode-*/user_decision.json` in order of episode index.

    Returns the parsed dicts; skips any that fail to read or parse.
    """
    out: list[tuple[int, dict]] = []
    for ep_dir in (trial_dir / "agent").glob("episode-*"):
        try:
            idx = int(ep_dir.name.split("-", 1)[1])
        except (IndexError, ValueError):
            continue
        d = _load_json(ep_dir / "user_decision.json")
        if d is None:
            continue
        out.append((idx, d))
    out.sort(key=lambda t: t[0])
    return [d for _, d in out]


def _safe_int(x: Any) -> int | None:
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


def detect_hard_cap_abandon(episodes: list[dict]) -> bool:
    """Was this trial cut short by the sim's `max_messages` hard cap?

    The sim writes `raw_response == "hard_cap_reached"` on the no-op decision
    that fires when `message_count >= max_messages` (see
    `src/user_agent/user_agent.py:251`). We also accept the structural check —
    `max_messages` is set AND `message_count >= max_messages` in the last
    episode — to survive a future rename of the raw_response sentinel.
    """
    if not episodes:
        return False
    last = episodes[-1]
    stats = last.get("stats") or {}
    max_msgs = _safe_int(stats.get("max_messages"))
    msg_count = _safe_int(stats.get("message_count"))

    if max_msgs is not None and msg_count is not None and msg_count >= max_msgs:
        return True

    for d in episodes:
        if (d.get("raw_response") or "") == "hard_cap_reached":
            return True
    return False


def per_action_counts(episodes: list[dict]) -> dict[str, int]:
    """Authoritative count of decisions per action, taken from the last
    episode's cumulative `stats.action_breakdown` — the sim maintains a running
    counter so the final episode's breakdown is the trial total. Missing keys
    default to 0."""
    counts: dict[str, int] = {a: 0 for a in ACTION_NAMES}
    if not episodes:
        return counts
    breakdown = (episodes[-1].get("stats") or {}).get("action_breakdown") or {}
    for action, n in breakdown.items():
        counts[action] = counts.get(action, 0) + int(n)
    return counts


def measure_one_trial(
    trial_dir: Path,
    task_dir: Path,
    out_name: str = "user_behavior_verdict.json",
) -> dict:
    """Compute the user-behavior panel for one trial and write it to disk."""
    t0 = time.monotonic()
    trial_dir = trial_dir.resolve()
    task_dir = task_dir.resolve()

    episodes = load_episodes(trial_dir)
    n_episodes = len(episodes)

    intervention_count = sum(1 for d in episodes if d.get("has_message"))
    no_op_count = sum(1 for d in episodes if d.get("action") == "no-op")
    wait_count_final: int | None = None
    if episodes:
        wait_count_final = _safe_int((episodes[-1].get("stats") or {}).get("wait_count"))

    actions = per_action_counts(episodes)
    hard_cap_abandon = detect_hard_cap_abandon(episodes)

    coverage_verdict = _load_json(trial_dir / "intent_coverage_verdict.json") or {}
    trial_msg_specificity = coverage_verdict.get("trial_msg_specificity")

    # All tier/kind aggregations and effort_cost are passthrough from
    # intent_coverage_verdict.json (single source of truth — see eval_design.md
    # §B). Legacy verdicts predating these fields → None / empty dict.
    effort_cost = coverage_verdict.get("effort_cost")
    if not isinstance(effort_cost, int):
        effort_cost = None
    tiers = coverage_verdict.get("per_tier_count") or {}
    kinds = coverage_verdict.get("per_kind_count") or {}

    # effort_per_matched_intent — sim-verbosity diagnostic from Block 1' of
    # eval_design.md. Needs the match_table to count matched intents.
    matched_intents: int | None = None
    match_table = coverage_verdict.get("match_table") or {}
    per_intent = match_table.get("per_intent")
    if isinstance(per_intent, list):
        matched_intents = sum(
            1 for e in per_intent
            if isinstance(e, dict) and (e.get("match_confidence") or 0) >= 0.5
        )
    effort_per_matched_intent: float | None = None
    if effort_cost is not None and matched_intents not in (None, 0):
        effort_per_matched_intent = round(effort_cost / matched_intents, 4)

    max_messages: int | None = None
    if episodes:
        max_messages = _safe_int((episodes[-1].get("stats") or {}).get("max_messages"))

    n_trial_msgs = coverage_verdict.get("n_trial_msgs")
    per_tier_fraction = coverage_verdict.get("per_tier_fraction")  # passthrough

    verdict = {
        "schema_version": 1,
        "trial_dir": str(trial_dir),
        "task_dir": str(task_dir),
        "n_episodes": n_episodes,
        "intervention_count": intervention_count,
        "no_op_count": no_op_count,
        "wait_count_final": wait_count_final,
        "max_messages": max_messages,
        "hard_cap_abandon": hard_cap_abandon,
        "per_action_count": actions,
        "per_tier_count": tiers,
        "per_tier_fraction": per_tier_fraction,
        "per_kind_count": kinds,
        "effort_cost": effort_cost,
        "effort_per_matched_intent": effort_per_matched_intent,
        "matched_intents": matched_intents,
        "n_trial_msgs": n_trial_msgs,
        "coverage_verdict_present": bool(coverage_verdict),
        "specificity_present": bool(trial_msg_specificity),
        "elapsed_sec": round(time.monotonic() - t0, 3),
    }
    (trial_dir / out_name).write_text(json.dumps(verdict, indent=2, ensure_ascii=False))
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trial-dir", required=True, type=Path)
    ap.add_argument("--task-dir", required=True, type=Path)
    ap.add_argument("--out-name", default="user_behavior_verdict.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    v = measure_one_trial(args.trial_dir, args.task_dir, out_name=args.out_name)
    print(json.dumps({
        "trial": args.trial_dir.name,
        "task": args.task_dir.name,
        "intervention_count": v["intervention_count"],
        "hard_cap_abandon": v["hard_cap_abandon"],
        "effort_cost": v["effort_cost"],
        "per_tier_count": v["per_tier_count"],
        "per_action_count": v["per_action_count"],
        "specificity_present": v["specificity_present"],
        "elapsed_sec": v["elapsed_sec"],
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
