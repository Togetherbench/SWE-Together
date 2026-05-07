#!/usr/bin/env python3
"""Step 1: deterministic fetch + Stage-0 filter for the screening pipeline.

Single entry point covering both upstream sources. Both paths emit the SAME
JSON schema so downstream Step 2/3 (`step2_screen_with_llm.py`,
`screen_with_openai.py`) run unchanged.

Usage:
    # DataClaw (32 HF datasets — `peteromallet/dataclaw-peteromallet`, etc.)
    python data-pipeline/screening/scripts/step1_collect.py --source dataclaw \\
        [--min-stars 20] [--skip-stars]

    # SWE-chat (single HF dataset SALT-NLP/SWE-chat)
    python data-pipeline/screening/scripts/step1_collect.py --source swechat \\
        [--min-stars 20] [--per-repo-cap 5] [--limit N]

Outputs (default — when --out-dir not set):
    data-pipeline/screening/scripts/new_dataclaw/all_sessions.json + candidates.json + sessions_with_popular_repos.json   (--source dataclaw)
    data-pipeline/screening/scripts/swechat/all_sessions.json    + candidates.json                                         (--source swechat)

History: this file consolidates the Stage-0 logic from
`fetch_new_dataclaw_v2.py` (v0.4.3 selection driver) plus the SWE-chat
parquet path. The legacy `fetch_new_dataclaw_v2.py` was removed once this
became the canonical entry point.
"""

import argparse
import asyncio
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).parent

# ──────────────────────────────────────────────────────────────────────────
# DataClaw config
# ──────────────────────────────────────────────────────────────────────────

DC_OUTPUT_DIR = ROOT / "new_dataclaw"
DC_OUTPUT_JSON = DC_OUTPUT_DIR / "all_sessions.json"
DC_OUTPUT_CANDIDATES = DC_OUTPUT_DIR / "candidates.json"
DC_OUTPUT_POPULAR = DC_OUTPUT_DIR / "sessions_with_popular_repos.json"
STARS_CACHE_PATH = ROOT / "github_stars_cache.json"

DATACLAW_DATASETS = [
    # Unique datasets (different donors or new data)
    ("misterkerns/my-personal-claude-code-data", "misterkerns"),
    ("REXX-NEW/my-personal-claude-code-data", "REXX-NEW"),
    ("REXX-NEW/my-personal-codex-data", "REXX-NEW"),
    ("emperorfutures/dataclaw-code2", "emperorfutures"),
    ("DJTRIXUK/dataclaw-DJTRIXUK", "DJTRIXUK"),
    ("woctordho/dataclaw-windows", "woctordho"),
    ("peteromallet/my-personal-codex-data", "peteromallet"),
    ("akenove/my-personal-codex-data", "akenove"),
    ("michaelwaves/my-personal-codex-data", "michaelwaves"),
    ("introvoyz041/my-personal-codex-data", "introvoyz041"),
    ("gutenbergpbc/john-masterclass-cc", "gutenbergpbc"),
    ("MRiabov/dataclaw-march-26", "MRiabov"),
    ("nixjoe/nes-cpu", "nixjoe"),
    ("nixjoe/new-cpu-260308", "nixjoe"),
    ("nixjoe/new-cpu-260310", "nixjoe"),
    ("nixjoe/vue2egg-260310", "nixjoe"),
    ("nixjoe/nes-cpu-260316", "nixjoe"),
    # Existing donors — datasets we already downloaded but may have more sessions
    ("peteromallet/dataclaw-peteromallet", "peteromallet"),
    ("woctordho/dataclaw", "woctordho"),
    ("Batman787/dataclaw-Batman787", "Batman787"),
    ("sunsun123new/dataclaw-sunsun123new", "sunsun123new"),
    ("GolienHzmsr/dataclaw-GolienHzmsr", "GolienHzmsr"),
    ("tillg/dataclaw-tillg", "tillg"),
    ("parani01/dataclaw-parani01", "parani01"),
    ("zhiyaowang/dataclaw-zhiyaowang", "zhiyaowang"),
    ("vaynelee/dataclaw-vaynelee", "vaynelee"),
    ("GazTrab/dataclaw-GazTrab", "GazTrab"),
    # Forks that might have different data (non-549 row counts)
    ("leoikin/dataclaw-peteromallet", "leoikin"),
    ("Codingxx/dataclaw-peteromallet", "Codingxx"),
    ("Edmon02/dataclaw-peteromallet", "Edmon02"),
    ("ajdriscod/dataclaw-peteromallet", "ajdriscod"),
]

