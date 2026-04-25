#!/bin/bash
set +e
#
# Verification script for desloppify-zone-classification.
# Behavioral checks dominate: we exercise _match_pattern, classify_file,
# FileZoneMap, adjust_potential, should_skip_finding, and run a real scan
# against a synthetic project to verify potentials are adjusted and findings
# are filtered by zone.
#

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN { s=a+b; if (s>1.0) s=1.0; printf "%.4f", s }')
}

cd "$WORKSPACE" 2>/dev/null || {
    echo "FATAL: workspace $WORKSPACE not found"
    echo "0.0" > "$LOG_DIR/reward.txt"
    exit 0
}

export PYTHONPATH="$WORKSPACE:$PYTHONPATH"

# ===================================================================
# CHECK 1 (0.20): _match_pattern behavioral precision
# Discriminates substring-only from precision-aware matchers.
# ===================================================================
echo "--- Check 1: _match_pattern precision (0.20) ---"

MATCH_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')

try:
    try:
        from desloppify.zones import _match_pattern as MP
    except ImportError:
        from desloppify.zones import match_pattern as MP

    cases = []
    # Directory patterns must match at root and nested, but NOT substring of dirname
    cases.append(('dir_root',     True,  MP('vendor/lib.js', '/vendor/')))
    cases.append(('dir_nested',   True,  MP('lib/vendor/lib.js', '/vendor/')))
    cases.append(('dir_tests',    True,  MP('src/tests/test_foo.py', '/tests/')))
    cases.append(('dir_neg_fp',   False, MP('src/my_tests_dir/foo.py', '/tests/')))
    cases.append(('dir_neg_sub',  False, MP('src/contests/foo.py', '/tests/')))

    # Prefix patterns (trailing _)
    cases.append(('prefix_pos',   True,  MP('src/tests/test_foo.py', 'test_')))
    cases.append(('prefix_deep',  True,  MP('a/b/c/test_x.py', 'test_')))
    cases.append(('prefix_neg',   False, MP('src/contest_results.py', 'test_')))
    cases.append(('prefix_neg2',  False, MP('src/my_test_helpers.py', 'test_')))

    # Exact basename (config.py only matches files literally named config.py)
    cases.append(('exact_pos',    True,  MP('src/config.py', 'config.py')))
    cases.append(('exact_deep',   True,  MP('a/b/config.py', 'config.py')))
    cases.append(('exact_neg',    False, MP('src/my_config.py', 'config.py')))

    # Suffix patterns (leading _ or .)
    cases.append(('suffix_pos',   True,  MP('src/foo_test.py', '_test.py')))
    cases.append(('dot_pos',      True,  MP('src/foo.test.ts', '.test.')))
    cases.append(('dot_pos2',     True,  MP('src/foo.spec.ts', '.spec.')))

    failed = [(name, exp, got) for name, exp, got in cases if exp != got]
    passed = len(cases) - len(failed)
    print(f'SCORE:{passed}/{len(cases)}')
    if failed:
        for name, exp, got in failed[:5]:
            print(f'  fail:{name} exp={exp} got={got}')
except Exception as e:
    print(f'ERROR:{type(e).__name__}:{e}')
PYEOF
)
echo "$MATCH_RESULT" | head -8 | sed 's/^/  /'
M_PASS=$(echo "$MATCH_RESULT" | grep -oE 'SCORE:[0-9]+/[0-9]+' | head -1 | sed 's/SCORE://')
if [ -n "$M_PASS" ]; then
    M_NUM=$(echo "$M_PASS" | cut -d/ -f1)
    M_DEN=$(echo "$M_PASS" | cut -d/ -f2)
    # Full credit if all pass; partial proportional otherwise (need >=12/14 for 0.20)
    M_PCT=$(awk -v n="$M_NUM" -v d="$M_DEN" 'BEGIN { printf "%.4f", (n+0.0)/(d+0.0) }')
    if awk -v p="$M_PCT" 'BEGIN { exit !(p >= 0.99) }'; then
        add_reward 0.20
        echo "  +0.20 (all $M_DEN cases)"
    elif awk -v p="$M_PCT" 'BEGIN { exit !(p >= 0.85) }'; then
        add_reward 0.12
        echo "  +0.12 (most: $M_NUM/$M_DEN)"
    elif awk -v p="$M_PCT" 'BEGIN { exit !(p >= 0.65) }'; then
        add_reward 0.05
        echo "  +0.05 (partial: $M_NUM/$M_DEN)"
    fi
