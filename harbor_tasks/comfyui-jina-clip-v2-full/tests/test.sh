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
#   Test 1:  0.02  jina_clip_2.py exists and parses as valid Python (structural)
#   Test 2:  0.03  Anti-stub: ≥5 classes, ≥150 lines, ≥3 forward() with ≥4 stmts (structural)
#   Test 3:  0.04  Tokenizer is subclass of SDTokenizer + Jina config (behavioral + AST anti-stub)
#   Test 4:  0.04  TextModel extends SDClipModel + real __init__ (behavioral + AST anti-stub)
#   Test 5:  0.10  Wrapper class instantiable on CPU (behavioral)
#   Test 6:  0.03  Non-stub: ≥5 classes, ≥150 code lines, ≥3 real forward() (structural anti-stub)
#   Test 7:  0.16  End-to-end: encode_token_weights works (F2P behavioral)
#   Test 8:  0.12  Output embedding dimension is 1024 (F2P behavioral)
#   Test 9:  0.12  Multi-layer transformer: ≥20 layers with real sub-modules (F2P behavioral)
#   Test 10: 0.10  Mean pooling correctness: different sequences → different pooled outputs (F2P behavioral)
#   Test 11: 0.10  Model parameter count ≥ 10M (F2P behavioral)
#   Test 12: 0.05  RoPE: rotary buffers/modules present, no large learned position embeddings (behavioral)
#   Test 13: 0.03  Tokenizer config: SentencePiece reference + embedding_size 1024 (behavioral inspect)
#   Test 14: 0.06  Pass-to-pass: upstream ComfyUI unit tests (P2P)
#
# Structural total: 0.05 (5%) — Tests 1, 2
# Behavioral total: 0.89 (89%) — Tests 3-13
# P2P total: 0.06 (6%) — Test 14
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
# TEST 1 (0.02): jina_clip_2.py exists and is valid Python
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/14: jina_clip_2.py exists and parses ==="
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
if [ "$T1" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.03): Required top-level names present (structural)
#   Must define: a Tokenizer class, a Model/CLIP class, ≥3 classes total
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/14: Required classes defined ==="
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

has_tokenizer = any(
    "Tokenizer" in n or "tokenizer" in n.lower()
    for n in top_names
)
has_model = any(
    ("Model" in n or "CLIP" in n or "Clip" in n)
    and ("Jina" in n or "jina" in n or "XLM" in n or "xlm" in n or "Roberta" in n or "Text" in n)
    for n in top_names
)
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
if [ "$T2" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.04): Tokenizer inherits SDTokenizer (behavioral import)
#   Import the module and verify tokenizer class hierarchy via issubclass.
#   AST anti-stub: __init__ passes Jina-specific config kwargs to super().
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/14: Tokenizer inherits SDTokenizer ==="
T3=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy.sd1_clip import SDTokenizer

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

    # AST anti-stub: verify __init__ has Jina-specific config (keyword args to super)
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
if [[ "$T3" == PASS* ]]; then add_reward 0.04; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.04): TextModel extends SDClipModel (behavioral import)
#   Import and verify class hierarchy + non-stub __init__
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/14: Text model extends SDClipModel ==="
T4=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

    text_model_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
            text_model_cls = obj
            break

    if text_model_cls is None:
        classes = [name for name in dir(jina_mod) if isinstance(getattr(jina_mod, name), type)]
        print(f"FAIL:no_SDClipModel_subclass:classes={classes[:10]}")
        sys.exit(0)

    # AST anti-stub: verify __init__ has real content (keyword args to super)
    import ast
    with open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py") as f:
        _tree = ast.parse(f.read())
    _init_kwargs = 0
    for _node in ast.iter_child_nodes(_tree):
        if isinstance(_node, ast.ClassDef) and _node.name == text_model_cls.__name__:
            for _child in _node.body:
                if isinstance(_child, ast.FunctionDef) and _child.name == "__init__":
                    for _n in ast.walk(_child):
                        if isinstance(_n, ast.keyword):
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
if [[ "$T4" == PASS* ]]; then add_reward 0.04; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.10): Wrapper class instantiable on CPU (behavioral)
#   SD1ClipModel wrapper must instantiate, be a proper nn.Module,
#   and expose encode_token_weights.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/14: Wrapper class instantiable on CPU ==="
T5=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip
    import torch

    wrapper_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            wrapper_cls = obj
            break

    if wrapper_cls is None:
        # Fallback: any class with Wrapper or Jina+Model in name
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

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    if not isinstance(instance, torch.nn.Module):
        print(f"FAIL:not_nn_module:{type(instance).__name__}")
        sys.exit(0)

    # Verify properly initialized nn.Module (catches skip-super stubs)
    try:
        list(instance.named_modules())
    except Exception:
        print("FAIL:not_properly_initialized")
        sys.exit(0)

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
# TEST 6 (0.03): Non-stub: real model architecture (structural anti-stub)
#   Requires ≥5 classes, ≥150 code lines, ≥3 forward methods
#   with ≥4 meaningful statements each.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/14: Non-stub: real model architecture ==="
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

