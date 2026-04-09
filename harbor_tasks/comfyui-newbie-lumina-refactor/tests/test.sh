#!/usr/bin/env bash
#
# Verification tests for ComfyUI NewBie architecture refactoring.
#
# Scoring: 86% behavioral, 14% structural (15 tests)
#
#   Structural (0.14):
#     S1 (0.02): Valid Python + class definition
#     S2 (0.03): No _pop_unexpected_kwargs / _fallback_operations / nn.init
#     S3 (0.02): No try/except in _forward
#     S4 (0.04): model_base.py: no apply_model + no CONDCrossAttn in NewBieImage
#     S5 (0.03): _forward has >=8 Call nodes (anti-delegation)
#
#   Behavioral (0.86):
#     B1  (0.05): Import + NextDiT subclass + _forward overridden
#     B2  (0.05): Instantiate on CPU + >=4 extra params vs base
#     B3  (0.12): _forward correct shape (4x4 AND 8x8) + _forward complex
#     B4  (0.08): F2P: return -img at ts=0.3 + _forward complex
#     B5  (0.08): F2P: return -img at ts=0.7 (varied) + _forward complex
#     B6  (0.08): F2P: t=1.0-timesteps at ts=0.3->0.7 + _forward complex
#     B7  (0.08): F2P: t=1.0-timesteps at ts=0.8->0.2 (varied) + complex
#     B8  (0.12): clip_text_pooled influences output
#     B9  (0.12): clip_img_pooled influences output
#     B10 (0.08): P2P: Base NextDiT still works
#
# Max stub score: 0.29 (structural 0.11 + B1 0.05 + B2 0.05 + B10 0.08)
#   (S5 fails for delegation; B3-B9 require _forward complexity or extra params)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0
PASS_COUNT=0
TOTAL=15

# Activate venv for torch availability
source /workspace/venv/bin/activate 2>/dev/null || true

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
    PASS_COUNT=$((PASS_COUNT + 1))
}

echo "=== Verifying ComfyUI NewBie architecture refactoring ==="
echo ""

# ═══════════════════════════════════════════════════════════════
# S1 (0.02): Valid Python + class definition
# ═══════════════════════════════════════════════════════════════
echo "--- S1/15: Valid Python + class ---"
S1=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        tree = ast.parse(f.read())
except FileNotFoundError:
    print("FAIL:not_found"); sys.exit(0)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}"); sys.exit(0)
if any(isinstance(n, ast.ClassDef) for n in ast.walk(tree)):
    print("PASS")
else:
    print("FAIL:no_class")
