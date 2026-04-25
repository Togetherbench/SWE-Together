#!/bin/bash
set +e

# Find workspace
WORKSPACE=""
for candidate in /workspace/ComfyUI /workspace/repo /workspace/comfyui; do
    if [ -f "$candidate/comfy/text_encoders/llama.py" ]; then
        WORKSPACE="$candidate"
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 3 -path '*/comfy/text_encoders/llama.py' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(dirname "$(dirname "$(dirname "$found")")")
    fi
fi

RESULT_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    echo "FATAL: workspace not found"
    echo "0.0" > "$RESULT_FILE"
    exit 0
fi

cd "$WORKSPACE"
TARGET_FILE="comfy/text_encoders/llama.py"

if [ ! -f "$TARGET_FILE" ]; then
    echo "FATAL: $TARGET_FILE not found"
    echo "0.0" > "$RESULT_FILE"
    exit 0
fi

SCORE=0.0

add_score() {
    SCORE=$(awk "BEGIN{printf \"%.4f\", $SCORE + $1}")
}

# Build a portable mock harness that exec's the source with mocked deps.
cat > /tmp/mock_setup.py << MOCKEOF
import sys, os, types, torch, math, logging
from typing import Optional, Any
from dataclasses import dataclass

WORKSPACE = "$WORKSPACE"
TARGET = os.path.join(WORKSPACE, "comfy/text_encoders/llama.py")

def _rms(x, w, e):
    v = x.pow(2).mean(-1, keepdim=True)
    return x * torch.rsqrt(v + e) * w

captured_masks = []
captured_q_shapes = []

def make_oafd():
    def fn(q, k2, v, heads, mask=None, skip_reshape=False):
        if mask is not None:
            captured_masks.append(mask.clone().detach().float())
        else:
            captured_masks.append(None)
        captured_q_shapes.append(tuple(q.shape))
        # q,k,v in skip_reshape format: [b, heads, seq, head_dim]
        s = q.shape[-1] ** -0.5
        sc = torch.matmul(q, k2.transpose(-2, -1)) * s
        if mask is not None:
            sc = sc + mask
        out = torch.softmax(sc, dim=-1).matmul(v)
        return out.transpose(1, 2).reshape(q.shape[0], q.shape[2], -1)
    return fn

def _oafd(*a, **k):
    return make_oafd()

source = open(TARGET).read()
cl = []
for l in source.split("\n"):
    s = l.strip()
    if s.startswith("from comfy") or s.startswith("import comfy"):
        continue
    if s.startswith("from . import") or s.startswith("from .") and "import" in s:
        continue
    cl.append(l)

class _common_dit:
    rms_norm = staticmethod(_rms)
class _ldm:
    common_dit = _common_dit
    class modules:
        class attention:
            optimized_attention_for_device = staticmethod(_oafd)
class _comfy:
    ldm = _ldm
    class model_management: pass

ns = {
    "__builtins__": __builtins__, "torch": torch, "nn": torch.nn,
    "dataclass": dataclass, "Optional": Optional, "Any": Any,
    "math": math, "logging": logging,
    "optimized_attention_for_device": _oafd,
    "qwen_vl": types.SimpleNamespace(),
    "comfy": _comfy,
}

try:
    exec("\n".join(cl), ns)
    LOAD_OK = True
    LOAD_ERR = None
except Exception as e:
    LOAD_OK = False
    LOAD_ERR = str(e)
MOCKEOF

#################################################################
# Test 1 [P2P, 0.05]: Syntax compile
#################################################################
echo "=== Test 1 [P2P]: Syntax compile ==="
python3 -c "compile(open('$TARGET_FILE').read(), '$TARGET_FILE', 'exec')" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "PASS"
    add_score 0.05
else
    echo "FAIL: syntax error"
    echo "0.0" > "$RESULT_FILE"
    exit 0
fi

#################################################################
# Test 2 [P2P, 0.05]: Module loads via mock harness
#################################################################
echo "=== Test 2 [P2P]: Module load ==="
T2=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL:", LOAD_ERR)
else:
    needed = ["Gemma3_4B_Config", "TransformerBlockGemma2", "precompute_freqs_cis"]
    missing = [n for n in needed if n not in ns]
    if missing:
        print("FAIL: missing", missing)
    else:
        print("PASS")
