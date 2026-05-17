#!/bin/bash
set +e
export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

chmod -R a+w /workspace/sd-scripts 2>/dev/null || true

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SRC="/workspace/sd-scripts/library/train_util.py"
REWARD=0.0

awk_add() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.4f", a + b }'
}

write_reward_and_exit() {
    echo "$1" > "$REWARD_FILE"
    exit 0
}

echo "=== sd-scripts-reg-image-dedup verifier ==="

if [ ! -f "$SRC" ]; then
    echo "FATAL: $SRC missing"
    write_reward_and_exit "0.0"
fi

# ---------------------------------------------------------------------------
# GATE 1 (P2P): module imports cleanly. Pre-existing pass.
# ---------------------------------------------------------------------------
echo "--- Gate: module imports ---"
timeout 60 python3 -c "
import sys
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu
assert hasattr(tu, 'DreamBoothDataset')
assert hasattr(tu, 'BaseDataset')
print('GATE PASS')
" > /tmp/gate_import.log 2>&1
if [ $? -ne 0 ]; then
    echo "GATE FAIL: import error (regression)"
    cat /tmp/gate_import.log | head -60
    write_reward_and_exit "0.0"
fi

# ---------------------------------------------------------------------------
# Pre-parse: AST extraction of structural facts.
# ---------------------------------------------------------------------------
timeout 60 python3 << 'PYEOF' > /tmp/parse_out 2>&1
import ast, json, sys, re

SRC = "/workspace/sd-scripts/library/train_util.py"
try:
    with open(SRC) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    json.dump({"parse_ok": False, "error": str(e)}, open("/tmp/test_cache.json", "w"))
    sys.exit(0)

cache = {"parse_ok": True, "src_len": len(src), "src": src}

db_cls = base_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        if node.name == "DreamBoothDataset":
            db_cls = node
        elif node.name == "BaseDataset":
            base_cls = node

def count_balance_while(fn):
    count = 0
    for n in ast.walk(fn):
        if isinstance(n, ast.While):
            seg = ast.dump(n)
            if "first_loop" in seg or ("num_train_images" in seg and "num_repeats" in seg):
                count += 1
    return count

def find_method(cls, name):
    if cls is None:
        return None
    for n in cls.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    return None

if db_cls:
    cache["dreambooth_found"] = True
    methods = {i.name: i for i in db_cls.body if isinstance(i, ast.FunctionDef)}
    cache["db_method_names"] = list(methods.keys())
    init_fn = methods.get("__init__")
    db_filter_fn = methods.get("filter_registered_images_by_orig_resolution")

    if init_fn:
        init_src = ast.get_source_segment(src, init_fn) or ""
        cache["init_has_first_loop_var"] = ("first_loop = True" in init_src) or ("first_loop=True" in init_src)
        cache["init_balance_while_count"] = count_balance_while(init_fn)
        cache["init_src"] = init_src

    if db_filter_fn:
        cache["db_filter_found"] = True
        seg = ast.get_source_segment(src, db_filter_fn) or ""
        cache["db_filter_source"] = seg
        update_calls = 0
        super_calls_with_update_false = 0
        super_calls_with_update_nontrue = 0
        rebalance_calls = 0
        helper_invocations = 0
        for n in ast.walk(db_filter_fn):
            if isinstance(n, ast.Call):
                fn_name = None
                if isinstance(n.func, ast.Attribute):
                    fn_name = n.func.attr
                elif isinstance(n.func, ast.Name):
                    fn_name = n.func.id
                if fn_name and "update_dataset_image_counts" in fn_name:
                    update_calls += 1
                if fn_name and "rebalance" in fn_name.lower():
                    rebalance_calls += 1
                # Behavioral signal: override invokes the dedup helper (any name that suggests
                # balanced reg registration / rebalance).
                if fn_name and any(s in fn_name.lower() for s in ("rebalance", "register_balanced", "register_regularization", "balance_reg")):
                    helper_invocations += 1
                # super().filter_...(update_counts=<anything-not-literal-True>)?
                if isinstance(n.func, ast.Attribute) and n.func.attr == "filter_registered_images_by_orig_resolution":
                    if isinstance(n.func.value, ast.Call) and isinstance(n.func.value.func, ast.Name) and n.func.value.func.id == "super":
                        for kw in n.keywords:
                            if kw.arg == "update_counts":
                                # Strict-False (legacy literal) accept
                                if isinstance(kw.value, ast.Constant) and kw.value.value is False:
                                    super_calls_with_update_false += 1
                                    super_calls_with_update_nontrue += 1
                                # Accept any expression that is NOT a literal True
                                # (UnaryOp(Not, ...), Name, BoolOp, Attribute, Compare, etc.)
                                else:
                                    is_literal_true = (
                                        isinstance(kw.value, ast.Constant) and kw.value.value is True
                                    )
                                    if not is_literal_true:
                                        super_calls_with_update_nontrue += 1
        cache["db_filter_update_count_calls"] = update_calls
        cache["db_filter_super_update_false"] = super_calls_with_update_false
        cache["db_filter_super_update_nontrue"] = super_calls_with_update_nontrue
        cache["db_filter_rebalance_calls"] = rebalance_calls
        cache["db_filter_helper_invocations"] = helper_invocations
    else:
        cache["db_filter_found"] = False

