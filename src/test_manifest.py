"""
Stable data model for per-turn test manifests.

Each task carries `tests/test_manifest.yaml` describing every gate with a
stable id, the user turn it covers, the kind (F2P / P2P), and a
one-line description. `tests/test.sh` runs the gates and emits
`/logs/verifier/gates.json` with canonical `passed` verdicts. Reward is
computed deterministically from manifest + gates.json so:

  - downstream tooling can show per-turn pass/fail per model
  - rewriting tests = editing structured data, not free-form bash
  - manifest is what the iterative repair loop reads / mutates

Schema version 1.0.
"""
from __future__ import annotations

from typing import Any, Literal, Optional, Sequence

from pydantic import BaseModel, Field, field_validator, model_validator


GateKind = Literal["F2P", "P2P_GATING", "P2P_REGRESSION", "P2P"]


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
    kind: GateKind = Field(..., description="F2P (positive coverage) or P2P/P2P_REGRESSION (bounded penalty + diagnostics). P2P_GATING is a deprecated legacy alias.")
    weight: float = Field(0.0, ge=0.0, le=1.0, description="Deprecated legacy field; ignored by canonical coverage scoring.")
    description: str
    notes: Optional[str] = None  # design rationale, e.g., what bug the gate exercises

    @field_validator("weight")
    @classmethod
    def f2p_must_have_weight(cls, v, info):
        # Pydantic v2 validator order: kind validated first; check both
        return v

    def model_post_init(self, __ctx):  # type: ignore[override]
        if self.kind in ("P2P_GATING", "P2P_REGRESSION", "P2P") and self.weight != 0:
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
        return errors


# ---------------------------------------------------------------------------
# Run-time per-gate verdicts (what tests/test.sh emits)
# ---------------------------------------------------------------------------


class GateVerdict(BaseModel):
    """One line in /logs/verifier/gates.json."""
    id: str
    passed: bool
    detail: Optional[str] = None  # short human reason if failed

    @model_validator(mode="before")
    @classmethod
    def normalize_legacy_verdicts(cls, data: Any) -> Any:
        """Accept the verifier shapes already present in the corpus.

        Historical verifiers have emitted `passed`, `pass`, or textual
        `verdict` values. Keep the internal model canonical while letting
        analysis tools parse old trials.
        """
        if not isinstance(data, dict):
            return data
        if "passed" not in data:
            if "pass" in data:
                data = {**data, "passed": data["pass"]}
            elif "verdict" in data:
                value = data["verdict"]
                if isinstance(value, str):
                    data = {**data, "passed": value.lower() in {"pass", "passed", "true", "ok"}}
                else:
                    data = {**data, "passed": bool(value)}
            elif "status" in data:
                value = data["status"]
                if isinstance(value, str):
                    data = {**data, "passed": value.lower() in {"pass", "passed", "true", "ok"}}
        return data


class GatesReport(BaseModel):
    gates: list[GateVerdict]

    def by_id(self) -> dict[str, GateVerdict]:
        return {v.id: v for v in self.gates}


class CoverageScore(BaseModel):
    """Unweighted F2P coverage plus bounded P2P penalty telemetry."""

    reward: float
    f2p_passed: int
    f2p_total: int
    f2p_pass_rate: float
    p2p_passed: int
    p2p_total: int
    p2p_pass_rate: Optional[float]
    p2p_fail_rate: float
    p2p_regression_passed: int
    p2p_regression_total: int
    p2p_regression_pass_rate: Optional[float]
    p2p_regression_fail_rate: float
    p2p_penalty: float
    p2p_penalty_cap: float
    p2p_gating_passed: int
    p2p_gating_total: int
    p2p_gating_failed: bool
    all_gate_passed: int
    all_gate_total: int
    all_gate_pass_rate: float
    swe_resolved: bool


def _gate_passed(by_id: dict[str, GateVerdict], gate: Gate) -> bool:
    verdict = by_id.get(gate.id)
    return bool(verdict and verdict.passed)


