#!/bin/bash
set +e
#
# Verification tests for ComfyUI NewBie architecture refactoring.
#
# The PR adds a "NewBie" image diffusion model. NewBie is essentially a Lumina2
# variant with an extra pooled CLIP-image conditioning that is added to the
# adaln input. The agent should:
#   - Reuse Lumina's NextDiT (subclass it) instead of vendoring a copy.
#   - Use ComfyUI's operations.Linear and operations.RMSNorm.
#   - Remove the antipattern helpers (_pop_unexpected_kwargs, _fallback_operations,
#     try/except in _forward, nn.init.* manual init, custom apply_model,
#     CONDCrossAttn for pooled output).
#   - Wire up extra_conds() for clip_img_pooled on a NewBie model_base subclass.
#   - End-to-end: a NewBie diffusion module instantiated through ComfyUI's
#     operation_settings should run forward(...) and produce a tensor of the
#     correct shape, AND the clip_img_pooled kwarg should actually influence
#     the output (so the wiring is real, not stubbed).
#
# Scoring (total = 1.0):
#   Structural (0.20):
#     S1 (0.04): no antipattern helpers / no nn.init in newbie model
#     S2 (0.04): no try/except inside _forward
#     S3 (0.06): model_base.NewBie* uses extra_conds, no apply_model override,
#                no CONDCrossAttn for pooled output
#     S4 (0.06): uses operations.Linear / operations.RMSNorm; no vendored RMSNorm
#
#   Behavioral (0.65):
#     B1 (0.10): NewBie diffusion module imports cleanly through ComfyUI
#     B2 (0.15): module instantiates and forward() runs end-to-end on CPU
#     B3 (0.15): output shape matches input shape (correct unpatchify)
#     B4 (0.15): clip_img_pooled actually influences the output
#     B5 (0.10): NewBie subclasses / reuses Lumina NextDiT (not a fresh copy)
#
#   P2P regression (0.15):
#     P1 (0.08): base Lumina NextDiT still constructs and runs
#     P2 (0.07): comfy.sd / comfy.model_base / comfy.model_detection still import

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

REPO=/workspace/ComfyUI
NEWBIE_PY=""

# Activate venv if present
source /workspace/venv/bin/activate 2>/dev/null || true
export PYTHONPATH="$REPO:$PYTHONPATH"

add() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1)r=1; printf "%.4f", r}')
}

echo "=== ComfyUI NewBie refactoring verification ==="

# Locate the newbie model file. Accept either a dedicated newbie/model.py
# or the case where NewBie classes live inside lumina/model.py.
if [ -f "$REPO/comfy/ldm/newbie/model.py" ]; then
    NEWBIE_PY="$REPO/comfy/ldm/newbie/model.py"
elif [ -f "$REPO/comfy/ldm/lumina/model.py" ]; then
    NEWBIE_PY="$REPO/comfy/ldm/lumina/model.py"
fi
echo "Using newbie source: $NEWBIE_PY"

