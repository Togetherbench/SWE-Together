#!/usr/bin/env python3
"""
Synthesize the initial (non-idiomatic) NewBie PR state for the ComfyUI refactoring task.

This script applies the initial newbie branch changes on top of the master commit:
1. Removes clip_text_dim support from comfy/ldm/lumina/model.py
2. Creates comfy/ldm/newbie/ with anti-pattern implementation
3. Adds NewBieImage to comfy/model_base.py (with unnecessary apply_model override)
4. Adds NewBieImageModel to comfy/supported_models.py
5. Adds NewBie model detection to comfy/model_detection.py
"""

import os
import re

REPO = "/workspace/ComfyUI"


def patch_lumina_model():
    """Remove clip_text_dim support from NextDiT (the initial PR removed this)."""
    path = os.path.join(REPO, "comfy/ldm/lumina/model.py")
    with open(path, "r") as f:
        content = f.read()

    # Remove the clip_text_dim parameter from NextDiT.__init__ signature
    content = re.sub(
        r'\s*clip_text_dim=None,\n',
        '\n',
        content
    )

    # Remove the clip_text_pooled_proj initialization block
    clip_proj_block = '''        self.clip_text_pooled_proj = None

        if clip_text_dim is not None:
            self.clip_text_dim = clip_text_dim
            self.clip_text_pooled_proj = nn.Sequential(
                operation_settings.get("operations").RMSNorm(clip_text_dim, eps=norm_eps, elementwise_affine=True, device=operation_settings.get("device"), dtype=operation_settings.get("dtype")),
                operation_settings.get("operations").Linear(
                    clip_text_dim,
                    clip_text_dim,
                    bias=True,
                    device=operation_settings.get("device"),
                    dtype=operation_settings.get("dtype"),
                ),
            )
            self.time_text_embed = nn.Sequential(
                nn.SiLU(),
                operation_settings.get("operations").Linear(
                    min(dim, 1024) + clip_text_dim,
                    min(dim, 1024),
                    bias=True,
                    device=operation_settings.get("device"),
                    dtype=operation_settings.get("dtype"),
                ),
            )

'''
    content = content.replace(clip_proj_block, "")

    # Remove the clip_text_pooled_proj usage block in _forward
    forward_clip_block = '''        if self.clip_text_pooled_proj is not None:
            pooled = kwargs.get("clip_text_pooled", None)
            if pooled is not None:
                pooled = self.clip_text_pooled_proj(pooled)
            else:
                pooled = torch.zeros((1, self.clip_text_dim), device=x.device, dtype=x.dtype)

            adaln_input = self.time_text_embed(torch.cat((t, pooled), dim=-1))

'''
    content = content.replace(forward_clip_block, "")

    # Also add self.norm_eps to NextDiT.__init__ (needed for NewBie to use operations.RMSNorm).
    # This is part of the newbie branch's changes to NextDiT.
    content = content.replace(
        "        self.rope_embedder = EmbedND(dim=dim // n_heads, theta=rope_theta, axes_dim=axes_dims)\n        self.dim = dim\n        self.n_heads = n_heads",
        "        self.rope_embedder = EmbedND(dim=dim // n_heads, theta=rope_theta, axes_dim=axes_dims)\n        self.dim = dim\n        self.n_heads = n_heads\n        self.norm_eps = norm_eps"
    )

    with open(path, "w") as f:
        f.write(content)
    print("Patched comfy/ldm/lumina/model.py")


