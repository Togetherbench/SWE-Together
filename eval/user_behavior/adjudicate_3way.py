#!/usr/bin/env python3
"""Stage 3b — 3-way correction adjudication.

The single-pass Stage-3 tagger (Gemini) is one judge. This stage reconciles it
with two more so the correction/nudge labels (→ User Correction) aren't one
model's idiosyncrasy:

  Judge A = Gemini-3.1-Pro      (Stage 3, already in verdict.trial_msg_tags)
  Judge B = Claude Opus 4.6     (full second tagging, cached sidecar)
  Arbiter = GPT-5.5 (Codex)     (votes ONLY on messages where A and B disagree —
                                 if A==B the 2-judge majority already stands)

Reconciled label per message = A when A==B, else the Arbiter's call (majority of
the three). Writes `trial_msg_tags_3way` into each intent_coverage_verdict.json
and leaves the original `trial_msg_tags` (Gemini) untouched. User Correction /
User Effort (kind_groups) read trial_msg_tags_3way when present.

Judge B comes from a sidecar (pipeline_logs/adj_judgeB_<cohort>.json), produced
by the same multi-label tag prompt under a different model. The Arbiter (GPT-5.5)
is reached through the Codex OAuth proxy (oauth_proxy.py on :4220) since the
ChatGPT subscription's gpt-5.5 isn't on the platform API.

RUN WITH .venv/bin/python3. Requires the oauth_proxy running for the arbiter.
"""
from __future__ import annotations
import argparse, asyncio, glob, json, os, sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO)); sys.path.insert(0, str(REPO / "external" / "harbor" / "src"))
from eval.user_behavior.coverage_one import load_dotenv, load_trial_sim_msgs, parse_json  # noqa: E402

SYSTEM = (REPO / "eval" / "user_behavior" / "prompts" / "tag_messages_system.md").read_text()
VALID = {"request","question","verification","workflow","approval","context","correction","nudge"}
LAYERS = ("correction", "nudge")   # the labels User Correction depends on


def _build_user(msgs):
    return "Messages:\n" + "\n".join(
        f'trial_idx={m["trial_idx"]}: {" ".join(m["text"].split())[:1000]}' for m in msgs)


class ArbiterLLM:
    """GPT-5.5 via the local Codex-OAuth proxy. Minimal chat body (LiteLLM adds
    params the Responses backend rejects)."""
    def __init__(self, base: str, model: str):
        self.base = base.rstrip("/"); self.model = model
    async def tag(self, msgs):
        import httpx
        prompt = SYSTEM + "\n\n" + _build_user(msgs)
        async with httpx.AsyncClient(timeout=240.0) as c:
            r = await c.post(f"{self.base}/chat/completions",
                             json={"model": self.model,
                                   "messages": [{"role": "user", "content": prompt}]})
            r.raise_for_status()
            j = r.json()
            if "error" in j:
                raise RuntimeError(str(j["error"])[:160])
            obj = parse_json(j["choices"][0]["message"]["content"])
            return {rr["trial_idx"]: [t for t in (rr.get("tags") or []) if t in VALID]
                    for rr in obj.get("results", []) if isinstance(rr.get("trial_idx"), int)}


def _disputed(a_tags, b_tags):
    return any((lab in a_tags) != (lab in b_tags) for lab in LAYERS)


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--trials-root", action="append", required=True, type=Path)
    ap.add_argument("--judgeb-sidecar", required=True, help="pipeline_logs/adj_judgeB_<cohort>.json")
    ap.add_argument("--arbiter-model", default="gpt-5.5")
    ap.add_argument("--arbiter-proxy", default="http://127.0.0.1:4220/v1")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--out-field", default="trial_msg_tags_3way")
    args = ap.parse_args()
    load_dotenv(REPO)
    B = json.loads(Path(args.judgeb_sidecar).read_text())
    arb = ArbiterLLM(args.arbiter_proxy, args.arbiter_model)
    sem = asyncio.Semaphore(args.workers)

    # gather trials; mark which need the arbiter
    trials = []   # (vp, A:dict idx->tags, Bd:dict idx->tags, disputed_idxs, msgs)
    for root in args.trials_root:
        for vp in sorted(glob.glob(f"{root}/*/intent_coverage_verdict.json")):
            d = os.path.basename(os.path.dirname(vp))
            if d.startswith("INFRAFAIL"):
                continue
            v = json.load(open(vp))
            A = {r["trial_idx"]: list(r.get("tags", [])) for r in (v.get("trial_msg_tags") or [])}
            Bd = {int(k): t for k, t in (B.get(d) or {}).items() if str(k).lstrip("-").isdigit()}
            disp = [i for i in A if i in Bd and _disputed(set(A[i]), set(Bd[i]))]
            trials.append((vp, d, v, A, Bd, disp))

    need = [(vp, v, A, Bd, disp) for (vp, d, v, A, Bd, disp) in trials if disp]
    print(f"trials={len(trials)}  with A/B disputes (need arbiter)={len(need)}  arbiter={args.arbiter_model}", flush=True)

    async def arbitrate(v, A):
        async with sem:
            sim = load_trial_sim_msgs(Path(v.get("trial_dir") or "."), Path(v["task_dir"]) if v.get("task_dir") and os.path.isdir(v["task_dir"]) else None)
            msgs = [m for m in sim if m["trial_idx"] != 0]
            for att in range(3):
                try:
                    return await arb.tag(msgs)
                except Exception as e:
                    if att == 2:
                        return {"_err": str(e)[:120]}
                    await asyncio.sleep(5)

    arb_out = await asyncio.gather(*[arbitrate(v, A) for (_, v, A, _, _) in need])
    arb_by_vp = {need[i][0]: arb_out[i] for i in range(len(need))}

    errs = 0
    for vp, d, v, A, Bd, disp in trials:
        C = arb_by_vp.get(vp) or {}
        if "_err" in C:
            errs += 1; C = {}
        rows = []
        for r in (v.get("trial_msg_tags") or []):
            i = r["trial_idx"]; a = set(r.get("tags", [])); b = set(Bd.get(i, []))
            tags = set(a)
            for lab in LAYERS:
                if (lab in a) == (lab in b):
                    keep = lab in a                       # agreed
                else:
                    keep = lab in set(C.get(i, []))       # arbiter (majority)
                tags.discard(lab);
                if keep: tags.add(lab)
            rows.append({**r, "tags": sorted(tags)})
        v[args.out_field] = rows
        json.dump(v, open(vp, "w"), ensure_ascii=False, indent=2)
    print(f"wrote {args.out_field} to {len(trials)} verdicts (arbiter errors={errs})", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