# ────────────────────────────────────────────────────────────────────
# S1: no antipattern helpers / no nn.init in any newbie-related model file
# ────────────────────────────────────────────────────────────────────
echo "--- S1: no antipattern helpers / no nn.init manual init ---"
S1=$(python3 - <<'PYEOF'
import ast, os, sys
roots = []
for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
          "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]:
    if os.path.isfile(p):
        roots.append(p)
if not roots:
    print("FAIL:no_files"); sys.exit(0)

bad_fns = {"_pop_unexpected_kwargs", "_fallback_operations"}
for path in roots:
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{path}:{e}"); sys.exit(0)

    is_newbie_file = "newbie" in path
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name in bad_fns:
                print(f"FAIL:{node.name}_defined_in_{path}"); sys.exit(0)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            if node.func.id in bad_fns:
                print(f"FAIL:{node.func.id}_called"); sys.exit(0)

    # Only check nn.init within NewBie* classes (Lumina base may legitimately
    # have none either, but we don't penalize Lumina for unrelated init code).
    for cls in ast.walk(tree):
        if not isinstance(cls, ast.ClassDef):
            continue
        if not (cls.name.startswith("NewBie") or is_newbie_file):
            continue
        for n in ast.walk(cls):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                v = n.func.value
                if (isinstance(v, ast.Attribute) and isinstance(v.value, ast.Name)
                        and v.value.id == "nn" and v.attr == "init"):
                    print(f"FAIL:nn_init_{n.func.attr}_in_{cls.name}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S1"
[ "$S1" = "PASS" ] && add 0.04

# ────────────────────────────────────────────────────────────────────
# S2: no try/except in any _forward method of newbie-related classes
# ────────────────────────────────────────────────────────────────────
echo "--- S2: no try/except in _forward ---"
S2=$(python3 - <<'PYEOF'
import ast, os, sys
paths = [p for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
                     "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]
         if os.path.isfile(p)]
if not paths:
    print("FAIL:nofile"); sys.exit(0)
for path in paths:
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for cls in ast.walk(tree):
        if not isinstance(cls, ast.ClassDef):
            continue
        # Only scrutinize newbie classes / newbie file
        if "newbie" not in path and not cls.name.startswith("NewBie"):
            continue
        for m in cls.body:
            if isinstance(m, ast.FunctionDef) and m.name in ("_forward", "forward"):
                for n in ast.walk(m):
                    if isinstance(n, ast.Try):
                        print(f"FAIL:try_in_{cls.name}.{m.name}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S2"
[ "$S2" = "PASS" ] && add 0.04

# ────────────────────────────────────────────────────────────────────
# S3: model_base.py — NewBie* class uses extra_conds, no apply_model,
#     no CONDCrossAttn for the pooled CLIP path.
# ────────────────────────────────────────────────────────────────────
echo "--- S3: model_base.py NewBie wiring ---"
S3=$(python3 - <<'PYEOF'
import ast, sys
try:
    tree = ast.parse(open("/workspace/ComfyUI/comfy/model_base.py").read())
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)

newbie_classes = [c for c in ast.walk(tree)
                  if isinstance(c, ast.ClassDef) and c.name.startswith("NewBie")]
if not newbie_classes:
    print("FAIL:no_newbie_class"); sys.exit(0)

ok = False
for cls in newbie_classes:
    has_extra_conds = False
    has_apply_model = False
    has_crossattn = False
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            if item.name == "apply_model":
                has_apply_model = True
            if item.name == "extra_conds":
                has_extra_conds = True
                for n in ast.walk(item):
                    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                        if n.func.attr == "CONDCrossAttn":
                            has_crossattn = True
    if has_extra_conds and not has_apply_model and not has_crossattn:
        ok = True
        break
if not ok:
    print("FAIL:newbie_wiring_wrong"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S3"
[ "$S3" = "PASS" ] && add 0.06

# ────────────────────────────────────────────────────────────────────
# S4: uses operations.Linear / operations.RMSNorm; no vendored RMSNorm import
# ────────────────────────────────────────────────────────────────────
echo "--- S4: ops.Linear / ops.RMSNorm reuse ---"
S4=$(python3 - <<PYEOF
import ast, os, sys
paths = [p for p in ["$NEWBIE_PY"] if p and os.path.isfile(p)]
# Also include any newbie-specific file regardless
for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py"]:
    if os.path.isfile(p) and p not in paths:
        paths.append(p)
if not paths:
    print("FAIL:nofile"); sys.exit(0)

def is_ops(node):
    if not isinstance(node, ast.Attribute):
        return False
    v = node.value
    if isinstance(v, ast.Name) and v.id in ("operations","ops"):
        return True
    if isinstance(v, ast.Call) and isinstance(v.func, ast.Attribute) and v.func.attr == "get":
        if isinstance(v.func.value, ast.Name) and v.func.value.id == "operation_settings":
            return True
    return False

found_linear = False
found_rms = False
vendored = False
for path in paths:
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            if node.attr == "Linear" and is_ops(node):
                found_linear = True
            if node.attr == "RMSNorm" and is_ops(node):
                found_rms = True
        if isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            if "components" in mod or "vendored" in mod:
                for n in node.names:
                    if n.name == "RMSNorm":
                        vendored = True
if not found_linear:
    print("FAIL:no_ops_Linear"); sys.exit(0)
if not found_rms:
    print("FAIL:no_ops_RMSNorm"); sys.exit(0)
if vendored:
    print("FAIL:vendored_RMSNorm"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S4"
[ "$S4" = "PASS" ] && add 0.06

# ────────────────────────────────────────────────────────────────────
# Behavioral block
# ────────────────────────────────────────────────────────────────────
echo ""
echo "--- Behavioral tests ---"

BOUT=$(python3 - <<'PYEOF'
import sys, os, importlib, traceback
sys.path.insert(0, "/workspace/ComfyUI")

results = {"B1":0,"B2":0,"B3":0,"B4":0,"B5":0,"P1":0,"P2":0}

# Force CPU
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

# Stub optional native ext
import types
for n in ("comfy_aimdo","comfy_aimdo.host_buffer","comfy_aimdo.torch","comfy_aimdo.model_vbar"):
    if n not in sys.modules:
        m = types.ModuleType(n); m.__path__=[]
        sys.modules[n] = m

try:
    import torch
    import torch.nn as nn
except Exception as e:
    print(f"FATAL:torch:{e}")
    for k in results: print(f"{k}:0")
    sys.exit(0)

# P2: top-level module import sanity
try:
    import comfy.sd
    import comfy.model_base
    import comfy.model_detection
    results["P2"] = 1
except Exception as e:
    traceback.print_exc()

# Find/import the NewBie diffusion class
NewBieCls = None
LuminaNextDiT = None
try:
    import comfy.ldm.lumina.model as lm
    LuminaNextDiT = getattr(lm, "NextDiT", None)
except Exception:
    pass

# Try a dedicated newbie module first
try:
    import comfy.ldm.newbie.model as nm
    for name in ("NewBieNextDiT","NewBie","NewBieModel"):
        if hasattr(nm, name):
            NewBieCls = getattr(nm, name)
            break
    # Otherwise pick any class subclassing NextDiT
    if NewBieCls is None and LuminaNextDiT is not None:
        for name, obj in vars(nm).items():
            if isinstance(obj, type) and issubclass(obj, LuminaNextDiT) and obj is not LuminaNextDiT:
                NewBieCls = obj
                break
except Exception:
    pass

# Or maybe it lives in lumina/model.py
if NewBieCls is None:
    try:
        import comfy.ldm.lumina.model as lm
        for name in ("NewBieNextDiT","NewBie"):
            if hasattr(lm, name):
                NewBieCls = getattr(lm, name)
                break
        if NewBieCls is None and LuminaNextDiT is not None:
            for name, obj in vars(lm).items():
                if (isinstance(obj, type) and issubclass(obj, LuminaNextDiT)
                        and obj is not LuminaNextDiT and "NewBie" in name):
                    NewBieCls = obj
                    break
    except Exception:
        pass

# Or use Lumina's NextDiT itself with clip_text_dim=… as the "NewBie" path
# (some refactors keep NewBie behavior *inside* Lumina2.NextDiT, gated by
#  clip_text_dim / clip_img_dim kwargs). In that case the same class instance
#  is treated as NewBie.
fallback_to_lumina = False
if NewBieCls is None and LuminaNextDiT is not None:
    NewBieCls = LuminaNextDiT
    fallback_to_lumina = True

if NewBieCls is None:
    print("DBG:no NewBie class found")
else:
    results["B1"] = 1
    print(f"DBG:NewBieCls={NewBieCls.__module__}.{NewBieCls.__name__} fallback={fallback_to_lumina}")

# B5: subclasses Lumina NextDiT (or *is* Lumina NextDiT extended via kwargs)
if NewBieCls is not None and LuminaNextDiT is not None:
    if NewBieCls is LuminaNextDiT or issubclass(NewBieCls, LuminaNextDiT):
        results["B5"] = 1

import comfy.ops
ops = comfy.ops.manual_cast

# Build minimal lumina-compatible kwargs
def build_kwargs(clip_img_dim=None, clip_text_dim=128):
    kw = dict(
        patch_size=2,
        in_channels=4,
        dim=128,
        n_layers=2,
        n_heads=4,
        n_kv_heads=2,
        axes_dims=[16, 8, 8],
        axes_lens=[64, 64, 64],
        cap_feat_dim=64,
        norm_eps=1e-5,
        rope_theta=10000.0,
        clip_text_dim=clip_text_dim,
        device=torch.device("cpu"),
        dtype=torch.float32,
        operations=ops,
    )
    # Common name variants for the clip-image dim
    if clip_img_dim is not None:
        kw["clip_img_dim"] = clip_img_dim
        kw["clip_img_pooled_dim"] = clip_img_dim
    return kw

def try_construct(cls, **extra):
    """Try common ctor variants, dropping unknown kwargs."""
    import inspect
    sig_params = set()
    try:
        sig = inspect.signature(cls.__init__)
        sig_params = set(sig.parameters)
        accepts_var_kw = any(p.kind == inspect.Parameter.VAR_KEYWORD
                              for p in sig.parameters.values())
    except Exception:
        accepts_var_kw = True

    base = build_kwargs(**extra)
    if not accepts_var_kw:
        base = {k: v for k, v in base.items() if k in sig_params}
    return cls(**base)

model = None
clip_img_dim = 64
if NewBieCls is not None:
    for attempt in (
        dict(clip_img_dim=clip_img_dim),
        dict(clip_img_dim=None),
    ):
        try:
            model = try_construct(NewBieCls, **attempt)
            print(f"DBG:constructed with {attempt}")
            break
        except Exception as e:
            print(f"DBG:ctor failed {attempt}: {type(e).__name__}: {e}")
            traceback.print_exc()
            model = None

if model is not None:
    results["B2"] = 0  # set after forward succeeds
    model = model.to(torch.float32).eval()

    # Build a forward call.
    bs, c, h, w = 1, 4, 16, 16
    x = torch.randn(bs, c, h, w)
    timesteps = torch.tensor([0.5])
    context = torch.randn(bs, 8, 64)        # cap_feats
    num_tokens = torch.tensor([8])
    attn = torch.ones(bs, 8, dtype=torch.bool)
    pooled_text = torch.randn(bs, 128)
    pooled_img = torch.randn(bs, clip_img_dim)

    def call(model, **extra_kwargs):
        kw = dict(
            x=x, timesteps=timesteps, context=context,
            num_tokens=num_tokens, attention_mask=attn,
            transformer_options={},
        )
        kw.update(extra_kwargs)
        # Try .forward and ._forward
        with torch.no_grad():
            try:
                return model(**kw)
            except TypeError:
                # Some signatures use positional cap_feats
                try:
                    return model._forward(**kw)
                except Exception as e:
                    raise

    # B2 + B3: forward runs, output shape == input shape
    try:
        out = call(model, clip_text_pooled=pooled_text, clip_img_pooled=pooled_img)
        results["B2"] = 1
        if isinstance(out, torch.Tensor) and out.shape == x.shape:
            results["B3"] = 1
        else:
            print(f"DBG:bad_shape: {getattr(out,'shape',type(out))}")
    except Exception as e:
        print(f"DBG:forward1 failed: {type(e).__name__}: {e}")
        traceback.print_exc()

    # B4: clip_img_pooled influences output (only meaningful if clip_img path exists)
    if results["B2"] == 1:
        has_clip_img_path = False
        for n, _ in model.named_modules():
            if "clip_img" in n.lower():
                has_clip_img_path = True
                break
        if not has_clip_img_path:
            # Look for attribute names too
            for attr in dir(model):
                if "clip_img" in attr.lower():
                    has_clip_img_path = True
                    break
        try:
            torch.manual_seed(0)
            out_a = call(model, clip_text_pooled=pooled_text, clip_img_pooled=pooled_img)
            torch.manual_seed(0)
            pooled_img2 = pooled_img + 5.0
            out_b = call(model, clip_text_pooled=pooled_text, clip_img_pooled=pooled_img2)
            if isinstance(out_a, torch.Tensor) and isinstance(out_b, torch.Tensor):
                diff = (out_a - out_b).abs().max().item()
                print(f"DBG:clip_img diff = {diff}")
                if has_clip_img_path:
                    if diff > 1e-5:
                        results["B4"] = 1
                else:
                    # No img path implemented at all → award partial via B4=0
                    # but still allow text path to count for B4 if it influences
                    pass
        except Exception as e:
            print(f"DBG:forward2 failed: {type(e).__name__}: {e}")

# P1: base Lumina NextDiT still constructs and runs (regression)
if LuminaNextDiT is not None:
    try:
        m2 = try_construct(LuminaNextDiT, clip_img_dim=None)
        m2 = m2.to(torch.float32).eval()
        bs, c, h, w = 1, 4, 16, 16
        x = torch.randn(bs, c, h, w)
        with torch.no_grad():
            out = m2(
                x=x,
                timesteps=torch.tensor([0.5]),
                context=torch.randn(bs, 8, 64),
                num_tokens=torch.tensor([8]),
                attention_mask=torch.ones(bs, 8, dtype=torch.bool),
                transformer_options={},
            )
        if isinstance(out, torch.Tensor) and out.shape == x.shape:
            results["P1"] = 1
    except Exception as e:
        print(f"DBG:P1 failed: {type(e).__name__}: {e}")

for k in ("B1","B2","B3","B4","B5","P1","P2"):
    print(f"{k}:{results[k]}")
PYEOF
)
echo "$BOUT"

get() { echo "$BOUT" | grep "^$1:" | head -1 | cut -d: -f2; }

B1=$(get B1); B2=$(get B2); B3=$(get B3); B4=$(get B4); B5=$(get B5)
P1=$