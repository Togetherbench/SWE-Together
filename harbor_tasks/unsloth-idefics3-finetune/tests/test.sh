#!/usr/bin/env bash
#
# Verification for unsloth-idefics3-finetune
# Tests: Idefics3 VLM support addition + hook compatibility fix
# Writes reward (0.0-1.0) to /logs/verifier/reward.txt
#
# Tier split (100% F2P behavioral+structural / 5% P2P, total 1.05 capped at 1.0):
#   F2P behavioral:    Check 1 (0.30) — hook compatibility fix
#   Silver behavioral: Check 2 (0.10) — from_pretrained quality (AST-based)
#   Silver behavioral: Check 3 (0.05) — VLLM_SUPPORTED_VLM registration
#   Silver behavioral: Check 4 (0.05) — __init__.py export
#   Bronze structural: Check 5 (0.20) — code substance (methods+LoRA+dispatch+depth)
#   Bronze structural: Check 6 (0.30) — implementation completeness (VLM PEFT+utilities)
#   P2P behavioral:    P2P-1 (0.01) — source integrity (parse + key files)
#   P2P behavioral:    P2P-2 (0.02) — peft_utils public API preserved
#   P2P behavioral:    P2P-3 (0.01) — existing VLLM_SUPPORTED_VLM entries preserved
#   P2P behavioral:    P2P-4 (0.01) — existing model exports preserved
#
set +e

REWARD=0.0
WORKSPACE="/workspace/unsloth"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(python3 -c "print(round(min(1.0, $REWARD + $1), 4))")
}

# Write a reusable CPU compat preamble
cat > /tmp/_cpu_compat.py << 'CPUEOF'
import sys, types, os, site

os.environ["UNSLOTH_IS_PRESENT"] = "1"

_sp = site.getsitepackages()[0]
_uz_path = os.path.join(_sp, 'unsloth_zoo')

if 'unsloth_zoo' not in sys.modules:
    _uz = types.ModuleType('unsloth_zoo')
    _uz.__path__ = [_uz_path]
    _uz.__package__ = 'unsloth_zoo'
    _uz.__file__ = os.path.join(_uz_path, '__init__.py')
    sys.modules['unsloth_zoo'] = _uz

if 'unsloth_zoo.device_type' not in sys.modules:
    _dt = types.ModuleType('unsloth_zoo.device_type')
    _dt.get_device_type = lambda: 'cpu'
    _dt.is_hip = lambda: False
    _dt.DEVICE_TYPE = 'cpu'
    _dt.DEVICE_TYPE_TORCH = 'cpu'
    _dt.DEVICE_COUNT = 1
    _dt.ALLOW_PREQUANTIZED_MODELS = True
    _dt.ALLOW_BITSANDBYTES = False
    sys.modules['unsloth_zoo.device_type'] = _dt
    sys.modules['unsloth_zoo'].device_type = _dt

if 'unsloth_zoo.utils' not in sys.modules:
    _utils_path = os.path.join(_uz_path, 'utils.py')
    if os.path.exists(_utils_path):
        import importlib.util
        _spec = importlib.util.spec_from_file_location('unsloth_zoo.utils', _utils_path)
        _umod = importlib.util.module_from_spec(_spec)
        sys.modules['unsloth_zoo.utils'] = _umod
        try:
            _spec.loader.exec_module(_umod)
        except Exception:
            pass
CPUEOF

cd "$WORKSPACE"

# ── Locate the agent's idefics module ──
IDEFICS_PY=$(python3 << 'PYEOF'
import glob, ast, os

candidates = sorted(glob.glob('unsloth/models/*idefics*.py'))

if not candidates:
    original_files = {
        'granite.py', 'llama.py', 'qwen2.py', 'mistral.py', 'gemma.py',
        'gemma3.py', 'vision.py', '__init__.py', 'mapper.py', 'loader.py',
        'cohere.py', 'dbrx.py', 'phi3.py', 'phi4.py', '_utils.py',
    }
    for f in sorted(glob.glob('unsloth/models/*.py')):
        basename = os.path.basename(f)
        if basename in original_files:
            continue
        try:
            tree = ast.parse(open(f).read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef) and 'Idefics' in node.name:
                    candidates.append(f)
                    break
        except Exception:
            pass

if not candidates:
    for f in sorted(glob.glob('unsloth/models/*.py')):
        try:
            tree = ast.parse(open(f).read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef) and 'Idefics' in node.name:
                    candidates.append(f)
                    break
        except Exception:
            pass

print(candidates[0] if candidates else '')
PYEOF
)

