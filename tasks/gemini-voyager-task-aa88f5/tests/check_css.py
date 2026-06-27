#!/usr/bin/env python3
"""CSS structural and behavioral checkers for gemini-voyager import dialog theming.

Usage: python3 check_css.py --test <test-name>

Tests operate on /workspace/gemini-voyager/public/contentStyle.css
and /workspace/gemini-voyager/src/pages/content/folder/manager.ts
"""

import argparse
import re
import sys
from pathlib import Path

CSS_PATH = Path("/workspace/gemini-voyager/public/contentStyle.css")
TS_PATH = Path("/workspace/gemini-voyager/src/pages/content/folder/manager.ts")

# ── CSS parsing helpers ────────────────────────────────────────────────────

def _strip_comments(css: str) -> str:
    """Remove /* ... */ comments from CSS."""
    return re.sub(r'/\*.*?\*/', '', css, flags=re.DOTALL)

def _parse_rules(css: str) -> list[dict]:
    """Parse CSS into a list of {selector, body, media_context} rules.

    Handles nested @media blocks by tracking the media context.
    Returns flat list of rules with their effective selectors and bodies.
    """
    css = _strip_comments(css)
    rules = []

    # Find top-level blocks (selectors + @media)
    pos = 0
    while pos < len(css):
        # Skip whitespace
        while pos < len(css) and css[pos] in ' \t\n\r':
            pos += 1
        if pos >= len(css):
            break

        # Check for @media
        media_match = re.match(r'@media\s+([^{]+)\{', css[pos:])
        if media_match:
            media_query = media_match.group(1).strip()
            # Find the matching closing brace for this @media block
            body_start = pos + media_match.end()
            body_end = _find_matching_brace(css, body_start - 1)
            media_body = css[body_start:body_end]
            # Parse rules inside @media
            for inner in _parse_rules(media_body):
                inner['media_context'] = media_query
                rules.append(inner)
            pos = body_end + 1
            continue

        # Check for regular selector block
        sel_match = re.match(r'([^{]+)\{', css[pos:])
        if sel_match:
            selector = sel_match.group(1).strip()
            body_start = pos + sel_match.end()
            body_end = _find_matching_brace(css, body_start - 1)
            body = css[body_start:body_end]
            rules.append({
                'selector': selector,
                'body': body,
                'media_context': None,
            })
            pos = body_end + 1
            continue

        pos += 1

    return rules

def _find_matching_brace(s: str, open_pos: int) -> int:
    """Given position of an opening brace, find the matching closing brace."""
    depth = 1
    pos = open_pos + 1
    while pos < len(s) and depth > 0:
        if s[pos] == '{':
            depth += 1
        elif s[pos] == '}':
            depth -= 1
        pos += 1
    return pos - 1  # position of closing brace

def _get_declarations(body: str) -> dict[str, str]:
    """Extract property: value pairs from a rule body."""
    decls = {}
    # Split by semicolons, but handle nested functions
    parts = re.split(r';(?![^(]*\))', body)
    for part in parts:
        part = part.strip()
        if ':' in part:
            prop, _, val = part.partition(':')
            decls[prop.strip().lower()] = val.strip()
    return decls

def _selector_has_theme(selector: str, theme: str) -> bool:
    """Check if selector contains a theme selector (.theme-host.<theme> or body.<theme>)."""
    patterns = [
        f'.theme-host.{theme}',
        f'body.{theme}',
    ]
    for p in patterns:
        if p in selector:
            return True
    return False

def _selector_has_class(selector: str, cls: str) -> bool:
    """Check if selector targets a specific CSS class."""
    # Check for .classname as a class selector (not part of another word)
    return bool(re.search(rf'\.{re.escape(cls)}(?![-\w])', selector))

# ── Individual tests ───────────────────────────────────────────────────────