GITHUB_REPO_RE = re.compile(
    r'(?:https?://)?github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)',
    re.IGNORECASE,
)
GH_REPO_FLAG_RE = re.compile(
    r'gh\s+\S+.*?--repo\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)',
    re.IGNORECASE,
)
GIT_REMOTE_ADD_RE = re.compile(
    r'git\s+remote\s+(?:add|set-url)\s+\S+\s+(?:https?://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)',
    re.IGNORECASE,
)


# ──────────────────────────────────────────────────────────────────────────
# DataClaw helpers
# ──────────────────────────────────────────────────────────────────────────

def _dc_load_existing_session_ids() -> set:
    """Skip sessions already in sessions_raw/ or the prior popular index."""
    ids = set()
    sessions_dir = ROOT / "sessions_raw"
    if sessions_dir.exists():
        for f in sessions_dir.glob("*.json"):
            ids.add(f.stem)
    if DC_OUTPUT_POPULAR.exists():
        with open(DC_OUTPUT_POPULAR) as f:
            for entry in json.load(f):
                ids.add(entry["session_id"])
    return ids


def _dc_download_dataset(hf_repo: str) -> list:
    """Download a dataclaw dataset and return list of sessions."""
    from huggingface_hub import HfApi, hf_hub_download

    api = HfApi()
    try:
        files = list(api.list_repo_files(hf_repo, repo_type="dataset"))
    except Exception as e:
        print(f"  ERROR listing files: {e}")
        return []

    sessions: list = []
    jsonl_files = [f for f in files if f.endswith(".jsonl")]
    json_files = [f for f in files if f.endswith(".json") and f != "metadata.json"]
    parquet_files = [f for f in files if f.endswith(".parquet")]

    if jsonl_files:
        for jf in jsonl_files:
            try:
                path = hf_hub_download(hf_repo, jf, repo_type="dataset")
                with open(path) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            sessions.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
                print(f"  Loaded {len(sessions)} sessions from {jf}")
            except Exception as e:
                print(f"  ERROR downloading {jf}: {e}")
    elif json_files:
        for jf in json_files:
            try:
                path = hf_hub_download(hf_repo, jf, repo_type="dataset")
                with open(path) as f:
                    data = json.load(f)
                if isinstance(data, list):
                    sessions.extend(data)
                elif isinstance(data, dict):
                    sessions.append(data)
                print(f"  Loaded {len(sessions)} sessions from {jf}")
            except Exception as e:
                print(f"  ERROR downloading {jf}: {e}")
    elif parquet_files:
        for pf in parquet_files:
            try:
                path = hf_hub_download(hf_repo, pf, repo_type="dataset")
                import pyarrow.parquet as pq

                table = pq.read_table(path)
                df = table.to_pandas()
                for _, row in df.iterrows():
                    sessions.append(row.to_dict())
                print(f"  Loaded {len(sessions)} sessions from {pf}")
            except Exception as e:
                print(f"  ERROR downloading {pf}: {e}")
    else:
        print(f"  No data files found in {files}")

    return sessions


def _dc_extract_github_repos_from_text(text: str) -> set:
    repos = set()
    for match in GITHUB_REPO_RE.finditer(text):
        repo = match.group(1).rstrip("/").rstrip(".git")
        if "/" in repo and not any(x in repo for x in ["settings", "user-attachments", "orgs/"]):
            repos.add(repo)
    return repos


