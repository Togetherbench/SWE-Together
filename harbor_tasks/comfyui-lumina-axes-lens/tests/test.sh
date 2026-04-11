#!/usr/bin/env bash
#
# Verification tests for ComfyUI Lumina 2 axes_lens RoPE implementation.
#
# Tests verify comfy/ldm/lumina/model.py has been updated to:
#   1. Define a new class that accepts axes_lens and uses it for RoPE
#   2. Wire NextDiT to use the new class with axes_lens
#   3. Produce numerically correct output matching EmbedND reference
#   4. Actually precompute and use axes_lens (not just store it)
#
# All tests run on CPU — no GPU required.
# Reward written to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring (P2P 4%, F2P-structural 9%, F2P-behavioral 87%, total=1.00):
#   T1:  0.01  model.py parses as valid Python (structural, P2P)
#   T2:  0.03  new class with axes_lens + forward (structural, F2P)
#   T3:  0.02  class has >=8 meaningful AST statements (structural, F2P)
#   T4:  0.03  NextDiT passes axes_lens to rope_embedder (structural, F2P)
#   T5:  0.04  instantiate config A (behavioral, F2P)
#   T6:  0.04  instantiate config B — varied params (behavioral, F2P)
#   T7:  0.06  forward shape matches EmbedND (behavioral, F2P)
#   T8:  0.05  forward values finite, in [-1,1], not zeros (behavioral, F2P)
#   T9:  0.13  sequential positions match EmbedND (behavioral, F2P)
#   T10: 0.12  non-sequential positions match EmbedND (behavioral, F2P)
#   T11: 0.08  config B match EmbedND — different axes_dim (behavioral, F2P)
#   T13: 0.08  different axes_lens -> different state (behavioral, F2P)
#   T15: 0.12  varied inputs: single + batch of 8 both correct (behavioral, F2P)
#   T16: 0.15  forward is pure: no mutation + deterministic (behavioral, F2P)
#   P2P: 0.04  EmbedND + NextDiT upstream functionality (P2P)
#
# Removed: T12 (0.04, precomputed state) and T14 (0.06, OOB divergence)
# rewarded mutually exclusive implementation strategies (precompute vs on-the-fly).
# Their 0.10 weight redistributed to T9 (+0.04), T10 (+0.03), T15 (+0.03).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0
MODEL_PY="/workspace/ComfyUI/comfy/ldm/lumina/model.py"

# Activate virtual environment (torch, einops installed here)
export PATH="/workspace/venv/bin:$PATH"

# Patch model_management.py for CPU-only environments to prevent
# "Torch not compiled with CUDA enabled" errors on comfy.* imports
sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    /workspace/ComfyUI/comfy/model_management.py 2>/dev/null || true

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ---- Shared mock for comfy.model_management (CPU-only) ----
cat > /tmp/_mock_mm.py << 'MOCKEOF'
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")
# Force CPU mode before any comfy imports to prevent CUDA errors
try:
    import comfy.cli_args
    comfy.cli_args.args.cpu = True
except Exception:
    pass
mm = types.ModuleType("comfy.model_management")
mm.get_torch_device = lambda: torch.device("cpu")
mm.is_device_mps = lambda d: False
mm.is_intel_xpu = lambda: False
mm.is_directml_enabled = lambda: False
mm.is_nvidia = lambda: False
mm.xformers_enabled = lambda: False
mm.pytorch_attention_enabled = lambda: True
mm.flash_attention_enabled = lambda: False
mm.sage_attention_enabled = lambda: False
mm.force_upcast_attention_dtype = lambda: None
mm.OOM_EXCEPTION = Exception
mm.soft_empty_cache = lambda *a, **kw: None
mm.get_free_memory = lambda *a, **kw: 4 * 1024**3
mm.throw_exception_if_processing_interrupted = lambda: None
mm.total_vram = 0
mm.total_ram = 8192
mm.cast_to = None
mm.unet_offload_device = lambda: torch.device("cpu")
mm.unet_inital_load_device = lambda *a: torch.device("cpu")
sys.modules["comfy.model_management"] = mm
import comfy
comfy.model_management = mm
MOCKEOF