PYEOF
)
echo "Test 2: $T2"
[[ "$T2" == PASS* ]] && add_score 0.05

#################################################################
# Test 3 [F2P, 0.10]: Config sliding_attention pattern correct
# Per HF: every 6th layer (idx 5, 11, 17...) is global; rest local.
# Pattern of length 6: positions 0..4 sliding, position 5 global.
#################################################################
echo "=== Test 3 [F2P]: Config sliding_attention pattern ==="
T3=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
sa = config.sliding_attention
if not isinstance(sa, list) or len(sa) != 6:
    print("FAIL: expected list len 6, got", sa); raise SystemExit
sliding_count = sum(1 for v in sa if v and v != 0)
global_count = 6 - sliding_count
if sliding_count != 5 or global_count != 1:
    print(f"FAIL: expected 5 sliding/1 global, got {sliding_count}/{global_count}"); raise SystemExit
# global must be at position 5 (last) so that (idx+1)%6==0 for layer 5
if sa[5] and sa[5] != 0:
    print("FAIL: position 5 should be global"); raise SystemExit
for i in range(5):
    if not sa[i] or sa[i] == 0:
        print(f"FAIL: position {i} should be sliding"); raise SystemExit
# Window size should be 1024
windows = [v for v in sa if v and v != 0]
if not all(w == 1024 for w in windows):
    print(f"FAIL: window size should be 1024, got {windows}"); raise SystemExit
print("PASS")
PYEOF
)
echo "Test 3: $T3"
[[ "$T3" == "PASS" ]] && add_score 0.10

#################################################################
# Test 4 [F2P, 0.10]: Per-layer assignment to layers via index
# layer_idx 5,11 => global; layer_idx 0..4,6..10 => sliding
#################################################################
echo "=== Test 4 [F2P]: Per-layer index mapping ==="
T4=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
expected_global = [5, 11, 17, 23, 29, 33]
expected_sliding = [0, 1, 2, 3, 4, 6, 7, 10, 12, 16, 18]
try:
    for idx in expected_global:
        if idx >= config.num_hidden_layers: continue
        b = Block(config, index=idx, device="cpu", dtype=torch.float32)
        if b.sliding_attention and b.sliding_attention != 0:
            print(f"FAIL: layer {idx} should be global, got {b.sliding_attention}"); raise SystemExit
    for idx in expected_sliding:
        if idx >= config.num_hidden_layers: continue
        b = Block(config, index=idx, device="cpu", dtype=torch.float32)
        if not b.sliding_attention or b.sliding_attention == 0:
            print(f"FAIL: layer {idx} should be sliding, got {b.sliding_attention}"); raise SystemExit
except SystemExit:
    raise
except Exception as e:
    print(f"FAIL: instantiation error: {e}"); raise SystemExit
print("PASS")
PYEOF
)
echo "Test 4: $T4"
[[ "$T4" == "PASS" ]] && add_score 0.10

#################################################################
# Test 5 [F2P, 0.05]: Stale TODO/warning text removed
#################################################################
echo "=== Test 5 [F2P]: Stale warning removed ==="
T5_PASS=1
src=$(cat "$TARGET_FILE")
if echo "$src" | grep -qi "sliding attention not implemented"; then
    T5_PASS=0
fi
if echo "$src" | grep -q "TODO: implement.*sliding"; then
    T5_PASS=0
fi
if [ $T5_PASS -eq 1 ]; then
    echo "PASS"
    add_score 0.05
else
    echo "FAIL: stale TODO/warning still present"
fi

#################################################################
# Test 6 [F2P, 0.25]: Forward pass produces correct sliding mask
# Run on a sliding-attention layer, capture mask, verify:
#   - tokens beyond window are masked (-inf)
#   - tokens within window are visible (0)
#   - causal property preserved
#################################################################
echo "=== Test 6 [F2P]: Sliding window mask correctness ==="
T6=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

