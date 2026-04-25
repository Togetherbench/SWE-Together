#!/bin/bash
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REPO="/workspace/sd-scripts"
SCORE=0
MAX=100

cd "$REPO" 2>/dev/null || { echo "0.0" > "$REWARD_FILE"; exit 0; }

###############################################################################
# CANARY: check that suffixed-key path still works (regression guard).
# Worth 15 pts (P2P regression). If this fails, multi-resolution is broken.
###############################################################################
echo "=== CANARY (P2P, 15pts): suffixed-key lookup still works ==="
python3 << 'PYEOF'
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL import: {e}"); sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512)
h, w = 64, 64
sfx = f"_{h}x{w}"
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p, **{
    f"latents{sfx}": np.ones((4, h, w), dtype=np.float32),
    f"original_size{sfx}": np.array([512, 512]),
    f"crop_ltrb{sfx}": np.array([0, 0, 0, 0]),
})
try:
    ok = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    if not ok:
        print("FAIL: suffixed-key not accepted"); sys.exit(1)
    lat, osz, cltrb, flip, am = strat.load_latents_from_disk(p, bucket)
    if lat is None or lat.shape != (4, h, w):
        print(f"FAIL: load shape {None if lat is None else lat.shape}"); sys.exit(1)
    print("PASS canary")
finally:
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 15))

###############################################################################
# F2P-1: is_disk_cached_latents_expected accepts legacy unsuffixed npz (15pts)
###############################################################################
echo ""
echo "=== F2P-1 (15pts): legacy unsuffixed npz accepted by is_disk_cached_latents_expected ==="
python3 << 'PYEOF'
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
    if not r:
        print("FAIL: returned False"); sys.exit(1)
    print("PASS")
except Exception as e:
    print(f"FAIL: {type(e).__name__}: {e}"); sys.exit(1)
finally:
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 15))

###############################################################################
# F2P-2: is_disk_cached_latents_expected rejects WRONG-shape legacy (15pts)
# This requires checking shape WITHOUT decompressing fully.
###############################################################################
echo ""
echo "=== F2P-2 (15pts): wrong-shape legacy npz rejected ==="
python3 << 'PYEOF'
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
# wrong shape: 32x32 instead of 64x64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, 32, 32), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    if r:
        print("FAIL: wrong-shape accepted"); sys.exit(1)
    print("PASS")
except Exception as e:
    print(f"FAIL: raised {type(e).__name__}: {e}"); sys.exit(1)
finally:
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 15))

###############################################################################
# F2P-3: load_latents_from_disk loads legacy npz with correct values (15pts)
###############################################################################
echo ""
echo "=== F2P-3 (15pts): load_latents_from_disk reads legacy npz correctly ==="
python3 << 'PYEOF'
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
    if lat is None or lat.shape != (4, h, w):
        print(f"FAIL shape: {None if lat is None else lat.shape}"); sys.exit(1)
    if abs(float(lat[0,0,0]) - 2.71) > 0.01:
        print(f"FAIL value: {float(lat[0,0,0])}"); sys.exit(1)
    if list(osz) != [768, 512]:
        print(f"FAIL osz: {osz}"); sys.exit(1)
    if list(cltrb) != [1, 2, 3, 4]:
        print(f"FAIL cltrb: {cltrb}"); sys.exit(1)
    print("PASS")
except Exception as e:
    print(f"FAIL: {type(e).__name__}: {e}"); sys.exit(1)
finally:
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 15))

###############################################################################
# F2P-4: METADATA-ONLY shape check (no full decompress) (20pts)
# Build a HUGE npz with bogus shape; if code decompresses, it'll be slow/use
# lots of memory. We use np.lib.format trickery: create a file where the
# zipped array body is corrupted/truncated but the header is intact.
# We test by checking that for a legacy npz with WRONG shape, the rejection
# happens via header inspection (np.lib.format.read_magic / read_array_header)
# rather than np.load(...)["latents"].shape which would decompress.
#
# We instrument by monkey-patching numpy.load to detect full decompression
# of the legacy "latents" key during the existence/shape check.
###############################################################################
echo ""
echo "=== F2P-4 (20pts): metadata-only shape check (no full decompress) ==="
python3 << 'PYEOF'
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy

