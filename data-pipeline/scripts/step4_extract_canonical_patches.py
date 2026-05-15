#!/usr/bin/env python3
"""Step 4 — unified canonical-patch extractor for all non-SWE-chat sources.

Consolidated 2026-05-14: merges what used to be three separate scripts
(messages-replay, hyperswitch issue→PR diff, SWE-chat parquet). The
SWE-chat parquet extractor was dead code and is preserved under
data-pipeline/scripts/_legacy/.

Strategy waterfall (per task, first match wins):

  1. **Hyperswitch issue→PR→`gh pr diff`** — for `hyperswitch-<N>` task names,
     resolve N to the earliest merged closing PR and use its diff as the
     gold canonical. (Was: step4_extract_canonical_patches_hyperswitch.py.)

  2. **Fix A: `install_config.json` commit_sha → `gh api commits/<sha>.diff`** —
     when the task records a specific upstream commit, fetch the exact diff.
     Gold-standard for cli, pi-mono, gemini-voyager, rudel, and others.

  3. **Tool-replay** — clone repo at base_commit, replay structured tool_uses
     (Write / Edit / MultiEdit / NotebookEdit) against the working tree, then
     `git diff HEAD`. Fidelity bucketed `exact | directional | lossy` based on
     warning count / mutating-op ratio.

Output schema is identical to the SWE-chat extractor's 15 fields so
downstream consumers treat all sources uniformly. Source-specific extras are
prefixed with `_`.

Sources covered (auto-detected per task — see infer_source()):
  - DataClaw    (flat tool_uses schema)
  - pi-mono     (nested content-block schema)
  - hyperswitch (stringified <tool_use>{json}</tool_use> markup + issue→PR path)
  - amytis      (flat schema)
  - cli         (Anthropic CC + install_config.json commit_sha)
  - any other harbor task with original_session.json + parsable Dockerfile

Usage:
  python data-pipeline/scripts/step4_extract_canonical_patches.py
  python data-pipeline/scripts/step4_extract_canonical_patches.py --tasks 'pi-mono-*'
  python data-pipeline/scripts/step4_extract_canonical_patches.py --tasks 'hyperswitch-7*'
  python data-pipeline/scripts/step4_extract_canonical_patches.py --limit 5
  python data-pipeline/scripts/step4_extract_canonical_patches.py --force
"""

import argparse
import fnmatch
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parents[2]
HARBOR_TASKS = ROOT / "harbor_tasks"
BASE_IMAGES = ROOT / "base_images"
DATA_PIPELINE = ROOT / "data-pipeline"

# Same threshold as SWE-chat extractor.
MAX_PATCH_BYTES = 256 * 1024

# File-mutating tool names (lowercased for case-insensitive matching).
# `write_file` and `replace` are emitted by Gemini / Codex / OpenCode CLIs.
# Adding them (2026-05-14) recovers 11 previously-classified-unrecoverable tasks
# whose sessions came from those tools.
WRITE_TOOLS = {"write", "create_file", "write_file"}
EDIT_TOOLS = {"edit", "str_replace_editor", "string_replace", "replace"}
MULTI_EDIT_TOOLS = {"multiedit"}
NOTEBOOK_EDIT_TOOLS = {"notebookedit"}
APPLY_PATCH_TOOLS = {"apply_patch", "applypatch"}
ALL_MUTATING = (
    WRITE_TOOLS | EDIT_TOOLS | MULTI_EDIT_TOOLS | NOTEBOOK_EDIT_TOOLS | APPLY_PATCH_TOOLS
)

# Paths the agent uses for its own scratchpad / cached config — never part of
# the canonical patch even when Read/Edit'd inside a session. Sit outside the
# repo on the contributor's host machine.
AGENT_INTERNAL_PATH_FRAGMENTS = (
    "/.claude/", "/.cursor/", "/.aider/", "/.vscode/",
    "/node_modules/", "/__pycache__/", "/.pytest_cache/", "/.mypy_cache/",
    "/.ruff_cache/", "/dist/", "/build/", "/.next/cache/",
)

# Paths that bash file mutations can target without touching the canonical
# patch — flagging them produces noise.
BASH_NON_REPO_PREFIXES = (
    "/tmp/", "/var/", "/dev/", "/proc/", "/sys/", "/etc/",
    "/root/.", "/home/", "/Users/",
)

# Stringified-tool-use markup (hyperswitch traces).
INLINE_TOOL_USE_RE = re.compile(
    r'<tool_use\s+id="[^"]*"\s*>\s*(\{.*?\})\s*</tool_use>',
    re.DOTALL,
)

# Hyperswitch task name → upstream issue number. Used by the
# try_hyperswitch_issue_pr_diff() path (consolidated from the former
# step4_extract_canonical_patches_hyperswitch.py).
HYPERSWITCH_TASK_RE = re.compile(r"^hyperswitch-(\d+)$")
HYPERSWITCH_UPSTREAM_REPO = "juspay/hyperswitch"

# Dockerfile parsing.
GIT_CLONE_RE = re.compile(
    r"git\s+clone\s+(?:(?:--depth[=\s]+\d+|--filter=\S+|--no-checkout|--bare|--mirror|-q|--quiet)\s+)*(\S+?\.git|https?://[^\s\\]+?)(?=\s|\\|$)"
)
GIT_CLONE_DEST_RE = re.compile(
    r"git\s+clone\s+(?:(?:--depth[=\s]+\d+|--filter=\S+|--no-checkout|--bare|--mirror|-q|--quiet)\s+)*\S+\s+(\S+)"
)
# Alternative pattern: `git init` + `git remote add origin <url>` + `git fetch origin <sha>`
GIT_REMOTE_ADD_RE = re.compile(
    r"git(?:\s+-C\s+\S+)?\s+remote\s+add\s+\S+\s+(\S+?\.git|https?://[^\s\\]+?)(?=\s|\\|$)"
)
GIT_FETCH_SHA_RE = re.compile(
    r"git(?:\s+-C\s+\S+)?\s+fetch\s+(?:(?:--depth[=\s]+\d+|--filter=\S+|--no-checkout|--bare|--mirror|-q|--quiet)\s+)*\S+\s+([a-f0-9]{7,40})\b"
)
GIT_CHECKOUT_RE = re.compile(r"git(?:\s+-C\s+\S+)?\s+checkout\s+(?:-b\s+\S+\s+)?([a-f0-9]{7,40})\b")
GIT_RESET_RE = re.compile(r"git(?:\s+-C\s+\S+)?\s+reset\s+--hard\s+([a-f0-9]{7,40})\b")
ARG_BASE_COMMIT_RE = re.compile(
    r"^\s*ARG\s+(?:BASE_COMMIT|REPO_COMMIT|COMMIT|GIT_COMMIT|TARGET_COMMIT)\s*=\s*([a-f0-9]{7,40})",
    re.MULTILINE,
)
FROM_RE = re.compile(r"^\s*FROM\s+(\S+)", re.MULTILINE)
WORKDIR_RE = re.compile(r"^\s*WORKDIR\s+(\S+)", re.MULTILINE)
CD_WORKSPACE_RE = re.compile(r"cd\s+(/workspace/\S+?)(?:\s|&&|$)")