block = Block(config, index=0, device="cpu", dtype=torch.float32)
if not block.sliding_attention:
    print("FAIL: layer 0 not sliding"); raise SystemExit

window = block.sliding_attention
# Use small window to keep test fast: monkey-patch this instance only
test_window = 8
block.sliding_attention = test_window
seq_len = 24

torch.manual_seed(0)
x = torch.randn(1, seq_len, config.hidden_size)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
try:
    freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                       config.rope_scale, config.rope_dims, device="cpu")
except Exception as e:
    print(f"FAIL: precompute: {e}"); raise SystemExit

causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)
captured_masks.clear()

try:
    _ = block(x=x, attention_mask=causal, freqs_cis=freqs, optimized_attention=make_oafd())
except Exception as e:
    print(f"FAIL: forward crash: {e}"); raise SystemExit

if not captured_masks or captured_masks[0] is None:
    print("FAIL: no mask captured"); raise SystemExit

mask = captured_masks[0]
# Reduce to 2D [seq, seq]
while mask.dim() > 2:
    mask = mask[0]

NEG = -1e30
errs = []
# Check: for query q, key k:
#   if k > q : masked (causal)
#   if q - k >= window : masked (sliding)
#   if 0 <= q - k < window : visible (0)
for q in [3, 7, 10, 15, 20, 23]:
    for k in [0, 1, 5, 9, 14, 19, 22, 23]:
        if k >= seq_len or q >= seq_len: continue
        v = mask[q, k].item()
        if k > q:
            if v > NEG:
                errs.append(f"causal violated at q={q} k={k}: {v}")
        elif q - k >= test_window:
            if v > NEG:
                errs.append(f"sliding violated at q={q} k={k} (dist={q-k}, window={test_window}): {v}")
        else:
            if v < -1.0:
                errs.append(f"in-window blocked at q={q} k={k} (dist={q-k}): {v}")

if errs:
    print("FAIL:", errs[0])
    raise SystemExit
print("PASS")
PYEOF
)
echo "Test 6: $T6"
[[ "$T6" == "PASS" ]] && add_score 0.25

#################################################################
# Test 7 [F2P, 0.15]: Global layer must NOT have sliding mask applied
#################################################################
echo "=== Test 7 [F2P]: Global layer no sliding ==="
T7=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

# Find a global layer (should be index 5 with HF pattern)
global_idx = None
for idx in range(config.num_hidden_layers):
    b = Block(config, index=idx, device="cpu", dtype=torch.float32)
    if not b.sliding_attention or b.sliding_attention == 0:
        global_idx = idx
        break
if global_idx is None:
    print("FAIL: no global layer found"); raise SystemExit

block = Block(config, index=global_idx, device="cpu", dtype=torch.float32)
seq_len = 24
torch.manual_seed(1)
x = torch.randn(1, seq_len, config.hidden_size)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                   config.rope_scale, config.rope_dims, device="cpu")
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)

captured_masks.clear()
try:
    _ = block(x=x, attention_mask=causal, freqs_cis=freqs, optimized_attention=make_oafd())
except Exception as e:
    print(f"FAIL: forward crash: {e}"); raise SystemExit

if not captured_masks or captured_masks[0] is None:
    print("FAIL: no mask captured"); raise SystemExit
mask = captured_masks[0]
while mask.dim() > 2:
    mask = mask[0]

# All in-causal positions (q >= k) should be 0, no sliding restriction
NEG = -1e30
for q in range(seq_len):
    for k in range(q + 1):  # k <= q
        v = mask[q, k].item()
        if v < -1.0:
            print(f"FAIL: global layer masked q={q} k={k}: {v}")
            raise SystemExit
# Causal still holds
for q in range(seq_len):
    for k in range(q + 1, seq_len):
        v = mask[q, k].item()
        if v > NEG:
            print(f"FAIL: global layer causal broken q={q} k={k}: {v}")
            raise SystemExit
print("PASS")
PYEOF
)
echo "Test 7: $T7"
[[ "$T7" == "PASS" ]] && add_score 0.15

