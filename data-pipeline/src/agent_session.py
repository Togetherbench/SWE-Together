"""Agent session — unified JSONL artifact format (schema v2.0).

One file per agent session. Line 0 is the header row; lines 1..N are turn rows.
Schema definition lives at `data-pipeline/agent_session.schema.json`.

Three callers, same shape:
    data-pipeline/sessions/<sid>.jsonl       (extraction staging)
    harbor_tasks/<task>/oracle_session.jsonl (promoted oracle)
    trials/<cohort>/<task>/<trial>/session.jsonl (model trial)

Read API (one helper, used by every replay/scoring script):
    session = AgentSession.load(path)
    patch   = session.grading_patch  # AUTHORITATIVE diff for scoring
    rows    = session.turns          # per-turn rows with cumulative_patch
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator

SCHEMA_ID = "agent_session/2.0"


@dataclass
class AgentSession:
    """In-memory view of a *_session.jsonl file."""

    header: dict[str, Any]
    turns: list[dict[str, Any]] = field(default_factory=list)
    path: Path | None = None

    # ---- IO ---------------------------------------------------------------

    @classmethod
    def load(cls, path: str | Path) -> "AgentSession":
        path = Path(path)
        rows = _parse_jsonl(path)
        if not rows:
            raise ValueError(f"empty session file: {path}")
        header = rows[0]
        if not header.get("_is_header"):
            raise ValueError(
                f"missing header row in {path} "
                f"(line 0 must set `_is_header: true`)"
            )
        if header.get("schema") != SCHEMA_ID:
            raise ValueError(
                f"schema mismatch in {path}: "
                f"expected {SCHEMA_ID!r}, got {header.get('schema')!r}"
            )
        return cls(header=header, turns=rows[1:], path=path)

    def write(self, path: str | Path | None = None) -> None:
        """Write JSONL — header first, then one line per turn."""
        out = Path(path) if path else self.path
        if out is None:
            raise ValueError("no path provided (and self.path is None)")
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w") as f:
            f.write(json.dumps(self.header, ensure_ascii=False))
            f.write("\n")
            for t in self.turns:
                f.write(json.dumps(t, ensure_ascii=False))
                f.write("\n")

    # ---- Convenience accessors -------------------------------------------

    @property
    def kind(self) -> str:
        return self.header.get("_kind", "")

    @property
    def task_name(self) -> str:
        return self.header.get("_task_name", "")

    @property
    def status(self) -> str:
        return self.header.get("_status", "")

    @property
    def base_commit(self) -> str | None:
        return self.header.get("_base_commit")

    @property
    def repo_url(self) -> str | None:
        return self.header.get("_repo_url")

    @property
    def grading_patch(self) -> str | None:
        """Authoritative diff for scoring.

        Oracle canonical: header `_grading_patch` is the source of truth (may
            be PR diff or hand-curated, distinct from per-turn replay).
        Oracle stub (`_status: no_canonical`): returns None unconditionally
            — even if turn rows carry a `cumulative_patch`, that's session
            history that we deliberately did NOT promote to a grading target.
            Returning it would silently let stubs participate in scoring.
        Trial: header has no `_grading_patch`; walk turns backward and take
            the LAST NON-EMPTY `cumulative_patch`. Walking backward (instead
            of just `self.turns[-1]`) matters because user-sim wrap-up turns
            often have empty cumulative_patch fields — and `agent/final.patch`
            itself can be truncated/empty.
        """
        if self.status == "no_canonical":
            return None
        gp = self.header.get("_grading_patch")
        if gp:
            return gp
        for row in reversed(self.turns):
            cp = row.get("cumulative_patch")
            if cp and cp.strip():
                return cp
        return None

    @property
    def grading_patch_source(self) -> str | None:
        return self.header.get("_grading_patch_source")

    def turn(self, idx: int) -> dict[str, Any]:
        return self.turns[idx]

    def __iter__(self) -> Iterator[dict[str, Any]]:
        return iter(self.turns)

    def __len__(self) -> int:
        return len(self.turns)


# -----------------------------------------------------------------------------
# Header / turn constructors — keep field names stable.
# -----------------------------------------------------------------------------


def make_header(
    *,
    kind: str,
    task_name: str,
    status: str,
    **extra: Any,
) -> dict[str, Any]:
    """Build a conformant header row. Extra fields pass through."""
    hdr: dict[str, Any] = {
        "_is_header": True,
        "schema": SCHEMA_ID,
        "_kind": kind,
        "_task_name": task_name,
        "_status": status,
    }
    hdr.update({k: v for k, v in extra.items() if v is not None})
    return hdr


def make_turn(*, turn: int, **extra: Any) -> dict[str, Any]:
    """Build a turn row. Extra fields pass through; None values dropped."""
    row: dict[str, Any] = {"turn": int(turn)}
    row.update({k: v for k, v in extra.items() if v is not None})
    return row


# -----------------------------------------------------------------------------
# Schema validation (closes over a cached schema; one-shot per process).
# -----------------------------------------------------------------------------

_SCHEMA_PATH = Path(__file__).resolve().parents[1] / "agent_session.schema.json"
_SCHEMA: dict[str, Any] | None = None
_VALIDATOR: Any = None


def _get_validator() -> Any:
    global _SCHEMA, _VALIDATOR
    if _VALIDATOR is not None:
        return _VALIDATOR
    try:
        from jsonschema import Draft202012Validator  # type: ignore
    except ImportError as e:  # pragma: no cover
        raise ImportError(
            "jsonschema is required for agent_session validation. "
            "Install with: pip install jsonschema"
        ) from e
    _SCHEMA = json.loads(_SCHEMA_PATH.read_text())
    _VALIDATOR = Draft202012Validator(_SCHEMA)
    return _VALIDATOR


def validate_row(row: dict[str, Any]) -> list[str]:
    """Validate a single row (header or turn) against the schema.

    Returns a list of human-readable error messages (empty = valid).
    """
    v = _get_validator()
    errors: list[str] = []
    for err in v.iter_errors(row):
        path = ".".join(str(p) for p in err.absolute_path) or "<root>"
        errors.append(f"{path}: {err.message}")
    return errors


def validate_file(path: str | Path) -> list[str]:
    """Validate every row of a *_session.jsonl file. Returns error list."""
    path = Path(path)
    errors: list[str] = []
    try:
        rows = _parse_jsonl(path)
    except Exception as e:
        return [f"parse error: {e}"]
    if not rows:
        return ["empty file"]
    if not rows[0].get("_is_header"):
        errors.append("line 0: missing `_is_header: true`")
    for i, r in enumerate(rows):
        for msg in validate_row(r):
            errors.append(f"line {i}: {msg}")
    return errors


# -----------------------------------------------------------------------------
# Internals.
# -----------------------------------------------------------------------------


def _parse_jsonl(path: Path) -> list[dict[str, Any]]:
    """Permissive JSONL reader — raises on unrecoverable lines."""
    rows: list[dict[str, Any]] = []
    with path.open() as f:
        for i, line in enumerate(f):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                rows.append(json.loads(stripped))
            except json.JSONDecodeError as e:
                raise ValueError(
                    f"{path}:{i + 1}: invalid JSON: {e.msg}"
                ) from e
    return rows
