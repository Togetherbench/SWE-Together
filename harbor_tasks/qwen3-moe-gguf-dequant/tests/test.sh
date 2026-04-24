#!/bin/bash
#
# Verification test for GGUF IQ dequantization functions in PyTorch.
#
# Tests 6 functions: IQ3_XXS (fix), IQ3_S, IQ1_S, IQ2_S, IQ2_XXS, IQ1_M (new)
# Plus: IQ3_XXS must not use .embedding() (user required elemental torch ops)
# Plus: P2P regression for pre-existing quant types
# Plus: stress tests with larger inputs and different seeds
#
# Gold-tier numerical tests: quantize random data with libggml (C), dequantize
# with both numpy reference (gguf.quants) and agent's PyTorch code, compare.
#
# Weight structure (total = 1.00):
#   [P2P] Q4_0 numerical:               0.02
#   [P2P] Q8_0 numerical:               0.02
#   [F2P] IQ3_XXS shape/dtype:          0.02
#   [F2P] IQ3_XXS numerical (seed=42):  0.10
#   [F2P] IQ3_XXS no-embedding:         0.05
#   [F2P] IQ3_XXS stress (seed=142):    0.02
#   [F2P] IQ3_S shape/dtype:            0.01
#   [F2P] IQ3_S numerical (seed=43):    0.10
#   [F2P] IQ3_S stress (seed=143):      0.03
#   [F2P] IQ1_S shape/dtype:            0.01
#   [F2P] IQ1_S numerical (seed=44):    0.10
#   [F2P] IQ1_S stress (seed=144):      0.03
#   [F2P] IQ2_S shape/dtype:            0.01
#   [F2P] IQ2_S numerical (seed=45):    0.08
#   [F2P] IQ2_S stress (seed=145):      0.04
#   [F2P] IQ2_XXS shape/dtype:          0.01
#   [F2P] IQ2_XXS numerical (seed=46):  0.08
#   [F2P] IQ2_XXS stress (seed=146):    0.04
#   [F2P] IQ1_M shape/dtype:            0.01
#   [F2P] IQ1_M numerical (seed=47):    0.10
#   [F2P] IQ1_M stress (seed=147):      0.04
#   [F2P] IQ3_S  no F.embedding:        0.01
#   [F2P] IQ1_S  no F.embedding:        0.01
#   [F2P] IQ2_S  no F.embedding:        0.01
#   [F2P] IQ2_XXS no F.embedding:       0.01
#   [F2P] IQ1_M  no F.embedding:        0.01
#   [F2P] Dispatch check:               0.02
#   [P2P] Upstream P2P:                 0.01
#   Sum = 1.00
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

python3 << 'PYEOF'
import sys, os, traceback
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

reward = 0.0
test_num = 0
total_tests = 28

###############################################################################
# Helper: independent libggml-based numerical test
###############################################################################
def test_numerical_independent(qtype_name, seed, n_blocks=32, rtol=5e-3, atol=5e-3):
    """Gold-tier test: quantize with libggml, dequantize with agent code and numpy ref, compare."""
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

        # Explicit NaN/Inf check
        if torch.isnan(out).any() or torch.isinf(out).any():
            nan_count = torch.isnan(out).sum().item()
            inf_count = torch.isinf(out).sum().item()
            print(f"  FAIL: {qtype_name} output contains NaN({nan_count}) or Inf({inf_count})")
            return False

        if torch.allclose(out, out_ref, rtol=rtol, atol=atol):
            print(f"  PASS: {qtype_name} matches reference (rtol={rtol}, atol={atol}, n_blocks={n_blocks})")
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
# Helper: lightweight shape/dtype pre-check
###############################################################################
def test_shape_dtype(qtype_name):
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
        print(f"  FAIL: {qtype_name} shape/dtype exception: {e}")
        return False


###############################################################################
# Helper: behavioral no-embedding check for IQ3_XXS
###############################################################################
def test_iq3_xxs_no_embedding():
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
        print(f"  FAIL: IQ3_XXS no-embedding exception: {e}")
        return False


###############################################################################
# Helper: behavioral no-embedding check for an arbitrary IQ type
###############################################################################
def test_no_embedding(qtype_name):
    try:
        import torch
        import torch.nn.functional as F
        import gguf
        from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            print(f"  FAIL: {qtype_name} not registered in dequantize_functions")
            return False

        block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
        n_blocks = 4
        numel = n_blocks * block_size
        n_bytes = n_blocks * type_size

        original_embedding = F.embedding
        embedding_called = [False]
        def patched_embedding(*args, **kwargs):
            embedding_called[0] = True
            return original_embedding(*args, **kwargs)

        F.embedding = patched_embedding
        try:
            dummy_input = torch.zeros(n_bytes, dtype=torch.uint8)
            _ = dequantize(dummy_input, qtype, (numel,), torch.float32)
        except Exception as inner_e:
            # If the function crashes, it's broken — no credit for no-embedding
            F.embedding = original_embedding
            print(f"  FAIL: {qtype_name} raised {type(inner_e).__name__}: {inner_e}")
            return False
        finally:
            F.embedding = original_embedding

        if embedding_called[0]:
            print(f"  FAIL: {qtype_name} calls F.embedding (should use elemental torch ops)")
            return False
        else:
            print(f"  PASS: {qtype_name} does not call F.embedding")
            return True
    except Exception as e:
        print(f"  FAIL: {qtype_name} no-embedding exception: {e}")
        return False


