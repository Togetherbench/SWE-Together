#!/bin/bash
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

mkdir -p /logs/verifier
REWARD_FILE="/logs/verifier/reward.txt"
REWARD=0.0

cd /workspace 2>/dev/null

python3 << 'PYEOF' > /tmp/test_output.log 2>&1
import sys, os, traceback, ctypes, inspect
sys.path.insert(0, '/workspace')
os.chdir('/workspace')

REWARD = 0.0

def write_reward(r):
    try:
        with open('/logs/verifier/reward.txt', 'w') as f:
            f.write(f"{r}\n")
    except Exception:
        pass

def fail_zero(reason=""):
    print(f"GATE FAIL: {reason}")
    write_reward(0.0)
    sys.exit(0)

try:
    import numpy as np
    import torch
    import gguf
except Exception as e:
    fail_zero(f"import error: {e}")

class ggml_init_params(ctypes.Structure):
    _fields_ = [("mem_size", ctypes.c_size_t),
                ("mem_buffer", ctypes.c_void_p),
                ("no_alloc", ctypes.c_bool)]

LIBGGML = None
for cand in ["/usr/local/lib/libggml.so", "/usr/local/lib/libggml-base.so",
             "/usr/lib/libggml.so", "/usr/lib/x86_64-linux-gnu/libggml.so"]:
    if os.path.exists(cand):
        try:
            lib = ctypes.CDLL(cand)
            if hasattr(lib, "ggml_quantize_chunk"):
                LIBGGML = lib
                break
        except Exception:
            continue

if LIBGGML is None:
    fail_zero("libggml not found")

LIBGGML.ggml_quantize_chunk.restype = ctypes.c_size_t
LIBGGML.ggml_quantize_chunk.argtypes = (
    ctypes.c_int, ctypes.POINTER(ctypes.c_float), ctypes.c_void_p,
    ctypes.c_int64, ctypes.c_int64, ctypes.c_int64,
    ctypes.POINTER(ctypes.c_float),
)
LIBGGML.ggml_quantize_requires_imatrix.restype = ctypes.c_bool
LIBGGML.ggml_quantize_requires_imatrix.argtypes = (ctypes.c_int,)
if hasattr(LIBGGML, "ggml_init"):
    LIBGGML.ggml_init.argtypes = (ggml_init_params,)
    try:
        LIBGGML.ggml_init(ggml_init_params(1 * 1024 * 1024, 0, False))
    except Exception:
        pass

c_float_p = ctypes.POINTER(ctypes.c_float)

def quantize_with_libggml(qtype, weights, numel):
    quantized = np.zeros(
        gguf.quant_shape_to_byte_shape((numel,), qtype),
        dtype=np.uint8, order="C"
    )
    if LIBGGML.ggml_quantize_requires_imatrix(qtype.value):
        qw = np.sum((weights * weights).reshape((-1, weights.shape[-1])), axis=0
                   ).ctypes.data_as(c_float_p)
    else:
        qw = ctypes.cast(0, c_float_p)
    LIBGGML.ggml_quantize_chunk(
        qtype.value,
        weights.ctypes.data_as(c_float_p),
        quantized.ctypes.data_as(ctypes.c_void_p),
        0, 1, numel, qw,
    )
    return quantized

# ---- Load module under test ----------------------------------------------
try:
    from qwen3_moe_fused.quantize_gguf import dequant as dq_mod
    from qwen3_moe_fused.quantize_gguf.dequant import dequantize, dequantize_functions
except Exception as e:
    fail_zero(f"dequant import error: {e}")

# ---- P2P regression gates (no reward, gate only) -------------------------
def p2p_check(qtype_name, seed=2024, n_blocks=16, rtol=5e-3, atol=5e-3):
    try:
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        block_size, _ = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)
        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        out = dequantize(torch.from_numpy(quantized), qtype, (numel,), torch.float32)
        if torch.isnan(out).any() or torch.isinf(out).any():
            return False
        if out.shape != out_ref.shape:
            return False
        return torch.allclose(out.float(), out_ref.float(), rtol=rtol, atol=atol)
    except Exception:
        traceback.print_exc()
        return False

print("=== P2P regression gates ===")
for qname in ("Q4_0", "Q8_0", "IQ4_NL", "IQ4_XS", "Q4_K", "Q6_K"):
    ok = p2p_check(qname)
    print(f"  P2P {qname}: {'OK' if ok else 'BROKEN'}")
    if not ok:
        fail_zero(f"P2P regression on {qname}")

