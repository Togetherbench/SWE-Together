#!/usr/bin/env bash
#
# Verification tests for sd-scripts backward-compatibility task.
#
# The agent must add fallback support to SdSdxlLatentsCachingStrategy:
# when a resolution-suffixed npz key is not found, fall back to the
# unsuffixed "latents" key and validate its shape using metadata-only
# (header-only) reads — not by decompressing the full array.
#
# 14 tests, 108 points total.
#   Behavioral F2P  (80%): T1(13), T2(10), T3(5), T4(12), T4b(8), T5(22), T6(12)
#   Behavioral Silver (5%): T7(5)
#   Behavioral P2P   (5%): T8(1), T9(1), T10(3)
#   Structural Bronze (10%): T11(4), T12(4), T13(3)
#   Behavioral Scoping (Turn 3): T14(5) — non-SD strategies unchanged
#
# Nop protection: all F2P tests are gated on a CANARY check that
# verifies multi-resolution suffixed-key lookup works. If the base code
# doesn't use suffixed keys (synthesis broken or no changes), the canary
# fails and all F2P tests are skipped — preventing false passes from
# code that trivially finds unsuffixed "latents" keys.
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0

###############################################################################
# CANARY: verify that suffixed-key lookup is active (multi_resolution=True).
# If the code just looks for unsuffixed "latents" (synthesis broken or
# unmodified base), suffixed-only npz would be REJECTED. In that case, all
# F2P tests below are meaningless — they'd pass trivially because the code
# always finds unsuffixed keys.
###############################################################################

echo "=== CANARY: suffixed-key lookup is active ==="
CANARY_PASS=0
python3 << 'PYEOF'
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64
key_suffix = f"_{latents_h}x{latents_w}"  # "_64x64"

# Create suffixed-only npz (no unsuffixed "latents" key)
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path, **{
    f"latents{key_suffix}": np.ones((4, latents_h, latents_w), dtype=np.float32),
    f"original_size{key_suffix}": np.array([512, 512]),
    f"crop_ltrb{key_suffix}": np.array([0, 0, 0, 0]),
})

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: exception: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

if not result:
    print("FAIL: suffixed-only npz not accepted — multi_resolution not active")
    sys.exit(1)

print("PASS: suffixed-key lookup works (multi_resolution is active)")
sys.exit(0)
PYEOF
if [ $? -eq 0 ]; then
    CANARY_PASS=1
fi

if [ "$CANARY_PASS" -ne 1 ]; then
    echo ""
    echo "WARNING: canary failed — F2P tests will be skipped (base code does not use suffixed keys)"
    echo ""
fi

###############################################################################
# BEHAVIORAL F2P — CORE FALLBACK (Tests 1-4, 35pts)
# All gated on CANARY_PASS to prevent false positives from unsynthesized base.
###############################################################################

echo "=== Test 1/13: is_disk_cached_latents_expected accepts correct-shape legacy npz (13pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 13)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

# Legacy npz: unsuffixed "latents" key with correct shape
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path,
    latents=np.zeros((4, latents_h, latents_w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: raised {type(e).__name__}: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

if not result:
    print("FAIL: returned False for legacy npz with correct shape — fallback not working")
    sys.exit(1)

print("PASS: is_disk_cached_latents_expected=True for legacy unsuffixed npz")
sys.exit(0)
PYEOF
fi

echo ""
echo "=== Test 2/13: load_latents_from_disk loads from legacy unsuffixed npz (10pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 10)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

expected_latents = np.ones((4, latents_h, latents_w), dtype=np.float32) * 3.14
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path,
    latents=expected_latents,
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 12, 12]),
)

try:
    result = strat.load_latents_from_disk(npz_path, bucket_reso)
