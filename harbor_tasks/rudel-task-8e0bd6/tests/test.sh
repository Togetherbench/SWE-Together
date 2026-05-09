#!/bin/bash
# =============================================================================
# Harbor verification for rudel-task-8e0bd6
#
# Feature: Add export/share buttons with watermark to dashboard charts
# CI source: .github/workflows/ci.yml → bunx turbo run lint check-types test build
#
# At base commit aa38a30fe, the dashboard pages use bare <AnalyticsCard> +
# manual <h2>/<p> headers for chart sections. The agent must add:
#   1. html-to-image + sonner to apps/web/package.json
#   2. apps/web/src/lib/screenshot.ts (capture + share utilities)
#   3. apps/web/src/components/analytics/ChartCard.tsx (new wrapper component)
#   4. sonner <Toaster /> to DashboardLayout
#   5. Replace AnalyticsCard → ChartCard in dashboard chart sections
# =============================================================================
set +e

REPO="/workspace/rudel"
WEB="$REPO/apps/web"
SRC="$WEB/src"
REWARD="/logs/verifier/reward.txt"
RESULTS="/logs/verifier/gates.json"

mkdir -p "$(dirname "$REWARD")" "$(dirname "$RESULTS")"
echo "0.0" > "$REWARD"
echo "{}" > "$RESULTS"

# ---------------------------------------------------------------------------
# Helper: write gate verdict to results JSON
# ---------------------------------------------------------------------------
emit_verdict() {
    local gid="$1" passed="$2" detail="$3"
    python3 -c "
import json, sys
try:
    with open('$RESULTS') as f:
        r = json.load(f)
except:
    r = {}
r['$gid'] = {'passed': $([ "$passed" = "true" ] && echo 'True' || echo 'False'), 'detail': '''$detail'''}
with open('$RESULTS','w') as f:
    json.dump(r, f, indent=2)
"
}

# ===========================================================================
# P2P REGRESSION GATES (any failure → reward = 0.0)
# ===========================================================================
p2p_failed=false

# p2p_regression_1: AnalyticsCard.tsx must still exist
if [ ! -f "$SRC/components/analytics/AnalyticsCard.tsx" ]; then
    echo "P2P REGRESSION FAIL: AnalyticsCard.tsx was deleted — it is used by StatCard and other non-chart cards"
    p2p_failed=true
fi

# p2p_regression_2: package.json must be valid JSON
if ! python3 -c "import json; json.load(open('$WEB/package.json'))" 2>/dev/null; then
    echo "P2P REGRESSION FAIL: package.json is not valid JSON"
    p2p_failed=true
fi

# p2p_regression_3: No obvious broken import paths in key files
python3 <<'PYEOF'
import os, re, json, sys

src = os.environ.get("SRC", "/workspace/rudel/apps/web/src")
errors = []

# Check ChartCard.tsx if it exists
chartcard = os.path.join(src, "components/analytics/ChartCard.tsx")
if os.path.exists(chartcard):
    with open(chartcard) as f:
        content = f.read()
    # Check for broken relative imports
    for m in re.finditer(r'from\s+["\']([^"\']+)["\']', content):
        imp = m.group(1)
        if imp.startswith('.') and '..' in imp:
            # Relative imports with too many levels
            if imp.count('..') > 3:
                errors.append(f"ChartCard.tsx: suspicious deep relative import: {imp}")

# Check screenshot.ts if it exists
sst = os.path.join(src, "lib/screenshot.ts")
if os.path.exists(sst):
    with open(sst) as f:
        content = f.read()
    if 'import' in content and 'html-to-image' not in content:
        errors.append("screenshot.ts: imports something but not html-to-image")

if errors:
    print("P2P REGRESSION FAIL:")
    for e in errors:
        print(f"  {e}")
    sys.exit(1)
else:
    print("P2P regression check passed")
PYEOF
if [ $? -ne 0 ]; then
    p2p_failed=true
fi

# ===========================================================================
# F2P GATE DEFINITIONS
# ===========================================================================
declare -A WEIGHTS
WEIGHTS["f2p_pkg_deps"]="0.15"
WEIGHTS["f2p_screenshot_lib"]="0.20"
WEIGHTS["f2p_chartcard_comp"]="0.25"
WEIGHTS["f2p_page_usage"]="0.20"
WEIGHTS["f2p_toaster"]="0.20"

declare -A VERDICTS

# ===========================================================================
# F2P GATE CHECKS (each gate = Python analysis script)
# ===========================================================================

