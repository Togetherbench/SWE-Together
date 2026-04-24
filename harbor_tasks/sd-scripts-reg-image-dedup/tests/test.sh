#!/bin/bash
# Verification for sd-scripts-reg-image-dedup
#
# Tests that the agent refactored the duplicate regularization-image balancing
# loop into a shared helper method AND added the update_counts parameter to
# avoid calling update_dataset_image_counts() twice.
#
# Weight budget (R/100, max capped at 1.0):
#   F2P Structural  (10pts): tests 1-2   (helper exists, call sites)
#   F2P Behavioral  (81pts): tests 3-11, 14 (functional correctness)
#   P2P             (3pts):  test 12     (upstream tests)
#   P2P Compile     (2pts):  test 13     (file integrity)
#
# Max stub score: 0.12 (structural 0.10 + compile 0.02)
# Nop score: 0.05 (P2P 0.03 + compile 0.02)
# Behavioral tests all require working code that produces correct outputs.

set +e
export PATH="/workspace/venv/bin:$PATH"

# Fix permission issue: E2B runs as 'user' but workspace is owned by root
chmod -R a+w /workspace/sd-scripts 2>/dev/null || true

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

R=0  # reward in hundredths; final = min(1.0, R/100)
SRC="/workspace/sd-scripts/library/train_util.py"

echo "=== sd-scripts-reg-image-dedup verifier ==="

###############################################################################
# PRE-PARSE: Parse train_util.py once, extract all data needed by tests.
#            Saves to /tmp/test_cache.json to avoid re-parsing 11 times.
###############################################################################
echo "--- Pre-parse: extracting AST data ---"
timeout 30 python3 << 'PYEOF'
import ast, json, sys

SRC_PATH = "/workspace/sd-scripts/library/train_util.py"
CACHE = "/tmp/test_cache.json"

try:
    with open(SRC_PATH) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    json.dump({"parse_ok": False, "error": str(e)}, open(CACHE, "w"))
    print(f"Pre-parse failed: {e}")
    sys.exit(0)

SKIP = {"__init__", "rebalance_regularization_images",
        "filter_registered_images_by_orig_resolution",
        "make_buckets", "register_image", "cache_latents",
        "__len__", "__getitem__"}

cache = {"parse_ok": True}

# --- DreamBoothDataset ---
db_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "DreamBoothDataset":
        db_cls = node; break

if db_cls:
    cache["dreambooth_found"] = True
    methods = {i.name: i for i in db_cls.body if isinstance(i, ast.FunctionDef)}
    cache["rebalance_exists"] = "rebalance_regularization_images" in methods

    # Find helper: first non-SKIP method with >= 2 args and >= 3 nontrivial stmts
    helper_name, helper_fn = None, None
    for nm, fn in methods.items():
        if nm in SKIP or len(fn.args.args) < 2:
            continue
        nontrivial = len([s for s in fn.body
                          if not isinstance(s, ast.Pass)
                          and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))])
        if nontrivial >= 3:
            helper_name, helper_fn = nm, fn; break

    cache["helper_name"] = helper_name

    if helper_fn:
        seg = ast.get_source_segment(src, helper_fn)
        if not seg:
            seg = "\n".join(src.splitlines()[helper_fn.lineno - 1 : helper_fn.end_lineno])
        cache["helper_source"] = seg

    # Extract rebalance source
    reb_fn = methods.get("rebalance_regularization_images")
    if reb_fn:
        seg = ast.get_source_segment(src, reb_fn)
        if not seg:
            seg = "\n".join(src.splitlines()[reb_fn.lineno - 1 : reb_fn.end_lineno])
        cache["rebalance_source"] = seg

    # Check if __init__ and rebalance both call a shared helper
    init_fn = methods.get("__init__")

    def calls_method(caller, name):
        return any(
            isinstance(n, ast.Call) and (
                (isinstance(n.func, ast.Attribute) and n.func.attr == name) or
                (isinstance(n.func, ast.Name) and n.func.id == name))
            for n in ast.walk(caller))

    shared_helper = None
    if init_fn and reb_fn:
        for nm in methods:
            if nm in SKIP or len(methods[nm].args.args) < 2:
                continue
            if calls_method(init_fn, nm) and calls_method(reb_fn, nm):
                shared_helper = nm; break
    cache["shared_helper"] = shared_helper

    # Init analysis for Test 11
    if init_fn:
        cache["init_while_count"] = sum(1 for n in ast.walk(init_fn) if isinstance(n, ast.While))
        init_src = ast.get_source_segment(src, init_fn)
        if not init_src:
            init_src = "\n".join(src.splitlines()[init_fn.lineno - 1 : init_fn.end_lineno])
        cache["init_has_first_loop"] = "first_loop" in init_src

    # Check if rebalance was modified (no first_loop) for Test 7 partial credit
    if reb_fn and "rebalance_source" in cache:
        cache["rebalance_has_first_loop"] = "first_loop" in cache["rebalance_source"]

    # DreamBooth filter override for Test 14
    db_filter_fn = methods.get("filter_registered_images_by_orig_resolution")
    if db_filter_fn:
        seg = ast.get_source_segment(src, db_filter_fn)
        if not seg:
            seg = "\n".join(src.splitlines()[db_filter_fn.lineno - 1 : db_filter_fn.end_lineno])
        cache["db_filter_source"] = seg
        # Check if DreamBooth filter calls update_dataset_image_counts
        cache["db_filter_calls_update"] = any(
            isinstance(n, ast.Call) and (
                (isinstance(n.func, ast.Attribute) and n.func.attr == "update_dataset_image_counts") or
                (isinstance(n.func, ast.Name) and n.func.id == "update_dataset_image_counts"))
            for n in ast.walk(db_filter_fn))
