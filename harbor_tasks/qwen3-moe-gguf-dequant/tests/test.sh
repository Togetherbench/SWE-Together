#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

cd /workspace 2>/dev/null

# Run the entire grading inside python; capture a single float reward.
python3 << 'PYEOF' > /tmp/test_output.log 2>&1
import sys, os, traceback
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

REWARD = 0.0

def write_reward(r):
    try:
        with open('/logs/verifier/reward.txt', 'w') as f:
            f.write(f"{r}\n")
    except Exception:
        pass

def fail_zero(reason=""):
    print(f"GATE FAIL: {reason}")
    write_reward(0.0)
    sys.exit(0)

# ---- Imports & libggml setup ---------------------------------------------
try:
    import ctypes
    import numpy as np
    import torch
    import gguf
except Exception as e:
    fail_zero(f"import error: {e}")

class ggml_init_params(ctypes.Structure):
    _fields_ = [("mem_size", ctypes.c_size_t),
                ("mem_buffer", ctypes.c_void_p),
                ("no_alloc", ctypes.c_bool)]

LIBGGML = None
candidates = [
    "/usr/local/lib/libggml.so",
    "/usr/local/lib/libggml-base.so",
    "/usr/lib/libggml.so",
    "/usr/lib/x86_64-linux-gnu/libggml.so",
]
for cand in candidates:
    if os.path.exists(cand):
        try:
            lib = ctypes.CDLL(cand)
            if hasattr(lib, "ggml_quantize_chunk"):
                LIBGGML = lib
                break
        except Exception:
            continue

if LIBGGML is None:
    fail_zero("libggml not found")

LIBGGML.ggml_quantize_chunk.restype = ctypes.c_size_t
LIBGGML.ggml_quantize_chunk.argtypes = (
    ctypes.c_int, ctypes.POINTER(ctypes.c_float), ctypes.c_void_p,
    ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
    ctypes.POINTER(ctypes.c_float),
)
LIBGGML.ggml_quantize_requires_imatrix.restype = ctypes.c_bool
LIBGGML.ggml_quantize_requires_imatrix.argtypes = (ctypes.c_int,)
if hasattr(LIBGGML, "ggml_init"):
    LIBGGML.ggml_init.argtypes = (ggml_init_params,)
    try:
        LIBGGML.ggml_init(ggml_init_params(1 * 1024 * 1024, 0, False))
    except Exception:
        pass

c_float_p = ctypes.POINTER(ctypes.c_float)

def quantize_with_libggml(qtype, weights, numel):
    quantized = np.zeros(
        gguf.quant_shape_to_byte_shape((numel,), qtype),
        dtype=np.uint8, order="C"
    )
    if LIBGGML.ggml_quantize_requires_imatrix(qtype.value):
        qw = np.sum(
            (weights * weights).reshape((-1, weights.shape[-1])), axis=0
        ).ctypes.data_as(c_float_p)
    else:
        qw = ctypes.cast(0, c_float_p)
    LIBGGML.ggml_quantize_chunk(
        qtype.value,
        weights.ctypes.data_as(c_float_p),
        quantized.ctypes.data_as(ctypes.c_void_p),
        0, 1, numel, qw,
    )
    return quantized

# ---- Import the dequant module under test --------------------------------
try:
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
except Exception as e:
    fail_zero(f"dequant import error: {e}")

# ---- P2P gating: pre-existing dequantizers must still work ---------------
# These pass on base. They are GATES (no reward weight).
def p2p_check(qtype_name, seed=2024, n_blocks=16, rtol=5e-3, atol=5e-3):
    try:
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        block_size, _ = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)
        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        quantized_t = torch.from_numpy(quantized)
        out = dequantize(quantized_t, qtype, (numel,), torch.float32)
        if torch.isnan(out).any() or torch.isinf(out).any():
            return False
        if out.shape != out_ref.shape:
            return False
        return torch.allclose(out.float(), out_ref.float(), rtol=rtol, atol=atol)
    except Exception:
        traceback.print_exc()
        return False

print("=== P2P regression gates (no reward) ===")
for qname in ("Q4_0", "Q8_0", "IQ4_NL", "IQ4_XS"):
    ok = p2p_check(qname)
    print(f"  P2P {qname}: {'OK' if ok else 'BROKEN'}")
    if not ok:
        # Agent destroyed something that worked on base.
        fail_zero(f"P2P regression on {qname}")

# ---- F2P weighted checks --------------------------------------------------
# All of these MUST fail on the un-modified buggy base:
#   - IQ3_XXS numerical: base is buggy (uses F.embedding incorrectly + view error)
#   - IQ3_S, IQ2_S, IQ2_XXS, IQ1_S, IQ1_M: not present in dequantize_functions on base
#   - "no F.embedding" structural for IQ3_XXS: base USES F.embedding, so this fails
# Total weight = 1.00

results = []

def record(name, weight, passed, detail=""):
    global REWARD
    earned = weight if passed else 0.0
    REWARD += earned
    status = "PASS" if passed else "FAIL"
    line = f"  [{status}] ({earned:.3f}/{weight:.3f}) {name} {detail}"
    print(line)
    results.append(line)

def numerical_test(qtype_name, seed, n_blocks=24, rtol=2e-3, atol=2e-3):
    try:
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            return False, "not registered"
        block_size, _ = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)
        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        quantized_t = torch.from_numpy(quantized)
        out = dequantize(quantized_t, qtype, (numel,), torch.float32)
        if torch.isnan(out).any() or torch.isinf(out).any():
            return False, "nan/inf"
        if out.shape != out_ref.shape:
            return False, f"shape {tuple(out.shape)} vs {tuple(out_ref.shape)}"
        diff = (out.float() - out_ref.float()).abs()
        max_diff = float(diff.max().item())
        ok = torch.allclose(out.float(), out_ref.float(), rtol=rtol, atol=atol)
        return ok, f"max_diff={max_diff:.5g}"
    except Exception as e:
        return False, f"exc:{e}"