# ---- Shared class discovery helper ----
cat > /tmp/_discover.py << 'DISCEOF'
import inspect, torch
import comfy.ldm.lumina.model as _lm
from comfy.ldm.flux.layers import EmbedND as _EmbedND
_SKIP = {"NextDiT","JointAttention","FinalLayer","FeedForward",
         "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
         "ModulationOut","Modulation"}
_cls = _cls_name = None
for _n, _o in inspect.getmembers(_lm, inspect.isclass):
    if _n in _SKIP: continue
    try:
        if "axes_lens" in inspect.signature(_o.__init__).parameters:
            _cls, _cls_name = _o, _n; break
    except: pass
DISCEOF

# ====================================================================
# STRUCTURAL TESTS (4 tests, 0.09 total)
# ====================================================================

echo "=== T1: model.py parses as valid Python ==="
T1=$(python3 << 'PYEOF'
import ast
try:
    ast.parse(open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read())
    print("PASS")
except SyntaxError as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.01; fi

echo ""
echo "=== T2: New class with axes_lens + forward ==="
T2=$(python3 << 'PYEOF'
import ast
source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)
SKIP = {"NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}
def _has_al_fw(node):
    al = fw = False
    for child in node.body:
        if isinstance(child, ast.FunctionDef) and child.name == "__init__":
            params = [a.arg for a in child.args.args] + [a.arg for a in child.args.kwonlyargs]
            al = any("axes_lens" in p for p in params)
        if isinstance(child, ast.FunctionDef) and child.name == "forward":
            fw = True
    return al and fw
for node in ast.iter_child_nodes(tree):
    if isinstance(node, ast.ClassDef) and node.name not in SKIP and _has_al_fw(node):
        print(f"PASS:{node.name}"); exit()
# Fallback: class defined elsewhere but imported into model.py
try:
    exec(open("/tmp/_mock_mm.py").read())
    exec(open("/tmp/_discover.py").read())
    if _cls is not None:
        import inspect as _insp
        _sf = _insp.getfile(_cls)
        _t = ast.parse(open(_sf).read())
        for _n in ast.iter_child_nodes(_t):
            if isinstance(_n, ast.ClassDef) and _n.name == _cls_name and _has_al_fw(_n):
                print(f"PASS:{_cls_name}"); exit()
except Exception:
    pass
print("FAIL")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.03; fi

echo ""
echo "=== T3: Class has >=8 meaningful AST statements ==="
T3=$(python3 << 'PYEOF'
import ast
source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)
SKIP = {"NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}
def _count_stmts(node):
    al = fw = False
    for child in node.body:
        if isinstance(child, ast.FunctionDef) and child.name == "__init__":
            params = [a.arg for a in child.args.args] + [a.arg for a in child.args.kwonlyargs]
            al = any("axes_lens" in p for p in params)
        if isinstance(child, ast.FunctionDef) and child.name == "forward":
            fw = True
    if not (al and fw):
        return None
    return sum(1 for c in ast.walk(node) if isinstance(c, (
        ast.Assign, ast.AugAssign, ast.AnnAssign, ast.If, ast.For,
        ast.While, ast.With, ast.Return, ast.Call, ast.FunctionDef)))
for node in ast.iter_child_nodes(tree):
    if not isinstance(node, ast.ClassDef) or node.name in SKIP:
        continue
    count = _count_stmts(node)
    if count is not None:
        if count >= 8:
            print(f"PASS:{node.name}:{count}_stmts"); exit()
        else:
            print(f"FAIL:{node.name}:{count}_stmts<8"); exit()
# Fallback: class defined elsewhere but imported into model.py
try:
    exec(open("/tmp/_mock_mm.py").read())
    exec(open("/tmp/_discover.py").read())
    if _cls is not None:
        import inspect as _insp
        _sf = _insp.getfile(_cls)
        _t = ast.parse(open(_sf).read())
        for _n in ast.iter_child_nodes(_t):
            if isinstance(_n, ast.ClassDef) and _n.name == _cls_name:
                count = _count_stmts(_n)
                if count is not None:
                    if count >= 8:
                        print(f"PASS:{_cls_name}:{count}_stmts"); exit()
                    else:
                        print(f"FAIL:{_cls_name}:{count}_stmts<8"); exit()
except Exception:
    pass
print("FAIL:no_class")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.02; fi

echo ""
echo "=== T4: NextDiT passes axes_lens to rope_embedder ==="
T4=$(python3 << 'PYEOF'
import ast, sys
source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)
for node in ast.iter_child_nodes(tree):
    if not (isinstance(node, ast.ClassDef) and node.name == "NextDiT"):
        continue
    for child in node.body:
        if not (isinstance(child, ast.FunctionDef) and child.name == "__init__"):
            continue
        for n in ast.walk(child):
            if isinstance(n, ast.Assign):
                for t in n.targets:
                    if isinstance(t, ast.Attribute) and t.attr == "rope_embedder":
                        if isinstance(n.value, ast.Call):
                            src = ast.get_source_segment(source, n.value) or ""
                            if "axes_lens" in src:
                                print("PASS"); sys.exit(0)
                            print("FAIL:no_axes_lens_in_call"); sys.exit(0)
print("FAIL:no_rope_embedder")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.03; fi

# ====================================================================
# BEHAVIORAL TESTS (10 tests, 0.87 total)
# ====================================================================

echo ""
echo "=== T5: Instantiate config A (dim=32, axes_dim=[8,8,16], axes_lens=[10,20,20]) ==="
T5=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
    print(f"PASS:{_cls_name}")
except Exception as e:
    print(f"FAIL:init:{e}")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.04; fi

echo ""
echo "=== T6: Instantiate config B (dim=64, theta=256, axes_dim=[16,16,32], axes_lens=[5,10,10]) ==="
T6=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=64, theta=256, axes_dim=[16,16,32], axes_lens=[5,10,10])
    print(f"PASS:{_cls_name}")
except Exception as e:
    print(f"FAIL:init:{e}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.04; fi

echo ""
echo "=== T7: Forward shape matches EmbedND ==="
T7=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=32, theta=10000, axes_dim=[8,8,16])
ids = torch.zeros(1, 5, 3, dtype=torch.float32)
for i in range(5):
    ids[0, i, :] = float(i)
try:
    with torch.no_grad():
        out = inst(ids.clone())
        ref_out = ref(ids.clone())
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
if not isinstance(out, torch.Tensor):
    print("FAIL:not_tensor"); exit()
if out.shape != ref_out.shape:
    print(f"FAIL:shape:{list(out.shape)}!={list(ref_out.shape)}"); exit()
print(f"PASS:{list(out.shape)}")
PYEOF
)
echo "  Result: $T7"
if [[ "$T7" == PASS* ]]; then add_reward 0.06; fi

echo ""
echo "=== T8: Forward values finite, in [-1,1], not zeros ==="
T8=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ids = torch.tensor([[[0.0,1.0,2.0],[3.0,4.0,5.0],[1.0,0.0,3.0]]])
try:
    with torch.no_grad():
        out = inst(ids.clone())
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
if not isinstance(out, torch.Tensor):
    print("FAIL:not_tensor"); exit()
if not torch.isfinite(out).all():
    print("FAIL:non_finite"); exit()
if out.abs().max() > 1.0 + 1e-6:
    print(f"FAIL:range:{out.abs().max().item():.4f}>1"); exit()
if torch.all(out == 0):
    print("FAIL:all_zeros"); exit()
print("PASS")
PYEOF
)
echo "  Result: $T8"
if [[ "$T8" == PASS* ]]; then add_reward 0.05; fi

