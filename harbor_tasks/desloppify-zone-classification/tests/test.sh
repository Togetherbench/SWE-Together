#!/bin/bash
set +e
#
# Verifier for desloppify-zone-classification.
# Discriminates by behavioral correctness across multiple independent slices.
#

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN { s=a+b; if (s>1.0) s=1.0; printf "%.4f", s }')
}

finish() {
    echo "$REWARD" > "$LOG_DIR/reward.txt"
    exit 0
}

cd "$WORKSPACE" 2>/dev/null || { echo "FATAL: workspace missing"; finish; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 not on PATH"; finish
fi

export PYTHONPATH="$WORKSPACE:$PYTHONPATH"

# ===================================================================
# P2P GATE (no reward): zones module imports, basic API present.
# Required for any subsequent test to run.
# ===================================================================
echo "--- P2P: zones module imports ---"
P2P=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
try:
    from desloppify.zones import Zone, ZoneRule, classify_file
    # Sanity: Zone enum has the expected members (existed on base too).
    need = {"PRODUCTION", "TEST", "CONFIG", "GENERATED", "VENDOR", "SCRIPT"}
    have = {m.name for m in Zone}
    assert need <= have, f"missing zones: {need - have}"
    print("OK")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $P2P"
echo "$P2P" | grep -q "^OK" || { echo "  P2P fail — REWARD=0"; finish; }

# ===================================================================
# F2P 1 (0.22): _match_pattern precision — behavioral.
# Tests that pattern matching distinguishes pattern types correctly.
# Base substring-only impl produces false positives on ALL these probes.
# ===================================================================
echo "--- F2P 1: _match_pattern behavioral correctness (0.22) ---"
F1=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
results = []

def probe_via_classify():
    """Fallback: probe behavior via classify_file with synthetic single-rule lists."""
    from desloppify.zones import classify_file, Zone, ZoneRule

    def matches(path, pattern, target_zone):
        rules = [ZoneRule(target_zone, [pattern])]
        return classify_file(path, rules) == target_zone

    cases = [
        # name, expected_match, path, pattern, target_zone
        # Directory negatives — substring-only base FAILS these
        ('dir_subdir_fp',     False, 'src/my_tests_dir/foo.py', '/tests/', Zone.TEST),
        ('dir_contains_fp',   False, 'src/contests/foo.py',     '/tests/', Zone.TEST),
        # Prefix negatives — basename must START with pattern
        ('prefix_mid_fp',     False, 'src/contest_results.py',  'test_',   Zone.TEST),
        ('prefix_internal',   False, 'src/my_test_helpers.py',  'test_',   Zone.TEST),
        # Exact basename negatives
        ('exact_prefix_fp',   False, 'src/my_config.py',        'config.py', Zone.CONFIG),
        ('exact_suffix_fp',   False, 'src/config.python.py',    'config.py', Zone.CONFIG),
        # Positives — must STILL match
        ('dir_pos',           True,  'src/tests/test_foo.py',   '/tests/', Zone.TEST),
        ('dir_root_pos',      True,  'tests/test_foo.py',       '/tests/', Zone.TEST),
        ('prefix_pos',        True,  'src/tests/test_foo.py',   'test_',   Zone.TEST),
        ('exact_pos',         True,  'src/config.py',           'config.py', Zone.CONFIG),
        ('exact_pos_root',    True,  'config.py',               'config.py', Zone.CONFIG),
    ]
    out = []
    for name, expected, path, pattern, zone in cases:
        try:
            got = matches(path, pattern, zone)
        except Exception as e:
            got = f"ERR:{e}"
        out.append((name, expected, got))
    return out

try:
    cases = probe_via_classify()
    failed = [(n,e,g) for n,e,g in cases if e != g]
    print(f"PASS:{len(cases)-len(failed)}/{len(cases)}")
    for n,e,g in failed[:10]:
        print(f"  fail:{n} exp={e} got={g}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "$F1" | head -12 | sed 's/^/  /'
P=$(echo "$F1" | grep -oE 'PASS:[0-9]+/[0-9]+' | head -1)
if [ -n "$P" ]; then
    N=$(echo "$P" | sed 's|PASS:||' | cut -d/ -f1)
    D=$(echo "$P" | sed 's|PASS:||' | cut -d/ -f2)
    if [ "$N" = "$D" ]; then
        add_reward 0.132; echo "  +0.132 (all $D behavioral cases)"
    elif awk -v n="$N" -v d="$D" 'BEGIN{exit !(n*1.0/d >= 0.85)}'; then
        add_reward 0.078; echo "  +0.078 (most $N/$D)"
    elif awk -v n="$N" -v d="$D" 'BEGIN{exit !(n*1.0/d >= 0.70)}'; then
        add_reward 0.036; echo "  +0.036 (some $N/$D)"
    else
        echo "  +0 ($N/$D)"
    fi
fi

# ===================================================================
# F2P 2 (0.15): COMMON_ZONE_RULES + per-language rule lists exist
# with correct structure. These names DO NOT exist on base.
# ===================================================================
echo "--- F2P 2: zone rule constants & per-language lists (0.15) ---"
F2=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
notes = []
common_len = 0

try:
    from desloppify.zones import COMMON_ZONE_RULES, Zone
    if isinstance(COMMON_ZONE_RULES, list) and len(COMMON_ZONE_RULES) >= 3:
        zs = {r.zone for r in COMMON_ZONE_RULES if hasattr(r, 'zone')}
        if {Zone.VENDOR, Zone.GENERATED, Zone.TEST} <= zs:
            score += 1
            common_len = len(COMMON_ZONE_RULES)
        else:
            notes.append(f"common_zones_missing={zs}")
    else:
        notes.append("common_short_or_missing")
except Exception as e:
    notes.append(f"common_err:{type(e).__name__}:{e}")

try:
    from desloppify.lang.python import PY_ZONE_RULES
    from desloppify.zones import COMMON_ZONE_RULES
    if isinstance(PY_ZONE_RULES, list) and len(PY_ZONE_RULES) > len(COMMON_ZONE_RULES):
        # Extract patterns from the language-specific (non-common) prefix
        n_specific = len(PY_ZONE_RULES) - len(COMMON_ZONE_RULES)
        patterns = []
        for r in PY_ZONE_RULES[:n_specific]:
            patterns.extend(getattr(r, 'patterns', []))
        if any('test_' in p for p in patterns):
            score += 1
        else:
            notes.append(f"py_no_test_={patterns}")
    else:
        notes.append("py_short_or_missing")
except Exception as e:
    notes.append(f"py_err:{type(e).__name__}:{e}")

try:
    from desloppify.lang.typescript import TS_ZONE_RULES
    from desloppify.zones import COMMON_ZONE_RULES
    if isinstance(TS_ZONE_RULES, list) and len(TS_ZONE_RULES) > len(COMMON_ZONE_RULES):
        n_specific = len(TS_ZONE_RULES) - len(COMMON_ZONE_RULES)
        patterns = []
        for r in TS_ZONE_RULES[:n_specific]:
            patterns.extend(getattr(r, 'patterns', []))
        if any(('.test.' in p) or ('.spec.' in p) or ('__tests__' in p) for p in patterns):
            score += 1
        else:
            notes.append(f"ts_patterns_wrong={patterns}")
    else:
        notes.append("ts_short_or_missing")
except Exception as e:
    notes.append(f"ts_err:{type(e).__name__}:{e}")

print(f"SCORE:{score}/3 {notes}")
PYEOF
)
echo "  $F2"
S=$(echo "$F2" | grep -oE 'SCORE:[0-9]+/3' | head -1 | sed 's|SCORE:||' | cut -d/ -f1)
case "$S" in
    3) add_reward 0.090; echo "  +0.090" ;;
    2) add_reward 0.060; echo "  +0.060" ;;
    1) add_reward 0.030; echo "  +0.030" ;;
    *) echo "  +0" ;;