def compute_coverage_score(
    manifest: TestManifest,
    report: GatesReport,
    *,
    p2p_penalty_cap: float = 0.5,
) -> CoverageScore:
    """Compute the proposed unweighted coverage score.

    Positive signal:
      passed F2P gates / total F2P gates.

    Negative signal:
      a bounded penalty for failed P2P gates:
      `p2p_penalty_cap * failed_p2p / total_p2p`.

    `P2P_GATING` is accepted as a deprecated legacy alias, but it no longer
    has hard-zero semantics.
    `swe_resolved` is the SWE-bench-compatible all-or-nothing view.
    Missing verdicts are treated as failed gates.
    """
    if not (0.0 <= p2p_penalty_cap <= 1.0):
        raise ValueError("p2p_penalty_cap must be in [0.0, 1.0]")

    by_id = report.by_id()
    f2p = manifest.f2p_gates()
    p2p_regression = [g for g in manifest.gates if g.kind in ("P2P_REGRESSION", "P2P")]
    p2p_gating = [g for g in manifest.gates if g.kind == "P2P_GATING"]
    p2p_all = p2p_regression + p2p_gating

    f2p_passed = sum(1 for g in f2p if _gate_passed(by_id, g))
    p2p_regression_passed = sum(1 for g in p2p_regression if _gate_passed(by_id, g))
    p2p_gating_passed = sum(1 for g in p2p_gating if _gate_passed(by_id, g))
    p2p_passed = sum(1 for g in p2p_all if _gate_passed(by_id, g))
    all_gate_passed = sum(1 for g in manifest.gates if _gate_passed(by_id, g))

    f2p_pass_rate = f2p_passed / len(f2p) if f2p else 0.0
    if p2p_all:
        p2p_pass_rate = p2p_passed / len(p2p_all)
        p2p_fail_rate = 1.0 - p2p_pass_rate
    else:
        p2p_pass_rate = None
        p2p_fail_rate = 0.0
    if p2p_regression:
        p2p_regression_pass_rate = p2p_regression_passed / len(p2p_regression)
        p2p_regression_fail_rate = 1.0 - p2p_regression_pass_rate
    else:
        p2p_regression_pass_rate = None
        p2p_regression_fail_rate = 0.0

    p2p_penalty = p2p_penalty_cap * p2p_fail_rate
    p2p_gating_failed = p2p_gating_passed != len(p2p_gating)
    reward = max(0.0, min(1.0, f2p_pass_rate - p2p_penalty))

    swe_resolved = (
        bool(f2p)
        and f2p_passed == len(f2p)
        and p2p_passed == len(p2p_all)
    )

    all_gate_total = len(manifest.gates)
    return CoverageScore(
        reward=round(reward, 4),
        f2p_passed=f2p_passed,
        f2p_total=len(f2p),
        f2p_pass_rate=round(f2p_pass_rate, 4),
        p2p_passed=p2p_passed,
        p2p_total=len(p2p_all),
        p2p_pass_rate=round(p2p_pass_rate, 4) if p2p_pass_rate is not None else None,
        p2p_fail_rate=round(p2p_fail_rate, 4),
        p2p_regression_passed=p2p_regression_passed,
        p2p_regression_total=len(p2p_regression),
        p2p_regression_pass_rate=(
            round(p2p_regression_pass_rate, 4)
            if p2p_regression_pass_rate is not None else None
        ),
        p2p_regression_fail_rate=round(p2p_regression_fail_rate, 4),
        p2p_penalty=round(p2p_penalty, 4),
        p2p_penalty_cap=p2p_penalty_cap,
        p2p_gating_passed=p2p_gating_passed,
        p2p_gating_total=len(p2p_gating),
        p2p_gating_failed=p2p_gating_failed,
        all_gate_passed=all_gate_passed,
        all_gate_total=all_gate_total,
        all_gate_pass_rate=round(all_gate_passed / all_gate_total, 4) if all_gate_total else 0.0,
        swe_resolved=swe_resolved,
    )


def write_coverage_outputs(
    manifest: TestManifest,
    report: GatesReport,
    reward_path,
    metrics_path=None,
    *,
    p2p_penalty_cap: float = 0.5,
) -> CoverageScore:
    """Write canonical reward.txt plus optional machine-readable metrics.

    New verifiers should run gates, emit gates.json, then call this helper
    instead of hand-writing reward formulas in bash.
    """
    import json
    from pathlib import Path

    score = compute_coverage_score(
        manifest,
        report,
        p2p_penalty_cap=p2p_penalty_cap,
    )
    Path(reward_path).write_text(f"{score.reward:.4f}\n")
    if metrics_path is not None:
        Path(metrics_path).write_text(json.dumps(score.model_dump(), indent=2) + "\n")
    return score


def compute_coverage_score_from_paths(
    manifest_path,
    gates_path,
    *,
    p2p_penalty_cap: float = 0.5,
) -> CoverageScore:
    """Load manifest + gates files and compute canonical coverage reward."""
    return compute_coverage_score(
        load_manifest(manifest_path),
        load_gates_report(gates_path),
        p2p_penalty_cap=p2p_penalty_cap,
    )


def compute_reward(manifest: TestManifest, report: GatesReport) -> float:
    """Canonical reward: unweighted F2P coverage minus bounded P2P penalty."""
    return compute_coverage_score(manifest, report).reward


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(
        description=(
            "Compute canonical unweighted F2P coverage reward from "
            "test_manifest.yaml + gates.json."
        )
    )
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--gates", required=True)
    ap.add_argument("--reward-file", default="/logs/verifier/reward.txt")
    ap.add_argument("--metrics-file", default="/logs/verifier/score_metrics.json")
    ap.add_argument("--p2p-penalty-cap", type=float, default=0.5)
    ap.add_argument("--print-json", action="store_true")
    args = ap.parse_args(argv)

    manifest = load_manifest(args.manifest)
    report = load_gates_report(args.gates)
    score = write_coverage_outputs(
        manifest,
        report,
        args.reward_file,
        args.metrics_file,
        p2p_penalty_cap=args.p2p_penalty_cap,
    )
    if args.print_json:
        print(score.model_dump_json(indent=2))
    return 0


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
    raw = raw.strip()
    if not raw:
        return GatesReport(gates=[])

    # Accept {"gates": [...]}, a raw array, keyed objects, or JSON-lines.
    if raw.startswith("{") or raw.startswith("["):
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict) and "gates" in data:
            return GatesReport(gates=[GateVerdict.model_validate(g) for g in data["gates"]])
        if isinstance(data, dict) and "verdicts" in data and isinstance(data["verdicts"], dict):
            gates = []
            for gid, value in data["verdicts"].items():
                if isinstance(value, dict):
                    gates.append(GateVerdict.model_validate({"id": gid, **value}))
                else:
                    gates.append(GateVerdict.model_validate({"id": gid, "passed": value}))
            return GatesReport(gates=gates)
        if isinstance(data, list):
            return GatesReport(gates=[GateVerdict.model_validate(g) for g in data])
        if isinstance(data, dict):
            gates = []
            for gid, value in data.items():
                if str(gid).startswith("_"):
                    continue
                if isinstance(value, dict):
                    gates.append(GateVerdict.model_validate({"id": gid, **value}))
                else:
                    gates.append(GateVerdict.model_validate({"id": gid, "passed": value}))
            return GatesReport(gates=gates)

    gates = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        gates.append(GateVerdict.model_validate_json(line))
    return GatesReport(gates=gates)


if __name__ == "__main__":
    raise SystemExit(main())
