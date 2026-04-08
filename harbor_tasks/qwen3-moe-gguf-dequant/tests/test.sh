#!/usr/bin/env bash
#
# Verification test for GGUF IQ dequantization functions in PyTorch.
#
# Tests 6 functions: IQ3_XXS (fix), IQ3_S, IQ1_S, IQ2_S, IQ2_XXS, IQ1_M (new)
# Plus: IQ3_XXS must not use .embedding() (user required elemental torch ops)
# Plus: P2P regression for pre-existing quant types
# Plus: upstream P2P for module imports and pre-existing infrastructure
#
# Gold-tier numerical tests: quantize random data with libggml (C), dequantize
# with both numpy reference (gguf.quants) and agent's PyTorch code, compare.
#
# KEY DESIGN CHANGE from v1:
#   - Each quant type test is fully independent (own libggml init)
#   - Lightweight shape/dtype pre-checks before heavy numerical tests
#   - AST check replaced with behavioral: call function + check output type
#   - Tolerance tightened from rtol=1e-2 to rtol=5e-3
#   - Total weights sum to 1.05 (capped at 1.00)
#
# Weights:
#   P2P: Q4_0 regression:         0.05  (Gold, P2P)
#   P2P: Q8_0 regression:         0.05  (Gold, P2P)
#   IQ3_XXS shape/dtype check:    0.03  (Behavioral, lightweight)
#   IQ3_XXS numerical:            0.12  (Gold, F2P core bug)
#   IQ3_XXS no-embedding behav:   0.05  (Behavioral, F2P refinement)
#   IQ3_S shape/dtype check:      0.02  (Behavioral, lightweight)
#   IQ3_S numerical:              0.12  (Gold, F2P)
#   IQ1_S shape/dtype check:      0.02  (Behavioral, lightweight)
#   IQ1_S numerical:              0.12  (Gold, F2P)
#   IQ2_S shape/dtype check:      0.02  (Behavioral, lightweight)
#   IQ2_S numerical:              0.10  (Gold, F2P)
#   IQ2_XXS shape/dtype check:    0.02  (Behavioral, lightweight)
#   IQ2_XXS numerical:            0.10  (Gold, F2P)
#   IQ1_M shape/dtype check:      0.02  (Behavioral, lightweight)
#   IQ1_M numerical:              0.10  (Gold, F2P)
#   dequantize dispatch check:    0.06  (Behavioral, integration)
#   Upstream P2P imports & infra: 0.05  (Gold, P2P)
#
# Behavioral: 100% | Structural (AST): 0%
# Stub score (file exists only): 0.00
# Max score: 1.00 (capped)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

python3 << 'PYEOF'
import sys, os, traceback
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

reward = 0.0

###############################################################################
# Helper: independent libggml-based numerical test
# Each call gets its own try/except so one failure doesn't cascade to others.
###############################################################################
def test_numerical_independent(qtype_name, seed, n_blocks=32, rtol=5e-3, atol=5e-3):
    """Gold-tier test: quantize with libggml, dequantize with agent code and numpy ref, compare.

    Each call is fully independent -- imports and initializes libggml fresh
    in its own scope so a failure in one test cannot cascade to others.
    """
    try:
        import ctypes
        import numpy as np
        import torch
        import gguf

        class ggml_init_params(ctypes.Structure):
            _fields_ = [("mem_size", ctypes.c_size_t), ("mem_buffer", ctypes.c_void_p), ("no_alloc", ctypes.c_bool)]

        libggml = ctypes.CDLL("/usr/local/lib/libggml.so")
        libggml.ggml_quantize_chunk.restype = ctypes.c_size_t
        libggml.ggml_quantize_chunk.argtypes = (
            ctypes.c_int, ctypes.POINTER(ctypes.c_float), ctypes.c_void_p,
            ctypes.c_int64, ctypes.c_int64, ctypes.c_int64, ctypes.POINTER(ctypes.c_float),
        )
        libggml.ggml_quantize_requires_imatrix.restype = ctypes.c_bool
        libggml.ggml_quantize_requires_imatrix.argtypes = (ctypes.c_int,)
        if hasattr(libggml, "ggml_init"):
            libggml.ggml_init.argtypes = (ggml_init_params,)
            libggml.ggml_init(ggml_init_params(1 * 1024 * 1024, 0, False))

        c_float_p = ctypes.POINTER(ctypes.c_float)

        from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            print(f"  FAIL: {qtype_name} not registered in dequantize_functions")
            return False

        block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        np.random.seed(seed)
        weights = np.random.uniform(-1, 1, numel).astype(np.float32)

        quantized = np.zeros(
            gguf.quant_shape_to_byte_shape((numel,), qtype),
            dtype=np.uint8, order="C"
        )
        if libggml.ggml_quantize_requires_imatrix(qtype.value):
            qw = np.sum(
                (weights * weights).reshape((-1, weights.shape[-1])), axis=0
            ).ctypes.data_as(c_float_p)
        else:
            qw = ctypes.cast(0, c_float_p)

        libggml.ggml_quantize_chunk(
            qtype.value,
            weights.ctypes.data_as(c_float_p),
            quantized.ctypes.data_as(ctypes.c_void_p),
            0, 1, numel, qw
        )

        # Reference: numpy dequantization from gguf library
        out_ref = gguf.quants.dequantize(quantized, qtype)
        out_ref = torch.from_numpy(out_ref)

        # Agent's implementation: PyTorch dequantization
        quantized_t = torch.from_numpy(quantized)
        out = dequantize(quantized_t, qtype, (numel,), torch.float32)

        if torch.allclose(out, out_ref, rtol=rtol, atol=atol):
            print(f"  PASS: {qtype_name} dequantization matches reference (rtol={rtol}, atol={atol})")
            return True
        else:
            diff = (out - out_ref).abs()
            print(f"  FAIL: {qtype_name} max_diff={diff.max().item():.6f} mean_diff={diff.mean().item():.6f}")
            return False
    except Exception as e:
        print(f"  FAIL: {qtype_name} exception: {e}")
        traceback.print_exc()
        return False


