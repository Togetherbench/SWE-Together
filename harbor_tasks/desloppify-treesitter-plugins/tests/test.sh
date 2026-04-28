#!/bin/bash
set +e

WORKSPACE="/workspace/desloppify"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"
GATES_FILE="$LOG_DIR/gates.json"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr -d '\n' | sed 's/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

cd "$WORKSPACE" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════
# P2P: base imports still work
# ═══════════════════════════════════════════════════════════════════
python3 -c "
import sys
sys.path.insert(0, '.')
from desloppify.core.registry import DETECTORS, DetectorMeta
from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES, DetectorScoringPolicy
from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS
" 2>/dev/null
if [ $? -eq 0 ]; then
    emit p2p_base_imports true ""
else
    emit p2p_base_imports false "base imports broken"
    # Don't exit early; let F2Ps fail naturally and reward=0
fi

run_py() {
    local gate_id="$1"
    local script="$2"
    local fail_reason
    fail_reason=$(python3 -c "$script" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then
        emit "$gate_id" true ""
        return 0
    else
        emit "$gate_id" false "$(printf '%s' "$fail_reason" | tail -c 240)"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# F2P 1: register_detector()
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_register_detector '
import sys
sys.path.insert(0, ".")
from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
m = DetectorMeta(name="__g1_det__", display="G1", dimension="Code quality",
                 action_type="manual_fix", guidance="t")
register_detector(m)
assert "__g1_det__" in DETECTORS, "not in DETECTORS"
assert DETECTORS["__g1_det__"].display == "G1", "wrong display"
# Idempotent
register_detector(m)
try:
    from desloppify.core.registry import _DISPLAY_ORDER
    assert _DISPLAY_ORDER.count("__g1_det__") == 1, "duplicated in display order"
except ImportError:
    pass
'

# ═══════════════════════════════════════════════════════════════════
# F2P 2: register_scoring_policy() updates derived state.
# Implementation-agnostic: read via module attribute lookup so both
# in-place mutation AND `global` rebind (as in the plan) pass.
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_register_scoring_policy '
import sys
sys.path.insert(0, ".")
import desloppify.engine.scoring_internal.policy.core as core
from desloppify.engine.scoring_internal.policy.core import (
    DETECTOR_SCORING_POLICIES, DetectorScoringPolicy, register_scoring_policy,
)
p = DetectorScoringPolicy(detector="__g2_pol__", dimension="Code quality",
                          tier=3, file_based=True)
register_scoring_policy(p)
assert "__g2_pol__" in DETECTOR_SCORING_POLICIES, "policy not registered"

# Derived state must reflect the new policy via module attribute access
dim = core.DIMENSIONS_BY_NAME.get("Code quality")
assert dim is not None, "Code quality dimension missing"
assert "__g2_pol__" in dim.detectors, "policy not in dim.detectors"
assert "__g2_pol__" in core.FILE_BASED_DETECTORS, "not in FILE_BASED_DETECTORS"

# file_based=False must NOT appear in FILE_BASED_DETECTORS
p2 = DetectorScoringPolicy(detector="__g2_pol2__", dimension="Code quality",
                           tier=3, file_based=False)
register_scoring_policy(p2)
assert "__g2_pol2__" not in core.FILE_BASED_DETECTORS, "file_based=False leaked"
'

# ═══════════════════════════════════════════════════════════════════
# F2P 3: refresh_detector_tools() must mutate DETECTOR_TOOLS in place
# AND the value must be derived from the registry (not a stub).
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_refresh_detector_tools_inplace '
import sys
sys.path.insert(0, ".")
from desloppify.core.registry import DETECTORS, DetectorMeta, register_detector
from desloppify.intelligence.narrative import _constants as nc
ref = nc.DETECTOR_TOOLS  # capture before mutation
register_detector(DetectorMeta(name="__g3_det__", display="G3", dimension="Code quality",
                               action_type="manual_fix", guidance="g"))

# Some implementations refresh via callback on register; otherwise call manually.
refresh_fn = getattr(nc, "refresh_detector_tools", None)
if refresh_fn is None:
    # Allow private name as fallback
    refresh_fn = getattr(nc, "_refresh_detector_tools", None)
if refresh_fn is not None:
    refresh_fn()

# In-place semantics: the captured reference must observe the update
assert "__g3_det__" in ref, "DETECTOR_TOOLS not mutated in place (held reference stale)"
# Module attribute should agree
assert "__g3_det__" in nc.DETECTOR_TOOLS, "DETECTOR_TOOLS module attr missing key"
'

# ═══════════════════════════════════════════════════════════════════
# F2P 4: generic_lang() registers tool ids as detectors.
# Must complete WITHOUT exception (no fallback that ignores crashes).
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_generic_lang_registers_detector '
import sys, inspect
sys.path.insert(0, ".")
from desloppify.languages.framework.generic import generic_lang
from desloppify.core.registry import DETECTORS

sig = inspect.signature(generic_lang)
param_names = list(sig.parameters.keys())

tool = {"label":"g4tool","cmd":"true","fmt":"json","id":"__g4_tool__","tier":2}
common = dict(name="__g4_lang__", extensions=[".g4"], tools=[tool])

# Pick the marker keyword the implementation actually accepts.
markers_val = ["g4.toml"]
if "detect_markers" in param_names:
    common["detect_markers"] = markers_val
elif "markers" in param_names:
    common["markers"] = markers_val

# Optional exclude param
if "exclude" in param_names:
    common["exclude"] = []
elif "exclusions" in param_names:
    common["exclusions"] = []

generic_lang(**common)  # MUST NOT raise
assert "__g4_tool__" in DETECTORS, "tool id not registered as detector"
assert DETECTORS["__g4_tool__"].dimension == "Code quality", "wrong dimension"
'

# ═══════════════════════════════════════════════════════════════════
# F2P 5: generic_lang() registers scoring policy + derived state
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_generic_lang_registers_scoring '
import sys, inspect
sys.path.insert(0, ".")
from desloppify.languages.framework.generic import generic_lang
from desloppify.engine.scoring_internal.policy.core import DETECTOR_SCORING_POLICIES
import desloppify.engine.scoring_internal.policy.core as policy_core

sig = inspect.signature(generic_lang)
pn = list(sig.parameters.keys())
tool = {"label":"g5tool","cmd":"true","fmt":"json","id":"__g5_tool__","tier":2}
kw = dict(name="__g5_lang__", extensions=[".g5"], tools=[tool])
if "detect_markers" in pn: kw["detect_markers"] = ["g5.toml"]
elif "markers" in pn: kw["markers"] = ["g5.toml"]
if "exclude" in pn: kw["exclude"] = []
elif "exclusions" in pn: kw["exclusions"] = []

generic_lang(**kw)
assert "__g5_tool__" in DETECTOR_SCORING_POLICIES, "scoring policy not registered"

cq = policy_core.DIMENSIONS_BY_NAME.get("Code quality")
assert cq is not None, "Code quality dim missing"
assert "__g5_tool__" in cq.detectors, "tool not in dim.detectors"
assert "__g5_tool__" in policy_core.FILE_BASED_DETECTORS, "tool not in FILE_BASED_DETECTORS"
'

# ═══════════════════════════════════════════════════════════════════
# F2P 6: generic_lang() causes DETECTOR_TOOLS to include the tool
# (verifies refresh wired into generic_lang or callback)
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_generic_lang_refreshes_narrative '
import sys, inspect
sys.path.insert(0, ".")
from desloppify.languages.framework.generic import generic_lang
from desloppify.intelligence.narrative._constants import DETECTOR_TOOLS

sig = inspect.signature(generic_lang)
pn = list(sig.parameters.keys())
tool = {"label":"g6tool","cmd":"true","fmt":"json","id":"__g6_tool__","tier":2}
kw = dict(name="__g6_lang__", extensions=[".g6"], tools=[tool])
if "detect_markers" in pn: kw["detect_markers"] = ["g6.toml"]
elif "markers" in pn: kw["markers"] = ["g6.toml"]
if "exclude" in pn: kw["exclude"] = []
elif "exclusions" in pn: kw["exclusions"] = []

generic_lang(**kw)
assert "__g6_tool__" in DETECTOR_TOOLS, "DETECTOR_TOOLS not refreshed by generic_lang"
'

# ═══════════════════════════════════════════════════════════════════
# F2P 7: generic_lang() appends shared phases (security + at least one
# of subjective review / duplicates / boilerplate duplication)
# ═══════════════════════════════════════════════════════════════════
run_py t1_f2p_generic_lang_shared_phases '
import sys, inspect
sys.path.insert(0, ".")
from desloppify.languages.framework.generic import generic_lang

sig = inspect.signature(generic_lang)
pn = list(sig.parameters.keys())
tool = {"label":"g7tool","cmd":"true","fmt":"json","id":"__g7_tool__","tier":2}
kw = dict(name="__g7_lang__", extensions=[".g7"], tools=[tool])
if "detect_markers" in pn: kw["detect_markers"] = ["g7.toml"]
elif "markers" in pn: kw["markers"] = ["g7.toml"]
if "exclude" in pn: kw["exclude"] = []
elif "exclusions" in pn: kw["exclusions"] = []

result = generic_lang(**kw)

# Locate the LangConfig: returned, or in registry_state
cfg = None
if result is not None:
    cfg = result
if cfg is None or not hasattr(cfg, "phases"):
    try:
        from desloppify.languages.framework import registry_state
        entry = getattr(registry_state, "_registry", {}).get("__g7_lang__")
        if entry is not None:
            cfg = entry() if callable(entry) and not hasattr(entry, "phases") else entry
    except Exception:
        pass

assert cfg is not None, "no config found"
phases = list(getattr(cfg, "phases", []) or [])
assert phases, "no phases on config"

labels = []
for p in phases:
    nm = getattr(p, "label", None) or getattr(p, "name", None) or str(p)
    labels.append(str(nm).lower())

joined = " | ".join(labels)
has_security = any(("security" in l) or ("secret" in l) for l in labels)
has_shared = any(("subjective" in l) or ("duplicat" in l) or ("boilerplate" in l) for l in labels)
assert has_security, f"no security phase in {labels}"
assert has_shared, f"no subjective/duplicate/boilerplate phase in {labels}"
# Tool phase should still be present (not replaced by shared phases)
assert len(phases) >= 3, f"expected tool + multiple shared phases, got {labels}"
'

# ═══════════════════════════════════════════════════════════════════
# Compute reward from gates.json
# ═══════════════════════════════════════════════════════════════════
python3 << PYEOF
import json
weights = {
    "t1_f2p_register_detector": 0.10,
    "t1_f2p_register_scoring_policy": 0.15,
    "t1_f2p_refresh_detector_tools_inplace": 0.15,
    "t1_f2p_generic_lang_registers_detector": 0.15,
    "t1_f2p_generic_lang_registers_scoring": 0.15,
    "t1_f2p_generic_lang_refreshes_narrative": 0.10,
    "t1_f2p_generic_lang_shared_phases": 0.20,
}
p2p_gating = {"p2p_base_imports"}
gates = []
with open("$GATES_FILE") as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: gates.append(json.loads(line))
        except Exception: pass

# P2P gating: any failure zeroes reward
for g in gates:
    if g["id"] in p2p_gating and not g["passed"]:
        reward = 0.0
        break
else:
    reward = sum(weights.get(g["id"], 0.0) for g in gates if g["passed"])

if reward > 1.0: reward = 1.0
with open("$LOG_DIR/reward.txt", "w") as f:
    f.write("%.4f\n" % reward)
print("REWARD=%.4f" % reward)
PYEOF
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjb21tYW5kIC12IHB5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate f2p_upstream_6d076581 'py_compile_changed_generic' 'cd /workspace/desloppify && cd /workspace && python3 -m py_compile /workspace/desloppify/desloppify/core/registry.py /workspace/desloppify/desloppify/engine/scoring_internal/policy/core.py /workspace/desloppify/desloppify/intelligence/narrative/_constants.py /workspace/desloppify/desloppify/languages/framework/generic.py /workspace/desloppify/desloppify/languages/plugin_cxx.py /workspace/desloppify/desloppify/languages/framework/treesitter/_lang_spec.py /workspace/desloppify/desloppify/languages/framework/treesitter/_parser.py /workspace/desloppify/desloppify/languages/framework/treesitter/_normalizer.py /workspace/desloppify/desloppify/languages/framework/treesitter/_extractors.py /workspace/desloppify/desloppify/languages/framework/treesitter/_dep_graph.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"f2p_upstream_6d076581": 0.2, "t1_f2p_generic_lang_refreshes_narrative": 0.08, "t1_f2p_generic_lang_registers_detector": 0.12, "t1_f2p_generic_lang_registers_scoring": 0.12, "t1_f2p_generic_lang_shared_phases": 0.16, "t1_f2p_refresh_detector_tools_inplace": 0.12, "t1_f2p_register_detector": 0.08, "t1_f2p_register_scoring_policy": 0.12}
P2P_GATING = ["p2p_base_imports"]
P2P_REGRESSION = []
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----


exit 0