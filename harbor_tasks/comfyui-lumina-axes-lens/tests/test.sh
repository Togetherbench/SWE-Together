#!/usr/bin/env bash
#
# Verification tests for ComfyUI Lumina 2 axes_lens RoPE implementation.
#
# Tests that comfy/ldm/lumina/model.py has been updated to:
#   1. Define a new class (e.g. LuminaEmbedND) that accepts axes_lens
#   2. Implement axes_lens support in the class body (precompute or use in forward)
#   3. Wire NextDiT to use the new class with axes_lens passed through
#
# All tests run on CPU — no GPU required.
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring (behavioral 70%, structural 30%):
#   Test 1:  0.05  model.py parses as valid Python (structural)
#   Test 2:  0.05  a new rope embedder class exists that accepts axes_lens (structural)
#   Test 3:  0.05  new class has real implementation, not a stub (structural/AST)
#   Test 4:  0.10  NextDiT's rope_embedder is instantiated with axes_lens (structural/AST)
#   Test 5:  0.05  rope or precomputation mechanism imported/used (structural)
#   Test 6:  0.10  new class instantiates + forward produces correct-shape output (behavioral/Silver)
#   Test 7:  0.25  forward output numerically matches rope() reference (behavioral/Gold)
#              — EmbedND wrapper detected: 0.10 partial (wrapper delegates, doesn't implement)
#   Test 8:  0.35  axes_lens produces correct precomputed state (behavioral/Gold)
#              — no precomputed state but axes_lens used in computation: 0.15 partial
#              — EmbedND wrapper or axes_lens unused: 0.00
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
MODEL_PY="/workspace/ComfyUI/comfy/ldm/lumina/model.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): model.py parses as valid Python
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/8: model.py parses as valid Python ==="
T1=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py", "r") as f:
    source = f.read()

try:
    ast.parse(source)
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.05): A new rope embedder class exists that accepts axes_lens
# Must have a class (not EmbedND) that accepts axes_lens in __init__
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/8: New rope embedder class accepts axes_lens ==="
T2=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

# Must be a NEW class (NOT EmbedND, NOT NextDiT) that:
# - Accepts axes_lens in __init__
# - Has a forward method (it's a rope embedder, not the whole model)
SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer",
        "TimestepEmbedder", "TransformerBlock", "ModulationOut", "Modulation"}

found_class = None
for node in ast.iter_child_nodes(tree):
    if not isinstance(node, ast.ClassDef):
        continue
    if node.name in SKIP:
        continue
    # Must have both __init__ with axes_lens AND a forward method
    has_axes_lens_init = False
    has_forward = False
    for child in node.body:
        if isinstance(child, ast.FunctionDef) and child.name == "__init__":
            all_params = [a.arg for a in child.args.args] + [a.arg for a in child.args.kwonlyargs]
            if any("axes_lens" in p for p in all_params):
                has_axes_lens_init = True
        if isinstance(child, ast.FunctionDef) and child.name == "forward":
            has_forward = True
    if has_axes_lens_init and has_forward:
        found_class = node.name
        break

if found_class:
    print(f"PASS:{found_class}")
else:
    print("FAIL:no_new_embedder_class_with_axes_lens")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.05): New class has real implementation — not a stub
# Anti-stub: must have >=8 meaningful AST statements in class body
# (a real rope embedder needs loops, tensor ops, register_buffer, etc.)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/8: New class has real implementation (not stub) ==="
T3=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer",
        "TimestepEmbedder", "TransformerBlock", "ModulationOut", "Modulation"}

best_count = 0
best_class = None

