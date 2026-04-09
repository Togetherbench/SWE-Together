#!/usr/bin/env bash
# Verification for sd-scripts-reg-image-dedup
#
# Tests that the agent refactored the duplicate regularization-image balancing
# loop into a shared helper method AND added the update_counts parameter to
# avoid calling update_dataset_image_counts() twice.
#
# Weight budget (sums to 1.00):
#   Structural  (0.10): tests 1-2   (helper exists, call sites)
#   Behavioral  (0.78): tests 3-11  (functional correctness)
#   P2P         (0.07): test 12     (upstream tests)
#   Compile     (0.05): test 13     (file integrity)
#
# Max stub score: 0.15 (structural 0.10 + compile 0.05)
# Behavioral tests all require working code that produces correct outputs.

set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

R=0  # reward in hundredths; final = min(1.0, R/100)
SRC="/workspace/sd-scripts/library/train_util.py"

echo "=== sd-scripts-reg-image-dedup verifier ==="

###############################################################################
# TEST 1 (Structural, 5pts): Helper method exists in DreamBoothDataset
#         AND rebalance_regularization_images still exists.
#         Anti-stub: helper body >= 3 non-trivial statements.
###############################################################################
echo "--- Test 1/13: Helper method + rebalance exist ---"
python3 << 'PYEOF' && R=$((R + 5)) || true
import ast, sys

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

# Find DreamBoothDataset
cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node
        break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}

methods = {item.name: item for item in cls.body if isinstance(item, ast.FunctionDef)}

if "rebalance_regularization_images" not in methods:
    print("FAIL: rebalance_regularization_images was removed"); sys.exit(1)

# Find helper: method with >= 3 non-trivial stmts, >= 2 args, not in SKIP
helper_name = None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name = nm
        break

if not helper_name:
    print("FAIL: No helper method found in DreamBoothDataset"); sys.exit(1)

print(f"PASS: Helper '{helper_name}' + rebalance both exist")
PYEOF

###############################################################################
# TEST 2 (Structural, 5pts): __init__ and rebalance both call the helper
###############################################################################
echo "--- Test 2/13: __init__ and rebalance both call helper ---"
python3 << 'PYEOF' && R=$((R + 5)) || true
import ast, sys

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}

M = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
init_n = M.get("__init__")
reb_n = M.get("rebalance_regularization_images")
if not init_n or not reb_n:
    print("FAIL: __init__ or rebalance missing"); sys.exit(1)

def calls_method(caller, name):
    return any(
        isinstance(n, ast.Call) and (
            (isinstance(n.func, ast.Attribute) and n.func.attr == name) or
            (isinstance(n.func, ast.Name) and n.func.id == name))
        for n in ast.walk(caller))

for nm in M:
    if nm in SKIP or len(M[nm].args.args) < 2:
        continue
    if calls_method(init_n, nm) and calls_method(reb_n, nm):
        print(f"PASS: Both __init__ and rebalance call {nm}")
        sys.exit(0)

print("FAIL: No shared helper called from both __init__ and rebalance")
sys.exit(1)
PYEOF

###############################################################################
# TEST 3 (Behavioral, 8pts): Helper correctly balances 1 reg image
#         1 reg with subset_repeats=1, 3 train -> repeats >= 3
###############################################################################
echo "--- Test 3/13: Helper balances 1 reg image (1 reg, 3 train) ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

# Find DreamBoothDataset and its helper
cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}

methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

# Extract helper source
seg = ast.get_source_segment(src, helper_fn)
if not seg:
    seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])

# Build a minimal test class with register_image + helper
indented = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\n"
    "class _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + indented + "\n"
)

class I:
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg

class S:
    def __init__(self, r):
        self.num_repeats = r

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})

try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}

try:
    getattr(t, helper_name)([(I("reg_0", 1, True), S(1))], 3)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

if "reg_0" not in t.image_data:
    print("FAIL: reg_0 not registered into image_data"); sys.exit(1)
if t.image_data["reg_0"].num_repeats < 3:
    print(f"FAIL: repeats={t.image_data['reg_0'].num_repeats}, expected >= 3"); sys.exit(1)
print(f"PASS: 1 reg balanced to {t.image_data['reg_0'].num_repeats} repeats (>= 3)")
PYEOF

###############################################################################
# TEST 4 (Behavioral, 8pts): Helper balances 3 reg images with correct
#         distribution (3 reg x subset_repeats=2, 10 train).
#         Catches naive stubs that set repeats = num_train per image.
###############################################################################
echo "--- Test 4/13: Helper balances 3 reg images (3 reg, 10 train) ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}
methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

seg = ast.get_source_segment(src, helper_fn)
if not seg:
    seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + indented + "\n"
)

class I:
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg
class S:
    def __init__(self, r):
        self.num_repeats = r

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}
regs = [(I(f"reg_{i}", 2, True), S(2)) for i in range(3)]

try:
    getattr(t, helper_name)(regs, 10)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

for i in range(3):
    if f"reg_{i}" not in t.image_data:
        print(f"FAIL: reg_{i} not registered"); sys.exit(1)

