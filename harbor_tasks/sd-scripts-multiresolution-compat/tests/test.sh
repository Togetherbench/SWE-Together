#!/usr/bin/env bash
#
# Verification tests for sd-scripts backward-compatibility task.
#
# The agent must add fallback support to SdSdxlLatentsCachingStrategy:
# when a resolution-suffixed npz key is not found, fall back to the
# unsuffixed "latents" key and validate its shape using metadata-only
# (header-only) reads — not by decompressing the full array.
#
# 12 tests, 100 points total.
#   Behavioral F2P  (70%): T1(15), T2(10), T3(5), T4(5), T5(20), T6(15)
#   Behavioral Silver (5%): T7(5)
#   Behavioral P2P  (15%): T8(5), T9(5), T10(5)
#   Structural Bronze (10%): T11(5), T12(5)
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0

###############################################################################
# BEHAVIORAL F2P — CORE FALLBACK (Tests 1-4, 35pts)
###############################################################################

echo "=== Test 1/12: is_disk_cached_latents_expected accepts correct-shape legacy npz (15pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 15)) || true
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

echo ""
echo "=== Test 2/12: load_latents_from_disk loads from legacy unsuffixed npz (10pts) ==="
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

echo ""
echo "=== Test 3/12: is_disk_cached_latents_expected rejects wrong-shape legacy npz (5pts) ==="
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

echo ""
echo "=== Test 4/12: load_latents_from_disk rejects wrong-shape legacy npz (5pts) ==="
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

###############################################################################
# BEHAVIORAL F2P — HEADER-ONLY PROOF (Tests 5-6, 35pts)
#
# These use corrupted npz files where npy data is truncated but
# the npy header is intact. A header-only reader extracts the shape;
# np.load()-based readers crash on the truncated data.
###############################################################################

echo ""
echo "=== Test 5/12: Truncated-data legacy npz with correct shape header accepted (20pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 20)) || true
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

echo ""
echo "=== Test 6/12: Truncated-data legacy npz with WRONG shape header rejected (15pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 15)) || true
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

###############################################################################
# BEHAVIORAL — SILVER (Test 7, 5pts)
###############################################################################

echo ""
echo "=== Test 7/12: Header-only shape reader returns correct shape (5pts) ==="
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
# BEHAVIORAL — PASS-TO-PASS (Tests 8-10, 15pts)
###############################################################################

echo ""
echo "=== Test 8/12: Resolution-suffixed npz still works (5pts) ==="
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
echo "=== Test 9/12: Both keys present — suffixed data preferred over legacy (5pts) ==="
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
echo "=== Test 10/12: Upstream test suite pass-to-pass (5pts) ==="
TEST_DIR="/workspace/sd-scripts/tests"
if [ -d "$TEST_DIR" ]; then
    TARGET="$TEST_DIR"
    [ -d "$TEST_DIR/library" ] && TARGET="$TEST_DIR/library"
    timeout 45 python3 -m pytest "$TARGET" -x --timeout=30 -q 2>&1
    P2P_RC=$?
    if [ $P2P_RC -eq 0 ]; then
        SCORE=$((SCORE + 5))
        echo "PASS: upstream tests pass — no regressions"
    else
        echo "FAIL: upstream tests failed (exit=$P2P_RC)"
    fi
else
    echo "SKIP: no upstream tests found at $TEST_DIR"
fi

###############################################################################
# STRUCTURAL — BRONZE (Tests 11-12, 10pts)
###############################################################################

echo ""
echo "=== Test 11/12: Header-only method uses zip/stream approach (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
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
            # Reject stubs: require >= 2 non-docstring statements
            stmts = [s for s in item.body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant,)))]
            if len(stmts) < 2:
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

# Fallback: check if header reading is inlined in _default_is_disk_cached_latents_expected
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
echo "=== Test 12/12: SdSdxl enables fallback for backward compat (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
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

###############################################################################
# FINAL SCORE
###############################################################################

echo ""
echo "================================"
echo "Weighted score: $SCORE / 100"
echo "================================"

REWARD=$(python3 -c "print(min(1.0, round($SCORE / 100, 2)))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
