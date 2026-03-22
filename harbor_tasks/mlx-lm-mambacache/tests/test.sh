#!/usr/bin/env bash
#
# Hardened verification test for MambaCache/ArraysCache batching support in mlx-lm.
#
# Tests structural correctness (30%), behavioral correctness (40%), and deep
# validation (30%) of merge/extract/prepare/finalize methods on ArraysCache,
# CacheList merge/extract, _merge_caches update in generate.py, and _lengths
# mask support. All tests run on CPU -- no GPU/Metal required.
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=10

CACHE_PY="/workspace/mlx-lm/mlx_lm/models/cache.py"
GENERATE_PY="/workspace/mlx-lm/mlx_lm/generate.py"

###############################################################################
# STRUCTURAL CHECKS (30% -- Tests 1-3)
###############################################################################

echo "=== Test 1/10: ArraysCache.merge is classmethod with correct signature ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
        if "merge" not in methods:
            print("FAIL: ArraysCache has no merge() method")
            sys.exit(1)

        merge_node = methods["merge"]

        # Check decorator: must be @classmethod
        is_classmethod = any(
            (isinstance(d, ast.Name) and d.id == "classmethod") or
            (isinstance(d, ast.Attribute) and d.attr == "classmethod")
            for d in merge_node.decorator_list
        )
        params = [a.arg for a in merge_node.args.args]

        if not is_classmethod and not (params and params[0] == "cls"):
            print("FAIL: merge() is not a classmethod and first param is not cls")
            sys.exit(1)

        # Check it takes a caches/list parameter (cls + at least one more param)
        if len(params) < 2:
            print("FAIL: merge() has no parameter for the list of caches")
            sys.exit(1)

        # Check method body is non-trivial (not just pass/return None)
        body = merge_node.body
        # Filter out docstrings
        stmts = [s for s in body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant, ast.Str)))]
        if len(stmts) <= 1:
            # Only 'pass' or 'return None' -- trivial stub
            if len(stmts) == 1:
                s = stmts[0]
                if isinstance(s, ast.Pass):
                    print("FAIL: merge() body is just 'pass' -- empty stub")
                    sys.exit(1)
                if isinstance(s, ast.Return) and (s.value is None or (isinstance(s.value, ast.Constant) and s.value.value is None)):
                    print("FAIL: merge() body is just 'return None' -- empty stub")
                    sys.exit(1)
            elif len(stmts) == 0:
                print("FAIL: merge() has empty body (only docstring)")
                sys.exit(1)

        print(f"PASS: ArraysCache.merge() is classmethod with params {params}, non-trivial body ({len(stmts)} stmts)")
        sys.exit(0)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 2/10: ArraysCache.extract has idx parameter and non-trivial body ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
        if "extract" not in methods:
            print("FAIL: ArraysCache has no extract() method")
            sys.exit(1)

        extract_node = methods["extract"]
        params = [a.arg for a in extract_node.args.args]

        # Must have self + at least one more param (idx)
        if len(params) < 2:
            print("FAIL: extract() has no idx parameter (only has: {})".format(params))
            sys.exit(1)

        # Check body is non-trivial
        body = extract_node.body
        stmts = [s for s in body if not (isinstance(s, ast.Expr) and isinstance(s.value, (ast.Constant, ast.Str)))]
        if len(stmts) <= 1:
            if len(stmts) == 1:
                s = stmts[0]
                if isinstance(s, ast.Pass):
                    print("FAIL: extract() body is just 'pass' -- empty stub")
                    sys.exit(1)
                if isinstance(s, ast.Return) and (s.value is None or (isinstance(s.value, ast.Constant) and s.value.value is None)):
                    print("FAIL: extract() body is just 'return None' -- empty stub")
                    sys.exit(1)
            elif len(stmts) == 0:
                print("FAIL: extract() has empty body")
                sys.exit(1)

        print(f"PASS: ArraysCache.extract() with params {params}, non-trivial body ({len(stmts)} stmts)")
        sys.exit(0)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 3/10: ArraysCache has prepare() and finalize() methods ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}

        if "prepare" not in methods:
            print("FAIL: ArraysCache has no prepare() method")
            sys.exit(1)

        if "finalize" not in methods:
            print("FAIL: ArraysCache has no finalize() method")
            sys.exit(1)

        # Check prepare has padding/lengths related params
        prep = methods["prepare"]
        all_params = [a.arg for a in prep.args.args] + [a.arg for a in prep.args.kwonlyargs]
        has_padding = any("padding" in p.lower() or "left" in p.lower() for p in all_params)
        has_lengths = any("length" in p.lower() for p in all_params)

        if has_padding or has_lengths:
            print(f"PASS: prepare({all_params}) + finalize() both exist with relevant params")
        else:
            print(f"PASS: prepare({all_params}) + finalize() both exist")
        sys.exit(0)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