# ---- F2P weighted ---------------------------------------------------------
results = []

def record(name, weight, passed, detail=""):
    global REWARD
    earned = weight if passed else 0.0
    REWARD += earned
    status = "PASS" if passed else "FAIL"
    line = f"  [{status}] (+{earned:.3f}/{weight:.3f}) {name} {detail}"
    print(line)
    results.append(line)

def numerical_test(qtype_name, seed, n_blocks=24, rtol=2e-3, atol=2e-3):
    try:
        qtype = getattr(gguf.GGMLQuantizationType, qtype_name)
        if qtype not in dequantize_functions:
            return False, "not registered"
        block_size, _ = gguf.GGML_QUANT_SIZES[qtype]
        numel = n_blocks * block_size
        rng = np.random.RandomState(seed)
        weights = rng.uniform(-1, 1, numel).astype(np.float32)
        quantized = quantize_with_libggml(qtype, weights, numel)
        out_ref = torch.from_numpy(gguf.quants.dequantize(quantized.copy(), qtype))
        out = dequantize(torch.from_numpy(quantized), qtype, (numel,), torch.float32)
        if torch.isnan(out).any() or torch.isinf(out).any():
            return False, "nan/inf"
        if out.shape != out_ref.shape:
            return False, f"shape {tuple(out.shape)} vs {tuple(out_ref.shape)}"
        diff = (out.float() - out_ref.float()).abs()
        max_diff = float(diff.max().item())
        ok = torch.allclose(out.float(), out_ref.float(), rtol=rtol, atol=atol)
        return ok, f"max_diff={max_diff:.5g}"
    except Exception as e:
        return False, f"exc:{type(e).__name__}:{e}"

# === Gate 1: IQ3_XXS numerical correctness — was buggy on base ===
# Multi-seed and multi-blocksize to catch shallow / partial fixes.
# Weight: 0.18
print("=== F2P G1: IQ3_XXS fix (numerical correctness) ===")
g1_subs = [
    (42, 8,  0.045),
    (142, 24, 0.045),
    (777, 32, 0.045),
    (9001, 16, 0.045),
]
for seed, nb, w in g1_subs:
    ok, info = numerical_test("IQ3_XXS", seed=seed, n_blocks=nb, rtol=2e-3, atol=2e-3)
    record(f"IQ3_XXS seed={seed} nb={nb}", w, ok, info)

# === Gate 2: IQ-family structural — must NOT use F.embedding (instruction R1) ===
# Weight: 0.04
# Broadened to inspect the full dequant module so wrapper helpers that
# internally call F.embedding (e.g. _grid_lookup / _ksigns_lookup that the
# IQ functions delegate to) are also caught. Rubric goal_7 requires
# elemental indexing inside the IQ-family dequantization PATH, not just the
# IQ3_XXS function body — a thin wrapper that itself calls F.embedding is
# still a violation. Comments are stripped before the check so a docstring
# mentioning F.embedding does not false-positive.
print("=== F2P G2: IQ-family path uses elemental indexing (no F.embedding) ===")
def _strip_python_comments(src):
    # Strip line comments and triple-quoted string blocks so docstrings /
    # `# F.embedding` notes don't trip the search.
    out_lines = []
    in_triple_single = False
    in_triple_double = False
    for line in src.splitlines():
        # Triple-quoted block tracking (whole-line approximation — adequate
        # for source files that put docstrings on their own lines).
        stripped = line.strip()
        if in_triple_single:
            if "'''" in line:
                in_triple_single = False
            continue
        if in_triple_double:
            if '"""' in line:
                in_triple_double = False
            continue
        if stripped.startswith("'''") and not stripped.endswith("'''", 3):
            in_triple_single = True
            continue
        if stripped.startswith('"""') and not stripped.endswith('"""', 3):
            in_triple_double = True
            continue
        # Strip inline #-comments (naive, but module source uses standard style)
        if "#" in line:
            line = line.split("#", 1)[0]
        out_lines.append(line)
    return "\n".join(out_lines)

