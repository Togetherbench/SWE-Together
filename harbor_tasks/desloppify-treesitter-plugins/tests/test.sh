#!/usr/bin/env bash
#
# Hardened verification script for desloppify-treesitter-plugins task.
# Tests the "Make Generic Language Plugins First-Class" implementation.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# DESIGN PRINCIPLES:
#   - Every check is deterministic: no LLM calls, no subjective evaluation.
#   - 70% of points require BEHAVIORAL correctness (actually running code),
#     only 30% for structural properties.
#   - Partial credit: each subsystem is independently scored.
#   - Total weight: 1.0 across 10 checks.
#   - Empty stubs / pass-only functions score near 0.
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
# CHECK 1 (0.10): register_detector() WORKS behaviorally
#   Must actually add a DetectorMeta to DETECTORS dict AND update
#   _DISPLAY_ORDER (or equivalent ordered list).
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 1: register_detector() behavioral test ==="

python3 << 'PYEOF' && { echo "PASS: register_detector() works"; add_reward 0.10; } || echo "FAIL: register_detector() broken"
import sys
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS, DetectorMeta

# Snapshot before
before_count = len(DETECTORS)
before_names = set(DETECTORS.keys())

# Import and call register_detector
from desloppify.core.registry import register_detector

test_meta = DetectorMeta(
    name="__verifier_behavioral_test__",
    display="Verifier Behavioral Test",
    dimension="Code quality",
    action_type="manual_fix",
    guidance="test guidance text",
)
register_detector(test_meta)

# 1) Must appear in DETECTORS
if "__verifier_behavioral_test__" not in DETECTORS:
    print("  FAIL: register_detector did not add to DETECTORS dict", file=sys.stderr)
    sys.exit(1)

# 2) Retrieved meta must have correct fields
meta = DETECTORS["__verifier_behavioral_test__"]
if meta.display != "Verifier Behavioral Test":
    print(f"  FAIL: display mismatch: {meta.display}", file=sys.stderr)
    sys.exit(1)
if meta.dimension != "Code quality":
    print(f"  FAIL: dimension mismatch: {meta.dimension}", file=sys.stderr)
    sys.exit(1)

# 3) Count must have increased
if len(DETECTORS) != before_count + 1:
    print(f"  FAIL: DETECTORS count didn't increase ({before_count} -> {len(DETECTORS)})", file=sys.stderr)
    sys.exit(1)

# 4) display_order() must include the new detector
from desloppify.core.registry import display_order
order = display_order()
if "__verifier_behavioral_test__" not in order:
    print(f"  FAIL: new detector not in display_order()", file=sys.stderr)
    sys.exit(1)

# Clean up
del DETECTORS["__verifier_behavioral_test__"]
print("  All register_detector behavioral checks passed")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.10): register_scoring_policy() WORKS behaviorally
#   Must add to DETECTOR_SCORING_POLICIES AND rebuild DIMENSIONS
#   so that the new detector appears in the correct dimension.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 2: register_scoring_policy() behavioral test ==="

python3 << 'PYEOF' && { echo "PASS: register_scoring_policy() works"; add_reward 0.10; } || echo "FAIL: register_scoring_policy() broken"
import sys
sys.path.insert(0, ".")

from desloppify.engine.scoring_internal.policy.core import (
    DETECTOR_SCORING_POLICIES,
    DIMENSIONS,
    DIMENSIONS_BY_NAME,
    FILE_BASED_DETECTORS,
    DetectorScoringPolicy,
    register_scoring_policy,
)

# Snapshot before
before_count = len(DETECTOR_SCORING_POLICIES)
cq_dim_before = DIMENSIONS_BY_NAME.get("Code quality")
cq_detectors_before = list(cq_dim_before.detectors) if cq_dim_before else []

# Register a new policy
test_policy = DetectorScoringPolicy(
    detector="__verifier_policy_test__",
    dimension="Code quality",
    tier=3,
    file_based=True,
)
register_scoring_policy(test_policy)