# --- Dockerfile parsing -------------------------------------------------------

def parse_task_dockerfile(dockerfile: Path) -> tuple[str | None, str | None, str | None]:
    """Return (repo_url, base_commit, repo_container_path).

    Handles two shapes:
      A) Direct clone in the task Dockerfile: `git clone <url> <dest> && git checkout <sha>`
      B) Base-image-derived: `FROM .../<cluster>-dev:latest` + `ARG BASE_COMMIT=<sha>`,
         with the clone living in `base_images/<cluster>/Dockerfile`.
    """
    if not dockerfile.exists():
        return None, None, None
    text = dockerfile.read_text(errors="replace")

    repo_url = repo_path = base_commit = None

    # Direct clone
    m = GIT_CLONE_RE.search(text)
    if m:
        repo_url = _normalize_repo_url(m.group(1))
    m = GIT_CLONE_DEST_RE.search(text)
    if m:
        repo_path = m.group(1)
    # Alternative: `git remote add origin <url>` (used when `git clone` is split)
    if not repo_url:
        m = GIT_REMOTE_ADD_RE.search(text)
        if m:
            repo_url = _normalize_repo_url(m.group(1))
    # Base commit: prefer `git fetch origin <sha>` (the explicit base) over
    # `git checkout <sha>` (which may be a branch tip created later in the
    # multi-stage builds used by some tasks like arr-monitor).
    m = GIT_FETCH_SHA_RE.search(text)
    if m:
        base_commit = m.group(1)
    if not base_commit:
        m = GIT_CHECKOUT_RE.search(text) or GIT_RESET_RE.search(text)
        if m:
            base_commit = m.group(1)

    # ARG BASE_COMMIT (base-image tasks)
    if not base_commit:
        m = ARG_BASE_COMMIT_RE.search(text)
        if m:
            base_commit = m.group(1)

    # Recurse into base image Dockerfile
    if not repo_url:
        m = FROM_RE.search(text)
        if m:
            cluster = _extract_cluster(m.group(1))
            if cluster:
                base_path = BASE_IMAGES / cluster / "Dockerfile"
                if base_path.exists():
                    bru, _, brp = parse_task_dockerfile(base_path)
                    repo_url = repo_url or bru
                    repo_path = repo_path or brp

    # Repo container path: prefer cd /workspace/<dir> in RUN lines, then WORKDIR
    if not repo_path:
        m = CD_WORKSPACE_RE.search(text)
        if m:
            repo_path = m.group(1)
    if not repo_path:
        m = WORKDIR_RE.search(text)
        if m:
            repo_path = m.group(1)

    return repo_url, base_commit, repo_path


def _normalize_repo_url(url: str) -> str:
    url = url.strip().rstrip("/").rstrip("\\")
    if url.endswith(".git"):
        url = url[:-4]
    return url


def _extract_cluster(image_ref: str) -> str | None:
    base = image_ref.split(":")[0].rstrip("/").split("/")[-1]
    base = re.sub(r"-dev$", "", base)
    if base in ("ubuntu", "debian", "alpine", "python", "node", "pytorch"):
        return None
    return base if (BASE_IMAGES / base).exists() else None


# --- Source inference --------------------------------------------------------

def infer_source(session: dict, task_name: str) -> str:
    # Task-name prefix wins: it's set when the harbor task was scaffolded and
    # uniquely identifies the cluster. (Donor metadata is unreliable — pi-mono
    # sessions also carry _donor, so keying on _donor mis-routes them.)
    name = task_name.lower()
    for prefix, src in [
        ("pi-mono-", "pi-mono"),
        ("hyperswitch-", "hyperswitch"),
        ("amytis-", "amytis"),
        ("cli-", "cli"),
        ("cc-backend-", "cc-backend"),
        ("agent-swarm-", "agent-swarm"),
        ("agent-kit-", "agent-kit"),
        ("comfyui-", "comfyui"),
        ("reigh-", "reigh"),
        ("sd-scripts-", "sd-scripts"),
        ("triton-", "triton"),
        ("banodoco-", "banodoco"),
        ("mlx-lm-", "mlx-lm"),
    ]:
        if name.startswith(prefix):
            return src
    # Fallback: session metadata
    hf = (session.get("_hf_repo", "") or "").lower()
    if session.get("_donor") or "dataclaw" in hf or "codex" in hf:
        return "dataclaw"
    if session.get("_source"):
        s = str(session["_source"]).lower()
        if "hyperswitch" in s:
            return "hyperswitch"
        if "pi" in s and ("share" in s or "mono" in s):
            return "pi-mono"
    return "unknown"


# --- Message normalization (3 schemas → unified op stream) -------------------

def normalize_messages(session: dict) -> list[dict]:
    """Yield ops in order, dedup'd across schemas.

    Some sources (cli, amytis, cc-backend, agent-swarm, many DataClaw donors)
    ship messages that contain BOTH the flat `tool_uses` array AND the nested
    `content[].tool_use` blocks for the same tool calls — they're duplicates
    of the same data. Naively emitting both doubles every Edit, which makes
    the second copy fail anchor-match (the first already moved the file).
    Pick exactly one shape per message, preferring the richest source.
    """
    ops = []
    for m in session.get("messages", []):
        if not isinstance(m, dict):
            continue
        role = m.get("role", "?")
        c = m.get("content")
        flat_uses = m.get("tool_uses") or []
        nested_uses = [
            b for b in (c or [])
            if isinstance(b, dict) and b.get("type") == "tool_use"
        ] if isinstance(c, list) else []

        # Shape A wins when present — `tool_uses` is the primary projection
        # for harbor-shaped sessions. Falls back to nested content blocks
        # (pi-mono-only schema) or inline markup (hyperswitch).
        if flat_uses:
            for tu in flat_uses:
                tool = tu.get("tool") or tu.get("name") or ""
                inp = tu.get("input")
                if isinstance(inp, str):
                    inp = {"_str": inp}
                ops.append({"role": role, "tool": tool, "input": inp or {}})
        elif nested_uses:
            for b in nested_uses:
                ops.append({
                    "role": role,
                    "tool": b.get("name", ""),
                    "input": b.get("input", {}) or {},
                })
        elif isinstance(c, str) and "<tool_use" in c:
            for m2 in INLINE_TOOL_USE_RE.finditer(c):
                try:
                    payload = json.loads(m2.group(1))
                except json.JSONDecodeError:
                    continue
                ops.append({
                    "role": role,
                    "tool": payload.get("name", ""),
                    "input": payload.get("arguments") or payload.get("input", {}) or {},
                })
    return ops


# --- Tool replay -------------------------------------------------------------