#################################################################
# Test 8 [F2P, 0.15]: Forward output is finite & differs from base
# (The base just emits a warning and uses no sliding mask, so output
# of a sliding layer with seq>window must differ from "no mask" run.)
#################################################################
echo "=== Test 8 [F2P]: Output differs from no-sliding-mask baseline ==="
T8=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

block = Block(config, index=0, device="cpu", dtype=torch.float32)
if not block.sliding_attention:
    print("FAIL: layer 0 not sliding"); raise SystemExit
block.sliding_attention = 4  # tiny window so it really matters
seq_len = 16
torch.manual_seed(7)
x = torch.randn(1, seq_len, config.hidden_size)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                   config.rope_scale, config.rope_dims, device="cpu")
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)

try:
    out = block(x=x.clone(), attention_mask=causal.clone(), freqs_cis=freqs, optimized_attention=make_oafd())
except Exception as e:
    print(f"FAIL: forward crash: {e}"); raise SystemExit

if not torch.isfinite(out).all():
    print("FAIL: non-finite output"); raise SystemExit

# Compare against a reference: same forward but with global-only causal
# (simulated by changing block to non-sliding via .sliding_attention=0)
# We can't easily flip behavior for base agents, but we can check the
# captured mask diverges from pure causal:
captured_masks.clear()
_ = block(x=x.clone(), attention_mask=causal.clone(), freqs_cis=freqs, optimized_attention=make_oafd())
m = captured_masks[0]
if m is None:
    print("FAIL: no mask"); raise SystemExit
while m.dim() > 2:
    m = m[0]
# Pure causal would have zero at (seq_len-1, 0); sliding with window=4 would have -inf
v = m[seq_len-1, 0].item()
if v > -1e10:
    print(f"FAIL: sliding mask not applied (last,0)={v}"); raise SystemExit
print("PASS")
PYEOF
)
echo "Test 8: $T8"
[[ "$T8" == "PASS" ]] && add_score 0.15

#################################################################
# Test 9 [F2P, 0.10]: Mask combines with provided attention_mask
# (must add, not replace) — we pass a non-causal extra mask and ensure
# both causal + sliding constraints survive.
#################################################################
echo "=== Test 9 [F2P]: Mask combines with provided attention_mask ==="
T9=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

block = Block(config, index=0, device="cpu", dtype=torch.float32)
if not block.sliding_attention:
    print("FAIL: layer 0 not sliding"); raise SystemExit
block.sliding_attention = 4
seq_len = 12
torch.manual_seed(3)
x = torch.randn(1, seq_len, config.hidden_size)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                   config.rope_scale, config.rope_dims, device="cpu")
# Provide an external mask that blocks position 2 entirely (column 2)
ext = torch.zeros(seq_len, seq_len)
ext[:, 2] = float("-inf")
# Combine with causal
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)
combined_in = ext + causal

captured_masks.clear()
try:
    _ = block(x=x, attention_mask=combined_in, freqs_cis=freqs, optimized_attention=make_oafd())
except Exception as e:
    print(f"FAIL: forward crash: {e}"); raise SystemExit

if not captured_masks or captured_masks[0] is None:
    print("FAIL: no mask"); raise SystemExit
m = captured_masks[0]
while m.dim() > 2:
    m = m[0]

# Position 2 must remain blocked everywhere
for q in range(seq_len):
    if m[q, 2].item() > -1e10:
        print(f"FAIL: external mask lost at q={q}, k=2: {m[q,2].item()}")
        raise SystemExit
# Causal must hold
if m[3, 5].item() > -1e10:
    print("FAIL: causal lost"); raise SystemExit
# Sliding must hold: q=11, k=0 (dist=11, window=4) blocked
if m[11, 0].item() > -1e10:
    print("FAIL: sliding lost when combining"); raise SystemExit
# Within window unblocked: q=11, k=10
if m[11, 10].item() < -1.0:
    print(f"FAIL: in-window blocked at (11,10): {m[11,10].item()}"); raise SystemExit
print("PASS")
PYEOF
)
echo "Test 9: $T9"
[[ "$T9" == "PASS" ]] && add_score 0.10

echo "=========================================="
echo "FINAL SCORE: $SCORE"
echo "$SCORE" > "$RESULT_FILE"
exit 0