# --- f2p_pkg_deps (0.15): html-to-image + sonner in package.json dependencies ---
python3 <<'PYEOF'
import json, os
web = os.environ.get("WEB", "/workspace/rudel/apps/web")
pkg_path = os.path.join(web, "package.json")
with open(pkg_path) as f:
    pkg = json.load(f)
deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
missing = []
for dep in ("html-to-image", "sonner"):
    if dep not in deps:
        missing.append(dep)
if missing:
    print(f"MISSING_DEPENDENCIES: {', '.join(missing)}")
    exit(1)
# Also check version strings are non-empty
for dep in ("html-to-image", "sonner"):
    ver = deps.get(dep, "")
    if not ver or ver == "*":
        missing.append(f"{dep}: empty version")
if missing:
    print(f"MISSING_DEPENDENCIES: {', '.join(missing)}")
    exit(1)
print("OK: html-to-image and sonner both present with version specs")
PYEOF
if [ $? -eq 0 ]; then
    VERDICTS["f2p_pkg_deps"]="true"
else
    VERDICTS["f2p_pkg_deps"]="false"
fi
emit_verdict "f2p_pkg_deps" "${VERDICTS[f2p_pkg_deps]}" "Verifies html-to-image and sonner deps"

# --- f2p_screenshot_lib (0.20): screenshot.ts with 4 non-stub functions ---
python3 <<'PYEOF'
import os, re, sys

src = os.environ.get("SRC", "/workspace/rudel/apps/web/src")
sst_path = os.path.join(src, "lib", "screenshot.ts")

if not os.path.exists(sst_path):
    print("MISSING: apps/web/src/lib/screenshot.ts does not exist")
    sys.exit(1)

with open(sst_path) as f:
    content = f.read()

# Required exports
required_exports = {
    "captureElement": False,
    "copyToClipboard": False,
    "downloadAsImage": False,
    "shareToX": False,
}

# Check for export declarations of each function
for fn_name in required_exports:
    pat = rf'(?:export\s+(?:async\s+)?function\s+{fn_name}|export\s+const\s+{fn_name}\s*=)'
    if re.search(pat, content):
        required_exports[fn_name] = True

missing = [k for k, v in required_exports.items() if not v]
if missing:
    print(f"MISSING_EXPORTS: {', '.join(missing)}")
    sys.exit(1)

# Anti-stub check: each exported function must have meaningful body
# Count non-trivial statements in each function body
for fn_name in required_exports:
    # Extract function body (everything from opening { to matching })
    pat = rf'(?:export\s+(?:async\s+)?function\s+{fn_name}\s*\([^)]*\)|export\s+const\s+{fn_name}\s*=\s*(?:async\s*)?\([^)]*\)\s*=>)\s*\{{([\s\S]*?)\n\}'
    m = re.search(pat, content)
    if not m:
        # Try arrow function with different pattern
        pat = rf'export\s+(?:async\s+)?function\s+{fn_name}\s*[^{{]*\{{([\s\S]*?)\n^\}}'
        m = re.search(pat, content, re.MULTILINE)
    if m:
        body = m.group(1).strip()
        # Count non-empty, non-comment lines
        lines = [l.strip() for l in body.split('\n') if l.strip() and not l.strip().startswith('//')]
        if len(lines) < 3:
            print(f"STUB: {fn_name} has only {len(lines)} meaningful lines (need ≥3)")
            sys.exit(1)
    else:
        print(f"STUB: Cannot extract body for {fn_name}")
        sys.exit(1)

# Check import from html-to-image
if 'html-to-image' not in content:
    print("MISSING: html-to-image import")
    sys.exit(1)

print("OK: screenshot.ts exports all 4 functions with non-trivial implementations")
PYEOF
if [ $? -eq 0 ]; then
    VERDICTS["f2p_screenshot_lib"]="true"
else
    VERDICTS["f2p_screenshot_lib"]="false"
fi
emit_verdict "f2p_screenshot_lib" "${VERDICTS[f2p_screenshot_lib]}" "Verifies screenshot.ts with 4 non-stub exports"

# --- f2p_chartcard_comp (0.25): ChartCard.tsx structure and behavior ---
python3 <<'PYEOF'
import os, re, sys

src = os.environ.get("SRC", "/workspace/rudel/apps/web/src")
cc_path = os.path.join(src, "components", "analytics", "ChartCard.tsx")

if not os.path.exists(cc_path):
    print("MISSING: ChartCard.tsx does not exist")
    sys.exit(1)

with open(cc_path) as f:
    content = f.read()

checks = {
    "wraps_AnalyticsCard": False,
    "has_title_prop": False,
    "has_description_prop": False,
    "has_children_prop": False,
    "has_shareable_prop": False,
    "has_watermark_branding": False,
    "has_obsessiondb_branding": False,
    "has_dropdown_share": False,
    "imports_screenshot": False,
    "imports_sonner_toast": False,
    "has_clipboard_action": False,
    "has_download_action": False,
    "has_share_x_action": False,
}