# 1) Must appear in DETECTOR_SCORING_POLICIES
if "__verifier_policy_test__" not in DETECTOR_SCORING_POLICIES:
    print("  FAIL: policy not in DETECTOR_SCORING_POLICIES", file=sys.stderr)
    sys.exit(1)

# 2) DIMENSIONS must be rebuilt: "Code quality" dimension must now include new detector
cq_dim_after = DIMENSIONS_BY_NAME.get("Code quality")
if cq_dim_after is None:
    print("  FAIL: Code quality dimension missing after rebuild", file=sys.stderr)
    sys.exit(1)
if "__verifier_policy_test__" not in cq_dim_after.detectors:
    print(f"  FAIL: new detector not in Code quality dimension detectors: {cq_dim_after.detectors}", file=sys.stderr)
    sys.exit(1)

# 3) FILE_BASED_DETECTORS must be rebuilt (file_based=True)
if "__verifier_policy_test__" not in FILE_BASED_DETECTORS:
    print(f"  FAIL: new detector not in FILE_BASED_DETECTORS", file=sys.stderr)
    sys.exit(1)

# Clean up
del DETECTOR_SCORING_POLICIES["__verifier_policy_test__"]
# Trigger rebuild to restore state (if _rebuild_derived exists)
try:
    from desloppify.engine.scoring_internal.policy.core import _rebuild_derived
    _rebuild_derived()
except ImportError:
    pass

print("  All register_scoring_policy behavioral checks passed")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.10): generic.py has non-stub functions with real bodies
#   Key functions must exist AND have >5 lines of body (not pass/return None).
#   This prevents empty stubs from scoring.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 3: generic.py with non-stub functions ==="

python3 << 'PYEOF' && { echo "PASS: generic.py has substantial implementations"; add_reward 0.10; } || echo "FAIL: generic.py missing or has stub functions"
import ast, sys, os

# Find generic.py
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
    print(f"  generic.py not found in: {candidates}", file=sys.stderr)
    sys.exit(1)

with open(found_path) as f:
    source = f.read()

tree = ast.parse(source)

# Build a map of function_name -> body_line_count
func_bodies = {}
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        # Count lines of body, excluding docstrings and bare pass/return None
        body = node.body
        # Skip docstring
        start = 0
        if (body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, (ast.Str, ast.Constant))):
            start = 1
        effective_body = body[start:]
        # Filter out bare pass, bare return, and return None
        meaningful = []
        for stmt in effective_body:
            if isinstance(stmt, ast.Pass):
                continue
            if isinstance(stmt, ast.Return) and stmt.value is None:
                continue
            if (isinstance(stmt, ast.Expr)
                    and isinstance(stmt.value, ast.Constant)
                    and stmt.value.value is Ellipsis):
                continue
            meaningful.append(stmt)
        # Count lines spanned by meaningful statements
        if meaningful:
            line_count = meaningful[-1].end_lineno - meaningful[0].lineno + 1
        else:
            line_count = 0
        func_bodies[node.name] = line_count

# Check required functions exist with substantial bodies
required = {
    "_run_tool": 3,        # Must have subprocess logic
    "_make_detect_fn": 3,  # Must build a detect function
    "capability_report": 3, # Must inspect plugin config
}

# Also need a factory: generic_lang or equivalent
factory_candidates = {"generic_lang", "make_generic_lang", "create_generic_lang"}
found_factory = factory_candidates & set(func_bodies.keys())
if found_factory:
    fname = next(iter(found_factory))
    required[fname] = 5  # Factory must have substantial body

missing = []
too_small = []
for func_name, min_lines in required.items():
    if func_name not in func_bodies:
        missing.append(func_name)
    elif func_bodies[func_name] < min_lines:
        too_small.append(f"{func_name} ({func_bodies[func_name]} lines, need {min_lines})")

if missing:
    print(f"  Missing functions: {missing}", file=sys.stderr)
    sys.exit(1)
if too_small:
    print(f"  Stub functions (too short): {too_small}", file=sys.stderr)
    sys.exit(1)