def check_no_f_embedding():
    try:
        fn = dequantize_functions.get(gguf.GGMLQuantizationType.IQ3_XXS)
        if fn is None:
            return False, "not registered"
        # Inspect the full module source, not just the IQ3_XXS function body.
        # This catches thin wrapper helpers (e.g. _grid_lookup, _ksigns_lookup)
        # that the IQ-family functions might delegate to.
        try:
            module_src = inspect.getsource(dq_mod)
        except Exception:
            # Fall back to function source if module source is unavailable
            module_src = inspect.getsource(fn)
        cleaned = _strip_python_comments(module_src)
        bad = (
            "F.embedding" in cleaned
            or "torch.nn.functional.embedding" in cleaned
            or "nn.functional.embedding" in cleaned
        )
        return (not bad), ("uses F.embedding in IQ-family path" if bad else "ok")
    except Exception as e:
        return False, f"exc:{e}"
ok, info = check_no_f_embedding()
record("IQ-family no F.embedding", 0.04, ok, info)

# === Gate 3: IQ3_S numerical correctness ===
# Weight: 0.16
print("=== F2P G3: IQ3_S ===")
for seed, nb, w in [(43, 16, 0.05), (143, 24, 0.05), (4321, 32, 0.06)]:
    ok, info = numerical_test("IQ3_S", seed=seed, n_blocks=nb, rtol=2e-3, atol=2e-3)
    record(f"IQ3_S seed={seed} nb={nb}", w, ok, info)

# === Gate 4: IQ2_S numerical correctness ===
# Weight: 0.16
print("=== F2P G4: IQ2_S ===")
for seed, nb, w in [(45, 16, 0.05), (145, 24, 0.05), (5151, 32, 0.06)]:
    ok, info = numerical_test("IQ2_S", seed=seed, n_blocks=nb, rtol=2e-3, atol=2e-3)
    record(f"IQ2_S seed={seed} nb={nb}", w, ok, info)

# === Gate 5: IQ2_XXS numerical correctness ===
# Weight: 0.14
print("=== F2P G5: IQ2_XXS ===")
for seed, nb, w in [(46, 16, 0.05), (146, 24, 0.05), (6262, 32, 0.04)]:
    ok, info = numerical_test("IQ2_XXS", seed=seed, n_blocks=nb, rtol=2e-3, atol=2e-3)
    record(f"IQ2_XXS seed={seed} nb={nb}", w, ok, info)

# === Gate 6: IQ1_S numerical correctness (looser tolerance) ===
# Weight: 0.13
print("=== F2P G6: IQ1_S ===")
for seed, nb, w in [(44, 16, 0.045), (144, 24, 0.045), (7373, 32, 0.04)]:
    ok, info = numerical_test("IQ1_S", seed=seed, n_blocks=nb, rtol=8e-3, atol=8e-3)
    record(f"IQ1_S seed={seed} nb={nb}", w, ok, info)

# === Gate 7: IQ1_M numerical correctness (looser tolerance) ===
# Weight: 0.13
print("=== F2P G7: IQ1_M ===")
for seed, nb, w in [(47, 16, 0.045), (147, 24, 0.045), (8484, 32, 0.04)]:
    ok, info = numerical_test("IQ1_M", seed=seed, n_blocks=nb, rtol=8e-3, atol=8e-3)
    record(f"IQ1_M seed={seed} nb={nb}", w, ok, info)

# === Gate 8: registration completeness — partial credit per type ===
# Weight: 0.06 (1.0 cents per registered type, all 6 must be present for full)
print("=== F2P G8: registration of all 6 IQ types ===")
required = ["IQ3_XXS", "IQ3_S", "IQ2_S", "IQ2_XXS", "IQ1_S", "IQ1_M"]
present = 0
for n in required:
    qt = getattr(gguf.GGMLQuantizationType, n)
    if qt in dequantize_functions:
        present += 1
frac = present / len(required)
w = 0.06
earned = w * frac
REWARD += earned
print(f"  [{'PASS' if frac==1.0 else 'PARTIAL'}] (+{earned:.3f}/{w:.3f}) registered {present}/{len(required)}")

print(f"\n=== Total REWARD = {REWARD:.4f} ===")
write_reward(round(min(max(REWARD, 0.0), 1.0), 4))
PYEOF

cat /tmp/test_output.log

if [ ! -s "$REWARD_FILE" ]; then
    echo "0.0" > "$REWARD_FILE"
fi

