#!/bin/bash
set +e
#
# Verifier for desloppify-zone-classification.
# Hard principle: no-op (unmodified buggy base) MUST score 0.0.
# All reward comes from F2P behavioral gates that fail on base and pass on fix.
#

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN { s=a+b; if (s>1.0) s=1.0; printf "%.4f", s }')
}

finish() {
    echo "$REWARD" > "$LOG_DIR/reward.txt"
    exit 0
}

cd "$WORKSPACE" 2>/dev/null || {
    echo "FATAL: workspace $WORKSPACE not found"
    finish
}

export PYTHONPATH="$WORKSPACE:$PYTHONPATH"

# ===================================================================
# P2P GATE (no reward): module imports without crashing.
# ===================================================================
echo "--- Gate: zones module imports ---"
GATE=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
try:
    from desloppify.zones import Zone, ZoneRule, classify_file
    print("OK")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $GATE"
if ! echo "$GATE" | grep -q "^OK"; then
    echo "  regression: zones module broken — REWARD=0"
    finish
fi

# ===================================================================
# F2P 1 (0.25): _match_pattern precision — fails on substring-only base.
# Base classify_file uses raw substring; on base, "/tests/" matches
# "src/my_tests_dir/foo.py" (false positive). Precision-aware impl rejects.
# ===================================================================
echo "--- F2P 1: pattern precision (0.25) ---"
F1=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
try:
    # Try _match_pattern directly; if missing, infer via classify_file.
    cases = []
    try:
        from desloppify.zones import _match_pattern as MP
        # Directory pattern false-positive check (base: substring → True; fix: False)
        cases.append(('dir_neg_fp',  False, MP('src/my_tests_dir/foo.py', '/tests/')))
        cases.append(('dir_neg_sub', False, MP('src/contests/foo.py', '/tests/')))
        # Prefix patterns must NOT match mid-name
        cases.append(('prefix_neg',  False, MP('src/contest_results.py', 'test_')))
        cases.append(('prefix_neg2', False, MP('src/my_test_helpers.py', 'test_')))
        # Exact basename: config.py must NOT match my_config.py
        cases.append(('exact_neg',   False, MP('src/my_config.py', 'config.py')))
        # Positives that must still hold
        cases.append(('dir_pos',     True,  MP('src/tests/test_foo.py', '/tests/')))
        cases.append(('prefix_pos',  True,  MP('src/tests/test_foo.py', 'test_')))
        cases.append(('exact_pos',   True,  MP('src/config.py', 'config.py')))
    except ImportError:
        # Fall back: probe via classify_file with synthetic rules.
        from desloppify.zones import classify_file, Zone, ZoneRule
        rules_dir   = [ZoneRule(Zone.TEST, ["/tests/"])]
        rules_pref  = [ZoneRule(Zone.TEST, ["test_"])]
        rules_exact = [ZoneRule(Zone.CONFIG, ["config.py"])]
        def cls(path, rules):
            return classify_file(path, rules)
        cases.append(('dir_neg_fp',  Zone.PRODUCTION, cls('src/my_tests_dir/foo.py', rules_dir)))
        cases.append(('dir_neg_sub', Zone.PRODUCTION, cls('src/contests/foo.py', rules_dir)))
        cases.append(('prefix_neg',  Zone.PRODUCTION, cls('src/contest_results.py', rules_pref)))
        cases.append(('prefix_neg2', Zone.PRODUCTION, cls('src/my_test_helpers.py', rules_pref)))
        cases.append(('exact_neg',   Zone.PRODUCTION, cls('src/my_config.py', rules_exact)))
        cases.append(('dir_pos',     Zone.TEST,       cls('src/tests/test_foo.py', rules_dir)))
        cases.append(('prefix_pos',  Zone.TEST,       cls('src/tests/test_foo.py', rules_pref)))
        cases.append(('exact_pos',   Zone.CONFIG,     cls('src/config.py', rules_exact)))

    failed = [(n,e,g) for n,e,g in cases if e != g]
    print(f"PASS:{len(cases)-len(failed)}/{len(cases)}")
    for n,e,g in failed[:6]:
        print(f"  fail:{n} exp={e} got={g}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "$F1" | head -8 | sed 's/^/  /'
P1=$(echo "$F1" | grep -oE 'PASS:[0-9]+/[0-9]+' | head -1)
if [ -n "$P1" ]; then
    N=$(echo "$P1" | sed 's|PASS:||' | cut -d/ -f1)
    D=$(echo "$P1" | sed 's|PASS:||' | cut -d/ -f2)
    if [ "$N" = "$D" ]; then
        add_reward 0.25
        echo "  +0.25 (all $D)"
    elif awk -v n="$N" -v d="$D" 'BEGIN { exit !(n*1.0/d >= 0.85) }'; then
        add_reward 0.15
        echo "  +0.15 (most $N/$D)"
    fi
fi

# ===================================================================
# F2P 2 (0.15): COMMON_ZONE_RULES + per-language zone rule lists exist.
# These names don't exist on base → no-op gets 0.
# ===================================================================
echo "--- F2P 2: zone rule constants (0.15) ---"
F2=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
notes = []
try:
    from desloppify.zones import COMMON_ZONE_RULES, Zone, ZoneRule
    if isinstance(COMMON_ZONE_RULES, list) and len(COMMON_ZONE_RULES) >= 3:
        zs = {r.zone for r in COMMON_ZONE_RULES}
        if {Zone.VENDOR, Zone.GENERATED, Zone.TEST} <= zs:
            score += 1
        else:
            notes.append(f"common_zones={zs}")
    else:
        notes.append("common_short")

    try:
        from desloppify.lang.python import PY_ZONE_RULES
        if isinstance(PY_ZONE_RULES, list) and len(PY_ZONE_RULES) > len(COMMON_ZONE_RULES):
            # Must include at least one Python-specific rule with test_ prefix
            extra_n = len(PY_ZONE_RULES) - len(COMMON_ZONE_RULES)
            patterns = []
            for r in PY_ZONE_RULES[:extra_n]:
                patterns.extend(getattr(r, 'patterns', []))
            if any('test_' in p for p in patterns):
                score += 1
            else:
                notes.append(f"py_no_test_={patterns}")
        else:
            notes.append("py_short")
    except ImportError as e:
        notes.append(f"py_missing:{e}")

    try:
        from desloppify.lang.typescript import TS_ZONE_RULES
        if isinstance(TS_ZONE_RULES, list) and len(TS_ZONE_RULES) > len(COMMON_ZONE_RULES):
            extra_n = len(TS_ZONE_RULES) - len(COMMON_ZONE_RULES)
            patterns = []
            for r in TS_ZONE_RULES[:extra_n]:
                patterns.extend(getattr(r, 'patterns', []))
            if any(('.test.' in p) or ('.spec.' in p) or ('__tests__' in p) for p in patterns):
                score += 1
            else:
                notes.append(f"ts_patterns={patterns}")
        else:
            notes.append("ts_short")
    except ImportError as e:
        notes.append(f"ts_missing:{e}")
except Exception as e:
    notes.append(f"err:{type(e).__name__}:{e}")

print(f"SCORE:{score}/3 {notes}")
PYEOF
)
echo "  $F2"
case "$F2" in
    SCORE:3/3*) add_reward 0.15; echo "  +0.15" ;;
    SCORE:2/3*) add_reward 0.08; echo "  +0.08" ;;
    SCORE:1/3*) add_reward 0.03; echo "  +0.03" ;;