esac

# ===================================================================
# F2P 3 (0.108): adjust_potential() exists AND behaves correctly.
# Behavioral: build a real FileZoneMap, call adjust_potential, verify
# the count actually subtracts non-production files.
# ===================================================================
echo "--- F2P 3: adjust_potential behavior (0.18) ---"
F3=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
notes = []
try:
    from desloppify.zones import adjust_potential, Zone, ZoneRule
    # 3a: function exists and accepts (zone_map, files, total)
    score += 1
except ImportError as e:
    notes.append(f"missing:{e}")
    print(f"SCORE:{score}/4 {notes}")
    sys.exit(0)

# 3b: None zone_map → no-op behavior (returns total OR len(files))
try:
    files = ['a.py', 'b.py', 'c.py']
    r = adjust_potential(None, files, 3)
    # Accept either contract: returns total (3) or len(files) (3)
    if r == 3:
        score += 1
    else:
        notes.append(f"none_noop={r}")
except TypeError:
    # Some impls drop the total arg
    try:
        r = adjust_potential(None, files)
        if r == 3:
            score += 1
        else:
            notes.append(f"none_noop2={r}")
    except Exception as e:
        notes.append(f"none_err:{e}")
except Exception as e:
    notes.append(f"none_err:{e}")

# 3c+3d: with a real zone_map, non-production files are subtracted
try:
    # Try multiple FileZoneMap constructor signatures (varies across patches)
    from desloppify.zones import FileZoneMap
    files = [
        'src/app.py',           # production
        'src/core.py',          # production
        'tests/test_app.py',    # test (matches /tests/)
        'vendor/lib.py',        # vendor (matches /vendor/)
    ]
    rules = [
        ZoneRule(Zone.TEST,   ['/tests/']),
        ZoneRule(Zone.VENDOR, ['/vendor/']),
    ]
    zm = None
    # Try common signatures
    for attempt in [
        lambda: FileZoneMap(files, rules),
        lambda: FileZoneMap(files=files, rules=rules),
        lambda: FileZoneMap(rules, None, None),  # other shape
    ]:
        try:
            zm = attempt()
            break
        except Exception:
            continue
    if zm is None:
        # Build a minimal mock that has .get(path) -> Zone
        class MockMap:
            def __init__(self, mapping): self._m = mapping
            def get(self, p): return self._m.get(p, Zone.PRODUCTION)
        zm = MockMap({
            'src/app.py': Zone.PRODUCTION,
            'src/core.py': Zone.PRODUCTION,
            'tests/test_app.py': Zone.TEST,
            'vendor/lib.py': Zone.VENDOR,
        })

    # 3c: production-only count is 2 (4 files, 2 non-prod)
    try:
        r = adjust_potential(zm, files, 4)
    except TypeError:
        r = adjust_potential(zm, files)
    if r == 2:
        score += 1
    else:
        notes.append(f"adj_full={r} (expected 2)")

    # 3d: empty subset → 0
    try:
        try:
            r2 = adjust_potential(zm, [], 0)
        except TypeError:
            r2 = adjust_potential(zm, [])
        if r2 == 0:
            score += 1
        else:
            notes.append(f"adj_empty={r2}")
    except Exception as e:
        notes.append(f"adj_empty_err:{e}")