# Verify _make_generic_fixer or equivalent also exists (for fix_cmd support)
fixer_candidates = {"_make_generic_fixer", "make_generic_fixer", "create_fixer"}
found_fixer = fixer_candidates & set(func_bodies.keys())
if not found_fixer:
    # Accept inline FixerConfig creation if it references fix_cmd
    if "FixerConfig" not in source or "fix_cmd" not in source:
        print(f"  No fixer creation function found", file=sys.stderr)
        sys.exit(1)

print(f"  Functions found: {sorted(func_bodies.keys())}")
print(f"  All required functions have substantial bodies")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 4 (0.15): End-to-end: generic_lang creates a WORKING plugin
#   This is the core behavioral test. Actually import generic_lang (or
#   equivalent), create a plugin config for a test language, and verify:
#   - LangConfig is produced with correct name/extensions
#   - Phases include at least 1 tool phase + security phase
#   - The tool's detector was registered in DETECTORS
#   - The tool's scoring policy was registered in DETECTOR_SCORING_POLICIES
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 4: End-to-end generic_lang creates working plugin ==="

PARTIAL4=0

python3 << 'PYEOF'
import sys, os, importlib
sys.path.insert(0, ".")

# Find and import generic.py
for mod_path in [
    "desloppify.languages.framework.generic",
    "desloppify.languages._framework.generic",
]:
    try:
        mod = importlib.import_module(mod_path)
        break
    except ImportError:
        continue
else:
    print("FAIL_IMPORT", file=sys.stdout)
    sys.exit(0)

# Find the factory function
factory = None
for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
    factory = getattr(mod, name, None)
    if factory:
        break

if not factory:
    print("FAIL_NO_FACTORY", file=sys.stdout)
    sys.exit(0)

# Check the factory signature to understand what args it needs
import inspect
sig = inspect.signature(factory)
params = list(sig.parameters.keys())
print(f"FACTORY_PARAMS:{','.join(params)}", file=sys.stdout)

# Try to call it with a minimal test language spec
# This mirrors what a real go/__init__.py would do
try:
    from desloppify.core.registry import DETECTORS
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    from desloppify.languages.framework.base.types import LangConfig

    before_detectors = set(DETECTORS.keys())
    before_policies = set(DETECTOR_SCORING_POLICIES.keys())

    # Construct a minimal tool spec matching the instruction plan format
    test_tool = {
        "label": "test_verifier_tool",
        "cmd": "echo '{}'",
        "fmt": "json",
        "id": "test_verifier_lint",
        "tier": 3,
    }

    # Try calling with various signatures
    result = None
    errors = []

    # Attempt 1: name + tools list (most likely signature)
    try:
        result = factory(
            name="__verifier_test_lang__",
            extensions=[".vfy"],
            tools=[test_tool],
        )
    except TypeError as e:
        errors.append(f"sig1: {e}")

    # Attempt 2: positional args
    if result is None:
        try:
            result = factory("__verifier_test_lang__", [".vfy"], [test_tool])
        except TypeError as e:
            errors.append(f"sig2: {e}")

    # Attempt 3: dict-based config
    if result is None:
        try:
            result = factory({
                "name": "__verifier_test_lang__",
                "extensions": [".vfy"],
                "tools": [test_tool],
            })
        except TypeError as e:
            errors.append(f"sig3: {e}")

    if result is None:
        print(f"FAIL_CALL:{'|'.join(errors)}", file=sys.stdout)
        sys.exit(0)

    # Verify the result
    results = []

    # a) Result is a LangConfig or has phases attribute
    if isinstance(result, LangConfig):
        results.append("IS_LANGCONFIG")
    elif hasattr(result, "phases"):
        results.append("HAS_PHASES")
    else:
        results.append("NO_LANGCONFIG")

    # b) Has phases
    if hasattr(result, "phases") and len(result.phases) > 0:
        results.append(f"PHASES:{len(result.phases)}")
        # Check for security phase
        phase_labels = [p.label.lower() for p in result.phases]
        if any("security" in l for l in phase_labels):
            results.append("HAS_SECURITY_PHASE")
    else:
        results.append("NO_PHASES")

    # c) Detector was registered
    after_detectors = set(DETECTORS.keys())
    new_detectors = after_detectors - before_detectors
    if new_detectors:
        results.append(f"NEW_DETECTORS:{','.join(sorted(new_detectors))}")
    else:
        results.append("NO_NEW_DETECTORS")

    # d) Scoring policy was registered
    after_policies = set(DETECTOR_SCORING_POLICIES.keys())
    new_policies = after_policies - before_policies
    if new_policies:
        results.append(f"NEW_POLICIES:{','.join(sorted(new_policies))}")
    else:
        results.append("NO_NEW_POLICIES")

    # e) Has fixers dict
    if hasattr(result, "fixers"):
        results.append(f"FIXERS:{len(result.fixers)}")
    else:
        results.append("NO_FIXERS_ATTR")

    print("|".join(results), file=sys.stdout)