fi

# ===================================================================
# CHECK 2 (0.10): COMMON_ZONE_RULES + per-language rules exist
# ===================================================================
echo "--- Check 2: zone rules constants (0.10) ---"

RULES_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import COMMON_ZONE_RULES, Zone, ZoneRule

    score = 0
    notes = []

    if isinstance(COMMON_ZONE_RULES, list) and len(COMMON_ZONE_RULES) >= 3:
        zones_in_common = {r.zone for r in COMMON_ZONE_RULES}
        if {Zone.VENDOR, Zone.GENERATED, Zone.TEST} <= zones_in_common:
            score += 1
        else:
            notes.append(f'common_zones={zones_in_common}')
    else:
        notes.append('common_rules_short')

    py_ok = False
    try:
        from desloppify.lang.python import PY_ZONE_RULES
        if isinstance(PY_ZONE_RULES, list) and len(PY_ZONE_RULES) > len(COMMON_ZONE_RULES):
            first = PY_ZONE_RULES[0]
            if isinstance(first, ZoneRule):
                py_ok = True
        if py_ok:
            score += 1
        else:
            notes.append('py_rules_bad')
    except ImportError:
        notes.append('py_rules_missing')

    ts_ok = False
    try:
        from desloppify.lang.typescript import TS_ZONE_RULES
        if isinstance(TS_ZONE_RULES, list) and len(TS_ZONE_RULES) > len(COMMON_ZONE_RULES):
            first = TS_ZONE_RULES[0]
            if isinstance(first, ZoneRule):
                ts_patterns = []
                for r in TS_ZONE_RULES[:len(TS_ZONE_RULES) - len(COMMON_ZONE_RULES)]:
                    ts_patterns.extend(r.patterns)
                if any('.test.' in p or '.spec.' in p or '__tests__' in p for p in ts_patterns):
                    ts_ok = True
        if ts_ok:
            score += 1
        else:
            notes.append('ts_rules_bad')
    except ImportError:
        notes.append('ts_rules_missing')

    print(f'SCORE:{score}/3 {notes}')
except Exception as e:
    print(f'ERROR:{type(e).__name__}:{e}')
PYEOF
)
echo "  $RULES_RESULT"
case "$RULES_RESULT" in
    SCORE:3/3*) add_reward 0.10; echo "  +0.10" ;;
    SCORE:2/3*) add_reward 0.06; echo "  +0.06" ;;
    SCORE:1/3*) add_reward 0.03; echo "  +0.03" ;;
esac

# ===================================================================
# CHECK 3 (0.15): FileZoneMap classification correctness via real files
# Builds an actual on-disk synthetic project so any reasonable ctor works.
# ===================================================================
echo "--- Check 3: FileZoneMap classification on real fs (0.15) ---"

ZM_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, Zone, COMMON_ZONE_RULES, classify_file

    # First test classify_file directly — implementation-agnostic
    cases = [
        ('src/main.py',                Zone.PRODUCTION),
        ('project/tests/test_main.py', Zone.TEST),
        ('lib/vendor/lib.py',          Zone.VENDOR),
        ('build/generated/schema.py',  Zone.GENERATED),
    ]
    cf_results = []
    for path, exp in cases:
        try:
            got = classify_file(path, COMMON_ZONE_RULES)
            cf_results.append((path, exp, got, got == exp))
        except Exception as e:
            cf_results.append((path, exp, f'ERR:{e}', False))

    cf_pass = sum(1 for _, _, _, ok in cf_results if ok)

    # Now build an actual file tree and try FileZoneMap with multiple ctors
    files = [
        'src/main.py',
        'src/utils.py',
        'project/tests/test_main.py',
        'project/tests/test_utils.py',
        'lib/vendor/lib.py',
        'build/generated/schema.py',
    ]
    tmp = tempfile.mkdtemp()
    abs_paths = []
    for fp in files:
        full = os.path.join(tmp, fp)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text('# stub\n')
        abs_paths.append(full)

    def make_zm():
        attempts = [
            lambda: FileZoneMap(files, COMMON_ZONE_RULES),
            lambda: FileZoneMap(abs_paths, COMMON_ZONE_RULES),
            lambda: FileZoneMap(files=files, rules=COMMON_ZONE_RULES),
            lambda: FileZoneMap(rules=COMMON_ZONE_RULES, files=files),
        ]
        # Path-based ctor
        def path_ctor():
            ff = lambda p: abs_paths
            return FileZoneMap(COMMON_ZONE_RULES, ff, Path(tmp))
        attempts.append(path_ctor)
        last_err = None
        for a in attempts:
            try:
                zm = a()
                # Sanity check
                _ = zm.get('src/main.py')
                return zm
            except Exception as e:
                last_err = e
                continue
        raise last_err or RuntimeError('all ctors failed')

    expected_classifications = {
        'src/main.py': Zone.PRODUCTION,
        'project/tests/test_main.py': Zone.TEST,
        'lib/vendor/lib.py': Zone.VENDOR,
        'build/generated/schema.py': Zone.GENERATED,
    }

    zm_pass = 0
    zm_total = len(expected_classifications)
    try:
        zm = make_zm()
        for path, exp in expected_classifications.items():
            got = zm.get(path)
            if got == exp:
                zm_pass += 1
        # production_count and counts
        try:
            pc = zm.production_count()
            if isinstance(pc, int) and pc >= 1:
                zm_pass += 0.5
        except Exception:
            pass
        try:
            ct = zm.counts()
            if isinstance(ct, dict) and len(ct) >= 2:
                zm_pass += 0.5
        except Exception:
            pass
    except Exception as e:
        print(f'  zm_ctor_failed:{type(e).__name__}:{e}')

    # cf_total = 4, zm_total = 5 (4 classifications + production_count + counts as 1)
    print(f'CF:{cf_pass}/{len(cases)} ZM:{zm_pass}/{zm_total + 1}')