for node in ast.iter_child_nodes(tree):
    if not isinstance(node, ast.ClassDef):
        continue
    if node.name in SKIP:
        continue
    class_src = ast.get_source_segment(source, node) or ""
    if "axes_lens" not in class_src:
        continue
    # Must also have a forward method
    has_forward = any(
        isinstance(c, ast.FunctionDef) and c.name == "forward"
        for c in node.body
    )
    if not has_forward:
        continue
    meaningful = sum(
        1 for child in ast.walk(node)
        if isinstance(child, (ast.Assign, ast.AugAssign, ast.AnnAssign,
                               ast.If, ast.For, ast.While, ast.With,
                               ast.Return, ast.Call, ast.FunctionDef))
    )
    if meaningful > best_count:
        best_count = meaningful
        best_class = node.name

if best_class is None:
    print("FAIL:no_axes_lens_class")
elif best_count >= 8:
    print(f"PASS:{best_class}:{best_count}_statements")
else:
    print(f"FAIL:stub:{best_class}:only_{best_count}_statements")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.10): NextDiT's rope_embedder is instantiated with axes_lens
# AST: the call that assigns self.rope_embedder passes axes_lens
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/8: NextDiT passes axes_lens to rope_embedder ==="
T4=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

nextdit = None
for node in ast.iter_child_nodes(tree):
    if isinstance(node, ast.ClassDef) and node.name == "NextDiT":
        nextdit = node
        break

if nextdit is None:
    print("FAIL:no_NextDiT")
    sys.exit(0)

init_node = None
for child in nextdit.body:
    if isinstance(child, ast.FunctionDef) and child.name == "__init__":
        init_node = child
        break

if init_node is None:
    print("FAIL:no_init")
    sys.exit(0)

for node in ast.walk(init_node):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Attribute) and target.attr == "rope_embedder":
                if isinstance(node.value, ast.Call):
                    call_src = ast.get_source_segment(source, node.value) or ""
                    for kw in node.value.keywords:
                        if kw.arg == "axes_lens":
                            print("PASS:axes_lens_kwarg")
                            sys.exit(0)
                    if "axes_lens" in call_src:
                        print("PASS:axes_lens_in_call")
                        sys.exit(0)
                    print("FAIL:rope_embedder_no_axes_lens")
                    sys.exit(0)

print("FAIL:no_rope_embedder_assignment")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.05): Precomputation mechanism exists
# Accepts: rope import, register_buffer usage, or F.embedding usage
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/8: Precomputation mechanism present ==="
T5=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

has_rope_import = any(
    "flux" in (node.module or "") and "math" in (node.module or "") and
    any(a.name == "rope" for a in node.names)
    for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)
)

has_register_buffer = any(
    isinstance(node, ast.Call) and
    isinstance(node.func, ast.Attribute) and node.func.attr == "register_buffer"
    for node in ast.walk(tree)
)

has_f_embedding = any(
    isinstance(node, ast.Call) and
    isinstance(node.func, ast.Attribute) and node.func.attr == "embedding"
    for node in ast.walk(tree)
)

if has_rope_import:
    print("PASS:rope_imported")
elif has_register_buffer:
    print("PASS:register_buffer_used")
elif has_f_embedding:
    print("PASS:F_embedding_used")
else:
    print("FAIL:no_precomputation_mechanism")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.10): New class imports and instantiates on CPU (behavioral/Silver)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/8: New class instantiates successfully on CPU ==="
