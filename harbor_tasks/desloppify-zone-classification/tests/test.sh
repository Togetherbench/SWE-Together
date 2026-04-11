#!/usr/bin/env bash
#
# Verification script for desloppify-zone-classification task.
# Tests the zone classification system implementation.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# TIER BREAKDOWN:
#   Checks 1-5:  Fail-to-pass behavioral core   (0.55)
#     (Check 2 split: 2a=classification 0.08, 2b=counts 0.04)
#   Checks 6-8:  Fail-to-pass behavioral silver (0.22)
#   Checks 9-12: Structural (Bronze+)           (0.23)
#   F2P behavioral: 77% | Structural: 23%
#   P2P: 0% (no upstream tests at base commit eba4ad1c)
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

# ===================================================================
# CHECK 1 (0.15): _match_pattern behavioral — CORE BUG, FAIL-TO-PASS
#   Base commit uses raw substring matching which causes false positives.
#   The new _match_pattern must distinguish directory, prefix, suffix,
#   exact basename, and dot patterns, rejecting false positives.
# ===================================================================
echo "--- Check 1: _match_pattern behavioral (0.15) ---"

MATCH_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    try:
        from desloppify.zones import _match_pattern
    except ImportError:
        from desloppify.zones import match_pattern as _match_pattern

    errors = []

    # --- Directory patterns (/dir/) ---
    if not _match_pattern('src/tests/test_foo.py', '/tests/'):
        errors.append('dir_match')
    if not _match_pattern('project/vendor/lib.js', '/vendor/'):
        errors.append('vendor_dir')
    # False positive: substring 'tests' inside another directory name
    if _match_pattern('src/my_tests_dir/foo.py', '/tests/'):
        errors.append('dir_false_positive')

    # --- Prefix patterns (test_) ---
    if not _match_pattern('src/tests/test_foo.py', 'test_'):
        errors.append('prefix_match')
    if not _match_pattern('deep/nested/test_integration.py', 'test_'):
        errors.append('prefix_deep')
    # False positive: 'contest_results' contains 'test_' as substring
    if _match_pattern('src/contest_results.py', 'test_'):
        errors.append('prefix_false_positive')

    # --- Exact basename (config.py) ---
    if not _match_pattern('src/config.py', 'config.py'):
        errors.append('exact_match')
    if not _match_pattern('deep/nested/config.py', 'config.py'):
        errors.append('exact_deep')

    # --- Suffix patterns (_test.py, _test.go) ---
    if not _match_pattern('src/foo_test.py', '_test.py'):
        errors.append('suffix_py')
    if not _match_pattern('pkg/bar_test.go', '_test.go'):
        errors.append('suffix_go')

    # --- Dot patterns (.test.) ---
    if not _match_pattern('src/foo.test.ts', '.test.'):
        errors.append('dot_pattern')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $MATCH_RESULT"
if [ "$MATCH_RESULT" = "PASS" ]; then
    echo "  PASS: _match_pattern handles all pattern types correctly"
    add_reward 0.15
else
    echo "  FAIL: ($MATCH_RESULT)"
fi

# ===================================================================
# CHECK 2a (0.08): FileZoneMap classification + overrides — FAIL-TO-PASS
#   FileZoneMap must classify files by zone and support overrides that
#   reclassify files. production_count() must work correctly.
#   Split from counts() so partial credit is possible.
# ===================================================================
echo "--- Check 2a: FileZoneMap classification + overrides (0.08) ---"

