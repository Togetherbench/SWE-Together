#!/bin/bash
set +e

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

# ═══════════════════════════════════════════════════════════════════
# CHECK 1 (0.08): register_detector() — behavioral
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 1 (0.08): register_detector() ==="
python3 << 'PYEOF'
import sys
sys.path.insert(0, ".")
try:
    from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
except Exception as e:
    print(f"  FAIL import: {e}", file=sys.stderr); sys.exit(1)

before = len(DETECTORS)
m = DetectorMeta(
    name="__chk1_det__", display="Check1", dimension="Code quality",
    action_type="manual_fix", guidance="t",
)
register_detector(m)
if "__chk1_det__" not in DETECTORS: sys.exit(2)
if DETECTORS["__chk1_det__"].display != "Check1": sys.exit(3)
if len(DETECTORS) != before + 1: sys.exit(4)

# Idempotent re-register
register_detector(m)
try:
    from desloppify.core.registry import _DISPLAY_ORDER
    if _DISPLAY_ORDER.count("__chk1_det__") != 1:
        sys.exit(5)
except Exception:
    pass

del DETECTORS["__chk1_det__"]
try:
    from desloppify.core.registry import _DISPLAY_ORDER
    while "__chk1_det__" in _DISPLAY_ORDER:
        _DISPLAY_ORDER.remove("__chk1_det__")
except Exception:
    pass
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.08

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.12): register_scoring_policy() rebuilds derived state
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 2 (0.12): register_scoring_policy() ==="
python3 << 'PYEOF'
import sys
sys.path.insert(0, ".")
try:
    import desloppify.engine.scoring_internal.policy.core as core
    from desloppify.engine.scoring_internal.policy.core import (
        DETECTOR_SCORING_POLICIES, DetectorScoringPolicy, register_scoring_policy,
    )
except Exception as e:
    print(f"  FAIL import: {e}", file=sys.stderr); sys.exit(1)

p = DetectorScoringPolicy(detector="__chk2_pol__", dimension="Code quality", tier=3, file_based=True)
register_scoring_policy(p)

if "__chk2_pol__" not in DETECTOR_SCORING_POLICIES: sys.exit(2)

dim = core.DIMENSIONS_BY_NAME.get("Code quality")
if dim is None: sys.exit(3)
if "__chk2_pol__" not in dim.detectors: sys.exit(4)
if "__chk2_pol__" not in core.FILE_BASED_DETECTORS: sys.exit(5)

# file_based=False should not be in FILE_BASED_DETECTORS
p2 = DetectorScoringPolicy(detector="__chk2_pol2__", dimension="Code quality", tier=3, file_based=False)
register_scoring_policy(p2)
if "__chk2_pol2__" in core.FILE_BASED_DETECTORS: sys.exit(6)

del DETECTOR_SCORING_POLICIES["__chk2_pol__"]
del DETECTOR_SCORING_POLICIES["__chk2_pol2__"]
try: core._rebuild_derived()
except Exception: pass
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.12

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.08): refresh_detector_tools() in-place mutation
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 3 (0.08): refresh_detector_tools() ==="
python3 << 'PYEOF'
import sys
sys.path.insert(0, ".")
try:
    from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS, refresh_detector_tools
except Exception as e:
    print(f"  FAIL import: {e}", file=sys.stderr); sys.exit(1)

ref = DETECTOR_TOOLS  # capture BEFORE mutation
register_detector(DetectorMeta(
    name="__chk3_det__", display="Chk3", dimension="Code quality",
    action_type="manual_fix", guidance="g",
))
refresh_detector_tools()
if "__chk3_det__" not in ref:
    print("  FAIL: in-place mutation missing", file=sys.stderr); sys.exit(2)

del DETECTORS["__chk3_det__"]
refresh_detector_tools()
if "__chk3_det__" in ref: sys.exit(3)
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.08

