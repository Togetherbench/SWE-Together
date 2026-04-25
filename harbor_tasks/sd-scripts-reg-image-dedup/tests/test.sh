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
# GATE: module imports cleanly. If this fails, the agent broke something.
# This passes on the base, so it's purely a gate (no reward weight).
# ---------------------------------------------------------------------------
echo "--- Gate: module imports ---"
timeout 30 python3 -c "
import sys
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu
assert hasattr(tu, 'DreamBoothDataset')
assert hasattr(tu, 'BaseDataset')
print('GATE PASS')
" > /tmp/gate_import.log 2>&1
if [ $? -ne 0 ]; then
    echo "GATE FAIL: import error (regression)"
    cat /tmp/gate_import.log | head -40
    write_reward_and_exit "0.0"
fi

# ---------------------------------------------------------------------------
# Pre-parse: AST-walk to extract structural facts about __init__, the
# DreamBooth filter override, and balancing-while occurrences.
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

def count_balance_while(fn):
    count = 0
    for n in ast.walk(fn):
        if isinstance(n, ast.While):
            seg = ast.dump(n)
            if "first_loop" in seg or ("num_train_images" in seg and "num_repeats" in seg):
                count += 1
    return count

if db_cls:
    cache["dreambooth_found"] = True
    methods = {i.name: i for i in db_cls.body if isinstance(i, ast.FunctionDef)}
    init_fn = methods.get("__init__")
    db_filter_fn = methods.get("filter_registered_images_by_orig_resolution")

    if init_fn:
        init_src = ast.get_source_segment(src, init_fn) or ""
        cache["init_has_first_loop_var"] = ("first_loop = True" in init_src) or ("first_loop=True" in init_src)
        cache["init_balance_while_count"] = count_balance_while(init_fn)

    if db_filter_fn:
        cache["db_filter_found"] = True
        seg = ast.get_source_segment(src, db_filter_fn) or ""
        cache["db_filter_source"] = seg
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

cache["first_loop_count"] = src.count("first_loop")
cache["while_n_lt_num_train"] = src.count("while n < num_train_images")

with open("/tmp/test_cache.json", "w") as f:
    json.dump(cache, f, indent=2)
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
# F2P TEST 1 (0.20): Balancing logic deduplicated out of __init__.
# On the buggy base, __init__ contains the `first_loop = True` while-loop and
# this test FAILS. After the refactor (any sensible extraction), it passes.
# ===========================================================================
echo "--- F2P 1: Balancing logic deduplicated out of __init__ ---"
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
# After dedup, the bal-while pattern should appear at most once in the file.
if wn > 1:
    print(f"FAIL: 'while n < num_train_images' appears {wn} times (still duplicated)")
    sys.exit(1)
print(f"PASS (while-pattern occurrences={wn})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.20")
    cat /tmp/t1.log
    echo "(+0.20)"
else
    cat /tmp/t1.log
fi

# ===========================================================================
# F2P TEST 2 (0.15): DreamBooth filter override doesn't redundantly call
# update_dataset_image_counts after rebalancing. The instruction explicitly
# requires removing that double call.
# On base: no override exists OR override calls update twice → fails.
# After fix: override exists and has 0 direct calls (super/base handles it).
# ===========================================================================
echo "--- F2P 2: DB filter override doesn't double-call update_dataset_image_counts ---"
timeout 10 python3 << 'PYEOF' > /tmp/t2.log 2>&1
import json, sys
c = json.load(open("/tmp/test_cache.json"))
if not c.get("db_filter_found", False):
    print("FAIL: no DreamBooth filter override exists yet")
    sys.exit(1)
calls = c.get("db_filter_update_count_calls", 99)
seg = c.get("db_filter_source", "")
# After the fix, the override should NOT directly call update_dataset_image_counts
# at the end (the base-class call via super() handles it after rebalance).
# Allow 0 direct calls. >=1 indicates the redundant call still present.
if calls >= 1:
    print(f"FAIL: override still has {calls} direct update_dataset_image_counts call(s)")
    sys.exit(1)
print(f"PASS (direct update calls in override = {calls})")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.15")
    cat /tmp/t2.log
    echo "(+0.15)"
else
    cat /tmp/t2.log
fi

