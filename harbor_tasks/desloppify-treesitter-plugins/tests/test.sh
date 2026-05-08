#!/bin/bash
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REWARD=0.0
WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

finish() {
    echo "$REWARD" > "$LOG_DIR/reward.txt"
    exit 0
}

cd "$WORKSPACE" 2>/dev/null || finish

# ═══════════════════════════════════════════════════════════════════
# P2P GATE: base imports still work (regression guard, no reward)
# ═══════════════════════════════════════════════════════════════════
python3 -c "
import sys
sys.path.insert(0, '.')
from desloppify.core.registry import DETECTORS, DetectorMeta
from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES, DetectorScoringPolicy
from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "REGRESSION: base imports broken"
    finish
fi

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 1 (0.10): register_detector() exists and works
# Fails on no-op (function doesn't exist on base)
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 1 (0.10): register_detector() ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
except Exception as e:
    print(f"  FAIL: {e}"); sys.exit(1)

m = DetectorMeta(
    name="__f2p1_det__", display="F2P1", dimension="Code quality",
    action_type="manual_fix", guidance="t",
)
register_detector(m)
if "__f2p1_det__" not in DETECTORS:
    sys.exit(2)
if DETECTORS["__f2p1_det__"].display != "F2P1":
    sys.exit(3)

# Idempotent re-register: _DISPLAY_ORDER must not duplicate
register_detector(m)
try:
    from desloppify.core.registry import _DISPLAY_ORDER
    if _DISPLAY_ORDER.count("__f2p1_det__") != 1:
        sys.exit(4)
except ImportError:
    pass

del DETECTORS["__f2p1_det__"]
try:
    from desloppify.core.registry import _DISPLAY_ORDER
    while "__f2p1_det__" in _DISPLAY_ORDER:
        _DISPLAY_ORDER.remove("__f2p1_det__")
except Exception:
    pass
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.10

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 2 (0.18): register_scoring_policy() rebuilds derived state
# Fails on no-op (function doesn't exist; derived rebuild not invoked)
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 2 (0.18): register_scoring_policy() rebuilds derived ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    import desloppify.engine.scoring_internal.policy.core as core
    from desloppify.engine.scoring_internal.policy.core import (
        DETECTOR_SCORING_POLICIES, DetectorScoringPolicy, register_scoring_policy,
    )
except Exception as e:
    print(f"  FAIL import: {e}"); sys.exit(1)

p = DetectorScoringPolicy(detector="__f2p2_pol__", dimension="Code quality", tier=3, file_based=True)
register_scoring_policy(p)

if "__f2p2_pol__" not in DETECTOR_SCORING_POLICIES:
    sys.exit(2)

# Derived state must reflect new policy
dim = core.DIMENSIONS_BY_NAME.get("Code quality")
if dim is None:
    sys.exit(3)
if "__f2p2_pol__" not in dim.detectors:
    sys.exit(4)
if "__f2p2_pol__" not in core.FILE_BASED_DETECTORS:
    sys.exit(5)

# file_based=False must NOT be in FILE_BASED_DETECTORS
p2 = DetectorScoringPolicy(detector="__f2p2_pol2__", dimension="Code quality", tier=3, file_based=False)
register_scoring_policy(p2)
if "__f2p2_pol2__" in core.FILE_BASED_DETECTORS:
    sys.exit(6)

# Cleanup
del DETECTOR_SCORING_POLICIES["__f2p2_pol__"]
del DETECTOR_SCORING_POLICIES["__f2p2_pol2__"]
try: core._rebuild_derived()
except Exception: pass
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.18

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 3 (0.12): refresh_detector_tools() with in-place mutation
# Fails on no-op (function doesn't exist) AND fails for naive impl
# that rebinds the dict (must mutate in-place to satisfy this check).
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 3 (0.12): refresh_detector_tools() in-place ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS, refresh_detector_tools
except Exception as e:
    print(f"  FAIL: {e}"); sys.exit(1)

# Capture reference BEFORE any mutation — like narrative modules do
ref = DETECTOR_TOOLS

register_detector(DetectorMeta(
    name="__f2p3_det__", display="F2P3", dimension="Code quality",
    action_type="manual_fix", guidance="g",
))
refresh_detector_tools()

# Critical: the captured reference must reflect the update
if "__f2p3_det__" not in ref:
    print("  FAIL: not in-place mutation"); sys.exit(2)