# Look for any extracted balancing helper method on either class
helper_method_names = []
for cls in (db_cls, base_cls):
    if cls is None:
        continue
    for n in cls.body:
        if isinstance(n, ast.FunctionDef):
            nm = n.name.lower()
            if any(s in nm for s in ("balance_reg", "register_regularization", "rebalance_regularization")):
                helper_method_names.append(n.name)
                seg = ast.get_source_segment(src, n) or ""
                # Detect early-return on empty reg list
                if "balance" in nm or "register_reg" in nm or "rebalance" in nm:
                    cache.setdefault("helpers", {})[n.name] = seg

cache["helper_method_names"] = helper_method_names
cache["first_loop_count"] = src.count("first_loop")
cache["while_n_lt_num_train"] = src.count("while n < num_train_images")

# Don't dump full src in the json
cache_to_write = {k: v for k, v in cache.items() if k != "src"}
with open("/tmp/test_cache.json", "w") as f:
    json.dump(cache_to_write, f, indent=2, default=str)
print("OK")
PYEOF

if [ ! -f /tmp/test_cache.json ]; then
    echo "FATAL: pre-parse failed"
    cat /tmp/parse_out
    write_reward_and_exit "0.0"
fi

PARSE_OK=$(python3 -c "import json; print(json.load(open('/tmp/test_cache.json')).get('parse_ok', False))" 2>/dev/null)
if [ "$PARSE_OK" != "True" ]; then
    echo "GATE FAIL: source did not parse"
    cat /tmp/test_cache.json
    write_reward_and_exit "0.0"
fi

# ===========================================================================
# F2P 1 (0.15): Balancing logic deduplicated out of __init__.
# Buggy base has 'first_loop = True' and bal-while inline in __init__.
# After refactor: __init__ no longer has those.
# ===========================================================================
echo "--- F2P 1 (0.15): Balancing logic extracted out of __init__ ---"
timeout 10 python3 << 'PYEOF' > /tmp/t1.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
init_has_var = c.get("init_has_first_loop_var", True)
init_while = c.get("init_balance_while_count", 1)
wn = c.get("while_n_lt_num_train", 0)

if init_has_var:
    print("FAIL: __init__ still has 'first_loop = True'")
    sys.exit(1)
if init_while > 0:
    print(f"FAIL: __init__ still has balancing-style while loop ({init_while})")
    sys.exit(1)
if wn > 1:
    print(f"FAIL: 'while n < num_train_images' appears {wn} times (still duplicated)")
    sys.exit(1)
