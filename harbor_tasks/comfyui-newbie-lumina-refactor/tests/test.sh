#!/usr/bin/env bash
#
# Verification tests for ComfyUI NewBie architecture refactoring.
#
# Scoring: 85% behavioral (F2P/P2P/Silver), 15% structural (absence/AST)
#
#   Structural (0.15):
#     T1 (0.03): Valid Python + class definition
#     T2 (0.04): No _pop_unexpected_kwargs AND no _fallback_operations
#     T3 (0.04): No nn.init in __init__ AND no try/except in _forward
#     T4 (0.04): model_base.py: no apply_model override + no CONDCrossAttn
#
#   Pass-to-Pass (0.10):
#     P2P (0.10): Base NextDiT still instantiates + produces valid output on CPU
#
#   Behavioral (0.75) compound with gate:
#     Gate: _forward overridden in class + >=8 Call nodes (anti-stub)
#     Part A (0.10): Import + instantiate on CPU + extra params vs base NextDiT
#     Part B (0.25): F2P: return -img verified via unpatchify monkey-patch
#     Part C (0.15): F2P: t = 1.0 - timesteps verified via t_embedder pre-hook
#     Part D (0.10): _forward returns tensor, correct shape, not trivially ±x
#     Part E (0.15): clip_text_pooled influences _forward output
#
# Max stub score: 0.25 (structural 0.15 + P2P 0.10; gate blocks Parts A-E)
# P2P: NextDiT base regression (agent might break lumina/model.py while refactoring)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# T1 (0.03): Valid Python with at least one class
# ═══════════════════════════════════════════════════════════════════
echo "=== T1: Valid Python + class ==="
T1=$(python3 << 'PYEOF'
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
echo "  $T1"
[ "$T1" = "PASS" ] && add_reward 0.03

# ═══════════════════════════════════════════════════════════════════
# T2 (0.04): No _pop_unexpected_kwargs AND no _fallback_operations
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: No anti-pattern helpers ==="
T2=$(python3 << 'PYEOF'
import sys, ast
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        tree = ast.parse(f.read())
except Exception:
    print("FAIL:parse"); sys.exit(0)

bad = {"_pop_unexpected_kwargs", "_fallback_operations"}
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in bad:
        print(f"FAIL:{node.name}_defined"); sys.exit(0)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in bad:
        print(f"FAIL:{node.func.id}_called"); sys.exit(0)
print("PASS")
PYEOF
)
echo "  $T2"
[ "$T2" = "PASS" ] && add_reward 0.04

# ═══════════════════════════════════════════════════════════════════
# T3 (0.04): No nn.init in __init__ AND no try/except in _forward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: No nn.init + no try/except ==="
T3=$(python3 << 'PYEOF'
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
        if not isinstance(method, ast.FunctionDef):
            continue
        if method.name == "__init__":
            for n in ast.walk(method):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute):
                    v = n.func.value
                    if (isinstance(v, ast.Attribute) and isinstance(v.value, ast.Name)
                            and v.value.id == "nn" and v.attr == "init"):
                        print(f"FAIL:nn_init_{n.func.attr}")
                        sys.exit(0)
        if method.name == "_forward":
            for n in ast.walk(method):
                if isinstance(n, ast.Try):
                    print("FAIL:try_except_in_forward")
                    sys.exit(0)
print("PASS")
PYEOF
)
echo "  $T3"
[ "$T3" = "PASS" ] && add_reward 0.04

