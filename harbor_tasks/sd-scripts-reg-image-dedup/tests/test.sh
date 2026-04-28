#!/bin/bash
set +e
export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

chmod -R a+w /workspace/sd-scripts 2>/dev/null || true

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

SRC="/workspace/sd-scripts/library/train_util.py"

echo "=== sd-scripts-reg-image-dedup verifier ==="

# ---------------------------------------------------------------------------
# P2P: module imports
# ---------------------------------------------------------------------------
P2P_OK=1
if [ ! -f "$SRC" ]; then
    emit p2p_module_imports false "train_util.py missing"
    P2P_OK=0
else
    timeout 60 python3 -c "
import sys
sys.path.insert(0, '/workspace/sd-scripts')
import library.train_util as tu
assert hasattr(tu, 'DreamBoothDataset')
assert hasattr(tu, 'BaseDataset')
print('OK')
" > /tmp/imp.log 2>&1
    if [ $? -ne 0 ]; then
        emit p2p_module_imports false "import failed"
        P2P_OK=0
    else
        emit p2p_module_imports true ""
    fi
fi

# Helper: write a python script that imports tu and exposes utility lookups
COMMON_PY='
import sys, inspect
sys.path.insert(0, "/workspace/sd-scripts")
import library.train_util as tu
DBD = getattr(tu, "DreamBoothDataset", None)
BASE = getattr(tu, "BaseDataset", None)
ImageInfo = getattr(tu, "ImageInfo", None)

HELPER_NAMES = (
    "register_regularization_images",
    "_register_regularization_images",
    "rebalance_regularization_images",
    "_rebalance_regularization_images",
    "_balance_reg_images",
    "balance_reg_images",
    "_balance_regularization_images",
    "balance_regularization_images",
)

def find_helper(*classes):
    for cls in classes:
        if cls is None:
            continue
        for n in HELPER_NAMES:
            if n in cls.__dict__:
                return n, cls
    # fallback inheritance
    for cls in classes:
        if cls is None:
            continue
        for n in HELPER_NAMES:
            if hasattr(cls, n):
                return n, cls
    return None, None

def make_subset():
    class S:
        image_dir = "/tmp/reg"
        num_repeats = 1
        img_count = 1
        caption_extension = ".txt"
        shuffle_caption = False
        keep_tokens = 0
        keep_tokens_separator = ""
        secondary_separator = None
        enable_wildcard = False
        color_aug = False
        flip_aug = False
        face_crop_aug_range = None
        random_crop = False
        token_warmup_min = 1
        token_warmup_step = 0
        caption_prefix = None
        caption_suffix = None
        caption_dropout_rate = 0.0
        caption_dropout_every_n_epochs = 0
        caption_tag_dropout_rate = 0.0
        is_reg = True
        class_tokens = "x"
        cache_info = False
        alpha_mask = False
        custom_attributes = {}
    return S()

def make_info(key, num_repeats=1):
    if ImageInfo is not None:
        try:
            return ImageInfo(image_key=key, num_repeats=num_repeats, caption="x", is_reg=True, absolute_path=f"/tmp/{key}.png")
        except Exception:
            try:
                return ImageInfo(key, num_repeats, "x", True, f"/tmp/{key}.png")
            except Exception:
                pass
    class FI: pass
    info = FI()
    info.image_key = key
    info.num_repeats = num_repeats
    info.is_reg = True
    info.absolute_path = f"/tmp/{key}.png"
    info.caption = "x"
    return info

def stub_instance(num_train=10):
    inst = DBD.__new__(DBD)
    inst.image_data = {}
    inst.image_to_subset = {}
    inst.subsets = []
    inst.is_training_dataset = True
    inst.num_train_images = num_train
    inst.num_reg_images = 0
    inst.reg_infos = []
    inst._reg_infos = []
    inst.enable_bucket = False
    inst.min_bucket_reso = 256
    inst.max_bucket_reso = 1024
    inst.bucket_reso_steps = 64
    inst.bucket_no_upscale = False
    inst.network_multiplier = 1.0
    inst.token_padding_disabled = False
    inst.tag_frequency = {}
    inst.XTI_layers = None
    inst.token_strings = None
    inst.caption_dropout_rate = 0.0
    inst.caption_dropout_every_n_epochs = 0
    inst.caption_tag_dropout_rate = 0.0
    inst.caption_prefix = None
    inst.caption_suffix = None
    inst.tokenizer_max_length = 75
    inst.current_step = 0
    inst.replacements = {}
    inst.batch_size = 1
    inst.size = 512
    inst.resolution = (512, 512)
    inst.width = 512
    inst.height = 512
    return inst

