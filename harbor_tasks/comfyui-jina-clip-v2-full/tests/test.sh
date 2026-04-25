#!/bin/bash
set +e
export PATH="/workspace/ComfyUI/bin:$PATH"

sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    /workspace/ComfyUI/comfy/model_management.py 2>/dev/null || true

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(awk "BEGIN { v = $REWARD + $1; if (v > 1.0) v = 1.0; printf \"%.4f\", v }")
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

PYTHON="/workspace/ComfyUI/bin/python3"
if ! "$PYTHON" -c "import torch" 2>/dev/null; then
    if python3 -c "import torch" 2>/dev/null; then
        PYTHON="python3"
    else
        echo "0.0" > "$REWARD_FILE"
        echo "FATAL: no python with torch"
        exit 0
    fi
fi
export PYTHONPATH="/workspace/ComfyUI:${PYTHONPATH:-}"

JINA_FILE="/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"

# ============================================================================
# HARD GATE: file must exist (no-op base does NOT have this file).
# This is the F2P trigger: on no-op, file is absent → REWARD stays 0.0.
# ============================================================================
if [ ! -f "$JINA_FILE" ]; then
    echo "GATE FAIL: $JINA_FILE missing — no-op base"
    finish
fi

# ============================================================================
# HARD GATE: regression guard — comfy.sd must still import cleanly.
# If agent broke pre-existing import paths, zero out.
# ============================================================================
"$PYTHON" -c "import sys; sys.path.insert(0,'/workspace/ComfyUI'); import comfy.sd" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "GATE FAIL: comfy.sd import broken — destructive change"
    finish
fi

# ----------------------------------------------------------------------------
# Shared helper
# ----------------------------------------------------------------------------
cat > /tmp/_jina_helpers.py << 'HELPEREOF'
import sys, os
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

import torch

def import_module():
    import comfy.text_encoders.jina_clip_2 as m
    return m

def find_wrapper_cls(mod):
    from comfy import sd1_clip
    candidates = []
    for name in dir(mod):
        obj = getattr(mod, name)
        if not isinstance(obj, type):
            continue
        try:
            if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
                candidates.append((0, obj))
                continue
            if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
                candidates.append((1, obj))
                continue
        except TypeError:
            pass
        try:
            if issubclass(obj, torch.nn.Module) and obj is not torch.nn.Module:
                if hasattr(obj, "encode_token_weights"):
                    candidates.append((2, obj))
        except TypeError:
            pass
    candidates.sort(key=lambda x: x[0])
    for prio, c in candidates:
        n = c.__name__.lower()
        if "tokenizer" in n:
            continue
        if "model" in n or "wrapper" in n or "te" in n or "clip" in n:
            return c
    for prio, c in candidates:
        if "tokenizer" in c.__name__.lower():
            continue
        return c
    return None

def find_tokenizer_cls(mod):
    candidates = []
    for name in dir(mod):
        obj = getattr(mod, name)
        if not isinstance(obj, type):
            continue
        if "tokenizer" in name.lower():
            candidates.append(obj)
    # prefer ones that don't subclass SDTokenizer (i.e., the top-level wrapper)
    from comfy import sd1_clip
    top = []
    inner = []
    for c in candidates:
        try:
            if issubclass(c, sd1_clip.SD1Tokenizer):
                top.append(c)
                continue
        except TypeError:
            pass
        inner.append(c)
    if top:
        return top[0]
    if candidates:
        return candidates[0]
    return None

def make_instance(cls):
    return cls(device="cpu", dtype=None, model_options={})

