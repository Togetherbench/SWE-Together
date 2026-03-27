I'm trying to reimplement Nunchaku SVDQ in `quantize_nunchaku_borrow.py` but currently it gives wrong result. I've verified that the AWQ part is correct.

The tensor shapes before and after quantization are documented in `keys_bf16.txt` and `keys_svdq_r128.txt`.

Your task is to read the original source code in the `nunchaku` folder to understand how the SVDQ layer works in the inference of Qwen-Image-Edit.
Then write a new script `reconstruct_weight.py` that reconstructs `weight` given the packed `proj_down, proj_up, qweight, wscales, smooth_factor`, and verify your result against the groundtruth `weight`.

The data in the folder `pt` are the groundtruth for the parameters:
- `attn.to_out.0`
- `attn.to_add_out`
- `img_mlp.net.0.proj`
- `img_mlp.net.2`
- `txt_mlp.net.0.proj`
- `txt_mlp.net.2`

For each parameter `<name>`, the `pt/` directory contains:
- `pt/<name>.weight.pt` — the original BF16 weight (groundtruth)
- `pt/<name>.proj_down.pt` — the packed low-rank proj_down tensor
- `pt/<name>.proj_up.pt` — the packed low-rank proj_up tensor
- `pt/<name>.qweight.pt` — the packed quantized weight (int8, 2 nibbles per byte)
- `pt/<name>.wscales.pt` — the packed weight scales
- `pt/<name>.smooth_factor.pt` — the smooth factor (not packed)

The key BF16 parameter shapes are:
```
attn.to_out.0.weight     [3072, 3072]  BF16
attn.to_add_out.weight   [3072, 3072]  BF16
img_mlp.net.0.proj.weight [12288, 3072] BF16
img_mlp.net.2.weight     [3072, 12288] BF16
txt_mlp.net.0.proj.weight [12288, 3072] BF16
txt_mlp.net.2.weight     [3072, 12288] BF16
```

The SVDQ quantized parameter shapes are:
```
attn.to_out.0.proj_down  [3072, 128]  BF16
attn.to_out.0.proj_up    [3072, 128]  BF16
attn.to_out.0.qweight    [3072, 1536] I8
attn.to_out.0.smooth_factor [3072]   BF16
attn.to_out.0.wscales    [48, 3072]  BF16

img_mlp.net.2.proj_down  [12288, 128] BF16
img_mlp.net.2.proj_up    [3072, 128]  BF16
img_mlp.net.2.qweight    [3072, 6144] I8
img_mlp.net.2.smooth_factor [12288]  BF16
img_mlp.net.2.wscales    [192, 3072] BF16
```

The packing was done using `NunchakuWeightPacker(bits=4, warp_n=128)` from `nunchaku/lora/flux/packer.py`.
Read that file to understand the packing layout and implement the correct inverse.

`quantize_nunchaku_borrow.py` contains the quantization functions used to produce the packed data. It already has a (broken) initial attempt at `reconstruct_weight.py` in the workspace — your job is to fix it.

Run `python reconstruct_weight.py` to test your implementation. All 6 parameters must pass with max diff < 0.1.