total = sum(t.image_data[f"reg_{i}"].num_repeats for i in range(3))
if total < 10:
    print(f"FAIL: total repeats {total} < 10 (under-allocated)"); sys.exit(1)
if total > 13:
    print(f"FAIL: total repeats {total} > 13 (over-allocated)"); sys.exit(1)

for i in range(3):
    reps = t.image_data[f"reg_{i}"].num_repeats
    if reps > 7:
        print(f"FAIL: reg_{i} has {reps} repeats (expected <= 7, not num_train)"); sys.exit(1)

print(f"PASS: 3 reg balanced, total={total}")
PYEOF

###############################################################################
# TEST 5 (Behavioral, 8pts): Helper calls register_image for each reg image.
#         Uses a tracking mock to verify register_image is actually called.
###############################################################################
echo "--- Test 5/13: Helper calls register_image for each reg image ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}
methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

seg = ast.get_source_segment(src, helper_fn)
if not seg:
    seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self._reg_calls.append(info.image_key)\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + indented + "\n"
)

class I:
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg
class S:
    def __init__(self, r):
        self.num_repeats = r

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}; t._reg_calls = []
regs = [(I(f"r_{i}", 1, True), S(1)) for i in range(4)]

try:
    getattr(t, helper_name)(regs, 10)
except Exception as e:
    print(f"FAIL: Helper call failed: {e}"); sys.exit(1)

expected = {"r_0", "r_1", "r_2", "r_3"}
missing = expected - set(t._reg_calls)
if missing:
    print(f"FAIL: register_image not called for {missing}"); sys.exit(1)
print(f"PASS: register_image called for all {len(expected)} reg images")
PYEOF

###############################################################################
# TEST 6 (Behavioral, 8pts): Helper with varied subset_repeats
#         2 reg with subset_repeats 1 and 3, 7 train
###############################################################################
echo "--- Test 6/13: Helper with varied subset_repeats (2 reg, 7 train) ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}
methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

seg = ast.get_source_segment(src, helper_fn)
if not seg:
    seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + indented + "\n"
)

class I:
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg
class S:
    def __init__(self, r):
        self.num_repeats = r

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}
regs = [
    (I("r_a", 1, True), S(1)),
    (I("r_b", 3, True), S(3)),
]

try:
    getattr(t, helper_name)(regs, 7)
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
# TEST 7 (Behavioral, 12pts): rebalance_regularization_images end-to-end.
#         Sets up mock with train + reg images, calls rebalance, verifies
#         reg images are removed and re-registered with balanced repeats.
###############################################################################
echo "--- Test 7/13: rebalance_regularization_images end-to-end ---"
python3 << 'PYEOF' && R=$((R + 12)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}
methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}

helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

reb_fn = methods.get("rebalance_regularization_images")
if not reb_fn:
    print("FAIL: rebalance_regularization_images not found"); sys.exit(1)

# Extract source for both methods
def get_src(fn):
    seg = ast.get_source_segment(src, fn)
    if not seg:
        seg = "\n".join(src.splitlines()[fn.lineno - 1 : fn.end_lineno])
    return seg

helper_src = get_src(helper_fn)
reb_src = get_src(reb_fn)

code = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + "\n".join("    " + l for l in helper_src.splitlines()) + "\n\n"
    + "\n".join("    " + l for l in reb_src.splitlines()) + "\n"
)

class I:
    def __init__(self, k, r, reg=False):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg
class S:
    def __init__(self, r):
        self.num_repeats = r

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
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
# TEST 8 (Behavioral, 8pts): update_counts=False skips update_dataset_image_counts.
#         Finds the update_counts-like param on filter_registered_images_by_orig_resolution
#         and calls with False to verify count update is skipped.
###############################################################################
echo "--- Test 8/13: update_counts=False skips count update in base filter ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

# Find BaseDataset
base_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "BaseDataset":
        base_cls = node; break
if not base_cls:
    print("FAIL: BaseDataset not found"); sys.exit(1)

# Find filter_registered_images_by_orig_resolution
filter_fn = None
for item in base_cls.body:
    if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
        filter_fn = item; break
if not filter_fn:
    print("FAIL: filter_registered_images_by_orig_resolution not found in BaseDataset"); sys.exit(1)

# Find update_counts-like param
param = None
for p in [a.arg for a in filter_fn.args.args[1:]] + [a.arg for a in filter_fn.args.kwonlyargs]:
    if "count" in p.lower() or "update" in p.lower():
        param = p; break
if not param:
    print("FAIL: No update_counts-like parameter on filter_registered_images_by_orig_resolution")
    sys.exit(1)