else:
    cache["dreambooth_found"] = False

# --- BaseDataset ---
base_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == "BaseDataset":
        base_cls = node; break

if base_cls:
    filter_fn = None
    for item in base_cls.body:
        if isinstance(item, ast.FunctionDef) and item.name == "filter_registered_images_by_orig_resolution":
            filter_fn = item; break

    if filter_fn:
        cache["base_filter_found"] = True
        param = None
        for p in [a.arg for a in filter_fn.args.args[1:]] + [a.arg for a in filter_fn.args.kwonlyargs]:
            if "count" in p.lower() or "update" in p.lower():
                param = p; break
        cache["filter_param"] = param
        seg = ast.get_source_segment(src, filter_fn)
        if not seg:
            seg = "\n".join(src.splitlines()[filter_fn.lineno - 1 : filter_fn.end_lineno])
        cache["filter_source"] = seg
    else:
        cache["base_filter_found"] = False
else:
    cache["base_filter_found"] = False

with open(CACHE, "w") as f:
    json.dump(cache, f)
print("Pre-parse complete")
PYEOF

###############################################################################
# TEST 1 (F2P Structural, 5pts): Helper method exists in DreamBoothDataset
#         AND rebalance_regularization_images still exists.
#         Anti-stub: helper body >= 3 non-trivial statements.
###############################################################################
echo "--- Test 1/14: Helper method + rebalance exist ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 5)) || true
import json, sys

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if not cache.get("dreambooth_found"):
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)
if not cache.get("rebalance_exists"):
    print("FAIL: rebalance_regularization_images was removed"); sys.exit(1)
if not cache.get("helper_name"):
    print("FAIL: No helper method found in DreamBoothDataset"); sys.exit(1)

print(f"PASS: Helper '{cache['helper_name']}' + rebalance both exist")
PYEOF

###############################################################################
# TEST 2 (F2P Structural, 5pts): __init__ and rebalance both call the helper
###############################################################################
echo "--- Test 2/14: __init__ and rebalance both call helper ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 5)) || true
import json, sys

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if not cache.get("shared_helper"):
    print("FAIL: No shared helper called from both __init__ and rebalance"); sys.exit(1)

print(f"PASS: Both __init__ and rebalance call {cache['shared_helper']}")
PYEOF

###############################################################################
# TEST 3 (F2P Behavioral, 8pts): Helper correctly balances 1 reg image
#         1 reg with subset_repeats=1, 3 train -> repeats >= 3
###############################################################################
echo "--- Test 3/14: Helper balances 1 reg image (1 reg, 3 train) ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 8)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("helper_name") or "helper_source" not in cache:
    print("FAIL: Helper not found"); sys.exit(1)

