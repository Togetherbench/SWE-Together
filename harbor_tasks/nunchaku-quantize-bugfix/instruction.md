Review `/workspace/quantize.py` and fix all bugs you find. The script quantizes Flux transformer weights for the nunchaku inference engine. The nunchaku repo is cloned at `/workspace/nunchaku/` for reference — you can read its dequantization kernels and packing utilities to understand the expected data layout.

Reference files `keys_bf16.txt` and `keys_svdq_r128.txt` in `/workspace/` show parameter names, shapes, and dtypes before and after quantization.

Focus areas:
- Do the quantization functions (`quantize_residual`, `quantize_awq_layer`) run correctly on sample tensors?
- Does `main()` correctly construct tensor key names when loading weights?
- Are the pack functions (`pack_svdq_qweight`, `pack_awq_qweight`) producing correct output?
- The nested loops in `pack_awq_qweight` can be simplified to a single loop using bitwise `|=` operations (not `sum()`). Please simplify the loop structure while keeping the output identical to the original.