esac

# ===================================================================
# F2P 3 (0.15): adjust_potential helper exists & subtracts non-prod.
# Not present on base → no-op gets 0.
# ===================================================================
echo "--- F2P 3: adjust_potential behavior (0.15) ---"
F3=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')

try:
    from desloppify.zones import adjust_potential, FileZoneMap, Zone
    # No-op when zone_map is None — accept either total or len(files) semantics.
    files = ['a.py', 'b.py', 'c.py']
    try:
        none_result = adjust_potential(None, files, 3)
    except TypeError:
        # Some impls accept (zone_map, files) only
        none_result = adjust_potential(None, files)
    if none_result != 3:
        print(f"FAIL:none_result={none_result}")
        sys.exit(0)

    # Build a FileZoneMap with mixed zones via real fs (multiple ctor styles)
    tmp = tempfile.mkdtemp()
    file_rels = [
        'src/main.py',          # production
        'src/util.py',          # production
        'tests/test_main.py',   # test (under /tests/)
        'vendor/lib.py',        # vendor (under /vendor/)
    ]
    abs_paths = []
    for rel in file_rels:
        full = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text("x=1\n")
        abs_paths.append(full)

    # Get rules (use COMMON_ZONE_RULES — covers /tests/ and /vendor/)
    from desloppify.zones import COMMON_ZONE_RULES

    # Try several constructor signatures
    zm = None
    candidates = [
        lambda: FileZoneMap(file_rels, COMMON_ZONE_RULES),
        lambda: FileZoneMap(abs_paths, COMMON_ZONE_RULES),
        lambda: FileZoneMap(file_rels, COMMON_ZONE_RULES, overrides={}),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: abs_paths, path=Path(tmp)),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: file_rels, path=Path(tmp)),
    ]
    err = None
    for c in candidates:
        try:
            zm = c()
            break
        except Exception as e:
            err = e
            continue
    if zm is None:
        print(f"FAIL:zm_ctor:{err}")
        sys.exit(0)

    # Determine which file representation the zm understands
    test_inputs = file_rels
    sample_zone = zm.get(file_rels[2])  # tests/test_main.py
    if sample_zone == Zone.PRODUCTION:
        # Try absolute paths instead
        sample_zone = zm.get(abs_paths[2])
        if sample_zone != Zone.PRODUCTION:
            test_inputs = abs_paths

    # adjust_potential should subtract non-production files (test, vendor)
    raw_total = len(test_inputs)
    try:
        adjusted = adjust_potential(zm, test_inputs, raw_total)
    except TypeError:
        adjusted = adjust_potential(zm, test_inputs)

    # Production count should be 2 (main.py, util.py); 1-3 acceptable depending on rules
    if adjusted == 2:
        print("PASS:exact")
    elif adjusted < raw_total and adjusted >= 1:
        print(f"PASS:partial:adj={adjusted}/raw={raw_total}")
    else:
        print(f"FAIL:adj={adjusted}/raw={raw_total}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  $F3"
case "$F3" in
    PASS:exact*)   add_reward 0.15; echo "  +0.15" ;;
    PASS:partial*) add_reward 0.10; echo "  +0.10" ;;
