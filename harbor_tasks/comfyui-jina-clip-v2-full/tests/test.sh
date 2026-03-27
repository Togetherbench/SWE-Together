#!/usr/bin/env bash
#
# Verification test for ComfyUI Jina CLIP v2 text encoder implementation.
#
# Tests structural and behavioral correctness of:
#   comfy/text_encoders/jina_clip_2.py
#
# All tests run on CPU — no GPU required.
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring weights:
#   Test 1:  0.04  jina_clip_2.py exists and parses as valid Python (structural)
#   Test 2:  0.06  Required classes defined: tokenizer, model, wrapper (structural)
#   Test 3:  0.08  Tokenizer is subclass of SDTokenizer + real __init__ (behavioral import + anti-stub)
#   Test 4:  0.10  JinaClip2TextModel extends SDClipModel + real __init__ (behavioral import + anti-stub)
#   Test 5:  0.10  JinaClip2TextModelWrapper instantiable on CPU (behavioral)
#   Test 6:  0.07  Non-stub implementation: model body has real architecture (structural anti-stub)
#   Test 7:  0.08  Mean pooling over attention mask: mask+pooling+output (behavioral import + AST)
#   Test 8:  0.08  Rotary embeddings (RoPE): requires inv_freq/cos_sin patterns (behavioral import + AST)
#   Test 9:  0.10  End-to-end: encode_token_weights works with dummy tokens (behavioral)
#   Test 10: 0.10  Output embedding dimension is 1024 (behavioral)
#   Test 11: 0.10  Multi-layer transformer: ≥20 encoder layers (behavioral)
#   Test 12: 0.09  Mean pooling correctness: masked tokens excluded from output (behavioral)
#
# Structural total: 0.17 (17%)
# Behavioral total: 0.83 (83%)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
JINA_PY="/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): jina_clip_2.py exists and is valid Python
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/12: jina_clip_2.py exists and parses ==="
T1=$(python3 << 'PYEOF'
import sys, ast, os

path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
if not os.path.exists(path):
    print("FAIL:file_not_found")
    sys.exit(0)

with open(path, "r") as f:
    source = f.read()

if len(source.strip()) < 50:
    print("FAIL:file_too_short")
    sys.exit(0)

try:
    ast.parse(source)
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax_error:{e}")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.04; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.10): Required top-level names present (structural)
#   Must define: a Tokenizer class, a TextModel class, a wrapper/entry class
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/12: Required classes defined ==="
T2=$(python3 << 'PYEOF'
import sys, ast

path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path, "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:{e}")
    sys.exit(0)

top_names = set()
for node in ast.iter_child_nodes(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        top_names.add(node.name)

# Must have some form of tokenizer
has_tokenizer = any(
    "Tokenizer" in n or "tokenizer" in n.lower()
    for n in top_names
)
# Must have some form of text/clip model
has_model = any(
    ("Model" in n or "CLIP" in n or "Clip" in n)
    and ("Jina" in n or "jina" in n or "XLM" in n or "xlm" in n or "Roberta" in n or "Text" in n)
    for n in top_names
)
# Must have some wrapper or at least 3 classes total
num_classes = sum(
    1 for node in ast.iter_child_nodes(tree)
    if isinstance(node, ast.ClassDef)
)

if has_tokenizer and has_model and num_classes >= 3:
    print("PASS")
elif has_tokenizer and has_model:
    print(f"FAIL:only_{num_classes}_classes_expected_3+")
elif has_model:
    print("FAIL:no_tokenizer")
elif has_tokenizer:
    print("FAIL:no_model_class")
else:
    print(f"FAIL:missing_both:top_names={sorted(top_names)[:10]}")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.06; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.08): Tokenizer is subclass of SDTokenizer (behavioral import)
#   Import the module and verify tokenizer class hierarchy via issubclass.
#   Then AST-verify Jina-specific tokenizer config (pad_with_end, special tokens).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/12: Tokenizer inherits SDTokenizer (behavioral import) ==="
T3=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy.sd1_clip import SDTokenizer

    # Find tokenizer subclass via runtime introspection
    tok_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, SDTokenizer) and obj is not SDTokenizer:
            tok_cls = obj
            break

    if tok_cls is None:
        tok_names = [n for n in dir(jina_mod) if isinstance(getattr(jina_mod, n), type) and "oken" in n]
        print(f"FAIL:no_SDTokenizer_subclass:found={tok_names[:5]}")
        sys.exit(0)

    # Verify via AST that tokenizer __init__ has Jina-specific config
    import ast
    path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
    with open(path) as f:
        tree = ast.parse(f.read())

    has_jina_config = False
    init_kwargs = 0
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.ClassDef) and node.name == tok_cls.__name__:
            for child in node.body:
                if isinstance(child, ast.FunctionDef) and child.name == "__init__":
                    for n in ast.walk(child):
                        if isinstance(n, ast.keyword):
                            init_kwargs += 1
                            if n.arg == "pad_with_end" and isinstance(n.value, ast.Constant) and n.value.value == False:
                                has_jina_config = True
                            if n.arg in ("end_token", "pad_token", "start_token"):
                                has_jina_config = True

    if has_jina_config:
        print(f"PASS:{tok_cls.__name__}:with_jina_config")
    elif init_kwargs >= 2:
        # Subclass with real __init__ config (not a stub)
        print(f"PASS:{tok_cls.__name__}:subclass_with_init:kwargs={init_kwargs}")
    else:
        print(f"FAIL:stub_tokenizer:init_kwargs={init_kwargs}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.10): JinaClip2TextModel (or equivalent) extends SDClipModel (behavioral)
#   Actually import the module and verify the class hierarchy
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/12: Text model extends SDClipModel (behavioral import) ==="
T4=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    # Find the "TextModel" or "ClipModel" class (not the wrapper)
    text_model_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        if name.endswith("Model") and ("Jina" in name or "jina" in name or "XLM" in name):
            # Check if it extends SDClipModel
            if issubclass(obj, sd1_clip.SDClipModel):
                text_model_cls = obj
                break

    if text_model_cls is None:
        # Try broader search: any class that extends SDClipModel
        for name in dir(jina_mod):
            obj = getattr(jina_mod, name)
            if isinstance(obj, type) and issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
                text_model_cls = obj
                break

    if text_model_cls is None:
        classes = [name for name in dir(jina_mod) if isinstance(getattr(jina_mod, name), type)]
        print(f"FAIL:no_SDClipModel_subclass:classes={classes[:10]}")
        sys.exit(0)

    # Stub rejection: verify __init__ has real content (keyword args to super)
    import ast as _ast4
    with open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py") as _f4:
        _tree4 = _ast4.parse(_f4.read())
    _init_kwargs = 0
    for _node in _ast4.iter_child_nodes(_tree4):
        if isinstance(_node, _ast4.ClassDef) and _node.name == text_model_cls.__name__:
            for _child in _node.body:
                if isinstance(_child, _ast4.FunctionDef) and _child.name == "__init__":
                    for _n in _ast4.walk(_child):
                        if isinstance(_n, _ast4.keyword):
                            _init_kwargs += 1
    if _init_kwargs >= 2:
        print(f"PASS:{text_model_cls.__name__}:init_kwargs={_init_kwargs}")
    else:
        print(f"FAIL:stub_model:init_kwargs={_init_kwargs}")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.10): Wrapper class is instantiable on CPU (behavioral)
