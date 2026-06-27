Read this repo to understand how the nunchaku dequantization works. Check whether `pack_svdq_qweight` and `pack_awq_qweight` in @quantize.py are consistent with the dequantization in this repo. You may refer to @keys_bf16.txt and @keys_svdq_r128.txt for the parameter names, shapes, dtypes before and after the quantization.
--- Content from referenced files ---
Content from @keys_bf16.txt:
transformer_blocks.0.attn.add_k_proj.bias [3072] BF16
transformer_blocks.0.attn.add_k_proj.weight [3072, 3072] BF16
transformer_blocks.0.attn.add_q_proj.bias [3072] BF16
transformer_blocks.0.attn.add_q_proj.weight [3072, 3072] BF16
transformer_blocks.0.attn.add_v_proj.bias [3072] BF16
transformer_blocks.0.attn.add_v_proj.weight [3072, 3072] BF16
transformer_blocks.0.attn.norm_added_k.weight [128] BF16
transformer_blocks.0.attn.norm_added_q.weight [128] BF16
transformer_blocks.0.attn.norm_k.weight [128] BF16
transformer_blocks.0.attn.norm_q.weight [128] BF16
transformer_blocks.0.attn.to_add_out.bias [3072] BF16
transformer_blocks.0.attn.to_add_out.weight [3072, 3072] BF16
transformer_blocks.0.attn.to_k.bias [3072] BF16
transformer_blocks.0.attn.to_k.weight [3072, 3072] BF16
transformer_blocks.0.attn.to_out.0.bias [3072] BF16
transformer_blocks.0.attn.to_out.0.weight [3072, 3072] BF16
transformer_blocks.0.attn.to_q.bias [3072] BF16
transformer_blocks.0.attn.to_q.weight [3072, 3072] BF16
transformer_blocks.0.attn.to_v.bias [3072] BF16
transformer_blocks.0.attn.to_v.weight [3072, 3072] BF16
transformer_blocks.0.img_mlp.net.0.proj.bias [12288] BF16
transformer_blocks.0.img_mlp.net.0.proj.weight [12288, 3072] BF16
transformer_blocks.0.img_mod.1.bias [18432] BF16
transformer_blocks.0.img_mod.1.weight [18432, 3072] BF16
transformer_blocks.0.txt_mlp.net.0.proj.bias [12288] BF16
transformer_blocks.0.txt_mlp.net.0.proj.weight [12288, 3072] BF16
transformer_blocks.0.txt_mod.1.bias [18432] BF16
transformer_blocks.0.txt_mod.1.weight [18432, 3072] BF16
Content from @keys_svdq_r128.txt:
transformer_blocks.0.attn.add_qkv_proj.bias [9216] BF16
transformer_blocks.0.attn.add_qkv_proj.proj_down [3072, 128] BF16
transformer_blocks.0.attn.add_qkv_proj.proj_up [9216, 128] BF16
transformer_blocks.0.attn.add_qkv_proj.qweight [9216, 1536] I8
transformer_blocks.0.attn.add_qkv_proj.smooth_factor [3072] BF16
transformer_blocks.0.attn.add_qkv_proj.smooth_factor_orig [3072] BF16
transformer_blocks.0.attn.add_qkv_proj.wscales [48, 9216] BF16
transformer_blocks.0.attn.norm_added_k.weight [128] BF16
transformer_blocks.0.attn.norm_added_q.weight [128] BF16
transformer_blocks.0.attn.norm_k.weight [128] BF16
transformer_blocks.0.attn.norm_q.weight [128] BF16
transformer_blocks.0.attn.to_add_out.bias [3072] BF16
transformer_blocks.0.attn.to_add_out.proj_down [3072, 128] BF16
transformer_blocks.0.attn.to_add_out.proj_up [3072, 128] BF16
transformer_blocks.0.attn.to_add_out.qweight [3072, 1536] I8
transformer_blocks.0.attn.to_add_out.smooth_factor [3072] BF16
transformer_blocks.0.attn.to_add_out.smooth_factor_orig [3072] BF16
transformer_blocks.0.attn.to_add_out.wscales [48, 3072] BF16
transformer_blocks.0.attn.to_out.0.bias [3072] BF16
transformer_blocks.0.attn.to_out.0.proj_down [3072, 128] BF16
transformer_blocks.0.attn.to_out.0.proj_up [3072, 128] BF16
transformer_blocks.0.attn.to_out.0.qweight [3072, 1536] I8
transformer_blocks.0.attn.to_out.0.smooth_factor [3072] BF16
transformer_blocks.0.attn.to_out.0.smooth_factor_orig [3072] BF16
transformer_blocks.0.attn.to_out.0.wscales [48, 3072] BF16
transformer_blocks.0.attn.to_qkv.bias [9216] BF16
transformer_blocks.0.attn.to_qkv.proj_down [3072, 128] BF16
transformer_blocks.0.attn.to_qkv.proj_up [9216, 128] BF16
transformer_blocks.0.attn.to_qkv.qweight [9216, 1536] I8
transformer_blocks.0.attn.to_qkv.smooth_factor [3072] BF16
transformer_blocks.0.attn.to_qkv.smooth_factor_orig [3072] BF16
transformer_blocks.0.attn.to_qkv.wscales [48, 9216] BF16
transformer_blocks.0.img_mlp.net.0.proj.bias [12288] BF16
transformer_blocks.0.img_mlp.net.0.proj.proj_down [3072, 128] BF16
transformer_blocks.0.img_mlp.net.0.proj.proj_up [12288, 128] BF16
transformer_blocks.0.img_mlp.net.0.proj.qweight [12288, 1536] I8
transformer_blocks.0.img_mlp.net.0.proj.smooth_factor [3072] BF16
transformer_blocks.0.img_mlp.net.0.proj.smooth_factor_orig [3072] BF16
transformer_blocks.0.img_mlp.net.0.proj.wscales [48, 12288] BF16
transformer_blocks.0.img_mod.1.bias [18432] BF16
transformer_blocks.0.img_mod.1.qweight [4608, 1536] I32
transformer_blocks.0.img_mod.1.wscales [48, 18432] BF16
transformer_blocks.0.img_mod.1.wzeros [48, 18432] BF16
transformer_blocks.0.txt_mlp.net.0.proj.bias [12288] BF16
transformer_blocks.0.txt_mlp.net.0.proj.proj_down [3072, 128] BF16
transformer_blocks.0.txt_mlp.net.0.proj.proj_up [12288, 128] BF16
transformer_blocks.0.txt_mlp.net.0.proj.qweight [12288, 1536] I8
transformer_blocks.0.txt_mlp.net.0.proj.smooth_factor [3072] BF16
transformer_blocks.0.txt_mlp.net.0.proj.smooth_factor_orig [3072] BF16
transformer_blocks.0.txt_mlp.net.0.proj.wscales [48, 12288] BF16
transformer_blocks.0.txt_mod.1.bias [18432] BF16
transformer_blocks.0.txt_mod.1.qweight [4608, 1536] I32
transformer_blocks.0.txt_mod.1.wscales [48, 18432] BF16
transformer_blocks.0.txt_mod.1.wzeros [48, 18432] BF16
Content from @quantize.py:
#!/usr/bin/env python3

