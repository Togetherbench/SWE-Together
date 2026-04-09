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
# Scoring (P2P 7%, F2P-structural 8%, F2P-behavioral 85%, total=1.00):
#   T1:  0.02  model.py parses as valid Python (structural, P2P)
#   T2:  0.03  new class with axes_lens + forward (structural, F2P)
#   T3:  0.02  class has >=8 meaningful AST statements (structural, F2P)
#   T4:  0.03  NextDiT passes axes_lens to rope_embedder (structural, F2P)
#   T5:  0.04  instantiate config A (behavioral, F2P)
#   T6:  0.04  instantiate config B — varied params (behavioral, F2P)
#   T7:  0.06  forward shape matches EmbedND (behavioral, F2P)
#   T8:  0.05  forward values finite, in [-1,1], not zeros (behavioral, F2P)
#   T9:  0.08  sequential positions match EmbedND (behavioral, F2P)
#   T10: 0.08  non-sequential positions match EmbedND (behavioral, F2P)
#   T11: 0.08  config B match EmbedND — different axes_dim (behavioral, F2P)
#   T12: 0.11  precomputed internal state exists (behavioral, F2P)
#   T13: 0.11  different axes_lens -> different state (behavioral, F2P)
#   T14: 0.11  OOB position diverges from EmbedND (behavioral, F2P)
#   T15: 0.09  varied inputs: single + batch of 8 both correct (behavioral, F2P)
#   P2P: 0.05  upstream ComfyUI unit tests (P2P)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0.0
MODEL_PY="/workspace/ComfyUI/comfy/ldm/lumina/model.py"

# Activate virtual environment (torch, einops installed here)
export PATH="/workspace/venv/bin:$PATH"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

# ---- Shared mock for comfy.model_management (CPU-only) ----
cat > /tmp/_mock_mm.py << 'MOCKEOF'
import sys, types, torch
sys.path.insert(0, "/workspace/ComfyUI")
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
_SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
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
# STRUCTURAL TESTS (4 tests, 0.10 total)
# ====================================================================

echo "=== T1/16: model.py parses as valid Python ==="
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
if [ "$T1" = "PASS" ]; then add_reward 0.02; fi

echo ""
echo "=== T2/16: New class with axes_lens + forward ==="
T2=$(python3 << 'PYEOF'
import ast
source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)
SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}
for node in ast.iter_child_nodes(tree):
    if not isinstance(node, ast.ClassDef) or node.name in SKIP:
        continue
    has_axes_lens = has_forward = False
    for child in node.body:
        if isinstance(child, ast.FunctionDef) and child.name == "__init__":
            params = [a.arg for a in child.args.args] + [a.arg for a in child.args.kwonlyargs]
            has_axes_lens = any("axes_lens" in p for p in params)
        if isinstance(child, ast.FunctionDef) and child.name == "forward":
            has_forward = True
    if has_axes_lens and has_forward:
        print(f"PASS:{node.name}"); exit()
print("FAIL")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.03; fi

echo ""
echo "=== T3/16: Class has >=8 meaningful AST statements ==="
T3=$(python3 << 'PYEOF'
import ast
source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)
SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}
for node in ast.iter_child_nodes(tree):
    if not isinstance(node, ast.ClassDef) or node.name in SKIP:
        continue
    has_axes_lens = has_forward = False
    for child in node.body:
        if isinstance(child, ast.FunctionDef) and child.name == "__init__":
            params = [a.arg for a in child.args.args] + [a.arg for a in child.args.kwonlyargs]
            has_axes_lens = any("axes_lens" in p for p in params)
        if isinstance(child, ast.FunctionDef) and child.name == "forward":
            has_forward = True
    if not (has_axes_lens and has_forward):
        continue
    count = sum(1 for c in ast.walk(node) if isinstance(c, (
        ast.Assign, ast.AugAssign, ast.AnnAssign, ast.If, ast.For,
        ast.While, ast.With, ast.Return, ast.Call, ast.FunctionDef)))
    if count >= 8:
        print(f"PASS:{node.name}:{count}_stmts"); exit()
    else:
        print(f"FAIL:{node.name}:{count}_stmts<8"); exit()
print("FAIL:no_class")
PYEOF
)
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.02; fi

echo ""
echo "=== T4/16: NextDiT passes axes_lens to rope_embedder ==="
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
# BEHAVIORAL TESTS (11 tests, 0.90 total)
# ====================================================================