# Cleanup
del DETECTORS["__f2p3_det__"]
refresh_detector_tools()
if "__f2p3_det__" in ref:
    sys.exit(3)
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.12

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 4 (0.20): generic_lang() registers detector dynamically
# When generic_lang() is called with a tool, the tool's id must end
# up in DETECTORS. Base generic.py doesn't do this.
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 4 (0.20): generic_lang() registers detectors ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.languages.framework.generic import generic_lang
    from desloppify.core.registry import DETECTORS
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
except Exception as e:
    print(f"  FAIL import: {e}"); sys.exit(1)

# Try a variety of plausible signatures
attempts = [
    dict(name="__f2p4lang__", extensions=[".f2p4"], markers=["f2p4.toml"],
         tools=[{"label":"f2p4tool","cmd":"true","fmt":"json","id":"__f2p4_tool__","tier":2}]),
    dict(name="__f2p4lang__", extensions=[".f2p4"], detect_markers=["f2p4.toml"],
         tools=[{"label":"f2p4tool","cmd":"true","fmt":"json","id":"__f2p4_tool__","tier":2}]),
    dict(name="__f2p4lang__", extensions=[".f2p4"], markers=["f2p4.toml"], exclusions=[],
         tools=[{"label":"f2p4tool","cmd":"true","fmt":"json","id":"__f2p4_tool__","tier":2}]),
    dict(name="__f2p4lang__", extensions=[".f2p4"], detect_markers=["f2p4.toml"], exclusions=[],
         tools=[{"label":"f2p4tool","cmd":"true","fmt":"json","id":"__f2p4_tool__","tier":2}]),
]
last_exc = None
called = False
for kwargs in attempts:
    try:
        generic_lang(**kwargs)
        called = True
        break
    except TypeError as e:
        last_exc = e
        continue
    except Exception as e:
        last_exc = e
        # Some impls may try subprocess at registration; that's fine if detector got registered first.
        if "__f2p4_tool__" in DETECTORS:
            called = True
            break
        continue

if not called and "__f2p4_tool__" not in DETECTORS:
    # Try positional
    try:
        generic_lang("__f2p4lang__", extensions=[".f2p4"], markers=["f2p4.toml"],
                     tools=[{"label":"f2p4tool","cmd":"true","fmt":"json","id":"__f2p4_tool__","tier":2}])
        called = True
    except Exception as e:
        last_exc = e

if "__f2p4_tool__" not in DETECTORS:
    print(f"  FAIL: tool not registered as detector ({last_exc})"); sys.exit(2)

print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.20

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 5 (0.15): generic_lang() registers scoring policy
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 5 (0.15): generic_lang() registers scoring policy ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.languages.framework.generic import generic_lang
    from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
    import desloppify.engine.scoring_internal.policy.core as policy_core
except Exception as e:
    print(f"  FAIL import: {e}"); sys.exit(1)

attempts = [
    dict(name="__f2p5lang__", extensions=[".f2p5"], markers=["f2p5.toml"],
         tools=[{"label":"f2p5tool","cmd":"true","fmt":"json","id":"__f2p5_tool__","tier":2}]),
    dict(name="__f2p5lang__", extensions=[".f2p5"], detect_markers=["f2p5.toml"],
         tools=[{"label":"f2p5tool","cmd":"true","fmt":"json","id":"__f2p5_tool__","tier":2}]),
    dict(name="__f2p5lang__", extensions=[".f2p5"], markers=["f2p5.toml"], exclusions=[],
         tools=[{"label":"f2p5tool","cmd":"true","fmt":"json","id":"__f2p5_tool__","tier":2}]),
    dict(name="__f2p5lang__", extensions=[".f2p5"], detect_markers=["f2p5.toml"], exclusions=[],
         tools=[{"label":"f2p5tool","cmd":"true","fmt":"json","id":"__f2p5_tool__","tier":2}]),
]
for kwargs in attempts:
    try:
        generic_lang(**kwargs)
        break
    except Exception:
        if "__f2p5_tool__" in DETECTOR_SCORING_POLICIES:
            break
        continue

if "__f2p5_tool__" not in DETECTOR_SCORING_POLICIES:
    print("  FAIL: scoring policy not registered"); sys.exit(2)

# Derived state must include it
cq = policy_core.DIMENSIONS_BY_NAME.get("Code quality")
if cq is None or "__f2p5_tool__" not in cq.detectors:
    print("  FAIL: not in DIMENSIONS_BY_NAME[Code quality].detectors"); sys.exit(3)

if "__f2p5_tool__" not in policy_core.FILE_BASED_DETECTORS:
    print("  FAIL: not in FILE_BASED_DETECTORS"); sys.exit(4)

print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.15

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 6 (0.10): generic_lang() refreshes DETECTOR_TOOLS
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 6 (0.10): DETECTOR_TOOLS refreshed by generic_lang() ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.languages.framework.generic import generic_lang
    from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
