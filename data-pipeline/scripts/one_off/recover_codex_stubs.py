#!/usr/bin/env python3
"""One-off: recover canonical patches for 3 Codex-format stubs.

The mainline `step4_extract_canonical_patches*.py` extractor dispatches on
snake_case Anthropic-style Edit/Write/MultiEdit tool inputs.  Three sessions
in `harbor_tasks/` use the Codex (opencode) shape instead:

  - `edit` tool with camelCase keys: filePath / oldString / newString / replaceAll
  - `apply_patch` tool with a single `patchText` envelope:
      *** Begin Patch
      *** Update File: <path>
      @@
      -old_line
      +new_line
      *** End Patch

This script:

1. Reads `harbor_tasks/<task>/original_session.json`
2. Iterates messages in order, picks out `edit` and `apply_patch` tool_uses
3. Normalizes Windows / absolute paths to repo-relative paths
4. Materializes a fresh working tree at `_base_commit` from the bare-clone cache
5. Replays edits + applies patches against the worktree
6. Runs `git diff` to produce the canonical unified diff
7. Writes a 15-field canonical JSON to
   `data-pipeline/artifacts_hand_curated/canonical_patches/<sid>.json`

Tasks handled:

  sd-scripts-reg-image-dedup        (3 apply_patch ops, kohya-ss/sd-scripts)
  sd-scripts-skip-resolution-tuple  (23 edit ops,         kohya-ss/sd-scripts)
  triton-windows-rebase-buildhelpers (9 edit ops,         triton-lang/triton)
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
CACHE_ROOT = Path.home() / ".cache" / "canonical-patches" / "repos"
OUT_DIR = ROOT / "data-pipeline" / "artifacts_hand_curated" / "canonical_patches"

# task -> (bare repo dir, repo_url, base_commit, optional path-prefix-strip list)
TASKS: dict[str, dict[str, Any]] = {
    "sd-scripts-reg-image-dedup": {
        "bare": "kohya-ss__sd-scripts.git",
        "repo_url": "https://github.com/kohya-ss/sd-scripts",
        "repo_id": "kohya-ss/sd-scripts",
        "base_commit": "34e7138b6a80c2d88f40c99fd68879c6e683f639",
        "strip_prefixes": ["C:/sd-scripts/", "C:\\sd-scripts\\", "/sd-scripts/"],
    },
    "sd-scripts-skip-resolution-tuple": {
        "bare": "kohya-ss__sd-scripts.git",
        "repo_url": "https://github.com/kohya-ss/sd-scripts",
        "repo_id": "kohya-ss/sd-scripts",
        "base_commit": "48d368fa557731ad0488c07304dfeba8c07910eb",
        "strip_prefixes": ["C:/sd-scripts/", "C:\\sd-scripts\\", "/sd-scripts/"],
    },
    "triton-windows-rebase-buildhelpers": {
        "bare": "triton-lang__triton.git",
        "repo_url": "https://github.com/triton-lang/triton",
        "repo_id": "triton-lang/triton",
        "base_commit": "434aecbe933af6a8d49595d4197bfc3df7618748",
        "strip_prefixes": ["C:/triton/", "C:\\triton\\", "/triton/", "/workspace/triton/"],
    },
}


def normalize_path(p: str, strip_prefixes: list[str]) -> str:
    """Strip Windows / absolute-clone prefixes, return repo-relative POSIX path."""
    if p is None:
        return ""
    s = p.replace("\\", "/").strip()
    for pre in strip_prefixes:
        pre_norm = pre.replace("\\", "/")
        if s.startswith(pre_norm):
            return s[len(pre_norm):]
    # also drop drive letters not in the strip list
    if re.match(r"^[A-Za-z]:/", s):
        # find first "/" after the drive, then trim a leading repo name
        s = s.split("/", 1)[1] if "/" in s else s
        # if path is "sd-scripts/library/foo" or "triton/python/foo" — trim that prefix
        first = s.split("/", 1)[0]
        if first in ("sd-scripts", "triton"):
            s = s.split("/", 1)[1] if "/" in s else ""
    return s.lstrip("/")


# ----- apply_patch envelope parser ----------------------------------------

_HUNK_HEADER = re.compile(r"^@@.*$")


def parse_codex_envelope(text: str) -> list[dict[str, Any]]:
    """Parse a Codex `*** Begin Patch` envelope into per-file file_ops.

    Returns a list of dicts:
       { "action": "update"|"add"|"delete", "path": str, "hunks": [(ctx_old, ctx_new)] }

    Each hunk is a list of lines where the first char is one of ' ', '+', '-'
    (context, addition, deletion). Hunks are split by `@@` markers.
    """
    lines = text.splitlines()
    files: list[dict[str, Any]] = []
    i = 0
    n = len(lines)
    # skip preamble until first *** Update/Add/Delete File:
    while i < n:
        line = lines[i]
        m = re.match(r"^\*\*\* (Update|Add|Delete) File: (.+)$", line)
        if m:
            action = m.group(1).lower()
            path = m.group(2).strip()
            i += 1
            # collect hunks until next file marker or End Patch
            hunks: list[list[str]] = []
            current: list[str] | None = None
            while i < n:
                ln = lines[i]
                if re.match(r"^\*\*\* (Update|Add|Delete) File:", ln) or ln.startswith("*** End Patch"):
                    break
                if ln.startswith("@@"):
                    if current is not None:
                        hunks.append(current)
                    current = []
                    i += 1
                    continue
                if current is None:
                    current = []
                # Codex bodies use ' ', '+', '-' (with leading single char)
                current.append(ln)
                i += 1
            if current is not None:
                hunks.append(current)
            files.append({"action": action, "path": path, "hunks": hunks})
            continue
        i += 1
    return files


def apply_codex_hunk_to_text(text: str, hunk: list[str]) -> tuple[str, str]:
    """Apply one Codex hunk to file text.

    Codex hunks have NO @@ line numbers — they are anchored by their context.
    A hunk is a sequence of lines starting with ' ' (context), '+' (add), '-' (del).
    We rebuild old/new slices from the hunk, then locate old in text and replace
    with new.

    Returns (new_text, reason) where reason is empty on success, non-empty on
    fail.
    """
    old_lines: list[str] = []
    new_lines: list[str] = []
    for ln in hunk:
        if not ln:
            # blank line in hunk = context with empty content
            old_lines.append("")
            new_lines.append("")
            continue
        marker = ln[0]
        body = ln[1:]
        if marker == "+":
            new_lines.append(body)
        elif marker == "-":
            old_lines.append(body)
        elif marker == " ":
            old_lines.append(body)
            new_lines.append(body)
        else:
            # treat unknown leading char as context (defensive)
            old_lines.append(ln)
            new_lines.append(ln)

    old_block = "\n".join(old_lines)
    new_block = "\n".join(new_lines)

    # The hunk applies in the middle of a file; we want to replace one
    # contiguous occurrence of old_block with new_block. Try exact match
    # first; if not found, try ignoring trailing whitespace on each line.
    if old_block in text:
        return text.replace(old_block, new_block, 1), ""

    # fall back: rstrip each line on both sides and try again
    def rstrip_block(s: str) -> str:
        return "\n".join(line.rstrip() for line in s.split("\n"))

    text_rs = rstrip_block(text)
    old_rs = rstrip_block(old_block)
    if old_rs in text_rs:
        # we can't safely splice into the rstripped text; locate the index then
        # work in the original.
        idx = text_rs.find(old_rs)
        # walk char-by-char in original text to find the same offset
        # (this is approximate; we just bail to a regex-style search)
        pat = re.compile(re.escape(old_rs).replace(r"\ ", r"[ \t]*"))
        m = pat.search(text)
        if m:
            return text[: m.start()] + new_block + text[m.end():], ""

    return text, "anchor_not_found"


# ----- main per-task replay -----------------------------------------------

def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True)


def materialize_worktree(bare: Path, commit: str, dest: Path) -> None:
    """Clone-shallow-from-bare and checkout the commit into a fresh worktree.

    We use `git clone --shared --no-local` semantics: actually we just init
    a fresh repo, fetch from the bare, checkout.
    """
    dest.mkdir(parents=True, exist_ok=True)
    run(["git", "init", "-q"], cwd=dest)
    run(["git", "remote", "add", "origin", str(bare)], cwd=dest)
    run(["git", "fetch", "-q", "--depth=1", "origin", commit], cwd=dest)
    run(["git", "checkout", "-q", commit], cwd=dest)


def apply_synthesize_buggy_state(task: str, workdir: Path) -> str:
    """Run the task's synthesize_buggy_state.py against the worktree, if any.

    The synth script uses a hard-coded REPO path (typically /workspace/<repo>);
    we monkey-patch via env + import-from-file with REPO substituted.

    Returns a status string ('applied' | 'absent' | 'skipped:<reason>').
    """
    synth = ROOT / "harbor_tasks" / task / "environment" / "synthesize_buggy_state.py"
    if not synth.exists():
        return "absent"
    src = synth.read_text()
    # Replace the hard-coded REPO path with the temp worktree
    new_src = re.sub(
        r'REPO\s*=\s*Path\(["\'][^"\']+["\']\)',
        f'REPO = Path({str(workdir)!r})',
        src,
        count=1,
    )
    # If the script has no REPO constant, it probably uses cwd-relative paths
    # like `open("library/foo.py")`. In that case we run it as-is with cwd=workdir.
    patched_path = workdir.parent / f"_synth_{task}.py"
    patched_path.write_text(new_src)
    # Run via subprocess so any module-level main() execution stays isolated
    proc = subprocess.run(
        [sys.executable, str(patched_path)],
        cwd=workdir,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return f"skipped:exit{proc.returncode}:{proc.stderr.strip()[:200]}"
    # Stage the synth result as the new "baseline" so git diff captures only
    # session-replay edits on top.
    run(["git", "add", "-A"], cwd=workdir, check=False)
    run(["git", "-c", "user.email=x@x", "-c", "user.name=x", "commit", "-q", "-m", "synth"], cwd=workdir, check=False)
    return "applied"


def recover_task(task: str, cfg: dict[str, Any]) -> dict[str, Any]:
    """Replay Codex ops for one task. Returns a summary dict."""
    print(f"\n=== {task} ===")
    session_path = ROOT / "harbor_tasks" / task / "original_session.json"
    session = json.loads(session_path.read_text())
    sid = session["session_id"]

    bare = CACHE_ROOT / cfg["bare"]
    if not bare.exists():
        return {"task": task, "status": "FAIL", "reason": f"bare cache missing: {bare}"}

    workdir = Path(tempfile.mkdtemp(prefix=f"codex-recover-{task}-"))
    try:
        materialize_worktree(bare, cfg["base_commit"], workdir)
        synth_status = apply_synthesize_buggy_state(task, workdir)
        print(f"  synth: {synth_status}")

        warnings: list[str] = []
        ops_applied = 0
        ops_failed = 0
        edit_count = 0
        patch_count = 0

        for m in session.get("messages", []):
            for tu in m.get("tool_uses") or []:
                tool = tu.get("tool")
                inp = tu.get("input") or {}

                if tool == "edit":
                    edit_count += 1
                    rel = normalize_path(inp.get("filePath") or "", cfg["strip_prefixes"])
                    if not rel:
                        warnings.append("edit: empty path after normalize")
                        ops_failed += 1
                        continue
                    fp = workdir / rel
                    if not fp.exists():
                        warnings.append(f"edit: missing file {rel}")
                        ops_failed += 1
                        continue
                    old_s = inp.get("oldString", "")
                    new_s = inp.get("newString", "")
                    replace_all = bool(inp.get("replaceAll", False))
                    text = fp.read_text()
                    if old_s == "":
                        # opencode "create new file" convention
                        fp.write_text(new_s)
                        ops_applied += 1
                        continue
                    if old_s not in text:
                        warnings.append(f"edit: anchor not found in {rel}")
                        ops_failed += 1
                        continue
                    new_text = text.replace(old_s, new_s, -1 if replace_all else 1)
                    if not replace_all and text.count(old_s) > 1:
                        warnings.append(f"edit: anchor non-unique in {rel} (first match used)")
                    fp.write_text(new_text)
                    ops_applied += 1

                elif tool == "apply_patch":
                    patch_count += 1
                    pt = inp.get("patchText") or ""
                    files = parse_codex_envelope(pt)
                    for fop in files:
                        rel = normalize_path(fop["path"], cfg["strip_prefixes"])
                        if not rel:
                            warnings.append(f"apply_patch: empty path '{fop['path']}'")
                            ops_failed += 1
                            continue
                        fp = workdir / rel
                        action = fop["action"]
                        if action == "delete":
                            if fp.exists():
                                fp.unlink()
                                ops_applied += 1
                            continue
                        if action == "add":
                            new_text = "\n".join(
                                line[1:] if line.startswith("+") else line
                                for hunk in fop["hunks"]
                                for line in hunk
                            )
                            fp.parent.mkdir(parents=True, exist_ok=True)
                            fp.write_text(new_text)
                            ops_applied += 1
                            continue
                        # update
                        if not fp.exists():
                            warnings.append(f"apply_patch: target missing {rel}")
                            ops_failed += 1
                            continue
                        text = fp.read_text()
                        for hunk in fop["hunks"]:
                            new_text, reason = apply_codex_hunk_to_text(text, hunk)
                            if reason:
                                warnings.append(f"apply_patch:{rel}: hunk {reason}")
                                ops_failed += 1
                            else:
                                ops_applied += 1
                                text = new_text
                        fp.write_text(text)

                elif tool == "write":
                    rel = normalize_path(inp.get("filePath") or "", cfg["strip_prefixes"])
                    if not rel:
                        warnings.append("write: empty path")
                        ops_failed += 1
                        continue
                    fp = workdir / rel
                    fp.parent.mkdir(parents=True, exist_ok=True)
                    fp.write_text(inp.get("content", ""))
                    ops_applied += 1
                # else: bash/grep/read/todowrite — ignore

        # generate diff
        run(["git", "add", "-N", "."], cwd=workdir, check=False)
        diff_proc = run(["git", "diff", "HEAD"], cwd=workdir, check=False)
        patch_text = diff_proc.stdout

        numstat_proc = run(["git", "diff", "HEAD", "--numstat"], cwd=workdir, check=False)
        numstat = numstat_proc.stdout
        files_changed_proc = run(["git", "diff", "HEAD", "--name-only"], cwd=workdir, check=False)
        files_changed_count = len([
            ln for ln in files_changed_proc.stdout.splitlines() if ln.strip()
        ])

        # stats
        total_add = total_del = 0
        files_changed_lines: list[str] = []
        for ln in numstat.splitlines():
            parts = ln.split("\t")
            if len(parts) >= 3:
                a, d, _ = parts[0], parts[1], parts[2]
                if a.isdigit():
                    total_add += int(a)
                if d.isdigit():
                    total_del += int(d)
                files_changed_lines.append(ln)

        if not patch_text.strip():
            return {
                "task": task,
                "status": "FAIL",
                "reason": "empty diff after replay",
                "warnings": warnings,
                "edit_count": edit_count,
                "patch_count": patch_count,
                "ops_applied": ops_applied,
                "ops_failed": ops_failed,
            }

        # decide fidelity
        fidelity = "high" if not warnings else "directional"

        # commit message: first user message + last assistant intent
        first_user = ""
        for m in session.get("messages", []):
            if m.get("role") == "user":
                c = m.get("content")
                if isinstance(c, str):
                    first_user = c
                break

        canonical = {
            "session_id": sid,
            "checkpoint_pk": None,
            "commits_in_checkpoint": 1,
            "commit_sha": None,
            "repo_id": cfg["repo_id"],
            "is_agent_author": True,
            "files_changed_count": files_changed_count,
            "total_additions": total_add,
            "total_deletions": total_del,
            "commit_message": first_user.strip()[:200],
            "files_changed": "\n".join(files_changed_lines),
            "numstat": numstat.rstrip(),
            "patch": patch_text,
            "patch_truncated": False,
            "agent_percentage": None,
            "_source": "codex_replay",
            "_reconstruction": "codex_tool_replay",
            "_fidelity": fidelity,
            "_reconstruction_warnings": warnings,
            "_base_commit": cfg["base_commit"],
            "_repo_url": cfg["repo_url"],
            "_task_name": task,
            "_n_mutating_ops": ops_applied,
            "_extraction": {
                "method": "codex_replay",
                "source": "harbor_tasks/<task>/original_session.json (Codex camelCase)",
                "fidelity": fidelity,
                "verified": False,
                "note": (
                    f"Replayed {edit_count} edit + {patch_count} apply_patch ops "
                    f"against {cfg['base_commit'][:10]}; "
                    f"{ops_applied} applied / {ops_failed} failed."
                ),
            },
        }

        out_path = OUT_DIR / f"{sid}.json"
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(canonical, indent=2) + "\n")
        print(f"  WROTE {out_path}")
        print(f"  files_changed={files_changed_count} +{total_add}/-{total_del}  warnings={len(warnings)}")

        return {
            "task": task,
            "status": "SUCCESS",
            "out_path": str(out_path),
            "files_changed_count": files_changed_count,
            "total_additions": total_add,
            "total_deletions": total_del,
            "warnings": warnings,
            "ops_applied": ops_applied,
            "ops_failed": ops_failed,
            "fidelity": fidelity,
            "canonical": canonical,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def update_reference_patch(task: str, recovery: dict[str, Any]) -> None:
    """Promote the recovered canonical into harbor_tasks/<task>/reference_patch.json."""
    rp_path = ROOT / "harbor_tasks" / task / "reference_patch.json"
    canonical = recovery["canonical"]
    promoted = dict(canonical)
    promoted["_canonical_source_path"] = str(
        Path("data-pipeline") / "artifacts_hand_curated" / "canonical_patches" / f"{canonical['session_id']}.json"
    )
    rp_path.write_text(json.dumps(promoted, indent=2) + "\n")
    print(f"  PROMOTED {rp_path}")


def main() -> int:
    results = []
    for task, cfg in TASKS.items():
        try:
            r = recover_task(task, cfg)
        except Exception as exc:
            r = {"task": task, "status": "FAIL", "reason": f"exception: {exc!r}"}
        results.append(r)
        if r["status"] == "SUCCESS":
            update_reference_patch(task, r)

    print("\n=== SUMMARY ===")
    for r in results:
        if r["status"] == "SUCCESS":
            print(
                f"  {r['task']:40s} SUCCESS  files={r['files_changed_count']} "
                f"+{r['total_additions']}/-{r['total_deletions']} "
                f"ops_ok={r['ops_applied']} ops_fail={r['ops_failed']} "
                f"warnings={len(r['warnings'])} fidelity={r['fidelity']}"
            )
        else:
            print(f"  {r['task']:40s} {r['status']}: {r.get('reason')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
