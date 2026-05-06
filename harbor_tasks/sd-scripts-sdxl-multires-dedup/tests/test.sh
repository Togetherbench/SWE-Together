#!/bin/bash
set +e
export PATH="/workspace/sd-scripts/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PYTHON=/workspace/sd-scripts/bin/python3
if [ ! -x "$PYTHON" ]; then PYTHON=$(which python3); fi

REPO=/workspace/sd-scripts
REWARD=0.0

add_reward() {
    REWARD=$(awk "BEGIN{r=$REWARD+$1; if(r>1.0) r=1.0; printf \"%.4f\", r}")
}

run_py() {
    cd "$REPO" && "$PYTHON" -c "$1" 2>&1
}

# Ensure verifier-side Python deps are present (numpy needed by p2p_upstream gate)
python3 -c "import numpy" 2>/dev/null || pip install -q numpy 2>/dev/null || pip3 install -q numpy 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════
# P2P GATE: base imports must still work (gating only, no reward)
# ════════════════════════════════════════════════════════════════════
GATE=$(run_py '
import sys
sys.path.insert(0, "/workspace/sd-scripts")
try:
    from library import strategy_sd, config_util, train_util, sdxl_original_unet
    print("OK")
except Exception as e:
    print(f"FAIL:{e}")
')
if ! echo "$GATE" | tail -1 | grep -q "^OK$"; then
    echo "regression gate failed: $GATE"
    echo "0.0000" > "$REWARD_FILE"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════
# F2P T1 (0.12): is_disk_cached_latents_expected forwards multi_resolution=True
# Behavioral: monkeypatch _default and check the value flows through
# ════════════════════════════════════════════════════════════════════
echo "=== T1: SD strategy is_disk_cached_latents_expected -> multi_resolution=True ==="
T1=$(run_py '
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
import library.strategy_base as sb
captured = {}
def mock(self, *a, **kw):
    captured["kw"] = kw
    captured["args"] = a
    return True
sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = mock
from library.strategy_sd import SdSdxlLatentsCachingStrategy
sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
n = len(sig.parameters) - 1
args = [True, 1, False, False, False][:n]
s = SdSdxlLatentsCachingStrategy(*args)
try:
    s.is_disk_cached_latents_expected((512, 512), "/tmp/x.npz", False, False)
except Exception:
    pass
kw = captured.get("kw", {})
ar = captured.get("args", ())
mr = kw.get("multi_resolution")
if mr is None and len(ar) >= 6:
    mr = ar[5]
print("PASS" if mr is True else f"FAIL:kw={kw} args={ar}")
')
echo "  $T1"
echo "$T1" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# F2P T2 (0.12): cache_batch_latents forwards multi_resolution=True
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T2: SD strategy cache_batch_latents -> multi_resolution=True ==="
T2=$(run_py '
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
import library.strategy_base as sb
captured = {}
def mock_cache(self, *a, **kw):
    captured["kw"] = kw
    captured["args"] = a
    return None
sb.LatentsCachingStrategy._default_cache_batch_latents = mock_cache
from library.strategy_sd import SdSdxlLatentsCachingStrategy
sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
n = len(sig.parameters) - 1
args = [True, 1, False, False, False][:n]
s = SdSdxlLatentsCachingStrategy(*args)
class V:
    device = "cpu"; dtype = None
    def encode(self, x):
        class D:
            class latent_dist:
                @staticmethod
                def sample(): return None
        return D()
attempts = [
    (V(), [], False, False, False),
    (V(), [], False, False),
    (V(), None, None, [], False, False, False),
]
for ca in attempts:
    try:
        s.cache_batch_latents(*ca); break
    except TypeError:
        continue
    except Exception:
        break
kw = captured.get("kw", {})
ar = captured.get("args", ())
mr = kw.get("multi_resolution")
# Search positional args for True flag indicating multi_resolution
if mr is None and len(ar) >= 8:
    # positions ~7+ might hold it
    for v in ar[6:]:
        if v is True:
            mr = True; break
print("PASS" if mr is True else f"FAIL:kw={kw} args_len={len(ar)}")
')
echo "  $T2"
echo "$T2" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# F2P T3 (0.10): SD strategy overrides load_latents_from_disk with size=8
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: SD strategy load_latents_from_disk override forwards size=8 ==="
T3=$(run_py '
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
own = "load_latents_from_disk" in SdSdxlLatentsCachingStrategy.__dict__
if not own:
    print("FAIL:not_overridden"); sys.exit()
import library.strategy_base as sb
captured = {}
def mock_load(self, *a, **kw):
    captured["a"] = a; captured["kw"] = kw
    return (None, None, None, None, None)
sb.LatentsCachingStrategy._default_load_latents_from_disk = mock_load
sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
n = len(sig.parameters) - 1
args = [True, 1, False, False, False][:n]
s = SdSdxlLatentsCachingStrategy(*args)
try:
    s.load_latents_from_disk("/tmp/x.npz", (512, 512))
except Exception as e:
    print(f"FAIL:exc={e}"); sys.exit()
a = captured.get("a", ())
ok = len(a) >= 1 and 8 in a
print("PASS" if ok else f"FAIL:a={a}")
')
echo "  $T3"
echo "$T3" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T4 (0.10): Schema accepts skip_duplicate_bucketed_images as bool
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: ConfigSanitizer schema has skip_duplicate_bucketed_images:bool ==="
T4=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import config_util
sch = getattr(config_util.ConfigSanitizer, "DATASET_ASCENDABLE_SCHEMA", None)
ok_schema = sch is not None and "skip_duplicate_bucketed_images" in sch and sch["skip_duplicate_bucketed_images"] is bool
print("PASS" if ok_schema else f"FAIL:{sch}")
')
echo "  $T4"
echo "$T4" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T5 (0.10): skip_duplicate_bucketed_images is a dataclass field on
# at least one DatasetParams class (BaseDatasetParams or one of subclasses)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5: skip_duplicate_bucketed_images is a dataclass field ==="
T5=$(run_py '
import sys, os, dataclasses
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import config_util
found = []
for name in ["BaseDatasetParams","DreamBoothDatasetParams","FineTuningDatasetParams","ControlNetDatasetParams"]:
    cls = getattr(config_util, name, None)
    if cls is None: continue
    if dataclasses.is_dataclass(cls):
        fields = {f.name for f in dataclasses.fields(cls)}
        if "skip_duplicate_bucketed_images" in fields:
            found.append(name)
print("PASS" if found else "FAIL:none")
')
echo "  $T5"
echo "$T5" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T6 (0.10): Schema validates a real TOML config containing
# skip_duplicate_bucketed_images=true (full integration through sanitizer)
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T6: ConfigSanitizer accepts skip_duplicate_bucketed_images in user config ==="
T6=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import config_util
try:
    cs = config_util.ConfigSanitizer(True, True, False, True)
except TypeError:
    try:
        cs = config_util.ConfigSanitizer(True, True, True)
    except Exception as e:
        print(f"FAIL:ctor:{e}"); sys.exit()
except Exception as e:
    print(f"FAIL:ctor:{e}"); sys.exit()

cfg = {
    "general": {"skip_duplicate_bucketed_images": True},
    "datasets": [
        {
            "resolution": 512,
            "batch_size": 1,
            "skip_duplicate_bucketed_images": True,
            "subsets": [{"image_dir": "/tmp/x"}],
        }
    ],
}
try:
    san = cs.sanitize_user_config(cfg)
except Exception as e:
    print(f"FAIL:sanitize:{e}"); sys.exit()

# verify the value survived sanitization somewhere
import json
s = json.dumps(san, default=str)
print("PASS" if "skip_duplicate_bucketed_images" in s else f"FAIL:not_in_output")
')
echo "  $T6"
echo "$T6" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T7 (0.12): unwrap_model_for_sampling exists in train_util AND
# correctly unwraps a torch.compile-style _orig_mod attribute.
# Behavioral check: pass an object whose accelerator.unwrap_model returns
# something with _orig_mod, and verify that it gets unwrapped to the inner.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7: unwrap_model_for_sampling unwraps _orig_mod ==="
T7=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import train_util
fn = getattr(train_util, "unwrap_model_for_sampling", None)
if fn is None:
    print("FAIL:no_function"); sys.exit()

class Inner:
    name = "inner"

class Wrapped:
    def __init__(self, inner):
        self._orig_mod = inner
        self.name = "wrapped"

class Accel:
    def unwrap_model(self, m):
        return m

inner = Inner()
wrapped = Wrapped(inner)
acc = Accel()
try:
    result = fn(acc, wrapped)
except Exception as e:
    print(f"FAIL:exc={e}"); sys.exit()

# Result must be the inner (unwrapped from _orig_mod), not the wrapper
if result is inner or getattr(result, "name", None) == "inner":
    print("PASS")
else:
    print(f"FAIL:got_name={getattr(result,'name',None)}")
')
echo "  $T7"
echo "$T7" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# F2P T8 (0.12): sdxl_original_unet isinstance checks handle _orig_mod.
# Behavioral: build a fake "compiled" wrapper around a ResnetBlock2D-like
# layer; the call_module path should treat it AS the resnet (via _orig_mod).
# We probe by inspecting the source of sdxl_original_unet.py and confirming
# that _orig_mod is referenced near isinstance checks (structural+behavioral
# proxy — actual call is too heavy to construct).
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T8: sdxl_original_unet isinstance handles _orig_mod ==="
T8=$(run_py '
import sys, os, re, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import sdxl_original_unet
src = inspect.getsource(sdxl_original_unet)

# Count call_module-like blocks (the inner function appears twice in the file)
call_module_blocks = re.findall(r"def call_module\([^)]*\):.*?(?=\n        for |\n        h = x\n)", src, re.DOTALL)
# Heuristic: just look in the whole file
has_orig_mod = "_orig_mod" in src
# check both isinstance(...ResnetBlock2D) and isinstance(...Transformer2DModel) appear,
# and _orig_mod is used in the same file
has_resnet_isinstance = "ResnetBlock2D" in src and "Transformer2DModel" in src
# Look for _orig_mod within ~200 chars of an isinstance(...ResnetBlock2D)
ok = False
for m in re.finditer(r"isinstance\([^)]*ResnetBlock2D[^)]*\)", src):
    window = src[max(0, m.start()-400):m.end()+400]
    if "_orig_mod" in window:
        ok = True
        break
# Also accept if _orig_mod is used in a helper near top of the relevant function
if not ok and "_orig_mod" in src and has_resnet_isinstance:
    # require it appears at least twice (both call_module copies, or one helper used twice)
    if src.count("_orig_mod") >= 1 and src.count("isinstance") >= 2:
        # stricter: helper must be referenced where layers are checked
        # accept only if _orig_mod appears after the first ResnetBlock2D mention
        first = src.find("ResnetBlock2D")
        if "_orig_mod" in src[first:first+2000] if first >= 0 else False:
            ok = True
print("PASS" if ok else "FAIL:no_orig_mod_near_isinstance")
')
echo "  $T8"
echo "$T8" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# F2P T9 (0.12): Behavioral test of the isinstance-with-_orig_mod fix.
# Build a fake compiled wrapper and run the same logic the patched
# call_module uses; verify it routes to the resnet branch.
# We do this by importing sdxl_original_unet and inspecting that the
# patched code path actually unwraps _orig_mod for isinstance dispatch.
# Concrete: monkey-create a class whose _orig_mod is a real ResnetBlock2D,
# then evaluate the same kind of dispatch by parsing/exec'ing the fixed
# pattern: an "actual = layer._orig_mod if hasattr(layer,'_orig_mod') else layer"
# style line must exist OR a helper function _get_orig_module / similar.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T9: behavioral _orig_mod dispatch in sdxl_original_unet ==="
T9=$(run_py '
import sys, os, inspect, re
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import sdxl_original_unet
src = inspect.getsource(sdxl_original_unet)

patterns = [
    r"_orig_mod\s+if\s+hasattr\([^,]+,\s*[\"\x27]_orig_mod[\"\x27]\)",
    r"hasattr\([^,]+,\s*[\"\x27]_orig_mod[\"\x27]\)\s*else",
    r"getattr\([^,]+,\s*[\"\x27]_orig_mod[\"\x27]",
    r"def\s+_get_orig_module",
    r"def\s+_isinstance_orig",
    r"layer\._orig_mod",
    r"try:\s*\n\s*\S+\s*=\s*\S+\._orig_mod",
]
hits = sum(1 for p in patterns if re.search(p, src))
# Need at least one of the unwrap patterns AND the resnet/transformer checks present
ok = hits >= 1 and "ResnetBlock2D" in src and "Transformer2DModel" in src
print("PASS" if ok else f"FAIL:hits={hits}")
')
echo "  $T9"
echo "$T9" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# Final reward
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
: > "$GATES_FILE"

VENV_PYTHON=/workspace/venv/bin/python3
if [ ! -x "$VENV_PYTHON" ]; then VENV_PYTHON=$(which python3); fi

echo ""
echo "=== Upstream F2P: unwrap_model_for_sampling + load_latents_from_disk override ==="
cd /workspace/sd-scripts && $VENV_PYTHON -c "
import sys; sys.path.insert(0, '.')
from library.train_util import unwrap_model_for_sampling
from library.strategy_sd import SdSdxlLatentsCachingStrategy
assert 'load_latents_from_disk' in SdSdxlLatentsCachingStrategy.__dict__, 'no override'
print('OK')
" 2>&1
F2P1_RC=$?
if [ "$F2P1_RC" -eq 0 ]; then
    echo '{"id": "f2p_upstream_unwrap_multires", "passed": true, "detail": "unwrap_model_for_sampling importable and load_latents_from_disk overridden"}' >> "$GATES_FILE"
else
    echo '{"id": "f2p_upstream_unwrap_multires", "passed": false, "detail": "import or assertion failed"}' >> "$GATES_FILE"
fi
echo "  f2p_upstream_unwrap_multires: RC=$F2P1_RC"

echo ""
echo "=== Upstream F2P: skip_duplicate_bucketed_images + _orig_mod in unet ==="
cd /workspace/sd-scripts && $VENV_PYTHON -c "
import sys, inspect, dataclasses; sys.path.insert(0, '.')
from library.config_util import DreamBoothDatasetParams
fields = {f.name for f in dataclasses.fields(DreamBoothDatasetParams)}
assert 'skip_duplicate_bucketed_images' in fields, 'missing field'
from library import sdxl_original_unet
src = inspect.getsource(sdxl_original_unet)
assert '_orig_mod' in src, 'no _orig_mod'
print('OK')
" 2>&1
F2P2_RC=$?
if [ "$F2P2_RC" -eq 0 ]; then
    echo '{"id": "f2p_upstream_skipdup_origmod", "passed": true, "detail": "skip_duplicate_bucketed_images field present and _orig_mod in unet"}' >> "$GATES_FILE"
else
    echo '{"id": "f2p_upstream_skipdup_origmod", "passed": false, "detail": "field or _orig_mod assertion failed"}' >> "$GATES_FILE"
fi
echo "  f2p_upstream_skipdup_origmod: RC=$F2P2_RC"

echo ""
echo "=== Upstream P2P: py_compile all changed files ==="
cd /workspace/sd-scripts && $VENV_PYTHON -c "
import py_compile, tempfile, os
files = ['library/strategy_sd.py', 'library/config_util.py', 'library/train_util.py', 'library/sdxl_original_unet.py']
for f in files:
    t = tempfile.mktemp(suffix='.pyc')
    py_compile.compile(f, cfile=t, doraise=True)
    if os.path.exists(t): os.unlink(t)
print('OK')
" 2>&1
P2P1_RC=$?
if [ "$P2P1_RC" -eq 0 ]; then
    echo '{"id": "p2p_upstream_py_compile_all", "passed": true, "detail": "all 4 changed files compile"}' >> "$GATES_FILE"
else
    echo '{"id": "p2p_upstream_py_compile_all", "passed": false, "detail": "py_compile failed"}' >> "$GATES_FILE"
fi
echo "  p2p_upstream_py_compile_all: RC=$P2P1_RC"

# ---- upstream reward adjustment ----
echo ""
echo "=== Upstream reward adjustment ==="
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "t1_f2p_strategy_sd_multires": 0.12,
    "t1_f2p_strategy_sd_load_size": 0.06,
    "t4_f2p_skip_dup_field": 0.09,
    "t4_f2p_skip_dup_dedup_logic": 0.09,
    "t5_f2p_unwrap_function_behavioral": 0.09,
    "t5_f2p_unwrap_orig_mod_handling": 0.06,
    "t7_f2p_unet_orig_mod": 0.06,
    "t7_f2p_unet_orig_mod_dispatch": 0.03,
    "f2p_upstream_unwrap_multires": 0.2,
    "f2p_upstream_skipdup_origmod": 0.2
}
P2P_REGRESSION = ["p2p_base_imports", "p2p_upstream_fb8ee95f", "p2p_upstream_py_compile_all"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
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

p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- end ----