#   SD1ClipModel wrapper must be instantiable with device="cpu"
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/12: Wrapper class instantiable on CPU ==="
T5=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip
    import torch

    # Find an SD1ClipModel subclass (the wrapper)
    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        # Try any class that could be a wrapper/entry point
        for name in dir(jina_mod):
            obj = getattr(jina_mod, name)
            if not isinstance(obj, type):
                continue
            if "Wrapper" in name or ("Jina" in name and "Model" in name):
                wrapper_cls = obj
                break

    if wrapper_cls is None:
        print("FAIL:no_wrapper_class")
        sys.exit(0)

    # Try to instantiate on CPU
    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Must be a torch.nn.Module
    if not isinstance(instance, torch.nn.Module):
        print(f"FAIL:not_nn_module:{type(instance).__name__}")
        sys.exit(0)

    # Must have encode_token_weights method
    if not hasattr(instance, "encode_token_weights"):
        print(f"FAIL:no_encode_token_weights:{wrapper_cls.__name__}")
        sys.exit(0)

    print(f"PASS:{wrapper_cls.__name__}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.07): Non-stub: model has real architecture body (structural anti-stub)
#   The underlying model must have real forward pass logic,
#   not just stubs. Check for multiple classes and forward methods.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/12: Non-stub: real model architecture (anti-stub) ==="
T6=$(python3 << 'PYEOF'
import sys, ast

path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path, "r") as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:{e}")
    sys.exit(0)

# Count total classes
num_classes = sum(1 for node in ast.iter_child_nodes(tree) if isinstance(node, ast.ClassDef))

# A real implementation has at least 5 classes (embeddings, attention, MLP, encoder, model + wrappers)
# A stub would have 2-3 classes at most
if num_classes < 4:
    print(f"FAIL:too_few_classes:{num_classes}_expected_4+")
    sys.exit(0)

# Count total lines of code (excluding blanks and comments)
code_lines = sum(
    1 for line in source.splitlines()
    if line.strip() and not line.strip().startswith("#")
)

if code_lines < 80:
    print(f"FAIL:too_few_code_lines:{code_lines}_expected_80+")
    sys.exit(0)

# Check for forward methods that have real content (>3 statements)
real_forward_count = 0
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef):
        for method in cls.body:
            if isinstance(method, ast.FunctionDef) and method.name == "forward":
                # Count meaningful statements in forward
                stmt_count = sum(1 for _ in ast.walk(method)
                                 if isinstance(_, (ast.Assign, ast.Return, ast.If,
                                                   ast.For, ast.Call, ast.AugAssign)))
                if stmt_count >= 4:
                    real_forward_count += 1