def test_dialog_title_light(css_rules: list[dict]) -> bool:
    """Dialog title has light-theme override with dark text color."""
    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_class(sel, 'gv-folder-dialog-title'):
            continue
        if not _selector_has_theme(sel, 'light-theme'):
            continue
        if not _selector_has_class(sel, 'gv-folder-import-dialog'):
            continue
        # Check for a dark-ish color value
        decls = _get_declarations(rule['body'])
        if 'color' in decls:
            color_val = decls['color'].lower()
            # Should not be white or near-white
            if _is_dark_text_color(color_val):
                return True
    return False

def test_strategy_label_light(css_rules: list[dict]) -> bool:
    """Strategy label has light-theme override."""
    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_class(sel, 'gv-folder-import-strategy-label'):
            continue
        if not _selector_has_theme(sel, 'light-theme'):
            continue
        return True
    return False

def test_radio_options_light(css_rules: list[dict]) -> bool:
    """Radio options have light-theme overrides for both border and text color."""
    has_border_override = False
    has_text_override = False

    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_theme(sel, 'light-theme'):
            continue

        if _selector_has_class(sel, 'gv-folder-import-radio-option') and 'span' not in sel:
            # Radio option border/background
            decls = _get_declarations(rule['body'])
            if 'border-color' in decls:
                has_border_override = True

        if _selector_has_class(sel, 'gv-folder-import-radio-option') and 'span' in sel:
            # Radio option text
            decls = _get_declarations(rule['body'])
            if 'color' in decls and _is_dark_text_color(decls['color']):
                has_text_override = True

    return has_border_override and has_text_override

def test_dialog_buttons_light(css_rules: list[dict]) -> bool:
    """Primary and secondary dialog buttons have light-theme overrides."""
    has_primary = False
    has_secondary = False

    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_theme(sel, 'light-theme'):
            continue

        if _selector_has_class(sel, 'gv-folder-dialog-btn-primary'):
            decls = _get_declarations(rule['body'])
            if 'background' in decls or 'color' in decls:
                has_primary = True

        if _selector_has_class(sel, 'gv-folder-dialog-btn-secondary'):
            decls = _get_declarations(rule['body'])
            if 'color' in decls or 'border-color' in decls:
                has_secondary = True

    return has_primary and has_secondary

def test_file_elements_light(css_rules: list[dict]) -> bool:
    """File name and file button have light-theme overrides."""
    has_name = False
    has_button = False

    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_theme(sel, 'light-theme'):
            continue

        if _selector_has_class(sel, 'gv-folder-import-file-name'):
            decls = _get_declarations(rule['body'])
            if 'color' in decls or 'background' in decls:
                has_name = True

        if _selector_has_class(sel, 'gv-folder-import-file-button'):
            decls = _get_declarations(rule['body'])
            if 'background' in decls or 'color' in decls:
                has_button = True

    return has_name and has_button

def test_menu_item_flex(css_rules: list[dict]) -> bool:
    """Menu item uses display:flex and align-items:center."""
    for rule in css_rules:
        sel = rule['selector']
        # Match .gv-folder-menu-item (not combined with other classes)
        stripped = sel.strip()
        if not re.match(r'^\.gv-folder-menu-item\s*$', stripped):
            # Also check combined selectors
            if not _selector_has_class(sel, 'gv-folder-menu-item'):
                continue

        decls = _get_declarations(rule['body'])
        display_val = decls.get('display', '')
        if 'flex' not in display_val.split():
            display_val = ''

        has_align = 'align-items' in decls

        if display_val and has_align:
            return True

    return False

def test_css_valid(css_rules: list[dict]) -> bool:
    """CSS file is syntactically valid (we successfully parsed it)."""
    # If we got here without exceptions and have a reasonable number of rules,
    # the CSS is likely valid. Also check brace balance.
    css = CSS_PATH.read_text(errors='ignore')
    css_no_comment = _strip_comments(css)
    opens = css_no_comment.count('{')
    closes = css_no_comment.count('}')
    return opens == closes and opens > 100  # Must have many rules