echo ""
echo "=== T9: Sequential positions match EmbedND ==="
T9=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=32, theta=10000, axes_dim=[8,8,16])
ids = torch.zeros(1, 5, 3, dtype=torch.float32)
for i in range(5):
    ids[0, i, :] = float(i)
try:
    with torch.no_grad():
        out = inst(ids.clone())
        ref_out = ref(ids.clone())
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
if out.shape != ref_out.shape:
    print(f"FAIL:shape:{list(out.shape)}!={list(ref_out.shape)}"); exit()
if not torch.allclose(out, ref_out, atol=1e-4, rtol=1e-4):
    d = (out - ref_out).abs().max().item()
    print(f"FAIL:values:max_diff={d:.6f}"); exit()
print("PASS")
PYEOF
)
echo "  Result: $T9"
if [[ "$T9" == PASS* ]]; then add_reward 0.13; fi

echo ""
echo "=== T10: Non-sequential positions match EmbedND ==="
T10=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=32, theta=10000, axes_dim=[8,8,16])
ids = torch.tensor([[[0.0, 2.0, 4.0],
                      [1.0, 3.0, 0.0],
                      [0.0, 1.0, 3.0],
                      [4.0, 0.0, 2.0]]])
try:
    with torch.no_grad():
        out = inst(ids.clone())
        ref_out = ref(ids.clone())
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
if out.shape != ref_out.shape:
    print(f"FAIL:shape"); exit()