import argparse

import safetensors
import safetensors.torch
import torch
from tqdm import tqdm


# Input: int32, shape (N, K), values in [0, 15]
# Output: int8, shape (N, K/2)
def pack_svdq_qweight(weight):
    n, k = weight.shape
    device = weight.device
    assert weight.dtype == torch.int32

    # Parameters from NunchakuWeightPacker(bits=4, warp_n=128)
    mem_n = 128
    mem_k = 64
    num_k_unrolls = 2
    assert n % mem_n == 0
    assert k % (mem_k * num_k_unrolls) == 0

    n_tiles = n // mem_n
    k_tiles = k // mem_k

    num_n_packs = 8
    n_pack_size = 2
    num_n_lanes = 8
    reg_n = 1

    num_k_packs = 1
    k_pack_size = 2
    num_k_lanes = 4
    reg_k = 8

    weight = weight.view(
        n_tiles,
        num_n_packs,
        n_pack_size,
        num_n_lanes,
        reg_n,
        k_tiles,
        num_k_packs,
        k_pack_size,
        num_k_lanes,
        reg_k,
    )

    #    (n_tiles, num_n_packs, n_pack_size, num_n_lanes, reg_n, k_tiles, num_k_packs, k_pack_size, num_k_lanes, reg_k)
    # -> (n_tiles, k_tiles, num_k_packs, num_n_packs, num_n_lanes, num_k_lanes, n_pack_size, k_pack_size, reg_n, reg_k)
    weight = weight.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9)

    weight = weight.view(n, k // 8, 8)
    packed = torch.zeros((n, k // 8), device=device, dtype=torch.int32)
    for i in range(8):
        packed |= weight[:, :, i] << (i * 4)

    packed = packed.view(torch.int8).view(n, k // 2)
    return packed


def quantize_residual(residual):
    group_size = 64
    N, K = residual.shape
    assert K % group_size == 0
    assert residual.dtype == torch.float32

    residual = residual.view(N, K // group_size, group_size)

    wscales = torch.abs(residual).max(dim=-1, keepdim=True)
    wscales = wscales / 7
    # Avoid zero division
    wscales = torch.clamp(wscales, min=1e-5)

    qweight = residual / wscales
    qweight = torch.clamp(torch.round(qweight).to(torch.int32), -8, 7)
    # Map -8..7 to 0..15
    qweight = qweight + 8

    qweight = qweight.view(N, K)
    qweight = pack_svdq_qweight(qweight)

    wscales = wscales.squeeze(-1).T
    return qweight, wscales


def quantize_svdq_layer(weight, smooth_factor, rank=128):
    N, K = weight.shape
    dtype = weight.dtype

    # Upcast to float32 before quantization
    weight = weight.float()
    smooth_factor = smooth_factor.float()
    weight = weight * smooth_factor.view(1, -1)

    U, S, Vh = torch.svd_lowrank(weight, q=min(2 * rank, N, K))
    Vh = Vh.T

    U = U[:, :rank]
    S = S[:rank]
    Vh = Vh[:rank, :]

    sqrt_S = torch.sqrt(S)
    proj_up = U * sqrt_S.view(1, -1)
    proj_down = Vh * sqrt_S.view(-1, 1)

    residual = weight - proj_up @ proj_down

    proj_up = proj_up.to(dtype)
    proj_down = proj_down.T.to(dtype)

    qweight, wscales = quantize_residual(residual)
    assert qweight.dtype == torch.int8
    wscales = wscales.to(dtype)
    return proj_down, proj_up, qweight, wscales


def pack_awq_qweight(weight):
    N, K = weight.shape
    device = weight.device
    assert weight.dtype == torch.int32

    weight = weight.view(N, K // 32, 32)
    packed = torch.zeros((N, K // 32, 4), device=device, dtype=torch.int32)
    for g in range(4):
        shift_low = 4 * g
        shift_high = 16 + 4 * g
        for j in range(4):
            idx_even = 8 * g + 2 * j
            idx_odd = 8 * g + 2 * j + 1
            w_even = weight[:, :, idx_even]
            w_odd = weight[:, :, idx_odd]
            packed[:, :, j] |= w_even << shift_low
            packed[:, :, j] |= w_odd << shift_high

    packed = packed.view(N // 4, K // 2)
    return packed


def quantize_awq_layer(weight):
    group_size = 64
    N, K = weight.shape
    assert K % group_size == 0
    assert K % 32 == 0
    assert N % 4 == 0
    dtype = weight.dtype

    # Upcast to float32 before quantization
    weight = weight.float()
    weight = weight.view(N, K // group_size, group_size)

    w_min = weight.min(dim=-1, keepdim=True)
    w_max = weight.max(dim=-1, keepdim=True)
    wscales = (w_max - w_min) / 15
    # Avoid zero division
    wscales = torch.clamp(wscales, min=1e-5)
    wzeros = w_min

    qweight = (weight - wzeros) / wscales
    qweight = torch.clamp(torch.round(qweight).to(torch.int32), 0, 15)

    qweight = qweight.view(N, K)
    qweight = pack_awq_qweight(qweight)

    wscales = wscales.squeeze(-1).T
    wzeros = wzeros.squeeze(-1).T
    return qweight, wscales, wzeros


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-a", type=str, help="SVDQ model to borrow")
    parser.add_argument("--model-b", type=str, help="BF16 model to quantize")
    parser.add_argument("--output", type=str)
    args = parser.parse_args()

    tensors_c = {}
    with (
        safetensors.safe_open(args.model_a, framework="pt") as f_a,
        safetensors.safe_open(args.model_b, framework="pt") as f_b,
    ):
        # Copy non-transformer block parameters from B to C
        for k in f_b.keys():
            if not k.startswith("transformer_blocks."):
                tensors_c[k] = f_b.get_tensor(k)

        # Process 60 transformer blocks
        for i in tqdm(range(60)):
            block_prefix = f"transformer_blocks.{i}."

            def get_a(name):
                return f_a.get_tensor(block_prefix + name)

            def get_b(name):
                return f_b.get_tensor(block_prefix + name)

            # Quantize SVDQ layers
            svdq_layers = [
                (
                    "attn.to_qkv",
                    [
                        "attn.to_q.weight",
                        "attn.to_k.weight",
                        "attn.to_v.weight",
                    ],
                    [
                        "attn.to_q.bias",
                        "attn.to_k.bias",
                        "attn.to_v.bias",
                    ],
                ),
                (
                    "attn.add_qkv_proj",
                    [
                        "attn.add_q_proj.weight",
                        "attn.add_k_proj.weight",
                        "attn.add_v_proj.weight",
                    ],
                    [
                        "attn.add_q_proj.bias",
                        "attn.add_k_proj.bias",
                        "attn.add_v_proj.bias",
                    ],
                ),
                (
                    "attn.to_out.0",
                    ["attn.to_out.0.weight"],
                    ["attn.to_out.0.bias"],
                ),
                (
                    "attn.to_add_out",
                    ["attn.to_add_out.weight"],
                    ["attn.to_add_out.bias"],
                ),
                (
                    "img_mlp.net.0.proj",
                    ["img_mlp.net.0.proj.weight"],
                    ["img_mlp.net.0.proj.bias"],
                ),
                (
                    "txt_mlp.net.0.proj",
                    ["txt_mlp.net.0.proj.weight"],
                    ["txt_mlp.net.0.proj.bias"],
                ),
            ]
            for target_name, src_weights, src_biases in svdq_layers:
                if len(src_weights) > 1:
                    weight = torch.cat([get_b(x) for x in src_weights], dim=0)
                    bias = torch.cat([get_b(x) for x in src_biases], dim=0)
                else:
                    weight = get_b(src_weights[0])
                    bias = get_b(src_biases[0])

                smooth_factor = get_a(f"{target_name}.smooth_factor")

                device = "cuda"
                outs = quantize_svdq_layer(weight.to(device), smooth_factor.to(device))
                outs = [x.to("cpu") for x in outs]
                proj_down, proj_up, qweight, wscales = outs

                base = block_prefix + target_name
                tensors_c[f"{base}.bias"] = bias
                tensors_c[f"{base}.proj_down"] = proj_down
                tensors_c[f"{base}.proj_up"] = proj_up
                tensors_c[f"{base}.qweight"] = qweight
                tensors_c[f"{base}.wscales"] = wscales
                tensors_c[f"{base}.smooth_factor"] = smooth_factor

            # Quantize AWQ layers
            awq_layers = ["img_mod.1", "txt_mod.1"]
            for name in awq_layers:
                weight = get_b(f"{name}.{weight}")
                bias = get_b(f"{name}.{bias}")

                device = "cuda"
                outs = quantize_awq_layer(weight.to(device))
                outs = [x.to("cpu") for x in outs]
                qweight, wscales, wzeros = outs

                base = block_prefix + name
                tensors_c[f"{base}.bias"] = bias
                tensors_c[f"{base}.qweight"] = qweight
                tensors_c[f"{base}.wscales"] = wscales
                tensors_c[f"{base}.wzeros"] = wzeros

            # Copy other parameters
            norms = [
                "attn.norm_k.weight",
                "attn.norm_q.weight",
                "attn.norm_added_k.weight",
                "attn.norm_added_q.weight",
            ]
            for name in norms:
                tensors_c[block_prefix + name] = get_b(name)

    print(f"Saving model to {args.output}...")
    safetensors.torch.save_file(tensors_c, args.output)
    print("Done.")


if __name__ == "__main__":
    main()
--- End of content ---