def create_newbie_components():
    """Create comfy/ldm/newbie/components.py with a standalone RMSNorm."""
    newbie_dir = os.path.join(REPO, "comfy/ldm/newbie")
    os.makedirs(newbie_dir, exist_ok=True)

    # Create __init__.py
    with open(os.path.join(newbie_dir, "__init__.py"), "w") as f:
        f.write("")

    components_content = '''import warnings

import torch
import torch.nn as nn

try:
    from apex.normalization import FusedRMSNorm as RMSNorm
except ImportError:
    warnings.warn("Cannot import apex RMSNorm, switch to vanilla implementation")

    class RMSNorm(torch.nn.Module):
        def __init__(self, dim: int, eps: float = 1e-6):
            """
            Initialize the RMSNorm normalization layer.

            Args:
                dim (int): The dimension of the input tensor.
                eps (float, optional): A small value added to the denominator for numerical stability. Default is 1e-6.

            Attributes:
                eps (float): A small value added to the denominator for numerical stability.
                weight (nn.Parameter): Learnable scaling parameter.

            """
            super().__init__()
            self.eps = eps
            self.weight = nn.Parameter(torch.ones(dim))

        def _norm(self, x):
            """
            Apply the RMSNorm normalization to the input tensor.

            Args:
                x (torch.Tensor): The input tensor.

            Returns:
                torch.Tensor: The normalized tensor.

            """
            return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps)

        def forward(self, x):
            """
            Forward pass through the RMSNorm layer.

            Args:
                x (torch.Tensor): The input tensor.

            Returns:
                torch.Tensor: The output tensor after applying RMSNorm.

            """
            output = self._norm(x.float()).type_as(x)
            return output * self.weight
'''

    with open(os.path.join(newbie_dir, "components.py"), "w") as f:
        f.write(components_content)
    print("Created comfy/ldm/newbie/components.py")