except Exception as e:
    print(f"FAIL: load_latents_from_disk raised: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

latents, original_size, crop_ltrb, flipped, alpha_mask = result

if latents is None:
    print("FAIL: loaded latents are None")
    sys.exit(1)

if latents.shape != (4, latents_h, latents_w):
    print(f"FAIL: wrong shape {latents.shape}, expected (4, {latents_h}, {latents_w})")
    sys.exit(1)

if abs(float(latents[0, 0, 0]) - 3.14) > 0.01:
    print(f"FAIL: wrong values, got {float(latents[0,0,0])}, expected ~3.14")
    sys.exit(1)

if original_size != [512, 512]:
    print(f"FAIL: wrong original_size {original_size}")
    sys.exit(1)

if crop_ltrb != [0, 0, 12, 12]:
    print(f"FAIL: wrong crop_ltrb {crop_ltrb}")
    sys.exit(1)

print("PASS: load_latents_from_disk loaded legacy npz correctly")
sys.exit(0)
PYEOF
fi

echo ""
echo "=== Test 3/13: is_disk_cached_latents_expected rejects wrong-shape legacy npz (5pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

# Gate: correct-shape must pass first (prevents free points from code that rejects all legacy)
fd1, correct_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
np.savez(correct_npz,
    latents=np.zeros((4, latents_h, latents_w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    gate = strat.is_disk_cached_latents_expected(bucket_reso, correct_npz, flip_aug=False, alpha_mask=False)
except Exception:
    gate = False
finally:
    if os.path.exists(correct_npz):
        os.unlink(correct_npz)

if not gate:
    print("FAIL: gate — correct-shape legacy npz not accepted, cannot verify wrong-shape rejection")
    sys.exit(1)

# Main check: wrong-shape must be rejected
fd2, wrong_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd2)
np.savez(wrong_npz,
    latents=np.zeros((4, 48, 64), dtype=np.float32),  # wrong H (48 != 64)
    original_size=np.array([512, 384]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, wrong_npz, flip_aug=False, alpha_mask=False)
except Exception:
    result = False  # exception also counts as rejection
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if result:
    print("FAIL: returned True for legacy npz with WRONG shape — should reject")
    sys.exit(1)

print("PASS: is_disk_cached_latents_expected=False for wrong-shape legacy npz")
sys.exit(0)
PYEOF
fi

echo ""
echo "=== Test 4/13: load_latents_from_disk rejects wrong-shape legacy npz (12pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 12)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

# Gate: correct-shape must load first
fd1, correct_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
np.savez(correct_npz,
    latents=np.ones((4, latents_h, latents_w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    latents, _, _, _, _ = strat.load_latents_from_disk(correct_npz, bucket_reso)
    gate = latents is not None and latents.shape == (4, latents_h, latents_w)
except Exception:
    gate = False
finally:
    if os.path.exists(correct_npz):
        os.unlink(correct_npz)

if not gate:
    print("FAIL: gate — correct-shape legacy load failed, cannot verify wrong-shape rejection")
    sys.exit(1)

# Main check: wrong-shape must raise or return None
fd2, wrong_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd2)
np.savez(wrong_npz,
    latents=np.zeros((4, 48, 64), dtype=np.float32),  # wrong H
    original_size=np.array([512, 384]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

rejected = False
try:
    result = strat.load_latents_from_disk(wrong_npz, bucket_reso)
    if result is None or result[0] is None:
        rejected = True
except Exception:
    rejected = True  # exception = rejection
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if not rejected:
    print("FAIL: load_latents_from_disk did not reject wrong-shape legacy npz")
    sys.exit(1)

print("PASS: load_latents_from_disk rejects wrong-shape legacy npz")
sys.exit(0)
PYEOF
fi

echo ""
echo "=== Test 4b/13: load_latents_from_disk rejects mismatched-resolution legacy npz (8pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 8)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

# Gate: correct-shape must load at 512x512 first
bucket_reso_512 = (512, 512)
h512 = bucket_reso_512[1] // 8  # 64
w512 = bucket_reso_512[0] // 8  # 64

fd1, correct_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
np.savez(correct_npz,
    latents=np.ones((4, h512, w512), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    latents, _, _, _, _ = strat.load_latents_from_disk(correct_npz, bucket_reso_512)
    gate = latents is not None and latents.shape == (4, h512, w512)
except Exception:
    gate = False
finally:
    if os.path.exists(correct_npz):
        os.unlink(correct_npz)

if not gate:
    print("FAIL: gate — correct-shape 512x512 legacy load failed")
    sys.exit(1)

# Main check: load 512x512-cached npz with 768x768 bucket — MUST reject
bucket_reso_768 = (768, 768)
h768 = bucket_reso_768[1] // 8  # 96
w768 = bucket_reso_768[0] // 8  # 96

fd2, wrong_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd2)
np.savez(wrong_npz,
    latents=np.ones((4, h512, w512), dtype=np.float32),  # 512x512 latents
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

rejected = False
try:
    result = strat.load_latents_from_disk(wrong_npz, bucket_reso_768)
    if result is None or result[0] is None:
        rejected = True
except Exception:
    rejected = True  # exception = rejection
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if not rejected:
    print("FAIL: load_latents_from_disk loaded 512x512 cached latents for 768x768 bucket — must raise or return None")
    sys.exit(1)

print("PASS: load_latents_from_disk rejects resolution-mismatched legacy npz")
sys.exit(0)
PYEOF
fi

###############################################################################
# BEHAVIORAL F2P — HEADER-ONLY PROOF (Tests 5-6, 34pts)
#
# These use corrupted npz files where npy data is truncated but
# the npy header is intact. A header-only reader extracts the shape;
# np.load()-based readers crash on the truncated data.
#
# Gated on CANARY_PASS to prevent false positives.
###############################################################################

echo ""
echo "=== Test 5/13: Truncated-data legacy npz with correct shape header accepted (22pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 22)) || true
import sys, os, io, tempfile, zipfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

shape = (4, latents_h, latents_w)
dtype = np.dtype('<f4')

# Create valid npy, then truncate data portion (keep header + 64 garbage bytes)
buf = io.BytesIO()
np.save(buf, np.zeros(shape, dtype=dtype))
full_npy = buf.getvalue()
data_size = int(np.prod(shape)) * dtype.itemsize  # 4*64*64*4 = 65536
header_size = len(full_npy) - data_size
npy_truncated = full_npy[:header_size] + b'\x00' * 64

# Small valid entries for other keys
buf_os = io.BytesIO(); np.save(buf_os, np.array([512, 512]))
buf_cl = io.BytesIO(); np.save(buf_cl, np.array([0, 0, 0, 0]))

# Build corrupted npz (valid zip, valid npy headers, truncated latents data)
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
with zipfile.ZipFile(npz_path, 'w') as zf:
    zf.writestr("latents.npy", npy_truncated)
    zf.writestr("original_size.npy", buf_os.getvalue())
    zf.writestr("crop_ltrb.npy", buf_cl.getvalue())

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: raised (likely using np.load on truncated data): {type(e).__name__}: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

if not result:
    print("FAIL: returned False — header-only read not working")
    sys.exit(1)

print("PASS: truncated-data legacy npz accepted (header-only shape read confirmed)")
sys.exit(0)
PYEOF
fi

echo ""
echo "=== Test 6/13: Truncated-data legacy npz with WRONG shape header rejected (12pts) ==="
if [ "$CANARY_PASS" -ne 1 ]; then
    echo "SKIP: canary failed"
else
python3 << 'PYEOF' && SCORE=$((SCORE + 12)) || true
import sys, os, io, tempfile, zipfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8
latents_w = bucket_reso[0] // 8
dtype = np.dtype('<f4')

# Gate: correct-shape truncated npz must pass first
correct_shape = (4, latents_h, latents_w)
buf = io.BytesIO(); np.save(buf, np.zeros(correct_shape, dtype=dtype))
full_npy = buf.getvalue()
data_size = int(np.prod(correct_shape)) * dtype.itemsize
header_size = len(full_npy) - data_size
npy_truncated = full_npy[:header_size] + b'\x00' * 64

buf_os = io.BytesIO(); np.save(buf_os, np.array([512, 512]))
buf_cl = io.BytesIO(); np.save(buf_cl, np.array([0, 0, 0, 0]))

fd1, gate_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
with zipfile.ZipFile(gate_npz, 'w') as zf:
    zf.writestr("latents.npy", npy_truncated)
    zf.writestr("original_size.npy", buf_os.getvalue())
    zf.writestr("crop_ltrb.npy", buf_cl.getvalue())

try:
    gate_result = strat.is_disk_cached_latents_expected(bucket_reso, gate_npz, flip_aug=False, alpha_mask=False)
except Exception:
    gate_result = False
finally:
    if os.path.exists(gate_npz):
        os.unlink(gate_npz)

if not gate_result:
    print("FAIL: gate — correct-shape truncated npz not accepted, cannot verify wrong-shape rejection")
    sys.exit(1)

# Main check: wrong-shape truncated npz
wrong_shape = (4, 48, 64)  # wrong H (48 != 64 expected)
buf2 = io.BytesIO(); np.save(buf2, np.zeros(wrong_shape, dtype=dtype))
full_npy2 = buf2.getvalue()
data_size2 = int(np.prod(wrong_shape)) * dtype.itemsize
header_size2 = len(full_npy2) - data_size2
npy_truncated2 = full_npy2[:header_size2] + b'\x00' * 64

fd2, wrong_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd2)
with zipfile.ZipFile(wrong_npz, 'w') as zf:
    zf.writestr("latents.npy", npy_truncated2)
    zf.writestr("original_size.npy", buf_os.getvalue())
    zf.writestr("crop_ltrb.npy", buf_cl.getvalue())

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, wrong_npz, flip_aug=False, alpha_mask=False)
except Exception:
    result = False  # exception = rejection
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if result:
    print("FAIL: returned True for truncated npz with WRONG shape header — should reject")
    sys.exit(1)

print("PASS: truncated-data npz with wrong shape rejected (header-only rejection confirmed)")
sys.exit(0)
PYEOF
fi

###############################################################################
# BEHAVIORAL — SILVER (Test 7, 5pts)
# Not gated on canary — tests existence of header reader method independently.
###############################################################################

echo ""
echo "=== Test 7/13: Header-only shape reader returns correct shape (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_base import LatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

# Create minimal concrete subclass
class TestStrategy(LatentsCachingStrategy):
    def cache_batch_latents(self, *a, **kw): pass

strat = TestStrategy(cache_to_disk=False, batch_size=1, skip_disk_cache_validity_check=False)

# Create test npz with known shape
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
test_arr = np.zeros((4, 16, 32), dtype=np.float32)
np.savez(npz_path, latents=test_arr)

# Discover shape reader method — accept canonical names and dynamic discovery
CANDIDATE_NAMES = [
    "_get_npz_array_shape_from_metadata",
    "_read_npy_shape_from_npz",
    "_read_npz_array_shape",
    "_get_npy_shape_from_npz",
    "_get_latent_shape_from_npz",
]

# Also dynamically discover any private method with shape/header/npy/meta in name
for name in dir(type(strat)):
    if name.startswith("_") and not name.startswith("__"):
        if any(kw in name for kw in ["shape", "npy", "header", "meta"]):
            if name not in CANDIDATE_NAMES:
                CANDIDATE_NAMES.append(name)

shape = None
method_used = None

# Search class methods first
for method_name in CANDIDATE_NAMES:
    method = getattr(strat, method_name, None)
    if method is None:
        continue
    # Try plausible call signatures
    for attempt in [
        lambda m: m(npz_path, "latents"),
        lambda m: m(np.load(npz_path), "latents"),
        lambda m: m(npz_path, "latents", None),
    ]:
        try:
            result = attempt(method)
            if result is not None:
                shape = result
                break
        except Exception:
            pass
    if shape is not None:
        method_used = method_name
        break

# Also search module-level functions in strategy_base.py and strategy_sd.py
if shape is None:
    import importlib
    for mod_name in ["library.strategy_base", "library.strategy_sd"]:
        try:
            mod = importlib.import_module(mod_name)
        except Exception:
            continue
        for name in dir(mod):
            if not name.startswith("_") or name.startswith("__"):
                continue
            if not any(kw in name for kw in ["shape", "npy", "header", "meta", "npz"]):
                continue
            func = getattr(mod, name, None)
            if not callable(func):
                continue
            for attempt in [
                lambda m: m(npz_path, "latents"),
                lambda m: m(npz_path, "latents", None),
            ]:
                try:
                    result = attempt(func)
                    if result is not None:
                        shape = result
                        method_used = name
                        break
                except Exception:
                    pass
            if shape is not None:
                break
        if shape is not None:
            break

os.unlink(npz_path)

if shape is None:
    print("FAIL: no callable header-only shape reader found")
    sys.exit(1)

if tuple(shape) != (4, 16, 32):
    print(f"FAIL: {method_used} returned {tuple(shape)}, expected (4, 16, 32)")
    sys.exit(1)

print(f"PASS: {method_used} returned correct shape {tuple(shape)}")
sys.exit(0)
PYEOF

###############################################################################
# BEHAVIORAL — PASS-TO-PASS (Tests 8-10, 12pts)
###############################################################################

echo ""
echo "=== Test 8/13: Resolution-suffixed npz still works (1pt) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 1)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8
latents_w = bucket_reso[0] // 8
key_suffix = f"_{latents_h}x{latents_w}"  # "_64x64"

# Modern (resolution-suffixed) npz
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path, **{
    f"latents{key_suffix}": np.ones((4, latents_h, latents_w), dtype=np.float32) * 2.71,
    f"original_size{key_suffix}": np.array([512, 512]),
    f"crop_ltrb{key_suffix}": np.array([0, 0, 0, 0]),
})

try:
    expected = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
    if not expected:
        print("FAIL: is_disk_cached_latents_expected=False for valid suffixed npz")
        sys.exit(1)

    latents, orig, crop, flipped, alpha = strat.load_latents_from_disk(npz_path, bucket_reso)
    if latents is None or latents.shape != (4, latents_h, latents_w):
        print(f"FAIL: wrong loaded shape {getattr(latents, 'shape', None)}")
        sys.exit(1)
    if abs(float(latents[0, 0, 0]) - 2.71) > 0.01:
        print(f"FAIL: wrong data — got {float(latents[0, 0, 0])}, expected ~2.71")
        sys.exit(1)
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

print(f"PASS: suffixed npz (key '{key_suffix}') still loads correctly")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 9/13: Both keys present — suffixed data preferred over legacy (1pt) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 1)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8
latents_w = bucket_reso[0] // 8
key_suffix = f"_{latents_h}x{latents_w}"

# NPZ with BOTH suffixed (value=7.0) and legacy (value=1.0) keys
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path, **{
    f"latents{key_suffix}": np.ones((4, latents_h, latents_w), dtype=np.float32) * 7.0,
    f"original_size{key_suffix}": np.array([512, 512]),
    f"crop_ltrb{key_suffix}": np.array([0, 0, 0, 0]),
    "latents": np.ones((4, latents_h, latents_w), dtype=np.float32) * 1.0,
    "original_size": np.array([512, 512]),
    "crop_ltrb": np.array([5, 5, 5, 5]),
})

try:
    latents, orig, crop, flipped, alpha = strat.load_latents_from_disk(npz_path, bucket_reso)
    if latents is None:
        print("FAIL: returned None")
        sys.exit(1)
    val = float(latents[0, 0, 0])
    if abs(val - 7.0) > 0.01:
        if abs(val - 1.0) < 0.01:
            print("FAIL: loaded legacy data (1.0) instead of suffixed data (7.0)")
        else:
            print(f"FAIL: unexpected value {val}")
        sys.exit(1)
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

print("PASS: suffixed data preferred over legacy when both present")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 10/13: Upstream test suite pass-to-pass (3pts) ==="
TEST_DIR="/workspace/sd-scripts/tests"
if [ -d "$TEST_DIR" ]; then
    TARGET="$TEST_DIR"
    [ -d "$TEST_DIR/library" ] && TARGET="$TEST_DIR/library"
    timeout 45 python3 -m pytest "$TARGET" -x --timeout=30 -q 2>&1
    P2P_RC=$?
    if [ $P2P_RC -eq 0 ]; then
        SCORE=$((SCORE + 3))
        echo "PASS: upstream tests pass — no regressions"
    else
        echo "FAIL: upstream tests failed (exit=$P2P_RC)"
    fi
else
    echo "SKIP: no upstream tests found at $TEST_DIR"
fi

###############################################################################
# STRUCTURAL — BRONZE (Tests 11-12, 8pts)
###############################################################################

echo ""
echo "=== Test 11/13: Header-only method uses zip/stream approach (4pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 4)) || true
import sys, ast

# Main methods that are NOT dedicated header readers
EXCLUDED = {
    "_default_is_disk_cached_latents_expected", "_default_load_latents_from_disk",
    "_default_cache_batch_latents", "is_disk_cached_latents_expected",
    "load_latents_from_disk", "cache_batch_latents",
}

KNOWN_NAMES = {
    "_get_npz_array_shape_from_metadata", "_read_npy_shape_from_npz",
    "_read_npz_array_shape", "_get_npy_shape_from_npz", "_get_latent_shape_from_npz",
}

def has_zip_access(src):
    return any(kw in src for kw in [".zip", "zipfile", "ZipFile", ".open("])

def has_header_read(src):
    return any(kw in src for kw in [
        "read_magic", "_read_array_header", "read_array_header",
        "_format_impl", "format.", "header",
    ])

for filepath in ["/workspace/sd-scripts/library/strategy_base.py", "/workspace/sd-scripts/library/strategy_sd.py"]:
    with open(filepath) as f:
        src = f.read()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if not isinstance(node, ast.ClassDef):
            continue
        if node.name not in ("LatentsCachingStrategy", "SdSdxlLatentsCachingStrategy"):
            continue
        for item in node.body:
            if not isinstance(item, ast.FunctionDef) or item.name in EXCLUDED:
                continue
            item_src = ast.unparse(item) if hasattr(ast, "unparse") else str(ast.dump(item))
            is_candidate = item.name in KNOWN_NAMES or (
                ("shape" in item_src.lower() or "header" in item_src.lower()) and has_zip_access(item_src)
            )
            if not is_candidate:
                continue
            # Reject stubs: require >= 1 non-docstring statement (a single try block is valid)
            stmts = [s for s in item.body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant,)))]
            if len(stmts) < 1:
                continue
            if not has_zip_access(item_src):
                print(f"FAIL: {item.name}: no zip/stream approach")
                sys.exit(1)
            if not has_header_read(item_src):
                print(f"FAIL: {item.name}: no header-reading logic")
                sys.exit(1)
            if "np.load(" in item_src:
                print(f"FAIL: {item.name}: uses np.load (loads full array)")
                sys.exit(1)
            print(f"PASS: {item.name} uses zip stream + header read")
            sys.exit(0)

# Fallback A: check module-level functions with zip/stream + header read
for filepath in ["/workspace/sd-scripts/library/strategy_base.py", "/workspace/sd-scripts/library/strategy_sd.py"]:
    with open(filepath) as f:
        src = f.read()
    tree = ast.parse(src)
    for item in tree.body:
        if not isinstance(item, ast.FunctionDef):
            continue
        item_src = ast.unparse(item) if hasattr(ast, "unparse") else str(ast.dump(item))
        is_candidate = any(kw in item.name.lower() for kw in ["shape", "header", "npy", "meta", "npz"]) \
            and has_zip_access(item_src)
        if not is_candidate:
            continue
        stmts = [s for s in item.body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant,)))]
        if len(stmts) < 1:
            continue
        if has_zip_access(item_src) and has_header_read(item_src) and "np.load(" not in item_src:
            print(f"PASS: module-level {item.name} uses zip stream + header read")
            sys.exit(0)

