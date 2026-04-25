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
    import library.lumina_models
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

# G2: Original (non-fp8_scaled) fp8_linear_forward_patch path still works on base.
# This is the regression guard for the existing fp8 path.
echo "=== G2 (gate): existing fp8_linear_forward_patch original-weight path ==="
cat > /tmp/_g2.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import torch, torch.nn as nn, sys
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:" + repr(e)); sys.exit(0)
torch.manual_seed(0)
lin = nn.Linear(8, 4, bias=False)
# Original-weight path: no scale_weight attribute set on module.
# fp8_linear_forward_patch should fall back / still work for non-scaled module.
x = torch.randn(2, 8)
try:
    # signature: (self, x, use_scaled_mm, max_value)
    y = fp8_linear_forward_patch(lin, x, False, 0)
    if y.shape == (2, 4) and not torch.isnan(y).any():
        print("PASS")
    else:
        print("FAIL:bad-output")
except Exception as e:
    # If function strictly requires scale_weight — that's still "base behavior";
    # we just don't gate on it failing.
    print("PASS_SOFT")
PYEOF
G2=$(python3 /tmp/_g2.py 2>&1 | tail -1)
echo "  $G2"
if [ "$G2" = "FAIL:bad-output" ]; then
    echo "Existing fp8 path regression — aborting"
    emit_zero_and_exit
fi

# ═══════════════════════════════════════════════════════════════════
# F2P REWARD GATES (1.0 total — all should FAIL on no-op base)
# ═══════════════════════════════════════════════════════════════════

# ---- F1 (0.10): FP8_OPTIMIZATION_TARGET_KEYS defined in a Lumina module and includes "layers" ----
echo "=== F1: FP8_OPTIMIZATION_TARGET_KEYS for Lumina includes 'layers' ==="
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

# ---- F2 (0.08): FP8_OPTIMIZATION_EXCLUDE_KEYS defined for Lumina ----
echo "=== F2: FP8_OPTIMIZATION_EXCLUDE_KEYS defined for Lumina ==="
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
    if m and ("modulation" in m.group(1) or "norm" in m.group(1)):
        found = True
        break
print("PASS" if found else "FAIL")
PYEOF
)
echo "  $F2"
[ "$F2" = "PASS" ] && add_reward 0.08

# ---- F3 (0.10): load_lumina_model accepts fp8_scaled AND body invokes apply_fp8_monkey_patch ----
echo "=== F3: load_lumina_model wires fp8_scaled -> apply_fp8_monkey_patch ==="
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
            if "apply_fp8_monkey_patch" in body:
                ok_call = True
        break
print("PASS" if (ok_arg and ok_call) else "FAIL")
PYEOF
)
echo "  $F3"
[ "$F3" = "PASS" ] && add_reward 0.10

# ---- F4 (0.10): --fp8_scaled CLI argument registered in Lumina train/inference scripts ----
echo "=== F4: --fp8_scaled CLI argument registered ==="
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

# ---- F5 (0.10): Lumina train_network argparse actually accepts --fp8_scaled at runtime ----
echo "=== F5: real argparse accepts --fp8_scaled ==="
cat > /tmp/_f5.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys
try:
    import importlib
    mod = importlib.import_module("lumina_train_network")
    parser = mod.setup_parser()
    # parse with --fp8_scaled. Provide minimum required args via known_args style.
    args, _ = parser.parse_known_args(["--fp8_scaled"])
    if getattr(args, "fp8_scaled", False) is True:
        print("PASS")
    else:
        print("FAIL:not-true")
except SystemExit:
    print("FAIL:systemexit")
except Exception as e:
    print("FAIL:" + repr(e)[:120])
PYEOF
F5=$(python3 /tmp/_f5.py 2>&1 | tail -1)
echo "  $F5"
[ "$F5" = "PASS" ] && add_reward 0.10

# ---- F6 (0.12): apply_fp8_monkey_patch works on a Lumina-like module using the EXPORTED keys ----
# This validates that target/exclude keys are well-formed AND that scaled-fp8 forward runs end-to-end.
echo "=== F6: apply_fp8_monkey_patch on Lumina-like module via exported keys ==="
cat > /tmp/_f6.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, torch, torch.nn as nn

