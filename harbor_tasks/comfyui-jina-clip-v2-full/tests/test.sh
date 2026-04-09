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
# Scoring weights (16 tests, sum 1.05, capped at 1.00):
#   Test 1:  0.02  File exists + valid Python                       [structural F2P]
#   Test 2:  0.05  Anti-stub: classes, lines, forward(), RoPE       [structural F2P]
#   Test 3:  0.03  Config references: 1024, 24, SentencePiece       [structural F2P]
#   Test 4:  0.07  Module imports + class hierarchy                  [behavioral F2P]
#   Test 5:  0.07  Tokenizer Jina config: pad_with_end, emb_size    [behavioral F2P]
#   Test 6:  0.07  Wrapper instantiates on CPU                      [behavioral F2P]
#   Test 7:  0.08  encode_token_weights with tokens [1,42,100,2]    [behavioral F2P]
#   Test 8:  0.08  Output embedding dimension is 1024               [behavioral F2P]
#   Test 9:  0.07  ≥20 transformer layers with real sub-modules     [behavioral F2P]
#   Test 10: 0.08  Different inputs → different outputs             [behavioral F2P]
#   Test 11: 0.08  ≥10M total parameters                           [behavioral F2P]
#   Test 12: 0.08  RoPE: inv_freq buffers, no large pos embed       [behavioral F2P]
#   Test 13: 0.07  Encode 20-token sequence: valid output shape     [behavioral F2P]
#   Test 14: 0.07  Pooled output: (cond, pooled) format             [behavioral F2P]
#   Test 15: 0.08  Core imports + second encode (diff tokens)       [behavioral F2P]
#   UP:     0.05  Upstream ComfyUI unit tests (10 test files)       [upstream P2P]
#
# P2P total:  0.05 (5%)
# F2P total:  1.00 (95%)
# Structural: 0.10 (10%)
# Behavioral: 0.95 (90%)
#
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
JINA_PY="/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ─── Environment setup ────────────────────────────────────────────
# The Docker image installs torch/transformers in /workspace/venv, but the
# verifier may not inherit Docker ENV settings. Use explicit venv python.
PYTHON="/workspace/venv/bin/python3"
if ! "$PYTHON" -c "import torch" 2>/dev/null; then
    if python3 -c "import torch" 2>/dev/null; then
        PYTHON="python3"
    else
        # Attempt to repair venv
        /workspace/venv/bin/pip install --no-cache-dir \
            torch==2.6.0+cpu --index-url https://download.pytorch.org/whl/cpu 2>/dev/null
        /workspace/venv/bin/pip install --no-cache-dir \
            transformers sentencepiece safetensors aiohttp einops 2>/dev/null
        PYTHON="/workspace/venv/bin/python3"
    fi
fi
export PYTHONPATH="/workspace/ComfyUI:${PYTHONPATH:-}"

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.02): File exists + valid Python [structural]
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/15: File exists + parses ==="
T1=$("$PYTHON" << 'PYEOF'
import sys, ast, os
path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
if not os.path.exists(path):
    print("FAIL:file_not_found")
    sys.exit(0)
with open(path) as f:
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
# TEST 2 (0.05): Anti-stub composite [structural]
#   ≥5 classes, ≥150 code lines, ≥3 forward() with ≥4 stmts each,
#   has RoPE pattern (rotary|rope|inv_freq), has mean pool pattern
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/15: Anti-stub composite ==="
T2=$("$PYTHON" << 'PYEOF'
import sys, ast, re

path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path) as f:
        source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:{e}")
    sys.exit(0)

# Count classes
num_classes = sum(1 for n in ast.iter_child_nodes(tree) if isinstance(n, ast.ClassDef))
if num_classes < 5:
    print(f"FAIL:classes={num_classes}_need_5+")
    sys.exit(0)

# Count non-comment code lines
code_lines = sum(1 for l in source.splitlines() if l.strip() and not l.strip().startswith("#"))
if code_lines < 150:
    print(f"FAIL:code_lines={code_lines}_need_150+")
    sys.exit(0)

# Count forward() methods with ≥4 meaningful statements
real_fwd = 0
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef):
        for m in cls.body:
            if isinstance(m, ast.FunctionDef) and m.name == "forward":
                stmts = sum(1 for _ in ast.walk(m)
                            if isinstance(_, (ast.Assign, ast.Return, ast.If,
                                              ast.For, ast.Call, ast.AugAssign)))
                if stmts >= 4:
                    real_fwd += 1
