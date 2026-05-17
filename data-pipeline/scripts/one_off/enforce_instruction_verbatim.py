#!/usr/bin/env python3
"""Enforce: instruction.md == sanitize_pii(first non-trivial user turn).

Policy (documented in CLAUDE.md, enforced by tests/test_instruction_verbatim.py):

  1. instruction.md MUST equal
     sanitize_pii(extract_first_non_trivial_user_text(messages))
     byte-for-byte (after rstrip of trailing whitespace).

  2. extract_first_non_trivial_user_text(messages):
       - walk user messages in order (messages[0], messages[1], ...)
       - extract text via _content_text_parts (concat type=='text' parts by '\n')
       - if extracted text matches any TRIVIAL_PATTERN, skip and record the
         pattern name
       - first message where text does NOT match any TRIVIAL_PATTERN -> use it
       - if NO non-trivial user message exists -> raise (truly unbenchmarkable)

  3. TRIVIAL_PATTERNS (narrow, byte-deterministic, literal-match only):

       - INTERRUPT_TOOL: whole stripped text == "[Request interrupted by user for tool use]"
       - INTERRUPT:      whole stripped text == "[Request interrupted by user]"
       - CAVEAT_ONLY:    whole stripped text is a single
                         <local-command-caveat>...</local-command-caveat> tag
                         (no content outside the tag)
       - COMMAND_NAME_ONLY: whole stripped text is a single
                            <command-name>...</command-name> tag
                            (no content outside the tag)
       - COMMAND_STANZA: whole stripped text consists exclusively of one or
                         more <command-name>/<command-message>/<command-args>/
                         <command-stdout>/<command-stderr>/<local-command-stdout>/
                         <local-command-stderr> tag-bodies separated by
                         whitespace (no prose outside the tags). When matched,
                         we then inspect the *first* <command-args>...</command-args>
                         body (the only tag that can plausibly carry user
                         prose):
                            * if the body matches a TRIVIAL_ARGS_PATTERN
                              (EMPTY_ARGS, SINGLE_TOKEN_ARGS) -> skip the
                              whole message as protocol metadata and record
                              COMMAND_STANZA_TRIVIAL_ARGS
                            * otherwise -> the args body IS the user's
                              substantive prose; use it as the effective
                              message text (drop the protocol-tag envelope
                              entirely) and record
                              `_instruction_command_args_extracted: true`
       - EMPTY:          whole text is empty/whitespace after stripping

     NO length thresholds, NO semantic predicates. Only literal patterns.

  3a. TRIVIAL_ARGS_PATTERNS (literal-match against the *stripped*
      <command-args> body):

       - EMPTY_ARGS:        body is empty/whitespace
       - SINGLE_TOKEN_ARGS: body is a single non-whitespace run --
                            i.e., a path, filename, flag, identifier, URL,
                            or quoted single token. Anything with internal
                            whitespace is treated as substantive prose and
                            extracted.

  4. sanitize_pii(text): minimal, documented redactions ONLY.
       - /Users/<name>/...   -> <HOST_PATH>
       - /home/<name>/...    -> <HOST_PATH>
       - C:\\Users\\<name>\\...  -> <HOST_PATH>
       - C:\\<name>\\<rest>   -> <HOST_PATH>
       - email@addr.tld      -> <EMAIL>
     No semantic changes, no reshaping, no whitespace normalization,
     no @-mention rewriting, no SWE-rebench unwrapping.

reference_patch.json metadata (only present when applicable):
   - _instruction_pii_redacted: bool
   - _instruction_fallback_msg_index: int (only if != 0)
   - _instruction_trivial_skipped: [<pattern names>] (only if non-empty)
   - _instruction_command_args_extracted: bool (only when True -- means the
     chosen message was a COMMAND_STANZA whose first <command-args> body
     was non-trivial; the instruction text is that args body, not the raw
     stanza)

Default is --dry-run. Pass --apply to overwrite instruction.md and patch
reference_patch.json metadata in place.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
TASKS_DIR = REPO_ROOT / "harbor_tasks"

# Narrow, byte-deterministic trivial-message patterns. Each is a literal
# match against the *stripped* extracted text. No length thresholds, no
# semantic predicates — by design.
TRIVIAL_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("EMPTY", re.compile(r"^\s*$")),
    ("INTERRUPT_TOOL", re.compile(r"^\[Request interrupted by user for tool use\]$")),
    ("INTERRUPT", re.compile(r"^\[Request interrupted by user\]$")),
    (
        "CAVEAT_ONLY",
        re.compile(r"^<local-command-caveat>.*?</local-command-caveat>$", re.DOTALL),
    ),
    (
        "COMMAND_NAME_ONLY",
        re.compile(r"^<command-name>.*?</command-name>$", re.DOTALL),
    ),
    (
        "COMMAND_STANZA",
        # One-or-more <command-*>/<local-command-*> tag-bodies separated by
        # whitespace, with no prose before/between/after. The slash-command
        # protocol metadata envelope: substantive user prose may live inside
        # the <command-args> body (handled by the COMMAND_ARGS_RE +
        # TRIVIAL_ARGS_PATTERNS path); everything else inside the stanza is
        # protocol metadata.
        re.compile(
            r"^\s*(?:<(command-name|command-message|command-args|command-stdout|command-stderr|local-command-stdout|local-command-stderr)>.*?</\1>\s*)+$",
            re.DOTALL,
        ),
    ),
]


# Matches the first <command-args>...</command-args> body in a COMMAND_STANZA.
# Greedy non-newline-blind: DOTALL so the body may span lines. We deliberately
# take only the FIRST match; the protocol allows multiple args tags but in
# practice each stanza only has one. If a stanza has two, we choose the first
# (documented behavior) rather than concatenate -- concatenation would
# introduce a synthesis transform we don't want.
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)


# Literal-match patterns against a *stripped* <command-args> body. If the
# body matches any of these, the whole COMMAND_STANZA message is treated as
# trivial protocol metadata (skip + advance). Otherwise the body IS the
# user's substantive prose and is lifted out of the stanza envelope.
#
# The central rule is SINGLE_TOKEN_ARGS: a single non-whitespace run --
# path, filename, flag, identifier, URL, quoted single token -- has no
# internal whitespace and therefore is not "prose". Any multi-word prose
# contains whitespace and falls through to "substantive".
TRIVIAL_ARGS_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("EMPTY_ARGS", re.compile(r"^\s*$")),
    ("SINGLE_TOKEN_ARGS", re.compile(r"^\s*\S+\s*$")),
]


def _trivial_args_pattern_name(body: str) -> str | None:
    """Return the matching TRIVIAL_ARGS_PATTERN name, or None if body is prose."""
    for name, pat in TRIVIAL_ARGS_PATTERNS:
        if pat.fullmatch(body):
            return name
    return None


# PII redaction regexes. Order matters: Windows paths before generic Users.
_PII_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # /Users/<user>/<rest-no-whitespace>
    (re.compile(r"/Users/[^/\s]+/[^\s\n]*"), "<HOST_PATH>"),
    # /home/<user>/<rest-no-whitespace>
    (re.compile(r"/home/[^/\s]+/[^\s\n]*"), "<HOST_PATH>"),
    # C:\Users\<user>\... up to whitespace
    (re.compile(r"C:\\Users\\[^\s]+"), "<HOST_PATH>"),
    # C:\<topdir>\<rest> -- catches C:\llama.cpp\..., C:\Strawberry\..., etc.
    # Excludes the Users case (handled above) and bare "C:\" with nothing after.
    (re.compile(r"C:\\(?!Users\\)[^\s\\]+\\[^\s]+"), "<HOST_PATH>"),
    # Email addresses: standard pragmatic regex
    (
        re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"),
        "<EMAIL>",
    ),
]


def sanitize_pii(text: str) -> tuple[str, bool]:
    """Apply minimal PII redactions. Returns (new_text, changed_bool)."""
    out = text
    for pat, repl in _PII_PATTERNS:
        out = pat.sub(repl, out)
    return out, (out != text)


def _content_text_parts(content) -> list[str]:
    """Return list of text strings extracted from a content field."""
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        parts: list[str] = []
        for p in content:
            if isinstance(p, dict) and p.get("type") == "text":
                t = p.get("text", "")
                if isinstance(t, str):
                    parts.append(t)
        return parts
    return []


def _trivial_pattern_name(text: str) -> str | None:
    """Return the matching TRIVIAL_PATTERN name, or None if text is non-trivial.

    Match is performed against the stripped text. The first matching pattern
    wins; ordering of TRIVIAL_PATTERNS is therefore semantically meaningful
    (e.g., EMPTY before INTERRUPT_TOOL avoids any ambiguity).
    """
    s = text.strip()
    for name, pat in TRIVIAL_PATTERNS:
        if pat.fullmatch(s):
            return name
    return None


def extract_first_non_trivial_user_text(
    messages: list[dict],
) -> tuple[str, int, list[str], bool]:
    """Return (text, msg_index_used, skipped_pattern_names, args_extracted).

    Walks the message list forward; for each user message, extracts its text
    and checks against TRIVIAL_PATTERNS. The first user message whose text
    does NOT match any pattern wins. Records the names of skipped patterns
    (in walk order) for audit metadata.

    COMMAND_STANZA special case: when a message matches COMMAND_STANZA, we
    inspect the first <command-args>...</command-args> body. If the body is
    trivial (EMPTY_ARGS / SINGLE_TOKEN_ARGS), the whole message is skipped
    and "COMMAND_STANZA_TRIVIAL_ARGS" is recorded. If the body is
    substantive (multi-token prose), the body IS the effective message text:
    we drop the stanza envelope and return the args body. In that case the
    fourth return value (args_extracted) is True.

    Raises ValueError if messages is empty, the first message isn't a user
    message, or every user message in the session is trivial.
    """
    if not messages:
        raise ValueError("empty messages list")
    m0 = messages[0]
    if m0.get("role") != "user":
        raise ValueError(f"first message role is {m0.get('role')!r}, expected 'user'")

    skipped: list[str] = []
    for idx, m in enumerate(messages):
        if m.get("role") != "user":
            continue
        parts = _content_text_parts(m.get("content"))
        text = "\n".join(parts) if parts else ""
        pattern = _trivial_pattern_name(text)

        if pattern is None and parts:
            # Non-trivial AND has at least one text part -> use it as-is.
            return (text, idx, skipped, False)

        if pattern == "COMMAND_STANZA":
            # Inspect first <command-args> body. The protocol envelope is
            # metadata, but its args body may carry the user's substantive
            # prose (the openclaw / unsloth pattern).
            am = COMMAND_ARGS_RE.search(text)
            args_body = am.group(1) if am else ""
            args_pat = _trivial_args_pattern_name(args_body)
            if args_pat is None:
                # Multi-token prose in args -> lift it out of the envelope.
                return (args_body, idx, skipped, True)
            # Trivial args -> whole message is protocol noise.
            skipped.append("COMMAND_STANZA_TRIVIAL_ARGS")
            continue

        if pattern is not None:
            skipped.append(pattern)
            continue
        # parts is empty (no text content at all) -> treat as EMPTY (record
        # and continue). This is the legacy "no text parts" fallback.
        skipped.append("EMPTY")

    raise ValueError(
        "no non-trivial user message found in session "
        f"(skipped {len(skipped)} trivial user messages: {skipped})"
    )


def policy_text_for_task(task_dir: Path) -> tuple[str, dict]:
    """Compute the policy-correct instruction.md content for a task.

    Returns (text, meta) where meta has keys:
      _instruction_pii_redacted: bool
      _instruction_fallback_msg_index: int (only if != 0)
      _instruction_trivial_skipped: [<pattern names>] (only if non-empty)
      _instruction_command_args_extracted: bool (only if True)
    """
    sess_path = task_dir / "original_session.json"
    with sess_path.open() as f:
        d = json.load(f)
    messages = d.get("messages") if isinstance(d, dict) else d

    raw, idx, skipped, args_extracted = extract_first_non_trivial_user_text(messages)
    sanitized, redacted = sanitize_pii(raw)

    meta: dict = {"_instruction_pii_redacted": redacted}
    if idx != 0:
        meta["_instruction_fallback_msg_index"] = idx
    if skipped:
        meta["_instruction_trivial_skipped"] = list(skipped)
    if args_extracted:
        meta["_instruction_command_args_extracted"] = True
    return sanitized, meta


def _diff_summary(old: str, new: str) -> tuple[int, int]:
    """Return (lines_removed, lines_added)."""
    old_lines = old.splitlines()
    new_lines = new.splitlines()
    diff = list(difflib.ndiff(old_lines, new_lines))
    rem = sum(1 for L in diff if L.startswith("- "))
    add = sum(1 for L in diff if L.startswith("+ "))
    return rem, add


def list_tasks() -> list[Path]:
    out = []
    for p in sorted(TASKS_DIR.iterdir()):
        if not p.is_dir():
            continue
        if p.name.startswith("_"):
            continue
        if not (p / "original_session.json").exists():
            continue
        if not (p / "instruction.md").exists():
            continue
        out.append(p)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually write changes (default: dry-run)")
    ap.add_argument("--show-diffs", type=int, default=0, help="show first N unified diffs")
    ap.add_argument("--task", action="append", help="limit to specific task name(s)")
    ns = ap.parse_args(argv)

    tasks = list_tasks()
    if ns.task:
        wanted = set(ns.task)
        tasks = [t for t in tasks if t.name in wanted]

    n_total = len(tasks)
    n_unchanged = 0
    n_changed = 0
    n_redacted = 0
    n_fallback = 0
    n_skipped_any = 0
    n_errors = 0
    changed_records: list[tuple[str, int, int, str, str]] = []
    error_records: list[tuple[str, str]] = []
    fallback_records: list[tuple[str, int, list[str]]] = []
    skipped_records: list[tuple[str, list[str]]] = []
    total_bytes_before = 0
    total_bytes_after = 0
    total_bytes_changed = 0

    for tdir in tasks:
        try:
            new_text, meta = policy_text_for_task(tdir)
        except Exception as e:
            n_errors += 1
            error_records.append((tdir.name, str(e)))
            continue

        ipath = tdir / "instruction.md"
        cur = ipath.read_text()
        cur_r = cur.rstrip()
        new_r = new_text.rstrip()

        total_bytes_before += len(cur.encode("utf-8"))
        total_bytes_after += len(new_r.encode("utf-8")) + 1  # trailing newline

        if meta.get("_instruction_pii_redacted"):
            n_redacted += 1
        if "_instruction_fallback_msg_index" in meta:
            n_fallback += 1
            fallback_records.append(
                (
                    tdir.name,
                    meta["_instruction_fallback_msg_index"],
                    meta.get("_instruction_trivial_skipped", []),
                )
            )
        if meta.get("_instruction_trivial_skipped"):
            n_skipped_any += 1
            skipped_records.append((tdir.name, meta["_instruction_trivial_skipped"]))

        if cur_r == new_r:
            n_unchanged += 1
        else:
            n_changed += 1
            rem, add = _diff_summary(cur_r, new_r)
            changed_records.append((tdir.name, rem, add, cur_r, new_r))
            total_bytes_changed += abs(len(new_r.encode("utf-8")) - len(cur_r.encode("utf-8")))

        # Always update reference_patch.json metadata fields
        rpath = tdir / "reference_patch.json"
        if rpath.exists() and ns.apply:
            with rpath.open() as f:
                rp = json.load(f)
            rp["_instruction_verbatim_enforced"] = True
            rp["_instruction_pii_redacted"] = bool(meta.get("_instruction_pii_redacted"))
            if "_instruction_fallback_msg_index" in meta:
                rp["_instruction_fallback_msg_index"] = meta["_instruction_fallback_msg_index"]
            elif "_instruction_fallback_msg_index" in rp:
                del rp["_instruction_fallback_msg_index"]
            if meta.get("_instruction_trivial_skipped"):
                rp["_instruction_trivial_skipped"] = list(
                    meta["_instruction_trivial_skipped"]
                )
            elif "_instruction_trivial_skipped" in rp:
                del rp["_instruction_trivial_skipped"]
            if meta.get("_instruction_command_args_extracted"):
                rp["_instruction_command_args_extracted"] = True
            elif "_instruction_command_args_extracted" in rp:
                del rp["_instruction_command_args_extracted"]
            # Legacy field cleanup: the old policy recorded a boolean
            # _instruction_artifact for INTERRUPT_TOOL first-turn tasks.
            # That signal is now subsumed by _instruction_trivial_skipped.
            if "_instruction_artifact" in rp:
                del rp["_instruction_artifact"]
            with rpath.open("w") as f:
                json.dump(rp, f, indent=2)
                f.write("\n")

        if ns.apply and cur_r != new_r:
            ipath.write_text(new_r + "\n")

    print(f"Total tasks scanned:        {n_total}")
    print(f"Unchanged (already correct): {n_unchanged}")
    print(f"To change:                   {n_changed}")
    print(f"PII redactions applied in:   {n_redacted}")
    print(f"Fallback to msg[i>0]:        {n_fallback}")
    print(f"Trivial msgs skipped in:     {n_skipped_any} tasks")
    print(f"Extraction errors:           {n_errors}")
    print(f"Total bytes before:          {total_bytes_before}")
    print(f"Total bytes after:           {total_bytes_after}")
    print(f"Total bytes changed (delta): {total_bytes_changed}")
    print()
    if fallback_records:
        print("FALLBACK records (task -> msg_index, patterns_skipped):")
        for n, i, pats in fallback_records:
            print(f"  {n}  -> msg[{i}]  skipped={pats}")
        print()
    if error_records:
        print("EXTRACTION ERRORS:")
        for n, e in error_records:
            print(f"  {n}  -> {e}")
        print()

    if changed_records and not ns.apply:
        print("Per-task diff stats (top 30 by churn):")
        for n, rem, add, _c, _nw in sorted(changed_records, key=lambda r: -(r[1] + r[2]))[:30]:
            print(f"  -{rem:4d}/+{add:4d}  {n}")
        print()

    show = min(ns.show_diffs, len(changed_records))
    for n, _rem, _add, cur_r, new_r in changed_records[:show]:
        print(f"=== diff: {n} ===")
        for line in difflib.unified_diff(
            cur_r.splitlines(),
            new_r.splitlines(),
            fromfile=f"a/{n}/instruction.md",
            tofile=f"b/{n}/instruction.md",
            lineterm="",
            n=2,
        ):
            print(line)
        print()

    mode = "APPLY" if ns.apply else "DRY-RUN"
    print(f"[{mode}] complete.")
    return 0 if n_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
