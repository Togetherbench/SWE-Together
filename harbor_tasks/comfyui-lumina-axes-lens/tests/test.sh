#!/usr/bin/env bash
#
# Verification tests for ComfyUI Lumina 2 axes_lens RoPE implementation.
#
# Tests verify comfy/ldm/lumina/model.py has been updated to:
#   1. Define a new class that accepts axes_lens and uses it for RoPE
#   2. Wire NextDiT to use the new class with axes_lens
#   3. Produce numerically correct output matching rope() reference
#   4. Actually use axes_lens (precomputed state or boundary behavior)
#
# All tests run on CPU — no GPU required.
# Reward written to /logs/verifier/reward.txt (0.0 to 1.0).
#
# Scoring (structural 15%, behavioral 85%):
#   Test 1: 0.05  model.py parses as valid Python (structural)
#   Test 2: 0.05  new class with axes_lens + forward + ≥8 stmts (structural)
#   Test 3: 0.05  NextDiT passes axes_lens to rope_embedder (structural)
#   Test 4: 0.05  instantiates on CPU, forward correct shape (behavioral/Silver)
#   Test 5: 0.35  forward matches rope() + axes_lens provably used (behavioral/Gold)
#             — values correct but no usage evidence: 0.05 partial
#   Test 6: 0.45  different axes_lens → different state/behavior + correct (behavioral/Gold)
#             — values correct but no difference: 0.05 partial
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0
MODEL_PY="/workspace/ComfyUI/comfy/ldm/lumina/model.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
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

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.05): model.py parses as valid Python
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/6: model.py parses as valid Python ==="
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
if [ "$T1" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.05): New class with axes_lens + forward + anti-stub (≥8 stmts)
# Must be a NEW class (not EmbedND, NextDiT, or other existing classes)
# with axes_lens in __init__ params, a forward method, and ≥8 meaningful
# AST statements (rejects trivial stubs/wrappers).
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/6: New rope embedder class (axes_lens + forward + ≥8 stmts) ==="
T2=$(python3 << 'PYEOF'
import ast, sys

source = open("/workspace/ComfyUI/comfy/ldm/lumina/model.py").read()
tree = ast.parse(source)

SKIP = {"EmbedND", "NextDiT", "JointAttention", "FinalLayer", "FeedForward",
        "TimestepEmbedder", "TransformerBlock", "JointTransformerBlock",
        "ModulationOut", "Modulation"}

best = None
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
    # Anti-stub: count meaningful AST statements (rejects pass/docstring stubs)
    count = sum(1 for c in ast.walk(node) if isinstance(c, (
        ast.Assign, ast.AugAssign, ast.AnnAssign, ast.If, ast.For,
        ast.While, ast.With, ast.Return, ast.Call, ast.FunctionDef)))
    if count >= 8 and (best is None or count > best[1]):
        best = (node.name, count)

if best:
    print(f"PASS:{best[0]}:{best[1]}_stmts")
else:
    print("FAIL")
PYEOF
)
echo "  Result: $T2"
if [[ "$T2" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.05): NextDiT passes axes_lens to rope_embedder
# Checks that self.rope_embedder = SomeClass(...axes_lens...) in NextDiT.__init__
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/6: NextDiT passes axes_lens to rope_embedder ==="
T3=$(python3 << 'PYEOF'
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
echo "  Result: $T3"
if [[ "$T3" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.05): Instantiation + forward shape correct (Silver)
# Behavioral: imports module, finds new class, creates instance with
# test axes_lens, calls forward, verifies output is a tensor with the
# same shape as EmbedND reference output.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/6: Instantiation + forward shape (Silver) ==="
T4=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
import inspect, torch
import comfy.ldm.lumina.model as lm
from comfy.ldm.flux.layers import EmbedND

SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}

cls = cls_name = None
for n, o in inspect.getmembers(lm, inspect.isclass):
    if n in SKIP: continue
    try:
        if "axes_lens" in inspect.signature(o.__init__).parameters:
            cls, cls_name = o, n; break
    except: pass

if cls is None:
    print("FAIL:no_class"); exit()

try:
    inst = cls(dim=32, theta=10000, axes_dim=[8, 8, 16], axes_lens=[10, 20, 20])
except Exception as e:
    print(f"FAIL:init:{e}"); exit()

ids = torch.zeros(1, 4, 3, dtype=torch.float32)
for i in range(4):
    ids[0, i, :] = float(i)

ref = EmbedND(dim=32, theta=10000, axes_dim=[8, 8, 16])
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
if torch.all(out == 0):
    print("FAIL:all_zeros"); exit()

print(f"PASS:{cls_name}")
PYEOF
)
echo "  Result: $T4"
if [[ "$T4" == PASS* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.35): Forward matches rope() reference + axes_lens provably used
# Gold tier: verifies numerical correctness across two position sets,
# then checks that axes_lens is actually used (not just stored).
#
# "Provably used" means ANY of:
#   (a) precomputed state (buffers/tensor attrs) exists in the instance
#   (b) out-of-bounds position (beyond axes_lens) causes error or
#       produces different output than vanilla EmbedND
#
# Full 0.35: values correct + evidence of axes_lens usage
# Partial 0.05: values correct but no evidence (wrapper/copy-EmbedND)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/6: Forward matches rope() + axes_lens used (Gold) ==="
T5=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
import inspect, sys, torch
import comfy.ldm.lumina.model as lm
from comfy.ldm.flux.layers import EmbedND

SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}

cls = cls_name = None
for n, o in inspect.getmembers(lm, inspect.isclass):
    if n in SKIP: continue
    try:
        if "axes_lens" in inspect.signature(o.__init__).parameters:
            cls, cls_name = o, n; break
    except: pass

if cls is None:
    print("FAIL:no_class"); sys.exit(0)

axes_dim, axes_lens, theta = [8, 8, 16], [10, 20, 20], 10000

try:
    inst = cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=axes_lens)