def _dc_extract_github_repos(session: dict) -> set:
    """Extract GitHub repo references from a session.

    Priority:
    1. gh CLI --repo flag in bash commands (exact owner/repo)
    2. git remote add/set-url commands
    3. github.com URLs in messages, tool inputs, tool outputs
    """
    repos = set()
    messages = session.get("messages", [])
    if isinstance(messages, str):
        try:
            messages = json.loads(messages)
        except Exception:
            messages = []

    for msg in messages:
        if not isinstance(msg, dict):
            continue

        content = msg.get("content", "")
        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict):
                    text_parts.append(str(block.get("text", "")))
                    inp = block.get("input", {})
                    if isinstance(inp, dict):
                        for k in ("command", "file_path", "path", "url"):
                            text_parts.append(str(inp.get(k, "")))
                    else:
                        text_parts.append(str(inp))
            content = " ".join(text_parts)
        content = str(content)

        for match in GH_REPO_FLAG_RE.finditer(content):
            repos.add(match.group(1).rstrip("/"))
        for match in GIT_REMOTE_ADD_RE.finditer(content):
            repos.add(match.group(1).rstrip("/").rstrip(".git"))
        repos.update(_dc_extract_github_repos_from_text(content))

        for tu in msg.get("tool_uses", []) or []:
            if not isinstance(tu, dict):
                continue
            inp = tu.get("input", "")
            inp_str = str(inp)
            for match in GH_REPO_FLAG_RE.finditer(inp_str):
                repos.add(match.group(1).rstrip("/"))
            for match in GIT_REMOTE_ADD_RE.finditer(inp_str):
                repos.add(match.group(1).rstrip("/").rstrip(".git"))
            repos.update(_dc_extract_github_repos_from_text(inp_str))

            output = tu.get("output", "")
            if output:
                out_str = str(output)[:5000]
                repos.update(_dc_extract_github_repos_from_text(out_str))
                for match in GH_REPO_FLAG_RE.finditer(out_str):
                    repos.add(match.group(1).rstrip("/"))

    return repos


def _dc_extract_project_name(session: dict) -> str:
    project = session.get("project", "")
    if not project:
        return ""
    project = project.lstrip("~").strip("/")
    if project.startswith("codex:"):
        project = project[6:]
    return project


def _dc_is_auto_generated(content: str) -> bool:
    if not content or not content.strip():
        return True
    s = content.strip()
    if re.match(r'^<[a-z]', s):
        return True
    if s.startswith("This session is being continued from a previous conversation"):
        return True
    if s.startswith("Base directory for this skill:"):
        return True
    if "[Request interrupted by user]" in s:
        return True
    return False


def _dc_is_cjk(ch: str) -> bool:
    try:
        name = unicodedata.name(ch, "")
    except ValueError:
        return False
    return any(k in name for k in ("CJK", "HANGUL", "HIRAGANA", "KATAKANA", "IDEOGRAPH"))


def _dc_detect_non_english(user_msgs: list, threshold: float = 0.3) -> bool:
    sample = " ".join(user_msgs[:5])
    if not sample:
        return False
    cjk_count = sum(1 for ch in sample if _dc_is_cjk(ch))
    alpha_count = sum(1 for ch in sample if ch.isalpha())
    if alpha_count == 0:
        return False
    return cjk_count / alpha_count > threshold


def _dc_screen_session(session: dict, donor: str, hf_repo: str) -> dict:
    """Apply Stage-0 deterministic checks to one DataClaw session."""
    messages = session.get("messages", [])
    if isinstance(messages, str):
        try:
            messages = json.loads(messages)
        except Exception:
            messages = []

    stats = session.get("stats", {})
    if isinstance(stats, str):
        try:
            stats = json.loads(stats)
        except Exception:
            stats = {}

    sid = session.get("session_id", session.get("id", ""))

    user_msgs = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        if m.get("role") != "user":
            continue
        content = m.get("content", "")
        if isinstance(content, list):
            content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
        if not content or _dc_is_auto_generated(content):
            continue
        user_msgs.append(content.strip())

    tool_counts = defaultdict(int)
    for m in messages:
        if not isinstance(m, dict):
            continue
        for tu in m.get("tool_uses", []) or []:
            if isinstance(tu, dict):
                tool_counts[tu.get("tool", "unknown")] += 1
        content = m.get("content", "")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    tool_counts[block.get("name", "unknown")] += 1

    github_repos = _dc_extract_github_repos(session)
    project_name = _dc_extract_project_name(session)
    is_non_english = _dc_detect_non_english(user_msgs)

    return {
        "session_id": sid,
        "donor": donor,
        "hf_repo": hf_repo,
        "model": session.get("model", ""),
        "project": session.get("project", ""),
        "project_name": project_name,
        "start_time": session.get("start_time", ""),
        "n_messages": len(messages),
        "genuine_user_messages": len(user_msgs),
        "user_messages": user_msgs[:10],
        "tool_counts": dict(tool_counts),
        "github_repos": sorted(github_repos),
        "likely_non_english": is_non_english,
        "input_tokens": stats.get("input_tokens", 0),
        "output_tokens": stats.get("output_tokens", 0),
        "pass_user_msgs": len(user_msgs) >= 3,
        "pass_has_repo": len(github_repos) > 0,
        "pass_english": not is_non_english,
    }