T6=$(python3 << PYEOF
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")

mock_mm = types.ModuleType("comfy.model_management")
mock_mm.get_torch_device = lambda: torch.device("cpu")
mock_mm.is_device_mps = lambda d: False
mock_mm.is_intel_xpu = lambda: False
mock_mm.is_directml_enabled = lambda: False
mock_mm.is_nvidia = lambda: False
mock_mm.xformers_enabled = lambda: False
mock_mm.pytorch_attention_enabled = lambda: True
mock_mm.flash_attention_enabled = lambda: False
mock_mm.sage_attention_enabled = lambda: False
mock_mm.force_upcast_attention_dtype = lambda: None
mock_mm.OOM_EXCEPTION = Exception
mock_mm.soft_empty_cache = lambda *a, **kw: None
mock_mm.get_free_memory = lambda *a, **kw: 4 * 1024 * 1024 * 1024
mock_mm.throw_exception_if_processing_interrupted = lambda: None
mock_mm.total_vram = 0
mock_mm.total_ram = 8192
mock_mm.cast_to = None
mock_mm.unet_offload_device = lambda: torch.device("cpu")
mock_mm.unet_inital_load_device = lambda *a: torch.device("cpu")
sys.modules["comfy.model_management"] = mock_mm
import comfy
comfy.model_management = mock_mm

try:
    import inspect
    import comfy.ldm.lumina.model as lumina_model

    SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer",
            "TimestepEmbedder", "TransformerBlock", "ModulationOut", "Modulation"}

    candidates = []
    for name, obj in inspect.getmembers(lumina_model, inspect.isclass):
        if name in SKIP:
            continue
        try:
            sig = inspect.signature(obj.__init__)
            if "axes_lens" in sig.parameters:
                candidates.append((name, obj))
        except (ValueError, TypeError):
            pass

    if not candidates:
        print("FAIL:no_class_with_axes_lens")
        sys.exit(0)

    name, cls = candidates[0]
    try:
        instance = cls(dim=32, theta=10000, axes_dim=[8, 8, 16], axes_lens=[10, 20, 20])
    except Exception as e:
        print(f"FAIL:instantiation:{e}")
        sys.exit(0)

    # Behavioral: call forward and verify output shape matches EmbedND reference
    from comfy.ldm.flux.layers import EmbedND
    ref_embedder = EmbedND(dim=32, theta=10000, axes_dim=[8, 8, 16])
    test_ids = torch.zeros(1, 4, 3, dtype=torch.float32)
    test_ids[0, :, 0] = torch.arange(4).float()
    test_ids[0, :, 1] = torch.arange(4).float()
    test_ids[0, :, 2] = torch.arange(4).float()

    try:
        with torch.no_grad():
            out = instance(test_ids)
            ref_out = ref_embedder(test_ids)
    except Exception as e:
        print(f"FAIL:forward_error:{e}")
        sys.exit(0)

    if not isinstance(out, torch.Tensor):
        print(f"FAIL:forward_not_tensor:{type(out)}")
        sys.exit(0)
    if out.shape != ref_out.shape:
        print(f"FAIL:wrong_shape:got={list(out.shape)}:expected={list(ref_out.shape)}")
        sys.exit(0)
    if torch.all(out == 0):
        print(f"FAIL:output_all_zeros")
        sys.exit(0)

    print(f"PASS:{name}")