# ═══════════════════════════════════════════════════════════════════
# T4 (0.04): model_base.py — no apply_model + no CONDCrossAttn in NewBieImage
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: model_base.py fixes ==="
T4=$(python3 << 'PYEOF'
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
echo "  $T4"
[ "$T4" = "PASS" ] && add_reward 0.04

# ═══════════════════════════════════════════════════════════════════
# P2P (0.10): Base NextDiT still functional after agent changes
#   Catches regressions if agent accidentally breaks lumina/model.py
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== P2P: Base NextDiT regression ==="
P2P=$(python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/ComfyUI")

try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

import torch
import comfy.ops

ops = comfy.ops.disable_weight_init
base = None
base_args = dict(
    patch_size=2, in_channels=16, dim=256, n_layers=2,
    n_heads=4, n_kv_heads=2, axes_dims=[32, 32], axes_lens=[32, 32],
)

# Try both calling conventions (operation_settings dict vs separate kwargs)
for kw in [
    {**base_args, "operation_settings": {"operations": ops, "device": "cpu", "dtype": None}},
    {**base_args, "device": "cpu", "dtype": None, "operations": ops},
]:
    try:
        import comfy.ldm.lumina.model as lumina_mod
        base = lumina_mod.NextDiT(**kw)
        break
    except Exception:
        base = None

if base is None:
    print("FAIL:instantiation")
    sys.exit(0)

# Init weights deterministically
torch.manual_seed(99)
with torch.no_grad():
    for p in base.parameters():
        p.normal_(std=0.02)
base.eval()

# Run forward pass — must produce valid tensor of correct shape
x = torch.randn(1, 16, 4, 4)
ts = torch.tensor([0.5])
ctx = torch.randn(1, 8, 256)

try:
    with torch.no_grad():
        out = base._forward(x, ts, ctx, 8, transformer_options={})
    if not isinstance(out, torch.Tensor):
        print(f"FAIL:not_tensor:{type(out).__name__}")
    elif out.shape != x.shape:
        print(f"FAIL:shape:{list(out.shape)}")
    elif out.abs().max().item() < 1e-8:
        print("FAIL:all_zeros")
    else:
        print("PASS")
except Exception as e:
    print(f"FAIL:forward:{e}")
PYEOF
)
echo "  $P2P"
[ "$P2P" = "PASS" ] && add_reward 0.10

# ═══════════════════════════════════════════════════════════════════
# BEHAVIORAL COMPOUND (0.75): Parts A-E with anti-stub gate
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Behavioral compound (0.75) ==="
BSCORE=$(python3 << 'PYEOF'
import sys, os, ast, inspect
sys.path.insert(0, "/workspace/ComfyUI")

# CPU-safe import
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass

score = 0.0

# ──────────────────────────────────────────────
# GATE: import, find NextDiT subclass, verify _forward is overridden + non-trivial
# ──────────────────────────────────────────────
print("  Gate: import + validate...")
try:
    import comfy.ldm.newbie.model as newbie_mod
    import comfy.ldm.lumina.model as lumina_mod
    NextDiT = lumina_mod.NextDiT
except Exception as e:
    print(f"  Gate FAIL (import: {e})")
    print(f"SCORE:{score:.2f}"); sys.exit(0)

newbie_cls = None
for name, obj in inspect.getmembers(newbie_mod, inspect.isclass):
    if issubclass(obj, NextDiT) and obj is not NextDiT:
        newbie_cls = obj
        break

if newbie_cls is None:
    print("  Gate FAIL (no NextDiT subclass)")
    print(f"SCORE:{score:.2f}"); sys.exit(0)

if "_forward" not in newbie_cls.__dict__:
    print("  Gate FAIL (_forward not overridden — bare subclass)")
    print(f"SCORE:{score:.2f}"); sys.exit(0)

# Anti-stub: _forward needs >= 8 Call nodes (real impls have dozens)
try:
    with open("/workspace/ComfyUI/comfy/ldm/newbie/model.py") as f:
        _tree = ast.parse(f.read())
    for _c in ast.walk(_tree):
        if isinstance(_c, ast.ClassDef):
            for _m in _c.body:
                if isinstance(_m, ast.FunctionDef) and _m.name == "_forward":
                    ncalls = sum(1 for n in ast.walk(_m) if isinstance(n, ast.Call))
                    if ncalls < 8:
                        print(f"  Gate FAIL (_forward has {ncalls} calls, need >= 8)")
                        print(f"SCORE:{score:.2f}"); sys.exit(0)
except Exception:
    pass

print(f"  Gate PASS ({newbie_cls.__name__})")

# ──────────────────────────────────────────────
# Part A (0.10): Instantiate on CPU + extra params beyond base NextDiT
# ──────────────────────────────────────────────
print("  Part A: instantiate...")
import torch
import torch.nn as nn
import comfy.ops

ops = comfy.ops.disable_weight_init
model = None

common_args = dict(
    patch_size=2, in_channels=16, dim=256, n_layers=2,
    n_heads=4, n_kv_heads=2, axes_dims=[32, 32], axes_lens=[32, 32],
    clip_text_dim=256, clip_img_dim=256,
)

# Try both calling conventions (operation_settings dict vs separate kwargs)
for kw in [
    {**common_args, "operation_settings": {"operations": ops, "device": "cpu", "dtype": None}},
    {**common_args, "device": "cpu", "dtype": None, "operations": ops},
]:
    try:
        model = newbie_cls(**kw)
        break
    except Exception:
        model = None

if model is None or not isinstance(model, nn.Module):
    print("  Part A: FAIL (instantiation)")
    print(f"SCORE:{score:.2f}"); sys.exit(0)

# Verify model adds params beyond bare NextDiT (rejects empty subclasses)
try:
    base_args = {k: v for k, v in common_args.items() if k not in ("clip_text_dim", "clip_img_dim")}
    base = None
    for kw in [
        {**base_args, "operation_settings": {"operations": ops, "device": "cpu", "dtype": None}},
        {**base_args, "device": "cpu", "dtype": None, "operations": ops},
    ]:
        try:
            base = NextDiT(**kw)
            break
        except Exception:
            base = None

    if base is not None:
        extra = set(dict(model.named_parameters())) - set(dict(base.named_parameters()))
        if len(extra) < 4:
            print(f"  Part A: FAIL ({len(extra)} extra params, need >= 4)")
            print(f"SCORE:{score:.2f}"); sys.exit(0)
        del base
except Exception:
    pass  # skip comparison if base instantiation fails

# Initialize weights for deterministic testing (disable_weight_init skips init)
torch.manual_seed(12345)
with torch.no_grad():
    for p in model.parameters():
        p.normal_(std=0.02)

score += 0.10
print("  Part A: PASS")
model.eval()

# Shared test inputs
x = torch.randn(1, 16, 4, 4)
ts = torch.tensor([0.3])
ctx = torch.randn(1, 8, 256)

# ──────────────────────────────────────────────
# Part B (0.25): F2P — return -img via unpatchify monkey-patch
#   Fixed: result = -unpatchified[:,:,:h,:w] → result + captured ≈ 0
#   Buggy: result = +unpatchified[:,:,:h,:w] → result + captured ≈ 2·captured
# ──────────────────────────────────────────────
print("  Part B: F2P return -img...")
orig_unpatchify = model.unpatchify
try:
    captured_up = {}

    def _hook_up(*args, **kwargs):
        r = orig_unpatchify(*args, **kwargs)
        captured_up["v"] = r.clone().detach()
        return r

    model.unpatchify = _hook_up
    with torch.no_grad():
        result_b = model._forward(x, ts, ctx, 8, transformer_options={})

    if "v" not in captured_up:
        print("  Part B: FAIL (unpatchify never called)")
    else:
        h, w = x.shape[2], x.shape[3]
        up_sliced = captured_up["v"][:, :, :h, :w]
        residual = (result_b + up_sliced).abs().max().item()
        if residual < 0.01:
            score += 0.25
            print(f"  Part B: PASS (residual={residual:.6f})")
        else:
            print(f"  Part B: FAIL (residual={residual:.4f}, want ~0)")
except Exception as e:
    print(f"  Part B: FAIL ({e})")
finally:
    model.unpatchify = orig_unpatchify

# ──────────────────────────────────────────────
# Part C (0.15): F2P — t = 1.0 - timesteps via t_embedder pre-hook
#   Fixed: t_embedder receives 1.0 - 0.3 = 0.7
#   Buggy: t_embedder receives 0.3
# ──────────────────────────────────────────────
print("  Part C: F2P t = 1.0 - timesteps...")
captured_t = {}

def _t_pre_hook(module, args):
    if args:
        captured_t["v"] = args[0].clone().detach()

handle_t = model.t_embedder.register_forward_pre_hook(_t_pre_hook)
try:
    with torch.no_grad():
        model._forward(x, torch.tensor([0.3]), ctx, 8, transformer_options={})

    if "v" not in captured_t:
        print("  Part C: FAIL (t_embedder never called)")
    else:
        got = captured_t["v"].float().item()
        want = 0.7  # 1.0 - 0.3
        if abs(got - want) < 0.01:
            score += 0.15
            print(f"  Part C: PASS (t_embedder input={got:.3f}, want={want:.3f})")
        else:
            print(f"  Part C: FAIL (t_embedder input={got:.3f}, want={want:.3f})")
except Exception as e:
    print(f"  Part C: FAIL ({e})")
finally:
    handle_t.remove()

# ──────────────────────────────────────────────
# Part D (0.10): _forward returns tensor with correct shape, not trivially ±x
# ──────────────────────────────────────────────
print("  Part D: output quality...")
try:
    with torch.no_grad():
        out_d = model._forward(x, ts, ctx, 8, transformer_options={})

    if not isinstance(out_d, torch.Tensor):
        print(f"  Part D: FAIL (not tensor: {type(out_d).__name__})")
    elif out_d.shape != x.shape:
        print(f"  Part D: FAIL (shape {list(out_d.shape)} != {list(x.shape)})")
    elif out_d.abs().max().item() < 1e-6:
        print("  Part D: FAIL (all zeros)")
    else:
        cos = torch.nn.functional.cosine_similarity(
            out_d.flatten().float(), x.flatten().float(), dim=0
        ).abs().item()
        if cos > 0.99:
            print(f"  Part D: FAIL (trivially ±x, cos_sim={cos:.4f})")
        else:
            score += 0.10
            print(f"  Part D: PASS (shape OK, cos_sim={cos:.4f})")
except Exception as e:
    print(f"  Part D: FAIL ({e})")

# ──────────────────────────────────────────────
# Part E (0.15): clip_text_pooled influences _forward output
#   Rejects bare NextDiT inheritance (Lumina base doesn't process clip)
# ──────────────────────────────────────────────
print("  Part E: clip influence...")
try:
    clip_val = torch.ones(1, 256) * 0.5

    with torch.no_grad():
        # Pass clip through both kwargs and transformer_options (covers multiple impls)
        out_clip = model._forward(
            x, ts, ctx, 8,
            clip_text_pooled=clip_val,
            transformer_options={
                "clip_text_pooled": clip_val,
                "extra_cond": {"clip_text_pooled": clip_val},
            },
        )
        out_noclip = model._forward(
            x, ts, ctx, 8,
            transformer_options={},
        )

    diff = (out_clip - out_noclip).abs().max().item()
    if diff > 1e-6:
        score += 0.15
        print(f"  Part E: PASS (clip influence diff={diff:.6f})")
    else:
        print(f"  Part E: FAIL (no influence, diff={diff:.8f})")
except Exception as e:
    print(f"  Part E: FAIL ({e})")

print(f"SCORE:{score:.2f}")
PYEOF
)
echo "$BSCORE"
BVAL=$(echo "$BSCORE" | grep -oP 'SCORE:\K[0-9.]+' | tail -1)
[ -n "$BVAL" ] && [ "$BVAL" != "0.00" ] && add_reward "$BVAL"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
