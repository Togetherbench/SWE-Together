#!/bin/bash
set +e

# Verifier for comfyui-newbie-lumina-refactor
# Goal: discriminate between no-op, shallow, partial, and complete refactors of
# the NewBie diffusion model into the Lumina codebase, reusing ComfyUI ops.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

REPO=/workspace/ComfyUI
source /workspace/venv/bin/activate 2>/dev/null || true
export PYTHONPATH="$REPO:$PYTHONPATH"
export COMFYUI_USE_CPU=1
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

write_reward() {
    awk -v r="$REWARD" 'BEGIN{ if(r>1) r=1; if(r<0) r=0; printf "%.4f", r }' > "$REWARD_FILE"
    echo "FINAL_REWARD=$(cat $REWARD_FILE)"
}

add() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1)r=1; printf "%.4f", r}')
}

fail_zero() {
    echo "P2P GATE FAILED: $1"
    REWARD=0.0
    write_reward
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

echo "=== ComfyUI NewBie refactoring verification ==="
cd "$REPO" 2>/dev/null || fail_zero "repo not found"

# ------------------------------------------------------------------
# P2P GATE 1: critical comfy modules import cleanly.
# ------------------------------------------------------------------
echo "--- P2P-1: comfy.{sd,model_base,model_detection,ldm.lumina.model} import ---"
python3 - > /tmp/p2p_import.txt 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception:
    pass
try:
    import comfy.sd, comfy.model_base, comfy.model_detection
    import comfy.ldm.lumina.model
    print("OK")
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD")
PYEOF
tail -20 /tmp/p2p_import.txt
grep -q "^OK$" /tmp/p2p_import.txt || fail_zero "import gate"

# ------------------------------------------------------------------
# P2P GATE 2: base Lumina NextDiT (vanilla, no clip_text_dim) still
# constructs and runs a forward pass.
# ------------------------------------------------------------------
echo "--- P2P-2: vanilla Lumina NextDiT forward ---"
python3 - > /tmp/p2p_lumina.txt 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception:
    pass
import torch
import comfy.ops
from comfy.ldm.lumina.model import NextDiT

ops = comfy.ops.disable_weight_init
try:
    m = NextDiT(
        patch_size=2, in_channels=4, dim=64, n_layers=2,
        n_heads=4, n_kv_heads=2,
        axes_dims=[8, 8, 8], axes_lens=[300, 64, 64],
        cap_feat_dim=32,
        device="cpu", dtype=torch.float32, operations=ops,
    )
    m.eval()
    x = torch.randn(1, 4, 16, 16)
    t = torch.tensor([0.5])
    ctx = torch.randn(1, 8, 32)
    nt = torch.tensor([8])
    am = torch.ones(1, 8, dtype=torch.bool)
    with torch.no_grad():
        y = m(x, t, ctx, nt, attention_mask=am)
    if y.shape[-2:] != (16, 16):
        print("BAD:shape", y.shape)
    else:
        print("OK")
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:exc")
PYEOF
tail -20 /tmp/p2p_lumina.txt
grep -q "^OK$" /tmp/p2p_lumina.txt || fail_zero "vanilla Lumina NextDiT broken"

# ==================================================================
# F2P gates. Each ~independent. Total = 1.0.
# ==================================================================

# ------------------------------------------------------------------
# F2P-1 (0.20): Lumina NextDiT supports clip_text_dim parameter (NewBie's
# pooled CLIP text feature) and runs a forward with clip_text_pooled
# influencing the output. This is the central "reuse Lumina" requirement.
# A no-op base lacks the parameter on Lumina (it's only on the vendored
# NewBie module), so this fails on base.
# ------------------------------------------------------------------
echo "--- F2P-1: Lumina NextDiT clip_text_dim integration (0.20) ---"
python3 - > /tmp/f2p1.txt 2>&1 <<'PYEOF'
import sys, inspect
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception:
    pass
import torch
import comfy.ops
from comfy.ldm.lumina.model import NextDiT

# Param presence
sig = inspect.signature(NextDiT.__init__)
if "clip_text_dim" not in sig.parameters:
    print("BAD:no_clip_text_dim_param"); sys.exit(0)

ops = comfy.ops.disable_weight_init
try:
    m = NextDiT(
        patch_size=2, in_channels=4, dim=64, n_layers=2,
        n_heads=4, n_kv_heads=2,
        axes_dims=[8, 8, 8], axes_lens=[300, 64, 64],
        cap_feat_dim=32,
        clip_text_dim=24,
        device="cpu", dtype=torch.float32, operations=ops,
    )
    m.eval()
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:construct"); sys.exit(0)

# Module presence
if not (hasattr(m, "clip_text_pooled_proj") and m.clip_text_pooled_proj is not None):
    print("BAD:no_clip_text_pooled_proj"); sys.exit(0)
if not (hasattr(m, "time_text_embed") and m.time_text_embed is not None):
    print("BAD:no_time_text_embed"); sys.exit(0)

x = torch.randn(2, 4, 16, 16)
t = torch.tensor([0.5, 0.5])
ctx = torch.randn(2, 8, 32)
nt = torch.tensor([8, 8])
am = torch.ones(2, 8, dtype=torch.bool)

# Two distinct pooled vectors → should produce different outputs.
torch.manual_seed(0)
pooled_a = torch.randn(2, 24)
pooled_b = torch.randn(2, 24) * 5.0 + 3.0
try:
    with torch.no_grad():
        ya = m(x, t, ctx, nt, attention_mask=am, clip_text_pooled=pooled_a)
        yb = m(x, t, ctx, nt, attention_mask=am, clip_text_pooled=pooled_b)
        yz = m(x, t, ctx, nt, attention_mask=am)  # None → zeros path
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:fwd"); sys.exit(0)

if ya.shape[-2:] != (16, 16):
    print("BAD:shape"); sys.exit(0)
diff = (ya - yb).abs().mean().item()
diff_z = (ya - yz).abs().mean().item()
if diff < 1e-5:
    print("BAD:pooled_no_effect", diff); sys.exit(0)
if diff_z < 1e-5:
    print("BAD:none_path_same_as_pooled", diff_z); sys.exit(0)
print("OK")
PYEOF
tail -20 /tmp/f2p1.txt
grep -q "^OK$" /tmp/f2p1.txt && add 0.20

# ------------------------------------------------------------------
# F2P-2 (0.15): the standalone vendored newbie module has been removed
# OR is now a thin reuse of Lumina (no NextDiT class redefined locally).
# A no-op base has comfy/ldm/newbie/model.py with its own NextDiT-like
# class re-implementing transformer blocks, so this fails on base.
# ------------------------------------------------------------------
echo "--- F2P-2: vendored NewBie diffusion module is removed or thin (0.15) ---"
python3 - > /tmp/f2p2.txt 2>&1 <<'PYEOF'
import os, ast, sys
p = "/workspace/ComfyUI/comfy/ldm/newbie/model.py"
if not os.path.isfile(p):
    print("OK:absent"); sys.exit(0)
src = open(p).read()
try:
    tree = ast.parse(src)
except Exception as e:
    print("BAD:parse", e); sys.exit(0)

# Count significant classes / attention-shaped methods. A correct refactor
# either deletes this file or shrinks it to a tiny reuse shim subclassing
# comfy.ldm.lumina.model.NextDiT.
nclasses = 0
heavy_classes = 0
for n in ast.walk(tree):
    if isinstance(n, ast.ClassDef):
        nclasses += 1
        # heavy = defines its own forward/_forward AND has many methods
        methods = [m for m in n.body if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef))]
        names = {m.name for m in methods}
        if ("_forward" in names or "forward" in names) and len(methods) >= 3:
            heavy_classes += 1

