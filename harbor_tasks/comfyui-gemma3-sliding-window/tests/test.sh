#!/bin/bash
# Verifier for comfyui-gemma3-sliding-window task
# Tests that the Gemma3 sliding window attention is correctly implemented
# F2P = fail-to-pass (fails on base, passes on correct fix)
# P2P = pass-to-pass (passes on both base and correct fix)
set +e

WORKSPACE="/workspace/repo"
RESULT_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

cd "$WORKSPACE"

TARGET_FILE="comfy/text_encoders/llama.py"
SCORE=0

if [ ! -f "$TARGET_FILE" ]; then
    echo "FATAL: $TARGET_FILE not found"
    echo "0.0" > "$RESULT_FILE"
    exit 0
fi

# Shared Python helper: exec the target file with mocked heavy deps (CUDA-free).
# This IS behavioral testing: we exec the ACTUAL source code and test real objects.
cat > /tmp/mock_setup.py << 'MOCKEOF'
import sys, types, torch, math, logging
from typing import Optional, Any
from dataclasses import dataclass

def _rms(x, w, e):
    v = x.pow(2).mean(-1, keepdim=True)
    return x * torch.rsqrt(v + e) * w

captured_masks = []

def _oafd(*a, **k):
    def fn(q, k2, v, heads, mask=None, skip_reshape=False):
        if mask is not None:
            captured_masks.append(mask.clone().detach())
        else:
            captured_masks.append(None)
        s = q.shape[-1] ** -0.5
        sc = torch.matmul(q, k2.transpose(-2, -1)) * s
        if mask is not None:
            sc = sc + mask
        return torch.softmax(sc, dim=-1).matmul(v).transpose(1,2).reshape(q.shape[0], q.shape[2], -1)
    return fn

source = open("comfy/text_encoders/llama.py").read()
cl = [l for l in source.split("\n")
      if not l.strip().startswith("from comfy")
      and not l.strip().startswith("import comfy")
      and not l.strip().startswith("from . import")]

class _comfy:
    class ldm:
        class common_dit:
            rms_norm = staticmethod(_rms)
    class model_management: pass

ns = {"__builtins__": __builtins__, "torch": torch, "nn": torch.nn,
      "dataclass": dataclass, "Optional": Optional, "Any": Any,
      "math": math, "logging": logging,
      "optimized_attention_for_device": _oafd,
      "qwen_vl": type("M",(),{})(), "comfy": _comfy}
exec("\n".join(cl), ns)
MOCKEOF

#################################################################
# Test 1 [P2P, weight 0.05]: Syntax/compile gate
# Passes on unmodified base AND on correct fix.
#################################################################
echo "=== Test 1 [P2P]: Syntax compile check ==="
python3 -c "compile(open('$TARGET_FILE').read(), '$TARGET_FILE', 'exec')" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "PASS"
    SCORE=$(python3 -c "print($SCORE + 0.05)")
else
    echo "FAIL: syntax error in $TARGET_FILE"
    echo "0.0" > "$RESULT_FILE"
    exit 0
fi

#################################################################
# Test 2 [F2P, weight 0.15]: Config correctness
# Instantiates Gemma3_4B_Config and checks sliding_attention
# pattern: majority sliding windows, every 6th layer global.
# Base has [False,False,False,False,False,1024] => FAILS
#################################################################
echo "=== Test 2 [F2P]: Config sliding_attention pattern ==="
T2=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

config = ns["Gemma3_4B_Config"]()
sa = config.sliding_attention
if not isinstance(sa, list) or len(sa) < 2:
    print("FAIL: sliding_attention not a valid list"); sys.exit(0)

sliding = [v for v in sa if v and v != 0]
global_l = [v for v in sa if not v or v == 0]
if len(sliding) <= len(global_l):
    print("FAIL: majority should be sliding, got %d sliding vs %d global" % (len(sliding), len(global_l)))
    sys.exit(0)
if not all(isinstance(w, int) and w > 0 for w in sliding):
    print("FAIL: sliding window values must be positive integers"); sys.exit(0)
if len(global_l) < 1:
    print("FAIL: need at least one global attention layer"); sys.exit(0)
print("PASS")
PYEOF
)
echo "Test 2: $T2"
if [ "$T2" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.15)")
fi

#################################################################
# Test 3 [F2P, weight 0.15]: Per-layer sliding_attention
# Instantiates TransformerBlockGemma2 at various indices.
# Layers 0-4 must have sliding, layer 5 must be global.
# Base has inverted pattern => FAILS
#################################################################
echo "=== Test 3 [F2P]: Per-layer sliding_attention ==="
T3=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]

b5 = Block(config, index=5, device="cpu", dtype=torch.float32)
if b5.sliding_attention and b5.sliding_attention != 0:
    print("FAIL: layer 5 should be global, got sliding_attention=%s" % b5.sliding_attention)
    sys.exit(0)

for idx in range(5):
    b = Block(config, index=idx, device="cpu", dtype=torch.float32)
    if not b.sliding_attention or b.sliding_attention == 0:
        print("FAIL: layer %d should have sliding attention, got %s" % (idx, b.sliding_attention))
        sys.exit(0)