except Exception as e:
    print(f'ERROR:{type(e).__name__}:{e}')
PYEOF
)
echo "  $ZM_RESULT"
CF_LINE=$(echo "$ZM_RESULT" | grep -oE 'CF:[0-9]+/[0-9]+ ZM:[0-9.]+/[0-9]+')
if [ -n "$CF_LINE" ]; then
    CF_NUM=$(echo "$CF_LINE" | sed 's/CF:\([0-9]*\)\/.*/\1/')
    ZM_NUM=$(echo "$CF_LINE" | sed 's/.*ZM:\([0-9.]*\)\/.*/\1/')
    # cf_total=4, zm_total=5, max combined ≈ 9
    COMBINED=$(awk -v c="$CF_NUM" -v z="$ZM_NUM" 'BEGIN { printf "%.4f", (c+z) / 9.0 }')
    Z_REWARD=$(awk -v p="$COMBINED" 'BEGIN { v = p * 0.15; if (v > 0.15) v = 0.15; printf "%.4f", v }')
    add_reward "$Z_REWARD"
    echo "  +$Z_REWARD (combined $COMBINED)"
fi

# ===================================================================
# CHECK 4 (0.10): adjust_potential + should_skip_finding helpers
# ===================================================================
echo "--- Check 4: helper functions adjust_potential / should_skip_finding (0.10) ---"

HELPERS_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')

try:
    from desloppify.zones import (
        adjust_potential, FileZoneMap, Zone, COMMON_ZONE_RULES,
        ZONE_POLICIES,
    )

    score = 0
    notes = []

    # adjust_potential(None, files, total) → returns total (no-op)
    try:
        v = adjust_potential(None, ['a.py', 'b.py'], 10)
        if v == 10:
            score += 1
        else:
            notes.append(f'noop_returned_{v}')
    except TypeError:
        # Some impls take 2 args (zone_map, files); try
        try:
            v = adjust_potential(None, ['a.py', 'b.py'])
            if v == 2:
                score += 1
            else:
                notes.append(f'noop2_returned_{v}')
        except Exception as e:
            notes.append(f'noop_err:{e}')

    # Build a real zone map then check production count adjustment
    import tempfile, os
    from pathlib import Path
    tmp = tempfile.mkdtemp()
    files_list = ['src/a.py', 'src/b.py', 'tests/test_a.py', 'vendor/lib.py']
    for fp in files_list:
        full = os.path.join(tmp, fp)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text('# stub\n')

    zm = None
    for attempt in [
        lambda: FileZoneMap(files_list, COMMON_ZONE_RULES),
        lambda: FileZoneMap(COMMON_ZONE_RULES, lambda p: [os.path.join(tmp, f) for f in files_list], Path(tmp)),
    ]:
        try:
            zm = attempt()
            break
        except Exception:
            continue

    if zm is not None:
        # Production: src/a.py, src/b.py → 2 prod files
        try:
            adjusted = adjust_potential(zm, files_list, len(files_list))
        except TypeError:
            adjusted = adjust_potential(zm, files_list)
        # Should subtract test+vendor → 2 production files
        if adjusted == 2:
            score += 1
        else:
            notes.append(f'adjusted_got_{adjusted}_expected_2')
    else:
        notes.append('no_zm')

    # should_skip_finding present and behaves
    try:
        from desloppify.zones import should_skip_finding
        if zm is not None:
            # vendor file with a coupling-ish detector should skip
            zone = zm.get('vendor/lib.py')
            policy = ZONE_POLICIES.get(zone)
            if policy and policy.skip_detectors:
                det = next(iter(policy.skip_detectors))
                if should_skip_finding(zm, 'vendor/lib.py', det) is True:
                    score += 1
                else:
                    notes.append('should_skip_false')
                # production should NOT skip
                if should_skip_finding(zm, 'src/a.py', det) is False:
                    score += 1
                else:
                    notes.append('prod_skipped')
            else:
                notes.append('no_skip_detectors_in_policy')
    except ImportError:
        notes.append('should_skip_missing')

    print(f'SCORE:{score}/4 {notes}')
