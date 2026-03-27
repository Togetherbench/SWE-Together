"""
Synthesize test data and buggy initial state for nunchaku-implement-a56d1e.

Creates:
- pt/<name>.{weight,proj_down,proj_up,qweight,wscales,smooth_factor}.pt
  for 6 synthetic test cases covering the main layer types
- reconstruct_weight.py: buggy initial version (wrong unpack logic)

The packing uses the same logic as NunchakuWeightPacker(bits=4, warp_n=128)
from nunchaku/lora/flux/packer.py. The agent reads that file to understand
the layout and implement correct inverses.
"""
import os
import sys
import torch

torch.manual_seed(42)
os.makedirs("pt", exist_ok=True)

# ── Pure-Python implementations of nunchaku's pack functions ──────────────────
# These mirror NunchakuWeightPacker(bits=4, warp_n=128) exactly.

def pack_svdq_qweight(weight_int32):
    """Pack (N, K) int32 values in 0..15 → (N, K//2) int8."""
    n, k = weight_int32.shape
    assert weight_int32.dtype == torch.int32
    mem_n, mem_k = 128, 64
    n_tiles, k_tiles = n // mem_n, k // mem_k

    # Reshape to (n_tiles, num_n_packs=8, n_pack_size=2, num_n_lanes=8,
    #             reg_n=1, k_tiles, num_k_packs=1, k_pack_size=2, num_k_lanes=4, reg_k=8)
    w = weight_int32.view(n_tiles, 8, 2, 8, 1, k_tiles, 1, 2, 4, 8)
    # Permute to (n_tiles, k_tiles, 1, 8, 8, 4, 2, 2, 1, 8)
    w = w.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9).contiguous()
    # Pack 8 nibbles into one int32, then view as int8
    w = w.view(n, k // 8, 8)
    packed = torch.zeros((n, k // 8), dtype=torch.int32)
    for i in range(8):
        packed |= w[:, :, i] << (i * 4)
    return packed.view(torch.int8).view(n, k // 2)


def pack_svdq_scale(scale_fp):
    """Pack (N, K//G) float → (K//G, N) packed.
    Mirrors NunchakuWeightPacker.pack_scale with group_size=64, warp_n=128.
    s_pack_size=4, num_s_lanes=32, num_s_packs=1."""
    n, k_div_g = scale_fp.shape
    assert n % 128 == 0
    # Reshape: (N//128, 1, 8, 2, 4, 2, K//G)
    s = scale_fp.reshape(n // 128, 1, 8, 2, 4, 2, k_div_g)
    # Permute: (N//128, K//G, 1, 8, 4, 2, 2)
    s = s.permute(0, 6, 1, 2, 4, 3, 5).contiguous()
    return s.view(k_div_g, n)


def pack_lowrank(weight, down):
    """Pack low-rank weight for NunchakuWeightPacker(bits=4, warp_n=128).
    down=True:  input (K, R) → output (K, R)
    down=False: input (N, R) → output (N, R)
    pack_n = pack_k = 16
    """
    reg_n, reg_k = 1, 2
    n_pack_size, num_n_lanes = 2, 8
    k_pack_size, num_k_lanes = 2, 4
    pack_n = n_pack_size * num_n_lanes * reg_n   # 16
    pack_k = k_pack_size * num_k_lanes * reg_k   # 16

    if down:
        r, c = weight.shape           # r=K, c=R
        r_packs = r // pack_n
        c_packs = c // pack_k
        w = weight.view(r_packs, pack_n, c_packs, pack_k).permute(2, 0, 1, 3)
    else:
        c, r = weight.shape           # c=N, r=R
        c_packs = c // pack_n
        r_packs = r // pack_k
        w = weight.view(c_packs, pack_n, r_packs, pack_k).permute(0, 2, 1, 3)

    w = w.reshape(c_packs, r_packs,
                  n_pack_size, num_n_lanes, reg_n,
                  k_pack_size, num_k_lanes, reg_k)
    w = w.permute(0, 1, 3, 6, 2, 5, 4, 7).contiguous()

    if down:
        return w.view(r, c)
    else:
        return w.view(c, r)


def quantize_and_pack(weight_bf16, smooth_factor_bf16, rank=16):
    """Quantize a BF16 weight matrix using SVDQ and return packed tensors.
    Also returns the exact reconstruction (what you'd get with correct unpack).
    """
    N, K = weight_bf16.shape
    w = weight_bf16.float()
    sf = smooth_factor_bf16.float()

    # Apply smooth factor
    w_sm = w * sf.unsqueeze(0)  # (N, K)

    # Low-rank SVD
    U, S, Vh = torch.linalg.svd(w_sm, full_matrices=False)
    U = U[:, :rank]; S = S[:rank]; Vh = Vh[:rank, :]
    sqrt_S = S.sqrt()
    proj_up  = (U * sqrt_S.unsqueeze(0)).to(torch.bfloat16)   # (N, R)
    proj_down = (Vh.T * sqrt_S.unsqueeze(0)).to(torch.bfloat16)  # (K, R)

    # Residual quantization (group_size=64)
    G = 64
    residual = (w_sm - proj_up.float() @ proj_down.float().T).view(N, K // G, G)
    wscales_raw = residual.abs().amax(dim=-1) / 7.0            # (N, K//G)
    wscales_raw = wscales_raw.clamp(min=1e-8)
    qw_int = (residual / wscales_raw.unsqueeze(-1)).round().to(torch.int32).clamp(-8, 7)
    qw_packed_input = (qw_int & 0xF).view(N, K)

    # Compute exact reconstruction (what correct unpack should produce).
    # This is the reference for Gold tests — bypasses pack→unpack error.
    residual_dequant = (qw_int.float() * wscales_raw.to(torch.bfloat16).float().unsqueeze(-1)).view(N, K)
    low_rank_exact = proj_up.float() @ proj_down.float().T
    weight_approx = ((residual_dequant + low_rank_exact) / sf.unsqueeze(0)).to(torch.bfloat16)

    # Pack
    qweight_p   = pack_svdq_qweight(qw_packed_input)
    wscales_p   = pack_svdq_scale(wscales_raw.to(torch.bfloat16))
    proj_up_p   = pack_lowrank(proj_up, down=False)
    proj_down_p = pack_lowrank(proj_down, down=True)

    return proj_down_p, proj_up_p, qweight_p, wscales_p, weight_approx


# ── Create synthetic test cases ───────────────────────────────────────────────
# Dimensions chosen to be small (fast on CPU) but match the real shape structure:
#   attn-like:    N=256, K=256  (square, like to_out.0 but smaller)
#   mlp-down:     N=512, K=256  (N > K, like img_mlp.net.0.proj)
#   mlp-up:       N=256, K=512  (N < K, like img_mlp.net.2)
CASES = [
    ("attn.to_out.0",       256, 256),
    ("attn.to_add_out",     256, 256),
    ("img_mlp.net.0.proj",  512, 256),
    ("img_mlp.net.2",       256, 512),
    ("txt_mlp.net.0.proj",  512, 256),
    ("txt_mlp.net.2",       256, 512),
]
RANK = 16

for name, N, K in CASES:
    torch.manual_seed(hash(name) & 0xFFFFFF)
    weight = torch.randn(N, K, dtype=torch.bfloat16)
    smooth = torch.abs(torch.randn(K, dtype=torch.bfloat16)) + 0.5

    proj_down_p, proj_up_p, qweight_p, wscales_p, weight_approx = quantize_and_pack(weight, smooth, rank=RANK)

    torch.save(weight,        f"pt/{name}.weight.pt")
    torch.save(weight_approx, f"pt/{name}.weight_approx.pt")
    torch.save(proj_down_p,   f"pt/{name}.proj_down.pt")
    torch.save(proj_up_p,     f"pt/{name}.proj_up.pt")
    torch.save(qweight_p,     f"pt/{name}.qweight.pt")
    torch.save(wscales_p,     f"pt/{name}.wscales.pt")
    torch.save(smooth,        f"pt/{name}.smooth_factor.pt")

print("Test data created for", len(CASES), "cases.")

# ── Write buggy initial reconstruct_weight.py ─────────────────────────────────
# Mirrors the initial version from the session (msg 11):
#   - unpack_svdq_qweight is WRONG (incorrect permute inverse)
#   - wscales are just transposed, not properly unpacked
#   - proj_up / proj_down are not unpacked at all
BUGGY = '''#!/usr/bin/env python3
"""Weight reconstruction (dequantization) script for Nunchaku SVDQ format.
Currently broken -- fix the unpack functions to pass the tests.
"""
import torch
import os


def unpack_svdq_qweight(qweight, N, K):
    """Unpack (N, K//2) int8 nibble-packed qweight back to (N, K) int32."""
    qw = qweight.long() & 0xFF
    el_low  = qw & 0xF
    el_high = (qw >> 4) & 0xF
    unpacked = torch.stack([el_low, el_high], dim=-1).view(N, K)

    mem_n, mem_k = 128, 64
    n_tiles = N // mem_n
    k_tiles = K // mem_k

    # BUG: wrong reshape dimensions -- the permuted shape is different
    reshaped = unpacked.view(n_tiles, k_tiles, 1, 8, 8, 4, 2, 2, 1, 8)
    # BUG: wrong inverse permute
    back = reshaped.permute(0, 3, 6, 4, 8, 1, 2, 7, 5, 9)
    return back.contiguous().view(N, K)


def reconstruct_weight(name):
    gt_weight    = torch.load(f"pt/{name}.weight.pt", weights_only=True)
    proj_down    = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
    proj_up      = torch.load(f"pt/{name}.proj_up.pt", weights_only=True)
    qweight      = torch.load(f"pt/{name}.qweight.pt", weights_only=True)
    smooth       = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
    wscales      = torch.load(f"pt/{name}.wscales.pt", weights_only=True)

    N, K = gt_weight.shape

    # 1. Unpack qweight
    qw_unpacked = unpack_svdq_qweight(qweight, N, K).float()
    qw_unpacked[qw_unpacked >= 8] -= 16

    # 2. Dequantize: BUG -- wscales just transposed, not properly unpacked
    wscales_t = wscales.T.float()                           # (N, K//64)
    wscales_exp = wscales_t.repeat_interleave(64, dim=1)    # (N, K)
    residual = qw_unpacked * wscales_exp

    # 3. Low-rank: BUG -- proj_up / proj_down not unpacked
    low_rank = proj_up.float() @ proj_down.float().T

    # 4. Combine and desmooth
    weight_recon = (residual + low_rank) / smooth.float().unsqueeze(0)

    diff = (weight_recon - gt_weight.float()).abs()
    return diff.max().item(), diff.mean().item()


def main():
    torch.set_default_dtype(torch.bfloat16)
    params = [
        "attn.to_out.0", "attn.to_add_out",
        "img_mlp.net.0.proj", "img_mlp.net.2",
        "txt_mlp.net.0.proj", "txt_mlp.net.2",
    ]
    all_pass = True
    for p in params:
        max_d, mean_d = reconstruct_weight(p)
        status = "PASSED" if max_d < 0.1 else "FAILED"
        if status == "FAILED":
            all_pass = False
        print(f"{p}: max_diff={max_d:.4f} mean_diff={mean_d:.6f} [{status}]")
    print("\\nAll passed!" if all_pass else "\\nSome tests FAILED.")


if __name__ == "__main__":
    main()
'''

with open("reconstruct_weight.py", "w") as f:
    f.write(BUGGY)

print("Buggy reconstruct_weight.py written.")
