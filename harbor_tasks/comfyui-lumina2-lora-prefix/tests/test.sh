#!/usr/bin/env bash
#
# Verification test for ComfyUI Lumina2 LoRA base_model.model key mapping.
#
# The fix: add key_map["base_model.model.{}".format(key_lora)] = to
# inside the isinstance(model, comfy.model_base.Lumina2) block in
# comfy/lora.py's model_lora_keys_unet() function.
#
# Scoring (total = 1.0, behavioral >= 60%, structural <= 40%):
#   Test 1: 0.05  lora.py parses as valid Python (Bronze/structural)
#   Test 2: 0.10  AST: base_model.model. string in Lumina2 block (Bronze/structural)
#   Test 3: 0.45  Behavioral: mock Lumina2 produces base_model.model.* keys (Gold)
#   Test 4: 0.15  Behavioral: existing keys still present (Silver — regression)
#   Test 5: 0.25  Behavioral: base_model.model.* maps to same targets as transformer.* (Silver)
#
# Structural: 0.15 | Behavioral: 0.85
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
LORA_PY="/workspace/ComfyUI/comfy/lora.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): lora.py parses as valid Python
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/5: lora.py valid Python ==="
T1=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
        source = f.read()
    ast.parse(source)
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
except FileNotFoundError:
    print("FAIL:file_not_found")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.10): AST check — "base_model.model." string literal in
#   Lumina2 isinstance block of model_lora_keys_unet
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/5: AST — base_model.model. in Lumina2 block ==="
T2=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
    source = f.read()

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
    sys.exit(0)

# Find model_lora_keys_unet function
target_func = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "model_lora_keys_unet":
        target_func = node
        break

if target_func is None:
    print("FAIL:no_model_lora_keys_unet")
    sys.exit(0)

# Find isinstance(model, comfy.model_base.Lumina2) block
lumina2_block = None
for node in ast.walk(target_func):
    if not isinstance(node, ast.If):
        continue
    # Look for: isinstance(model, comfy.model_base.Lumina2)
    test = node.test
    if not isinstance(test, ast.Call):
        continue
    if not (isinstance(test.func, ast.Name) and test.func.id == "isinstance"):
        continue
    if len(test.args) < 2:
        continue
    # Check second arg is comfy.model_base.Lumina2 (Attribute chain)
    second_arg = test.args[1]
    arg_str = ast.dump(second_arg)
    if "Lumina2" in arg_str:
        lumina2_block = node
        break

if lumina2_block is None:
    print("FAIL:no_lumina2_isinstance_block")
    sys.exit(0)

# Within the Lumina2 block, look for a Constant string containing "base_model.model."
# used as a subscript target in a key_map assignment
found_base_model_key = False
for node in ast.walk(lumina2_block):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if "base_model.model." in node.value:
            found_base_model_key = True
            break
    # Also check for format strings: "base_model.model.{}".format(...)
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Attribute) and node.func.attr == "format":
            if isinstance(node.func.value, ast.Constant):
                if "base_model.model." in str(node.func.value.value):
                    found_base_model_key = True
                    break

if found_base_model_key:
    print("PASS")
else:
    print("FAIL:no_base_model_model_in_lumina2_block")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.45): Behavioral — mock Lumina2 and call model_lora_keys_unet,
#   verify base_model.model.* keys appear in result
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/5: Behavioral — Lumina2 mock produces base_model.model.* keys ==="
T3=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    # Must set cpu=True before model_management imports, else it tries to init CUDA
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
    import comfy.model_base as model_base
    import comfy.lora as lora

    class MockModelConfig:
        def __init__(self):
            # Minimal Lumina2 unet_config so z_image_to_diffusers returns some keys
            self.unet_config = {
                "n_layers": 2,
                "dim": 64,
                "n_heads": 4,
                "n_refiner_layers": 1,
                "head_dim": 16,
            }

    class MockLumina2(model_base.Lumina2):
        """Minimal mock — bypasses heavy __init__, exposes necessary attrs."""
        def __init__(self):
            pass  # skip parent __init__

        def state_dict(self):
            return {}

    mock = MockLumina2()
    mock.model_config = MockModelConfig()

    key_map = lora.model_lora_keys_unet(mock)

    bm_keys = [k for k in key_map if k.startswith("base_model.model.")]
    tr_keys = [k for k in key_map if k.startswith("transformer.")]

    if len(bm_keys) == 0:
        all_keys_sample = list(key_map.keys())[:5]
        print(f"FAIL:no_base_model_keys:sample={all_keys_sample}")
    elif len(tr_keys) == 0:
        print(f"FAIL:no_transformer_keys_for_comparison")
    elif len(bm_keys) < 0.8 * len(tr_keys):
        # Reject stub solutions that add a few dummy keys instead of the real mapping
        print(f"FAIL:too_few_keys:{len(bm_keys)}_vs_{len(tr_keys)}_transformer")
    else:
        print(f"PASS:{len(bm_keys)}_keys")

