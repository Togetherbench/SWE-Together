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
    found=$(find /workspace -maxdepth 4 -path '*/comfy/text_encoders/llama.py' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(dirname "$(dirname "$(dirname "$found")")")
    fi
fi

RESULT_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD=0.0

emit_zero_and_exit() {
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
    if s.startswith("from . import") or (s.startswith("from .") and "import" in s):
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
    import traceback
    LOAD_OK = False
    LOAD_ERR = traceback.format_exc()
MOCKEOF

# ==== P2P GATE: module must load ====
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
# F2P 1 [0.15]: Config sliding_attention pattern correct
# Base has [False, False, False, False, False, 1024] which is the
# WRONG pattern (only layer 5 = sliding, rest global).
# Correct pattern: positions 0-4 sliding, position 5 global.
#################################################################
T1=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
sa = config.sliding_attention
if not isinstance(sa, list) or len(sa) != 6:
    print("FAIL"); raise SystemExit
def is_sliding(v):
    return bool(v) and v != 0
sliding_positions = [i for i, v in enumerate(sa) if is_sliding(v)]
global_positions = [i for i, v in enumerate(sa) if not is_sliding(v)]
if sliding_positions != [0,1,2,3,4] or global_positions != [5]:
    print("FAIL"); raise SystemExit
windows = [v for v in sa if is_sliding(v)]
if not all(w == 1024 for w in windows):
    print("FAIL"); raise SystemExit
print("PASS")
PYEOF
)
if [ "$T1" = "PASS" ]; then
    add_score 0.15
    echo "F2P1 PASS"
else
    echo "F2P1 FAIL"
fi

#################################################################
# F2P 2 [0.15]: Per-layer mapping — layer 5 (and 11,17,...) is global,
# others sliding. This requires correct config + correct index mapping.
# Buggy base: layer 5 -> 1024 (sliding), layer 0 -> False (global) — INVERTED.
#################################################################
T2=$(python3 << 'PYEOF'
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL"); raise SystemExit
config = ns["Gemma3_4B_Config"]()
Block = ns["TransformerBlockGemma2"]
def is_sliding(v):
    return bool(v) and v != 0
try:
    # layer 5 should be global
    b5 = Block(config, index=5, device="cpu", dtype=torch.float32)
    if is_sliding(b5.sliding_attention):
        print("FAIL: layer 5 sliding"); raise SystemExit
    # layer 11 should be global
    b11 = Block(config, index=11, device="cpu", dtype=torch.float32)
    if is_sliding(b11.sliding_attention):
        print("FAIL: layer 11 sliding"); raise SystemExit
    # layers 0,1,2,3,4 should be sliding
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
if [ "$T2" = "PASS" ]; then
    add_score 0.15
    echo "F2P2 PASS"
else
    echo "F2P2 FAIL"
fi

#################################################################
# F2P 3 [0.10]: Stale TODO/warning text removed
# Base has both. Real fix removes them.
#################################################################
src=$(cat "$TARGET_FILE")
T3_PASS=1
if echo "$src" | grep -qi "sliding attention not implemented"; then
    T3_PASS=0
fi
if echo "$src" | grep -qi "TODO: implement"; then
    # Specifically the sliding-attention TODO
    if echo "$src" | grep -B1 -A1 "TODO: implement" | grep -qi "sliding"; then
        T3_PASS=0
    fi
fi
if [ $T3_PASS -eq 1 ]; then
    add_score 0.10
    echo "F2P3 PASS"
else
    echo "F2P3 FAIL"
fi

#################################################################
# F2P 4 [0.35]: Sliding window mask correctness via forward pass
# Run the gemma3 model on a sliding-attention layer with seq_len > window
# (using a small window override) and verify:
#   - mask passed to attention has -inf for keys outside window
#   - mask has 0 (or finite) for keys inside window
#   - causal direction respected (queries cannot attend to keys >= window positions in past)
#################################################################
T4=$(python3 << 'PYEOF'
import torch
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
try:
    config = ns["Gemma3_4B_Config"]()
    Block = ns["TransformerBlockGemma2"]

    # Use small window to make seq_len > window feasible
    config.sliding_attention = [4, 4, 4, 4, 4, False]
    config.num_hidden_layers = 6
    config.hidden_size = 64
    config.num_attention_heads = 4
    config.num_key_value_heads = 2
    config.intermediate_size = 128
    config.head_dim = 16

    block = Block(config, index=0, device="cpu", dtype=torch.float32)

    seq_len = 12
    x = torch.randn(1, seq_len, 64)
    # Build freqs_cis: gemma3 expects [local, global], each (seq_len, head_dim/2) complex-style.
    # Try common shapes; accept failure gracefully.
    head_dim = 16
    # try (cos, sin) pair or complex tensor; simplest: complex
    t = torch.arange(seq_len).float().unsqueeze(1)
    inv = 1.0 / (10000 ** (torch.arange(0, head_dim, 2).float() / head_dim))
    freqs = t * inv.unsqueeze(0)
    freqs_cis_local = torch.polar(torch.ones_like(freqs), freqs)
    inv2 = 1.0 / (1000000 ** (torch.arange(0, head_dim, 2).float() / head_dim))
    freqs2 = t * inv2.unsqueeze(0)
    freqs_cis_global = torch.polar(torch.ones_like(freqs2), freqs2)
    freqs_cis = (freqs_cis_local, freqs_cis_global)

    captured_masks.clear()
    captured_q_shapes.clear()
    try:
        out = block(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=ns["optimized_attention_for_device"]())
    except Exception as e:
        # Try alternative freqs_cis as tuple of (cos, sin)
        cos_l = torch.cos(freqs); sin_l = torch.sin(freqs)
        cos_g = torch.cos(freqs2); sin_g = torch.sin(freqs2)
        freqs_cis = ((cos_l, sin_l), (cos_g, sin_g))
        captured_masks.clear()
        captured_q_shapes.clear()
        try:
            out = block(x, attention_mask=None, freqs_cis=freqs_cis, optimized_attention=ns["optimized_attention_for_device"]())
        except Exception as e2:
            print(f"FAIL: forward error: {e2}"); raise SystemExit

    if not captured_masks or captured_masks[0] is None:
        print("FAIL: no mask captured"); raise SystemExit

    mask = captured_masks[0]
    # mask shape may be [seq, seq] or broadcastable to [b, h, seq, seq]
    while mask.dim() > 2:
        mask = mask[0]
    if mask.shape[-2:] != (seq_len, seq_len):
        print(f"FAIL: mask shape {mask.shape}"); raise SystemExit

    window = 4
    # Required: mask[i, j] == -inf when (i - j) >= window  (key too far in past)
    # Required: mask[i, j] is finite (not -inf) when 0 <= (i - j) < window
    fails = []
    for i in range(seq_len):
        for j in range(seq_len):
            v = float(mask[i, j])
            d = i - j
            if d >= window:
                if v > -1e30:
                    fails.append(f"({i},{j}) d={d} expected -inf got {v}")
            elif 0 <= d < window:
                if v < -1e30:
                    fails.append(f"({i},{j}) d={d} expected finite got {v}")
    if fails:
        print("FAIL:", fails[:3]); raise SystemExit
    print("PASS")
except SystemExit:
    raise
except Exception as e:
    import traceback
    print(f"FAIL: {e}")
    traceback.print_exc()
PYEOF
)
if [ "$T4" = "PASS" ]; then
    add_score 0.35
    echo "F2P4 PASS"
else
    echo "F2P4 FAIL: $T4"
fi

#################################################################
# F2P 5 [0.15]: Sliding mask combines with existing attention mask
# Provide a non-None attention_mask and verify final mask still has the
# sliding constraint (out-of-window positions are -inf).
#################################################################
T5=$(python3 << 'PYEOF'
import torch
exec(open("/tmp/mock_setup.py").read())
if not LOAD_OK:
    print("FAIL: load"); raise SystemExit
try:
    config = ns["Gemma3_4B_Config"]()
    Block = ns["TransformerBlockGemma2"]
    config.sliding_attention = [3, 3, 3, 3, 3, False]
    config.num_hidden_layers = 6
    config.hidden_size = 64
    config.num_attention_heads = 4
    config.num_key_value_heads = 2
    config.intermediate_size = 128
    config.head_dim = 16

    block = Block(config, index=0, device="cpu", dtype=torch.float32)

    seq_len = 10
    x = torch.randn(1, seq_len, 64)
    head_dim = 16
    t = torch.arange(seq_len).float().unsqueeze(1)
    inv = 1.0 / (10000 ** (torch.arange(0, head_dim, 2).float() / head_dim))
    freqs = t * inv.unsqueeze(0)
    inv2 = 1.0 / (1000000 ** (torch.arange(0, head_dim, 2).float() / head_dim))
    freqs2 = t * inv2.unsqueeze(0)

    # Provide an existing mask with all zeros (causal/full visible) — sliding must still cut it down
    existing_mask = torch.zeros(seq_len, seq_len)

    success = False
    for fc in [
        (torch.polar(torch.ones_like(freqs), freqs), torch.polar(torch.ones_like(freqs2), freqs2)),
        ((torch.cos(freqs), torch.sin(freqs)), (torch.cos(freqs2), torch.sin(freqs2))),
    ]:
        captured_masks.clear()
        try:
            out = block(x, attention_mask=existing_mask, freqs_cis=fc, optimized_attention=ns["optimized_attention_for_device"]())
            success = True
            break
        except Exception:
            continue

    if not success:
        print("FAIL: forward failed"); raise SystemExit

    if not captured_masks or captured_masks[0] is None:
        print("FAIL: no mask"); raise SystemExit

    mask = captured_masks[0]
    while mask.dim() > 2:
        mask = mask[0]

    window = 3
    # Out-of-window positions must still be -inf even when combined with zeros mask
    bad = 0
    for i in range(seq_len):
        for j in range(seq_len):
            d = i - j
            if d >= window:
                if float(mask[i, j]) > -1e30:
                    bad += 1
    if bad > 0:
        print(f"FAIL: {bad} out-of-window positions not masked"); raise SystemExit
    print("PASS")
except SystemExit:
    raise
except Exception as e:
    print(f"FAIL: {e}")
PYEOF
)
if [ "$T5" = "PASS" ]; then
    add_score 0.10
    echo "F2P5 PASS"
else
    echo "F2P5 FAIL: $T5"
fi

echo "TOTAL: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt