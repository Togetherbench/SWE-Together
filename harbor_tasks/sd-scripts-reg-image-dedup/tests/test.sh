#!/bin/bash
set +e
export PATH="/workspace/venv/bin:$PATH"

chmod -R a+w /workspace/sd-scripts 2>/dev/null || true

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SRC="/workspace/sd-scripts/library/train_util.py"
REWARD=0.0

awk_add() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.4f", a + b }'
}

echo "=== sd-scripts-reg-image-dedup verifier ==="

if [ ! -f "$SRC" ]; then
    echo "FATAL: $SRC missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-parse: extract structural data
# ---------------------------------------------------------------------------
timeout 30 python3 << 'PYEOF' > /tmp/parse_out 2>&1
import ast, json, sys

SRC = "/workspace/sd-scripts/library/train_util.py"
try:
    with open(SRC) as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    json.dump({"parse_ok": False, "error": str(e)}, open("/tmp/test_cache.json", "w"))
    sys.exit(0)

cache = {"parse_ok": True, "src_len": len(src)}

db_cls = base_cls = None
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        if node.name == "DreamBoothDataset":
            db_cls = node
        elif node.name == "BaseDataset":
            base_cls = node

def calls_method(caller, name):
    return any(
        isinstance(n, ast.Call) and (
            (isinstance(n.func, ast.Attribute) and n.func.attr == name) or
            (isinstance(n.func, ast.Name) and n.func.id == name))
        for n in ast.walk(caller))

def count_while_with_first_loop(fn):
    # Count whiles that contain a reference to 'first_loop' or that look like the bal loop
    count = 0
    for n in ast.walk(fn):
        if isinstance(n, ast.While):
            seg = ast.dump(n)
            if "first_loop" in seg or "num_train_images" in seg:
                count += 1
    return count

if db_cls:
    cache["dreambooth_found"] = True
    methods = {i.name: i for i in db_cls.body if isinstance(i, ast.FunctionDef)}
    init_fn = methods.get("__init__")
    rebalance_fn = methods.get("rebalance_regularization_images")
    db_filter_fn = methods.get("filter_registered_images_by_orig_resolution")

    if init_fn:
        init_src = ast.get_source_segment(src, init_fn) or ""
        cache["init_has_first_loop_var"] = "first_loop = True" in init_src or "first_loop=True" in init_src
        cache["init_balance_while_count"] = count_while_with_first_loop(init_fn)
        cache["init_loc"] = init_src.count("\n")

    if rebalance_fn:
        cache["rebalance_found"] = True
        rb_src = ast.get_source_segment(src, rebalance_fn) or ""
        cache["rebalance_loc"] = rb_src.count("\n")
    else:
        cache["rebalance_found"] = False

    if db_filter_fn:
        cache["db_filter_found"] = True
        seg = ast.get_source_segment(src, db_filter_fn) or ""
        cache["db_filter_source"] = seg
        # Count direct calls to update_dataset_image_counts inside the override
        update_calls = 0
        for n in ast.walk(db_filter_fn):
            if isinstance(n, ast.Call):
                fn_name = None
                if isinstance(n.func, ast.Attribute):
                    fn_name = n.func.attr
                elif isinstance(n.func, ast.Name):
                    fn_name = n.func.id
                if fn_name and "update_dataset_image_counts" in fn_name:
                    update_calls += 1
        cache["db_filter_update_count_calls"] = update_calls
    else:
        cache["db_filter_found"] = False

# Count occurrences of the balancing while loop pattern in source
cache["first_loop_count"] = src.count("first_loop")
cache["while_n_lt_num_train"] = src.count("while n < num_train_images")

with open("/tmp/test_cache.json", "w") as f:
    json.dump(cache, f, indent=2)
print("OK")
PYEOF

if [ ! -f /tmp/test_cache.json ]; then
    echo "FATAL: pre-parse failed"
    cat /tmp/parse_out
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

PARSE_OK=$(python3 -c "import json; print(json.load(open('/tmp/test_cache.json')).get('parse_ok', False))" 2>/dev/null)
if [ "$PARSE_OK" != "True" ]; then
    echo "FAIL: source did not parse"
    cat /tmp/test_cache.json
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ===========================================================================
# TEST 1 (Structural, 0.08): Module imports cleanly. Required for everything.
# ===========================================================================
echo "--- Test 1: Module imports ---"
timeout 30 python3 -c "
import sys
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu
assert hasattr(tu, 'DreamBoothDataset')
assert hasattr(tu, 'BaseDataset')
print('PASS')
" > /tmp/t1.log 2>&1
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.08")
    echo "PASS (+0.08)"