num_classes = sum(1 for node in ast.iter_child_nodes(tree) if isinstance(node, ast.ClassDef))

if num_classes < 5:
    print(f"FAIL:too_few_classes:{num_classes}_expected_5+")
    sys.exit(0)

code_lines = sum(
    1 for line in source.splitlines()
    if line.strip() and not line.strip().startswith("#")
)

if code_lines < 150:
    print(f"FAIL:too_few_code_lines:{code_lines}_expected_150+")
    sys.exit(0)

# Count forward methods with real content (≥4 meaningful statements)
real_forward_count = 0
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef):
        for method in cls.body:
            if isinstance(method, ast.FunctionDef) and method.name == "forward":
                stmt_count = sum(1 for _ in ast.walk(method)
                                 if isinstance(_, (ast.Assign, ast.Return, ast.If,
                                                   ast.For, ast.Call, ast.AugAssign)))
                if stmt_count >= 4:
                    real_forward_count += 1

if real_forward_count >= 3:
    print(f"PASS:classes={num_classes},code_lines={code_lines},real_forwards={real_forward_count}")
elif num_classes >= 7 and code_lines >= 250:
    print(f"PASS:classes={num_classes},code_lines={code_lines}")
else:
    print(f"FAIL:classes={num_classes},lines={code_lines},forwards={real_forward_count}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.16): End-to-end: encode_token_weights (F2P behavioral)
#   Instantiate wrapper, call encode_token_weights with dummy tokens,
#   verify output is a tensor with valid shape.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/14: End-to-end encode_token_weights ==="
T7=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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

    # Determine the clip_name key used in token_weight_pairs dict
    name_key = getattr(instance, "clip_name", None)
    if name_key is None:
        clip_sub = getattr(instance, "clip", None)
        name_key = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Create dummy token weights: [(token_id, weight), ...]
    dummy_tokens = [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (2, 1.0)]]

    first_error = None
    for key in [name_key, "jina_clip_2", "clip"]:
        try:
            result = instance.encode_token_weights({key: dummy_tokens})
            if result is not None:
                if isinstance(result, (tuple, list)) and len(result) >= 2:
                    cond = result[0]
                    if isinstance(cond, torch.Tensor) and cond.ndim >= 2:
                        print(f"PASS:output_shape={tuple(cond.shape)}")
                        sys.exit(0)
                elif isinstance(result, torch.Tensor):
                    print(f"PASS:tensor_output_shape={tuple(result.shape)}")
                    sys.exit(0)
        except Exception as e:
            if first_error is None:
                first_error = str(e)[:120]
            continue

    print(f"FAIL:encode_failed:{first_error}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.16; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.12): Output embedding dimension is 1024 (F2P behavioral)
#   Jina CLIP v2 uses hidden_size=1024. Wrong dimension = wrong config.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/14: Output embedding dimension is 1024 ==="
T8=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.12; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.12): Multi-layer transformer: ≥20 layers with real sub-modules
#   Jina CLIP v2 has 24 transformer layers. Each layer must contain
#   real attention/FFN sub-modules (Linear layers), not empty shells.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/14: Multi-layer transformer (≥20 layers with sub-modules) ==="
T9=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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

    # Find the deepest ModuleList (transformer layers)
    max_layer_count = 0
    layer_list = None
    for mod_name, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList):
            count = len(mod)
            if count > max_layer_count:
                max_layer_count = count
                layer_list = mod

    if max_layer_count < 20:
        print(f"FAIL:too_few_layers={max_layer_count}_expected_20+")
        sys.exit(0)

    # Verify layers have real sub-modules (attention + FFN, not empty shells)
    real_layers = 0
    for layer in layer_list:
        sub_modules = list(layer.named_modules())
        # A real transformer layer has ≥5 sub-modules
        # (attention, FFN, layer norms, projections)
        if len(sub_modules) >= 5:
            has_linear = any(
                isinstance(m, torch.nn.Linear)
                for _, m in sub_modules
            )
            if has_linear:
                real_layers += 1

    if real_layers >= 20:
        print(f"PASS:layers={max_layer_count},real_layers={real_layers}")
    else:
        print(f"FAIL:real_layers={real_layers}_of_{max_layer_count}_expected_20+")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T9"
