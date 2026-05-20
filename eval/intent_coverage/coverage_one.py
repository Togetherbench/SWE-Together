"""Single-trial intent coverage judge — match-table edition (Codex design).

Pipeline:
  1. Load pre-extracted intent units from
     `harbor_tasks/<task>/oracle_intents.json` (run extract_intents.py first).
  2. Load trial sim messages from
     `<trial_dir>/agent/episode-*/user_decision.json`.
  3. LLM returns ONLY a match table — per-intent best-match + unmatched trial msgs.
  4. Code deterministically computes:
       coverage_rate     = matched intents / total intents
       weighted_coverage = mean(match_confidence over all intents)
       scope_precision   = unique matched trial msgs / total trial msgs
       overall_score     = 0.65 * weighted_coverage + 0.35 * scope_precision

Usage:
    .venv/bin/python -m eval.intent_coverage.coverage_one \\
        --trial-dir trials_eval_pilot_10_task_r1/cli-task-2a55af__LXqASZW \\
        --task-dir  harbor_tasks/cli-task-2a55af

Output: `<trial_dir>/intent_coverage_verdict.json`
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT / "external" / "harbor" / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "external" / "harbor" / "src"))

from harbor.llms.lite_llm import LiteLLM  # noqa: E402
from eval.intent_coverage.extract_intents import extract_one as extract_intents_one  # noqa: E402

SYSTEM_PROMPT_PATH = Path(__file__).parent / "prompts" / "coverage_system.md"
DEFAULT_MODEL = "anthropic/claude-opus-4-6"

# Score formula (Codex weights — coverage outweighs precision slightly)
W_COVERAGE = 0.65
W_PRECISION = 0.35
MATCH_CONFIDENCE_FLOOR_FOR_COVERED = 0.5  # ≥ this counts as "covered"
_FLOAT_TOL = 1e-6

# §Proposal — user effort tiers (eval_design.md §B). Keep in sync with
# `eval/user_behavior/behavior_one.py::SPECIFICITY_WEIGHTS`.
SPECIFICITY_WEIGHTS: dict[str, int] = {
    "vague":         1,
    "directional":   2,
    "diagnostic":    3,
    "prescriptive":  4,
    "patch_level":   5,
}
TIER_NAMES: frozenset[str] = frozenset(SPECIFICITY_WEIGHTS)

# Kinds that don't pay effort — commit/push/ok/continue are free.
FREE_KINDS: frozenset[str] = frozenset({"workflow", "context", "approval"})
ALL_KINDS: frozenset[str] = frozenset({
    "request", "correction", "question", "verification",
    "workflow", "context", "approval",
})


def load_dotenv(repo_root: Path) -> None:
    env = repo_root / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


def load_intents(task_dir: Path) -> list[dict]:
    """Load or extract on-demand the task's intent units."""
    cache = task_dir / "oracle_intents.json"
    if not cache.exists():
        raise FileNotFoundError(
            f"missing {cache}. Run "
            f"`python -m eval.intent_coverage.extract_intents --task-dir {task_dir}` first."
        )
    return json.loads(cache.read_text())["intents"]


def load_trial_sim_msgs(trial_dir: Path) -> list[dict]:
    out = []
    eps = sorted((trial_dir / "agent").glob("episode-*"))
    for ep in eps:
        ud = ep / "user_decision.json"
        if not ud.exists(): continue
        try:
            d = json.loads(ud.read_text())
        except json.JSONDecodeError:
            continue
        if not d.get("has_message"): continue
        text = (d.get("content") or "").strip()
        if not text: continue
        out.append({
            "trial_idx": len(out),
            "turn": d.get("turn"),
            "action": d.get("action", ""),
            "text": text,
        })
    return out


