#!/bin/bash
set +e
#
# Verification tests for ComfyUI NewBie architecture refactoring.
#
# CORE PRINCIPLE: a no-op patch must score 0.0. The base code in this PR
# vendors a NewBie module with antipatterns (try/except in _forward,
# _pop_unexpected_kwargs, _fallback_operations, nn.init.*, custom apply_model,
# CONDCrossAttn for pooled output) that the agent must remove/refactor.
#
# All reward weight is on behaviors that FAIL on the unmodified base and
# PASS on a correct refactor:
#  - Antipattern helpers must be GONE (they exist on base → fails on base)
#  - try/except in _forward must be GONE (it exists on base → fails on base)
#  - apply_model override / CONDCrossAttn for pooled must be GONE
#  - clip_img_pooled must actually flow through extra_conds and influence forward
#  - NewBie diffusion module must subclass / reuse Lumina NextDiT (not vendor a copy)
#
# P2P gates: base Lumina + comfy.sd / comfy.model_base / comfy.model_detection
# must still import and run. If those break → REWARD=0.0, exit.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

REPO=/workspace/ComfyUI
source /workspace/venv/bin/activate 2>/dev/null || true
export PYTHONPATH="$REPO:$PYTHONPATH"
export COMFYUI_USE_CPU=1

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
    exit 0
}

echo "=== ComfyUI NewBie refactoring verification ==="

# ------------------------------------------------------------------
# Locate candidate newbie source file(s)
# ------------------------------------------------------------------
NEWBIE_FILES=()
[ -f "$REPO/comfy/ldm/newbie/model.py" ] && NEWBIE_FILES+=("$REPO/comfy/ldm/newbie/model.py")
[ -f "$REPO/comfy/ldm/lumina/model.py" ] && NEWBIE_FILES+=("$REPO/comfy/ldm/lumina/model.py")

echo "Candidate newbie source files: ${NEWBIE_FILES[@]}"

# ------------------------------------------------------------------
# P2P GATE: base imports must still work. The base buggy state imports
# fine; if the agent broke this, no reward.
# ------------------------------------------------------------------
echo "--- P2P: comfy.sd / comfy.model_base / comfy.model_detection import ---"
python3 - <<'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass
try:
    import comfy.sd  # noqa
    import comfy.model_base  # noqa
    import comfy.model_detection  # noqa
    import comfy.ldm.lumina.model  # noqa
    print("PASS")
except Exception as e:
    import traceback; traceback.print_exc()
    print(f"FAIL:{e}")
PYEOF
P2P_IMPORT=$?
python3 - <<'PYEOF' > /tmp/p2p_import.txt 2>&1
import sys
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
try:
    import comfy.sd, comfy.model_base, comfy.model_detection, comfy.ldm.lumina.model
    print("OK")
except Exception as e:
    print("BAD")
PYEOF
grep -q "^OK$" /tmp/p2p_import.txt || fail_zero "comfy.{sd,model_base,model_detection} or lumina.model fails to import"

# ------------------------------------------------------------------
# P2P GATE: base Lumina NextDiT can still be constructed and run forward
# (a correct refactor preserves Lumina behavior; if the agent broke
# Lumina, that's a regression — no reward.)
# ------------------------------------------------------------------
echo "--- P2P: base Lumina NextDiT construct + forward ---"
python3 - <<'PYEOF' > /tmp/p2p_lumina.txt 2>&1
import sys, os
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
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
        print("BAD:shape", y.shape); sys.exit(0)
    print("OK")
except Exception as e:
    import traceback; traceback.print_exc()
    print("BAD:exc")
PYEOF
cat /tmp/p2p_lumina.txt | tail -5
grep -q "^OK$" /tmp/p2p_lumina.txt || fail_zero "base Lumina NextDiT broken"

# ==================================================================
# F2P (BEHAVIORAL) GATES
# ==================================================================
# Each of these checks something that is TRUE/PRESENT on the buggy base
# (so it FAILS the gate on no-op) and is removed/added by a correct fix.
# ==================================================================

