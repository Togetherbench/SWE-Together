#!/usr/bin/env bash
# Verification for sd-scripts-refactor-ses_38
#
# Tests that the agent refactored the duplicate regularization-image balancing
# loop into a shared helper method AND added the update_counts parameter to
# avoid calling update_dataset_image_counts() twice.
#
# Scoring (10 tests):
#   Structural (2 tests, 20%): helper exists, call sites correct
#   Behavioral (7 tests, 70%): functional correctness of helper + update_counts
#   Compile   (1 test,  10%): file integrity
#
# Stub analysis (def f(): pass + stub calls):
#   Structural: 2/10 pass, Compile: 1/10 pass → max stub = 0.30
#   Tests 6-7 require behavioral update_counts param (no structural fallback)
#
# Writes reward to /logs/verifier/reward.txt (0.0–1.0)

set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=10

TRAIN_UTIL="/workspace/sd-scripts/library/train_util.py"

echo "=== sd-scripts-refactor-ses_38 verifier ==="

###############################################################################
# TEST 1 (Structural/Bronze): Helper exists + rebalance_regularization_images
#         still exists in DreamBoothDataset
###############################################################################
echo "--- Test 1/10: Helper method + rebalance_regularization_images exist ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_found = False
rebalance_found = False

for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if not isinstance(item, ast.FunctionDef):
            continue
        name = item.name.lower()
        excl = name.startswith("filter_") or name.startswith("rebalance_") or name.startswith("__")
        # Accept "register" OR "balance" with "reg"/"regularization"
        if (not excl
                and ("register" in name or "balance" in name)
                and ("reg" in name or "regularization" in name)
                and len(item.args.args) >= 3):
            helper_found = True
        if name == "rebalance_regularization_images":
            rebalance_found = True

if not helper_found:
    print("FAIL: No helper method found in DreamBoothDataset")
    sys.exit(1)
if not rebalance_found:
    print("FAIL: rebalance_regularization_images was removed")
    sys.exit(1)
print("PASS: Helper + rebalance both exist")
sys.exit(0)
PYEOF

###############################################################################
# TEST 2 (Structural/Silver): __init__ and rebalance both call the helper
###############################################################################
echo "--- Test 2/10: __init__ and rebalance both call helper ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue

    # Find helper name
    helper_name = None
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            nm = item.name.lower()
            excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
            if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
                helper_name = item.name
                break
    if not helper_name:
        print("FAIL: Helper not found")
        sys.exit(1)

    init_calls = rebal_calls = False
    for item in cls.body:
        if not isinstance(item, ast.FunctionDef):
            continue
        for node in ast.walk(item):
            if isinstance(node, ast.Call):
                hit = ((isinstance(node.func, ast.Attribute) and node.func.attr == helper_name)
                       or (isinstance(node.func, ast.Name) and node.func.id == helper_name))
                if hit:
                    if item.name == "__init__":
                        init_calls = True
                    elif item.name == "rebalance_regularization_images":
                        rebal_calls = True

    if not init_calls:
        print(f"FAIL: __init__ does not call {helper_name}")
        sys.exit(1)
    if not rebal_calls:
        print(f"FAIL: rebalance does not call {helper_name}")
        sys.exit(1)
    print(f"PASS: Both __init__ and rebalance call {helper_name}")
    sys.exit(0)

print("FAIL: DreamBoothDataset not found")
sys.exit(1)
PYEOF

###############################################################################
# TEST 3 (Behavioral/Gold): Helper correctly balances 1 reg image
#         (1 reg with subset_repeats=1, 3 train → repeats >= 3)
###############################################################################
echo "--- Test 3/10: Helper balances 1 reg image (1 reg, 3 train) ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, logging, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_func = helper_name = None
for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            nm = item.name.lower()
            excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
            if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
                helper_func = item
                helper_name = item.name
                break

if not helper_func:
    print("FAIL: Helper not found")
    sys.exit(1)

helper_source = ast.get_source_segment(src, helper_func)
body_lines = helper_source.splitlines()[1:]

tester_src = (
    "class _Tester:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "\n"
    f"    def {helper_name}(self, reg_infos, num_train_images):\n"
    + "\n".join("    " + line for line in body_lines) + "\n"
)