# --- F2P 1: IQ3_XXS numerical correctness (was buggy on base) ---
# Weight: 0.16 (two seeds, 0.08 each)
print("=== F2P numerical: IQ3_XXS (fix) ===")
for seed, w in [(42, 0.08), (142, 0.08)]:
    ok, info = numerical_test("IQ3_XXS", seed=seed, n_blocks=24, rtol=2e-3, atol=2e-3)
    record(f"IQ3_XXS num seed={seed}", w, ok, info)

# --- F2P 2: 5 new IQ types, two seeds each ---
# Weight: 0.60 total -> 0.06 per (5 types * 2 seeds)
print("=== F2P numerical: new IQ implementations ===")
NEW_TYPES = [
    ("IQ3_S",  2e-3, 2e-3),
    ("IQ2_S",  2e-3, 2e-3),
    ("IQ2_XXS",2e-3, 2e-3),
    ("IQ1_S",  6e-3, 6e-3),
    ("IQ1_M",  6e-3, 6e-3),
]
seed_pairs = {
    "IQ3_S":   (43, 143),
    "IQ2_S":   (45, 145),
    "IQ2_XXS": (46, 146),
    "IQ1_S":   (44, 144),
    "IQ1_M":   (47, 147),
}
for qname, rtol, atol in NEW_TYPES:
    s1, s2 = seed_pairs[qname]
    for s in (s1, s2):
        ok, info = numerical_test(qname, seed=s, n_blocks=24, rtol=rtol, atol=atol)
        record(f"{qname} num seed={s}", 0.06, ok, info)

# --- F2P 3: dispatch registration for the 5 new types ---
# Weight: 0.10 total -> 0.02 per type
# On base, only IQ3_XXS is in dequantize_functions; the 5 new ones must be added.
print("=== F2P registration ===")
for qname in ("IQ3_S", "IQ2_S", "IQ2_XXS", "IQ1_S", "IQ1_M"):
    qtype = getattr(gguf.GGMLQuantizationType, qname)
    record(f"{qname} registered", 0.02, qtype in dequantize_functions)

# --- F2P 4: IQ3_XXS implementation must NOT use F.embedding ---
# Weight: 0.04
# Base implementation explicitly uses torch.nn.functional.embedding for IQ3_XXS.
# A correct fix per the instruction switches to direct tensor indexing.
print("=== F2P structural: no F.embedding in IQ3_XXS ===")
try:
    import inspect
    from qwen3_moe_fused.quantize_gguf import dequant as _dequant_mod
    src = inspect.getsource(_dequant_mod.dequantize_blocks_IQ3_XXS)
    no_embedding = ("F.embedding" not in src) and ("nn.functional.embedding" not in src) \
                   and ("functional.embedding" not in src)
    record("IQ3_XXS no F.embedding", 0.04, no_embedding,
           "" if no_embedding else "(still uses F.embedding)")
except Exception as e:
    record("IQ3_XXS no F.embedding", 0.04, False, f"exc:{e}")

# --- F2P 5: Determinism + large-batch stress on IQ3_XXS and IQ1_S ---
# Weight: 0.10 total -> 0.05 per type
# Determinism: two calls give identical output. Large-batch: 64 blocks with no NaN.
# On base IQ3_XXS produces wrong output (and IQ1_S not registered) so this fails.
print("=== F2P determinism + large-batch ===")
def determinism_and_stress(qtype_name, n_blocks=64, seed=7777, rtol=6e-3, atol=6e-3):
    try:
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            return False, "not registered"
        block_size, _ = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)
        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        qt = torch.from_numpy(quantized)
        out1 = dequantize(qt, qtype, (numel,), torch.float32)
        out2 = dequantize(qt, qtype, (numel,), torch.float32)
        if torch.isnan(out1).any() or torch.isinf(out1).any():
            return False, "nan/inf"
        if not torch.equal(out1, out2):
            return False, "non-deterministic"
        if out1.shape != out_ref.shape:
            return False, "shape"
        ok = torch.allclose(out1.float(), out_ref.float(), rtol=rtol, atol=atol)
        return ok, "ok" if ok else "numeric"
    except Exception as e:
        return False, f"exc:{e}"

for qname, w in [("IQ3_XXS", 0.05), ("IQ1_S", 0.05)]:
    ok, info = determinism_and_stress(qname,
                                      rtol=(6e-3 if qname == "IQ1_S" else 2e-3),
                                      atol=(6e-3 if qname == "IQ1_S" else 2e-3))
    record(f"{qname} det+stress", w, ok, info)

# ---- Total ----------------------------------------------------------------
total = round(REWARD, 6)
# Clamp to [0, 1]
if total < 0: total = 0.0
if total > 1: total = 1.0
print(f"=== TOTAL REWARD: {total} ===")
write_reward(total)
PYEOF

# Echo log tail to help debugging post-mortem
if [ -f /tmp/test_output.log ]; then
    echo "----- /tmp/test_output.log (tail) -----"
    tail -n 120 /tmp/test_output.log
fi

# Safety net: if the python block didn't write a reward file, force 0.0.
if [ ! -s "$REWARD_FILE" ]; then
    echo "0.0" > "$REWARD_FILE"
fi

# Ensure the file exists with a valid float
REWARD=$(cat "$REWARD_FILE" 2>/dev/null | head -n1 | tr -d '[:space:]')
case "$REWARD" in
    ''|*[!0-9.]*) REWARD="0.0" ;;
esac
echo "$REWARD" > /logs/verifier/reward.txt