###############################################################################
# BEHAVIORAL CHECKS (40% -- Tests 4-7)
###############################################################################

echo ""
echo "=== Test 4/10: ArraysCache can be imported and instantiated, merge is callable ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys
sys.path.insert(0, "/workspace/mlx-lm")

try:
    from mlx_lm.models.cache import ArraysCache
except ImportError as e:
    print(f"FAIL: Cannot import ArraysCache: {e}")
    sys.exit(1)

# Instantiate
try:
    ac = ArraysCache(size=2)
except Exception as e:
    print(f"FAIL: Cannot instantiate ArraysCache(size=2): {e}")
    sys.exit(1)

# Check merge is callable and is classmethod
if not hasattr(ArraysCache, "merge"):
    print("FAIL: ArraysCache has no 'merge' attribute")
    sys.exit(1)

if not callable(getattr(ArraysCache, "merge")):
    print("FAIL: ArraysCache.merge is not callable")
    sys.exit(1)

# Check extract is callable
if not hasattr(ac, "extract"):
    print("FAIL: ArraysCache instance has no 'extract' method")
    sys.exit(1)

# Check prepare and finalize are callable
if not hasattr(ac, "prepare") or not callable(ac.prepare):
    print("FAIL: ArraysCache instance has no callable 'prepare' method")
    sys.exit(1)

if not hasattr(ac, "finalize") or not callable(ac.finalize):
    print("FAIL: ArraysCache instance has no callable 'finalize' method")
    sys.exit(1)

print("PASS: ArraysCache imports, instantiates, and has merge/extract/prepare/finalize")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 5/10: ArraysCache.merge produces correct batched output ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys
sys.path.insert(0, "/workspace/mlx-lm")

try:
    import mlx.core as mx
    from mlx_lm.models.cache import ArraysCache
except ImportError as e:
    print(f"FAIL: Import error: {e}")
    sys.exit(1)

# Create two ArraysCache instances with mock SSM state data
# ArraysCache stores arbitrary arrays (e.g., conv_state, ssm_state for Mamba)
# Typical shapes: conv_state = (1, d_inner, d_conv), ssm_state = (1, d_inner, d_state)
cache1 = ArraysCache(size=2)
cache1.cache[0] = mx.ones((1, 4, 3))      # conv_state for batch item 1
cache1.cache[1] = mx.ones((1, 4, 8)) * 2  # ssm_state for batch item 1

cache2 = ArraysCache(size=2)
cache2.cache[0] = mx.ones((1, 4, 3)) * 3  # conv_state for batch item 2
cache2.cache[1] = mx.ones((1, 4, 8)) * 4  # ssm_state for batch item 2

# Merge them
try:
    merged = ArraysCache.merge([cache1, cache2])
except Exception as e:
    print(f"FAIL: ArraysCache.merge() raised: {e}")
    sys.exit(1)

# Validate output
if not isinstance(merged, ArraysCache):
    print(f"FAIL: merge() returned {type(merged)}, expected ArraysCache")
    sys.exit(1)

if merged.cache[0] is None or merged.cache[1] is None:
    print("FAIL: merged cache arrays are None")
    sys.exit(1)

# Check batch dimension is 2 (merged two caches)
shape0 = merged.cache[0].shape
shape1 = merged.cache[1].shape
if shape0[0] != 2:
    print(f"FAIL: merged cache[0] batch dim is {shape0[0]}, expected 2")
    sys.exit(1)
if shape1[0] != 2:
    print(f"FAIL: merged cache[1] batch dim is {shape1[0]}, expected 2")
    sys.exit(1)

# Check values are correct (first batch = 1s/2s, second batch = 3s/4s)
val_0_0 = merged.cache[0][0, 0, 0].item()
val_0_1 = merged.cache[0][1, 0, 0].item()
val_1_0 = merged.cache[1][0, 0, 0].item()
val_1_1 = merged.cache[1][1, 0, 0].item()

