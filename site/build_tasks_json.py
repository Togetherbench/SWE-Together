#!/usr/bin/env python3
"""Build site/tasks.js (+ tasks.json) from the canonical lite70 task set.

Task list:  scripts/canonical_plan_lite70.json
Per-task metadata, in priority order of reliability:
  - oracle_session.jsonl  header  -> repo_url, base_commit, change stats  (all 70)
  - canonical_goals.json          -> completeness goals + tiers/weights    (all 70)
  - oracle_intents.json           -> the multi-turn user correction loop   (most)
  - task.toml                     -> difficulty / category / tags / time   (all 70)
  - README.md  ## Summary / ## Task Summary -> human blurb                 (~31)

Output:
  site/tasks.js   -> `window.SUITE = {...}; window.TASKS = [...];`
  site/tasks.json -> {suite, tasks}
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / "scripts" / "canonical_plan_lite70.json"
TASKS_DIR = ROOT / "harbor_tasks"
OUT_DIR = Path(__file__).resolve().parent

LANGS = ["python", "go", "golang", "rust", "typescript", "javascript", "tsx",
         "c++", "cpp", "cuda", "java", "kotlin", "swift", "ruby", "shell",
         "bash", "triton", "html", "css", "c"]
LANG_LABEL = {"go": "Go", "golang": "Go", "python": "Python", "rust": "Rust",
              "typescript": "TypeScript", "tsx": "TypeScript", "javascript": "JavaScript",
              "cpp": "C++", "c++": "C++", "c": "C", "cuda": "CUDA", "java": "Java",
              "kotlin": "Kotlin", "swift": "Swift", "ruby": "Ruby", "shell": "Shell",
              "bash": "Shell", "triton": "Triton", "html": "HTML", "css": "CSS"}

TITLE_PREFIXES = [
    "the user wants to ", "the user wants ", "the user would like to ",
    "the user has requested to ", "the user has ", "the user is asking to ",
    "the user is ", "the user needs to ", "the user requests ", "the user ",
    "the agent needs to ", "the agent must ", "the task is to ", "we need to ",
    "this task ", "implement support for ", "add support to ", "add support for ",
]


def squash(text: str) -> str:
    return " ".join((text or "").split())


def first_sentence(text: str, limit: int = 170) -> str:
    text = squash(text)
    m = re.search(r"(.+?[.!?])(\s|$)", text)
    s = m.group(1) if m else text
    if len(s) > limit:
        s = s[: limit - 1].rsplit(" ", 1)[0].rstrip() + "…"
    return s


def is_hashy(slug: str) -> bool:
    return bool(re.search(r"-(task|implement|auto)-[0-9a-f]{6,}$", slug)) or \
        bool(re.search(r"-[0-9a-f]{8,}$", slug)) or bool(re.search(r"-\d{3,}$", slug))


def prettify_slug(slug: str) -> str:
    parts = [p for p in slug.split("-") if not re.fullmatch(r"[0-9a-f]{6,}", p)]
    parts = [p for p in parts if p not in ("task", "implement", "auto")]
    return " ".join(w[:1].upper() + w[1:] for w in (parts or slug.split("-")))


def derive_title(slug: str, source: str) -> str:
    if not squash(source):
        return prettify_slug(slug)
    s = first_sentence(source, limit=999).rstrip("…").strip()
    # Drop a leading subordinate clause: "In X, " / "When X, " / "At X, " / "For X, "
    m = re.match(r"(?i)^(in|when|at|for|after|once|currently|because|since)\b[^,]{0,55},\s+(.+)$", s)
    if m:
        s = m.group(2)
    low = s.lower()
    for p in TITLE_PREFIXES:
        if low.startswith(p):
            s = s[len(p):]
            break
    s = s.strip().rstrip(".")
    if not s:
        return prettify_slug(slug)
    if len(s) > 70:
        s = s[:70].rsplit(" ", 1)[0].rstrip() + "…"
    return s[:1].upper() + s[1:]


def parse_readme_summary(text: str) -> str:
    for head in ("Task Summary", "Summary"):
        m = re.search(rf"##\s*{head}\s*\n+(.+?)(?:\n##\s|\Z)", text, re.S)
        if m:
            body = m.group(1).strip()
            # First paragraph (stop at a numbered/bulleted list or blank line block).
            para = re.split(r"\n\s*\n|\n\s*[-*\d]", body)[0]
            return squash(para)
    return ""


def parse_readme_repo(text: str) -> tuple[str | None, int | None]:
    m = re.search(r"^\|\s*Repo\s*\|\s*(.+?)\s*\|\s*$", text, re.M)
    if not m:
        return None, None
    val = m.group(1).strip().strip("`")
    stars = None
    sm = re.search(r"\(([\d,]+)\s*stars?\)", val)
    if sm:
        stars = int(sm.group(1).replace(",", ""))
    val = re.sub(r"\s*\([^)]*\)\s*$", "", val).strip().strip("`")
    return (val or None), stars


def repo_from_url(url: str | None) -> str | None:
    if not url:
        return None
    m = re.search(r"github\.com[/:]+([^/]+/[^/.\s]+)", url)
    return m.group(1) if m else None


def pick_language(tags: list[str]) -> str | None:
    low = [t.lower() for t in tags]
    for lang in LANGS:
        if lang in low:
            return LANG_LABEL.get(lang, lang.capitalize())
    return None


def read_header(d: Path) -> dict:
    p = d / "oracle_session.jsonl"
    if not p.exists():
        return {}
    try:
        with p.open() as fh:
            return json.loads(fh.readline())
    except Exception:  # noqa: BLE001
        return {}


def read_session_minutes(d: Path):
    """Wall-clock duration of the original session = last - first message timestamp."""
    p = d / "original_session.json"
    if not p.exists():
        return None
    try:
        msgs = json.loads(p.read_text()).get("messages", [])
    except Exception:  # noqa: BLE001
        return None
    ts = []
    for m in msgs:
        t = m.get("timestamp")
        if not t:
            continue
        try:
            ts.append(datetime.fromisoformat(str(t).replace("Z", "+00:00")))
        except Exception:  # noqa: BLE001
            pass
    if len(ts) < 2:
        return None
    return round((max(ts) - min(ts)).total_seconds() / 60)


def read_intents(d: Path, cap: int = 12) -> list[dict]:
    p = d / "oracle_intents.json"
    if not p.exists():
        return []
    try:
        intents = json.loads(p.read_text()).get("intents", [])
    except Exception:  # noqa: BLE001
        return []
    out = []
    for it in intents[:cap]:
        out.append({
            "kind": it.get("intent_kind"),
            "text": squash(it.get("text", "")),
            "quote": squash(it.get("verbatim_excerpt", "")),
        })
    return out


def load_task(slug: str) -> dict:
    d = TASKS_DIR / slug
    rec: dict = {"name": slug}

    # task.toml
    meta = {}
    tp = d / "task.toml"
    if tp.exists():
        try:
            meta = tomllib.loads(tp.read_text()).get("metadata", {})
        except Exception as e:  # noqa: BLE001
            print(f"  ! toml {slug}: {e}", file=sys.stderr)
    tags = list(meta.get("tags", []) or [])
    rec.update(category=meta.get("category"), difficulty=meta.get("difficulty"),
               tags=tags, language=pick_language(tags),
               expert_min=meta.get("expert_time_estimate_min"),
               junior_min=meta.get("junior_time_estimate_min"),
               session_min=read_session_minutes(d))

    # oracle header (canonical repo + change stats)
    hdr = read_header(d)
    repo = repo_from_url(hdr.get("_repo_url"))
    base = hdr.get("_base_commit")
    rec["repo_url"] = hdr.get("_repo_url")
    rec["base_commit"] = base[:10] if base else None
    rec["files_changed"] = hdr.get("files_changed_count")
    rec["additions"] = hdr.get("total_additions")
    rec["deletions"] = hdr.get("total_deletions")

    # README (repo+stars fallback, human summary)
    readme = (d / "README.md").read_text() if (d / "README.md").exists() else ""
    r_repo, stars = parse_readme_repo(readme)
    rec["repo"] = repo or r_repo
    rec["stars"] = stars
    summary = parse_readme_summary(readme)

    # goals
    goals = []
    gp = d / "canonical_goals.json"
    if gp.exists():
        try:
            goals = json.loads(gp.read_text()).get("completeness_goals", [])
        except Exception:  # noqa: BLE001
            goals = []
    rec["goals"] = [{"goal": squash(g.get("goal", "")), "tier": g.get("tier"),
                     "weight": g.get("weight")} for g in goals]
    rec["n_goals"] = len(goals)
    rec["goal_tiers"] = dict(Counter(g.get("tier") for g in goals))

    # blurb: README summary -> first core goal -> first goal
    if not summary and goals:
        core = next((g for g in goals if g.get("tier") == "core"), goals[0])
        summary = core.get("goal", "")
    rec["summary"] = summary
    rec["blurb"] = first_sentence(summary)
    # Title from the action: hashy slugs -> first core goal; else prettified slug.
    core = next((g.get("goal", "") for g in goals if g.get("tier") == "core"),
                goals[0].get("goal", "") if goals else "")
    rec["title"] = derive_title(slug, core or summary)

    # multi-turn correction loop
    intents = read_intents(d)
    rec["intents"] = intents
    rec["n_intents"] = len(intents)
    return rec


def main() -> int:
    plan = json.loads(PLAN.read_text())
    slugs = plan["tasks"]
    models = plan.get("models", {})

    tasks, missing = [], []
    for slug in slugs:
        (tasks.append(load_task(slug)) if (TASKS_DIR / slug).exists()
         else missing.append(slug))
    if missing:
        print(f"WARNING missing dirs: {missing}", file=sys.stderr)

    repos = {t["repo"] for t in tasks if t.get("repo")}
    cats = Counter(t["category"] for t in tasks if t.get("category"))
    diffs = Counter(t["difficulty"] for t in tasks if t.get("difficulty"))
    langs = Counter(t["language"] for t in tasks if t.get("language"))
    total_turns = sum(t["n_intents"] for t in tasks)

    def model_label(m: str) -> str:
        m = m.split("/")[-1]
        return {"claude-opus-4-6": "Claude Opus 4.6", "deepseek-v4-pro": "DeepSeek V4 Pro",
                "gpt-5.5": "GPT-5.5"}.get(m, m)

    agent_label = {"mini-swe-agent": "mini-swe-agent", "opencode": "OpenCode"}
    cohorts, model_set = [], set()
    for key, cfg in models.items():
        ml = model_label(cfg.get("model", ""))
        cohorts.append({"key": key, "agent": agent_label.get(cfg.get("agent_type"),
                        cfg.get("agent_type")), "model": ml})
        model_set.add(ml)

    suite = {
        "name": plan.get("name", "lite70"),
        "n_tasks": len(tasks), "n_repos": len(repos), "n_cohorts": len(cohorts),
        "n_models": len(model_set), "n_replicates": len(plan.get("replicates", [])) or None,
        "n_user_turns": total_turns,
        "categories": dict(cats.most_common()), "difficulties": dict(diffs.most_common()),
        "languages": dict(langs.most_common()),
        "cohorts": cohorts,
        "models": sorted(model_set), "agents": sorted({c["agent"] for c in cohorts}),
    }
    payload = {"suite": suite, "tasks": tasks}

    (OUT_DIR / "tasks.json").write_text(json.dumps(payload, indent=2))
    (OUT_DIR / "tasks.js").write_text(
        "// Auto-generated by build_tasks_json.py — do not edit by hand.\n"
        f"window.SUITE = {json.dumps(suite)};\n"
        f"window.TASKS = {json.dumps(tasks)};\n")

    print(f"Wrote {len(tasks)} tasks -> site/tasks.js + tasks.json")
    print(f"  repos={len(repos)} langs={dict(langs)} diffs={dict(diffs)} turns={total_turns}")
    no_repo = [t['name'] for t in tasks if not t.get('repo')]
    if no_repo:
        print(f"  no-repo: {no_repo}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