def create_newbie_model():
    """Create comfy/ldm/newbie/model.py with initial anti-pattern implementation."""
    model_content = '''from __future__ import annotations
from typing import Optional, Any, Dict
import torch
import torch.nn as nn
import comfy.ldm.common_dit as common_dit
from comfy.ldm.lumina.model import NextDiT as NextDiTBase
from .components import RMSNorm

#######################################################
#            Adds support for NewBie image            #
#######################################################

def _fallback_operations():
    try:
        import comfy.ops
        return comfy.ops.disable_weight_init
    except Exception:
        return None

def _pop_unexpected_kwargs(kwargs: Dict[str, Any]) -> None:
    for k in (
        "model_type",
        "operation_settings",
        "unet_dtype",
        "weight_dtype",
        "precision",
        "extra_model_config",
    ):
        kwargs.pop(k, None)

class NewBieNextDiT_CLIP(NextDiTBase):

    def __init__(
        self,
        *args,
        clip_text_dim: int = 1024,
        clip_img_dim: int = 1024,
        device=None,
        dtype=None,
        operations=None,
        **kwargs,
    ):
        _pop_unexpected_kwargs(kwargs)
        if operations is None:
            operations = _fallback_operations()
        super().__init__(*args, device=device, dtype=dtype, operations=operations, **kwargs)
        self._nb_device = device
        self._nb_dtype = dtype
        self._nb_ops = operations
        min_mod = min(int(getattr(self, "dim", 1024)), 1024)
        if operations is not None and hasattr(operations, "Linear"):
            Linear = operations.Linear
            Norm = getattr(operations, "RMSNorm", None)
        else:
            Linear = nn.Linear
            Norm = None

        if Norm is None:
            Norm = RMSNorm

        self.clip_text_pooled_proj = nn.Sequential(
            Norm(clip_text_dim, eps=1e-5, elementwise_affine=True, device=device, dtype=dtype),
            Linear(clip_text_dim, clip_text_dim, bias=True, device=device, dtype=dtype),
        )

        nn.init.normal_(self.clip_text_pooled_proj[1].weight, std=0.01)
        nn.init.zeros_(self.clip_text_pooled_proj[1].bias)
        self.time_text_embed = nn.Sequential(
            nn.SiLU(),
            Linear(min_mod + clip_text_dim, min_mod, bias=True, device=device, dtype=dtype),
        )
        nn.init.zeros_(self.time_text_embed[1].weight)
        nn.init.zeros_(self.time_text_embed[1].bias)

        self.clip_img_pooled_embedder = nn.Sequential(
            Norm(clip_img_dim, eps=1e-5, elementwise_affine=True, device=device, dtype=dtype),
            Linear(clip_img_dim, min_mod, bias=True, device=device, dtype=dtype),
        )

        nn.init.normal_(self.clip_img_pooled_embedder[1].weight, std=0.01)
        nn.init.zeros_(self.clip_img_pooled_embedder[1].bias)

    @staticmethod
    def _get_clip_from_kwargs(transformer_options: dict, kwargs: dict, key: str):
        if key in kwargs:
            return kwargs.get(key)
        if transformer_options is not None and key in transformer_options:
            return transformer_options.get(key)
        extra = transformer_options.get("extra_cond", None) if transformer_options else None
        if isinstance(extra, dict) and key in extra:
            return extra.get(key)
        return None

    def _forward(
        self,
        x: torch.Tensor,
        timesteps: torch.Tensor,
        context: torch.Tensor,
        num_tokens: int,
        attention_mask: Optional[torch.Tensor] = None,
        transformer_options: dict = {},
        **kwargs,
    ):
        t = timesteps
        cap_feats = context
        cap_mask = attention_mask
        bs, c, h, w = x.shape
        x = common_dit.pad_to_patch_size(x, (self.patch_size, self.patch_size))
        t_emb = self.t_embedder(t, dtype=x.dtype)
        adaln_input = t_emb
        clip_text_pooled = self._get_clip_from_kwargs(transformer_options, kwargs, "clip_text_pooled")
        clip_img_pooled = self._get_clip_from_kwargs(transformer_options, kwargs, "clip_img_pooled")
        if clip_text_pooled is not None:
            if clip_text_pooled.dim() > 2:
                clip_text_pooled = clip_text_pooled.view(clip_text_pooled.shape[0], -1)
            clip_text_pooled = clip_text_pooled.to(device=t_emb.device, dtype=t_emb.dtype)
            clip_emb = self.clip_text_pooled_proj(clip_text_pooled)
            adaln_input = self.time_text_embed(torch.cat([t_emb, clip_emb], dim=-1))
        if clip_img_pooled is not None:
            if clip_img_pooled.dim() > 2:
                clip_img_pooled = clip_img_pooled.view(clip_img_pooled.shape[0], -1)
            clip_img_pooled = clip_img_pooled.to(device=t_emb.device, dtype=t_emb.dtype)
            adaln_input = adaln_input + self.clip_img_pooled_embedder(clip_img_pooled)
        if isinstance(cap_feats, torch.Tensor):
            try:
                target_dtype = next(self.cap_embedder.parameters()).dtype
            except StopIteration:
                target_dtype = cap_feats.dtype
            cap_feats = cap_feats.to(device=t_emb.device, dtype=target_dtype)
        cap_feats = self.cap_embedder(cap_feats)
        patches = transformer_options.get("patches", {})
        x_is_tensor = True
        img, mask, img_size, cap_size, freqs_cis = self.patchify_and_embed(
            x, cap_feats, cap_mask, adaln_input, num_tokens, transformer_options=transformer_options
        )
        freqs_cis = freqs_cis.to(img.device)
        for i, layer in enumerate(self.layers):
            img = layer(img, mask, freqs_cis, adaln_input, transformer_options=transformer_options)
            if "double_block" in patches:
                for p in patches["double_block"]:
                    out = p(
                        {
                            "img": img[:, cap_size[0] :],
                            "txt": img[:, : cap_size[0]],
                            "pe": freqs_cis[:, cap_size[0] :],
                            "vec": adaln_input,
                            "x": x,
                            "block_index": i,
                            "transformer_options": transformer_options,
                        }
                    )
                    if isinstance(out, dict):
                        if "img" in out:
                            img[:, cap_size[0] :] = out["img"]
                        if "txt" in out:
                            img[:, : cap_size[0]] = out["txt"]

        img = self.final_layer(img, adaln_input)
        img = self.unpatchify(img, img_size, cap_size, return_tensor=x_is_tensor)
        img = img[:, :, :h, :w]
        return img


def NextDiT_3B_GQA_patch2_Adaln_Refiner_WHIT_CLIP(**kwargs):
    _pop_unexpected_kwargs(kwargs)
    kwargs.setdefault("patch_size", 2)
    kwargs.setdefault("in_channels", 16)
    kwargs.setdefault("dim", 2304)
    kwargs.setdefault("n_layers", 36)
    kwargs.setdefault("n_heads", 24)
    kwargs.setdefault("n_kv_heads", 8)
    kwargs.setdefault("axes_dims", [32, 32, 32])
    kwargs.setdefault("axes_lens", [1024, 512, 512])
    return NewBieNextDiT_CLIP(**kwargs)


def NewBieNextDiT(*, device=None, dtype=None, operations=None, **kwargs):
    _pop_unexpected_kwargs(kwargs)
    if operations is None:
        operations = _fallback_operations()
    if dtype is None:
        dev_str = str(device) if device is not None else ""
        if dev_str.startswith("cuda") and torch.cuda.is_available():
            if hasattr(torch.cuda, "is_bf16_supported") and torch.cuda.is_bf16_supported():
                dtype = torch.bfloat16
            else:
                dtype = torch.float16
        else:
            dtype = torch.float32
    model = NextDiT_3B_GQA_patch2_Adaln_Refiner_WHIT_CLIP(
        device=device, dtype=dtype, operations=operations, **kwargs
    )
    return model
'''

    path = os.path.join(REPO, "comfy/ldm/newbie/model.py")
    with open(path, "w") as f:
        f.write(model_content)
    print("Created comfy/ldm/newbie/model.py")