###############################################################################
# Helper: lightweight shape/dtype pre-check (no libggml needed)
###############################################################################
def test_shape_dtype(qtype_name):
    """Lightweight check: function exists, accepts tensor input, returns correct shape/dtype."""
    try:
        import torch
        import gguf
        from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            print(f"  FAIL: {qtype_name} not in dequantize_functions dict")
            return False

        block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
        n_blocks = 4
        numel = n_blocks * block_size
        n_bytes = n_blocks * type_size

        # Create a dummy quantized tensor (zeros -- we only check shape/dtype, not values)
        dummy_input = torch.zeros(n_bytes, dtype=torch.uint8)
        out = dequantize(dummy_input, qtype, (numel,), torch.float32)

        if out.shape != (numel,):
            print(f"  FAIL: {qtype_name} output shape {out.shape} != expected ({numel},)")
            return False
        if out.dtype != torch.float32:
            print(f"  FAIL: {qtype_name} output dtype {out.dtype} != expected float32")
            return False

        print(f"  PASS: {qtype_name} shape={out.shape}, dtype={out.dtype}")
        return True
    except Exception as e:
        print(f"  FAIL: {qtype_name} shape/dtype check exception: {e}")
        return False


###############################################################################
# Helper: behavioral no-embedding check for IQ3_XXS
###############################################################################
def test_iq3_xxs_no_embedding():
    """Behavioral check: run IQ3_XXS and verify it does NOT use F.embedding internally.

    Instead of AST parsing, we monkey-patch torch.nn.functional.embedding to
    detect if it gets called during dequantization. This is purely behavioral:
    if the function works without calling embedding, the test passes.
    """
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

        # Monkey-patch F.embedding to detect usage
        original_embedding = F.embedding
        embedding_called = [False]
        def patched_embedding(*args, **kwargs):
            embedding_called[0] = True
            return original_embedding(*args, **kwargs)

        F.embedding = patched_embedding
        try:
            dummy_input = torch.zeros(n_bytes, dtype=torch.uint8)
            _ = dequantize(dummy_input, qtype, (numel,), torch.float32)
        finally:
            F.embedding = original_embedding

        if embedding_called[0]:
            print("  FAIL: IQ3_XXS calls F.embedding (should use elemental torch ops)")
            return False
        else:
            print("  PASS: IQ3_XXS does not call F.embedding")
            return True
    except Exception as e:
        print(f"  FAIL: IQ3_XXS no-embedding check exception: {e}")
        return False


# ============================================================================
# Run all tests
# ============================================================================

# --- P2P regression tests ---
print("=== Test 1/17: P2P Q4_0 regression [weight=0.05, Gold, P2P] ===")
if test_numerical_independent("Q4_0", seed=100):
    reward += 0.05

print("\n=== Test 2/17: P2P Q8_0 regression [weight=0.05, Gold, P2P] ===")
if test_numerical_independent("Q8_0", seed=101):
    reward += 0.05

# --- IQ3_XXS (core bug fix) ---
print("\n=== Test 3/17: IQ3_XXS shape/dtype check [weight=0.03, Behavioral] ===")
if test_shape_dtype("IQ3_XXS"):
    reward += 0.03

print("\n=== Test 4/17: IQ3_XXS numerical correctness [weight=0.12, Gold, F2P] ===")
if test_numerical_independent("IQ3_XXS", seed=42):
    reward += 0.12

print("\n=== Test 5/17: IQ3_XXS no F.embedding [weight=0.05, Behavioral, F2P] ===")
if test_iq3_xxs_no_embedding():
    reward += 0.05

# --- IQ3_S ---
print("\n=== Test 6/17: IQ3_S shape/dtype check [weight=0.02, Behavioral] ===")
if test_shape_dtype("IQ3_S"):
    reward += 0.02

print("\n=== Test 7/17: IQ3_S numerical correctness [weight=0.12, Gold, F2P] ===")
if test_numerical_independent("IQ3_S", seed=43):
    reward += 0.12