except Exception as e:
    print(f"FAIL_EXCEPTION:{type(e).__name__}:{e}", file=sys.stdout)
PYEOF

E2E_OUTPUT=$(python3 << 'PYEOF2'
import sys, os, importlib
sys.path.insert(0, ".")

for mod_path in [
    "desloppify.languages.framework.generic",
    "desloppify.languages._framework.generic",
]:
    try:
        mod = importlib.import_module(mod_path)
        break
    except ImportError:
        continue
else:
    print("FAIL_IMPORT")
    sys.exit(0)

factory = None
for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
    factory = getattr(mod, name, None)
    if factory:
        break

if not factory:
    print("FAIL_NO_FACTORY")
    sys.exit(0)

import inspect
try:
    from desloppify.core.registry import DETECTORS
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    from desloppify.languages.framework.base.types import LangConfig

    before_detectors = set(DETECTORS.keys())
    before_policies = set(DETECTOR_SCORING_POLICIES.keys())

    test_tool = {
        "label": "test_verifier_tool",
        "cmd": "echo '{}'",
        "fmt": "json",
        "id": "test_verifier_lint",
        "tier": 3,
    }

    result = None
    errors = []

    try:
        result = factory(
            name="__verifier_test_lang__",
            extensions=[".vfy"],
            tools=[test_tool],
        )
    except TypeError as e:
        errors.append(str(e))

    if result is None:
        try:
            result = factory("__verifier_test_lang__", [".vfy"], [test_tool])
        except TypeError as e:
            errors.append(str(e))

    if result is None:
        try:
            result = factory({
                "name": "__verifier_test_lang__",
                "extensions": [".vfy"],
                "tools": [test_tool],
            })
        except TypeError as e:
            errors.append(str(e))

    if result is None:
        print(f"FAIL_CALL:{'|'.join(errors)}")
        sys.exit(0)

    results = []

    if isinstance(result, LangConfig):
        results.append("IS_LANGCONFIG")
    elif hasattr(result, "phases"):
        results.append("HAS_PHASES")
    else:
        results.append("NO_LANGCONFIG")

    if hasattr(result, "phases") and len(result.phases) > 0:
        results.append(f"PHASES:{len(result.phases)}")
        phase_labels = [p.label.lower() for p in result.phases]
        if any("security" in l for l in phase_labels):
            results.append("HAS_SECURITY_PHASE")
    else:
        results.append("NO_PHASES")

    after_detectors = set(DETECTORS.keys())
    new_detectors = after_detectors - before_detectors
    if new_detectors:
        results.append(f"NEW_DETECTORS:{','.join(sorted(new_detectors))}")
    else:
        results.append("NO_NEW_DETECTORS")

    after_policies = set(DETECTOR_SCORING_POLICIES.keys())
    new_policies = after_policies - before_policies
    if new_policies:
        results.append(f"NEW_POLICIES:{','.join(sorted(new_policies))}")
    else:
        results.append("NO_NEW_POLICIES")

    if hasattr(result, "fixers"):
        results.append(f"FIXERS:{len(result.fixers)}")
    else:
        results.append("NO_FIXERS_ATTR")

    print("|".join(results))

except Exception as e:
    print(f"FAIL_EXCEPTION:{type(e).__name__}:{e}")
PYEOF2
)

echo "  E2E output: $E2E_OUTPUT"