def patch_model_base():
    """Add NewBieImage class (with anti-pattern apply_model override) to model_base.py."""
    path = os.path.join(REPO, "comfy/model_base.py")
    with open(path, "r") as f:
        content = f.read()

    # Remove Lumina2 clip_text_pooled hack (part of the initial PR)
    lumina_hack = '''        clip_text_pooled = kwargs["pooled_output"]  # Newbie
        if clip_text_pooled is not None:
            out['clip_text_pooled'] = comfy.conds.CONDRegular(clip_text_pooled)

'''
    content = content.replace(lumina_hack, "")

    # Add NewBieImage class after Flux2 class (before GenmoMochi or next class)
    newbie_class = '''
class NewBieImage(BaseModel):
    def __init__(self, model_config, model_type=ModelType.FLOW, device=None):
        import comfy.ldm.newbie.model as nb
        super().__init__(model_config, model_type, device=device, unet_model=nb.NewBieNextDiT)

    def extra_conds(self, **kwargs):
        out = super().extra_conds(**kwargs)
        cross_attn = kwargs.get("cross_attn", None)
        if cross_attn is not None:
            out["c_crossattn"] = comfy.conds.CONDCrossAttn(cross_attn)
        attention_mask = kwargs.get("attention_mask", None)
        if attention_mask is not None:
            out["attention_mask"] = comfy.conds.CONDRegular(attention_mask)
        cap_feats = kwargs.get("cap_feats", None)
        if cap_feats is not None:
            out["cap_feats"] = comfy.conds.CONDRegular(cap_feats)
        cap_mask = kwargs.get("cap_mask", None)
        if cap_mask is not None:
            out["cap_mask"] = comfy.conds.CONDRegular(cap_mask)
        clip_text_pooled = kwargs.get("clip_text_pooled", None)
        if clip_text_pooled is not None:
            out["clip_text_pooled"] = comfy.conds.CONDRegular(clip_text_pooled)
        clip_img_pooled = kwargs.get("clip_img_pooled", None)
        if clip_img_pooled is not None:
            out["clip_img_pooled"] = comfy.conds.CONDRegular(clip_img_pooled)
        return out

    def extra_conds_shapes(self, **kwargs):
        out = super().extra_conds_shapes(**kwargs)
        cap_feats = kwargs.get("cap_feats", None)
        if cap_feats is not None:
            out["cap_feats"] = list(cap_feats.shape)
        clip_text_pooled = kwargs.get("clip_text_pooled", None)
        if clip_text_pooled is not None:
            out["clip_text_pooled"] = list(clip_text_pooled.shape)
        clip_img_pooled = kwargs.get("clip_img_pooled", None)
        if clip_img_pooled is not None:
            out["clip_img_pooled"] = list(clip_img_pooled.shape)
        return out

    def apply_model(
            self, x, t,
            c_concat=None, c_crossattn=None,
            control=None, transformer_options={}, **kwargs
    ):
        sigma = t
        try:
            model_device = next(self.diffusion_model.parameters()).device
        except StopIteration:
            model_device = x.device
        x_in = x.to(device=model_device)
        sigma_in = sigma.to(device=model_device)
        xc = self.model_sampling.calculate_input(sigma_in, x_in)
        if c_concat is not None:
            xc = torch.cat([xc] + [c_concat.to(device=model_device)], dim=1)
        dtype = self.get_dtype()
        if self.manual_cast_dtype is not None:
            dtype = self.manual_cast_dtype
        xc = xc.to(dtype=dtype)
        t_val = (1.0 - sigma_in).to(dtype=torch.float32)
        cap_feats = kwargs.get("cap_feats", kwargs.get("cross_attn", c_crossattn))
        cap_mask = kwargs.get("cap_mask", kwargs.get("attention_mask"))
        clip_text_pooled = kwargs.get("clip_text_pooled")
        clip_img_pooled = kwargs.get("clip_img_pooled")
        if cap_feats is not None:
            cap_feats = cap_feats.to(device=model_device, dtype=dtype)
        if cap_mask is None and cap_feats is not None:
            cap_mask = torch.ones(cap_feats.shape[:2], dtype=torch.bool, device=model_device)
        elif cap_mask is not None:
            cap_mask = cap_mask.to(device=model_device)
            if cap_mask.dtype != torch.bool:
                cap_mask = cap_mask != 0
        model_kwargs = {}
        if clip_text_pooled is not None:
            model_kwargs["clip_text_pooled"] = clip_text_pooled.to(device=model_device, dtype=dtype)
        if clip_img_pooled is not None:
            model_kwargs["clip_img_pooled"] = clip_img_pooled.to(device=model_device, dtype=dtype)
        model_output = self.diffusion_model(xc, t_val, cap_feats, cap_mask, **model_kwargs).float()
        model_output = -model_output
        denoised = self.model_sampling.calculate_denoised(sigma_in, model_output, x_in)
        if denoised.device != x.device:
            denoised = denoised.to(device=x.device)
        return denoised

'''

    # Insert NewBieImage after Flux2 class, before GenmoMochi
    insert_marker = "\nclass GenmoMochi(BaseModel):"
    if insert_marker in content:
        content = content.replace(insert_marker, newbie_class + "\nclass GenmoMochi(BaseModel):")
    else:
        # Fallback: append at end of file before last class
        content += newbie_class

    with open(path, "w") as f:
        f.write(content)
    print("Patched comfy/model_base.py")


