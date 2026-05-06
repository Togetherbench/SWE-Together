"""Step 2: LLM-based viability judge with Gemini 3.1 Pro.

Asks: "Is the coding work in this session reproducible in a clean Harbor task,
or is it fundamentally about external state (PR creation, push, issue triage)?"

Returns per-session: primary_deliverable / reproducible_in_harbor / verdict.

The earlier Flash-then-Pro two-stage flow was simplified to Pro-only: SWE-chat
already provides repo_id + stargazers_count + action_count natively, so the
Flash repo+stars step (the original justification) added no signal — Flash
just confirmed what we already knew, and disagreed with Pro on 46% of
candidates. Trust Pro.

For DataClaw the script still preserves the legacy "rescue NOT_VIABLE" mode.

Usage:
    # SWE-chat (default flow: read step1 candidates, run Pro on each)
    python data-pipeline/screening/scripts/step2_screen_with_llm.py --source swechat \\
        [--limit N] [--out-dir data-pipeline/screening/artifacts_swechat/]

    # DataClaw (rescue NOT_VIABLE from screening_results.json)
    python data-pipeline/screening/scripts/step2_screen_with_llm.py --source dataclaw [--limit N]
"""
import argparse
import collections
import json
import os
import pathlib
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import google.generativeai as genai

API_KEY = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
if not API_KEY:
    sys.exit("Set GEMINI_API_KEY env var")

genai.configure(api_key=API_KEY)
MODEL_NAME = 'gemini-3.1-pro-preview'

# DataClaw paths (preserve original behavior)
ROOT_REPO = Path(__file__).resolve().parents[3]  # data-pipeline/screening/scripts/<this> → repo root
DC_REGEX_RESULTS = ROOT_REPO / 'session_collection' / 'screening_results.json'
DC_SESSIONS_DIR = ROOT_REPO / 'session_collection' / 'sessions_raw'
DC_OUTPUT = ROOT_REPO / 'session_collection' / 'llm_rescreen_results.json'

# SWE-chat paths
SWECHAT_DIR = Path(__file__).resolve().parent / 'swechat'
SWECHAT_STEP1 = SWECHAT_DIR / 'all_sessions.json'             # input from step1_collect.py
SWECHAT_OUTPUT = SWECHAT_DIR / 'step2_screening.json'         # default output (overridable via --out-dir)
SWECHAT_CANDIDATES = SWECHAT_DIR / 'step2_candidates.json'

SWECHAT_HF_REPO = 'SALT-NLP/SWE-chat'

PROMPT_TEMPLATE = """You are evaluating whether a multi-turn coding session can become a reproducible
Harbor benchmark task. Harbor tasks run in a clean Docker container with the target repo
pre-cloned at a specific commit. The agent gets the instruction, works, and its final
file-state is scored.

SESSION SUMMARY
---
repo: {repo} ({stars} stars, public)
user_messages: {u_count}    tool_uses: {t_count}    edits: {edit_count}
tool distribution: {tool_dist}

FIRST 3 USER MESSAGES:
{user_msgs}

LAST USER MESSAGE:
{last_user}

EDITED FILES:
{edit_paths}

BASH COMMANDS (first 20):
{bash_cmds}
---

Return a JSON object with these keys:
  - primary_deliverable: "code_changes" | "pr_creation" | "issue_triage" | "analysis_only" | "deployment_ops" | "other"
  - reproducible_in_harbor: true | false
  - reason: 1 sentence explaining
  - verdict: "VIABLE" | "NOT_VIABLE"

Verdict rules:
- VIABLE if the coding work (edits, fixes, refactors) is the core value AND can be
  reproduced without the push/PR step. The agent in Harbor would produce the same
  edits; the `git push` at the end is just a publishing step we'd skip.
- NOT_VIABLE if the task's actual deliverable IS the PR content/management or the
  session is primarily discussion/planning with no substantive edits.

Output ONLY the JSON, no markdown fences."""


# ──────────────────────────────────────────────────────────────────────────
# DataClaw summary (existing format: per-session JSON in sessions_raw/)
# ──────────────────────────────────────────────────────────────────────────