def _dc_load_stars_cache() -> dict:
    if STARS_CACHE_PATH.exists():
        with open(STARS_CACHE_PATH) as f:
            return json.load(f)
    return {}


def _dc_save_stars_cache(cache: dict) -> None:
    with open(STARS_CACHE_PATH, "w") as f:
        json.dump(cache, f, indent=2)


async def _dc_lookup_stars(repos: list, cache: dict) -> dict:
    import aiohttp

    to_lookup = [r for r in repos if r not in cache]
    if not to_lookup:
        return cache

    gh_token = os.environ.get("GITHUB_TOKEN", "")
    headers = {"Accept": "application/vnd.github.v3+json"}
    if gh_token:
        headers["Authorization"] = f"token {gh_token}"

    print(f"  Looking up stars for {len(to_lookup)} new repos...")
    async with aiohttp.ClientSession(headers=headers) as session:
        sem = asyncio.Semaphore(10)

        async def fetch_one(repo):
            async with sem:
                url = f"https://api.github.com/repos/{repo}"
                try:
                    async with session.get(url) as resp:
                        if resp.status == 200:
                            data = await resp.json()
                            cache[repo] = data.get("stargazers_count", 0)
                        elif resp.status == 404:
                            cache[repo] = -1
                        elif resp.status == 403:
                            print(f"    Rate limited at {repo}")
                            return "rate_limited"
                        else:
                            cache[repo] = -1
                except Exception:
                    cache[repo] = -1
                return "ok"

        for i in range(0, len(to_lookup), 50):
            batch = to_lookup[i:i + 50]
            results = await asyncio.gather(*[fetch_one(r) for r in batch])
            if "rate_limited" in results:
                break
            _dc_save_stars_cache(cache)

    _dc_save_stars_cache(cache)
    return cache


# ──────────────────────────────────────────────────────────────────────────
# DataClaw entry point
# ──────────────────────────────────────────────────────────────────────────