if [[ "$T9" == PASS* ]]; then add_reward 0.12; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10 (0.10): Mean pooling correctness (F2P behavioral)
#   Two different token sequences must produce different outputs,
#   proving the attention mask is applied during pooling.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 10/14: Mean pooling correctness ==="
T10=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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

    # Two different token sequences (different lengths = different masks)
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
            if isinstance(p, dict):
                for v in p.values():
                    if isinstance(v, torch.Tensor):
                        return v
        return None

    pooled_short = get_pooled(result_short)
    pooled_long = get_pooled(result_long)

    if pooled_short is not None and pooled_long is not None:
        if not torch.allclose(pooled_short, pooled_long, atol=1e-4):
            print(f"PASS:pooled_outputs_differ:shapes={tuple(pooled_short.shape)},{tuple(pooled_long.shape)}")
        else:
            print("FAIL:pooled_outputs_identical")
    else:
        # Fall back to checking the cond (first) output
        cond_short = result_short[0] if isinstance(result_short, (tuple, list)) else result_short
        cond_long = result_long[0] if isinstance(result_long, (tuple, list)) else result_long
        if isinstance(cond_short, torch.Tensor) and isinstance(cond_long, torch.Tensor):
            if cond_short.shape != cond_long.shape or not torch.allclose(cond_short, cond_long, atol=1e-4):
                print(f"PASS:outputs_differ:shapes={tuple(cond_short.shape)},{tuple(cond_long.shape)}")
            else:
                print("FAIL:outputs_identical")
        else:
            print("FAIL:cannot_compare_outputs")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T10"