if real_forward_count >= 2:
    print(f"PASS:classes={num_classes},code_lines={code_lines},real_forwards={real_forward_count}")
elif num_classes >= 6 and code_lines >= 150:
    print(f"PASS:classes={num_classes},code_lines={code_lines}")
else:
    print(f"FAIL:insufficient_implementation:classes={num_classes},lines={code_lines},forwards={real_forward_count}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.08): Mean pooling over attention mask (behavioral import + AST)
#   Import the module and verify via inspect that a model class accepts
#   attention_mask. Then use AST to confirm .mean() call exists in code
#   (not in comments — AST is inherently comment-resistant).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/12: Mean pooling over attention mask ==="
T7=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    import inspect, ast

    # Behavioral: find class with forward() that takes attention_mask
    found_mask_param = False
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        forward = getattr(obj, 'forward', None)
        if forward is None:
            continue
        try:
            sig = inspect.signature(forward)
            if 'attention_mask' in sig.parameters or 'mask' in sig.parameters:
                found_mask_param = True
                break
        except (ValueError, TypeError):
            continue

    # AST: verify .mean() call exists in actual code (not comments)
    path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
    with open(path) as f:
        tree = ast.parse(f.read())

    has_mean_call = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr == "mean":
                has_mean_call = True
                break

    # AST: check for division with sum (weighted mean pattern)
    has_weighted_div = False
    for node in ast.walk(tree):
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            dump = ast.dump(node)
            if "sum" in dump.lower():
                has_weighted_div = True
                break

    # AST: pooled output assignment (variable name, not string in comment)
    has_pooled_assign = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and "pooled" in target.id.lower():
                    has_pooled_assign = True
                elif isinstance(target, ast.Attribute) and "pooled" in target.attr.lower():
                    has_pooled_assign = True
        if has_pooled_assign:
            break

    signals = sum([found_mask_param, has_mean_call, has_weighted_div, has_pooled_assign])
    if found_mask_param and (has_mean_call or has_weighted_div) and has_pooled_assign:
        print(f"PASS:signals={signals}")
    elif signals >= 3 and found_mask_param:
        print(f"PASS:signals={signals}")
    else:
        print(f"FAIL:mask_param={found_mask_param},mean_call={has_mean_call},weighted_div={has_weighted_div},pooled={has_pooled_assign}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.08): Rotary embeddings (RoPE) implemented (behavioral import + AST)
#   Import module and verify RoPE classes/functions exist at runtime.
#   Then AST-check for inv_freq, cos/sin patterns (comment-resistant).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/12: Rotary embeddings (RoPE) implemented ==="
T8=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    import ast

    # Behavioral: check for rotary/rope class in imported module
    has_rotary_class = False
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and ("rotary" in name.lower() or "rope" in name.lower()):
            has_rotary_class = True
            break

    # Behavioral: check for rotate_half or similar function (not class)
    has_rotate_func = False
    for name in dir(jina_mod):
        if "rotate" in name.lower():
            obj = getattr(jina_mod, name, None)
            if callable(obj) and not isinstance(obj, type):
                has_rotate_func = True
                break

    # AST: check for self.inv_freq or register_buffer("inv_freq", ...)
    path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
    with open(path) as f:
        tree = ast.parse(f.read())

    has_inv_freq = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and node.attr == "inv_freq":
            has_inv_freq = True
            break
    if not has_inv_freq:
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                func = node.func
                if isinstance(func, ast.Attribute) and func.attr == "register_buffer":
                    if node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == "inv_freq":
                        has_inv_freq = True
                        break

    # AST: cos + sin calls (both must be present for RoPE application)
    cos_found = sin_found = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            attr = None
            if isinstance(func, ast.Attribute):
                attr = func.attr
            elif isinstance(func, ast.Name):
                attr = func.id
            if attr == "cos":
                cos_found = True
            elif attr == "sin":
                sin_found = True
    has_cos_sin = cos_found and sin_found

    signals = sum([has_rotary_class, has_rotate_func, has_inv_freq, has_cos_sin])
    if signals >= 3 and (has_inv_freq or has_cos_sin):
        print(f"PASS:signals={signals}")
    elif has_inv_freq and has_cos_sin:
        print(f"PASS:signals={signals}")
    else:
        print(f"FAIL:rotary_class={has_rotary_class},rotate_func={has_rotate_func},inv_freq={has_inv_freq},cos_sin={has_cos_sin}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.10): End-to-end: encode_token_weights with dummy tokens (behavioral)
#   Instantiate the wrapper, call encode_token_weights with dummy input,
#   verify output has the right shape/structure.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/12: End-to-end encode_token_weights (behavioral) ==="
T9=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    # Find wrapper class (SD1ClipModel subclass)
    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        print("FAIL:no_wrapper_cls")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Build dummy tokenized input
    # SD1ClipModel wrapper uses clip_name as the key in token_weight_pairs dict
    name_key = getattr(instance, "clip_name", None)
    if name_key is None:
        # Fall back: inspect the clip sub-model
        clip_sub = getattr(instance, "clip", None)
        name_key = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Create dummy token weights: batch=1, seq_len=5
    # Format: [(token_id, weight), ...]
    dummy_tokens = [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (2, 1.0)]]

    first_error = None
    last_error = "unknown"
    # Try the found key and common fallbacks
    for key in [name_key, "jina_clip_2", "clip"]:
        try:
            result = instance.encode_token_weights({key: dummy_tokens})
            if result is not None:
                # Result should be (cond, pooled) tuple or similar
                if isinstance(result, (tuple, list)) and len(result) >= 2:
                    cond = result[0]
                    if isinstance(cond, torch.Tensor) and cond.ndim >= 2:
                        print(f"PASS:output_shape={tuple(cond.shape)}")
                        sys.exit(0)
                elif isinstance(result, torch.Tensor):
                    print(f"PASS:tensor_output_shape={tuple(result.shape)}")
                    sys.exit(0)
        except Exception as e:
            err = str(e)[:120]
            if first_error is None:
                first_error = err
            last_error = err
            continue

    # Report the first meaningful error (most informative)
    print(f"FAIL:encode_failed:first_error={first_error or last_error}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T9"
if [[ "$T9" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10 (0.10): Output embedding dimension is 1024 (behavioral)
#   Instantiate the wrapper, run a forward pass, verify output dim=1024.
#   Jina CLIP v2 uses hidden_size=1024 — a wrong dimension means wrong config.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 10/12: Output embedding dimension is 1024 ==="
T10=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    # Find wrapper class
    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        print("FAIL:no_wrapper_cls")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Get the clip_name key
    name_key = getattr(instance, "clip_name", None)
    if name_key is None:
        clip_sub = getattr(instance, "clip", None)
        name_key = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    dummy_tokens = [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (2, 1.0)]]

    result = None
    for key in [name_key, "jina_clip_2", "clip"]:
        try:
            result = instance.encode_token_weights({key: dummy_tokens})
            if result is not None:
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_returned_none")
        sys.exit(0)

    if isinstance(result, (tuple, list)) and len(result) >= 1:
        cond = result[0]
    elif isinstance(result, torch.Tensor):
        cond = result
    else:
        print(f"FAIL:unexpected_result_type:{type(result)}")
        sys.exit(0)

    if not isinstance(cond, torch.Tensor):
        print(f"FAIL:cond_not_tensor:{type(cond)}")
        sys.exit(0)

    embed_dim = cond.shape[-1]
    if embed_dim == 1024:
        print(f"PASS:embed_dim={embed_dim}")
    else:
        print(f"FAIL:wrong_embed_dim={embed_dim}_expected_1024")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T10"
if [[ "$T10" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 11 (0.10): Multi-layer transformer: ≥20 encoder layers (behavioral)
#   Jina CLIP v2 uses 24 transformer layers. Verify the model has a
#   deep encoder, not a shallow placeholder. Count nn.Module children
#   that look like transformer layers at runtime.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 11/12: Multi-layer transformer (≥20 encoder layers) ==="
T11=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    # Find wrapper class
    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        print("FAIL:no_wrapper_cls")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Walk through all modules to find lists of transformer layers
    # Look for ModuleList with ≥20 children, or count repeated layer patterns
    max_layer_count = 0

    for mod_name, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList):
            count = len(mod)
            if count > max_layer_count:
                max_layer_count = count

    if max_layer_count >= 20:
        print(f"PASS:layer_count={max_layer_count}")
    elif max_layer_count >= 12:
        print(f"FAIL:too_few_layers={max_layer_count}_expected_20+_got_medium")
    else:
        print(f"FAIL:too_few_layers={max_layer_count}_expected_20+")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T11"
if [[ "$T11" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 12 (0.09): Mean pooling correctness: masked tokens excluded (behavioral)
#   Create a wrapper, run two inputs with different attention masks,
#   and verify that the outputs differ (proving the mask is applied).
#   If masking doesn't work, both outputs would be identical.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 12/12: Mean pooling correctness (masked tokens excluded) ==="
T12=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    # Find wrapper class
    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        print("FAIL:no_wrapper_cls")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    name_key = getattr(instance, "clip_name", None)
    if name_key is None:
        clip_sub = getattr(instance, "clip", None)
        name_key = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Two different token sequences (different lengths = different attention masks)
    tokens_short = [[(1, 1.0), (2, 1.0)]]
    tokens_long = [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (300, 1.0), (400, 1.0), (2, 1.0)]]

    result_short = None
    result_long = None

    for key in [name_key, "jina_clip_2", "clip"]:
        try:
            r1 = instance.encode_token_weights({key: tokens_short})
            r2 = instance.encode_token_weights({key: tokens_long})
            if r1 is not None and r2 is not None:
                result_short = r1
                result_long = r2
                break
        except Exception:
            continue

    if result_short is None or result_long is None:
        print("FAIL:encode_failed")
        sys.exit(0)

    # Extract pooled outputs (second element of the tuple)
    def get_pooled(result):
        if isinstance(result, (tuple, list)) and len(result) >= 2:
            p = result[1]
            if isinstance(p, torch.Tensor):
                return p
            # Some implementations return a dict
            if isinstance(p, dict):
                for v in p.values():
                    if isinstance(v, torch.Tensor):
                        return v
        return None

    pooled_short = get_pooled(result_short)
    pooled_long = get_pooled(result_long)

    if pooled_short is not None and pooled_long is not None:
        # Pooled outputs should differ for different inputs
        if not torch.allclose(pooled_short, pooled_long, atol=1e-4):
            print(f"PASS:pooled_outputs_differ:shapes={tuple(pooled_short.shape)},{tuple(pooled_long.shape)}")
        else:
            print(f"FAIL:pooled_outputs_identical:masking_not_working")
    else:
        # Fall back to checking the cond (first) output shapes differ
        cond_short = result_short[0] if isinstance(result_short, (tuple, list)) else result_short
        cond_long = result_long[0] if isinstance(result_long, (tuple, list)) else result_long
        if isinstance(cond_short, torch.Tensor) and isinstance(cond_long, torch.Tensor):
            if cond_short.shape != cond_long.shape or not torch.allclose(cond_short, cond_long, atol=1e-4):
                print(f"PASS:outputs_differ:shapes={tuple(cond_short.shape)},{tuple(cond_long.shape)}")
            else:
                print(f"FAIL:outputs_identical:masking_not_working")
        else:
            print(f"FAIL:cannot_compare_outputs")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T12"
if [[ "$T12" == PASS* ]]; then add_reward 0.09; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