print("PASS")
PYEOF
)
echo "Test 3: $T3"
if [ "$T3" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.15)")
fi

#################################################################
# Test 4 [F2P, weight 0.10]: Warning removal
# The "sliding attention not implemented" warning must be removed.
# Base has the warning => FAILS
#################################################################
echo "=== Test 4 [F2P]: Warning removal ==="
T4=$(python3 << 'PYEOF'
source = open("comfy/text_encoders/llama.py").read()
if "sliding attention not implemented" in source.lower():
    print("FAIL: warning still present")
else:
    print("PASS")
PYEOF
)
echo "Test 4: $T4"
if [ "$T4" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.10)")
fi

#################################################################
# Test 5 [F2P, weight 0.20]: Forward pass sliding window mask
# Runs forward() on a sliding-attention block and captures the
# attention mask. Verifies tokens outside window are masked.
# Base has no mask => FAILS
#################################################################
echo "=== Test 5 [F2P]: Forward pass sliding window mask ==="
T5=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

block = Block(config, index=0, device="cpu", dtype=torch.float32)
if not block.sliding_attention:
    print("FAIL: layer 0 has no sliding attention (config not fixed)")
    sys.exit(0)

window = block.sliding_attention
seq_len = window * 2 if isinstance(window, int) and window > 0 else 16
batch = 1
hidden = config.hidden_size

torch.manual_seed(42)
x = torch.randn(batch, seq_len, hidden)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                   config.rope_scale, config.rope_dims, device="cpu")
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)
oafd_fn = _oafd()

captured_masks.clear()
try:
    _ = block(x=x, attention_mask=causal, freqs_cis=freqs, optimized_attention=oafd_fn)
except Exception as e:
    print("FAIL: forward crashed: %s" % str(e)[:200])
    sys.exit(0)

if not captured_masks:
    print("FAIL: no mask captured"); sys.exit(0)

mask = captured_masks[0]
if mask is None:
    print("FAIL: mask is None"); sys.exit(0)

m = mask
while m.dim() > 2:
    m = m[0]

if seq_len > window:
    far_val = m[-1, 0].item()
    near_val = m[-1, -2].item()
    if far_val == 0.0 or (far_val > -1e9 and far_val != float("-inf")):
        print("FAIL: pos 0 should be masked from pos %d (window=%d), got %.4f" % (seq_len-1, window, far_val))
        sys.exit(0)
    if near_val < -1e9 or near_val == float("-inf"):
        print("FAIL: pos %d should be visible from pos %d, got %.4f" % (seq_len-2, seq_len-1, near_val))
        sys.exit(0)

print("PASS")
PYEOF
)
echo "Test 5: $T5"
if [ "$T5" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.20)")
fi

#################################################################
# Test 6 [F2P, weight 0.15]: Global layer forward produces valid output
# A global attention layer must NOT apply sliding window masking.
# If sliding window mask is incorrectly applied to global layers
# (e.g. with window=0), attention collapses and output contains NaN.
# Base has no mask at all => FAILS (Test 2/3 already fail so this
# is only reachable when config is fixed)
#################################################################
echo "=== Test 6 [F2P]: Global layer valid output ==="
T6=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

# Global layer (index 5, should NOT have sliding window)
block_global = Block(config, index=5, device="cpu", dtype=torch.float32)
if block_global.sliding_attention and block_global.sliding_attention != 0:
    print("FAIL: layer 5 should be global, got sliding_attention=%s" % block_global.sliding_attention)
    sys.exit(0)

seq_len = 32
batch = 1
hidden = config.hidden_size

torch.manual_seed(123)
x = torch.randn(batch, seq_len, hidden)
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs = precompute(config.head_dim, pos_ids, config.rope_theta,
                   config.rope_scale, config.rope_dims, device="cpu")
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)
oafd_fn = _oafd()

captured_masks.clear()
try:
    out = block_global(x=x, attention_mask=causal, freqs_cis=freqs, optimized_attention=oafd_fn)
except Exception as e:
    err = str(e)
    print("FAIL: global layer forward crashed: %s" % err[:200])
    sys.exit(0)

# Check the mask passed to attention: global layer should NOT apply sliding
# window masking. The mask should allow all causally-valid positions.
if not captured_masks:
    print("FAIL: no mask captured for global layer")
    sys.exit(0)

mask = captured_masks[0]
if mask is None:
    # No mask at all is also acceptable for global attention (just causal)
    print("PASS")
    sys.exit(0)

m = mask
while m.dim() > 2:
    m = m[0]

# Row seq_len-1, col 0: last token should see first token in global attention
val_far = m[-1, 0].item()
if val_far < -1e9 or val_far == float("-inf"):
    print("FAIL: global layer masks position 0 from position %d (sliding window incorrectly applied to global layer)" % (seq_len - 1))
    sys.exit(0)

# Row 4, col 0: token 4 should see token 0 in global attention
val_near = m[4, 0].item()
if val_near < -1e9 or val_near == float("-inf"):
    print("FAIL: global layer masks position 0 from position 4 (should allow full causal)")
    sys.exit(0)

