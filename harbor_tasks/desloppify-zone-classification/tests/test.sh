#!/usr/bin/env bash
#
# Verification script for desloppify-zone-classification task.
# Tests the zone classification system implementation.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# DESIGN PRINCIPLES (agentic verifier pattern):
#   - Every check is deterministic: no LLM calls, no subjective evaluation.
#   - Checks test STRUCTURAL PROPERTIES not exact code: the agent can use
#     any approach as long as the key functions and behaviors exist.
#   - Partial credit: each component is independently scored.
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

# ===================================================================
# CHECK 1 (0.10): zones.py exists and core classes are importable
#   Zone enum, ZoneRule dataclass, COMMON_ZONE_RULES must exist.
# ===================================================================
echo "--- Check 1: zones.py core classes ---"

CORE_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import Zone, ZoneRule, COMMON_ZONE_RULES

    # Zone enum must have at least PRODUCTION, TEST, CONFIG, GENERATED
    required_zones = {'production', 'test', 'config', 'generated'}
    actual_zones = {z.value for z in Zone}
    missing = required_zones - actual_zones
    if missing:
        print(f'FAIL:missing_zones={missing}')
    elif not isinstance(COMMON_ZONE_RULES, list) or len(COMMON_ZONE_RULES) < 2:
        print(f'FAIL:COMMON_ZONE_RULES_too_short={len(COMMON_ZONE_RULES)}')
    else:
        # Check ZoneRule has zone and patterns
        rule = COMMON_ZONE_RULES[0]
        if hasattr(rule, 'zone') and hasattr(rule, 'patterns'):
            print('PASS')
        else:
            print('FAIL:ZoneRule_missing_fields')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Core classes result: $CORE_RESULT"

if [ "$CORE_RESULT" = "PASS" ]; then
    echo "  PASS: Zone, ZoneRule, COMMON_ZONE_RULES all importable and correct"
    add_reward 0.10
else
    echo "  FAIL: ($CORE_RESULT)"
fi

# ===================================================================
# CHECK 2 (0.15): _match_pattern function exists and works correctly
#   Must handle directory patterns, prefix patterns, suffix patterns,
#   exact basename patterns, and fallback substring matching.
# ===================================================================
echo "--- Check 2: _match_pattern function ---"

MATCH_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import _match_pattern

    errors = []

    # Directory pattern: /tests/ should match paths containing /tests/
    if not _match_pattern('src/tests/test_foo.py', '/tests/'):
        errors.append('dir_match_failed')
    if _match_pattern('src/my_tests_dir/foo.py', '/tests/'):
        errors.append('dir_false_positive')

    # Prefix pattern: test_ should match basenames starting with test_
    if not _match_pattern('src/tests/test_foo.py', 'test_'):
        errors.append('prefix_match_failed')
    if _match_pattern('src/contest_results.py', 'test_'):
        errors.append('prefix_false_positive')

    # Exact basename: config.py should match only files named config.py
    if not _match_pattern('src/config.py', 'config.py'):
        errors.append('exact_match_failed')
    if not _match_pattern('deep/nested/config.py', 'config.py'):
        errors.append('exact_deep_match_failed')

    # Suffix pattern: _test.py should match basenames ending with _test.py
    if not _match_pattern('src/foo_test.py', '_test.py'):
        errors.append('suffix_match_failed')

    # Extension/dot pattern: .test. should match basenames containing .test.
    if not _match_pattern('src/foo.test.ts', '.test.'):
        errors.append('dot_pattern_failed')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  _match_pattern result: $MATCH_RESULT"

if [ "$MATCH_RESULT" = "PASS" ]; then
    echo "  PASS: _match_pattern handles all pattern types correctly"
    add_reward 0.15
else
    echo "  FAIL: ($MATCH_RESULT)"
fi

# ===================================================================
# CHECK 3 (0.10): classify_file function with override support
#   Must classify files by rules and support manual overrides.
# ===================================================================
echo "--- Check 3: classify_file with overrides ---"