except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.45; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.15): Behavioral — existing key formats still present
#   (transformer.*, diffusion_model.*, lycoris_*)
#   Regression: adding base_model.model.* must not break existing mappings
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/5: Behavioral — existing key formats still present ==="
T4=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
    import comfy.model_base as model_base
    import comfy.lora as lora

    class MockModelConfig:
        def __init__(self):
            self.unet_config = {
                "n_layers": 2,
                "dim": 64,
                "n_heads": 4,
                "n_refiner_layers": 1,
                "head_dim": 16,
            }

    class MockLumina2(model_base.Lumina2):
        def __init__(self):
            pass

        def state_dict(self):
            return {}

    mock = MockLumina2()
    mock.model_config = MockModelConfig()

    key_map = lora.model_lora_keys_unet(mock)

    has_transformer = any(k.startswith("transformer.") for k in key_map)
    has_diffusion = any(k.startswith("diffusion_model.") for k in key_map)
    has_lycoris = any(k.startswith("lycoris_") for k in key_map)

    if has_transformer and has_diffusion and has_lycoris:
        print("PASS")
    else:
        missing = []
        if not has_transformer: missing.append("transformer.*")
        if not has_diffusion: missing.append("diffusion_model.*")
        if not has_lycoris: missing.append("lycoris_*")
        print(f"FAIL:missing={missing}")

except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.25): Behavioral — base_model.model.X maps to same target
#   as transformer.X (both must map to the same diffusion_model.* key)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/5: Behavioral — base_model.model.X and transformer.X agree ==="
T5=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
    import comfy.model_base as model_base
    import comfy.lora as lora

    class MockModelConfig:
        def __init__(self):
            self.unet_config = {
                "n_layers": 2,
                "dim": 64,
                "n_heads": 4,
                "n_refiner_layers": 1,
                "head_dim": 16,
            }

    class MockLumina2(model_base.Lumina2):
        def __init__(self):
            pass

        def state_dict(self):
            return {}

    mock = MockLumina2()
    mock.model_config = MockModelConfig()

    key_map = lora.model_lora_keys_unet(mock)

    bm_keys = {k: v for k, v in key_map.items() if k.startswith("base_model.model.")}
    tr_keys = {k: v for k, v in key_map.items() if k.startswith("transformer.")}

    if not bm_keys:
        print("FAIL:no_base_model_keys")
        sys.exit(0)

    if not tr_keys:
        print("FAIL:no_transformer_keys")
        sys.exit(0)

    # For each base_model.model.X key, check transformer.X maps to same value
    mismatches = []
    matches = 0
    for bm_key, bm_val in bm_keys.items():
        # bm_key = "base_model.model.layers.0...."
        # tr_key = "transformer.layers.0...."
        suffix = bm_key[len("base_model.model."):]
        tr_key = "transformer." + suffix
        if tr_key in tr_keys:
            # Compare targets (may be string or tuple with slice info)
            bm_target = bm_val[0] if isinstance(bm_val, tuple) else bm_val
            tr_target = tr_keys[tr_key][0] if isinstance(tr_keys[tr_key], tuple) else tr_keys[tr_key]
            if bm_target == tr_target:
                matches += 1
            else:
                mismatches.append(f"{bm_key}:{bm_target}!={tr_target}")

    if matches > 0 and not mismatches:
        print(f"PASS:{matches}_consistent_mappings")
    elif matches > 0:
        print(f"FAIL:mismatches={mismatches[:3]}")
    else:
        # No overlapping keys — maybe the key_lora suffix differs between formats
        # Fall back: just verify the VALUES of base_model.model.* are a subset of
        # the values produced by transformer.* (same targets, different key names)
        bm_targets = set()
        for v in bm_keys.values():
            bm_targets.add(v[0] if isinstance(v, tuple) else v)
        tr_targets = set()
        for v in tr_keys.values():
            tr_targets.add(v[0] if isinstance(v, tuple) else v)
        overlap = bm_targets & tr_targets
        if len(overlap) > 0:
            print(f"PASS:shared_targets={len(overlap)}")
        else:
            print(f"FAIL:no_shared_targets:bm_sample={list(bm_targets)[:3]},tr_sample={list(tr_targets)[:3]}")

except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.25; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
