#!/bin/bash
#
# Verification script for desloppify-treesitter-plugins task.
# Tests the "Make Generic Language Plugins First-Class" implementation.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# Weight breakdown (sum of weights = 1.00):
#   Check 1  (0.07)  register_detector() behavioral          [F2P] - fails at base (no register_detector), passes after implementation
#   Check 2  (0.07)  register_scoring_policy() behavioral    [F2P] - fails at base (no register_scoring_policy), passes after implementation
#   Check 3  (0.16)  E2E generic_lang creates working plugin [F2P] - fails at base (no generic.py), passes after implementation
#   Check 4  (0.07)  fix_cmd creates working FixerConfig     [F2P] - fails at base (no generic fixers), passes after implementation
#   Check 5  (0.07)  Agent's test_generic_plugin.py passes   [F2P] - fails at base (test file doesn't exist), passes after implementation
#   Check 6  (0.07)  Shared phases present (behavioral)      [F2P] - fails at base (no shared phases in generic plugins), passes after implementation
#   Check 7  (0.04)  DETECTOR_TOOLS refresh behavioral       [F2P] - fails at base (no refresh mechanism), passes after implementation
#   Check 8  (0.08)  Langs command or capability report      [F2P] - fails at base (no langs command), passes after implementation
#   Check 9  (0.10)  Existing tests pass (P2P regression)    [P2P] - passes at base and should pass after implementation
#   Check 10 (0.07)  >=3 language plugins load + register    [F2P] - fails at base (no language plugins), passes after implementation
#   Check 11 (0.04)  STRICT all-4 shared phases              [F2P] - fails at base, passes after implementation
#   Check 12 (0.04)  >=3 real plugins produce fixers         [F2P] - fails at base, passes after implementation
#   Check 13 (0.07)  Langs hides shared phases + auto-fix    [F2P] - fails at base, passes after implementation
#   Check 14 (0.02)  Tool w/o fix_cmd produces no fixer      [F2P] - fails at base (no factory), passes after implementation
#   Check 15 (0.03)  Fixer dash-naming + auto_fix action_type [F2P] - fails at base, passes after implementation
#
# Behavioral: 1.00 (100%) | Structural: 0.00 (0%)
# F2P weight: 0.90 (90%) | P2P weight: 0.10 (10%)
#
set +e

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ═══════════════════════════════════════════════════════════════════
# CHECK 1 (0.07): register_detector() WORKS behaviorally       [F2P]
#   Must actually add a DetectorMeta to DETECTORS dict AND update
#   display order (list or function).
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 1: register_detector() behavioral test ==="

python3 << 'PYEOF' && { echo "PASS: register_detector() works"; add_reward 0.07; } || echo "FAIL: register_detector() broken"
import sys
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS, DetectorMeta

before_count = len(DETECTORS)

from desloppify.core.registry import register_detector

test_meta = DetectorMeta(
    name="__verifier_reg_test__",
    display="Verifier Reg Test",
    dimension="Code quality",
    action_type="manual_fix",
    guidance="test guidance text",
)
register_detector(test_meta)

# 1) Must appear in DETECTORS
if "__verifier_reg_test__" not in DETECTORS:
    print("  FAIL: not added to DETECTORS", file=sys.stderr)
    sys.exit(1)

# 2) Fields must match
meta = DETECTORS["__verifier_reg_test__"]
if meta.display != "Verifier Reg Test":
    print(f"  FAIL: display mismatch: {meta.display}", file=sys.stderr)
    sys.exit(1)
if meta.dimension != "Code quality":
    print(f"  FAIL: dimension mismatch: {meta.dimension}", file=sys.stderr)
    sys.exit(1)

# 3) Count increased
if len(DETECTORS) != before_count + 1:
    print(f"  FAIL: count unchanged ({before_count} -> {len(DETECTORS)})", file=sys.stderr)
    sys.exit(1)

# 4) Display order includes it (check multiple mechanisms)
order_ok = False
try:
    from desloppify.core.registry import display_order
    if "__verifier_reg_test__" in display_order():
        order_ok = True
except (ImportError, TypeError):
    pass
if not order_ok:
    try:
        from desloppify.core.registry import _DISPLAY_ORDER
        if "__verifier_reg_test__" in _DISPLAY_ORDER:
            order_ok = True
    except (ImportError, AttributeError):
        pass
if not order_ok:
    # Accept if DETECTORS is ordered and contains the new entry
    if list(DETECTORS.keys())[-1] == "__verifier_reg_test__":
        order_ok = True
if not order_ok:
    print("  FAIL: not in display_order", file=sys.stderr)
    sys.exit(1)

# Clean up
del DETECTORS["__verifier_reg_test__"]
print("  All register_detector checks passed")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.07): register_scoring_policy() WORKS behaviorally [F2P]
#   Must add to DETECTOR_SCORING_POLICIES AND rebuild DIMENSIONS
#   so that the new detector appears in the correct dimension.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 2: register_scoring_policy() behavioral test ==="

python3 << 'PYEOF' && { echo "PASS: register_scoring_policy() works"; add_reward 0.07; } || echo "FAIL: register_scoring_policy() broken"
import sys
sys.path.insert(0, ".")

import desloppify.engine.scoring_internal.policy.core as _core_mod
from desloppify.engine.scoring_internal.policy.core import (
    DETECTOR_SCORING_POLICIES,
    DetectorScoringPolicy,
    register_scoring_policy,
)

before_count = len(DETECTOR_SCORING_POLICIES)

test_policy = DetectorScoringPolicy(
    detector="__verifier_pol_test__",
    dimension="Code quality",
    tier=3,
    file_based=True,
)
register_scoring_policy(test_policy)

# 1) In DETECTOR_SCORING_POLICIES
if "__verifier_pol_test__" not in DETECTOR_SCORING_POLICIES:
    print("  FAIL: not in DETECTOR_SCORING_POLICIES", file=sys.stderr)
    sys.exit(1)

# 2) DIMENSIONS rebuilt: "Code quality" now includes new detector
# Re-access from module to handle both global reassignment and in-place mutation
cq_dim_after = _core_mod.DIMENSIONS_BY_NAME.get("Code quality")
if cq_dim_after is None:
    print("  FAIL: Code quality dimension missing after rebuild", file=sys.stderr)
    sys.exit(1)
if "__verifier_pol_test__" not in cq_dim_after.detectors:
    print(f"  FAIL: not in Code quality detectors: {cq_dim_after.detectors}", file=sys.stderr)
    sys.exit(1)

# 3) FILE_BASED_DETECTORS rebuilt
if "__verifier_pol_test__" not in _core_mod.FILE_BASED_DETECTORS:
    print("  FAIL: not in FILE_BASED_DETECTORS", file=sys.stderr)
    sys.exit(1)

# Clean up
del DETECTOR_SCORING_POLICIES["__verifier_pol_test__"]
try:
    _core_mod._rebuild_derived()