def encode(instance, tokens):
    keys_to_try = []
    cn = getattr(instance, "clip_name", None)
    if cn:
        keys_to_try.append(cn)
    for attr_name in dir(instance):
        if attr_name.startswith("_"):
            continue
        try:
            attr = getattr(instance, attr_name, None)
        except Exception:
            continue
        import torch as _t
        if isinstance(attr, _t.nn.Module) and hasattr(attr, "encode_token_weights"):
            keys_to_try.append(attr_name)
    for k in ("jina_clip_2", "jina_clip", "jina", "clip", "l", "xlm_roberta", "roberta"):
        if k not in keys_to_try:
            keys_to_try.append(k)
    last_err = None
    for key in keys_to_try:
        try:
            r = instance.encode_token_weights({key: tokens})
            if r is not None:
                return r
        except Exception as e:
            last_err = e
            continue
    try:
        r = instance.encode_token_weights(tokens)
        if r is not None:
            return r
    except Exception as e:
        last_err = e
    if last_err:
        raise last_err
    return None

def extract_cond_pooled(result):
    if isinstance(result, dict):
        cond = result.get("cond") or result.get("hidden_states") or result.get(0)
        pooled = result.get("pooled_output") or result.get("pooled") or result.get(1)
        return cond, pooled
    if isinstance(result, (tuple, list)):
        cond = result[0] if len(result) >= 1 else None
        pooled = result[1] if len(result) >= 2 else None
        return cond, pooled
    if hasattr(result, "shape"):
        return result, None
    return None, None
HELPEREOF

# ============================================================================
# F2P GATE 1 (0.10): module imports + has wrapper + tokenizer classes
# Fails on no-op (file absent → import fails).
# ============================================================================
echo "=== F2P-1: import + wrapper + tokenizer classes ==="
T1=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, find_tokenizer_cls
try:
    mod = import_module()
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:import:{e}"); raise SystemExit
cls = find_wrapper_cls(mod)
if cls is None:
    print("FAIL:no_wrapper"); raise SystemExit
tok = find_tokenizer_cls(mod)
if tok is None:
    print("FAIL:no_tokenizer_class"); raise SystemExit
# Sanity: file is non-trivial
import os, ast
src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read()
classes = [n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.ClassDef)]
code_lines = sum(1 for l in src.splitlines() if l.strip() and not l.strip().startswith("#"))
if len(classes) < 2 or code_lines < 50:
    print(f"FAIL:stub classes={len(classes)} lines={code_lines}"); raise SystemExit
print(f"PASS wrapper={cls.__name__} tokenizer={tok.__name__}")
PYEOF
)
echo "  $T1"
[[ "$T1" == PASS* ]] && add_reward 0.10

# ============================================================================
# F2P GATE 2 (0.20): wrapper instantiates on CPU as nn.Module.
# Fails on no-op.
# ============================================================================
echo "=== F2P-2: wrapper instantiates on CPU ==="
T2=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance
import torch
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls)
    assert isinstance(inst, torch.nn.Module), "wrapper not nn.Module"
    # Must contain a transformer somewhere with parameters
    has_params = any(True for _ in inst.parameters())
    assert has_params, "no parameters"
    print("PASS")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T2"
[[ "$T2" == PASS* ]] && add_reward 0.20

# ============================================================================
# F2P GATE 3 (0.30): forward pass through encode_token_weights produces
# a real cond tensor with hidden_size matching XLM-RoBERTa-large (1024).
# Fails on no-op.
# ============================================================================
echo "=== F2P-3: forward pass produces real tensor with hidden_size=1024 ==="
T3=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance, encode, extract_cond_pooled
import torch
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls)
    inst.eval()
    # Build a small token sequence: BOS=0, some ids, EOS=2, pad=1
    seq = [(0, 1.0), (5, 1.0), (10, 1.0), (20, 1.0), (2, 1.0)]
    seq += [(1, 1.0)] * 3
    toks = [seq]
    with torch.no_grad():
        result = encode(inst, toks)
    cond, pooled = extract_cond_pooled(result)
    assert cond is not None, "no cond"
    assert hasattr(cond, "shape"), f"cond not tensor: {type(cond)}"
    # Expected: (B, T, hidden) — hidden == 1024 for XLM-RoBERTa large
    assert cond.dim() == 3, f"cond dim {cond.dim()}"
    assert cond.shape[0] == 1, f"batch {cond.shape}"
    assert cond.shape[2] == 1024, f"hidden {cond.shape[2]}"
    # Output must not be all zeros / all NaN
    assert torch.isfinite(cond).all(), "non-finite"
    assert cond.abs().sum().item() > 0, "all zero"
    print(f"PASS shape={tuple(cond.shape)}")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T3"