except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.25): Forward output numerically matches rope() reference
# Gold tier: computes expected output using ComfyUI's rope() function
# and compares numerically. A stub returning zeros/hardcoded shapes
# will fail because the values won't match.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/8: Forward output matches rope() reference (Gold) ==="
T7=$(python3 << PYEOF
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")

mock_mm = types.ModuleType("comfy.model_management")
mock_mm.get_torch_device = lambda: torch.device("cpu")
mock_mm.is_device_mps = lambda d: False
mock_mm.is_intel_xpu = lambda: False
mock_mm.is_directml_enabled = lambda: False
mock_mm.is_nvidia = lambda: False
mock_mm.xformers_enabled = lambda: False
mock_mm.pytorch_attention_enabled = lambda: True
mock_mm.flash_attention_enabled = lambda: False
mock_mm.sage_attention_enabled = lambda: False
mock_mm.force_upcast_attention_dtype = lambda: None
mock_mm.OOM_EXCEPTION = Exception
mock_mm.soft_empty_cache = lambda *a, **kw: None
mock_mm.get_free_memory = lambda *a, **kw: 4 * 1024 * 1024 * 1024
mock_mm.throw_exception_if_processing_interrupted = lambda: None
mock_mm.total_vram = 0
mock_mm.total_ram = 8192
mock_mm.cast_to = None
mock_mm.unet_offload_device = lambda: torch.device("cpu")
mock_mm.unet_inital_load_device = lambda *a: torch.device("cpu")
sys.modules["comfy.model_management"] = mock_mm
import comfy
comfy.model_management = mock_mm

try:
    import inspect
    import comfy.ldm.lumina.model as lumina_model
    from comfy.ldm.flux.layers import EmbedND

    SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer",
            "TimestepEmbedder", "TransformerBlock", "ModulationOut", "Modulation"}

    candidate_cls = None
    candidate_name = None
    for name, obj in inspect.getmembers(lumina_model, inspect.isclass):
        if name in SKIP:
            continue
        try:
            sig = inspect.signature(obj.__init__)
            if "axes_lens" in sig.parameters:
                candidate_cls = obj
                candidate_name = name
                break
        except (ValueError, TypeError):
            pass

    if candidate_cls is None:
        print("FAIL:no_class_with_axes_lens")
        sys.exit(0)

    axes_dim = [8, 8, 16]
    axes_lens = [10, 20, 20]
    theta = 10000
    try:
        instance = candidate_cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=axes_lens)
    except Exception as e:
        print(f"FAIL:instantiation:{e}")
        sys.exit(0)

    # Detect EmbedND wrapper pattern: if the instance contains an EmbedND submodule,
    # it's just delegating rather than implementing axes_lens precomputation.
    is_embed_wrapper = False
    for mod_name, mod in instance.named_modules():
        if mod_name and isinstance(mod, EmbedND):
            is_embed_wrapper = True
            break

    # Create test positions: (batch=1, n_tokens=5, n_axes=3)
    # Integer positions within axes_lens bounds
    ids = torch.zeros(1, 5, 3, dtype=torch.float32)
    ids[0, :, 0] = torch.arange(5).float()
    ids[0, :, 1] = torch.arange(5).float()
    ids[0, :, 2] = torch.arange(5).float()

    try:
        with torch.no_grad():
            out = instance(ids)
    except Exception as e:
        print(f"FAIL:forward_error:{e}")
        sys.exit(0)

    if not isinstance(out, torch.Tensor):
        print(f"FAIL:output_not_tensor:{type(out)}")
        sys.exit(0)

    # Compute reference output using EmbedND (which uses rope() internally)
    # For integer positions, a correct axes_lens implementation should produce
    # the same values as EmbedND since both use the same rope formula
    ref_embedder = EmbedND(dim=32, theta=theta, axes_dim=axes_dim)
    with torch.no_grad():
        ref_out = ref_embedder(ids)

    # Compare shapes first
    if out.shape != ref_out.shape:
        print(f"FAIL:shape_mismatch:got={list(out.shape)}:expected={list(ref_out.shape)}")
        sys.exit(0)

    # Numerical comparison with tolerance for float32/64 differences
    if torch.allclose(out, ref_out, atol=1e-4, rtol=1e-4):
        max_diff = (out - ref_out).abs().max().item()
        if is_embed_wrapper:
            print(f"PARTIAL:{candidate_name}:wrapper_delegates_to_EmbedND:max_diff={max_diff:.2e}")
        else:
            print(f"PASS:{candidate_name}:max_diff={max_diff:.2e}")
    else:
        max_diff = (out - ref_out).abs().max().item()
        mean_diff = (out - ref_out).abs().mean().item()
        print(f"FAIL:values_wrong:max_diff={max_diff:.4f}:mean_diff={mean_diff:.4f}")