case "$E2E_OUTPUT" in
    FAIL_IMPORT*)
        echo "FAIL: Could not import generic.py module"
        ;;
    FAIL_NO_FACTORY*)
        echo "FAIL: No factory function (generic_lang etc.) found"
        ;;
    FAIL_CALL*)
        echo "FAIL: Could not call factory function: $E2E_OUTPUT"
        ;;
    FAIL_EXCEPTION*)
        echo "FAIL: Exception during e2e test: $E2E_OUTPUT"
        ;;
    *)
        # Parse results
        E2E_POINTS=0

        # a) Produces a LangConfig (0.03)
        if echo "$E2E_OUTPUT" | grep -q "IS_LANGCONFIG\|HAS_PHASES"; then
            echo "  + LangConfig produced"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # b) Has phases (0.03)
        if echo "$E2E_OUTPUT" | grep -q "PHASES:"; then
            PHASE_COUNT=$(echo "$E2E_OUTPUT" | grep -oP 'PHASES:\K[0-9]+')
            if [ "$PHASE_COUNT" -ge 2 ]; then
                echo "  + Has $PHASE_COUNT phases (>= 2)"
                E2E_POINTS=$((E2E_POINTS + 1))
            else
                echo "  - Only $PHASE_COUNT phase(s), need >= 2"
            fi
        fi

        # c) Registered detectors (0.03)
        if echo "$E2E_OUTPUT" | grep -q "NEW_DETECTORS:"; then
            echo "  + Detectors registered in DETECTORS dict"
            E2E_POINTS=$((E2E_POINTS + 1))
        else
            echo "  - No new detectors registered"
        fi

        # d) Registered scoring policies (0.03)
        if echo "$E2E_OUTPUT" | grep -q "NEW_POLICIES:"; then
            echo "  + Scoring policies registered"
            E2E_POINTS=$((E2E_POINTS + 1))
        else
            echo "  - No new scoring policies registered"
        fi

        # e) Has security phase (0.03)
        if echo "$E2E_OUTPUT" | grep -q "HAS_SECURITY_PHASE"; then
            echo "  + Security phase present"
            E2E_POINTS=$((E2E_POINTS + 1))
        else
            echo "  - No security phase"
        fi

        # Score: 0.03 per sub-check, total 0.15
        if [ "$E2E_POINTS" -eq 5 ]; then
            echo "PASS: All 5 e2e sub-checks passed"
            add_reward 0.15
        elif [ "$E2E_POINTS" -ge 3 ]; then
            echo "PARTIAL: $E2E_POINTS/5 e2e sub-checks passed"
            add_reward 0.09
        elif [ "$E2E_POINTS" -ge 1 ]; then
            echo "PARTIAL: $E2E_POINTS/5 e2e sub-checks passed"
            add_reward 0.03
        else
            echo "FAIL: 0/5 e2e sub-checks passed"
        fi
        ;;
esac

# ═══════════════════════════════════════════════════════════════════
# CHECK 5 (0.10): fix_cmd creates working FixerConfig objects
#   Language plugins with fix_cmd must produce FixerConfig objects
#   with callable detect and fix attributes.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 5: fix_cmd creates working FixerConfig ==="

python3 << 'PYEOF' && { echo "PASS: FixerConfig creation works"; add_reward 0.10; } || echo "FAIL: FixerConfig creation broken"
import sys, os, importlib, ast
sys.path.insert(0, ".")

# First verify that at least 3 of 5 language plugins have fix_cmd
languages_with_fix_cmd = []
for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    for dir_path in [f"desloppify/languages/{lang}", f"desloppify/languages/_framework/plugins/{lang}"]:
        init_file = f"{dir_path}/__init__.py"
        if os.path.exists(init_file):
            with open(init_file) as f:
                content = f.read()
            if "fix_cmd" in content:
                languages_with_fix_cmd.append(lang)
                break

# Also check generic.py for inline fix_cmd per language
if len(languages_with_fix_cmd) < 3:
    for gpath in ["desloppify/languages/framework/generic.py", "desloppify/languages/_framework/generic.py"]:
        if os.path.exists(gpath):
            with open(gpath) as f:
                content = f.read()
            for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
                if lang not in languages_with_fix_cmd and "fix_cmd" in content and lang in content.lower():
                    languages_with_fix_cmd.append(lang)

