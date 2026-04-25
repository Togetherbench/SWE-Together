#!/bin/bash
set +e

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

emit_zero_and_exit() {
    echo "0.0" > "$REWARD_FILE"
    exit 0
}

REPO=/workspace/sd-scripts
if [ ! -d "$REPO" ]; then
    echo "REPO MISSING"
    emit_zero_and_exit
fi

# Mock-init for behavioral imports
cat > /tmp/_vfp8mock.py << 'MOCKINIT'
import sys
from unittest.mock import MagicMock

_MODS = [
    "cv2", "PIL", "PIL.Image", "PIL.ImageFilter", "PIL.ImageOps",
    "einops", "einops.layers", "einops.layers.torch",
    "diffusers", "diffusers.schedulers",
    "diffusers.schedulers.scheduling_euler_ancestral_discrete",
    "diffusers.schedulers.scheduling_euler_discrete",
    "diffusers.schedulers.scheduling_flow_match_euler_discrete",
    "diffusers.configuration_utils", "diffusers.models",
    "diffusers.models.attention_processor", "diffusers.loaders",
    "diffusers.utils",
    "flash_attn", "flash_attn.flash_attn_interface", "flash_attn.bert_padding",
    "sageattention",
    "apex", "apex.normalization", "apex.optimizers",
    "xformers", "xformers.ops", "triton",
    "bitsandbytes", "bitsandbytes.nn", "quanto",
    "lycoris", "lycoris.config", "lycoris.modules", "peft",
    "gradio", "wandb", "tensorboard", "tensorboardX",
    "voluptuous", "open_clip", "open_clip.tokenizer",
]
for _m in _MODS:
    if _m not in sys.modules:
        _mo = MagicMock()
        _mo.__spec__ = MagicMock()
        _mo.__all__ = []
        sys.modules[_m] = _mo

sys.path.insert(0, "/workspace/sd-scripts")
MOCKINIT

# ═══════════════════════════════════════════════════════════════════
# P2P GATES (gating only — no reward weight, fail-fast)
# ═══════════════════════════════════════════════════════════════════

# G1: Library imports must succeed (no syntax errors / circular imports)
echo "=== G1 (gate): library imports work ==="
G1=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
try:
    import library.fp8_optimization_utils as fou
    import library.lumina_util as lu
    import library.lumina_models as lm
    print("PASS")
except Exception as e:
    print("FAIL:" + repr(e))
PYEOF
)
echo "  $G1"
if [ "$G1" != "PASS" ]; then
    echo "Library import regression — aborting with 0"
    emit_zero_and_exit
fi

# ═══════════════════════════════════════════════════════════════════
# F2P REWARD GATES (1.0 total)
# Each gate probes a different slice of the fix.
# ═══════════════════════════════════════════════════════════════════