if [[ "$T10" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 11 (0.10): Model parameter count ≥ 10M (F2P behavioral)
#   A real XLM-RoBERTa with 24 layers / 1024 hidden has ~300M+ params.
#   This catches fake architectures with stub layers (e.g. Linear(10,10)).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 11/14: Model parameter count ≥ 10M ==="
T11=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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

    total_params = sum(p.numel() for p in instance.parameters())

    if total_params >= 10_000_000:
        print(f"PASS:total_params={total_params:,}")
    else:
        print(f"FAIL:too_few_params={total_params:,}_expected_10M+")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T11"
if [[ "$T11" == PASS* ]]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 12 (0.05): RoPE detection (behavioral — model buffer inspection)
#   Jina CLIP v2 uses rotary position embeddings, NOT learned position
#   embeddings. Verify by inspecting the instantiated model's buffers
#   and modules — no AST needed.
#
#   Signals checked (need ≥2 of 4):
#     1. Named buffers contain "inv_freq" (standard RoPE buffer)
#     2. Named modules contain "rotary" or "rope" (rotary embedding module)
#     3. No large learned position Embedding (>1000 entries) exists
#     4. Module-level names reference rotary/rope classes or functions
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 12/14: RoPE detection (behavioral) ==="
T12=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import torch
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy import sd1_clip

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

    # Signal 1: named buffers contain inv_freq (standard RoPE buffer)
    has_inv_freq = any(
        "inv_freq" in bname
        for bname, _ in instance.named_buffers()
    )

    # Signal 2: named modules contain rotary/rope
    has_rotary_module = any(
        "rotary" in mname.lower() or "rope" in mname.lower()
        for mname, _ in instance.named_modules()
    )

    # Signal 3: no large learned position Embedding (>1000 entries)
    # Models with RoPE don't have a position_embeddings table
    has_large_pos_embed = False
    for mname, mod in instance.named_modules():
        if isinstance(mod, torch.nn.Embedding) and "position" in mname.lower():
            if mod.num_embeddings > 1000:
                has_large_pos_embed = True
                break

    # Signal 4: module-level names reference rotary/rope
    has_rotary_name = any(
        ("rotary" in n.lower() or "rope" in n.lower())
        and (isinstance(getattr(jina_mod, n, None), type) or callable(getattr(jina_mod, n, None)))
        for n in dir(jina_mod)
    )

    signals = sum([has_inv_freq, has_rotary_module, not has_large_pos_embed, has_rotary_name])

    if signals >= 2:
        print(f"PASS:signals={signals}:inv_freq={has_inv_freq},rotary_mod={has_rotary_module},no_pos_embed={not has_large_pos_embed},rotary_name={has_rotary_name}")
    else:
        print(f"FAIL:signals={signals}:inv_freq={has_inv_freq},rotary_mod={has_rotary_module},no_pos_embed={not has_large_pos_embed},rotary_name={has_rotary_name}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T12"
if [[ "$T12" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 13 (0.03): Tokenizer config (behavioral inspect)
#   Verify the tokenizer is configured for Jina CLIP v2:
#     - References SentencePiece (not BPE/WordPiece)
#     - embedding_size = 1024
#     - max_length ≥ 512
#
#   NOTE: The tokenizer cannot be instantiated because the
#   SentencePiece model file is not in the Docker image. We use
#   inspect.getsource() on the tokenizer class as the next best
#   behavioral-adjacent check.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 13/14: Tokenizer config ==="
T13=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import inspect
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy.sd1_clip import SDTokenizer

    tok_cls = None
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, SDTokenizer) and obj is not SDTokenizer:
            tok_cls = obj
            break

    if tok_cls is None:
        print("FAIL:no_tokenizer_class")
        sys.exit(0)

    # Get the tokenizer source via inspect (behavioral-adjacent)
    try:
        source = inspect.getsource(tok_cls)
    except (OSError, TypeError):
        print("FAIL:cannot_inspect_source")
        sys.exit(0)

    # Check 1: References SentencePiece tokenizer
    has_spiece = (
        "SPiece" in source or
        "sentencepiece" in source.lower() or
        "spiece" in source.lower() or
        "SentencePiece" in source
    )

    # Check 2: embedding_size = 1024
    has_emb_1024 = "1024" in source

    # Check 3: max_length ≥ 512 (Jina v2 uses 8192)
    has_large_maxlen = any(
        str(n) in source
        for n in [8192, 4096, 2048, 1024, 512]
    )

    signals = sum([has_spiece, has_emb_1024, has_large_maxlen])

    if signals >= 2:
        print(f"PASS:spiece={has_spiece},emb1024={has_emb_1024},maxlen={has_large_maxlen}")
    else:
        print(f"FAIL:spiece={has_spiece},emb1024={has_emb_1024},maxlen={has_large_maxlen}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"ERROR:{e}")
PYEOF
)
echo "  Result: $T13"
if [[ "$T13" == PASS* ]]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 14 (0.06): Pass-to-pass: upstream ComfyUI unit tests (P2P)
#   Ensure the new implementation doesn't break existing functionality.
#   Discovers and runs CPU-safe upstream tests.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 14/14: Pass-to-pass: upstream unit tests ==="
T14="SKIP"
# Ensure pytest is available
python3 -m pytest --version >/dev/null 2>&1 || pip install --no-cache-dir pytest pytest-timeout >/dev/null 2>&1

# Discover CPU-safe upstream test files
P2P_PASSED=0
P2P_TOTAL=0

for test_file in \
    /workspace/ComfyUI/tests/test_asset_seeder.py \
    /workspace/ComfyUI/tests/test_caching.py \
    /workspace/ComfyUI/tests/test_json_util.py \
    /workspace/ComfyUI/tests/test_utils.py \
    /workspace/ComfyUI/tests/test_model_merging.py; do
    if [ -f "$test_file" ]; then
        P2P_TOTAL=$((P2P_TOTAL + 1))
        T14_OUTPUT=$(cd /workspace/ComfyUI && python3 -m pytest "$test_file" -x --timeout=30 -q 2>&1)
        T14_EXIT=$?
        if [ $T14_EXIT -eq 0 ] || [ $T14_EXIT -eq 5 ]; then
            P2P_PASSED=$((P2P_PASSED + 1))
        fi
    fi
done

if [ $P2P_TOTAL -eq 0 ]; then
    # No upstream test files at this commit — award for not breaking imports
    # Verify that the core comfy module still imports correctly
    T14_IMPORT=$(python3 -c "
import sys
sys.path.insert(0, '/workspace/ComfyUI')
try:
    import comfy.sd1_clip
    import comfy.model_management
    print('PASS')
except Exception as e:
    print(f'FAIL:{e}')
" 2>&1)
    if [[ "$T14_IMPORT" == PASS* ]]; then
        T14="PASS:core_imports_ok"
    else
        T14="FAIL:$T14_IMPORT"
    fi
elif [ $P2P_PASSED -eq $P2P_TOTAL ]; then
    T14="PASS:${P2P_PASSED}/${P2P_TOTAL}_upstream_tests"
elif [ $P2P_PASSED -gt 0 ]; then
    T14="PASS:${P2P_PASSED}/${P2P_TOTAL}_upstream_tests"
else
    T14="FAIL:0/${P2P_TOTAL}_upstream_tests"
fi

echo "  Result: $T14"
if [[ "$T14" == PASS* ]]; then add_reward 0.06; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