# ============================================================================
# Run all tests
# ============================================================================

# --- P2P regression ---
test_num += 1
print(f"=== Test {test_num}/{total_tests}: P2P Q4_0 [P2P, weight=0.02] ===")
if test_numerical_independent("Q4_0", seed=100):
    reward += 0.02

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: P2P Q8_0 [P2P, weight=0.02] ===")
if test_numerical_independent("Q8_0", seed=101):
    reward += 0.02

# --- IQ3_XXS (core bug fix) ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_XXS shape/dtype [F2P, weight=0.02] ===")
if test_shape_dtype("IQ3_XXS"):
    reward += 0.02

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_XXS numerical seed=42 [F2P, weight=0.10] ===")
if test_numerical_independent("IQ3_XXS", seed=42):
    reward += 0.10

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_XXS no F.embedding [F2P, weight=0.05] ===")
if test_iq3_xxs_no_embedding():
    reward += 0.05

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_XXS stress seed=142, 64blk [F2P, weight=0.02] ===")
if test_numerical_independent("IQ3_XXS", seed=142, n_blocks=64):
    reward += 0.02

# --- IQ3_S ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_S shape/dtype [F2P, weight=0.01] ===")
if test_shape_dtype("IQ3_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_S numerical seed=43 [F2P, weight=0.10] ===")
if test_numerical_independent("IQ3_S", seed=43):
    reward += 0.10

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_S stress seed=143, 64blk [F2P, weight=0.03] ===")
if test_numerical_independent("IQ3_S", seed=143, n_blocks=64):
    reward += 0.03

# --- IQ1_S ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_S shape/dtype [F2P, weight=0.01] ===")
if test_shape_dtype("IQ1_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_S numerical seed=44 [F2P, weight=0.10] ===")
if test_numerical_independent("IQ1_S", seed=44):
    reward += 0.10

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_S stress seed=144, 64blk [F2P, weight=0.03] ===")
if test_numerical_independent("IQ1_S", seed=144, n_blocks=64):
    reward += 0.03

# --- IQ2_S ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_S shape/dtype [F2P, weight=0.01] ===")
if test_shape_dtype("IQ2_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_S numerical seed=45 [F2P, weight=0.08] ===")
if test_numerical_independent("IQ2_S", seed=45):
    reward += 0.08

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_S stress seed=145, 64blk [F2P, weight=0.04] ===")
if test_numerical_independent("IQ2_S", seed=145, n_blocks=64):
    reward += 0.04