import typing
ns = {"logger": logging.getLogger("test"), "logging": logging, "math": math, "typing": typing}
ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(tester_src, ns)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}")
    sys.exit(1)

class _Info:
    def __init__(self, key, reps, is_reg=False):
        self.image_key = key
        self.num_repeats = reps
        self.is_reg = is_reg

class _Subset:
    def __init__(self, reps):
        self.num_repeats = reps

t = ns["_Tester"]()
t.image_data = {}
t.image_to_subset = {}

reg = _Info("reg_0", 1, True)
sub = _Subset(1)
getattr(t, helper_name)([(reg, sub)], 3)

if "reg_0" not in t.image_data:
    print("FAIL: reg_0 not registered into image_data")
    sys.exit(1)
if t.image_data["reg_0"].num_repeats < 3:
    print(f"FAIL: repeats={t.image_data['reg_0'].num_repeats}, expected >= 3")
    sys.exit(1)
print(f"PASS: 1 reg balanced to {t.image_data['reg_0'].num_repeats} repeats (>= 3)")
sys.exit(0)
PYEOF

###############################################################################
# TEST 4 (Behavioral/Gold): Helper balances 3 reg images with correct
#         distribution (3 reg × subset_repeats=2, 10 train)
#         Catches naive stubs that set repeats = num_train per image
###############################################################################
echo "--- Test 4/10: Helper balances 3 reg images (3 reg, 10 train) ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, logging, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_func = helper_name = None
for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            nm = item.name.lower()
            excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
            if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
                helper_func = item
                helper_name = item.name
                break

if not helper_func:
    print("FAIL: Helper not found")
    sys.exit(1)

helper_source = ast.get_source_segment(src, helper_func)
body_lines = helper_source.splitlines()[1:]

tester_src = (
    "class _Tester:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "\n"
    f"    def {helper_name}(self, reg_infos, num_train_images):\n"
    + "\n".join("    " + line for line in body_lines) + "\n"
)

import typing
ns = {"logger": logging.getLogger("test"), "logging": logging, "math": math, "typing": typing}
ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(tester_src, ns)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}")
    sys.exit(1)

class _Info:
    def __init__(self, key, reps, is_reg=False):
        self.image_key = key
        self.num_repeats = reps
        self.is_reg = is_reg

class _Subset:
    def __init__(self, reps):
        self.num_repeats = reps

t = ns["_Tester"]()
t.image_data = {}
t.image_to_subset = {}

regs = [(_Info(f"reg_{i}", 2, True), _Subset(2)) for i in range(3)]
getattr(t, helper_name)(regs, 10)

# All 3 must be registered
for i in range(3):
    if f"reg_{i}" not in t.image_data:
        print(f"FAIL: reg_{i} not registered")
        sys.exit(1)

# Sum of repeats must be close to num_train=10
# Real algorithm gives exactly 10; allow [10, 13] for minor variations
total = sum(t.image_data[f"reg_{i}"].num_repeats for i in range(3))
if total < 10:
    print(f"FAIL: total repeats {total} < 10 (under-allocated)")
    sys.exit(1)
if total > 13:
    print(f"FAIL: total repeats {total} > 13 (over-allocated; expected ~10)")
    sys.exit(1)

# Each reg should have reasonable repeats — not set to num_train individually
for i in range(3):
    reps = t.image_data[f"reg_{i}"].num_repeats
    if reps > 7:  # ~10/3 ≈ 3.3, allow up to 7 for edge cases
        print(f"FAIL: reg_{i} has {reps} repeats (expected <= 7, not num_train)")
        sys.exit(1)

print(f"PASS: 3 reg balanced, total={total}")
sys.exit(0)
PYEOF

###############################################################################
# TEST 5 (Behavioral/Gold): Helper calls register_image for each reg image
#         Uses a tracking mock to verify register_image is actually called
###############################################################################
echo "--- Test 5/10: Helper calls register_image for each reg image ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, logging, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_func = helper_name = None
for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            nm = item.name.lower()
            excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
            if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
                helper_func = item
                helper_name = item.name
                break

if not helper_func:
    print("FAIL: Helper not found")
    sys.exit(1)

helper_source = ast.get_source_segment(src, helper_func)
body_lines = helper_source.splitlines()[1:]