export IDEFICS_PY
echo "Idefics module: ${IDEFICS_PY:-not found}"

# ═══════════════════════════════════════════════════════════════════
# CHECK 1 (0.30) — F2P BEHAVIORAL: Hook compatibility fix
#
# Path A (0.30): Monkey-patch/modify the hook or enclosing function
# Path B (0.22): Override get_input_embeddings to return Embedding
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 1 [0.30] F2P: Hook compatibility fix ---"

CHECK1=$(python3 << 'PYEOF'
import sys, os, importlib, importlib.util, inspect, ast
exec(open('/tmp/_cpu_compat.py').read())

idefics_path = os.environ.get('IDEFICS_PY', '')

hook_safe = False
returns_correct = False
embed_override = False

# ═══ PATH A: Was the hook/function itself fixed? ═══
try:
    import unsloth_zoo.peft_utils as pu
    src = inspect.getsource(pu.requires_grad_for_gradient_checkpointing)

    if 'len(input) == 0' in src:
        lines = src.split('\n')
        for i, line in enumerate(lines):
            if 'len(input) == 0' in line.strip():
                for j in range(i+1, min(i+5, len(lines))):
                    nxt = lines[j].strip()
                    if not nxt or nxt.startswith('#'):
                        continue
                    if 'raise' not in nxt:
                        hook_safe = True
                        returns_correct = True
                    break
                break
    elif 'requires_grad_pre_hook' not in src:
        hook_safe = True
        returns_correct = True
except Exception:
    pass

# A2: Check agent's module for monkey-patch code
if not hook_safe and os.path.exists(idefics_path):
    try:
        with open(idefics_path) as f:
            agent_src = f.read()

        patches_hook = (
            'requires_grad_for_gradient_checkpointing' in agent_src or
            'requires_grad_pre_hook' in agent_src
        )

        if patches_hook:
            tree = ast.parse(agent_src)
            for node in ast.walk(tree):
                if isinstance(node, ast.Assign):
                    for target in node.targets:
                        attr_name = ''
                        if isinstance(target, ast.Attribute):
                            attr_name = target.attr
                        if 'requires_grad' in attr_name:
                            hook_safe = True
                            returns_correct = True
                            break
                if isinstance(node, ast.FunctionDef):
                    if 'requires_grad' in node.name and 'pre_hook' in node.name:
                        hook_safe = True
                        returns_correct = True
                        break
                    if node.name == 'requires_grad_for_gradient_checkpointing':
                        hook_safe = True
                        returns_correct = True
                        break
                if hook_safe:
                    break
    except Exception:
        pass

    if not hook_safe:
        for patch_file in ['unsloth/patch.py', 'unsloth/models/patch.py',
                           'unsloth/hooks.py', 'unsloth/models/hooks.py']:
            if not os.path.exists(patch_file):
                continue
            try:
                with open(patch_file) as f:
                    psrc = f.read()
                if 'requires_grad_pre_hook' in psrc or 'requires_grad_for_gradient_checkpointing' in psrc:
                    hook_safe = True
                    returns_correct = True
                    break
            except Exception:
                pass

# A3: Dynamic test
if not hook_safe:
    try:
        import unsloth_zoo.peft_utils as pu
        import torch

        if os.path.exists(idefics_path):
            try:
                spec = importlib.util.spec_from_file_location(
                    'unsloth.models.idefics_c1a', idefics_path)
                mod = importlib.util.module_from_spec(spec)
                sys.modules['unsloth.models.idefics_c1a'] = mod
                spec.loader.exec_module(mod)
            except Exception:
                pass

        patched_hook = getattr(pu, 'requires_grad_pre_hook', None)
        if patched_hook is not None:
            dummy = torch.nn.Linear(1, 1)
            try:
                result = patched_hook(dummy, ())
                hook_safe = True
                if result is None or (isinstance(result, tuple) and len(result) == 0):
                    returns_correct = True
            except Exception:
                pass
    except Exception:
        pass

# ═══ PATH B: get_input_embeddings override ═══
if not hook_safe:
    if os.path.exists(idefics_path):
        try:
            with open(idefics_path) as f:
                tree = ast.parse(f.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef) and \
                   ('Idefics' in node.name or 'Granite' in node.name):
                    for item in node.body:
                        if isinstance(item, ast.FunctionDef) and \
                           item.name == 'get_input_embeddings':
                            for sub in ast.walk(item):
                                if isinstance(sub, ast.Return) and sub.value is not None:
                                    embed_override = True
                                    break
                            break
                    break
        except Exception:
            pass

    if not embed_override and os.path.exists(idefics_path):
        try:
            spec = importlib.util.spec_from_file_location(
                'unsloth.models.idefics_c1b', idefics_path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules['unsloth.models.idefics_c1b'] = mod
            spec.loader.exec_module(mod)

            import torch
            embed = torch.nn.Embedding(10, 4)
            cls = None
            for name in dir(mod):
                obj = getattr(mod, name)
                if isinstance(obj, type) and ('Idefics' in name or 'Granite' in name):
                    cls = obj
                    break

            if cls and 'get_input_embeddings' in cls.__dict__:
                instance = cls.__new__(cls)
                mock_structures = [
                    ('model', type('M', (), {
                        'text_model': type('TM', (), {'embed_tokens': embed})()
                    })()),
                    ('model', type('M', (), {'embed_tokens': embed})()),
                    ('language_model', type('LM', (), {
                        'model': type('M', (), {'embed_tokens': embed})()
                    })()),
                ]
                for attr_name, mock_obj in mock_structures:
                    setattr(instance, attr_name, mock_obj)
                    try:
                        result = instance.get_input_embeddings()
                        if isinstance(result, (torch.nn.Embedding, torch.nn.Module)):
                            params = list(result.parameters())
                            if len(params) > 0:
                                embed_override = True
                                break
                    except Exception:
                        pass
        except Exception:
            pass

if hook_safe and returns_correct:
    print('PASS_A')
elif hook_safe:
    print('PASS_A_PARTIAL')
elif embed_override:
    print('PASS_B')
else:
    print('FAIL')
PYEOF
)

echo "  Result: $CHECK1"
case "$CHECK1" in
    PASS_A) add_reward 0.30 ;;
    PASS_A_PARTIAL) add_reward 0.18 ;;
    PASS_B) add_reward 0.22 ;;