# Track whether full decompression of "latents" array happens during the
# is_disk_cached_latents_expected call.
import zipfile
orig_zip_open = zipfile.ZipFile.open
decompress_count = {"n": 0}

def tracking_open(self, name, *a, **kw):
    n = name.filename if hasattr(name, "filename") else str(name)
    if "latents.npy" in n and not any(s in n for s in ["_64x64", "_32x32", "original_size", "crop_ltrb"]):
        # Read of unsuffixed latents body
        decompress_count["n"] += 1
    return orig_zip_open(self, name, *a, **kw)

zipfile.ZipFile.open = tracking_open

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
# Make a moderately-sized array
np.savez(p,
    latents=np.zeros((4, h, w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    decompress_count["n"] = 0
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    if not r:
        print("FAIL: legacy not accepted at all"); sys.exit(1)
    if decompress_count["n"] > 0:
        print(f"FAIL: full decompression of 'latents' happened ({decompress_count['n']} times) — should use header-only metadata read")
        sys.exit(1)
    print("PASS: shape check used metadata only")
finally:
    zipfile.ZipFile.open = orig_zip_open
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 20))

###############################################################################
# Structural-1: prefer suffixed key over unsuffixed when both present (10pts)
###############################################################################
echo ""
echo "=== Structural-1 (10pts): suffixed key preferred when both present ==="
python3 << 'PYEOF'
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
sfx = f"_{h}x{w}"
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
suffixed_val = np.ones((4, h, w), dtype=np.float32) * 7.0
unsuffixed_val = np.ones((4, h, w), dtype=np.float32) * 1.0
np.savez(p, **{
    f"latents{sfx}": suffixed_val,
    f"original_size{sfx}": np.array([512, 512]),
    f"crop_ltrb{sfx}": np.array([0, 0, 0, 0]),
    "latents": unsuffixed_val,
    "original_size": np.array([1, 1]),
    "crop_ltrb": np.array([9, 9, 9, 9]),
})
try:
    res = strat.load_latents_from_disk(p, bucket)
    lat = res[0]
    if lat is None:
        print("FAIL: None"); sys.exit(1)
    v = float(lat[0,0,0])
    if abs(v - 7.0) > 0.01:
        print(f"FAIL: got {v}, suffixed should be preferred"); sys.exit(1)
    print("PASS")
except Exception as e:
    print(f"FAIL: {e}"); sys.exit(1)
finally:
    os.unlink(p)
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 10))

###############################################################################
# Structural-2: uses numpy.lib.format private API (header-only read) (5pts)
###############################################################################
echo ""
echo "=== Structural-2 (5pts): code uses numpy.lib.format for header-only read ==="
F=""
for cand in "$REPO/library/strategy_sd.py" "$REPO/library/strategy_base.py"; do
    [ -f "$cand" ] && F="$F $cand"
done
if [ -n "$F" ] && grep -E "numpy\.lib\.format|np\.lib\.format|read_array_header|read_magic|from numpy\.lib import format|from numpy\.lib\.format" $F > /dev/null 2>&1; then
    echo "PASS"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: no use of numpy.lib.format header-only API found"
fi

###############################################################################
# P2P-2: non-existent file returns False, not raise (5pts)
###############################################################################
echo ""
echo "=== P2P-2 (5pts): non-existent file returns False ==="
python3 << 'PYEOF'
import sys
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
try:
    r = strat.is_disk_cached_latents_expected((512,512), "/tmp/__no_such_file_xyz.npz", flip_aug=False, alpha_mask=False)
    if r:
        print("FAIL: returned True for missing file"); sys.exit(1)
    print("PASS")
except Exception as e:
    # Acceptable if it raises FileNotFoundError-like; but ideally returns False.
    # Be lenient: accept either.
    print(f"PASS (raised {type(e).__name__})")
PYEOF
[ $? -eq 0 ] && SCORE=$((SCORE + 5))

###############################################################################
REWARD=$(awk -v s="$SCORE" -v m="$MAX" 'BEGIN{printf "%.3f", s/m}')
echo ""
echo "=== SCORE: $SCORE / $MAX -> $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"