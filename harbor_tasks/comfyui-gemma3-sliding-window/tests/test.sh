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


export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

# Find workspace
WORKSPACE=""
for candidate in /workspace/ComfyUI /workspace/repo /workspace/comfyui; do
    if [ -f "$candidate/comfy/text_encoders/llama.py" ]; then
        WORKSPACE="$candidate"
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 5 -path '*/comfy/text_encoders/llama.py' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(dirname "$(dirname "$(dirname "$found")")")
    fi
fi

RESULT_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD=0.0

emit_and_exit() {
    echo "$REWARD" > "$RESULT_FILE"
    exit 0
}

emit_zero_and_exit() {
    REWARD=0.0
    echo "0.0" > "$RESULT_FILE"
    exit 0
}

if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    echo "FATAL: workspace not found"
    emit_zero_and_exit
fi

cd "$WORKSPACE"
TARGET_FILE="comfy/text_encoders/llama.py"

if [ ! -f "$TARGET_FILE" ]; then
    echo "FATAL: $TARGET_FILE not found"
    emit_zero_and_exit
fi

add_score() {
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $1}")
}

# ==== P2P GATE: syntax must compile ====
python3 -c "compile(open('$TARGET_FILE').read(), '$TARGET_FILE', 'exec')" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "P2P GATE FAIL: syntax error"
    emit_zero_and_exit
fi

# Build a portable mock harness
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
captured_call_count = [0]

def make_oafd():
    def fn(q, k2, v, heads, mask=None, skip_reshape=False):
        captured_call_count[0] += 1
        if mask is not None:
            try:
                captured_masks.append(mask.clone().detach().float())
            except Exception:
                captured_masks.append(None)
        else:
            captured_masks.append(None)
        captured_q_shapes.append(tuple(q.shape))
        if skip_reshape:
            qq, kk, vv = q, k2, v
        else:
            qq, kk, vv = q, k2, v
        s = qq.shape[-1] ** -0.5
        sc = torch.matmul(qq, kk.transpose(-2, -1)) * s
        if mask is not None:
            sc = sc + mask
        out = torch.softmax(sc, dim=-1).matmul(vv)
        if skip_reshape:
            return out.transpose(1, 2).reshape(qq.shape[0], qq.shape[2], -1)
        return out
    return fn

def _oafd(*a, **k):
    return make_oafd()

source = open(TARGET).read()
cl = []
for l in source.split("\n"):
    s = l.strip()
    if s.startswith("from comfy") or s.startswith("import comfy"):
        continue
    if s.startswith("from . import") or (s.startswith("from .") and "import" in s):
        continue
    cl.append(l)

class _common_dit:
    rms_norm = staticmethod(_rms)
class _attention_mod:
    optimized_attention_for_device = staticmethod(_oafd)
class _modules_mod:
    attention = _attention_mod
class _ldm:
    common_dit = _common_dit
    modules = _modules_mod
class _model_management:
    pass
class _comfy:
    ldm = _ldm
    model_management = _model_management

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
    import traceback
    LOAD_OK = False
    LOAD_ERR = traceback.format_exc()
MOCKEOF

# ==== P2P GATE: module must load and required symbols exist ====
LOAD_RES=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL")
    print(LOAD_ERR)
else:
    needed = ["Gemma3_4B_Config", "TransformerBlockGemma2"]
    missing = [n for n in needed if n not in ns]
    if missing:
        print("FAIL")
        print("missing", missing)
    else:
        print("PASS")
PYEOF
)
if ! echo "$LOAD_RES" | head -1 | grep -q "^PASS$"; then
    echo "P2P GATE FAIL: module did not load"
    echo "$LOAD_RES"
    emit_zero_and_exit
fi

#################################################################
# F2P 1 [0.10]: Stale TODO/warning text removed (cleanup gate)
#################################################################
src=$(cat "$TARGET_FILE")
T1_PASS=1
if echo "$src" | grep -qi "sliding attention not implemented"; then
    T1_PASS=0
fi
if echo "$src" | grep -q "TODO: implement"; then
    T1_PASS=0
fi
if [ "$T1_PASS" = "1" ]; then
    add_score 0.10
    echo "F2P1 PASS (cleanup)"
else
    echo "F2P1 FAIL (stale TODO/warning still present)"
fi

#################################################################
# F2P 2 [0.15]: Config sliding_attention pattern correct
# Sliding positions [0..4], global at position 5, window=1024.
#################################################################
T2=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
sa = getattr(config, "sliding_attention", None)
if not isinstance(sa, list) or len(sa) != 6:
    print("FAIL: not list len 6"); raise SystemExit
def is_sliding(v):
    return bool(v) and v != 0