except Exception as e:
    print(f"  FAIL import: {e}"); sys.exit(1)

attempts = [
    dict(name="__f2p6lang__", extensions=[".f2p6"], markers=["f2p6.toml"],
         tools=[{"label":"f2p6tool","cmd":"true","fmt":"json","id":"__f2p6_tool__","tier":2}]),
    dict(name="__f2p6lang__", extensions=[".f2p6"], detect_markers=["f2p6.toml"],
         tools=[{"label":"f2p6tool","cmd":"true","fmt":"json","id":"__f2p6_tool__","tier":2}]),
    dict(name="__f2p6lang__", extensions=[".f2p6"], markers=["f2p6.toml"], exclusions=[],
         tools=[{"label":"f2p6tool","cmd":"true","fmt":"json","id":"__f2p6_tool__","tier":2}]),
    dict(name="__f2p6lang__", extensions=[".f2p6"], detect_markers=["f2p6.toml"], exclusions=[],
         tools=[{"label":"f2p6tool","cmd":"true","fmt":"json","id":"__f2p6_tool__","tier":2}]),
]
for kwargs in attempts:
    try:
        generic_lang(**kwargs)
        break
    except Exception:
        if "__f2p6_tool__" in DETECTOR_TOOLS:
            break
        continue

if "__f2p6_tool__" not in DETECTOR_TOOLS:
    print("  FAIL: DETECTOR_TOOLS not refreshed"); sys.exit(2)
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.10

# ═══════════════════════════════════════════════════════════════════
# F2P CHECK 7 (0.15): generic_lang() appends shared phases
# (security + at least one of subjective/duplicates/boilerplate)
# ═══════════════════════════════════════════════════════════════════
echo "=== F2P 7 (0.15): generic_lang() includes shared phases ==="
python3 << 'PYEOF' 2>&1
import sys
sys.path.insert(0, ".")
try:
    from desloppify.languages.framework.generic import generic_lang
    from desloppify.languages.framework import registry_state
except Exception as e:
    print(f"  FAIL import: {e}"); sys.exit(1)

attempts = [
    dict(name="__f2p7lang__", extensions=[".f2p7"], markers=["f2p7.toml"],
         tools=[{"label":"f2p7tool","cmd":"true","fmt":"json","id":"__f2p7_tool__","tier":2}]),
    dict(name="__f2p7lang__", extensions=[".f2p7"], detect_markers=["f2p7.toml"],
         tools=[{"label":"f2p7tool","cmd":"true","fmt":"json","id":"__f2p7_tool__","tier":2}]),
    dict(name="__f2p7lang__", extensions=[".f2p7"], markers=["f2p7.toml"], exclusions=[],
         tools=[{"label":"f2p7tool","cmd":"true","fmt":"json","id":"__f2p7_tool__","tier":2}]),
    dict(name="__f2p7lang__", extensions=[".f2p7"], detect_markers=["f2p7.toml"], exclusions=[],
         tools=[{"label":"f2p7tool","cmd":"true","fmt":"json","id":"__f2p7_tool__","tier":2}]),
]
result = None
for kwargs in attempts:
    try:
        result = generic_lang(**kwargs)
        break
    except Exception:
        if "__f2p7lang__" in registry_state._registry:
            break
        continue

cfg = None
entry = registry_state._registry.get("__f2p7lang__")
if entry is not None:
    try:
        cfg = entry() if callable(entry) else entry
    except Exception:
        cfg = entry
if cfg is None and result is not None:
    try:
        cfg = result() if callable(result) else result
    except Exception:
        cfg = result

if cfg is None:
    print("  FAIL: no config registered"); sys.exit(2)

phases = getattr(cfg, "phases", None) or []
phase_names = []
for p in phases:
    nm = getattr(p, "name", None) or getattr(p, "label", None) or str(p)
    phase_names.append(str(nm).lower())

joined = " | ".join(phase_names)
# Must have the tool phase plus shared phases
if len(phases) < 3:
    print(f"  FAIL: only {len(phases)} phases: {phase_names}"); sys.exit(3)

has_security = any("security" in n or "secret" in n for n in phase_names)
has_shared = any(("subjective" in n) or ("duplicat" in n) or ("boilerplate" in n) for n in phase_names)

if not has_security:
    print(f"  FAIL: no security phase: {phase_names}"); sys.exit(4)
if not has_shared:
    print(f"  FAIL: no shared subjective/duplicate phase: {phase_names}"); sys.exit(5)
print("  PASS")
PYEOF
[ $? -eq 0 ] && add_reward 0.15

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$LOG_DIR/reward.txt"
exit 0