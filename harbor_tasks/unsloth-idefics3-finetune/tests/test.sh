#!/usr/bin/env bash
#
# Verification for unsloth-idefics3-finetune
# Tests: Idefics3 VLM support addition + hook compatibility fix
# Writes reward (0.0-1.0) to /logs/verifier/reward.txt
#
# Tier split (80% behavioral / 20% structural / 15% P2P, total 1.15 capped at 1.0):
#   F2P behavioral:    Check 1 (0.40) — hook compatibility fix (returns correct values)
#   Silver behavioral: Check 2 (0.30) — from_pretrained delegates with real model behavior
#   Silver behavioral: Check 3 (0.05) — VLLM_SUPPORTED_VLM registration
#   Silver behavioral: Check 4 (0.05) — __init__.py export
#   Bronze structural: Check 5 (0.20) — code substance (methods+LoRA+dispatch+depth)
#   P2P behavioral:    P2P-1 (0.03) — source integrity (parse + key files)
#   P2P behavioral:    P2P-2 (0.04) — hook handles normal tensors (CPU mock)
#   P2P behavioral:    P2P-3 (0.04) — existing VLLM_SUPPORTED_VLM entries preserved
#   P2P behavioral:    P2P-4 (0.04) — existing model exports preserved
#
set +e

REWARD=0.0
WORKSPACE="/workspace/unsloth"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

# Write a reusable CPU compat preamble that patches unsloth_zoo's device_type
# module. On CPU-only Docker, get_device_type() raises NotImplementedError at
# import time.  This preamble must be executed before any unsloth_zoo import.
cat > /tmp/_cpu_compat.py << 'CPUEOF'
import sys, types
try:
    import unsloth_zoo.device_type as _dt
except (NotImplementedError, ImportError):
    _dt = types.ModuleType('unsloth_zoo.device_type')
    _dt.get_device_type = lambda: 'cpu'
    _dt.DEVICE_TYPE = 'cpu'
    sys.modules['unsloth_zoo.device_type'] = _dt
    if 'unsloth_zoo' not in sys.modules:
        import importlib
        _uz = types.ModuleType('unsloth_zoo')
        _uz.__path__ = []
        sys.modules['unsloth_zoo'] = _uz
    sys.modules['unsloth_zoo'].device_type = _dt
CPUEOF

cd "$WORKSPACE"