[[ "$T3" == PASS* ]] && add_reward 0.30

# ============================================================================
# F2P GATE 4 (0.15): config exposes XLM-RoBERTa large dimensions.
# Either via JSON config beside the .py, or via constants in the module.
# Fails on no-op.
# ============================================================================
echo "=== F2P-4: config dimensions correct (XLM-RoBERTa large, vocab 250002) ==="
T4=$("$PYTHON" << 'PYEOF'
import os, json, glob, re
te_dir = "/workspace/ComfyUI/comfy/text_encoders"
ok = False
# Search any JSON in the text_encoders dir whose name contains 'jina'
for path in glob.glob(os.path.join(te_dir, "*jina*.json")):
    try:
        cfg = json.load(open(path))
    except Exception:
        continue
    hs = cfg.get("hidden_size")
    nl = cfg.get("num_hidden_layers")
    nh = cfg.get("num_attention_heads")
    vs = cfg.get("vocab_size")
    if hs == 1024 and nl == 24 and nh == 16 and vs == 250002:
        ok = True
        break
if not ok:
    # fallback: check constants in the .py
    src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read()
    if (re.search(r"\b1024\b", src) and re.search(r"\b24\b", src)
            and re.search(r"\b16\b", src) and re.search(r"\b250002\b", src)):
        ok = True
print("PASS" if ok else "FAIL")
PYEOF
)
echo "  $T4"
[[ "$T4" == PASS* ]] && add_reward 0.15

# ============================================================================
# F2P GATE 5 (0.10): tokenizer class is wired and has standard sd1_clip
# tokenize interface. We don't require an actual tokenizer model file
# (download might be infeasible) — just that the class exists and inherits
# the right base or exposes tokenize_with_weights.
# Fails on no-op.
# ============================================================================
echo "=== F2P-5: tokenizer class has tokenize interface ==="
T5=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_tokenizer_cls
try:
    mod = import_module()
    tok = find_tokenizer_cls(mod)
    assert tok is not None, "no tokenizer class"
    # Must be either: subclass of SD1Tokenizer, or have tokenize_with_weights
    from comfy import sd1_clip
    is_top = False
    try:
        is_top = issubclass(tok, sd1_clip.SD1Tokenizer)
    except TypeError:
        pass
    has_iface = hasattr(tok, "tokenize_with_weights") or is_top
    assert has_iface, f"tokenizer {tok.__name__} lacks tokenize interface"
    print(f"PASS {tok.__name__} top={is_top}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T5"
[[ "$T5" == PASS* ]] && add_reward 0.10

# ============================================================================
# F2P GATE 6 (0.15): differs from absolute-position XLM-RoBERTa.
# Jina CLIP v2 uses RoPE (rotary positional embeddings) and mean pooling.
# Either signal (RoPE OR mean pooling) is accepted. Fails on no-op.
# ============================================================================
echo "=== F2P-6: RoPE or mean-pooling signal present ==="
T6=$("$PYTHON" << 'PYEOF'
import re
src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read().lower()
rope = ("rope" in src or "rotary" in src or "freqs_cis" in src
        or "rope_theta" in src or "rotary_emb" in src or "apply_rope" in src
        or "precompute_freqs" in src)
mean_pool = ("mean_pool" in src or "mean pooling" in src
             or re.search(r"attention_mask.*sum\(", src) is not None
             or re.search(r"\.mean\(.*dim", src) is not None
             or "masked_mean" in src)
if rope or mean_pool:
    print(f"PASS rope={rope} mean_pool={mean_pool}")
else:
    print("FAIL")
PYEOF
)
echo "  $T6"
[[ "$T6" == PASS* ]] && add_reward 0.15

echo "=== TOTAL REWARD: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"
exit 0