sliding_positions = [i for i, v in enumerate(sa) if is_sliding(v)]
global_positions = [i for i, v in enumerate(sa) if not is_sliding(v)]
if sliding_positions != [0,1,2,3,4] or global_positions != [5]:
    print(f"FAIL pattern: {sa}"); raise SystemExit
windows = [v for v in sa if is_sliding(v)]
if not all(w == 1024 for w in windows):
    print(f"FAIL window: {windows}"); raise SystemExit
print("PASS")
PYEOF
)
if echo "$T2" | grep -q "^PASS$"; then
    add_score 0.15
    echo "F2P2 PASS"
else
    echo "F2P2 FAIL: $T2"
fi

#################################################################
# F2P 3 [0.15]: Per-layer index mapping — layer 5 is global, 0-4 sliding.
#################################################################
T3=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
def is_sliding(v):
    return bool(v) and v != 0
try:
    b5 = Block(config, index=5, device="cpu", dtype=torch.float32)
    if is_sliding(b5.sliding_attention):
        print("FAIL: layer 5 sliding"); raise SystemExit
    b11 = Block(config, index=11, device="cpu", dtype=torch.float32)
    if is_sliding(b11.sliding_attention):
        print("FAIL: layer 11 sliding"); raise SystemExit
    for idx in [0,1,2,3,4,6,7,10]:
        b = Block(config, index=idx, device="cpu", dtype=torch.float32)
        if not is_sliding(b.sliding_attention):
            print(f"FAIL: layer {idx} not sliding"); raise SystemExit
        if b.sliding_attention != 1024:
            print(f"FAIL: layer {idx} window {b.sliding_attention}"); raise SystemExit
except SystemExit:
    raise
except Exception as e:
    print(f"FAIL: {e}"); raise SystemExit
print("PASS")
PYEOF
)
if echo "$T3" | grep -q "^PASS$"; then
    add_score 0.15
    echo "F2P3 PASS"
else
    echo "F2P3 FAIL: $T3"
fi

#################################################################
# F2P 4 [0.25]: Behavioral — sliding window mask actually applied at attention.
# Build a Gemma3 block with a tiny window and run forward; verify the mask
# passed into optimized_attention has -inf entries where (q - k) >= window.
#################################################################
T4=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL load"); raise SystemExit

import torch

# Build a minimal Gemma3-ish config by patching window size
try:
    Cfg = ns["Gemma3_4B_Config"]
    Block = ns["TransformerBlockGemma2"]
except Exception as e:
    print(f"FAIL symbols: {e}"); raise SystemExit

# Make a small config: shrink hidden sizes for speed by editing fields if dataclass
config = Cfg()

# Override sliding window to small value for testing
try:
    config.sliding_attention = [4, 4, 4, 4, 4, False]
except Exception as e:
    print(f"FAIL override: {e}"); raise SystemExit

# Try to shrink dimensions. If frozen, fall back to original.
seq_len = 12
hidden = config.hidden_size

# Build sliding-layer (idx=0) and global-layer (idx=5) blocks
try:
    block_local = Block(config, index=0, device="cpu", dtype=torch.float32)
    block_global = Block(config, index=5, device="cpu", dtype=torch.float32)
except Exception as e:
    print(f"FAIL block construct: {e}"); raise SystemExit

# Determine head_dim
head_dim = getattr(config, "head_dim", 128)
n_heads = config.num_attention_heads

# Build dummy x and freqs_cis shaped to bypass rope (rope needs (cos, sin) tuples)
x = torch.randn(1, seq_len, hidden, dtype=torch.float32)

# freqs_cis is expected to be a list/tuple of [local, global] each (cos, sin) of shape (seq_len, head_dim)
def make_freqs(seq_len, head_dim):
    pos = torch.arange(seq_len, dtype=torch.float32)
    inv = 1.0 / (10000 ** (torch.arange(0, head_dim, 2, dtype=torch.float32) / head_dim))
    freqs = torch.outer(pos, inv)
    cos = torch.cos(freqs).repeat_interleave(2, dim=-1)
    sin = torch.sin(freqs).repeat_interleave(2, dim=-1)
    return (cos, sin)

freqs_local = make_freqs(seq_len, head_dim)
freqs_global = make_freqs(seq_len, head_dim)
freqs_cis = [freqs_local, freqs_global]

# Get the optimized_attention callable used by self_attn
oa = ns["optimized_attention_for_device"]("cpu")

# Reset capture lists
captured_masks.clear()
captured_q_shapes.clear()
captured_call_count[0] = 0

# Local layer forward — should apply sliding window mask
try:
    _ = block_local(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=oa)
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL local fwd: {e}"); raise SystemExit

