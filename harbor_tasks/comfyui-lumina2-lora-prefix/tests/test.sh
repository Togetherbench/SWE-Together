#!/bin/bash
set +e

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
# F2P 1 (0.25): base_model.model.* keys exist in returned key_map
#   On buggy base: 0 such keys → FAIL.
#   On fix: many such keys → PASS.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 1: base_model.model.* keys present (0.25) ---"
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
case "$T" in PASS*) add_reward 0.25 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 2 (0.25): base_model.model.* coverage is at parity with transformer.*
#   On buggy base: ratio = 0 → FAIL.
#   On fix that adds the prefix in the same loop: ratio ~ 1.0 → PASS.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 2: base_model.model.* count >= 90% of transformer.* count (0.25) ---"
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
case "$T" in PASS*) add_reward 0.25 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 3 (0.25): base_model.model.layers.0.* keys exist
#   Validates that the prefix maps real PEFT-style keys (the example in
#   the user instruction). Fails on base, passes on fix.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 3: base_model.model.layers.0.* keys present (0.25) ---"
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
case "$T" in PASS*) add_reward 0.25 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# F2P 4 (0.25): base_model.model.* keys map to the SAME targets as
# transformer.* keys (i.e. stripping the prefix yields a valid model
# parameter target). This is the strongest behavioral check: confirms
# the prefix is not just present but functionally equivalent to the
# existing transformer.* prefix mapping.
# ─────────────────────────────────────────────────────────────────────
echo "--- F2P 4: base_model.model.<x> -> same target as transformer.<x> (0.25) ---"
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
case "$T" in PASS*) add_reward 0.25 ;; *) fail_check "$T" ;; esac

echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"