except Exception as e:
    import traceback
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.25
elif [[ "$T7" == PARTIAL* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.35): axes_lens produces correct precomputed state
# Gold tier: creates two instances with DIFFERENT axes_lens values,
# verifies that:
#   (a) instance has precomputed state (buffers or tensor attrs)
#   (b) different axes_lens values produce different precomputed state
#   (c) forward output with precomputed state still matches rope() reference
# A stub with register_buffer("x", torch.zeros(1)) fails because
# the buffer won't change with different axes_lens, and forward values
# won't match the reference.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/8: axes_lens precomputed state correctness (Gold) ==="
T8=$(python3 << PYEOF
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")

mock_mm = types.ModuleType("comfy.model_management")
mock_mm.get_torch_device = lambda: torch.device("cpu")
mock_mm.is_device_mps = lambda d: False
mock_mm.is_intel_xpu = lambda: False
mock_mm.is_directml_enabled = lambda: False
mock_mm.is_nvidia = lambda: False
mock_mm.xformers_enabled = lambda: False
mock_mm.pytorch_attention_enabled = lambda: True
mock_mm.flash_attention_enabled = lambda: False
mock_mm.sage_attention_enabled = lambda: False
mock_mm.force_upcast_attention_dtype = lambda: None
mock_mm.OOM_EXCEPTION = Exception
mock_mm.soft_empty_cache = lambda *a, **kw: None
mock_mm.get_free_memory = lambda *a, **kw: 4 * 1024 * 1024 * 1024
mock_mm.throw_exception_if_processing_interrupted = lambda: None
mock_mm.total_vram = 0
mock_mm.total_ram = 8192
mock_mm.cast_to = None
mock_mm.unet_offload_device = lambda: torch.device("cpu")
mock_mm.unet_inital_load_device = lambda *a: torch.device("cpu")
sys.modules["comfy.model_management"] = mock_mm
import comfy
comfy.model_management = mock_mm

try:
    import inspect
    import comfy.ldm.lumina.model as lumina_model
    from comfy.ldm.flux.layers import EmbedND

    SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer",
            "TimestepEmbedder", "TransformerBlock", "ModulationOut", "Modulation"}

    candidate_cls = None
    candidate_name = None
    for name, obj in inspect.getmembers(lumina_model, inspect.isclass):
        if name in SKIP:
            continue
        try:
            sig = inspect.signature(obj.__init__)
            if "axes_lens" in sig.parameters:
                candidate_cls = obj
                candidate_name = name
                break
        except (ValueError, TypeError):
            pass

    if candidate_cls is None:
        print("FAIL:no_class_with_axes_lens")
        sys.exit(0)

    axes_dim = [8, 8, 16]
    theta = 10000

    # --- Part A: create instances with TWO different axes_lens ---
    axes_lens_a = [10, 20, 20]
    axes_lens_b = [5, 10, 10]

    try:
        inst_a = candidate_cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=axes_lens_a)
    except Exception as e:
        print(f"FAIL:instantiation_a:{e}")
        sys.exit(0)
    try:
        inst_b = candidate_cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=axes_lens_b)
    except Exception as e:
        print(f"FAIL:instantiation_b:{e}")
        sys.exit(0)

    # --- Part B: verify precomputed state exists and differs ---
    def get_state(inst):
        """Collect all tensors: buffers + tensor attributes."""
        state = {}
        for k, v in inst.named_buffers():
            state[f"buf:{k}"] = v
        for k, v in vars(inst).items():
            if isinstance(v, torch.Tensor) and k not in ("weight", "bias"):
                state[f"attr:{k}"] = v
        # Also check for nn.ModuleList/submodules with buffers
        for k, v in inst.named_parameters():
            state[f"param:{k}"] = v
        return state

    state_a = get_state(inst_a)
    state_b = get_state(inst_b)

    if len(state_a) == 0 and len(state_b) == 0:
        # No precomputed state at all — but forward might still work correctly
        # via on-the-fly computation that uses axes_lens. Give partial credit
        # only if forward output is correct (verified below).
        has_precomputed = False
    else:
        has_precomputed = True
        # Check that state differs between different axes_lens values
        # (proves axes_lens actually influences precomputation)
        states_differ = False
        for key in state_a:
            if key in state_b:
                if state_a[key].shape != state_b[key].shape:
                    states_differ = True
                    break
                if not torch.allclose(state_a[key].float(), state_b[key].float(), atol=1e-6):
                    states_differ = True
                    break
        if not states_differ and set(state_a.keys()) != set(state_b.keys()):
            states_differ = True

        if not states_differ:
            print("FAIL:precomputed_state_identical_for_different_axes_lens")
            sys.exit(0)

    # --- Part C: verify forward correctness with DIFFERENT position sets ---
    # Use positions that are within the SMALLER axes_lens bounds
    ref_embedder = EmbedND(dim=32, theta=theta, axes_dim=axes_dim)

    # Test set 1: sequential positions
    ids1 = torch.zeros(1, 4, 3, dtype=torch.float32)
    ids1[0, :, 0] = torch.arange(4).float()
    ids1[0, :, 1] = torch.arange(4).float()
    ids1[0, :, 2] = torch.arange(4).float()

    # Test set 2: non-sequential positions (different pattern)
    ids2 = torch.zeros(1, 3, 3, dtype=torch.float32)
    ids2[0, :, 0] = torch.tensor([0.0, 2.0, 4.0])
    ids2[0, :, 1] = torch.tensor([1.0, 3.0, 0.0])
    ids2[0, :, 2] = torch.tensor([0.0, 1.0, 3.0])

    checks_passed = 0
    total_checks = 2

    for label, ids in [("sequential", ids1), ("nonseq", ids2)]:
        try:
            with torch.no_grad():
                out = inst_a(ids)
                ref = ref_embedder(ids)
        except Exception as e:
            print(f"FAIL:forward_{label}:{e}")
            sys.exit(0)

        if out.shape != ref.shape:
            print(f"FAIL:shape_{label}:got={list(out.shape)}:expected={list(ref.shape)}")
            sys.exit(0)

        if torch.allclose(out, ref, atol=1e-4, rtol=1e-4):
            checks_passed += 1
        else:
            max_diff = (out - ref).abs().max().item()
            print(f"FAIL:values_{label}:max_diff={max_diff:.4f}")
            sys.exit(0)

    if checks_passed == total_checks:
        if has_precomputed:
            print(f"PASS:{candidate_name}:precomputed_and_correct")
        else:
            # No precomputed state — check if this is just an EmbedND wrapper
            is_embed_wrapper = False
            for mod_name, mod in inst_a.named_modules():
                if mod_name and isinstance(mod, EmbedND):
                    is_embed_wrapper = True
                    break
            if is_embed_wrapper:
                print(f"FAIL:wrapper_around_EmbedND:{candidate_name}")
            else:
                # Check that axes_lens is actually used in computation,
                # not just stored as an attribute
                import ast as ast_mod
                with open("/workspace/ComfyUI/comfy/ldm/lumina/model.py") as fh:
                    cls_source = fh.read()
                cls_tree = ast_mod.parse(cls_source)
                axes_lens_used = False
                for nd in ast_mod.iter_child_nodes(cls_tree):
                    if isinstance(nd, ast_mod.ClassDef) and nd.name == candidate_name:
                        cls_src = ast_mod.get_source_segment(cls_source, nd) or ""
                        # Count lines referencing axes_lens beyond param def + simple storage
                        refs = [l.strip() for l in cls_src.split('\n')
                                if 'axes_lens' in l
                                and not l.strip().startswith('def ')
                                and 'self.axes_lens=axes_lens' not in l.replace(' ', '')]
                        if len(refs) >= 1:
                            axes_lens_used = True
                        break
                if axes_lens_used:
                    print(f"PARTIAL:{candidate_name}:correct_without_precomputed_state")
                else:
                    print(f"FAIL:axes_lens_stored_but_not_used:{candidate_name}")
    else:
        print(f"FAIL:only_{checks_passed}/{total_checks}_position_sets_correct")

except Exception as e:
    import traceback
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.35
elif [[ "$T8" == PARTIAL* ]]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
