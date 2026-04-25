#!/bin/bash
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REPO="/workspace/sd-scripts"
REWARD=0.0

cd "$REPO" 2>/dev/null || { echo "0.0" > "$REWARD_FILE"; exit 0; }

# P2P GATE: import works and suffixed-key path still functions (regression guard).
# This passes on the buggy base (multi-resolution was just enabled), so it's a gate, not reward.
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64; sfx = f"_{h}x{w}"
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p, **{
    f"latents{sfx}": np.ones((4, h, w), dtype=np.float32),
    f"original_size{sfx}": np.array([512, 512]),
    f"crop_ltrb{sfx}": np.array([0, 0, 0, 0]),
})
try:
    ok = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert ok, "suffixed-key not accepted"
    lat, osz, cltrb, flip, am = strat.load_latents_from_disk(p, bucket)
    assert lat is not None and lat.shape == (4, h, w)
finally:
    os.unlink(p)
PYEOF
GATE=$?
if [ $GATE -ne 0 ]; then
    echo "P2P gate failed (regression on suffixed-key path)"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

###############################################################################
# F2P-1 (weight 0.20): is_disk_cached_latents_expected accepts legacy unsuffixed npz.
# On buggy base: only suffixed key is checked, so legacy returns False → fails.
###############################################################################
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, h, w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert r, "legacy not accepted"
finally:
    os.unlink(p)
PYEOF
F2P1=$?

###############################################################################
# F2P-2 (weight 0.20): wrong-shape legacy npz must be rejected.
###############################################################################
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, 32, 32), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert not r, "wrong-shape legacy accepted"
finally:
    os.unlink(p)
PYEOF
F2P2=$?

###############################################################################
# F2P-3 (weight 0.25): load_latents_from_disk reads legacy npz with correct values.
###############################################################################
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
expected = np.ones((4, h, w), dtype=np.float32) * 2.71
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=expected,
    original_size=np.array([768, 512]),
    crop_ltrb=np.array([1, 2, 3, 4]),
)
try:
    res = strat.load_latents_from_disk(p, bucket)
    lat, osz, cltrb = res[0], res[1], res[2]
    assert lat is not None and lat.shape == (4, h, w), f"shape {None if lat is None else lat.shape}"
    assert abs(float(lat[0,0,0]) - 2.71) < 0.01, f"value {float(lat[0,0,0])}"
    assert list(osz) == [768, 512], f"osz {osz}"
    assert list(cltrb) == [1, 2, 3, 4], f"cltrb {cltrb}"
finally:
    os.unlink(p)
PYEOF
F2P3=$?

###############################################################################
# F2P-4 (weight 0.20): metadata-only shape check during is_disk_cached_latents_expected
# (does NOT decompress full latents body for legacy unsuffixed npz).
###############################################################################
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy

import zipfile
orig_zip_open = zipfile.ZipFile.open
decompress_count = {"n": 0}

def tracking_open(self, name, *a, **kw):
    n = name.filename if hasattr(name, "filename") else str(name)
    # The unsuffixed latents body would be stored as "latents.npy" inside the zip
    base = os.path.basename(n)
    if base == "latents.npy":
        decompress_count["n"] += 1
    return orig_zip_open(self, name, *a, **kw)

zipfile.ZipFile.open = tracking_open

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, h, w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    decompress_count["n"] = 0
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert r, "legacy not accepted"
    # Reading via np.lib.format.read_array_header from the zip's open stream
    # still calls ZipFile.open once to get the stream; but np.load(...)["latents"]
    # also opens it. The distinguishing factor is whether the ARRAY IS FULLY READ.
    # We use a stricter check: did the code call the body open more than zero times
    # AND did it not just read header? Detect by reading file size cheaply.
    # Use a more sensitive marker: size of decompressed reads.
finally:
    os.unlink(p)
PYEOF
F2P4_BASIC=$?

# More robust F2P-4: check that np.load() is NOT used to retrieve full latents
# during is_disk_cached_latents_expected on a legacy npz. Use a sentinel where
# np.load(...)["latents"] would return a HUGE array but np.lib.format header
# reads cheap shape info.
python3 << 'PYEOF' >/dev/null 2>&1
import sys, os, tempfile, numpy as np, time, tracemalloc
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64

# Build a fairly large latents array to make decompression measurable.
big_h, big_w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
# Use uncompressed savez to make zip "open" of body identifiable.
np.savez(p,
    latents=np.zeros((4, big_h, big_w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

# Monkey-patch np.load to detect calls returning a dict-like that gives full latents.
import numpy as _np
orig_load = _np.load
load_calls = {"n": 0, "latents_accessed": 0}

class WrappedNpz:
    def __init__(self, obj):
        self._obj = obj
    def __getitem__(self, k):
        if k == "latents":
            load_calls["latents_accessed"] += 1
        return self._obj[k]
    def __contains__(self, k):
        return k in self._obj
    def keys(self):
        return self._obj.keys()
    def close(self):
        return self._obj.close()
    def __enter__(self):
        self._obj.__enter__()
        return self
    def __exit__(self, *a):
        return self._obj.__exit__(*a)
    def __getattr__(self, k):
        return getattr(self._obj, k)
    @property
    def files(self):
        return self._obj.files

def wrapped_load(*a, **kw):
    load_calls["n"] += 1
    res = orig_load(*a, **kw)
    if hasattr(res, "files"):
        return WrappedNpz(res)
    return res

_np.load = wrapped_load

try:
    load_calls["latents_accessed"] = 0
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert r, "legacy not accepted"
    # The fix should use np.lib.format header reading, NOT np.load(...)["latents"]
    assert load_calls["latents_accessed"] == 0, f"latents fully accessed {load_calls['latents_accessed']} times"
finally:
    _np.load = orig_load
    os.unlink(p)
PYEOF
F2P4_STRICT=$?

# Compute reward
add() { REWARD=$(awk "BEGIN{print $REWARD + $1}"); }

[ $F2P1 -eq 0 ] && add 0.20
[ $F2P2 -eq 0 ] && add 0.20
[ $F2P3 -eq 0 ] && add 0.25
[ $F2P4_BASIC -eq 0 ] && [ $F2P4_STRICT -eq 0 ] && add 0.35

echo "F2P1=$F2P1 F2P2=$F2P2 F2P3=$F2P3 F2P4_BASIC=$F2P4_BASIC F2P4_STRICT=$F2P4_STRICT"
echo "REWARD=$REWARD"

echo "$REWARD" > /logs/verifier/reward.txt