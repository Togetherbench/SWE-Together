#!/usr/bin/env python3
"""Source code verification for gemini-voyager modifier-key task.

Usage: python3 verify.py <repo_path> <log_dir>
Writes verify-results.json to log_dir.
"""
import json
import os
import re
import sys


def verify_source(repo: str) -> dict:
    results = {}

    # ------------------------------------------------------------------
    # 1. Check browser.ts: isMac() and getModifierKey() exports
    # ------------------------------------------------------------------
    browser_path = os.path.join(repo, "src/core/utils/browser.ts")
    if os.path.exists(browser_path):
        with open(browser_path) as f:
            content = f.read()

        results.update(_check_browser_functions(content))
    else:
        results["is-mac-meaningful"] = False
        results["get-modifier-key-meaningful"] = False

    # ------------------------------------------------------------------
    # 2. Check locale files for {modifier} placeholder and new key
    # ------------------------------------------------------------------
    locale_dirs = ["en", "ar", "es", "fr", "ja", "ko", "pt", "ru", "zh", "zh_TW"]
    all_use_modifier = True
    all_have_hint = True

    for loc in locale_dirs:
        path = os.path.join(repo, f"src/locales/{loc}/messages.json")
        if not os.path.exists(path):
            all_use_modifier = False
            all_have_hint = False
            continue
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            all_use_modifier = False
            all_have_hint = False
            continue

        ces = data.get("ctrlEnterSend", {}).get("message", "")
        ceh = data.get("ctrlEnterSendHint", {}).get("message", "")
        icsh = data.get("inputCollapseShortcutHint", {}).get("message", "")

        if "{modifier}" not in ces or "{modifier}" not in ceh:
            all_use_modifier = False
        if not icsh:
            all_have_hint = False

    results["modifier-placeholders"] = all_use_modifier
    results["shortcut-hint-key"] = all_have_hint

    # ------------------------------------------------------------------
    # 3. Check Popup.tsx for getModifierKey usage
    # ------------------------------------------------------------------
    popup_path = os.path.join(repo, "src/pages/popup/Popup.tsx")
    if os.path.exists(popup_path):
        with open(popup_path) as f:
            popup_content = f.read()

        # Check import
        imports_gmk = bool(
            re.search(
                r"import\s+\{[^}]*getModifierKey[^}]*\}\s+from\s+['\"]@/core/utils/browser['\"]",
                popup_content,
            )
        )

        # Check usage: .replace('{modifier}', getModifierKey())
        uses_replace = bool(
            re.search(
                r"\.replace\(['\"]\{modifier\}['\"],\s*getModifierKey\(\)",
                popup_content,
            )
        )

        results["popup-imports-getmodifierkey"] = imports_gmk
        results["popup-uses-replace"] = uses_replace
    else:
        results["popup-imports-getmodifierkey"] = False
        results["popup-uses-replace"] = False

    # ------------------------------------------------------------------
    # 4. Check KeyboardShortcutService.ts formatShortcut()
    # ------------------------------------------------------------------
    kss_path = os.path.join(repo, "src/core/services/KeyboardShortcutService.ts")
    if os.path.exists(kss_path):
        with open(kss_path) as f:
            kss_content = f.read()

        # Check if isMac or getModifierKey is imported/used in this file
        uses_platform = bool(
            re.search(
                r"import\s+\{[^}]*\bisMac\b[^}]*\}\s+from",
                kss_content,
            )
        ) or "isMac()" in kss_content

        results["format-shortcut-platform-aware"] = uses_platform
    else:
        results["format-shortcut-platform-aware"] = False

    return results


def _check_browser_functions(content: str) -> dict:
    """Check isMac() and getModifierKey() functions in browser.ts source."""
    results = {}

    # Check isMac export
    is_mac_match = re.search(r"export\s+function\s+isMac\b", content)
    if is_mac_match:
        body = _extract_function_body(content, is_mac_match.end())
        meaningful_lines = [
            line
            for line in body
            if line and not line.strip().startswith("//") and not line.strip().startswith("*")
        ]
        has_meaningful_body = len(meaningful_lines) >= 3
        uses_navigator = "navigator" in "\n".join(body)
        results["is-mac-meaningful"] = has_meaningful_body and uses_navigator
    else:
        results["is-mac-meaningful"] = False

    # Check getModifierKey export
    gmk_match = re.search(r"export\s+function\s+getModifierKey\b", content)
    if gmk_match:
        body = _extract_function_body(content, gmk_match.end())
        body_text = "\n".join(body)
        calls_is_mac = "isMac()" in body_text or "isMac(" in body_text
        meaningful_lines = [
            line
            for line in body
            if line and not line.strip().startswith("//") and not line.strip().startswith("*")
        ]
        results["get-modifier-key-meaningful"] = (
            calls_is_mac and len(meaningful_lines) >= 1
        )
    else:
        results["get-modifier-key-meaningful"] = False

    return results


def _extract_function_body(content: str, start_pos: int) -> list:
    """Extract function body lines from source starting after function signature."""
    # Find opening brace
    brace_start = content.find("{", start_pos)
    if brace_start < 0:
        return []
    brace_depth = 0
    lines = []
    started = False
    for line in content[brace_start:].split("\n"):
        brace_depth += line.count("{") - line.count("}")
        if not started:
            started = True
            continue
        if brace_depth <= 0:
            break
        lines.append(line)
    return lines


def main():
    if len(sys.argv) < 3:
        print("Usage: verify.py <repo_path> <log_dir>", file=sys.stderr)
        sys.exit(1)

    repo = sys.argv[1]
    logdir = sys.argv[2]

    results = verify_source(repo)

    out_path = os.path.join(logdir, "verify-results.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2)

    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
