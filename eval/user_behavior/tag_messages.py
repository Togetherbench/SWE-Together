"""Message tagger — the production tagging step (Stage 3).

One judge call per trial (default Gemini-3.1-Pro):
  - tag-call (prompts/tag_messages_system.md) → per-message {tags, frustration}
written per trial_idx into intent_coverage_verdict.json :: trial_msg_tags.

trial_msg_tags drives the User Correction metric (user_metrics owns the weight):
  - User Correction = #correction + 0.2·#nudge   (user_metrics.user_correction)
It is derived (user_metrics.metrics_from_rows) and persisted into the verdict as
top-level user_correction — the same deriver eval/run_eval.py aggregates, so stored
and recomputed values can never diverge.

Reproducibility: pinned model @ temp 0, versioned prompt
(prompts/tag_messages_system.md), versioned taxonomy (user_metrics.py).

RUN WITH .venv/bin/python3 (bare python3 = anaconda, no harbor → silent crash).
"""
from __future__ import annotations
import argparse, asyncio, json, glob, os, sys
from pathlib import Path

_HERE = Path(__file__).resolve()
REPO = _HERE.parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "external" / "harbor" / "src"))
from eval.user_behavior.coverage_one import (   # noqa: E402
    _make_llm, load_dotenv, load_trial_sim_msgs, parse_json, DEFAULT_MODEL,
)
from eval.user_behavior import user_metrics as kg  # noqa: E402

TAG_SYS = (_HERE.parent / "prompts" / "tag_messages_system.md").read_text()    # tags + frustration


def _build_user(msgs) -> str:
    lines = [f'trial_idx={m["trial_idx"]}: {" ".join(m["text"].split())[:1000]}' for m in msgs]
    return "Messages:\n" + "\n".join(lines)


def _normalize(r: dict) -> dict | None:
    ti = r.get("trial_idx")
    if not isinstance(ti, int):
        return None
    tags = sorted({t for t in (r.get("tags") or []) if t in kg.ALL_TAGS})
    if not (set(tags) & kg.BASE):
        tags = sorted(set(tags) | {"request"})        # guarantee >=1 base act
    return {"trial_idx": ti, "tags": tags,
            "frustration": int(bool(r.get("frustration")))}


async def _ask(llm, system: str, user: str, attempts: int = 3) -> dict:
    """One judge call → {trial_idx: raw_row}. Retries transient parse/API failures."""
    for att in range(attempts):
        try:
            resp = await llm.call(system + "\n\n" + user)
            obj = parse_json(resp.content)
            return {r["trial_idx"]: r for r in obj.get("results", [])
                    if isinstance(r, dict) and isinstance(r.get("trial_idx"), int)}
        except Exception:
            if att == attempts - 1:
                raise
            await asyncio.sleep(4)


async def tag_one(llm, trial_dir: Path, task_dir: Path | None) -> list[dict]:
    """Tag every (non-instruction) sim message of one trial: one judge call →
    {tags, frustration} per message."""
    sim = load_trial_sim_msgs(trial_dir, task_dir)
    msgs = [m for m in sim if m["trial_idx"] != 0]
    if not msgs:
        return []
    user = _build_user(msgs)
    tag_rows = await _ask(llm, TAG_SYS, user)     # {trial_idx: {tags, frustration}}
    rows = []
    for m in msgs:
        i = m["trial_idx"]
        row = tag_rows.get(i) or {}
        nr = _normalize({"trial_idx": i, "tags": row.get("tags"),
                         "frustration": row.get("frustration")})
        if nr:
            rows.append(nr)
    return rows


def _resolve_dirs(verdict_path: str, verdict: dict):
    td = verdict.get("trial_dir")
    if not td or not os.path.isdir(td):
        td = os.path.dirname(verdict_path)
    tk = verdict.get("task_dir")
    if not tk or not os.path.isdir(tk):
        task = os.path.basename(os.path.dirname(verdict_path)).split("__")[0]
        cand = str(REPO / "tasks" / task)
        tk = cand if os.path.isdir(cand) else None
    return Path(td), (Path(tk) if tk else None)


async def _tag_into_verdict(llm, sem, vp: str, force: bool):
    async with sem:
        try:
            v = json.load(open(vp))
        except Exception:
            v = {}
        if v.get("trial_msg_tags") and not force:
            return "skip"
        try:
            rows = await tag_one(llm, *_resolve_dirs(vp, v))
        except Exception as e:
            return f"err: {type(e).__name__}: {e}"[:160]
        v["trial_msg_tags"] = rows
        m = kg.metrics_from_rows(rows)          # persist the derived User Correction metric
        v["user_correction"] = m["user_correction"]
        v.pop("user_effort", None)             # drop legacy effort field if present
        v.pop("trial_msg_specificity", None)   # drop the old single-label kind_hint/tier block
        json.dump(v, open(vp, "w"), ensure_ascii=False, indent=2)
        return "ok"


async def run_batch(trials_roots, model=DEFAULT_MODEL, workers=50, force=False):
    load_dotenv(REPO)
    if model.startswith("gemini/") and not os.environ.get("GEMINI_API_KEY"):
        sys.exit("!! GEMINI_API_KEY missing")
    vps = sorted(p for root in trials_roots
                 for p in glob.glob(f"{root}/*/intent_coverage_verdict.json"))
    llm = _make_llm(model, 0.0)
    sem = asyncio.Semaphore(workers)
    print(f"tagging {len(vps)} trials with {model}, workers={workers}", flush=True)
    res = {}
    B = 200
    for i in range(0, len(vps), B):
        out = await asyncio.gather(*[_tag_into_verdict(llm, sem, vp, force) for vp in vps[i:i+B]])
        for o in out:
            res[o.split(":")[0]] = res.get(o.split(":")[0], 0) + 1
        print(f"  {min(i+B,len(vps))}/{len(vps)}  {res}", flush=True)
    print(f"DONE {res}", flush=True)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials-root", action="append", required=True,
                    help="cohort dir(s) holding <trial>/intent_coverage_verdict.json")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--workers", type=int, default=50)
    ap.add_argument("--force", action="store_true", help="re-tag even if trial_msg_tags exists")
    a = ap.parse_args()
    asyncio.run(run_batch(a.trials_root, a.model, a.workers, a.force))


if __name__ == "__main__":
    main()