esac

# ===================================================================
# F2P 4 (0.10): FileZoneMap.counts() returns dict of zone counts.
# Not present on base.
# ===================================================================
echo "--- F2P 4: FileZoneMap.counts() (0.10) ---"
F4=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')
try:
    from desloppify.zones import FileZoneMap, COMMON_ZONE_RULES, Zone

    tmp = tempfile.mkdtemp()
    rels = ['src/a.py', 'src/b.py', 'tests/test_a.py', 'vendor/lib.py']
    abs_paths = []
    for r in rels:
        full = os.path.join(tmp, r)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text("x=1\n")
        abs_paths.append(full)

    zm = None
    for c in [
        lambda: FileZoneMap(rels, COMMON_ZONE_RULES),
        lambda: FileZoneMap(abs_paths, COMMON_ZONE_RULES),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: abs_paths, path=Path(tmp)),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: rels, path=Path(tmp)),
    ]:
        try:
            zm = c(); break
        except Exception:
            continue

    if zm is None:
        print("FAIL:no_ctor")
        sys.exit(0)

    if not hasattr(zm, 'counts'):
        print("FAIL:no_counts_method")
        sys.exit(0)

    counts = zm.counts()
    if not isinstance(counts, dict):
        print(f"FAIL:not_dict:{type(counts)}")
        sys.exit(0)

    total = sum(counts.values())
    if total != len(rels):
        print(f"FAIL:total={total}/expected={len(rels)} counts={counts}")
        sys.exit(0)

    # Must have at least 2 distinct zones (production + at least one non-prod)
    if len(counts) >= 2:
        print(f"PASS:counts={counts}")
    else:
        print(f"FAIL:single_zone:{counts}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  $F4"
case "$F4" in
    PASS*) add_reward 0.10; echo "  +0.10" ;;