# Fallback B: check if header reading is inlined in _default_is_disk_cached_latents_expected
for filepath in ["/workspace/sd-scripts/library/strategy_base.py"]:
    with open(filepath) as f:
        src = f.read()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "LatentsCachingStrategy":
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == "_default_is_disk_cached_latents_expected":
                    item_src = ast.unparse(item) if hasattr(ast, "unparse") else str(ast.dump(item))
                    if has_zip_access(item_src) and has_header_read(item_src):
                        print("PASS: header reading inlined in _default_is_disk_cached_latents_expected")
                        sys.exit(0)

print("FAIL: no zip/stream header-only approach found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 12/13: SdSdxl enables fallback for backward compat (4pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 4)) || true
import sys, ast, re

# Approach 1: SdSdxl passes fallback keyword in a call to base class
with open("/workspace/sd-scripts/library/strategy_sd.py") as f:
    sd_src = f.read()

sd_tree = ast.parse(sd_src)
for node in ast.walk(sd_tree):
    if isinstance(node, ast.ClassDef) and node.name == "SdSdxlLatentsCachingStrategy":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name in ("is_disk_cached_latents_expected", "load_latents_from_disk"):
                for subnode in ast.walk(item):
                    if isinstance(subnode, ast.Call):
                        for kw in subnode.keywords:
                            if kw.arg and "fallback" in kw.arg.lower():
                                print(f"PASS: {item.name} passes fallback keyword arg")
                                sys.exit(0)

# Approach 2: fallback logic is inline in the base class with unsuffixed key check
with open("/workspace/sd-scripts/library/strategy_base.py") as f:
    base_src = f.read()

base_tree = ast.parse(base_src)
for node in ast.walk(base_tree):
    if isinstance(node, ast.ClassDef) and node.name == "LatentsCachingStrategy":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "_default_is_disk_cached_latents_expected":
                body_src = " ".join(ast.unparse(s) for s in item.body) if hasattr(ast, "unparse") else ""
                has_suffixed = bool(re.search(r"""['"]latents['"][\s]*\+""", body_src))
                has_unsuffixed = bool(re.search(r"""['"]latents['"](?![\s]*\+)""", body_src))
                if has_suffixed and has_unsuffixed and "suffix" in body_src:
                    print("PASS: base class has inline fallback logic with unsuffixed key check")
                    sys.exit(0)

print("FAIL: no fallback enablement found in SdSdxl or base class")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 13/13: Metadata-only shape read integrated into fallback path (3pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 3)) || true
import sys, ast
#
# Verifies that the code path which falls back to the unsuffixed "latents"
# key performs a METADATA-ONLY shape read — not np.load on the fallback key.
#
# Accepts EITHER:
#   (A) calls a self-method whose name suggests header/metadata/shape reading
#       (e.g. self._get_npz_array_shape_from_metadata(...)); OR
#   (B) inlines a numpy.lib.format private-API call (read_magic /
#       _read_array_header / read_array_header_1_0 / read_array_header_2_0)
#       alongside zip-member access (.zip.open / zipfile.open).
#
# The check is scoped to the fallback branch — the function must reference
# both suffixed and unsuffixed "latents" keys (i.e. actually implement fallback).
#
METADATA_CALL_HINTS = ("shape_from_metadata", "shape_from_npz", "npy_shape",
                      "npz_array_shape", "npz_shape", "header_shape",
                      "read_array_shape", "array_shape_from", "shape_from_header",
                      "metadata_shape", "read_npz_header", "get_npz_array")