if len(captured_masks) < 1:
    print("FAIL: no attn call captured for local"); raise SystemExit

mask_local = captured_masks[-1]
if mask_local is None:
    print("FAIL: local layer passed no mask (sliding window not applied)"); raise SystemExit

# Validate sliding window structure: window=4
# For q-row i, key j is allowed iff (i - j) < 4 (and j <= i for causal? not enforced here)
# We don't require causal — only that positions with i - j >= 4 are -inf.
window = 4
m2d = mask_local
# Reduce to 2D (seq, seq) by squeezing batch/head dims
while m2d.dim() > 2:
    m2d = m2d[0]
if m2d.shape[-2:] != (seq_len, seq_len):
    print(f"FAIL mask shape: {tuple(m2d.shape)}"); raise SystemExit

ok = True
checked_blocked = 0
checked_allowed = 0
for i in range(seq_len):
    for j in range(seq_len):
        v = m2d[i, j].item()
        if (i - j) >= window:
            # Must be -inf or extremely negative
            if not (v < -1e30 or v == float("-inf")):
                ok = False
            else:
                checked_blocked += 1
        # We don't insist on what's at (j - i) >= window since that depends on whether mask is symmetric or causal-style.
        # But within window (|i - j| < window), and for j <= i, mask should not be -inf.
        if (i - j) >= 0 and (i - j) < window:
            if v < -1e30 or v == float("-inf"):
                ok = False
            else:
                checked_allowed += 1

if not ok:
    print(f"FAIL mask values wrong (blocked={checked_blocked}, allowed={checked_allowed})"); raise SystemExit
if checked_blocked < 1 or checked_allowed < 1:
    print(f"FAIL mask coverage too low (blocked={checked_blocked}, allowed={checked_allowed})"); raise SystemExit

# Now global layer — should NOT apply sliding window (mask should be None or no -inf entries from sliding)
captured_masks.clear()
captured_q_shapes.clear()
try:
    _ = block_global(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=oa)
except Exception as e:
    print(f"FAIL global fwd: {e}"); raise SystemExit

mask_global = captured_masks[-1] if captured_masks else None
if mask_global is not None:
    g2d = mask_global
    while g2d.dim() > 2:
        g2d = g2d[0]
    # Global layer must NOT have -inf at sliding-window positions (i.e., shouldn't be sliding)
    # check position (5,0): with window=4, i-j=5 >= 4 — local would block, global must not
    if g2d.shape[-2:] == (seq_len, seq_len):
        if g2d[5, 0].item() < -1e30:
            print("FAIL: global layer applied sliding mask"); raise SystemExit

print("PASS")
PYEOF
)
if echo "$T4" | grep -q "^PASS$"; then
    add_score 0.25
    echo "F2P4 PASS (behavioral mask)"
else
    echo "F2P4 FAIL: $T4"
fi

#################################################################
# F2P 5 [0.15]: Mask combines with existing attention_mask (additive)
# Pass an attention_mask of zeros (no-op causal-like) and verify sliding mask is added,
# not replaced.
#################################################################
T5=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
import torch
Cfg = ns["Gemma3_4B_Config"]
Block = ns["TransformerBlockGemma2"]
config = Cfg()
try:
    config.sliding_attention = [4, 4, 4, 4, 4, False]
except Exception as e:
    print(f"FAIL: {e}"); raise SystemExit

seq_len = 10
hidden = config.hidden_size
head_dim = getattr(config, "head_dim", 128)

try:
    block_local = Block(config, index=0, device="cpu", dtype=torch.float32)
except Exception as e:
    print(f"FAIL block: {e}"); raise SystemExit

x = torch.randn(1, seq_len, hidden, dtype=torch.float32)

def make_freqs(seq_len, head_dim):
    pos = torch.arange(seq_len, dtype=torch.float32)
    inv = 1.0 / (10000 ** (torch.arange(0, head_dim, 2, dtype=torch.float32) / head_dim))
    freqs = torch.outer(pos, inv)
    cos = torch.cos(freqs).repeat_interleave(2, dim=-1)
    sin = torch.sin(freqs).repeat_interleave(2, dim=-1)
    return (cos, sin)

freqs_cis = [make_freqs(seq_len, head_dim), make_freqs(seq_len, head_dim)]
oa = ns["optimized_attention_for_device"]("cpu")

# Existing attention mask: a distinctive marker value at position (0,0) we can detect
existing = torch.zeros(seq_len, seq_len, dtype=torch.float32)
MARKER = -7.5
existing[0, 0] = MARKER  # within window so should remain combined
existing[1, 1] = MARKER

captured_masks.clear()
try:
    _ = block_local(x, attention_mask=existing, freqs_cis=freqs_cis, optimized_attention=oa)