# ------------------------------------------------------------------
# F2P-1 (0.10): _pop_unexpected_kwargs and _fallback_operations are GONE
# from any newbie-related model file. (They are present on the buggy base
# inside the vendored newbie module → no-op fails this.)
# ------------------------------------------------------------------
echo "--- F2P-1: antipattern helpers removed (0.10) ---"
F2P1=$(python3 - <<'PYEOF'
import ast, os, sys
roots = []
for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
          "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]:
    if os.path.isfile(p):
        roots.append(p)
if not roots:
    print("FAIL:no_files"); sys.exit(0)
bad = {"_pop_unexpected_kwargs", "_fallback_operations"}
for path in roots:
    try:
        src = open(path).read()
        tree = ast.parse(src)
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name in bad:
                print(f"FAIL:{node.name}_in_{path}"); sys.exit(0)
        if isinstance(node, ast.Call):
            f = node.func
            name = None
            if isinstance(f, ast.Name): name = f.id
            elif isinstance(f, ast.Attribute): name = f.attr
            if name in bad:
                print(f"FAIL:call_{name}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $F2P1"
[ "$F2P1" = "PASS" ] && add 0.10

# ------------------------------------------------------------------
# F2P-2 (0.08): no nn.init.* manual init calls inside any class named
# NewBie* (or in the dedicated newbie file). The base vendored module
# has nn.init calls; a proper refactor relies on ops defaults.
# ------------------------------------------------------------------
echo "--- F2P-2: no nn.init.* in NewBie classes (0.08) ---"
F2P2=$(python3 - <<'PYEOF'
import ast, os, sys
paths = [p for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
                     "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]
         if os.path.isfile(p)]
if not paths:
    print("FAIL:no_files"); sys.exit(0)
for path in paths:
    is_newbie_file = "/newbie/" in path
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for cls in ast.walk(tree):
        if not isinstance(cls, ast.ClassDef): continue
        if not (cls.name.startswith("NewBie") or is_newbie_file): continue
        for n in ast.walk(cls):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                v = n.func.value
                if (isinstance(v, ast.Attribute) and isinstance(v.value, ast.Name)
                        and v.value.id == "nn" and v.attr == "init"):
                    print(f"FAIL:nn.init.{n.func.attr}_in_{cls.name}"); sys.exit(0)
                if isinstance(v, ast.Name) and v.id == "init":
                    # `from torch.nn import init; init.xavier_uniform_(...)`
                    print(f"FAIL:init.{n.func.attr}_in_{cls.name}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $F2P2"
[ "$F2P2" = "PASS" ] && add 0.08

# ------------------------------------------------------------------
# F2P-3 (0.10): no try/except inside _forward of NewBie* classes / newbie
# module. The base has a defensive try/except wrapping _forward; refactor
# removes it.
# ------------------------------------------------------------------
echo "--- F2P-3: no try/except in _forward (0.10) ---"
F2P3=$(python3 - <<'PYEOF'
import ast, os, sys
paths = [p for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
                     "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]
         if os.path.isfile(p)]
if not paths:
    print("FAIL:nofile"); sys.exit(0)
for path in paths:
    is_newbie_file = "/newbie/" in path
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for cls in ast.walk(tree):
        if not isinstance(cls, ast.ClassDef): continue
        if not (is_newbie_file or cls.name.startswith("NewBie")): continue
        for m in cls.body:
            if isinstance(m, ast.FunctionDef) and m.name in ("_forward", "forward"):
                for n in ast.walk(m):
                    if isinstance(n, ast.Try):
                        print(f"FAIL:try_in_{cls.name}.{m.name}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $F2P3"
[ "$F2P3" = "PASS" ] && add 0.10

# ------------------------------------------------------------------
# F2P-4 (0.10): model_base.NewBie* uses extra_conds, has NO apply_model
# override, and does NOT use CONDCrossAttn for pooled CLIP output.
# Base wires NewBie via custom apply_model + CONDCrossAttn for pooled —
# refactor must use the standard extra_conds path.
# ------------------------------------------------------------------
echo "--- F2P-4: model_base NewBie wiring (0.10) ---"
F2P4=$(python3 - <<'PYEOF'
import ast, sys
try:
    tree = ast.parse(open("/workspace/ComfyUI/comfy/model_base.py").read())
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit(0)
newbie = [c for c in ast.walk(tree)
          if isinstance(c, ast.ClassDef) and c.name.startswith("NewBie")]
if not newbie:
    print("FAIL:no_newbie_class"); sys.exit(0)
for cls in newbie:
    has_extra_conds = False
    has_apply_model = False
    has_crossattn = False
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            if item.name == "apply_model":
                has_apply_model = True
            if item.name == "extra_conds":
                has_extra_conds = True
        for n in ast.walk(item) if isinstance(item, ast.FunctionDef) else []:
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                if n.func.attr == "CONDCrossAttn":
                    has_crossattn = True
    if has_extra_conds and not has_apply_model and not has_crossattn:
        print("PASS"); sys.exit(0)
print("FAIL:no_clean_newbie_class")
PYEOF
)
echo "  $F2P4"
[ "$F2P4" = "PASS" ] && add 0.10

# ------------------------------------------------------------------
# F2P-5 (0.08): NewBie subclasses / reuses Lumina NextDiT.
# Base vendors its own NewBieNextDiT class that does NOT subclass NextDiT.
# A correct refactor either (a) defines NewBieNextDiT(NextDiT) or
# (b) drops the separate class entirely and uses NextDiT directly with
# additional kwargs.
# ------------------------------------------------------------------
echo "--- F2P-5: NewBie reuses Lumina NextDiT (0.08) ---"
F2P5=$(python3 - <<'PYEOF'
import ast, os, sys
paths = [p for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
                     "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]
         if os.path.isfile(p)]
if not paths:
    print("FAIL:nofile"); sys.exit(0)

found_subclass = False
found_newbie_class = False
for path in paths:
    try:
        tree = ast.parse(open(path).read())
    except Exception:
        continue
    for cls in ast.walk(tree):
        if not isinstance(cls, ast.ClassDef): continue
        if not cls.name.startswith("NewBie"): continue
        # Must look like a DiT (so we test true reuse, not unrelated NewBie* class)
        # Check bases: any base that resolves to NextDiT or *.NextDiT counts.
        for b in cls.bases:
            base_name = None
            if isinstance(b, ast.Name): base_name = b.id
            elif isinstance(b, ast.Attribute): base_name = b.attr
            if base_name and ("NextDiT" in base_name):
                found_subclass = True
        # Track that there's a NewBie* DiT-looking class for the
        # "no-separate-class" path
        if any("DiT" in cls.name or "NextDiT" in cls.name for _ in [0]):
            if "DiT" in cls.name:
                found_newbie_class = True

# Path A: NewBie*DiT subclass of NextDiT exists.
if found_subclass:
    print("PASS"); sys.exit(0)

# Path B: no separate NewBieNextDiT class at all — NewBie reuses NextDiT
# directly via supported_models / model_base.
if not found_newbie_class:
    # Verify model_base actually references NextDiT (or Lumina2 base) for NewBie,
    # not a vendored class.
    try:
        mb = open("/workspace/ComfyUI/comfy/model_base.py").read()
    except Exception:
        print("FAIL:no_mb"); sys.exit(0)
    if "class NewBie" in mb and ("Lumina2" in mb or "NextDiT" in mb):
        # NewBie inherits from Lumina2 (which uses NextDiT) → reuse OK
        print("PASS"); sys.exit(0)

print("FAIL:no_reuse")
PYEOF
)
echo "  $F2P5"
[ "$F2P5" = "PASS" ] && add 0.08

# ------------------------------------------------------------------
# F2P-6 (0.10): comfy.ldm.lumina.model uses operations.Linear /
# operations.RMSNorm for the pooled-CLIP path (no vendored RMSNorm class
# definition in newbie file, and no plain torch.nn.Linear / nn.LayerNorm
# used for the pooled embedder in NewBie code).
# Base vendored module defines its own RMSNorm class.
# ------------------------------------------------------------------
echo "--- F2P-6: ops.Linear / ops.RMSNorm reuse, no vendored RMSNorm (0.10) ---"
F2P6=$(python3 - <<'PYEOF'
import ast, os, sys
paths = [p for p in ["/workspace/ComfyUI/comfy/ldm/newbie/model.py",
                     "/workspace/ComfyUI/comfy/ldm/lumina/model.py"]
         if os.path.isfile(p)]
if not paths:
    print("FAIL:nofile"); sys.exit(0)

# (a) No class named RMSNorm defined in any newbie/lumina file.
for path in paths:
    try:
        tree = ast.parse(open(path).read())
    except Exception as e:
        print(f"FAIL:parse:{e}"); sys.exit(0)
    for cls in ast.walk(tree):
        if isinstance(cls, ast.ClassDef) and cls.name == "RMSNorm":
            print(f"FAIL:RMSNorm_class_in_{path}"); sys.exit(0)

# (b) Somewhere in newbie-related code, operations.RMSNorm and
# operations.Linear are referenced (the pooled embedder uses them).
joined = ""
for path in paths:
    joined += open(path).read() + "\n"

if "RMSNorm" not in joined:
    print("FAIL:no_rmsnorm_ref"); sys.exit(0)
if ".Linear(" not in joined and "operations.Linear" not in joined:
    print("FAIL:no_linear_ref"); sys.exit(0)
if "operations.RMSNorm" not in joined and "operations\").RMSNorm" not in joined and "operation_settings" not in joined:
    # accept either explicit operations.RMSNorm(...) or
    # operation_settings.get("operations").RMSNorm(...)
    print("FAIL:no_ops_rmsnorm"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $F2P6"
[ "$F2P6" = "PASS" ] && add 0.10

# ------------------------------------------------------------------
# F2P-7 (0.18): END-TO-END BEHAVIORAL — Construct a NewBie diffusion module
# through ComfyUI's operations, run forward(), and verify:
#  (a) it runs without raising
#  (b) output shape == input shape
#  (c) clip_img_pooled actually influences the output (different pooled
#      vector → different output). This guarantees the wiring is real,
#      not stubbed/ignored.
#
# The base buggy module defines NewBie classes but the pooled CLIP-image
# input is taken via clip_text_pooled (CONDCrossAttn) and the wiring is
# wrong; this end-to-end check fails on no-op.
# ------------------------------------------------------------------
echo "--- F2P-7: end-to-end NewBie forward + clip_img_pooled influence (0.18) ---"
python3 - <<'PYEOF' > /tmp/f2p7.txt 2>&1
import sys, os, importlib, traceback
sys.path.insert(0, "/workspace/ComfyUI")
try:
    import comfy.cli_args; comfy.cli_args.args.cpu = True
except Exception: pass
import torch
import comfy.ops

ops = comfy.ops.disable_weight_init

# Try multiple module paths the agent may have used.
candidates = []
try:
    import comfy.ldm.newbie.model as nm
    candidates.append(("newbie", nm))
except Exception:
    pass
try:
    import comfy.ldm.lumina.model as lm
    candidates.append(("lumina", lm))
except Exception:
    pass

if not candidates:
    print("BAD:no_module"); sys.exit(0)

# Find a NewBie* DiT class in any candidate, OR fall back to Lumina NextDiT
# if the agent unified everything into NextDiT with a clip_img_pooled_dim
# / clip_img_dim style kwarg.
ModelCls = None
extra_kwargs = {}
img_kwarg_name = None

# Probe NextDiT signature for an image-pooled kwarg that takes an int dim.
import inspect
for tag, mod in candidates:
    for clsname in dir(mod):
        cls = getattr(mod, clsname)
        if not isinstance(cls, type): continue
        if not (clsname.startswith("NewBie") or clsname == "NextDiT"): continue
        try:
            sig = inspect.signature(cls.__init__)
        except Exception:
            continue
        params = sig.parameters
        # Look for a parameter that suggests CLIP-image pooled dim.
        for pname in params:
            pl = pname.lower()
            if ("clip" in pl and "img" in pl and ("dim" in pl or "pooled" in pl)) \
               or pname in ("clip_img_pooled_dim", "clip_img_dim"):
                ModelCls = cls
                img_kwarg_name = pname
                break
        if ModelCls is not None:
            break
    if ModelCls is not None:
        break

if ModelCls is None:
    print("BAD:no_clip_img_kwarg"); sys.exit(0)

print(f"using {ModelCls.__name__} with kwarg {img_kwarg_name}")

CLIP_IMG_DIM = 16
common = dict(
    patch_size=2, in_channels=4, dim=64, n_layers=2,
    n_heads=4, n_kv_heads=2,
    axes_dims=[8, 8, 8], axes_lens=[300, 64, 64],
    cap_feat_dim=32,
    device="cpu", dtype=torch.float32, operations=ops,
)
common[img_kwarg_name] = CLIP_IMG_DIM

try:
    m = ModelCls(**common)
except TypeError as e:
    # Some signatures may also need clip_text_dim or similar; try a few.
    for extra in [{"clip_text_dim": 32}, {}]:
        try:
            kk = dict(common); kk.update(extra)
            m = ModelCls(**kk)
            break
        except Exception:
            m = None
    if m is None:
        print(f"BAD:construct:{e}"); traceback.print_exc(); sys.exit(0)
except Exception as e:
    print(f"BAD:construct:{e}"); traceback.print_exc(); sys.exit(0)

m.eval()

x = torch.randn(1, 4, 16, 16)
t = torch.tensor([0.5])
ctx = torch.randn(1, 8, 32)
nt = torch.tensor([8])
am = torch.ones(1, 8, dtype=torch.bool)

p1 = torch.zeros(1, CLIP_IMG_DIM)
p2 = torch.randn(1, CLIP_IMG_DIM) * 5.0

# Try several kwarg names — agent might pass clip_img_pooled or similar.
img_input_names = ["clip_img_pooled", "clip_image_pooled", "clip_img"]

result_a = None
result_b = None
used_name = None
for nm in img_input_names:
    try:
        with torch.no_grad():
            torch.manual_seed(0)
            ya = m(x, t, ctx, nt, attention_mask=am, **{nm: p1})
            torch.manual_seed(0)
            yb = m(x, t, ctx, nt, attention_mask=am, **{nm: p2})
        result_a, result_b, used_name = ya, yb, nm
        break
    except TypeError:
        continue
    except Exception as e:
        traceback.print_exc()
        continue

if result_a is None:
    # Final attempt: pass via kwargs without specific name
    try:
        with torch.no_grad():
            ya = m(x, t, ctx, nt, attention_mask=am)
            yb = m(x, t, ctx, nt, attention_mask=am)
        # No way to test influence then — fail influence portion.
        result_a, result_b, used_name = ya, yb, None
    except Exception as e:
        print(f"BAD:forward:{e}"); traceback.print_exc(); sys.exit(0)

# Check (a): runs OK
print(f"FORWARD_OK shape={tuple(result_a.shape)} kwarg={used_name}")

# Check (b): output spatial shape matches input
if tuple(result_a.shape[-2:]) != (16, 16):
    print(f"BAD:shape:{result_a.shape}"); sys.exit(0)
print("SHAPE_OK")

# Check (c): pooled influence
if used_name is None:
    print("BAD:no_pooled_kwarg_accepted"); sys.exit(0)
diff = (result_a - result_b).abs().max().item()
print(f"DIFF={diff}")
if diff < 1e-5:
    print("BAD:no_influence")
    sys.exit(0)
print("INFLUENCE_OK")
PYEOF
cat /tmp/f2p7.txt | tail -30
HAS_FORWARD=$(grep -c "^FORWARD_OK" /tmp/f2p7.txt)
HAS_SHAPE=$(grep -c "^SHAPE_OK" /tmp/f2p7.txt)
HAS_INFL=$(grep -c "^INFLUENCE_OK" /tmp/f2p7.txt)

# Award sub-weights for the end-to-end behavioral checks.
# 0.06 forward runs, 0.04 shape correct, 0.08 pooled influence.
if [ "$HAS_FORWARD" -ge 1 ]; then add 0.06; echo "  forward runs (+0.06)"; fi
if [ "$HAS_SHAPE" -ge 1 ];   then add 0.04; echo "  shape matches (+0.04)"; fi
if [ "$HAS_INFL" -ge 1 ];    then add 0.08; echo "  clip_img_pooled influences output (+0.08)"; fi

# ------------------------------------------------------------------
# F2P-8 (0.06): The model_base.py file no longer wires the pooled CLIP
# input via the buggy `kwargs["pooled_output"]` direct subscription
# inside extra_conds (which raises KeyError when pooled_output absent).
# Base does this; correct refactor uses kwargs.get(...) or moves it into
# a NewBie subclass.
# ------------------------------------------------------------------
echo "--- F2P-8: pooled subscription bug fixed in model_base (0.06) ---"
F2P8=$(python3 - <<'PYEOF'
import re, sys
try:
    src = open("/workspace/ComfyUI/comfy/model_base.py").read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)

# The buggy pattern: kwargs["pooled_output"] inside Lumina2.extra_conds.
# A correct fix either removes that line entirely from Lumina2.extra_conds
# (moving pooled handling into NewBie.extra_conds) or uses kwargs.get(...).
#
# Find Lumina2 class body.
m = re.search(r"class\s+Lumina2\b[^\n]*\n(.*?)(?=^class\s+\w)", src, re.S | re.M)
if not m:
    print("FAIL:no_lumina2"); sys.exit(0)
body = m.group(1)
# If the class still has the literal `kwargs["pooled_output"]` it's the
# buggy base.
if 'kwargs["pooled_output"]' in body or "kwargs['pooled_output']" in body:
    print("FAIL:still_bug"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $F2P8"
[ "$F2P8" = "PASS" ] && add 0.06

# ------------------------------------------------------------------
# F2P-9 (0.06): supported_models / model_detection wires NewBie. On the
# buggy base, NewBie is detected via an ad-hoc clip_text_dim hack but
# image_model isn't set to "newbie" in detection. A correct refactor
# emits image_model="newbie" so dispatch works.
# ------------------------------------------------------------------
echo "--- F2P-9: model_detection emits image_model=newbie (0.06) ---"
F2P9=$(python3 - <<'PYEOF'
import re, sys
try:
    src = open("/workspace/ComfyUI/comfy/model_detection.py").read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
# Look for image_model = "newbie" anywhere.
if re.search(r'image_model"\]\s*=\s*"newbie"', src) or \
   re.search(r"image_model'\]\s*=\s*'newbie'", src):
    print("PASS"); sys.exit(0)
print("FAIL")
PYEOF
)
echo "  $F2P9"
[ "$F2P9" = "PASS" ] && add 0.06

# ------------------------------------------------------------------
# F2P-10 (0.10): A NewBie* model_base class is defined that subclasses
# Lumina2 (or BaseModel) and adds clip_img_pooled (or equivalent CLIP
# image pooled) into extra_conds. This is the architectural piece that
# makes the pooled wiring real end-to-end.
# Base has no such class.
# ------------------------------------------------------------------
echo "--- F2P-10: NewBie model_base class with clip_img_pooled extra_cond (0.10) ---"
F2P10=$(python3 - <<'PYEOF'
import ast, sys
try:
    tree = ast.parse(open("/workspace/ComfyUI/comfy/model_base.py").read())
except Exception as e:
    print(f"FAIL:{e}"); sys.exit(0)
for cls in ast.walk(tree):
    if not isinstance(cls, ast.ClassDef): continue
    if not cls.name.startswith("NewBie"): continue
    # base must include Lumina2 or BaseModel
    base_names = []
    for b in cls.bases:
        if isinstance(b, ast.Name): base_names.append(b.id)
        elif isinstance(b, ast.Attribute): base_names.append(b.attr)
    if not any(n in ("Lumina2", "BaseModel") for n in base_names):
        continue
    # find extra_conds
    for item in cls.body:
        if isinstance(item, ast.FunctionDef) and item.name == "extra_conds":
            # search for any reference to clip_img_pooled or similar
            for n in ast.walk(item):
                if isinstance(n, ast.Constant) and isinstance(n.value, str):
                    if "clip_img" in n.value or "clip_image" in n.value:
                        print("PASS"); sys.exit(0)
print("FAIL")
PYEOF
)
echo "  $F2P10"
[ "$F2P10" = "PASS" ] && add 0.10

# ==================================================================
# Final
# ==================================================================
echo "=== Final reward: $REWARD ==="
write_reward