"""Multi-label message tagger — the production tagging step.

One Gemini call per trial → per-message {tags, frustration, tier}, written into
intent_coverage_verdict.json :: trial_msg_tags. Drives BOTH user axes:
  - User Correction = #correction + 0.2·#nudge   (kind_groups.user_correction)
  - User Effort      = Σ tier_weight over directives (kind_groups.user_effort)

Reproducibility: pinned gemini-3.1-pro-preview @ temp 0, versioned prompt
(prompts/tag_messages_system.md), versioned taxonomy (kind_groups.py).

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
from eval.user_behavior import kind_groups as kg  # noqa: E402

SYSTEM = (_HERE.parent / "prompts" / "tag_messages_system.md").read_text()
TIERS = set(kg.SPECIFICITY_WEIGHTS)


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
    tier = r.get("tier") if r.get("tier") in TIERS else "none"
    tier, _ = kg.expected_tier(tags, tier)             # force 'none' on non-directives
    return {"trial_idx": ti, "tags": tags,
            "frustration": int(bool(r.get("frustration"))), "tier": tier}


async def tag_one(llm, trial_dir: Path, task_dir: Path | None) -> list[dict]:
    """Tag every (non-instruction) sim message of one trial. Returns the rows."""
    sim = load_trial_sim_msgs(trial_dir, task_dir)
    msgs = [m for m in sim if m["trial_idx"] != 0]
    if not msgs:
        return []
    resp = await llm.call(SYSTEM + "\n\n" + _build_user(msgs))
    obj = parse_json(resp.content)
    rows = [x for x in (_normalize(r) for r in obj.get("results", []) if isinstance(r, dict)) if x]
    return rows


def _resolve_dirs(verdict_path: str, verdict: dict):
    td = verdict.get("trial_dir")
    if not td or not os.path.isdir(td):
        td = os.path.dirname(verdict_path)
    tk = verdict.get("task_dir")
    if not tk or not os.path.isdir(tk):
        task = os.path.basename(os.path.dirname(verdict_path)).split("__")[0]
        cand = str(REPO / "harbor_tasks" / task)
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