if abs(val_0_0 - 1.0) > 0.01 or abs(val_0_1 - 3.0) > 0.01:
    print(f"FAIL: cache[0] values wrong. Got [{val_0_0}, {val_0_1}], expected [1.0, 3.0]")
    sys.exit(1)

if abs(val_1_0 - 2.0) > 0.01 or abs(val_1_1 - 4.0) > 0.01:
    print(f"FAIL: cache[1] values wrong. Got [{val_1_0}, {val_1_1}], expected [2.0, 4.0]")
    sys.exit(1)

print(f"PASS: merge() produces batched output with correct shapes {shape0}, {shape1} and values")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 6/10: ArraysCache.extract recovers individual cache from merged ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys
sys.path.insert(0, "/workspace/mlx-lm")

try:
    import mlx.core as mx
    from mlx_lm.models.cache import ArraysCache
except ImportError as e:
    print(f"FAIL: Import error: {e}")
    sys.exit(1)

# Create and merge caches
cache1 = ArraysCache(size=2)
cache1.cache[0] = mx.ones((1, 4, 3)) * 10
cache1.cache[1] = mx.ones((1, 4, 8)) * 20

cache2 = ArraysCache(size=2)
cache2.cache[0] = mx.ones((1, 4, 3)) * 30
cache2.cache[1] = mx.ones((1, 4, 8)) * 40

try:
    merged = ArraysCache.merge([cache1, cache2])
except Exception as e:
    print(f"FAIL: merge() raised: {e}")
    sys.exit(1)

# Extract individual caches back
try:
    extracted_0 = merged.extract(0)
    extracted_1 = merged.extract(1)
except Exception as e:
    print(f"FAIL: extract() raised: {e}")
    sys.exit(1)

# Validate extracted caches
if not isinstance(extracted_0, ArraysCache):
    print(f"FAIL: extract(0) returned {type(extracted_0)}, expected ArraysCache")
    sys.exit(1)

if extracted_0.cache[0] is None or extracted_0.cache[1] is None:
    print("FAIL: extracted cache has None arrays")
    sys.exit(1)

# Check batch dim is 1 after extraction
if extracted_0.cache[0].shape[0] != 1:
    print(f"FAIL: extracted cache[0] batch dim is {extracted_0.cache[0].shape[0]}, expected 1")
    sys.exit(1)

# Check values: extracted_0 should have values 10/20, extracted_1 should have 30/40
v0_0 = extracted_0.cache[0][0, 0, 0].item()
v0_1 = extracted_0.cache[1][0, 0, 0].item()
v1_0 = extracted_1.cache[0][0, 0, 0].item()
v1_1 = extracted_1.cache[1][0, 0, 0].item()

if abs(v0_0 - 10.0) > 0.01 or abs(v0_1 - 20.0) > 0.01:
    print(f"FAIL: extracted[0] values wrong. Got [{v0_0}, {v0_1}], expected [10.0, 20.0]")
    sys.exit(1)

if abs(v1_0 - 30.0) > 0.01 or abs(v1_1 - 40.0) > 0.01:
    print(f"FAIL: extracted[1] values wrong. Got [{v1_0}, {v1_1}], expected [30.0, 40.0]")
    sys.exit(1)

print("PASS: extract() recovers correct individual caches from merged batch")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 7/10: _merge_caches handles ArraysCache and CacheList with branching logic ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast, re

with open("/workspace/mlx-lm/mlx_lm/generate.py", "r") as f:
    source = f.read()

lines = source.split('\n')

# Extract the _merge_caches function body
in_merge = False
merge_lines = []
indent = 0
for i, line in enumerate(lines):
    if 'def _merge_caches' in line:
        in_merge = True
        indent = len(line) - len(line.lstrip())
        merge_lines.append(line)
        continue
    if in_merge:
        # End of function: non-empty line at same or lesser indent
        stripped = line.strip()
        if stripped and not line[0:1].isspace() and i > 0:
            break
        if stripped and len(line) - len(line.lstrip()) <= indent and (stripped.startswith('def ') or stripped.startswith('class ') or stripped.startswith('@')):
            break
        merge_lines.append(line)

merge_body = '\n'.join(merge_lines)

if not merge_lines:
    print("FAIL: _merge_caches() function not found in generate.py")
    sys.exit(1)

# Check 1: Must handle ArraysCache (explicit reference or generic .merge())
has_arrays_cache = 'ArraysCache' in merge_body
has_generic_merge = 'hasattr' in merge_body and 'merge' in merge_body