# Must not have any heavy diffusion class redefinitions.
if heavy_classes > 0:
    print("BAD:heavy_classes", heavy_classes); sys.exit(0)

# Must reference Lumina to count as reuse (or be effectively empty).
if len(src.strip()) > 200:
    if ("comfy.ldm.lumina" not in src) and ("from comfy.ldm.lumina" not in src):
        print("BAD:no_lumina_import"); sys.exit(0)

# Reject obvious antipatterns.
bad_tokens = [
    "_pop_unexpected_kwargs",
    "_fallback_operations",
    "CONDCrossAttn",
]
for tok in bad_tokens:
    if tok in src:
        print("BAD:antipattern", tok); sys.exit(0)

# Reject manual nn.init.* calls.
if "nn.init." in src:
    print("BAD:nn_init"); sys.exit(0)

print("OK")
PYEOF
tail -20 /tmp/f2p2.txt
grep -q "^OK" /tmp/f2p2.txt && add 0.15

# ------------------------------------------------------------------
# F2P-3 (0.15): comfy/ldm/lumina/model.py itself is clean — no
# antipatterns. (The base buggy state may not have these in lumina,
# but if the agent VENDORED them in, fail. Also catches agents that
# moved bad code rather than removing it.)
# ------------------------------------------------------------------
echo "--- F2P-3: lumina/model.py is clean (0.15) ---"
python3 - > /tmp/f2p3.txt 2>&1 <<'PYEOF'
import os, sys
p = "/workspace/ComfyUI/comfy/ldm/lumina/model.py"
if not os.path.isfile(p):
    print("BAD:missing"); sys.exit(0)