if real_fwd < 3:
    print(f"FAIL:real_forwards={real_fwd}_need_3+")
    sys.exit(0)

# RoPE pattern
src_lower = source.lower()
has_rope = bool(re.search(r'rotary|rope|inv_freq', src_lower))
if not has_rope:
    print("FAIL:no_rope_pattern")
    sys.exit(0)

# Mean pooling pattern
has_mean = bool(re.search(r'\.mean\s*\(|mean.pooling|mean_pool|attention_mask.*sum', src_lower))
if not has_mean:
    print("FAIL:no_mean_pool_pattern")
    sys.exit(0)

print(f"PASS:classes={num_classes},lines={code_lines},fwd={real_fwd}")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.03): Config references [structural]
#   Source mentions: 1024 (hidden_size), 24 (num_layers),
#   and SentencePiece / spiece tokenizer
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/15: Config references ==="
T3=$("$PYTHON" << 'PYEOF'
import sys

path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path) as f:
        source = f.read()
except Exception as e:
    print(f"FAIL:{e}")
    sys.exit(0)

has_1024 = "1024" in source
has_24 = "24" in source
has_spiece = any(p in source.lower() for p in ["sentencepiece", "spiece", "SPiece"])

signals = sum([has_1024, has_24, has_spiece])
if signals >= 2:
    print(f"PASS:1024={has_1024},24={has_24},spiece={has_spiece}")
else:
    print(f"FAIL:1024={has_1024},24={has_24},spiece={has_spiece}")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.07): Module imports + class hierarchy [behavioral]
#   Import module. Find subclasses of SDTokenizer, SDClipModel,
#   and SD1ClipModel. Need all three.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/15: Module imports + class hierarchy ==="
T4=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL:import_error:{e}")
    sys.exit(0)

from comfy import sd1_clip

found_tok = False
found_model = False
found_wrapper = False

for name in dir(jina_mod):
    obj = getattr(jina_mod, name)
    if not isinstance(obj, type):
        continue
    if issubclass(obj, sd1_clip.SDTokenizer) and obj is not sd1_clip.SDTokenizer:
        found_tok = True
    if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
        found_model = True
    if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
        found_wrapper = True

if found_tok and found_model and found_wrapper:
    print("PASS:all_3_subclasses")
elif found_tok and found_model:
    print("FAIL:missing_SD1ClipModel_subclass")
elif found_tok:
    print("FAIL:missing_model_subclasses")
else:
    print(f"FAIL:tok={found_tok},model={found_model},wrapper={found_wrapper}")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.07): Tokenizer Jina config [behavioral]
#   Tokenizer __init__ should pass Jina-specific config to super():
#   pad_with_end=False, embedding_size=1024, SPieceTokenizer class
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/15: Tokenizer Jina config ==="
T5=$("$PYTHON" << 'PYEOF'
import sys, inspect, re
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy.sd1_clip import SDTokenizer
except ImportError as e:
    print(f"FAIL:import:{e}")
    sys.exit(0)

tok_cls = None
for name in dir(jina_mod):
    obj = getattr(jina_mod, name)
    if isinstance(obj, type) and issubclass(obj, SDTokenizer) and obj is not SDTokenizer:
        tok_cls = obj
        break

if tok_cls is None:
    print("FAIL:no_SDTokenizer_subclass")
    sys.exit(0)

try:
    source = inspect.getsource(tok_cls)
except (OSError, TypeError):
    print("FAIL:cannot_inspect_source")
    sys.exit(0)

# Check Jina-specific config signals
has_pad_false = "pad_with_end" in source and "False" in source
has_emb_1024 = bool(re.search(r'embedding_size\s*=\s*1024', source))
has_spiece = any(p in source for p in ["SPiece", "spiece", "SentencePiece", "sentencepiece"])
has_max_8192 = "8192" in source

signals = sum([has_pad_false, has_emb_1024, has_spiece, has_max_8192])
if signals >= 2:
    print(f"PASS:pad_false={has_pad_false},emb1024={has_emb_1024},spiece={has_spiece},max8192={has_max_8192}")
else:
    print(f"FAIL:signals={signals}:pad_false={has_pad_false},emb1024={has_emb_1024},spiece={has_spiece},max8192={has_max_8192}")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.07): Wrapper instantiates on CPU [behavioral]