except Exception as e:
    print(f'ERROR:{type(e).__name__}:{e}')
PYEOF
)
echo "  $HELPERS_RESULT"
H_NUM=$(echo "$HELPERS_RESULT" | grep -oE 'SCORE:[0-9]+/4' | sed 's/SCORE:\([0-9]*\)\/4/\1/')
if [ -n "$H_NUM" ]; then
    H_REWARD=$(awk -v n="$H_NUM" 'BEGIN { v = n * 0.025; printf "%.4f", v }')
    add_reward "$H_REWARD"
    echo "  +$H_REWARD ($H_NUM/4)"
fi

# ===================================================================
# CHECK 5 (0.15): User override mechanism
# ===================================================================
echo "--- Check 5: zone overrides (0.15) ---"

OVR_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')

try:
    from desloppify.zones import FileZoneMap, Zone, COMMON_ZONE_RULES

    files_list = ['src/main.py', 'tests/test_main.py']
    tmp = tempfile.mkdtemp()
    abs_paths = []
    for fp in files_list:
        full = os.path.join(tmp, fp)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text('# stub\n')
        abs_paths.append(full)

    overrides = {'src/main.py': 'test'}  # force production → test

    zm = None
    for attempt in [
        lambda: FileZoneMap(files_list, COMMON_ZONE_RULES, overrides=overrides),
        lambda: FileZoneMap(files=files_list, rules=COMMON_ZONE_RULES, overrides=overrides),
        lambda: FileZoneMap(COMMON_ZONE_RULES, lambda p: abs_paths, Path(tmp), overrides=overrides),
    ]:
        try:
            zm = attempt()
            break
        except Exception:
            continue

    if zm is None:
        print('NO_OVERRIDE_SUPPORT')
        sys.exit(0)

    score = 0
    # Override applied to a production file → now TEST
    if zm.get('src/main.py') == Zone.TEST:
        score += 1
    # Non-overridden file still classifies normally
    if zm.get('tests/test_main.py') == Zone.TEST:
        score += 1
    # Counts reflect overrides
    try:
        ct = zm.counts()
        # Both files are now TEST
        test_count = ct.get('test') if isinstance(ct, dict) else None
        if test_count is None:
            test_count = ct.get(Zone.TEST) if isinstance(ct, dict) else None
        if test_count == 2:
            score += 1
    except Exception:
        pass

    print(f'SCORE:{score}/3')
except Exception as e:
    print(f'ERROR:{type(e).__name__}:{e}')
PYEOF
)
echo "  $OVR_RESULT"
case "$OVR_RESULT" in
    *SCORE:3/3*) add_reward 0.15; echo "  +0.15" ;;
    *SCORE:2/3*) add_reward 0.10; echo "  +0.10" ;;
    *SCORE:1/3*) add_reward 0.04; echo "  +0.04" ;;
    *NO_OVERRIDE_SUPPORT*) echo "  +0.00 (no override ctor)" ;;
esac

# ===================================================================
# CHECK 6 (0.20): END-TO-END — run a real scan and verify potentials
# adjustment + zone-stamped or filtered findings on a synthetic project.
# This is the big behavioral discriminator.
# ===================================================================
echo "--- Check 6: e2e scan with zone-adjusted potentials (0.20) ---"