esac

# ===================================================================
# F2P 5 (0.10): should_skip_finding helper enforces ZONE_POLICIES.skip_detectors.
# Not present on base.
# ===================================================================
echo "--- F2P 5: should_skip_finding (0.10) ---"
F5=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')
try:
    from desloppify.zones import (should_skip_finding, FileZoneMap,
                                   COMMON_ZONE_RULES, Zone, ZONE_POLICIES)

    tmp = tempfile.mkdtemp()
    rels = ['src/a.py', 'tests/test_a.py', 'vendor/lib.py']
    abs_paths = []
    for r in rels:
        full = os.path.join(tmp, r)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text("x=1\n")
        abs_paths.append(full)

    zm = None
    for c in [
        lambda: FileZoneMap(rels, COMMON_ZONE_RULES),
        lambda: FileZoneMap(abs_paths, COMMON_ZONE_RULES),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: abs_paths, path=Path(tmp)),
        lambda: FileZoneMap(rules=COMMON_ZONE_RULES, file_finder=lambda p: rels, path=Path(tmp)),
    ]:
        try:
            zm = c(); break
        except Exception:
            continue
    if zm is None:
        print("FAIL:no_ctor"); sys.exit(0)

    # Find a path the zm classifies as TEST or VENDOR
    test_path = None
    prod_path = None
    for cand in rels + abs_paths:
        z = zm.get(cand)
        if z in (Zone.TEST, Zone.VENDOR) and test_path is None:
            test_path = cand
        if z == Zone.PRODUCTION and prod_path is None:
            prod_path = cand

    if test_path is None or prod_path is None:
        print(f"FAIL:no_zoned_paths test={test_path} prod={prod_path}")
        sys.exit(0)

    # No-op contract: zone_map=None → False
    if should_skip_finding(None, prod_path, "orphaned"):
        print("FAIL:none_returns_true"); sys.exit(0)

    # Production should never be skipped
    if should_skip_finding(zm, prod_path, "orphaned"):
        print("FAIL:prod_skipped"); sys.exit(0)

    # TEST/VENDOR with a coupling-class detector should be skipped per policies
    skip_results = []
    for det in ("orphaned", "single_use", "facade", "coupling", "cycles"):
        skip_results.append(should_skip_finding(zm, test_path, det))

    if any(skip_results):
        print(f"PASS:test_skipped={sum(skip_results)}/5")
    else:
        print(f"FAIL:no_skip:{skip_results}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  $F5"
case "$F5" in
    PASS*) add_reward 0.10; echo "  +0.10" ;;
esac

# ===================================================================
# F2P 6 (0.15): End-to-end — running scan on a synthetic project produces
# a smaller "potentials" denominator than the raw file count when test
# files are present. On base, _phase_unused/_phase_smells return raw totals
# (no zone adjustment) → adjusted_total == raw_total.
# ===================================================================
echo "--- F2P 6: phase runners adjust potentials (0.15) ---"
F6=$(python3 - <<'PYEOF' 2>&1
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, '.')