def call_helper(fn, reg_infos, num_train):
    sig = inspect.signature(fn)
    params = [p for p in sig.parameters.values() if p.name != "self"]
    # Try kwargs by name
    bound_kwargs = {}
    for p in params:
        nm = p.name.lower()
        if "reg" in nm and "info" in nm:
            bound_kwargs[p.name] = reg_infos
        elif nm in ("reg_infos", "regs", "reg_image_infos"):
            bound_kwargs[p.name] = reg_infos
    if bound_kwargs:
        try:
            return fn(**bound_kwargs)
        except TypeError:
            pass
    # Try positional with just reg_infos
    for args in ([reg_infos], [reg_infos, num_train], [num_train, reg_infos], []):
        try:
            return fn(*args)
        except TypeError:
            continue
    # Last attempt — bubble up exception
    return fn()
'

# ---------------------------------------------------------------------------
# F2P: helper balances repeats
# ---------------------------------------------------------------------------
echo "--- F2P: helper_balances_repeats ---"
cat > /tmp/g_balances.py <<PYEOF
$COMMON_PY

helper_name, helper_cls = find_helper(DBD, BASE)
if helper_name is None:
    print("FAIL: no balance helper found")
    sys.exit(1)

inst = stub_instance(num_train=10)
reg_infos = [(make_info(f"r{i}", 1), make_subset()) for i in range(3)]
inst.reg_infos = reg_infos
inst._reg_infos = reg_infos

fn = getattr(inst, helper_name, None)
if fn is None:
    fn = getattr(helper_cls, helper_name).__get__(inst, type(inst))

try:
    call_helper(fn, reg_infos, 10)
except Exception as e:
    print(f"FAIL: helper raised: {e!r}")
    sys.exit(1)

total = sum(info.num_repeats for info, _ in reg_infos)
if total < 10:
    print(f"FAIL: total reg num_repeats={total}, expected >=10")
    sys.exit(1)
if total > 10 + len(reg_infos):
    print(f"FAIL: total reg num_repeats={total} excessively large (>{10+len(reg_infos)})")
    sys.exit(1)
print(f"PASS total={total}")
PYEOF
timeout 60 python3 /tmp/g_balances.py > /tmp/g_balances.log 2>&1
RC=$?
cat /tmp/g_balances.log
if [ $RC -eq 0 ]; then
    emit t1_f2p_helper_balances_repeats true ""
else
    emit t1_f2p_helper_balances_repeats false "$(tail -3 /tmp/g_balances.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# F2P: helper handles zero reg images without hang/crash
# ---------------------------------------------------------------------------
echo "--- F2P: helper_zero_reg_no_hang ---"
cat > /tmp/g_zero.py <<PYEOF
$COMMON_PY

helper_name, helper_cls = find_helper(DBD, BASE)
if helper_name is None:
    print("FAIL: no balance helper found")
    sys.exit(1)

inst = stub_instance(num_train=10)
inst.reg_infos = []
inst._reg_infos = []
fn = getattr(inst, helper_name, None)
if fn is None:
    fn = getattr(helper_cls, helper_name).__get__(inst, type(inst))

try:
    call_helper(fn, [], 10)
except Exception as e:
    print(f"FAIL: helper raised on empty reg_infos: {e!r}")
    sys.exit(1)
# Must not have populated image_data with reg entries
n_reg = sum(1 for k, v in inst.image_data.items() if getattr(v, "is_reg", False))
if n_reg != 0:
    print(f"FAIL: empty reg_infos resulted in {n_reg} reg entries in image_data")
    sys.exit(1)
print("PASS")
PYEOF
# Use timeout 15s to detect infinite loop
timeout 15 python3 /tmp/g_zero.py > /tmp/g_zero.log 2>&1
RC=$?
cat /tmp/g_zero.log
if [ $RC -eq 0 ]; then
    emit t1_f2p_helper_zero_reg_no_hang true ""
elif [ $RC -eq 124 ]; then
    emit t1_f2p_helper_zero_reg_no_hang false "timeout — likely infinite loop on zero reg images"
else
    emit t1_f2p_helper_zero_reg_no_hang false "$(tail -3 /tmp/g_zero.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# F2P: dedup — inline 'while n < num_train_images' pattern at most once
# ---------------------------------------------------------------------------
echo "--- F2P: init_dedup_single_balance_loop ---"
cat > /tmp/g_dedup.py <<PYEOF
import re, sys
src = open("/workspace/sd-scripts/library/train_util.py").read()
# Count both common balancing-loop spellings
n1 = len(re.findall(r"while\s+n\s*<\s*num_train_images", src))
# Heuristic: count 'first_loop = True' occurrences (the buggy duplicate marker)
n2 = src.count("first_loop = True") + src.count("first_loop=True")
# Allow at most ONE occurrence of each pattern (i.e., the dedup'd helper itself)
if n1 > 1:
    print(f"FAIL: 'while n < num_train_images' appears {n1} times — duplicate not removed")
    sys.exit(1)