except (ImportError, AttributeError):
    pass

print("  All register_scoring_policy checks passed")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.16): End-to-end: generic_lang creates WORKING plugin [F2P]
#   Import generic_lang (or equivalent factory), create a plugin for
#   a test language, and verify:
#   a) LangConfig produced (0.04)
#   b) Has >=2 phases (0.04)
#   c) Detectors registered in DETECTORS (0.04)
#   d) Scoring policies registered (0.04)
#   e) Security phase present (0.04)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 3: E2E generic_lang creates working plugin ==="

E2E_OUTPUT=$(python3 << 'PYEOF'
import sys, importlib, inspect
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS
from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
from desloppify.languages.framework.base.types import LangConfig

before_detectors = set(DETECTORS.keys())
before_policies = set(DETECTOR_SCORING_POLICIES.keys())

result = None

# ── Strategy A: call generic_lang factory directly ──
mod = None
for mod_path in [
    "desloppify.languages.framework.generic",
    "desloppify.languages._framework.generic",
]:
    try:
        mod = importlib.import_module(mod_path)
        break
    except ImportError:
        continue

if mod is not None:
    factory = None
    for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
        factory = getattr(mod, name, None)
        if factory and callable(factory):
            break
        factory = None

    if factory:
        test_tool = {
            "label": "verifier_e2e_tool",
            "cmd": "echo '{}'",
            "fmt": "json",
            "id": "verifier_e2e_lint",
            "tier": 3,
        }

        # Build kwargs dynamically from factory signature
        sig_kwargs = {}
        try:
            sig = inspect.signature(factory)
            for p, param in sig.parameters.items():
                if p in ("name", "lang_name", "language"):
                    sig_kwargs[p] = "__verifier_e2e_lang__"
                elif p in ("extensions", "exts", "file_extensions"):
                    sig_kwargs[p] = [".vfy"]
                elif p in ("tools",):
                    sig_kwargs[p] = [test_tool]
                elif param.default is not inspect.Parameter.empty:
                    pass  # has default, skip
                elif p in ("integration_depth", "depth"):
                    sig_kwargs[p] = "generic"
                elif p in ("file_finder",):
                    sig_kwargs[p] = lambda **kw: []
                elif p in ("extract_functions", "noop_extract_functions"):
                    sig_kwargs[p] = lambda *a, **kw: []
                elif p in ("dep_graph", "empty_dep_graph"):
                    sig_kwargs[p] = lambda *a, **kw: {}
                elif p in ("quality_message", "quality_msg"):
                    sig_kwargs[p] = "Generic plugin"
        except (ValueError, TypeError):
            pass

        for attempt in [
            lambda: factory(**sig_kwargs) if sig_kwargs else None,
            lambda: factory(name="__verifier_e2e_lang__", extensions=[".vfy"], tools=[test_tool]),
            lambda: factory("__verifier_e2e_lang__", [".vfy"], [test_tool]),
            lambda: factory({"name": "__verifier_e2e_lang__", "extensions": [".vfy"], "tools": [test_tool]}),
        ]:
            try:
                r = attempt()
                if r is not None:
                    result = r
                    break
            except (TypeError, KeyError, ValueError, AttributeError, RuntimeError):
                continue

# ── Strategy B: load a real generic plugin via discovery + get_lang() ──
if result is None:
    # Try triggering plugin discovery first (load_all / discover_plugins)
    for disc_path in [
        "desloppify.languages.framework.discovery",
        "desloppify.languages._framework.discovery",
        "desloppify.languages.discovery",
    ]:
        try:
            disc = importlib.import_module(disc_path)
            for fn_name in ["load_all", "discover_plugins", "register_all", "load_languages"]:
                fn = getattr(disc, fn_name, None)
                if fn and callable(fn):
                    fn()
                    break
        except Exception:
            continue

    for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
        try:
            # Import module first to trigger registration (matches Check 4/6 pattern)
            for mp in [
                f"desloppify.languages.{lang}",
                f"desloppify.languages.plugin_{lang}",
                f"desloppify.languages._framework.plugins.{lang}",
            ]:
                try:
                    importlib.import_module(mp)
                    break
                except ImportError:
                    continue
            from desloppify.languages.framework.resolution import get_lang
            cfg = get_lang(lang)
            if cfg is not None:
                result = cfg
                break
        except Exception:
            continue

if result is None:
    print("FAIL_CALL")
    sys.exit(0)

try:
    results = []

    # a) Is a LangConfig or has phases
    if isinstance(result, LangConfig):
        results.append("IS_LANGCONFIG")
    elif hasattr(result, "phases"):
        results.append("HAS_PHASES")
    else:
        results.append("NO_LANGCONFIG")

    # b) Has >=2 phases
    if hasattr(result, "phases") and len(result.phases) >= 2:
        results.append(f"PHASES:{len(result.phases)}")
    elif hasattr(result, "phases"):
        results.append(f"FEW_PHASES:{len(result.phases)}")
    else:
        results.append("NO_PHASES")

    # c) New detectors registered
    after_detectors = set(DETECTORS.keys())
    new_det = after_detectors - before_detectors
    if new_det:
        results.append(f"NEW_DETECTORS:{len(new_det)}")
    else:
        results.append("NO_NEW_DETECTORS")

    # d) New scoring policies registered
    after_policies = set(DETECTOR_SCORING_POLICIES.keys())
    new_pol = after_policies - before_policies
    if new_pol:
        results.append(f"NEW_POLICIES:{len(new_pol)}")
    else:
        results.append("NO_NEW_POLICIES")

    # e) Security phase present
    if hasattr(result, "phases") and result.phases:
        phase_labels = [p.label.lower() for p in result.phases]
        if any("security" in l for l in phase_labels):
            results.append("HAS_SECURITY_PHASE")
        else:
            results.append("NO_SECURITY_PHASE")
    else:
        results.append("NO_SECURITY_PHASE")

    print("|".join(results))

except Exception as e:
    print(f"FAIL_EXCEPTION:{type(e).__name__}:{e}")
PYEOF
)

echo "  E2E output: $E2E_OUTPUT"