except Exception as e:
    print(f"FAIL:init:{e}"); sys.exit(0)

# --- Numerical check: two position sets vs rope() reference ---
ref = EmbedND(dim=32, theta=theta, axes_dim=axes_dim)

# Set 1: sequential positions
ids1 = torch.zeros(1, 5, 3, dtype=torch.float32)
for i in range(5):
    ids1[0, i, :] = float(i)

# Set 2: non-sequential positions
ids2 = torch.tensor([[[0.0, 2.0, 4.0],
                       [1.0, 3.0, 0.0],
                       [0.0, 1.0, 3.0]]])

for label, ids in [("seq", ids1), ("nonseq", ids2)]:
    try:
        with torch.no_grad():
            out = inst(ids)
            ref_out = ref(ids)
    except Exception as e:
        print(f"FAIL:fwd_{label}:{e}"); sys.exit(0)
    if out.shape != ref_out.shape:
        print(f"FAIL:shape_{label}:{list(out.shape)}!={list(ref_out.shape)}"); sys.exit(0)
    if not torch.allclose(out, ref_out, atol=1e-4, rtol=1e-4):
        d = (out - ref_out).abs().max().item()
        print(f"FAIL:values_{label}:max_diff={d:.4f}"); sys.exit(0)

# --- Evidence that axes_lens is actually used ---

# Evidence A: precomputed state (buffers, parameters, or tensor attributes)
def get_state(m):
    s = {}
    for k, v in m.named_buffers(): s[f"b:{k}"] = v
    for k, v in m.named_parameters(): s[f"p:{k}"] = v
    for k, v in vars(m).items():
        if isinstance(v, torch.Tensor) and k not in ("weight", "bias"):
            s[f"a:{k}"] = v
    return s

has_precomputed = len(get_state(inst)) > 0

# Evidence B: out-of-bounds position differs from EmbedND
# Position 15 on axis 0 exceeds axes_lens[0]=10. A precomputed impl
# using F.embedding would error; a clamping impl would give different
# output than EmbedND (which computes dynamically for any position).
has_boundary = False
oob = torch.tensor([[[15.0, 0.0, 0.0]]])
try:
    with torch.no_grad():
        o1 = inst(oob)
        o2 = ref(oob)
    if not torch.allclose(o1, o2, atol=1e-4, rtol=1e-4):
        has_boundary = True
except (IndexError, RuntimeError):
    has_boundary = True  # F.embedding OOB proves precomputed lookup

if has_precomputed or has_boundary:
    print(f"PASS:{cls_name}")
else:
    print(f"PARTIAL:{cls_name}:no_axes_lens_evidence")