# ---- F1 (0.10): FP8_OPTIMIZATION_TARGET_KEYS for Lumina includes "layers" ----
echo "=== F1 (0.10): FP8_OPTIMIZATION_TARGET_KEYS includes 'layers' ==="
F1=$(python3 << 'PYEOF' 2>&1 | tail -1
import re
found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and re.search(r'["\']layers', m.group(1)):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  $F1"
[ "$F1" = "PASS" ] && add_reward 0.10

# ---- F2 (0.08): FP8_OPTIMIZATION_EXCLUDE_KEYS defined for Lumina (excludes norm) ----
echo "=== F2 (0.08): FP8_OPTIMIZATION_EXCLUDE_KEYS defined ==="
F2=$(python3 << 'PYEOF' 2>&1 | tail -1
import re
found = False
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m and re.search(r'norm', m.group(1)):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  $F2"
[ "$F2" = "PASS" ] && add_reward 0.08

# ---- F3 (0.12): load_lumina_model accepts fp8_scaled AND body invokes apply_fp8_monkey_patch ----
echo "=== F3 (0.12): load_lumina_model wires fp8_scaled -> apply_fp8_monkey_patch ==="
F3=$(python3 << 'PYEOF' 2>&1 | tail -1
import ast
try:
    src = open("/workspace/sd-scripts/library/lumina_util.py").read()
    tree = ast.parse(src)
except Exception:
    print("FAIL"); raise SystemExit(0)
ok_arg = False
ok_call = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_lumina_model":
        args = [a.arg for a in node.args.args + node.args.kwonlyargs]
        if "fp8_scaled" in args:
            ok_arg = True
        end = getattr(node, "end_lineno", None)
        if end:
            body = "\n".join(src.split("\n")[node.lineno - 1: end])
            if "apply_fp8_monkey_patch" in body and ("optimize_state_dict_with_fp8" in body or "load_safetensors_with_lora_and_fp8" in body or "load_safetensors_with_fp8_optimization" in body):
                ok_call = True
        break
print("PASS" if (ok_arg and ok_call) else "FAIL")
PYEOF
)
echo "  $F3"
[ "$F3" = "PASS" ] && add_reward 0.12

# ---- F4 (0.10): --fp8_scaled CLI argument registered in Lumina train scripts ----
echo "=== F4 (0.10): --fp8_scaled CLI argument registered ==="
F4=$(python3 << 'PYEOF' 2>&1 | tail -1
import re
candidates = [
    "/workspace/sd-scripts/library/lumina_train_util.py",
    "/workspace/sd-scripts/lumina_train_network.py",
    "/workspace/sd-scripts/lumina_train.py",
    "/workspace/sd-scripts/lumina_minimal_inference.py",
]
found = False
for p in candidates:
    try:
        src = open(p).read()
    except FileNotFoundError:
        continue
    if re.search(r'add_argument\(\s*["\']--fp8_scaled["\']', src):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  $F4"
[ "$F4" = "PASS" ] && add_reward 0.10

# ---- F5 (0.10): lumina_train_network.py wires fp8_scaled into load_target_model ----
echo "=== F5 (0.10): lumina_train_network.load_target_model uses fp8_scaled ==="
F5=$(python3 << 'PYEOF' 2>&1 | tail -1
import ast, re
path = "/workspace/sd-scripts/lumina_train_network.py"
try:
    src = open(path).read()
except FileNotFoundError:
    print("FAIL"); raise SystemExit(0)
try:
    tree = ast.parse(src)
except Exception:
    print("FAIL"); raise SystemExit(0)
ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_target_model":
        end = getattr(node, "end_lineno", None)
        if end:
            body = "\n".join(src.split("\n")[node.lineno - 1: end])
            if "fp8_scaled" in body and "load_lumina_model" in body:
                ok = True
        break
print("PASS" if ok else "FAIL")
PYEOF
)
echo "  $F5"
[ "$F5" = "PASS" ] && add_reward 0.10

# ---- F6 (0.20): BEHAVIORAL — optimize_state_dict_with_fp8 + apply_fp8_monkey_patch + forward
# numerically reproduce a base linear forward to within tolerance on a synthetic Lumina-like state dict ----
echo "=== F6 (0.20): behavioral fp8 quantize+forward roundtrip ==="
cat > /tmp/_f6.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, torch, torch.nn as nn
torch.manual_seed(0)
try:
    from library.fp8_optimization_utils import optimize_state_dict_with_fp8, apply_fp8_monkey_patch
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

# Build a tiny Lumina-like model: a couple "layers.N.linear" and a "norm" we don't want quantized.
class Block(nn.Module):
    def __init__(self):
        super().__init__()
        self.attn_proj = nn.Linear(32, 32, bias=False)
        self.ffn = nn.Linear(32, 32, bias=False)
        self.norm = nn.LayerNorm(32)
    def forward(self, x):
        return self.ffn(self.attn_proj(self.norm(x)))

class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList([Block() for _ in range(2)])
        self.head = nn.Linear(32, 32, bias=False)  # not in "layers." prefix
    def forward(self, x):
        for b in self.layers:
            x = b(x)
        return self.head(x)

m = Tiny().eval()
x = torch.randn(2, 32)
with torch.no_grad():
    y_ref = m(x)

sd = {k: v.detach().clone() for k, v in m.state_dict().items()}

target_keys = ["layers"]
exclude_keys = ["norm"]

try:
    new_sd = optimize_state_dict_with_fp8(
        sd, calc_device=torch.device("cpu"),
        target_layer_keys=target_keys,
        exclude_layer_keys=exclude_keys,
    )
except TypeError:
    # Older signature
    try:
        new_sd = optimize_state_dict_with_fp8(sd, torch.device("cpu"), target_keys, exclude_keys)
    except Exception as e:
        print("FAIL:optimize:" + repr(e)); sys.exit(0)
except Exception as e:
    print("FAIL:optimize:" + repr(e)); sys.exit(0)

# Confirm at least one scale_weight buffer was added for layers.* but not for head/norm.
has_scale_layers = any(k.endswith(".scale_weight") and k.startswith("layers.") for k in new_sd.keys())
has_scale_head = any(k.startswith("head.") and k.endswith(".scale_weight") for k in new_sd.keys())
has_scale_norm = any(".norm." in k and k.endswith(".scale_weight") for k in new_sd.keys())
if not has_scale_layers:
    print("FAIL:no-scale-on-layers"); sys.exit(0)
if has_scale_head:
    print("FAIL:scale-on-non-target"); sys.exit(0)
if has_scale_norm:
    print("FAIL:scale-on-excluded-norm"); sys.exit(0)

# Apply monkey patch and load
m2 = Tiny().eval()
try:
    apply_fp8_monkey_patch(m2, new_sd, use_scaled_mm=False)
except Exception as e:
    print("FAIL:patch:" + repr(e)); sys.exit(0)

info = m2.load_state_dict(new_sd, strict=False, assign=True)
with torch.no_grad():
    try:
        y2 = m2(x)
    except Exception as e:
        print("FAIL:forward:" + repr(e)); sys.exit(0)

if torch.isnan(y2).any() or torch.isinf(y2).any():
    print("FAIL:nan-or-inf"); sys.exit(0)

# fp8 quantization is lossy but should be reasonably close
diff = (y2 - y_ref).abs().mean().item()
ref_mag = y_ref.abs().mean().item() + 1e-6
rel = diff / ref_mag
# allow generous tolerance for fp8 e4m3 block-quant round-trip
if rel < 0.30:
    print("PASS")
else:
    print(f"FAIL:rel={rel:.4f}")
PYEOF
F6=$(timeout 60 python3 /tmp/_f6.py 2>&1 | tail -1)
echo "  $F6"
[ "$F6" = "PASS" ] && add_reward 0.20

# ---- F7 (0.15): BEHAVIORAL — fp8_linear_forward_patch with realistic scale_weight on a patched Linear
# matches a non-fp8 reference within tolerance. This catches the "scale_weight stays at ones / dequant
# missing fp32 hop on CUDA" class of bugs even on CPU by ensuring forward is mathematically correct. ----
echo "=== F7 (0.15): fp8_linear_forward_patch numerical correctness ==="
cat > /tmp/_f7.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, torch, torch.nn as nn
torch.manual_seed(1)
try:
    from library.fp8_optimization_utils import (
        optimize_state_dict_with_fp8, apply_fp8_monkey_patch
    )
except Exception as e:
    print("FAIL:import:" + repr(e)); sys.exit(0)

class Tiny(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList([nn.Linear(64, 64, bias=False) for _ in range(2)])
    def forward(self, x):
        for l in self.layers:
            x = l(x)
        return x

m = Tiny().eval()
x = torch.randn(4, 64)
with torch.no_grad():
    y_ref = m(x)

sd = {k: v.detach().clone() for k, v in m.state_dict().items()}
try:
    new_sd = optimize_state_dict_with_fp8(
        sd, calc_device=torch.device("cpu"),
        target_layer_keys=["layers"],
        exclude_layer_keys=["norm"],
    )
except TypeError:
    new_sd = optimize_state_dict_with_fp8(sd, torch.device("cpu"), ["layers"], ["norm"])
except Exception as e:
    print("FAIL:optimize:" + repr(e)); sys.exit(0)

# Verify scale_weight values are NOT all ones (a common bug: scale buffer initialized to 1
# and never overwritten, causing 448x dequant magnitude error).
all_ones = True
for k, v in new_sd.items():
    if k.endswith(".scale_weight"):
        if not torch.allclose(v.float(), torch.ones_like(v.float())):
            all_ones = False
            break
if all_ones:
    print("FAIL:scale_weight-all-ones"); sys.exit(0)

m2 = Tiny().eval()
try:
    apply_fp8_monkey_patch(m2, new_sd, use_scaled_mm=False)
except Exception as e:
    print("FAIL:patch:" + repr(e)); sys.exit(0)
m2.load_state_dict(new_sd, strict=False, assign=True)

with torch.no_grad():
    try:
        y2 = m2(x)
    except Exception as e:
        print("FAIL:forward:" + repr(e)); sys.exit(0)

if torch.isnan(y2).any() or torch.isinf(y2).any():
    print("FAIL:nan"); sys.exit(0)

diff = (y2 - y_ref).abs().mean().item()
ref_mag = y_ref.abs().mean().item() + 1e-6
rel = diff / ref_mag
# Tighter tolerance here since it's just linear stack
if rel < 0.20:
    print("PASS")
else:
    print(f"FAIL:rel={rel:.4f}")
PYEOF
F7=$(timeout 60 python3 /tmp/_f7.py 2>&1 | tail -1)
echo "  $F7"
[ "$F7" = "PASS" ] && add_reward 0.15

# ---- F8 (0.08): completeness — at least 2 of {lumina_util.py, lumina_train_network.py, lumina_train.py, lumina_minimal_inference.py}
# changed to wire fp8_scaled. Detect via presence of "fp8_scaled" token in those files. ----
echo "=== F8 (0.08): completeness across Lumina entry points ==="
F8=$(python3 << 'PYEOF' 2>&1 | tail -1
files = [
    "/workspace/sd-scripts/library/lumina_util.py",
    "/workspace/sd-scripts/lumina_train_network.py",
    "/workspace/sd-scripts/lumina_train.py",
    "/workspace/sd-scripts/lumina_minimal_inference.py",
]
n = 0
for p in files:
    try:
        s = open(p).read()
    except FileNotFoundError:
        continue
    if "fp8_scaled" in s:
        n += 1
print("PASS" if n >= 2 else f"FAIL:{n}")
PYEOF
)
echo "  $F8"
[ "$F8" = "PASS" ] && add_reward 0.08

# ---- F9 (0.07): fp8_scaled path actually triggers quantization machinery (not just arg passthrough).
# Source check that the fp8_scaled branch in load_lumina_model references the Lumina TARGET/EXCLUDE keys. ----
echo "=== F9 (0.07): load_lumina_model fp8_scaled branch references Lumina target keys ==="
F9=$(python3 << 'PYEOF' 2>&1 | tail -1
import ast
try:
    src = open("/workspace/sd-scripts/library/lumina_util.py").read()
    tree = ast.parse(src)
except Exception:
    print("FAIL"); raise SystemExit(0)
ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_lumina_model":
        end = getattr(node, "end_lineno", None)
        if end:
            body = "\n".join(src.split("\n")[node.lineno - 1: end])
            if "FP8_OPTIMIZATION_TARGET_KEYS" in body and "FP8_OPTIMIZATION_EXCLUDE_KEYS" in body:
                ok = True
        break
print("PASS" if ok else "FAIL")
PYEOF
)
echo "  $F9"
[ "$F9" = "PASS" ] && add_reward 0.07

echo "=========================================="
echo "FINAL REWARD: $REWARD"
echo "=========================================="

echo "$REWARD" > /logs/verifier/reward.txt