def summarize_dataclaw_session(session_path: Path) -> dict:
    d = json.load(open(session_path))
    messages = d.get('messages', [])
    user_texts = []
    bash_cmds = []
    edit_paths = []
    tool_dist = collections.Counter()

    for m in messages:
        role = m.get('role'); c = m.get('content')
        if role == 'user':
            if isinstance(c, str):
                user_texts.append(c)
            elif isinstance(c, list):
                for x in c:
                    if isinstance(x, dict) and x.get('type') == 'text':
                        user_texts.append(x.get('text', ''))
        elif role == 'assistant' and isinstance(c, list):
            for x in c:
                if isinstance(x, dict) and x.get('type') == 'tool_use':
                    name = (x.get('name') or '').lower()
                    tool_dist[name] += 1
                    inp = x.get('input', {}) or {}
                    if name == 'bash':
                        cmd = inp.get('command') or inp.get('cmd') or ''
                        if isinstance(cmd, str):
                            bash_cmds.append(cmd)
                    elif name in ('edit', 'write', 'multiedit', 'str_replace', 'apply_patch',
                                  'create', 'str_replace_based_edit_tool'):
                        fp = (inp.get('file_path') or inp.get('path')
                              or inp.get('filePath') or inp.get('filename'))
                        if fp:
                            edit_paths.append(fp)

    substantive_users = [t for t in user_texts if len(t.strip()) > 2]
    first3 = '\n\n'.join(f"U{i+1}: {t[:500]}" for i, t in enumerate(substantive_users[:3]))
    last = substantive_users[-1][:500] if substantive_users else '(none)'
    tool_dist_str = ', '.join(f"{k}={v}" for k, v in tool_dist.most_common(8))
    edits_str = '\n'.join(f"  {p}" for p in edit_paths[:15]) or '  (none)'
    bash_str = '\n'.join(f"  {c[:150]}" for c in bash_cmds[:20])

    return {
        'session_id': d['session_id'],
        'repo': d.get('_github_repo'),
        'stars': d.get('_github_stars'),
        'u_count': len(substantive_users),
        't_count': sum(tool_dist.values()),
        'edit_count': len(edit_paths),
        'tool_dist': tool_dist_str,
        'user_msgs': first3,
        'last_user': last,
        'edit_paths': edits_str,
        'bash_cmds': bash_str,
    }


# ──────────────────────────────────────────────────────────────────────────
# SWE-chat summary (transcripts/<sid>.jsonl + step2 metadata)
# ──────────────────────────────────────────────────────────────────────────

def _swechat_parse_transcript(transcript_path: Path) -> dict:
    """Parse a SWE-chat Claude-Code-style JSONL transcript."""
    user_texts = []
    bash_cmds = []
    edit_paths = []
    tool_dist = collections.Counter()

    try:
        with open(transcript_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue

                rtype = rec.get('type')
                msg = rec.get('message', {})
                content = msg.get('content', '')

                if rtype == 'user':
                    if isinstance(content, list):
                        text_parts = [b.get('text', '') for b in content
                                      if isinstance(b, dict) and b.get('type') == 'text']
                        content = ' '.join(text_parts)
                    if isinstance(content, str):
                        s = content.strip()
                        if s and not s.startswith('<') and '[Request interrupted' not in s:
                            user_texts.append(s)

                elif rtype == 'assistant' and isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict) or block.get('type') != 'tool_use':
                            continue
                        name = (block.get('name') or '').lower()
                        tool_dist[name] += 1
                        inp = block.get('input', {}) or {}
                        if name == 'bash':
                            cmd = inp.get('command') or inp.get('cmd') or ''
                            if isinstance(cmd, str):
                                bash_cmds.append(cmd)
                        elif name in ('edit', 'write', 'multiedit', 'str_replace', 'apply_patch',
                                      'create', 'str_replace_based_edit_tool'):
                            fp = (inp.get('file_path') or inp.get('path')
                                  or inp.get('filePath') or inp.get('filename'))
                            if fp:
                                edit_paths.append(fp)
    except Exception as e:
        print(f"    WARN parse {transcript_path.name}: {e}", file=sys.stderr)

    return {
        'user_texts': user_texts,
        'bash_cmds': bash_cmds,
        'edit_paths': edit_paths,
        'tool_dist': tool_dist,
    }