esac

# ═══════════════════════════════════════════════════════════════════
# CHECK 2 (0.10) — SILVER BEHAVIORAL: from_pretrained quality
#
# AST-based check:
# (a) from_pretrained method exists with proper parameters (0.05)
# (b) from_pretrained has delegation (calls another from_pretrained) (0.05)
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 2 [0.10] Silver: from_pretrained quality ---"

CHECK2=$(python3 << 'PYEOF'
import ast, os, sys

idefics_path = os.environ.get('IDEFICS_PY', '')
has_method = False
has_delegation = False

if not os.path.exists(idefics_path):
    print('FAIL:no_file')
    sys.exit(0)

try:
    with open(idefics_path) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    print(f'FAIL:parse:{e}')
    sys.exit(0)

target_class = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        target_class = node
        break

if target_class is None:
    print('FAIL:no_class')
    sys.exit(0)

fp_method = None
for item in target_class.body:
    if isinstance(item, ast.FunctionDef) and item.name == 'from_pretrained':
        fp_method = item
        break

if fp_method is None:
    # ── Inheritance fallback: check if from_pretrained is inherited ──
    # If class body is trivial (e.g. `pass`) but inherits from a parent
    # that has from_pretrained, give credit.
    base_names = [b.id if isinstance(b, ast.Name) else
                  (b.attr if isinstance(b, ast.Attribute) else '')
                  for b in target_class.bases]
    inherits_model = any(
        'Model' in bn or 'Vision' in bn or 'Base' in bn
        for bn in base_names
    )
    if inherits_model:
        # Try dynamic import to verify inherited from_pretrained
        try:
            exec(open('/tmp/_cpu_compat.py').read())
            import importlib.util as _ilu
            _spec = _ilu.spec_from_file_location('unsloth.models.idefics_c2inh', idefics_path)
            _mod = _ilu.module_from_spec(_spec)
            sys.modules['unsloth.models.idefics_c2inh'] = _mod
            _spec.loader.exec_module(_mod)
            _cls = None
            for _name in dir(_mod):
                _obj = getattr(_mod, _name)
                if isinstance(_obj, type) and ('Idefics' in _name or 'Granite' in _name):
                    _cls = _obj
                    break
            if _cls and hasattr(_cls, 'from_pretrained'):
                has_method = True
                has_delegation = True  # inherited implies delegation to parent
        except Exception:
            pass
        if not has_method:
            # Static fallback: parent class defined in same file has from_pretrained
            for pnode in ast.walk(tree):
                if isinstance(pnode, ast.ClassDef) and pnode.name in base_names:
                    for pitem in pnode.body:
                        if isinstance(pitem, ast.FunctionDef) and pitem.name == 'from_pretrained':
                            has_method = True
                            has_delegation = True
                            break
                    break
    if not has_method:
        print('FAIL:no_from_pretrained')
        sys.exit(0)
else:
    # (a) Check proper parameters
    param_names = set()
    for arg in fp_method.args.args:
        param_names.add(arg.arg)
    for kwonly in fp_method.args.kwonlyargs:
        param_names.add(kwonly.arg)

    expected_params = {'model_name', 'load_in_4bit', 'dtype', 'max_seq_length'}
    found_params = param_names & expected_params
    if len(found_params) >= 2:
        has_method = True

    # (b) Check delegation (calls another .from_pretrained)
    for node in ast.walk(fp_method):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr == 'from_pretrained':
                has_delegation = True
            elif isinstance(func, ast.Name) and 'from_pretrained' in func.id:
                has_delegation = True

results = []
if has_method:
    results.append('method')
if has_delegation:
    results.append('delegation')

print('|'.join(results) if results else 'FAIL')
PYEOF
)

