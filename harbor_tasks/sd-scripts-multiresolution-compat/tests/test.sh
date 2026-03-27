#!/usr/bin/env bash
#
# Verification tests for sd-scripts backward-compatibility task.
#
# The agent must add fallback support to SdSdxlLatentsCachingStrategy:
# when a resolution-suffixed npz key is not found, fall back to the
# unsuffixed "latents" key and validate its shape using metadata-only
# (header-only) reads — not by decompressing the full array.
#
# Weighted scoring: SCORE accumulates in hundredths (100 = 1.0).
#   Structural (20%): T1(5), T2(5), T3(5), T9(5)
#   Behavioral fallback (25%): T4(5), T6(5), T7(5), T8(5), T10(5)
#   Behavioral header-only (55%): T5(15), T11(20), T12(20)
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0

STRATEGY_BASE="/workspace/sd-scripts/library/strategy_base.py"
STRATEGY_SD="/workspace/sd-scripts/library/strategy_sd.py"

###############################################################################
# STRUCTURAL CHECKS (20% — Tests 1-3, 9)
###############################################################################

echo "=== Test 1/12: header-only npz shape reader method exists (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, ast

# Accept any of the canonical names the original session used OR alternative valid names
ACCEPTED_NAMES = {
    "_get_npz_array_shape_from_metadata",  # ground truth session name
    "_read_npy_shape_from_npz",            # alt name
    "_read_npz_array_shape",               # alt name
    "_get_npy_shape_from_npz",             # alt name (npy variant)
    "_get_latent_shape_from_npz",          # alt name
}

def has_zip_stream_access(item_src):
    return any(kw in item_src for kw in [".zip", "zipfile", "ZipFile", ".open(", "read_magic", "_read_array_header"])

# These are main methods, not dedicated header-only helpers — exclude them
EXCLUDED_METHODS = {
    "_default_is_disk_cached_latents_expected",
    "_default_load_latents_from_disk",
    "_default_cache_batch_latents",
    "is_disk_cached_latents_expected",
    "load_latents_from_disk",
    "cache_batch_latents",
}

found_method = None
found_in = None

for filepath in ["/workspace/sd-scripts/library/strategy_base.py", "/workspace/sd-scripts/library/strategy_sd.py"]:
    with open(filepath) as f:
        src = f.read()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name in ("LatentsCachingStrategy", "SdSdxlLatentsCachingStrategy"):
            for item in node.body:
                if not isinstance(item, ast.FunctionDef):
                    continue
                if item.name in EXCLUDED_METHODS:
                    continue
                # Accept the canonical names OR any method that does zip/stream header reads
                item_src = ast.unparse(item) if hasattr(ast, "unparse") else str(ast.dump(item))
                is_known_name = item.name in ACCEPTED_NAMES
                is_zip_reader = (
                    "shape" in item_src.lower() or "header" in item_src.lower()
                ) and has_zip_stream_access(item_src)
                if not (is_known_name or is_zip_reader):
                    continue
                stmts = [s for s in item.body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant, ast.Str)))]
                params = [a.arg for a in item.args.args] + [a.arg for a in item.args.posonlyargs]
                # Require >= 2 non-docstring statements (rejects bare stubs like `pass` or `return None`)
                if len(stmts) >= 2 and len(params) >= 1:
                    found_method = item.name
                    found_in = filepath.split("/")[-1]
                    break
            if found_method:
                break
    if found_method:
        break

if found_method:
    print(f"PASS: header-reading method '{found_method}' found in {found_in}")
    sys.exit(0)