SCAN_TMP=$(mktemp -d)

mkdir -p "$SCAN_TMP/src" "$SCAN_TMP/tests" "$SCAN_TMP/vendor" "$SCAN_TMP/generated"

# Build a tiny synthetic project where production code is healthy
# but test/vendor/generated files contain "issues" the detectors might
# normally flag. If zones work right, those don't drag potentials.
cat > "$SCAN_TMP/src/main.py" <<'PY'
"""Main module."""
from src.utils import helper

def run():
    return helper(1) + helper(2)

if __name__ == "__main__":
    run()
PY

cat > "$SCAN_TMP/src/utils.py" <<'PY'
"""Utilities used by main."""

def helper(x):
    return x * 2

def other_helper(x):
    return helper(x) + 1
PY

cat > "$SCAN_TMP/tests/test_main.py" <<'PY'
"""Tests — should be classified as TEST zone."""
def test_orphan_function_a():
    pass

def test_orphan_function_b():
    pass

# duplicate-ish
def test_orphan_function_c():
    pass
PY

cat > "$SCAN_TMP/vendor/lib.py" <<'PY'
"""Vendored — should be VENDOR zone."""
def vendored_thing(x):
    return x

def another_vendored(x):
    return x
PY

cat > "$SCAN_TMP/generated/schema.py" <<'PY'
"""Generated — should be GENERATED zone."""
def gen_a(): pass
def gen_b(): pass
def gen_c(): pass
PY

E2E_RESULT=$(cd "$WORKSPACE" && python3 - "$SCAN_TMP" <<'PYEOF' 2>&1
import sys, os
sys.path.insert(0, '.')

scan_path = sys.argv[1]

score = 0
notes = []

# Try to invoke scan via the project's lang config or scan command
try:
    from pathlib import Path
    from desloppify.lang.python import _LANG as PY_LANG  # may not exist, try fallbacks
except ImportError:
    PY_LANG = None

# Find python lang config in a robust way
py_lang = None
try:
    from desloppify.lang import LANGS as _LANGS
    if isinstance(_LANGS, dict):
        py_lang = _LANGS.get('python') or _LANGS.get('py')
except Exception:
    pass

if py_lang is None:
    try:
        from desloppify.lang import get_lang
        py_lang = get_lang('python')
    except Exception:
        pass

if py_lang is None:
    try:
        import desloppify.lang.python as pymod
        # Often the LangConfig is registered on import; grab any module-level instance
        from desloppify.lang.base import LangConfig as _LC
        for attr in dir(pymod):
            obj = getattr(pymod, attr)
            if isinstance(obj, _LC):
                py_lang = obj
                break
    except Exception as e:
        notes.append(f'no_lang:{e}')

if py_lang is None:
    print(f'NO_PY_LANG {notes}')
    sys.exit(0)

# Ensure zone_rules attached
zone_rules = getattr(py_lang, 'zone_rules', None)
if not zone_rules:
    notes.append('no_zone_rules_on_lang')

# Prefer the high-level scan entrypoint if present
findings = None
potentials = None
try:
    from desloppify.scan_core import generate_findings
    findings, potentials = generate_findings(Path(scan_path), include_slow=False, lang=py_lang)
except Exception:
    try:
        from desloppify.scan import generate_findings as gf
        findings, potentials = gf(Path(scan_path), include_slow=False, lang=py_lang)
    except Exception:
        # Try _generate_findings_from_lang
        try:
            from desloppify.scan import _generate_findings_from_lang
            findings, potentials = _generate_findings_from_lang(Path(scan_path), py_lang, include_slow=False)
        except Exception as e:
            try:
                from desloppify.scan_core import _generate_findings_from_lang
                findings, potentials = _generate_findings_from_lang(Path(scan_path), py_lang, include_slow=False)
            except Exception as e2:
                notes.append(f'no_scan_entry:{e2}')

if potentials is None:
    print(f'NO_POTENTIALS {notes}')
    sys.exit(0)

# Now test: production count is 2 (src/main.py + src/utils.py).
# If zones work, file-based potentials (unused, smells, structural) should be ≤ 2.
# Total files = 5 (2 prod + 1 test + 1 vendor + 1 generated).

prod_files = 2
total_files = 5

# Check: at least one file-based potential should be adjusted to <= prod_files
file_based_keys = ['unused', 'smells', 'structural']
adjusted_keys = []
for k in file_based_keys:
    if k in potentials:
        v = potentials[k]
        if isinstance(v, int) and v <= prod_files:
            adjusted_keys.append(k)

if len(adjusted_keys) >= 2:
    score += 2  # strong evidence potentials are adjusted
elif len(adjusted_keys) >= 1:
    score += 1

# Check: at least one potential is NOT inflated to 5 (the raw total)
inflated = [k for k in file_based_keys if potentials.get(k) == total_files]
if not inflated:
    score += 1
else:
    notes.append(f'inflated:{inflated}')

# Check: findings include zone metadata or are filtered
zone_stamped = sum(1 for f in (findings or []) if f.get('zone'))
prod_findings = sum(1 for f in (findings or []) if not f.get('zone'))
# At least some findings should be production (not zone-stamped) since src has files
if findings is not None:
    if prod_findings >= 0:  # always true; just ensure scan worked
        score += 1
    # Bonus: zone metadata appears on at least one finding
    if zone_stamped >= 1:
        score += 1

print(f'SCORE:{score}/5 potentials={dict(potentials)} prod_findings={prod_findings if findings is not None else "?"} zone_stamped={zone_stamped} {notes}')
PYEOF
)
echo "$E2E_RESULT" | head -3 | sed 's/^/  /'
E2E_NUM=$(echo "$E2E_RESULT" | grep -oE 'SCORE:[0-9]+/5' | head -1 | sed 's/SCORE:\([0-9]*\)\/5/\1/')
if [ -n "$E2E_NUM" ]; then
    E2E_REWARD=$(awk -v n="$E2E_NUM" 'BEGIN { v = n * 0.04; if (v > 0.20) v = 0.20; printf "%.4f", v }')
    add_reward "$E2E_REWARD"
    echo "  +$E2E_REWARD ($E2E_NUM/5)"