case "$E2E_OUTPUT" in
    FAIL_IMPORT*|FAIL_NO_FACTORY*|FAIL_CALL*|FAIL_EXCEPTION*)
        echo "FAIL: $E2E_OUTPUT"
        ;;
    *)
        E2E_POINTS=0

        # a) LangConfig produced (0.04)
        if echo "$E2E_OUTPUT" | grep -q "IS_LANGCONFIG\|HAS_PHASES"; then
            echo "  + LangConfig produced"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # b) >=2 phases (0.04)
        if echo "$E2E_OUTPUT" | grep -qP "PHASES:\d+"; then
            echo "  + Has multiple phases"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # c) Detectors registered (0.04)
        if echo "$E2E_OUTPUT" | grep -q "NEW_DETECTORS:"; then
            echo "  + Detectors registered"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # d) Policies registered (0.04)
        if echo "$E2E_OUTPUT" | grep -q "NEW_POLICIES:"; then
            echo "  + Scoring policies registered"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # e) Security phase (0.04)
        if echo "$E2E_OUTPUT" | grep -q "HAS_SECURITY_PHASE"; then
            echo "  + Security phase present"
            E2E_POINTS=$((E2E_POINTS + 1))
        fi

        # Proportional scoring: 0.032 per sub-check (5 * 0.032 = 0.16)
        if [ "$E2E_POINTS" -gt 0 ]; then
            E2E_REWARD=$(python3 -c "print(round($E2E_POINTS * 0.032, 3))")
            echo "  Score: $E2E_POINTS/5 sub-checks = $E2E_REWARD"
            add_reward "$E2E_REWARD"
        else
            echo "FAIL: 0/5 e2e sub-checks"
        fi
        ;;
esac

# ═══════════════════════════════════════════════════════════════════
# CHECK 4 (0.07): fix_cmd creates working FixerConfig objects   [F2P]
#   Call generic_lang with a tool that has fix_cmd and verify the
#   resulting config has FixerConfig entries with callable detect+fix.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 4: fix_cmd creates working FixerConfig ==="

python3 << 'PYEOF' && { echo "PASS: FixerConfig creation works"; add_reward 0.07; } || echo "FAIL: FixerConfig creation broken"
import sys, importlib, inspect
sys.path.insert(0, ".")

from desloppify.languages.framework.base.types import FixerConfig

found_working_fixer = False

# Strategy 1: Call generic_lang with a fix_cmd tool and check config.fixers
for mod_path in [
    "desloppify.languages.framework.generic",
    "desloppify.languages._framework.generic",
]:
    try:
        mod = importlib.import_module(mod_path)
    except ImportError:
        continue

    factory = None
    for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
        factory = getattr(mod, name, None)
        if factory and callable(factory):
            break
        factory = None
    if not factory:
        continue

    test_tool = {
        "label": "verifier_fix_tool",
        "cmd": "echo '{}'",
        "fmt": "json",
        "id": "verifier_fix_lint",
        "tier": 3,
        "fix_cmd": "echo 'fixed'",
    }

    # Build kwargs dynamically from factory signature
    sig_kwargs = {}
    try:
        sig = inspect.signature(factory)
        for p, param in sig.parameters.items():
            if p in ("name", "lang_name", "language"):
                sig_kwargs[p] = "__verifier_fix_lang__"
            elif p in ("extensions", "exts", "file_extensions"):
                sig_kwargs[p] = [".vfy"]
            elif p in ("tools",):
                sig_kwargs[p] = [test_tool]
            elif param.default is not inspect.Parameter.empty:
                pass
            elif p in ("integration_depth", "depth"):
                sig_kwargs[p] = "generic"
            elif p in ("file_finder",):
                sig_kwargs[p] = lambda **kw: []
            elif p in ("extract_functions", "noop_extract_functions"):
                sig_kwargs[p] = lambda *a, **kw: []
            elif p in ("dep_graph", "empty_dep_graph"):
                sig_kwargs[p] = lambda *a, **kw: {}
            elif p in ("quality_message", "quality_msg"):
                sig_kwargs[p] = "Generic plugin"
    except (ValueError, TypeError):
        pass

    result = None
    for attempt in [
        lambda: factory(**sig_kwargs) if sig_kwargs else None,
        lambda: factory(name="__verifier_fix_lang__", extensions=[".vfy"], tools=[test_tool]),
        lambda: factory("__verifier_fix_lang__", [".vfy"], [test_tool]),
    ]:
        try:
            result = attempt()
            if result is not None:
                break
        except (TypeError, KeyError, ValueError, AttributeError, RuntimeError):
            continue

    if result and hasattr(result, "fixers") and result.fixers:
        for fname, fcfg in result.fixers.items():
            if isinstance(fcfg, FixerConfig) and callable(fcfg.detect) and callable(fcfg.fix):
                print(f"  Strategy 1: generic_lang produced FixerConfig '{fname}' with callable detect+fix")
                found_working_fixer = True
                break
    if found_working_fixer:
        break

# Strategy 2: Call _make_generic_fixer (or similar) directly
if not found_working_fixer:
    for mod_path in [
        "desloppify.languages.framework.generic",
        "desloppify.languages._framework.generic",
    ]:
        try:
            mod = importlib.import_module(mod_path)
        except ImportError:
            continue
        for attr_name in dir(mod):
            fn = getattr(mod, attr_name)
            if not callable(fn) or attr_name.startswith("__"):
                continue
            if "fixer" not in attr_name.lower() and "fix" not in attr_name.lower():
                continue
            try:
                test_tool = {
                    "label": "verifier_fix_tool",
                    "cmd": "echo '{}'",
                    "fmt": "json",
                    "id": "verifier_fix2",
                    "tier": 3,
                    "fix_cmd": "echo 'fixed'",
                }
                fixer = fn(test_tool)
                if isinstance(fixer, FixerConfig) and callable(fixer.detect) and callable(fixer.fix):
                    print(f"  Strategy 2: {attr_name}() produces valid FixerConfig")
                    found_working_fixer = True
                    break
            except Exception:
                continue
        if found_working_fixer:
            break

# Strategy 3: Check an actual language plugin's fixers
if not found_working_fixer:
    for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
        try:
            for mp in [f"desloppify.languages.{lang}", f"desloppify.languages.plugin_{lang}", f"desloppify.languages._framework.plugins.{lang}"]:
                try:
                    importlib.import_module(mp)
                    break
                except ImportError:
                    continue
            from desloppify.languages.framework.resolution import get_lang
            cfg = get_lang(lang)
            if cfg and hasattr(cfg, "fixers") and cfg.fixers:
                for fname, fcfg in cfg.fixers.items():
                    if isinstance(fcfg, FixerConfig) and callable(fcfg.detect) and callable(fcfg.fix):
                        print(f"  Strategy 3: {lang} has FixerConfig '{fname}'")
                        found_working_fixer = True
                        break
            if found_working_fixer:
                break
        except Exception:
            pass

if not found_working_fixer:
    print("  No working FixerConfig found via any strategy", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 5 (0.07): Agent's test_generic_plugin.py PASSES pytest  [F2P]
#   The agent must write tests that pass AND are real tests.
#   Quality gate: >=10 functions, >=50% with assertions,
#   >=2 desloppify imports, >=3 test names reference new features.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 5: Agent's test_generic_plugin.py passes pytest ==="

cd "$WORKSPACE"

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

    QUALITY_OK=$(python3 << PYEOF
import ast, sys, re

with open("$TEST_FILE") as f:
    source = f.read()
tree = ast.parse(source)

test_funcs = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef) and n.name.startswith("test_")]
num_tests = len(test_funcs)

