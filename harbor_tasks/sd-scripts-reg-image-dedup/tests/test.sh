#!/usr/bin/env bash
# Verification for sd-scripts-reg-image-dedup
#
# Tests that the agent refactored the duplicate regularization-image balancing
# loop into a shared helper method AND added the update_counts parameter to
# avoid calling update_dataset_image_counts() twice.
#
# Scoring (11 tests, weighted to 100):
#   Structural  (2 tests, 10%): helper exists, call sites correct
#   Behavioral  (7 tests, 75%): functional correctness of helper + update_counts
#   P2P         (1 test,  10%): upstream library tests still pass
#   Compile     (1 test,   5%): file integrity
#
# Max stub score: 0.25 (structural 0.10 + P2P 0.10 + compile 0.05)

set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

R=0  # reward in hundredths; final = min(1.0, R/100)

echo "=== sd-scripts-reg-image-dedup verifier ==="

###############################################################################
# Shared helper-discovery module — written once, imported by all tests.
# Finds the extracted helper method dynamically (call-site + name fallback).
###############################################################################
cat > /tmp/disco.py << 'DISCO'
import ast, sys, logging, math, typing

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}

def load(path="/workspace/sd-scripts/library/train_util.py"):
    with open(path) as f:
        src = f.read()
    return src, ast.parse(src)

def _call(caller, name):
    """True if AST node `caller` contains a call to `name`."""
    return caller and any(
        isinstance(n, ast.Call) and (
            (isinstance(n.func, ast.Attribute) and n.func.attr == name) or
            (isinstance(n.func, ast.Name) and n.func.id == name))
        for n in ast.walk(caller))

def _nontrivial(fn, m=3):
    """Anti-stub: body has >= m non-trivial statements."""
    return len([s for s in fn.body
                if not isinstance(s, ast.Pass)
                and not (isinstance(s, ast.Expr)
                         and isinstance(s.value, ast.Constant))]) >= m

def find_cls(tree, name):
    for c in ast.walk(tree):
        if isinstance(c, ast.ClassDef) and c.name == name:
            return c
    return None

def find_helper(src, tree):
    """Find the shared helper in DreamBoothDataset.
    Primary: method called from both __init__ AND rebalance (call-site analysis).
    Fallback: name contains 'reg'/'regularization', >= 3 args, non-trivial body.
    Returns (name, func_node) or (None, None)."""
    cls = find_cls(tree, "DreamBoothDataset")
    if not cls:
        return None, None
    M = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
    init, reb = M.get("__init__"), M.get("rebalance_regularization_images")
    if init and reb:
        for nm, fn in M.items():
            if nm in SKIP or len(fn.args.args) < 2:
                continue
            if _call(init, nm) and _call(reb, nm) and _nontrivial(fn):
                return nm, fn
    for nm, fn in M.items():
        if nm in SKIP:
            continue
        lo = nm.lower()
        if ("reg" in lo or "regularization" in lo) and len(fn.args.args) >= 3 and _nontrivial(fn):
            return nm, fn
    return None, None

def src_of(src, func):
    """Extract source text for an AST function node."""
    seg = ast.get_source_segment(src, func)
    if not seg:
        seg = "\n".join(src.splitlines()[func.lineno - 1 : func.end_lineno])
    return seg

def mk_cls(src, *funcs, track=False):
    """Build a test class containing extracted method(s) + register_image mock."""
    reg = ("    def register_image(self, info, subset):\n"
           + ("        self._reg_calls.append(info.image_key)\n" if track else "")
           + "        self.image_data[info.image_key] = info\n"
           "        self.image_to_subset[info.image_key] = subset\n")
    parts = ["from __future__ import annotations\nclass _T:\n" + reg]
    for fn in funcs:
        parts.append("\n".join("    " + l for l in src_of(src, fn).splitlines()))
    return "\n\n".join(parts) + "\n"

def ns():
    d = {"logger": logging.getLogger("test"), "logging": logging,
         "math": math, "typing": typing}
    d.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
    return d

def find_uparam(tree):
    """Find update_counts-like param on BaseDataset.filter_registered_images_by_orig_resolution.
    Returns (param_name, func_node) or (None, func_node) or (None, None)."""
    cls = find_cls(tree, "BaseDataset")
    if not cls:
        return None, None
    for item in cls.body:
        if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
            for p in [a.arg for a in item.args.args[1:]] + [a.arg for a in item.args.kwonlyargs]:
                if "count" in p.lower() or "update" in p.lower():
                    return p, item
            return None, item
    return None, None

class I:
    """Mock ImageInfo."""
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg

class S:
    """Mock Subset."""
    def __init__(self, r):
        self.num_repeats = r
DISCO