def summarize_swechat_session(rec: dict) -> dict:
    """Build the prompt-fill dict for one SWE-chat record (from gemini_screening.json)."""
    from huggingface_hub import hf_hub_download

    sid = rec['session_id']
    g = rec.get('gemini', {}) or {}

    try:
        tpath = hf_hub_download(SWECHAT_HF_REPO, f'transcripts/{sid}.jsonl', repo_type='dataset')
        parsed = _swechat_parse_transcript(Path(tpath))
    except Exception as e:
        return {
            'session_id': sid,
            'error': f'transcript fetch/parse: {str(e)[:120]}',
        }

    user_texts = parsed['user_texts']
    bash_cmds = parsed['bash_cmds']
    edit_paths = parsed['edit_paths']
    tool_dist = parsed['tool_dist']

    first3 = '\n\n'.join(f"U{i+1}: {t[:500]}" for i, t in enumerate(user_texts[:3]))
    last = user_texts[-1][:500] if user_texts else '(none)'
    tool_dist_str = ', '.join(f"{k}={v}" for k, v in tool_dist.most_common(8))
    edits_str = '\n'.join(f"  {p}" for p in edit_paths[:15]) or '  (none)'
    bash_str = '\n'.join(f"  {c[:150]}" for c in bash_cmds[:20])

    return {
        'session_id': sid,
        'repo': g.get('github_repo') or rec.get('project') or '?',
        'stars': g.get('stars_approx') or rec.get('_swechat_stars', '?'),
        'u_count': len(user_texts),
        't_count': sum(tool_dist.values()),
        'edit_count': len(edit_paths),
        'tool_dist': tool_dist_str,
        'user_msgs': first3,
        'last_user': last,
        'edit_paths': edits_str,
        'bash_cmds': bash_str,
    }


# ──────────────────────────────────────────────────────────────────────────
# Gemini Pro call
# ──────────────────────────────────────────────────────────────────────────

def call_gemini(prompt: str, max_retries: int = 3) -> str:
    model = genai.GenerativeModel(MODEL_NAME)
    for attempt in range(max_retries):
        try:
            resp = model.generate_content(
                prompt,
                generation_config={'temperature': 0.0, 'response_mime_type': 'application/json'},
            )
            return resp.text.strip()
        except Exception as e:
            if attempt == max_retries - 1:
                raise
            time.sleep(2 ** attempt)


def rescreen_one(summary_or_path, source: str) -> dict:
    """Run one Pro call. summary_or_path is a Path (dataclaw) or dict (swechat record)."""
    try:
        if source == 'dataclaw':
            summary = summarize_dataclaw_session(summary_or_path)
        else:
            summary = summarize_swechat_session(summary_or_path)
            if 'error' in summary:
                return summary
        prompt = PROMPT_TEMPLATE.format(**summary)
        raw = call_gemini(prompt)
        try:
            v = json.loads(raw)
        except json.JSONDecodeError:
            raw2 = re.sub(r'^```(?:json)?\s*|\s*```$', '', raw.strip(), flags=re.MULTILINE)
            v = json.loads(raw2)
        v['session_id'] = summary['session_id']
        v['repo'] = summary['repo']
        return v
    except Exception as e:
        sid = (summary_or_path['session_id'] if isinstance(summary_or_path, dict)
               else pathlib.Path(summary_or_path).stem)
        return {'session_id': sid, 'error': str(e)[:200]}


# ──────────────────────────────────────────────────────────────────────────
# DataClaw entry point — rescue NOT_VIABLE
# ──────────────────────────────────────────────────────────────────────────

def run_dataclaw(args: argparse.Namespace) -> int:
    if not DC_REGEX_RESULTS.exists():
        print(f"ERROR: {DC_REGEX_RESULTS} not found", file=sys.stderr)
        return 1

    regex_results = json.load(open(DC_REGEX_RESULTS))
    to_rescreen = [r for r in regex_results if r.get('verdict') == 'NOT_VIABLE']
    if args.limit:
        to_rescreen = to_rescreen[:args.limit]
    print(f"Re-screening {len(to_rescreen)} dataclaw NOT_VIABLE sessions with Gemini Pro...",
          file=sys.stderr)

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(rescreen_one, DC_SESSIONS_DIR / f"{r['session_id']}.json", 'dataclaw'): r
                for r in to_rescreen}
        for i, fut in enumerate(as_completed(futs)):
            results.append(fut.result())
            if (i + 1) % 20 == 0:
                print(f"  {i+1}/{len(to_rescreen)}", file=sys.stderr)

    _summarize_and_save(results, DC_OUTPUT)
    return 0


# ──────────────────────────────────────────────────────────────────────────
# SWE-chat entry point — re-evaluate ALL step2 candidates with Pro
# ──────────────────────────────────────────────────────────────────────────

