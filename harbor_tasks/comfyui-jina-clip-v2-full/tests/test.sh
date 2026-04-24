#!/bin/bash
#
# Verification test for ComfyUI Jina CLIP v2 text encoder implementation.
#
# Tests structural and behavioral correctness of:
#   comfy/text_encoders/jina_clip_2.py
#
# All tests run on CPU — no GPU required.
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring weights (21 F2P tests + 1 P2P test; F2P sum = 1.00, P2P = 0.04 bonus capped at 1.0):
#   Test 1:  0.02  File exists + valid Python                       [structural F2P]
#   Test 2:  0.03  Anti-stub: classes, lines, forward(), RoPE       [structural F2P]
#   Test 3:  0.02  Config references: 1024, 24, SentencePiece       [structural F2P]
#   Test 4:  0.05  Module imports + class hierarchy                  [behavioral F2P]
#   Test 5:  0.05  Tokenizer Jina config: pad_with_end, emb_size    [behavioral F2P]
#   Test 6:  0.04  Wrapper instantiates on CPU                      [behavioral F2P]
#   Test 7:  0.05  encode_token_weights with tokens [1,42,100,2]    [behavioral F2P]
#   Test 8:  0.05  Output embedding dimension is 1024               [behavioral F2P]
#   Test 9:  0.06  Exactly 24 transformer layers (tight)            [behavioral F2P]
#   Test 10: 0.05  Different inputs -> different outputs            [behavioral F2P]
#   Test 11: 0.07  >=250M total parameters                         [behavioral F2P]
#   Test 12: 0.07  RoPE: 3+ signals (flexible patterns)            [behavioral F2P]
#   Test 13: 0.04  Encode 20-token sequence: valid output shape     [behavioral F2P]
#   Test 14: 0.05  Pooled output: (cond, pooled) format             [behavioral F2P]
#   Test 15: 0.05  Core imports + second encode (diff tokens)       [behavioral F2P]
#   Test 16: 0.06  Vocab embedding >= 200K entries                  [behavioral F2P]
#   Test 17: 0.04  Attention heads = 16 per layer                   [behavioral F2P]
#   Test 18: 0.04  FFN intermediate dim = 4096                      [behavioral F2P]
#   Test 19: 0.06  Layer norm epsilon close to 1e-5                 [behavioral F2P]
#   Test 20: 0.06  State dict key compatibility                     [behavioral F2P]
#   Test 21: 0.04  Mean pooling behavior (not CLS/last)             [behavioral F2P]
#   UP:      0.04  Upstream ComfyUI unit tests                      [upstream P2P]
#
set +e
export PATH="/workspace/venv/bin:$PATH"

sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    /workspace/ComfyUI/comfy/model_management.py 2>/dev/null || true

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

PYTHON="/workspace/venv/bin/python3"
if ! "$PYTHON" -c "import torch" 2>/dev/null; then
    if python3 -c "import torch" 2>/dev/null; then
        PYTHON="python3"
    fi
fi
export PYTHONPATH="/workspace/ComfyUI:${PYTHONPATH:-}"

# --- Write shared helper module ----------------------------------------
cat > /tmp/_jina_test_helpers.py << 'HELPEREOF'
import sys, inspect
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception:
    pass

import torch
import comfy.text_encoders.jina_clip_2 as jina_mod
from comfy import sd1_clip

def find_wrapper_cls():
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if isinstance(obj, type) and issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
            return obj, "sd1clip"
    candidates = []
    for name in dir(jina_mod):
        obj = getattr(jina_mod, name)
        if not isinstance(obj, type):
            continue
        if not issubclass(obj, torch.nn.Module) or obj is torch.nn.Module:
            continue
        if not hasattr(obj, "encode_token_weights"):
            continue
        try:
            sig = inspect.signature(obj.__init__)
            params = list(sig.parameters.keys())
            if len(params) >= 3:
                candidates.append(obj)
        except (ValueError, TypeError):
            continue
    if candidates:
        return candidates[0], "custom"
    return None, None

def make_instance(wrapper_cls):
    return wrapper_cls(device="cpu", dtype=None, model_options={})