###############################################################################
# TEST 1 (Structural, 5pts): Helper method exists in DreamBoothDataset
#         AND rebalance_regularization_images still exists.
#         Anti-stub: helper body >= 3 non-trivial statements.
###############################################################################
echo "--- Test 1/11: Helper method + rebalance exist ---"
python3 << 'PYEOF' && R=$((R + 5)) || true
import sys; sys.path.insert(0, "/tmp")
from disco import load, find_helper, find_cls

src, tree = load()
name, fn = find_helper(src, tree)
if not fn:
    print("FAIL: No helper method found in DreamBoothDataset"); sys.exit(1)

cls = find_cls(tree, "DreamBoothDataset")
meths = {i.name for i in cls.body if hasattr(i, "name")}
if "rebalance_regularization_images" not in meths:
    print("FAIL: rebalance_regularization_images was removed"); sys.exit(1)

print(f"PASS: Helper '{name}' + rebalance both exist")
PYEOF

###############################################################################
# TEST 2 (Structural, 5pts): __init__ and rebalance both call the helper
###############################################################################
echo "--- Test 2/11: __init__ and rebalance both call helper ---"
python3 << 'PYEOF' && R=$((R + 5)) || true
import sys, ast; sys.path.insert(0, "/tmp")
from disco import load, find_cls, _call, SKIP

src, tree = load()
cls = find_cls(tree, "DreamBoothDataset")
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

M = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
init_n = M.get("__init__")
reb_n = M.get("rebalance_regularization_images")
if not init_n or not reb_n:
    print("FAIL: __init__ or rebalance missing"); sys.exit(1)

for nm, fn in M.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    if _call(init_n, nm) and _call(reb_n, nm):
        print(f"PASS: Both __init__ and rebalance call {nm}")
        sys.exit(0)

print("FAIL: No shared helper called from both __init__ and rebalance")
sys.exit(1)
PYEOF

###############################################################################
# TEST 3 (Behavioral, 10pts): Helper correctly balances 1 reg image
#         1 reg with subset_repeats=1, 3 train -> repeats >= 3
###############################################################################
echo "--- Test 3/11: Helper balances 1 reg image (1 reg, 3 train) ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys; sys.path.insert(0, "/tmp")
from disco import load, find_helper, mk_cls, ns, I, S

src, tree = load()
name, fn = find_helper(src, tree)
if not fn:
    print("FAIL: Helper not found"); sys.exit(1)

N = ns()
try:
    exec(mk_cls(src, fn), N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}

try:
    getattr(t, name)([(I("reg_0", 1, True), S(1))], 3)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

if "reg_0" not in t.image_data:
    print("FAIL: reg_0 not registered into image_data"); sys.exit(1)
if t.image_data["reg_0"].num_repeats < 3:
    print(f"FAIL: repeats={t.image_data['reg_0'].num_repeats}, expected >= 3"); sys.exit(1)
print(f"PASS: 1 reg balanced to {t.image_data['reg_0'].num_repeats} repeats (>= 3)")
PYEOF

###############################################################################
# TEST 4 (Behavioral, 10pts): Helper balances 3 reg images with correct
#         distribution (3 reg x subset_repeats=2, 10 train).
#         Catches naive stubs that set repeats = num_train per image.
###############################################################################
echo "--- Test 4/11: Helper balances 3 reg images (3 reg, 10 train) ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys; sys.path.insert(0, "/tmp")
from disco import load, find_helper, mk_cls, ns, I, S

src, tree = load()
name, fn = find_helper(src, tree)
if not fn:
    print("FAIL: Helper not found"); sys.exit(1)

N = ns()
try:
    exec(mk_cls(src, fn), N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}
regs = [(I(f"reg_{i}", 2, True), S(2)) for i in range(3)]

try:
    getattr(t, name)(regs, 10)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

for i in range(3):
    if f"reg_{i}" not in t.image_data:
        print(f"FAIL: reg_{i} not registered"); sys.exit(1)

# Sum of repeats must be close to num_train=10; allow [10, 13] for minor variations
total = sum(t.image_data[f"reg_{i}"].num_repeats for i in range(3))
if total < 10:
    print(f"FAIL: total repeats {total} < 10 (under-allocated)"); sys.exit(1)
if total > 13:
    print(f"FAIL: total repeats {total} > 13 (over-allocated)"); sys.exit(1)

# Each reg should have reasonable repeats — not set to num_train individually
for i in range(3):
    reps = t.image_data[f"reg_{i}"].num_repeats
    if reps > 7:
        print(f"FAIL: reg_{i} has {reps} repeats (expected <= 7, not num_train)"); sys.exit(1)

print(f"PASS: 3 reg balanced, total={total}")
PYEOF

###############################################################################
# TEST 5 (Behavioral, 10pts): Helper calls register_image for each reg image.
#         Uses a tracking mock to verify register_image is actually called.
###############################################################################
echo "--- Test 5/11: Helper calls register_image for each reg image ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys; sys.path.insert(0, "/tmp")
from disco import load, find_helper, mk_cls, ns, I, S