# Check imports
checks["imports_screenshot"] = bool(re.search(r'from\s+["\']\.\.\/\.\.\/lib\/screenshot["\']|from\s+["\']@\/lib\/screenshot["\']|from\s+["\'][^"\']*screenshot["\']', content))
checks["imports_sonner_toast"] = 'sonner' in content and ('toast' in content.lower())

# Check component props interface
if 'title' in content:
    checks["has_title_prop"] = bool(re.search(r'title\s*[?:]\s*string', content))
if 'description' in content:
    checks["has_description_prop"] = bool(re.search(r'description\?\s*:\s*string', content) or 'description' in content.lower())
checks["has_children_prop"] = bool(re.search(r'children\s*[?:]\s*React(?:\.)?Node', content))
checks["has_shareable_prop"] = bool(re.search(r'shareable\??\s*:\s*boolean', content))

# Check AnalyticsCard wrapping
checks["wraps_AnalyticsCard"] = bool(re.search(r'<AnalyticsCard', content))

# Check branding/watermark
checks["has_watermark_branding"] = 'rudel.ai' in content or 'rudel' in content.lower()
checks["has_obsessiondb_branding"] = 'ObsessionDB' in content or 'obsessiondb' in content.lower() or 'obsession' in content.lower()

# Check dropdown menu
checks["has_dropdown_share"] = 'DropdownMenu' in content

# Check specific actions
checks["has_clipboard_action"] = 'clipboard' in content.lower() or 'Clipboard' in content or 'copy' in content.lower()
checks["has_download_action"] = 'download' in content.lower() or 'Download' in content
checks["has_share_x_action"] = 'twitter' in content.lower() or 'Twitter' in content or 'shareToX' in content or 'intent/tweet' in content

# Count passed checks
passed = sum(1 for v in checks.values() if v)
total = len(checks)
required = 9  # At least 9 of 13 checks must pass

if passed < required:
    print(f"FAILED: Only {passed}/{total} structural checks passed (need ≥{required})")
    for k, v in sorted(checks.items()):
        print(f"  {'✓' if v else '✗'} {k}")
    sys.exit(1)

# Component must be a function component
is_function = bool(re.search(r'export\s+function\s+\w+|export\s+const\s+\w+\s*=\s*(?:\(|\w+\s*=>)', content))
if not is_function:
    print("FAILED: ChartCard is not exported as a function component")
    sys.exit(1)

print(f"OK: ChartCard passes {passed}/{total} structural checks")
PYEOF
if [ $? -eq 0 ]; then
    VERDICTS["f2p_chartcard_comp"]="true"
else
    VERDICTS["f2p_chartcard_comp"]="false"
fi
emit_verdict "f2p_chartcard_comp" "${VERDICTS[f2p_chartcard_comp]}" "Verifies ChartCard component structure"

# --- f2p_page_usage (0.20): dashboard pages import ChartCard ---
python3 <<'PYEOF'
import os, re, sys

src = os.environ.get("SRC", "/workspace/rudel/apps/web/src")
pages_dir = os.path.join(src, "pages", "dashboard")

if not os.path.isdir(pages_dir):
    print("MISSING: dashboard pages directory")
    sys.exit(1)

pages_with_chartcard = []
pages_without = []
all_pages = []

for fname in sorted(os.listdir(pages_dir)):
    if not fname.endswith('.tsx'):
        continue
    fpath = os.path.join(pages_dir, fname)
    with open(fpath) as f:
        content = f.read()
    all_pages.append(fname)
    if 'ChartCard' in content:
        pages_with_chartcard.append(fname)
    else:
        pages_without.append(fname)

# Expected: at least 6 pages should use ChartCard
# (the canonical patch updates 8 pages: Overview, ProjectsList, DevelopersList,
#  SessionsList, Errors, Learnings, ROI, ProjectDetail, DeveloperDetail)
min_required = 6
if len(pages_with_chartcard) < min_required:
    print(f"FAILED: Only {len(pages_with_chartcard)} pages import ChartCard (need ≥{min_required})")
    print(f"  Pages with ChartCard: {pages_with_chartcard}")
    print(f"  Pages without: {pages_without}")
    sys.exit(1)

# Verify each page with ChartCard also uses <ChartCard> JSX (not just the import)
pages_with_jsx = []
for fname in pages_with_chartcard:
    fpath = os.path.join(pages_dir, fname)
    with open(fpath) as f:
        content = f.read()
    if re.search(r'<ChartCard\b', content):
        pages_with_jsx.append(fname)

