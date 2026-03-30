#!/usr/bin/env bash
#
# Verification test for GGUF IQ dequantization functions in PyTorch.
#
# Tests 6 functions: IQ3_XXS (fix), IQ3_S, IQ1_S, IQ2_S, IQ2_XXS, IQ1_M (new)
# Plus: IQ3_XXS must not use .embedding() (user required elemental torch ops)
# Plus: P2P regression for pre-existing quant types
#
# Gold-tier numerical tests: quantize random data with libggml (C), dequantize
# with both numpy reference (gguf.quants) and agent's PyTorch code, compare.
#
# Weights:
#   P2P: Q4_0 regression:    0.05  (Gold, P2P)
#   P2P: Q8_0 regression:    0.05  (Gold, P2P)
#   IQ3_XXS numerical:       0.15  (Gold, F2P core bug)
#   IQ3_XXS no embedding:    0.05  (AST, F2P refinement)
#   IQ3_S numerical:         0.14  (Gold, F2P)
#   IQ1_S numerical:         0.14  (Gold, F2P)
#   IQ2_S numerical:         0.14  (Gold, F2P)
#   IQ2_XXS numerical:       0.14  (Gold, F2P)
#   IQ1_M numerical:         0.14  (Gold, F2P)
#
# Behavioral: 95% | Structural (AST): 5%
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

python3 << 'PYEOF'
import sys, os, ast, traceback
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
import gguf
import numpy as np
import torch

# ---- libggml setup (infrastructure, always available) ----
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


def test_numerical(qtype_name, seed, n_blocks=32):
    """Gold-tier test: quantize with libggml, dequantize with agent code and numpy ref, compare."""
    try:
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

        if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
            print(f"  PASS: {qtype_name} dequantization matches reference")
            return True
        else:
            diff = (out - out_ref).abs()
            print(f"  FAIL: {qtype_name} max_diff={diff.max().item():.6f} mean_diff={diff.mean().item():.6f}")
            return False
    except Exception as e:
        print(f"  FAIL: {qtype_name} exception: {e}")
        return False


def test_no_embedding_call():
    """AST check: IQ3_XXS must not call *.embedding() (user required elemental torch ops).

    Justified: F.embedding and tensor indexing (table[indices]) produce identical
    numerical output. This user requirement is a code style constraint that cannot
    be tested behaviorally — only by inspecting the source.
    """
    try:
        with open('/workspace/qwen3_moe_fused/quantize_gguf/dequant.py') as f:
            tree = ast.parse(f.read())

        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == 'dequantize_blocks_IQ3_XXS':
                for child in ast.walk(node):
                    if isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute):
                        if child.func.attr == 'embedding':
                            print("  FAIL: IQ3_XXS calls .embedding() (should use elemental torch ops)")
                            return False
                print("  PASS: IQ3_XXS does not use .embedding()")
                return True

        print("  FAIL: dequantize_blocks_IQ3_XXS not found in AST")
        return False
    except Exception as e:
        print(f"  FAIL: AST check error: {e}")
        return False


# ---- Run all tests ----
reward = 0.0

# P2P: Pre-existing quant types must still work after agent's changes
print("=== Test 1/9: P2P Q4_0 regression [weight=0.05, Gold, P2P] ===")
if test_numerical("Q4_0", seed=100):
    reward += 0.05

print("\n=== Test 2/9: P2P Q8_0 regression [weight=0.05, Gold, P2P] ===")
if test_numerical("Q8_0", seed=101):
    reward += 0.05

# F2P: IQ3_XXS core bug fix (alignment + correct split_block_dims)
print("\n=== Test 3/9: IQ3_XXS numerical correctness [weight=0.15, Gold, F2P] ===")
if test_numerical("IQ3_XXS", seed=42):
    reward += 0.15

# F2P: IQ3_XXS must not use .embedding() (user refinement request)
print("\n=== Test 4/9: IQ3_XXS no .embedding() [weight=0.05, AST, F2P] ===")
if test_no_embedding_call():
    reward += 0.05

# F2P: New function implementations (each Gold, F2P)
tests = [
    ("IQ3_S",   43, 0.14),
    ("IQ1_S",   44, 0.14),
    ("IQ2_S",   45, 0.14),
    ("IQ2_XXS", 46, 0.14),
    ("IQ1_M",   47, 0.14),
]

for i, (name, seed, weight) in enumerate(tests, 5):
    print(f"\n=== Test {i}/9: {name} numerical correctness [weight={weight}, Gold, F2P] ===")
    if test_numerical(name, seed):
        reward += weight

reward = round(min(reward, 1.0), 2)
print(f"\n{'='*40}")
print(f"REWARD: {reward}")

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(str(reward))
PYEOF

echo "Verification complete."