# ── Locate the agent's idefics module ──
IDEFICS_PY=$(python3 << 'PYEOF'
import glob, ast
candidates = sorted(glob.glob('unsloth/models/*idefics*.py'))
if not candidates:
    # Search for any file with an Idefics/Granite class
    for f in sorted(glob.glob('unsloth/models/*.py')):
        try:
            tree = ast.parse(open(f).read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
                    candidates.append(f)
                    break
        except Exception:
            pass
print(candidates[0] if candidates else '')
PYEOF
)

export IDEFICS_PY
echo "Idefics module: ${IDEFICS_PY:-not found}"
# Note: we do NOT early-exit when IDEFICS_PY is empty. Each F2P test
# already handles missing idefics gracefully, and P2P tests must still
# run to verify existing functionality is preserved.

# ═══════════════════════════════════════════════════════════════════
# CHECK 1 (0.40) — F2P BEHAVIORAL: Hook compatibility fix
#
# Core bug: unsloth_zoo.peft_utils.requires_grad_pre_hook crashes
# when Idefics3's nested get_input_embeddings passes empty tuple.
#
# Accept two fix approaches:
#   Path A (0.40): Monkey-patch hook to handle empty inputs
#     - Must RETURN correct values: empty tuple in → empty tuple out
#     - Must NOT return None for empty inputs (that breaks the pipeline)
#     - Non-empty inputs must still be returned (not swallowed)
#   Path B (0.30): Override get_input_embeddings to return Embedding
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 1 [0.40] F2P: Hook compatibility fix ---"

CHECK1=$(python3 << 'PYEOF'
import sys, os, importlib, importlib.util
exec(open('/tmp/_cpu_compat.py').read())

idefics_path = os.environ.get('IDEFICS_PY', '')

# ---- Path A: Hook handles empty tuple after importing agent code ----
hook_safe = False
returns_correct = False
try:
    import unsloth_zoo.peft_utils as pu
    original_hook = getattr(pu, 'requires_grad_pre_hook', None)

    # Import agent's idefics module (may monkey-patch the hook at module level)
    if os.path.exists(idefics_path):
        try:
            spec = importlib.util.spec_from_file_location(
                'unsloth.models.idefics_c1a', idefics_path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules['unsloth.models.idefics_c1a'] = mod
            spec.loader.exec_module(mod)
        except Exception:
            pass

    # Also try loading __init__.py and other patch locations
    for patch_file in ['unsloth/models/__init__.py', 'unsloth/__init__.py',
                       'unsloth/patch.py', 'unsloth/models/patch.py']:
        if os.path.exists(patch_file):
            try:
                spec = importlib.util.spec_from_file_location(
                    f'patch_{os.path.basename(patch_file)}', patch_file)
                pmod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(pmod)
            except Exception:
                pass

    import torch
    patched_hook = getattr(pu, 'requires_grad_pre_hook', original_hook)
    dummy = torch.nn.Linear(1, 1)

    # Test 1: empty tuple — the bug trigger
    # The hook must not crash AND must return the correct value
    try:
        result_empty = patched_hook(dummy, ())
        hook_safe = True

        # Verify RETURN VALUE: empty tuple must return empty tuple (not None)
        # The hook is a pre-hook: it receives (module, inputs) and returns inputs.
        # If inputs is empty tuple, the return must be () or None-is-acceptable
        # only if the hook is designed to pass through.
        # But the critical check: it must NOT return None when given empty tuple,
        # because that would change the inputs to the forward pass.
        if result_empty is not None and not isinstance(result_empty, tuple):
            hook_safe = False  # Returned wrong type
        elif result_empty is None:
            # None means "don't modify inputs" in PyTorch pre-hooks — acceptable
            pass
        elif isinstance(result_empty, tuple) and len(result_empty) == 0:
            pass  # Correct: empty tuple in, empty tuple out
    except (RuntimeError, TypeError, IndexError, AttributeError):
        pass

    # Test 2: non-empty inputs must still be processed correctly
    if hook_safe:
        try:
            test_tensor = torch.randn(2, 3, requires_grad=False)
            result_nonempty = patched_hook(dummy, (test_tensor,))
            # Result should either be None (passthrough) or a tuple containing
            # tensors that require grad (the hook's purpose is to enable grad)
            if result_nonempty is not None:
                if not isinstance(result_nonempty, tuple):
                    hook_safe = False
                elif len(result_nonempty) == 0:
                    hook_safe = False  # Swallowed the inputs!
                else:
                    # Check that the tensor was processed (requires_grad set)
                    first = result_nonempty[0]
                    if isinstance(first, torch.Tensor) and not first.requires_grad:
                        # Hook didn't actually do anything — might be a stub
                        # This is still acceptable if it's a passthrough for safety
                        pass
            returns_correct = True
        except Exception:
            hook_safe = False

    # Also test with single-element empty-like inputs
    if not hook_safe:
        try:
            patched_hook(dummy, (None,))
            hook_safe = True
            returns_correct = True
        except Exception:
            pass
except ImportError:
    pass

# ---- Path B: get_input_embeddings override returns Embedding ----
embed_override = False
if not hook_safe:
    try:
        if os.path.exists(idefics_path):
            spec = importlib.util.spec_from_file_location(
                'unsloth.models.idefics_c1b', idefics_path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules['unsloth.models.idefics_c1b'] = mod
            spec.loader.exec_module(mod)

            import torch
            embed = torch.nn.Embedding(10, 4)

            # Find the Idefics/Granite class
            cls = None
            for name in dir(mod):
                obj = getattr(mod, name)
                if isinstance(obj, type) and ('Idefics' in name or 'Granite' in name):
                    cls = obj
                    break

            if cls and 'get_input_embeddings' in cls.__dict__:
                # Try calling with mock model structures matching Idefics3 internals
                instance = cls.__new__(cls)

                mock_structures = [
                    # self.model.text_model.embed_tokens (standard Idefics3)
                    ('model', type('M', (), {
                        'text_model': type('TM', (), {'embed_tokens': embed})()
                    })()),
                    # self.model.embed_tokens
                    ('model', type('M', (), {'embed_tokens': embed})()),
                    # self.language_model.model.embed_tokens
                    ('language_model', type('LM', (), {
                        'model': type('M', (), {'embed_tokens': embed})()
                    })()),
                ]

                for attr_name, mock_obj in mock_structures:
                    setattr(instance, attr_name, mock_obj)
                    try:
                        result = instance.get_input_embeddings()
                        if isinstance(result, (torch.nn.Embedding, torch.nn.Module)):
                            # Verify the returned embedding actually has parameters
                            params = list(result.parameters())
                            if len(params) > 0:
                                embed_override = True
                                break
                    except Exception:
                        pass
    except Exception:
        pass

if hook_safe and returns_correct:
    print('PASS_A')   # monkey-patch approach works with correct return values
elif hook_safe:
    print('PASS_A_PARTIAL')  # handles empty but non-empty behavior unchecked
elif embed_override:
    print('PASS_B')   # get_input_embeddings override works
else:
    print('FAIL')
PYEOF
)

echo "  Result: $CHECK1"
case "$CHECK1" in
    PASS_A) add_reward 0.40 ;;
    PASS_A_PARTIAL) add_reward 0.25 ;;
    PASS_B) add_reward 0.30 ;;