tester_src = (
    "class _Tester:\n"
    "    def register_image(self, info, subset):\n"
    "        self._reg_calls.append(info.image_key)\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "\n"
    f"    def {helper_name}(self, reg_infos, num_train_images):\n"
    + "\n".join("    " + line for line in body_lines) + "\n"
)

import typing
ns = {"logger": logging.getLogger("test"), "logging": logging, "math": math, "typing": typing}
ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(tester_src, ns)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}")
    sys.exit(1)

class _Info:
    def __init__(self, key, reps, is_reg=False):
        self.image_key = key
        self.num_repeats = reps
        self.is_reg = is_reg

class _Subset:
    def __init__(self, reps):
        self.num_repeats = reps

t = ns["_Tester"]()
t.image_data = {}
t.image_to_subset = {}
t._reg_calls = []

regs = [(_Info(f"r_{i}", 1, True), _Subset(1)) for i in range(4)]
getattr(t, helper_name)(regs, 10)

registered = set(t._reg_calls)
expected = {"r_0", "r_1", "r_2", "r_3"}
if not expected.issubset(registered):
    missing = expected - registered
    print(f"FAIL: register_image not called for {missing}")
    sys.exit(1)
print(f"PASS: register_image called for all {len(expected)} reg images")
sys.exit(0)
PYEOF

###############################################################################
# TEST 6 (Behavioral/Gold): update_counts=False skips update_dataset_image_counts
#         Extracts BaseDataset.filter_registered_images_by_orig_resolution,
#         runs it with a mock, and verifies the count update is skipped.
###############################################################################
echo "--- Test 6/10: update_counts=False skips count update in base filter ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

# Find BaseDataset.filter_registered_images_by_orig_resolution
filter_func = None
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef) and cls.name == "BaseDataset":
        for item in cls.body:
            if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
                filter_func = item
                break

if not filter_func:
    print("FAIL: filter method not found in BaseDataset")
    sys.exit(1)

# Check for update_counts-like param
all_params = [a.arg for a in filter_func.args.args[1:]] + [a.arg for a in filter_func.args.kwonlyargs]
update_param = None
for p in all_params:
    if "count" in p.lower() or "update" in p.lower():
        update_param = p
        break

if update_param:
    # Behavioral test — call with False, verify skip
    filter_source = ast.get_source_segment(src, filter_func)

    tester_src = (
        "class _FTester:\n"
        "    def has_orig_resolution_filter(self):\n"
        "        return True\n"
        "    def check_orig_resolution(self, size):\n"
        "        import math\n"
        "        return math.sqrt(size[0] * size[1]) > 100\n"
        "    def update_dataset_image_counts(self):\n"
        "        self._updated = True\n"
        "\n"
        + "\n".join("    " + line for line in filter_source.splitlines()) + "\n"
    )

    class _FakeInfo:
        def __init__(self, size):
            self.image_size = size

    import typing
    ns = {"math": math, "typing": typing}
    ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
    try:
        exec(tester_src, ns)
    except Exception as e:
        print(f"FAIL: Could not compile filter: {e}")
        sys.exit(1)

    t = ns["_FTester"]()
    t.image_data = {"tiny": _FakeInfo((5, 5))}  # area=25, fails resolution check
    t.image_to_subset = {"tiny": None}
    t._updated = False

    kwargs = {update_param: False}
    t.filter_registered_images_by_orig_resolution(**kwargs)

    if t._updated:
        print(f"FAIL: {update_param}=False still called update_dataset_image_counts")
        sys.exit(1)
    if "tiny" in t.image_data:
        print("FAIL: image was not filtered out")
        sys.exit(1)
    print(f"PASS: {update_param}=False skips count update")
    sys.exit(0)

print("FAIL: No update_counts-like parameter found on filter_registered_images_by_orig_resolution")
sys.exit(1)
PYEOF

###############################################################################
# TEST 7 (Behavioral/Gold): update_counts=True triggers update_dataset_image_counts
#         Verifies the default/True path still calls the count update.
###############################################################################
echo "--- Test 7/10: update_counts=True triggers count update in base filter ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

filter_func = None
for cls in ast.walk(tree):
    if isinstance(cls, ast.ClassDef) and cls.name == "BaseDataset":
        for item in cls.body:
            if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
                filter_func = item
                break

if not filter_func:
    print("FAIL: filter method not found")
    sys.exit(1)

