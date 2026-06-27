#!/bin/bash
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
LORA_PY="/workspace/ComfyUI/comfy/lora.py"

VENV_PY="/workspace/venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    VENV_PY="python3"
fi

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
    echo "  PASS (+$1)  total=$REWARD"
}

fail_check() {
    echo "  FAIL: $1"
}

emit_gate() {
    local gid="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    mkdir -p /logs/verifier
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$gid" "$passed" "$detail" >> /logs/verifier/gates.json
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────
# GATE A: lora.py is valid Python (P2P regression guard, no reward)
# ─────────────────────────────────────────────────────────────────────
echo "=== Gate A: lora.py syntactically valid Python ==="
T=$(python3 - << 'PYEOF'
import ast
try:
    with open("/workspace/ComfyUI/comfy/lora.py") as f:
        ast.parse(f.read())
    print("PASS")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T"
if [ "$T" != "PASS" ]; then
    echo "  REGRESSION: lora.py has invalid syntax. Reward=0."
    REWARD=0.0
    finish
fi

# Build shared helper
cat > /tmp/lumina2_test_helper.py << 'PYCFG'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
    import comfy.model_base as model_base
    import comfy.lora as lora
    import comfy.utils as comfy_utils
    IMPORT_OK = True
    IMPORT_ERR = None
except Exception as _e:
    IMPORT_OK = False
    IMPORT_ERR = f"{type(_e).__name__}:{_e}"

_cache = {}

class _MockModelConfig:
    def __init__(self, n_layers):
        self.unet_config = {
            "n_layers": n_layers,
            "dim": 64,
            "n_heads": 4,
            "n_refiner_layers": 1,
            "head_dim": 16,
        }

def get_key_map(n_layers=2):
    if not IMPORT_OK:
        raise ImportError(f"comfy import failed: {IMPORT_ERR}")
    if n_layers not in _cache:
        class MockLumina2(model_base.Lumina2):
            def __init__(self):
                pass
            def state_dict(self):
                config = self.model_config.unet_config
                mapping = comfy_utils.z_image_to_diffusers(config, output_prefix="diffusion_model.")
                keys = {}
                for _from_key, to in mapping.items():
                    target = to[0] if isinstance(to, tuple) else to
                    keys[target] = torch.zeros(1)
                return keys
        mock = MockLumina2()
        mock.model_config = _MockModelConfig(n_layers)
        _cache[n_layers] = lora.model_lora_keys_unet(mock, key_map={})
    return _cache[n_layers]
PYCFG

# ─────────────────────────────────────────────────────────────────────
# GATE B: comfy imports cleanly (P2P regression guard, no reward)
# ─────────────────────────────────────────────────────────────────────
echo "=== Gate B: comfy imports cleanly ==="
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from lumina2_test_helper import IMPORT_OK, IMPORT_ERR
print("PASS" if IMPORT_OK else f"FAIL:{IMPORT_ERR}")
PYEOF
)
echo "  $T"
if [ "$T" != "PASS" ]; then
    echo "  REGRESSION: comfy imports failed. Reward=0."
    REWARD=0.0
    finish
fi

# ─────────────────────────────────────────────────────────────────────
# GATE C: baseline transformer.* keys still produced (P2P regression guard)
# This protects against destructive edits that wipe Lumina2 mapping.
# ─────────────────────────────────────────────────────────────────────
echo "=== Gate C: transformer.* keys still produced (regression guard) ==="
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    tf = [k for k in km if k.startswith("transformer.")]
    if len(tf) < 5:
        print(f"FAIL:transformer_keys_too_few:{len(tf)}")
    else:
        print("PASS")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $T"
if [ "$T" != "PASS" ]; then
    echo "  REGRESSION: transformer.* mapping broken. Reward=0."
    REWARD=0.0
    finish
fi

echo ""
echo "=== F2P behavioral checks (all reward sourced here) ==="

# ─────────────────────────────────────────────────────────────────────
# F2P 1 (0.15): base_model.model.* keys exist in returned key_map
#   On buggy base: 0 such keys → FAIL.
#   On fix: many such keys → PASS.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 1: base_model.model.* keys present (0.15) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    if len(bm) < 5:
        print(f"FAIL:too_few:{len(bm)}")
    else:
        print(f"PASS:{len(bm)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $T"
case "$T" in PASS*) add_reward 0.15; emit_gate "f2p_turn1_base_model_keys" true "$T" ;; *) fail_check "$T"; emit_gate "f2p_turn1_base_model_keys" false "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 2 (0.15): base_model.model.* coverage is at parity with transformer.*
#   On buggy base: ratio = 0 → FAIL.
#   On fix that adds the prefix in the same loop: ratio ~ 1.0 → PASS.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 2: base_model.model.* count >= 90% of transformer.* count (0.15) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    tf = [k for k in km if k.startswith("transformer.")]
    if len(tf) == 0:
        print("FAIL:no_transformer_keys")
    else:
        ratio = len(bm) / len(tf)
        if ratio >= 0.9:
            print(f"PASS:{ratio:.2f}")
        else:
            print(f"FAIL:ratio={ratio:.2f} bm={len(bm)} tf={len(tf)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $T"
case "$T" in PASS*) add_reward 0.15; emit_gate "f2p_turn1_coverage_parity" true "$T" ;; *) fail_check "$T"; emit_gate "f2p_turn1_coverage_parity" false "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 3 (0.15): base_model.model.layers.0.* keys exist
#   Validates that the prefix maps real PEFT-style keys (the example in
#   the user instruction). Fails on base, passes on fix.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 3: base_model.model.layers.0.* keys present (0.15) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    keys0 = [k for k in km if k.startswith("base_model.model.layers.0.")]
    if len(keys0) < 3:
        print(f"FAIL:too_few:{len(keys0)}")
    else:
        print(f"PASS:{len(keys0)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $T"
case "$T" in PASS*) add_reward 0.15; emit_gate "f2p_turn1_layers0_keys" true "$T" ;; *) fail_check "$T"; emit_gate "f2p_turn1_layers0_keys" false "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 4 (0.15): base_model.model.* keys map to the SAME targets as
# transformer.* keys (i.e. stripping the prefix yields a valid model
# parameter target). This is the strongest behavioral check: confirms
# the prefix is not just present but functionally equivalent to the
# existing transformer.* prefix mapping.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 4: base_model.model.<x> -> same target as transformer.<x> (0.15) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)

    def extract(v):
        return v[0] if isinstance(v, tuple) else v

    tf_map = {k[len("transformer."):]: extract(v)
              for k, v in km.items() if k.startswith("transformer.")}
    bm_map = {k[len("base_model.model."):]: extract(v)
              for k, v in km.items() if k.startswith("base_model.model.")}

    if not tf_map:
        print("FAIL:no_transformer_keys")
    elif not bm_map:
        print("FAIL:no_base_model_keys")
    else:
        common = set(tf_map.keys()) & set(bm_map.keys())
        if not common:
            print("FAIL:no_overlap")
        else:
            mismatches = [k for k in common if tf_map[k] != bm_map[k]]
            ratio = (len(common) - len(mismatches)) / len(common)
            if ratio >= 0.9 and len(common) >= 5:
                print(f"PASS:overlap={len(common)} match_ratio={ratio:.2f}")
            else:
                print(f"FAIL:overlap={len(common)} mismatches={len(mismatches)} ratio={ratio:.2f}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  $T"
case "$T" in PASS*) add_reward 0.15; emit_gate "f2p_turn1_target_match" true "$T" ;; *) fail_check "$T"; emit_gate "f2p_turn1_target_match" false "$T" ;; esac