REWARD=$(cat "$REWARD_FILE" 2>/dev/null || echo "0.0")
echo "Final reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
# ---- v5: orchestrator-wrapped appended block ----
_v5_run_upstream_appended() {
  set +e  # never abort the host script from inside the wrapper


# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier

# F2P gate: IQ3_XXS runtime dequant correctness
_gate_id="f2p_upstream_iq3xxs_dequant"
if python3 -c "
import numpy as np, torch, gguf, ctypes, sys
sys.path.insert(0, '/workspace')
from qwen3_moe_fused.quantize_gguf.dequant import dequantize
class P(ctypes.Structure):
    _fields_ = [('s', ctypes.c_size_t), ('b', ctypes.c_void_p), ('n', ctypes.c_bool)]
lib = ctypes.CDLL('/usr/local/lib/libggml-base.so')
lib.ggml_quantize_chunk.restype = ctypes.c_size_t
lib.ggml_quantize_chunk.argtypes = (ctypes.c_int, ctypes.POINTER(ctypes.c_float), ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64, ctypes.c_int64, ctypes.POINTER(ctypes.c_float))
lib.ggml_quantize_requires_imatrix.restype = ctypes.c_bool
lib.ggml_quantize_requires_imatrix.argtypes = (ctypes.c_int,)
if hasattr(lib, 'ggml_init'):
    lib.ggml_init.argtypes = (P,)
    lib.ggml_init(P(1048576, 0, False))
fp = ctypes.POINTER(ctypes.c_float)
qt = gguf.GGMLQuantizationType.IQ3_XXS
bs, _ = gguf.GGML_QUANT_SIZES[qt]
n = 16 * bs
w = np.random.RandomState(42).uniform(-1, 1, n).astype(np.float32)
q = np.zeros(gguf.quant_shape_to_byte_shape((n,), qt), dtype=np.uint8, order='C')
lib.ggml_quantize_chunk(qt.value, w.ctypes.data_as(fp), q.ctypes.data_as(ctypes.c_void_p), 0, 1, n, ctypes.cast(0, fp))
out = dequantize(torch.from_numpy(q), qt, (n,), torch.float32)
ref = torch.from_numpy(gguf.quants.dequantize(q.copy(), qt))
assert torch.allclose(out.float(), ref.float(), rtol=2e-3, atol=2e-3)
print('PASS')
" > /dev/null 2>&1; then
    echo "{\"id\": \"${_gate_id}\", \"passed\": true, \"detail\": \"IQ3_XXS dequant passed\"}" >> /logs/verifier/gates.json
else
    echo "{\"id\": \"${_gate_id}\", \"passed\": false, \"detail\": \"IQ3_XXS dequant failed\"}" >> /logs/verifier/gates.json
fi

# F2P gate: All new IQ types registered
_gate_id="f2p_upstream_iq_types_registered"
if python3 -c "
import sys; sys.path.insert(0, '/workspace')
from qwen3_moe_fused.quantize_gguf.dequant import dequantize_functions
import gguf
for name in ['IQ2_XXS','IQ2_S','IQ3_S','IQ1_S','IQ1_M']:
    qt = getattr(gguf.GGMLQuantizationType, name)
    assert qt in dequantize_functions, name + ' not registered'
print('PASS')
" > /dev/null 2>&1; then
    echo "{\"id\": \"${_gate_id}\", \"passed\": true, \"detail\": \"All IQ types registered\"}" >> /logs/verifier/gates.json
else
    echo "{\"id\": \"${_gate_id}\", \"passed\": false, \"detail\": \"Missing IQ type registrations\"}" >> /logs/verifier/gates.json
fi

# P2P gate: py_compile
_gate_id="p2p_upstream_pycompile"
if python3 -m py_compile /workspace/qwen3_moe_fused/quantize_gguf/dequant.py > /dev/null 2>&1; then
    echo "{\"id\": \"${_gate_id}\", \"passed\": true, \"detail\": \"py_compile passed\"}" >> /logs/verifier/gates.json
else
    echo "{\"id\": \"${_gate_id}\", \"passed\": false, \"detail\": \"py_compile failed\"}" >> /logs/verifier/gates.json
fi

# ---- upstream reward tail ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_iq3xxs_dequant": 0.20, "f2p_upstream_iq_types_registered": 0.20}
P2P_REGRESSION = ["p2p_upstream_pycompile"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

p2p_failed = False  # P2P_REGRESSION gates are informational only (v043 fix)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('REWARD=%.4f' % reward)
PYEOF
# ---- end ----
}
# Run via subshell so even unhandled `exit N` in the wrapper
# only kills the subshell, not the host. Exit codes ignored.
( _v5_run_upstream_appended ) || true
# ---- end v5 wrapper ----

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