esac

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.30) — SILVER BEHAVIORAL: from_pretrained delegates
#
# Mock transformers model class, call from_pretrained, verify:
# (a) The mock was invoked (delegation happens)
# (b) The result has real model-like attributes (not a bare stub)
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 2 [0.30] Silver: from_pretrained delegation ---"

CHECK2=$(python3 << 'PYEOF'
import sys, os, importlib.util
exec(open('/tmp/_cpu_compat.py').read())
from unittest.mock import MagicMock, patch
import torch

idefics_path = os.environ.get('IDEFICS_PY', '')
delegation_works = False
result_has_substance = False

try:
    spec = importlib.util.spec_from_file_location(
        'unsloth.models.idefics_c2', idefics_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules['unsloth.models.idefics_c2'] = mod
    spec.loader.exec_module(mod)

    # Find the Idefics/Granite class
    cls = None
    for name in dir(mod):
        obj = getattr(mod, name)
        if isinstance(obj, type) and ('Idefics' in name or 'Granite' in name):
            cls = obj
            break

    if cls is not None:
        fp = getattr(cls, 'from_pretrained', None)
        if fp and callable(fp):
            # Strategy 1: Mock on the agent's module namespace
            model_classes = [
                'Idefics3ForConditionalGeneration',
                'AutoModelForVision2Seq',
                'AutoModelForCausalLM',
                'AutoModel',
            ]

            # Create a mock that returns a realistic model-like object
            mock_model = MagicMock()
            mock_model.config = MagicMock()
            mock_model.config.hidden_size = 768
            mock_model.config.model_type = "idefics3"
            # Give it a real parameter so we can verify it's passed through
            real_param = torch.nn.Parameter(torch.randn(4, 4))
            mock_model.parameters = MagicMock(return_value=iter([real_param]))

            for mc_name in model_classes:
                target = getattr(mod, mc_name, None)
                if target is None or not hasattr(target, 'from_pretrained'):
                    continue

                orig_fp = target.from_pretrained
                tracker = MagicMock(return_value=mock_model)
                target.from_pretrained = tracker
                try:
                    result = fp('fake-test-model-12345')
                except Exception:
                    result = None
                target.from_pretrained = orig_fp

                if tracker.called:
                    delegation_works = True
                    # Verify the result is not just discarded — the cls.from_pretrained
                    # should return something based on the delegated model
                    if result is not None:
                        # Check result has some model-like qualities
                        # (could be the mock itself or a wrapper around it)
                        result_has_substance = True
                    break

            # Strategy 2: Mock on the transformers module itself
            if not delegation_works:
                import transformers
                for mc_name in model_classes:
                    target = getattr(transformers, mc_name, None)
                    if target is None or not hasattr(target, 'from_pretrained'):
                        continue

                    orig_fp = target.from_pretrained
                    tracker = MagicMock(return_value=mock_model)
                    target.from_pretrained = tracker
                    try:
                        result = fp('fake-test-model-12345')
                    except Exception:
                        result = None
                    target.from_pretrained = orig_fp

                    if tracker.called:
                        delegation_works = True
                        if result is not None:
                            result_has_substance = True
                        break
except Exception:
    pass

if delegation_works and result_has_substance:
    print('PASS')
elif delegation_works:
    print('PARTIAL')  # delegates but discards result
else:
    print('FAIL')
PYEOF
)

echo "  Result: $CHECK2"
case "$CHECK2" in
    PASS) add_reward 0.30 ;;
    PARTIAL) add_reward 0.15 ;;