if not torch.allclose(out, ref_out, atol=1e-4, rtol=1e-4):
    d = (out - ref_out).abs().max().item()
    print(f"FAIL:values:max_diff={d:.6f}"); exit()
print("PASS")
PYEOF
)
echo "  Result: $T10"
if [[ "$T10" == PASS* ]]; then add_reward 0.12; fi

echo ""
echo "=== T11: Config B match EmbedND (dim=64, axes_dim=[16,16,32]) ==="
T11=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=64, theta=256, axes_dim=[16,16,32], axes_lens=[5,10,10])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=64, theta=256, axes_dim=[16,16,32])
ids = torch.tensor([[[0.0, 1.0, 2.0],
                      [2.0, 3.0, 0.0],
                      [4.0, 9.0, 8.0]]])
try:
    with torch.no_grad():
        out = inst(ids.clone())
        ref_out = ref(ids.clone())
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
if out.shape != ref_out.shape:
    print(f"FAIL:shape:{list(out.shape)}!={list(ref_out.shape)}"); exit()
if not torch.allclose(out, ref_out, atol=1e-4, rtol=1e-4):
    d = (out - ref_out).abs().max().item()
    print(f"FAIL:values:max_diff={d:.6f}"); exit()
print("PASS")
PYEOF
)
echo "  Result: $T11"
if [[ "$T11" == PASS* ]]; then add_reward 0.08; fi

echo ""
echo "=== T13: Different axes_lens -> different internal state ==="
T13=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst_a = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
    inst_b = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[5,10,10])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()

def get_state(m):
    s = {}
    for k, v in m.named_buffers():
        if v.numel() > 1: s[f"b:{k}"] = v
    for k, v in m.named_parameters():
        if v.numel() > 1: s[f"p:{k}"] = v
    for k, v in vars(m).items():
        if isinstance(v, torch.Tensor) and v.numel() > 10:
            s[f"a:{k}"] = v
    return s

sa, sb = get_state(inst_a), get_state(inst_b)
if not sa and not sb:
    # No internal state — try boundary behavior
    mid = torch.tensor([[[7.0, 0.0, 0.0]]])  # valid for A (7<10), OOB for B (7>=5)
    try:
        with torch.no_grad():
            oa = inst_a(mid.clone())
        try:
            with torch.no_grad():
                ob = inst_b(mid.clone())
            if not torch.allclose(oa, ob, atol=1e-4):
                print("PASS:boundary_differs")
            else:
                print("FAIL:no_state_no_boundary_diff")
        except (IndexError, RuntimeError):
            print("PASS:boundary_error")
    except Exception:
        print("FAIL:both_error")
    exit()

differs = False
if set(sa.keys()) != set(sb.keys()):
    differs = True
else:
    for k in sa:
        if k in sb:
            if sa[k].shape != sb[k].shape:
                differs = True; break
            if not torch.allclose(sa[k].float(), sb[k].float(), atol=1e-6):
                differs = True; break
if differs:
    print("PASS:state_differs")
else:
    print("FAIL:identical_state")
PYEOF
)
echo "  Result: $T13"
if [[ "$T13" == PASS* ]]; then add_reward 0.08; fi

echo ""
echo "=== T15: Varied inputs — single position + batch of 8 ==="
T15=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=32, theta=10000, axes_dim=[8,8,16])
passed = 0
# Single position
ids1 = torch.tensor([[[0.0, 0.0, 0.0]]])
try:
    with torch.no_grad():
        o = inst(ids1.clone())
        r = ref(ids1.clone())
    if o.shape == r.shape and torch.allclose(o, r, atol=1e-4, rtol=1e-4):
        passed += 1
except: pass
# Batch of 8 varied positions (all within bounds)
ids2 = torch.zeros(1, 8, 3, dtype=torch.float32)
for i in range(8):
    ids2[0, i, 0] = float(i % 10)
    ids2[0, i, 1] = float((i * 2) % 20)
    ids2[0, i, 2] = float((i * 3) % 20)
