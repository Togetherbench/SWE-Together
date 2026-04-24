#!/bin/bash
#
# Verification tests for ComfyUI Lumina2 LoRA base_model.model key mapping.
#
# The fix: add key_map["base_model.model.{}".format(key_lora)] = to
# inside the isinstance(model, comfy.model_base.Lumina2) block in
# comfy/lora.py's model_lora_keys_unet() function.
#
# Scoring (16 tests, total = 1.0):
#   Test 1:  0.01  structural P2P: lora.py valid Python
#   Test 2:  0.04  structural F2P: AST — "base_model.model." in Lumina2 block
#   Test 3:  0.04  structural F2P: AST — key_map assignment with base_model.model
#   Test 4:  0.08  behavioral F2P: base_model.model.* keys exist (n_layers=2)
#   Test 5:  0.15  behavioral F2P: key count ratio >= 90% of transformer.*
#   Test 6:  0.08  behavioral F2P: layer 0 keys present
#   Test 7:  0.08  behavioral F2P: layer 1 keys present (varied layer)
#   Test 8:  0.12  behavioral F2P: >=50% target match with transformer.*
#   Test 9:  0.11  behavioral F2P: >=90% target match (strict)
#   Test 10: 0.01  behavioral P2P: transformer.* keys still present
#   Test 11: 0.01  behavioral P2P: diffusion_model.* keys still present
#   Test 12: 0.01  behavioral P2P: lycoris_* keys still present
#   Test 13: 0.09  behavioral F2P: n_layers=4 produces more keys than n_layers=2
#   Test 14: 0.08  behavioral F2P: keys span >=3 distinct component types
#   Test 15: 0.08  behavioral F2P: diffusion_model.* target consistency
#   Test 16: 0.01  behavioral P2P: upstream ComfyUI unit tests pass (CPU-safe)
#   Test 17: 0.02  structural F2P: AST — base_model.model key_map RHS matches
#                  sibling entries' RHS in the Lumina2 block (catches
#                  "just added a string" shortcut; reward stays capped at 1.0)
#
# P2P: 0.05 (5%) | F2P: 0.95 (95%)
# Nop score: 0.05 (P2P tests only)
# Sum of weights: 1.02, reward capped at 1.0 by add_reward().
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
LORA_PY="/workspace/ComfyUI/comfy/lora.py"
PASS=0
TOTAL=17

# Use venv Python for behavioral tests (has torch installed).
# Fall back to python3 if venv doesn't exist.
VENV_PY="/workspace/venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    VENV_PY="python3"
fi

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
    PASS=$((PASS + 1))
    echo "  PASS (+$1)"
}

fail_check() {
    echo "  FAIL: $1"
}

# ── Shared helper for behavioral tests ──────────────────────────────
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
    model_base = None
    lora = None
    comfy_utils = None

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
                pass  # skip heavy parent __init__
            def state_dict(self):
                # Return realistic native model keys so both diffusers-loop
                # and state-dict-loop implementations produce base_model.model.* keys.
                config = self.model_config.unet_config
                mapping = comfy_utils.z_image_to_diffusers(config, output_prefix="diffusion_model.")
                keys = {}
                for _from_key, to in mapping.items():
                    target = to[0] if isinstance(to, tuple) else to
                    keys[target] = torch.zeros(1)
                return keys
        mock = MockLumina2()
        mock.model_config = _MockModelConfig(n_layers)
        # Pass explicit key_map={} to avoid mutable default argument bug
        # (successive calls would otherwise share and mutate the same dict)
        _cache[n_layers] = lora.model_lora_keys_unet(mock, key_map={})
    return _cache[n_layers]

def extract_target(val):
    """Extract comparable target from key_map value (may be str or tuple)."""
    return val[0] if isinstance(val, tuple) else val
PYCFG

