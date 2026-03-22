#!/usr/bin/env python3
"""Synthesize buggy initial state for the benchmark task.

Replaces the working IQ3_XXS dequantization function with a buggy version
that has alignment issues and uses F.embedding instead of direct indexing.
This file is deleted after running during Docker build.
"""
import ast
import re
import textwrap

DEQUANT_FILE = "/workspace/qwen3_moe_fused/quantize_gguf/dequant.py"

with open(DEQUANT_FILE, "r") as f:
    content = f.read()

# The file at commit 1c51697 has a working IQ3_XXS.
# Replace it with a buggy stub that mirrors the initial session state:
# - No .clone() before .view(torch.int32) -> alignment RuntimeError
# - Uses F.embedding instead of direct tensor indexing
# - Wrong split_block_dims (missing the 32-byte split for scales)
buggy_iq3_xxs = textwrap.dedent("""\
    def dequantize_blocks_IQ3_XXS(blocks, block_size, type_size, dtype=None):
        n_blocks = blocks.shape[0]

        d, qs, scales = split_block_dims(blocks, 2, 64)

        d = d.view(torch.float16).to(dtype)
        # BUG: viewing unaligned tensor as int32 without clone causes RuntimeError
        scales = scales.view(torch.int32)

        db = d * (0.5 + ((scales >> 28) & 0xF).to(dtype)) * 0.5
        db = db.reshape(n_blocks, -1, 1, 1)

        # signs
        shifts = torch.tensor([0, 7, 14, 21], device=d.device, dtype=torch.int32).reshape(1, 1, 4)
        signs = (scales.reshape(n_blocks, -1, 1) >> shifts) & 0x7F

        signs = torch.nn.functional.embedding(signs, KSIGNS_IQ2_XXS.float().to(d.device))

        shifts_bits = torch.arange(8, device=d.device, dtype=torch.uint8).reshape(1, 1, 1, 8)
        signs = (signs.to(torch.uint8).unsqueeze(-1) >> shifts_bits) & 1
        signs = torch.where(
            signs == 0, torch.tensor(1.0, dtype=dtype, device=d.device), torch.tensor(-1.0, dtype=dtype, device=d.device)
        )

        # grid
        grid_val = torch.nn.functional.embedding(qs.long(), GRID_IQ3_XXS.to(dtype=dtype, device=d.device))
        grid_val = grid_val.reshape(n_blocks, -1, 4, 8)

        return (db * grid_val * signs).reshape(n_blocks, 256)

    """)

# Replace the working IQ3_XXS function with the buggy stub
# Match from function definition to the next blank line before dequantize_functions dict
pattern = r"def dequantize_blocks_IQ3_XXS\(.*?\n(?=\n(?:def |dequantize_functions))"
content = re.sub(pattern, buggy_iq3_xxs, content, flags=re.DOTALL)

with open(DEQUANT_FILE, "w") as f:
    f.write(content)

# Verify the synthesis worked
with open(DEQUANT_FILE) as f:
    source = f.read()
tree = ast.parse(source)
funcs = [n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]
print("Functions found:", funcs)
assert "dequantize_blocks_IQ3_XXS" in funcs, "IQ3_XXS function missing!"
assert "dequantize_blocks_IQ3_S" not in funcs, "IQ3_S should not exist yet!"
assert "F.embedding" not in source or "torch.nn.functional.embedding" in source, "Buggy F.embedding should be present"
print("Synthesis check passed - buggy IQ3_XXS installed, no other IQ functions present")