def build_user_message(intents: list[dict], sim: list[dict]) -> str:
    parts = []
    parts.append("## INTENTS — atomic intent units from the original session\n")
    if intents:
        for it in intents:
            parts.append(
                f"- intent_id={it['intent_id']} kind={it['intent_kind']} (turn {it.get('source_turn','?')}): "
                f"{it['text']}  |  excerpt: {it['verbatim_excerpt']}"
            )
    else:
        parts.append("- (none — original session had no non-trivial follow-up turns)")
    parts.append("\n## TRIAL — sim messages this trial actually fired\n")
    if sim:
        for s in sim:
            txt = re.sub(r"\s+", " ", s["text"]).strip()
            parts.append(
                f"- trial_idx={s['trial_idx']} (turn {s['turn']}, action={s['action']}): {txt[:1200]}"
            )
    else:
        parts.append("- (none — sim fired zero messages this trial)")
    parts.append(
        "\n## Your task\nProduce the match table per the system prompt. JSON only."
    )
    return "\n".join(parts)


_JSON_RE = re.compile(r"\{[\s\S]+\}")


def parse_json(raw: str) -> dict:
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\n", "", text)
        text = re.sub(r"\n```$", "", text)
    m = _JSON_RE.search(text)
    if not m:
        raise ValueError(f"no JSON object in response (head={raw[:200]!r})")
    return json.loads(m.group(0))


def normalize_match_table(table: dict, n_intents: int, n_trial: int) -> tuple[dict, list[str]]:
    """Coerce LLM output into a well-formed table. Returns (table, warnings)."""
    warnings: list[str] = []

    per_intent = table.get("per_intent") or []
    if not isinstance(per_intent, list):
        warnings.append(f"per_intent not a list: {type(per_intent).__name__}")
        per_intent = []

    seen_ids: dict[int, dict] = {}
    for entry in per_intent:
        if not isinstance(entry, dict): continue
        iid = entry.get("intent_id")
        if not isinstance(iid, int) or not (0 <= iid < n_intents):
            warnings.append(f"per_intent entry with bad intent_id={iid}")
            continue
        conf = entry.get("match_confidence")
        if not isinstance(conf, (int, float)):
            warnings.append(f"intent {iid} match_confidence non-numeric")
            conf = 0.0
        conf = max(0.0, min(1.0, float(conf)))
        mtidx = entry.get("matched_trial_idx")
        if mtidx is not None:
            if not isinstance(mtidx, int) or not (0 <= mtidx < n_trial):
                warnings.append(f"intent {iid} matched_trial_idx={mtidx} out of [0,{n_trial})")
                mtidx = None
        # If null match but high confidence, that's contradictory — zero it
        if mtidx is None and conf > 0:
            warnings.append(f"intent {iid}: null match but confidence={conf}; zeroed")
            conf = 0.0
        seen_ids[iid] = {
            "intent_id": iid,
            "matched_trial_idx": mtidx,
            "match_confidence": conf,
            "rationale": str(entry.get("rationale", ""))[:300],
        }
    # Fill missing intent_ids with no-match entries
    full_per_intent = []
    for iid in range(n_intents):
        if iid in seen_ids:
            full_per_intent.append(seen_ids[iid])
        else:
            warnings.append(f"intent {iid} missing from response; assumed no-match")
            full_per_intent.append({
                "intent_id": iid, "matched_trial_idx": None,
                "match_confidence": 0.0, "rationale": "missing in LLM output",
            })

    unmatched = table.get("unmatched_trial_msgs") or []
    if not isinstance(unmatched, list):
        warnings.append("unmatched_trial_msgs not a list; treating as []")
        unmatched = []
    cleaned_unmatched = []
    for u in unmatched:
        if not isinstance(u, dict): continue
        ti = u.get("trial_idx")
        if not isinstance(ti, int) or not (0 <= ti < n_trial): continue
        cleaned_unmatched.append({
            "trial_idx": ti,
            "category": u.get("category", "task-relevant-extra"),
            "rationale": str(u.get("rationale", ""))[:300],
        })

    return {
        "schema_version": 2,
        "n_intents": n_intents,
        "n_trial_msgs": n_trial,
        "per_intent": full_per_intent,
        "unmatched_trial_msgs": cleaned_unmatched,
    }, warnings