except Exception as e:
    notes.append(f"behavior_err:{type(e).__name__}:{e}")

print(f"SCORE:{score}/4 {notes}")
PYEOF
)
echo "  $F3"
S=$(echo "$F3" | grep -oE 'SCORE:[0-9]+/4' | head -1 | sed 's|SCORE:||' | cut -d/ -f1)
case "$S" in
    4) add_reward 0.108; echo "  +0.108" ;;
    3) add_reward 0.078; echo "  +0.078" ;;
    2) add_reward 0.048; echo "  +0.048" ;;
    1) add_reward 0.018; echo "  +0.018" ;;
    *) echo "  +0" ;;
esac

# ===================================================================
# F2P 4 (0.15): End-to-end zone classification on a synthetic project.
# Build files, classify them with PY_ZONE_RULES, verify zones are correct
# AND verify pattern precision holds in the integrated flow.
# ===================================================================
echo "--- F2P 4: end-to-end classification with PY_ZONE_RULES (0.15) ---"
F4=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
try:
    from desloppify.zones import classify_file, Zone
    from desloppify.lang.python import PY_ZONE_RULES
except Exception as e:
    print(f"SCORE:0/8 import_err:{e}")
    sys.exit(0)

cases = [
    # path, expected zone
    ('src/app/views.py',           Zone.PRODUCTION),
    ('src/app/contests/foo.py',    Zone.PRODUCTION),     # NOT test (substring trap)
    ('src/contest_results.py',     Zone.PRODUCTION),     # NOT test (prefix trap)
    ('src/my_config.py',           Zone.PRODUCTION),     # NOT config (exact trap)
    ('src/tests/test_views.py',    Zone.TEST),           # /tests/ dir + test_ prefix
    ('tests/test_helpers.py',      Zone.TEST),           # root-level tests dir
    ('vendor/lib/foo.py',          Zone.VENDOR),         # /vendor/
    ('generated/proto_pb2.py',     Zone.GENERATED),      # /generated/
]