src, tree = load()
name, fn = find_helper(src, tree)
if not fn:
    print("FAIL: Helper not found"); sys.exit(1)

N = ns()
try:
    exec(mk_cls(src, fn, track=True), N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}; t._reg_calls = []
regs = [(I(f"r_{i}", 1, True), S(1)) for i in range(4)]

try:
    getattr(t, name)(regs, 10)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

expected = {"r_0", "r_1", "r_2", "r_3"}
missing = expected - set(t._reg_calls)
if missing:
    print(f"FAIL: register_image not called for {missing}"); sys.exit(1)
print(f"PASS: register_image called for all {len(expected)} reg images")
PYEOF

###############################################################################
# TEST 6 (Behavioral, 10pts): update_counts=False skips update_dataset_image_counts.
#         Extracts BaseDataset.filter_registered_images_by_orig_resolution,
#         calls with False, verifies the count update is skipped.
###############################################################################
echo "--- Test 6/11: update_counts=False skips count update in base filter ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys, math, typing; sys.path.insert(0, "/tmp")
from disco import load, find_uparam, src_of

src, tree = load()
param, fn = find_uparam(tree)
if not param:
    print("FAIL: No update_counts-like parameter on filter_registered_images_by_orig_resolution")
    sys.exit(1)

seg = src_of(src, fn)
ind = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\n"
    "class _FT:\n"
    "    def has_orig_resolution_filter(self): return True\n"
    "    def check_orig_resolution(self, s):\n"
    "        import math; return math.sqrt(s[0]*s[1]) > 100\n"
    "    def update_dataset_image_counts(self): self._updated = True\n"
    "\n" + ind + "\n"
)

class _FI:
    def __init__(self, sz): self.image_size = sz

N = {"math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile filter: {e}"); sys.exit(1)

t = N["_FT"]()
t.image_data = {"tiny": _FI((5, 5))}   # area=25, fails resolution check
t.image_to_subset = {"tiny": None}
t._updated = False

try:
    t.filter_registered_images_by_orig_resolution(**{param: False})
except Exception as e:
    print(f"FAIL: filter call failed: {e}"); sys.exit(1)

if t._updated:
    print(f"FAIL: {param}=False still called update_dataset_image_counts"); sys.exit(1)
if "tiny" in t.image_data:
    print("FAIL: image was not filtered out"); sys.exit(1)
print(f"PASS: {param}=False skips count update")
PYEOF

###############################################################################
# TEST 7 (Behavioral, 10pts): update_counts=True triggers update_dataset_image_counts
###############################################################################
echo "--- Test 7/11: update_counts=True triggers count update in base filter ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys, math, typing; sys.path.insert(0, "/tmp")
from disco import load, find_uparam, src_of

src, tree = load()
param, fn = find_uparam(tree)
if not param:
    print("FAIL: No update_counts-like parameter found"); sys.exit(1)

seg = src_of(src, fn)
ind = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\n"
    "class _FT:\n"
    "    def has_orig_resolution_filter(self): return True\n"
    "    def check_orig_resolution(self, s):\n"
    "        import math; return math.sqrt(s[0]*s[1]) > 100\n"
    "    def update_dataset_image_counts(self): self._updated = True\n"
    "\n" + ind + "\n"
)

class _FI:
    def __init__(self, sz): self.image_size = sz

N = {"math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile filter: {e}"); sys.exit(1)

t = N["_FT"]()
t.image_data = {"tiny": _FI((5, 5))}
t.image_to_subset = {"tiny": None}
t._updated = False

try:
    t.filter_registered_images_by_orig_resolution(**{param: True})
except Exception as e:
    print(f"FAIL: filter call failed: {e}"); sys.exit(1)

if not t._updated:
    print(f"FAIL: {param}=True did not call update_dataset_image_counts"); sys.exit(1)
print(f"PASS: {param}=True triggers count update")
PYEOF

###############################################################################
# TEST 8 (Behavioral, 15pts): rebalance_regularization_images end-to-end.
#         Sets up mock with train + reg images, calls rebalance, verifies
#         reg images are removed and re-registered with balanced repeats.
###############################################################################
echo "--- Test 8/11: rebalance_regularization_images end-to-end ---"
python3 << 'PYEOF' && R=$((R + 15)) || true
import sys, ast; sys.path.insert(0, "/tmp")
from disco import load, find_helper, find_cls, mk_cls, ns, I, S

src, tree = load()
name, hfn = find_helper(src, tree)
if not hfn:
    print("FAIL: Helper not found"); sys.exit(1)

cls = find_cls(tree, "DreamBoothDataset")
reb = None
for item in cls.body:
    if isinstance(item, ast.FunctionDef) and item.name == "rebalance_regularization_images":
        reb = item; break