except Exception as e:
    print(f"FAIL fwd: {e}"); raise SystemExit

if not captured_masks or captured_masks[-1] is None:
    print("FAIL: no mask after combining"); raise SystemExit

m = captured_masks[-1]
while m.dim() > 2:
    m = m[0]

# Marker at (0,0) and (1,1): these are within window (i==j), should be preserved (==MARKER, not 0, not -inf)
v00 = m[0,0].item()
v11 = m[1,1].item()
if abs(v00 - MARKER) > 1e-3 or abs(v11 - MARKER) > 1e-3:
    print(f"FAIL: existing mask not preserved (v00={v00}, v11={v11})"); raise SystemExit

# Sliding window must still be applied: (5,0) should be -inf-ish
window = 4
v50 = m[5,0].item()
if not (v50 < -1e30 or v50 == float("-inf")):
    print(f"FAIL: sliding not applied after combining (v50={v50})"); raise SystemExit

print("PASS")
PYEOF
)
if echo "$T5" | grep -q "^PASS$"; then
    add_score 0.15
    echo "F2P5 PASS (mask combine)"
else
    echo "F2P5 FAIL: $T5"
fi

#################################################################
# F2P 6 [0.10]: Local layer uses local RoPE (freqs_cis[0]),
# global layer uses global RoPE (freqs_cis[1]).
# We probe by giving distinguishable freqs per index and reading rotated q.
#################################################################
T6=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
import torch
Cfg = ns["Gemma3_4B_Config"]
Block = ns["TransformerBlockGemma2"]
config = Cfg()
try:
    config.sliding_attention = [4, 4, 4, 4, 4, False]
except Exception as e:
    print(f"FAIL: {e}"); raise SystemExit

seq_len = 6
hidden = config.hidden_size
head_dim = getattr(config, "head_dim", 128)

try:
    block_local = Block(config, index=0, device="cpu", dtype=torch.float32)
    block_global = Block(config, index=5, device="cpu", dtype=torch.float32)
except Exception as e:
    print(f"FAIL: {e}"); raise SystemExit

x = torch.randn(1, seq_len, hidden, dtype=torch.float32)

# Use very distinct freqs: freqs_cis[0]=(zeros,zeros) so cos=0,sin=0 means rotated q = 0
# freqs_cis[1]=(ones,zeros) means rotated q = q (cos=1,sin=0 -> identity)
zeros_cs = (torch.zeros(seq_len, head_dim), torch.zeros(seq_len, head_dim))
ones_cs = (torch.ones(seq_len, head_dim), torch.zeros(seq_len, head_dim))
freqs_cis = [zeros_cs, ones_cs]

oa = ns["optimized_attention_for_device"]("cpu")

# Local layer: should use freqs_cis[0] = zeros => q after rope ~ 0 => attention scores all equal
captured_masks.clear()
captured_q_shapes.clear()
captured_call_count[0] = 0

# Capture q values too — extend mock
import torch as _t
q_capture = []
def capture_fn(q, k2, v, heads, mask=None, skip_reshape=False):
    q_capture.append(q.detach().clone())
    s = q.shape[-1] ** -0.5
    sc = _t.matmul(q, k2.transpose(-2, -1)) * s
    if mask is not None:
        sc = sc + mask
    out = _t.softmax(sc, dim=-1).matmul(v)
    if skip_reshape:
        return out.transpose(1,2).reshape(q.shape[0], q.shape[2], -1)
    return out

try:
    _ = block_local(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=capture_fn)
except Exception as e:
    print(f"FAIL local fwd: {e}"); raise SystemExit

if not q_capture:
    print("FAIL: no q captured local"); raise SystemExit
q_local = q_capture[-1]
local_mag = q_local.abs().mean().item()

q_capture.clear()
try:
    _ = block_global(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=capture_fn)
except Exception as e:
    print(f"FAIL global fwd: {e}"); raise SystemExit

if not q_capture:
    print("FAIL: no q captured global"); raise SystemExit
q_global = q_capture[-1]
global_mag = q_global.abs().mean().item()

# With freqs_local=zeros and freqs_global=ones, local rotated q should be much smaller magnitude
# than global rotated q.
if not (local_mag < global_mag * 0.5):
    print(f"FAIL rope select: local_mag={local_mag} global_mag={global_mag}"); raise SystemExit

print("PASS")
PYEOF
)
if echo "$T6" | grep -q "^PASS$"; then
    add_score 0.10
    echo "F2P6 PASS (rope per-layer)"
else
    echo "F2P6 FAIL: $T6"
fi

echo "FINAL REWARD: $REWARD"
echo "$REWARD" > "$RESULT_FILE"
exit 0