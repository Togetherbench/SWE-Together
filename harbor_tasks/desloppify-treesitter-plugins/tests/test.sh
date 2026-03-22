#!/usr/bin/env bash
#
# Verification script for desloppify-treesitter-plugins task.
# Tests the "Make Generic Language Plugins First-Class" implementation.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# DESIGN PRINCIPLES:
#   - Every check is deterministic: no LLM calls, no subjective evaluation.
#   - Checks test STRUCTURAL PROPERTIES not exact code: the agent can use any
#     valid approach as long as the required functions/classes/patterns exist.
#   - Partial credit: each subsystem is independently scored.
#   - Total weight: 1.0 across 10 checks.
#
set +e

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

# Helper: increment reward (capped at 1.0)
add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ═══════════════════════════════════════════════════════════════════
# CHECK 1 (0.10): registry.py has register_detector() function
#   The agent must add a public function that registers DetectorMeta
#   objects into the DETECTORS dict at runtime.
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 1: register_detector() in registry.py ==="

python3 << 'PYEOF' && { echo "PASS: register_detector() found"; add_reward 0.10; } || echo "FAIL: register_detector() missing or broken"
import ast, sys

with open("desloppify/core/registry.py") as f:
    source = f.read()

tree = ast.parse(source)
func_names = {node.name for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

if "register_detector" not in func_names:
    print(f"  register_detector not found. Functions: {sorted(func_names)}", file=sys.stderr)
    sys.exit(1)

# Verify it references DETECTORS dict (should mutate it)
if "DETECTORS" not in source:
    print("  DETECTORS dict not found in registry.py", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.10): scoring policy core.py has register_scoring_policy()
#   The agent must add runtime registration for scoring policies.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 2: register_scoring_policy() in scoring policy core.py ==="

python3 << 'PYEOF' && { echo "PASS: register_scoring_policy() found"; add_reward 0.10; } || echo "FAIL: register_scoring_policy() missing or broken"
import ast, sys

with open("desloppify/engine/scoring_internal/policy/core.py") as f:
    source = f.read()

tree = ast.parse(source)
func_names = {node.name for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

if "register_scoring_policy" not in func_names:
    print(f"  register_scoring_policy not found. Functions: {sorted(func_names)}", file=sys.stderr)
    sys.exit(1)

# Check for _rebuild_derived helper (rebuilds DIMENSIONS after new policy)
if "_rebuild_derived" not in func_names:
    print(f"  _rebuild_derived not found. Functions: {sorted(func_names)}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.15): generic.py exists with key functions
#   The core new file: must have _run_tool(), _make_detect_fn(),
#   capability_report(), and the generic_lang factory or equivalent.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 3: generic.py with key functions ==="

python3 << 'PYEOF' && { echo "PASS: generic.py has required functions"; add_reward 0.15; } || echo "FAIL: generic.py missing or incomplete"
import ast, sys, os

# Check multiple possible locations for generic.py
candidates = [
    "desloppify/languages/framework/generic.py",
    "desloppify/languages/_framework/generic.py",
]
found_path = None
for path in candidates:
    if os.path.exists(path):
        found_path = path
        break

if found_path is None:
    print(f"  generic.py not found in any expected location: {candidates}", file=sys.stderr)
    sys.exit(1)

with open(found_path) as f:
    source = f.read()

tree = ast.parse(source)
func_names = {node.name for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

# Required functions (the instruction explicitly names these)
required = {"_run_tool", "_make_detect_fn", "capability_report"}
missing = required - func_names

if missing:
    print(f"  Missing functions: {sorted(missing)}. Found: {sorted(func_names)}", file=sys.stderr)
    sys.exit(1)

# Must also have a factory function (generic_lang or similar)
factory_candidates = {"generic_lang", "make_generic_lang", "create_generic_lang"}
if not func_names & factory_candidates:
    # Check for class-based approach
    class_names = {node.name for node in ast.walk(tree) if isinstance(node, ast.ClassDef)}
    if not class_names:
        print(f"  No factory function or class found. Functions: {sorted(func_names)}", file=sys.stderr)
        sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 4 (0.10): Language plugins have fix_cmd in tool specs
#   go, rust, ruby, swift, kotlin must each have fix_cmd defined.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 4: Language plugins have fix_cmd ==="

FIX_CMD_PASS=0
FIX_CMD_TOTAL=5

for lang in go rust ruby swift kotlin; do
    # Check multiple possible locations
    FOUND=0
    for dir in "desloppify/languages/$lang" "desloppify/languages/_framework/plugins/$lang"; do
        INIT_FILE="$dir/__init__.py"
        if [ -f "$INIT_FILE" ]; then
            if python3 -c "
with open('$INIT_FILE') as f:
    content = f.read()
if 'fix_cmd' in content:
    exit(0)
else:
    exit(1)
" 2>/dev/null; then
                FOUND=1
                break
            fi
        fi
    done
    # Also check if the language is defined inline in generic.py or a config file
    if [ "$FOUND" -eq 0 ]; then
        for gpath in "desloppify/languages/framework/generic.py" "desloppify/languages/_framework/generic.py"; do
            if [ -f "$gpath" ]; then
                if python3 -c "
with open('$gpath') as f:
    content = f.read()
# Check if this language has fix_cmd defined somewhere in the file
import re
# Look for patterns like 'fix_cmd' near the language name
if 'fix_cmd' in content and '$lang' in content.lower():
    exit(0)
exit(1)
" 2>/dev/null; then
                    FOUND=1
                    break
                fi
            fi
        done
    fi
    if [ "$FOUND" -eq 1 ]; then
        echo "  $lang: fix_cmd found"
        FIX_CMD_PASS=$((FIX_CMD_PASS + 1))
    else
        echo "  $lang: fix_cmd NOT found"
    fi
done

if [ "$FIX_CMD_PASS" -eq "$FIX_CMD_TOTAL" ]; then
    echo "PASS: All $FIX_CMD_TOTAL language plugins have fix_cmd"
    add_reward 0.10
elif [ "$FIX_CMD_PASS" -ge 3 ]; then
    echo "PARTIAL: $FIX_CMD_PASS/$FIX_CMD_TOTAL plugins have fix_cmd"
    add_reward 0.05
else
    echo "FAIL: Only $FIX_CMD_PASS/$FIX_CMD_TOTAL plugins have fix_cmd"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 5 (0.10): test_generic_plugin.py exists with meaningful tests
#   Must exist and have at least 10 test functions.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 5: test_generic_plugin.py exists with tests ==="

python3 << 'PYEOF' && { echo "PASS: test_generic_plugin.py has sufficient tests"; add_reward 0.10; } || echo "FAIL: test_generic_plugin.py missing or insufficient"
import ast, sys, os, glob

# Search for test_generic_plugin.py in the project
candidates = glob.glob("desloppify/**/test_generic_plugin.py", recursive=True)
if not candidates:
    # Also check for similar names
    candidates = glob.glob("desloppify/**/test_generic*.py", recursive=True)

if not candidates:
    print("  test_generic_plugin.py not found anywhere under desloppify/", file=sys.stderr)
    sys.exit(1)

test_file = candidates[0]
print(f"  Found: {test_file}")

with open(test_file) as f:
    source = f.read()

tree = ast.parse(source)
test_funcs = [node.name for node in ast.walk(tree)
              if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")]

print(f"  Test functions found: {len(test_funcs)}")
if len(test_funcs) < 10:
    print(f"  Need at least 10 test functions, found {len(test_funcs)}: {test_funcs}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 6 (0.10): Dynamic registration works at import time
#   Importing a generic plugin should cause its detectors to appear
#   in the DETECTORS dict and DETECTOR_SCORING_POLICIES dict.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 6: Dynamic registration imports work ==="

python3 << 'PYEOF' && { echo "PASS: Dynamic registration works at import"; add_reward 0.10; } || echo "FAIL: Dynamic registration broken"
import sys
sys.path.insert(0, ".")

try:
    from desloppify.core.registry import register_detector, DetectorMeta, DETECTORS

    # Test that register_detector is callable and works
    test_meta = DetectorMeta(
        name="__test_verifier_detector__",
        display="Test Verifier",
        dimension="Code quality",
        action_type="manual_fix",
        guidance="test only",
    )
    register_detector(test_meta)
    if "__test_verifier_detector__" not in DETECTORS:
        print("  register_detector did not add to DETECTORS dict", file=sys.stderr)
        sys.exit(1)

    # Clean up
    del DETECTORS["__test_verifier_detector__"]

except ImportError as e:
    print(f"  Import error: {e}", file=sys.stderr)
    sys.exit(1)

try:
    from desloppify.engine.scoring_internal.policy.core import (
        register_scoring_policy,
        DetectorScoringPolicy,
        DETECTOR_SCORING_POLICIES,
    )

    test_policy = DetectorScoringPolicy(
        detector="__test_verifier_policy__",
        dimension="Code quality",
        tier=3,
        file_based=True,
    )
    register_scoring_policy(test_policy)
    if "__test_verifier_policy__" not in DETECTOR_SCORING_POLICIES:
        print("  register_scoring_policy did not add to DETECTOR_SCORING_POLICIES", file=sys.stderr)
        sys.exit(1)

    # Clean up
    del DETECTOR_SCORING_POLICIES["__test_verifier_policy__"]

except ImportError as e:
    print(f"  Import error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 7 (0.10): Narrative constants refresh mechanism exists
#   _constants.py must have a way to refresh DETECTOR_TOOLS after
#   dynamic registration (refresh_detector_tools or equivalent).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 7: Narrative DETECTOR_TOOLS refresh mechanism ==="

python3 << 'PYEOF' && { echo "PASS: DETECTOR_TOOLS refresh mechanism found"; add_reward 0.10; } || echo "FAIL: DETECTOR_TOOLS refresh mechanism missing"
import ast, sys, os

# Check multiple possible paths for _constants.py
candidates = [
    "desloppify/intelligence/narrative/_constants.py",
    "desloppify/narrative/_constants.py",
]
found_path = None
for path in candidates:
    if os.path.exists(path):
        found_path = path
        break

if found_path is None:
    print(f"  _constants.py not found in expected locations", file=sys.stderr)
    sys.exit(1)

with open(found_path) as f:
    source = f.read()

tree = ast.parse(source)
func_names = {node.name for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

# Look for a refresh function (any of these names)
refresh_candidates = {"refresh_detector_tools", "_refresh_detector_tools", "rebuild_detector_tools"}
found_refresh = func_names & refresh_candidates

if not found_refresh:
    # Also accept if there's a callback-based approach
    if "on_detector_registered" in source or "callback" in source.lower():
        print("  Found callback-based refresh mechanism")
    else:
        print(f"  No refresh function found. Functions: {sorted(func_names)}", file=sys.stderr)
        sys.exit(1)
else:
    print(f"  Found refresh function: {found_refresh}")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 8 (0.10): Generic plugin fixer creation
#   generic.py must have _make_generic_fixer() or equivalent that
#   creates FixerConfig objects from tool specs with fix_cmd.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 8: Generic fixer creation function ==="

python3 << 'PYEOF' && { echo "PASS: Generic fixer creation found"; add_reward 0.10; } || echo "FAIL: Generic fixer creation missing"
import ast, sys, os

candidates = [
    "desloppify/languages/framework/generic.py",
    "desloppify/languages/_framework/generic.py",
]
found_path = None
for path in candidates:
    if os.path.exists(path):
        found_path = path
        break

if found_path is None:
    print(f"  generic.py not found", file=sys.stderr)
    sys.exit(1)

with open(found_path) as f:
    source = f.read()

tree = ast.parse(source)
func_names = {node.name for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}

# Must have a fixer creation function
fixer_candidates = {"_make_generic_fixer", "make_generic_fixer", "create_fixer"}
found_fixer = func_names & fixer_candidates

if not found_fixer:
    # Check if FixerConfig is referenced at all (agent may inline it)
    if "FixerConfig" in source and "fix_cmd" in source:
        print("  Found inline FixerConfig creation with fix_cmd")
    else:
        print(f"  No fixer creation found. Functions: {sorted(func_names)}", file=sys.stderr)
        print(f"  FixerConfig in source: {'FixerConfig' in source}", file=sys.stderr)
        print(f"  fix_cmd in source: {'fix_cmd' in source}", file=sys.stderr)
        sys.exit(1)
else:
    print(f"  Found fixer function: {found_fixer}")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 9 (0.05): langs command or capability reporting
#   Either langs.py exists with SHARED_PHASE_LABELS filtering,
#   or capability_report is wired into scan output.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 9: Langs command or capability reporting ==="

python3 << 'PYEOF' && { echo "PASS: Langs command or capability reporting found"; add_reward 0.05; } || echo "FAIL: No langs command or capability reporting"
import os, sys

# Check for langs.py in commands
langs_candidates = [
    "desloppify/app/commands/langs.py",
    "desloppify/app/commands/langs_cmd.py",
]
found_langs = False
for path in langs_candidates:
    if os.path.exists(path):
        with open(path) as f:
            content = f.read()
        # Should filter shared phase labels
        if "SHARED_PHASE_LABELS" in content or "shared" in content.lower():
            found_langs = True
            print(f"  Found langs command with shared phase filtering: {path}")
            break
        else:
            # Even without filtering, having the command is partial credit
            found_langs = True
            print(f"  Found langs command (no shared phase filtering): {path}")
            break

if not found_langs:
    # Check if capability_report is wired into scan
    scan_candidates = [
        "desloppify/engine/planning/scan.py",
        "desloppify/engine/scan.py",
    ]
    for path in scan_candidates:
        if os.path.exists(path):
            with open(path) as f:
                content = f.read()
            if "capability_report" in content:
                found_langs = True
                print(f"  Found capability_report in scan: {path}")
                break

if not found_langs:
    print("  No langs command or capability_report integration found", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 10 (0.10): Existing test suite still passes
#   The agent's changes must not break anything that was already working.
#   Pre-existing failure: test_legacy_assets_badge_path_migrates_to_root_default
#   in test_config.py — ignore this known issue.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 10: Existing tests pass (no regressions) ==="

cd "$WORKSPACE"
# Run the core tests that existed at the base commit.
# Ignore pre-existing failure in test_config.py (badge_path migration test)
# and the fixtures directory.
python3 -m pytest desloppify/tests/ -q --tb=line \
    --ignore=desloppify/tests/fixtures \
    -k "not test_legacy_assets_badge_path_migrates_to_root_default" \
    2>&1 | tail -10 > "$LOG_DIR/pytest_output.txt"
PYTEST_EXIT=$?

cat "$LOG_DIR/pytest_output.txt"

if [ $PYTEST_EXIT -eq 0 ]; then
    echo "PASS: All existing tests pass"
    add_reward 0.10
elif [ $PYTEST_EXIT -eq 1 ]; then
    # Some tests failed — check how many
    FAILED=$(grep -oP '\d+ failed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "?")
    TOTAL=$(grep -oP '\d+ passed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    echo "PARTIAL: $FAILED tests failed, $TOTAL passed"
    # Give partial credit if most pass
    if [ "$TOTAL" -gt 0 ] 2>/dev/null && [ "$FAILED" -lt 5 ] 2>/dev/null; then
        add_reward 0.05
    fi
elif [ $PYTEST_EXIT -eq 5 ]; then
    # Exit code 5 = no tests collected (possible if test paths changed)
    echo "WARN: No tests collected — test paths may have changed"
    # Check if tests exist elsewhere
    python3 -m pytest desloppify/ -q --tb=line --co 2>&1 | tail -5 > "$LOG_DIR/pytest_collect.txt"
    COLLECTED=$(grep -oP '\d+ tests?' "$LOG_DIR/pytest_collect.txt" | head -1 || echo "0")
    echo "  Tests collected elsewhere: $COLLECTED"
    if [ -n "$COLLECTED" ] && [ "$COLLECTED" != "0" ]; then
        add_reward 0.03
    fi
else
    echo "FAIL: pytest exited with code $PYTEST_EXIT"
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