helper_name = cache["helper_name"]
seg = cache["helper_source"]
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
# TEST 4 (F2P Behavioral, 8pts): Helper balances 3 reg images with correct
#         distribution (3 reg x subset_repeats=2, 10 train).
#         Catches naive stubs that set repeats = num_train per image.
###############################################################################
echo "--- Test 4/14: Helper balances 3 reg images (3 reg, 10 train) ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 8)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("helper_name") or "helper_source" not in cache:
    print("FAIL: Helper not found"); sys.exit(1)

helper_name = cache["helper_name"]
seg = cache["helper_source"]
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
# TEST 5 (F2P Behavioral, 8pts): Helper calls register_image for each reg image.
#         Uses a tracking mock to verify register_image is actually called.
###############################################################################
echo "--- Test 5/14: Helper calls register_image for each reg image ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 8)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("helper_name") or "helper_source" not in cache:
    print("FAIL: Helper not found"); sys.exit(1)

helper_name = cache["helper_name"]
seg = cache["helper_source"]
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
# TEST 6 (F2P Behavioral, 8pts): Helper with varied subset_repeats
#         2 reg with subset_repeats 1 and 3, 7 train
###############################################################################
echo "--- Test 6/14: Helper with varied subset_repeats (2 reg, 7 train) ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 8)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("helper_name") or "helper_source" not in cache:
    print("FAIL: Helper not found"); sys.exit(1)

helper_name = cache["helper_name"]
seg = cache["helper_source"]
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
# TEST 7 (F2P Behavioral, 20pts): rebalance_regularization_images end-to-end.
#         Sets up mock with train + reg images, calls rebalance, verifies
#         reg images are removed and re-registered with balanced repeats.
#         Accepts either: (a) helper+rebalance or (b) modified rebalance alone.
#         Nop (unmodified rebalance with first_loop) is rejected.
###############################################################################
echo "--- Test 7/14: rebalance_regularization_images end-to-end ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 20)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if "rebalance_source" not in cache:
    print("FAIL: rebalance_regularization_images not found"); sys.exit(1)

reb_src = cache["rebalance_source"]

# Build test class: include helper if it exists, otherwise use rebalance alone
# Reject unmodified nop (rebalance still has first_loop and no helper)
has_helper = cache.get("helper_name") and "helper_source" in cache
rebalance_modified = not cache.get("rebalance_has_first_loop", True)

mock_preamble = (
    "from __future__ import annotations\nclass _T:\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    "    def update_dataset_image_counts(self): pass\n\n"
)

if has_helper:
    helper_src = cache["helper_source"]
    code = (
        mock_preamble
        + "\n".join("    " + l for l in helper_src.splitlines()) + "\n\n"
        + "\n".join("    " + l for l in reb_src.splitlines()) + "\n"
    )
elif rebalance_modified:
    # No helper but rebalance was restructured (not nop)
    code = (
        mock_preamble
        + "\n".join("    " + l for l in reb_src.splitlines()) + "\n"
    )
else:
    print("FAIL: No helper found and rebalance not modified (still has first_loop)")
    sys.exit(1)

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
# TEST 8 (F2P Behavioral, 5pts): update_counts=False skips update_dataset_image_counts.
#         Finds the update_counts-like param on filter_registered_images_by_orig_resolution
#         and calls with False to verify count update is skipped.
###############################################################################
echo "--- Test 8/14: update_counts=False skips count update in base filter ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 5)) || true
import json, sys, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if not cache.get("base_filter_found"):
    print("FAIL: filter_registered_images_by_orig_resolution not found in BaseDataset"); sys.exit(1)
if not cache.get("filter_param"):
    print("FAIL: No update_counts-like parameter on filter_registered_images_by_orig_resolution")
    sys.exit(1)

param = cache["filter_param"]
seg = cache["filter_source"]
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
# TEST 9 (F2P Behavioral, 4pts): update_counts=True triggers update_dataset_image_counts
###############################################################################
echo "--- Test 9/14: update_counts=True triggers count update in base filter ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 4)) || true
import json, sys, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if not cache.get("base_filter_found"):
    print("FAIL: filter method not found"); sys.exit(1)