def patch_supported_models():
    """Add NewBieImageModel to supported_models.py."""
    path = os.path.join(REPO, "comfy/supported_models.py")
    with open(path, "r") as f:
        content = f.read()

    newbie_model_class = '''
class NewBieImageModel(supported_models_base.BASE):
    unet_config = {
        "image_model": "NewBieImage",
        "model_type": "newbie_dit",
    }
    sampling_settings = {
        "multiplier": 1.0,
        "shift": 6.0,
    }
    memory_usage_factor = 1.5
    unet_extra_config = {}
    latent_format = latent_formats.Flux
    supported_inference_dtypes = [torch.bfloat16, torch.float16, torch.float32]
    vae_key_prefix = ["vae."]
    text_encoder_key_prefix = ["text_encoders."]

    def get_model(self, state_dict, prefix="", device=None):
        out = model_base.NewBieImage(self, device=device)
        return out

    def clip_target(self, state_dict={}):
        return None

'''

    # Insert before WAN21_T2V class
    insert_marker = "\nclass WAN21_T2V(supported_models_base.BASE):"
    if insert_marker in content:
        content = content.replace(insert_marker, newbie_model_class + "\nclass WAN21_T2V(supported_models_base.BASE):")

    # Update models list to include NewBieImageModel
    content = re.sub(
        r'(models\s*=\s*\[[^\]]*?ZImage,\s*Lumina2,)',
        r'\1 NewBieImageModel,',
        content,
        flags=re.DOTALL
    )

    with open(path, "w") as f:
        f.write(content)
    print("Patched comfy/supported_models.py")