ZONEMAP_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, Zone, COMMON_ZONE_RULES

    files = [
        'src/main.py',
        'src/utils.py',
        'src/models.py',
        'project/tests/test_main.py',
        'project/tests/test_utils.py',
        'lib/vendor/lib.py',
        'build/generated/schema.py',
    ]

    errors = []

    # --- Basic classification (no overrides) ---
    zm = None
    for attempt in [
        lambda: FileZoneMap(files, COMMON_ZONE_RULES),
        lambda: FileZoneMap(files, rules=COMMON_ZONE_RULES),
        lambda: FileZoneMap(files=files, rules=COMMON_ZONE_RULES),
    ]:
        try:
            zm = attempt()
            break
        except TypeError:
            continue
    if zm is None:
        errors.append('ctor_failed')
        raise Exception('FileZoneMap constructor failed with all signatures')

    expected = {
        'src/main.py': Zone.PRODUCTION,
        'project/tests/test_main.py': Zone.TEST,
        'lib/vendor/lib.py': Zone.VENDOR,
        'build/generated/schema.py': Zone.GENERATED,
    }
    for path, exp_zone in expected.items():
        actual = zm.get(path)
        if actual != exp_zone:
            errors.append(f'{path}:exp={exp_zone.value},got={actual}')

    # --- production_count() ---
    if not hasattr(zm, 'production_count'):
        errors.append('missing_production_count')
    else:
        pc = zm.production_count()
        if pc != 3:
            errors.append(f'prod_count={pc},expected=3')

    # --- Overrides: reclassify test file as production ---
    def make_zm_with_overrides(f, r, ovr):
        for attempt in [
            lambda: FileZoneMap(f, r, overrides=ovr),
            lambda: FileZoneMap(f, r, ovr),
            lambda: FileZoneMap(files=f, rules=r, overrides=ovr),
        ]:
            try:
                return attempt()
            except TypeError:
                continue
        return None

    zm2 = make_zm_with_overrides(files, COMMON_ZONE_RULES,
                                  {'project/tests/test_main.py': 'production'})
    if zm2 is None:
        errors.append('override_ctor_failed')
    else:
        if zm2.get('project/tests/test_main.py') != Zone.PRODUCTION:
            errors.append('override_test_to_prod_failed')
        pc2 = zm2.production_count()
        if pc2 != 4:
            errors.append(f'override_prod_count={pc2},expected=4')

    # --- Overrides: reclassify vendor as production ---
    zm3 = make_zm_with_overrides(files, COMMON_ZONE_RULES,
                                  {'lib/vendor/lib.py': 'production'})
    if zm3 is None:
        errors.append('override_ctor2_failed')
    elif zm3.get('lib/vendor/lib.py') != Zone.PRODUCTION:
        errors.append('override_vendor_to_prod_failed')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $ZONEMAP_RESULT"
if [ "$ZONEMAP_RESULT" = "PASS" ]; then
    echo "  PASS: FileZoneMap classifies and overrides correctly"
    add_reward 0.08
else
    echo "  FAIL: ($ZONEMAP_RESULT)"
fi

# ===================================================================
# CHECK 2b (0.04): FileZoneMap.counts() method — FAIL-TO-PASS
#   counts() must return a dict mapping zone values to file counts.
#   Split from 2a so partial credit is awarded for classification
#   even when counts() is missing.
# ===================================================================
echo "--- Check 2b: FileZoneMap.counts() (0.04) ---"