echo "  Result: $CHECK2"
if echo "$CHECK2" | grep -q "method"; then
    add_reward 0.05
fi
if echo "$CHECK2" | grep -q "delegation"; then
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 3 (0.05) — SILVER BEHAVIORAL: VLLM_SUPPORTED_VLM
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 3 [0.05] Silver: VLLM_SUPPORTED_VLM ---"

CHECK3=$(python3 << 'PYEOF'
import sys, importlib.util, ast
exec(open('/tmp/_cpu_compat.py').read())

found = False

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
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 4 [0.05] Silver: __init__.py export ---"

CHECK4=$(python3 << 'PYEOF'
import sys, importlib.util, ast
exec(open('/tmp/_cpu_compat.py').read())

found = False

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
# Proportional: 0.05 per subcheck (4 subchecks x 0.05 = 0.20):
#   (a) Class has >=2 methods with >=2 non-trivial stmts each
#   (b) >=3 distinct LoRA/PEFT indicators
#   (c) "idefics3" or FastIdefics referenced in other files (dispatch)
#   (d) from_pretrained has >=2 non-trivial stmts
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 5 [0.20] Bronze: Code substance (proportional) ---"

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

# ---- (a) Class >=2 methods with >=2 meaningful stmts ----
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        substantial = 0
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and meaningful_stmts(item) >= 2:
                substantial += 1
        if substantial >= 2:
            results['methods'] = True
        else:
            # Inheritance fallback: if class inherits from a model base,
            # check if parent class (in same file or dynamically) has methods
            base_names_5a = [b.id if isinstance(b, ast.Name) else
                             (b.attr if isinstance(b, ast.Attribute) else '')
                             for b in node.bases]
            inherits_model_5a = any(
                'Model' in bn or 'Vision' in bn or 'Base' in bn
                for bn in base_names_5a
            )
            if inherits_model_5a:
                # Check parent class in same file
                for pnode in ast.walk(tree):
                    if isinstance(pnode, ast.ClassDef) and pnode.name in base_names_5a:
                        parent_substantial = 0
                        for pitem in pnode.body:
                            if isinstance(pitem, ast.FunctionDef) and meaningful_stmts(pitem) >= 2:
                                parent_substantial += 1
                        if parent_substantial >= 2:
                            results['methods'] = True
                        break
                # Dynamic fallback
                if not results['methods']:
                    try:
                        exec(open('/tmp/_cpu_compat.py').read())
                        import importlib.util as _ilu5a
                        _spec5a = _ilu5a.spec_from_file_location('unsloth.models.idefics_c5a', idefics_path)
                        _mod5a = _ilu5a.module_from_spec(_spec5a)
                        sys.modules['unsloth.models.idefics_c5a'] = _mod5a
                        _spec5a.loader.exec_module(_mod5a)
                        for _name5a in dir(_mod5a):
                            _obj5a = getattr(_mod5a, _name5a)
                            if isinstance(_obj5a, type) and ('Idefics' in _name5a or 'Granite' in _name5a):
                                # Count callable methods (non-dunder) on the class
                                _meths = [m for m in dir(_obj5a) if not m.startswith('_') and callable(getattr(_obj5a, m, None))]
                                if len(_meths) >= 2:
                                    results['methods'] = True
                                break
                    except Exception:
                        pass
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
    # Also count parameter names that reference LoRA concepts
    if isinstance(node, ast.arg) and node.arg in lora_ids:
        indicators.add(node.arg)

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

# ---- (d) from_pretrained >=2 meaningful stmts ----
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        found_fp_5d = False
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == 'from_pretrained':
                if meaningful_stmts(item) >= 2:
                    results['depth'] = True
                found_fp_5d = True
                break
        if not found_fp_5d:
            # Inheritance fallback: check if parent class has from_pretrained
            base_names_5d = [b.id if isinstance(b, ast.Name) else
                             (b.attr if isinstance(b, ast.Attribute) else '')
                             for b in node.bases]
            inherits_model_5d = any(
                'Model' in bn or 'Vision' in bn or 'Base' in bn
                for bn in base_names_5d
            )
            if inherits_model_5d:
                # Check parent in same file
                for pnode5d in ast.walk(tree):
                    if isinstance(pnode5d, ast.ClassDef) and pnode5d.name in base_names_5d:
                        for pitem5d in pnode5d.body:
                            if isinstance(pitem5d, ast.FunctionDef) and pitem5d.name == 'from_pretrained':
                                if meaningful_stmts(pitem5d) >= 2:
                                    results['depth'] = True
                                break
                        break
                # Dynamic fallback
                if not results['depth']:
                    try:
                        exec(open('/tmp/_cpu_compat.py').read())
                        import importlib.util as _ilu5d
                        _spec5d = _ilu5d.spec_from_file_location('unsloth.models.idefics_c5d', idefics_path)
                        _mod5d = _ilu5d.module_from_spec(_spec5d)
                        sys.modules['unsloth.models.idefics_c5d'] = _mod5d
                        _spec5d.loader.exec_module(_mod5d)
                        for _name5d in dir(_mod5d):
                            _obj5d = getattr(_mod5d, _name5d)
                            if isinstance(_obj5d, type) and ('Idefics' in _name5d or 'Granite' in _name5d):
                                if hasattr(_obj5d, 'from_pretrained'):
                                    results['depth'] = True
                                break
                    except Exception:
                        pass
        break

detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
print(f"{'PASS' if all(results.values()) else 'FAIL'} [{detail}]")
PYEOF
)

echo "  Result: $CHECK5"
if echo "$CHECK5" | grep -q "methods=OK"; then
    add_reward 0.05
fi
if echo "$CHECK5" | grep -q "lora=OK"; then
    add_reward 0.05
fi
if echo "$CHECK5" | grep -q "dispatch=OK"; then
    add_reward 0.05
fi
if echo "$CHECK5" | grep -q "depth=OK"; then
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# CHECK 6 (0.30) — BRONZE STRUCTURAL: Implementation completeness
#
# Proportional scoring for how complete the VLM class implementation is:
#   (a) Has get_peft_model method (0.05)
#   (b) get_peft_model accepts basic LoRA parameters (0.05)
#   (c) get_peft_model has VLM-specific params: finetune_vision_layers
#       and/or finetune_language_layers (0.10)
#       → This is the KEY discriminator. The instruction says "Include
#         proper LoRA/PEFT configuration targeting the right projection
#         layers for Idefics3". VLM-aware PEFT requires separate control
#         of vision vs. language layers, matching FastBaseModel.get_peft_model
#         in vision.py.
#   (d) get_peft_model has fine-grained module selection:
#       finetune_attention_modules and/or finetune_mlp_modules (0.05)
#   (e) Has >=2 utility methods beyond from_pretrained/get_peft_model (0.05)
# ═══════════════════════════════════════════════════════════════════
echo "--- Check 6 [0.30] Bronze: Implementation completeness ---"

CHECK6=$(python3 << 'PYEOF'
import ast, sys, os

idefics_path = os.environ.get('IDEFICS_PY', '')
results = {
    'peft_method': False,
    'peft_params': False,
    'vlm_params': False,
    'module_params': False,
    'utilities': False,
}

if not os.path.exists(idefics_path):
    detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
    print(f'FAIL [{detail}]')
    sys.exit(0)

try:
    with open(idefics_path) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception:
    detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
    print(f'FAIL:parse [{detail}]')
    sys.exit(0)

target_class = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and ('Idefics' in node.name or 'Granite' in node.name):
        target_class = node
        break

if target_class is None:
    detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
    print(f'FAIL:no_class [{detail}]')
    sys.exit(0)

# Collect all methods in the class
all_methods = []
for item in target_class.body:
    if isinstance(item, ast.FunctionDef):
        all_methods.append(item.name)

# (a) Has get_peft_model method
if 'get_peft_model' in all_methods:
    results['peft_method'] = True

# Find get_peft_model and analyze its parameters
peft_param_names = set()
for item in target_class.body:
    if isinstance(item, ast.FunctionDef) and item.name == 'get_peft_model':
        for arg in item.args.args:
            peft_param_names.add(arg.arg)
        for kwonly in item.args.kwonlyargs:
            peft_param_names.add(kwonly.arg)
        break

# (b) Basic LoRA parameters
basic_lora = {'r', 'lora_alpha', 'lora_dropout', 'target_modules', 'bias'}
if len(peft_param_names & basic_lora) >= 3:
    results['peft_params'] = True

# (c) VLM-specific parameters — the KEY discriminator
vlm_params = {'finetune_vision_layers', 'finetune_language_layers'}
if len(peft_param_names & vlm_params) >= 1:
    results['vlm_params'] = True

# (d) Fine-grained module selection parameters
module_params = {'finetune_attention_modules', 'finetune_mlp_modules'}
if len(peft_param_names & module_params) >= 1:
    results['module_params'] = True

# (e) Has >=2 utility methods beyond from_pretrained/get_peft_model/__init__
base_methods = {'from_pretrained', 'get_peft_model', '__init__', '__new__', '__repr__', '__str__'}
utility_methods = [m for m in all_methods if m not in base_methods and not m.startswith('__')]
if len(utility_methods) >= 2:
    results['utilities'] = True

# ── Inheritance fallback for Check 6 ──
# If class body is trivial (e.g. `pass`) but inherits from a model base,
# check if the parent provides the expected methods/params.
if not all(results.values()):
    base_names_6 = [b.id if isinstance(b, ast.Name) else
                    (b.attr if isinstance(b, ast.Attribute) else '')
                    for b in target_class.bases]
    inherits_model_6 = any(
        'Model' in bn or 'Vision' in bn or 'Base' in bn
        for bn in base_names_6
    )
    if inherits_model_6:
        # Try to find parent class in the same file first (AST)
        parent_class_6 = None
        for pn6 in ast.walk(tree):
            if isinstance(pn6, ast.ClassDef) and pn6.name in base_names_6:
                parent_class_6 = pn6
                break

        if parent_class_6 is not None:
            parent_methods_6 = []
            for pitem6 in parent_class_6.body:
                if isinstance(pitem6, ast.FunctionDef):
                    parent_methods_6.append(pitem6.name)

            if not results['peft_method'] and 'get_peft_model' in parent_methods_6:
                results['peft_method'] = True

            if not results['peft_params'] or not results['vlm_params'] or not results['module_params']:
                parent_peft_params = set()
                for pitem6 in parent_class_6.body:
                    if isinstance(pitem6, ast.FunctionDef) and pitem6.name == 'get_peft_model':
                        for arg6 in pitem6.args.args:
                            parent_peft_params.add(arg6.arg)
                        for kw6 in pitem6.args.kwonlyargs:
                            parent_peft_params.add(kw6.arg)
                        break
                if not results['peft_params'] and len(parent_peft_params & basic_lora) >= 3:
                    results['peft_params'] = True
                if not results['vlm_params'] and len(parent_peft_params & vlm_params) >= 1:
                    results['vlm_params'] = True
                if not results['module_params'] and len(parent_peft_params & module_params) >= 1:
                    results['module_params'] = True

            if not results['utilities']:
                parent_utility = [m for m in parent_methods_6 if m not in base_methods and not m.startswith('__')]
                if len(parent_utility) >= 2:
                    results['utilities'] = True

        # Dynamic fallback: import the module and inspect the class via MRO
        if not all(results.values()):
            try:
                exec(open('/tmp/_cpu_compat.py').read())
                import importlib.util as _ilu6, inspect as _insp6
                _spec6 = _ilu6.spec_from_file_location('unsloth.models.idefics_c6', idefics_path)
                _mod6 = _ilu6.module_from_spec(_spec6)
                sys.modules['unsloth.models.idefics_c6'] = _mod6
                _spec6.loader.exec_module(_mod6)
                _cls6 = None
                for _n6 in dir(_mod6):
                    _o6 = getattr(_mod6, _n6)
                    if isinstance(_o6, type) and ('Idefics' in _n6 or 'Granite' in _n6):
                        _cls6 = _o6
                        break
                if _cls6:
                    if not results['peft_method'] and hasattr(_cls6, 'get_peft_model'):
                        results['peft_method'] = True
                    if hasattr(_cls6, 'get_peft_model') and (not results['peft_params'] or not results['vlm_params'] or not results['module_params']):
                        try:
                            _sig6 = _insp6.signature(_cls6.get_peft_model)
                            _dyn_params6 = set(_sig6.parameters.keys())
                            if not results['peft_params'] and len(_dyn_params6 & basic_lora) >= 3:
                                results['peft_params'] = True
                            if not results['vlm_params'] and len(_dyn_params6 & vlm_params) >= 1:
                                results['vlm_params'] = True
                            if not results['module_params'] and len(_dyn_params6 & module_params) >= 1:
                                results['module_params'] = True
                        except Exception:
                            pass
                    if not results['utilities']:
                        _all_meths6 = [m for m in dir(_cls6) if not m.startswith('_') and callable(getattr(_cls6, m, None))]
                        _base_set6 = {'from_pretrained', 'get_peft_model'}
                        _util6 = [m for m in _all_meths6 if m not in _base_set6]
                        if len(_util6) >= 2:
                            results['utilities'] = True
            except Exception:
                pass

detail = ' | '.join(f'{k}={"OK" if v else "MISS"}' for k, v in results.items())
print(f"{'PASS' if all(results.values()) else 'FAIL'} [{detail}]")
PYEOF
)

echo "  Result: $CHECK6"
if echo "$CHECK6" | grep -q "peft_method=OK"; then
    add_reward 0.05
fi
if echo "$CHECK6" | grep -q "peft_params=OK"; then
    add_reward 0.05
fi
if echo "$CHECK6" | grep -q "vlm_params=OK"; then
    add_reward 0.10
fi
if echo "$CHECK6" | grep -q "module_params=OK"; then
    add_reward 0.05
fi
if echo "$CHECK6" | grep -q "utilities=OK"; then
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# P2P TESTS (0.05 total): Existing functionality still works
# ═══════════════════════════════════════════════════════════════════

echo "--- P2P-1 [0.01]: Source integrity ---"

P2P1_RESULT=$(python3 << 'PYEOF'
import ast, sys, os, glob
workspace = "/workspace/unsloth"
os.chdir(workspace)

init_py = os.path.join(workspace, "unsloth/models/__init__.py")
if not os.path.isfile(init_py):
    print("FAIL:init_missing"); sys.exit(0)
try:
    with open(init_py) as f:
        ast.parse(f.read())
except SyntaxError as e:
    print(f"FAIL:init_syntax:{e}"); sys.exit(0)

vision_py = os.path.join(workspace, "unsloth/models/vision.py")
if os.path.isfile(vision_py):
    try:
        with open(vision_py) as f:
            ast.parse(f.read())
    except SyntaxError as e:
        print(f"FAIL:vision_syntax:{e}"); sys.exit(0)

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

basenames = [os.path.basename(f).lower() for f in py_files]
existing_models = [b for b in basenames if any(m in b for m in ["llama", "qwen", "gemma", "mistral"])]
if len(existing_models) < 1:
    print(f"FAIL:no_existing_models"); sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P1_RESULT"
if [ "$P2P1_RESULT" = "PASS" ]; then
    add_reward 0.01
fi

echo "--- P2P-2 [0.02]: peft_utils public API preserved ---"

P2P2_RESULT=$(python3 << 'PYEOF'
import sys
exec(open('/tmp/_cpu_compat.py').read())

try:
    import unsloth_zoo.peft_utils as pu
except ImportError as e:
    print(f"FAIL:import:{e}"); sys.exit(0)

skip_list = getattr(pu, 'SKIP_QUANTIZATION_MODULES', None)
if skip_list is None:
    print("FAIL:no_SKIP_QUANTIZATION_MODULES"); sys.exit(0)
required_skips = {"lm_head", "multi_modal_projector", "router"}
found_skips = set(skip_list)
missing = required_skips - found_skips
if missing:
    print(f"FAIL:missing_skip_modules:{missing}"); sys.exit(0)

get_peft_regex = getattr(pu, 'get_peft_regex', None)
if get_peft_regex is None or not callable(get_peft_regex):
    print("FAIL:no_get_peft_regex"); sys.exit(0)

rg_fn = getattr(pu, 'requires_grad_for_gradient_checkpointing', None)
if rg_fn is None or not callable(rg_fn):
    print("FAIL:no_requires_grad_fn"); sys.exit(0)

lora_fn = getattr(pu, 'get_lora_layer_modules', None)
if lora_fn is None or not callable(lora_fn):
    print("FAIL:no_get_lora_layer_modules"); sys.exit(0)

print("PASS")
PYEOF
)

echo "  Result: $P2P2_RESULT"
if [ "$P2P2_RESULT" = "PASS" ]; then
    add_reward 0.02
fi

echo "--- P2P-3 [0.01]: Existing VLLM_SUPPORTED_VLM entries preserved ---"

P2P3_RESULT=$(python3 << 'PYEOF'
import sys, ast

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
    add_reward 0.01
fi

echo "--- P2P-4 [0.01]: Existing model exports preserved ---"

P2P4_RESULT=$(python3 << 'PYEOF'
import sys, ast

try:
    with open('/workspace/unsloth/unsloth/models/__init__.py') as f:
        tree = ast.parse(f.read())
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

required_exports = {
    "FastLlamaModel", "FastLanguageModel", "FastMistralModel",
    "FastGraniteModel",
}

found_names = set()
for node in ast.walk(tree):
    if isinstance(node, ast.ImportFrom):
        for alias in node.names:
            if alias.name == '*':
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
    add_reward 0.01
fi

echo ""
echo "======================================="
echo "  Tier breakdown:"
echo "    [0.30] Check 1: F2P hook compatibility fix (behavioral)"
echo "    [0.10] Check 2: from_pretrained quality (AST-based)"
echo "    [0.05] Check 3: VLLM_SUPPORTED_VLM (behavioral)"
echo "    [0.05] Check 4: __init__.py export (behavioral)"
echo "    [0.20] Check 5: Code substance — 0.05 each: methods, LoRA, dispatch, depth"
echo "    [0.30] Check 6: Implementation completeness — peft(0.05), params(0.05),"
echo "                     vlm_params(0.10), module_params(0.05), utilities(0.05)"
echo "    [0.01] P2P-1: Source integrity"
echo "    [0.02] P2P-2: peft_utils public API preserved"
echo "    [0.01] P2P-3: Existing VLLM_SUPPORTED_VLM entries preserved"
echo "    [0.01] P2P-4: Existing model exports preserved"
echo "    F2P: 1.00 | P2P: 0.05"
echo "  Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