if len(languages_with_fix_cmd) < 3:
    print(f"  Only {len(languages_with_fix_cmd)} languages have fix_cmd (need >= 3): {languages_with_fix_cmd}", file=sys.stderr)
    sys.exit(1)

print(f"  Languages with fix_cmd: {languages_with_fix_cmd}")

# Now try to import a generic plugin and verify its fixers are FixerConfig with callables
from desloppify.languages.framework.base.types import FixerConfig

# Try to import one of the language plugins and check its fixers
found_working_fixer = False
for lang in languages_with_fix_cmd[:3]:
    try:
        # Try importing the language module
        for mod_path in [
            f"desloppify.languages.{lang}",
            f"desloppify.languages._framework.plugins.{lang}",
        ]:
            try:
                mod = importlib.import_module(mod_path)
                break
            except ImportError:
                continue
        else:
            continue

        # Check if we can find fixers in the loaded config
        from desloppify.languages.framework.resolution import get_lang
        try:
            cfg = get_lang(lang)
            if cfg and hasattr(cfg, "fixers") and cfg.fixers:
                for fixer_name, fixer_cfg in cfg.fixers.items():
                    if isinstance(fixer_cfg, FixerConfig):
                        if callable(fixer_cfg.detect) and callable(fixer_cfg.fix):
                            print(f"  {lang}: FixerConfig '{fixer_name}' has callable detect+fix")
                            found_working_fixer = True
                            break
                        else:
                            print(f"  {lang}: FixerConfig '{fixer_name}' detect/fix not callable", file=sys.stderr)
                    else:
                        print(f"  {lang}: fixer is {type(fixer_cfg).__name__}, not FixerConfig", file=sys.stderr)
        except Exception as e:
            # get_lang may not work for unregistered langs; try alternative
            pass

    except Exception as e:
        print(f"  {lang}: error during import: {e}", file=sys.stderr)

# Alternative: check if _make_generic_fixer exists and can be called
if not found_working_fixer:
    for gpath_mod in ["desloppify.languages.framework.generic", "desloppify.languages._framework.generic"]:
        try:
            mod = importlib.import_module(gpath_mod)
            make_fixer = getattr(mod, "_make_generic_fixer", None) or getattr(mod, "make_generic_fixer", None)
            if make_fixer:
                test_tool = {
                    "label": "test_tool",
                    "cmd": "echo 'test'",
                    "fmt": "json",
                    "id": "test_fixer",
                    "tier": 3,
                    "fix_cmd": "echo 'fixed'",
                }
                fixer = make_fixer(test_tool)
                if isinstance(fixer, FixerConfig) and callable(fixer.detect) and callable(fixer.fix):
                    print(f"  _make_generic_fixer produces valid FixerConfig with callable detect+fix")
                    found_working_fixer = True
                    break
        except Exception as e:
            print(f"  {gpath_mod}: {e}", file=sys.stderr)

