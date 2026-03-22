#!/usr/bin/env bash
#
# Verification test for MambaCache/ArraysCache batching support in mlx-lm.
# Checks structural correctness of merge/extract/prepare/finalize methods on
# ArraysCache, CacheList merge/extract, _merge_caches update in generate.py,
# and presence of a test file. All tests run on CPU -- no GPU/Metal required.
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

echo "=== Test 1/10: ArraysCache has merge() classmethod ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

# Find ArraysCache class
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
        if "merge" in methods:
            # Check it's a classmethod (has @classmethod decorator)
            merge_node = methods["merge"]
            decorators = [d for d in merge_node.decorator_list
                         if (isinstance(d, ast.Name) and d.id == "classmethod") or
                            (isinstance(d, ast.Attribute) and d.attr == "classmethod")]
            if decorators:
                print("PASS: ArraysCache has merge() classmethod")
            else:
                # Also accept staticmethod or regular method that takes cls
                params = [a.arg for a in merge_node.args.args]
                if params and params[0] == "cls":
                    print("PASS: ArraysCache has merge() with cls parameter")
                else:
                    print("PASS: ArraysCache has merge() method (not classmethod but acceptable)")
            sys.exit(0)
        else:
            print("FAIL: ArraysCache exists but has no merge() method")
            sys.exit(1)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 2/10: ArraysCache has extract() method ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name for n in node.body if isinstance(n, ast.FunctionDef)}
        if "extract" in methods:
            print("PASS: ArraysCache has extract() method")
            sys.exit(0)
        else:
            print("FAIL: ArraysCache exists but has no extract() method")
            sys.exit(1)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 3/10: ArraysCache has prepare() method ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
        if "prepare" in methods:
            prep = methods["prepare"]
            all_params = [a.arg for a in prep.args.args] + [a.arg for a in prep.args.kwonlyargs]
            # Should accept left_padding and/or lengths
            has_padding = any("padding" in p.lower() or "left" in p.lower() for p in all_params)
            has_lengths = any("length" in p.lower() for p in all_params)
            if has_padding or has_lengths:
                print(f"PASS: ArraysCache has prepare() with params: {all_params}")
            else:
                print(f"PASS: ArraysCache has prepare() method (params: {all_params})")
            sys.exit(0)
        else:
            print("FAIL: ArraysCache exists but has no prepare() method")
            sys.exit(1)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 4/10: ArraysCache has finalize() method ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        methods = {n.name for n in node.body if isinstance(n, ast.FunctionDef)}
        if "finalize" in methods:
            print("PASS: ArraysCache has finalize() method")
            sys.exit(0)
        else:
            print("FAIL: ArraysCache exists but has no finalize() method")
            sys.exit(1)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 5/10: ArraysCache._lengths attribute initialized and used in make_mask ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