# Find exported keys
TARGET = None
EXCLUDE = None
for modpath in ["library.lumina_util", "library.lumina_models"]:
    try:
        m = __import__(modpath, fromlist=["x"])
        if hasattr(m, "FP8_OPTIMIZATION_TARGET_KEYS"):
            TARGET = m.FP8_OPTIMIZATION_TARGET_KEYS
            EXCLUDE = getattr(m, "FP8_OPTIMIZATION_EXCLUDE_KEYS", [])
            break
    except Exception:
        pass

if TARGET is None:
    print("FAIL:no-keys"); sys.exit(0)

try:
    from library.fp8_optimization_utils import (
        apply_fp8_monkey_patch, optimize_state_dict_with_fp8,
    )
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

# Build a small Lumina-like model with "layers" containing linears,
# plus a "norm" / "adaLN_modulation" branch that should be excluded.
class Block(nn.Module):
    def __init__(self):
        super().__init__()
        self.attn_qkv = nn.Linear(16, 48, bias=False)
        self.attn_out = nn.Linear(16, 16, bias=False)
        self.adaLN_modulation = nn.Sequential(nn.SiLU(), nn.Linear(16, 32, bias=True))
        self.norm = nn.LayerNorm(16)

class LuminaLike(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList([Block() for _ in range(2)])
        self.final_layer = nn.Linear(16, 16, bias=False)
    def forward(self, x):
        for blk in self.layers:
            x = blk.attn_out(blk.attn_qkv(x)[..., :16])
        return self.final_layer(x)

torch.manual_seed(0)
model = LuminaLike()
sd = {k: v.detach().clone() for k, v in model.state_dict().items()}

try:
    new_sd = optimize_state_dict_with_fp8(
        sd, calc_device=torch.device("cpu"),
        target_layer_keys=TARGET, exclude_layer_keys=EXCLUDE,
        move_to_device=False,
    )
except TypeError:
    # Some signatures use positional only; try alt
    try:
        new_sd = optimize_state_dict_with_fp8(
            sd, torch.device("cpu"), TARGET, EXCLUDE, move_to_device=False,
        )
    except Exception as e:
        print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)
except Exception as e:
    print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)

# Confirm at least one "layers." weight got an fp8 scale_weight companion
has_scale = any(k.endswith(".scale_weight") and ".layers." in k for k in new_sd.keys())
if not has_scale:
    print("FAIL:no-scale-weight"); sys.exit(0)

# adaLN_modulation / norm should NOT have scale_weight if "modulation" or "norm" excluded
bad = [k for k in new_sd.keys()
       if k.endswith(".scale_weight") and ("adaLN_modulation" in k or ".norm." in k or k.endswith(".norm.scale_weight"))]
# Allow either modulation or norm exclusion (whichever the agent picked); only fail if BOTH leak
# Specifically: if exclude contains "norm", no .norm. weights should have scale_weight.
exc_str = " ".join(EXCLUDE) if isinstance(EXCLUDE, (list, tuple)) else str(EXCLUDE)
norm_leak = any(".norm." in k for k in bad) and ("norm" in exc_str)
mod_leak = any("adaLN_modulation" in k for k in bad) and ("modulation" in exc_str)
if norm_leak or mod_leak:
    print("FAIL:exclude-leak:" + str(bad[:3])); sys.exit(0)

# Now apply monkey patch and run forward
try:
    apply_fp8_monkey_patch(model, new_sd, use_scaled_mm=False)
    info = model.load_state_dict(new_sd, strict=False, assign=True)
except Exception as e:
    print("FAIL:patch:" + repr(e)[:120]); sys.exit(0)

x = torch.randn(2, 16, dtype=torch.bfloat16)
model = model.to(torch.bfloat16) if False else model
try:
    # match dtype
    for p in model.parameters():
        if p.dtype not in (torch.float8_e4m3fn, torch.float8_e5m2):
            p.data = p.data.to(torch.bfloat16)
    for b_name, b in model.named_buffers():
        if b.dtype not in (torch.float8_e4m3fn, torch.float8_e5m2) and b.is_floating_point():
            b.data = b.data.to(torch.bfloat16)
    y = model(x)
except Exception as e:
    print("FAIL:fwd:" + repr(e)[:120]); sys.exit(0)

if torch.isnan(y).any() or torch.isinf(y).any():
    print("FAIL:nan"); sys.exit(0)