# ═══════════════════════════════════════════════════════════════════
# CHECK 4 (0.22): generic_lang() E2E — registers detectors, policies, phases
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 4 (0.22): generic_lang() E2E ==="
CHK4=$(python3 << 'PYEOF'
import sys, json
sys.path.insert(0, ".")
score = 0
parts = []
err = ""

try:
    from desloppify.languages.framework.generic import generic_lang
    parts.append("factory")
    score += 3
except Exception as e:
    print(json.dumps({"score": 0, "parts": [], "err": f"factory_import:{e}"}))
    sys.exit(0)

try:
    from desloppify.core.registry import DETECTORS, DETECTOR_TOOLS_KEYS  # may not exist
except Exception:
    pass

try:
    from desloppify.core.registry import DETECTORS
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    import desloppify.engine.scoring_internal.policy.core as policy_core
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
    from desloppify.languages.framework import registry_state

    # Try common signatures
    result = None
    last_exc = None
    attempts = [
        lambda: generic_lang(
            name="__chk4lang__",
            extensions=[".chk4"],
            markers=["chk4.toml"],
            tools=[{"label": "chk4tool", "cmd": "true", "fmt": "json",
                    "id": "__chk4_tool__", "tier": 2}],
        ),
        lambda: generic_lang(
            name="__chk4lang__",
            extensions=[".chk4"],
            detect_markers=["chk4.toml"],
            tools=[{"label": "chk4tool", "cmd": "true", "fmt": "json",
                    "id": "__chk4_tool__", "tier": 2}],
        ),
        lambda: generic_lang(
            "__chk4lang__",
            extensions=[".chk4"],
            detect_markers=["chk4.toml"],
            tools=[{"label": "chk4tool", "cmd": "true", "fmt": "json",
                    "id": "__chk4_tool__", "tier": 2}],
        ),
        lambda: generic_lang(
            "__chk4lang__",
            extensions=[".chk4"],
            markers=["chk4.toml"],
            tools=[{"label": "chk4tool", "cmd": "true", "fmt": "json",
                    "id": "__chk4_tool__", "tier": 2}],
        ),
    ]
    for fn in attempts:
        try:
            result = fn()
            break
        except TypeError as e:
            last_exc = e
            continue
        except Exception as e:
            last_exc = e
            continue

    cfg = None
    if "__chk4lang__" in registry_state._registry:
        entry = registry_state._registry["__chk4lang__"]
        try:
            cfg = entry() if callable(entry) else entry
        except Exception:
            cfg = entry
    if cfg is None and result is not None:
        cfg = result() if callable(result) else result

    if cfg is not None:
        parts.append("config")
        score += 3

    # Detector dynamically registered
    if "__chk4_tool__" in DETECTORS:
        parts.append("detector_registered")
        score += 4

    # Policy registered + reflected in derived state
    if "__chk4_tool__" in DETECTOR_SCORING_POLICIES:
        parts.append("policy_registered")
        score += 3
        # Verify it's in DIMENSIONS_BY_NAME's detectors
        cq = policy_core.DIMENSIONS_BY_NAME.get("Code quality")
        if cq is not None and "__chk4_tool__" in cq.detectors:
            parts.append("policy_in_dim")
            score += 2
        if "__chk4_tool__" in policy_core.FILE_BASED_DETECTORS:
            parts.append("policy_in_filebased")
            score += 2

    # DETECTOR_TOOLS refreshed
    if "__chk4_tool__" in DETECTOR_TOOLS:
        parts.append("detector_tools_refreshed")
        score += 2

    # Phases present (>=2: tool phase + at least one shared phase)
    if cfg is not None:
        phases = getattr(cfg, "phases", None) or []
        if len(phases) >= 2:
            parts.append("phases_2plus")
            score += 1
        if len(phases) >= 3:
            parts.append("phases_3plus")
            score += 1
        # Look for security / subjective / dupes phase names
        names = []
        for ph in phases:
            n = getattr(ph, "name", "") or getattr(ph, "label", "") or ""
            names.append(str(n).lower())
        joined = " ".join(names)
        shared_hits = sum(1 for kw in ("security", "subjective", "duplica", "boilerplate") if kw in joined)
        if shared_hits >= 2:
            parts.append("shared_phases")
            score += 1

except Exception as e:
    import traceback
    err = f"{e!r}\n{traceback.format_exc()[:400]}"

print(json.dumps({"score": score, "parts": parts, "err": err}))
PYEOF
)
echo "  $CHK4"
CHK4_SCORE=$(echo "$CHK4" | python3 -c "import sys,json
try:
    d=json.loads(sys.stdin.read() or '{}')
    print(d.get('score',0))
except: print(0)" 2>/dev/null)
[ -z "$CHK4_SCORE" ] && CHK4_SCORE=0
# 22 max points → scale to 0.22
CHK4_REWARD=$(awk -v s="$CHK4_SCORE" 'BEGIN{r=s/22.0*0.22; if(r>0.22)r=0.22; printf "%.4f", r}')
add_reward "$CHK4_REWARD"

# ═══════════════════════════════════════════════════════════════════
# CHECK 5 (0.12): Real generic plugin loads via discovery & is callable
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 5 (0.12): real generic plugin discovery ==="
CHK5=$(python3 << 'PYEOF'
import sys, json
sys.path.insert(0, ".")
score = 0
parts = []
err = ""

try:
    # Trigger discovery
    try:
        from desloppify.languages import discovery
        if hasattr(discovery, "load_all"):
            try:
                discovery.load_all()
                parts.append("load_all_ok")
                score += 2
            except Exception as e:
                err += f"load_all:{e};"
    except Exception as e:
        err += f"discovery:{e};"

    from desloppify.languages.framework import registry_state
    from desloppify.core.registry import DETECTORS
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS

    reg = registry_state._registry
    # Look for any commonly-expected generic plugin language
    candidates = ["go", "rust", "ruby", "swift", "kotlin", "elixir", "php", "lua", "bash", "cxx"]
    found_langs = [c for c in candidates if c in reg]
    if found_langs:
        parts.append(f"langs:{len(found_langs)}")
        score += min(len(found_langs), 4)  # up to 4 points

    # Attempt to instantiate first found
    cfg = None
    for lname in found_langs:
        try:
            entry = reg[lname]
            cfg = entry() if callable(entry) else entry
            if cfg is not None:
                parts.append(f"instantiated:{lname}")
                score += 2
                break
        except Exception as e:
            err += f"inst-{lname}:{e};"

    if cfg is not None:
        phases = getattr(cfg, "phases", None) or []
        if len(phases) >= 2:
            parts.append("has_phases")
            score += 2

    # At least one generic-style detector got registered (id ending in _lint or known patterns)
    generic_dets = [n for n in DETECTORS if any(n.endswith(s) for s in ("_lint", "_check", "_lint_check"))]
    if len(generic_dets) >= 1:
        parts.append(f"generic_dets:{len(generic_dets)}")
        score += 2

except Exception as e:
    import traceback
    err += f"top:{e!r}|{traceback.format_exc()[:300]}"

print(json.dumps({"score": score, "parts": parts, "err": err[:500]}))
PYEOF
)
echo "  $CHK5"
CHK5_SCORE=$(echo "$CHK5" | python3 -c "import sys,json
try:
    d=json.loads(sys.stdin.read() or '{}')
    print(d.get('score',0))
except: print(0)" 2>/dev/null)
[ -z "$CHK5_SCORE" ] && CHK5_SCORE=0
# Max 12 → 0.12
CHK5_REWARD=$(awk -v s="$CHK5_SCORE" 'BEGIN{r=s/12.0*0.12; if(r>0.12)r=0.12; printf "%.4f", r}')
add_reward "$CHK5_REWARD"

# ═══════════════════════════════════════════════════════════════════
# CHECK 6 (0.15): Scoring/narrative integration — registered detector
#   actually participates in scoring & generates narrative actions
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 6 (0.15): scoring/narrative integration ==="
CHK6=$(python3 << 'PYEOF'
import sys, json
sys.path.insert(0, ".")
score = 0
parts = []
err = ""

try:
    from desloppify.core.registry import DetectorMeta, register_detector, DETECTORS
    from desloppify.engine.scoring_internal.policy.core import (
        DetectorScoringPolicy, register_scoring_policy, DETECTOR_SCORING_POLICIES,
        detector_policy,
    )
    import desloppify.engine.scoring_internal.policy.core as pc
    from desloppify.intelligence.narrative._constants import refresh_detector_tools, DETECTOR_TOOLS

    # Register a full synthetic detector
    register_detector(DetectorMeta(
        name="__chk6_synth__", display="Chk6Synth", dimension="Code quality",
        action_type="manual_fix", guidance="fix it",
    ))
    register_scoring_policy(DetectorScoringPolicy(
        detector="__chk6_synth__", dimension="Code quality", tier=2, file_based=True,
    ))
    refresh_detector_tools()

    # 6a: detector_policy() returns the registered policy with proper tier
    pol = detector_policy("__chk6_synth__")
    if pol.tier == 2 and pol.dimension == "Code quality":
        parts.append("policy_lookup")
        score += 3

    # 6b: dimension contains the detector
    cq = pc.DIMENSIONS_BY_NAME.get("Code quality")
    if cq and "__chk6_synth__" in cq.detectors:
        parts.append("dim_includes")
        score += 3

    # 6c: DETECTOR_TOOLS contains the detector after refresh
    if "__chk6_synth__" in DETECTOR_TOOLS:
        parts.append("narrative_tools")
        score += 3

    # 6d: tier weights / file-based behavior consistent
    if "__chk6_synth__" in pc.FILE_BASED_DETECTORS:
        parts.append("file_based")
        score += 3

    # 6e: re-registering with different tier should update derived state
    register_scoring_policy(DetectorScoringPolicy(
        detector="__chk6_synth__", dimension="Code quality", tier=4, file_based=True,
    ))
    pol2 = detector_policy("__chk6_synth__")
    if pol2.tier == 4:
        parts.append("update_works")
        score += 3

    # Cleanup
    del DETECTORS["__chk6_synth__"]
    del DETECTOR_SCORING_POLICIES["__chk6_synth__"]
    try: pc._rebuild_derived()
    except: pass
    refresh_detector_tools()

except Exception as e:
    import traceback
    err = f"{e!r}|{traceback.format_exc()[:400]}"

print(json.dumps({"score": score, "parts": parts, "err": err[:500]}))
PYEOF
)
echo "  $CHK6"
CHK6_SCORE=$(echo "$CHK6" | python3 -c "import sys,json
try:
    d=json.loads(sys.stdin.read() or '{}')
    print(d.get('score',0))
except: print(0)" 2>/dev/null)
[ -z "$CHK6_SCORE" ] && CHK6_SCORE=0
# Max 15 → 0.15
CHK6_REWARD=$(awk -v s="$CHK6_SCORE" 'BEGIN{r=s/15.0*0.15; if(r>0.15)r=0.15; printf "%.4f", r}')
add_reward "$CHK6_REWARD"

# ═══════════════════════════════════════════════════════════════════
# CHECK 7 (0.10): Shared phases (security, subjective, duplicates)
#   appended to generic plugins
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 7 (0.10): shared phases ==="
CHK7=$(python3 << 'PYEOF'
import sys, json
sys.path.insert(0, ".")
score = 0
parts = []

try:
    from desloppify.languages.framework.generic import generic_lang
    from desloppify.languages.framework import registry_state

    # Use a fresh language name
    try:
        generic_lang(
            name="__chk7lang__",
            extensions=[".chk7"],
            markers=["chk7.toml"],
            tools=[{"label": "chk7t", "cmd": "true", "fmt": "json",
                    "id": "__chk7_tool__", "tier": 2}],
        )
    except TypeError:
        try:
            generic_lang(
                "__chk7lang__",
                extensions=[".chk7"],
                detect_markers=["chk7.toml"],
                tools=[{"label": "chk7t", "cmd": "true", "fmt": "json",
                        "id": "__chk7_tool__", "tier": 2}],
            )
        except Exception:
            pass

    entry = registry_state._registry.get("__chk7lang__")
    cfg = None
    if entry is not None:
        try: cfg = entry() if callable(entry) else entry
        except: cfg = entry

    if cfg is not None:
        phases = getattr(cfg, "phases", None) or []
        names = []
        for ph in phases:
            n = getattr(ph, "name", "") or ""
            names.append(str(n).lower())

        # Tool phase exists
        if any("chk7" in n or "chk7t" in n for n in names) or len(phases) >= 1:
            parts.append("tool_phase")
            score += 2

        joined = " | ".join(names)

        # Security phase
        if any("security" in n for n in names):
            parts.append("security")
            score += 2

        # Subjective phase
        if any("subjective" in n or "review" in n for n in names):
            parts.append("subjective")
            score += 2

        # Duplicates / dupes
        if any("duplica" in n or "dupe" in n for n in names):
            parts.append("duplicates")
            score += 2

        # Boilerplate
        if any("boilerplate" in n or "jscpd" in n for n in names):
            parts.append("boilerplate")
            score += 2

except Exception:
    pass

print(json.dumps({"score": score, "parts": parts}))
PYEOF
)
echo "  $CHK7"
CHK7_SCORE=$(echo "$CHK7" | python3 -c "import sys,json
try:
    d=json.loads(sys.stdin.read() or '{}')
    print(d.get('score',0))
except: print(0)" 2>/dev/null)
[ -z "$CHK7_SCORE" ] && CHK7_SCORE=0
# Max 10 → 0.10
CHK7_REWARD=$(awk -v s="$CHK7_SCORE" 'BEGIN{r=s/10.0*0.10; if(r>0.10)r=0.10; printf "%.4f", r}')
add_reward "$CHK7_REWARD"

# ═══════════════════════════════════════════════════════════════════
# CHECK 8 (0.08): Regression — existing tests in core areas still pass
#   (registry, scoring policy, narrative constants imports)
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 8 (0.08): regression — core imports & basic tests ==="
python3 << 'PYEOF'
import sys
sys.path.insert(0, ".")
errors = []
try:
    from desloppify.core.registry import DETECTORS, DetectorMeta
    if not isinstance(DETECTORS, dict) or len(DETECTORS) < 1:
        errors.append("DETECTORS empty/wrong type")
except Exception as e:
    errors.append(f"registry:{e}")

try:
    from desloppify.engine.scoring_internal.policy.core import (
        DETECTOR_SCORING_POLICIES, DIMENSIONS_BY_NAME, FILE_BASED_DETECTORS,
        DetectorScoringPolicy, detector_policy,
    )
    if "Code quality" not in DIMENSIONS_BY_NAME:
        errors.append("Code quality dim missing")
except Exception as e:
    errors.append(f"policy:{e}")

try:
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
    if not isinstance(DETECTOR_TOOLS, dict):
        errors.append("DETECTOR_TOOLS wrong type")
except Exception as e:
    errors.append(f"narrative:{e}")

try:
    from desloppify.languages.framework.base.phase_builders import (
        detector_phase_security, shared_subjective_duplicates_tail,
    )
    sec = detector_phase_security()
    tail = shared_subjective_duplicates_tail()
    if sec is None or not tail:
        errors.append("phase_builders empty")
except Exception as e:
    errors.append(f"phase_builders:{e}")

if errors:
    print("  FAIL:", errors, file=sys.stderr)
    sys.exit(1)
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.08

# ═══════════════════════════════════════════════════════════════════
# CHECK 9 (0.05): pytest sanity — focused tests don't blow up
# ═══════════════════════════════════════════════════════════════════
echo "=== Check 9 (0.05): pytest sanity ==="
if python3 -c "import pytest" 2>/dev/null; then
    OUT=$(timeout 90 python3 -m pytest desloppify/tests -q -x \
        --ignore=desloppify/tests/lang \
        -k "registry or policy or narrative or scoring" \
        --no-header 2>&1 | tail -20)
    echo "$OUT" | tail -5
    if echo "$OUT" | grep -qE "passed|no tests ran"; then
        if ! echo "$OUT" | grep -qE "failed|error"; then
            add_reward 0.05
        else
            # Some passed even with failures: partial
            PASSED=$(echo "$OUT" | grep -oE "[0-9]+ passed" | head -1 | grep -oE "[0-9]+")
            FAILED=$(echo "$OUT" | grep -oE "[0-9]+ failed" | head -1 | grep -oE "[0-9]+")
            [ -z "$PASSED" ] && PASSED=0
            [ -z "$FAILED" ] && FAILED=0
            if [ "$PASSED" -gt 0 ] && [ "$FAILED" -lt 3 ]; then
                add_reward 0.025
            fi
        fi
    fi
else
    # No pytest available — give partial credit since structural checks already passed
    add_reward 0.025
fi

# ═══════════════════════════════════════════════════════════════════
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$LOG_DIR/reward.txt"
exit 0