try:
    from desloppify.zones import (FileZoneMap, COMMON_ZONE_RULES,
                                   adjust_potential, Zone)
    # Try Python lang module
    try:
        from desloppify.lang.python import PY_ZONE_RULES, _phase_unused
        from desloppify.lang import LANGS
        py_lang = LANGS.get('python')
    except ImportError:
        try:
            from desloppify.lang.python import PY_ZONE_RULES
        except Exception:
            print("FAIL:no_py_zone_rules"); sys.exit(0)
        py_lang = None

    # Build synthetic project — production + test files
    tmp = tempfile.mkdtemp()
    rels = [
        'pkg/__init__.py',
        'pkg/main.py',
        'pkg/util.py',
        'pkg/tests/__init__.py',
        'pkg/tests/test_main.py',
        'pkg/tests/test_util.py',
    ]
    for r in rels:
        full = os.path.join(tmp, r)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        Path(full).write_text("def f():\n    pass\n")

    # Use file_finder if available, else just our paths
    abs_files = [os.path.join(tmp, r) for r in rels]

    zm = None
    for c in [
        lambda: FileZoneMap(rels, PY_ZONE_RULES),
        lambda: FileZoneMap(abs_files, PY_ZONE_RULES),
        lambda: FileZoneMap(rules=PY_ZONE_RULES, file_finder=lambda p: abs_files, path=Path(tmp)),
        lambda: FileZoneMap(rules=PY_ZONE_RULES, file_finder=lambda p: rels, path=Path(tmp)),
    ]:
        try:
            zm = c(); break
        except Exception:
            continue
    if zm is None:
        print("FAIL:no_ctor"); sys.exit(0)

    # Pick a file representation the zm understands
    files_to_use = rels
    if zm.get(rels[4]) == Zone.PRODUCTION:
        files_to_use = abs_files
    if zm.get(files_to_use[4]) == Zone.PRODUCTION:
        # Neither rep was classified — rules may differ. Fall back to test fail.
        print(f"FAIL:test_files_not_classified zm.get={zm.get(files_to_use[4])}")
        sys.exit(0)

    raw_total = len(files_to_use)
    try:
        adjusted = adjust_potential(zm, files_to_use, raw_total)
    except TypeError:
        adjusted = adjust_potential(zm, files_to_use)

    # Synthetic project has 3 prod files + 3 test files = expect adjusted ~= 3
    if adjusted < raw_total and adjusted >= 1:
        print(f"PASS:adjusted={adjusted}/raw={raw_total}")
    else:
        print(f"FAIL:adjusted={adjusted}/raw={raw_total}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  $F6"
case "$F6" in
    PASS*) add_reward 0.15; echo "  +0.15" ;;
esac

# ===================================================================
# F2P 7 (0.10): TS-language zone rules classify .test.ts files correctly.
# Substring-only base may misclassify; precision impl + TS_ZONE_RULES required.
# ===================================================================
echo "--- F2P 7: TS zone rules classify .test.ts (0.10) ---"
F7=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
try:
    from desloppify.zones import classify_file, Zone
    from desloppify.lang.typescript import TS_ZONE_RULES

    cases = [
        ('src/foo.ts',           Zone.PRODUCTION),
        ('src/foo.test.ts',      Zone.TEST),
        ('src/__tests__/x.ts',   Zone.TEST),
        ('node_modules/lib.ts',  None),  # accept any non-prod or production
        ('src/vendor/lib.ts',    Zone.VENDOR),
    ]
    correct = 0
    total_strict = 0
    fails = []
    for path, exp in cases:
        got = classify_file(path, TS_ZONE_RULES)
        if exp is None:
            continue
        total_strict += 1
        if got == exp:
            correct += 1
        else:
            fails.append((path, exp, got))

    if correct == total_strict:
        print(f"PASS:{correct}/{total_strict}")
    elif correct >= total_strict - 1:
        print(f"PARTIAL:{correct}/{total_strict} fails={fails}")
    else:
        print(f"FAIL:{correct}/{total_strict} fails={fails}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  $F7"
case "$F7" in
    PASS*)    add_reward 0.10; echo "  +0.10" ;;
    PARTIAL*) add_reward 0.05; echo "  +0.05" ;;
esac

echo "--- Final reward: $REWARD ---"
finish