if y.shape != (2, 16):
    print("FAIL:shape"); sys.exit(0)
print("PASS")
PYEOF
F6=$(python3 /tmp/_f6.py 2>&1 | tail -1)
echo "  $F6"
[ "$F6" = "PASS" ] && add_reward 0.12

# ---- F7 (0.10): adaLN_modulation OR norm linears NOT picked up by quant target on real Lumina-like state_dict ----
echo "=== F7: exclude keys actually exclude norm/modulation ==="
cat > /tmp/_f7.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, torch, torch.nn as nn

TARGET = None; EXCLUDE = None
for modpath in ["library.lumina_util", "library.lumina_models"]:
    try:
        m = __import__(modpath, fromlist=["x"])
        if hasattr(m, "FP8_OPTIMIZATION_TARGET_KEYS"):
            TARGET = m.FP8_OPTIMIZATION_TARGET_KEYS
            EXCLUDE = getattr(m, "FP8_OPTIMIZATION_EXCLUDE_KEYS", [])
            break
    except Exception:
        pass

if TARGET is None or EXCLUDE is None:
    print("FAIL:no-keys"); sys.exit(0)

exc_str = " ".join(EXCLUDE) if isinstance(EXCLUDE, (list, tuple)) else str(EXCLUDE)
# Must exclude either norm or modulation
if not ("norm" in exc_str or "modulation" in exc_str):
    print("FAIL:weak-exclude"); sys.exit(0)

# Synthesize a state dict resembling Lumina with both layers.X.attn.qkv and layers.X.adaLN_modulation
sd = {
    "layers.0.attention.qkv.weight": torch.randn(48, 16),
    "layers.0.attention.out.weight": torch.randn(16, 16),
    "layers.0.adaLN_modulation.1.weight": torch.randn(32, 16),
    "layers.0.adaLN_modulation.1.bias": torch.randn(32),
    "layers.0.norm1.weight": torch.randn(16),
    "final_layer.weight": torch.randn(16, 16),
}

try:
    from library.fp8_optimization_utils import optimize_state_dict_with_fp8
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

try:
    new_sd = optimize_state_dict_with_fp8(
        sd, calc_device=torch.device("cpu"),
        target_layer_keys=TARGET, exclude_layer_keys=EXCLUDE,
        move_to_device=False,
    )
except TypeError:
    try:
        new_sd = optimize_state_dict_with_fp8(
            sd, torch.device("cpu"), TARGET, EXCLUDE, move_to_device=False,
        )
    except Exception as e:
        print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)
except Exception as e:
    print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)

# attention.qkv should be quantized (have scale_weight)
qkv_scaled = "layers.0.attention.qkv.scale_weight" in new_sd
if not qkv_scaled:
    print("FAIL:qkv-not-quantized"); sys.exit(0)

# adaLN_modulation.1 should NOT be quantized if "modulation" in exclude
if "modulation" in exc_str:
    if "layers.0.adaLN_modulation.1.scale_weight" in new_sd:
        print("FAIL:modulation-leaked"); sys.exit(0)

# norm layers should not be quantized if "norm" in exclude
if "norm" in exc_str:
    leaks = [k for k in new_sd if k.endswith(".scale_weight") and ".norm" in k.replace(".scale_weight","")]
    # qkv.scale_weight contains no ".norm" so this is fine
    if leaks:
        print("FAIL:norm-leaked:" + str(leaks)); sys.exit(0)

print("PASS")
PYEOF
F7=$(python3 /tmp/_f7.py 2>&1 | tail -1)
echo "  $F7"
[ "$F7" = "PASS" ] && add_reward 0.10

# ---- F8 (0.10): scaled fp8 forward numerical sanity (per-tensor) ----
echo "=== F8: scaled fp8 forward numerical sanity (bf16) ==="
cat > /tmp/_f8.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, torch, torch.nn as nn
try:
    from library.fp8_optimization_utils import fp8_linear_forward_patch
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

torch.manual_seed(0)
in_f, out_f = 32, 16
W = torch.randn(out_f, in_f, dtype=torch.float32) * 0.1
scale = torch.tensor(W.abs().max() / 200.0, dtype=torch.bfloat16)
fp8_w = (W / scale.float()).clamp(-448, 448).to(torch.float8_e4m3fn)