COUNTS_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, Zone, COMMON_ZONE_RULES

    files = [
        'src/main.py',
        'src/utils.py',
        'src/models.py',
        'project/tests/test_main.py',
        'project/tests/test_utils.py',
        'lib/vendor/lib.py',
        'build/generated/schema.py',
    ]

    errors = []

    zm = None
    for attempt in [
        lambda: FileZoneMap(files, COMMON_ZONE_RULES),
        lambda: FileZoneMap(files, rules=COMMON_ZONE_RULES),
        lambda: FileZoneMap(files=files, rules=COMMON_ZONE_RULES),
    ]:
        try:
            zm = attempt()
            break
        except TypeError:
            continue
    if zm is None:
        raise Exception('FileZoneMap constructor failed')

    if not hasattr(zm, 'counts'):
        errors.append('missing_counts')
    else:
        c = zm.counts()
        if not isinstance(c, dict):
            errors.append('counts_not_dict')
        elif sum(c.values()) != len(files):
            errors.append(f'counts_sum={sum(c.values())},expected={len(files)}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $COUNTS_RESULT"
if [ "$COUNTS_RESULT" = "PASS" ]; then
    echo "  PASS: FileZoneMap.counts() returns correct zone distribution"
    add_reward 0.04
else
    echo "  FAIL: ($COUNTS_RESULT)"
fi

# ===================================================================
# CHECK 3 (0.10): adjust_potential behavioral — FAIL-TO-PASS
#   Must subtract non-production files from potential counts.
#   Tests mixed files, all-production, None zone_map, all non-production.
# ===================================================================
echo "--- Check 3: adjust_potential (0.10) ---"

ADJUST_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import adjust_potential, FileZoneMap, COMMON_ZONE_RULES

    errors = []

    def call_adjust(zm, files, total):
        \"\"\"Try both 3-arg and 2-arg signatures.\"\"\"
        try:
            return adjust_potential(zm, files, total)
        except TypeError:
            return adjust_potential(zm, total)

    def make_zm(f, r):
        for attempt in [
            lambda: FileZoneMap(f, r),
            lambda: FileZoneMap(f, rules=r),
            lambda: FileZoneMap(files=f, rules=r),
        ]:
            try: return attempt()
            except TypeError: continue
        raise Exception('FileZoneMap ctor failed')

    # Scenario 1: mixed files (2 prod, 1 test, 1 vendor)
    files1 = ['src/main.py', 'src/utils.py', 'project/tests/test_main.py', 'lib/vendor/lib.py']
    zm1 = make_zm(files1, COMMON_ZONE_RULES)
    r1 = call_adjust(zm1, files1, 4)
    if r1 != 2:
        errors.append(f'mixed={r1},expected=2')

    # Scenario 2: all production
    files2 = ['src/a.py', 'src/b.py', 'src/c.py']
    zm2 = make_zm(files2, COMMON_ZONE_RULES)
    r2 = call_adjust(zm2, files2, 3)
    if r2 != 3:
        errors.append(f'all_prod={r2},expected=3')

    # Scenario 3: None zone_map = no-op (backward compat)
    try:
        r3 = adjust_potential(None, [], 10)
    except TypeError:
        r3 = adjust_potential(None, 10)
    if r3 != 10:
        errors.append(f'none={r3},expected=10')

    # Scenario 4: all non-production
    files4 = ['project/tests/test_a.py', 'lib/vendor/v.py', 'build/generated/g.py']
    zm4 = make_zm(files4, COMMON_ZONE_RULES)
    r4 = call_adjust(zm4, files4, 3)
    if r4 != 0:
        errors.append(f'all_nonprod={r4},expected=0')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $ADJUST_RESULT"
if [ "$ADJUST_RESULT" = "PASS" ]; then
    echo "  PASS: adjust_potential correctly adjusts counts in all scenarios"
    add_reward 0.10
else
    echo "  FAIL: ($ADJUST_RESULT)"
fi

# ===================================================================
# CHECK 4 (0.10): should_skip_finding behavioral — FAIL-TO-PASS
#   Must check zone policies to determine if findings should be skipped.
#   Tests test/orphaned skip, production/orphaned keep, None backward compat.
# ===================================================================
echo "--- Check 4: should_skip_finding (0.10) ---"

SKIP_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import (should_skip_finding, FileZoneMap,
                                   COMMON_ZONE_RULES, ZONE_POLICIES, Zone)

    files = ['src/main.py', 'project/tests/test_main.py', 'lib/vendor/lib.py', 'build/generated/gen.py']
    # Flexible constructor
    zm = None
    for attempt in [
        lambda: FileZoneMap(files, COMMON_ZONE_RULES),
        lambda: FileZoneMap(files, rules=COMMON_ZONE_RULES),
        lambda: FileZoneMap(files=files, rules=COMMON_ZONE_RULES),
    ]:
        try:
            zm = attempt()
            break
        except TypeError:
            continue
    if zm is None:
        raise Exception('FileZoneMap ctor failed')

    errors = []

    def get_skip_detectors(policy):
        \"\"\"Get skip_detectors from policy - handles attr, dict, or set.\"\"\"
        if policy is None:
            return set()
        if hasattr(policy, 'skip_detectors'):
            return policy.skip_detectors
        if isinstance(policy, dict):
            return policy.get('skip_detectors', set())
        return set()

    # Test zone should skip 'orphaned' detector
    test_policy = ZONE_POLICIES.get(Zone.TEST)
    test_skips = get_skip_detectors(test_policy)
    if test_policy is None or 'orphaned' not in test_skips:
        errors.append('test_policy_missing_orphaned')

    # should_skip_finding: test + orphaned = True
    if not should_skip_finding(zm, 'project/tests/test_main.py', 'orphaned'):
        errors.append('test_orphaned_not_skipped')

    # should_skip_finding: production + orphaned = False
    if should_skip_finding(zm, 'src/main.py', 'orphaned'):
        errors.append('prod_orphaned_skipped')

    # Vendor should also skip orphaned
    vendor_policy = ZONE_POLICIES.get(Zone.VENDOR)
    vendor_skips = get_skip_detectors(vendor_policy)
    if vendor_policy and 'orphaned' in vendor_skips:
        if not should_skip_finding(zm, 'lib/vendor/lib.py', 'orphaned'):
            errors.append('vendor_orphaned_not_skipped')

    # None zone_map = never skip (backward compat)
    if should_skip_finding(None, 'project/tests/test_main.py', 'orphaned'):
        errors.append('none_map_skipped')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $SKIP_RESULT"
if [ "$SKIP_RESULT" = "PASS" ]; then
    echo "  PASS: should_skip_finding correctly applies zone policies"
    add_reward 0.10
else
    echo "  FAIL: ($SKIP_RESULT)"
fi

# ===================================================================
# CHECK 5 (0.08): Entry filtering by zone — FAIL-TO-PASS
#   Accepts either a standalone filter_entries() function or constructs
#   filtering from should_skip_finding. Either approach is valid.
# ===================================================================
echo "--- Check 5: entry filtering (0.08) ---"

FILTER_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, COMMON_ZONE_RULES

    # Try filter_entries first, fall back to should_skip_finding
    try:
        from desloppify.zones import filter_entries
    except ImportError:
        from desloppify.zones import should_skip_finding
        def filter_entries(zm, entries, detector):
            return [e for e in entries
                    if not should_skip_finding(zm, e.get('file', ''), detector)]

    files = ['src/main.py', 'src/utils.py', 'project/tests/test_main.py',
             'project/tests/test_utils.py', 'lib/vendor/lib.py']
    # Flexible constructor
    zm = None
    for attempt in [
        lambda: FileZoneMap(files, COMMON_ZONE_RULES),
        lambda: FileZoneMap(files, rules=COMMON_ZONE_RULES),
        lambda: FileZoneMap(files=files, rules=COMMON_ZONE_RULES),
    ]:
        try:
            zm = attempt()
            break
        except TypeError:
            continue
    if zm is None:
        raise Exception('FileZoneMap ctor failed')

    entries = [
        {'file': 'src/main.py', 'name': 'prod_func'},
        {'file': 'src/utils.py', 'name': 'util_func'},
        {'file': 'project/tests/test_main.py', 'name': 'test_func'},
        {'file': 'project/tests/test_utils.py', 'name': 'test_util'},
        {'file': 'lib/vendor/lib.py', 'name': 'vendor_func'},
    ]

    errors = []

    # Filter 'orphaned': test files should be excluded
    filtered = filter_entries(zm, entries, 'orphaned')
    remaining = [e['file'] for e in filtered]

    if 'project/tests/test_main.py' in remaining:
        errors.append('test_not_filtered')
    if 'project/tests/test_utils.py' in remaining:
        errors.append('test2_not_filtered')
    if 'src/main.py' not in remaining:
        errors.append('prod_wrongly_filtered')
    if 'src/utils.py' not in remaining:
        errors.append('prod2_wrongly_filtered')

    # None zone_map returns all entries unchanged
    all_back = filter_entries(None, entries, 'orphaned')
    if len(all_back) != 5:
        errors.append(f'none_map={len(all_back)},expected=5')

    # Empty entries returns empty
    empty = filter_entries(zm, [], 'orphaned')
    if len(empty) != 0:
        errors.append(f'empty={len(empty)}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $FILTER_RESULT"
if [ "$FILTER_RESULT" = "PASS" ]; then
    echo "  PASS: entry filtering by zone works correctly"
    add_reward 0.08
else
    echo "  FAIL: ($FILTER_RESULT)"
fi

# ===================================================================
# CHECK 6 (0.08): COMMON_ZONE_RULES content + behavioral matching
#   Must have >=3 rules with >=5 patterns covering vendor/test/generated.
#   Patterns must actually match expected file paths (behavioral).
# ===================================================================
echo "--- Check 6: COMMON_ZONE_RULES content (0.08) ---"

RULES_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import COMMON_ZONE_RULES, Zone

    try:
        from desloppify.zones import _match_pattern
    except ImportError:
        from desloppify.zones import match_pattern as _match_pattern

    errors = []

    if len(COMMON_ZONE_RULES) < 3:
        errors.append(f'too_few_rules={len(COMMON_ZONE_RULES)}')

    all_patterns = []
    zones_covered = set()
    for rule in COMMON_ZONE_RULES:
        zones_covered.add(rule.zone)
        all_patterns.extend(rule.patterns)

    if len(all_patterns) < 5:
        errors.append(f'too_few_patterns={len(all_patterns)}')

    for z in [Zone.VENDOR, Zone.TEST, Zone.GENERATED]:
        if z not in zones_covered:
            errors.append(f'no_{z.value}_rule')

    # Behavioral: patterns must match expected files
    test_cases = [
        ('project/tests/test_foo.py', Zone.TEST),
        ('lib/vendor/third_party.py', Zone.VENDOR),
        ('build/generated/proto.py', Zone.GENERATED),
    ]
    for path, expected_zone in test_cases:
        matched = False
        for rule in COMMON_ZONE_RULES:
            if rule.zone == expected_zone:
                for pat in rule.patterns:
                    if _match_pattern(path, pat):
                        matched = True
                        break
            if matched:
                break
        if not matched:
            errors.append(f'no_match:{path}')

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $RULES_RESULT"
if [ "$RULES_RESULT" = "PASS" ]; then
    echo "  PASS: COMMON_ZONE_RULES has sufficient rules with working patterns"
    add_reward 0.08
else
    echo "  FAIL: ($RULES_RESULT)"
fi

# ===================================================================
# CHECK 7 (0.07): Per-language zone rules (Python + TypeScript)
#   Both language modules must define zone rules lists (>=3 rules each)
#   with language-specific test patterns.
# ===================================================================
echo "--- Check 7: per-language zone rules (0.07) ---"

LANG_RESULT=$(python3 -c "
import sys, importlib
sys.path.insert(0, '.')

errors = []

def find_zone_rules(module):
    \"\"\"Find zone rules in a module — prefer longest list with zone+patterns items.\"\"\"
    candidates = []
    for attr_name in dir(module):
        val = getattr(module, attr_name)
        if isinstance(val, list) and len(val) > 0:
            item = val[0]
            if hasattr(item, 'zone') and hasattr(item, 'patterns'):
                candidates.append((attr_name, val))
    # Return the longest candidate (per-language rules include common rules)
    if candidates:
        candidates.sort(key=lambda x: len(x[1]), reverse=True)
        return candidates[0][1]
    # Try config classes
    for attr_name in dir(module):
        cls = getattr(module, attr_name)
        if isinstance(cls, type):
            try:
                instance = cls()
                rules = getattr(instance, 'zone_rules', None)
                if rules and isinstance(rules, list) and len(rules) > 0:
                    return rules
            except Exception:
                pass
    return None

try:
    py_mod = importlib.import_module('desloppify.lang.python')
    py_rules = find_zone_rules(py_mod)
    if not py_rules or len(py_rules) < 2:
        errors.append(f'py_too_few={len(py_rules) if py_rules else 0}')
    else:
        py_pats = []
        for r in py_rules:
            py_pats.extend(r.patterns)
        if not any('test_' in p or '/tests/' in p for p in py_pats):
            errors.append('py_missing_test_pattern')
except Exception as e:
    errors.append(f'py_error={e}')

try:
    ts_mod = importlib.import_module('desloppify.lang.typescript')
    ts_rules = find_zone_rules(ts_mod)
    if not ts_rules or len(ts_rules) < 2:
        errors.append(f'ts_too_few={len(ts_rules) if ts_rules else 0}')
    else:
        ts_pats = []
        for r in ts_rules:
            ts_pats.extend(r.patterns)
        if not any('.test.' in p or '.spec.' in p or '__tests__' in p
                   for p in ts_pats):
            errors.append('ts_missing_test_pattern')
except Exception as e:
    errors.append(f'ts_error={e}')

if not errors:
    print('PASS')
else:
    print(f'FAIL:{errors}')
" 2>&1)

echo "  Result: $LANG_RESULT"
if [ "$LANG_RESULT" = "PASS" ]; then
    echo "  PASS: Python and TypeScript both have zone rules with test patterns"
    add_reward 0.07
else
    echo "  FAIL: ($LANG_RESULT)"
fi

# ===================================================================
# CHECK 8 (0.07): CLI zone subcommand parseable
#   The 'zone' command must be wired into the CLI argument parser.
#   Tests parser args and subprocess invocation (no source-check fallback).
# ===================================================================
echo "--- Check 8: CLI zone subcommand (0.07) ---"

CLI_RESULT=$(python3 -c "
import sys, subprocess, io, contextlib
sys.path.insert(0, '.')

# Approach 1: try parsing args directly via create_parser
try:
    from desloppify.cli import create_parser
    parser = create_parser()
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            args = parser.parse_args(['zone', 'show'])
        except SystemExit as e:
            if e.code == 2:
                raise ValueError('zone not recognized')
    print('PASS')
    sys.exit(0)
except (ImportError, AttributeError):
    pass
except ValueError:
    pass

# Approach 2: try running CLI subprocess — exit 0 or 1 = recognized,
# exit 2 = argparse unrecognized error
try:
    r = subprocess.run(
        [sys.executable, '-m', 'desloppify', 'zone', '--help'],
        capture_output=True, text=True, timeout=10
    )
    if r.returncode != 2:
        print('PASS')
        sys.exit(0)
    # Also check if 'zone' appears in the main help as a subcommand
    r2 = subprocess.run(
        [sys.executable, '-m', 'desloppify', '--help'],
        capture_output=True, text=True, timeout=10
    )
    if 'zone' in r2.stdout:
        print('PASS')
        sys.exit(0)
except Exception:
    pass

print('FAIL')
" 2>&1)

echo "  Result: $CLI_RESULT"
if [ "$CLI_RESULT" = "PASS" ]; then
    echo "  PASS: zone subcommand is registered in CLI"
    add_reward 0.07
else
    echo "  FAIL: ($CLI_RESULT)"
fi

# ===================================================================
# CHECK 9 (0.05): zone_cmd.py — non-stub cmd_zone
#   zone_cmd.py must exist with a cmd_zone function whose body has
#   >=2 non-trivial statements (rejects stub implementations).
#   AST justified: cmd_zone requires state dict + argparse args that
#   are complex to construct outside a full CLI context.
# ===================================================================
echo "--- Check 9: zone_cmd.py non-stub (0.05) ---"

ZONECMD_RESULT=$(python3 -c "
import sys, ast, os
sys.path.insert(0, '.')

candidates = [
    'desloppify/commands/zone_cmd.py',
    'desloppify/zone_cmd.py',
    'desloppify/commands/zone.py',
]

found = None
for p in candidates:
    if os.path.exists(p):
        found = p
        break

if not found:
    # Try import as last resort
    try:
        from desloppify.commands.zone_cmd import cmd_zone
        if callable(cmd_zone):
            # Can't check body depth via import, but function exists
            print('PASS')
        else:
            print('FAIL:not_callable')
    except Exception:
        print('FAIL:not_found')
    sys.exit(0)

with open(found) as f:
    tree = ast.parse(f.read())

# Find cmd_zone (or any function with 'zone' and 'cmd' in name)
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if 'zone' in node.name.lower() and 'cmd' in node.name.lower():
            body = [s for s in node.body
                    if not isinstance(s, ast.Pass)
                    and not (isinstance(s, ast.Expr)
                             and isinstance(getattr(s, 'value', None), ast.Constant))]
            if len(body) >= 2:
                print('PASS')
            else:
                print(f'FAIL:body_too_short={len(body)}')
            sys.exit(0)

# Fallback: file must have >=2 functions each with >=2 non-trivial statements
substantial = 0
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        body = [s for s in node.body
                if not isinstance(s, ast.Pass)
                and not (isinstance(s, ast.Expr)
                         and isinstance(getattr(s, 'value', None), ast.Constant))]
        if len(body) >= 2:
            substantial += 1
if substantial >= 2:
    print('PASS')
else:
    print(f'FAIL:insufficient_functions={substantial}')
" 2>&1)

echo "  Result: $ZONECMD_RESULT"
if [ "$ZONECMD_RESULT" = "PASS" ]; then
    echo "  PASS: zone_cmd.py has non-stub cmd_zone function"
    add_reward 0.05
else
    echo "  FAIL: ($ZONECMD_RESULT)"
fi

# ===================================================================
# CHECK 10 (0.06): plan.py zone_overrides + LangConfig zone fields
#   generate_findings must accept zone_overrides parameter.
#   LangConfig must have zone_rules and _zone_map fields.
# ===================================================================
echo "--- Check 10: plan.py + LangConfig (0.06) ---"

INTEG_RESULT=$(python3 -c "
import sys, inspect, ast
sys.path.insert(0, '.')

errors = []

# Part A: generate_findings accepts zone_overrides
try:
    from desloppify.plan import generate_findings
    sig = inspect.signature(generate_findings)
    if 'zone_overrides' not in sig.parameters:
        errors.append('no_zone_overrides_param')
except Exception as e:
    errors.append(f'plan_error')

# Part B: LangConfig has zone_rules (dataclass field, class attr, or instance attr)
try:
    from desloppify.lang.base import LangConfig
    import dataclasses
    found_zone_rules = False
    # Check dataclass fields first
    try:
        fields = {f.name for f in dataclasses.fields(LangConfig)}
        if 'zone_rules' in fields:
            found_zone_rules = True
    except TypeError:
        pass
    # Fallback: check class attribute or __init__ signature
    if not found_zone_rules:
        if hasattr(LangConfig, 'zone_rules'):
            found_zone_rules = True
        else:
            import inspect
            sig = inspect.signature(LangConfig.__init__)
            if 'zone_rules' in sig.parameters:
                found_zone_rules = True
    if not found_zone_rules:
        errors.append('no_zone_rules_field')
except Exception as e:
    errors.append('langconfig_import_error')

if not errors:
    print('PASS')
else:
    print(f'FAIL:{errors}')
" 2>&1)

echo "  Result: $INTEG_RESULT"
if [ "$INTEG_RESULT" = "PASS" ]; then
    echo "  PASS: plan.py and LangConfig have zone infrastructure"
    add_reward 0.06
else
    echo "  FAIL: ($INTEG_RESULT)"
fi

# ===================================================================
# CHECK 11 (0.05): ZONE_POLICIES structure
#   Must map Zone values to policies with skip_detectors sets.
#   TEST/GENERATED/VENDOR must have non-empty skip_detectors.
# ===================================================================
echo "--- Check 11: ZONE_POLICIES structure (0.05) ---"

POLICIES_RESULT=$(python3 -c "
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import ZONE_POLICIES, Zone

    errors = []

    def get_skip_detectors(policy):
        if policy is None:
            return None
        if hasattr(policy, 'skip_detectors'):
            return policy.skip_detectors
        if isinstance(policy, dict):
            return policy.get('skip_detectors')
        return None

    # Must have policies for TEST and GENERATED
    for z in [Zone.TEST, Zone.GENERATED]:
        p = ZONE_POLICIES.get(z)
        if p is None:
            errors.append(f'missing_{z.value}')
        else:
            sd = get_skip_detectors(p)
            if sd is None:
                errors.append(f'{z.value}_no_skip_detectors')
            elif not isinstance(sd, (set, frozenset, list, tuple)):
                errors.append(f'{z.value}_wrong_type')
            elif not sd:
                errors.append(f'{z.value}_empty')

    # GENERATED/VENDOR should skip at least some detectors (>=1)
    for z in [Zone.GENERATED, Zone.VENDOR]:
        p = ZONE_POLICIES.get(z)
        sd = get_skip_detectors(p) if p else None
        if sd is not None and len(sd) < 1:
            errors.append(f'{z.value}_too_few_skips={len(sd)}')

    # PRODUCTION policy is optional — should_skip_finding handles missing entries
    # (production files are never skipped regardless)

    if not errors:
        print('PASS')
    else:
        print(f'FAIL:{errors}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $POLICIES_RESULT"
if [ "$POLICIES_RESULT" = "PASS" ]; then
    echo "  PASS: ZONE_POLICIES has correct structure for all zone types"
    add_reward 0.05
else
    echo "  FAIL: ($POLICIES_RESULT)"
fi

# ===================================================================
# CHECK 12 (0.07): Phase runner integration
#   At least one language module (Python or TypeScript) must have
#   zone-related functions accessible, indicating zone integration
#   in phase runners. Tries behavioral import check first, falls
#   back to AST if modules have side effects preventing import.
# ===================================================================
echo "--- Check 12: phase runner integration (0.07) ---"

PHASE_RESULT=$(python3 -c "
import sys, ast, os, importlib
sys.path.insert(0, '.')

zone_integrated = 0

# Approach 1 (behavioral): check if lang modules have zone-related
# names in their namespace (from importing zones functions)
for mod_name in ['desloppify.lang.python', 'desloppify.lang.typescript']:
    try:
        mod = importlib.import_module(mod_name)
        zone_names = ['adjust_potential', 'should_skip_finding',
                       'filter_entries', 'FileZoneMap']
        if any(hasattr(mod, name) for name in zone_names):
            zone_integrated += 1
            continue
        # Also check for zone rules variable (e.g. PY_ZONE_RULES)
        for attr in dir(mod):
            if 'zone' in attr.lower() and 'rule' in attr.lower():
                zone_integrated += 1
                break
    except Exception:
        pass

# Approach 2 (AST fallback): check for import statements from zones
if zone_integrated == 0:
    for lang_path in ['desloppify/lang/python/__init__.py',
                       'desloppify/lang/typescript/__init__.py']:
        if not os.path.exists(lang_path):
            continue
        try:
            with open(lang_path) as f:
                tree = ast.parse(f.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ImportFrom):
                    if node.module and 'zones' in node.module:
                        zone_integrated += 1
                        break
                    if node.names:
                        for alias in node.names:
                            if alias.name and 'zone' in alias.name.lower():
                                zone_integrated += 1
                                break
        except Exception:
            pass

if zone_integrated >= 1:
    print('PASS')
else:
    print(f'FAIL:no_zone_integration')
" 2>&1)

echo "  Result: $PHASE_RESULT"
if [ "$PHASE_RESULT" = "PASS" ]; then
    echo "  PASS: Phase runners have zone integration"
    add_reward 0.07
else
    echo "  FAIL: ($PHASE_RESULT)"
fi

# ===================================================================
# Write final reward
# ===================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
