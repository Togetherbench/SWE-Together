"""
Stable data model for per-turn test manifests.

Each task carries `tests/test_manifest.yaml` describing every gate with a
stable id, the user turn it covers, the kind (F2P / P2P_GATING), the
reward weight, and a one-line description. `tests/test.sh` runs the gates
and emits `/logs/verifier/gates.json` (one JSON line per gate with verdict).
Reward is computed deterministically from manifest + gates.json so:

  - downstream tooling can show per-turn pass/fail per model
  - rewriting tests = editing structured data, not free-form bash
  - manifest is what the iterative repair loop reads / mutates

Schema version 1.0.
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator


GateKind = Literal["F2P", "P2P_GATING", "P2P_REGRESSION"]


class Gate(BaseModel):
    """One scored or gating check."""
    id: str = Field(..., description="Stable, snake_case, unique across the manifest. Embedded in test.sh.")
    turn: Optional[int] = Field(
        None,
        description=(
            "1-indexed user turn this gate covers, or null for cross-turn gates "
            "(source-immutability, regression guards). Every F2P gate MUST have a turn."
        ),
    )
    kind: GateKind = Field(..., description="F2P (scores), P2P_GATING (zeroes reward on fail), P2P_REGRESSION (must keep passing).")
    weight: float = Field(0.0, ge=0.0, le=1.0)
    description: str
    notes: Optional[str] = None  # design rationale, e.g., what bug the gate exercises

    @field_validator("weight")
    @classmethod
    def f2p_must_have_weight(cls, v, info):
        # Pydantic v2 validator order: kind validated first; check both
        return v

    def model_post_init(self, __ctx):  # type: ignore[override]
        if self.kind == "F2P" and self.weight <= 0:
            raise ValueError(f"F2P gate {self.id!r} must have positive weight")
        if self.kind == "F2P" and self.turn is None:
            raise ValueError(f"F2P gate {self.id!r} must have a `turn` (per-turn coverage rule)")
        if self.kind in ("P2P_GATING", "P2P_REGRESSION") and self.weight != 0:
            raise ValueError(f"{self.kind} gate {self.id!r} must have weight=0")


class Turn(BaseModel):
    """A user turn we expect tests to cover."""
    turn: int = Field(..., ge=1)
    user_message: str = Field(..., description="Verbatim quote of the user message.")
    deliverable: str = Field(..., description="What the agent should have produced for this turn (one sentence).")
    skipped: bool = False
    skip_reason: Optional[str] = None  # e.g. "purely conversational acknowledgement"


class TestManifest(BaseModel):
    """Top-level manifest. Lives at tests/test_manifest.yaml."""
    version: str = "1.0"
    task: str
    turns: list[Turn]
    gates: list[Gate]
    notes: Optional[str] = None

    @field_validator("gates")
    @classmethod
    def gate_ids_unique(cls, v):
        seen = set()
        for g in v:
            if g.id in seen:
                raise ValueError(f"duplicate gate id: {g.id}")
            seen.add(g.id)
        return v

    def f2p_gates(self) -> list[Gate]:
        return [g for g in self.gates if g.kind == "F2P"]

    def f2p_weight_total(self) -> float:
        return sum(g.weight for g in self.f2p_gates())

    def gates_for_turn(self, turn: int) -> list[Gate]:
        return [g for g in self.gates if g.turn == turn]

    def validate_per_turn_coverage(self, min_f2p_per_turn: int = 2) -> list[str]:
        """Return list of error strings; empty list = OK."""
        errors: list[str] = []
        # F2P gate count per active turn
        active_turns = [t for t in self.turns if not t.skipped]
        for t in active_turns:
            n_f2p = sum(1 for g in self.gates if g.turn == t.turn and g.kind == "F2P")
            if n_f2p < min_f2p_per_turn:
                errors.append(
                    f"turn {t.turn} has {n_f2p} F2P gate(s); need >= {min_f2p_per_turn}"
                )
        # Total F2P weight ~= 1.0
        total = self.f2p_weight_total()
        if not (0.99 <= total <= 1.01):
            errors.append(f"F2P weight total = {total:.3f}; must equal 1.0")
        return errors


# ---------------------------------------------------------------------------
# Run-time per-gate verdicts (what tests/test.sh emits)
# ---------------------------------------------------------------------------


class GateVerdict(BaseModel):
    """One line in /logs/verifier/gates.json."""
    id: str
    passed: bool
    detail: Optional[str] = None  # short human reason if failed


class GatesReport(BaseModel):
    gates: list[GateVerdict]

    def by_id(self) -> dict[str, GateVerdict]:
        return {v.id: v for v in self.gates}


def compute_reward(manifest: TestManifest, report: GatesReport) -> float:
    """Pure deterministic reward calc.

    Rules:
      1. Any P2P_GATING gate failing -> reward = 0.0 (hard zero, regression).
      2. P2P_REGRESSION gates passing required to score; if any fail -> reward = 0.0.
      3. Reward = sum of weights of F2P gates that passed.
      4. Missing verdicts (gate declared but not emitted) treated as failure.
    """
    by_id = report.by_id()
    for g in manifest.gates:
        if g.kind in ("P2P_GATING", "P2P_REGRESSION"):
            v = by_id.get(g.id)
            if v is None or not v.passed:
                return 0.0
    earned = 0.0
    for g in manifest.f2p_gates():
        v = by_id.get(g.id)
        if v is not None and v.passed:
            earned += g.weight
    return round(min(earned, 1.0), 4)


# ---------------------------------------------------------------------------
# YAML helpers (avoid importing yaml at module load to keep import light)
# ---------------------------------------------------------------------------


def load_manifest(path) -> TestManifest:
    import yaml
    from pathlib import Path
    data = yaml.safe_load(Path(path).read_text())
    return TestManifest.model_validate(data)


def dump_manifest(manifest: TestManifest, path) -> None:
    import yaml
    from pathlib import Path
    data = manifest.model_dump(exclude_none=True)
    Path(path).write_text(yaml.safe_dump(data, sort_keys=False, width=100))


def load_gates_report(path) -> GatesReport:
    import json
    from pathlib import Path
    raw = Path(path).read_text()
    # Accept either {"gates": [...]} or a JSON-lines stream
    raw = raw.strip()
    if raw.startswith("{"):
        return GatesReport.model_validate_json(raw)
    gates = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        gates.append(GateVerdict.model_validate_json(line))
    return GatesReport(gates=gates)