src = open(p).read()
bad = [
    "_pop_unexpected_kwargs",
    "_fallback_operations",
    "CONDCrossAttn",
    "nn.init.xavier_",
    "nn.init.normal_",
    "nn.init.kaiming_",
    "nn.init.zeros_",
    "nn.init.constant_",
]
for tok in bad:
    if tok in src:
        print("BAD:", tok); sys.exit(0)
# Don't allow try/except around the whole _forward body either.
import ast
tree = ast.parse(src)
for n in ast.walk(tree):
    if isinstance(n, ast.FunctionDef) and n.name == "_forward":
        # If the very first stmt is a Try whose body is the entire forward
        body = n.body
        if len(body) == 1 and isinstance(body[0], ast.Try):
            print("BAD:try_wraps_forward"); sys.exit(0)
print("OK")
PYEOF
tail -10 /tmp/f2p3.txt
grep -q "^OK$" /tmp/f2p3.txt && add 0.15

# ------------------------------------------------------------------
# F2P-4 (0.15): model_base.NewBie / Lumina path uses kwargs.get for
# pooled_output and propagates clip_text_pooled into extra_conds.
# The base buggy state has `kwargs["pooled_output"]` which raises KeyError
# when no pooled is provided.
# ------------------------------------------------------------------
echo "--- F2P-4: model_base extra_conds robustness (0.15) ---"
python3 - > /tmp/f2p4.txt 2>&1 <<'PYEOF'
import os, sys, re
p = "/workspace/ComfyUI/comfy/model_base.py"
if not os.path.isfile(p):
    print("BAD:missing"); sys.exit(0)
src = open(p).read()

# Must NOT contain `kwargs["pooled_output"]` (raises KeyError).
# Allow .get usage.
if re.search(r'kwargs\[\s*[\'"]pooled_output[\'"]\s*\]', src):
    print("BAD:kwargs_subscript"); sys.exit(0)

# Must reference clip_text_pooled in extra_conds wiring.
if "clip_text_pooled" not in src:
    print("BAD:no_clip_text_pooled"); sys.exit(0)

# Must propagate via CONDRegular (pooled is per-batch single vector,
# not cross-attn). CONDCrossAttn would be wrong.
# Find the block that mentions clip_text_pooled and check.
idx = src.find("clip_text_pooled")
window = src[max(0, idx-200):idx+400]
if "CONDCrossAttn" in window:
    print("BAD:CONDCrossAttn"); sys.exit(0)
if "CONDRegular" not in window:
    print("BAD:not_CONDRegular"); sys.exit(0)
print("OK")
PYEOF
tail -10 /tmp/f2p4.txt
grep -q "^OK$" /tmp/f2p4.txt && add 0.15