passed = 0
fails = []
for path, expected in cases:
    try:
        got = classify_file(path, PY_ZONE_RULES)
    except Exception as e:
        got = f"ERR:{e}"
    if got == expected:
        passed += 1
    else:
        fails.append((path, expected, got))

print(f"SCORE:{passed}/{len(cases)}")
for p, e, g in fails[:8]:
    print(f"  {p}: exp={e} got={g}")
PYEOF
)
echo "$F4" | head -10 | sed 's/^/  /'
S=$(echo "$F4" | grep -oE 'SCORE:[0-9]+/8' | head -1 | sed 's|SCORE:||' | cut -d/ -f1)
if [ -n "$S" ]; then
    if [ "$S" -ge 8 ]; then
        add_reward 0.090; echo "  +0.090 (8/8)"
    elif [ "$S" -ge 7 ]; then
        add_reward 0.066; echo "  +0.066 ($S/8)"
    elif [ "$S" -ge 6 ]; then
        add_reward 0.042; echo "  +0.042 ($S/8)"
    elif [ "$S" -ge 4 ]; then
        add_reward 0.018; echo "  +0.018 ($S/8)"
    else
        echo "  +0 ($S/8)"
    fi
fi

# ===================================================================
# F2P 5 (0.12): User override mechanism — overrides flow into FileZoneMap.
# Build a map where a "config.py" is overridden to PRODUCTION, verify .get()
# returns PRODUCTION. Try both override-as-arg and override-via-state.
# ===================================================================
echo "--- F2P 5: user override mechanism (0.12) ---"
F5=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
notes = []

try:
    from desloppify.zones import FileZoneMap, Zone, ZoneRule
    from desloppify.lang.python import PY_ZONE_RULES
except Exception as e:
    print(f"SCORE:0/3 import_err:{e}")
    sys.exit(0)

files = ['src/app.py', 'config.py', 'tests/test_x.py']

# 5a: without override, config.py → CONFIG
zm_default = None
for attempt in [
    lambda: FileZoneMap(files, PY_ZONE_RULES),
    lambda: FileZoneMap(files=files, rules=PY_ZONE_RULES),
]:
    try:
        zm_default = attempt(); break
    except Exception:
        continue
if zm_default is not None:
    try:
        z = zm_default.get('config.py')
        if z == Zone.CONFIG:
            score += 1
        else:
            notes.append(f"default_config={z}")
    except Exception as e:
        notes.append(f"default_err:{e}")
else:
    notes.append("no_FileZoneMap_ctor")

# 5b: with override config.py → production
zm_override = None
for attempt in [
    lambda: FileZoneMap(files, PY_ZONE_RULES, overrides={'config.py': 'production'}),
    lambda: FileZoneMap(files=files, rules=PY_ZONE_RULES, overrides={'config.py': 'production'}),
]:
    try:
        zm_override = attempt(); break
    except Exception:
        continue
if zm_override is not None:
    try:
        z = zm_override.get('config.py')
        if z == Zone.PRODUCTION:
            score += 1
        else:
            notes.append(f"override_config={z}")
    except Exception as e:
        notes.append(f"override_err:{e}")
else:
    notes.append("no_overrides_kwarg")

# 5c: override doesn't break unrelated classifications
if zm_override is not None:
    try:
        z_test = zm_override.get('tests/test_x.py')
        if z_test == Zone.TEST:
            score += 1
        else:
            notes.append(f"unrelated={z_test}")
    except Exception as e:
        notes.append(f"unrelated_err:{e}")