PYEOF
)
echo "  Result: $T5"
if [[ "$T5" == PASS* ]]; then add_reward 0.35
elif [[ "$T5" == PARTIAL* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.45): Different axes_lens → different state/behavior + correct
# Gold tier: creates two instances with different axes_lens values.
# Verifies:
#   (a) internal state or boundary behavior differs between them
#   (b) both produce correct forward output for in-bounds positions
#
# A stub/wrapper/copy-EmbedND that ignores axes_lens will produce
# identical state and identical boundary behavior for both instances.
#
# Full 0.45: state/behavior differs + all 3 position checks correct
# Partial 0.05: all 3 correct but no state/behavior difference
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/6: Different axes_lens → different state + correct (Gold) ==="
T6=$(python3 << 'PYEOF'
exec(open("/tmp/_mock_mm.py").read())
import inspect, sys, torch
import comfy.ldm.lumina.model as lm
from comfy.ldm.flux.layers import EmbedND

SKIP = {"EmbedND","NextDiT","JointAttention","FinalLayer","FeedForward",
        "TimestepEmbedder","TransformerBlock","JointTransformerBlock",
        "ModulationOut","Modulation"}

cls = cls_name = None
for n, o in inspect.getmembers(lm, inspect.isclass):
    if n in SKIP: continue
    try:
        if "axes_lens" in inspect.signature(o.__init__).parameters:
            cls, cls_name = o, n; break
    except: pass

if cls is None:
    print("FAIL:no_class"); sys.exit(0)

axes_dim, theta = [8, 8, 16], 10000
lens_a, lens_b = [10, 20, 20], [5, 10, 10]

try:
    inst_a = cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=lens_a)
    inst_b = cls(dim=32, theta=theta, axes_dim=axes_dim, axes_lens=lens_b)
except Exception as e:
    print(f"FAIL:init:{e}"); sys.exit(0)

# --- Part A: state or boundary behavior differs ---
def get_state(m):
    s = {}
    for k, v in m.named_buffers(): s[f"b:{k}"] = v
    for k, v in m.named_parameters(): s[f"p:{k}"] = v
    for k, v in vars(m).items():
        if isinstance(v, torch.Tensor) and k not in ("weight", "bias"):
            s[f"a:{k}"] = v
    return s

sa, sb = get_state(inst_a), get_state(inst_b)

states_differ = False
if sa or sb:
    if set(sa.keys()) != set(sb.keys()):
        states_differ = True
    else:
        for k in sa:
            if k in sb:
                if sa[k].shape != sb[k].shape:
                    states_differ = True; break
                if not torch.allclose(sa[k].float(), sb[k].float(), atol=1e-6):
                    states_differ = True; break

# If no state difference, check boundary behavior.
# Position 7: valid for lens_a[0]=10 (7<10), OOB for lens_b[0]=5 (7>=5).
boundary_differs = False
if not states_differ:
    mid = torch.tensor([[[7.0, 0.0, 0.0]]])
    try:
        with torch.no_grad():
            oa = inst_a(mid)
        try:
            with torch.no_grad():
                ob = inst_b(mid)
            if not torch.allclose(oa, ob, atol=1e-4, rtol=1e-4):
                boundary_differs = True
        except (IndexError, RuntimeError):
            boundary_differs = True  # B errors on OOB, A doesn't
    except (IndexError, RuntimeError):
        boundary_differs = True  # unexpected but shows axes_lens used

has_evidence = states_differ or boundary_differs

# --- Part B: both produce correct output for in-bounds positions ---
ref = EmbedND(dim=32, theta=theta, axes_dim=axes_dim)
correct = 0

# inst_a: sequential positions (all within lens_a bounds)
ids_seq = torch.tensor([[[0,0,0],[1,1,1],[2,2,2],[3,3,3]]], dtype=torch.float32)
try:
    with torch.no_grad():
        o = inst_a(ids_seq)
        r = ref(ids_seq)
    if o.shape == r.shape and torch.allclose(o, r, atol=1e-4, rtol=1e-4):
        correct += 1
except: pass

# inst_a: non-sequential positions
ids_ns = torch.tensor([[[0,2,4],[1,3,0],[0,1,3]]], dtype=torch.float32)
try:
    with torch.no_grad():
        o = inst_a(ids_ns)
        r = ref(ids_ns)
    if o.shape == r.shape and torch.allclose(o, r, atol=1e-4, rtol=1e-4):
        correct += 1
except: pass

# inst_b: positions within lens_b bounds (all < 5 on axis 0, < 10 on axes 1,2)
ids_b = torch.tensor([[[0,2,4],[1,3,0],[0,1,3]]], dtype=torch.float32)
try:
    with torch.no_grad():
        o = inst_b(ids_b)
        r = ref(ids_b)
    if o.shape == r.shape and torch.allclose(o, r, atol=1e-4, rtol=1e-4):
        correct += 1
except: pass

if correct == 3 and has_evidence:
    ev = "state" if states_differ else "boundary"
    print(f"PASS:{cls_name}:{ev}")
elif correct == 3:
    print(f"PARTIAL:{cls_name}:correct_no_evidence")
else:
    print(f"FAIL:{cls_name}:correct={correct}/3:evidence={has_evidence}")
PYEOF
)
echo "  Result: $T6"
if [[ "$T6" == PASS* ]]; then add_reward 0.45
elif [[ "$T6" == PARTIAL* ]]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$REWARD_FILE"