def replay_ops(ops: list[dict], work_tree: Path, repo_path_hint: str | None) -> list[str]:
    warnings: list[str] = []
    n_applied = 0

    for i, op in enumerate(ops):
        tool = (op["tool"] or "").lower()
        inp = op["input"] if isinstance(op["input"], dict) else {}

        if tool in WRITE_TOOLS:
            path = _pick(inp, "file_path", "path", "filePath")
            content = inp.get("content")
            if content is None:
                content = inp.get("file_text") or inp.get("text") or inp.get("fileText") or ""
            if not path:
                warnings.append(f"op[{i}] {tool}: missing file_path")
                continue
            if _is_agent_internal(path):
                continue  # silently skip — not part of canonical patch
            target = _resolve(path, work_tree, repo_path_hint)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            n_applied += 1

        elif tool in EDIT_TOOLS or tool in MULTI_EDIT_TOOLS:
            # Pi-mono uses tool name `edit` but ships a multi-edit shape:
            # {path, edits: [{oldText, newText}, ...]}. Detect either way.
            edits_list = inp.get("edits")
            if isinstance(edits_list, list) and edits_list:
                file_path = _pick(inp, "file_path", "path", "filePath")
                if not file_path:
                    warnings.append(f"op[{i}] {tool}: missing file_path")
                    continue
                if _is_agent_internal(file_path):
                    continue
                for j, edit in enumerate(edits_list):
                    if not isinstance(edit, dict):
                        continue
                    ed = dict(edit)
                    ed.setdefault("file_path", file_path)
                    ok, err = _do_edit(ed, work_tree, repo_path_hint)
                    if ok:
                        n_applied += 1
                    elif err is not None:  # None err = silent skip (agent-internal)
                        warnings.append(f"op[{i}].edit[{j}] {file_path}: {err}")
            else:
                ok, err = _do_edit(inp, work_tree, repo_path_hint)
                if ok:
                    n_applied += 1
                elif err is not None:
                    warnings.append(f"op[{i}] edit: {err}")

        elif tool in NOTEBOOK_EDIT_TOOLS:
            warnings.append(f"op[{i}] notebookedit: not implemented")

        elif tool in APPLY_PATCH_TOOLS:
            patch_text = inp.get("patchText") or inp.get("patch") or inp.get("input") or inp.get("_str") or ""
            if not patch_text:
                warnings.append(f"op[{i}] apply_patch: empty patch")
                continue
            n, errs = _apply_v4a_patch(patch_text, work_tree, repo_path_hint)
            n_applied += n
            for e in errs:
                warnings.append(f"op[{i}] apply_patch: {e}")

        elif tool == "bash":
            cmd = (inp.get("command") or inp.get("_str") or "")
            # Try to actually replay simple `sed -i` mutations on repo files —
            # rarely the canonical fix for a 1-line bug (e.g. hyperswitch-9063
            # ships an underscore→hyphen substitution as `sed -i`, not Edit).
            n_sed, sed_unhandled = _replay_sed_i(cmd, work_tree, repo_path_hint)
            n_applied += n_sed

            # For unhandled mutations: only flag if the target is plausibly
            # inside the repo (skip /tmp/, /var/, /dev/, …).
            for kind, target in sed_unhandled:
                if not _bash_target_in_repo(target):
                    continue
                warnings.append(
                    f"op[{i}] bash: possible sneak edit not replayed ({kind} {target}): {cmd[:120]}"
                )
            # Catch other patterns we don't replay: `cat > foo`, `tee foo`.
            if not n_sed:
                m = re.search(r"\bcat\s+>\s*(\S+\.\w+)", cmd)
                if m and _bash_target_in_repo(m.group(1)):
                    warnings.append(f"op[{i}] bash: possible sneak edit not replayed: {cmd[:120]}")
                m = re.search(r"\btee\s+(?:-a\s+)?(\S+\.\w+)", cmd)
                if m and _bash_target_in_repo(m.group(1)):
                    warnings.append(f"op[{i}] bash: possible sneak edit not replayed: {cmd[:120]}")

    if n_applied == 0:
        warnings.append("no file-mutating ops were successfully applied")
    return warnings


def _pick(d: dict, *keys: str) -> str:
    """Return the first non-empty value among `keys`, else ''."""
    for k in keys:
        v = d.get(k)
        if v:
            return v
    return ""


def _is_agent_internal(path: str) -> bool:
    """True if this path is the agent's scratchpad / tooling cache, not the repo."""
    p = path.replace("\\", "/")
    return any(frag in p for frag in AGENT_INTERNAL_PATH_FRAGMENTS)


def _bash_target_in_repo(path: str) -> bool:
    """True if `path` plausibly lives inside the repo (not /tmp/, /var/, etc.)."""
    p = path.strip().replace("\\", "/")
    if p.startswith("/"):
        return not any(p.startswith(prefix) for prefix in BASH_NON_REPO_PREFIXES)
    return True  # relative paths are repo-relative


# Match `sed -i 's/old/new/[g]' file` and `sed -i 'Ns/old/new/[g]' file`. We
# cap to the simple substitute form because shell quoting + general sed
# scripts are not safe to evaluate. Captures: quote-char, delim, body, flags,
# file path. Body is greedy-but-bounded by the closing delim+flags+quote.
SED_I_RE = re.compile(
    r"""
    \bsed\s+-i\b           # sed -i (in-place)
    (?:\s+(?:-E|-r|-e\s+\S+))*  # optional flags we ignore
    \s+(?P<quote>['"])     # opening quote
      (?P<addr>\d+)?       # optional line address (1302s/...)
      s
      (?P<delim>[/|#@,])   # delimiter
      (?P<body>.+?)        # old_text, new_text, optional flags (parsed below)
    (?P=quote)             # closing quote
    \s+(?P<file>\S+)       # target file
    """,
    re.VERBOSE | re.DOTALL,
)


def _replay_sed_i(cmd: str, work_tree: Path, repo_path_hint: str | None
                  ) -> tuple[int, list[tuple[str, str]]]:
    """Best-effort replay of simple `sed -i` substitutions on repo files.
    Returns (n_applied, unhandled_targets). Unhandled targets are the file
    paths from sed/cat/tee patterns we couldn't or didn't replay.
    """
    n_applied = 0
    unhandled: list[tuple[str, str]] = []
    for m in SED_I_RE.finditer(cmd):
        delim = m.group("delim")
        body = m.group("body")
        addr = m.group("addr")
        target_file = m.group("file")
        # Body is `<old><delim><new><delim>?<flags>?` — split on UNESCAPED delim.
        # Simple two-pass: find first un-escaped delim, then first un-escaped
        # delim after that.
        parts = _sed_split(body, delim)
        if len(parts) < 2:
            unhandled.append(("sed", target_file))
            continue
        old_pat, new_pat = parts[0], parts[1]
        flags = parts[2] if len(parts) >= 3 else ""
        # Decode common escapes (\n, \t, \/, \', \" — and the delim itself).
        old_pat = _sed_unescape(old_pat, delim)
        new_pat = _sed_unescape(new_pat, delim)

        if not _bash_target_in_repo(target_file):
            continue  # writing outside repo
        target = _resolve(target_file, work_tree, repo_path_hint)
        if not target.exists():
            unhandled.append(("sed (file not found)", target_file))
            continue
        text = target.read_text(errors="replace")

        # We only replay LITERAL substitutions — sed regex with metachars is
        # too easy to misinterpret. Heuristic: if old_pat contains unescaped
        # regex metachars except `.` (very common), treat as regex via re.
        try:
            if "g" in flags:
                new_text = re.sub(old_pat, new_pat.replace("\\", "\\\\"), text)
            elif addr:
                lines = text.split("\n")
                idx = int(addr) - 1
                if 0 <= idx < len(lines):
                    lines[idx] = re.sub(old_pat, new_pat.replace("\\", "\\\\"), lines[idx], count=1)
                    new_text = "\n".join(lines)
                else:
                    unhandled.append(("sed (addr out of range)", target_file))
                    continue
            else:
                new_text = re.sub(old_pat, new_pat.replace("\\", "\\\\"), text, count=1)
        except re.error:
            unhandled.append(("sed (regex error)", target_file))
            continue

        if new_text == text:
            unhandled.append(("sed (no match)", target_file))
            continue
        target.write_text(new_text)
        n_applied += 1

    return n_applied, unhandled