# --- IQ2_XXS ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_XXS shape/dtype [F2P, weight=0.01] ===")
if test_shape_dtype("IQ2_XXS"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_XXS numerical seed=46 [F2P, weight=0.08] ===")
if test_numerical_independent("IQ2_XXS", seed=46):
    reward += 0.08

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_XXS stress seed=146, 64blk [F2P, weight=0.04] ===")
if test_numerical_independent("IQ2_XXS", seed=146, n_blocks=64):
    reward += 0.04

# --- IQ1_M ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_M shape/dtype [F2P, weight=0.01] ===")
if test_shape_dtype("IQ1_M"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_M numerical seed=47 [F2P, weight=0.10] ===")
if test_numerical_independent("IQ1_M", seed=47):
    reward += 0.10

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_M stress seed=147, 64blk [F2P, weight=0.04] ===")
if test_numerical_independent("IQ1_M", seed=147, n_blocks=64):
    reward += 0.04

# --- no-F.embedding: instruction says "use elemental torch operations (direct
#     tensor indexing) instead of F.embedding" — applies to all IQ functions. ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ3_S no F.embedding [F2P, weight=0.01] ===")
if test_no_embedding("IQ3_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_S no F.embedding [F2P, weight=0.01] ===")
if test_no_embedding("IQ1_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_S no F.embedding [F2P, weight=0.01] ===")
if test_no_embedding("IQ2_S"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ2_XXS no F.embedding [F2P, weight=0.01] ===")
if test_no_embedding("IQ2_XXS"):
    reward += 0.01

test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: IQ1_M no F.embedding [F2P, weight=0.01] ===")
if test_no_embedding("IQ1_M"):
    reward += 0.01

# --- Dispatch ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: dispatch check [F2P, weight=0.02] ===")
try:
    import gguf
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize_functions

    import torch
    required_types = ["IQ3_XXS", "IQ3_S", "IQ1_S", "IQ2_S", "IQ2_XXS", "IQ1_M"]
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize
    working = []
    broken = []
    for name in required_types:
        qtype = getattr(gguf.GGMLQuantizationType, name, None)
        if qtype is None:
            broken.append(f"{name} (not in gguf enum)")
            continue
        if qtype not in dequantize_functions:
            broken.append(name)
            continue
        # Verify each function actually runs without crashing
        try:
            block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
            dummy = torch.zeros(4 * type_size, dtype=torch.uint8)
            _ = dequantize(dummy, qtype, (4 * block_size,), torch.float32)
            working.append(name)
        except Exception:
            broken.append(f"{name} (crashes)")

    if broken:
        print(f"  FAIL: broken: {', '.join(broken)}")
    else:
        print(f"  PASS: all {len(required_types)} IQ types working")
        reward += 0.02
except Exception as e:
    print(f"  FAIL: dispatch exception: {e}")

# --- Upstream P2P ---
test_num += 1
print(f"\n=== Test {test_num}/{total_tests}: Upstream P2P [P2P, weight=0.01] ===")
try:
    p2p_checks = 0
    p2p_total = 8

    import gguf
    from gguf import GGMLQuantizationType, GGML_QUANT_SIZES
    p2p_checks += 1
    print("  PASS: gguf imports OK")

    from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
    p2p_checks += 1
    print("  PASS: dequant imports OK")

    from qwen3_moe_fused.quantize_gguf.dequant import split_block_dims
    assert callable(split_block_dims)
    import torch
    test_tensor = torch.arange(20, dtype=torch.uint8).reshape(1, 20)
    parts = split_block_dims(test_tensor, 2, 8)
    assert isinstance(parts, (tuple, list))
    assert len(parts) >= 2
    p2p_checks += 1
    print(f"  PASS: split_block_dims works ({len(parts)} parts)")

    assert callable(dequantize)
    import inspect
    sig = inspect.signature(dequantize)
    assert len(sig.parameters) >= 3
    p2p_checks += 1
    print(f"  PASS: dequantize signature OK")

    baseline_ok = True
    for tname in ["Q4_0", "Q8_0"]:
        qt = getattr(GGMLQuantizationType, tname, None)
        if qt is None or qt not in dequantize_functions:
            baseline_ok = False
    if baseline_ok:
        p2p_checks += 1
        print("  PASS: baseline types present")

    import importlib
    dequant_mod = importlib.import_module("qwen3_moe_fused.quantize_gguf.dequant")
    grid_ok = True
    grid = getattr(dequant_mod, 'GRID_IQ3_XXS', None)
    if grid is not None and hasattr(grid, 'shape') and grid.shape[0] != 256:
        grid_ok = False
    ksigns = getattr(dequant_mod, 'KSIGNS_IQ2_XXS', None)
    if ksigns is not None and hasattr(ksigns, 'shape') and ksigns.shape[0] != 128:
        grid_ok = False
    if grid_ok:
        p2p_checks += 1
        print("  PASS: lookup tables intact")

    import ast as ast_mod
    dequant_file = "/workspace/qwen3_moe_fused/quantize_gguf/dequant.py"
    if os.path.exists(dequant_file):
        with open(dequant_file) as f:
            src = f.read()
        tree = ast_mod.parse(src)
        func_names = {n.name for n in ast_mod.walk(tree) if isinstance(n, ast_mod.FunctionDef)}
        if 'dequantize' in func_names and 'split_block_dims' in func_names:
            p2p_checks += 1
            print(f"  PASS: AST valid ({len(func_names)} functions)")

    try:
        qt_q4 = GGMLQuantizationType.Q4_0
        block_size, type_size = GGML_QUANT_SIZES[qt_q4]
        n_blocks = 2
        dummy = torch.zeros(n_blocks * type_size, dtype=torch.uint8)
        result = dequantize(dummy, qt_q4, (n_blocks * block_size,), torch.float32)
        assert result.shape == (n_blocks * block_size,)
        assert result.dtype == torch.float32
        p2p_checks += 1
        print("  PASS: Q4_0 functional test")
    except Exception as e:
        print(f"  FAIL: Q4_0 functional: {e}")

    p2p_score = round(0.01 * p2p_checks / p2p_total, 4)
    reward += p2p_score
    print(f"  P2P: {p2p_checks}/{p2p_total} => +{p2p_score}")
except Exception as e:
    print(f"  FAIL: P2P exception: {e}")
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