async def _run_dataclaw_async(args: argparse.Namespace) -> int:
    # When --out-dir is set, redirect all 3 outputs there with step-prefixed names.
    if args.out_dir:
        out_dir = Path(args.out_dir).resolve()
        out_json = out_dir / "step1_all_sessions.json"
        out_candidates = out_dir / "step1_candidates.json"
        out_popular = out_dir / "step1_sessions_with_popular_repos.json"
    else:
        out_dir = DC_OUTPUT_DIR
        out_json = DC_OUTPUT_JSON
        out_candidates = DC_OUTPUT_CANDIDATES
        out_popular = DC_OUTPUT_POPULAR
    out_dir.mkdir(parents=True, exist_ok=True)
    existing_ids = _dc_load_existing_session_ids()
    print(f"Already have {len(existing_ids)} session IDs")

    all_screened: list = []
    dataset_stats: list = []

    for hf_repo, donor in DATACLAW_DATASETS:
        print(f"\n{'='*60}")
        print(f"Fetching {hf_repo} (donor: {donor})...")

        sessions = _dc_download_dataset(hf_repo)
        if not sessions:
            dataset_stats.append({"hf_repo": hf_repo, "donor": donor, "error": "no data"})
            continue

        new_count = 0
        dup_count = 0
        for session in sessions:
            sid = session.get("session_id", session.get("id", ""))
            if sid in existing_ids:
                dup_count += 1
                continue
            existing_ids.add(sid)
            all_screened.append(_dc_screen_session(session, donor, hf_repo))
            new_count += 1

        dataset_stats.append({
            "hf_repo": hf_repo, "donor": donor,
            "total_rows": len(sessions), "new": new_count, "dup": dup_count,
        })
        print(f"  Total: {len(sessions)}, New: {new_count}, Duplicates: {dup_count}")

    # Funnel summary
    print(f"\n{'='*60}")
    print(f"Total new sessions screened: {len(all_screened)}")

    pass_msgs = sum(1 for r in all_screened if r["pass_user_msgs"])
    pass_repo = sum(1 for r in all_screened if r["pass_has_repo"])
    pass_basic = [r for r in all_screened if r["pass_user_msgs"] and r["pass_has_repo"]]

    print(f"\n=== Filter Funnel ===")
    print(f"Total new sessions:       {len(all_screened)}")
    print(f"3+ user messages:         {pass_msgs}")
    print(f"Has GitHub repo:          {pass_repo}")
    print(f"Pass ALL basic filters:   {len(pass_basic)}")

    # Stars lookup
    if not args.skip_stars and pass_basic:
        all_repos = set()
        for r in pass_basic:
            all_repos.update(r["github_repos"])
        print(f"\nLooking up stars for {len(all_repos)} unique repos...")
        cache = _dc_load_stars_cache()
        cache = await _dc_lookup_stars(sorted(all_repos), cache)

        for r in pass_basic:
            qualifying = []
            max_stars = 0
            for repo in r["github_repos"]:
                stars = cache.get(repo, -1)
                if stars >= args.min_stars:
                    qualifying.append([repo, stars])
                    max_stars = max(max_stars, stars)
            r["qualifying_repos"] = qualifying
            r["max_stars"] = max_stars
            r["pass_stars"] = max_stars >= args.min_stars

        candidates = [r for r in pass_basic if r.get("pass_stars")]
    else:
        candidates = pass_basic

    print(f"Pass stars filter:        {len(candidates)}")

    with open(out_json, "w") as f:
        json.dump(all_screened, f, indent=2, default=str, ensure_ascii=False)
    print(f"\nWrote {len(all_screened)} sessions to {out_json}")

    with open(out_candidates, "w") as f:
        json.dump(candidates, f, indent=2, default=str, ensure_ascii=False)
    print(f"Wrote {len(candidates)} candidates to {out_candidates}")

    index_entries = []
    for r in candidates:
        index_entries.append({
            "session_id": r["session_id"],
            "donor": r["donor"],
            "hf_repo": r["hf_repo"],
            "project": r.get("project", ""),
            "model": r.get("model", ""),
            "start_time": r.get("start_time", ""),
            "n_messages": r["n_messages"],
            "qualifying_repos": r.get("qualifying_repos", []),
            "all_repos": r["github_repos"],
        })
    with open(out_popular, "w") as f:
        json.dump(index_entries, f, indent=2, default=str, ensure_ascii=False)
    print(f"Wrote {len(index_entries)} index entries to {out_popular}")

    if args.out_dir:
        with open(out_dir / "step1_run_config.json", "w") as f:
            json.dump({
                "source": args.source,
                "min_stars": args.min_stars,
                "skip_stars": args.skip_stars,
                "n_screened": len(all_screened),
                "n_candidates": len(candidates),
                "n_datasets": len(DATACLAW_DATASETS),
            }, f, indent=2)

    print(f"\n=== Dataset Summary ===")
    for ds in dataset_stats:
        if "error" in ds:
            print(f"  {ds['hf_repo']}: {ds['error']}")
        else:
            print(f"  {ds['hf_repo']}: {ds['total_rows']} rows, {ds['new']} new, {ds['dup']} dup")

    candidates.sort(key=lambda r: (
        r.get("max_stars", 0) if isinstance(r.get("max_stars"), int) else 0,
        r["genuine_user_messages"],
    ), reverse=True)
    print(f"\n=== Top 30 Candidates ===")
    for i, r in enumerate(candidates[:30]):
        repos = ", ".join(q[0] for q in r.get("qualifying_repos", []))[:50]
        stars = r.get("max_stars", "?")
        n_user = r["genuine_user_messages"]
        first_msg = r["user_messages"][0][:80] if r["user_messages"] else "?"
        print(f"  {i+1}. [{stars}★] {repos}")
        print(f"     {n_user} user msgs | donor: {r['donor']} | {r['hf_repo']}")
        print(f"     \"{first_msg}\"")
        print()

    return 0