def _sed_split(body: str, delim: str) -> list[str]:
    """Split `body` on un-escaped `delim`. Returns up to 3 parts (old/new/flags)."""
    parts: list[str] = []
    buf: list[str] = []
    i = 0
    while i < len(body) and len(parts) < 2:
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            buf.append(ch)
            buf.append(body[i + 1])
            i += 2
            continue
        if ch == delim:
            parts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    # Whatever is left in `buf` is the next field; rest of body (if any) is flags
    if buf or i < len(body):
        rest = "".join(buf) + body[i:]
        # Split flags off if there's still a delim
        d_idx = rest.find(delim)
        if d_idx >= 0:
            parts.append(rest[:d_idx])
            parts.append(rest[d_idx + 1:])
        else:
            parts.append(rest)
    return parts


def _sed_unescape(s: str, delim: str) -> str:
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt == "n": out.append("\n")
            elif nxt == "t": out.append("\t")
            elif nxt == delim: out.append(delim)
            elif nxt == "\\": out.append("\\")
            else: out.append(nxt)
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def _is_hashline_edit(inp: dict) -> bool:
    """Detect pi-mono Hashline / oh-my-pi anchor-based edit shape.

    Schema: `{op: replace_line|replace_range|insert_after|append_eof|prepend_bof,
              target: "<line>#<hash>" | "<startLine>#<h1>-<endLine>#<h2>",
              content: [str, ...]}`.

    The original file text is never recorded; the anchor is a content hash.
    Without the agent's prior `read` ops we can't reconstruct old text. Skip
    cleanly rather than emit an "empty content" warning."""
    return ("op" in inp and "target" in inp and "content" in inp
            and isinstance(inp.get("content"), list))


def _do_edit(inp: dict, work_tree: Path, repo_path_hint: str | None) -> tuple[bool, str | None]:
    # Field-name variants seen across sources:
    #   Anthropic CC:  file_path, old_string, new_string, replace_all
    #   pi-mono:       path, oldText, newText
    #   pi-mono Hashline / oh-my-pi: path, edits=[{op, target, content}]  (caller dispatches)
    #   misc:          old_str / new_str
    if _is_hashline_edit(inp):
        return False, None  # silently skip — anchor-based, not recoverable
    path = _pick(inp, "file_path", "path", "filePath")
    old = _pick(inp, "old_string", "oldText", "old_str", "old")
    new = _pick(inp, "new_string", "newText", "new_str", "new")
    replace_all = bool(inp.get("replace_all") or inp.get("replaceAll"))
    if not path:
        return False, "missing file_path"
    if _is_agent_internal(path):
        return False, None  # silently skip — sentinel: ok to drop without warn
    if not old and not new:
        return False, "edit input has no old/new text (export likely stripped content)"
    target = _resolve(path, work_tree, repo_path_hint)
    if not target.exists():
        return False, f"file not found: {target.relative_to(work_tree)}"
    text = target.read_text(errors="replace")
    if not old:
        target.write_text(text + new)
        return True, None
    if old not in text:
        # Deliberately do NOT fuzzy-match. Cross-validation against upstream
        # PRs (see `data-pipeline/scripts/notes/source_research.md`) showed
        # whitespace-tolerant fuzzy matching can synthesize patches that
        # don't reflect what the human actually shipped. We'd rather skip
        # the op and surface a real warning than invent a recovery.
        return False, f"old text not found in {target.relative_to(work_tree)}"
    if replace_all:
        text = text.replace(old, new)
    else:
        text = text.replace(old, new, 1)
    target.write_text(text)
    return True, None


def _apply_v4a_patch(patch_text: str, work_tree: Path, repo_path_hint: str | None) -> tuple[int, list[str]]:
    """Apply an OpenAI/Anthropic V4A apply_patch envelope to work_tree.

    Format:
      *** Begin Patch
      *** Update File: <path>
      @@ <optional_hunk_header>
       context
      -removed
      +added
       context
      *** End Patch

    Also handles `*** Add File:` (new file, all '+' lines) and `*** Delete File:`.
    """
    n_applied = 0
    errs: list[str] = []
    lines = patch_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("*** Update File:"):
            path = line[len("*** Update File:"):].strip()
            i += 1
            ok, err = _apply_v4a_update(path, lines, i, work_tree, repo_path_hint)
            if ok:
                n_applied += 1
            elif err:
                errs.append(err)
            # Skip ahead to next sentinel
            while i < len(lines) and not lines[i].startswith(("*** Update File:", "*** Add File:", "*** Delete File:", "*** End Patch")):
                i += 1
        elif line.startswith("*** Add File:"):
            path = line[len("*** Add File:"):].strip()
            i += 1
            content_lines = []
            while i < len(lines) and not lines[i].startswith(("*** Update File:", "*** Add File:", "*** Delete File:", "*** End Patch")):
                if lines[i].startswith("+"):
                    content_lines.append(lines[i][1:])
                i += 1
            target = _resolve(path, work_tree, repo_path_hint)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("\n".join(content_lines) + ("\n" if content_lines else ""))
            n_applied += 1
        elif line.startswith("*** Delete File:"):
            path = line[len("*** Delete File:"):].strip()
            target = _resolve(path, work_tree, repo_path_hint)
            if target.exists():
                target.unlink()
                n_applied += 1
            else:
                errs.append(f"delete: file not found {path}")
            i += 1
        else:
            i += 1
    return n_applied, errs


def _apply_v4a_update(path: str, lines: list[str], start: int, work_tree: Path, repo_path_hint: str | None) -> tuple[bool, str | None]:
    """Apply hunks for an Update File block. Returns (ok, err)."""
    target = _resolve(path, work_tree, repo_path_hint)
    if not target.exists():
        return False, f"update: file not found {path} → {target.relative_to(work_tree)}"
    text = target.read_text(errors="replace")
    file_lines = text.split("\n")

    i = start
    end_markers = ("*** Update File:", "*** Add File:", "*** Delete File:", "*** End Patch")
    while i < len(lines) and not lines[i].startswith(end_markers):
        if lines[i].startswith("@@"):
            i += 1
            # Collect a hunk: context (' '), removals ('-'), additions ('+').
            hunk_old: list[str] = []
            hunk_new: list[str] = []
            while i < len(lines) and not lines[i].startswith(end_markers) and not lines[i].startswith("@@"):
                ln = lines[i]
                if ln.startswith("+"):
                    hunk_new.append(ln[1:])
                elif ln.startswith("-"):
                    hunk_old.append(ln[1:])
                elif ln.startswith(" "):
                    hunk_old.append(ln[1:])
                    hunk_new.append(ln[1:])
                # Other lines (blank, etc.) treated as context with their literal text
                else:
                    hunk_old.append(ln)
                    hunk_new.append(ln)
                i += 1
            if not hunk_old:
                continue
            idx = _find_block(file_lines, hunk_old)
            if idx == -1:
                return False, f"update: hunk anchor not found in {path}"
            file_lines = file_lines[:idx] + hunk_new + file_lines[idx + len(hunk_old):]
        else:
            i += 1

    target.write_text("\n".join(file_lines))
    return True, None


