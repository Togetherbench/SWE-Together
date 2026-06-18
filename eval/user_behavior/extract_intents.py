"""Extract atomic intent units from a task's oracle_session.jsonl.

Runs once per task (cached). Downstream coverage_one.py reads the cache.

Usage:
    .venv/bin/python -m eval.user_behavior.extract_intents \\
        --task-dir harbor_tasks/cli-task-46c118

Output:
    harbor_tasks/<task>/oracle_intents.json
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

SYSTEM_PROMPT_PATH = Path(__file__).parent / "prompts" / "extract_intents_system.md"
# Default extractor model — matches coverage_one.DEFAULT_MODEL (Gemini-3.1-Pro).
# Keeps extract + judge on the same model so oracle_intents.json and per-trial
# coverage verdicts share calibration.
DEFAULT_MODEL = "gemini/gemini-3.1-pro-preview"


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


def load_oracle_user_turns(task_dir: Path) -> list[dict]:
    """Same filter as coverage_one — skip turn 0, trivial acks, interrupts."""
    osess = task_dir / "oracle_session.jsonl"
    if not osess.exists():
        raise FileNotFoundError(f"missing oracle_session.jsonl in {task_dir}")
    out = []
    for line in osess.read_text().splitlines():
        if not line.strip(): continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("_is_header"): continue
        if int(d.get("turn", 0)) == 0: continue
        msg = (d.get("user_message") or "").strip()
        if len(msg) < 10: continue
        low = msg.lower()
        if low.startswith("this session is being continued"): continue
        if low.startswith("[request interrupted"): continue
        out.append({"source_turn": d.get("turn"), "text": msg})
    return out


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


async def extract_one(
    task_dir: Path,
    model: str = DEFAULT_MODEL,
    out_name: str = "oracle_intents.json",
    force: bool = False,
) -> dict:
    out_path = task_dir / out_name
    if out_path.exists() and not force:
        existing = json.loads(out_path.read_text())
        return existing

    load_dotenv(REPO_ROOT)

    turns = load_oracle_user_turns(task_dir)
    if not turns:
        empty = {
            "schema_version": 1, "task": task_dir.name,
            "n_oracle_turns_in": 0, "intents": [],
            "extractor_model": "trivial-no-turns",
        }
        out_path.write_text(json.dumps(empty, indent=2, ensure_ascii=False))
        return empty

    user_msg_parts = ["## Oracle user turns (post instruction.md)\n"]
    for i, t in enumerate(turns):
        snippet = re.sub(r"\s+", " ", t["text"]).strip()
        # Don't truncate aggressively — long messages may carry many intents we
        # WANT the extractor to split. Cap at 3000 chars to bound token cost.
        user_msg_parts.append(f"- turn={t['source_turn']}: {snippet[:3000]}")
    user_msg_parts.append(
        "\n## Your task\nDecompose into atomic intent units per the system prompt. "
        "Return JSON only."
    )

    sys_prompt = SYSTEM_PROMPT_PATH.read_text()
    llm = LiteLLM(model_name=model, temperature=0.0)

    t0 = time.monotonic()
    resp = await llm.call(
        prompt="\n".join(user_msg_parts),
        message_history=[{"role": "system", "content": sys_prompt}],
        tools=None,
    )
    raw = getattr(resp, "content", None) or getattr(resp, "text", None) or str(resp)
    parsed = parse_json(raw)

    # Validate structure
    intents = parsed.get("intents") or []
    if not isinstance(intents, list):
        raise ValueError(f"intents field is not a list: {type(intents)}")
    # Normalize: ensure intent_id is sequential, fill in missing
    for i, it in enumerate(intents):
        it["intent_id"] = i
        if "intent_kind" not in it:
            it["intent_kind"] = "request"
        if "text" not in it or not it["text"]:
            raise ValueError(f"intent {i} missing 'text'")
        if "verbatim_excerpt" not in it:
            it["verbatim_excerpt"] = it["text"][:80]

    out = {
        "schema_version": 1,
        "task": task_dir.name,
        "n_oracle_turns_in": len(turns),
        "intents": intents,
        "extractor_model": model,
        "elapsed_sec": round(time.monotonic() - t0, 1),
    }
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--task-dir", required=True, type=Path)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--out-name", default="oracle_intents.json")
    ap.add_argument("--force", action="store_true", help="Re-extract even if cache exists")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    result = asyncio.run(extract_one(
        task_dir=args.task_dir.resolve(),
        model=args.model, out_name=args.out_name, force=args.force,
    ))
    print(json.dumps({
        "task": result["task"],
        "n_oracle_turns_in": result["n_oracle_turns_in"],
        "n_intents": len(result["intents"]),
        "model": result.get("extractor_model"),
        "elapsed_sec": result.get("elapsed_sec"),
        "preview": [
            {"id": i["intent_id"], "kind": i["intent_kind"], "text": i["text"][:80]}
            for i in result["intents"][:6]
        ],
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
