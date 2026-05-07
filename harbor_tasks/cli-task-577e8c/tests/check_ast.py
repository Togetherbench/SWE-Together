#!/usr/bin/env python3
"""Structural verifier for opencode.go — checks that the ReadSession method
properly logs warnings when ExtractModifiedFiles fails.

Checks are scoped to the ReadSession function body, not the entire file.
"""
from __future__ import annotations

import argparse
import re
import sys


def extract_function_body(source: str, func_name: str) -> str | None:
    """Extract the body of a Go method/function by tracking brace depth.

    Matches `func (...receiver...) func_name(...) (...returns...) {`.
    Returns the full function text including the signature or None.
    """
    # Match function declaration: func (receiver) Name(...) (returns) {
    pattern = rf'func\s+(?:\(\s*\w+\s+\*?\s*\w+\s*\)\s+)?{re.escape(func_name)}\s*\([^)]*\)\s*(?:\([^)]*\))?\s*{{'
    m = re.search(pattern, source)
    if not m:
        return None

    start = m.start()
    # Count braces from the opening { of the match
    brace_start = m.end() - 1  # position of the opening {
    depth = 0
    i = brace_start
    while i < len(source):
        # Skip string literals and comments
        if source[i] == '"':
            i = _skip_string(source, i, '"')
            continue
        if source[i] == '`':
            i = _skip_string(source, i, '`')
            continue
        if source[i:i+2] == '//':
            eol = source.find('\n', i)
            i = eol + 1 if eol != -1 else len(source)
            continue
        if source[i:i+2] == '/*':
            end = source.find('*/', i+2)
            i = end + 2 if end != -1 else len(source)
            continue

        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[start:i+1]
        i += 1

    return None


def _skip_string(source: str, start: int, quote: str) -> int:
    """Skip a string literal starting at start (which points to the opening quote)."""
    i = start + 1
    while i < len(source):
        if source[i] == '\\':
            i += 2
            continue
        if source[i] == quote:
            return i + 1
        i += 1
    return len(source)


def check_warn_call_present(func_body: str) -> bool:
    """Verify logging.Warn (or similar) is called within ReadSession."""
    patterns = [
        r'logging\.\w+\s*\(',
        r'slog\.\w+\s*\(',
    ]
    for pat in patterns:
        if re.search(pat, func_body):
            return True
    return False


def check_log_has_session_ref(func_body: str) -> bool:
    """Verify the warning log includes a session reference in its arguments."""
    # Look for session_ref, SessionRef, sessionID, or session_id in log call args
    # We find a log call, then look in its argument list
    log_calls = list(re.finditer(
        r'(?:logging\.\w+|slog\.\w+)\s*\(((?:[^()]|\([^)]*\))*)\)',
        func_body,
        re.DOTALL,
    ))
    for call in log_calls:
        args = call.group(1)
        if re.search(r'[Ss]ession[Rr]ef|[Ss]ession_?[Ii][Dd]|"[^"]*session', args):
            return True
    return False


def check_log_has_error(func_body: str) -> bool:
    """Verify the warning log includes error information."""
    log_calls = list(re.finditer(
        r'(?:logging\.\w+|slog\.\w+)\s*\(((?:[^()]|\([^)]*\))*)\)',
        func_body,
        re.DOTALL,
    ))
    for call in log_calls:
        args = call.group(1)
        # Check for err.Error(), err string, or "error" key
        if re.search(r'err\.\w+|"error"|Error\(', args):
            return True
    return False


def check_error_branch_handles(func_body: str) -> bool:
    """Verify the ExtractModifiedFiles error branch does more than
    just `modifiedFiles = nil` — it should have at least one additional
    meaningful statement (e.g., a log call).
    """
    # Find the error handling block for ExtractModifiedFiles
    # Pattern: ExtractModifiedFiles(...) ; err != nil { ... }
    # We already know ReadSession exists. Look for the error branch.
    pattern = r'ExtractModifiedFiles\s*\([^)]*\).*?if\s+err\s*!=\s*nil\s*\{([^}]*)\}'
    m = re.search(pattern, func_body, re.DOTALL)
    if not m:
        return False
    body = m.group(1).strip()
    # Count meaningful statements (not just modifiedFiles = nil)
    meaningful = 0
    for line in body.split('\n'):
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        if 'modifiedFiles' in line and 'nil' in line:
            continue  # This is the fallback assignment
        meaningful += 1
    # At minimum there should be the logging call
    return meaningful >= 1


CHECKS = {
    'warn_call_present': check_warn_call_present,
    'log_has_session_ref': check_log_has_session_ref,
    'log_has_error': check_log_has_error,
    'error_branch_handles': check_error_branch_handles,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file', help='Path to opencode.go')
    ap.add_argument('--check', required=True, choices=list(CHECKS))
    args = ap.parse_args()

    with open(args.file) as f:
        source = f.read()

    func_body = extract_function_body(source, 'ReadSession')
    if func_body is None:
        print(f"ERROR: Could not find ReadSession function in {args.file}")
        sys.exit(1)

    check_fn = CHECKS[args.check]
    if check_fn(func_body):
        print(f"CHECK {args.check}: PASS")
        sys.exit(0)
    else:
        print(f"CHECK {args.check}: FAIL")
        sys.exit(1)


if __name__ == '__main__':
    main()