def patch_model_detection():
    """Add NewBie model detection to model_detection.py."""
    path = os.path.join(REPO, "comfy/model_detection.py")
    with open(path, "r") as f:
        content = f.read()

    # Add newbie detection function before the main detect_unet_config function
    # Check if we need to add it
    if "newbie_dit" in content:
        print("model_detection.py already has NewBie detection, skipping")
        return

    # Add a detection helper for NewBie - find the Lumina2 detection section
    # and add NewBie after it
    newbie_detection = '''
def newbie_detect(unet_config):
    """Detect NewBie model type from unet_config."""
    if unet_config.get("image_model", "") == "NewBieImage":
        return True
    return False

'''

    # Insert near top after imports/initial functions
    # Find a good insertion point - after lumina-related detection if it exists
    insert_after = "def count_blocks(state_dict, prefix_string):"
    if insert_after in content:
        idx = content.find(insert_after)
        # Find end of that function
        next_def = content.find("\ndef ", idx + 1)
        if next_def > 0:
            content = content[:next_def] + "\n" + newbie_detection + content[next_def:]

    with open(path, "w") as f:
        f.write(content)
    print("Patched comfy/model_detection.py")


def patch_model_management_cpu():
    """Patch model_management.py so it works with CPU-only PyTorch.

    ComfyUI's model_management.py calls torch.cuda.current_device() at module import
    time, which fails with CPU-only torch builds. Add a CPU fallback so verification
    tests can import comfy modules without a GPU.
    """
    path = os.path.join(REPO, "comfy/model_management.py")
    with open(path, "r") as f:
        content = f.read()

    # Replace the get_torch_device() function to fall back to CPU when CUDA unavailable
    old_get_device = '''def get_torch_device():
    global directml_enabled
    if directml_enabled:
        return torch_directml.device(torch_directml.default_device())
    else:
        if vram_state == VRAMState.MPS:
            return torch.device("mps")
        if cpu_state == CPUState.CPU:
            return torch.device("cpu")
        else:
            return torch.device(torch.cuda.current_device())'''

    new_get_device = '''def get_torch_device():
    global directml_enabled
    if directml_enabled:
        return torch_directml.device(torch_directml.default_device())
    else:
        if vram_state == VRAMState.MPS:
            return torch.device("mps")
        if cpu_state == CPUState.CPU:
            return torch.device("cpu")
        else:
            try:
                return torch.device(torch.cuda.current_device())
            except (AssertionError, RuntimeError):
                return torch.device("cpu")'''

    if old_get_device in content:
        content = content.replace(old_get_device, new_get_device)
    else:
        # Fallback: patch the bare current_device call
        content = content.replace(
            "return torch.device(torch.cuda.current_device())",
            "try:\n                return torch.device(torch.cuda.current_device())\n            except (AssertionError, RuntimeError):\n                return torch.device(\"cpu\")"
        )

    # Also wrap the vram detection at module level
    old_vram_line = "total_vram = get_total_memory(get_torch_device()) / (1024 * 1024)"
    new_vram_line = (
        "try:\n"
        "    total_vram = get_total_memory(get_torch_device()) / (1024 * 1024)\n"
        "except (AssertionError, RuntimeError):\n"
        "    total_vram = 0"
    )
    content = content.replace(old_vram_line, new_vram_line)

    with open(path, "w") as f:
        f.write(content)
    print("Patched comfy/model_management.py for CPU-only operation")


if __name__ == "__main__":
    # NOTE: only synthesize buggy state for files the canonical patch's
    # block-replacement hunks expect to ALREADY contain buggy classes.
    # That is model_base.py + supported_models.py (+ model_detection.py for
    # wiring) + model_management.py (CPU fallback unrelated to the task).
    #
    # We intentionally DO NOT pre-synth lumina/model.py or comfy/ldm/newbie/*.
    # The canonical patch's lumina hunk uses pre-synth anchors (line ~380
    # `clip_text_dim=None,`), and its newbie/model.py hunk is a NEW-FILE
    # hunk. Pre-synth'ing either would conflict at oracle-replay time
    # with "does not match index" / "file already exists" — see
    # analysis/ORACLE_AUDIT.md PATCH_ERR for this task.
    patch_model_management_cpu()
    patch_model_base()
    patch_supported_models()
    patch_model_detection()
    print("Synthesis complete (buggy state limited to model_base + supported_models + model_detection).")