def encode(instance, tokens):
    clip_name = getattr(instance, "clip_name", None)
    if clip_name is None:
        clip_sub = getattr(instance, "clip", None)
        if clip_sub:
            clip_name = getattr(clip_sub, "clip_name", None)
    keys_to_try = []
    if clip_name:
        keys_to_try.append(clip_name)
    # Also discover attribute names on the wrapper that hold sub-models
    for attr_name in dir(instance):
        if "jina" in attr_name.lower() or "clip" in attr_name.lower():
            attr = getattr(instance, attr_name, None)
            if isinstance(attr, torch.nn.Module) and hasattr(attr, "encode_token_weights"):
                keys_to_try.append(attr_name)
    keys_to_try.extend(["jina_clip_2", "jina_clip_v2", "jina", "clip", "l"])
    for key in keys_to_try:
        try:
            r = instance.encode_token_weights({key: tokens})
            if r is not None:
                return r
        except Exception:
            continue
    try:
        r = instance.encode_token_weights(tokens)
        if r is not None:
            return r
    except Exception:
        pass
    return None

def extract_cond(result):
    if isinstance(result, (tuple, list)) and len(result) >= 1:
        cond = result[0]
        if isinstance(cond, torch.Tensor):
            return cond
    if isinstance(result, torch.Tensor):
        return result
    return None
HELPEREOF

# ===================================================================
# TEST 1 (0.02): File exists + valid Python [structural]
# ===================================================================
echo "=== Test 1/21: File exists + parses ==="
T1=$("$PYTHON" << 'PYEOF'
import sys, ast, os
path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
if not os.path.exists(path):
    print("FAIL:file_not_found"); sys.exit(0)
with open(path) as f:
    source = f.read()
if len(source.strip()) < 50:
    print("FAIL:file_too_short"); sys.exit(0)
try:
    ast.parse(source); print("PASS")
except SyntaxError as e:
    print(f"FAIL:syntax_error:{e}")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.02; fi

# ===================================================================
# TEST 2 (0.03): Anti-stub composite [structural]
# ===================================================================
echo ""
echo "=== Test 2/21: Anti-stub composite ==="
T2=$("$PYTHON" << 'PYEOF'
import sys, ast, re
path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path) as f: source = f.read()
    tree = ast.parse(source)
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
num_classes = sum(1 for n in ast.iter_child_nodes(tree) if isinstance(n, ast.ClassDef))
if num_classes < 5:
    print(f"FAIL:classes={num_classes}_need_5+"); sys.exit(0)
code_lines = sum(1 for l in source.splitlines() if l.strip() and not l.strip().startswith("#"))
if code_lines < 150:
    print(f"FAIL:code_lines={code_lines}_need_150+"); sys.exit(0)
real_fwd = 0
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef):
        for m in cls.body:
            if isinstance(m, ast.FunctionDef) and m.name == "forward":
                stmts = sum(1 for _ in ast.walk(m) if isinstance(_, (ast.Assign, ast.Return, ast.If, ast.For, ast.Call, ast.AugAssign)))
                if stmts >= 4: real_fwd += 1
if real_fwd < 3:
    print(f"FAIL:real_forwards={real_fwd}_need_3+"); sys.exit(0)
src_lower = source.lower()
if not re.search(r'rotary|rope|inv_freq', src_lower):
    print("FAIL:no_rope_pattern"); sys.exit(0)
if not re.search(r'\.mean\s*\(|mean.pooling|mean_pool|attention_mask.*sum', src_lower):
    print("FAIL:no_mean_pool_pattern"); sys.exit(0)
print(f"PASS:classes={num_classes},lines={code_lines},fwd={real_fwd}")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.03; fi