try:
    with torch.no_grad():
        o = inst(ids2.clone())
        r = ref(ids2.clone())
    if o.shape == r.shape and torch.allclose(o, r, atol=1e-4, rtol=1e-4):
        passed += 1
except: pass
if passed == 2:
    print("PASS")
else:
    print(f"FAIL:{passed}/2")
PYEOF
)
echo "  Result: $T15"
if [[ "$T15" == PASS* ]]; then add_reward 0.12; fi

echo ""
echo "=== T16: Forward is pure — no input mutation + deterministic ==="
T16=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
passed = 0
total = 2
# Sub-check 1: Forward does not mutate input tensor
ids = torch.tensor([[[1.0, 2.0, 3.0],
                      [4.0, 5.0, 6.0],
                      [7.0, 8.0, 9.0]]])
ids_orig = ids.clone()
try:
    with torch.no_grad():
        out1 = inst(ids)
    if torch.equal(ids, ids_orig):
        passed += 1
    else:
        diff = (ids - ids_orig).abs().max().item()
        print(f"INFO:input_mutated:max_change={diff:.6f}")
except Exception as e:
    print(f"FAIL:fwd:{e}"); exit()
# Sub-check 2: Calling forward twice with same input gives identical output
ids2 = torch.tensor([[[2.0, 3.0, 4.0],
                       [5.0, 1.0, 7.0]]])
try:
    with torch.no_grad():
        r1 = inst(ids2.clone())
        r2 = inst(ids2.clone())
    if torch.allclose(r1, r2, atol=1e-6):
        passed += 1
    else:
        d = (r1 - r2).abs().max().item()
        print(f"INFO:non_deterministic:max_diff={d:.6f}")
except Exception as e:
    print(f"INFO:determinism_error:{e}")
if passed == total:
    print("PASS")
else:
    print(f"FAIL:{passed}/{total}")
PYEOF
)
echo "  Result: $T16"
if [[ "$T16" == PASS* ]]; then add_reward 0.15; fi

# ====================================================================
# P2P: Verify existing EmbedND and NextDiT upstream functionality (0.04)
# ====================================================================
echo ""
echo "=== P2P: EmbedND and NextDiT upstream functionality ==="
P2P=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
import torch
passed = 0
total = 3

# Sub-check 1: EmbedND produces finite RoPE output (cos/sin in [-1,1])
try:
    from comfy.ldm.flux.layers import EmbedND
    embed = EmbedND(dim=32, theta=10000, axes_dim=[8, 8, 16])
    ids = torch.tensor([[[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]]])
    with torch.no_grad():
        out = embed(ids)
    if isinstance(out, torch.Tensor) and torch.isfinite(out).all() and out.abs().max() <= 1.0 + 1e-6 and out.numel() > 0:
        passed += 1
    else:
        print(f"FAIL:embednd_values:max={out.abs().max().item():.4f},numel={out.numel()}")
except Exception as e:
    print(f"FAIL:embednd_import:{e}")

# Sub-check 2: EmbedND output varies with position (not constant)
try:
    ids_a = torch.tensor([[[0.0, 0.0, 0.0]]])
    ids_b = torch.tensor([[[5.0, 5.0, 5.0]]])
    with torch.no_grad():
        out_a = embed(ids_a)
        out_b = embed(ids_b)
    if not torch.allclose(out_a, out_b, atol=1e-6):
        passed += 1
    else:
        print("FAIL:embednd_constant_output")
except Exception as e:
    print(f"FAIL:embednd_vary:{e}")

# Sub-check 3: NextDiT class exists with expected attributes (axes_lens, rope_embedder)
try:
    import comfy.ldm.lumina.model as lm
    assert hasattr(lm, "NextDiT"), "NextDiT not found"
    import inspect
    sig = inspect.signature(lm.NextDiT.__init__)
    assert "axes_lens" in sig.parameters, "axes_lens param missing from NextDiT"
    passed += 1
except Exception as e:
    print(f"FAIL:nextdit:{e}")

if passed == total:
    print("PASS")
elif passed > 0:
    print(f"FAIL:partial:{passed}/{total}")
else:
    print("FAIL:all")
PYEOF
)
echo "  Result: $P2P"
if [[ "$P2P" == PASS* ]]; then add_reward 0.04; fi

# ====================================================================
# Write final reward
# ====================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