if not reb:
    print("FAIL: rebalance_regularization_images not found"); sys.exit(1)

# Build class containing both helper and rebalance methods
N = ns()
try:
    exec(mk_cls(src, hfn, reb), N)
except Exception as e:
    print(f"FAIL: Could not compile: {e}"); sys.exit(1)

# Setup: 3 train images (2 reps each = 6 total) + 2 reg images
t = N["_T"]()
t.is_training_dataset = True
t.image_data = {}; t.image_to_subset = {}

train_sub = S(2)
for i in range(3):
    info = I(f"train_{i}", 2, False)
    t.image_data[f"train_{i}"] = info
    t.image_to_subset[f"train_{i}"] = train_sub

reg_sub = S(1)
for i in range(2):
    info = I(f"reg_{i}", 1, True)
    t.image_data[f"reg_{i}"] = info
    t.image_to_subset[f"reg_{i}"] = reg_sub

try:
    t.rebalance_regularization_images()
except Exception as e:
    print(f"FAIL: rebalance call failed: {e}"); sys.exit(1)

# Train images should still exist
for i in range(3):
    if f"train_{i}" not in t.image_data:
        print(f"FAIL: train_{i} was removed"); sys.exit(1)

# Reg images should be re-registered
reg_found = [k for k in t.image_data if k.startswith("reg_")]
if not reg_found:
    print("FAIL: No reg images re-registered after rebalance"); sys.exit(1)

# Total reg repeats should be >= train total (6)
train_total = sum(t.image_data[f"train_{i}"].num_repeats for i in range(3))
reg_total = sum(t.image_data[k].num_repeats for k in reg_found)
if reg_total < train_total:
    print(f"FAIL: reg_total={reg_total} < train_total={train_total}"); sys.exit(1)

print(f"PASS: rebalance end-to-end (train={train_total}, reg={reg_total})")
PYEOF

###############################################################################
# TEST 9 (Behavioral, 10pts): Helper with varied subset_repeats
#         2 reg with subset_repeats 1 and 3, 7 train
###############################################################################
echo "--- Test 9/11: Helper with varied subset_repeats (2 reg, 7 train) ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import sys; sys.path.insert(0, "/tmp")
from disco import load, find_helper, mk_cls, ns, I, S

src, tree = load()
name, fn = find_helper(src, tree)
if not fn:
    print("FAIL: Helper not found"); sys.exit(1)

N = ns()
try:
    exec(mk_cls(src, fn), N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}
regs = [
    (I("r_a", 1, True), S(1)),
    (I("r_b", 3, True), S(3)),
]

try:
    getattr(t, name)(regs, 7)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

if "r_a" not in t.image_data or "r_b" not in t.image_data:
    print("FAIL: Not all reg images registered"); sys.exit(1)

total = t.image_data["r_a"].num_repeats + t.image_data["r_b"].num_repeats
if total < 7:
    print(f"FAIL: total={total} < 7 (under-allocated)"); sys.exit(1)
if total > 11:
    print(f"FAIL: total={total} > 11 (over-allocated)"); sys.exit(1)

print(f"PASS: Varied repeats: r_a={t.image_data['r_a'].num_repeats}, r_b={t.image_data['r_b'].num_repeats}, total={total}")
PYEOF

###############################################################################
# TEST 10 (P2P, 10pts): Upstream library tests still pass
###############################################################################
echo "--- Test 10/11: P2P upstream library tests ---"
(
    cd /workspace/sd-scripts
    if ! python3 -m pytest --version >/dev/null 2>&1; then
        echo "SKIP: pytest not available"; exit 1
    fi

    if [ -d "tests/library" ]; then
        TEST_DIR="tests/library"
    elif [ -d "tests" ]; then
        TEST_DIR="tests"
    else
        echo "SKIP: no tests directory found"; exit 1
    fi

    echo "Running: pytest $TEST_DIR -x --timeout=60 -q"
    python3 -m pytest "$TEST_DIR" -x --timeout=60 -q 2>&1 | tail -10
    exit ${PIPESTATUS[0]}
) && R=$((R + 10)) || true

###############################################################################
# TEST 11 (Compile, 5pts): File compiles cleanly
###############################################################################
echo "--- Test 11/11: train_util.py compiles ---"
python3 -m py_compile /workspace/sd-scripts/library/train_util.py && \
    echo "PASS: py_compile succeeded" && R=$((R + 5)) || \
    echo "FAIL: py_compile failed"

###############################################################################
# Write reward
###############################################################################
REWARD=$(python3 -c "print(f'{min(1.0, $R / 100):.4f}')")
echo "$REWARD" > "$REWARD_FILE"
echo "=== RESULT: R=$R/100, reward=$REWARD ==="