all_params = [a.arg for a in filter_func.args.args[1:]] + [a.arg for a in filter_func.args.kwonlyargs]
update_param = None
for p in all_params:
    if "count" in p.lower() or "update" in p.lower():
        update_param = p
        break

if update_param:
    # Behavioral test — call with True, verify trigger
    filter_source = ast.get_source_segment(src, filter_func)

    tester_src = (
        "class _FTester:\n"
        "    def has_orig_resolution_filter(self):\n"
        "        return True\n"
        "    def check_orig_resolution(self, size):\n"
        "        import math\n"
        "        return math.sqrt(size[0] * size[1]) > 100\n"
        "    def update_dataset_image_counts(self):\n"
        "        self._updated = True\n"
        "\n"
        + "\n".join("    " + line for line in filter_source.splitlines()) + "\n"
    )

    class _FakeInfo:
        def __init__(self, size):
            self.image_size = size

    import typing
    ns = {"math": math, "typing": typing}
    ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
    try:
        exec(tester_src, ns)
    except Exception as e:
        print(f"FAIL: Could not compile filter: {e}")
        sys.exit(1)

    t = ns["_FTester"]()
    t.image_data = {"tiny": _FakeInfo((5, 5))}
    t.image_to_subset = {"tiny": None}
    t._updated = False

    kwargs = {update_param: True}
    t.filter_registered_images_by_orig_resolution(**kwargs)

    if not t._updated:
        print(f"FAIL: {update_param}=True did not call update_dataset_image_counts")
        sys.exit(1)
    print(f"PASS: {update_param}=True triggers count update")
    sys.exit(0)

print("FAIL: No update_counts-like parameter found on filter_registered_images_by_orig_resolution")
sys.exit(1)
PYEOF

###############################################################################
# TEST 8 (Behavioral/Gold): rebalance_regularization_images end-to-end
#         Sets up mock with train + reg images, calls rebalance, verifies
#         reg images are removed and re-registered with balanced repeats.
###############################################################################
echo "--- Test 8/10: rebalance_regularization_images end-to-end ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, logging, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_func = helper_name = None
rebalance_func = None

for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if not isinstance(item, ast.FunctionDef):
            continue
        nm = item.name.lower()
        excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
        if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
            helper_func = item
            helper_name = item.name
        if nm == "rebalance_regularization_images":
            rebalance_func = item

if not helper_func:
    print("FAIL: Helper not found")
    sys.exit(1)
if not rebalance_func:
    print("FAIL: rebalance_regularization_images not found")
    sys.exit(1)

helper_src = ast.get_source_segment(src, helper_func)
rebalance_src = ast.get_source_segment(src, rebalance_func)

tester_src = (
    "class _RebTester:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "\n"
    + "\n".join("    " + line for line in helper_src.splitlines()) + "\n"
    + "\n"
    + "\n".join("    " + line for line in rebalance_src.splitlines()) + "\n"
)

import typing
ns = {"logger": logging.getLogger("test"), "logging": logging, "math": math, "typing": typing}
ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(tester_src, ns)
except Exception as e:
    print(f"FAIL: Could not compile: {e}")
    sys.exit(1)

class _Info:
    def __init__(self, key, reps, is_reg=False):
        self.image_key = key
        self.num_repeats = reps
        self.is_reg = is_reg

class _Subset:
    def __init__(self, reps):
        self.num_repeats = reps

# Setup: 3 train images (2 reps each = 6 total) + 2 reg images
t = ns["_RebTester"]()
t.is_training_dataset = True
t.image_data = {}
t.image_to_subset = {}

train_sub = _Subset(2)
for i in range(3):
    info = _Info(f"train_{i}", 2, False)
    t.image_data[f"train_{i}"] = info
    t.image_to_subset[f"train_{i}"] = train_sub

reg_sub = _Subset(1)
for i in range(2):
    info = _Info(f"reg_{i}", 1, True)
    t.image_data[f"reg_{i}"] = info
    t.image_to_subset[f"reg_{i}"] = reg_sub

t.rebalance_regularization_images()

# Train images should still exist
for i in range(3):
    if f"train_{i}" not in t.image_data:
        print(f"FAIL: train_{i} was removed")
        sys.exit(1)

