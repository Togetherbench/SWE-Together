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
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
    echo "  PASS (+$1)  total=$REWARD"
}

fail_check() {
    echo "  FAIL: $1"
}

# Shared helper that exercises the real model_lora_keys_unet code path.
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

def extract_target(val):
    return val[0] if isinstance(val, tuple) else val
PYCFG

echo "=== Verifying ComfyUI Lumina2 LoRA base_model.model key mapping ==="
echo ""

# ─────────────────────────────────────────────────────────────────────
# Test 1 (0.02): lora.py is valid Python (P2P)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 1: lora.py valid Python (0.02) ---"
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
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.02 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 2 (0.03): AST — base_model.model. assignment lives inside Lumina2 block (F2P structural)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 2: base_model.model key_map assignment in Lumina2 block (0.03) ---"
T=$(python3 - << 'PYEOF'
import ast, sys
try:
    with open("/workspace/ComfyUI/comfy/lora.py") as f:
        tree = ast.parse(f.read())
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)

func = next((n for n in ast.walk(tree)
             if isinstance(n, ast.FunctionDef) and n.name == "model_lora_keys_unet"), None)
if not func:
    print("FAIL:no_func"); sys.exit(0)

lumina2 = None
for node in ast.walk(func):
    if isinstance(node, ast.If) and isinstance(node.test, ast.Call):
        t = node.test
        if isinstance(t.func, ast.Name) and t.func.id == "isinstance":
            if len(t.args) >= 2 and "Lumina2" in ast.dump(t.args[1]):
                lumina2 = node; break
if not lumina2:
    print("FAIL:no_lumina2"); sys.exit(0)

found = False
for node in ast.walk(lumina2):
    if isinstance(node, ast.Assign):
        for tgt in node.targets:
            if isinstance(tgt, ast.Subscript):
                # Look for any string constant with base_model.model. in the slice
                for sub in ast.walk(tgt):
                    if isinstance(sub, ast.Constant) and isinstance(sub.value, str) \
                            and "base_model.model." in sub.value:
                        found = True
                        break
                # Also handle f-string / format-call with base_model.model.
                for sub in ast.walk(tgt):
                    if isinstance(sub, ast.Call):
                        for c in ast.walk(sub):
                            if isinstance(c, ast.Constant) and isinstance(c.value, str) \
                                    and "base_model.model." in c.value:
                                found = True
            if found: break
    if found: break