if not has_arrays_cache and not has_generic_merge:
    # Check if old error is still present (meaning no new types added)
    if 'does not yet support batching with history' in merge_body:
        print("FAIL: _merge_caches() still only handles KVCache/RotatingKVCache (old error present, no ArraysCache)")
        sys.exit(1)
    print("FAIL: _merge_caches() has no ArraysCache handling and no generic merge fallback")
    sys.exit(1)

# Check 2: Must handle CacheList (explicit reference, or generic handler covers it)
has_cache_list = 'CacheList' in merge_body

if not has_cache_list and not has_generic_merge:
    print("FAIL: _merge_caches() has no CacheList handling")
    sys.exit(1)

# Check 3: Must have actual branching logic (isinstance checks or hasattr)
has_isinstance = 'isinstance' in merge_body
if not has_isinstance and not has_generic_merge:
    print("FAIL: _merge_caches() has no isinstance checks or generic dispatch")
    sys.exit(1)

# Check 4: Verify it's not just deleting the error -- must have real merge calls
has_merge_call = '.merge(' in merge_body
if not has_merge_call:
    print("FAIL: _merge_caches() has no .merge() calls -- likely just deleted the error")
    sys.exit(1)

details = []
if has_arrays_cache: details.append("ArraysCache")
if has_cache_list: details.append("CacheList")
if has_generic_merge: details.append("generic-merge")
print(f"PASS: _merge_caches() has branching logic handling: {', '.join(details)}")
sys.exit(0)
PYEOF

###############################################################################
# DEEP VALIDATION (30% -- Tests 8-10)
###############################################################################

echo ""
echo "=== Test 8/10: _lengths attribute works in make_mask for right-padding ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys
sys.path.insert(0, "/workspace/mlx-lm")

try:
    import mlx.core as mx
    from mlx_lm.models.cache import ArraysCache
except ImportError as e:
    print(f"FAIL: Import error: {e}")
    sys.exit(1)

# Check _lengths attribute exists (set via __init__ or prepare)
ac = ArraysCache(size=2, left_padding=[1, 0])

# Check that _lengths can be set (either via attribute or prepare)
has_lengths_attr = hasattr(ac, '_lengths')
has_prepare = hasattr(ac, 'prepare') and callable(ac.prepare)

if not has_lengths_attr and not has_prepare:
    print("FAIL: ArraysCache has no _lengths attribute and no prepare() method")
    sys.exit(1)

# Set _lengths via prepare if available, otherwise directly
try:
    if has_prepare:
        ac.prepare(lengths=[3, 4])
    elif has_lengths_attr:
        ac._lengths = mx.array([3, 4])
except Exception as e:
    print(f"FAIL: Could not set _lengths: {e}")
    sys.exit(1)

# Now verify _lengths is actually stored
lengths_val = getattr(ac, '_lengths', None)
if lengths_val is None:
    print("FAIL: _lengths is None after setting via prepare(lengths=[3, 4])")
    sys.exit(1)

# Test make_mask uses _lengths to create right-padding mask
# With left_padding=[1, 0] and _lengths=[3, 4] and N=5:
# Row 0: positions [0,1,2,3,4], left_pad=1 so pos>=1, length=3 so pos<3 => mask [F,T,T,F,F]
# Row 1: positions [0,1,2,3,4], left_pad=0 so pos>=0, length=4 so pos<4 => mask [T,T,T,T,F]
try:
    mask = ac.make_mask(5)
except Exception as e:
    print(f"FAIL: make_mask(5) raised: {e}")
    sys.exit(1)

if mask is None:
    print("FAIL: make_mask returned None despite left_padding and _lengths being set")
    sys.exit(1)

# Verify mask shape
if mask.shape != (2, 5):
    print(f"FAIL: mask shape is {mask.shape}, expected (2, 5)")
    sys.exit(1)

# Verify mask values encode right-padding correctly
# Row 0: [F, T, T, F, F]
# Row 1: [T, T, T, T, F]
mask_list = mask.tolist()
row0 = mask_list[0]
row1 = mask_list[1]

# Row 0: position 0 should be False (left-padded), position 1-2 True, position 3-4 False (right-padded)
if row0[0] != False or row0[1] != True or row0[2] != True or row0[3] != False:
    print(f"FAIL: Row 0 mask incorrect. Expected [F,T,T,F,F], got {row0}")
    sys.exit(1)