print(f"SCORE:{score}/3 {notes}")
PYEOF
)
echo "  $F5"
S=$(echo "$F5" | grep -oE 'SCORE:[0-9]+/3' | head -1 | sed 's|SCORE:||' | cut -d/ -f1)
case "$S" in
    3) add_reward 0.072; echo "  +0.072" ;;
    2) add_reward 0.042; echo "  +0.042" ;;
    1) add_reward 0.018; echo "  +0.018" ;;
    *) echo "  +0" ;;
esac

# ===================================================================
# F2P 6 (0.060): LangConfig has zone_rules field AND it's wired up.
# Tests that the language registers zone_rules so the pipeline can use them.
# ===================================================================
echo "--- F2P 6: LangConfig.zone_rules wired (0.10) ---"
F6=$(python3 - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '.')
score = 0
notes = []
try:
    from desloppify.lang.base import LangConfig
    import dataclasses
    fields = {f.name for f in dataclasses.fields(LangConfig)}
    if 'zone_rules' in fields:
        score += 1
    else:
        notes.append(f"no_zone_rules_field;fields={fields}")
except Exception as e:
    notes.append(f"langconfig_err:{e}")

# Check that python lang module registers a config with non-empty zone_rules
try:
    from desloppify.lang import LANGS
    py = LANGS.get('python') if isinstance(LANGS, dict) else None
    if py is None:
        # Try alternate access — maybe it's auto-registered on import
        import desloppify.lang.python  # noqa
        py = LANGS.get('python') if isinstance(LANGS, dict) else None
    if py is not None and hasattr(py, 'zone_rules') and py.zone_rules:
        score += 1
    else:
        notes.append(f"py_lang_zone_rules_empty;py={py}")
except Exception as e:
    notes.append(f"py_lang_err:{e}")

print(f"SCORE:{score}/2 {notes}")
PYEOF
)
echo "  $F6"
S=$(echo "$F6" | grep -oE 'SCORE:[0-9]+/2' | head -1 | sed 's|SCORE:||' | cut -d/ -f1)
case "$S" in
    2) add_reward 0.060; echo "  +0.060" ;;
    1) add_reward 0.024; echo "  +0.024" ;;
    *) echo "  +0" ;;
esac

# ===================================================================
# F2P 7 (0.08): Completeness — did the patch touch enough files?
# A "right idea but only edited zones.py" patch should lose this.
# Strong fixes touch zones.py + lang/python + lang/typescript + at least
# one of (lang/base.py, scoring.py, commands/scan.py).
# ===================================================================
echo "--- F2P 7: file-touch completeness signal (0.08) ---"
F7_count=0
# zones.py must mention COMMON_ZONE_RULES (added by all real fixes)
if grep -q "COMMON_ZONE_RULES" desloppify/zones.py 2>/dev/null; then
    F7_count=$((F7_count + 1))
fi
# python lang must define PY_ZONE_RULES
if grep -q "PY_ZONE_RULES" desloppify/lang/python/__init__.py 2>/dev/null; then
    F7_count=$((F7_count + 1))
fi
# typescript lang must define TS_ZONE_RULES
if grep -q "TS_ZONE_RULES" desloppify/lang/typescript/__init__.py 2>/dev/null; then
    F7_count=$((F7_count + 1))
fi
# adjust_potential must exist in zones.py
if grep -q "def adjust_potential" desloppify/zones.py 2>/dev/null; then
    F7_count=$((F7_count + 1))
fi
echo "  completeness signals: $F7_count/4"
case "$F7_count" in
    4) add_reward 0.048; echo "  +0.048" ;;
    3) add_reward 0.030; echo "  +0.030" ;;
    2) add_reward 0.012; echo "  +0.012" ;;
    *) echo "  +0" ;;
esac

# ===================================================================
# Optional: run any existing pytest tests for zones (bonus discrimination,
# no extra weight — zero-weight gating skipped if no tests exist).
# ===================================================================
if command -v pytest >/dev/null 2>&1; then
    if compgen -G "tests/test_zones*.py" >/dev/null 2>&1 || \
       compgen -G "tests/zones/test_*.py" >/dev/null 2>&1; then
        echo "--- Bonus: existing pytest zone tests ---"
        pytest tests/ -k zone -q --no-header 2>&1 | tail -5 | sed 's/^/  /'
    fi