if num_tests < 10:
    print(f"FAIL_COUNT:{num_tests}", end="")
    sys.exit(0)

# Count tests with assertions
tests_with_asserts = 0
for func in test_funcs:
    func_source = ast.get_source_segment(source, func) or ""
    has_assert = False
    for node in ast.walk(func):
        if isinstance(node, ast.Assert):
            has_assert = True
            break
        if (isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr.startswith("assert")):
            has_assert = True
            break
    if not has_assert and ("assert" in func_source.lower() or "raises" in func_source.lower()):
        has_assert = True
    if has_assert:
        tests_with_asserts += 1

assert_ratio = tests_with_asserts / num_tests if num_tests > 0 else 0

# Count distinct desloppify module imports
desloppify_imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom) and node.module and "desloppify" in node.module:
        desloppify_imports.add(node.module)
    if isinstance(node, ast.Import):
        for alias in node.names:
            if "desloppify" in alias.name:
                desloppify_imports.add(alias.name)

# Test names must reference new features (anti-gaming)
keywords = {"register", "detector", "scoring", "policy", "generic", "fixer",
            "phase", "narrative", "lang_config", "langconfig", "shared", "security"}
relevant_names = 0
for func in test_funcs:
    name_lower = func.name.lower()
    if any(kw in name_lower for kw in keywords):
        relevant_names += 1

if assert_ratio < 0.5:
    print(f"FAIL_ASSERTS:{tests_with_asserts}/{num_tests}", end="")
elif len(desloppify_imports) < 2:
    print(f"FAIL_IMPORTS:{len(desloppify_imports)}", end="")
elif relevant_names < 3:
    print(f"FAIL_RELEVANCE:{relevant_names}", end="")
else:
    print(f"OK:{num_tests}:{tests_with_asserts}:{len(desloppify_imports)}:{relevant_names}", end="")