# ===================================================================
# TEST 3 (0.02): Config references [structural]
# ===================================================================
echo ""
echo "=== Test 3/21: Config references ==="
T3=$("$PYTHON" << 'PYEOF'
import sys
path = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
try:
    with open(path) as f: source = f.read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
has_1024 = "1024" in source
has_24 = "24" in source
has_spiece = any(p in source.lower() for p in ["sentencepiece", "spiece"])
signals = sum([has_1024, has_24, has_spiece])
if signals >= 2: print(f"PASS:1024={has_1024},24={has_24},spiece={has_spiece}")
else: print(f"FAIL:1024={has_1024},24={has_24},spiece={has_spiece}")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.02; fi

# ===================================================================
# TEST 4 (0.05): Module imports + class hierarchy [behavioral]
# ===================================================================
echo ""
echo "=== Test 4/21: Module imports + class hierarchy ==="
T4=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try: import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
except Exception as e:
    print(f"FAIL:import:{e}"); sys.exit(0)
from comfy import sd1_clip
import torch
found_tok = found_model = found_sd1_wrapper = found_custom_wrapper = False
for name in dir(jina_mod):
    obj = getattr(jina_mod, name)
    if not isinstance(obj, type): continue
    if issubclass(obj, sd1_clip.SDTokenizer) and obj is not sd1_clip.SDTokenizer: found_tok = True
    if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel: found_model = True
    if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel: found_sd1_wrapper = True
    if (issubclass(obj, torch.nn.Module) and obj is not torch.nn.Module
        and hasattr(obj, "encode_token_weights")
        and not issubclass(obj, sd1_clip.SD1ClipModel)):
        found_custom_wrapper = True
if found_tok and found_model and found_sd1_wrapper:
    print("PASS:all_3_subclasses")
elif found_tok and found_model and found_custom_wrapper:
    print("PASS:tok+model+custom_wrapper")
elif found_tok and found_model:
    print("FAIL:missing_wrapper")
else:
    print(f"FAIL:tok={found_tok},model={found_model},sd1={found_sd1_wrapper},custom={found_custom_wrapper}")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 5 (0.05): Tokenizer Jina config [behavioral]
# ===================================================================
echo ""
echo "=== Test 5/21: Tokenizer Jina config ==="
T5=$("$PYTHON" << 'PYEOF'
import sys, inspect, re
sys.path.insert(0, "/workspace/ComfyUI")
try: import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
try:
    import comfy.text_encoders.jina_clip_2 as jina_mod
    from comfy.sd1_clip import SDTokenizer
except ImportError as e:
    print(f"FAIL:import:{e}"); sys.exit(0)
tok_cls = None
for name in dir(jina_mod):
    obj = getattr(jina_mod, name)
    if isinstance(obj, type) and issubclass(obj, SDTokenizer) and obj is not SDTokenizer:
        tok_cls = obj; break
if tok_cls is None:
    print("FAIL:no_SDTokenizer_subclass"); sys.exit(0)
try: source = inspect.getsource(tok_cls)
except (OSError, TypeError):
    print("FAIL:cannot_inspect_source"); sys.exit(0)
has_pad_false = "pad_with_end" in source and "False" in source
has_emb_1024 = bool(re.search(r'embedding_size\s*=\s*1024', source))
has_spiece = any(p in source for p in ["SPiece", "spiece", "SentencePiece", "sentencepiece"])
has_max_8192 = "8192" in source
signals = sum([has_pad_false, has_emb_1024, has_spiece, has_max_8192])
if signals >= 3:
    print(f"PASS:pad_false={has_pad_false},emb1024={has_emb_1024},spiece={has_spiece},max8192={has_max_8192}")
else:
    print(f"FAIL:signals={signals}_need_3+")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 6 (0.04): Wrapper instantiates on CPU [behavioral]
# ===================================================================
echo ""
echo "=== Test 6/21: Wrapper instantiates on CPU ==="
T6=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper_found"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    if not isinstance(instance, torch.nn.Module): print("FAIL:not_nn_module"); sys.exit(0)
    if not hasattr(instance, "encode_token_weights"): print("FAIL:no_encode_token_weights"); sys.exit(0)
    mod_count = sum(1 for _ in instance.named_modules())
    if mod_count < 10: print(f"FAIL:too_few_modules={mod_count}"); sys.exit(0)
    print(f"PASS:{wrapper_cls.__name__}:modules={mod_count}:style={style}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.04; fi

# ===================================================================
# TEST 7 (0.05): encode_token_weights basic [behavioral]
# ===================================================================
echo ""
echo "=== Test 7/21: encode_token_weights basic ==="
T7=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode, extract_cond
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    result = encode(instance, [[(1, 1.0), (42, 1.0), (100, 1.0), (2, 1.0)]])
    if result is None: print("FAIL:encode_returned_none"); sys.exit(0)
    cond = extract_cond(result)
    if cond is not None and cond.ndim >= 2:
        print(f"PASS:shape={tuple(cond.shape)}")
    else:
        print(f"FAIL:bad_result")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 8 (0.05): Output embedding dimension is 1024 [behavioral]
# ===================================================================
echo ""
echo "=== Test 8/21: Output dim 1024 ==="
T8=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode, extract_cond
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    result = encode(instance, [[(1, 1.0), (500, 1.0), (1000, 1.0), (2, 1.0)]])
    if result is None: print("FAIL:encode_none"); sys.exit(0)
    cond = extract_cond(result)
    if cond is None: print("FAIL:no_tensor"); sys.exit(0)
    dim = cond.shape[-1]
    if dim == 1024: print(f"PASS:dim={dim},shape={tuple(cond.shape)}")
    else: print(f"FAIL:dim={dim}_expected_1024")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 9 (0.06): Exactly 24 transformer layers [behavioral]
# ===================================================================
echo ""
echo "=== Test 9/21: Exactly 24 transformer layers ==="
T9=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    max_count = 0; best_list = None
    for mname, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList) and len(mod) > max_count:
            max_count = len(mod); best_list = mod
    if max_count < 23 or max_count > 24:
        print(f"FAIL:layers={max_count}_need_23-24"); sys.exit(0)
    real_layers = 0
    for layer in best_list:
        subs = list(layer.named_modules())
        has_linear = any(isinstance(m, torch.nn.Linear) for _, m in subs)
        if len(subs) >= 5 and has_linear: real_layers += 1
    if real_layers >= 23: print(f"PASS:total={max_count},real={real_layers}")
    else: print(f"FAIL:real_layers={real_layers}_of_{max_count}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T9"
if [[ "$T9" == PASS* ]]; then add_reward 0.06; fi

# ===================================================================
# TEST 10 (0.05): Different inputs -> different outputs [behavioral]
# ===================================================================
echo ""
echo "=== Test 10/21: Different inputs differ ==="
T10=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    r_short = encode(instance, [[(1, 1.0), (2, 1.0)]])
    r_long = encode(instance, [[(1, 1.0), (42, 1.0), (100, 1.0), (200, 1.0), (300, 1.0), (400, 1.0), (2, 1.0)]])
    if r_short is None or r_long is None: print("FAIL:encode_failed"); sys.exit(0)
    def ext(r):
        if isinstance(r, (tuple, list)):
            for item in r:
                if isinstance(item, torch.Tensor): return item
        if isinstance(r, torch.Tensor): return r
        return None
    t_short, t_long = ext(r_short), ext(r_long)
    if t_short is None or t_long is None: print("FAIL:no_tensor"); sys.exit(0)
    if t_short.shape != t_long.shape or not torch.allclose(t_short, t_long, atol=1e-4):
        print(f"PASS:shapes={tuple(t_short.shape)},{tuple(t_long.shape)}")
    else: print("FAIL:outputs_identical")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T10"
if [[ "$T10" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 11 (0.07): >=250M parameters [behavioral]
# ===================================================================
echo ""
echo "=== Test 11/21: >=250M parameters ==="
T11=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    total = sum(p.numel() for p in instance.parameters())
    if total >= 250_000_000: print(f"PASS:params={total:,}")
    else: print(f"FAIL:params={total:,}_need_250M+")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T11"
if [[ "$T11" == PASS* ]]; then add_reward 0.07; fi

# ===================================================================
# TEST 12 (0.07): RoPE detection -- 3+ of 5 signals [behavioral]
# ===================================================================
echo ""
echo "=== Test 12/21: RoPE detection (flexible) ==="
T12=$("$PYTHON" << 'PYEOF'
import sys, re
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, jina_mod
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    has_inv_freq = any("inv_freq" in bn for bn, _ in instance.named_buffers()) or \
                   any("inv_freq" in pn for pn, _ in instance.named_parameters()) or \
                   any("freq" in bn.lower() for bn, _ in instance.named_buffers())
    has_rotary_mod = any("rotary" in mn.lower() or "rope" in mn.lower() for mn, _ in instance.named_modules())
    has_large_pos = False
    for mn, mod in instance.named_modules():
        if isinstance(mod, torch.nn.Embedding) and "position" in mn.lower():
            if mod.num_embeddings > 1000: has_large_pos = True; break
    has_rotary_name = any(
        ("rotary" in n.lower() or "rope" in n.lower() or "freqs_cis" in n.lower())
        and (isinstance(getattr(jina_mod, n, None), type) or callable(getattr(jina_mod, n, None)))
        for n in dir(jina_mod))
    has_source_rope = False
    try:
        import inspect
        source = inspect.getsource(jina_mod)
        rope_patterns = [r'rotary', r'rope', r'inv_freq', r'freqs_cis', r'apply_rope', r'precompute_freqs', r'RotaryEmbedding', r'rope_theta']
        matches = sum(1 for p in rope_patterns if re.search(p, source, re.IGNORECASE))
        has_source_rope = matches >= 2
    except Exception: pass
    signals = sum([has_inv_freq, has_rotary_mod, not has_large_pos, has_rotary_name, has_source_rope])
    if signals >= 3:
        print(f"PASS:{signals}/5:inv={has_inv_freq},rot_mod={has_rotary_mod},no_pos={not has_large_pos},rot_name={has_rotary_name},src={has_source_rope}")
    else:
        print(f"FAIL:signals={signals}_need_3")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T12"
if [[ "$T12" == PASS* ]]; then add_reward 0.07; fi

# ===================================================================
# TEST 13 (0.04): Encode 20-token sequence [behavioral]
# ===================================================================
echo ""
echo "=== Test 13/21: Encode 20-token sequence ==="
T13=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode, extract_cond
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    result = encode(instance, [[(i * 50 + 1, 1.0) for i in range(20)]])
    if result is None: print("FAIL:encode_none"); sys.exit(0)
    cond = extract_cond(result)
    if cond is None: print("FAIL:no_tensor"); sys.exit(0)
    if cond.ndim >= 2 and cond.shape[-1] == 1024:
        print(f"PASS:shape={tuple(cond.shape)}")
    else: print(f"FAIL:shape={tuple(cond.shape)}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T13"
if [[ "$T13" == PASS* ]]; then add_reward 0.04; fi

# ===================================================================
# TEST 14 (0.05): Pooled output format [behavioral]
# ===================================================================
echo ""
echo "=== Test 14/21: Pooled output format ==="
T14=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    result = encode(instance, [[(1, 1.0), (77, 1.0), (333, 1.0), (999, 1.0), (2, 1.0)]])
    if result is None: print("FAIL:encode_none"); sys.exit(0)
    if not isinstance(result, (tuple, list)) or len(result) < 2:
        print(f"FAIL:not_tuple_or_too_short:{type(result).__name__}"); sys.exit(0)
    pooled = result[1]
    if isinstance(pooled, torch.Tensor):
        if pooled.ndim >= 1 and pooled.shape[-1] == 1024:
            print(f"PASS:pooled_tensor:shape={tuple(pooled.shape)}")
        else: print(f"FAIL:pooled_wrong_shape:{tuple(pooled.shape)}")
    elif isinstance(pooled, dict):
        for k, v in pooled.items():
            if isinstance(v, torch.Tensor) and v.ndim >= 1 and v.shape[-1] == 1024:
                print(f"PASS:pooled_dict:{k}:shape={tuple(v.shape)}"); sys.exit(0)
        print(f"FAIL:no_1024_tensor_in_pooled_dict")
    else: print(f"FAIL:unexpected_pooled_type:{type(pooled).__name__}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T14"
if [[ "$T14" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 15 (0.05): Core imports + second encode [behavioral]
# ===================================================================
echo ""
echo "=== Test 15/21: P2P + second encode ==="
T15=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
sys.path.insert(0, "/workspace/ComfyUI")
try: import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
try:
    import comfy.sd1_clip; import comfy.model_management
except Exception as e:
    print(f"FAIL:core_import:{e}"); sys.exit(0)
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode, extract_cond
    import torch
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    result = encode(instance, [[(1, 1.0), (2000, 0.8), (5000, 1.2), (10000, 1.0), (2, 1.0)]])
    if result is None: print("FAIL:encode_none"); sys.exit(0)
    cond = extract_cond(result)
    if cond is not None and cond.ndim >= 2 and cond.shape[-1] == 1024:
        print(f"PASS:imports_ok,encode_ok:shape={tuple(cond.shape)}")
    else: print(f"FAIL:bad_output")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T15"
if [[ "$T15" == PASS* ]]; then add_reward 0.05; fi

# ===================================================================
# TEST 16 (0.06): Vocab embedding >= 200K entries [behavioral]
# ===================================================================
echo ""
echo "=== Test 16/21: Vocab embedding >= 200K ==="
T16=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    max_embed = 0; embed_name = ""
    for mn, mod in instance.named_modules():
        if isinstance(mod, torch.nn.Embedding) and mod.num_embeddings > max_embed:
            max_embed = mod.num_embeddings; embed_name = mn
    if max_embed >= 200_000: print(f"PASS:vocab={max_embed}:{embed_name}")
    else: print(f"FAIL:vocab={max_embed}_need_200K+")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T16"
if [[ "$T16" == PASS* ]]; then add_reward 0.06; fi

# ===================================================================
# TEST 17 (0.04): Attention heads = 16 per layer [behavioral]
# ===================================================================
echo ""
echo "=== Test 17/21: Attention heads = 16 ==="
T17=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    mha_heads = []
    for mn, mod in instance.named_modules():
        if isinstance(mod, torch.nn.MultiheadAttention): mha_heads.append(mod.num_heads)
    if len(mha_heads) >= 20:
        correct = sum(1 for h in mha_heads if h == 16)
        if correct >= 20: print(f"PASS:mha_heads=16,count={correct}"); sys.exit(0)
        else: print(f"FAIL:mha_heads_wrong:{set(mha_heads)}"); sys.exit(0)
    best_list = None; max_count = 0
    for mname, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList) and len(mod) > max_count:
            max_count = len(mod); best_list = mod
    if best_list is None or max_count < 20: print("FAIL:no_layer_list"); sys.exit(0)
    correct_attn = 0; found_heads_vals = set()
    for layer in best_list:
        layer_ok = False; layer_head_val = None
        for mn, mod in layer.named_modules():
            for attr in ['num_heads', 'num_attention_heads', 'heads', 'nhead']:
                val = getattr(mod, attr, None)
                if isinstance(val, int) and val > 0:
                    found_heads_vals.add(val); layer_head_val = val
                    if val == 16: layer_ok = True
                    break
            if layer_ok: break
        if not layer_ok and layer_head_val is None:
            for mn, mod in layer.named_modules():
                if isinstance(mod, torch.nn.Linear):
                    if mod.in_features == 1024 and mod.out_features == 3072:
                        layer_ok = True; break
        if layer_ok: correct_attn += 1
    if correct_attn >= 20: print(f"PASS:layers_with_16_heads={correct_attn}/{max_count}")
    elif found_heads_vals: print(f"FAIL:found_heads={found_heads_vals},correct={correct_attn}/{max_count}")
    else: print(f"FAIL:no_head_count,correct={correct_attn}/{max_count}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T17"
if [[ "$T17" == PASS* ]]; then add_reward 0.04; fi

# ===================================================================
# TEST 18 (0.04): FFN intermediate dimension = 4096 [behavioral]
# ===================================================================
echo ""
echo "=== Test 18/21: FFN intermediate dim = 4096 ==="
T18=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    best_list = None; max_count = 0
    for mname, mod in instance.named_modules():
        if isinstance(mod, torch.nn.ModuleList) and len(mod) > max_count:
            max_count = len(mod); best_list = mod
    if best_list is None or max_count < 20: print("FAIL:no_layer_list"); sys.exit(0)
    correct_ffn = 0
    for layer in best_list:
        has_up = has_down = False
        for mn, mod in layer.named_modules():
            if isinstance(mod, torch.nn.Linear):
                if mod.in_features == 1024 and mod.out_features == 4096: has_up = True
                if mod.in_features == 4096 and mod.out_features == 1024: has_down = True
        if has_up and has_down: correct_ffn += 1
    if correct_ffn >= 20: print(f"PASS:layers_with_4096_ffn={correct_ffn}/{max_count}")
    else:
        ffn_sizes = set()
        for layer in best_list[:3]:
            for mn, mod in layer.named_modules():
                if isinstance(mod, torch.nn.Linear) and mod.in_features == 1024 and mod.out_features != 1024:
                    ffn_sizes.add(mod.out_features)
        print(f"FAIL:correct_ffn={correct_ffn}/{max_count},found_sizes={ffn_sizes}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T18"
if [[ "$T18" == PASS* ]]; then add_reward 0.04; fi

# ===================================================================
# TEST 19 (0.06): Layer norm epsilon ~ 1e-5 [behavioral]
# ===================================================================
echo ""
echo "=== Test 19/21: LayerNorm epsilon ~ 1e-5 ==="
T19=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    ln_eps_values = []
    for mn, mod in instance.named_modules():
        if isinstance(mod, torch.nn.LayerNorm): ln_eps_values.append((mn, mod.eps))
    if len(ln_eps_values) == 0: print("FAIL:no_layernorm_found"); sys.exit(0)
    correct_eps = sum(1 for _, eps in ln_eps_values if 1e-6 <= eps <= 1e-4)
    bert_eps = sum(1 for _, eps in ln_eps_values if eps < 1e-10)
    if correct_eps >= len(ln_eps_values) * 0.8 and bert_eps == 0:
        print(f"PASS:correct_eps={correct_eps}/{len(ln_eps_values)},sample_eps={ln_eps_values[0][1]}")
    elif bert_eps > 0:
        print(f"FAIL:bert_eps_detected={bert_eps}/{len(ln_eps_values)}")
    else:
        eps_set = set(eps for _, eps in ln_eps_values)
        print(f"FAIL:eps_values={eps_set}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T19"
if [[ "$T19" == PASS* ]]; then add_reward 0.06; fi

# ===================================================================
# TEST 20 (0.06): State dict key compatibility [behavioral]
# ===================================================================
echo ""
echo "=== Test 20/21: State dict key patterns ==="
T20=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    sd_keys = list(instance.state_dict().keys())
    if len(sd_keys) < 100: print(f"FAIL:too_few_keys={len(sd_keys)}"); sys.exit(0)
    keys_str = " ".join(sd_keys); keys_lower = keys_str.lower()
    has_embedding = any("embed" in k.lower() for k in sd_keys)
    has_numbered_layers = any(f".{i}." in keys_str for i in [0, 1, 10, 23])
    has_attention = any(k in keys_lower for k in ["query", "key", "value", "q_proj", "k_proj", "v_proj", "q_lin", "k_lin", "v_lin", "in_proj", "self_attn"])
    has_ffn = any(k in keys_lower for k in ["intermediate", "dense", "fc1", "fc2", "mlp", "ffn"])
    has_layernorm = any("norm" in k.lower() or "ln" in k.lower() for k in sd_keys)
    signals = sum([has_embedding, has_numbered_layers, has_attention, has_ffn, has_layernorm])
    if signals >= 4:
        print(f"PASS:signals={signals}/5:embed={has_embedding},layers={has_numbered_layers},attn={has_attention},ffn={has_ffn},ln={has_layernorm},keys={len(sd_keys)}")
    else:
        print(f"FAIL:signals={signals}/5")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T20"
if [[ "$T20" == PASS* ]]; then add_reward 0.06; fi

# ===================================================================
# TEST 21 (0.04): Mean pooling behavior (not CLS/last) [behavioral]
# Closes gap on the "output pooling strategy" requirement:
# Test 2 only catches pooling structurally via regex; this verifies
# the pooled output is actually the mean of the sequence, not a
# first-token (CLS) or last-token pool.
# ===================================================================
echo ""
echo "=== Test 21: Mean pooling behavior (not CLS/last) ==="
T21=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
try:
    from _jina_test_helpers import find_wrapper_cls, make_instance, encode, jina_mod
    import torch
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
try:
    wrapper_cls, style = find_wrapper_cls()
    if wrapper_cls is None: print("FAIL:no_wrapper"); sys.exit(0)
    instance = make_instance(wrapper_cls)
    instance.eval()
    tokens = [[(1, 1.0), (42, 1.0), (100, 1.0), (500, 1.0), (900, 1.0), (2, 1.0)]]
    with torch.no_grad():
        result = encode(instance, tokens)
    if not isinstance(result, (tuple, list)) or len(result) < 2:
        print(f"FAIL:no_tuple:{type(result).__name__}"); sys.exit(0)
    cond = result[0]
    pooled = result[1]
    if isinstance(pooled, dict):
        pooled_t = None
        for v in pooled.values():
            if isinstance(v, torch.Tensor) and v.ndim >= 1 and v.shape[-1] == 1024:
                pooled_t = v; break
        pooled = pooled_t
    if not isinstance(cond, torch.Tensor) or not isinstance(pooled, torch.Tensor):
        print(f"FAIL:not_tensor:cond={type(cond).__name__},pooled={type(pooled).__name__}"); sys.exit(0)
    if cond.ndim < 2 or cond.shape[-1] != 1024:
        print(f"FAIL:bad_cond_shape:{tuple(cond.shape)}"); sys.exit(0)
    # Normalize cond to [B, T, H]
    c = cond if cond.ndim == 3 else cond.unsqueeze(0)
    # Normalize pooled to [B, H]
    p = pooled if pooled.ndim == 2 else pooled.reshape(-1, pooled.shape[-1]) if pooled.ndim > 2 else pooled.unsqueeze(0)
    if p.shape[-1] != 1024:
        print(f"FAIL:pooled_dim={p.shape[-1]}"); sys.exit(0)
    mean_pool = c.mean(dim=-2)
    cls_pool = c[..., 0, :]
    last_pool = c[..., -1, :]
    def l2(a, b):
        a = a.reshape(-1).float()
        b = b.reshape(-1).float()
        n = min(a.shape[0], b.shape[0])
        return (a[:n] - b[:n]).pow(2).sum().sqrt().item()
    d_mean = l2(p, mean_pool)
    d_cls = l2(p, cls_pool)
    d_last = l2(p, last_pool)
    # Mean must be strictly closest (catches both CLS and last-token pooling).
    # With random weights, all pooling strategies may produce near-identical outputs
    # (all token embeddings converge), so accept if all distances are tiny.
    nearest_wrong = min(d_cls, d_last)
    all_tiny = (d_mean < 1e-3 and d_cls < 1e-3 and d_last < 1e-3)
    if all_tiny:
        # Random-weight regime: all token outputs converge, can't distinguish pooling
        # Fall back to source code check across the whole module
        import inspect as _insp, re as _re
        try:
            _src = _insp.getsource(jina_mod).lower()
        except Exception:
            _src = ""
        has_mean = bool(_re.search(r'\.mean\s*\(|mean.pool|mean_pool|attention_mask.*sum', _src))
        if has_mean:
            print(f"PASS:random_weights_mean_src:mean={d_mean:.4f},cls={d_cls:.4f},last={d_last:.4f}")
        else:
            print(f"FAIL:no_mean_in_source:mean={d_mean:.4f},cls={d_cls:.4f},last={d_last:.4f}")
    elif d_mean < nearest_wrong * 0.9 or (d_mean < 1e-3 and nearest_wrong > 1e-3):
        print(f"PASS:mean={d_mean:.4f},cls={d_cls:.4f},last={d_last:.4f}")
    else:
        print(f"FAIL:mean={d_mean:.4f},cls={d_cls:.4f},last={d_last:.4f}")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T21"
if [[ "$T21" == PASS* ]]; then add_reward 0.04; fi

# ===================================================================
# P2P UPSTREAM: ComfyUI's own CPU-safe unit tests (0.04)
# ===================================================================
echo ""
echo "=== P2P Upstream: ComfyUI unit tests ==="
cd /workspace/ComfyUI
UP_RESULT=$("$PYTHON" -m pytest \
    tests-unit/utils/json_util_test.py \
    tests-unit/feature_flags_test.py \
    tests-unit/comfy_test/folder_path_test.py \
    tests-unit/folder_paths_test/misc_test.py \
    tests-unit/folder_paths_test/filter_by_content_types_test.py \
    tests-unit/folder_paths_test/system_user_test.py \
    tests-unit/websocket_feature_flags_test.py \
    tests-unit/utils/extra_config_test.py \
    --timeout=60 -q 2>&1)
UP_EXIT=$?
echo "$UP_RESULT" | tail -5
if [ $UP_EXIT -eq 0 ]; then
    echo "  PASS: upstream tests pass"
    add_reward 0.04
else
    echo "  FAIL: upstream tests failed (exit=$UP_EXIT)"
fi

# ===================================================================
# Write final reward
# ===================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
