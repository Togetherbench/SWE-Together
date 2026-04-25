#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

cd /workspace 2>/dev/null

python3 << 'PYEOF' > /tmp/test_output.log 2>&1
import sys, os, traceback, ast, re
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

# Total weight breakdown:
#  P2P regression (libggml numerical) on Q4_0, Q8_0, IQ4_NL, IQ4_XS:  0.16
#  F2P numerical (6 IQ types, 2 seeds each, tighter tolerance):       0.60
#  F2P shape/dtype + dispatch registration (6 types):                 0.12
#  F2P "no F.embedding" structural for IQ3_XXS:                       0.04
#  F2P determinism / no-NaN robustness:                               0.04
#  F2P large-batch stress for IQ3_XXS + IQ1_S:                        0.04
# Total = 1.00

reward = 0.0
results = []

def record(name, weight, passed, detail=""):
    global reward
    earned = weight if passed else 0.0
    reward += earned
    status = "PASS" if passed else "FAIL"
    results.append(f"  [{status}] ({earned:.3f}/{weight:.3f}) {name} {detail}")
    print(f"  [{status}] ({earned:.3f}/{weight:.3f}) {name} {detail}")

def record_partial(name, weight, frac, detail=""):
    global reward
    frac = max(0.0, min(1.0, frac))
    earned = weight * frac
    reward += earned
    status = "PASS" if frac >= 0.99 else ("PART" if frac > 0 else "FAIL")
    results.append(f"  [{status}] ({earned:.3f}/{weight:.3f}) {name} {detail}")
    print(f"  [{status}] ({earned:.3f}/{weight:.3f}) {name} {detail}")

###############################################################################
# Set up libggml-based numerical comparator
###############################################################################
LIBGGML = None
GGML_OK = False
try:
    import ctypes
    import numpy as np
    import torch
    import gguf

    class ggml_init_params(ctypes.Structure):
        _fields_ = [("mem_size", ctypes.c_size_t),
                    ("mem_buffer", ctypes.c_void_p),
                    ("no_alloc", ctypes.c_bool)]

    candidates = [
        "/usr/local/lib/libggml.so",
        "/usr/local/lib/libggml-base.so",
        "/usr/lib/libggml.so",
        "/usr/lib/x86_64-linux-gnu/libggml.so",
    ]
    for cand in candidates:
        if os.path.exists(cand):
            try:
                LIBGGML = ctypes.CDLL(cand)
                if hasattr(LIBGGML, "ggml_quantize_chunk"):
                    break
            except Exception:
                LIBGGML = None
                continue

    if LIBGGML is not None and hasattr(LIBGGML, "ggml_quantize_chunk"):
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
        GGML_OK = True
except Exception as e:
    print(f"libggml setup failed: {e}")

c_float_p = (ctypes.POINTER(ctypes.c_float) if GGML_OK else None)


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


def numerical_test(qtype_name, seed, n_blocks=32, rtol=2e-3, atol=2e-3,
                   require_registered=True):
    """Returns (passed, max_diff). Compares agent dequant vs gguf.quants reference."""
    if not GGML_OK:
        return False, float("inf")
    try:
        from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if require_registered and qtype not in dequantize_functions:
            return False, float("inf")

        block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)

        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        quantized_t = torch.from_numpy(quantized)
        out = dequantize(quantized_t, qtype, (numel,), torch.float32)

        if torch.isnan(out).any() or torch.isinf(out).any():
            return False, float("inf")

        if out.shape != out_ref.shape:
            return False, float("inf")

        diff = (out.float() - out_ref.float()).abs()
        max_diff = float(diff.max().item())
        ok = torch.allclose(out.float(), out_ref.float(), rtol=rtol, atol=atol)
        return ok, max_diff
    except Exception as e:
        traceback.print_exc()
        return False, float("inf")


def shape_dtype_check(qtype_name):
    try:
        import torch
        import gguf
        from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            return False, "not registered"
        block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
        n_blocks = 4
        numel = n_blocks * block_size
        n_bytes = n_blocks * type_size
        # Use random non-zero bytes; some implementations crash on zeros
        rng = np.random.RandomState(123)
        dummy = torch.from_numpy(rng.randint(0, 256, n_bytes, dtype=np.uint8 if False else np.int64).astype(np.uint8))
        out = dequantize(dummy, qtype, (numel,), torch.float32)
        if out.shape != (numel,):
            return False, f"bad shape {out.shape}"
        if out.dtype != torch.float32:
            return False, f"bad dtype {out.dtype}"
        return True, "ok"
    except Exception as e:
        return False, f"exc:{e}"


###############################################################################
# 1. P2P regression — pre-existing dequantizers must still work (0.16)
###############################################################################
print("=== P2P regression ===")
for qname, w in [("Q4_0", 0.04), ("Q8_0", 0.04), ("IQ4_NL", 0.04), ("IQ4_XS", 0.04)]:
    ok, md = numerical_test(qname, seed=2024, n_blocks=16, rtol=5e-3, atol=5e-3,
                            require_registered=False)
    record(f"P2P numerical {qname}", w, ok, f"max_diff={md:.5g}")

###############################################################################
# 2. F2P numerical — six IQ types, two independent seeds each (0.60)
###############################################################################
print("=== F2P numerical correctness ===")
IQ_TYPES = ["IQ3_XXS", "IQ3_S", "IQ1_S", "IQ2_S", "IQ2_XXS", "IQ1_M"]
# 6 types * 2 seeds = 12 sub-tests, 0.05 each = 0.60
seeds_a = {"IQ3_XXS":42, "IQ3_S":43, "IQ1_S":44, "IQ2_S":45, "IQ2_XXS":46, "IQ1_M":47}
seeds_b = {"IQ3_XXS":142, "IQ3_S":143, "IQ1_S":144, "IQ2_S":145, "IQ2_XXS":146, "IQ1_M":147}