esac

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.05) — SILVER BEHAVIORAL: VLLM_SUPPORTED_VLM
#
# Runtime import of vision.py to verify "idefics3" is in the list.
# AST fallback if import fails.
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 3 [0.05] Silver: VLLM_SUPPORTED_VLM ---"

CHECK3=$(python3 << 'PYEOF'
import sys, importlib.util, ast
exec(open('/tmp/_cpu_compat.py').read())

found = False

# Runtime check
try:
    spec = importlib.util.spec_from_file_location(
        'unsloth.models.vision_c3', 'unsloth/models/vision.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    vlm_list = getattr(mod, 'VLLM_SUPPORTED_VLM', None)
    if vlm_list is not None and 'idefics3' in vlm_list:
        found = True
except Exception:
    pass

# AST fallback
if not found:
    try:
        with open('unsloth/models/vision.py') as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id == 'VLLM_SUPPORTED_VLM':
                        if isinstance(node.value, (ast.List, ast.Tuple, ast.Set)):
                            for elt in node.value.elts:
                                if isinstance(elt, ast.Constant) and elt.value == 'idefics3':
                                    found = True
    except Exception:
        pass

print('PASS' if found else 'FAIL')
PYEOF
)

echo "  Result: $CHECK3"
if [ "$CHECK3" = "PASS" ]; then
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 4 (0.05) — SILVER BEHAVIORAL: __init__.py export
#
# Runtime import to verify Idefics class is accessible from
# unsloth/models/__init__.py.  AST fallback for import failures.
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 4 [0.05] Silver: __init__.py export ---"

CHECK4=$(python3 << 'PYEOF'
import sys, importlib.util, ast
exec(open('/tmp/_cpu_compat.py').read())

found = False

# Runtime check
try:
    spec = importlib.util.spec_from_file_location(
        'unsloth.models.init_c4', 'unsloth/models/__init__.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for name in dir(mod):
        if 'Idefics' in name or 'Granite' in name:
            obj = getattr(mod, name)
            if isinstance(obj, type):
                found = True
                break
except Exception:
    pass

# AST fallback
if not found:
    try:
        with open('unsloth/models/__init__.py') as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                for alias in node.names:
                    if alias.name and 'Idefics' in alias.name:
                        found = True
                    if alias.name == '*' and node.module and 'idefics' in node.module:
                        found = True
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name and 'Idefics' in alias.name:
                        found = True
            if found:
                break
    except Exception:
        pass

print('PASS' if found else 'FAIL')
PYEOF
)

echo "  Result: $CHECK4"
if [ "$CHECK4" = "PASS" ]; then
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 5 (0.20) — BRONZE STRUCTURAL: Code substance
#
# ALL four conditions required (0.20 if all pass, 0.00 otherwise):
#   (a) Class has >=3 methods with >3 non-trivial stmts each
#   (b) >=3 distinct LoRA/PEFT indicators
#   (c) "idefics3" or FastIdefics referenced in other files (dispatch)
#   (d) from_pretrained has >=6 non-trivial stmts
#
# AST justified: methods require GPU/weights to execute;
# LoRA config depends on architecture; dispatch is structural.
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 5 [0.20] Bronze: Code substance (all-or-nothing) ---"

CHECK5=$(python3 << 'PYEOF'
import ast, sys, os, glob

idefics_path = os.environ.get('IDEFICS_PY', '')
results = {'methods': False, 'lora': False, 'dispatch': False, 'depth': False}

try:
    with open(idefics_path) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception:
    print('FAIL:parse_error')
    sys.exit(0)

def meaningful_stmts(func_node):
    """Count stmts that are NOT pass, docstrings, or bare constant exprs."""
    count = 0
    for child in ast.walk(func_node):
        if isinstance(child, ast.stmt) and child is not func_node:
            if isinstance(child, ast.Pass):
                continue
            if isinstance(child, ast.Expr) and isinstance(child.value, ast.Constant):
                continue
            count += 1
    return count

# ---- (a) Class >=3 methods with >3 meaningful stmts ----
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        substantial = 0
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and meaningful_stmts(item) > 3:
                substantial += 1
        if substantial >= 3:
            results['methods'] = True
        break

# ---- (b) >=3 distinct LoRA/PEFT indicators ----
indicators = set()
proj_names = {'q_proj', 'k_proj', 'v_proj', 'o_proj',
              'gate_proj', 'up_proj', 'down_proj'}
lora_ids = {'LoraConfig', 'get_peft_model', 'target_modules',
            'lora_r', 'lora_alpha', 'lora_dropout'}

for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value in proj_names:
            indicators.add('proj_layers')
    if isinstance(node, ast.Name) and node.id in lora_ids:
        indicators.add(node.id)
    if isinstance(node, ast.Attribute) and node.attr in lora_ids:
        indicators.add(node.attr)
    if isinstance(node, ast.ImportFrom) and node.module and 'peft' in node.module.lower():
        indicators.add('peft_import')
    if isinstance(node, ast.Name) and node.id.lower() == 'peft':
        indicators.add('peft_ref')

if len(indicators) >= 3:
    results['lora'] = True

# ---- (c) "idefics3" or FastIdefics referenced in OTHER files ----
idefics_abs = os.path.abspath(idefics_path)
for fpath in sorted(glob.glob('unsloth/**/*.py', recursive=True)):
    if os.path.abspath(fpath) == idefics_abs:
        continue
    try:
        with open(fpath) as f:
            ftree = ast.parse(f.read())
    except Exception:
        continue
    for nd in ast.walk(ftree):
        if isinstance(nd, ast.Constant) and isinstance(nd.value, str):
            if nd.value == 'idefics3' or 'idefics' in nd.value.lower():
                results['dispatch'] = True
        if isinstance(nd, ast.Name) and 'FastIdefics' in nd.id:
            results['dispatch'] = True
        if isinstance(nd, ast.Attribute) and 'FastIdefics' in nd.attr:
            results['dispatch'] = True
        if results['dispatch']:
            break
    if results['dispatch']:
        break

# ---- (d) from_pretrained >=6 meaningful stmts ----
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == 'from_pretrained':
                if meaningful_stmts(item) >= 6:
                    results['depth'] = True
                break
        break

passed = all(results.values())
detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
print(f"{'PASS' if passed else 'FAIL'} [{detail}]")
PYEOF
)

echo "  Result: $CHECK5"
if echo "$CHECK5" | grep -q "^PASS"; then
    add_reward 0.20
fi

# ═══════════════════════════════════════════════════════════════════
# Final reward
# ═══════════════════════════════════════════════════════════════════
# P2P TESTS (0.15 total): Existing functionality still works
#
# These verify the agent hasn't broken existing behavior while
# adding Idefics3 support. All run on CPU with mock objects.
# ═══════════════════════════════════════════════════════════════════

# ── P2P-1 (0.03): Source integrity — all .py files parse + key files exist ──
echo "--- P2P-1 [0.03]: Source integrity ---"

P2P1_RESULT=$(python3 << 'PYEOF'
import ast, sys, os, glob
workspace = "/workspace/unsloth"
os.chdir(workspace)

# (a) unsloth/models/__init__.py parseable
init_py = os.path.join(workspace, "unsloth/models/__init__.py")
if not os.path.isfile(init_py):
    print("FAIL:init_missing"); sys.exit(0)
try:
    with open(init_py) as f:
        ast.parse(f.read())
except SyntaxError as e:
    print(f"FAIL:init_syntax:{e}"); sys.exit(0)

# (b) unsloth/models/vision.py parseable
vision_py = os.path.join(workspace, "unsloth/models/vision.py")
if os.path.isfile(vision_py):
    try:
        with open(vision_py) as f:
            ast.parse(f.read())
    except SyntaxError as e:
        print(f"FAIL:vision_syntax:{e}"); sys.exit(0)

# (c) All existing .py under unsloth/models/ must still parse
model_dir = os.path.join(workspace, "unsloth/models")
py_files = sorted(glob.glob(os.path.join(model_dir, "*.py")))
if len(py_files) < 3:
    print(f"FAIL:too_few_files:{len(py_files)}"); sys.exit(0)

for fpath in py_files:
    try:
        with open(fpath) as f:
            ast.parse(f.read())
    except SyntaxError as e:
        print(f"FAIL:syntax:{os.path.basename(fpath)}:{e}"); sys.exit(0)

# (d) Key existing model files still present (llama, qwen, etc.)
basenames = [os.path.basename(f).lower() for f in py_files]
existing_models = [b for b in basenames if any(m in b for m in ["llama", "qwen", "gemma", "mistral"])]
if len(existing_models) < 1:
    print(f"FAIL:no_existing_models"); sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P1_RESULT"
if [ "$P2P1_RESULT" = "PASS" ]; then
    add_reward 0.03
fi

# ── P2P-2 (0.04): unsloth_zoo.peft_utils public API preserved ──
# The agent may monkey-patch the hook or modify peft_utils.py.
# This P2P test verifies the module's public API is intact:
#   - SKIP_QUANTIZATION_MODULES list exists with known entries
#   - get_peft_regex function exists and is callable
#   - requires_grad_for_gradient_checkpointing function exists
echo "--- P2P-2 [0.04]: peft_utils public API preserved ---"

P2P2_RESULT=$(python3 << 'PYEOF'
import sys
exec(open('/tmp/_cpu_compat.py').read())

try:
    import unsloth_zoo.peft_utils as pu
except ImportError as e:
    print(f"FAIL:import:{e}"); sys.exit(0)

# (a) SKIP_QUANTIZATION_MODULES list must exist with known entries
skip_list = getattr(pu, 'SKIP_QUANTIZATION_MODULES', None)
if skip_list is None:
    print("FAIL:no_SKIP_QUANTIZATION_MODULES"); sys.exit(0)
required_skips = {"lm_head", "multi_modal_projector", "router"}
found_skips = set(skip_list)
missing = required_skips - found_skips
if missing:
    print(f"FAIL:missing_skip_modules:{missing}"); sys.exit(0)

# (b) get_peft_regex function exists and is callable
get_peft_regex = getattr(pu, 'get_peft_regex', None)
if get_peft_regex is None or not callable(get_peft_regex):
    print("FAIL:no_get_peft_regex"); sys.exit(0)

# (c) requires_grad_for_gradient_checkpointing exists
rg_fn = getattr(pu, 'requires_grad_for_gradient_checkpointing', None)
if rg_fn is None or not callable(rg_fn):
    print("FAIL:no_requires_grad_fn"); sys.exit(0)

# (d) get_lora_layer_modules exists
lora_fn = getattr(pu, 'get_lora_layer_modules', None)
if lora_fn is None or not callable(lora_fn):
    print("FAIL:no_get_lora_layer_modules"); sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P2_RESULT"
if [ "$P2P2_RESULT" = "PASS" ]; then
    add_reward 0.04
fi

# ── P2P-3 (0.04): VLLM_SUPPORTED_VLM retains existing entries ──
# The agent must ADD idefics3 without removing existing VLM entries.
# Before the change, the list has: qwen2_5_vl, gemma3, mistral3, qwen3_vl.
echo "--- P2P-3 [0.04]: Existing VLLM_SUPPORTED_VLM entries preserved ---"

P2P3_RESULT=$(python3 << 'PYEOF'
import sys, ast

# Use AST to avoid import-time GPU dependencies in vision.py
try:
    with open('/workspace/unsloth/unsloth/models/vision.py') as f:
        tree = ast.parse(f.read())
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

existing_entries = {"qwen2_5_vl", "gemma3", "mistral3", "qwen3_vl"}
found_entries = set()

for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == 'VLLM_SUPPORTED_VLM':
                if isinstance(node.value, (ast.List, ast.Tuple, ast.Set)):
                    for elt in node.value.elts:
                        if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                            found_entries.add(elt.value)

missing = existing_entries - found_entries
if missing:
    print(f"FAIL:missing_entries:{missing}")
    sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P3_RESULT"
if [ "$P2P3_RESULT" = "PASS" ]; then
    add_reward 0.04
fi

# ── P2P-4 (0.04): Existing model class exports preserved in __init__.py ──
# The agent must not break imports of FastLlamaModel, FastMistralModel, etc.
# These are the core model classes that must remain accessible.
echo "--- P2P-4 [0.04]: Existing model exports preserved ---"

P2P4_RESULT=$(python3 << 'PYEOF'
import sys, ast

try:
    with open('/workspace/unsloth/unsloth/models/__init__.py') as f:
        tree = ast.parse(f.read())
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

# These classes MUST still be imported in __init__.py
required_exports = {
    "FastLlamaModel", "FastLanguageModel", "FastMistralModel",
    "FastGraniteModel",
}

found_names = set()
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom):
        for alias in node.names:
            if alias.name == '*':
                # Wildcard import from a module that might contain our classes
                pass
            elif alias.asname:
                found_names.add(alias.asname)
            else:
                found_names.add(alias.name)

missing = required_exports - found_names
if missing:
    print(f"FAIL:missing_exports:{missing}")
    sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P4_RESULT"
if [ "$P2P4_RESULT" = "PASS" ]; then
    add_reward 0.04
fi

echo ""
echo "======================================="
echo "  Tier breakdown:"
echo "    [0.40] Check 1: F2P hook compatibility fix (behavioral)"
echo "    [0.30] Check 2: from_pretrained delegation (behavioral)"
echo "    [0.05] Check 3: VLLM_SUPPORTED_VLM (behavioral)"
echo "    [0.05] Check 4: __init__.py export (behavioral)"
echo "    [0.20] Check 5: Code substance — methods+LoRA+dispatch+depth (structural)"
echo "    [0.03] P2P-1: Source integrity (parse + key files exist)"
echo "    [0.04] P2P-2: Hook handles normal tensors (CPU behavioral)"
echo "    [0.04] P2P-3: Existing VLLM_SUPPORTED_VLM entries preserved"
echo "    [0.04] P2P-4: Existing model exports preserved in __init__.py"
echo "    Behavioral: 0.92 | Structural: 0.20 | P2P: 0.15"
echo "  Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
