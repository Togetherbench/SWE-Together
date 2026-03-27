When I run Triton on Windows with AMD GPU, it shows:
```
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:33:26: error: 'tt.load' op operation destroyed but still has uses
        k_scale = tl.load(K_scale_ptr)
                         ^
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:137:51: note: called from
                                4 - STAGE, offs_m, offs_n,
                                                  ^
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:39:53: note: - use: %165 = "tt.splat"(<<UNKNOWN SSA VALUE>>) : (f32) -> tensor<64x64xf32, #ttg.amd_wmma<{version = 2, isTranspose = true, warpsPerCTA = [8, 1]}>>

        qk = tl.dot(q, k).to(tl.float32) * q_scale * k_scale
                                                    ^
LLVM ERROR: operation destroyed but still has uses
```
