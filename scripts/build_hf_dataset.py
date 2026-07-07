#!/usr/bin/env python3
"""Build a Hugging Face-loadable dataset from the SWE-Together `tasks/` tree.

Each task in `tasks/<name>/` is a Docker-backed, multi-turn coding session. The
heavy artifacts (environment image, verifier, user-sim prompts) stay in this
repo; this script distills the *metadata* into one flat row per task so the
benchmark is browsable in the HF dataset viewer and loadable programmatically:

    from datasets import load_dataset
    ds = load_dataset("yfwu/SWE-Together")            # 109 tasks, split="train"

Row extraction is stdlib-only; writing Parquet + the pushed artifact needs the
`datasets` / `huggingface_hub` libraries (see --push). Run it with an env that
has them (e.g. the project `.venv`).

    python scripts/build_hf_dataset.py                       # writes hf_dataset/
    python scripts/build_hf_dataset.py --push yfwu/SWE-Together
    python scripts/build_hf_dataset.py --push yfwu/SWE-Together --private
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TASKS_DIR = REPO_ROOT / "tasks"


# --------------------------------------------------------------------------- #
# Minimal TOML-subset parser (Python 3.9 has no tomllib).
# Handles the shapes task.toml actually uses: [section] / [a.b] headers,
# key = "str" | number | true/false | ["x", "y"]. Section-aware so the two
# distinct `timeout_sec` keys ([verifier] vs [agent]) don't collide.
# --------------------------------------------------------------------------- #
def parse_task_toml(text: str) -> dict:
    out: dict = {}
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            out.setdefault(section, {})
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        parsed = _parse_toml_value(val)
        if section:
            out.setdefault(section, {})[key] = parsed
        else:
            out[key] = parsed
    return out


def _parse_toml_value(val: str):
    if val.startswith("[") and val.endswith("]"):
        inner = val[1:-1].strip()
        if not inner:
            return []
        return [_parse_toml_value(x.strip()) for x in _split_top_commas(inner)]
    if len(val) >= 2 and val[0] in "\"'" and val[-1] == val[0]:
        return val[1:-1]
    if val in ("true", "false"):
        return val == "true"
    try:
        return int(val)
    except ValueError:
        pass
    try:
        return float(val)
    except ValueError:
        pass
    return val


def _split_top_commas(s: str) -> list[str]:
    parts, buf, depth, quote = [], [], 0, ""
    for ch in s:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
            buf.append(ch)
        elif ch in "[":
            depth += 1
            buf.append(ch)
        elif ch in "]":
            depth -= 1
            buf.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append("".join(buf))
    return parts


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def clean_repo_cell(cell: str) -> str:
    """'`banodoco/reigh` (30 stars)' -> 'banodoco/reigh'."""
    cell = cell.strip().strip("`").strip()
    cell = re.sub(r"\s*\(.*?\)\s*$", "", cell).strip()
    return cell


def readme_field(readme_text: str, field: str) -> str | None:
    # README tables are `| Field | Value |` rows.
    m = re.search(rf"\|\s*{re.escape(field)}\s*\|\s*([^\|\n]+?)\s*\|", readme_text)
    return m.group(1).strip() if m else None


def normalize_category(cat: str) -> str:
    return {
        "feature-implementation": "feature",
        "implementation": "feature",
        "refactoring": "refactor",
    }.get(cat, cat)


# --------------------------------------------------------------------------- #
# Per-task extraction
# --------------------------------------------------------------------------- #
def build_row(task_id: str) -> dict:
    d = TASKS_DIR / task_id
    toml = parse_task_toml((d / "task.toml").read_text())
    meta = toml.get("metadata", {})
    env = toml.get("environment", {})

    instruction = (d / "instruction.md").read_text().strip()
    ref = load_json(d / "reference_patch.json") or {}
    install = load_json(d / "tests" / "install_config.json")
    oracle = load_json(d / "oracle_intents.json") or {}
    goals = load_json(d / "canonical_goals.json") or {}
    manifest_text = ""
    mpath = d / "tests" / "test_manifest.yaml"
    if mpath.exists():
        manifest_text = mpath.read_text()
    readme_text = ""
    rpath = d / "README.md"
    if rpath.exists():
        readme_text = rpath.read_text()

    # repo / base_commit / url with layered fallbacks
    repo = ref.get("repo_id")
    if not repo and readme_text:
        cell = readme_field(readme_text, "Repo")
        if cell:
            repo = clean_repo_cell(cell)
    base_commit = ref.get("_base_commit") or (install or {}).get("commit_sha")
    if not base_commit and readme_text:
        cell = readme_field(readme_text, "Base commit")
        if cell:
            base_commit = cell.strip("`")
    repo_url = ref.get("_repo_url")
    if not repo_url and repo and "/" in repo:
        repo_url = f"https://github.com/{repo}"

    intents = oracle.get("intents", []) or []
    scoring_tier = "swerebench" if install else "legacy"

    row = {
        "task_id": task_id,
        "instruction": instruction,
        "repo": repo,
        "repo_url": repo_url,
        "base_commit": base_commit,
        "language": (install or {}).get("language"),
        "difficulty": meta.get("difficulty"),
        "category": normalize_category(meta.get("category", "")),
        "category_raw": meta.get("category"),
        "tags": [str(t) for t in (meta.get("tags") or [])],
        "scoring_tier": scoring_tier,
        "num_user_intents": len(intents),
        "expert_time_estimate_min": meta.get("expert_time_estimate_min"),
        "junior_time_estimate_min": meta.get("junior_time_estimate_min"),
        "agent_timeout_sec": toml.get("agent", {}).get("timeout_sec"),
        "docker_image": env.get("docker_image"),
        "allow_internet": env.get("allow_internet"),
        "cpus": env.get("cpus"),
        "memory": env.get("memory"),
        # SWE-rebench-tier scoring targets (empty for legacy-only tasks)
        "fail_to_pass": list((install or {}).get("FAIL_TO_PASS", []) or []),
        "pass_to_pass": list((install or {}).get("PASS_TO_PASS", []) or []),
        "test_cmd": (install or {}).get("test_cmd"),
        "log_parser": (install or {}).get("log_parser"),
        "source_files": list((install or {}).get("source_files", []) or []),
        # Reference (gold) patch reconstructed from the session
        "reference_patch": ref.get("patch") or "",
        "patch_files_changed": ref.get("files_changed_count"),
        "patch_additions": ref.get("total_additions"),
        "patch_deletions": ref.get("total_deletions"),
        "patch_is_agent_author": ref.get("is_agent_author"),
        # Rich multi-turn / rubric structures kept as JSON strings (heterogeneous)
        "oracle_intents": json.dumps(intents, ensure_ascii=False),
        "completeness_goals": json.dumps(
            goals.get("completeness_goals", []), ensure_ascii=False
        ),
        "test_manifest": manifest_text,
        "session_id": ref.get("session_id") or oracle.get("task"),
    }
    return row


def build_all() -> list[dict]:
    tasks = sorted(
        p.name for p in TASKS_DIR.iterdir() if p.is_dir() and (p / "task.toml").exists()
    )
    rows = [build_row(t) for t in tasks]
    return rows


def hf_features():
    """Explicit schema so empty list columns (e.g. all-empty `pass_to_pass`)
    don't infer to `list<null>`, and the type is stable across rebuilds."""
    from datasets import Features, Sequence, Value

    S = Value("string")
    str_list = Sequence(S)
    return Features({
        "task_id": S, "instruction": S, "repo": S, "repo_url": S,
        "base_commit": S, "language": S, "difficulty": S, "category": S,
        "category_raw": S, "tags": str_list, "scoring_tier": S,
        "num_user_intents": Value("int64"),
        "expert_time_estimate_min": Value("float64"),
        "junior_time_estimate_min": Value("float64"),
        "agent_timeout_sec": Value("float64"),
        "docker_image": S, "allow_internet": Value("bool"),
        "cpus": Value("int64"), "memory": S,
        "fail_to_pass": str_list, "pass_to_pass": str_list,
        "test_cmd": S, "log_parser": S, "source_files": str_list,
        "reference_patch": S,
        "patch_files_changed": Value("int64"),
        "patch_additions": Value("int64"),
        "patch_deletions": Value("int64"),
        "patch_is_agent_author": Value("bool"),
        "oracle_intents": S, "completeness_goals": S,
        "test_manifest": S, "session_id": S,
    })