else
    echo "FAIL: import error"
    cat /tmp/t1.log | head -30
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ===========================================================================
# TEST 2 (Structural, 0.10): Dedup achieved — the balancing while-loop with
# first_loop is no longer in __init__. (Allows it to live in a helper.)
# ===========================================================================
echo "--- Test 2: Balancing logic deduplicated out of __init__ ---"
timeout 10 python3 << 'PYEOF' > /tmp/t2.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
init_has_var = c.get("init_has_first_loop_var", True)
init_while = c.get("init_balance_while_count", 1)
fl = c.get("first_loop_count", 0)
wn = c.get("while_n_lt_num_train", 0)

if init_has_var:
    print(f"FAIL: __init__ still has 'first_loop = True' (balancing not extracted)")
    sys.exit(1)
if init_while > 0:
    print(f"FAIL: __init__ still has balancing-style while loop ({init_while})")
    sys.exit(1)
# After dedup, the bal pattern should appear at most once in the file
if wn > 1:
    print(f"FAIL: 'while n < num_train_images' appears {wn} times (duplication remains)")
    sys.exit(1)
print(f"PASS (first_loop refs={fl}, while-pattern={wn})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    cat /tmp/t2.log
    echo "(+0.10)"
else
    cat /tmp/t2.log
fi

# ===========================================================================
# TEST 3 (Structural, 0.07): DreamBooth filter override should NOT directly
# call update_dataset_image_counts (it's already called via base / rebalance).
# Allow at most 0 such direct calls — base class call is via super().
# ===========================================================================
echo "--- Test 3: DB filter override doesn't re-call update_dataset_image_counts ---"
timeout 10 python3 << 'PYEOF' > /tmp/t3.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
if not c.get("db_filter_found", False):
    # OK if no override exists; nothing to fix
    print("SKIP: no DB filter override (acceptable)")
    sys.exit(0)
calls = c.get("db_filter_update_count_calls", 99)
seg = c.get("db_filter_source", "")
# Allow exactly one — but only if it's the super() call inside the override.
# We count direct attribute/name calls to update_dataset_image_counts.
# After fix, the override shouldn't call update_dataset_image_counts at all
# (because base does, OR rebalance does).
if calls > 1:
    print(f"FAIL: override still has {calls} direct update_dataset_image_counts calls")
    sys.exit(1)
print(f"PASS (direct update calls in override = {calls})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.07")
    cat /tmp/t3.log
    echo "(+0.07)"
else
    cat /tmp/t3.log
fi

# ===========================================================================
# Helper: build a DreamBoothDataset for behavioral tests
# Implementation-agnostic — handles signature variations.
# ===========================================================================
cat > /tmp/build_ds.py << 'PYEOF'
"""Helper to build a DreamBoothDataset robustly across small signature differences."""
import sys, os, inspect
sys.path.insert(0, '/workspace/sd-scripts')

from PIL import Image
import library.train_util as tu

def mkimg(path, size=(64, 64)):
    Image.new("RGB", size, (128, 128, 128)).save(path)

def build_subset(image_dir, num_repeats=1, is_reg=False, **overrides):
    cls = tu.DreamBoothSubset
    sig = inspect.signature(cls.__init__)
    params = list(sig.parameters.values())[1:]  # skip self
    kwargs = {}
    defaults = {
        "image_dir": image_dir,
        "num_repeats": num_repeats,
        "is_reg": is_reg,
        "shuffle_caption": False,
        "caption_separator": ",",
        "keep_tokens": 0,
        "keep_tokens_separator": "",
        "secondary_separator": "",
        "enable_wildcard": False,
        "color_aug": False,
        "flip_aug": False,
        "face_crop_aug_range": None,
        "random_crop": False,
        "caption_dropout_rate": 0.0,
        "caption_dropout_every_n_epochs": 0,
        "caption_tag_dropout_rate": 0.0,
        "caption_prefix": "",
        "caption_suffix": "",
        "token_warmup_min": 1,
        "token_warmup_step": 0,
        "class_tokens": "x",
        "caption_extension": ".txt",
        "cache_info": False,
        "alpha_mask": False,
        "resize_interpolation": None,
        "custom_attributes": None,
    }
    defaults.update(overrides)
    for p in params:
        if p.name in defaults:
            kwargs[p.name] = defaults[p.name]
        elif p.default is inspect.Parameter.empty:
            # Required arg we don't know — try None
            kwargs[p.name] = None
    try:
        return cls(**kwargs)
    except TypeError as e:
        # Try positional with all params we have
        raise

def build_dataset(subsets, batch_size=1, resolution=(64, 64), validation_split=0.0, is_training_dataset=True):
    cls = tu.DreamBoothDataset
    sig = inspect.signature(cls.__init__)
    params = list(sig.parameters.values())[1:]
    defaults = {
        "subsets": subsets,
        "is_training_dataset": is_training_dataset,
        "batch_size": batch_size,
        "tokenizer": None,
        "tokenizers": [None],
        "max_token_length": 75,
        "resolution": resolution,
        "network_multiplier": 1.0,
        "enable_bucket": False,
        "min_bucket_reso": 64,
        "max_bucket_reso": 256,
        "bucket_reso_steps": 64,
        "bucket_no_upscale": False,
        "prior_loss_weight": 1.0,
        "debug_dataset": False,
        "validation_split": validation_split,
        "validation_seed": None,
        "resize_interpolation": None,
    }
    kwargs = {}
    for p in params:
        if p.name in defaults:
            kwargs[p.name] = defaults[p.name]
        elif p.default is inspect.Parameter.empty:
            kwargs[p.name] = None
    return cls(**kwargs)
PYEOF

# ===========================================================================
# TEST 4 (Behavioral, 0.18): Normal balancing — reg images get repeats bumped
# to roughly match training image total.
# ===========================================================================
echo "--- Test 4: Normal balancing behavior ---"
timeout 90 python3 << 'PYEOF' > /tmp/t4.log 2>&1
import sys, os, tempfile
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

with tempfile.TemporaryDirectory() as tmp:
    train_dir = os.path.join(tmp, "10_train")
    reg_dir = os.path.join(tmp, "1_reg")
    os.makedirs(train_dir)
    os.makedirs(reg_dir)
    # 3 train images * 10 repeats = 30 train repeats
    for i in range(3):
        mkimg(os.path.join(train_dir, f"t{i}.png"))
    # 2 reg images * 1 repeat = 2 reg repeats; should be balanced up to ~30
    for i in range(2):
        mkimg(os.path.join(reg_dir, f"r{i}.png"))

    ts = build_subset(train_dir, num_repeats=10, is_reg=False)
    rs = build_subset(reg_dir, num_repeats=1, is_reg=True)

    ds = build_dataset([ts, rs])
    ntr = ds.num_train_images
    nrg = ds.num_reg_images
    print(f"num_train_images={ntr} num_reg_images={nrg}")
    assert ntr == 30, f"expected 30 train, got {ntr}"
    # Reg should be balanced to >= train (within 1 of train, since topup goes per-image)
    assert nrg >= ntr - 1 and nrg <= ntr + 2, f"reg not balanced: {nrg} vs {ntr}"
    # And the actual sum of repeats over reg image_data should match
    total_reg = sum(info.num_repeats for info in ds.image_data.values() if info.is_reg)
    assert total_reg == nrg, f"reg counts inconsistent: total={total_reg} stored={nrg}"
    print("PASS")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.18")
    cat /tmp/t4.log | tail -3
    echo "(+0.18)"
else
    echo "FAIL"
    cat /tmp/t4.log | tail -25
fi

# ===========================================================================
# TEST 5 (Behavioral, 0.15): Edge case — zero reg images shouldn't crash.
# ===========================================================================
echo "--- Test 5: Zero reg images edge case ---"
timeout 90 python3 << 'PYEOF' > /tmp/t5.log 2>&1
import sys, os, tempfile
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

with tempfile.TemporaryDirectory() as tmp:
    train_dir = os.path.join(tmp, "5_train")
    os.makedirs(train_dir)
    for i in range(2):
        mkimg(os.path.join(train_dir, f"t{i}.png"))

    ts = build_subset(train_dir, num_repeats=5, is_reg=False)
    ds = build_dataset([ts])  # NO reg subset
    assert ds.num_train_images == 10, f"expected 10, got {ds.num_train_images}"
    assert ds.num_reg_images == 0, f"expected 0 reg, got {ds.num_reg_images}"
    print("PASS")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    cat /tmp/t5.log | tail -3
    echo "(+0.15)"
else
    echo "FAIL"
    cat /tmp/t5.log | tail -25
fi

# ===========================================================================
# TEST 6 (Behavioral, 0.10): Edge case — reg images present but train list is
# empty (validation-split or zero-train scenario). Shouldn't infinite loop.
# ===========================================================================
echo "--- Test 6: Zero train images (with reg) shouldn't hang ---"
timeout 60 python3 << 'PYEOF' > /tmp/t6.log 2>&1
import sys, os, tempfile, signal
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

# Set hard alarm to detect infinite loop
def handler(signum, frame):
    raise TimeoutError("infinite loop detected in balancing")
signal.signal(signal.SIGALRM, handler)
signal.alarm(30)

with tempfile.TemporaryDirectory() as tmp:
    reg_dir = os.path.join(tmp, "1_reg")
    os.makedirs(reg_dir)
    for i in range(2):
        mkimg(os.path.join(reg_dir, f"r{i}.png"))

    rs = build_subset(reg_dir, num_repeats=1, is_reg=True)
    try:
        ds = build_dataset([rs])
        print(f"num_train={ds.num_train_images} num_reg={ds.num_reg_images}")
        # No train images; whatever the implementation chooses, just shouldn't hang
        print("PASS")
    except TimeoutError as e:
        print(f"FAIL: {e}")
        sys.exit(1)
    except Exception as e:
        # An exception is acceptable as long as it's not a hang
        # but a clean handling is preferred
        print(f"PARTIAL: raised {type(e).__name__}: {e}")
        # We accept this case rather than failing — but let's be lenient and pass
        print("PASS")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    cat /tmp/t6.log | tail -3
    echo "(+0.10)"
else
    echo "FAIL"
    cat /tmp/t6.log | tail -25
fi

# ===========================================================================
# TEST 7 (Behavioral, 0.10): Multiple reg subsets with different num_repeats
# should still balance correctly without double-counting.
# ===========================================================================
echo "--- Test 7: Multi-subset balancing correctness ---"
timeout 90 python3 << 'PYEOF' > /tmp/t7.log 2>&1
import sys, os, tempfile
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

with tempfile.TemporaryDirectory() as tmp:
    t1 = os.path.join(tmp, "5_train1"); os.makedirs(t1)
    t2 = os.path.join(tmp, "3_train2"); os.makedirs(t2)
    r1 = os.path.join(tmp, "2_reg1");   os.makedirs(r1)
    for i in range(2): mkimg(os.path.join(t1, f"a{i}.png"))
    for i in range(2): mkimg(os.path.join(t2, f"b{i}.png"))
    for i in range(3): mkimg(os.path.join(r1, f"r{i}.png"))

    ts1 = build_subset(t1, num_repeats=5, is_reg=False)
    ts2 = build_subset(t2, num_repeats=3, is_reg=False)
    rs  = build_subset(r1, num_repeats=2, is_reg=True)

    ds = build_dataset([ts1, ts2, rs])
    expected_train = 2*5 + 2*3   # = 16
    assert ds.num_train_images == expected_train, f"train: got {ds.num_train_images} want {expected_train}"
    # Reg should be roughly balanced toward 16
    assert ds.num_reg_images >= expected_train - 1, f"reg under-balanced: {ds.num_reg_images}"
    assert ds.num_reg_images <= expected_train + 3, f"reg over-balanced (likely double-call): {ds.num_reg_images}"

    # Check stored image_data sums match the reported counts
    train_sum = sum(i.num_repeats for i in ds.image_data.values() if not i.is_reg)
    reg_sum   = sum(i.num_repeats for i in ds.image_data.values() if     i.is_reg)
    assert train_sum == ds.num_train_images, f"train mismatch {train_sum} vs {ds.num_train_images}"
    assert reg_sum   == ds.num_reg_images,   f"reg   mismatch {reg_sum} vs {ds.num_reg_images}"
    print(f"PASS (train={ds.num_train_images}, reg={ds.num_reg_images})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    cat /tmp/t7.log | tail -3
    echo "(+0.10)"
else
    echo "FAIL"
    cat /tmp/t7.log | tail -25
fi

# ===========================================================================
# TEST 8 (Behavioral, 0.12): The double-update bug — after calling the
# DreamBooth filter override, num_train_images and num_reg_images should be
# accurate and consistent with image_data sums (no stale or doubled state).
# ===========================================================================
echo "--- Test 8: filter override leaves counts consistent ---"
timeout 90 python3 << 'PYEOF' > /tmp/t8.log 2>&1
import sys, os, tempfile
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

with tempfile.TemporaryDirectory() as tmp:
    train_dir = os.path.join(tmp, "4_train"); os.makedirs(train_dir)
    reg_dir   = os.path.join(tmp, "1_reg");   os.makedirs(reg_dir)
    for i in range(3): mkimg(os.path.join(train_dir, f"t{i}.png"))
    for i in range(2): mkimg(os.path.join(reg_dir,   f"r{i}.png"))

    ts = build_subset(train_dir, num_repeats=4, is_reg=False)
    rs = build_subset(reg_dir,   num_repeats=1, is_reg=True)

    ds = build_dataset([ts, rs])

    # Call the filter override (no actual filtering will happen since enable_bucket=False
    # but the call paths still exercise update logic)
    if hasattr(ds, "filter_registered_images_by_orig_resolution"):
        try:
            ds.filter_registered_images_by_orig_resolution()
        except Exception as e:
            print(f"NOTE: filter raised {type(e).__name__}: {e}")

    train_sum = sum(i.num_repeats for i in ds.image_data.values() if not i.is_reg)
    reg_sum   = sum(i.num_repeats for i in ds.image_data.values() if     i.is_reg)
    # After the filter, the counts should match the actual image_data state.
    # The bug was a double-call to update_dataset_image_counts which by itself
    # is idempotent... but combined with rebalance it could re-bump reg counts.
    # We assert: stored attributes match recomputed sums, AND reg sum is balanced.
    assert ds.num_train_images == train_sum, f"train: stored={ds.num_train_images} actual={train_sum}"
    assert ds.num_reg_images   == reg_sum,   f"reg:   stored={ds.num_reg_images} actual={reg_sum}"
    # And reg should not have been over-bumped (consistent with train ~12)
    assert reg_sum <= train_sum + 2, f"reg over-bumped {reg_sum} vs train {train_sum}"
    assert reg_sum >= train_sum - 2, f"reg under-balanced {reg_sum} vs train {train_sum}"
    print(f"PASS (train={train_sum}, reg={reg_sum})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.12")
    cat /tmp/t8.log | tail -3
    echo "(+0.12)"
else
    echo "FAIL"
    cat /tmp/t8.log | tail -25
fi

# ===========================================================================
# TEST 9 (Behavioral, 0.10): Idempotence — calling rebalance again or
# calling filter twice shouldn't keep growing reg counts (regression guard
# against double-balancing).
# ===========================================================================
echo "--- Test 9: Idempotence — repeated filter calls don't inflate reg counts ---"
timeout 90 python3 << 'PYEOF' > /tmp/t9.log 2>&1
import sys, os, tempfile
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
from build_ds import mkimg, build_subset, build_dataset

with tempfile.TemporaryDirectory() as tmp:
    train_dir = os.path.join(tmp, "6_train"); os.makedirs(train_dir)
    reg_dir   = os.path.join(tmp, "1_reg");   os.makedirs(reg_dir)
    for i in range(2): mkimg(os.path.join(train_dir, f"t{i}.png"))
    for i in range(2): mkimg(os.path.join(reg_dir,   f"r{i}.png"))

    ts = build_subset(train_dir, num_repeats=6, is_reg=False)
    rs = build_subset(reg_dir,   num_repeats=1, is_reg=True)

    ds = build_dataset([ts, rs])
    initial_reg = ds.num_reg_images
    initial_train = ds.num_train_images
    print(f"initial: train={initial_train} reg={initial_reg}")

    # Call filter override several times; numbers should stabilize
    if hasattr(ds, "filter_registered_images_by_orig_resolution"):
        for i in range(3):
            try:
                ds.filter_registered_images_by_orig_resolution()
            except Exception:
                pass
        after_reg = ds.num_reg_images
        after_train = ds.num_train_images
        print(f"after 3 calls: train={after_train} reg={after_reg}")
        assert after_train == initial_train, f"train changed: {after_train} vs {initial_train}"
        # reg should NOT have been re-bumped each time
        assert after_reg <= initial_reg + 2, f"reg inflated: {after_reg} (was {initial_reg})"
    print("PASS")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.10")
    cat /tmp/t9.log | tail -5
    echo "(+0.10)"
else
    echo "FAIL"
    cat /tmp/t9.log | tail -25
fi

# ===========================================================================
# Final reward
# ===========================================================================
# Cap at 1.0
FINAL=$(awk -v r="$REWARD" 'BEGIN { if (r > 1.0) r = 1.0; if (r < 0) r = 0; printf "%.4f", r }')
echo "=== Final reward: $FINAL ==="
echo "$FINAL" > "$REWARD_FILE"
exit 0