if n2 > 1:
    print(f"FAIL: 'first_loop = True' appears {n2} times — duplicate not removed")
    sys.exit(1)
# Additionally: helper must exist (else nothing was extracted)
import ast
tree = ast.parse(src)
helper_found = False
HNAMES = ("register_regularization_images", "_register_regularization_images",
          "rebalance_regularization_images", "_rebalance_regularization_images",
          "_balance_reg_images", "balance_reg_images",
          "_balance_regularization_images", "balance_regularization_images")
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in HNAMES:
        helper_found = True
        break
if not helper_found:
    print("FAIL: no extracted balancing helper method present")
    sys.exit(1)
print(f"PASS (while_n={n1}, first_loop={n2}, helper_found=True)")
PYEOF
timeout 30 python3 /tmp/g_dedup.py > /tmp/g_dedup.log 2>&1
RC=$?
cat /tmp/g_dedup.log
if [ $RC -eq 0 ]; then
    emit t1_f2p_init_dedup_single_balance_loop true ""
else
    emit t1_f2p_init_dedup_single_balance_loop false "$(tail -3 /tmp/g_dedup.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# F2P: BaseDataset.filter_registered_images_by_orig_resolution accepts
# update_counts param and respects update_counts=False (suppresses count update)
# ---------------------------------------------------------------------------
echo "--- F2P: base_filter_accepts_update_counts ---"
cat > /tmp/g_param.py <<PYEOF
$COMMON_PY
import inspect

if BASE is None:
    print("FAIL: no BaseDataset")
    sys.exit(1)
fn = getattr(BASE, "filter_registered_images_by_orig_resolution", None)
if fn is None:
    print("FAIL: BaseDataset.filter_registered_images_by_orig_resolution missing")
    sys.exit(1)

sig = inspect.signature(fn)
if "update_counts" not in sig.parameters:
    print(f"FAIL: BaseDataset.filter_registered_images_by_orig_resolution signature lacks update_counts param: {sig}")
    sys.exit(1)
p = sig.parameters["update_counts"]
if p.default is not True:
    # Accept either True default or no default (less common); but require True default to maintain backward compat
    if p.default is inspect.Parameter.empty:
        print(f"FAIL: update_counts has no default — would break callers")
        sys.exit(1)
    # Don't insist on True specifically as long as defined; but warn.
    print(f"NOTE: update_counts default is {p.default!r}")

# Behavioral: build a stub BaseDataset-like instance and call with update_counts=False;
# update_dataset_image_counts must NOT fire.
inst = DBD.__new__(DBD)
inst.image_data = {}
inst.image_to_subset = {}
inst.subsets = []
inst.is_training_dataset = True
inst.num_train_images = 0
inst.num_reg_images = 0
inst.reg_infos = []
inst._reg_infos = []
inst.enable_bucket = False
inst.min_bucket_reso = 256
inst.max_bucket_reso = 1024
inst.bucket_reso_steps = 64
inst.bucket_no_upscale = False

calls = {"n": 0}
import types
def fake_update(self, *a, **kw):
    calls["n"] += 1
# Patch class-level
orig = BASE.update_dataset_image_counts
BASE.update_dataset_image_counts = fake_update
try:
    # Call BASE method directly bound to inst, with update_counts=False
    base_fn = BASE.filter_registered_images_by_orig_resolution
    try:
        base_fn(inst, update_counts=False)
    except Exception as e:
        # Some impls require image_data items; if it fails for non-update reasons we cannot judge
        # but if it didn't update counts before failing, that's fine
        pass
    n_false = calls["n"]
    calls["n"] = 0
    try:
        base_fn(inst, update_counts=True)
    except Exception:
        pass
    n_true = calls["n"]
finally:
    BASE.update_dataset_image_counts = orig

if n_false != 0:
    print(f"FAIL: update_counts=False still triggered {n_false} update calls")
    sys.exit(1)
if n_true < 1:
    print(f"FAIL: update_counts=True did NOT trigger update_dataset_image_counts (got {n_true})")
    sys.exit(1)
print(f"PASS (false_calls={n_false}, true_calls={n_true})")
PYEOF
timeout 30 python3 /tmp/g_param.py > /tmp/g_param.log 2>&1
RC=$?
cat /tmp/g_param.log
if [ $RC -eq 0 ]; then
    emit t1_f2p_base_filter_accepts_update_counts true ""