def _find_block(haystack: list[str], needle: list[str]) -> int:
    """Return index of contiguous needle in haystack, else -1. Whitespace-tolerant."""
    if not needle:
        return -1
    n = len(needle)
    for s in range(len(haystack) - n + 1):
        if all(haystack[s + k].rstrip() == needle[k].rstrip() for k in range(n)):
            return s
    return -1


def _resolve(path: str, work_tree: Path, repo_path_hint: str | None) -> Path:
    """Resolve a tool_use file_path to a path under work_tree.

    Sessions can be recorded inside a container (`/workspace/<repo>/src/foo.py`)
    OR on a contributor's host machine (`/Users/jane/workspace/<repo>/src/foo.py`).
    Strategy: progressive-suffix search — pick the longest path suffix whose
    parent directory already exists in work_tree (so fresh-write paths land
    in a real subtree, not at the original host root).
    """
    p_str = path.strip()
    # Windows path normalization: C:\foo\bar → /foo/bar (drop drive, swap seps)
    if re.match(r"^[A-Za-z]:[\\/]", p_str):
        p_str = "/" + p_str[3:].replace("\\", "/")
    elif "\\" in p_str:
        p_str = p_str.replace("\\", "/")
    if not p_str.startswith("/"):
        return work_tree / p_str

    if repo_path_hint:
        hint = repo_path_hint.rstrip("/") + "/"
        if p_str.startswith(hint):
            return work_tree / p_str[len(hint):]

    parts = p_str.lstrip("/").split("/")
    # 1. Longest suffix whose full path already exists (Edit case)
    for start in range(len(parts)):
        cand = work_tree.joinpath(*parts[start:])
        if cand.exists():
            return cand
    # 2. Longest suffix where some ancestor already exists in work_tree
    #    (fresh-write into a new subdir of an existing tree)
    for start in range(len(parts) - 1):
        cand = work_tree.joinpath(*parts[start:])
        anc = cand.parent
        while anc != work_tree and anc != anc.parent:
            if anc.exists():
                return cand
            anc = anc.parent
    # 3. Fresh write into a top-level dir not yet present in the cloned base
    #    (e.g., `.github/workflows/ci.yml` when the base repo has no .github/
    #    yet). Look for a well-known repo-relative prefix anchor and preserve
    #    from there. This fixes the phantom-path bug seen on rudel-task-d64e5a
    #    where the path was collapsed to basename `ci.yml` at repo root.
    KNOWN_REPO_PREFIXES = {
        ".github", ".vscode", ".cursor", ".devcontainer", ".docker", ".idea",
        "src", "lib", "tests", "test", "scripts", "docs", "doc",
        "packages", "crates", "internal", "cmd", "pkg", "kernel",
        "app", "apps", "web", "server", "client", "frontend", "backend",
        "new-ui", "ui", "csrc", "include", "examples", "data-pipeline",
        "harbor_tasks", "migrations", "templates", "static", "public",
        "plans", "thoughts",
    }
    for i, part in enumerate(parts):
        if part in KNOWN_REPO_PREFIXES:
            return work_tree.joinpath(*parts[i:])
    # 4. Last resort: drop everything but the basename and place at repo root.
    return work_tree / parts[-1]


# --- Diff capture ------------------------------------------------------------

def capture_diff(work_tree: Path) -> dict:
    def git(*args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(work_tree), *args],
            check=False, capture_output=True, text=True,
        ).stdout

    git("add", "-N", ".")  # register untracked files so diff shows them
    patch = git("diff", "HEAD")
    name_status = git("diff", "--name-status", "HEAD")
    numstat = git("diff", "--numstat", "HEAD")

    additions = deletions = files = 0
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            try:
                additions += int(parts[0])
                deletions += int(parts[1])
                files += 1
            except ValueError:
                pass  # binary files: "-\t-\tpath"

    return {
        "patch": patch,
        "files_changed": name_status,
        "numstat": numstat,
        "files_changed_count": files,
        "total_additions": additions,
        "total_deletions": deletions,
    }


# --- Repo cloning ------------------------------------------------------------

_CACHE_ROOT = Path.home() / ".cache" / "canonical-patches" / "repos"


def _bare_cache_path(repo_url: str) -> Path:
    """`<owner>__<name>.git` under the shared cache."""
    parts = repo_url.rstrip("/").split("/")
    if len(parts) >= 2:
        slug = f"{parts[-2]}__{parts[-1]}"
    else:
        slug = parts[-1]
    return _CACHE_ROOT / f"{slug}.git"


