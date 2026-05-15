#!/bin/bash
set +e
# [v041-fix] torch/CUDA infra probe
mkdir -p /logs/verifier
if ! python3 -c "import torch; assert torch.cuda.is_available() if False else True" 2>/dev/null; then
    echo "INFRA: torch / CUDA unavailable - marking infra_fault and exiting"
    echo "1" > /logs/verifier/infra_fault
    echo "0.00" > /logs/verifier/reward.txt
    exit 0
fi

export PATH="/workspace/ComfyUI/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
REWARD=0.0

add_reward() {
    REWARD=$(awk "BEGIN { v = $REWARD + $1; if (v > 1.0) v = 1.0; printf \"%.4f\", v }")
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

# Disable CUDA diagnostic
sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    /workspace/ComfyUI/comfy/model_management.py 2>/dev/null || true

PYTHON="/workspace/ComfyUI/bin/python3"
if ! "$PYTHON" -c "import torch" 2>/dev/null; then
    if python3 -c "import torch" 2>/dev/null; then
        PYTHON="python3"
    else
        echo "FATAL: no python with torch"
        finish
    fi
fi
export PYTHONPATH="/workspace/ComfyUI:${PYTHONPATH:-}"

JINA_FILE="/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py"
SD_FILE="/workspace/ComfyUI/comfy/sd.py"

# ============================================================================
# P2P GATE 1: comfy.sd must import (regression check)
# ============================================================================
"$PYTHON" -c "import sys; sys.path.insert(0,'/workspace/ComfyUI'); import comfy.sd" 2>/tmp/sd_import_err
if [ $? -ne 0 ]; then
    echo "P2P FAIL: comfy.sd import broken"
    cat /tmp/sd_import_err
    finish
fi

# ============================================================================
# P2P GATE 2: file must exist (no-op short-circuit)
# ============================================================================
if [ ! -f "$JINA_FILE" ]; then
    echo "P2P FAIL: $JINA_FILE missing — no-op base"
    finish
fi

# Empty/trivial file → no-op
LINES=$(wc -l < "$JINA_FILE" 2>/dev/null || echo 0)
if [ "$LINES" -lt 30 ]; then
    echo "P2P FAIL: file too short ($LINES lines) — likely stub"
    finish
fi

# ----------------------------------------------------------------------------
# Helpers (shared probe utilities)
# ----------------------------------------------------------------------------
cat > /tmp/_jina_probe.py << 'PYEOF'
import sys, os, ast, importlib, traceback
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

import torch

def load_module():
    if "comfy.text_encoders.jina_clip_2" in sys.modules:
        del sys.modules["comfy.text_encoders.jina_clip_2"]
    return importlib.import_module("comfy.text_encoders.jina_clip_2")

def all_classes(mod):
    out = []
    for name in dir(mod):
        obj = getattr(mod, name)
        if isinstance(obj, type) and obj.__module__ == mod.__name__:
            out.append((name, obj))
    return out

def find_wrapper_cls(mod):
    from comfy import sd1_clip
    cands = []
    for name, obj in all_classes(mod):
        n = name.lower()
        if "tokenizer" in n:
            continue
        try:
            if issubclass(obj, sd1_clip.SD1ClipModel) and obj is not sd1_clip.SD1ClipModel:
                cands.append((0, obj))
                continue
        except TypeError: pass
        try:
            if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
                cands.append((1, obj))
                continue
        except TypeError: pass
    cands.sort(key=lambda x: x[0])
    return cands[0][1] if cands else None

def find_inner_cls(mod):
    """Find the SDClipModel-derived inner text-encoder class (not the SD1ClipModel container)."""
    from comfy import sd1_clip
    for name, obj in all_classes(mod):
        if "tokenizer" in name.lower():
            continue
        try:
            if issubclass(obj, sd1_clip.SDClipModel) and obj is not sd1_clip.SDClipModel:
                return obj
        except TypeError: pass
    return None

def find_tokenizer_top(mod):
    from comfy import sd1_clip
    for name, obj in all_classes(mod):
        if "tokenizer" not in name.lower():
            continue
        try:
            if issubclass(obj, sd1_clip.SD1Tokenizer):
                return obj
        except TypeError: pass
    # fallback
    for name, obj in all_classes(mod):
        if "tokenizer" in name.lower():
            return obj
    return None

def find_tokenizer_inner(mod):
    from comfy import sd1_clip
    cands = []
    for name, obj in all_classes(mod):
        if "tokenizer" not in name.lower():
            continue
        try:
            if issubclass(obj, sd1_clip.SDTokenizer) and not issubclass(obj, sd1_clip.SD1Tokenizer):
                cands.append(obj)
        except TypeError: pass
    return cands[0] if cands else None

def find_torch_text_model(mod):
    """Find the underlying nn.Module text encoder class (the one that takes a config dict)."""
    cands = []
    for name, obj in all_classes(mod):
        if "tokenizer" in name.lower():
            continue
        try:
            if issubclass(obj, torch.nn.Module):
                # Heuristic: takes config_dict in __init__
                import inspect
                try:
                    sig = inspect.signature(obj.__init__)
                    params = list(sig.parameters.keys())
                    if "config_dict" in params or "num_tokens" in params:
                        cands.append(obj)
                except Exception:
                    pass
        except TypeError: pass
    return cands
PYEOF

# ============================================================================
# F2P GATE 1 (0.10): module imports cleanly + has wrapper + tokenizer classes
# ============================================================================
echo "=== F2P-1 (weight 0.06): import + class structure ==="
R1=$("$PYTHON" << 'PYEOF' 2>&1
import sys; sys.path.insert(0, "/tmp"); sys.path.insert(0, "/workspace/ComfyUI")
from _jina_probe import load_module, find_wrapper_cls, find_tokenizer_top, find_inner_cls, find_tokenizer_inner
try:
    mod = load_module()
except Exception as e:
    import traceback; traceback.print_exc()
    print("FAIL"); raise SystemExit
w = find_wrapper_cls(mod)
t = find_tokenizer_top(mod)
inner = find_inner_cls(mod)
tinner = find_tokenizer_inner(mod)
if w is None or t is None or inner is None:
    print(f"FAIL wrapper={w} tok={t} inner={inner}")
    raise SystemExit
print("PASS")
PYEOF
)
echo "$R1"
if echo "$R1" | grep -q "^PASS"; then
    add_reward 0.06
    echo "  +0.06"
fi

# ============================================================================
# F2P GATE 2 (0.15): instantiation + forward pass with random weights
# Tests that the wrapper actually constructs an nn.Module and can run.
# ============================================================================
echo "=== F2P-2 (weight 0.09): wrapper instantiates + runs forward ==="
R2=$("$PYTHON" << 'PYEOF' 2>&1
import sys, os
sys.path.insert(0, "/tmp"); sys.path.insert(0, "/workspace/ComfyUI")
import torch
from _jina_probe import load_module, find_inner_cls

try:
    mod = load_module()
    InnerCls = find_inner_cls(mod)
    if InnerCls is None:
        print("FAIL no_inner"); raise SystemExit
    inst = InnerCls(device="cpu", dtype=torch.float32, model_options={})
    if not hasattr(inst, "transformer"):
        print("FAIL no_transformer"); raise SystemExit
    # Try a forward pass with small token input
    tokens = torch.tensor([[0, 100, 200, 300, 2, 1, 1, 1]], dtype=torch.long)
    inst.eval()
    with torch.no_grad():
        try:
            out = inst(tokens)
        except Exception as e:
            # Try alternate signatures
            try:
                out = inst.transformer(tokens, attention_mask=None)
            except Exception as e2:
                print(f"FAIL forward: {e} / {e2}")
                raise SystemExit
    # Output should be a tuple (cond, pooled) or similar
    if out is None:
        print("FAIL out_none"); raise SystemExit
    # Extract first tensor
    def first_tensor(x):
        if isinstance(x, torch.Tensor): return x
        if isinstance(x, (tuple, list)):
            for el in x:
                t = first_tensor(el)
                if t is not None: return t
        return None
    t = first_tensor(out)
    if t is None or t.dim() < 2:
        print(f"FAIL bad_shape: {type(out)}"); raise SystemExit
    if t.shape[-1] != 1024:
        print(f"FAIL hidden={t.shape[-1]} expected 1024")
        raise SystemExit
    print(f"PASS shape={tuple(t.shape)}")
except SystemExit:
    raise
except Exception as e:
    import traceback; traceback.print_exc()
    print("FAIL exc")
PYEOF
)
echo "$R2"
if echo "$R2" | grep -q "^PASS"; then
    add_reward 0.09
    echo "  +0.09"
fi

# ============================================================================
# F2P GATE 3 (0.20): config has correct XLM-RoBERTa-large architecture params
# vocab=250002, hidden=1024, layers=24, heads=16, intermediate=4096
# Plus the json file must exist alongside
# ============================================================================
echo "=== F2P-3 (weight 0.12): config dimensions correct ==="
R3=$("$PYTHON" << 'PYEOF' 2>&1
import os, json, glob
d = "/workspace/ComfyUI/comfy/text_encoders"
candidates = glob.glob(os.path.join(d, "jina*clip*2*.json")) + glob.glob(os.path.join(d, "jina_clip_2*.json"))
if not candidates:
    # config might be inline in the .py file
    src = open(os.path.join(d, "jina_clip_2.py")).read()
    # Look for hidden_size etc inline
    if "250002" in src and "1024" in src and ("24" in src) and ("4096" in src):
        print("PARTIAL_INLINE")
        raise SystemExit
    print("FAIL no_config"); raise SystemExit

required = {
    "vocab_size": 250002,
    "hidden_size": 1024,
    "num_hidden_layers": 24,
    "num_attention_heads": 16,
    "intermediate_size": 4096,
}
best_score = 0
for cfg_path in candidates:
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except Exception:
        continue
    score = sum(1 for k,v in required.items() if cfg.get(k) == v)
    if score > best_score:
        best_score = score

if best_score == len(required):
    print("PASS")
elif best_score >= 3:
    print(f"PARTIAL {best_score}/{len(required)}")
else:
    print(f"FAIL {best_score}/{len(required)}")
PYEOF
)
echo "$R3"
if echo "$R3" | grep -q "^PASS"; then
    add_reward 0.12
    echo "  +0.12"
elif echo "$R3" | grep -q "^PARTIAL"; then
    add_reward 0.06
    echo "  +0.06 (partial)"
fi

# ============================================================================
# F2P GATE 4 (0.15): tokenizer special tokens correct (XLM-R: BOS=0, PAD=1, EOS=2)
# Probe via instantiated inner tokenizer / state
# ============================================================================
echo "=== F2P-4 (weight 0.09): special tokens BOS=0, PAD=1, EOS=2 ==="
R4=$("$PYTHON" << 'PYEOF' 2>&1
import sys, os, re
sys.path.insert(0, "/tmp"); sys.path.insert(0, "/workspace/ComfyUI")
from _jina_probe import load_module, find_inner_cls, find_tokenizer_inner

try:
    mod = load_module()
except Exception as e:
    print(f"FAIL import: {e}"); raise SystemExit

InnerCls = find_inner_cls(mod)
src_jina = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read()

# Check via source for special_tokens dict
ok_specials = False
m = re.search(r'special_tokens\s*=\s*\{[^}]*\}', src_jina)
if m:
    blk = m.group(0)
    has_start0 = re.search(r'["\']start["\']\s*:\s*0', blk) is not None
    has_pad1 = re.search(r'["\']pad["\']\s*:\s*1', blk) is not None
    has_end2 = re.search(r'["\']end["\']\s*:\s*2', blk) is not None
    if has_start0 and has_pad1 and has_end2:
        ok_specials = True

if not ok_specials:
    # Try instantiating
    try:
        inst = InnerCls(device="cpu", dtype=None, model_options={})
        st = getattr(inst, "special_tokens", None)
        if isinstance(st, dict):
            if st.get("start") == 0 and st.get("pad") == 1 and st.get("end") == 2:
                ok_specials = True
    except Exception:
        pass

if ok_specials:
    print("PASS")
else:
    print("FAIL")
PYEOF
)
echo "$R4"
if echo "$R4" | grep -q "^PASS"; then
    add_reward 0.09
    echo "  +0.09"
fi

# ============================================================================
# F2P GATE 5 (0.15): RoPE positional embeddings used (NOT absolute embeddings)
# This is the key architectural difference that distinguishes a careful
# implementation from a copy-paste of plain XLM-RoBERTa.
# ============================================================================
echo "=== F2P-5 (weight 0.09): uses RoPE (no absolute position embeddings) ==="
R5=$("$PYTHON" << 'PYEOF' 2>&1
import re
src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read().lower()

# Must mention rope / rotary
has_rope_term = ("rope" in src) or ("rotary" in src)
# Should compute or apply RoPE-style rotations: cos/sin tables + rotate_half
has_rotate_half = "rotate_half" in src or "apply_rope" in src or ("cos" in src and "sin" in src and "rotary" in src) or "freqs_cis" in src or "rope_theta" in src or "rotary_emb_base" in src or "precompute" in src
# Must NOT be using a plain absolute position_embeddings layer (that would be standard BERT)
# Allow the keyword to appear in comments mentioning the architectural change
abs_pos_used = False
# Look for nn.Embedding(... max_position_embeddings ...) in the module
if re.search(r'nn\.embedding\s*\(\s*[^,]*max_position', src) or re.search(r'operations\.embedding\s*\(\s*[^,]*max_position', src):
    abs_pos_used = True
if "position_embeddings" in src and "self.position_embeddings" in src:
    # Likely declaring an absolute position embedding layer
    abs_pos_used = True

if has_rope_term and has_rotate_half and not abs_pos_used:
    print("PASS")
elif has_rope_term and not abs_pos_used:
    print("PARTIAL")
else:
    print(f"FAIL rope_term={has_rope_term} rotate={has_rotate_half} abs={abs_pos_used}")
PYEOF
)
echo "$R5"
if echo "$R5" | grep -q "^PASS"; then
    add_reward 0.09
    echo "  +0.09"
elif echo "$R5" | grep -q "^PARTIAL"; then
    add_reward 0.04
    echo "  +0.04 (partial)"
fi

# ============================================================================
# F2P GATE 6 (0.15): mean pooling over non-pad tokens (NOT CLS pooling)
# Probe behaviorally: outputs with different attention masks must differ.
# ============================================================================
echo "=== F2P-6 (weight 0.09): mean-pooling over masked tokens ==="
R6=$("$PYTHON" << 'PYEOF' 2>&1
import sys, os, re
sys.path.insert(0, "/tmp"); sys.path.insert(0, "/workspace/ComfyUI")
import torch
from _jina_probe import load_module, find_inner_cls

src = open("/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py").read().lower()
# Source-level check: mean pooling somewhere
has_mean_pooling_term = ("mean" in src and "pool" in src) or "mean_pool" in src or "mean pooling" in src
# Should enable_attention_masks (because mean pool requires real mask)
has_attn_masks = "enable_attention_masks=true" in src.replace(" ","")

# Behavioral probe: pooled output should depend on mask (mean pool gives different values
# for sequences with different valid lengths, even with same first token).
behavioral_ok = False
try:
    mod = load_module()
    InnerCls = find_inner_cls(mod)
    if InnerCls is not None:
        inst = InnerCls(device="cpu", dtype=torch.float32, model_options={})
        inst.eval()
        torch.manual_seed(0)
        # Token sequences sharing a CLS token but differing in body
        t1 = torch.tensor([[0, 100, 200, 2, 1, 1, 1, 1]], dtype=torch.long)
        t2 = torch.tensor([[0, 100, 999, 888, 777, 666, 555, 2]], dtype=torch.long)
        with torch.no_grad():
            try:
                o1 = inst(t1)
                o2 = inst(t2)
                def get_pooled(o):
                    if isinstance(o, (tuple, list)):
                        # Common: (cond, pooled, ...) — pooled often shape (B, D)
                        for x in o:
                            if isinstance(x, torch.Tensor) and x.dim() == 2:
                                return x
                    return None
                p1 = get_pooled(o1); p2 = get_pooled(o2)
                if p1 is not None and p2 is not None:
                    diff = (p1 - p2).abs().mean().item()
                    if diff > 1e-4:
                        behavioral_ok = True
            except Exception as e:
                pass
except Exception:
    pass

score = sum([has_mean_pooling_term, has_attn_masks, behavioral_ok])
if score >= 2:
    print(f"PASS ({score}/3)")
elif score == 1:
    print(f"PARTIAL ({score}/3)")
else:
    print(f"FAIL ({score}/3)")
PYEOF
)
echo "$R6"
if echo "$R6" | grep -q "^PASS"; then
    add_reward 0.09
    echo "  +0.09"
elif echo "$R6" | grep -q "^PARTIAL"; then
    add_reward 0.04
    echo "  +0.04 (partial)"
fi

# ============================================================================
# F2P GATE 7 (0.10): ComfyUI integration in sd.py (TEModel + detect + dispatch)
# Tests the completeness of integration into the main loader path.
# ============================================================================
echo "=== F2P-7 (weight 0.06): sd.py integration ==="
R7=$("$PYTHON" << 'PYEOF' 2>&1
import re
src = open("/workspace/ComfyUI/comfy/sd.py").read()

# Need: import of jina_clip_2, TEModel enum entry, detect branch, dispatch branch
has_import = "comfy.text_encoders.jina_clip_2" in src
has_enum = re.search(r'\bJINA_CLIP_2\s*=\s*\d+', src) is not None
has_detect = bool(re.search(r'TEModel\.JINA_CLIP_2', src))
# Dispatch branch: must reference JinaClip class for clip_target.clip
has_dispatch = bool(re.search(r'clip_target\.clip\s*=\s*comfy\.text_encoders\.jina_clip_2\.', src))
has_dispatch_tok = bool(re.search(r'clip_target\.tokenizer\s*=\s*comfy\.text_encoders\.jina_clip_2\.', src))

score = sum([has_import, has_enum, has_detect, has_dispatch, has_dispatch_tok])
print(f"score={score}/5  imp={has_import} enum={has_enum} det={has_detect} disp={has_dispatch} tok={has_dispatch_tok}")
if score == 5:
    print("PASS")
elif score >= 3:
    print("PARTIAL")
else:
    print("FAIL")
PYEOF
)
echo "$R7"
if echo "$R7" | grep -q "^PASS$"; then
    add_reward 0.06
    echo "  +0.06"
elif echo "$R7" | grep -q "^PARTIAL$"; then
    add_reward 0.03
    echo "  +0.03 (partial)"
fi

# ============================================================================
# Summary (existing gates)
# ============================================================================
echo ""
echo "=== EXISTING GATES REWARD: $REWARD ==="

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
> "$GATES_FILE"

echo "=== Upstream F2P gate: jina_clip_2.py syntax + config JSON ==="
if python3 -c "import ast, json; ast.parse(open('/workspace/ComfyUI/comfy/text_encoders/jina_clip_2.py').read()); d=json.load(open('/workspace/ComfyUI/comfy/text_encoders/jina_clip_2_config.json')); assert d.get('hidden_size')==1024 and d.get('vocab_size')==250002 and d.get('num_hidden_layers')==24" 2>/dev/null; then
    echo '{"id": "f2p_upstream_pyfile_and_config", "passed": true, "detail": "jina_clip_2.py is valid Python and config JSON has correct dimensions"}' >> "$GATES_FILE"
    echo "  PASSED"
else
    echo '{"id": "f2p_upstream_pyfile_and_config", "passed": false, "detail": "jina_clip_2.py missing or invalid, or config JSON missing or has wrong dimensions"}' >> "$GATES_FILE"
    echo "  FAILED"
fi

echo "=== Upstream F2P gate: sd.py JINA_CLIP_2 integration ==="
if python3 -c "import re,sys; src=open('/workspace/ComfyUI/comfy/sd.py').read(); ok=('comfy.text_encoders.jina_clip_2' in src) and bool(re.search(r'JINA_CLIP_2\s*=\s*\d+',src)) and ('TEModel.JINA_CLIP_2' in src); sys.exit(0 if ok else 1)" 2>/dev/null; then
    echo '{"id": "f2p_upstream_sdpy_integration", "passed": true, "detail": "sd.py has import, enum, and detect for JINA_CLIP_2"}' >> "$GATES_FILE"
    echo "  PASSED"
else
    echo '{"id": "f2p_upstream_sdpy_integration", "passed": false, "detail": "sd.py missing import, enum, or detect for JINA_CLIP_2"}' >> "$GATES_FILE"
    echo "  FAILED"
fi

echo "=== Upstream P2P gate: sd.py valid Python syntax ==="
if python3 -c "import ast; ast.parse(open('/workspace/ComfyUI/comfy/sd.py').read())" 2>/dev/null; then
    echo '{"id": "p2p_upstream_sdpy_syntax", "passed": true, "detail": "sd.py is valid Python"}' >> "$GATES_FILE"
    echo "  PASSED"
else
    echo '{"id": "p2p_upstream_sdpy_syntax", "passed": false, "detail": "sd.py has syntax errors"}' >> "$GATES_FILE"
    echo "  FAILED"
fi

# Upstream reward adjustment
python3 << 'UPSTREAM_REWARD_EOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_pyfile_and_config": 0.20, "f2p_upstream_sdpy_integration": 0.20}
P2P_REGRESSION = ["p2p_upstream_sdpy_syntax"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
# weighted-replace formula (c8bc168a standard, replaces additive)
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
UPSTREAM_REWARD_EOF

# ---- end inner-claude upstream gates ----

echo ""
FINAL_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "0.0")
echo "=== FINAL REWARD: $FINAL_REWARD ==="