def normalize_trial_msg_specificity(
    spec: object, n_trial: int,
) -> tuple[list[dict], list[str]]:
    """Validate the §Proposal `trial_msg_specificity` array. Returns
    (normalized list, warnings). Missing rows are filled with `(vague, request)`
    and flagged in warnings so downstream readers can detect gaps."""
    warnings: list[str] = []
    if spec is None:
        if n_trial > 0:
            warnings.append("trial_msg_specificity missing from response")
        return [], warnings
    if not isinstance(spec, list):
        warnings.append(f"trial_msg_specificity not a list: {type(spec).__name__}")
        return [], warnings

    seen: dict[int, dict] = {}
    for entry in spec:
        if not isinstance(entry, dict):
            continue
        ti = entry.get("trial_idx")
        if not isinstance(ti, int) or not (0 <= ti < n_trial):
            warnings.append(f"specificity entry with bad trial_idx={ti}")
            continue
        tier = entry.get("tier")
        if tier not in TIER_NAMES:
            warnings.append(f"trial {ti} bad tier={tier!r}; coerced to 'vague'")
            tier = "vague"
        kind = entry.get("kind_hint")
        if kind not in ALL_KINDS:
            warnings.append(f"trial {ti} bad kind_hint={kind!r}; coerced to 'request'")
            kind = "request"
        seen[ti] = {
            "trial_idx": ti,
            "tier": tier,
            "kind_hint": kind,
            "rationale": str(entry.get("rationale", ""))[:200],
        }

    out: list[dict] = []
    for ti in range(n_trial):
        if ti in seen:
            out.append(seen[ti])
        else:
            warnings.append(f"trial {ti} missing from specificity; assumed vague/request")
            out.append({
                "trial_idx": ti, "tier": "vague", "kind_hint": "request",
                "rationale": "missing in LLM output",
            })
    return out, warnings


def compute_effort_cost(specificity: list[dict]) -> int:
    """Per-trial effort scalar — sum of tier weights over non-FREE messages.

    `eval_design.md` §B:
        effort_cost = Σ SPECIFICITY_WEIGHTS[m.tier]
                      for m in specificity if m.kind_hint not in FREE_KINDS
    """
    total = 0
    for m in specificity:
        if m.get("kind_hint") in FREE_KINDS:
            continue
        total += SPECIFICITY_WEIGHTS.get(m.get("tier") or "", 0)
    return total


def compute_scores(match_table: dict, n_intents: int, n_trial: int) -> dict:
    """All numeric scores derived deterministically from the match table."""
    per_intent = match_table["per_intent"]

    if n_intents == 0:
        # No oracle intents — coverage is vacuously perfect, but scope_precision
        # tells us if the sim was off-task. If trial also fired nothing, scores=1.
        scope_precision = 0.0 if n_trial > 0 else 1.0
        return {
            "coverage_rate": 1.0,
            "weighted_coverage": 1.0,
            "scope_precision": scope_precision,
            "overall_score": W_COVERAGE * 1.0 + W_PRECISION * scope_precision,
        }

    confidences = [e["match_confidence"] for e in per_intent]
    n_covered = sum(1 for c in confidences if c >= MATCH_CONFIDENCE_FLOOR_FOR_COVERED)
    coverage_rate = n_covered / n_intents
    weighted_coverage = sum(confidences) / n_intents

    if n_trial == 0:
        scope_precision = 0.0  # nothing fired → vacuously 0 precision contribution
    else:
        used_trial_idxs = {e["matched_trial_idx"] for e in per_intent if e["matched_trial_idx"] is not None}
        scope_precision = len(used_trial_idxs) / n_trial

    overall_score = W_COVERAGE * weighted_coverage + W_PRECISION * scope_precision
    return {
        "coverage_rate": round(coverage_rate, 4),
        "weighted_coverage": round(weighted_coverage, 4),
        "scope_precision": round(scope_precision, 4),
        "overall_score": round(overall_score, 4),
    }


