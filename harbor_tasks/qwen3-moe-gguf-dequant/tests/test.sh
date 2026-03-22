#!/usr/bin/env bash
#
# Verification test for GGUF IQ dequantization functions in PyTorch.
# Tests 6 functions: IQ3_XXS, IQ3_S, IQ1_S, IQ2_S, IQ2_XXS, IQ1_M
#
# Each function is tested for:
#   (a) existence and importability
#   (b) numerical correctness against numpy reference (via libggml quantization)
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=6

echo "=== Test 1/6: IQ3_XXS dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

# Check function exists
qtype = gguf.GGMLQuantizationType.IQ3_XXS
if qtype not in dequantize_functions:
    print("FAIL: IQ3_XXS not in dequantize_functions")
    sys.exit(1)

# Check it does not use F.embedding (user explicitly asked to remove it)
import inspect
src = inspect.getsource(dequantize_functions[qtype])
if 'F.embedding' in src or 'nn.functional.embedding' in src:
    print("FAIL: IQ3_XXS still uses F.embedding (should use elemental torch ops)")
    sys.exit(1)

# Numerical test against numpy reference
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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(42)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ3_XXS dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ3_XXS max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 2/6: IQ3_S dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

qtype = gguf.GGMLQuantizationType.IQ3_S
if qtype not in dequantize_functions:
    print("FAIL: IQ3_S not in dequantize_functions")
    sys.exit(1)

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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(43)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ3_S dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ3_S max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 3/6: IQ1_S dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

qtype = gguf.GGMLQuantizationType.IQ1_S
if qtype not in dequantize_functions:
    print("FAIL: IQ1_S not in dequantize_functions")
    sys.exit(1)

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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(44)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ1_S dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ1_S max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 4/6: IQ2_S dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

qtype = gguf.GGMLQuantizationType.IQ2_S
if qtype not in dequantize_functions:
    print("FAIL: IQ2_S not in dequantize_functions")
    sys.exit(1)

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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(45)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ2_S dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ2_S max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 5/6: IQ2_XXS dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

qtype = gguf.GGMLQuantizationType.IQ2_XXS
if qtype not in dequantize_functions:
    print("FAIL: IQ2_XXS not in dequantize_functions")
    sys.exit(1)

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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(46)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ2_XXS dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ2_XXS max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 6/6: IQ1_M dequantization ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

import ctypes
from math import prod
import gguf
import numpy as np
import torch

from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions

qtype = gguf.GGMLQuantizationType.IQ1_M
if qtype not in dequantize_functions:
    print("FAIL: IQ1_M not in dequantize_functions")
    sys.exit(1)

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

n_blocks = 32
block_size, type_size = gguf.GGML_QUANT_SIZES[qtype]
numel = n_blocks * block_size
np.random.seed(47)
weights = np.random.uniform(-1, 1, numel).astype(np.float32)

quantized = np.zeros(gguf.quant_shape_to_byte_shape((numel,), qtype), dtype=np.uint8, order="C")
c_float_p = ctypes.POINTER(ctypes.c_float)
if libggml.ggml_quantize_requires_imatrix(qtype.value):
    qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0).ctypes.data_as(c_float_p)
else:
    qw = ctypes.cast(0, c_float_p)
libggml.ggml_quantize_chunk(qtype.value, weights.ctypes.data_as(c_float_p),
    quantized.ctypes.data_as(ctypes.c_void_p), 0, 1, numel, qw)

out_ref = gguf.quants.dequantize(quantized, qtype)
out_ref = torch.from_numpy(out_ref)

quantized_t = torch.from_numpy(quantized)
out = dequantize(quantized_t, qtype, (numel,), torch.float32)

if torch.allclose(out, out_ref, rtol=1e-2, atol=1e-2):
    print("PASS: IQ1_M dequantization matches reference")
else:
    diff = (out - out_ref).abs()
    print(f"FAIL: IQ1_M max diff={diff.max().item():.6f}, mean diff={diff.mean().item():.6f}")
    sys.exit(1)
PYEOF

echo ""
echo "================================"
echo "Results: $PASS / $TOTAL passed"
echo "================================"

if [ "$PASS" -eq "$TOTAL" ]; then
    echo "1.0" > "$REWARD_FILE"
    echo "REWARD: 1.0"
else
    REWARD=$(python3 -c "print(round($PASS / $TOTAL, 2))")
    echo "$REWARD" > "$REWARD_FILE"
    echo "REWARD: $REWARD"
fi