# --------------------------------------------------------------------------- #
# Coverage report
# --------------------------------------------------------------------------- #
def report(rows: list[dict]) -> None:
    from collections import Counter

    n = len(rows)
    def cov(key):
        return sum(1 for r in rows if r.get(key) not in (None, "", []))

    print(f"\n  {n} tasks")
    print(f"  repo:          {cov('repo')}/{n}")
    print(f"  base_commit:   {cov('base_commit')}/{n}")
    print(f"  reference_patch:{cov('reference_patch')}/{n}")
    print(f"  language:      {cov('language')}/{n}")
    print(f"  tier:          {dict(Counter(r['scoring_tier'] for r in rows))}")
    print(f"  difficulty:    {dict(Counter(r['difficulty'] for r in rows))}")
    print(f"  category:      {dict(Counter(r['category'] for r in rows))}")
    print(f"  distinct repos:{len({r['repo'] for r in rows if r['repo']})}")


# --------------------------------------------------------------------------- #
# Dataset card
# --------------------------------------------------------------------------- #
def dataset_card(rows: list[dict], repo_id: str) -> str:
    from collections import Counter

    n = len(rows)
    tiers = Counter(r["scoring_tier"] for r in rows)
    langs = Counter(r["language"] for r in rows if r["language"])
    diffs = Counter(r["difficulty"] for r in rows if r["difficulty"])
    n_repos = len({r["repo"] for r in rows if r["repo"]})
    diff_rows = "\n".join(
        f"| {k} | {v} |" for k, v in sorted(diffs.items(), key=lambda x: -x[1])
    )
    lang_rows = "\n".join(
        f"| {k} | {v} |" for k, v in sorted(langs.items(), key=lambda x: -x[1])
    )
    return f"""---
license: apache-2.0
task_categories:
  - text-generation
tags:
  - code
  - swe
  - agents
  - coding-agents
  - multi-turn
  - benchmark
pretty_name: SWE-Together
size_categories:
  - n<1K
configs:
  - config_name: default
    data_files:
      - split: test
        path: data/test-*.parquet
---

# SWE-Together

**SWE-Together: Evaluating Coding Agents in Interactive User Sessions.**

SWE-Together reconstructs the multi-turn loop from real user–agent coding
sessions, replaying each with a reactive **user simulator** that asks
questions, adds requirements, and pushes back — preserving the original
user's intent. This dataset holds the **{n} discriminating tasks** of the
canonical suite as one metadata row per task.

- 📄 Paper: https://huggingface.co/papers/2606.29957
- 🌐 Website: https://togetherbench.com
- 💻 Code + Docker environments + verifiers: https://github.com/Togetherbench/SWE-Together
- 🔎 Trace viewer: https://traces.togetherbench.com/jobs/trials

```python
from datasets import load_dataset

ds = load_dataset("{repo_id}", split="test")
print(ds[0]["instruction"])   # the real user's first message, verbatim
```

## What each row is

A task is a first user message plus a **replayable, containerized interaction**.
The heavy artifacts — the environment image, the deterministic verifier, and the
user-simulator prompts — live in the [GitHub repo](https://github.com/Togetherbench/SWE-Together)
under `tasks/<task_id>/`. Each row here distills that task's metadata so it is
browsable and loadable; `docker_image` and `task_id` point back to the full task.

## Fields

| Field | Type | Description |
|---|---|---|
| `task_id` | string | Task folder name; key into `tasks/<task_id>/` in the GitHub repo. |
| `instruction` | string | The real user's **first message**, verbatim (what the agent reads). |
| `repo` | string | Upstream GitHub repo the session was on (`owner/name`), when known. |
| `repo_url` | string | URL of that repo, when known. |
| `base_commit` | string | Commit the environment is built from, when known. |
| `language` | string | Primary language (SWE-rebench-tier tasks). |
| `difficulty` | string | `easy` / `medium` / `hard`. |
| `category` | string | `feature` / `bugfix` / `refactor`. |
| `tags` | list[string] | Free-form task tags. |
| `scoring_tier` | string | `swerebench` (log-parser + `FAIL_TO_PASS`) or `legacy` (weighted F2P/P2P gates). |
| `num_user_intents` | int | Distinct user intents across the session (turns that carry a request/question). |
| `expert_time_estimate_min` | float | Human expert time estimate. |
| `junior_time_estimate_min` | float | Human junior time estimate. |
| `agent_timeout_sec` | float | Per-trial agent timeout. |
| `docker_image` | string | The task's environment image (`ghcr.io/togetherbench/...`). |
| `allow_internet`, `cpus`, `memory` | — | Sandbox resource policy. |
| `fail_to_pass`, `pass_to_pass` | list[string] | Test targets (SWE-rebench tier). |
| `test_cmd`, `log_parser` | string | Verifier command + parser (SWE-rebench tier). |
| `source_files` | list[string] | Files the reference change touches (SWE-rebench tier). |
| `reference_patch` | string | Gold patch (unified diff) reconstructed from the session, when available. |
| `patch_files_changed`, `patch_additions`, `patch_deletions` | int | Diff stats for the reference patch. |
| `oracle_intents` | string (JSON) | Ordered user intents `[{{intent_id, source_turn, intent_kind, text, verbatim_excerpt}}]` driving the multi-turn loop. |
| `completeness_goals` | string (JSON) | Judge rubric goals for the agentic correctness score. |
| `test_manifest` | string (YAML) | Legacy-tier F2P/P2P scoring gates and weights. |
| `session_id` | string | Source session identifier (provenance). |

## Suite at a glance

- **{n} tasks**, **{n_repos} distinct repositories**.
- Scoring tiers: {", ".join(f"`{k}` ({v})" for k, v in tiers.items())}.

| Difficulty | Tasks |
|---|---:|
{diff_rows}

| Language (SWE-rebench tier) | Tasks |
|---|---:|
{lang_rows}

## Running the benchmark

This table is for browsing and programmatic access. To actually **run** a coding
agent against a task (with the user simulator and the deterministic verifier),
use the harness in the GitHub repo:

```bash
git clone https://github.com/Togetherbench/SWE-Together
cd SWE-Together && uv sync
.venv/bin/python launch.py canonical_full109.json --stage run --models opencode_opus48 --execute
```

## Citation

```bibtex
@misc{{swetogether2026,
  title  = {{SWE-Together: Evaluating Coding Agents in Interactive User Sessions}},
  author = {{Wu, Yifan and others}},
  year   = {{2026}},
  url    = {{https://togetherbench.com}}
}}
```

## License

Released under the Apache-2.0 license, matching the
[source repository](https://github.com/Togetherbench/SWE-Together). Task content
derives from public repositories; each task records its upstream `repo`/`repo_url`.
"""


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(REPO_ROOT / "hf_dataset"),
                    help="output directory (default: ./hf_dataset)")
    ap.add_argument("--push", metavar="REPO_ID", default=None,
                    help="also push to this HF dataset repo, e.g. yfwu/SWE-Together")
    ap.add_argument("--private", action="store_true",
                    help="create the HF repo as private (default: public)")
    args = ap.parse_args()

    rows = build_all()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # Human-readable snapshot (git-friendly, diffable).
    jsonl_path = out / "swe_together.jsonl"
    with jsonl_path.open("w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    repo_id = args.push or "yfwu/SWE-Together"
    card_path = out / "README.md"
    card_path.write_text(dataset_card(rows, repo_id))

    report(rows)
    print(f"\n  wrote {jsonl_path}  ({jsonl_path.stat().st_size/1024:.0f} KB)")
    print(f"  wrote {card_path}")

    # Typed Parquet — the canonical artifact the dataset card points at.
    try:
        from datasets import Dataset
    except ImportError:
        print("\n  (datasets not importable — skipped Parquet; JSONL + card written)")
        if args.push:
            print("  --push needs `datasets` + `huggingface_hub`.", file=sys.stderr)
            return 1
        return 0

    ds = Dataset.from_list(rows, features=hf_features())
    parquet_path = out / "data" / "test-00000-of-00001.parquet"
    parquet_path.parent.mkdir(parents=True, exist_ok=True)
    ds.to_parquet(str(parquet_path))
    print(f"  wrote {parquet_path}  ({parquet_path.stat().st_size/1024:.0f} KB)")

    if args.push:
        from huggingface_hub import HfApi

        api = HfApi()
        api.create_repo(repo_id=args.push, repo_type="dataset",
                        private=args.private, exist_ok=True)
        api.upload_folder(
            folder_path=str(out), repo_id=args.push, repo_type="dataset",
            commit_message="Add SWE-Together benchmark tasks",
        )
        print(f"\n  pushed → https://huggingface.co/datasets/{args.push}")
    else:
        print(f"\n  to publish:  python {Path(__file__).name} --push {repo_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