async def judge_one_trial(
    trial_dir: Path,
    task_dir: Path,
    model: str = DEFAULT_MODEL,
    out_name: str = "intent_coverage_verdict.json",
    max_retries: int = 2,
    auto_extract: bool = True,
) -> dict:
    load_dotenv(REPO_ROOT)

    # Step 1: ensure intents are extracted (cached)
    if auto_extract and not (task_dir / "oracle_intents.json").exists():
        logging.info("oracle_intents.json missing; extracting now for %s", task_dir.name)
        await extract_intents_one(task_dir=task_dir, model=model)
    intents = load_intents(task_dir)
    sim = load_trial_sim_msgs(trial_dir)

    # Step 2: trivial shortcut
    if not intents and not sim:
        verdict = {
            "schema_version": 2, "n_intents": 0, "n_trial_msgs": 0,
            "match_table": {"per_intent": [], "unmatched_trial_msgs": []},
            "trial_msg_specificity": [],
            "coverage_rate": 1.0, "weighted_coverage": 1.0,
            "scope_precision": 1.0, "overall_score": 1.0,
            "effort_cost": 0,
            "judge_model": "shortcut", "elapsed_sec": 0.0,
            "schema_warnings": [],
            "trial_dir": str(trial_dir), "task_dir": str(task_dir),
        }
        (trial_dir / out_name).write_text(json.dumps(verdict, indent=2, ensure_ascii=False))
        return verdict

    # Step 3: LLM match
    user_msg = build_user_message(intents, sim)
    sys_prompt = SYSTEM_PROMPT_PATH.read_text()
    llm = LiteLLM(model_name=model, temperature=0.0)

    t0 = time.monotonic()
    last_err = ""
    table_raw = None
    for attempt in range(max_retries + 1):
        try:
            resp = await llm.call(
                prompt=user_msg,
                message_history=[{"role": "system", "content": sys_prompt}],
                tools=None,
            )
            raw = getattr(resp, "content", None) or getattr(resp, "text", None) or str(resp)
            table_raw = parse_json(raw)
            break
        except (json.JSONDecodeError, ValueError) as e:
            last_err = f"{type(e).__name__}: {e}"
            if attempt < max_retries:
                logging.warning("parse fail attempt %d: %s — retrying", attempt + 1, last_err)
                continue
            raise RuntimeError(f"could not parse match table after {max_retries+1} attempts: {last_err}")

    # Step 4: normalize + score
    table, warnings = normalize_match_table(table_raw, len(intents), len(sim))
    scores = compute_scores(table, len(intents), len(sim))

    # §Proposal — trial_msg_specificity + effort_cost (eval_design.md §B)
    specificity, spec_warnings = normalize_trial_msg_specificity(
        table_raw.get("trial_msg_specificity"), len(sim),
    )
    warnings.extend(spec_warnings)
    effort_cost = compute_effort_cost(specificity)

    verdict = {
        "schema_version": 2,
        "n_intents": len(intents),
        "n_trial_msgs": len(sim),
        "match_table": table,
        "trial_msg_specificity": specificity,
        **scores,
        "effort_cost": effort_cost,
        "judge_model": model,
        "elapsed_sec": round(time.monotonic() - t0, 1),
        "schema_warnings": warnings,
        "trial_dir": str(trial_dir),
        "task_dir": str(task_dir),
    }
    (trial_dir / out_name).write_text(json.dumps(verdict, indent=2, ensure_ascii=False))
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trial-dir", required=True, type=Path)
    ap.add_argument("--task-dir", required=True, type=Path)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--out-name", default="intent_coverage_verdict.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--no-auto-extract", action="store_true",
                    help="Fail if oracle_intents.json is missing instead of auto-extracting")
    args = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    v = asyncio.run(judge_one_trial(
        trial_dir=args.trial_dir.resolve(),
        task_dir=args.task_dir.resolve(),
        model=args.model, out_name=args.out_name,
        auto_extract=not args.no_auto_extract,
    ))
    print(json.dumps({
        "trial": args.trial_dir.name, "task": args.task_dir.name,
        "n_intents": v["n_intents"], "n_trial_msgs": v["n_trial_msgs"],
        "coverage_rate": v["coverage_rate"],
        "weighted_coverage": v["weighted_coverage"],
        "scope_precision": v["scope_precision"],
        "overall_score": v["overall_score"],
        "elapsed_sec": v["elapsed_sec"],
        "schema_warnings": v["schema_warnings"],
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