# Find ArraysCache class specifically and check for _lengths
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "ArraysCache":
        # Check if _lengths is referenced anywhere in ArraysCache body
        class_source_lines = source.split('\n')
        # Get the line range for ArraysCache
        start_line = node.lineno - 1
        end_line = node.end_lineno if hasattr(node, 'end_lineno') and node.end_lineno else len(class_source_lines)
        class_body = '\n'.join(class_source_lines[start_line:end_line])

        has_lengths_in_class = '_lengths' in class_body

        # Also check if _lengths is used in the make_mask method
        methods = {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
        has_lengths_in_mask = False
        if 'make_mask' in methods:
            mask_node = methods['make_mask']
            mask_start = mask_node.lineno - 1
            mask_end = mask_node.end_lineno if hasattr(mask_node, 'end_lineno') and mask_node.end_lineno else mask_start + 20
            mask_body = '\n'.join(class_source_lines[mask_start:mask_end])
            has_lengths_in_mask = '_lengths' in mask_body

        if has_lengths_in_class and has_lengths_in_mask:
            print("PASS: _lengths attribute exists in ArraysCache and is used in make_mask()")
        elif has_lengths_in_class:
            print("PASS: _lengths attribute exists in ArraysCache class body")
        else:
            print("FAIL: _lengths not found in ArraysCache class (only exists in other cache classes)")
            sys.exit(1)
        sys.exit(0)

print("FAIL: ArraysCache class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 6/10: CacheList has merge() classmethod ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "CacheList":
        methods = {n.name for n in node.body if isinstance(n, ast.FunctionDef)}
        if "merge" in methods:
            print("PASS: CacheList has merge() method")
            sys.exit(0)
        else:
            print("FAIL: CacheList exists but has no merge() method")
            sys.exit(1)

print("FAIL: CacheList class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 7/10: CacheList has extract() method ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, ast

with open("/workspace/mlx-lm/mlx_lm/models/cache.py", "r") as f:
    source = f.read()

tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "CacheList":
        methods = {n.name for n in node.body if isinstance(n, ast.FunctionDef)}
        if "extract" in methods:
            print("PASS: CacheList has extract() method")
            sys.exit(0)
        else:
            print("FAIL: CacheList exists but has no extract() method")
            sys.exit(1)

print("FAIL: CacheList class not found")
sys.exit(1)
PYEOF

echo ""
echo "=== Test 8/10: _merge_caches() handles ArraysCache ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, re

with open("/workspace/mlx-lm/mlx_lm/generate.py", "r") as f:
    source = f.read()

# Find the _merge_caches function and check it handles ArraysCache
# Look for ArraysCache reference inside _merge_caches
in_merge = False
found_arrays_cache = False
lines = source.split('\n')
for line in lines:
    if 'def _merge_caches' in line:
        in_merge = True
    elif in_merge and line.strip().startswith('def ') and '_merge_caches' not in line:
        break
    elif in_merge and line.strip().startswith('class '):
        break
    if in_merge and 'ArraysCache' in line:
        found_arrays_cache = True

if found_arrays_cache:
    print("PASS: _merge_caches() references ArraysCache")
else:
    # Alternative: check if _merge_caches handles it via a generic .merge() call
    # or if the ValueError for unsupported types has been removed/modified
    has_merge_caches = bool(re.search(r'def _merge_caches', source))
    if not has_merge_caches:
        print("FAIL: _merge_caches() function not found in generate.py")
        sys.exit(1)
    # Check if the error message has been updated to suggest it supports more types
    has_old_error_only = bool(re.search(
        r'does not yet support batching with history', source
    ))
    if not has_old_error_only:
        # Error removed or modified -- likely all types handled
        print("PASS: _merge_caches() appears to handle all cache types (old error removed)")
    else:
        print("FAIL: _merge_caches() still only handles KVCache/RotatingKVCache")
        sys.exit(1)
PYEOF

echo ""
echo "=== Test 9/10: _merge_caches() handles CacheList ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, re

with open("/workspace/mlx-lm/mlx_lm/generate.py", "r") as f:
    source = f.read()

# Find the _merge_caches function and check it handles CacheList
in_merge = False
found_cache_list = False
lines = source.split('\n')
for line in lines:
    if 'def _merge_caches' in line:
        in_merge = True
    elif in_merge and line.strip().startswith('def ') and '_merge_caches' not in line:
        break
    elif in_merge and line.strip().startswith('class '):
        break
    if in_merge and 'CacheList' in line:
        found_cache_list = True

if found_cache_list:
    print("PASS: _merge_caches() references CacheList")
else:
    # Alternative: check if there's a generic handler that would catch CacheList
    # via hasattr(cache, 'merge') or similar
    in_merge = False
    has_generic = False
    for line in lines:
        if 'def _merge_caches' in line:
            in_merge = True
        elif in_merge and line.strip().startswith('def ') and '_merge_caches' not in line:
            break
        if in_merge and ('hasattr' in line and 'merge' in line):
            has_generic = True

    if has_generic:
        print("PASS: _merge_caches() has generic merge handling (covers CacheList)")
    else:
        print("FAIL: _merge_caches() does not handle CacheList")
        sys.exit(1)
PYEOF

echo ""
echo "=== Test 10/10: Test file exists with test cases ==="
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import sys, os, ast, glob

# Look for test file in tests/ directory
test_patterns = [
    "/workspace/mlx-lm/tests/test_mamba_cache_batching.py",
    "/workspace/mlx-lm/tests/test_mamba_cache*.py",
    "/workspace/mlx-lm/tests/test_arrays_cache*.py",
    "/workspace/mlx-lm/tests/test_cache_batch*.py",
    "/workspace/mlx-lm/tests/test_batch_cache*.py",
]

test_file = None
for pattern in test_patterns:
    matches = glob.glob(pattern)
    if matches:
        test_file = matches[0]
        break

if test_file is None:
    # Broader search: any new test file that references ArraysCache or MambaCache
    for f in glob.glob("/workspace/mlx-lm/tests/test_*.py"):
        with open(f, "r") as fh:
            content = fh.read()
        if "ArraysCache" in content or "MambaCache" in content:
            if "merge" in content or "extract" in content:
                test_file = f
                break

if test_file is None:
    print("FAIL: no test file found for MambaCache/ArraysCache batching")
    sys.exit(1)

# Parse and count test methods
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

if test_count >= 5:
    print(f"PASS: test file {os.path.basename(test_file)} has {test_count} test methods")
elif test_count > 0:
    print(f"PASS: test file {os.path.basename(test_file)} has {test_count} test methods (fewer than ideal)")
else:
    print(f"FAIL: test file exists but has no test_ methods")
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