# --- IQ1_S ---
print("\n=== Test 8/17: IQ1_S shape/dtype check [weight=0.02, Behavioral] ===")
if test_shape_dtype("IQ1_S"):
    reward += 0.02

print("\n=== Test 9/17: IQ1_S numerical correctness [weight=0.12, Gold, F2P] ===")
if test_numerical_independent("IQ1_S", seed=44):
    reward += 0.12

# --- IQ2_S ---
print("\n=== Test 10/17: IQ2_S shape/dtype check [weight=0.02, Behavioral] ===")
if test_shape_dtype("IQ2_S"):
    reward += 0.02

print("\n=== Test 11/17: IQ2_S numerical correctness [weight=0.10, Gold, F2P] ===")
if test_numerical_independent("IQ2_S", seed=45):
    reward += 0.10

# --- IQ2_XXS ---
print("\n=== Test 12/17: IQ2_XXS shape/dtype check [weight=0.02, Behavioral] ===")
if test_shape_dtype("IQ2_XXS"):
    reward += 0.02

print("\n=== Test 13/17: IQ2_XXS numerical correctness [weight=0.10, Gold, F2P] ===")
if test_numerical_independent("IQ2_XXS", seed=46):
    reward += 0.10

# --- IQ1_M ---
print("\n=== Test 14/17: IQ1_M shape/dtype check [weight=0.02, Behavioral] ===")
if test_shape_dtype("IQ1_M"):
    reward += 0.02

print("\n=== Test 15/17: IQ1_M numerical correctness [weight=0.10, Gold, F2P] ===")
if test_numerical_independent("IQ1_M", seed=47):
    reward += 0.10

# --- Integration: dequantize dispatch works for all types ---
print("\n=== Test 16/17: dequantize dispatch covers all IQ types [weight=0.06, Behavioral] ===")
try:
    import gguf
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize_functions

    required_types = ["IQ3_XXS", "IQ3_S", "IQ1_S", "IQ2_S", "IQ2_XXS", "IQ1_M"]
    registered = []
    missing = []
    for name in required_types:
        qtype = getattr(gguf.GGMLQuantizationType, name, None)
        if qtype is None:
            missing.append(f"{name} (not in gguf enum)")
        elif qtype in dequantize_functions:
            registered.append(name)
        else:
            missing.append(name)

    if missing:
        print(f"  FAIL: missing from dequantize_functions: {', '.join(missing)}")
        print(f"  Registered: {', '.join(registered)}")
        # Partial credit: give proportional score
        frac = len(registered) / len(required_types)
        partial = round(0.06 * frac, 4)
        reward += partial
        print(f"  Partial credit: {partial}")
    else:
        print(f"  PASS: all {len(required_types)} IQ types registered in dequantize_functions")
        reward += 0.06
except Exception as e:
    print(f"  FAIL: dispatch check exception: {e}")

# --- Upstream P2P: module imports and pre-existing infrastructure ---
print("\n=== Test 17/17: Upstream P2P imports & pre-existing infra [weight=0.05, Gold, P2P] ===")
try:
    p2p_checks = 0
    p2p_total = 5

    # 1. gguf module imports
    import gguf
    from gguf import GGMLQuantizationType, GGML_QUANT_SIZES
    p2p_checks += 1
    print("  PASS: gguf module imports OK")

    # 2. dequant module imports
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
    p2p_checks += 1
    print("  PASS: dequant module imports OK")

    # 3. split_block_dims helper exists and is callable
    from qwen3_moe_fused.quantize_gguf.dequant import split_block_dims
    assert callable(split_block_dims), "split_block_dims is not callable"
    p2p_checks += 1
    print("  PASS: split_block_dims exists and is callable")

    # 4. dequantize is callable and accepts expected signature
    assert callable(dequantize), "dequantize is not callable"
    import inspect
    sig = inspect.signature(dequantize)
    assert len(sig.parameters) >= 3, f"dequantize has too few params: {sig}"
    p2p_checks += 1
    print(f"  PASS: dequantize is callable with signature {sig}")

    # 5. Pre-existing quant types (Q4_0, Q8_0) remain in dequantize_functions
    baseline_types = ["Q4_0", "Q8_0"]
    baseline_ok = True
    for tname in baseline_types:
        qt = getattr(GGMLQuantizationType, tname, None)
        if qt is None or qt not in dequantize_functions:
            print(f"  FAIL: pre-existing {tname} missing from dequantize_functions")
            baseline_ok = False
    if baseline_ok:
        p2p_checks += 1
        print(f"  PASS: baseline quant types {baseline_types} present in dequantize_functions")

    p2p_score = round(0.05 * p2p_checks / p2p_total, 4)
    reward += p2p_score
    print(f"  P2P sub-score: {p2p_checks}/{p2p_total} => +{p2p_score}")
except Exception as e:
    print(f"  FAIL: upstream P2P exception: {e}")
    traceback.print_exc()

# ============================================================================
# Final scoring
# ============================================================================
reward = round(min(reward, 1.0), 2)
print(f"\n{'='*40}")
print(f"REWARD: {reward}")

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(str(reward))
PYEOF

echo "Verification complete."