NUMPY_FORMAT_APIS = ("read_magic", "_read_array_header",
                     "read_array_header_1_0", "read_array_header_2_0")
ZIP_STREAM_HINTS = (".zip.open", "zipfile.ZipFile", "ZipFile(", ".open(")

FALLBACK_FUNCS = ("_default_is_disk_cached_latents_expected",
                  "_default_load_latents_from_disk",
                  "is_disk_cached_latents_expected",
                  "load_latents_from_disk")

def iter_class_methods(tree, class_names):
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name in class_names:
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    yield item

found_metadata_integrated_fallback = False
reasons = []

for filepath in ["/workspace/sd-scripts/library/strategy_base.py",
                 "/workspace/sd-scripts/library/strategy_sd.py"]:
    try:
        with open(filepath) as f:
            src = f.read()
        tree = ast.parse(src)
    except Exception as e:
        reasons.append(f"{filepath}: parse error {e}")
        continue

    classes = ("LatentsCachingStrategy", "SdSdxlLatentsCachingStrategy")
    for fn in iter_class_methods(tree, classes):
        if fn.name not in FALLBACK_FUNCS:
            continue
        fn_src = ast.unparse(fn) if hasattr(ast, "unparse") else ""
        # Must reference both "latents"+suffix and an unsuffixed "latents" probe
        import re as re13
        has_suffixed = bool(re13.search(r"""['"]latents['"][\s]*\+""", fn_src)) \
                       or ('f"latents{' in fn_src) or ("f'latents{" in fn_src)
        # Use negative lookahead to find bare 'latents' NOT followed by ' +'
        has_unsuffixed = bool(re13.search(r"""['"]latents['"](?![\s]*\+)""", fn_src))
        if not (has_suffixed and has_unsuffixed):
            continue

        calls_metadata_helper = any(hint in fn_src for hint in METADATA_CALL_HINTS)
        uses_numpy_format_api = any(api in fn_src for api in NUMPY_FORMAT_APIS)
        uses_zip_stream = any(hint in fn_src for hint in ZIP_STREAM_HINTS)

        if calls_metadata_helper:
            found_metadata_integrated_fallback = True
            reasons.append(f"{fn.name}: calls metadata helper")
            break
        if uses_numpy_format_api and uses_zip_stream:
            found_metadata_integrated_fallback = True
            reasons.append(f"{fn.name}: inlines numpy.lib.format API + zip stream")
            break
    if found_metadata_integrated_fallback:
        break