for qname in IQ_TYPES:
    # IQ1_* tolerances slightly looser since they use 1.5-bit grids
    if qname in ("IQ1_S", "IQ1_M"):
        rtol, atol = 5e-3, 5e-3
    else:
        rtol, atol = 2e-3, 2e-3
    ok_a, md_a = numerical_test(qname, seed=seeds_a[qname], n_blocks=24,
                                rtol=rtol, atol=atol)
    record(f"F2P numerical {qname} seed={seeds_a[qname]}", 0.05, ok_a,
           f"max_diff={md_a:.5g}")
    ok_b, md_b = numerical_test(qname, seed=seeds_b[qname], n_blocks=48,
                                rtol=rtol, atol=atol)
    record(f"F2P numerical {qname} seed={seeds_b[qname]}", 0.05, ok_b,
           f"max_diff={md_b:.5g}")

###############################################################################
# 3. F2P shape/dtype + dispatch (0.12)  — 0.02 each
###############################################################################
print("=== F2P shape/dtype + dispatch ===")
for qname in IQ_TYPES:
    ok, msg = shape_dtype_check(qname)
    record(f"F2P shape/dtype/dispatch {qname}", 0.02, ok, msg)

###############################################################################
# 4. F2P "no F.embedding" structural for IQ3_XXS (0.04)
#    Instruction explicitly required removing F.embedding from IQ3_XXS.
###############################################################################
print("=== F2P IQ3_XXS no F.embedding ===")
try:
    import torch
    import torch.nn.functional as F
    import gguf
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize

    qtype = gguf.GGMLQuantizationType.IQ3_XXS
    block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
    n_blocks = 4
    numel = n_blocks * block_size
    n_bytes = n_blocks * type_size

    orig_embedding = F.embedding
    called = {"n": 0}
    def patched(*a, **kw):
        called["n"] += 1
        return orig_embedding(*a, **kw)
    F.embedding = patched
    try:
        rng = np.random.RandomState(7)
        dummy = torch.from_numpy(rng.randint(0, 256, n_bytes, dtype=np.int64).astype(np.uint8))
        _ = dequantize(dummy, qtype, (numel,), torch.float32)
    finally:
        F.embedding = orig_embedding

    record("F2P IQ3_XXS does not call F.embedding", 0.04, called["n"] == 0,
           f"calls={called['n']}")
except Exception as e:
    record("F2P IQ3_XXS does not call F.embedding", 0.04, False, f"exc:{e}")

###############################################################################
# 5. F2P determinism + no-NaN robustness over varied bit patterns (0.04)
###############################################################################
print("=== F2P determinism + robustness ===")
det_ok_count = 0
det_total = 0
try:
    import torch
    import gguf
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
    for qname in IQ_TYPES:
        det_total += 1
        try:
            qtype = getattr(gguf.GGMLQuantizationType, qname)
            if qtype not in dequantize_functions:
                continue
            if not GGML_OK:
                continue
            block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
            n_blocks = 8
            numel = n_blocks * block_size
            rng = np.random.RandomState(9999 + det_total)
            weights = rng.uniform(-2, 2, numel).astype(np.float32)
            q = quantize_with_libggml(qtype, weights, numel)
            qt = torch.from_numpy(q)
            out1 = dequantize(qt, qtype, (numel,), torch.float32)
            out2 = dequantize(qt.clone(), qtype, (numel,), torch.float32)
            if torch.isnan(out1).any() or torch.isinf(out1).any():
                continue
            if not torch.equal(out1, out2):
                continue
            det_ok_count += 1
        except Exception:
            continue
except Exception:
    pass

record_partial("F2P determinism + no-NaN across IQ types", 0.04,
               det_ok_count / max(det_total, 1),
               f"{det_ok_count}/{det_total}")

###############################################################################
# 6. F2P stress on larger batches for IQ3_XXS and IQ1_S (0.04)
###############################################################################
print("=== F2P stress (large batch) ===")
ok_s1, md_s1 = numerical_test("IQ3_XXS", seed=2025, n_blocks=128,
                              rtol=2e-3, atol=2e-3)
record("F2P stress IQ3_XXS n_blocks=128", 0.02, ok_s1, f"max_diff={md_s1:.5g}")
ok_s2, md_s2 = numerical_test("IQ1_S", seed=2026, n_blocks=128,
                              rtol=5e-3, atol=5e-3)
record("F2P stress IQ1_S n_blocks=128", 0.02, ok_s2, f"max_diff={md_s2:.5g}")

###############################################################################
# Final
###############################################################################
print("")
print("=" * 60)
print("SUMMARY")
print("=" * 60)
for r in results:
    print(r)

# Clamp for safety
if reward < 0:
    reward = 0.0
if reward > 1.0:
    reward = 1.0

with open("/tmp/reward_value.txt", "w") as f:
    f.write(f"{reward:.4f}\n")

print(f"\nFINAL REWARD: {reward:.4f}")
PYEOF

cat /tmp/test_output.log

if [ -f /tmp/reward_value.txt ]; then
    REWARD=$(cat /tmp/reward_value.txt | tr -d '[:space:]')
else
    REWARD="0.0000"
fi

# Validate it's numeric
if ! awk -v v="$REWARD" 'BEGIN{ if (v+0==v) exit 0; else exit 1 }'; then
    REWARD="0.0000"
fi

echo "$REWARD" > "$REWARD_FILE"
echo "Reward written to $REWARD_FILE: $REWARD"