else
    emit t1_f2p_base_filter_accepts_update_counts false "$(tail -3 /tmp/g_param.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# F2P: end-to-end DB override invokes update_dataset_image_counts EXACTLY ONCE.
# This is the core "no double-call" behavioral discriminator.
# ---------------------------------------------------------------------------
echo "--- F2P: db_override_no_double_update ---"
cat > /tmp/g_once.py <<PYEOF
$COMMON_PY

if "filter_registered_images_by_orig_resolution" not in DBD.__dict__:
    print("FAIL: DreamBoothDataset does not override filter_registered_images_by_orig_resolution")
    sys.exit(1)

inst = stub_instance(num_train=10)
reg_infos = [(make_info(f"r{i}", 1), make_subset()) for i in range(3)]
inst.reg_infos = reg_infos
inst._reg_infos = reg_infos

calls = {"n": 0}
def fake_update(self, *a, **kw):
    calls["n"] += 1

orig_base = BASE.update_dataset_image_counts
BASE.update_dataset_image_counts = fake_update
# Also override on DBD if it has its own
orig_dbd = DBD.__dict__.get("update_dataset_image_counts")
if orig_dbd is not None:
    DBD.update_dataset_image_counts = fake_update

try:
    try:
        DBD.filter_registered_images_by_orig_resolution(inst)
    except TypeError as e:
        # Maybe override requires different sig — try with no args via bound call
        try:
            inst.filter_registered_images_by_orig_resolution()
        except Exception as e2:
            print(f"NOTE: override raised after partial execution: {e2!r}")
    except Exception as e:
        print(f"NOTE: override raised after partial execution: {e!r}")
finally:
    BASE.update_dataset_image_counts = orig_base
    if orig_dbd is not None:
        DBD.update_dataset_image_counts = orig_dbd

n = calls["n"]
if n == 0:
    print(f"FAIL: update_dataset_image_counts was never invoked (under-correction; counts would be stale)")
    sys.exit(1)
if n >= 2:
    print(f"FAIL: update_dataset_image_counts invoked {n} times — double-call still present")
    sys.exit(1)
print(f"PASS (invocations={n})")
PYEOF
timeout 60 python3 /tmp/g_once.py > /tmp/g_once.log 2>&1
RC=$?
cat /tmp/g_once.log
if [ $RC -eq 0 ]; then
    emit t1_f2p_db_override_no_double_update true ""
else
    emit t1_f2p_db_override_no_double_update false "$(tail -3 /tmp/g_once.log | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Compute reward
# ---------------------------------------------------------------------------
python3 <<'PYEOF' > /tmp/reward_calc 2>&1
import json
gates = []
with open("/logs/verifier/gates.json") as f:
    for line in f:
        line = line.strip()
        if line:
            gates.append(json.loads(line))

weights = {
    "t1_f2p_helper_balances_repeats": 0.30,
    "t1_f2p_helper_zero_reg_no_hang": 0.20,
    "t1_f2p_init_dedup_single_balance_loop": 0.15,
    "t1_f2p_base_filter_accepts_update_counts": 0.15,
    "t1_f2p_db_override_no_double_update": 0.20,
}

p2p_failed = False
for g in gates:
    if g["id"].startswith("p2p_") and not g["passed"]:
        p2p_failed = True

reward = 0.0
if not p2p_failed:
    for g in gates:
        if g["id"] in weights and g["passed"]:
            reward += weights[g["id"]]

print(f"{reward:.4f}")
PYEOF
REWARD=$(tail -1 /tmp/reward_calc)
if ! echo "$REWARD" | grep -qE '^[0-9]+\.[0-9]+$'; then
    REWARD="0.0000"
fi
printf "%.4f\n" "$REWARD" > /logs/verifier/reward.txt
echo "=== Final reward: $(cat /logs/verifier/reward.txt) ==="
cat /logs/verifier/gates.json

# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBscyAvd29ya3NwYWNlL3ZlbnYvYmluL3B5dGhvbjMgPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_6dd743e7 'py_compile_changed' 'cd /workspace/sd-scripts && /workspace/venv/bin/python3 -m py_compile library/train_util.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_base_filter_accepts_update_counts": 0.15, "t1_f2p_db_override_no_double_update": 0.2, "t1_f2p_helper_balances_repeats": 0.3, "t1_f2p_helper_zero_reg_no_hang": 0.2, "t1_f2p_init_dedup_single_balance_loop": 0.15}
P2P_GATING = ["p2p_module_imports"]
P2P_REGRESSION = ["p2p_upstream_6dd743e7"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----