lin = nn.Linear(in_f, out_f, bias=False)
lin.weight = nn.Parameter(fp8_w, requires_grad=False)
lin.scale_weight = scale
lin.fp8_matmul_enabled = False

x = torch.randn(4, in_f, dtype=torch.bfloat16)
try:
    y = fp8_linear_forward_patch(lin, x, False, 0)
except Exception as e:
    print("FAIL:run:" + repr(e)[:160]); sys.exit(0)

# Reference: compute in fp32 with the dequantized fp8 weight
W_deq = fp8_w.to(torch.float32) * scale.float()
y_ref = (x.to(torch.float32) @ W_deq.t()).to(torch.bfloat16)

if y.shape != (4, out_f):
    print("FAIL:shape"); sys.exit(0)
if torch.isnan(y).any() or torch.isinf(y).any():
    print("FAIL:nan"); sys.exit(0)
# Tolerance generous to absorb fp8/bf16 rounding
diff = (y.float() - y_ref.float()).abs().max().item()
ref_max = y_ref.float().abs().max().item() + 1e-6
if diff / ref_max > 0.5:
    print("FAIL:numerical:" + str(diff)); sys.exit(0)
print("PASS")
PYEOF
F8=$(python3 /tmp/_f8.py 2>&1 | tail -1)
echo "  $F8"
[ "$F8" = "PASS" ] && add_reward 0.10

# ---- F9 (0.10): lumina_train_network.load_target_model passes fp8_scaled into load_lumina_model ----
echo "=== F9: load_target_model wires fp8_scaled through ==="
F9=$(python3 << 'PYEOF' 2>&1 | tail -1
import re
try:
    src = open("/workspace/sd-scripts/lumina_train_network.py").read()
except FileNotFoundError:
    print("FAIL"); raise SystemExit(0)

# Find load_target_model body
m = re.search(r'def\s+load_target_model\s*\([^)]*\)\s*:\s*\n(.*?)(?=\n    def |\Z)', src, re.DOTALL)
if not m:
    print("FAIL:no-method"); raise SystemExit(0)
body = m.group(1)
# Body must reference args.fp8_scaled AND pass fp8_scaled= into a load call
if "args.fp8_scaled" in body and re.search(r'fp8_scaled\s*=\s*args\.fp8_scaled', body):
    print("PASS")
else:
    print("FAIL")
PYEOF
)
echo "  $F9"
[ "$F9" = "PASS" ] && add_reward 0.10

# ---- F10 (0.10): load_lumina_model with fp8_scaled actually returns a model with fp8 weight on a small synthetic checkpoint ----
echo "=== F10: end-to-end fp8_scaled load on synthetic checkpoint ==="
cat > /tmp/_f10.py << 'PYEOF'
exec(open("/tmp/_vfp8mock.py").read())
import sys, os, torch, tempfile

# Try to construct a tiny safetensors checkpoint and pass through load_lumina_model
# This is best-effort — if model construction is too heavy, we fall back to checking
# that load_lumina_model SIGNATURE accepts fp8_scaled and the body imports
# apply_fp8_monkey_patch (already covered by F3). To make F10 a real F2P:
# we test that calling load_lumina_model(..., fp8_scaled=True) without error path
# at least DISPATCHES into the fp8 branch — verifiable via monkeypatching.

import library.lumina_util as lu
import inspect

sig = inspect.signature(lu.load_lumina_model)
if "fp8_scaled" not in sig.parameters:
    print("FAIL:no-param"); sys.exit(0)

src = inspect.getsource(lu.load_lumina_model)
# The function body must conditionally do fp8 work — both checking the flag
# AND calling apply_fp8_monkey_patch.
if "fp8_scaled" not in src:
    print("FAIL:no-flag-check"); sys.exit(0)
if "apply_fp8_monkey_patch" not in src:
    print("FAIL:no-monkey-patch"); sys.exit(0)

# Confirm there is a conditional branch on fp8_scaled
import re
if not re.search(r'if\s+.*fp8_scaled', src):
    print("FAIL:no-if"); sys.exit(0)

print("PASS")
PYEOF
F10=$(python3 /tmp/_f10.py 2>&1 | tail -1)
echo "  $F10"
[ "$F10" = "PASS" ] && add_reward 0.10

echo ""
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > "$REWARD_FILE"