def test_dark_theme_intact(css_rules: list[dict]) -> bool:
    """At least 3 dark-theme overrides still exist for import dialog elements."""
    import_classes = [
        'gv-folder-import-dialog',
        'gv-folder-dialog-title',
        'gv-folder-import-strategy-label',
        'gv-folder-import-radio-option',
        'gv-folder-import-file-name',
        'gv-folder-import-file-button',
        'gv-folder-dialog-btn-primary',
        'gv-folder-dialog-btn-secondary',
    ]

    count = 0
    seen = set()
    for rule in css_rules:
        sel = rule['selector']
        if not _selector_has_theme(sel, 'dark-theme'):
            continue
        for cls in import_classes:
            if _selector_has_class(sel, cls) and cls not in seen:
                seen.add(cls)
                count += 1

    return count >= 3

# ── Color helpers ──────────────────────────────────────────────────────────

def _is_dark_text_color(color: str) -> bool:
    """Check if a color value represents a dark (non-white) text color.

    Handles oklch(), rgb(), hex, and named colors.
    """
    color = color.strip().lower()

    # oklch(L C H) — low L means dark
    m = re.match(r'oklch\(([\d.]+)', color)
    if m:
        L = float(m.group(1))
        return L < 0.8  # L < 0.8 means dark-ish

    # oklch(L C H / alpha)
    m = re.match(r'oklch\(([\d.]+)\s+[\d.]+\s+[\d.]+', color)
    if m:
        L = float(m.group(1))
        return L < 0.8

    # rgb(r, g, b)
    m = re.match(r'rgb\((\d+),\s*(\d+),\s*(\d+)\)', color)
    if m:
        r, g, b = int(m.group(1)), int(m.group(2)), int(m.group(3))
        # Average below 180 is dark
        return (r + g + b) / 3 < 180

    # Hex colors
    if color.startswith('#'):
        hex_val = color.lstrip('#')
        if len(hex_val) == 3:
            r = int(hex_val[0] * 2, 16)
            g = int(hex_val[1] * 2, 16)
            b = int(hex_val[2] * 2, 16)
        elif len(hex_val) == 6:
            r = int(hex_val[0:2], 16)
            g = int(hex_val[2:4], 16)
            b = int(hex_val[4:6], 16)
        else:
            return True  # give benefit of doubt
        return (r + g + b) / 3 < 180

    # Named colors
    light_colors = {'white', 'snow', 'ivory', 'azure', 'beige', 'bisque',
                    'cornsilk', 'floralwhite', 'ghostwhite', 'honeydew',
                    'lavenderblush', 'lemonchiffon', 'lightyellow', 'linen',
                    'mintcream', 'oldlace', 'papayawhip', 'seashell',
                    'whitesmoke', 'aliceblue'}
    if color in light_colors:
        return False

    return True  # give benefit of doubt for unknown colors

# ── Main ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--test', required=True)
    args = parser.parse_args()

    test_name = args.test

    # Tests that operate on CSS
    css_tests = {
        'dialog-title-light': test_dialog_title_light,
        'strategy-label-light': test_strategy_label_light,
        'radio-options-light': test_radio_options_light,
        'dialog-buttons-light': test_dialog_buttons_light,
        'file-elements-light': test_file_elements_light,
        'menu-item-flex': test_menu_item_flex,
        'css-valid': test_css_valid,
        'dark-theme-intact': test_dark_theme_intact,
    }

    if test_name in css_tests:
        if not CSS_PATH.exists():
            print(f"FATAL: CSS file not found at {CSS_PATH}")
            sys.exit(1)
        try:
            rules = _parse_rules(CSS_PATH.read_text(errors='ignore'))
        except Exception as e:
            print(f"FATAL: Could not parse CSS: {e}")
            sys.exit(1)

        try:
            result = css_tests[test_name](rules)
        except Exception as e:
            print(f"FATAL: Test {test_name} errored: {e}")
            sys.exit(1)

        sys.exit(0 if result else 1)
    else:
        print(f"FATAL: Unknown test: {test_name}")
        sys.exit(1)

if __name__ == '__main__':
    main()