# Extract source and build test class
seg = ast.get_source_segment(src, filter_fn)
if not seg:
    seg = "\n".join(src.splitlines()[filter_fn.lineno - 1 : filter_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())

code = (
    "from __future__ import annotations\n"
    "class _FT:\n"
    "    def has_orig_resolution_filter(self): return True\n"
    "    def check_orig_resolution(self, s):\n"
    "        import math; return math.sqrt(s[0]*s[1]) > 100\n"
    "    def update_dataset_image_counts(self): self._updated = True\n\n"
    + indented + "\n"
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
# TEST 9 (Behavioral, 8pts): update_counts=True triggers update_dataset_image_counts
###############################################################################
echo "--- Test 9/13: update_counts=True triggers count update in base filter ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

base_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "BaseDataset":
        base_cls = node; break
if not base_cls:
    print("FAIL: BaseDataset not found"); sys.exit(1)

filter_fn = None
for item in base_cls.body:
    if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
        filter_fn = item; break
if not filter_fn:
    print("FAIL: filter method not found"); sys.exit(1)

param = None
for p in [a.arg for a in filter_fn.args.args[1:]] + [a.arg for a in filter_fn.args.kwonlyargs]:
    if "count" in p.lower() or "update" in p.lower():
        param = p; break
if not param:
    print("FAIL: No update_counts param found"); sys.exit(1)

seg = ast.get_source_segment(src, filter_fn)
if not seg:
    seg = "\n".join(src.splitlines()[filter_fn.lineno - 1 : filter_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())

code = (
    "from __future__ import annotations\n"
    "class _FT:\n"
    "    def has_orig_resolution_filter(self): return True\n"
    "    def check_orig_resolution(self, s):\n"
    "        import math; return math.sqrt(s[0]*s[1]) > 100\n"
    "    def update_dataset_image_counts(self): self._updated = True\n\n"
    + indented + "\n"
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
# TEST 10 (Behavioral, 8pts): Helper handles zero reg images gracefully
#         Empty reg_infos list should not crash.
###############################################################################
echo "--- Test 10/13: Helper handles zero reg images ---"
python3 << 'PYEOF' && R=$((R + 8)) || true
import ast, sys, logging, math, typing

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}
methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
helper_name, helper_fn = None, None
for nm, fn in methods.items():
    if nm in SKIP or len(fn.args.args) < 2:
        continue
    nontrivial = len([s for s in fn.body
                      if not isinstance(s, ast.Pass)
                      and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
    if nontrivial >= 3:
        helper_name, helper_fn = nm, fn; break
if not helper_fn:
    print("FAIL: Helper not found"); sys.exit(1)

seg = ast.get_source_segment(src, helper_fn)
if not seg:
    seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])
indented = "\n".join("    " + l for l in seg.splitlines())
code = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n\n"
    + indented + "\n"
)

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}"); sys.exit(1)

t = N["_T"]()
t.image_data = {}; t.image_to_subset = {}

try:
    getattr(t, helper_name)([], 5)
except Exception as e:
    print(f"FAIL: Helper crashed on empty reg list: {e}"); sys.exit(1)

if len(t.image_data) != 0:
    print(f"FAIL: Expected 0 images, got {len(t.image_data)}"); sys.exit(1)
print("PASS: Helper handles empty reg_infos gracefully")
PYEOF

###############################################################################
# TEST 11 (Behavioral, 10pts): Duplicate balancing loop is removed from __init__
#         Verify that __init__ no longer contains the inline while-loop for
#         balancing (it should call the helper instead).
###############################################################################
echo "--- Test 11/13: Duplicate loop removed from __init__ ---"
python3 << 'PYEOF' && R=$((R + 10)) || true
import ast, sys

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        cls = node; break
if not cls:
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

methods = {i.name: i for i in cls.body if isinstance(i, ast.FunctionDef)}
init_fn = methods.get("__init__")
if not init_fn:
    print("FAIL: __init__ not found"); sys.exit(1)

# Count while loops in __init__ that look like balancing loops
# The buggy state has a while loop with first_loop/register_image pattern
while_count = 0
for node in ast.walk(init_fn):
    if isinstance(node, ast.While):
        while_count += 1

# Also check for "first_loop" variable usage in __init__
init_src = ast.get_source_segment(src, init_fn)
if not init_src:
    init_src = "\n".join(src.splitlines()[init_fn.lineno - 1 : init_fn.end_lineno])

has_first_loop = "first_loop" in init_src

if while_count == 0 and not has_first_loop:
    print("PASS: No duplicate balancing while-loop in __init__")
elif while_count == 0:
    # first_loop variable exists but no while loop -- might be leftover comment
    print("PASS: While loop removed from __init__ (first_loop ref may be comment)")
else:
    print(f"FAIL: __init__ still has {while_count} while loops (expected 0 -- should use helper)")
    sys.exit(1)
PYEOF

###############################################################################
# TEST 12 (P2P, 7pts): Upstream library tests still pass
###############################################################################
echo "--- Test 12/13: P2P upstream library tests ---"
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
) && R=$((R + 7)) || true

###############################################################################
# TEST 13 (Compile, 5pts): File compiles cleanly
###############################################################################
echo "--- Test 13/13: train_util.py compiles ---"
python3 -m py_compile /workspace/sd-scripts/library/train_util.py && \
    echo "PASS: py_compile succeeded" && R=$((R + 5)) || \
    echo "FAIL: py_compile failed"

###############################################################################
# Write reward
###############################################################################
REWARD=$(python3 -c "print(f'{min(1.0, $R / 100):.4f}')")
echo "$REWARD" > "$REWARD_FILE"
echo "=== RESULT: R=$R/100, reward=$REWARD ==="