def run_dataclaw(args: argparse.Namespace) -> int:
    return asyncio.run(_run_dataclaw_async(args))


# ──────────────────────────────────────────────────────────────────────────
# SWE-chat entry point
# ──────────────────────────────────────────────────────────────────────────

def run_swechat(args: argparse.Namespace) -> int:
    """Pull SWE-chat sessions + repositories parquet, apply Stage-0 filters,
    emit step1_all_sessions.json (a single file — SWE-chat applies all
    filters inline, so no separate post-filter "candidates" subset exists)."""
    import pandas as pd
    from huggingface_hub import hf_hub_download

    if args.out_dir:
        out_dir = Path(args.out_dir).resolve()
        all_sessions_name = "step1_all_sessions.json"
    else:
        out_dir = ROOT / "swechat"
        all_sessions_name = "all_sessions.json"
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Pulling sessions.parquet + repositories.parquet from HF...")
    sf = hf_hub_download("SALT-NLP/SWE-chat", "sessions.parquet", repo_type="dataset")
    rf = hf_hub_download("SALT-NLP/SWE-chat", "repositories.parquet", repo_type="dataset")
    sessions = pd.read_parquet(sf)
    repos = pd.read_parquet(rf)

    def _stars(meta_json: str) -> int:
        try:
            return int(json.loads(meta_json).get("stargazers_count", 0))
        except Exception:
            return 0

    repos = repos.assign(stars=repos["repo_github_metadata"].map(_stars))
    sessions = sessions.assign(
        ss_num=pd.to_numeric(sessions["session_success"], errors="coerce")
    )

    print(f"\n=== Stage 0 funnel (source=swechat) ===")
    df = sessions.copy()
    print(f"  start                            {len(df):>5}")

    df = df[df["prompt_count"] >= 3]
    print(f"  prompt_count >= 3                {len(df):>5}")

    df = df[df["action_count"] > 0]
    print(f"  action_count > 0                 {len(df):>5}")

    df = df.merge(
        repos[["repo_id", "stars", "is_fork", "license_type", "repo_type_domain"]],
        on="repo_id",
        how="left",
    )
    df = df[df["stars"] >= args.min_stars]
    print(f"  stars >= {args.min_stars:<3}                    {len(df):>5}")

    # Removed filters that didn't earn their slot:
    #   is_fork == False       — SWE-chat repositories table never includes forks; dropped 0.
    #   session_success >= N   — itself a Gemini annotation; step2 reruns Gemini Pro on each
    #                            survivor anyway, so this filter just preapplies a weaker
    #                            version of the same judgment.
    df = df[df["agent_percentage"].fillna(0) >= args.min_agent_percentage]
    print(f"  agent_percentage >= {args.min_agent_percentage:<3}         {len(df):>5}")

    if args.per_repo_cap is not None:
        df = (
            df.sort_values("ss_num", ascending=False)
              .groupby("repo_id", group_keys=False)
              .head(args.per_repo_cap)
        )
        print(f"  per-repo cap = {args.per_repo_cap:<3}              {len(df):>5}")

    if args.limit is not None:
        df = df.head(args.limit)
        print(f"  --limit {args.limit:<3}                    {len(df):>5}")

    records = []
    for _, row in df.iterrows():
        sid = row["session_id"]
        repo_id = row["repo_id"]
        records.append({
            "session_id": sid,
            "donor": str(row.get("user_id", "")),
            "hf_repo": "SALT-NLP/SWE-chat",
            "model": str(row.get("agent", "")),
            "project": repo_id,
            "project_name": repo_id.split("/")[-1] if "/" in repo_id else repo_id,
            "start_time": str(row.get("created_at", "")),
            "n_messages": int(row.get("turn_count", 0) or 0),
            "genuine_user_messages": int(row.get("prompt_count", 0) or 0),
            "user_messages": [],  # populated lazily from transcripts/<sid>.jsonl in step2
            "tool_counts": {
                "research": int(row.get("research_count", 0) or 0),
                "action": int(row.get("action_count", 0) or 0),
                "_total": int(row.get("tool_call_count", 0) or 0),
                "_unique": int(row.get("unique_tools_count", 0) or 0),
            },
            "github_repos": [repo_id],
            "likely_non_english": False,
            "input_tokens": int(row.get("input_tokens", 0) or 0),
            "output_tokens": int(row.get("output_tokens", 0) or 0),
            "_swechat_session_success": float(row.get("ss_num", 0) or 0),
            "_swechat_agent_percentage": float(row.get("agent_percentage", 0) or 0),
            "_swechat_user_persona": str(row.get("user_persona", "")),
            "_swechat_stars": int(row.get("stars", 0) or 0),
            "_swechat_repo_type_domain": str(row.get("repo_type_domain", "")),
            "_swechat_license_type": str(row.get("license_type", "")),
            "pass_user_msgs": True,
            "pass_has_repo": True,
            "pass_english": True,
        })

    all_sessions_path = out_dir / all_sessions_name
    with open(all_sessions_path, "w") as f:
        json.dump(records, f, indent=2, default=str)

    if args.out_dir:
        with open(out_dir / "step1_run_config.json", "w") as f:
            json.dump({
                "source": args.source,
                "min_stars": args.min_stars,
                "min_agent_percentage": args.min_agent_percentage,
                "per_repo_cap": args.per_repo_cap,
                "limit": args.limit,
                "n_input_sessions": len(sessions),
                "n_output_records": len(records),
            }, f, indent=2)

    print(f"\nWrote {len(records)} records to {all_sessions_path}")

    by_repo = Counter(r["project"] for r in records)
    by_persona = Counter(r["_swechat_user_persona"] for r in records)
    by_agent = Counter(r["model"] for r in records)
    print(f"\nTop 10 repos by candidate count:")
    for repo, n in by_repo.most_common(10):
        print(f"  {n:>4}  {repo}")
    print(f"\nUser persona distribution:")
    for k, v in by_persona.most_common():
        print(f"  {v:>4}  {k}")
    print(f"\nAgent distribution:")
    for k, v in by_agent.most_common():
        print(f"  {v:>4}  {k}")

    return 0