print("PASS" if found else "FAIL:no_assignment")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.03 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 3 (0.05): Behavioral — comfy imports cleanly (P2P)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 3: comfy imports cleanly (0.05) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from lumina2_test_helper import IMPORT_OK, IMPORT_ERR
print("PASS" if IMPORT_OK else f"FAIL:{IMPORT_ERR}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.05 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 4 (0.10): Behavioral — base_model.model.* keys exist in returned key_map (F2P)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 4: base_model.model.* keys exist (0.10) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    if len(bm) == 0:
        print("FAIL:no_base_model_keys")
    elif len(bm) < 5:
        print(f"FAIL:too_few:{len(bm)}")
    else:
        print("PASS")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.10 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 5 (0.15): Behavioral — base_model.model.* count matches transformer.* count (F2P)
# (At least 90% parity — i.e. the prefix is added with the same coverage as the existing prefixes.)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 5: base_model.model.* count >= 90% of transformer.* count (0.15) ---"
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
echo "  Result: $T"
case "$T" in PASS*) add_reward 0.15 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# Test 6 (0.10): Behavioral — base_model.model.layers.0.* keys present (F2P)
# This validates the prefix is correctly stripping/prepending so a real
# PEFT-style key like `base_model.model.layers.0.attention.out.lora_A.weight`
# would map to a valid model parameter.
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 6: base_model.model.layers.0.* keys present (0.10) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    keys0 = [k for k in km if k.startswith("base_model.model.layers.0.")]
    if len(keys0) >= 3:
        print("PASS")
    else:
        print(f"FAIL:count={len(keys0)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.10 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 7 (0.10): Behavioral — base_model.model.layers.1.* keys present (F2P, varied layer)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 7: base_model.model.layers.1.* keys present (0.10) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    keys1 = [k for k in km if k.startswith("base_model.model.layers.1.")]
    if len(keys1) >= 3:
        print("PASS")
    else:
        print(f"FAIL:count={len(keys1)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.10 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 8 (0.15): Behavioral — base_model.model.{X} target equals transformer.{X} target
# (At least 90% match — the prefix is just an alias, must point to the same model param.)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 8: base_model.model.X target == transformer.X target (>=90%) (0.15) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map, extract_target
    km = get_key_map(2)
    matched = 0
    total = 0
    mismatches = []
    for k, v in km.items():
        if k.startswith("base_model.model."):
            suffix = k[len("base_model.model."):]
            tk = "transformer." + suffix
            total += 1
            if tk in km:
                if extract_target(km[tk]) == extract_target(v):
                    matched += 1
                else:
                    mismatches.append((suffix, extract_target(v), extract_target(km[tk])))
    if total == 0:
        print("FAIL:no_base_model_keys")
    else:
        ratio = matched / total
        if ratio >= 0.9:
            print(f"PASS:{matched}/{total}")
        else:
            print(f"FAIL:{matched}/{total}={ratio:.2f}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
case "$T" in PASS*) add_reward 0.15 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# Test 9 (0.10): Behavioral — base_model.model.X target is a real diffusion_model.* string (F2P)
# Catches: "added the key but mapped to garbage / itself / a string constant".
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 9: base_model.model targets resolve to diffusion_model.* (0.10) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map, extract_target
    km = get_key_map(2)
    bm = {k: v for k, v in km.items() if k.startswith("base_model.model.")}
    if not bm:
        print("FAIL:none"); sys.exit(0)
    ok = 0
    bad = 0
    sample_bad = None
    for k, v in bm.items():
        t = extract_target(v)
        if isinstance(t, str) and t.startswith("diffusion_model.") and (t.endswith(".weight") or t.endswith(".bias")):
            ok += 1
        else:
            bad += 1
            if sample_bad is None:
                sample_bad = (k, t)
    ratio = ok / (ok + bad)
    if ratio >= 0.9:
        print(f"PASS:{ok}/{ok+bad}")
    else:
        print(f"FAIL:{ok}/{ok+bad} sample={sample_bad}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
case "$T" in PASS*) add_reward 0.10 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# Test 10 (0.03): Behavioral P2P — transformer.* still present (regression)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 10: transformer.* keys still present (P2P, 0.03) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    tf = [k for k in km if k.startswith("transformer.")]
    print("PASS" if len(tf) >= 5 else f"FAIL:{len(tf)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.03 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 11 (0.03): Behavioral P2P — diffusion_model.* still present (regression)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 11: diffusion_model.* keys still present (P2P, 0.03) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    dm = [k for k in km if k.startswith("diffusion_model.")]
    print("PASS" if len(dm) >= 5 else f"FAIL:{len(dm)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.03 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 12 (0.03): Behavioral P2P — lycoris_* still present (regression)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 12: lycoris_* keys still present (P2P, 0.03) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    ly = [k for k in km if k.startswith("lycoris_")]
    print("PASS" if len(ly) >= 5 else f"FAIL:{len(ly)}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.03 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 13 (0.05): Behavioral F2P — n_layers scaling (more layers => more keys)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 13: n_layers scaling (0.05) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km2 = get_key_map(2)
    km4 = get_key_map(4)
    bm2 = sum(1 for k in km2 if k.startswith("base_model.model."))
    bm4 = sum(1 for k in km4 if k.startswith("base_model.model."))
    if bm2 > 0 and bm4 > bm2:
        print("PASS")
    else:
        print(f"FAIL:bm2={bm2} bm4={bm4}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.05 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 14 (0.04): Behavioral F2P — keys span multiple component types
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 14: base_model.model keys span multiple components (0.04) ---"
T=$($VENV_PY - << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from lumina2_test_helper import get_key_map
    km = get_key_map(2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    # Take 3rd component to identify a "type"
    types = set()
    for k in bm:
        parts = k.split(".")
        if len(parts) >= 4:
            types.add(parts[2] + "." + parts[3] if parts[2] == "layers" else parts[2])
    if len(types) >= 3:
        print(f"PASS:{len(types)}")
    else:
        print(f"FAIL:types={types}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
case "$T" in PASS*) add_reward 0.04 ;; *) fail_check "$T" ;; esac

# ─────────────────────────────────────────────────────────────────────
# Test 15 (0.02): AST — base_model.model RHS matches sibling RHS shape (catches "= 'string'" hack)
# ─────────────────────────────────────────────────────────────────────
echo "--- Test 15: AST — base_model.model RHS shape sane (0.02) ---"
T=$(python3 - << 'PYEOF'
import ast, sys
try:
    with open("/workspace/ComfyUI/comfy/lora.py") as f:
        tree = ast.parse(f.read())
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)

func = next((n for n in ast.walk(tree)
             if isinstance(n, ast.FunctionDef) and n.name == "model_lora_keys_unet"), None)
if not func: print("FAIL:no_func"); sys.exit(0)

lumina2 = None
for node in ast.walk(func):
    if isinstance(node, ast.If) and isinstance(node.test, ast.Call):
        t = node.test
        if isinstance(t.func, ast.Name) and t.func.id == "isinstance":
            if len(t.args) >= 2 and "Lumina2" in ast.dump(t.args[1]):
                lumina2 = node; break
if not lumina2: print("FAIL:no_lumina2"); sys.exit(0)

# Find any assignment to key_map[...base_model.model...] = RHS
# RHS must NOT be a constant string starting with "base_model.model." (i.e. no self-reference)
def has_bmm(node):
    for sub in ast.walk(node):
        if isinstance(sub, ast.Constant) and isinstance(sub.value, str) and "base_model.model." in sub.value:
            return True
    return False

ok = False
for n in ast.walk(lumina2):
    if isinstance(n, ast.Assign) and len(n.targets) == 1:
        tgt = n.targets[0]
        if isinstance(tgt, ast.Subscript) and has_bmm(tgt.slice):
            rhs = n.value
            # RHS is typically `to` (a Name) or `k` (state-dict-loop variant) — not a self-referencing literal
            if isinstance(rhs, ast.Constant) and isinstance(rhs.value, str) and "base_model.model." in rhs.value:
                continue
            ok = True
            break
print("PASS" if ok else "FAIL:rhs_suspicious")
PYEOF
)
echo "  Result: $T"
[ "$T" = "PASS" ] && add_reward 0.02 || fail_check "$T"

# ─────────────────────────────────────────────────────────────────────
# Test 16 (0.03): Functional — simulate a PEFT-style state_dict load