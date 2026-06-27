"""Single source of truth for the message-tag taxonomy + the User Correction metric.

Per sim message (stored in intent_coverage_verdict.json :: trial_msg_tags):
  - tags: list[str]   multi-label, independent presence (>=1 base act, >=0 corrective)
  - frustration: int  orthogonal affect axis (0/1)

User Correction = #correction + 0.2·#nudge  (agent-driven corrective pushback), derived
in code (no hard-coded weights anywhere else). Imported by tag_messages.py,
eval/run_eval.py, and every aggregation so the taxonomy + weight live in ONE place.
"""
from __future__ import annotations

# ── base speech acts (every message has >=1) ─────────────────────────────────
BASE = {"request", "question", "verification", "workflow", "approval", "context"}

# ── corrective layer (>=0 per message) ───────────────────────────────────────
EXPLICIT_CORRECTIVE = {"correction"}   # asserts the agent erred (redirect/reminder fold in)
IMPLICIT_CORRECTIVE = {"nudge"}        # only implies the agent erred
CORRECTIVE = EXPLICIT_CORRECTIVE | IMPLICIT_CORRECTIVE

ALL_TAGS = BASE | CORRECTIVE
AFFECT = {"frustration"}               # separate axis, can co-occur with anything

# ── User Correction metric (agent-driven) ────────────────────────────────────
W_NUDGE = 0.2          # explicit correction counts 1.0; implicit nudge counts 0.2


def user_correction(msg_tags) -> float:
    """msg_tags: iterable of per-message tag collections for ONE trial.
    Returns #correction + W_NUDGE·#nudge (the canonical User Correction score)."""
    corr = sum(1 for t in msg_tags if "correction" in t)
    nud = sum(1 for t in msg_tags if "nudge" in t)
    return corr + W_NUDGE * nud


def metrics_from_rows(trial_msg_tags) -> dict:
    """Derive the per-trial User Correction metric from `trial_msg_tags` rows
    ([{tags, ...}, ...]). SINGLE SOURCE OF TRUTH for both what gets persisted into
    intent_coverage_verdict.json (by tag_messages.py) and what eval/run_eval.py
    aggregates — so stored and recomputed values can never diverge.
    Returns Nones when the trial wasn't tagged (no rows)."""
    rows = trial_msg_tags or []
    if not rows:
        return {"user_correction": None, "n_tagged_msgs": 0,
                "n_correction": None, "n_nudge": None}
    tags = [r.get("tags", []) for r in rows]
    return {
        "user_correction": round(user_correction(tags), 4),
        "n_tagged_msgs": len(rows),
        "n_correction": sum(1 for t in tags if "correction" in t),
        "n_nudge": sum(1 for t in tags if "nudge" in t),
    }


# ── helpers ───────────────────────────────────────────────────────────────────
def primary_kind(tags) -> str:
    """Back-compat single label (when something needs one): correction > nudge > base act."""
    if "correction" in tags:
        return "correction"
    if "nudge" in tags:
        return "nudge"
    for t in tags:
        if t in BASE:
            return t
    return "request"


def validate(tags, frustration=0) -> list[str]:
    """Soft schema warnings (non-fatal). Used by the tagger."""
    w = []
    tags = list(tags)
    if not (set(tags) & BASE):
        w.append("no base act")
    bad = set(tags) - ALL_TAGS
    if bad:
        w.append(f"unknown tags: {sorted(bad)}")
    if frustration not in (0, 1):
        w.append(f"frustration={frustration!r} not in {{0,1}}")
    return w
