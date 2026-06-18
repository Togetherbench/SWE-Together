"""Single source of truth for the message-tag taxonomy + the two user-axis metrics.

Per sim message (stored in intent_coverage_verdict.json :: trial_msg_tags):
  - tags: list[str]   multi-label, independent presence (>=1 base act, >=0 corrective)
  - frustration: int  orthogonal affect axis (0/1)
  - tier: str         specificity of the directive payload ('none' if non-directive)

Two metrics are derived from these in code (no hard-coded weights anywhere else):
  - User Correction = #correction + 0.2·#nudge        (agent-driven corrective pushback)
  - User Effort      = Σ tier_weight over directive msgs (task-driven specification load)

Imported by tag_messages.py, eval/run_eval.py, and every plot/aggregation so the
taxonomy and weights live in ONE place.
"""
from __future__ import annotations

# ── base speech acts (every message has >=1) ─────────────────────────────────
BASE = {"request", "question", "verification", "workflow", "approval", "context"}

# ── corrective layer (>=0 per message) ───────────────────────────────────────
EXPLICIT_CORRECTIVE = {"correction"}   # asserts the agent erred (redirect/reminder fold into correction or request)
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


# ── User Effort metric (task-driven) — tier-weighted specification load ───────
FREE = {"workflow", "approval", "context"}                     # don't cost effort
DIRECTIVE_BEARING = {"request", "verification"} | CORRECTIVE   # only these get a real tier
SPECIFICITY_WEIGHTS = {"none": 0, "vague": 1, "directional": 2, "diagnostic": 3,
                       "prescriptive": 4, "patch_level": 5}
TIER_NAMES = tuple(SPECIFICITY_WEIGHTS)


def has_directive(tags) -> bool:
    return bool(set(tags) & DIRECTIVE_BEARING)


def tier_weight(tier) -> int:
    return SPECIFICITY_WEIGHTS.get(tier or "none", 0)


def user_effort_of(tags, tier) -> int:
    """Per-message User-Effort cost: the tier weight if the msg carries a directive,
    else 0. tier is per-message — never summed across tags. A pure question/approval/
    context (no directive) is tier 'none' → 0."""
    return tier_weight(tier) if (has_directive(tags) and tier not in (None, "none")) else 0


def user_effort(msg_tags_tiers) -> int:
    """msg_tags_tiers: iterable of (tags, tier) for ONE trial. Returns the trial's
    User Effort = Σ tier_weight over directive-bearing messages (sum of tier_weight·turn)."""
    return sum(user_effort_of(tags, tier) for tags, tier in msg_tags_tiers)


def expected_tier(tags, tier):
    """tier MUST be 'none' when there's no directive payload. Returns (fixed_tier, warning|None)."""
    if not has_directive(tags) and tier not in (None, "none"):
        return "none", f"tier={tier!r} on non-directive msg → forced to 'none'"
    return tier, None


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


def validate(tags, frustration=0, tier="none") -> list[str]:
    """Soft schema warnings (non-fatal). Used by the tagger and tests/test_kind_tags.py."""
    w = []
    tags = list(tags)
    if not (set(tags) & BASE):
        w.append("no base act")
    bad = set(tags) - ALL_TAGS
    if bad:
        w.append(f"unknown tags: {sorted(bad)}")
    if frustration not in (0, 1):
        w.append(f"frustration={frustration!r} not in {{0,1}}")
    if tier not in SPECIFICITY_WEIGHTS:
        w.append(f"tier={tier!r} invalid")
    _, tw = expected_tier(tags, tier)
    if tw:
        w.append(tw)
    return w