# ------------------------------------------------------------------
# F2P-5 (0.15): No custom apply_model override on the NewBie model class
# (the buggy base adds one to bypass the standard pipeline). The fix
# must rely on the standard BaseModel.apply_model path.
# Check across sd.py, model_base.py and any newbie module.
# ------------------------------------------------------------------
echo "--- F2P-5: no custom apply_model override on NewBie class (0.15) ---"
python3 - > /tmp/f2p5.txt 2>&1 <<'PYEOF'
import os, ast, sys
candidates = [
    "/workspace/ComfyUI/comfy/model_base.py",
    "/workspace/ComfyUI/comfy/ldm/newbie/model.py",
]
for p in candidates:
    if not os.path.isfile(p):
        continue
    try:
        tree = ast.parse(open(p).read())
    except Exception:
        continue
    for n in ast.walk(tree):
        if isinstance(n, ast.ClassDef):
            cname = n.name
            if "NewBie" in cname or "Newbie" in cname or cname == "NewBie":
                for m in n.body:
                    if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        if m.name == "apply_model":
                            print(f"BAD:apply_model_in_{cname}_at_{p}"); sys.exit(0)
print("OK")
PYEOF
tail -10 /tmp/f2p5.txt
grep -q "^OK$" /tmp/f2p5.txt && add 0.15

# ------------------------------------------------------------------
# F2P-6 (0.20): supported_models / model_detection wires up NewBie via
# the existing Lumina2 config branch (clip_text_dim detected from state
# dict), and a state_dict with 'clip_text_pooled_proj.0.weight' yields
# a dit_config containing clip_text_dim. Behavioral check.
# ------------------------------------------------------------------
echo "--- F2P-6: model_detection picks up clip_text_dim (0.20) ---"
python3 - > /tmp/f2p6.txt 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception:
    pass
import torch
try:
    import comfy.model_detection as MD
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:import"); sys.exit(0)

# Build a faux Lumina-2-shaped state dict with the NewBie marker.
prefix = "model.diffusion_model."
sd = {}
# Lumina marker keys (subset that detection checks). Use dim=2304.
# Mimic structures used by detect_unet_config for Lumina.
def add(k, shape):
    sd[prefix + k] = torch.zeros(shape)

# These keys are what model_detection inspects for Lumina NextDiT.
add("cap_embedder.1.weight", (2304, 2560))   # cap_feat_dim=2560 → Lumina2
add("x_embedder.weight", (2304, 4*2*2))      # patch_size=2, in_channels=4
add("t_embedder.mlp.0.weight", (2304, 256))
add("final_layer.linear.weight", (2*2*4, 2304))
# Layer 0 marker (n_layers detected by counting)
add("layers.0.attention.wq.weight", (2304, 2304))
add("layers.0.attention.wk.weight", (2304*1, 2304))
# NewBie marker
add("clip_text_pooled_proj.0.weight", (768,))

try:
    cfg = MD.model_config_from_unet(sd, prefix)
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:detect_exc"); sys.exit(0)

if cfg is None:
    # Fall back: try detect_unet_config directly.
    try:
        cfg2 = MD.detect_unet_config(sd, prefix)
    except Exception as e:
        import traceback; traceback.print_exc()
        print("BAD:unet_detect_exc"); sys.exit(0)
    if cfg2 is None:
        print("BAD:no_config"); sys.exit(0)
    unet_cfg = cfg2
else:
    unet_cfg = getattr(cfg, "unet_config", None) or {}

ctd = unet_cfg.get("clip_text_dim")
if ctd is None or int(ctd) != 768:
    print("BAD:clip_text_dim", ctd); sys.exit(0)
print("OK")
PYEOF
tail -20 /tmp/f2p6.txt
grep -q "^OK$" /tmp/f2p6.txt && add 0.20

# ------------------------------------------------------------------
# Done.
# ------------------------------------------------------------------
echo "=== Final reward: $REWARD ==="
write_reward
echo "$REWARD" > "$REWARD_FILE"