fi

echo ""
echo "Final reward (before upstream gates): $REWARD"
echo "$REWARD" > "$LOG_DIR/reward.txt"

# ---- inner-claude upstream gates ----
echo "--- Upstream gates ---"
GATES_FILE="$LOG_DIR/gates.json"
> "$GATES_FILE"

# F2P upstream gate 1: zones.py core exports importable
echo "  Running f2p_upstream_zones_core..."
cd /workspace/desloppify && PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0,'.'); from desloppify.zones import COMMON_ZONE_RULES, adjust_potential, should_skip_finding, Zone, FileZoneMap; assert isinstance(COMMON_ZONE_RULES, list) and len(COMMON_ZONE_RULES) >= 3" 2>/dev/null
if [ $? -eq 0 ]; then
    echo '{"id": "f2p_upstream_zones_core", "passed": true, "detail": "zones.py core exports importable"}' >> "$GATES_FILE"
    echo "  f2p_upstream_zones_core: PASSED"
else
    echo '{"id": "f2p_upstream_zones_core", "passed": false, "detail": "zones.py missing or core exports not found"}' >> "$GATES_FILE"
    echo "  f2p_upstream_zones_core: FAILED"
fi

# F2P upstream gate 2: LangConfig.zone_rules + PY/TS_ZONE_RULES
echo "  Running f2p_upstream_lang_wiring..."
cd /workspace/desloppify && PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0,'.'); from desloppify.lang.base import LangConfig; import dataclasses; assert 'zone_rules' in {f.name for f in dataclasses.fields(LangConfig)}; from desloppify.lang.python import PY_ZONE_RULES; from desloppify.lang.typescript import TS_ZONE_RULES; assert isinstance(PY_ZONE_RULES, list) and len(PY_ZONE_RULES) >= 1; assert isinstance(TS_ZONE_RULES, list) and len(TS_ZONE_RULES) >= 1" 2>/dev/null
if [ $? -eq 0 ]; then
    echo '{"id": "f2p_upstream_lang_wiring", "passed": true, "detail": "LangConfig.zone_rules and PY/TS_ZONE_RULES present"}' >> "$GATES_FILE"
    echo "  f2p_upstream_lang_wiring: PASSED"
else
    echo '{"id": "f2p_upstream_lang_wiring", "passed": false, "detail": "LangConfig missing zone_rules or PY/TS_ZONE_RULES not found"}' >> "$GATES_FILE"
    echo "  f2p_upstream_lang_wiring: FAILED"
fi

# P2P upstream gate 1: CLI module imports cleanly
echo "  Running p2p_upstream_cli_import..."
cd /workspace/desloppify && PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0,'.'); from desloppify import cli" 2>/dev/null
if [ $? -eq 0 ]; then
    echo '{"id": "p2p_upstream_cli_import", "passed": true, "detail": "cli module imports cleanly"}' >> "$GATES_FILE"
    echo "  p2p_upstream_cli_import: PASSED"
else
    echo '{"id": "p2p_upstream_cli_import", "passed": false, "detail": "cli module import failed"}' >> "$GATES_FILE"
    echo "  p2p_upstream_cli_import: FAILED"
fi

# P2P upstream gate 2: Plan module imports cleanly
echo "  Running p2p_upstream_plan_import..."
cd /workspace/desloppify && PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0,'.'); from desloppify import plan" 2>/dev/null
if [ $? -eq 0 ]; then
    echo '{"id": "p2p_upstream_plan_import", "passed": true, "detail": "plan module imports cleanly"}' >> "$GATES_FILE"
    echo "  p2p_upstream_plan_import: PASSED"
else
    echo '{"id": "p2p_upstream_plan_import", "passed": false, "detail": "plan module import failed"}' >> "$GATES_FILE"
    echo "  p2p_upstream_plan_import: FAILED"
fi

# Run upstream reward adjustment
python3 /workspace/task/upstream_reward_tail.py
echo "Final reward (after upstream gates): $(cat $LOG_DIR/reward.txt)"
# ---- end ----

exit 0