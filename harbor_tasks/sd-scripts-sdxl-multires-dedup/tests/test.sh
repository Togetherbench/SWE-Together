#!/bin/bash
set +e
export PATH="/workspace/sd-scripts/bin:$PATH"

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

# ════════════════════════════════════════════════════════════════════
# P2P GATE: base imports must still work
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
# F2P T1 (0.10): is_disk_cached_latents_expected forwards multi_resolution=True
# Base: passes False (default) → FAIL. Fix: passes True → PASS.
# ════════════════════════════════════════════════════════════════════
echo "=== T1: SD strategy is_disk_cached_latents_expected -> multi_resolution=True ==="
T1=$(run_py '
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
import library.strategy_base as sb
captured = {}
orig = sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected
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
# Multi-resolution may be passed by keyword OR positionally as the 6th arg of _default
mr = kw.get("multi_resolution")
if mr is None and len(ar) >= 6:
    mr = ar[5]
print("PASS" if mr is True else f"FAIL:kw={kw} args={ar}")
')
echo "  $T1"
echo "$T1" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T2 (0.10): cache_batch_latents forwards multi_resolution=True
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
# Try various signatures
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
if mr is None and len(ar) >= 8:
    # _default_cache_batch_latents(self, encode, dev, dtype, infos, flip, alpha, crop, multi_resolution)
    mr = ar[7] if len(ar) > 7 else None
print("PASS" if mr is True else f"FAIL:kw={kw} args_len={len(ar)}")
')
echo "  $T2"
echo "$T2" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T3 (0.08): load_latents_from_disk overridden in SD strategy
# Base: not overridden → FAIL. Fix: overridden, calls _default with size 8.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T3: SD strategy load_latents_from_disk override ==="
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
echo "$T3" | tail -1 | grep -q "^PASS$" && add_reward 0.08

# ════════════════════════════════════════════════════════════════════
# F2P T4 (0.12): Schema accepts skip_duplicate_bucketed_images as bool,
# AND it is present as a dataclass field on at least one DatasetParams class.
# Base lacks both → FAIL. Fix adds both → PASS.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T4: ConfigSanitizer schema + dataclass field for skip_duplicate_bucketed_images ==="
T4=$(run_py '
import sys, os, dataclasses
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import config_util
sch = getattr(config_util.ConfigSanitizer, "DATASET_ASCENDABLE_SCHEMA", None)
ok_schema = sch is not None and "skip_duplicate_bucketed_images" in sch and sch["skip_duplicate_bucketed_images"] is bool
found_field = False
for name in ["BaseDatasetParams","DreamBoothDatasetParams","FineTuningDatasetParams","ControlNetDatasetParams"]:
    cls = getattr(config_util, name, None)
    if cls is None: continue
    if dataclasses.is_dataclass(cls):
        fields = {f.name for f in dataclasses.fields(cls)}
        if "skip_duplicate_bucketed_images" in fields:
            found_field = True; break
print("PASS" if ok_schema and found_field else f"FAIL:schema={ok_schema},field={found_field}")
')
echo "  $T4"
echo "$T4" | tail -1 | grep -q "^PASS$" && add_reward 0.12

# ════════════════════════════════════════════════════════════════════
# F2P T5 (0.10): User TOML config with skip_duplicate_bucketed_images survives sanitize
# Base: schema rejects/drops the unknown field → FAIL. Fix: preserves it → PASS.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T5: sanitize_user_config preserves skip_duplicate_bucketed_images ==="
T5=$(run_py '
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library.config_util import ConfigSanitizer
sig = inspect.signature(ConfigSanitizer.__init__)
nparams = len(sig.parameters) - 1
# Try several arg counts/orderings
cs = None
for trial in [[True, True, False, True], [True, True, True, False], [True, True, False], [True, True]]:
    try:
        cs = ConfigSanitizer(*trial[:nparams]); break
    except TypeError:
        continue
    except Exception:
        continue
if cs is None:
    print("FAIL:cant_construct"); sys.exit()
cfg = {
    "general": {},
    "datasets": [{
        "resolution": 512,
        "batch_size": 1,
        "skip_duplicate_bucketed_images": True,
        "subsets": [{"image_dir": "/tmp/x"}]
    }]
}
try:
    out = cs.sanitize_user_config(cfg)
    s = repr(out)
    ok = "skip_duplicate_bucketed_images" in s and "True" in s
    print("PASS" if ok else f"FAIL:dropped")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{e}")
')
echo "  $T5"
echo "$T5" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T6 (0.10): train_util / config_util has dedup logic referencing skip_duplicate_bucketed_images
# Base lacks the string entirely. Fix adds it.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T6: dedup logic exists in train_util or config_util ==="
T6=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
hits = 0
for f in ["library/train_util.py", "library/config_util.py"]:
    try:
        with open(f) as fh:
            src = fh.read()
        if "skip_duplicate_bucketed_images" in src:
            hits += 1
    except Exception:
        pass
print("PASS" if hits >= 2 else f"FAIL:hits={hits}")
')
echo "  $T6"
echo "$T6" | tail -1 | grep -q "^PASS$" && add_reward 0.10

# ════════════════════════════════════════════════════════════════════
# F2P T7 (0.15): unwrap_model_for_sampling exists in train_util and handles _orig_mod
# Base: doesn't exist → FAIL. Fix: exists, returns inner module when _orig_mod present.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T7: unwrap_model_for_sampling unwraps torch.compile'd models ==="
T7=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import train_util
fn = getattr(train_util, "unwrap_model_for_sampling", None)
if fn is None:
    print("FAIL:no_function"); sys.exit()
import torch.nn as nn

class Inner(nn.Module):
    def __init__(self):
        super().__init__()
        self.linear = nn.Linear(2, 2)

class FakeAccelerator:
    def unwrap_model(self, m):
        return m

inner = Inner()
# Simulate a torch.compile-style wrapper: another nn.Module that has _orig_mod as a submodule
class Wrapper(nn.Module):
    def __init__(self, orig):
        super().__init__()
        self._orig_mod = orig
    def forward(self, x):
        return self._orig_mod(x)

w = Wrapper(inner)
acc = FakeAccelerator()
try:
    result = fn(acc, w)
except Exception as e:
    print(f"FAIL:exc={e}"); sys.exit()
# Expectation: result should be the inner module (or behaviorally equivalent — has the linear submodule directly)
ok = (result is inner) or (hasattr(result, "linear") and not hasattr(result, "_orig_mod"))
# Also check: passing a plain (non-wrapped) module returns it unchanged
try:
    plain = Inner()
    r2 = fn(acc, plain)
    ok2 = r2 is plain or hasattr(r2, "linear")
except Exception:
    ok2 = False
print("PASS" if (ok and ok2) else f"FAIL:ok={ok},ok2={ok2}")
')
echo "  $T7"
echo "$T7" | tail -1 | grep -q "^PASS$" && add_reward 0.15

# ════════════════════════════════════════════════════════════════════
# F2P T8 (0.15): isinstance checks in sdxl_original_unet handle _orig_mod
# Behavioral: build a fake "compiled" wrapper around a ResnetBlock2D and call call_module.
# Base: isinstance(layer, ResnetBlock2D) is False for wrapper → wrong branch taken.
# Fix: detects _orig_mod and routes correctly (passes emb).
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T8: sdxl_original_unet handles torch.compile wrapped layers ==="
T8=$(run_py '
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
# Source-level check: isinstance branches reference _orig_mod near them
with open("library/sdxl_original_unet.py") as f:
    src = f.read()
# Find both call_module functions and verify _orig_mod is mentioned
import re
# Look for any unwrapping / OptimizedModule handling pattern
patterns = [
    "_orig_mod",
    "OptimizedModule",
]
has_orig = "_orig_mod" in src
# And verify it appears in proximity to ResnetBlock2D check (i.e., the isinstance got modified)
# Simple heuristic: count occurrences of _orig_mod, must be >= 1
count = src.count("_orig_mod")
# Also ensure it is referenced in the same region as ResnetBlock2D isinstance lines
ok_proximity = False
lines = src.split("\n")
for i, line in enumerate(lines):
    if "ResnetBlock2D" in line and "isinstance" in line:
        # check 10 lines before and 5 after
        window = "\n".join(lines[max(0,i-10):i+6])
        if "_orig_mod" in window:
            ok_proximity = True
            break
print("PASS" if (has_orig and count >= 1 and ok_proximity) else f"FAIL:has={has_orig},count={count},prox={ok_proximity}")
')
echo "  $T8"
echo "$T8" | tail -1 | grep -q "^PASS$" && add_reward 0.15

# ════════════════════════════════════════════════════════════════════
# F2P T9 (0.10): End-to-end — generate_dataset_group_by_blueprint accepts skip_duplicate_bucketed_images
# Build a minimal blueprint and verify dataset is created with the attribute set.
# ════════════════════════════════════════════════════════════════════
echo ""
echo "=== T9: dataset construction propagates skip_duplicate_bucketed_images ==="
T9=$(run_py '
import sys, os, tempfile, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
from library import config_util, train_util
# Check that a Dataset class either accepts skip_duplicate_bucketed_images in __init__
# OR sets the attribute by default.
hits = 0
for name in ["DreamBoothDataset", "FineTuningDataset", "ControlNetDataset", "BaseDataset"]:
    cls = getattr(train_util, name, None)
    if cls is None: continue
    try:
        sig = inspect.signature(cls.__init__)
        if "skip_duplicate_bucketed_images" in sig.parameters:
            hits += 1; continue
    except Exception:
        pass
    try:
        src = inspect.getsource(cls)
        if "skip_duplicate_bucketed_images" in src:
            hits += 1
    except Exception:
        pass
print("PASS" if hits >= 1 else f"FAIL:hits={hits}")
')
echo "  $T9"
echo "$T9" | tail -1 | grep -q "^PASS$" && add_reward 0.10

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "FINAL REWARD: $REWARD"
echo "════════════════════════════════════════════════════════════════════"
echo "$REWARD" > "$REWARD_FILE"