print("FAIL: no header-only npz shape reader found in LatentsCachingStrategy or SdSdxlLatentsCachingStrategy")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 2/12: fallback logic exists for legacy (unsuffixed) latents (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, ast, re

with open("/workspace/sd-scripts/library/strategy_base.py") as f:
    src = f.read()

tree = ast.parse(src)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "LatentsCachingStrategy":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "_default_is_disk_cached_latents_expected":
                # Unparse ONLY the body statements (not signature) to avoid false positives
                body_only_src = " ".join(ast.unparse(s) for s in item.body) if hasattr(ast, 'unparse') else str([ast.dump(s) for s in item.body])
                all_args = [a.arg for a in item.args.args] + [a.arg for a in item.args.kwonlyargs]

                # Accept approach 1: explicit fallback parameter USED in body
                has_fallback_param = any("fallback" in a.lower() for a in all_args)
                # Accept approach 2: inline logic that checks BOTH suffixed AND unsuffixed "latents" key.
                # The original code already has 'latents' + key_reso_suffix (suffixed).
                # Fallback requires a STANDALONE 'latents' reference (not concatenated with +).
                has_suffixed = bool(re.search(r"""['"]latents['"][\s]*\+""", body_only_src))
                has_unsuffixed = bool(re.search(r"""['"]latents['"](?![\s]*\+)""", body_only_src))
                has_inline_fallback = has_suffixed and has_unsuffixed and (
                    "suffix" in body_only_src or "reso" in body_only_src
                )

                if has_fallback_param:
                    fallback_param = next(a for a in all_args if "fallback" in a.lower())
                    if fallback_param in body_only_src:
                        print(f"PASS: fallback param '{fallback_param}' found and used in body of _default_is_disk_cached_latents_expected")
                        sys.exit(0)
                    print(f"FAIL: fallback param '{fallback_param}' declared but not used in function body")
                    sys.exit(1)
                elif has_inline_fallback:
                    print("PASS: inline fallback logic for unsuffixed 'latents' key found in _default_is_disk_cached_latents_expected")
                    sys.exit(0)
                else:
                    print(f"FAIL: no fallback mechanism found in _default_is_disk_cached_latents_expected. Params: {all_args}")
                    sys.exit(1)
        print("FAIL: _default_is_disk_cached_latents_expected not found in LatentsCachingStrategy")
        sys.exit(1)

print("FAIL: LatentsCachingStrategy class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 3/12: SdSdxlLatentsCachingStrategy has backward-compat enabled (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, ast

# Approach 1: SdSdxl explicitly passes fallback via parameter name or keyword argument in a call
with open("/workspace/sd-scripts/library/strategy_sd.py") as f:
    sd_src = f.read()

sd_tree = ast.parse(sd_src)
found_in_sdsdxl = False
for node in ast.walk(sd_tree):
    if isinstance(node, ast.ClassDef) and node.name == "SdSdxlLatentsCachingStrategy":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name in ("is_disk_cached_latents_expected", "load_latents_from_disk"):
                # Check 1: method has a parameter with "fallback" in its name
                all_args = [a.arg for a in item.args.args] + [a.arg for a in item.args.kwonlyargs]
                has_fallback_param = any("fallback" in a.lower() for a in all_args)
                # Check 2: method calls a function with a "fallback" keyword argument
                has_fallback_kwarg_call = False
                for subnode in ast.walk(item):
                    if isinstance(subnode, ast.Call):
                        for kw in subnode.keywords:
                            if kw.arg and "fallback" in kw.arg.lower():
                                has_fallback_kwarg_call = True
                if has_fallback_param or has_fallback_kwarg_call:
                    found_in_sdsdxl = True

if found_in_sdsdxl:
    print("PASS: SdSdxlLatentsCachingStrategy uses fallback via parameter or keyword argument")
    sys.exit(0)

# Approach 2: backward compat is in the base class — verify base has fallback logic
# with BOTH suffixed AND unsuffixed "latents" key check (not just existing suffixed logic)
import re as _re
with open("/workspace/sd-scripts/library/strategy_base.py") as f:
    base_src = f.read()

base_tree = ast.parse(base_src)
base_has_fallback = False
for node in ast.walk(base_tree):
    if isinstance(node, ast.ClassDef) and node.name == "LatentsCachingStrategy":
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == "_default_is_disk_cached_latents_expected":
                body_only_src = " ".join(ast.unparse(s) for s in item.body) if hasattr(ast, "unparse") else str([ast.dump(s) for s in item.body])
                has_suffixed = bool(_re.search(r"""['"]latents['"][\s]*\+""", body_only_src))
                has_unsuffixed = bool(_re.search(r"""['"]latents['"](?![\s]*\+)""", body_only_src))
                if has_suffixed and has_unsuffixed and "suffix" in body_only_src:
                    base_has_fallback = True

if base_has_fallback:
    print("PASS: backward-compat fallback is in base class LatentsCachingStrategy._default_is_disk_cached_latents_expected (applies to SdSdxl)")
    sys.exit(0)

print("FAIL: SdSdxlLatentsCachingStrategy has no fallback enabled (neither via parameter/kwarg nor via base class)")
sys.exit(1)
PYEOF

###############################################################################
# BEHAVIORAL CHECKS — CORE FALLBACK (25% — Tests 4, 6-8, 10)
###############################################################################

echo ""
echo "=== Test 4/12: strategy_base.py imports cleanly (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys
sys.path.insert(0, "/workspace/sd-scripts")
try:
    import library.strategy_base as sb
    print(f"PASS: strategy_base imported, LatentsCachingStrategy: {sb.LatentsCachingStrategy}")
    sys.exit(0)
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)
PYEOF

echo ""
echo "=== Test 5/12: header-only shape reader returns correct shape (15pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 15)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_base import LatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

# Create a minimal concrete subclass for testing
class TestStrategy(LatentsCachingStrategy):
    def cache_batch_latents(self, *a, **kw): pass

strat = TestStrategy(cache_to_disk=False, batch_size=1, skip_disk_cache_validity_check=False)

# Create a test npz with a known shape
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
test_arr = np.zeros((4, 16, 32), dtype=np.float32)
np.savez(npz_path, latents=test_arr)

# Try canonical names from ground-truth session, then alternative valid names
# Also try dynamic discovery of any private method containing "shape" or "npy" related to npz reading
import inspect

CANDIDATE_NAMES = [
    "_get_npz_array_shape_from_metadata",  # ground truth
    "_read_npy_shape_from_npz",
    "_read_npz_array_shape",
    "_get_npy_shape_from_npz",
    "_get_latent_shape_from_npz",
]

# Also dynamically discover any method whose name suggests shape/header reading from npz
for name in dir(type(strat)):
    if name.startswith("_") and any(kw in name for kw in ["shape", "npy", "npz", "header", "meta"]) and name not in CANDIDATE_NAMES:
        CANDIDATE_NAMES.append(name)

shape = None
method_used = None
for method_name in CANDIDATE_NAMES:
    method = getattr(strat, method_name, None) or getattr(type(strat), method_name, None)
    if method is None:
        continue
    # Try all plausible call signatures — methods may take:
    #   (npz_path_str, key)   — path-based
    #   (npz_file_obj, key)   — NpzFile-based
    #   (npz_path_str, key, ...) — path-based with extra args
    shape = None
    call_attempts = [
        lambda m: m(npz_path, "latents"),                                    # path + key
        lambda m: m(npz_path, "latents", None),                              # path + key + zip_file=None
        lambda m: (lambda f: m(f, "latents"))(np.load(npz_path)),            # NpzFile + key (load separately)
    ]
    for attempt in call_attempts:
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

if shape is None or method_used is None:
    print("FAIL: no callable header-only shape reader found on LatentsCachingStrategy instance")
    sys.exit(1)

if tuple(shape) != (4, 16, 32):
    print(f"FAIL: {method_used} returned shape {shape}, expected (4, 16, 32)")
    sys.exit(1)

print(f"PASS: {method_used} returned correct shape {shape}")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 6/12: is_disk_cached_latents_expected returns True for legacy npz (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")

try:
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
except Exception as e:
    print(f"FAIL: import error: {e}")
    sys.exit(1)

strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

# bucket_reso = (512, 512), stride = 8 => expected latents_size = (64, 64)
bucket_reso = (512, 512)
latents_h = bucket_reso[1] // 8  # 64
latents_w = bucket_reso[0] // 8  # 64

# Create legacy npz: key "latents" (no resolution suffix), correct shape
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
    os.unlink(npz_path)
    print(f"FAIL: is_disk_cached_latents_expected raised: {e}")
    sys.exit(1)
finally:
    os.unlink(npz_path)

if not result:
    print("FAIL: returned False for legacy npz with correct shape — backward compat not working")
    sys.exit(1)

print(f"PASS: is_disk_cached_latents_expected=True for legacy unsuffixed npz with shape ({latents_h},{latents_w})")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 7/12: is_disk_cached_latents_expected rejects legacy npz with WRONG shape (5pts) ==="
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

# Pre-check: correct-shape legacy npz must return True (proves fallback is actually implemented).
# Without this gate, an unmodified codebase returns False for ALL legacy npz (key missing),
# which would make the wrong-shape check below a free point.
fd1, correct_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
np.savez(correct_npz,
    latents=np.zeros((4, latents_h, latents_w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    correct_result = strat.is_disk_cached_latents_expected(bucket_reso, correct_npz, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: pre-check (correct-shape) raised: {e}")
    sys.exit(1)
finally:
    if os.path.exists(correct_npz):
        os.unlink(correct_npz)

if not correct_result:
    print("FAIL: pre-check: correct-shape legacy npz returned False — fallback not implemented, cannot verify shape rejection")
    sys.exit(1)

# Main check: wrong-shape legacy npz must return False
fd2, wrong_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd2)
np.savez(wrong_npz,
    latents=np.zeros((4, 48, 64), dtype=np.float32),  # wrong H (48 != 64)
    original_size=np.array([512, 384]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, wrong_npz, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: is_disk_cached_latents_expected raised: {e}")
    sys.exit(1)
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if result:
    print("FAIL: returned True for legacy npz with WRONG shape — should reject mismatched latents")
    sys.exit(1)

print("PASS: is_disk_cached_latents_expected=False for legacy npz with wrong shape (correct rejection, fallback verified)")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 8/12: load_latents_from_disk loads from legacy unsuffixed npz (5pts) ==="
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
    print(f"FAIL: wrong latents shape {latents.shape}, expected (4, {latents_h}, {latents_w})")
    sys.exit(1)

if abs(float(latents[0, 0, 0]) - 3.14) > 0.01:
    print(f"FAIL: latents values wrong, got {float(latents[0,0,0])}, expected ~3.14")
    sys.exit(1)

print(f"PASS: load_latents_from_disk loaded legacy latents with shape {latents.shape}")
sys.exit(0)
PYEOF

###############################################################################
# STRUCTURAL — DEEP VALIDATION (5% — Test 9)
###############################################################################

echo ""
echo "=== Test 9/12: Metadata read uses header-only approach (AST check) (5pts) ==="
python3 << 'PYEOF' && SCORE=$((SCORE + 5)) || true
import sys, ast

ACCEPTED_NAMES = {
    "_get_npz_array_shape_from_metadata", "_read_npy_shape_from_npz",
    "_read_npz_array_shape", "_get_npy_shape_from_npz", "_get_latent_shape_from_npz",
}

def check_method(item):
    body_src = ast.unparse(item) if hasattr(ast, 'unparse') else str(ast.dump(item))
    uses_zip_stream = (
        ".zip" in body_src or
        "zipfile" in body_src or
        "ZipFile" in body_src or
        ".open(" in body_src
    )
    reads_header = (
        "read_magic" in body_src or
        "_read_array_header" in body_src or
        "read_array_header" in body_src or
        "_format_impl" in body_src or
        "format.py" in body_src or
        "header" in body_src.lower()
    )
    naive_load = "np.load(npz_path" in body_src or "np.load(path" in body_src
    return uses_zip_stream, reads_header, naive_load, body_src

for filepath in ["/workspace/sd-scripts/library/strategy_base.py", "/workspace/sd-scripts/library/strategy_sd.py"]:
    with open(filepath) as f:
        src = f.read()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name in ("LatentsCachingStrategy", "SdSdxlLatentsCachingStrategy"):
            for item in node.body:
                if not isinstance(item, ast.FunctionDef):
                    continue
                item_src = ast.unparse(item) if hasattr(ast, "unparse") else str(ast.dump(item))
                is_candidate = item.name in ACCEPTED_NAMES or (
                    ("shape" in item_src.lower() or "header" in item_src.lower()) and
                    (".zip" in item_src or "zipfile" in item_src or "ZipFile" in item_src)
                )
                if not is_candidate:
                    continue
                uses_zip, reads_hdr, naive, body_src = check_method(item)
                if naive:
                    print(f"FAIL: {item.name} uses np.load() — loads full array")
                    sys.exit(1)
                if not uses_zip:
                    print(f"FAIL: {item.name}: no zip/stream approach detected")
                    sys.exit(1)
                if not reads_hdr:
                    print(f"FAIL: {item.name}: no header-reading logic detected")
                    sys.exit(1)
                print(f"PASS: {item.name} uses zip stream + header read (no full decompression)")
                sys.exit(0)

print("FAIL: no header-only npz shape reader with zip/stream approach found")
sys.exit(1)
PYEOF

###############################################################################
# BEHAVIORAL — NON-LEGACY PATH (5% — Test 10)
###############################################################################

echo ""
echo "=== Test 10/12: Resolution-suffixed npz still works (5pts) ==="
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
key_suffix = f"_{latents_h}x{latents_w}"  # "_64x64"

# Create modern (resolution-suffixed) npz
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
np.savez(npz_path, **{
    f"latents{key_suffix}": np.ones((4, latents_h, latents_w), dtype=np.float32) * 2.71,
    f"original_size{key_suffix}": np.array([512, 512]),
    f"crop_ltrb{key_suffix}": np.array([0, 0, 0, 0]),
})

# is_disk_cached_latents_expected should return True
try:
    expected = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
except Exception as e:
    os.unlink(npz_path)
    print(f"FAIL: is_disk_cached_latents_expected raised: {e}")
    sys.exit(1)

if not expected:
    os.unlink(npz_path)
    print(f"FAIL: is_disk_cached_latents_expected=False for valid resolution-suffixed npz (key '{key_suffix}')")
    sys.exit(1)

# load_latents_from_disk should succeed
try:
    latents, orig_size, crop, flipped, alpha = strat.load_latents_from_disk(npz_path, bucket_reso)
except Exception as e:
    os.unlink(npz_path)
    print(f"FAIL: load_latents_from_disk raised: {e}")
    sys.exit(1)
finally:
    os.unlink(npz_path)

if latents is None or latents.shape != (4, latents_h, latents_w):
    print(f"FAIL: wrong shape {latents.shape if latents is not None else None}")
    sys.exit(1)

print(f"PASS: resolution-suffixed npz (key '{key_suffix}') still loads correctly — non-legacy path unchanged")
sys.exit(0)
PYEOF

###############################################################################
# BEHAVIORAL — HEADER-ONLY PROOF (40% — Tests 11-12)
#
# These tests use corrupted npz files where the npy data is truncated but
# the npy header is intact. A header-only reader extracts the shape from
# the header; np.load()-based readers crash on the truncated data.
# This is the strongest behavioral proof of header-only reads.
###############################################################################

echo ""
echo "=== Test 11/12: Corrupted-data legacy npz with correct shape header accepted (20pts) ==="
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

# Create a valid npy using numpy's own writer, then truncate the data portion
buf = io.BytesIO()
np.save(buf, np.zeros(shape, dtype=dtype))
full_npy = buf.getvalue()
data_size = int(np.prod(shape)) * dtype.itemsize  # 4*64*64*4 = 65536
header_size = len(full_npy) - data_size
# Keep only the header + 64 bytes of garbage data (way less than needed)
npy_truncated = full_npy[:header_size] + b'\x00' * 64

# Create valid npy entries for original_size and crop_ltrb (small, full data OK)
buf_os = io.BytesIO()
np.save(buf_os, np.array([512, 512]))
buf_cl = io.BytesIO()
np.save(buf_cl, np.array([0, 0, 0, 0]))

# Build the corrupted npz (valid zip, valid npy headers, truncated latents data)
fd, npz_path = tempfile.mkstemp(suffix=".npz")
os.close(fd)
with zipfile.ZipFile(npz_path, 'w') as zf:
    zf.writestr("latents.npy", npy_truncated)
    zf.writestr("original_size.npy", buf_os.getvalue())
    zf.writestr("crop_ltrb.npy", buf_cl.getvalue())

try:
    result = strat.is_disk_cached_latents_expected(bucket_reso, npz_path, flip_aug=False, alpha_mask=False)
except Exception as e:
    if os.path.exists(npz_path):
        os.unlink(npz_path)
    print(f"FAIL: is_disk_cached_latents_expected raised (likely using np.load on truncated data): {e}")
    sys.exit(1)
finally:
    if os.path.exists(npz_path):
        os.unlink(npz_path)

if not result:
    print("FAIL: returned False for corrupted-data legacy npz with correct shape header — header-only read not working")
    sys.exit(1)

print(f"PASS: is_disk_cached_latents_expected=True for corrupted-data legacy npz (header-only shape read confirmed)")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 12/12: Corrupted-data legacy npz with WRONG shape header rejected (20pts) ==="
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

dtype = np.dtype('<f4')

# --- Gate: correct-shape corrupted npz must return True first ---
# This prevents free points when no fallback exists (all legacy npz return False)
correct_shape = (4, latents_h, latents_w)
buf = io.BytesIO()
np.save(buf, np.zeros(correct_shape, dtype=dtype))
full_npy = buf.getvalue()
data_size = int(np.prod(correct_shape)) * dtype.itemsize
header_size = len(full_npy) - data_size
npy_truncated = full_npy[:header_size] + b'\x00' * 64

buf_os = io.BytesIO()
np.save(buf_os, np.array([512, 512]))
buf_cl = io.BytesIO()
np.save(buf_cl, np.array([0, 0, 0, 0]))

fd1, gate_npz = tempfile.mkstemp(suffix=".npz")
os.close(fd1)
with zipfile.ZipFile(gate_npz, 'w') as zf:
    zf.writestr("latents.npy", npy_truncated)
    zf.writestr("original_size.npy", buf_os.getvalue())
    zf.writestr("crop_ltrb.npy", buf_cl.getvalue())

try:
    gate_result = strat.is_disk_cached_latents_expected(bucket_reso, gate_npz, flip_aug=False, alpha_mask=False)
except Exception as e:
    print(f"FAIL: gate check raised: {e}")
    sys.exit(1)
finally:
    if os.path.exists(gate_npz):
        os.unlink(gate_npz)

if not gate_result:
    print("FAIL: gate: correct-shape corrupted npz returned False — cannot verify wrong-shape rejection without working header reader")
    sys.exit(1)

# --- Main check: wrong-shape corrupted npz must return False ---
wrong_shape = (4, 48, 64)  # wrong H (48 != 64 expected)
buf2 = io.BytesIO()
np.save(buf2, np.zeros(wrong_shape, dtype=dtype))
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
except Exception as e:
    print(f"FAIL: is_disk_cached_latents_expected raised: {e}")
    sys.exit(1)
finally:
    if os.path.exists(wrong_npz):
        os.unlink(wrong_npz)

if result:
    print("FAIL: returned True for corrupted-data legacy npz with WRONG shape header — should reject")
    sys.exit(1)

print("PASS: is_disk_cached_latents_expected=False for corrupted-data npz with wrong shape header (header-only rejection confirmed)")
sys.exit(0)
PYEOF

echo ""
echo "================================"
echo "Weighted score: $SCORE / 100"
echo "================================"

REWARD=$(python3 -c "print(min(1.0, round($SCORE / 100, 2)))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