print(f"PASS (while-pattern occurrences={wn})")
PYEOF
T1=$?
cat /tmp/t1.log
if [ $T1 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    echo "(+0.15)"
fi

# ===========================================================================
# F2P 2 (0.15): A dedicated helper method exists for reg balancing.
# Required by "remove duplicate code" — the dedup must produce a callable.
# ===========================================================================
echo "--- F2P 2 (0.15): Dedicated balancing helper method exists ---"
timeout 10 python3 << 'PYEOF' > /tmp/t2.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
helpers = c.get("helper_method_names", [])
if not helpers:
    print("FAIL: no helper method named like _balance_reg/register_regularization/rebalance_regularization found")
    sys.exit(1)
print(f"PASS (helpers found: {helpers})")
PYEOF
T2=$?
cat /tmp/t2.log
if [ $T2 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    echo "(+0.15)"
fi

# ===========================================================================
# F2P 3 (0.15): DreamBooth filter override doesn't redundantly call
# update_dataset_image_counts. Behavioral signal: rebalance path is invoked,
# and direct update calls in the override body are <= 1 (since the helper
# / rebalance manages the count update internally).
#
# RELAXED 2026-05-16: previously required 0 direct calls, which rejected valid
# solutions that invoke rebalance+update once explicitly in the override. Per
# the SWE-bench Verified critique, accept either:
#   (a) <= 1 direct update call AND rebalance/helper invocation present, OR
#   (b) 0 direct update calls (canonical form: rebalance helper handles it).
# ===========================================================================
echo "--- F2P 3 (0.15): DB filter override defers update via helper (no redundant double-call) ---"
timeout 10 python3 << 'PYEOF' > /tmp/t3.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
if not c.get("db_filter_found", False):
    print("FAIL: no DreamBooth filter override exists")
    sys.exit(1)
calls = c.get("db_filter_update_count_calls", 99)
helper_invocations = c.get("db_filter_helper_invocations", 0)
rebalance_calls = c.get("db_filter_rebalance_calls", 0)

# Hard fail: more than one direct call is the double-call regression we forbid.
if calls > 1:
    print(f"FAIL: override still has {calls} direct update_dataset_image_counts call(s) (double-call regression)")
    sys.exit(1)

# Canonical form: 0 direct calls + rebalance helper invoked. Pass.
if calls == 0 and (helper_invocations >= 1 or rebalance_calls >= 1):
    print(f"PASS (no direct update; rebalance/helper invoked: helper={helper_invocations}, rebalance={rebalance_calls})")
    sys.exit(0)

# Alternative form: exactly one direct call + rebalance/helper present (helper
# does NOT internally update_dataset_image_counts; override does it once after).
if calls == 1 and (helper_invocations >= 1 or rebalance_calls >= 1):
    print(f"PASS (1 direct update + rebalance/helper invoked: helper={helper_invocations}, rebalance={rebalance_calls})")
    sys.exit(0)

# Degenerate form: 0 direct calls, no rebalance helper => override is a no-op stub.
if calls == 0 and helper_invocations == 0 and rebalance_calls == 0:
    print("FAIL: override has neither rebalance/helper invocation nor any update call (stubbed?)")
    sys.exit(1)

print(f"PASS (calls={calls}, helper={helper_invocations}, rebalance={rebalance_calls})")
PYEOF
T3=$?
cat /tmp/t3.log
if [ $T3 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    echo "(+0.15)"
fi

# ===========================================================================
# F2P 4 (0.10): Override calls super with update_counts=<non-True> AND triggers
# a rebalance. The override is structurally complete: it suppresses the base's
# count-update so the rebalance/helper path can manage the single count-update.
#
# RELAXED 2026-05-16: previously required literal `update_counts=False`, which
# rejected the canonical `update_counts=not self.is_training_dataset` (UnaryOp).
# Per the SWE-bench Verified critique, accept ANY expression passed to the
# `update_counts` kwarg that is not a literal True. Valid forms include:
#   - Constant(False)                   (legacy literal)
#   - UnaryOp(Not, Attribute(...))      (canonical: not self.is_training_dataset)
#   - Name(...)                         (variable)
#   - BoolOp/Compare/Attribute          (any non-True expression)
# ===========================================================================
echo "--- F2P 4 (0.10): override defers count update via super(update_counts=<non-True>) and rebalances ---"
timeout 10 python3 << 'PYEOF' > /tmp/t4.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
if not c.get("db_filter_found", False):
    print("FAIL: no override")
    sys.exit(1)
sf = c.get("db_filter_super_update_false", 0)
snt = c.get("db_filter_super_update_nontrue", 0)
rb = c.get("db_filter_rebalance_calls", 0)
helper_inv = c.get("db_filter_helper_invocations", 0)
seg = c.get("db_filter_source", "")
if snt < 1:
    print(f"FAIL: super(...).filter_registered_images_by_orig_resolution(update_counts=<non-True>) not present "
          f"(super_update_false={sf}, super_update_nontrue={snt})")
    sys.exit(1)
if rb < 1 and helper_inv < 1 and "rebalance" not in seg.lower() and "register_regularization" not in seg.lower() and "register_balanced" not in seg.lower():
    print("FAIL: override does not invoke a rebalance/re-register helper")
    sys.exit(1)
print(f"PASS (super-update-nontrue={snt} [of which literal-False={sf}], rebalance-call-like={rb}, helper-invocations={helper_inv})")
PYEOF
T4=$?
cat /tmp/t4.log
if [ $T4 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    echo "(+0.10)"
fi

# ===========================================================================
# F2P 5 (0.20): BEHAVIORAL — zero-reg-images edge case is handled gracefully.
# Construct a DreamBoothDataset-like flow by directly invoking the balancing
# helper(s) with empty reg_infos and verify no crash. We do this by patching
# enough state to call the helper safely on a real instance using
# DreamBoothDataset.__new__ and bound method invocation.
# ===========================================================================
echo "--- F2P 5 (0.20): Zero reg images edge case (behavioral) ---"
timeout 60 python3 << 'PYEOF' > /tmp/t5.log 2>&1
import sys, traceback
sys.path.insert(0, "/workspace/sd-scripts")
try:
    import library.train_util as tu
except Exception as e:
    print("FAIL: import error:", e); traceback.print_exc(); sys.exit(1)

DBD = getattr(tu, "DreamBoothDataset", None)
BASE = getattr(tu, "BaseDataset", None)
if DBD is None:
    print("FAIL: DreamBoothDataset missing"); sys.exit(1)

# Find a balance helper
helper_name = None
for n in ("_balance_reg_images", "register_regularization_images", "rebalance_regularization_images"):
    if hasattr(DBD, n) or hasattr(BASE, n):
        helper_name = n
        break
if helper_name is None:
    print("FAIL: no balance helper method found on classes")
    sys.exit(1)

# Construct a minimal instance without running __init__
inst = DBD.__new__(DBD)
inst.image_data = {}
inst.image_to_subset = {}
inst.subsets = []
inst.is_training_dataset = True
inst.num_train_images = 0
inst.num_reg_images = 0
inst._reg_infos = []

# Try to call the helper with empty reg_infos. Try a few signatures.
import inspect
fn = getattr(inst, helper_name, None)
if fn is None:
    fn = getattr(BASE, helper_name, None).__get__(inst, type(inst))

try:
    sig = inspect.signature(fn)
    params = [p for p in sig.parameters.values() if p.name != "self"]
    args = []
    for p in params:
        if p.default is not inspect.Parameter.empty:
            continue
        # Heuristic: empty list for reg_infos, 0 for num_train_images
        if "reg" in p.name.lower():
            args.append([])
        elif "num_train" in p.name.lower() or "train" in p.name.lower():
            args.append(0)
        else:
            args.append(None)
    # Call without crashing
    try:
        fn(*args)
        print(f"PASS: {helper_name}({args}) handled empty reg_infos without error")
        sys.exit(0)
    except TypeError:
        # Try alternate ordering
        try:
            fn([], 0)
            print(f"PASS: {helper_name}([], 0) handled empty reg_infos without error")
            sys.exit(0)
        except Exception as e:
            try:
                fn([])
                print(f"PASS: {helper_name}([]) handled empty reg_infos without error")
                sys.exit(0)
            except Exception as e2:
                print(f"FAIL: helper call raised: {e2}")
                traceback.print_exc()
                sys.exit(1)
except Exception as e:
    print(f"FAIL: {e}")
    traceback.print_exc()
    sys.exit(1)
PYEOF
T5=$?
cat /tmp/t5.log
if [ $T5 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.20")
    echo "(+0.20)"
fi

# ===========================================================================
# F2P 6 (0.15): BEHAVIORAL — balancing produces correct repeat counts.
# Construct fake ImageInfo objects + reg_infos and call the helper to balance
# against num_train_images=10 with 3 reg images of num_repeats=1. The total
# reg num_repeats must equal num_train_images (or at least >= num_train_images
# and <= num_train_images + len(reg_infos), matching the original semantics).
# ===========================================================================
echo "--- F2P 6 (0.15): Balancing math correctness (behavioral) ---"
timeout 60 python3 << 'PYEOF' > /tmp/t6.log 2>&1
import sys, traceback, inspect
sys.path.insert(0, "/workspace/sd-scripts")
try:
    import library.train_util as tu
except Exception as e:
    print("FAIL: import error:", e); sys.exit(1)

DBD = getattr(tu, "DreamBoothDataset", None)
BASE = getattr(tu, "BaseDataset", None)
ImageInfo = getattr(tu, "ImageInfo", None)

helper_name = None
for n in ("_balance_reg_images", "register_regularization_images", "rebalance_regularization_images"):
    if hasattr(DBD, n) or hasattr(BASE, n):
        helper_name = n
        break
if helper_name is None:
    print("FAIL: no helper method found"); sys.exit(1)

inst = DBD.__new__(DBD)
inst.image_data = {}
inst.image_to_subset = {}
inst.subsets = []
inst.is_training_dataset = True
inst.num_train_images = 10
inst.num_reg_images = 0
inst._reg_infos = []

# Build fake reg ImageInfos
class FakeSubset:
    def __init__(self):
        self.image_dir = "/tmp/reg"
        self.num_repeats = 1
        self.img_count = 1

reg_infos = []
for i in range(3):
    if ImageInfo is not None:
        try:
            info = ImageInfo(image_key=f"reg_{i}", num_repeats=1, caption="x", is_reg=True, absolute_path=f"/tmp/reg_{i}.png")
        except Exception:
            try:
                info = ImageInfo(f"reg_{i}", 1, "x", True, f"/tmp/reg_{i}.png")
            except Exception as e:
                print(f"FAIL: cannot construct ImageInfo: {e}")
                sys.exit(1)
    else:
        class FI:
            pass
        info = FI()
        info.image_key = f"reg_{i}"
        info.num_repeats = 1
        info.is_reg = True
        info.absolute_path = f"/tmp/reg_{i}.png"
        info.caption = "x"
    reg_infos.append((info, FakeSubset()))

fn = getattr(inst, helper_name)
sig = inspect.signature(fn)
params = [p for p in sig.parameters.values() if p.name != "self"]

call_kwargs = {}
call_args = []
for p in params:
    if p.default is not inspect.Parameter.empty:
        continue
    nm = p.name.lower()
    if "reg" in nm:
        call_args.append(reg_infos)
    elif "num_train" in nm or "train_images" in nm or nm == "num":
        call_args.append(10)
    else:
        call_args.append(None)

# Save original num_repeats so we can detect them being mutated
originals = [info.num_repeats for info, _ in reg_infos]

try:
    fn(*call_args)
except TypeError:
    try:
        fn(reg_infos, 10)
    except TypeError:
        try:
            fn(10, reg_infos)
        except Exception as e:
            print(f"FAIL: could not call helper: {e}")
            traceback.print_exc()
            sys.exit(1)
    except Exception as e:
        print(f"FAIL: helper raised: {e}")
        traceback.print_exc()
        sys.exit(1)
except Exception as e:
    print(f"FAIL: helper raised: {e}")
    traceback.print_exc()
    sys.exit(1)

total = sum(info.num_repeats for info, _ in reg_infos)
n_train = 10
# Original semantics: balance loop adds 1 per pass until n >= num_train_images
# Final total should be exactly num_train_images (since starts at 3, increments by 1).
# Allow [num_train_images, num_train_images + len(reg_infos)] tolerance.
if total < n_train or total > n_train + len(reg_infos):
    print(f"FAIL: total reg num_repeats={total}, expected ~{n_train} (originals {originals})")
    sys.exit(1)

# Also check images registered
reg_in_data = [k for k, info in inst.image_data.items() if getattr(info, "is_reg", False)]
if len(reg_in_data) != 3:
    # Some implementations register through register_image, others may not. Be lenient
    # but require at least one path of registration if helper name suggests register.
    if "register" in helper_name:
        print(f"FAIL: register helper did not register 3 reg images (got {len(reg_in_data)})")
        sys.exit(1)

print(f"PASS: total reg num_repeats={total} (target {n_train}), registered={len(reg_in_data)}")
sys.exit(0)
PYEOF
T6=$?
cat /tmp/t6.log
if [ $T6 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    echo "(+0.15)"
fi

# ===========================================================================
# F2P 7 (0.10): BEHAVIORAL — DB filter override, when called, performs exactly
# ONE update of num_train_images / num_reg_images (no double accounting).
# We monkey-patch update_dataset_image_counts on a real instance and ensure
# it's invoked at most once by a single override call.
# ===========================================================================
echo "--- F2P 7 (0.10): override path triggers update_dataset_image_counts at most once ---"
timeout 60 python3 << 'PYEOF' > /tmp/t7.log 2>&1
import sys, traceback
sys.path.insert(0, "/workspace/sd-scripts")
try:
    import library.train_util as tu
except Exception as e:
    print("FAIL: import:", e); sys.exit(1)

DBD = getattr(tu, "DreamBoothDataset")
BASE = getattr(tu, "BaseDataset")

if not hasattr(DBD, "filter_registered_images_by_orig_resolution"):
    print("FAIL: DreamBoothDataset has no filter_registered_images_by_orig_resolution override")
    sys.exit(1)

# Verify it is actually defined on DBD (not just inherited)
own = "filter_registered_images_by_orig_resolution" in DBD.__dict__
if not own:
    print("FAIL: filter_registered_images_by_orig_resolution not overridden on DreamBoothDataset")
    sys.exit(1)

inst = DBD.__new__(DBD)
inst.image_data = {}
inst.image_to_subset = {}
inst.subsets = []
inst.is_training_dataset = True
inst.num_train_images = 0
inst.num_reg_images = 0
inst._reg_infos = []
inst.enable_bucket = True
inst.min_bucket_reso = None
inst.max_bucket_reso = None
inst.bucket_reso_steps = 64
inst.bucket_no_upscale = False

call_count = {"n": 0}
def fake_update(self=None, *a, **kw):
    call_count["n"] += 1

# Patch on instance and on classes to catch any path
import types
inst.update_dataset_image_counts = types.MethodType(lambda self: (call_count.__setitem__("n", call_count["n"]+1)), inst)
# Also patch class-level methods so super() routes hit our counter
orig_base_update = getattr(BASE, "update_dataset_image_counts", None)
def class_fake(self, *a, **kw):
    call_count["n"] += 1
if orig_base_update is not None:
    BASE.update_dataset_image_counts = class_fake

# Patch base filter to be a no-op that just respects update_counts kwarg by calling update if True
orig_base_filter = BASE.filter_registered_images_by_orig_resolution
def fake_filter(self, update_counts: bool = True):
    if update_counts:
        # Simulate base behavior of calling update
        self.update_dataset_image_counts()
BASE.filter_registered_images_by_orig_resolution = fake_filter

try:
    inst.filter_registered_images_by_orig_resolution()
except Exception as e:
    # The override might call rebalance which needs more state; that's OK as long as
    # it didn't double-count BEFORE crashing. But a clean fix shouldn't crash here.
    print(f"NOTE: override raised: {e}")

# Restore
BASE.filter_registered_images_by_orig_resolution = orig_base_filter
if orig_base_update is not None:
    BASE.update_dataset_image_counts = orig_base_update

n = call_count["n"]
if n > 1:
    print(f"FAIL: update_dataset_image_counts invoked {n} times in single filter call (double-call still present)")
    sys.exit(1)
print(f"PASS: update_dataset_image_counts invoked {n} time(s) (<=1)")
sys.exit(0)
PYEOF
T7=$?
cat /tmp/t7.log
if [ $T7 -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    echo "(+0.10)"
fi

# ---------------------------------------------------------------------------
# Total / write
# ---------------------------------------------------------------------------
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt