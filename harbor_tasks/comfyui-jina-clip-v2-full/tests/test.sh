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

# ------------------------------------------------------------------
# Shared helper: discover the wrapper class and call it generically
# ------------------------------------------------------------------
cat > /tmp/_jina_helpers.py << 'HELPEREOF'
import sys, inspect, os
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

def find_inner_sdclip(instance):
    """Find an inner SDClipModel-like submodule (the one with .transformer)."""
    from comfy import sd1_clip
    for name, child in instance.named_modules():
        if isinstance(child, sd1_clip.SDClipModel) and child is not instance:
            return child
        if hasattr(child, "transformer") and isinstance(getattr(child, "transformer", None), torch.nn.Module):
            if child is not instance:
                return child
    if hasattr(instance, "transformer"):
        return instance
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

# ===================================================================
# T1 (0.05): File exists, parses, isn't a stub
# ===================================================================
echo "=== T1: file exists + non-stub ==="
T1=$("$PYTHON" << 'PYEOF'
import os, ast
p = "/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
if not os.path.exists(p):
    print("FAIL:missing"); raise SystemExit
src = open(p).read()
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}"); raise SystemExit
classes = [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]
code_lines = sum(1 for l in src.splitlines() if l.strip() and not l.strip().startswith("#"))
if len(classes) < 3 or code_lines < 100:
    print(f"FAIL:stub classes={len(classes)} lines={code_lines}"); raise SystemExit
print(f"PASS classes={len(classes)} lines={code_lines}")
PYEOF
)
echo "  $T1"
[[ "$T1" == PASS* ]] && add_reward 0.05

# ===================================================================
# T2 (0.05): Module imports cleanly; wrapper + tokenizer classes exist
# ===================================================================
echo "=== T2: module imports + wrapper + tokenizer classes ==="
T2=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls
try:
    mod = import_module()
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:import:{e}"); raise SystemExit
cls = find_wrapper_cls(mod)
if cls is None:
    print("FAIL:no_wrapper"); raise SystemExit
tok = None
for name in dir(mod):
    obj = getattr(mod, name)
    if isinstance(obj, type) and "tokenizer" in name.lower():
        tok = obj; break
if tok is None:
    print("FAIL:no_tokenizer_class"); raise SystemExit
print(f"PASS wrapper={cls.__name__} tokenizer={tok.__name__}")
PYEOF
)
echo "  $T2"
[[ "$T2" == PASS* ]] && add_reward 0.05

# ===================================================================
# T3 (0.08): Wrapper instantiates on CPU
# ===================================================================
echo "=== T3: wrapper instantiates ==="
T3=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls)
    import torch
    assert isinstance(inst, torch.nn.Module), "wrapper not nn.Module"
    print("PASS")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T3"
[[ "$T3" == PASS* ]] && add_reward 0.08

