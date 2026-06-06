"""Canonical-run tracker — declarative plan + per-cell state machine.

A canonical leaderboard run is the matrix ``models × replicates × tasks``:
the v0.5 default is 3 models × 3 replicates × 166 tasks = **1,494 cells**.
Each cell carries a trial that must travel through four stages on disk:

    Step 0  src/run_eval.py            → agent/final.patch + verifier/reward.txt
    Step 1  eval/correctness/judge_one → judge_verdict.json
    Step 2  eval/intent_coverage/coverage_one → intent_coverage_verdict.json
    Step 3  eval/user_behavior/behavior_one   → user_behavior_verdict.json

This module knows how to:

- load a plan JSON ("which cells should exist?"),
- walk a trials root on disk,
- classify every cell into one of nine :class:`CellState` values, and
- summarise per-cohort and per-task progress for the CLI tools.

Callers: :mod:`scripts.canonical_status` (read-only report) and
:mod:`scripts.canonical_launch` (the driver). Both layer on top — none of
the disk-walking or state-machine logic lives in the CLI scripts.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any

# Reuse the infra sentinel's sidecar reader so a single source of truth
# decides what counts as "infra failed". Avoids divergence between the
# tracker's view and the sentinel's audit output.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "src"))
from eval_infra_sentinel import classify_or_load  # noqa: E402


# ──────────────────────────────────────────────────────────────────────────
# State machine
# ──────────────────────────────────────────────────────────────────────────


class CellState(str, Enum):
    """Where one (model, replicate, task) cell lives on disk.

    Ordering matters — higher ordinal = further along. Used to pick the
    "best" trial dir when multiple exist for the same cell (retries).
    """

    NOT_STARTED       = "not_started"
    STEP0_RUNNING     = "step0_running"
    STEP0_HARBOR_ERR  = "step0_harbor_err"
    STEP0_INFRA_FAIL  = "step0_infra_failed"
    STEP0_OK          = "step0_ok"
    STEP1_DONE        = "step1_done"
    STEP2_DONE        = "step2_done"
    STEP3_DONE        = "step3_done"


# Anything from STEP0_OK upward means Step 0 produced a real datapoint; the
# eval/run_eval.py judge + coverage + behavior stages should run on it.
STEP0_USABLE: frozenset[CellState] = frozenset({
    CellState.STEP0_OK,
    CellState.STEP1_DONE,
    CellState.STEP2_DONE,
    CellState.STEP3_DONE,
})

# Step 0 needs to (re)run if no trial dir exists OR the latest is broken.
STEP0_NEEDS_RUN: frozenset[CellState] = frozenset({
    CellState.NOT_STARTED,
    CellState.STEP0_RUNNING,
    CellState.STEP0_HARBOR_ERR,
    CellState.STEP0_INFRA_FAIL,
})

_STATE_ORDER: dict[CellState, int] = {s: i for i, s in enumerate([
    CellState.NOT_STARTED,
    CellState.STEP0_RUNNING,
    CellState.STEP0_HARBOR_ERR,
    CellState.STEP0_INFRA_FAIL,
    CellState.STEP0_OK,
    CellState.STEP1_DONE,
    CellState.STEP2_DONE,
    CellState.STEP3_DONE,
])}


@dataclass
class CellStatus:
    model_tag: str
    replicate: int
    task: str
    state: CellState
    trial_dir: Path | None = None
    trial_count: int = 0  # how many `<task>__*` dirs exist (retries)


@dataclass
class CohortStatus:
    model_tag: str
    replicate: int
    counts: dict[CellState, int] = field(default_factory=dict)
    total: int = 0

    @property
    def next_action(self) -> str:
        """What the launcher should do next for this cohort.

        Step 0 is per-cohort (one ``src/run_eval.py`` invocation per
        (model, replicate)). Step 1+2+3 is per-model (one
        ``eval/run_eval.py`` invocation across the model's replicates).
        Both layers consult this string.
        """
        step0_pending = sum(self.counts.get(s, 0) for s in STEP0_NEEDS_RUN)
        if step0_pending:
            return "step0"
        if self.counts.get(CellState.STEP3_DONE, 0) == self.total:
            return "done"
        return "eval"


# ──────────────────────────────────────────────────────────────────────────
# Plan loading
# ──────────────────────────────────────────────────────────────────────────


@dataclass
class CanonicalPlan:
    name: str
    trials_root: Path
    tasks_root: Path
    models: dict[str, dict[str, Any]]  # model_tag → {model, user_model, workers}
    replicates: list[int]
    tasks: list[str]

    @property
    def total_cells(self) -> int:
        return len(self.models) * len(self.replicates) * len(self.tasks)

    def cohort_dir(self, model_tag: str, replicate: int) -> Path:
        return self.trials_root / f"{model_tag}_r{replicate}"


def _discover_runnable_tasks(tasks_root: Path) -> list[str]:
    """Return the active task list — same predicate as
    ``src/run_eval.py:get_all_tasks``: dir with task.toml + instruction.md
    + tests/test.sh. Sorted alphabetically for stable enumeration.
    """
    if not tasks_root.is_dir():
        raise FileNotFoundError(f"tasks_root not found: {tasks_root}")
    out = []
    for d in sorted(tasks_root.iterdir()):
        if not d.is_dir() or d.name.startswith("_") or d.name.startswith("."):
            continue
        if not (d / "task.toml").exists():
            continue
        if not (d / "instruction.md").exists():
            continue
        if not (d / "tests" / "test.sh").exists():
            continue
        out.append(d.name)
    return out


def load_plan(path: Path, repo_root: Path = REPO_ROOT) -> CanonicalPlan:
    """Read a canonical-plan JSON and materialise the task list.

    ``tasks: "ALL"`` (the recommended default) gets expanded against the
    plan's ``tasks_root`` at load time. A literal list is honoured
    verbatim — useful for a smoke-test plan that targets, say, 10 tasks.

    Paths in the plan are interpreted relative to ``repo_root``.
    """
    raw = json.loads(path.read_text())
    name = raw["name"]
    trials_root = (repo_root / raw["trials_root"]).resolve()
    tasks_root = (repo_root / raw.get("tasks_root", "harbor_tasks")).resolve()
    models = raw["models"]
    replicates = list(raw.get("replicates", [1, 2, 3]))
    tasks_field = raw.get("tasks", "ALL")
    if tasks_field == "ALL":
        tasks = _discover_runnable_tasks(tasks_root)
    elif isinstance(tasks_field, list):
        tasks = list(tasks_field)
    else:
        raise ValueError(f"plan.tasks must be 'ALL' or a list, got: {tasks_field!r}")
    if not tasks:
        raise ValueError(f"plan has zero tasks (tasks_root={tasks_root})")
    return CanonicalPlan(
        name=name,
        trials_root=trials_root,
        tasks_root=tasks_root,
        models=models,
        replicates=replicates,
        tasks=tasks,
    )


# ──────────────────────────────────────────────────────────────────────────
# Cell classification
# ──────────────────────────────────────────────────────────────────────────


def _classify_one_trial_dir(trial_dir: Path) -> CellState:
    """State for a single trial dir. Step 1/2/3 verdicts override Step 0
    state because once verdicts land, the cell is functionally past Step 0
    even if the sentinel sidecar was never written."""
    if not (trial_dir / "result.json").exists():
        return CellState.STEP0_RUNNING

    try:
        result = json.loads((trial_dir / "result.json").read_text())
    except (json.JSONDecodeError, OSError):
        return CellState.STEP0_RUNNING

    if result.get("exception_info"):
        return CellState.STEP0_HARBOR_ERR
    vr = result.get("verifier_result")
    if not (vr and vr.get("rewards")):
        return CellState.STEP0_HARBOR_ERR

    # Step 0 reward exists. Defer to sentinel for the infra verdict —
    # sidecar reads are O(1); fresh classification is bounded by transcript
    # size. This keeps the tracker honest with the audit CLI.
    verdict = classify_or_load(trial_dir)
    if verdict.status == "infra_failed":
        return CellState.STEP0_INFRA_FAIL

    has_judge = (trial_dir / "judge_verdict.json").exists()
    has_cov   = (trial_dir / "intent_coverage_verdict.json").exists()
    has_beh   = (trial_dir / "user_behavior_verdict.json").exists()
    if has_judge and has_cov and has_beh:
        return CellState.STEP3_DONE
    if has_judge and has_cov:
        return CellState.STEP2_DONE
    if has_judge:
        return CellState.STEP1_DONE
    return CellState.STEP0_OK


def classify_cell(
    plan: CanonicalPlan, model_tag: str, replicate: int, task: str,
) -> CellStatus:
    """State of one (model, replicate, task) cell.

    When multiple trial dirs match (Harbor creates a new UID per retry),
    the *highest-ordinal* state wins — a single ok rerun rescues a cell
    even if older infra-failed dirs are still around for forensics.
    """
    cohort = plan.cohort_dir(model_tag, replicate)
    if not cohort.exists():
        return CellStatus(model_tag, replicate, task,
                          CellState.NOT_STARTED, None, 0)

    # Harbor truncates trial dir names to 32 chars of task name — match on
    # the truncated prefix (same fix as run_eval.is_task_completed).
    matches = [d for d in cohort.iterdir()
               if d.is_dir() and d.name.startswith(task[:32] + "__")]
    if not matches:
        return CellStatus(model_tag, replicate, task,
                          CellState.NOT_STARTED, None, 0)

    best_dir = matches[0]
    best_state = _classify_one_trial_dir(matches[0])
    for d in matches[1:]:
        s = _classify_one_trial_dir(d)
        if _STATE_ORDER[s] > _STATE_ORDER[best_state]:
            best_dir, best_state = d, s

    return CellStatus(model_tag, replicate, task,
                      best_state, best_dir, len(matches))


def classify_all(plan: CanonicalPlan) -> list[CellStatus]:
    """Walk every cell in the plan and return its status. Caller decides
    how to aggregate (by cohort, by task, by state)."""
    out: list[CellStatus] = []
    for model_tag in plan.models:
        for rep in plan.replicates:
            for task in plan.tasks:
                out.append(classify_cell(plan, model_tag, rep, task))
    return out


def summarise_cohorts(cells: list[CellStatus]) -> dict[tuple[str, int], CohortStatus]:
    """Counter per (model_tag, replicate). Cohort summaries drive the
    "what to launch next" decision in the CLI."""
    out: dict[tuple[str, int], CohortStatus] = {}
    for c in cells:
        key = (c.model_tag, c.replicate)
        if key not in out:
            out[key] = CohortStatus(c.model_tag, c.replicate)
        co = out[key]
        co.total += 1
        co.counts[c.state] = co.counts.get(c.state, 0) + 1
    return out


def model_step0_done(cells: list[CellStatus], model_tag: str) -> bool:
    """True iff every cell for this model has progressed past Step 0
    (across all replicates). Step 1+2+3 needs this to be True before
    eval/run_eval.py is launched — otherwise the per-task aggregator gets
    holes."""
    seen = False
    for c in cells:
        if c.model_tag != model_tag:
            continue
        seen = True
        if c.state not in STEP0_USABLE:
            return False
    return seen