if not found_metadata_integrated_fallback:
    print("FAIL: fallback code path does not integrate a metadata-only shape read")
    print("       (expected either a self-method call to a metadata-shape helper,")
    print("        or inline numpy.lib.format API + zip-stream access in a function")
    print("        that probes both 'latents'+suffix and unsuffixed 'latents')")
    sys.exit(1)

print(f"PASS: {reasons[0]}")
sys.exit(0)
PYEOF

###############################################################################
# BEHAVIORAL — SCOPING (Test 14, 5pts)
#
# Turn 3 constraint: "We only need to add backward compatibility for SD1/SDXL.
# Or you can implement it in the base class if it's simpler and does not
# change the current behavior."
#
# Verifies that non-SD strategies (multi_resolution=False, no fallback opt-in)
# retain unchanged behavior — i.e., the fallback is SCOPED and not applied
# universally. Catches regressions where fallback leaks into the default path.
###############################################################################

echo ""
echo "=== Test 14/14: Non-SD strategy behavior preserved — fallback is SD-only (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, os, tempfile, inspect, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_base import LatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

class TestStrategy(LatentsCachingStrategy):
    def cache_batch_latents(self, *a, **kw): pass

strat = TestStrategy(cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

# Check A (AST-ish via inspect): any `fallback_*suffix*` param must default False.
for mname in ("_default_is_disk_cached_latents_expected", "_default_load_latents_from_disk"):
    m = getattr(strat, mname, None)
    if m is None:
        continue
    try:
        sig = inspect.signature(m)
    except (TypeError, ValueError):
        continue
    for pname, p in sig.parameters.items():
        low = pname.lower()
        if "fallback" in low and ("suffix" in low or "resolution" in low or "legacy" in low):
            if p.default is not False:
                print(f"FAIL: {mname}.{pname} default={p.default!r} — must be False so non-SD strategies keep current behavior (opt-in only)")
                sys.exit(1)

# Check B (behavioral): non-SD path (multi_resolution=False) must still accept
# legacy unsuffixed npz — that's pre-existing non-SD behavior and must not
# regress under Turn 3's "does not change the current behavior" constraint.
bucket_reso = (512, 512)
lh, lw = bucket_reso[1] // 8, bucket_reso[0] // 8

fd, path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(path,
    latents=np.zeros((4, lh, lw), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

result = None
err = None
try:
    # Preferred signature: multi_resolution kwarg present (base state).
    result = strat._default_is_disk_cached_latents_expected(
        8, bucket_reso, path, False, False, multi_resolution=False,
    )
except TypeError:
    try:
        result = strat._default_is_disk_cached_latents_expected(
            8, bucket_reso, path, False, False,
        )
    except Exception as e:
        err = e
except Exception as e:
    err = e
finally:
    if os.path.exists(path):
        os.unlink(path)

if err is not None:
    print(f"FAIL: non-SD call raised {type(err).__name__}: {err}")
    sys.exit(1)

if not result:
    print("FAIL: non-SD path (multi_resolution=False) rejects legacy unsuffixed npz — breaks pre-existing non-SD behavior")
    sys.exit(1)

print("PASS: non-SD strategy behavior preserved (fallback is opt-in, default-off)")
sys.exit(0)
PYEOF

###############################################################################
# FINAL SCORE
###############################################################################

echo ""
echo "================================"
echo "Weighted score: $SCORE / 108"
echo "================================"

REWARD=$(python3 -c "print(min(1.0, round($SCORE / 108, 2)))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