# ===================================================================
# T4 (0.15): encode_token_weights produces a real tensor (forward pass)
# ===================================================================
echo "=== T4: encode forward pass produces real tensor ==="
T4=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance, encode, extract_cond_pooled
import torch
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls)
    inst.eval()
    toks = [[(0, 1.0), (42, 1.0), (100, 1.0), (2, 1.0)]]
    with torch.no_grad():
        r = encode(inst, toks)
    cond, pooled = extract_cond_pooled(r)
    if cond is None or not hasattr(cond, "shape"):
        print(f"FAIL:no_cond r_type={type(r).__name__}"); raise SystemExit
    if cond.dim() < 2:
        print(f"FAIL:cond_dim={cond.dim()} shape={tuple(cond.shape)}"); raise SystemExit
    # Expect hidden_size 1024 for XLM-RoBERTa-large
    last = cond.shape[-1]
    if last != 1024:
        print(f"FAIL:hidden_size={last} (expected 1024)"); raise SystemExit
    if not torch.isfinite(cond).all():
        print("FAIL:nonfinite"); raise SystemExit
    print(f"PASS cond_shape={tuple(cond.shape)}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T4"
[[ "$T4" == PASS* ]] && add_reward 0.15

# ===================================================================
# T5 (0.10): XLM-RoBERTa config sanity (vocab=250002, 24 layers, 16 heads)
# ===================================================================
echo "=== T5: architecture config matches XLM-RoBERTa-large ==="
T5=$("$PYTHON" << 'PYEOF'
import os, json, glob
d = "/workspace/ComfyUI/comfy/text_encoders"
cfgs = glob.glob(os.path.join(d, "jina*config*.json")) + glob.glob(os.path.join(d, "*jina*config*.json"))
ok = False
for c in cfgs:
    try:
        j = json.load(open(c))
    except Exception:
        continue
    vs = j.get("vocab_size")
    nh = j.get("num_hidden_layers")
    ah = j.get("num_attention_heads")
    hs = j.get("hidden_size")
    if vs == 250002 and nh == 24 and ah == 16 and hs == 1024:
        ok = True
        print(f"PASS cfg={os.path.basename(c)}")
        break
if not ok:
    # Try inferring from module source
    src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read()
    if "250002" in src and "1024" in src:
        print("PASS inline")
        ok = True
if not ok:
    print("FAIL")
PYEOF
)
echo "  $T5"
[[ "$T5" == PASS* ]] && add_reward 0.10

# ===================================================================
# T6 (0.10): Jina-specific architectural choice present (RoPE or mean pooling)
# These are the two key documented departures from vanilla XLM-RoBERTa.
# ===================================================================
echo "=== T6: jina-specific RoPE / mean-pool implementation ==="
T6=$("$PYTHON" << 'PYEOF'
import re
src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read().lower()
score = 0
# RoPE indicators
rope_terms = ["rope", "rotary", "freqs_cis", "rotate_half", "apply_rope", "precompute"]
if any(t in src for t in rope_terms):
    score += 1
# Mean-pool indicators (or attention-mask weighted pool)
pool_terms = ["mean_pool", "mean pool", "mean pooling", "mean(dim", ".mean(", "attention_mask"]
if any(t in src for t in pool_terms):
    score += 1
if score >= 1:
    print(f"PASS score={score}")
else:
    print("FAIL")
PYEOF
)
echo "  $T6"
[[ "$T6" == PASS* ]] && add_reward 0.10

# ===================================================================
# T7 (0.10): Output sequence dim matches input token count (real per-token output)
# ===================================================================
echo "=== T7: output respects input sequence length ==="
T7=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance, encode, extract_cond_pooled
import torch
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls); inst.eval()
    short = [[(0,1.0),(5,1.0),(2,1.0)]]
    long_ = [[(0,1.0)]+[(i+10,1.0) for i in range(12)]+[(2,1.0)]]
    with torch.no_grad():
        rs = encode(inst, short)
        rl = encode(inst, long_)
    cs, _ = extract_cond_pooled(rs)
    cl, _ = extract_cond_pooled(rl)
    if cs is None or cl is None:
        print("FAIL:none"); raise SystemExit
    # Sequence dimension: usually shape[-2]; tolerate small offsets (added BOS/EOS)
    sl_s = cs.shape[-2] if cs.dim() >= 2 else None
    sl_l = cl.shape[-2] if cl.dim() >= 2 else None
    if sl_s is None or sl_l is None:
        print(f"FAIL:dim cs={tuple(cs.shape)} cl={tuple(cl.shape)}"); raise SystemExit
    if sl_l <= sl_s:
        print(f"FAIL:not_growing s={sl_s} l={sl_l}"); raise SystemExit
    # outputs should differ (real forward, not constant)
    if cs.shape == cl.shape:
        print(f"FAIL:same_shape {tuple(cs.shape)}"); raise SystemExit
    print(f"PASS s={sl_s} l={sl_l}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T7"
[[ "$T7" == PASS* ]] && add_reward 0.10

# ===================================================================
# T8 (0.10): State dict has roberta-style keys with correct shapes
# ===================================================================
echo "=== T8: transformer state_dict has roberta-shaped weights ==="
T8=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance, find_inner_sdclip
import torch, re
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls)
    inner = find_inner_sdclip(inst)
    if inner is None:
        # Try the wrapper itself
        if hasattr(inst, "transformer"):
            inner = inst
        else:
            print("FAIL:no_inner"); raise SystemExit
    transformer = inner.transformer
    sd = transformer.state_dict()
    keys = list(sd.keys())
    if len(keys) < 50:
        print(f"FAIL:too_few_keys={len(keys)}"); raise SystemExit
    # Embedding shape
    emb_keys = [k for k in keys if "word_embedding" in k or "embed_tokens" in k]
    if not emb_keys:
        print(f"FAIL:no_emb sample={keys[:5]}"); raise SystemExit
    emb = sd[emb_keys[0]]
    if emb.shape[0] != 250002 or emb.shape[1] != 1024:
        print(f"FAIL:emb_shape={tuple(emb.shape)}"); raise SystemExit
    # Count distinct layers (look for 'layer.N' or 'layers.N' patterns)
    layer_idxs = set()
    for k in keys:
        m = re.search(r"layers?\.(\d+)\.", k)
        if m:
            layer_idxs.add(int(m.group(1)))
    if len(layer_idxs) < 24:
        print(f"FAIL:layers={len(layer_idxs)}"); raise SystemExit
    print(f"PASS keys={len(keys)} layers={len(layer_idxs)} emb={tuple(emb.shape)}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T8"
[[ "$T8" == PASS* ]] && add_reward 0.10

# ===================================================================
# T9 (0.10): Different inputs produce different outputs (transformer actually runs)
# ===================================================================
echo "=== T9: different inputs -> different outputs ==="
T9=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/tmp")
from _jina_helpers import import_module, find_wrapper_cls, make_instance, encode, extract_cond_pooled
import torch
try:
    mod = import_module()
    cls = find_wrapper_cls(mod)
    inst = make_instance(cls); inst.eval()
    a = [[(0,1.0),(42,1.0),(100,1.0),(2,1.0)]]
    b = [[(0,1.0),(999,1.0),(7777,1.0),(2,1.0)]]
    with torch.no_grad():
        ra = encode(inst, a)
        rb = encode(inst, b)
    ca, _ = extract_cond_pooled(ra)
    cb, _ = extract_cond_pooled(rb)
    if ca is None or cb is None:
        print("FAIL:none"); raise SystemExit
    if ca.shape != cb.shape:
        print(f"FAIL:shape_mismatch {tuple(ca.shape)} vs {tuple(cb.shape)}"); raise SystemExit
    diff = (ca - cb).abs().mean().item()
    if diff < 1e-5:
        print(f"FAIL:identical diff={diff}"); raise SystemExit
    print(f"PASS diff={diff:.4f}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T9"
[[ "$T9" == PASS* ]] && add_reward 0.10

# ===================================================================
# T10 (0.10): Integration in comfy/sd.py (registration + detection)
# ===================================================================
echo "=== T10: comfy/sd.py registration ==="
T10=$("$PYTHON" << 'PYEOF'
sd_src = open("/workspace/ComfyUI/comfy/sd.py").read()
score = 0
if "jina_clip_2" in sd_src:
    score += 1
if "JINA_CLIP_2" in sd_src or "jina_clip_2" in sd_src.lower():
    score += 1
# Detection rule referencing roberta
if "roberta" in sd_src.lower():
    score += 1
if score >= 2:
    print(f"PASS score={score}")
else:
    print(f"FAIL score={score}")
PYEOF
)
echo "  $T10"
[[ "$T10" == PASS* ]] && add_reward 0.10

# ===================================================================
# T11 (0.07): comfy.sd module still imports cleanly (P2P regression guard)
# ===================================================================
echo "=== T11: comfy.sd imports without breakage ==="
T11=$("$PYTHON" << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass
try:
    import comfy.sd
    # Detection function still callable
    fn = getattr(comfy.sd, "detect_te_model", None)
    if fn is None:
        print("FAIL:no_detect")
    else:
        # Empty sd should return None (or at least not crash)
        r = fn({})
        print(f"PASS detect_empty={r}")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
)
echo "  $T11"
[[ "$T11" == PASS* ]] && add_reward 0.07

# ===================================================================
# Final report
# ===================================================================
echo ""
echo "================ FINAL REWARD: $REWARD ================"
echo "$REWARD" > "$REWARD_FILE"
exit 0