# ===========================================================================
# Build a DreamBoothDataset for behavioral tests. Helper handles signature
# differences; if construction fails entirely we skip behavioral tests with
# zero (which is correct — base would have failed too).
# ===========================================================================
mkdir -p /tmp/sd_test
rm -rf /tmp/sd_test/*
mkdir -p /tmp/sd_test/train_only/cls
mkdir -p /tmp/sd_test/train_with_reg/cls
mkdir -p /tmp/sd_test/train_with_reg/reg
mkdir -p /tmp/sd_test/zero_reg/cls

# Create dummy small images
timeout 30 python3 << 'PYEOF' > /tmp/mkimg.log 2>&1
from PIL import Image
import os
def mkimgs(dir_, n, size=(64,64), color=(128,128,128)):
    os.makedirs(dir_, exist_ok=True)
    for i in range(n):
        Image.new("RGB", size, color).save(os.path.join(dir_, f"img_{i}.png"))
        with open(os.path.join(dir_, f"img_{i}.txt"), "w") as f:
            f.write("a photo")

mkimgs("/tmp/sd_test/train_only/cls", 5)
mkimgs("/tmp/sd_test/train_with_reg/cls", 4)
mkimgs("/tmp/sd_test/train_with_reg/reg", 2)
mkimgs("/tmp/sd_test/zero_reg/cls", 3)
print("imgs OK")
PYEOF
if [ $? -ne 0 ]; then
    echo "IMG SETUP FAIL (skipping behavioral tests)"
    cat /tmp/mkimg.log | head
fi

cat > /tmp/build_ds.py << 'PYEOF'
"""Robust DreamBoothDataset builder across signature variations."""
import sys, os, inspect
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu

def make_subset(image_dir, num_repeats=1, is_reg=False):
    SubsetCls = tu.DreamBoothSubset
    sig = inspect.signature(SubsetCls.__init__)
    params = list(sig.parameters.keys())
    kwargs = {}
    # The original signature includes many fields; use defaults / sensible values.
    defaults = {
        "image_dir": image_dir,
        "is_reg": is_reg,
        "class_tokens": "cls",
        "caption_extension": ".txt",
        "cache_info": False,
        "num_repeats": num_repeats,
        "shuffle_caption": False,
        "caption_separator": ",",
        "keep_tokens": 0,
        "keep_tokens_separator": "",
        "secondary_separator": None,
        "enable_wildcard": False,
        "color_aug": False,
        "flip_aug": False,
        "face_crop_aug_range": None,
        "random_crop": False,
        "caption_prefix": None,
        "caption_suffix": None,
        "caption_dropout_rate": 0.0,
        "caption_dropout_every_n_epochs": 0,
        "caption_tag_dropout_rate": 0.0,
        "token_warmup_min": 1,
        "token_warmup_step": 0,
        "alpha_mask": False,
        "custom_attributes": None,
        "resize_interpolation": None,
    }
    for p in params:
        if p == "self":
            continue
        if p in defaults:
            kwargs[p] = defaults[p]
    try:
        return SubsetCls(**kwargs)
    except TypeError:
        # Fallback: positional with first few common args
        return SubsetCls(image_dir, False, "cls", ".txt", False, num_repeats,
                         False, ",", 0, "", None, False, False, False, None, False,
                         None, None, 0.0, 0, 0.0, 1, 0, False, None)

def make_dataset(subsets, is_training=True):
    DSCls = tu.DreamBoothDataset
    sig = inspect.signature(DSCls.__init__)
    params = list(sig.parameters.keys())
    defaults = {
        "subsets": subsets,
        "is_training_dataset": is_training,
        "batch_size": 1,
        "tokenizer": None,
        "max_token_length": 75,
        "resolution": (64, 64),
        "network_multiplier": 1.0,
        "enable_bucket": False,
        "min_bucket_reso": 64,
        "max_bucket_reso": 256,
        "bucket_reso_steps": 64,
        "bucket_no_upscale": False,
        "prior_loss_weight": 1.0,
        "debug_dataset": False,
        "validation_split": 0.0,
        "validation_seed": None,
        "resize_interpolation": None,
    }
    kwargs = {}
    for p in params:
        if p == "self":
            continue
        if p in defaults:
            kwargs[p] = defaults[p]
    return DSCls(**kwargs)
PYEOF

# ===========================================================================
# F2P TEST 3 (0.25): Zero-reg-images edge case — instantiating a dataset with
# only training images (no reg subset) must not crash.
# On a buggy base where balancing logic isn't guarded, division/loop may break;
# more importantly, the agent's refactor must preserve this. We treat this as
# a behavioral check that exercises the new helper path.
# Crucially this also checks that base behavior (counts) is sensible.
# ===========================================================================
echo "--- F2P 3: Zero reg images doesn't crash & counts correct ---"
timeout 60 python3 << 'PYEOF' > /tmp/t3.log 2>&1
import sys
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
try:
    from build_ds import make_subset, make_dataset
    s = make_subset("/tmp/sd_test/zero_reg/cls", num_repeats=3, is_reg=False)
    ds = make_dataset([s], is_training=True)
    # 3 images * num_repeats=3 = 9
    assert ds.num_train_images == 9, f"expected 9 train, got {ds.num_train_images}"
    assert ds.num_reg_images == 0, f"expected 0 reg, got {ds.num_reg_images}"
    print("PASS: zero-reg dataset built; counts correct")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"FAIL: {e}")
    sys.exit(1)
PYEOF
T3_RESULT=$?
cat /tmp/t3.log | tail -30

# This test passes on base too (zero-reg already works in original code).
# So we use it only as a GATE for the more interesting behavioral checks below;
# no reward weight assigned here directly.

# ===========================================================================
# F2P TEST 4 (0.25): Reg image balancing still works correctly after refactor.
# 4 train images * num_repeats=2 = 8 train; 2 reg images should balance to 8.
# This passes on base AND on fix — but only if the refactor preserved behavior.
# A broken refactor would fail. We use this as a regression GUARD: if it fails,
# whole reward zeroes out.
# ===========================================================================
echo "--- GUARD: balancing behavior preserved ---"
timeout 60 python3 << 'PYEOF' > /tmp/guard.log 2>&1
import sys
sys.path.insert(0, '/workspace/sd-scripts')
sys.path.insert(0, '/tmp')
try:
    from build_ds import make_subset, make_dataset
    train = make_subset("/tmp/sd_test/train_with_reg/cls", num_repeats=2, is_reg=False)
    reg = make_subset("/tmp/sd_test/train_with_reg/reg", num_repeats=1, is_reg=True)
    ds = make_dataset([train, reg], is_training=True)
    # 4 train * 2 = 8 train repeats
    assert ds.num_train_images == 8, f"expected 8 train, got {ds.num_train_images}"
    # reg should be balanced to match (8)
    assert ds.num_reg_images == 8, f"expected 8 reg (balanced), got {ds.num_reg_images}"
    print("GUARD PASS: balancing preserved")
except Exception as e:
    import traceback
    traceback.print_exc()
    print(f"GUARD FAIL: {e}")
    sys.exit(1)
PYEOF
GUARD_RESULT=$?
cat /tmp/guard.log | tail -30

if [ $GUARD_RESULT -ne 0 ]; then
    echo "GUARD FAILED — refactor broke balancing. Zeroing reward."
    write_reward_and_exit "0.0"
fi

# Now the dedup-edge-case award: dataset with no reg images should also have
# successful construction (this passes on base too, so it's a guard, not reward).
if [ $T3_RESULT -ne 0 ]; then
    echo "GUARD FAIL: zero-reg case broke. Zeroing reward."
    write_reward_and_exit "0.0"
fi

# ===========================================================================
# F2P TEST 5 (0.20): A single helper method exists on DreamBoothDataset that
# encapsulates the balancing logic. Acceptable names span what models chose:
# _balance_reg_images, register_regularization_images, rebalance_regularization_images.
# On the buggy base, NONE of these helper methods exist on DreamBoothDataset.
# After any reasonable refactor, at least one exists.
# ===========================================================================
echo "--- F2P 5: balancing helper method exists ---"
timeout 30 python3 << 'PYEOF' > /tmp/t5.log 2>&1
import sys
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu
candidates = [
    "_balance_reg_images",
    "balance_reg_images",
    "register_regularization_images",
    "rebalance_regularization_images",
]
found = [n for n in candidates if hasattr(tu.DreamBoothDataset, n)]
if not found:
    print(f"FAIL: no balancing helper method found. Tried: {candidates}")
    sys.exit(1)
print(f"PASS: helper(s) present = {found}")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.20")
    cat /tmp/t5.log
    echo "(+0.20)"
else
    cat /tmp/t5.log
fi

# ===========================================================================
# F2P TEST 6 (0.20): Override calls super() and the base/super invocation
# triggers exactly one update of dataset image counts overall. We verify by
# reading the override source: it must call super().filter_registered_images_by_orig_resolution
# (so we know it composes properly rather than reimplementing) AND it must NOT
# directly call update_dataset_image_counts (already enforced in F2P 2, but
# here we additionally require the super() call exists, which it doesn't on
# the base because the override itself doesn't exist on the base).
# ===========================================================================
echo "--- F2P 6: override exists, calls super(), no direct update call ---"
timeout 10 python3 << 'PYEOF' > /tmp/t6.log 2>&1
import json, sys, re
c = json.load(open("/tmp/test_cache.json"))
if not c.get("db_filter_found", False):
    print("FAIL: DreamBooth filter override does not exist")
    sys.exit(1)
seg = c.get("db_filter_source", "")
# Must call super() form
if not re.search(r"super\s*\(\s*\)\s*\.\s*filter_registered_images_by_orig_resolution", seg):
    print("FAIL: override doesn't call super().filter_registered_images_by_orig_resolution")
    sys.exit(1)
# Must NOT directly call update_dataset_image_counts (re-check)
direct = c.get("db_filter_update_count_calls", 99)
if direct >= 1:
    print(f"FAIL: override has {direct} direct update_dataset_image_counts calls")
    sys.exit(1)
print("PASS: override delegates to super() and doesn't double-call update")
PYEOF
if [ $? -eq 0 ]; then
    REWARD=$(awk_add "$REWARD" "0.20")
    cat /tmp/t6.log
    echo "(+0.20)"
else
    cat /tmp/t6.log
fi

echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"