PYEOF
)
echo "  $S1"
if [ "$S1" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════
# S2 (0.03): No _pop_unexpected_kwargs / _fallback_operations / nn.init
# ═══════════════════════════════════════════════════════════════
echo "--- S2/15: No antipattern helpers + no nn.init ---"
S2=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        tree = ast.parse(f.read())
except Exception:
    print("FAIL:parse"); sys.exit(0)

bad_fns = {"_pop_unexpected_kwargs", "_fallback_operations"}
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if node.name in bad_fns:
            print(f"FAIL:{node.name}_defined"); sys.exit(0)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id in bad_fns:
            print(f"FAIL:{node.func.id}_called"); sys.exit(0)

for cls in ast.walk(tree):
    if not isinstance(cls, ast.ClassDef):
        continue
    for method in cls.body:
        if isinstance(method, ast.FunctionDef) and method.name == "__init__":
            for n in ast.walk(method):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                    v = n.func.value
                    if (isinstance(v, ast.Attribute) and isinstance(v.value, ast.Name)
                            and v.value.id == "nn" and v.attr == "init"):
                        print(f"FAIL:nn_init_{n.func.attr}"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S2"
if [ "$S2" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════
# S3 (0.02): No try/except in _forward
# ═══════════════════════════════════════════════════════════════
echo "--- S3/15: No try/except in _forward ---"
S3=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        tree = ast.parse(f.read())
except Exception:
    print("FAIL:parse"); sys.exit(0)

for cls in ast.walk(tree):
    if not isinstance(cls, ast.ClassDef):
        continue
    for method in cls.body:
        if isinstance(method, ast.FunctionDef) and method.name == "_forward":
            for n in ast.walk(method):
                if isinstance(n, ast.Try):
                    print("FAIL:try_except_in_forward"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S3"
if [ "$S3" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════
# S4 (0.04): model_base.py: no apply_model + no CONDCrossAttn in NewBieImage
# ═══════════════════════════════════════════════════════════════
echo "--- S4/15: model_base.py fixes ---"
S4=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/model_base.py") as f:
        tree = ast.parse(f.read())
except Exception:
    print("FAIL:parse"); sys.exit(0)

found = False
for cls in ast.walk(tree):
    if not isinstance(cls, ast.ClassDef) or cls.name != "NewBieImage":
        continue
    found = True
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            if item.name == "apply_model":
                print("FAIL:apply_model_present"); sys.exit(0)
            if item.name == "extra_conds":
                for n in ast.walk(item):
                    if (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                            and n.func.attr == "CONDCrossAttn"):
                        print("FAIL:CONDCrossAttn"); sys.exit(0)

if not found:
    print("FAIL:NewBieImage_missing"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $S4"
if [ "$S4" = "PASS" ]; then add_reward 0.04; fi

# ═══════════════════════════════════════════════════════════════
# S5 (0.03): _forward has >=8 Call nodes (anti-delegation)
# ═══════════════════════════════════════════════════════════════
echo "--- S5/15: _forward complexity ---"
S5=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        tree = ast.parse(f.read())
except Exception:
    print("FAIL:parse"); sys.exit(0)

found = False
for cls in ast.walk(tree):
    if not isinstance(cls, ast.ClassDef):
        continue
    for method in cls.body:
        if isinstance(method, ast.FunctionDef) and method.name == "_forward":
            ncalls = sum(1 for n in ast.walk(method) if isinstance(n, ast.Call))
            found = True
            if ncalls >= 8:
                print("PASS")
            else:
                print(f"FAIL:{ncalls}_calls_need_8")
            sys.exit(0)

if not found:
    print("FAIL:no_forward")
PYEOF
)
echo "  $S5"
if [ "$S5" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════
# BEHAVIORAL TESTS (B1-B10, 0.86 total)
# All in one Python script, each independently scored.
# No conditional gates — each test runs in its own try/except.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "--- Behavioral tests (B1-B10) ---"
BOUT=$(python3 << 'PYEOF'
import sys, ast, inspect
sys.path.insert(0, "/workspace/ComfyUI")

# Critical: torch must be available
try:
    import torch
    import torch.nn as nn
except ImportError as e:
    for i in range(1, 11):
        print(f"B{i}:FAIL:torch_unavailable:{e}")
    sys.exit(0)

try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

try:
    import comfy.ops
    ops = comfy.ops.disable_weight_init
except Exception as e:
    for i in range(1, 11):
        print(f"B{i}:FAIL:comfy_ops:{e}")
    sys.exit(0)

NextDiT = None
newbie_cls = None
model = None
base_model = None

# Import Lumina
try:
    import comfy.ldm.lumina.model as lumina_mod
    NextDiT = lumina_mod.NextDiT
except Exception as e:
    print(f"SETUP_ERR:lumina:{e}")

# Import NewBie
try:
    import comfy.ldm.newbie.model as newbie_mod
except Exception as e:
    newbie_mod = None
    print(f"SETUP_ERR:newbie:{e}")

# Find NewBie subclass of NextDiT
if newbie_mod is not None and NextDiT is not None:
    for _name, _obj in inspect.getmembers(newbie_mod, inspect.isclass):
        if issubclass(_obj, NextDiT) and _obj is not NextDiT:
            newbie_cls = _obj
            break

COMMON_ARGS = dict(
    patch_size=2, in_channels=16, dim=256, n_layers=2,
    n_heads=4, n_kv_heads=2, axes_dims=[32, 32], axes_lens=[32, 32],
    clip_text_dim=256, clip_img_dim=256,
)
BASE_ARGS = {k: v for k, v in COMMON_ARGS.items()
             if k not in ("clip_text_dim", "clip_img_dim")}

def try_instantiate(cls, args):
    for kw in [
        {**args, "operation_settings": {"operations": ops, "device": "cpu", "dtype": None}},
        {**args, "device": "cpu", "dtype": None, "operations": ops},
    ]:
        try:
            return cls(**kw)
        except Exception:
            continue
    return None

def init_weights(m, seed=12345):
    torch.manual_seed(seed)
    with torch.no_grad():
        for p in m.parameters():
            p.normal_(std=0.02)
    m.eval()
    return m

# Pre-instantiate models
if newbie_cls is not None:
    model = try_instantiate(newbie_cls, COMMON_ARGS)
    if model is not None:
        init_weights(model, seed=12345)

if NextDiT is not None:
    base_model = try_instantiate(NextDiT, BASE_ARGS)
    if base_model is not None:
        init_weights(base_model, seed=12345)

n_model_params = sum(1 for _ in model.parameters()) if model is not None else 0
n_base_params = sum(1 for _ in base_model.parameters()) if base_model is not None else 0
has_extra_params = n_model_params > n_base_params + 3

# _forward complexity check (shared precondition for B3-B7)
forward_complex = False
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        _tree = ast.parse(f.read())
    for _c in ast.walk(_tree):
        if isinstance(_c, ast.ClassDef):
            for _m in _c.body:
                if isinstance(_m, ast.FunctionDef) and _m.name == "_forward":
                    _ncalls = sum(1 for _n in ast.walk(_m) if isinstance(_n, ast.Call))
                    forward_complex = _ncalls >= 8
except Exception:
    pass

# Deterministic test inputs
torch.manual_seed(42)
x4 = torch.randn(1, 16, 4, 4)
x8 = torch.randn(1, 16, 8, 8)
ctx = torch.randn(1, 8, 256)
clip_text_a = torch.ones(1, 256) * 0.5
clip_text_b = torch.zeros(1, 256)
clip_img_a = torch.ones(1, 256) * 0.7
clip_img_b = torch.zeros(1, 256)

def fwd_kwargs(clip_text=None, clip_img=None):
    """Build _forward kwargs covering both kwarg and transformer_options paths."""
    kw = {}
    to = {}
    if clip_text is not None:
        kw["clip_text_pooled"] = clip_text
        to["clip_text_pooled"] = clip_text
    if clip_img is not None:
        kw["clip_img_pooled"] = clip_img
        to["clip_img_pooled"] = clip_img
    kw["transformer_options"] = to
    return kw

# ──────────────────────────────────────────────
# B1 (0.05): Import + NextDiT subclass + _forward overridden
# ──────────────────────────────────────────────
try:
    if NextDiT is None:
        raise ValueError("NextDiT import failed")
    if newbie_cls is None:
        raise ValueError("no NextDiT subclass in newbie module")
    if not issubclass(newbie_cls, NextDiT):
        raise ValueError(f"{newbie_cls.__name__} not a NextDiT subclass")
    if "_forward" not in newbie_cls.__dict__:
        raise ValueError("_forward not overridden")
    print("B1:PASS")
except Exception as e:
    print(f"B1:FAIL:{e}")

# ──────────────────────────────────────────────
# B2 (0.05): Instantiate on CPU + >=4 extra params vs base
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("instantiation failed")
    if not isinstance(model, nn.Module):
        raise ValueError(f"not nn.Module: {type(model).__name__}")
    n_extra = n_model_params - n_base_params
    if n_extra < 4:
        raise ValueError(f"{n_extra} extra params, need >=4")
    print("B2:PASS")
except Exception as e:
    print(f"B2:FAIL:{e}")

# ──────────────────────────────────────────────
# B3 (0.12): _forward correct shape (4x4 AND 8x8) + _forward complex
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not forward_complex:
        raise ValueError("_forward too simple (delegation)")

    kw = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
    with torch.no_grad():
        out4 = model._forward(x4, torch.tensor([0.5]), ctx, 8, **kw)
        if out4.shape != x4.shape:
            raise ValueError(f"4x4 shape {list(out4.shape)} != {list(x4.shape)}")
        if out4.abs().max().item() < 1e-6:
            raise ValueError("4x4 output all zeros")

        out8 = model._forward(x8, torch.tensor([0.5]), ctx, 8, **kw)
        if out8.shape != x8.shape:
            raise ValueError(f"8x8 shape {list(out8.shape)} != {list(x8.shape)}")
        if out8.abs().max().item() < 1e-6:
            raise ValueError("8x8 output all zeros")

    print("B3:PASS")
except Exception as e:
    print(f"B3:FAIL:{e}")

# ──────────────────────────────────────────────
# B4 (0.08): F2P: return -img at ts=0.3 (unpatchify hook)
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not forward_complex:
        raise ValueError("_forward too simple")

    orig_up = model.unpatchify
    captured = {}

    def hook_up(*a, **kw):
        r = orig_up(*a, **kw)
        captured["v"] = r.clone().detach()
        return r

    model.unpatchify = hook_up
    try:
        kw = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        with torch.no_grad():
            result = model._forward(x4, torch.tensor([0.3]), ctx, 8, **kw)
    finally:
        model.unpatchify = orig_up

    if "v" not in captured:
        raise ValueError("unpatchify never called")
    h, w = x4.shape[2], x4.shape[3]
    up_sliced = captured["v"][:, :, :h, :w]
    residual = (result + up_sliced).abs().max().item()
    if residual > 0.01:
        raise ValueError(f"residual={residual:.4f}, want ~0 (missing -img)")
    print("B4:PASS")
except Exception as e:
    print(f"B4:FAIL:{e}")

# ──────────────────────────────────────────────
# B5 (0.08): F2P: return -img at ts=0.7 (varied input)
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not forward_complex:
        raise ValueError("_forward too simple")

    orig_up = model.unpatchify
    captured = {}

    def hook_up(*a, **kw):
        r = orig_up(*a, **kw)
        captured["v"] = r.clone().detach()
        return r

    model.unpatchify = hook_up
    try:
        kw = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        with torch.no_grad():
            result = model._forward(x4, torch.tensor([0.7]), ctx, 8, **kw)
    finally:
        model.unpatchify = orig_up

    if "v" not in captured:
        raise ValueError("unpatchify never called")
    h, w = x4.shape[2], x4.shape[3]
    up_sliced = captured["v"][:, :, :h, :w]
    residual = (result + up_sliced).abs().max().item()
    if residual > 0.01:
        raise ValueError(f"residual={residual:.4f}, want ~0 (missing -img)")
    print("B5:PASS")
except Exception as e:
    print(f"B5:FAIL:{e}")

# ──────────────────────────────────────────────
# B6 (0.08): F2P: t = 1.0 - timesteps at ts=0.3 -> t_embedder sees 0.7
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not forward_complex:
        raise ValueError("_forward too simple")

    captured_t = {}

    def t_hook(module, args):
        if args:
            captured_t["v"] = args[0].clone().detach()

    handle = model.t_embedder.register_forward_pre_hook(t_hook)
    try:
        kw = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        with torch.no_grad():
            model._forward(x4, torch.tensor([0.3]), ctx, 8, **kw)
    finally:
        handle.remove()

    if "v" not in captured_t:
        raise ValueError("t_embedder never called")
    got = captured_t["v"].float().item()
    if abs(got - 0.7) > 0.01:
        raise ValueError(f"t_embedder got {got:.3f}, want 0.7")
    print("B6:PASS")
except Exception as e:
    print(f"B6:FAIL:{e}")

# ──────────────────────────────────────────────
# B7 (0.08): F2P: t = 1.0 - timesteps at ts=0.8 -> t_embedder sees 0.2
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not forward_complex:
        raise ValueError("_forward too simple")

    captured_t = {}

    def t_hook(module, args):
        if args:
            captured_t["v"] = args[0].clone().detach()

    handle = model.t_embedder.register_forward_pre_hook(t_hook)
    try:
        kw = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        with torch.no_grad():
            model._forward(x4, torch.tensor([0.8]), ctx, 8, **kw)
    finally:
        handle.remove()

    if "v" not in captured_t:
        raise ValueError("t_embedder never called")
    got = captured_t["v"].float().item()
    if abs(got - 0.2) > 0.01:
        raise ValueError(f"t_embedder got {got:.3f}, want 0.2")
    print("B7:PASS")
except Exception as e:
    print(f"B7:FAIL:{e}")

# ──────────────────────────────────────────────
# B8 (0.12): clip_text_pooled influences output
#   Vary clip_text while holding clip_img constant.
#   Uses two different clip values (not absent vs present) to avoid
#   crashes in implementations that require clip kwargs.
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not has_extra_params:
        raise ValueError("no extra params (delegation)")

    with torch.no_grad():
        kw_a = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        out_a = model._forward(x4, torch.tensor([0.5]), ctx, 8, **kw_a)

        kw_b = fwd_kwargs(clip_text=clip_text_b, clip_img=clip_img_a)
        out_b = model._forward(x4, torch.tensor([0.5]), ctx, 8, **kw_b)

    diff = (out_a - out_b).abs().max().item()
    if diff < 1e-6:
        raise ValueError(f"no clip_text influence (diff={diff:.8f})")
    print("B8:PASS")
except Exception as e:
    print(f"B8:FAIL:{e}")

# ──────────────────────────────────────────────
# B9 (0.12): clip_img_pooled influences output
#   Vary clip_img while holding clip_text constant.
# ──────────────────────────────────────────────
try:
    if model is None:
        raise ValueError("model not available")
    if not has_extra_params:
        raise ValueError("no extra params (delegation)")

    with torch.no_grad():
        kw_a = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_a)
        out_a = model._forward(x4, torch.tensor([0.5]), ctx, 8, **kw_a)

        kw_b = fwd_kwargs(clip_text=clip_text_a, clip_img=clip_img_b)
        out_b = model._forward(x4, torch.tensor([0.5]), ctx, 8, **kw_b)

    diff = (out_a - out_b).abs().max().item()
    if diff < 1e-6:
        raise ValueError(f"no clip_img influence (diff={diff:.8f})")
    print("B9:PASS")
except Exception as e:
    print(f"B9:FAIL:{e}")

# ──────────────────────────────────────────────
# B10 (0.08): P2P: Base NextDiT still works
# ──────────────────────────────────────────────
try:
    if base_model is None:
        raise ValueError("base instantiation failed")

    with torch.no_grad():
        base_out = base_model._forward(x4, torch.tensor([0.5]), ctx, 8,
                                       transformer_options={})

    if not isinstance(base_out, torch.Tensor):
        raise ValueError(f"not tensor: {type(base_out).__name__}")
    if base_out.shape != x4.shape:
        raise ValueError(f"shape {list(base_out.shape)} != {list(x4.shape)}")
    if base_out.abs().max().item() < 1e-8:
        raise ValueError("all zeros")
    print("B10:PASS")
except Exception as e:
    print(f"B10:FAIL:{e}")
PYEOF
)
echo "$BOUT"

# Parse behavioral results and add rewards
echo "$BOUT" | grep -q "^B1:PASS" && add_reward 0.05
echo "$BOUT" | grep -q "^B2:PASS" && add_reward 0.05
echo "$BOUT" | grep -q "^B3:PASS" && add_reward 0.12
echo "$BOUT" | grep -q "^B4:PASS" && add_reward 0.08
echo "$BOUT" | grep -q "^B5:PASS" && add_reward 0.08
echo "$BOUT" | grep -q "^B6:PASS" && add_reward 0.08
echo "$BOUT" | grep -q "^B7:PASS" && add_reward 0.08
echo "$BOUT" | grep -q "^B8:PASS" && add_reward 0.12
echo "$BOUT" | grep -q "^B9:PASS" && add_reward 0.12
echo "$BOUT" | grep -q "^B10:PASS" && add_reward 0.08

# ═══════════════════════════════════════════════════════════════
# P2P UPSTREAM: Run ComfyUI's own CPU-safe unit tests (bonus 0.05)
# Uses tests-unit/ (pure unit tests), NOT tests/ (integration
# tests that require websocket-client and a running server).
# Note: preview_method_override_test.py does not exist at this commit.
# ═══════════════════════════════════════════════════════════════
echo ""
echo "=== P2P Upstream: ComfyUI unit tests ==="
cd /workspace/ComfyUI
UP_RESULT=$(python3 -m pytest \
    tests-unit/utils/json_util_test.py \
    tests-unit/feature_flags_test.py \
    tests-unit/execution_test/validate_node_input_test.py \
    tests-unit/comfy_test/folder_path_test.py \
    tests-unit/folder_paths_test/misc_test.py \
    tests-unit/folder_paths_test/filter_by_content_types_test.py \
    tests-unit/folder_paths_test/system_user_test.py \
    tests-unit/websocket_feature_flags_test.py \
    tests-unit/utils/extra_config_test.py \
    -x --timeout=60 -q 2>&1)
UP_EXIT=$?
echo "$UP_RESULT" | tail -5
if [ $UP_EXIT -eq 0 ]; then
    echo "  PASS: upstream unit tests pass"
    add_reward 0.05
else
    echo "  FAIL: upstream unit tests failed (exit=$UP_EXIT)"
fi

# ═══════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Score: $PASS_COUNT/$TOTAL tests passed"
echo "Reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