if not cache.get("filter_param"):
    print("FAIL: No update_counts param found"); sys.exit(1)

param = cache["filter_param"]
seg = cache["filter_source"]
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
# TEST 10 (F2P Behavioral, 5pts): Helper handles zero reg images gracefully
#         Empty reg_infos list should not crash or hang (infinite loop).
#         Uses threading with a short timeout to detect hangs.
###############################################################################
echo "--- Test 10/14: Helper handles zero reg images ---"
timeout 10 python3 << 'PYEOF' && R=$((R + 5)) || true
import json, sys, logging, math, typing, threading

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("helper_name") or "helper_source" not in cache:
    print("FAIL: Helper not found"); sys.exit(1)

helper_name = cache["helper_name"]
seg = cache["helper_source"]
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
result = {"done": False, "error": None}

def run_helper():
    try:
        getattr(t, helper_name)([], 5)
        result["done"] = True
    except Exception as e:
        result["error"] = str(e)

thread = threading.Thread(target=run_helper, daemon=True)
thread.start()
thread.join(timeout=3)

if not result["done"]:
    if result["error"]:
        print(f"FAIL: Helper crashed on empty reg list: {result['error']}"); sys.exit(1)
    else:
        print("FAIL: Helper hangs on empty reg_infos (infinite loop - needs guard clause)"); sys.exit(1)

if len(t.image_data) != 0:
    print(f"FAIL: Expected 0 images, got {len(t.image_data)}"); sys.exit(1)
print("PASS: Helper handles empty reg_infos gracefully")
PYEOF

###############################################################################
# TEST 11 (F2P Behavioral, 10pts): Duplicate balancing loop is removed from __init__
#         Verify that __init__ no longer contains the inline while-loop for
#         balancing (it should call the helper instead).
###############################################################################
echo "--- Test 11/14: Duplicate loop removed from __init__ ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 10)) || true
import json, sys

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok") or not cache.get("dreambooth_found"):
    print("FAIL: DreamBoothDataset not found"); sys.exit(1)

while_count = cache.get("init_while_count", -1)
has_first_loop = cache.get("init_has_first_loop", False)

if while_count < 0:
    print("FAIL: __init__ not found"); sys.exit(1)

# The balancing while-loop uses a 'first_loop' variable.
# __init__ may have other legitimate while loops (e.g. npz path search),
# so we check for the balancing-specific marker rather than counting all loops.
if not has_first_loop:
    print("PASS: Duplicate balancing while-loop removed from __init__")
else:
    print("FAIL: __init__ still contains the balancing while-loop (first_loop variable found)")
    sys.exit(1)
PYEOF

###############################################################################
# TEST 12 (P2P, 3pts): Upstream library tests still pass
###############################################################################
echo "--- Test 12/14: P2P upstream library tests ---"
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

    echo "Running: pytest $TEST_DIR --timeout=20 -q --continue-on-collection-errors (with 45s bash guard)"
    OUTPUT=$(timeout 45 python3 -m pytest "$TEST_DIR" --timeout=20 -q --continue-on-collection-errors 2>&1 | tail -15)
    echo "$OUTPUT"
    # Pass if tests passed and none failed (collection errors from env deps are OK)
    if echo "$OUTPUT" | grep -qE '[0-9]+ passed' && ! echo "$OUTPUT" | grep -qE '[0-9]+ failed'; then
        exit 0
    else
        exit 1
    fi
) && R=$((R + 3)) || true

###############################################################################
# TEST 13 (P2P Compile, 2pts): File compiles cleanly
###############################################################################
echo "--- Test 13/14: train_util.py compiles ---"
python3 -m py_compile /workspace/sd-scripts/library/train_util.py && \
    echo "PASS: py_compile succeeded" && R=$((R + 2)) || \
    echo "FAIL: py_compile failed"