echo ""
echo "=== Legacy checks reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
pip3 install --user --break-system-packages ruff 2>/dev/null || true

GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$GATES_FILE")"
# Do NOT truncate here — earlier inline emit_gate calls already wrote verdicts.

# F2P upstream gate 1: behavioral check for Lumina2 base_model.model keys
echo "=== Upstream F2P: Lumina2 base_model.model keys behavioral check ==="
GATE_RESULT=$( cd /workspace/ComfyUI && /workspace/venv/bin/python3 -c "
import sys; sys.path.insert(0, '.')
import comfy.cli_args; comfy.cli_args.args.cpu = True
import comfy.model_base, comfy.lora, comfy.utils
import torch
class MockConfig:
    unet_config = {'n_layers': 2, 'dim': 64, 'n_heads': 4, 'n_refiner_layers': 1, 'head_dim': 16}
class MockLumina2(comfy.model_base.Lumina2):
    def __init__(self): pass
    def state_dict(self):
        mapping = comfy.utils.z_image_to_diffusers(self.model_config.unet_config, output_prefix='diffusion_model.')
        return {(v[0] if isinstance(v, tuple) else v): torch.zeros(1) for _, v in mapping.items()}
mock = MockLumina2()
mock.model_config = MockConfig()
km = comfy.lora.model_lora_keys_unet(mock, key_map={})
bm_keys = [k for k in km if k.startswith('base_model.model.')]
assert len(bm_keys) >= 5, f'Expected base_model.model keys, got {len(bm_keys)}'
print(f'PASS: {len(bm_keys)} base_model.model keys')
" 2>&1 )
GATE_RC=$?
echo "  $GATE_RESULT (rc=$GATE_RC)"
if [ $GATE_RC -eq 0 ]; then
    echo "{\"id\": \"f2p_upstream_lumina2_bm_keys\", \"passed\": true, \"detail\": \"$GATE_RESULT\"}" >> "$GATES_FILE"
else
    echo "{\"id\": \"f2p_upstream_lumina2_bm_keys\", \"passed\": false, \"detail\": \"$GATE_RESULT\"}" >> "$GATES_FILE"
fi

# F2P upstream gate 2: grep structural check
echo "=== Upstream F2P: grep base_model.model key_map assignment ==="
grep -q 'key_map.*base_model\.model.*= to' /workspace/ComfyUI/comfy/lora.py
GATE_RC=$?
if [ $GATE_RC -eq 0 ]; then
    echo "  PASS (rc=$GATE_RC)"
    echo '{"id": "f2p_upstream_grep_bm_to", "passed": true, "detail": "grep matched"}' >> "$GATES_FILE"
else
    echo "  FAIL (rc=$GATE_RC)"
    echo '{"id": "f2p_upstream_grep_bm_to", "passed": false, "detail": "grep no match"}' >> "$GATES_FILE"
fi

# P2P upstream gate 1: AST parse
echo "=== Upstream P2P: lora.py AST parse ==="
AST_RESULT=$( /workspace/venv/bin/python3 -c "import ast; ast.parse(open('/workspace/ComfyUI/comfy/lora.py').read()); print('OK')" 2>&1 )
GATE_RC=$?
echo "  $AST_RESULT (rc=$GATE_RC)"
if [ $GATE_RC -eq 0 ]; then
    echo '{"id": "p2p_upstream_ast_parse", "passed": true, "detail": "AST parse OK"}' >> "$GATES_FILE"
else
    echo "{\"id\": \"p2p_upstream_ast_parse\", \"passed\": false, \"detail\": \"$AST_RESULT\"}" >> "$GATES_FILE"
fi

# P2P upstream gate 2: ruff lint
echo "=== Upstream P2P: ruff lint check ==="
RUFF_BIN="$HOME/.local/bin/ruff"
if [ ! -x "$RUFF_BIN" ]; then
    RUFF_BIN="ruff"
fi
RUFF_RESULT=$( $RUFF_BIN check --no-cache /workspace/ComfyUI/comfy/lora.py 2>&1 )
GATE_RC=$?
echo "  $RUFF_RESULT (rc=$GATE_RC)"
if [ $GATE_RC -eq 0 ]; then
    echo '{"id": "p2p_upstream_ruff", "passed": true, "detail": "ruff passed"}' >> "$GATES_FILE"
else
    echo "{\"id\": \"p2p_upstream_ruff\", \"passed\": false, \"detail\": \"ruff failed\"}" >> "$GATES_FILE"
fi
# ---- end upstream gates ----

# ---- upstream reward tail ----
/workspace/venv/bin/python3 - << 'PYTAIL'
import json, os

WEIGHTS = {"f2p_upstream_lumina2_bm_keys": 0.20, "f2p_upstream_grep_bm_to": 0.20}
P2P_REGRESSION = ["p2p_upstream_ast_parse", "p2p_upstream_ruff"]

verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass

existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
# weighted-replace formula (c8bc168a standard, replaces additive)
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYTAIL

echo ""
echo "=== Final reward (after upstream gates): $(cat /logs/verifier/reward.txt) ==="

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