CLASSIFY_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import classify_file, Zone, ZoneRule, COMMON_ZONE_RULES

    errors = []

    # Test classification with COMMON_ZONE_RULES
    z = classify_file('vendor/lib.py', COMMON_ZONE_RULES)
    if z != Zone.VENDOR:
        errors.append(f'vendor_classification={z}')

    z = classify_file('tests/test_foo.py', COMMON_ZONE_RULES)
    if z != Zone.TEST:
        errors.append(f'test_classification={z}')

    z = classify_file('src/main.py', COMMON_ZONE_RULES)
    if z != Zone.PRODUCTION:
        errors.append(f'production_classification={z}')

    # Test override: production file overridden to test
    z = classify_file('src/main.py', COMMON_ZONE_RULES,
                      overrides={'src/main.py': 'test'})
    if z != Zone.TEST:
        errors.append(f'override_failed={z}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  classify_file result: $CLASSIFY_RESULT"

if [ "$CLASSIFY_RESULT" = "PASS" ]; then
    echo "  PASS: classify_file works with rules and overrides"
    add_reward 0.10
else
    echo "  FAIL: ($CLASSIFY_RESULT)"
fi

# ===================================================================
# CHECK 4 (0.10): FileZoneMap class with production_count
#   Must build a zone map from files and provide counts.
# ===================================================================
echo "--- Check 4: FileZoneMap class ---"

ZONEMAP_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, Zone, COMMON_ZONE_RULES

    files = [
        'src/main.py',
        'src/utils.py',
        'tests/test_main.py',
        'vendor/lib.py',
        'generated/schema.py',
    ]
    zm = FileZoneMap(files, COMMON_ZONE_RULES)

    errors = []

    # Check zone assignments
    if zm.get('src/main.py') != Zone.PRODUCTION:
        errors.append(f'main_zone={zm.get(\"src/main.py\")}')
    if zm.get('tests/test_main.py') != Zone.TEST:
        errors.append(f'test_zone={zm.get(\"tests/test_main.py\")}')
    if zm.get('vendor/lib.py') != Zone.VENDOR:
        errors.append(f'vendor_zone={zm.get(\"vendor/lib.py\")}')

    # Check production_count exists and returns correct value
    if not hasattr(zm, 'production_count'):
        errors.append('missing_production_count')
    else:
        pc = zm.production_count()
        if pc != 2:  # main.py and utils.py
            errors.append(f'production_count={pc},expected=2')

    # Check counts method exists
    if not hasattr(zm, 'counts'):
        errors.append('missing_counts')
    else:
        c = zm.counts()
        if not isinstance(c, dict):
            errors.append(f'counts_not_dict={type(c)}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  FileZoneMap result: $ZONEMAP_RESULT"

if [ "$ZONEMAP_RESULT" = "PASS" ]; then
    echo "  PASS: FileZoneMap builds correctly with production_count"
    add_reward 0.10
else
    echo "  FAIL: ($ZONEMAP_RESULT)"
fi

# ===================================================================
# CHECK 5 (0.10): adjust_potential helper function
#   Must subtract non-production files from a potential count.
# ===================================================================
echo "--- Check 5: adjust_potential helper ---"

ADJUST_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import adjust_potential, FileZoneMap, COMMON_ZONE_RULES

    files = [
        'src/main.py',
        'src/utils.py',
        'tests/test_main.py',
        'vendor/lib.py',
    ]
    zm = FileZoneMap(files, COMMON_ZONE_RULES)

    errors = []

    # adjust_potential should subtract non-production files from total
    result = adjust_potential(zm, 4)
    if result != 2:
        errors.append(f'adjust_result={result},expected=2')

    # None zone_map should return total unchanged (backward compat)
    result = adjust_potential(None, 10)
    if result != 10:
        errors.append(f'none_result={result},expected=10')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  adjust_potential result: $ADJUST_RESULT"

if [ "$ADJUST_RESULT" = "PASS" ]; then
    echo "  PASS: adjust_potential correctly subtracts non-production files"
    add_reward 0.10
else
    echo "  FAIL: ($ADJUST_RESULT)"
fi

# ===================================================================
# CHECK 6 (0.10): should_skip_finding helper function
#   Must check zone policy to determine if a finding should be skipped.
# ===================================================================
echo "--- Check 6: should_skip_finding helper ---"

SKIP_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import (should_skip_finding, FileZoneMap,
                                   COMMON_ZONE_RULES, ZONE_POLICIES, Zone)

    files = [
        'src/main.py',
        'tests/test_main.py',
    ]
    zm = FileZoneMap(files, COMMON_ZONE_RULES)

    errors = []

    # Test zone should skip 'orphaned' detector
    test_policy = ZONE_POLICIES.get(Zone.TEST)
    if test_policy is None:
        errors.append('no_test_policy')
    elif 'orphaned' not in test_policy.skip_detectors:
        errors.append('test_policy_missing_orphaned')

    # should_skip_finding for test file + orphaned = True
    if not should_skip_finding(zm, 'tests/test_main.py', 'orphaned'):
        errors.append('should_skip_test_orphaned_false')

    # should_skip_finding for production file + orphaned = False
    if should_skip_finding(zm, 'src/main.py', 'orphaned'):
        errors.append('should_not_skip_prod_orphaned')

    # None zone_map = never skip (backward compat)
    if should_skip_finding(None, 'tests/test_main.py', 'orphaned'):
        errors.append('none_map_should_not_skip')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  should_skip_finding result: $SKIP_RESULT"

if [ "$SKIP_RESULT" = "PASS" ]; then
    echo "  PASS: should_skip_finding correctly applies zone policies"
    add_reward 0.10
else
    echo "  FAIL: ($SKIP_RESULT)"
fi

# ===================================================================
# CHECK 7 (0.10): zone_cmd.py exists with cmd_zone function
#   New file must exist and be importable.
# ===================================================================
echo "--- Check 7: zone_cmd.py exists ---"

ZONECMD_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.commands.zone_cmd import cmd_zone
    if callable(cmd_zone):
        print('PASS')
    else:
        print('FAIL:cmd_zone_not_callable')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  zone_cmd result: $ZONECMD_RESULT"

if [ "$ZONECMD_RESULT" = "PASS" ]; then
    echo "  PASS: zone_cmd.py importable with cmd_zone function"
    add_reward 0.10
else
    echo "  FAIL: ($ZONECMD_RESULT)"
fi

# ===================================================================
# CHECK 8 (0.05): CLI wiring — zone subcommand registered in cli.py
#   The 'zone' command must be wired into the argument parser.
# ===================================================================
echo "--- Check 8: CLI zone subcommand ---"

CLI_RESULT=$(python3 -c "
import sys, io, contextlib
sys.path.insert(0, '.')

try:
    from desloppify.cli import create_parser
    parser = create_parser()
    # Suppress stderr from argparse errors
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            args = parser.parse_args(['zone', 'show'])
        except SystemExit:
            print('FAIL')
            sys.exit(0)
    if hasattr(args, 'command') and args.command == 'zone':
        print('PASS')
    else:
        print('FAIL')
except Exception as e:
    print('FAIL')
" 2>&1)

echo "  CLI result: $CLI_RESULT"

if [ "$CLI_RESULT" = "PASS" ]; then
    echo "  PASS: zone subcommand registered in CLI parser"
    add_reward 0.05
else
    echo "  FAIL: ($CLI_RESULT)"
fi

# ===================================================================
# CHECK 9 (0.05): Python language zone rules defined
#   PY_ZONE_RULES must exist and include language-specific patterns.
# ===================================================================
echo "--- Check 9: Python zone rules ---"

PYRULES_RESULT=$(python3 -c "
import sys, importlib
sys.path.insert(0, '.')

try:
    # Try direct import first (avoids full lang registry load)
    py_mod = importlib.import_module('desloppify.lang.python')
    # Look for zone rules as module-level variable or in config
    rules = None

    # Check for PY_ZONE_RULES or similar module-level variable
    for attr_name in dir(py_mod):
        val = getattr(py_mod, attr_name)
        if isinstance(val, list) and len(val) > 0:
            item = val[0]
            if hasattr(item, 'zone') and hasattr(item, 'patterns'):
                rules = val
                break

    # Fallback: try instantiating PythonConfig and reading zone_rules
    if rules is None:
        try:
            config = py_mod.PythonConfig()
            rules = getattr(config, 'zone_rules', None)
        except Exception:
            pass

    if not rules or len(rules) < 3:
        print(f'FAIL:too_few_rules={len(rules) if rules else 0}')
    else:
        all_patterns = []
        for r in rules:
            all_patterns.extend(r.patterns)
        has_test_prefix = any('test_' in p for p in all_patterns)
        if has_test_prefix:
            print('PASS')
        else:
            print(f'FAIL:missing_py_test_patterns,patterns={all_patterns[:10]}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Python zone rules result: $PYRULES_RESULT"

if [ "$PYRULES_RESULT" = "PASS" ]; then
    echo "  PASS: Python-specific zone rules defined"
    add_reward 0.05
else
    echo "  FAIL: ($PYRULES_RESULT)"
fi

# ===================================================================
# CHECK 10 (0.05): LangConfig has zone_rules field
#   The base LangConfig must support zone_rules and _zone_map.
# ===================================================================
echo "--- Check 10: LangConfig zone support ---"

LANGCONFIG_RESULT=$(python3 -c "
import sys, ast
sys.path.insert(0, '.')

try:
    # Use AST to check for zone_rules field without triggering full import chain
    with open('desloppify/lang/base.py') as f:
        tree = ast.parse(f.read())

    fields_found = set()
    for node in ast.walk(tree):
        # Look for assignment targets named 'zone_rules' or '_zone_map' in the class body
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            fields_found.add(node.target.id)
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    fields_found.add(t.id)

    # Also try runtime check as fallback
    try:
        from desloppify.lang.base import LangConfig
        import dataclasses
        runtime_fields = {f.name for f in dataclasses.fields(LangConfig)}
        fields_found = fields_found | runtime_fields
    except Exception:
        pass

    errors = []
    if 'zone_rules' not in fields_found:
        errors.append('missing_zone_rules')
    if '_zone_map' not in fields_found:
        errors.append('missing__zone_map')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  LangConfig result: $LANGCONFIG_RESULT"

if [ "$LANGCONFIG_RESULT" = "PASS" ]; then
    echo "  PASS: LangConfig has zone_rules and _zone_map fields"
    add_reward 0.05
else
    echo "  FAIL: ($LANGCONFIG_RESULT)"
fi

# ===================================================================
# CHECK 11 (0.05): filter_entries helper function exists
#   Must filter detector entries by zone policy.
# ===================================================================
echo "--- Check 11: filter_entries helper ---"

FILTER_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import filter_entries, FileZoneMap, COMMON_ZONE_RULES

    files = ['src/main.py', 'tests/test_main.py']
    zm = FileZoneMap(files, COMMON_ZONE_RULES)

    entries = [
        {'file': 'src/main.py', 'name': 'prod_func'},
        {'file': 'tests/test_main.py', 'name': 'test_func'},
    ]

    # Filter by 'orphaned' — test files should be excluded
    filtered = filter_entries(zm, entries, 'orphaned')
    remaining_files = [e['file'] for e in filtered]

    errors = []
    if 'tests/test_main.py' in remaining_files:
        errors.append('test_file_not_filtered')
    if 'src/main.py' not in remaining_files:
        errors.append('prod_file_wrongly_filtered')

    # None zone_map returns all entries unchanged
    all_back = filter_entries(None, entries, 'orphaned')
    if len(all_back) != 2:
        errors.append(f'none_map_count={len(all_back)}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  filter_entries result: $FILTER_RESULT"

if [ "$FILTER_RESULT" = "PASS" ]; then
    echo "  PASS: filter_entries correctly filters by zone policy"
    add_reward 0.05
else
    echo "  FAIL: ($FILTER_RESULT)"
fi

# ===================================================================
# CHECK 12 (0.05): plan.py threads zone_overrides parameter
#   generate_findings must accept zone_overrides parameter.
# ===================================================================
echo "--- Check 12: plan.py zone_overrides parameter ---"

PLAN_RESULT=$(python3 -c "
import sys, inspect
sys.path.insert(0, '.')

try:
    from desloppify.plan import generate_findings
    sig = inspect.signature(generate_findings)
    params = list(sig.parameters.keys())
    if 'zone_overrides' in params:
        print('PASS')
    else:
        print(f'FAIL:params={params}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  plan.py result: $PLAN_RESULT"

if [ "$PLAN_RESULT" = "PASS" ]; then
    echo "  PASS: generate_findings accepts zone_overrides parameter"
    add_reward 0.05
else
    echo "  FAIL: ($PLAN_RESULT)"
fi

# ===================================================================
# CHECK 13 (0.05): ZONE_POLICIES dict exists with correct structure
#   Must map Zone values to policies with skip_detectors sets.
# ===================================================================
echo "--- Check 13: ZONE_POLICIES structure ---"

POLICIES_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import ZONE_POLICIES, Zone

    errors = []

    # Must have at least PRODUCTION, TEST, CONFIG, GENERATED
    for z in [Zone.PRODUCTION, Zone.TEST, Zone.CONFIG, Zone.GENERATED]:
        if z not in ZONE_POLICIES:
            errors.append(f'missing_policy_{z.value}')

    # TEST policy should skip expensive coupling detectors
    test_policy = ZONE_POLICIES.get(Zone.TEST)
    if test_policy:
        sd = test_policy.skip_detectors
        if not isinstance(sd, (set, frozenset)):
            errors.append(f'skip_detectors_type={type(sd)}')
        elif not sd:
            errors.append('test_skip_detectors_empty')
        if not hasattr(test_policy, 'exclude_from_score'):
            errors.append('missing_exclude_from_score')
    else:
        errors.append('no_test_policy')

    # GENERATED/VENDOR should skip most detectors
    gen_policy = ZONE_POLICIES.get(Zone.GENERATED)
    if gen_policy and len(gen_policy.skip_detectors) < 5:
        errors.append(f'generated_too_few_skips={len(gen_policy.skip_detectors)}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  ZONE_POLICIES result: $POLICIES_RESULT"

if [ "$POLICIES_RESULT" = "PASS" ]; then
    echo "  PASS: ZONE_POLICIES has correct structure for all zone types"
    add_reward 0.05
else
    echo "  FAIL: ($POLICIES_RESULT)"
fi

# ===================================================================
# Write final reward
# ===================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