###############################################################################
# TEST 14 (F2P Behavioral, 10pts): End-to-end DreamBooth filter override calls
#         update_dataset_image_counts at most ONCE when is_training_dataset=True.
#         Covers the instruction ask: "fix the redundant double call to
#         update_dataset_image_counts()". Stitches base filter + DB override +
#         rebalance (+helper) and asserts the count is not doubled.
#         Accepts ANY approach: update_counts param, moving call into rebalance,
#         or any other mechanism that eliminates the double call.
###############################################################################
echo "--- Test 14/14: DreamBooth training filter calls update_dataset_image_counts <=1x ---"
timeout 15 python3 << 'PYEOF' && R=$((R + 10)) || true
import json, sys, logging, math, typing

cache = json.load(open("/tmp/test_cache.json"))
if not cache.get("parse_ok"):
    print("FAIL: Could not parse source"); sys.exit(1)
if "db_filter_source" not in cache or "filter_source" not in cache:
    print("FAIL: Filter sources not found in cache"); sys.exit(1)
if "rebalance_source" not in cache:
    print("FAIL: rebalance_regularization_images not found"); sys.exit(1)

helper_src = cache.get("helper_source", "")
rebalance_src = cache["rebalance_source"]
db_filter_src = cache["db_filter_source"]
base_filter_src = cache["filter_source"]

base_code = (
    "class _Base:\n"
    "    def has_orig_resolution_filter(self): return True\n"
    "    def check_orig_resolution(self, size):\n"
    "        return size[0] >= 50 and size[1] >= 50\n"
    "    def update_dataset_image_counts(self):\n"
    "        self._update_calls = getattr(self, '_update_calls', 0) + 1\n"
    "    def register_image(self, info, subset):\n"
    "        self.image_data[info.image_key] = info\n"
    "        self.image_to_subset[info.image_key] = subset\n"
    + "\n".join("    " + l for l in base_filter_src.splitlines()) + "\n"
)

db_code = "class _DB(_Base):\n"
if helper_src:
    db_code += "\n".join("    " + l for l in helper_src.splitlines()) + "\n"
db_code += "\n".join("    " + l for l in rebalance_src.splitlines()) + "\n"
db_code += "\n".join("    " + l for l in db_filter_src.splitlines()) + "\n"

code = "from __future__ import annotations\n" + base_code + "\n" + db_code

N = {"logger": logging.getLogger("test"), "logging": logging,
     "math": math, "typing": typing,
     "ImageInfo": object, "DreamBoothSubset": object}
N.update({k: v for k, v in vars(typing).items() if not k.startswith('_')})

try:
    exec(code, N)
except Exception as e:
    print(f"FAIL: Could not compile stitched DreamBooth class: {e}"); sys.exit(1)

class I:
    def __init__(self, k, r, reg=False, size=(100, 100)):
        self.image_key = k; self.num_repeats = r; self.is_reg = reg
        self.image_size = size
class S:
    def __init__(self, r):
        self.num_repeats = r

db = N["_DB"]()
db.is_training_dataset = True
db._update_calls = 0
db.image_data = {
    "train_0": I("train_0", 2, False, (100, 100)),
    "train_1": I("train_1", 2, False, (100, 100)),
    "train_2": I("train_2", 2, False, (100, 100)),
    "reg_0":   I("reg_0",   1, True,  (10, 10)),
    "reg_1":   I("reg_1",   1, True,  (100, 100)),
}
db.image_to_subset = {k: S(v.num_repeats) for k, v in db.image_data.items()}

try:
    db.filter_registered_images_by_orig_resolution()
except Exception as e:
    print(f"FAIL: DreamBooth filter call failed: {e}"); sys.exit(1)

if db._update_calls > 1:
    print(f"FAIL: update_dataset_image_counts called {db._update_calls} times "
          "(expected <=1; double-count not eliminated)")
    sys.exit(1)
if db._update_calls < 1:
    print("FAIL: update_dataset_image_counts never called (counts never updated after filter)")
    sys.exit(1)
print(f"PASS: update_dataset_image_counts called exactly {db._update_calls}x after filter")
PYEOF

###############################################################################
# Write reward
###############################################################################
REWARD=$(python3 -c "print(f'{min(1.0, $R / 100):.4f}')")
echo "$REWARD" > "$REWARD_FILE"
echo "=== RESULT: R=$R/100, reward=$REWARD ==="