def run_swechat(args: argparse.Namespace) -> int:
    if not SWECHAT_STEP1.exists():
        print(f"ERROR: {SWECHAT_STEP1} not found — run step1_collect.py --source swechat first",
              file=sys.stderr)
        return 1

    step1_records = json.load(open(SWECHAT_STEP1))
    to_screen = list(step1_records)
    if args.limit:
        to_screen = to_screen[:args.limit]

    # Resolve output paths: --out-dir overrides, else default into scripts/screening/swechat/
    if args.out_dir:
        out_dir = Path(args.out_dir).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)
        screening_path = out_dir / 'step2_screening.json'
        candidates_path = out_dir / 'step2_candidates.json'
        # Provenance: snapshot the step1 input + run config
        with open(out_dir / 'step1_all_sessions.json', 'w') as fp:
            json.dump(step1_records, fp, indent=2, ensure_ascii=False, default=str)
        with open(out_dir / 'step2_run_config.json', 'w') as fp:
            json.dump({
                'source': args.source,
                'model': MODEL_NAME,
                'limit': args.limit,
                'workers': args.workers,
                'resume': args.resume,
                'n_input_sessions': len(step1_records),
                'n_to_screen': len(to_screen),
            }, fp, indent=2)
        print(f"[--out-dir] writing artifacts to {out_dir}", file=sys.stderr)
    else:
        SWECHAT_DIR.mkdir(parents=True, exist_ok=True)
        screening_path = SWECHAT_OUTPUT
        candidates_path = SWECHAT_CANDIDATES

    # Resume support
    existing = {}
    if args.resume and screening_path.exists():
        for r in json.load(open(screening_path)):
            existing[r['session_id']] = r
        before = len(to_screen)
        to_screen = [r for r in to_screen if r['session_id'] not in existing]
        print(f"Resume: {len(existing)} already done, {before - len(to_screen)} new",
              file=sys.stderr)

    print(f"Screening {len(to_screen)} swechat sessions with {MODEL_NAME} "
          f"(workers={args.workers})...", file=sys.stderr)

    results = list(existing.values())
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(rescreen_one, r, 'swechat'): r for r in to_screen}
        for i, fut in enumerate(as_completed(futs)):
            results.append(fut.result())
            if (i + 1) % 25 == 0:
                with open(screening_path, 'w') as fp:
                    json.dump(results, fp, indent=2, ensure_ascii=False, default=str)
                print(f"  {i+1}/{len(to_screen)} (saved {len(results)} total)", file=sys.stderr)

    # Final save + filtered candidates (VIABLE + reproducible_in_harbor=True)
    _summarize_and_save(results, screening_path)
    candidates = [r for r in results
                  if r.get('verdict') == 'VIABLE' and r.get('reproducible_in_harbor') is True]
    candidates.sort(key=lambda r: r.get('repo') or '')
    with open(candidates_path, 'w') as fp:
        json.dump(candidates, fp, indent=2, ensure_ascii=False, default=str)
    print(f"Wrote {len(candidates)} candidates (VIABLE + reproducible) to {candidates_path}",
          file=sys.stderr)
    return 0


def _summarize_and_save(results: list, output_path: Path):
    verdicts = collections.Counter(r.get('verdict', 'ERROR') for r in results)
    deliv = collections.Counter(r.get('primary_deliverable', '?') for r in results
                                if r.get('verdict'))
    repro = collections.Counter(r.get('reproducible_in_harbor', '?') for r in results
                                if r.get('verdict'))

    print(f"\n=== Pro re-screen results ===", file=sys.stderr)
    for v, n in verdicts.most_common():
        print(f"  {n:>4}: {v}", file=sys.stderr)
    print(f"\nPrimary deliverable:", file=sys.stderr)
    for k, n in deliv.most_common():
        print(f"  {n:>4}: {k}", file=sys.stderr)
    print(f"\nReproducible in Harbor:", file=sys.stderr)
    for k, n in repro.most_common():
        print(f"  {n:>4}: {k}", file=sys.stderr)

    viable = [r for r in results if r.get('verdict') == 'VIABLE']
    print(f"\nVIABLE: {len(viable)} of {len(results)}", file=sys.stderr)

    with open(output_path, 'w') as fp:
        json.dump(results, fp, indent=2, ensure_ascii=False, default=str)
    print(f"\nSaved -> {output_path}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--source', choices=['dataclaw', 'swechat'], default='dataclaw',
                        help='Which upstream to screen')
    parser.add_argument('--limit', type=int, default=0, help='Max sessions to process (0=all)')
    parser.add_argument('--workers', type=int, default=10, help='Concurrent Pro calls')
    parser.add_argument('--resume', action='store_true', help='Skip session_ids already in output JSON')
    parser.add_argument('--out-dir', type=str, default=None,
                        help='(swechat) Override output dir (default: scripts/screening/swechat/). '
                             'When set, also writes step1_all_sessions.json + step2_run_config.json '
                             'as provenance.')
    args = parser.parse_args()

    if args.source == 'dataclaw':
        return run_dataclaw(args)
    return run_swechat(args)


if __name__ == '__main__':
    sys.exit(main() or 0)