# Reg images should be re-registered
reg_found = [k for k in t.image_data if k.startswith("reg_")]
if len(reg_found) == 0:
    print("FAIL: No reg images re-registered after rebalance")
    sys.exit(1)

# Total reg repeats should be >= train total (6)
train_total = sum(t.image_data[f"train_{i}"].num_repeats for i in range(3))
reg_total = sum(t.image_data[k].num_repeats for k in reg_found)

if reg_total < train_total:
    print(f"FAIL: reg_total={reg_total} < train_total={train_total}")
    sys.exit(1)

print(f"PASS: rebalance end-to-end (train={train_total}, reg={reg_total})")
sys.exit(0)
PYEOF

###############################################################################
# TEST 9 (Behavioral/Gold): Helper with varied subset_repeats
#         (2 reg with subset_repeats 1 and 3, 7 train)
#         Verifies correct handling of heterogeneous repeat counts
###############################################################################
echo "--- Test 9/10: Helper with varied subset_repeats (2 reg, 7 train) ---"
python3 << 'PYEOF' && PASS=$((PASS + 1)) || true
import ast, sys, logging, math

with open("/workspace/sd-scripts/library/train_util.py") as f:
    src = f.read()
tree = ast.parse(src)

helper_func = helper_name = None
for cls in ast.walk(tree):
    if not (isinstance(cls, ast.ClassDef) and cls.name == "DreamBoothDataset"):
        continue
    for item in cls.body:
        if isinstance(item, ast.FunctionDef):
            nm = item.name.lower()
            excl = nm.startswith("filter_") or nm.startswith("rebalance_") or nm.startswith("__")
            if not excl and ("register" in nm or "balance" in nm) and ("reg" in nm or "regularization" in nm):
                helper_func = item
                helper_name = item.name
                break

if not helper_func:
    print("FAIL: Helper not found")
    sys.exit(1)

helper_source = ast.get_source_segment(src, helper_func)
body_lines = helper_source.splitlines()[1:]

tester_src = (
    "class _Tester:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "\n"
    f"    def {helper_name}(self, reg_infos, num_train_images):\n"
    + "\n".join("    " + line for line in body_lines) + "\n"
)

import typing
ns = {"logger": logging.getLogger("test"), "logging": logging, "math": math, "typing": typing}
ns.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})
try:
    exec(tester_src, ns)
except Exception as e:
    print(f"FAIL: Could not compile helper: {e}")
    sys.exit(1)

class _Info:
    def __init__(self, key, reps, is_reg=False):
        self.image_key = key
        self.num_repeats = reps
        self.is_reg = is_reg

class _Subset:
    def __init__(self, reps):
        self.num_repeats = reps

t = ns["_Tester"]()
t.image_data = {}
t.image_to_subset = {}

# 2 reg images with different subset_repeats
regs = [
    (_Info("r_a", 1, True), _Subset(1)),
    (_Info("r_b", 3, True), _Subset(3)),
]
getattr(t, helper_name)(regs, 7)

if "r_a" not in t.image_data or "r_b" not in t.image_data:
    print("FAIL: Not all reg images registered")
    sys.exit(1)

total = t.image_data["r_a"].num_repeats + t.image_data["r_b"].num_repeats
if total < 7:
    print(f"FAIL: total={total} < 7 (under-allocated)")
    sys.exit(1)
if total > 11:
    print(f"FAIL: total={total} > 11 (over-allocated)")
    sys.exit(1)

print(f"PASS: Varied repeats: r_a={t.image_data['r_a'].num_repeats}, r_b={t.image_data['r_b'].num_repeats}, total={total}")
sys.exit(0)
PYEOF

###############################################################################
# TEST 10 (Compile): File compiles cleanly
###############################################################################
echo "--- Test 10/10: train_util.py compiles ---"
python3 -m py_compile /workspace/sd-scripts/library/train_util.py && \
    echo "PASS: py_compile succeeded" && PASS=$((PASS + 1)) || \
    echo "FAIL: py_compile failed"

###############################################################################
# Write reward
###############################################################################
REWARD=$(python3 -c "print(f'{$PASS / $TOTAL:.4f}')")
echo "$REWARD" > "$REWARD_FILE"
echo "=== RESULT: $PASS/$TOTAL tests passed, reward=$REWARD ==="
