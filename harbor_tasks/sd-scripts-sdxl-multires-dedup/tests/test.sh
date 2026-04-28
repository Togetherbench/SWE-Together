#!/bin/bash
set +e
export PATH="/workspace/sd-scripts/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$REWARD_FILE")"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr -d '\n' | sed 's/"/\\"/g' | head -c 300)
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

PYTHON=/workspace/sd-scripts/bin/python3
if [ ! -x "$PYTHON" ]; then PYTHON=$(which python3); fi

REPO=/workspace/sd-scripts

run_py() {
    cd "$REPO" && "$PYTHON" -c "$1" 2>&1
}

# ════════════════════════════════════════════════════════════════════
# P2P informational: base imports
# ════════════════════════════════════════════════════════════════════
GATE=$(run_py '
import sys
sys.path.insert(0, "/workspace/sd-scripts")
try:
    from library import strategy_sd
    print("OK")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
')
if echo "$GATE" | tail -1 | grep -q "^OK$"; then
    emit p2p_base_imports true ""
else
    emit p2p_base_imports false "$GATE"
fi

# ════════════════════════════════════════════════════════════════════
# T1a: strategy_sd multi_resolution=True forwarding
# Combines source-inspect (robust to import failures) + behavioral check
# ════════════════════════════════════════════════════════════════════
echo "=== T1a: strategy_sd multi_resolution forwarding ==="
T1A=$(run_py '
import sys, os, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

# Read the source first (works even if imports fail)
src_path = "/workspace/sd-scripts/library/strategy_sd.py"
try:
    with open(src_path) as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:cant_read:{e}"); sys.exit()

# Count multi_resolution=True occurrences. The fix should add at least 2:
# in is_disk_cached_latents_expected and cache_batch_latents.
mr_true_count = len(re.findall(r"multi_resolution\s*=\s*True", src))
if mr_true_count < 2:
    print(f"FAIL:only_{mr_true_count}_multi_resolution_True_in_src"); sys.exit()

# Try behavioral verification too — but do not require it (env may be broken)
behavioral_ok = False
try:
    import library.strategy_base as sb
    captured = {}
    orig_default = sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected
    def mock(self, *a, **kw):
        captured.setdefault("kw_list", []).append(kw)
        captured.setdefault("args_list", []).append(a)
        return True
    sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = mock

    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    n = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:n]
    s = SdSdxlLatentsCachingStrategy(*args)
    try:
        s.is_disk_cached_latents_expected((512, 512), "/tmp/x.npz", False, False)
    except Exception:
        pass
    for kw in captured.get("kw_list", []):
        if kw.get("multi_resolution") is True:
            behavioral_ok = True
            break
    for ar in captured.get("args_list", []):
        if any(v is True for v in ar[1:]):
            # could also be passed positionally
            pass
    sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = orig_default
except Exception:
    pass

# Pass if either source check shows mr=True forwarded OR behavioral verified
print(f"PASS:src_count={mr_true_count}_behavioral={behavioral_ok}")
')
echo "  $T1A"
if echo "$T1A" | tail -1 | grep -q "^PASS"; then
    emit t1_f2p_strategy_sd_multires true ""
else
    emit t1_f2p_strategy_sd_multires false "$T1A"
fi

# ════════════════════════════════════════════════════════════════════
# T1b: strategy_sd load_latents_from_disk forwards size=8 (latent stride)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T1b: strategy_sd load_latents_from_disk size=8 ==="
T1B=$(run_py '
import sys, os, re, ast
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
src_path = "/workspace/sd-scripts/library/strategy_sd.py"
try:
    with open(src_path) as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:cant_read:{e}"); sys.exit()

# Look for an override of load_latents_from_disk that calls into _default with 8
try:
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL:parse:{e}"); sys.exit()

found_method = False
forwards_8 = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_latents_from_disk":
        found_method = True
        body_src = ast.get_source_segment(src, node) or ""
        # check that 8 is passed somewhere in the body (the latent stride)
        if re.search(r"\b8\b", body_src):
            forwards_8 = True

if not found_method:
    print("FAIL:no_load_latents_from_disk_override"); sys.exit()
if not forwards_8:
    print("FAIL:no_size_8_in_body"); sys.exit()
print("PASS")
')
echo "  $T1B"
if echo "$T1B" | tail -1 | grep -q "^PASS$"; then
    emit t1_f2p_strategy_sd_load_size true ""
else
    emit t1_f2p_strategy_sd_load_size false "$T1B"
fi

# ════════════════════════════════════════════════════════════════════
# T4a: skip_duplicate_bucketed_images is a recognized field
# Accept either dataclass field OR schema entry (multiple correct shapes)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4a: skip_duplicate_bucketed_images recognized field ==="
T4A=$(run_py '
import sys, os, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

# Source-level check across config_util.py and train_util.py
hits = 0
for path in ["library/config_util.py", "library/train_util.py"]:
    try:
        with open(path) as f:
            src = f.read()
        if "skip_duplicate_bucketed_images" in src:
            hits += src.count("skip_duplicate_bucketed_images")
    except Exception:
        pass

# Need at least 3 occurrences total — the name should appear in the
# dataclass field, the schema, AND in dedup logic. A pure stub that just
# adds the name in one place will not reach 3.
if hits < 3:
    print(f"FAIL:only_{hits}_occurrences"); sys.exit()
print(f"PASS:hits={hits}")
')
echo "  $T4A"
if echo "$T4A" | tail -1 | grep -q "^PASS"; then
    emit t4_f2p_skip_dup_field true ""
else
    emit t4_f2p_skip_dup_field false "$T4A"
fi

# ════════════════════════════════════════════════════════════════════
# T4b: actual dedup logic — must reference image_data manipulation AND
# the skip_duplicate flag in same scope, AND have a tracking set/dict
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4b: actual dedup logic ==="
T4B=$(run_py '
import sys, os, ast, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

candidates = ["library/train_util.py", "library/config_util.py"]
found = False
detail = ""
for path in candidates:
    try:
        with open(path) as f:
            src = f.read()
    except Exception:
        continue
    if "skip_duplicate_bucketed_images" not in src:
        continue
    try:
        tree = ast.parse(src)
    except Exception:
        continue
    # Look for any function containing skip_duplicate_bucketed_images AND
    # some form of set/dict tracking AND image_data manipulation
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            body_src = ast.get_source_segment(src, node) or ""
            if "skip_duplicate_bucketed_images" not in body_src:
                continue
            has_tracker = bool(re.search(r"set\(\)|\{\}|seen|duplicat|already|registered", body_src, re.I))
            has_image_data = "image_data" in body_src or "image_to_subset" in body_src or "del " in body_src or ".pop(" in body_src or ".remove(" in body_src
            if has_tracker and has_image_data:
                found = True
                detail = f"{path}:{node.name}"
                break
    if found:
        break

# Also accept a top-level pattern (not inside a function)
if not found:
    for path in candidates:
        try:
            with open(path) as f:
                src = f.read()
        except Exception:
            continue
        if "skip_duplicate_bucketed_images" in src and re.search(r"image_data", src):
            # weak fallback: name + image_data in same file with conditional usage
            if re.search(r"if\s+[^\n]*skip_duplicate_bucketed_images", src):
                found = True
                detail = f"{path}:weak"
                break

print(f"PASS:{detail}" if found else "FAIL:no_dedup_logic")
')
echo "  $T4B"
if echo "$T4B" | tail -1 | grep -q "^PASS"; then
    emit t4_f2p_skip_dup_dedup_logic true ""
else
    emit t4_f2p_skip_dup_dedup_logic false "$T4B"
fi

# ════════════════════════════════════════════════════════════════════
# T5a: unwrap_model_for_sampling exists in train_util AND behaves correctly
# Behavioral: pass fake accelerator returning wrapped object with _orig_mod
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5a: unwrap_model_for_sampling behavioral ==="
T5A=$(run_py '
import sys, os, re, ast
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

# Source check first
try:
    with open("library/train_util.py") as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:cant_read:{e}"); sys.exit()

if "def unwrap_model_for_sampling" not in src and "unwrap_model_for_sampling" not in src:
    print("FAIL:no_function_defined"); sys.exit()

# Try behavioral
behavioral = False
behavioral_detail = ""
try:
    from library import train_util
    fn = getattr(train_util, "unwrap_model_for_sampling", None)
    if fn is None:
        behavioral_detail = "no attr"
    else:
        sentinel = object()
        class Inner:
            pass
        inner = Inner()
        class Wrapped:
            def __init__(self, inner): self._orig_mod = inner
        wrapped = Wrapped(inner)

        # Case 1: accelerator unwrap_model raises KeyError(_orig_mod) for compiled
        class FailingAccel:
            def unwrap_model(self, m, **kw):
                raise KeyError("_orig_mod")
        try:
            r = fn(FailingAccel(), wrapped)
            if r is inner:
                behavioral = True
                behavioral_detail = "raises_keyerror_unwrap_to_inner"
        except Exception as e:
            behavioral_detail = f"raises_case_failed:{e}"

        # Case 2: accelerator returns wrapped, function unwraps _orig_mod
        if not behavioral:
            class PassthroughAccel:
                def unwrap_model(self, m, **kw):
                    return m
            try:
                r = fn(PassthroughAccel(), wrapped)
                if r is inner:
                    behavioral = True
                    behavioral_detail = "passthrough_unwrap_to_inner"
            except Exception as e:
                behavioral_detail += f"|passthrough_failed:{e}"

        # Case 3: accelerator returns inner directly (already unwrapped), keep as-is
        if not behavioral:
            class GoodAccel:
                def unwrap_model(self, m, **kw):
                    if hasattr(m, "_orig_mod"):
                        return m._orig_mod
                    return m
            try:
                r = fn(GoodAccel(), wrapped)
                if r is inner:
                    behavioral = True
                    behavioral_detail = "goodaccel_unwraps"
            except Exception as e:
                behavioral_detail += f"|good_failed:{e}"
except Exception as e:
    behavioral_detail = f"import_failed:{e}"

if behavioral:
    print(f"PASS:{behavioral_detail}")
else:
    # Fall back: if function exists in src AND mentions _orig_mod, pass
    # (env may not allow import, but the fix is present)
    if "unwrap_model_for_sampling" in src and "_orig_mod" in src:
        # check both terms appear close together
        idx = src.find("unwrap_model_for_sampling")
        # find function block
        m = re.search(r"def\s+unwrap_model_for_sampling\s*\([^)]*\)\s*:.*?(?=\ndef |\Z)", src, re.DOTALL)
        if m and "_orig_mod" in m.group(0):
            print(f"PASS:src_only:{behavioral_detail}")
        else:
            print(f"FAIL:src_present_but_no_orig_mod_in_fn:{behavioral_detail}")
    else:
        print(f"FAIL:{behavioral_detail}")
')
echo "  $T5A"
if echo "$T5A" | tail -1 | grep -q "^PASS"; then
    emit t5_f2p_unwrap_function_behavioral true ""
else
    emit t5_f2p_unwrap_function_behavioral false "$T5A"
fi

# ════════════════════════════════════════════════════════════════════
# T5b: unwrap_model_for_sampling source references _orig_mod (structural)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5b: unwrap_model_for_sampling source mentions _orig_mod ==="
T5B=$(run_py '
import sys, os, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    with open("library/train_util.py") as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit()

m = re.search(r"def\s+unwrap_model_for_sampling\s*\([^)]*\)\s*:(.*?)(?=\n(?:def|class)\s|\Z)", src, re.DOTALL)
if not m:
    print("FAIL:no_function"); sys.exit()
body = m.group(1)
# Function must:
#  - reference _orig_mod (handle the compile case)
#  - call unwrap_model OR access _orig_mod directly
has_orig_mod = "_orig_mod" in body
calls_unwrap = "unwrap_model" in body or "unwrap" in body
has_handling = "try:" in body or "hasattr" in body or "getattr" in body or "except" in body

ok = has_orig_mod and (calls_unwrap or has_handling)
print(f"PASS:orig_mod={has_orig_mod}_unwrap={calls_unwrap}_handling={has_handling}" if ok else f"FAIL:orig_mod={has_orig_mod}_unwrap={calls_unwrap}_handling={has_handling}")
')
echo "  $T5B"
if echo "$T5B" | tail -1 | grep -q "^PASS"; then
    emit t5_f2p_unwrap_orig_mod_handling true ""
else
    emit t5_f2p_unwrap_orig_mod_handling false "$T5B"
fi

# ════════════════════════════════════════════════════════════════════
# T7a: sdxl_original_unet.py references _orig_mod near isinstance
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7a: sdxl_original_unet _orig_mod near isinstance ==="
T7A=$(run_py '
import sys, os, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    with open("library/sdxl_original_unet.py") as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit()

if "_orig_mod" not in src:
    print("FAIL:no_orig_mod"); sys.exit()

# Look for _orig_mod within a window around isinstance(..., ResnetBlock2D)
ok = False
for m in re.finditer(r"isinstance\([^)]*(?:ResnetBlock2D|Transformer2DModel)[^)]*\)", src):
    window = src[max(0, m.start()-500):m.end()+500]
    if "_orig_mod" in window:
        ok = True
        break

# Alternative: a helper function that unwraps _orig_mod
if not ok:
    if re.search(r"_orig_mod", src) and re.search(r"isinstance", src):
        # at least appears in same file with both isinstance and _orig_mod
        # require multi-occurrence (both call_module variants in file)
        if src.count("_orig_mod") >= 2:
            ok = True

print("PASS" if ok else "FAIL:no_orig_mod_near_isinstance")
')
echo "  $T7A"
if echo "$T7A" | tail -1 | grep -q "^PASS"; then
    emit t7_f2p_unet_orig_mod true ""
else
    emit t7_f2p_unet_orig_mod false "$T7A"
fi

# ════════════════════════════════════════════════════════════════════
# T7b: sdxl_original_unet has unwrap-style dispatch pattern
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7b: sdxl_original_unet _orig_mod-aware dispatch ==="
T7B=$(run_py '
import sys, os, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    with open("library/sdxl_original_unet.py") as f:
        src = f.read()
except Exception as e:
    print(f"FAIL:{e}"); sys.exit()

# Accept any of these patterns showing _orig_mod-aware dispatch:
patterns = [
    r"hasattr\([^,)]+,\s*[\x27\"]_orig_mod[\x27\"]\)",
    r"getattr\([^,)]+,\s*[\x27\"]_orig_mod[\x27\"]",
    r"\._orig_mod\b",
    r"_orig_mod[\x27\"]\s*\)",
]
hits = sum(1 for p in patterns if re.search(p, src))
print("PASS" if hits >= 1 and "_orig_mod" in src else f"FAIL:hits={hits}")
')
echo "  $T7B"
if echo "$T7B" | tail -1 | grep -q "^PASS"; then
    emit t7_f2p_unet_orig_mod_dispatch true ""
else
    emit t7_f2p_unet_orig_mod_dispatch false "$T7B"
fi

# ════════════════════════════════════════════════════════════════════
# Compute reward from gates.json
# ════════════════════════════════════════════════════════════════════
REWARD=$("$PYTHON" - <<'PYEOF'
import json
weights = {
    "t1_f2p_strategy_sd_multires": 0.20,
    "t1_f2p_strategy_sd_load_size": 0.10,
    "t4_f2p_skip_dup_field": 0.15,
    "t4_f2p_skip_dup_dedup_logic": 0.15,
    "t5_f2p_unwrap_function_behavioral": 0.15,
    "t5_f2p_unwrap_orig_mod_handling": 0.10,
    "t7_f2p_unet_orig_mod": 0.10,
    "t7_f2p_unet_orig_mod_dispatch": 0.05,
}
gating = set()  # no P2P_GATING gates
total = 0.0
gating_failed = False
try:
    with open("/logs/verifier/gates.json") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                g = json.loads(line)
            except Exception:
                continue
            if g.get("id") in gating and not g.get("passed"):
                gating_failed = True
            if g.get("passed") and g.get("id") in weights:
                total += weights[g["id"]]
except Exception:
    pass
if gating_failed:
    total = 0.0
if total > 1.0:
    total = 1.0
print(f"{total:.4f}")
PYEOF
)

echo ""
echo "=== Final reward: $REWARD ==="
printf "%.4f\n" "$REWARD" > "$REWARD_FILE"

# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBscyAvd29ya3NwYWNlL3ZlbnYvYmluL3B5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_fb8ee95f 'py_compile_changed' 'cd /workspace/sd-scripts && /workspace/venv/bin/python3 -m py_compile library/strategy_sd.py library/config_util.py library/train_util.py library/sdxl_original_unet.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_strategy_sd_load_size": 0.1, "t1_f2p_strategy_sd_multires": 0.2, "t4_f2p_skip_dup_dedup_logic": 0.15, "t4_f2p_skip_dup_field": 0.15, "t5_f2p_unwrap_function_behavioral": 0.15, "t5_f2p_unwrap_orig_mod_handling": 0.1, "t7_f2p_unet_orig_mod": 0.1, "t7_f2p_unet_orig_mod_dispatch": 0.05}
P2P_GATING = []
P2P_REGRESSION = ["p2p_base_imports", "p2p_upstream_fb8ee95f"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----