# ──────────────────────────────────────────────────────────────────────────
# Dispatcher
# ──────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--source",
        choices=["dataclaw", "swechat"],
        required=True,
        help="Which dataset to fetch + filter",
    )
    parser.add_argument("--min-stars", type=int, default=10,
                        help="Minimum repo star count (default 10). SWE-chat repos are already "
                             "filtered to public GitHub projects, so a lower bar than DataClaw's "
                             "20 is fine; quality is enforced by step2 Pro instead.")
    parser.add_argument("--skip-stars", action="store_true",
                        help="(dataclaw) skip GitHub API star lookup")
    # SWE-chat-only knobs
    parser.add_argument("--per-repo-cap", type=int, default=None,
                        help="(swechat) max sessions per repo, sorted by session_success")
    parser.add_argument("--min-agent-percentage", type=int, default=30,
                        help="(swechat) drop sessions where agent wrote less than this %% (default 30)")
    parser.add_argument("--limit", type=int, default=None,
                        help="(swechat) cap total candidates after filtering")
    parser.add_argument("--out-dir", type=str, default=None,
                        help="Override output directory. When set, files are step-prefixed "
                             "(step1_all_sessions.json, step1_candidates.json, etc.) and "
                             "step1_run_config.json is written for provenance.")
    args = parser.parse_args()

    if args.source == "dataclaw":
        return run_dataclaw(args)
    return run_swechat(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