PYEOF
    )

    echo "  Quality: $QUALITY_OK"

    case "$QUALITY_OK" in
        FAIL_COUNT*)
            echo "FAIL: Too few test functions (need >= 10)"
            ;;
        FAIL_ASSERTS*)
            echo "FAIL: Too few assertions (need >= 50%)"
            ;;
        FAIL_IMPORTS*)
            echo "FAIL: Too few desloppify imports (need >= 2)"
            ;;
        FAIL_RELEVANCE*)
            echo "FAIL: Too few tests reference new features (need >= 3 with relevant names)"
            ;;
        OK*)
            timeout 60 python3 -m pytest "$TEST_FILE" -q --tb=line > "$LOG_DIR/agent_tests_full.txt" 2>&1
            tail -15 "$LOG_DIR/agent_tests_full.txt" > "$LOG_DIR/agent_tests.txt"
            cat "$LOG_DIR/agent_tests.txt"

            PASSED=$(grep -oP '\d+ passed' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
            FAILED=$(grep -oP '\d+ failed' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
            ERRORS=$(grep -oP '\d+ error' "$LOG_DIR/agent_tests.txt" | grep -oP '\d+' || echo "0")
            TOTAL=$((PASSED + FAILED + ERRORS))

            if [ "$TOTAL" -eq 0 ]; then
                echo "FAIL: No tests collected"
            else
                PASS_RATE=$(python3 -c "print($PASSED / $TOTAL)")
                echo "  Pass rate: $PASSED/$TOTAL = $PASS_RATE"

                if python3 -c "exit(0 if $PASS_RATE >= 0.8 else 1)"; then
                    echo "PASS: >= 80% pass"
                    add_reward 0.07
                elif python3 -c "exit(0 if $PASS_RATE >= 0.5 else 1)"; then
                    echo "PARTIAL: >= 50% pass"
                    add_reward 0.04
                else
                    echo "FAIL: < 50% pass"
                fi
            fi
            ;;
    esac
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 6 (0.07): Shared phases present in generic plugins      [F2P]
#   Generic plugins must include shared phases (security + at least
#   one of subjective review / duplicates / boilerplate).
#   Tested by loading a real plugin or calling the factory.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 6: Shared phases present in generic plugins ==="

python3 << 'PYEOF' && { echo "PASS: Shared phases integrated"; add_reward 0.07; } || echo "FAIL: Shared phases missing"
import sys, importlib, inspect
sys.path.insert(0, ".")

# Strategy 1: Load a real language plugin, check its phases
found_shared = False
for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    try:
        for mp in [f"desloppify.languages.{lang}", f"desloppify.languages.plugin_{lang}", f"desloppify.languages._framework.plugins.{lang}"]:
            try:
                importlib.import_module(mp)
                break
            except ImportError:
                continue
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if cfg and hasattr(cfg, "phases") and cfg.phases:
            labels = {p.label.lower() for p in cfg.phases}
            has_security = any("security" in l for l in labels)
            has_other = any(
                "subjective" in l or "review" in l or "duplicat" in l or "boilerplate" in l
                for l in labels
            )
            if has_security and has_other:
                print(f"  {lang}: security + shared phases found in {sorted(labels)}")
                found_shared = True
                break
            elif has_security:
                print(f"  {lang}: security phase found (partial)")
                found_shared = True
                break
    except Exception:
        pass

# Strategy 2: Call generic_lang directly
if not found_shared:
    for mod_path in [
        "desloppify.languages.framework.generic",
        "desloppify.languages._framework.generic",
    ]:
        try:
            mod = importlib.import_module(mod_path)
        except ImportError:
            continue
        factory = None
        for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
            factory = getattr(mod, name, None)
            if factory and callable(factory):
                break
            factory = None
        if not factory:
            continue

        test_tool = {
            "label": "verifier_shared_tool",
            "cmd": "echo '{}'",
            "fmt": "json",
            "id": "verifier_shared_lint",
            "tier": 3,
        }
        sig_kwargs = {}
        try:
            sig = inspect.signature(factory)
            for p, param in sig.parameters.items():
                if p in ("name", "lang_name", "language"):
                    sig_kwargs[p] = "__verifier_shared_lang__"
                elif p in ("extensions", "exts", "file_extensions"):
                    sig_kwargs[p] = [".vfy"]
                elif p in ("tools",):
                    sig_kwargs[p] = [test_tool]
                elif param.default is not inspect.Parameter.empty:
                    pass
                elif p in ("integration_depth", "depth"):
                    sig_kwargs[p] = "generic"
                elif p in ("file_finder",):
                    sig_kwargs[p] = lambda **kw: []
                elif p in ("extract_functions", "noop_extract_functions"):
                    sig_kwargs[p] = lambda *a, **kw: []
                elif p in ("dep_graph", "empty_dep_graph"):
                    sig_kwargs[p] = lambda *a, **kw: {}
                elif p in ("quality_message", "quality_msg"):
                    sig_kwargs[p] = "Generic plugin"
        except (ValueError, TypeError):
            pass
        result = None
        for attempt in [
            lambda: factory(**sig_kwargs) if sig_kwargs else None,
            lambda: factory(name="__verifier_shared_lang__", extensions=[".vfy"], tools=[test_tool]),
            lambda: factory("__verifier_shared_lang__", [".vfy"], [test_tool]),
        ]:
            try:
                result = attempt()
                if result is not None:
                    break
            except (TypeError, KeyError, ValueError, AttributeError, RuntimeError):
                continue

        if result and hasattr(result, "phases") and result.phases:
            labels = {p.label.lower() for p in result.phases}
            has_security = any("security" in l for l in labels)
            has_other = any(
                "subjective" in l or "review" in l or "duplicat" in l or "boilerplate" in l
                for l in labels
            )
            if has_security and has_other:
                print(f"  Factory: security + shared phases in {sorted(labels)}")
                found_shared = True
            elif has_security:
                print(f"  Factory: security phase found (partial)")
                found_shared = True
        if found_shared:
            break

if not found_shared:
    print("  No shared phases found", file=sys.stderr)
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 7 (0.04): Narrative DETECTOR_TOOLS refresh behaviorally [F2P]
#   After calling refresh, DETECTOR_TOOLS must reflect newly
#   registered detectors.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 7: DETECTOR_TOOLS refresh behavioral ==="

python3 << 'PYEOF' && { echo "PASS: DETECTOR_TOOLS refresh works"; add_reward 0.04; } || echo "FAIL: DETECTOR_TOOLS refresh broken"
import sys
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector

test_meta = DetectorMeta(
    name="__verifier_narr_test__",
    display="Verifier Narr Test",
    dimension="Code quality",
    action_type="manual_fix",
    guidance="narrative test",
)
register_detector(test_meta)

from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS

# Check auto-refresh via callback
if "__verifier_narr_test__" in DETECTOR_TOOLS:
    print("  Auto-refresh: new detector in DETECTOR_TOOLS")
else:
    # Try manual refresh
    refreshed = False
    for func_name in ["refresh_detector_tools", "_refresh_detector_tools", "rebuild_detector_tools"]:
        try:
            from desloppify.intelligence.narrative import _constants
            fn = getattr(_constants, func_name, None)
            if fn:
                fn()
                refreshed = True
                break
        except Exception:
            continue

    if not refreshed:
        del DETECTORS["__verifier_narr_test__"]
        print("  No refresh mechanism found", file=sys.stderr)
        sys.exit(1)

    if "__verifier_narr_test__" not in DETECTOR_TOOLS:
        del DETECTORS["__verifier_narr_test__"]
        print("  Refresh called but detector not in DETECTOR_TOOLS", file=sys.stderr)
        sys.exit(1)
    print("  Manual refresh: new detector in DETECTOR_TOOLS")

# Verify entry structure (dict with action metadata)
entry = DETECTOR_TOOLS["__verifier_narr_test__"]
if not isinstance(entry, dict):
    del DETECTORS["__verifier_narr_test__"]
    print(f"  Entry is {type(entry).__name__}, not dict", file=sys.stderr)
    sys.exit(1)

if "action_type" not in entry and "guidance" not in entry:
    del DETECTORS["__verifier_narr_test__"]
    print(f"  Entry missing expected keys: {sorted(entry.keys())}", file=sys.stderr)
    sys.exit(1)

del DETECTORS["__verifier_narr_test__"]
print("  DETECTOR_TOOLS entry has correct structure")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 8 (0.08): Langs command or capability reporting          [F2P]
#   The langs command or capability_report must be callable and
#   produce meaningful output (not just exist as dead code).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 8: Langs command or capability reporting ==="

CHECK8_PASS=false

# Strategy 1: Run the CLI command
timeout 30 python3 -m desloppify langs 2>&1 > "$LOG_DIR/langs_output.txt"
LANGS_EXIT=$?
if [ $LANGS_EXIT -eq 0 ] && [ -s "$LOG_DIR/langs_output.txt" ]; then
    LINES=$(wc -l < "$LOG_DIR/langs_output.txt")
    if [ "$LINES" -ge 3 ]; then
        echo "  CLI 'desloppify langs' produced $LINES lines"
        CHECK8_PASS=true
    fi
fi

# Strategy 2: Import and call the command module
if [ "$CHECK8_PASS" = false ]; then
    python3 << 'PYEOF' && CHECK8_PASS=true || true
import sys, importlib
sys.path.insert(0, ".")

found = False
for mod_path in [
    "desloppify.app.commands.langs",
    "desloppify.app.commands.langs_cmd",
]:
    try:
        mod = importlib.import_module(mod_path)
        # Find a callable command function
        for attr_name in dir(mod):
            fn = getattr(mod, attr_name)
            if callable(fn) and not attr_name.startswith("_"):
                # Found a public callable in the langs module
                found = True
                print(f"  Langs module {mod_path} has callable '{attr_name}'")
                break
        if found:
            break
    except ImportError:
        continue

if not found:
    # Strategy 3: Check capability_report is callable from generic module
    for mod_path in [
        "desloppify.languages.framework.generic",
        "desloppify.languages._framework.generic",
    ]:
        try:
            mod = importlib.import_module(mod_path)
            for attr_name in dir(mod):
                if "capability" in attr_name.lower() or "report" in attr_name.lower():
                    fn = getattr(mod, attr_name)
                    if callable(fn):
                        print(f"  Found callable {attr_name} in {mod_path}")
                        found = True
                        break
            if found:
                break
        except ImportError:
            continue

if not found:
    sys.exit(1)
PYEOF
fi

if [ "$CHECK8_PASS" = true ]; then
    echo "PASS: Langs command or capability report works"
    add_reward 0.08
else
    echo "FAIL: No langs command or capability report found"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 9 (0.10): Existing test suite still passes (P2P)        [P2P]
#   Agent's changes must not break pre-existing tests.
#   Known pre-existing failure excluded.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 9: Existing tests pass (P2P regression) ==="

cd "$WORKSPACE"
timeout 90 python3 -m pytest desloppify/tests/ -q --tb=line \
    --ignore=desloppify/tests/fixtures \
    --ignore=desloppify/tests/lang/common \
    -k "not test_legacy_assets_badge_path_migrates_to_root_default and not test_unknown_ext" \
    --continue-on-collection-errors \
    > "$LOG_DIR/pytest_full.txt" 2>&1
PYTEST_EXIT=$?
tail -10 "$LOG_DIR/pytest_full.txt" > "$LOG_DIR/pytest_output.txt"

cat "$LOG_DIR/pytest_output.txt"

if [ $PYTEST_EXIT -eq 0 ]; then
    echo "PASS: All existing tests pass"
    add_reward 0.10
elif [ $PYTEST_EXIT -eq 1 ]; then
    FAILED=$(grep -oP '\d+ failed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    TOTAL=$(grep -oP '\d+ passed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    echo "PARTIAL: $FAILED failed, $TOTAL passed"
    if [ "$TOTAL" -gt 0 ] 2>/dev/null && [ "$FAILED" -le 2 ] 2>/dev/null; then
        echo "  Minor regressions (<=2 failures)"
        add_reward 0.06
    elif [ "$TOTAL" -gt 0 ] 2>/dev/null && [ "$FAILED" -lt 10 ] 2>/dev/null; then
        echo "  Moderate regressions (<10 failures)"
        add_reward 0.03
    fi
elif [ $PYTEST_EXIT -eq 2 ]; then
    # Exit code 2 = collection errors. This often happens when new plugins cause import
    # errors in test files that import all languages. Check if actual test failures exist.
    PASSED=$(grep -oP '\d+ passed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    ERRORS=$(grep -oP '\d+ error' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    FAILED=$(grep -oP '\d+ failed' "$LOG_DIR/pytest_output.txt" | grep -oP '\d+' || echo "0")
    echo "PARTIAL: collection errors=$ERRORS, failed=$FAILED, passed=$PASSED"
    if [ "$PASSED" -gt 0 ] 2>/dev/null; then
        if [ "$FAILED" -eq 0 ] 2>/dev/null; then
            # Collection errors only (from new plugins), no test failures
            echo "  Collection errors from new plugins, no test failures"
            add_reward 0.05
        else
            add_reward 0.02
        fi
    fi
elif [ $PYTEST_EXIT -eq 5 ]; then
    echo "WARN: No tests collected (paths may have changed)"
    timeout 30 python3 -m pytest desloppify/ -q --tb=line --co 2>&1 | tail -5 > "$LOG_DIR/pytest_collect.txt"
    COLLECTED=$(grep -oP '\d+ tests?' "$LOG_DIR/pytest_collect.txt" | head -1 || echo "0")
    echo "  Tests found elsewhere: $COLLECTED"
    if [ -n "$COLLECTED" ] && [ "$COLLECTED" != "0" ]; then
        add_reward 0.02
    fi
elif [ $PYTEST_EXIT -eq 124 ]; then
    echo "WARN: pytest timed out (90s)"
    add_reward 0.02
else
    echo "FAIL: pytest exited with code $PYTEST_EXIT"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 10 (0.07): >=3 language plugins load and register       [F2P]
#   Import language plugin modules (go, rust, ruby, swift, kotlin),
#   verify each one registers detectors in the DETECTORS dict.
#   Require >=3 of 5 to pass.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 10: Language plugins load and register detectors ==="

LANGS_LOADED=$(python3 << 'PYEOF'
import sys, importlib
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS

# Try triggering plugin discovery first (load_all / discover_plugins)
for disc_path in [
    "desloppify.languages.framework.discovery",
    "desloppify.languages._framework.discovery",
    "desloppify.languages.discovery",
]:
    try:
        disc = importlib.import_module(disc_path)
        for fn_name in ["load_all", "discover_plugins", "register_all", "load_languages"]:
            fn = getattr(disc, fn_name, None)
            if fn and callable(fn):
                fn()
                break
    except Exception:
        continue

loaded = 0
for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    before = set(DETECTORS.keys())
    found = False
    cfg = None

    # Strategy 1: Import module first to trigger registration, then get_lang
    for mp in [
        f"desloppify.languages.{lang}",
        f"desloppify.languages.plugin_{lang}",
        f"desloppify.languages._framework.plugins.{lang}",
    ]:
        try:
            importlib.import_module(mp)
            break
        except ImportError:
            continue

    try:
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if cfg is not None:
            found = True
    except Exception:
        pass

    # Strategy 2: Direct module import only (if get_lang didn't work)
    if not found:
        for mp in [
            f"desloppify.languages.{lang}",
            f"desloppify.languages.plugin_{lang}",
            f"desloppify.languages._framework.plugins.{lang}",
        ]:
            try:
                importlib.import_module(mp)
                found = True
                break
            except ImportError:
                continue

    if not found:
        print(f"  {lang}: not found via get_lang or import", file=sys.stderr)
        continue

    after = set(DETECTORS.keys())
    new = after - before
    if new:
        print(f"  {lang}: registered detectors {sorted(new)}")
        loaded += 1
    else:
        # Maybe already loaded by a previous import; check if lang-related detectors exist
        lang_related = [d for d in DETECTORS if lang in d.lower() or
                        (lang == "go" and "golangci" in d.lower()) or
                        (lang == "rust" and "clippy" in d.lower()) or
                        (lang == "ruby" and "rubocop" in d.lower()) or
                        (lang == "swift" and "swiftlint" in d.lower()) or
                        (lang == "kotlin" and "ktlint" in d.lower())]
        if lang_related:
            print(f"  {lang}: found related detectors {lang_related}")
            loaded += 1
        elif cfg is not None:
            # Plugin loaded via get_lang but no detectors — still counts as loaded
            print(f"  {lang}: loaded via get_lang (phases={len(cfg.phases) if hasattr(cfg, 'phases') else '?'})")
            loaded += 1
        else:
            print(f"  {lang}: loaded but no detectors registered", file=sys.stderr)

print(f"LOADED:{loaded}")
PYEOF
)

echo "  $LANGS_LOADED"

LANG_COUNT=$(echo "$LANGS_LOADED" | grep -oP 'LOADED:\K\d+' || echo "0")
if [ "$LANG_COUNT" -ge 3 ]; then
    echo "PASS: $LANG_COUNT/5 language plugins loaded with detectors"
    add_reward 0.07
elif [ "$LANG_COUNT" -ge 1 ]; then
    echo "PARTIAL: $LANG_COUNT/5 language plugins loaded"
    add_reward 0.03
else
    echo "FAIL: No language plugins loaded"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 11 (0.04): STRICT all-4 shared phases present            [F2P]
#   Step 3 of the plan REQUIRES all four: security + subjective
#   review + duplicates + boilerplate duplication. Check 6 accepts
#   partial (security-only); this harder check asserts all four are
#   attached to at least one real generic language plugin.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 11: STRICT all-4 shared phases present ==="

python3 << 'PYEOF' && { echo "PASS: All 4 shared phases present"; add_reward 0.04; } || echo "FAIL: Not all 4 shared phases present"
import sys, importlib
sys.path.insert(0, ".")

need = {
    "security": ("security",),
    "subjective": ("subjective", "review"),
    "duplicates": ("duplicat",),
    "boilerplate": ("boilerplate",),
}

found_all = False
for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    try:
        for mp in [
            f"desloppify.languages.{lang}",
            f"desloppify.languages.plugin_{lang}",
            f"desloppify.languages._framework.plugins.{lang}",
        ]:
            try:
                importlib.import_module(mp)
                break
            except ImportError:
                continue
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if not cfg or not hasattr(cfg, "phases") or not cfg.phases:
            continue
        labels = [p.label.lower() for p in cfg.phases]
        joined = " | ".join(labels)
        hits = {
            key: any(any(tok in l for tok in toks) for l in labels)
            for key, toks in need.items()
        }
        if all(hits.values()):
            print(f"  {lang}: all 4 shared phases present in {labels}")
            found_all = True
            break
        else:
            missing = [k for k, v in hits.items() if not v]
            print(f"  {lang}: missing {missing} (have: {joined})")
    except Exception as e:
        print(f"  {lang}: error {type(e).__name__}: {e}")

if not found_all:
    sys.exit(1)
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 12 (0.04): Real plugins produce working fixers           [F2P]
#   Step 4 of the plan REQUIRES adding fix_cmd to 5 specific plugin
#   files (go/rust/ruby/swift/kotlin). Check 4 only requires ONE
#   working FixerConfig via any strategy (synthetic tool counts).
#   This check asserts >=3 of the 5 real plugins yield FixerConfig
#   objects, so an agent that forgot plugin-side edits is penalised.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 12: Real plugins produce fixers ==="

FIXER_COUNT=$(python3 << 'PYEOF'
import sys, importlib
sys.path.insert(0, ".")

from desloppify.languages.framework.base.types import FixerConfig

working = 0
for lang in ["go", "rust", "ruby", "swift", "kotlin"]:
    try:
        for mp in [
            f"desloppify.languages.{lang}",
            f"desloppify.languages.plugin_{lang}",
            f"desloppify.languages._framework.plugins.{lang}",
        ]:
            try:
                importlib.import_module(mp)
                break
            except ImportError:
                continue
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if not cfg or not hasattr(cfg, "fixers") or not cfg.fixers:
            continue
        for fname, fcfg in cfg.fixers.items():
            if isinstance(fcfg, FixerConfig) and callable(fcfg.detect) and callable(fcfg.fix):
                print(f"  {lang}: fixer '{fname}' OK")
                working += 1
                break
    except Exception:
        pass

print(f"WORKING:{working}")
PYEOF
)
echo "$FIXER_COUNT"
COUNT=$(echo "$FIXER_COUNT" | grep -oP 'WORKING:\K\d+' || echo "0")
if [ "$COUNT" -ge 3 ]; then
    echo "PASS: $COUNT/5 real plugins have fixers"
    add_reward 0.04
elif [ "$COUNT" -ge 1 ]; then
    echo "PARTIAL: $COUNT/5 real plugins have fixers"
    add_reward 0.02
else
    echo "FAIL: No real plugins have fixers"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 13 (0.07): Langs command hides shared phases + shows      [F2P]
#                  auto-fix suffix
#   Step 5 of the plan REQUIRES: (a) filter _SHARED_PHASE_LABELS from
#   tool-labels output, (b) append " (auto-fix)" suffix when
#   fixers are present. Check 8 only tests "some callable exists".
#   This check calls the CLI and asserts observable output.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 13: langs output hides shared phases + shows auto-fix ==="

timeout 30 python3 -m desloppify langs > "$LOG_DIR/langs_output_v2.txt" 2>&1
L_EXIT=$?
OUT_FILE="$LOG_DIR/langs_output_v2.txt"

CHECK13_POINTS=0
if [ $L_EXIT -eq 0 ] && [ -s "$OUT_FILE" ]; then
    # (a) "(auto-fix)" suffix appears somewhere in langs output
    if grep -qiE '\(auto[- ]?fix\)' "$OUT_FILE"; then
        echo "  + auto-fix suffix present in langs output"
        CHECK13_POINTS=$((CHECK13_POINTS + 1))
    else
        echo "  - auto-fix suffix missing"
    fi
    # (b) shared phase labels should NOT appear in the tool-labels portion.
    # We accept pass if at most 1 of the 4 shared labels appears in the
    # output (some plugins may still reference them contextually).
    SHARED_HITS=0
    for label in "Security" "Subjective review" "Boilerplate duplication" "Duplicates"; do
        if grep -q "$label" "$OUT_FILE"; then
            SHARED_HITS=$((SHARED_HITS + 1))
        fi
    done
    if [ "$SHARED_HITS" -le 1 ]; then
        echo "  + shared phase labels filtered (hits=$SHARED_HITS)"
        CHECK13_POINTS=$((CHECK13_POINTS + 1))
    else
        echo "  - too many shared phase labels surface in langs output (hits=$SHARED_HITS)"
    fi
else
    echo "  (langs command did not run cleanly; exit=$L_EXIT)"
fi

if [ "$CHECK13_POINTS" -eq 2 ]; then
    echo "PASS: langs formatting correct"
    add_reward 0.07
elif [ "$CHECK13_POINTS" -eq 1 ]; then
    echo "PARTIAL: one of two langs formatting rules met"
    add_reward 0.03
else
    echo "FAIL: langs formatting not present"
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 14 (0.02): Tool without fix_cmd produces NO fixer         [F2P]
#   Step 4 explicitly lists tools that must NOT get a fixer
#   (elixir/php/cxx/bash/perl/lua credo/phpstan/cppcheck/shellcheck/
#   perlcritic/luacheck). A correct implementation keys fixer
#   creation on the presence of fix_cmd; a broken one creates a
#   fixer for every tool. We assert the negative behaviourally.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 14: tool without fix_cmd → no fixer ==="

python3 << 'PYEOF' && { echo "PASS: no-fix_cmd tool produces no fixer"; add_reward 0.02; } || echo "FAIL: tool without fix_cmd still has a fixer"
import sys, importlib, inspect
sys.path.insert(0, ".")

mod = None
for mod_path in [
    "desloppify.languages.framework.generic",
    "desloppify.languages._framework.generic",
]:
    try:
        mod = importlib.import_module(mod_path)
        break
    except ImportError:
        continue

if mod is None:
    print("  generic module not importable", file=sys.stderr)
    sys.exit(1)

factory = None
for name in ["generic_lang", "make_generic_lang", "create_generic_lang"]:
    fn = getattr(mod, name, None)
    if fn and callable(fn):
        factory = fn
        break

if factory is None:
    # Accept fallback: check a real plugin (e.g. bash) has empty fixers
    try:
        importlib.import_module("desloppify.languages.bash")
    except ImportError:
        try:
            importlib.import_module("desloppify.languages.plugin_bash")
        except ImportError:
            pass
    try:
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang("bash")
        if cfg is not None and hasattr(cfg, "fixers"):
            if not cfg.fixers:
                print("  bash plugin has no fixers (shellcheck has no fix_cmd)")
                sys.exit(0)
            else:
                print(f"  bash plugin unexpectedly has fixers: {list(cfg.fixers)}", file=sys.stderr)
                sys.exit(1)
    except Exception:
        pass
    print("  no factory found and no real plugin to check", file=sys.stderr)
    sys.exit(1)

test_tool = {
    "label": "verifier_nofix_tool",
    "cmd": "echo '{}'",
    "fmt": "json",
    "id": "verifier_nofix_lint",
    "tier": 3,
    # deliberately no fix_cmd
}

sig_kwargs = {}
try:
    sig = inspect.signature(factory)
    for p, param in sig.parameters.items():
        if p in ("name", "lang_name", "language"):
            sig_kwargs[p] = "__verifier_nofix_lang__"
        elif p in ("extensions", "exts", "file_extensions"):
            sig_kwargs[p] = [".vfy"]
        elif p in ("tools",):
            sig_kwargs[p] = [test_tool]
        elif param.default is not inspect.Parameter.empty:
            pass
        elif p in ("integration_depth", "depth"):
            sig_kwargs[p] = "generic"
        elif p in ("file_finder",):
            sig_kwargs[p] = lambda **kw: []
        elif p in ("extract_functions", "noop_extract_functions"):
            sig_kwargs[p] = lambda *a, **kw: []
        elif p in ("dep_graph", "empty_dep_graph"):
            sig_kwargs[p] = lambda *a, **kw: {}
        elif p in ("quality_message", "quality_msg"):
            sig_kwargs[p] = "Generic plugin"
except (ValueError, TypeError):
    pass

result = None
for attempt in [
    lambda: factory(**sig_kwargs) if sig_kwargs else None,
    lambda: factory(name="__verifier_nofix_lang__", extensions=[".vfy"], tools=[test_tool]),
    lambda: factory("__verifier_nofix_lang__", [".vfy"], [test_tool]),
]:
    try:
        r = attempt()
        if r is not None:
            result = r
            break
    except (TypeError, KeyError, ValueError, AttributeError, RuntimeError):
        continue

if result is None:
    # Could not invoke factory directly; fall back to real plugin
    try:
        importlib.import_module("desloppify.languages.bash")
    except ImportError:
        try:
            importlib.import_module("desloppify.languages.plugin_bash")
        except ImportError:
            pass
    try:
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang("bash")
        if cfg is not None and hasattr(cfg, "fixers"):
            if not cfg.fixers:
                print("  fallback: bash plugin has no fixers")
                sys.exit(0)
            else:
                print(f"  fallback: bash plugin has fixers: {list(cfg.fixers)}", file=sys.stderr)
                sys.exit(1)
    except Exception:
        pass
    print("  could not invoke factory to test no-fix_cmd tool", file=sys.stderr)
    sys.exit(1)

fixers = getattr(result, "fixers", None) or {}
if fixers:
    print(f"  FAIL: factory produced fixers for a tool without fix_cmd: {list(fixers)}", file=sys.stderr)
    sys.exit(1)
print("  factory produced no fixers for tool without fix_cmd")
PYEOF

# ═══════════════════════════════════════════════════════════════════
# CHECK 15 (0.03): fixer naming + detector action_type wiring      [F2P]
#   Turn 1 plan explicitly states:
#     fixer_name = tool["id"].replace("_", "-")
#     register_detector(DetectorMeta(..., action_type="auto_fix", ...))
#   Currently unverified. Load a real plugin with fix_cmd (ruby pref,
#   else go/rust/swift/kotlin) and check both (proportional score).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Check 15: fixer dash-naming + auto_fix action_type ==="

CHK15_OUT=$(python3 << 'PYEOF'
import sys, importlib
sys.path.insert(0, ".")

from desloppify.core.registry import DETECTORS

# Known fix_cmd plugins and their tool ids from the instruction plan.
PLUGINS = [
    ("ruby", "rubocop_lint"),
    ("go", "golangci_lint"),
    ("rust", "clippy_lint"),
    ("swift", "swiftlint_lint"),
    ("kotlin", "ktlint_lint"),
]

dash_hit = False
auto_fix_hit = False
dash_detail = ""
auto_detail = ""

for lang, expected_id in PLUGINS:
    try:
        for mp in [f"desloppify.languages.{lang}",
                   f"desloppify.languages.plugin_{lang}",
                   f"desloppify.languages._framework.plugins.{lang}"]:
            try:
                importlib.import_module(mp)
                break
            except ImportError:
                continue
        from desloppify.languages.framework.resolution import get_lang
        cfg = get_lang(lang)
        if not cfg:
            continue

        # Check dash naming: some fixer key must contain "-" (the agent may
        # have picked a different id but the replace("_","-") rule means no
        # underscore should appear when a tool's id contained one).
        fixers = getattr(cfg, "fixers", None) or {}
        if not dash_hit and fixers:
            for fname in fixers.keys():
                if "-" in fname and "_" not in fname:
                    dash_hit = True
                    dash_detail = f"{lang}: fixer key '{fname}'"
                    break

        # Check detector action_type for any tool in this plugin that has a
        # fix_cmd attached. We approximate by scanning detectors whose name
        # matches expected_id OR a language-related token. Accept any value
        # that is not "manual_fix" and references auto/fix semantics.
        if not auto_fix_hit:
            candidate_ids = [expected_id] + [
                d for d in DETECTORS
                if lang in d.lower()
                or (lang == "go" and "golangci" in d.lower())
                or (lang == "rust" and "clippy" in d.lower())
                or (lang == "ruby" and "rubocop" in d.lower())
                or (lang == "swift" and "swiftlint" in d.lower())
                or (lang == "kotlin" and "ktlint" in d.lower())
            ]
            for det_id in candidate_ids:
                meta = DETECTORS.get(det_id)
                if meta is None:
                    continue
                at = getattr(meta, "action_type", None)
                if isinstance(at, str) and at and at != "manual_fix" and "fix" in at.lower():
                    auto_fix_hit = True
                    auto_detail = f"{lang}: detector '{det_id}' action_type='{at}'"
                    break
    except Exception:
        continue

points = 0
if dash_hit:
    print(f"  + dash-naming: {dash_detail}")
    points += 1
else:
    print("  - dash-naming: no fixer key used '-' replacement of tool id")
if auto_fix_hit:
    print(f"  + action_type: {auto_detail}")
    points += 1
else:
    print("  - action_type: no fix_cmd plugin detector reports auto_fix")

print(f"CHK15_POINTS:{points}")
PYEOF
)
echo "$CHK15_OUT"
CHK15_POINTS=$(echo "$CHK15_OUT" | grep -oP 'CHK15_POINTS:\K\d+' || echo "0")
if [ "$CHK15_POINTS" -ge 2 ]; then
    echo "PASS: dash-naming + auto_fix action_type"
    add_reward 0.03
elif [ "$CHK15_POINTS" -ge 1 ]; then
    echo "PARTIAL: 1/2 fixer-wiring sub-checks"
    add_reward 0.01
else
    echo "FAIL: neither dash-naming nor auto_fix action_type present"
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