fi

rm -rf "$SCAN_TMP"

# ===================================================================
# CHECK 7 (0.05): P2P regression guard — base imports & FileZoneMap still
# usable after changes; existing scoring module still imports.
# ===================================================================
echo "--- Check 7: P2P regression / smoke (0.05) ---"

REGR_RESULT=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
try:
    import desloppify
    score += 1
except Exception as e:
    print(f'  pkg_import_fail:{e}')

try:
    from desloppify.zones import (
        Zone, ZoneRule, ZonePolicy, FileZoneMap,
        ZONE_POLICIES, COMMON_ZONE_RULES, classify_file,
    )
    score += 1
except Exception as e:
    print(f'  zones_import_fail:{e}')

try:
    from desloppify import scoring
    score += 1
except Exception as e:
    print(f'  scoring_import_fail:{e}')

try:
    from desloppify.lang import python as pymod
    from desloppify.lang import typescript as tsmod
    score += 1
except Exception as e:
    print(f'  lang_import_fail:{e}')

print(f'SCORE:{score}/4')
PYEOF
)
echo "  $REGR_RESULT" | head -5 | sed 's/^/  /'
R_NUM=$(echo "$REGR_RESULT" | grep -oE 'SCORE:[0-9]+/4' | sed 's/SCORE:\([0-9]*\)\/4/\1/')
if [ -n "$R_NUM" ]; then
    R_REWARD=$(awk -v n="$R_NUM" 'BEGIN { v = n * 0.0125; printf "%.4f", v }')
    add_reward "$R_REWARD"
    echo "  +$R_REWARD ($R_NUM/4)"
fi

# ===================================================================
# CHECK 8 (0.05): Existing test suite (if any) still passes for zones
# ===================================================================
echo "--- Check 8: existing pytest for zones (0.05) ---"

if command -v pytest >/dev/null 2>&1; then
    PYTEST_OUT=$(cd "$WORKSPACE" && timeout 60 pytest tests/ -k "zone" -x -q --no-header 2>&1 | tail -20)
    echo "$PYTEST_OUT" | tail -3 | sed 's/^/  /'
    if echo "$PYTEST_OUT" | grep -qE "passed" && ! echo "$PYTEST_OUT" | grep -qE "failed|error"; then
        add_reward 0.05
        echo "  +0.05"
    elif echo "$PYTEST_OUT" | grep -qE "no tests ran|deselected"; then
        # No zone-specific tests is fine — give half credit if nothing fails
        add_reward 0.025
        echo "  +0.025 (no zone tests)"
    fi
else
    echo "  pytest unavailable, skipping"
fi

# ===================================================================
# Final
# ===================================================================
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$LOG_DIR/reward.txt"
exit 0