def _ensure_bare_clone(repo_url: str) -> Path | None:
    """Init a bare clone for `repo_url` once across the whole run. Returns
    the bare repo path, or None on init failure."""
    bare = _bare_cache_path(repo_url)
    if (bare / "HEAD").exists():
        return bare
    bare.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["git", "init", "-q", "--bare", str(bare)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    subprocess.run(["git", "-C", str(bare), "remote", "add", "origin", repo_url],
                   capture_output=True)
    return bare


def _fetch_sha_into_cache(bare: Path, sha: str) -> bool:
    """Fetch `sha` into the bare cache and tag it as a reachable ref so
    downstream `git clone --shared` + `git checkout` can resolve it.

    Without the `update-ref` step, `git fetch <sha>` lands the commit object
    in the cache but leaves it unreachable from any ref, and `git clone --shared`
    only copies refs (not loose unreachable objects). The local clone then
    can't `checkout <sha>` and dies with "unable to read tree".
    """
    ref = f"refs/extracted/{sha}"
    have_ref = subprocess.run(["git", "-C", str(bare), "show-ref", "--verify", "--quiet", ref],
                              capture_output=True)
    if have_ref.returncode == 0:
        return True
    have_obj = subprocess.run(["git", "-C", str(bare), "cat-file", "-e", sha],
                              capture_output=True)
    if have_obj.returncode != 0:
        # Try direct fetch of the SHA (reachable from a tip).
        r = subprocess.run(
            ["git", "-C", str(bare), "fetch", "--no-tags", "--depth", "1", "origin", sha],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            # Fallback: fetch PR + branch refs (some commits live on
            # squash-merged PR refs only).
            r2 = subprocess.run(
                ["git", "-C", str(bare), "fetch", "--no-tags", "--depth", "200", "origin",
                 "+refs/pull/*/head:refs/remotes/origin/pr/*",
                 "+refs/heads/*:refs/remotes/origin/*"],
                capture_output=True, text=True,
            )
            if r2.returncode != 0:
                return False
        # Re-check after fetch.
        have_obj = subprocess.run(["git", "-C", str(bare), "cat-file", "-e", sha],
                                  capture_output=True)
        if have_obj.returncode != 0:
            return False
    # Pin the SHA under our own refs/ namespace so `clone --shared` exports it.
    subprocess.run(["git", "-C", str(bare), "update-ref", ref, sha],
                   capture_output=True)
    return True


def clone_at_commit(repo_url: str, sha: str, dest: Path) -> tuple[bool, str | None]:
    """Materialize a working tree at `sha` into `dest`, using a shared bare
    cache so each repo URL is fetched from the network at most once per run.

    Avoids `git clone --shared`: that filters non-standard refs and produces
    an empty clone for SHAs only reachable via `refs/extracted/`. Instead we
    init the destination empty, fetch the SHA from the local bare cache (a
    file-system path, instant), then checkout `FETCH_HEAD`.
    """
    if not repo_url or not sha:
        return False, f"missing repo_url ({repo_url}) or sha ({sha})"
    bare = _ensure_bare_clone(repo_url)
    if bare is None:
        return False, f"bare cache init failed for {repo_url}"
    if not _fetch_sha_into_cache(bare, sha):
        return False, f"fetch failed: {sha} not reachable in {repo_url}"
    # Resolve short SHA → full SHA in the bare cache. `git fetch` over the
    # protocol (or even local) doesn't accept short SHAs; only refs or full
    # 40-char hashes are valid.
    full_sha = subprocess.run(
        ["git", "-C", str(bare), "rev-parse", "--verify", f"{sha}^{{commit}}"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not full_sha:
        full_sha = sha  # last resort

    # Empty init + fetch from the local bare path (no network).
    r = subprocess.run(["git", "init", "-q", str(dest)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"local init failed: {r.stderr[:200].strip()}"
    fr = subprocess.run(
        ["git", "-C", str(dest), "fetch", "-q", "--no-tags", "--depth", "1",
         str(bare), full_sha],
        capture_output=True, text=True,
    )
    if fr.returncode != 0:
        return False, f"local fetch failed: {fr.stderr[:200].strip()}"
    co = subprocess.run(
        ["git", "-C", str(dest), "checkout", "-q", "FETCH_HEAD"],
        capture_output=True, text=True,
    )
    if co.returncode != 0:
        return False, f"checkout failed: {co.stderr[:200].strip()}"
    subprocess.run(["git", "-C", str(dest), "config", "user.email", "extract@local"],
                   capture_output=True)
    subprocess.run(["git", "-C", str(dest), "config", "user.name", "extract"],
                   capture_output=True)
    return True, None


# --- Driver ------------------------------------------------------------------

def extract_one(task_dir: Path, output_root: Path, force: bool) -> dict:
    task_name = task_dir.name
    session_path = task_dir / "original_session.json"
    dockerfile = task_dir / "environment" / "Dockerfile"
    result = {"task": task_name, "status": "?"}

    if not session_path.exists():
        result.update(status="skip", reason="no original_session.json")
        return result

    try:
        session = json.load(open(session_path))
    except Exception as e:
        result.update(status="error", reason=f"session load: {e}")
        return result

    sid = session.get("session_id") or task_name
    source = infer_source(session, task_name)
    out_path = output_root / f"artifacts_{source}" / "canonical_patches" / f"{sid}.json"

    if out_path.exists() and not force:
        result.update(status="cached", path=str(out_path))
        return result

    # On --force, remove any prior OK output for this task across all source
    # dirs (not just the current source). A task whose source-classification
    # or status changed shouldn't leave a phantom record under the old source.
    if force:
        for old in (output_root.glob(f"artifacts_*/canonical_patches/{sid}.json")):
            old.unlink()

    repo_url, base_commit, repo_path = parse_task_dockerfile(dockerfile)
    if not (repo_url and base_commit):
        result.update(status="skip",
                      reason=f"could not parse Dockerfile (repo={repo_url}, sha={base_commit})")
        return result

    # Hyperswitch path (consolidated 2026-05-14): hyperswitch-<N> tasks
    # resolve to a closing PR. `gh pr diff <PR>` is the gold-standard
    # canonical. Tried before Fix A/install_config because hyperswitch tasks
    # don't typically record commit_sha. Returns None for non-hyperswitch
    # tasks or when no closing PR exists — falls through to Fix A.
    hs = try_hyperswitch_issue_pr_diff(task_name, repo_url, base_commit, sid, source)
    if hs is not None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        json.dump(hs, open(out_path, "w"), indent=2)
        result.update(
            status="ok",
            path=str(out_path),
            files=hs["files_changed_count"],
            additions=hs["total_additions"],
            deletions=hs["total_deletions"],
            warnings=0,
            ops=0,
            method="github_pr_diff",
        )
        return result

    # Fix A (2026-05-14): if tests/install_config.json records an upstream
    # commit_sha, that's gold-standard. Fetch the upstream commit diff via
    # `gh api` and skip the lossy tool_replay path entirely. Falls through
    # to tool_replay when install_config has no commit_sha or gh fetch fails.
    upstream = try_upstream_commit_diff(task_dir, repo_url, base_commit,
                                        sid, source, task_name)
    if upstream is not None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        json.dump(upstream, open(out_path, "w"), indent=2)
        result.update(
            status="ok",
            path=str(out_path),
            files=upstream["files_changed_count"],
            additions=upstream["total_additions"],
            deletions=upstream["total_deletions"],
            warnings=0,
            ops=0,
            method="upstream_commit_diff",
        )
        return result

    ops = normalize_messages(session)
    n_mutating = sum(1 for o in ops if (o["tool"] or "").lower() in ALL_MUTATING)
    if n_mutating == 0:
        result.update(status="skip", reason="no mutating tool_uses found")
        return result

    # Reigh-style export: tool_use input is a bare string (just the file path)
    # rather than a dict — no old/new content survives. Replay can recover
    # nothing. Skip cleanly instead of producing a zero-diff "ok".
    n_string_inputs = sum(
        1 for m in session.get("messages", []) if isinstance(m, dict)
        for tu in (m.get("tool_uses") or [])
        if isinstance(tu.get("input"), str)
    )
    n_dict_inputs = sum(
        1 for m in session.get("messages", []) if isinstance(m, dict)
        for tu in (m.get("tool_uses") or [])
        if isinstance(tu.get("input"), dict)
    )
    if n_string_inputs > 0 and n_dict_inputs == 0:
        result.update(
            status="skip",
            reason=f"export stripped tool_use content (all {n_string_inputs} inputs are bare strings)",
        )
        return result

    with tempfile.TemporaryDirectory(prefix="extract-patch-") as tmp:
        wt = Path(tmp)
        ok, err = clone_at_commit(repo_url, base_commit, wt)
        if not ok:
            result.update(status="error", reason=err)
            return result

        warnings = replay_ops(ops, wt, repo_path)
        diff = capture_diff(wt)

    # If replay produced no changes despite mutating ops being present,
    # the extraction failed (anchor mismatch, wrong base commit, stripped
    # content, etc.). Skip cleanly rather than claim a successful zero-diff.
    if diff["files_changed_count"] == 0:
        n_anchor_fail = sum(1 for w in warnings if "old text not found" in w or "hunk anchor not found" in w)
        n_stripped = sum(1 for w in warnings if "stripped" in w or "no old/new text" in w)
        reason = f"replay produced no diff (ops={n_mutating}, warnings={len(warnings)}"
        if n_anchor_fail:
            reason += f", {n_anchor_fail} anchor mismatches"
        if n_stripped:
            reason += f", {n_stripped} stripped"
        reason += ")"
        result.update(status="skip", reason=reason)
        return result

    patch = diff["patch"]
    truncated = False
    if len(patch) > MAX_PATCH_BYTES:
        patch = patch[:MAX_PATCH_BYTES] + f"\n…[truncated at {MAX_PATCH_BYTES} bytes]"
        truncated = True

    # Fidelity tier: how much can downstream trust this as a textual gold patch?
    #   exact       — ≤2 warnings; cross-validated cases (cc-backend, amytis)
    #                 reproduce upstream PRs byte-for-byte at this threshold.
    #   directional — partial recovery: right files, but typically ~50% of
    #                 deletions missing. Use as "did agent touch right files"
    #                 oracle, NOT as exact textual match.
    #   lossy       — most ops failed; patch may misrepresent the real fix.
    n_warn = len(warnings)
    if n_mutating == 0:
        fidelity = "lossy"
    elif n_warn <= 2 and n_warn / max(1, n_mutating) <= 0.15:
        fidelity = "exact"
    elif n_warn / max(1, n_mutating) <= 0.50:
        fidelity = "directional"
    else:
        fidelity = "lossy"

    out = {
        # SWE-chat schema (identical field names + types)
        "session_id": sid,
        "checkpoint_pk": None,
        "commits_in_checkpoint": 1,
        "commit_sha": None,
        "repo_id": _repo_id_from_url(repo_url),
        "is_agent_author": True,
        "files_changed_count": diff["files_changed_count"],
        "total_additions": diff["total_additions"],
        "total_deletions": diff["total_deletions"],
        "commit_message": "[reconstructed from session messages]",
        "files_changed": diff["files_changed"],
        "numstat": diff["numstat"],
        "patch": patch,
        "patch_truncated": truncated,
        "agent_percentage": None,
        # Non-SWE additions (underscore-prefixed, additive)
        "_source": source,
        "_reconstruction": "tool_replay",
        "_fidelity": fidelity,
        "_reconstruction_warnings": warnings,
        "_base_commit": base_commit,
        "_repo_url": repo_url,
        "_task_name": task_name,
        "_n_mutating_ops": n_mutating,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(out_path, "w"), indent=2)

    result.update(
        status="ok",
        path=str(out_path),
        files=diff["files_changed_count"],
        additions=diff["total_additions"],
        deletions=diff["total_deletions"],
        warnings=len(warnings),
        ops=n_mutating,
    )
    return result


def _repo_id_from_url(url: str) -> str:
    parts = url.rstrip("/").split("/")
    if len(parts) >= 2:
        return f"{parts[-2]}/{parts[-1]}"
    return url


# --- Hyperswitch issue→PR→diff path (consolidated from former
#     step4_extract_canonical_patches_hyperswitch.py, 2026-05-14)
# hyperswitch-<N> task names encode an upstream issue number. The merged
# closing PR's `gh pr diff` is gold-standard. Runs before Fix A/install_config
# because hyperswitch tasks don't typically record commit_sha in install_config
# (their canonical comes from the closing PR, not a single commit).

def try_hyperswitch_issue_pr_diff(task_name: str, repo_url: str,
                                  base_commit: str, sid: str,
                                  source: str) -> dict | None:
    """For hyperswitch-<N> tasks: resolve N → closing merged PR → `gh pr diff`.
    Returns a complete SWE-chat-schema canonical dict, or None on any failure
    (caller falls through to install_config / tool_replay)."""
    if source != "hyperswitch":
        return None
    m = HYPERSWITCH_TASK_RE.match(task_name)
    if not m:
        return None
    issue_num = int(m.group(1))

    pr_num, pr_status = _find_hyperswitch_closing_pr(issue_num)
    if pr_num is None:
        return None
    diff_text, err = _fetch_pr_diff(pr_num)
    if err:
        return None

    truncated = False
    if len(diff_text) > MAX_PATCH_BYTES:
        diff_text = diff_text[:MAX_PATCH_BYTES] + f"\n…[truncated at {MAX_PATCH_BYTES} bytes]"
        truncated = True

    summary = _summarize_unified_diff(diff_text)
    return {
        "session_id": sid,
        "checkpoint_pk": None,
        "commits_in_checkpoint": 1,
        "commit_sha": None,
        "repo_id": HYPERSWITCH_UPSTREAM_REPO,
        "is_agent_author": False,
        "files_changed_count": summary["files_changed_count"],
        "total_additions": summary["total_additions"],
        "total_deletions": summary["total_deletions"],
        "commit_message": f"[gold patch from {HYPERSWITCH_UPSTREAM_REPO}#{pr_num} closing #{issue_num}]",
        "files_changed": summary["files_changed"],
        "numstat": summary["numstat"],
        "patch": diff_text,
        "patch_truncated": truncated,
        "agent_percentage": None,
        "_source": source,
        "_reconstruction": "github_pr_diff",
        "_fidelity": "exact",
        "_reconstruction_warnings": [],
        "_base_commit": base_commit,
        "_repo_url": repo_url or f"https://github.com/{HYPERSWITCH_UPSTREAM_REPO}",
        "_task_name": task_name,
        "_n_mutating_ops": 0,
        "_upstream_issue": issue_num,
        "_upstream_pr": pr_num,
        "_pr_lookup_status": pr_status,
    }


def _find_hyperswitch_closing_pr(issue_num: int) -> tuple[int | None, str]:
    """Resolve hyperswitch issue → earliest merged closing PR.
    Returns (pr_num, status_text). pr_num is None when no merged closing PR."""
    r = subprocess.run(
        ["gh", "issue", "view", str(issue_num),
         "--repo", HYPERSWITCH_UPSTREAM_REPO,
         "--json", "closedByPullRequestsReferences,state,closed"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        # Maybe the number is a PR, not an issue.
        rp = subprocess.run(
            ["gh", "pr", "view", str(issue_num),
             "--repo", HYPERSWITCH_UPSTREAM_REPO,
             "--json", "number,state"],
            capture_output=True, text=True,
        )
        if rp.returncode == 0:
            try:
                pr = json.loads(rp.stdout)
                if pr.get("state") == "MERGED":
                    return pr["number"], "issue-number-was-actually-merged-PR"
            except json.JSONDecodeError:
                pass
        return None, f"issue #{issue_num} not found ({r.stderr.strip()[:80]})"
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None, "issue view: invalid JSON"
    refs = data.get("closedByPullRequestsReferences") or []
    if not refs:
        return None, "issue has no closing PR"
    # Pick earliest merged PR (lowest number). Follow-up bugfixes mention the
    # same issue but aren't the closing PR.
    candidates = []
    for ref in refs:
        n = ref.get("number")
        if not n:
            continue
        rp = subprocess.run(
            ["gh", "pr", "view", str(n), "--repo", HYPERSWITCH_UPSTREAM_REPO,
             "--json", "number,state,additions,deletions,changedFiles"],
            capture_output=True, text=True,
        )
        if rp.returncode != 0:
            continue
        try:
            pr = json.loads(rp.stdout)
        except json.JSONDecodeError:
            continue
        if pr.get("state") == "MERGED":
            candidates.append(pr)
    if not candidates:
        return refs[-1]["number"], "no merged PR among closing refs (picking last)"
    candidates.sort(key=lambda x: x["number"])
    return candidates[0]["number"], f"earliest of {len(candidates)} merged closing PRs"


def _fetch_pr_diff(pr_num: int) -> tuple[str, str | None]:
    r = subprocess.run(
        ["gh", "pr", "diff", str(pr_num), "--repo", HYPERSWITCH_UPSTREAM_REPO],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return "", f"gh pr diff #{pr_num} failed: {r.stderr.strip()[:120]}"
    if not r.stdout.strip():
        return "", f"PR #{pr_num} diff is empty"
    return r.stdout, None


# --- Fix A (2026-05-14): install_config.json commit_sha → upstream commit diff
# A material fraction of tasks have the upstream commit SHA recorded in their
# tests/install_config.json. When present, the upstream diff is gold-standard
# (no anchor mismatches, no formatter noise). This path runs before the lossy
# tool_replay reconstruction.

def try_upstream_commit_diff(task_dir: Path, repo_url: str, base_commit: str,
                             sid: str, source: str,
                             task_name: str) -> dict | None:
    """If tests/install_config.json records an upstream commit_sha, fetch the
    raw unified diff for that commit via `gh api` and build a complete
    SWE-chat-schema canonical from it. Returns None on any failure
    (caller falls back to tool_replay).
    """
    cfg_path = task_dir / "tests" / "install_config.json"
    if not cfg_path.exists():
        return None
    try:
        cfg = json.load(open(cfg_path))
    except Exception:
        return None
    commit_sha = cfg.get("commit_sha")
    if not commit_sha or not isinstance(commit_sha, str) or len(commit_sha) < 7:
        return None
    if not repo_url:
        return None
    repo_id = _repo_id_from_url(repo_url)

    # Raw unified diff
    r = subprocess.run(
        ["gh", "api", f"repos/{repo_id}/commits/{commit_sha}",
         "-H", "Accept: application/vnd.github.v3.diff"],
        capture_output=True, text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    diff_text = r.stdout
    truncated = False
    if len(diff_text) > MAX_PATCH_BYTES:
        diff_text = diff_text[:MAX_PATCH_BYTES] + f"\n…[truncated at {MAX_PATCH_BYTES} bytes]"
        truncated = True

    # Commit message (best-effort; not fatal if it fails)
    commit_message = ""
    r2 = subprocess.run(
        ["gh", "api", f"repos/{repo_id}/commits/{commit_sha}",
         "--jq", ".commit.message"],
        capture_output=True, text=True,
    )
    if r2.returncode == 0:
        commit_message = (r2.stdout or "").strip().strip('"')

    summary = _summarize_unified_diff(diff_text)

    return {
        "session_id": sid,
        "checkpoint_pk": None,
        "commits_in_checkpoint": 1,
        "commit_sha": commit_sha,
        "repo_id": repo_id,
        "is_agent_author": False,
        "files_changed_count": summary["files_changed_count"],
        "total_additions": summary["total_additions"],
        "total_deletions": summary["total_deletions"],
        "commit_message": commit_message,
        "files_changed": summary["files_changed"],
        "numstat": summary["numstat"],
        "patch": diff_text,
        "patch_truncated": truncated,
        "agent_percentage": None,
        "_source": source,
        "_reconstruction": "upstream_commit_diff",
        "_fidelity": "exact",
        "_reconstruction_warnings": [],
        "_base_commit": base_commit,
        "_repo_url": repo_url,
        "_task_name": task_name,
        "_n_mutating_ops": 0,
        "_install_config_commit_sha": commit_sha,
    }


def _summarize_unified_diff(diff_text: str) -> dict:
    """Parse a unified-diff blob to recover the same shape git emits for
    --name-status and --numstat (so consumers don't care which extractor ran)."""
    files: list[tuple[str, str]] = []
    numstats: list[tuple[int, int, str]] = []
    cur_file: str | None = None
    cur_add = cur_del = 0
    cur_status = "M"
    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            if cur_file is not None:
                numstats.append((cur_add, cur_del, cur_file))
                files.append((cur_status, cur_file))
            m = re.match(r"diff --git a/(.+) b/(.+)$", raw)
            cur_file = m.group(2) if m else "?"
            cur_add = cur_del = 0
            cur_status = "M"
        elif raw.startswith("new file mode"):
            cur_status = "A"
        elif raw.startswith("deleted file mode"):
            cur_status = "D"
        elif raw.startswith("rename to "):
            cur_status = "R"
        elif raw.startswith("+") and not raw.startswith("+++"):
            cur_add += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            cur_del += 1
    if cur_file is not None:
        numstats.append((cur_add, cur_del, cur_file))
        files.append((cur_status, cur_file))
    return {
        "files_changed_count": len(files),
        "total_additions": sum(a for a, _, _ in numstats),
        "total_deletions": sum(d for _, d, _ in numstats),
        "files_changed": "\n".join(f"{s}\t{p}" for s, p in files),
        "numstat": "\n".join(f"{a}\t{d}\t{p}" for a, d, p in numstats),
    }


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--tasks", default="*",
                    help="Glob over harbor_tasks/<pattern>/ (default: all)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true",
                    help="Re-extract even if cached")
    ap.add_argument("--output-root", default=str(DATA_PIPELINE),
                    help="Output root (default: data-pipeline/)")
    args = ap.parse_args()

    output_root = Path(args.output_root)
    candidates = [d for d in HARBOR_TASKS.iterdir()
                  if d.is_dir() and fnmatch.fnmatch(d.name, args.tasks)]
    candidates.sort()
    if args.limit:
        candidates = candidates[: args.limit]

    print(f"Targeting {len(candidates)} tasks → {output_root}/artifacts_<source>/canonical_patches/")

    counts: dict[str, int] = {}
    t0 = time.time()
    for i, task_dir in enumerate(candidates, 1):
        r = extract_one(task_dir, output_root, args.force)
        st = r["status"]
        counts[st] = counts.get(st, 0) + 1
        if st == "ok":
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} ok "
                  f"({r['files']} files, +{r['additions']}/-{r['deletions']}, "
                  f"ops={r['ops']}, warn={r['warnings']})")
        elif st in ("skip", "cached"):
            tail = r.get("reason") or Path(r.get("path", "")).name
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} {st}: {tail}")
        else:
            print(f"  [{i}/{len(candidates)}] {r['task']:50s} ERROR: {r.get('reason', '?')}")

    print(f"\n=== Done in {time.time()-t0:.1f}s ===")
    for k, v in sorted(counts.items()):
        print(f"  {k:10s}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