if len(pages_with_jsx) < min_required:
    print(f"FAILED: Only {len(pages_with_jsx)} pages use <ChartCard> JSX (need ≥{min_required})")
    sys.exit(1)

print(f"OK: {len(pages_with_jsx)} dashboard pages use <ChartCard> component")
PYEOF
if [ $? -eq 0 ]; then
    VERDICTS["f2p_page_usage"]="true"
else
    VERDICTS["f2p_page_usage"]="false"
fi
emit_verdict "f2p_page_usage" "${VERDICTS[f2p_page_usage]}" "Verifies dashboard pages use ChartCard"

# --- f2p_toaster (0.20): DashboardLayout imports/renders Toaster from sonner ---
python3 <<'PYEOF'
import os, re, sys

src = os.environ.get("SRC", "/workspace/rudel/apps/web/src")
layout_path = os.path.join(src, "layouts", "DashboardLayout.tsx")

if not os.path.exists(layout_path):
    print("MISSING: DashboardLayout.tsx")
    sys.exit(1)

with open(layout_path) as f:
    content = f.read()

# Check sonner import
if 'sonner' not in content:
    print("FAILED: sonner not imported in DashboardLayout")
    sys.exit(1)

# Check Toaster component usage
if 'Toaster' not in content:
    print("FAILED: <Toaster /> not found in DashboardLayout")
    sys.exit(1)

# Check <Toaster is rendered
if not re.search(r'<Toaster\b', content):
    print("FAILED: <Toaster /> JSX not rendered in DashboardLayout")
    sys.exit(1)

# Check for richColors prop (optional, but indicates proper setup)
has_rich = 'richColors' in content
has_position = bool(re.search(r'position\s*=', content))

print(f"OK: DashboardLayout uses <Toaster /> from sonner (richColors={has_rich}, position={has_position})")
PYEOF
if [ $? -eq 0 ]; then
    VERDICTS["f2p_toaster"]="true"
else
    VERDICTS["f2p_toaster"]="false"
fi
emit_verdict "f2p_toaster" "${VERDICTS[f2p_toaster]}" "Verifies Toaster integration in DashboardLayout"

# ===========================================================================
# REWARD COMPUTATION (weighted-replace formula)
# ===========================================================================

# P2P regression gate: if any failed, reward = 0
if [ "$p2p_failed" = "true" ]; then
    echo "0.0" > "$REWARD"
    echo "VERIFIER_RESULT: p2p_regression_failed" >> "$REWARD"
    exit 0
fi

# Check if any F2P passed
any_f2p=false
for gid in "${!VERDICTS[@]}"; do
    if [ "${VERDICTS[$gid]}" = "true" ]; then
        any_f2p=true
        break
    fi
done

if [ "$any_f2p" = "false" ]; then
    echo "0.0" > "$REWARD"
    exit 0
fi

# Compute reward using weighted-replace formula
python3 <<PYEOF
import json, os

weights = {
    "f2p_pkg_deps": 0.15,
    "f2p_screenshot_lib": 0.20,
    "f2p_chartcard_comp": 0.25,
    "f2p_page_usage": 0.20,
    "f2p_toaster": 0.20,
}

# Read verdicts from results file
results_path = "$RESULTS"
with open(results_path) as f:
    results = json.load(f)

verdicts = {}
for gid in weights:
    verdicts[gid] = results.get(gid, {}).get("passed", False)

# Read existing reward
reward_path = "$REWARD"
try:
    with open(reward_path) as f:
        existing_str = f.read().strip()
    # Parse numeric value
    import re
    m = re.search(r'(\d+\.?\d*)', existing_str)
    existing = float(m.group(1)) if m else 0.0
except:
    existing = 0.0

weights_sum = sum(weights.values())
inner_weight = max(0.0, 1.0 - weights_sum)

reward = existing * inner_weight
for gid, w in weights.items():
    if verdicts.get(gid, False):
        reward += w

reward = round(reward, 4)
with open(reward_path, 'w') as f:
    f.write(f"{reward}\\n")
print(f"FINAL_REWARD: {reward}")
print(f"Gates passed: {sum(1 for v in verdicts.values() if v)}/{len(verdicts)}")
PYEOF

# Write final gates.json summary
python3 -c "
import json
with open('$RESULTS') as f:
    r = json.load(f)
r['_final_reward'] = float(open('$REWARD').read().strip().split('\n')[0])
with open('$RESULTS','w') as f:
    json.dump(r, f, indent=2)
"

echo "Verification complete. Reward: $(cat $REWARD | head -1)"