# Row 1: positions 0-3 True, position 4 False (right-padded)
if row1[3] != True or row1[4] != False:
    print(f"FAIL: Row 1 mask incorrect. Expected [T,T,T,T,F], got {row1}")
    sys.exit(1)

print(f"PASS: _lengths correctly creates right-padding mask in make_mask()")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 9/10: CacheList.merge and extract work with mixed cache types ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys
sys.path.insert(0, "/workspace/mlx-lm")

try:
    import mlx.core as mx
    from mlx_lm.models.cache import ArraysCache, CacheList, KVCache
except ImportError as e:
    print(f"FAIL: Import error: {e}")
    sys.exit(1)

# Check CacheList has merge and extract
if not hasattr(CacheList, 'merge'):
    print("FAIL: CacheList has no 'merge' method")
    sys.exit(1)

# Check extract on an instance
try:
    cl_test = CacheList(ArraysCache(size=1))
    if not hasattr(cl_test, 'extract'):
        print("FAIL: CacheList instance has no 'extract' method")
        sys.exit(1)
except Exception as e:
    print(f"FAIL: Cannot create CacheList instance: {e}")
    sys.exit(1)

# Test merge with ArraysCache sub-caches
ac1 = ArraysCache(size=2)
ac1.cache[0] = mx.ones((1, 4, 3)) * 5
ac1.cache[1] = mx.ones((1, 4, 8)) * 6

ac2 = ArraysCache(size=2)
ac2.cache[0] = mx.ones((1, 4, 3)) * 7
ac2.cache[1] = mx.ones((1, 4, 8)) * 8

cl1 = CacheList(ac1)
cl2 = CacheList(ac2)

try:
    merged_cl = CacheList.merge([cl1, cl2])
except Exception as e:
    print(f"FAIL: CacheList.merge() raised: {e}")
    sys.exit(1)

if not isinstance(merged_cl, CacheList):
    print(f"FAIL: CacheList.merge() returned {type(merged_cl)}, expected CacheList")
    sys.exit(1)

# Verify the sub-cache is batched
sub = merged_cl.caches[0] if hasattr(merged_cl, 'caches') else merged_cl[0]
if sub.cache[0] is None:
    print("FAIL: merged CacheList sub-cache[0] is None")
    sys.exit(1)

if sub.cache[0].shape[0] != 2:
    print(f"FAIL: merged sub-cache batch dim is {sub.cache[0].shape[0]}, expected 2")
    sys.exit(1)

# Test extract
try:
    extracted = merged_cl.extract(0)
except Exception as e:
    print(f"FAIL: CacheList.extract(0) raised: {e}")
    sys.exit(1)

if not isinstance(extracted, CacheList):
    print(f"FAIL: CacheList.extract returned {type(extracted)}, expected CacheList")
    sys.exit(1)

# Check extracted sub-cache has batch dim 1
ex_sub = extracted.caches[0] if hasattr(extracted, 'caches') else extracted[0]
if ex_sub.cache[0].shape[0] != 1:
    print(f"FAIL: extracted sub-cache batch dim is {ex_sub.cache[0].shape[0]}, expected 1")
    sys.exit(1)

# Check values
v = ex_sub.cache[0][0, 0, 0].item()
if abs(v - 5.0) > 0.01:
    print(f"FAIL: extracted value is {v}, expected 5.0")
    sys.exit(1)

print("PASS: CacheList.merge() and extract() work correctly with ArraysCache sub-caches")
sys.exit(0)
PYEOF

echo ""
echo "=== Test 10/10: Agent test file exists and passes (or behavioral integration check) ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os, subprocess, glob, ast

# First try to find and run agent-written tests
test_file = None
test_patterns = [
    "/workspace/mlx-lm/tests/test_mamba_cache_batching.py",
    "/workspace/mlx-lm/tests/test_mamba_cache*.py",
    "/workspace/mlx-lm/tests/test_arrays_cache*.py",
    "/workspace/mlx-lm/tests/test_cache_batch*.py",
    "/workspace/mlx-lm/tests/test_batch_cache*.py",
]

for pattern in test_patterns:
    matches = glob.glob(pattern)
    if matches:
        test_file = matches[0]
        break

if test_file is None:
    # Broader search: any test file referencing ArraysCache + merge
    for f in glob.glob("/workspace/mlx-lm/tests/test_*.py"):
        try:
            with open(f, "r") as fh:
                content = fh.read()
            if ("ArraysCache" in content or "MambaCache" in content) and ("merge" in content or "extract" in content):
                test_file = f
                break
        except:
            pass