#   SD1ClipModel subclass must instantiate with device="cpu"
#   and expose encode_token_weights method.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/15: Wrapper instantiates on CPU ==="
T6=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_SD1ClipModel_subclass")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    if not isinstance(instance, torch.nn.Module):
        print("FAIL:not_nn_module")
        sys.exit(0)

    if not hasattr(instance, "encode_token_weights"):
        print("FAIL:no_encode_token_weights")
        sys.exit(0)

    # Verify it has real sub-modules (not empty shell)
    mod_count = sum(1 for _ in instance.named_modules())
    if mod_count < 10:
        print(f"FAIL:too_few_modules={mod_count}")
        sys.exit(0)

    print(f"PASS:{wrapper_cls.__name__}:modules={mod_count}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.08): encode_token_weights basic [behavioral]
#   Call encode_token_weights with tokens [1,42,100,2].
#   Result must be non-None with a tensor component.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/15: encode_token_weights basic ==="
T7=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Determine clip_name key
    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    dummy_tokens = [[(1, 1.0), (42, 1.0), (100, 1.0), (2, 1.0)]]

    result = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r = instance.encode_token_weights({key: dummy_tokens})
            if r is not None:
                result = r
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_returned_none")
        sys.exit(0)

    # Check result has tensor
    if isinstance(result, (tuple, list)) and len(result) >= 1:
        cond = result[0]
        if isinstance(cond, torch.Tensor) and cond.ndim >= 2:
            print(f"PASS:shape={tuple(cond.shape)}")
        else:
            print(f"FAIL:cond_type={type(cond).__name__},ndim={getattr(cond, 'ndim', 'N/A')}")
    elif isinstance(result, torch.Tensor) and result.ndim >= 2:
        print(f"PASS:tensor_shape={tuple(result.shape)}")
    else:
        print(f"FAIL:unexpected_type={type(result).__name__}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.08): Output embedding dimension is 1024 [behavioral]
#   Encode tokens [1,500,1000,2] (different from test 7).
#   Last dim of output tensor must be 1024.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/15: Output dim 1024 ==="
T8=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Use different tokens than test 7 to catch hardcoded outputs
    dummy_tokens = [[(1, 1.0), (500, 1.0), (1000, 1.0), (2, 1.0)]]

    result = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r = instance.encode_token_weights({key: dummy_tokens})
            if r is not None:
                result = r
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_none")
        sys.exit(0)

    cond = result[0] if isinstance(result, (tuple, list)) else result
    if not isinstance(cond, torch.Tensor):
        print(f"FAIL:not_tensor:{type(cond).__name__}")
        sys.exit(0)

    dim = cond.shape[-1]
    if dim == 1024:
        print(f"PASS:dim={dim},shape={tuple(cond.shape)}")
    else:
        print(f"FAIL:dim={dim}_expected_1024")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.07): ≥20 transformer layers [behavioral]
#   Jina CLIP v2 has 24 layers. Each must have ≥5 sub-modules
#   including Linear layers (real attention/FFN, not empty shells).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/15: ≥20 transformer layers ==="
T9=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Find the largest ModuleList (transformer layers)
    max_count = 0
    best_list = None
    for mname, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList) and len(mod) > max_count:
            max_count = len(mod)
            best_list = mod

    if max_count < 20:
        print(f"FAIL:layers={max_count}_need_20+")
        sys.exit(0)

    # Verify layers have real sub-modules
    real_layers = 0
    for layer in best_list:
        subs = list(layer.named_modules())
        has_linear = any(isinstance(m, torch.nn.Linear) for _, m in subs)
        if len(subs) >= 5 and has_linear:
            real_layers += 1

    if real_layers >= 20:
        print(f"PASS:total={max_count},real={real_layers}")
    else:
        print(f"FAIL:real_layers={real_layers}_of_{max_count}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T9"
if [[ "$T9" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10 (0.08): Different inputs → different outputs [behavioral]
#   Short tokens [1,2] vs long tokens [1,42,100,200,300,400,2].
#   Both pooled and cond outputs must differ.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 10/15: Different inputs differ ==="
T10=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    tokens_short = [[(1, 1.0), (2, 1.0)]]
    tokens_long = [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (300, 1.0), (400, 1.0), (2, 1.0)]]

    r_short = r_long = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r1 = instance.encode_token_weights({key: tokens_short})
            r2 = instance.encode_token_weights({key: tokens_long})
            if r1 is not None and r2 is not None:
                r_short, r_long = r1, r2
                break
        except Exception:
            continue

    if r_short is None or r_long is None:
        print("FAIL:encode_failed")
        sys.exit(0)

    def extract_tensor(r):
        if isinstance(r, (tuple, list)):
            for item in r:
                if isinstance(item, torch.Tensor):
                    return item
                if isinstance(item, dict):
                    for v in item.values():
                        if isinstance(v, torch.Tensor):
                            return v
        if isinstance(r, torch.Tensor):
            return r
        return None

    t_short = extract_tensor(r_short)
    t_long = extract_tensor(r_long)

    if t_short is None or t_long is None:
        print("FAIL:no_tensor_in_result")
        sys.exit(0)

    # Outputs must differ (different tokens → different embeddings)
    if t_short.shape != t_long.shape or not torch.allclose(t_short, t_long, atol=1e-4):
        print(f"PASS:shapes={tuple(t_short.shape)},{tuple(t_long.shape)}")
    else:
        print("FAIL:outputs_identical")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T10"
if [[ "$T10" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 11 (0.08): ≥10M parameters [behavioral]
#   Real XLM-RoBERTa 24-layer/1024-hidden has ~300M+ params.
#   10M bar catches stubs with tiny Linear(10,10) layers.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 11/15: ≥10M parameters ==="
T11=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})
    total = sum(p.numel() for p in instance.parameters())

    if total >= 10_000_000:
        print(f"PASS:params={total:,}")
    else:
        print(f"FAIL:params={total:,}_need_10M+")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T11"
if [[ "$T11" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 12 (0.08): RoPE detection [behavioral]
#   Check for inv_freq buffers (standard RoPE signal) AND
#   no large learned position Embedding (>1000 entries).
#   Need ≥2 of 4 signals: inv_freq, rotary module, no pos embed,
#   rotary class/function in module.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 12/15: RoPE detection ==="
T12=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    # Signal 1: inv_freq buffer
    has_inv_freq = any("inv_freq" in bn for bn, _ in instance.named_buffers())

    # Signal 2: rotary/rope module name
    has_rotary_mod = any(
        "rotary" in mn.lower() or "rope" in mn.lower()
        for mn, _ in instance.named_modules()
    )

    # Signal 3: no large learned position Embedding
    has_large_pos = False
    for mn, mod in instance.named_modules():
        if isinstance(mod, torch.nn.Embedding) and "position" in mn.lower():
            if mod.num_embeddings > 1000:
                has_large_pos = True
                break

    # Signal 4: rotary class/function in module namespace
    has_rotary_name = any(
        ("rotary" in n.lower() or "rope" in n.lower())
        and (isinstance(getattr(jina_mod, n, None), type) or callable(getattr(jina_mod, n, None)))
        for n in dir(jina_mod)
    )

    signals = sum([has_inv_freq, has_rotary_mod, not has_large_pos, has_rotary_name])
    if signals >= 2:
        print(f"PASS:signals={signals}:inv={has_inv_freq},rot_mod={has_rotary_mod},no_pos={not has_large_pos},rot_name={has_rotary_name}")
    else:
        print(f"FAIL:signals={signals}:inv={has_inv_freq},rot_mod={has_rotary_mod},no_pos={not has_large_pos},rot_name={has_rotary_name}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T12"
if [[ "$T12" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 13 (0.07): Encode 20-token sequence [behavioral]
#   Encode a longer sequence (20 tokens with varied IDs).
#   Output must have shape [1, N, 1024] where N ≥ 1.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 13/15: Encode 20-token sequence ==="
T13=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # 20 tokens with varied IDs (different from other tests)
    long_tokens = [[(i * 50 + 1, 1.0) for i in range(20)]]

    result = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r = instance.encode_token_weights({key: long_tokens})
            if r is not None:
                result = r
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_none")
        sys.exit(0)

    cond = result[0] if isinstance(result, (tuple, list)) else result
    if not isinstance(cond, torch.Tensor):
        print(f"FAIL:not_tensor:{type(cond).__name__}")
        sys.exit(0)

    if cond.ndim >= 2 and cond.shape[-1] == 1024:
        print(f"PASS:shape={tuple(cond.shape)}")
    else:
        print(f"FAIL:shape={tuple(cond.shape)}_expected_[1,N,1024]")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T13"
if [[ "$T13" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 14 (0.07): Pooled output format [behavioral]
#   encode_token_weights should return (cond, pooled_dict) where
#   pooled_dict contains a tensor. This tests mean pooling output.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 14/15: Pooled output format ==="
T14=$("$PYTHON" << 'PYEOF'
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Yet another distinct token set
    tokens = [[(1, 1.0), (77, 1.0), (333, 1.0), (999, 1.0), (2, 1.0)]]

    result = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r = instance.encode_token_weights({key: tokens})
            if r is not None:
                result = r
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_none")
        sys.exit(0)

    if not isinstance(result, (tuple, list)) or len(result) < 2:
        print(f"FAIL:not_tuple_or_too_short:type={type(result).__name__},len={len(result) if hasattr(result, '__len__') else 'N/A'}")
        sys.exit(0)

    pooled = result[1]

    # pooled can be a tensor or a dict containing a tensor
    if isinstance(pooled, torch.Tensor):
        if pooled.ndim >= 1 and pooled.shape[-1] == 1024:
            print(f"PASS:pooled_tensor:shape={tuple(pooled.shape)}")
        else:
            print(f"FAIL:pooled_wrong_shape:{tuple(pooled.shape)}")
    elif isinstance(pooled, dict):
        found_pooled = False
        for k, v in pooled.items():
            if isinstance(v, torch.Tensor) and v.ndim >= 1:
                if v.shape[-1] == 1024:
                    print(f"PASS:pooled_dict:{k}:shape={tuple(v.shape)}")
                    found_pooled = True
                    break
        if not found_pooled:
            print(f"FAIL:no_1024_tensor_in_pooled_dict:keys={list(pooled.keys())}")
    else:
        print(f"FAIL:unexpected_pooled_type:{type(pooled).__name__}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T14"
if [[ "$T14" == PASS* ]]; then add_reward 0.07; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 15 (0.08): P2P + second encode [behavioral]
#   1. Core comfy imports still work (no breakage).
#   2. Encode with completely different token set — consistent behavior.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 15/15: P2P + second encode ==="
T15=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

# Part 1: core imports
try:
    import comfy.sd1_clip
    import comfy.model_management
except Exception as e:
    print(f"FAIL:core_import:{e}")
    sys.exit(0)

# Part 2: encode with a fresh token set
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
        print("FAIL:no_wrapper")
        sys.exit(0)

    instance = wrapper_cls(device="cpu", dtype=None, model_options={})

    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        clip_name = getattr(clip_sub, "clip_name", "jina_clip_2") if clip_sub else "jina_clip_2"

    # Third distinct token set (catches hardcoded outputs)
    tokens = [[(1, 1.0), (2000, 0.8), (5000, 1.2), (10000, 1.0), (2, 1.0)]]

    result = None
    for key in [clip_name, "jina_clip_2", "clip", "l"]:
        try:
            r = instance.encode_token_weights({key: tokens})
            if r is not None:
                result = r
                break
        except Exception:
            continue

    if result is None:
        print("FAIL:encode_none")
        sys.exit(0)

    cond = result[0] if isinstance(result, (tuple, list)) else result
    if isinstance(cond, torch.Tensor) and cond.ndim >= 2 and cond.shape[-1] == 1024:
        print(f"PASS:imports_ok,encode_ok:shape={tuple(cond.shape)}")
    else:
        print(f"FAIL:bad_output:type={type(cond).__name__}")
except ImportError as e:
    print(f"FAIL:import:{e}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T15"
if [[ "$T15" == PASS* ]]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# P2P UPSTREAM: Run ComfyUI's own CPU-safe unit tests (bonus 0.05)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== P2P Upstream: ComfyUI unit tests ==="
cd /workspace/ComfyUI
UP_RESULT=$("$PYTHON" -m pytest \
    tests-unit/utils/json_util_test.py \
    tests-unit/feature_flags_test.py \
    tests-unit/execution_test/validate_node_input_test.py \
    tests-unit/execution_test/preview_method_override_test.py \
    tests-unit/comfy_test/folder_path_test.py \
    tests-unit/folder_paths_test/misc_test.py \
    tests-unit/folder_paths_test/filter_by_content_types_test.py \
    tests-unit/folder_paths_test/system_user_test.py \
    tests-unit/websocket_feature_flags_test.py \
    tests-unit/utils/extra_config_test.py \
    -x --timeout=60 -q 2>&1)
UP_EXIT=$?
echo "$UP_RESULT" | tail -5
if [ $UP_EXIT -eq 0 ]; then
    echo "  PASS: upstream tests pass"
    add_reward 0.05
else
    echo "  FAIL: upstream tests failed (exit=$UP_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