echo "=== Verifying ComfyUI Lumina2 LoRA base_model.model key mapping ==="
echo ""

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.01): P2P — lora.py is valid Python
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 1/$TOTAL: lora.py valid Python ---"
T=$(python3 << 'PYEOF'
import ast
try:
    with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
        ast.parse(f.read())
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
except FileNotFoundError:
    print("FAIL:file_not_found")
PYEOF
)
echo "  Result: $T"
if [ "$T" = "PASS" ]; then add_reward 0.01 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.04): AST — "base_model.model." string constant in Lumina2 block
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 2/$TOTAL: AST — base_model.model. in Lumina2 block ---"
T=$(python3 << 'PYEOF'
import ast, sys

try:
    with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
        tree = ast.parse(f.read())
except (SyntaxError, FileNotFoundError) as e:
    print(f"FAIL:{e}"); sys.exit(0)

# Find model_lora_keys_unet function
func = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "model_lora_keys_unet":
        func = node; break
if not func:
    print("FAIL:no_model_lora_keys_unet"); sys.exit(0)

# Find isinstance(model, ...Lumina2) block
lumina2 = None
for node in ast.walk(func):
    if not isinstance(node, ast.If): continue
    t = node.test
    if not isinstance(t, ast.Call): continue
    if not (isinstance(t.func, ast.Name) and t.func.id == "isinstance"): continue
    if len(t.args) >= 2 and "Lumina2" in ast.dump(t.args[1]):
        lumina2 = node; break
if not lumina2:
    print("FAIL:no_lumina2_isinstance_block"); sys.exit(0)

# Check for "base_model.model." string constant anywhere in the block
for node in ast.walk(lumina2):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if "base_model.model." in node.value:
            print("PASS"); sys.exit(0)
print("FAIL:no_base_model_model_string")
PYEOF
)
echo "  Result: $T"
if [ "$T" = "PASS" ]; then add_reward 0.04 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.04): AST — key_map[...base_model.model...] = ... in Lumina2
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 3/$TOTAL: AST — key_map assignment with base_model.model ---"
T=$(python3 << 'PYEOF'
import ast, sys

try:
    with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
        tree = ast.parse(f.read())
except (SyntaxError, FileNotFoundError) as e:
    print(f"FAIL:{e}"); sys.exit(0)

func = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "model_lora_keys_unet":
        func = node; break
if not func:
    print("FAIL:no_func"); sys.exit(0)

lumina2 = None
for node in ast.walk(func):
    if not isinstance(node, ast.If): continue
    t = node.test
    if isinstance(t, ast.Call) and isinstance(t.func, ast.Name) and t.func.id == "isinstance":
        if len(t.args) >= 2 and "Lumina2" in ast.dump(t.args[1]):
            lumina2 = node; break
if not lumina2:
    print("FAIL:no_lumina2_block"); sys.exit(0)

# Look for key_map[...] = ... where subscript involves base_model.model
for node in ast.walk(lumina2):
    if not isinstance(node, ast.Assign): continue
    for target in node.targets:
        if isinstance(target, ast.Subscript):
            if isinstance(target.value, ast.Name) and target.value.id == "key_map":
                if "base_model.model" in ast.dump(target.slice):
                    print("PASS"); sys.exit(0)
print("FAIL:no_key_map_base_model_assignment")
PYEOF
)
echo "  Result: $T"
if [ "$T" = "PASS" ]; then add_reward 0.04 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.08): F2P — base_model.model.* keys exist with n_layers=2
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 4/$TOTAL: F2P (0.08) — base_model.model.* keys exist ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    if len(bm) > 0:
        print(f"PASS:{len(bm)}_keys")
    else:
        sample = list(km.keys())[:5]
        print(f"FAIL:no_base_model_keys:sample={sample}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.08 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.15): F2P — base_model.model.* count >= 90% of transformer.*
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 5/$TOTAL: F2P (0.15) — key count ratio >= 90% ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    tr = [k for k in km if k.startswith("transformer.")]
    if len(tr) == 0:
        print("FAIL:no_transformer_keys")
    elif len(bm) == 0:
        print("FAIL:no_base_model_keys")
    elif len(bm) >= 0.9 * len(tr):
        print(f"PASS:{len(bm)}/{len(tr)}={len(bm)/len(tr):.2f}")
    else:
        print(f"FAIL:ratio={len(bm)}/{len(tr)}={len(bm)/len(tr):.2f}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.15 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.08): F2P — layer index 0 keys present in base_model.model.*
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 6/$TOTAL: F2P — layer 0 keys present ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    has_layer0 = any(".0." in k for k in bm)
    if has_layer0:
        print("PASS")
    else:
        print(f"FAIL:no_layer_0_keys:sample={bm[:3]}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [ "$T" = "PASS" ]; then add_reward 0.08 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.08): F2P — layer index 1 keys present (varied layer)
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 7/$TOTAL: F2P — layer 1 keys present ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    has_layer1 = any(".1." in k for k in bm)
    if has_layer1:
        print("PASS")
    else:
        print(f"FAIL:no_layer_1_keys:sample={bm[:3]}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [ "$T" = "PASS" ]; then add_reward 0.08 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.12): F2P — >=50% base_model.model.* targets match transformer.*
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 8/$TOTAL: F2P — >=50% target match with transformer.* ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = {k: v for k, v in km.items() if k.startswith("base_model.model.")}
    tr = {k: v for k, v in km.items() if k.startswith("transformer.")}
    if not bm:
        print("FAIL:no_base_model_keys"); raise SystemExit
    if not tr:
        print("FAIL:no_transformer_keys"); raise SystemExit

    matches = 0
    checked = 0
    for bk, bv in bm.items():
        suffix = bk[len("base_model.model."):]
        tk = "transformer." + suffix
        if tk in tr:
            checked += 1
            if extract_target(bv) == extract_target(tr[tk]):
                matches += 1

    if checked == 0:
        print("FAIL:no_overlapping_suffixes")
    elif matches >= 0.5 * checked:
        print(f"PASS:{matches}/{checked}")
    else:
        print(f"FAIL:{matches}/{checked}<50%")
except SystemExit:
    pass
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.12 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.11): F2P — >=90% target match (strict consistency)
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 9/$TOTAL: F2P — >=90% target match (strict) ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = {k: v for k, v in km.items() if k.startswith("base_model.model.")}
    tr = {k: v for k, v in km.items() if k.startswith("transformer.")}
    if not bm:
        print("FAIL:no_base_model_keys"); raise SystemExit
    if not tr:
        print("FAIL:no_transformer_keys"); raise SystemExit

    matches = 0
    checked = 0
    for bk, bv in bm.items():
        suffix = bk[len("base_model.model."):]
        tk = "transformer." + suffix
        if tk in tr:
            checked += 1
            if extract_target(bv) == extract_target(tr[tk]):
                matches += 1

    if checked == 0:
        print("FAIL:no_overlapping_suffixes")
    elif matches >= 0.9 * checked:
        print(f"PASS:{matches}/{checked}")
    else:
        print(f"FAIL:{matches}/{checked}<90%")
except SystemExit:
    pass
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.11 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10 (0.01): P2P — transformer.* keys still present
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 10/$TOTAL: P2P — transformer.* keys present ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    tr = [k for k in km if k.startswith("transformer.")]
    if len(tr) > 0:
        print(f"PASS:{len(tr)}_keys")
    else:
        print("FAIL:no_transformer_keys")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.01 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 11 (0.01): P2P — diffusion_model.* keys still present
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 11/$TOTAL: P2P — diffusion_model.* keys present ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    dm = [k for k in km if k.startswith("diffusion_model.")]
    if len(dm) > 0:
        print(f"PASS:{len(dm)}_keys")
    else:
        print("FAIL:no_diffusion_model_keys")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.01 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 12 (0.01): P2P — lycoris_* keys still present
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 12/$TOTAL: P2P — lycoris_* keys present ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    ly = [k for k in km if k.startswith("lycoris_")]
    if len(ly) > 0:
        print(f"PASS:{len(ly)}_keys")
    else:
        print("FAIL:no_lycoris_keys")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.01 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 13 (0.09): F2P — n_layers=4 produces more base_model.model.* keys
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 13/$TOTAL: F2P — n_layers=4 scaling ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km2 = get_key_map(n_layers=2)
    km4 = get_key_map(n_layers=4)
    bm2 = [k for k in km2 if k.startswith("base_model.model.")]
    bm4 = [k for k in km4 if k.startswith("base_model.model.")]
    if len(bm2) == 0:
        print("FAIL:no_base_model_keys_n2")
    elif len(bm4) == 0:
        print("FAIL:no_base_model_keys_n4")
    elif len(bm4) > len(bm2):
        print(f"PASS:n2={len(bm2)},n4={len(bm4)}")
    else:
        print(f"FAIL:n4={len(bm4)}_not_greater_than_n2={len(bm2)}")
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.09 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 14 (0.10): F2P — keys span >=3 distinct component types
#   Checks that keys aren't all from a single component (e.g., all
#   attention). Looks at the second-to-last key segment.
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 14/$TOTAL: F2P (0.08) — diverse sub-components (>=3 types) ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = [k for k in km if k.startswith("base_model.model.")]
    if len(bm) == 0:
        print("FAIL:no_base_model_keys"); raise SystemExit

    # Extract the second-to-last segment of each key as "component type"
    # e.g., "base_model.model.diffusion_model.layers.0.attention.q" -> "attention"
    components = set()
    for k in bm:
        parts = k.split(".")
        if len(parts) >= 3:
            components.add(parts[-2])  # e.g., "attention", "ff", "norm"

    if len(components) >= 3:
        print(f"PASS:{len(components)}_types:{sorted(components)[:5]}")
    else:
        print(f"FAIL:only_{len(components)}_types:{sorted(components)}")
except SystemExit:
    pass
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.08 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 15 (0.08): F2P — base_model.model.* targets consistent with
#   diffusion_model.* (cross-prefix verification, not just transformer.*)
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 15/$TOTAL: F2P — diffusion_model.* target consistency ---"
T=$($VENV_PY << 'PYEOF'
exec(open("/tmp/lumina2_test_helper.py").read())
try:
    km = get_key_map(n_layers=2)
    bm = {k: v for k, v in km.items() if k.startswith("base_model.model.")}
    dm = {k: v for k, v in km.items() if k.startswith("diffusion_model.")}
    if not bm:
        print("FAIL:no_base_model_keys"); raise SystemExit
    if not dm:
        print("FAIL:no_diffusion_model_keys"); raise SystemExit

    matches = 0
    checked = 0
    for bk, bv in bm.items():
        suffix = bk[len("base_model.model."):]
        dk = "diffusion_model." + suffix
        if dk in dm:
            checked += 1
            if extract_target(bv) == extract_target(dm[dk]):
                matches += 1

    if checked == 0:
        print("FAIL:no_overlapping_suffixes")
    elif matches >= 0.8 * checked:
        print(f"PASS:{matches}/{checked}")
    else:
        print(f"FAIL:{matches}/{checked}")
except SystemExit:
    pass
except Exception as e:
    print(f"ERROR:{type(e).__name__}:{e}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.08 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 16 (0.01): P2P — upstream ComfyUI CPU-safe unit tests
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 16/$TOTAL: P2P — upstream ComfyUI unit tests ---"
cd /workspace/ComfyUI
$VENV_PY -m pytest tests/ -x --timeout=60 -q -k "not cuda and not gpu" --ignore=tests/compare --ignore=tests/execution --ignore=tests/inference 2>/dev/null
PYTEST_EXIT=$?
# Exit 0 = all passed, exit 5 = no tests collected (both are acceptable)
if [ $PYTEST_EXIT -eq 0 ] || [ $PYTEST_EXIT -eq 5 ]; then
    add_reward 0.01
else
    fail_check "upstream tests failed (exit code $PYTEST_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════════
# TEST 17 (0.02): F2P — AST — base_model.model assignment RHS matches a
#   sibling key_map[...] assignment's RHS (e.g., same `to` variable used
#   by transformer./diffusion_model./lycoris_ entries). Guards against a
#   shallow "just added the string" fix that would satisfy Tests 2/3 but
#   assign a wrong value (e.g., None, a literal, or the loop key k) that
#   isn't consistent with the surrounding prefix-stripping pattern.
# ═══════════════════════════════════════════════════════════════════
echo "--- Test 17/$TOTAL: F2P — base_model.model RHS matches sibling key_map value ---"
T=$(python3 << 'PYEOF'
import ast, sys

try:
    with open("/workspace/ComfyUI/comfy/lora.py", "r") as f:
        tree = ast.parse(f.read())
except (SyntaxError, FileNotFoundError) as e:
    print(f"FAIL:{e}"); sys.exit(0)

func = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "model_lora_keys_unet":
        func = node; break
if not func:
    print("FAIL:no_func"); sys.exit(0)

lumina2 = None
for node in ast.walk(func):
    if not isinstance(node, ast.If): continue
    t = node.test
    if isinstance(t, ast.Call) and isinstance(t.func, ast.Name) and t.func.id == "isinstance":
        if len(t.args) >= 2 and "Lumina2" in ast.dump(t.args[1]):
            lumina2 = node; break
if not lumina2:
    print("FAIL:no_lumina2_block"); sys.exit(0)

# Collect key_map[...] = <val> assignments inside the Lumina2 block.
# Split into the base_model.model.* subscript vs. the sibling prefixes.
base_rhs = []
sibling_rhs = []
for node in ast.walk(lumina2):
    if not isinstance(node, ast.Assign): continue
    for target in node.targets:
        if not isinstance(target, ast.Subscript): continue
        if not (isinstance(target.value, ast.Name) and target.value.id == "key_map"): continue
        sl_dump = ast.dump(target.slice)
        rhs_dump = ast.dump(node.value)
        if "base_model.model" in sl_dump:
            base_rhs.append(rhs_dump)
        elif any(p in sl_dump for p in ("transformer.", "diffusion_model.", "lycoris_")):
            sibling_rhs.append(rhs_dump)

if not base_rhs:
    print("FAIL:no_base_model_assign"); sys.exit(0)
if not sibling_rhs:
    print("FAIL:no_sibling_assigns"); sys.exit(0)

# Accept if any base RHS equals any sibling RHS (agent reused same value
# pattern, e.g., `to`), or RHS is a bare Name referencing a mapped target
# (names like to/k/v are all acceptable as long as they match siblings).
for b in base_rhs:
    if b in sibling_rhs:
        print("PASS:rhs_matches_sibling"); sys.exit(0)

print(f"FAIL:rhs_mismatch:base={base_rhs[:1]}:siblings={sibling_rhs[:2]}")
PYEOF
)
echo "  Result: $T"
if [[ "$T" == PASS* ]]; then add_reward 0.02 ; else fail_check "$T"; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Score: $PASS/$TOTAL tests passed"
echo "Reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