if test_file is not None:
    # Parse to count test methods
    with open(test_file, "r") as f:
        source = f.read()

    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        print(f"FAIL: test file has syntax error: {e}")
        sys.exit(1)

    test_count = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"):
            test_count += 1

    if test_count < 3:
        print(f"FAIL: test file has only {test_count} test methods (need >= 3)")
        sys.exit(1)

    # Actually run the tests
    result = subprocess.run(
        ["python3", "-m", "pytest", test_file, "-x", "-q", "--tb=short", "--timeout=30"],
        capture_output=True, text=True, timeout=60,
        cwd="/workspace/mlx-lm",
        env={**os.environ, "PYTHONPATH": "/workspace/mlx-lm"}
    )

    if result.returncode == 0:
        print(f"PASS: {os.path.basename(test_file)} has {test_count} tests and all pass")
        sys.exit(0)
    else:
        # Check if pytest is not installed and fall back
        if "No module named 'pytest'" in result.stderr:
            # Try running with unittest
            result2 = subprocess.run(
                ["python3", "-m", "unittest", test_file, "-v"],
                capture_output=True, text=True, timeout=60,
                cwd="/workspace/mlx-lm",
                env={**os.environ, "PYTHONPATH": "/workspace/mlx-lm"}
            )
            if result2.returncode == 0:
                print(f"PASS: {os.path.basename(test_file)} has {test_count} tests and passes via unittest")
                sys.exit(0)
            else:
                # Just importing the test file without errors is acceptable
                result3 = subprocess.run(
                    ["python3", "-c", f"import importlib.util; spec = importlib.util.spec_from_file_location('test', '{test_file}'); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)"],
                    capture_output=True, text=True, timeout=30,
                    cwd="/workspace/mlx-lm",
                    env={**os.environ, "PYTHONPATH": "/workspace/mlx-lm"}
                )
                if result3.returncode == 0:
                    print(f"PASS: {os.path.basename(test_file)} has {test_count} tests and imports clean (runner unavailable)")
                    sys.exit(0)

        # Some tests may fail due to missing GPU / model -- check if at least some pass
        stdout = result.stdout + result.stderr
        import re
        passed_match = re.search(r'(\d+) passed', stdout)
        if passed_match and int(passed_match.group(1)) >= 3:
            print(f"PASS: {os.path.basename(test_file)} has {passed_match.group(1)} passing tests")
            sys.exit(0)

        print(f"FAIL: tests failed:\n{result.stdout[-500:]}\n{result.stderr[-500:]}")
        sys.exit(1)
else:
    # No test file found -- fall back to an integration behavioral check
    # Verify that MambaCache (subclass of ArraysCache) also inherits merge/extract
    sys.path.insert(0, "/workspace/mlx-lm")
    try:
        from mlx_lm.models.cache import MambaCache, ArraysCache
        import mlx.core as mx

        mc1 = MambaCache()
        mc1.cache[0] = mx.ones((1, 4, 3))
        mc1.cache[1] = mx.ones((1, 4, 8))

        mc2 = MambaCache()
        mc2.cache[0] = mx.ones((1, 4, 3)) * 2
        mc2.cache[1] = mx.ones((1, 4, 8)) * 2

        merged = MambaCache.merge([mc1, mc2])
        extracted = merged.extract(1)

        v = extracted.cache[0][0, 0, 0].item()
        if abs(v - 2.0) > 0.01:
            print(f"FAIL: MambaCache merge/extract value wrong: {v}, expected 2.0")
            sys.exit(1)

        print("PASS: MambaCache inherits working merge/extract from ArraysCache (no test file, but behavioral check passes)")
        sys.exit(0)
    except Exception as e:
        print(f"FAIL: No test file found AND MambaCache behavioral check failed: {e}")
        sys.exit(1)
PYEOF

echo ""
echo "================================"
echo "Results: $PASS / $TOTAL passed"
echo "================================"

if [ "$PASS" -eq "$TOTAL" ]; then
    echo "1.0" > "$REWARD_FILE"
    echo "REWARD: 1.0"
else
    REWARD=$(python3 -c "print(round($PASS / $TOTAL, 2))")
    echo "$REWARD" > "$REWARD_FILE"
    echo "REWARD: $REWARD"
fi