if not found_working_fixer:
    print("  No working FixerConfig with callable detect+fix found", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 6 (0.15): Agent's test_generic_plugin.py PASSES via pytest
#   The agent must write tests that actually pass. We run pytest on
#   the test file and require >= 50% pass rate.
#   This catches both "no test file" and "stub tests that all fail".
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 6: Agent's test_generic_plugin.py passes pytest ==="

cd "$WORKSPACE"

# Find the test file
TEST_FILE=$(python3 -c "
import glob
candidates = glob.glob('desloppify/**/test_generic_plugin.py', recursive=True)
if not candidates:
    candidates = glob.glob('desloppify/**/test_generic*.py', recursive=True)
if candidates:
    print(candidates[0])
else:
    print('')
")

if [ -z "$TEST_FILE" ]; then
    echo "FAIL: test_generic_plugin.py not found"
else
    echo "  Found: $TEST_FILE"

    # First check it has enough test functions (at least 10)
    TEST_COUNT=$(python3 -c "
import ast
with open('$TEST_FILE') as f:
    tree = ast.parse(f.read())
tests = [n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name.startswith('test_')]
print(len(tests))
")
    echo "  Test functions: $TEST_COUNT"

    if [ "$TEST_COUNT" -lt 10 ]; then
        echo "FAIL: Only $TEST_COUNT test functions (need >= 10)"
    else
        # Run pytest on the test file
        python3 -m pytest "$TEST_FILE" -q --tb=line 2>&1 | tail -15 > "$LOG_DIR/agent_tests.txt"
        AGENT_PYTEST_EXIT=$?

        cat "$LOG_DIR/agent_tests.txt"

        # Parse results
        PASSED=$(grep -oP '\d+ passed' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
        FAILED=$(grep -oP '\d+ failed' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
        ERRORS=$(grep -oP '\d+ error' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
        TOTAL=$((PASSED + FAILED + ERRORS))

        if [ "$TOTAL" -eq 0 ]; then
            echo "FAIL: No tests collected or all errored"
        else
            PASS_RATE=$(python3 -c "print($PASSED / $TOTAL)")
            echo "  Pass rate: $PASSED/$TOTAL = $PASS_RATE"

            if python3 -c "exit(0 if $PASS_RATE >= 0.8 else 1)"; then
                echo "PASS: >= 80% of agent's tests pass"
                add_reward 0.15
            elif python3 -c "exit(0 if $PASS_RATE >= 0.5 else 1)"; then
                echo "PARTIAL: >= 50% of agent's tests pass"
                add_reward 0.08
            elif python3 -c "exit(0 if $PASS_RATE >= 0.3 else 1)"; then
                echo "PARTIAL: >= 30% of agent's tests pass"
                add_reward 0.04
            else
                echo "FAIL: < 30% of agent's tests pass"
            fi
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 7 (0.10): Shared phases present in generic plugins
#   Generic plugins must include shared phases (security, subjective
#   review, and at least one of duplicates/boilerplate).
#   This tests behavioral integration, not just file existence.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 7: Shared phases present in generic plugins ==="

python3 << 'PYEOF' && { echo "PASS: Shared phases correctly integrated"; add_reward 0.10; } || echo "FAIL: Shared phases missing"
import sys, os, importlib
sys.path.insert(0, ".")

# Strategy 1: Check if any already-loaded generic plugin has shared phases
# by importing a real language plugin (go, rust, etc.)
found_shared_phases = False
shared_phase_names = {"security", "subjective review", "boilerplate duplication", "duplicates"}

for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    try:
        for mod_path in [
            f"desloppify.languages.{lang}",
            f"desloppify.languages._framework.plugins.{lang}",
        ]:
            try:
                importlib.import_module(mod_path)
                break
            except ImportError:
                continue

        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if cfg and hasattr(cfg, "phases") and cfg.phases:
            phase_labels = {p.label.lower() for p in cfg.phases}
            has_security = any("security" in l for l in phase_labels)
            has_subjective = any("subjective" in l or "review" in l for l in phase_labels)
            has_dupes = any("duplicat" in l or "boilerplate" in l for l in phase_labels)

            print(f"  {lang} phases: {sorted(phase_labels)}")

            if has_security and has_subjective:
                found_shared_phases = True
                print(f"  {lang}: has security + subjective review phases")
                break
    except Exception as e:
        print(f"  {lang}: {e}", file=sys.stderr)

# Strategy 2: Check generic.py source for shared phase imports/usage
if not found_shared_phases:
    for gpath in ["desloppify/languages/framework/generic.py", "desloppify/languages/_framework/generic.py"]:
        if os.path.exists(gpath):
            with open(gpath) as f:
                content = f.read()
            # Must import shared phase builders
            has_security_import = (
                "detector_phase_security" in content
                or "phase_security" in content
            )
            has_subjective_import = (
                "shared_subjective_duplicates_tail" in content
                or "detector_phase_subjective_review" in content
                or "phase_subjective_review" in content
            )
            if has_security_import and has_subjective_import:
                # Verify they're actually used (not just imported)
                # Check they appear in a function body, not just import lines
                import ast
                tree = ast.parse(content)
                # Find function bodies that reference phase builders
                for node in ast.walk(tree):
                    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        func_source = ast.get_source_segment(content, node)
                        if func_source and ("security" in func_source.lower()) and (
                            "subjective" in func_source.lower() or "shared_subjective" in func_source.lower()
                        ):
                            found_shared_phases = True
                            print(f"  Found security + subjective phase usage in {gpath}:{node.name}")
                            break
            if found_shared_phases:
                break

if not found_shared_phases:
    print("  No shared phases (security + subjective review) found in generic plugins", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 8 (0.05): Narrative DETECTOR_TOOLS refresh works behaviorally
#   After calling refresh, DETECTOR_TOOLS must reflect newly
#   registered detectors.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 8: Narrative DETECTOR_TOOLS refresh behavioral ==="

python3 << 'PYEOF' && { echo "PASS: DETECTOR_TOOLS refresh works"; add_reward 0.05; } || echo "FAIL: DETECTOR_TOOLS refresh broken"
import sys
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS, DetectorMeta

# First register a test detector
test_meta = DetectorMeta(
    name="__verifier_narrative_test__",
    display="Verifier Narrative Test",
    dimension="Code quality",
    action_type="manual_fix",
    guidance="narrative test",
)

# Import register_detector to add it
from desloppify.core.registry import register_detector
register_detector(test_meta)

# Now try to refresh DETECTOR_TOOLS
from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS

# Check if the new detector is already in DETECTOR_TOOLS (auto-refresh via callback)
if "__verifier_narrative_test__" in DETECTOR_TOOLS:
    print("  Auto-refresh via callback: new detector already in DETECTOR_TOOLS")
else:
    # Try manual refresh
    try:
        from desloppify.intelligence.narrative._constants import refresh_detector_tools
        refresh_detector_tools()
    except ImportError:
        try:
            from desloppify.intelligence.narrative._constants import _refresh_detector_tools
            _refresh_detector_tools()
        except ImportError:
            try:
                from desloppify.intelligence.narrative._constants import rebuild_detector_tools
                rebuild_detector_tools()
            except ImportError:
                print("  No refresh function found and no auto-refresh", file=sys.stderr)
                del DETECTORS["__verifier_narrative_test__"]
                sys.exit(1)

    if "__verifier_narrative_test__" not in DETECTOR_TOOLS:
        print("  refresh was called but detector still not in DETECTOR_TOOLS", file=sys.stderr)
        del DETECTORS["__verifier_narrative_test__"]
        sys.exit(1)

    print("  Manual refresh works: new detector appears in DETECTOR_TOOLS")

# Verify the entry has expected fields
entry = DETECTOR_TOOLS["__verifier_narrative_test__"]
if not isinstance(entry, dict):
    print(f"  DETECTOR_TOOLS entry is {type(entry).__name__}, not dict", file=sys.stderr)
    del DETECTORS["__verifier_narrative_test__"]
    sys.exit(1)

if "action_type" not in entry and "guidance" not in entry:
    print(f"  DETECTOR_TOOLS entry missing expected keys: {sorted(entry.keys())}", file=sys.stderr)
    del DETECTORS["__verifier_narrative_test__"]
    sys.exit(1)

# Clean up
del DETECTORS["__verifier_narrative_test__"]
print("  DETECTOR_TOOLS refresh verified with correct entry structure")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 9 (0.05): Langs command or capability reporting
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
            # Even without filtering, having the command counts
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
# CHECK 10 (0.10): Existing test suite still passes (no regressions)
#   The agent's changes must not break anything that was already working.
#   Pre-existing failure: test_legacy_assets_badge_path_migrates_to_root_default
#   in test_config.py — ignore this known issue.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 10: Existing tests pass (no regressions) ==="

cd "$WORKSPACE"
# Run the core tests that existed at the base commit.
# Ignore pre-existing failure in test_config.py (badge_path migration test)
# and the fixtures directory, and the agent's new test file.
python3 -m pytest desloppify/tests/ -q --tb=line \
    --ignore=desloppify/tests/fixtures \
    --ignore=desloppify/tests/lang/common \
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