# Diagonal: every token should attend to itself
diag_val = m[seq_len // 2, seq_len // 2].item()
if diag_val < -1e9 or diag_val == float("-inf"):
    print("FAIL: global layer masks self-attention on diagonal")
    sys.exit(0)

print("PASS")
PYEOF
)
echo "Test 6: $T6"
if [ "$T6" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.15)")
fi

#################################################################
# Test 7 [F2P, weight 0.15]: Rope frequency assignment
# Sliding (local) layers must use freqs_cis[0] (local theta),
# global layers must use freqs_cis[1] (global theta).
# Base has these swapped => FAILS
#################################################################
echo "=== Test 7 [F2P]: Rope frequency assignment ==="
T7=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
precompute = ns["precompute_freqs_cis"]

# Use a TrackingList to detect which freqs_cis index is accessed
class TrackingList:
    def __init__(self, items):
        self.items = list(items)
        self.accesses = []
    def __getitem__(self, idx):
        self.accesses.append(idx)
        return self.items[idx]
    def __iter__(self):
        return iter(self.items)
    def __len__(self):
        return len(self.items)

seq_len = 16
pos_ids = torch.arange(0, seq_len).unsqueeze(0)
freqs_pair = precompute(config.head_dim, pos_ids, config.rope_theta,
                        config.rope_scale, config.rope_dims, device="cpu")
causal = torch.empty(seq_len, seq_len).fill_(float("-inf")).triu_(1)
oafd_fn = _oafd()

# Test sliding layer (index=0)
block_sl = Block(config, index=0, device="cpu", dtype=torch.float32)
if not block_sl.sliding_attention:
    print("FAIL: layer 0 has no sliding attention"); sys.exit(0)

torch.manual_seed(42)
x = torch.randn(1, seq_len, config.hidden_size)
tracker_sl = TrackingList(freqs_pair)
captured_masks.clear()
try:
    block_sl(x=x.clone(), attention_mask=causal.clone(), freqs_cis=tracker_sl, optimized_attention=oafd_fn)
except Exception as e:
    print("FAIL: sliding layer forward crashed: %s" % str(e)[:200])
    sys.exit(0)

if not tracker_sl.accesses:
    print("FAIL: freqs_cis was not indexed for sliding layer"); sys.exit(0)
sl_idx = tracker_sl.accesses[0]

# Test global layer (index=5)
block_gl = Block(config, index=5, device="cpu", dtype=torch.float32)
tracker_gl = TrackingList(freqs_pair)
captured_masks.clear()
try:
    block_gl(x=x.clone(), attention_mask=causal.clone(), freqs_cis=tracker_gl, optimized_attention=oafd_fn)
except Exception as e:
    # Global layer might crash due to other bugs; check what we captured
    if not tracker_gl.accesses:
        print("FAIL: freqs_cis not indexed for global layer"); sys.exit(0)

gl_idx = tracker_gl.accesses[0] if tracker_gl.accesses else -1

# Sliding (local) should use freqs_cis[0], global should use freqs_cis[1]
# rope_theta = [10000.0, 1000000.0] -> index 0 = local, index 1 = global
if sl_idx != 0:
    print("FAIL: sliding layer used freqs_cis[%d], expected [0] (local theta)" % sl_idx)
    sys.exit(0)
if gl_idx != 1:
    print("FAIL: global layer used freqs_cis[%d], expected [1] (global theta)" % gl_idx)
    sys.exit(0)

print("PASS")
PYEOF
)
echo "Test 7: $T7"
if [ "$T7" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.15)")
fi

#################################################################
# Test 8 [P2P, weight 0.05]: Class structure sanity
# Verifies key classes exist and can be instantiated.
# Passes on base AND on correct fix.
#################################################################
echo "=== Test 8 [P2P]: Class structure sanity ==="
T8=$(python3 << 'PYEOF'
import sys
exec(open("/tmp/mock_setup.py").read())

errs = []
for c in ["Gemma3_4B_Config", "Gemma2_2B_Config", "Llama2Config",
          "TransformerBlockGemma2", "TransformerBlock", "Attention", "MLP"]:
    if c not in ns:
        errs.append("missing: " + c)

try:
    cfg = ns["Gemma3_4B_Config"]()
    if cfg.transformer_type != "gemma3":
        errs.append("wrong transformer_type")
except Exception as e:
    errs.append("Gemma3_4B_Config init: " + str(e)[:80])

try:
    cfg2 = ns["Gemma2_2B_Config"]()
    b = ns["TransformerBlockGemma2"](cfg2, index=0, device="cpu", dtype=torch.float32)
except Exception as e:
    errs.append("TransformerBlockGemma2 init: " + str(e)[:80])

if errs:
    print("FAIL: " + "; ".join(errs))
else:
    print("PASS")
PYEOF
)
echo "Test 8: $T8"
if [ "$T8" = "PASS" ]; then
    SCORE=$(python3 -c "print($SCORE + 0.05)")
fi

#################################################################
# Final score
#################################################################
echo ""
echo "==============================="
echo "Final score: $SCORE"
echo "==============================="
echo "$SCORE" > "$RESULT_FILE"