echo ""
echo "=== T5/16: Instantiate config A (dim=32, axes_dim=[8,8,16], axes_lens=[10,20,20]) ==="
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
echo "=== T6/16: Instantiate config B (dim=64, theta=256, axes_dim=[16,16,32], axes_lens=[5,10,10]) ==="
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
echo "=== T7/16: Forward shape matches EmbedND ==="
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
        out = inst(ids)
        ref_out = ref(ids)
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
echo "=== T8/16: Forward values finite, in [-1,1], not zeros ==="
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
        out = inst(ids)
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
echo "=== T9/16: Sequential positions match EmbedND ==="
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
        out = inst(ids)
        ref_out = ref(ids)
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
if [[ "$T9" == PASS* ]]; then add_reward 0.08; fi

echo ""
echo "=== T10/16: Non-sequential positions match EmbedND ==="
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
        out = inst(ids)
        ref_out = ref(ids)
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
if [[ "$T10" == PASS* ]]; then add_reward 0.08; fi

echo ""
echo "=== T11/16: Config B match EmbedND (dim=64, axes_dim=[16,16,32]) ==="
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
        out = inst(ids)
        ref_out = ref(ids)
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
echo "=== T12/16: Precomputed internal state exists ==="
T12=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
# Look for precomputed tensors: buffers, parameters, or tensor attrs
# with numel > 10 (filters out stored config scalars/small lists)
precomputed = []
for k, v in inst.named_buffers():
    if v.numel() > 10:
        precomputed.append(f"buf:{k}:{list(v.shape)}")
for k, v in inst.named_parameters():
    if v.numel() > 10:
        precomputed.append(f"par:{k}:{list(v.shape)}")
for k, v in vars(inst).items():
    if isinstance(v, torch.Tensor) and v.numel() > 10:
        precomputed.append(f"attr:{k}:{list(v.shape)}")
if precomputed:
    print(f"PASS:{len(precomputed)}_tensors")
else:
    print("FAIL:no_precomputed_state")
PYEOF
)
echo "  Result: $T12"
if [[ "$T12" == PASS* ]]; then add_reward 0.11; fi

echo ""
echo "=== T13/16: Different axes_lens -> different internal state ==="
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
            oa = inst_a(mid)
        try:
            with torch.no_grad():
                ob = inst_b(mid)
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
if [[ "$T13" == PASS* ]]; then add_reward 0.11; fi

echo ""
echo "=== T14/16: OOB position diverges from EmbedND ==="
T14=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
exec(open("/tmp/_discover.py").read())
if _cls is None:
    print("FAIL:no_class"); exit()
try:
    inst = _cls(dim=32, theta=10000, axes_dim=[8,8,16], axes_lens=[10,20,20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()
ref = _EmbedND(dim=32, theta=10000, axes_dim=[8,8,16])
# Position 15 on axis 0 exceeds axes_lens[0]=10
oob = torch.tensor([[[15.0, 0.0, 0.0]]])
try:
    with torch.no_grad():
        o_new = inst(oob)
        o_ref = ref(oob)
    # Both succeed: check if outputs differ (precomputed would clamp/wrap)
    if not torch.allclose(o_new, o_ref, atol=1e-4):
        print("PASS:different_output")
    else:
        print("FAIL:same_as_embednd")
except (IndexError, RuntimeError) as e:
    # OOB error proves precomputed lookup
    print(f"PASS:oob_error:{type(e).__name__}")
except Exception as e:
    print(f"FAIL:unexpected:{e}")
PYEOF
)
echo "  Result: $T14"
if [[ "$T14" == PASS* ]]; then add_reward 0.11; fi

echo ""
echo "=== T15/16: Varied inputs — single position + batch of 8 ==="
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
        o = inst(ids1)
        r = ref(ids1)
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
        o = inst(ids2)
        r = ref(ids2)
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
if [[ "$T15" == PASS* ]]; then add_reward 0.09; fi

# ====================================================================
# T16 P2P: Run ComfyUI's own CPU-safe unit tests (0.05)
# ====================================================================
echo ""
echo "=== T16/16: P2P — ComfyUI unit tests ==="
cd /workspace/ComfyUI
if python3 -m pytest tests/ -x --timeout=60 -q -k "not cuda and not gpu" 2>/dev/null; then
    echo "  PASS: upstream tests pass"
    add_reward 0.05
else
    echo "  FAIL: upstream tests failed or not found"
fi

# ====================================================================
# Write final reward
# ====================================================================
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
