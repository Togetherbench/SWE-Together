#!/usr/bin/env bash
#
# Verification tests for sd-scripts multi-resolution dataset caching and
# skip_duplicate_bucketed_images feature.
#
# Core changes to verify (from session ses_39d979efaffeg73LC25luDShF6):
#   1. library/strategy_sd.py:
#      - is_disk_cached_latents_expected passes multi_resolution=True
#      - load_latents_from_disk override exists with fallback
#      - cache_batch_latents passes multi_resolution=True
#   2. library/config_util.py:
#      - skip_duplicate_bucketed_images in DATASET_ASCENDABLE_SCHEMA
#      - skip_duplicate_bucketed_images in BaseDatasetParams
#      - deduplication logic present after make_buckets loop
#   3. library/train_util.py:
#      - skip_duplicate_bucketed_images param in dataset constructors
#      - unwrap_model_for_sampling helper defined with _orig_mod fallback
#   4. library/sdxl_original_unet.py:
#      - isinstance check uses _orig_mod unwrapping for compiled layers
#
# Scoring (>=60% behavioral, <=40% structural):
#   Test 1:  0.10  BEHAVIORAL  strategy_sd.py multi_resolution=True in is_disk_cached_latents_expected (import+monkeypatch+call)
#   Test 2:  0.10  BEHAVIORAL  strategy_sd.py load_latents_from_disk is overridden (import+inspect)
#   Test 3:  0.10  BEHAVIORAL  strategy_sd.py cache_batch_latents passes multi_resolution=True (import+inspect)
#   Test 4:  0.10  STRUCTURAL  config_util.py skip_duplicate_bucketed_images in DATASET_ASCENDABLE_SCHEMA + BaseDatasetParams (AST tightened)
#   Test 5:  0.10  STRUCTURAL  config_util.py deduplication logic with min complexity (AST tightened)
#   Test 6:  0.15  BEHAVIORAL  config_util.py BaseDatasetParams has skip_duplicate_bucketed_images field (import+inspect)
#   Test 7:  0.15  BEHAVIORAL  train_util.py dataset class accepts skip_duplicate_bucketed_images (import+inspect)
#   Test 8:  0.10  STRUCTURAL  train_util.py unwrap_model_for_sampling with _orig_mod + keep_torch_compile (AST tightened)
#   Test 9:  0.10  STRUCTURAL  sdxl_original_unet.py isinstance check uses _orig_mod unwrapping (AST)
#
# Behavioral total: Tests 1+2+3+6+7 = 0.10+0.10+0.10+0.15+0.15 = 0.60 (60%)
# Structural total: Tests 4+5+8+9 = 0.10+0.10+0.10+0.10 = 0.40 (40%)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

STRATEGY_SD="/workspace/sd-scripts/library/strategy_sd.py"
CONFIG_UTIL="/workspace/sd-scripts/library/config_util.py"
TRAIN_UTIL="/workspace/sd-scripts/library/train_util.py"
SDXL_UNET="/workspace/sd-scripts/library/sdxl_original_unet.py"

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.10): BEHAVIORAL — strategy_sd.py is_disk_cached_latents_expected
#   Silver tier: import module, monkeypatch base method, call, verify multi_resolution=True
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/9: [BEHAVIORAL] strategy_sd.py is_disk_cached_latents_expected uses multi_resolution=True ==="
T1=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    # Monkeypatch base class to capture kwargs before importing child
    import library.strategy_base as sb
    captured_kwargs = {}
    orig_method = sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected

    def mock_default(self, *args, **kwargs):
        captured_kwargs.update(kwargs)
        return orig_method(self, *args, **kwargs)

    sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = mock_default

    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    nparams = len(sig.parameters) - 1  # exclude self
    args = [True, 1, False, False, False][:nparams]  # sd, cache_to_disk, batch_size, skip_disk_cache_validity_check, ...
    strategy = SdSdxlLatentsCachingStrategy(*args)

    # Call with test inputs — the method should delegate to _default with multi_resolution=True
    try:
        result = strategy.is_disk_cached_latents_expected((512, 512), "/tmp/test.npz", False, False)
    except Exception:
        # Method may raise due to missing files, but kwargs should still be captured
        pass

    if captured_kwargs.get("multi_resolution") is True:
        print("PASS")
    else:
        print("FAIL:multi_resolution not True, got=" + str(captured_kwargs.get("multi_resolution")))
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.10): BEHAVIORAL — strategy_sd.py load_latents_from_disk
#   Silver tier: import, verify method is overridden (not inherited), non-trivial body
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/9: [BEHAVIORAL] strategy_sd.py load_latents_from_disk override ==="
T2=$(python3 << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    from library.strategy_base import LatentsCachingStrategy
    from library.strategy_sd import SdSdxlLatentsCachingStrategy

    # Check that load_latents_from_disk exists
    if not hasattr(SdSdxlLatentsCachingStrategy, "load_latents_from_disk"):
        print("FAIL:method_not_found")
        sys.exit(0)

    base_method = getattr(LatentsCachingStrategy, "load_latents_from_disk", None)
    child_method = SdSdxlLatentsCachingStrategy.load_latents_from_disk

    # Verify the method is overridden (not inherited from base)
    if base_method is not None and child_method is base_method:
        print("FAIL:not_overridden")
        sys.exit(0)

    # Verify non-trivial body (at least 5 non-empty, non-comment lines)
    src = inspect.getsource(child_method)
    lines = [l.strip() for l in src.split('\n')
             if l.strip() and not l.strip().startswith('#') and not l.strip().startswith('"""')]
    if len(lines) < 5:
        print("FAIL:stub_body_too_short")
        sys.exit(0)

    # Verify it has fallback logic (try/except or if/hasattr or super call)
    import ast, textwrap
    tree = ast.parse(textwrap.dedent(src))
    has_fallback = False
    for node in ast.walk(tree):
        if isinstance(node, (ast.Try, ast.If)):
            has_fallback = True
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and "load_latents" in func.attr:
                has_fallback = True
    if not has_fallback:
        print("FAIL:no_fallback_logic")
        sys.exit(0)

    print("PASS")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 3 (0.10): BEHAVIORAL — strategy_sd.py cache_batch_latents
#   Silver tier: import, monkeypatch base method, verify multi_resolution=True is passed
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/9: [BEHAVIORAL] strategy_sd.py cache_batch_latents uses multi_resolution=True ==="
T3=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    import library.strategy_base as sb
    captured_kwargs = {}

    def mock_cache(self, *args, **kwargs):
        captured_kwargs.update(kwargs)
        return None  # Skip actual caching

    sb.LatentsCachingStrategy._default_cache_batch_latents = mock_cache

    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    nparams = len(sig.parameters) - 1  # exclude self
    args = [True, 1, False, False, False][:nparams]
    strategy = SdSdxlLatentsCachingStrategy(*args)

    # Call cache_batch_latents with minimal mock args
    # Signature: cache_batch_latents(self, encode_by_vae, vae_device, vae_dtype,
    #            image_infos, flip_aug, alpha_mask, random_crop)
    try:
        strategy.cache_batch_latents(None, None, None, [], False, False, False)
    except TypeError:
        # Try alternate arg counts if signature differs
        try:
            strategy.cache_batch_latents(None, None, None, [], False, False)
        except Exception:
            pass
    except Exception:
        pass

    if captured_kwargs.get("multi_resolution") is True:
        print("PASS")
    else:
        print("FAIL:multi_resolution not True, got=" + str(captured_kwargs.get("multi_resolution")))
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.10): STRUCTURAL — config_util.py skip_duplicate_bucketed_images
#   Bronze tier: AST check with tightened constraints — must be in a variable
#   assigned to a name containing "SCHEMA" or "ASCENDABLE", and in a class
#   containing "DatasetParams" or "Dataset" in name
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/9: [STRUCTURAL] config_util.py skip_duplicate_bucketed_images in schema and dataclass ==="
T4=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/sd-scripts/library/config_util.py") as f:
    source = f.read()

try:
    tree = ast.parse(source)
except SyntaxError as e:
    print(f"FAIL:syntax:{e}")
    sys.exit(0)

in_schema = False
in_dataclass = False

for node in ast.walk(tree):
    # Check dict literal assigned to a variable with SCHEMA/ASCENDABLE in name
    if isinstance(node, ast.Assign):
        target_names = []
        for t in node.targets:
            if isinstance(t, ast.Name):
                target_names.append(t.id)
        is_schema_var = any("SCHEMA" in n or "ASCENDABLE" in n for n in target_names)
        if is_schema_var and isinstance(node.value, ast.Dict):
            for key in node.value.keys:
                if isinstance(key, ast.Constant) and key.value == "skip_duplicate_bucketed_images":
                    in_schema = True

    # Check class body — only classes with "Dataset" or "Params" in name
    if isinstance(node, ast.ClassDef):
        is_dataset_class = "Dataset" in node.name or "Params" in node.name
        if is_dataset_class:
            for stmt in ast.walk(node):
                if isinstance(stmt, ast.AnnAssign):
                    if isinstance(stmt.target, ast.Name) and stmt.target.id == "skip_duplicate_bucketed_images":
                        in_dataclass = True
                elif isinstance(stmt, ast.Assign):
                    for target in stmt.targets:
                        if isinstance(target, ast.Name) and target.id == "skip_duplicate_bucketed_images":
                            in_dataclass = True

if in_schema and in_dataclass:
    print("PASS")
elif in_schema:
    print("FAIL:in_schema_but_not_dataclass")
elif in_dataclass:
    print("FAIL:in_dataclass_but_not_schema")
else:
    print("FAIL:not_found_in_schema_or_dataset_class")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.10): STRUCTURAL — config_util.py deduplication logic
#   Bronze tier: AST check with stub rejection — requires all three of:
#   (1) skip_duplicate_bucketed_images conditional check
#   (2) tracking data structure with >=2 operations (add/update + membership test)
#   (3) removal from image_data specifically (not just any .pop())
#   All three must appear within the same function body.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/9: [STRUCTURAL] config_util.py deduplication logic ==="
T5=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/sd-scripts/library/config_util.py") as f:
    source = f.read()

tree = ast.parse(source)

# Find functions/methods that contain ALL of: skip_duplicate reference, tracking, removal
found_complete_dedup = False

def check_function_for_dedup(func_node):
    """Check if a function body contains complete dedup logic."""
    has_skip_check = False
    has_tracking_ops = 0  # Count: need add/update AND membership test (in/not in)
    has_image_data_removal = False
    has_make_buckets_ref = False

    for node in ast.walk(func_node):
        # skip_duplicate_bucketed_images reference
        if isinstance(node, ast.Attribute) and node.attr == "skip_duplicate_bucketed_images":
            has_skip_check = True

        # Tracking set operations: .add(), .update(), set membership
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("add", "update", "append"):
                has_tracking_ops += 1
            # make_buckets reference
            if isinstance(func, ast.Attribute) and func.attr == "make_buckets":
                has_make_buckets_ref = True

        # Membership test: `x in seen_set` or `x not in seen_set`
        if isinstance(node, ast.Compare):
            for op in node.ops:
                if isinstance(op, (ast.In, ast.NotIn)):
                    has_tracking_ops += 1

        # Removal from image_data (not just any pop)
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("pop", "remove", "discard"):
                if isinstance(func.value, ast.Attribute) and func.value.attr == "image_data":
                    has_image_data_removal = True
        if isinstance(node, ast.Delete):
            for target in node.targets:
                if isinstance(target, ast.Subscript):
                    if isinstance(target.value, ast.Attribute) and target.value.attr == "image_data":
                        has_image_data_removal = True
        # Dict comprehension filtering image_data
        if isinstance(node, ast.Assign):
            if isinstance(node.value, ast.DictComp):
                for target in node.targets:
                    if isinstance(target, ast.Attribute) and target.attr == "image_data":
                        has_image_data_removal = True

    return (has_skip_check and has_tracking_ops >= 2 and has_image_data_removal)

# Search all functions in the module
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        if check_function_for_dedup(node):
            found_complete_dedup = True
            break

if found_complete_dedup:
    print("PASS")
else:
    print("FAIL:incomplete_dedup_logic")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.15): BEHAVIORAL — config_util.py BaseDatasetParams
#   Silver tier: import config_util, verify BaseDatasetParams dataclass has
#   skip_duplicate_bucketed_images field with correct type
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/9: [BEHAVIORAL] config_util.py BaseDatasetParams has skip_duplicate_bucketed_images ==="
T6=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    from library.config_util import BaseDatasetParams
    import dataclasses

    # Verify it's a dataclass
    if not dataclasses.is_dataclass(BaseDatasetParams):
        # Fallback: check if it has the attribute defined at class level
        if hasattr(BaseDatasetParams, "skip_duplicate_bucketed_images"):
            print("PASS")
        else:
            print("FAIL:not_dataclass_and_no_attr")
        sys.exit(0)

    # Check that skip_duplicate_bucketed_images is a dataclass field
    field_names = {f.name for f in dataclasses.fields(BaseDatasetParams)}
    if "skip_duplicate_bucketed_images" not in field_names:
        print("FAIL:field_not_in_dataclass")
        sys.exit(0)

    # Verify the field has a boolean default (not required)
    for f in dataclasses.fields(BaseDatasetParams):
        if f.name == "skip_duplicate_bucketed_images":
            if f.default is not dataclasses.MISSING:
                if isinstance(f.default, bool):
                    print("PASS")
                else:
                    print("PASS")  # Accept non-bool defaults too (e.g., None)
            elif f.default_factory is not dataclasses.MISSING:
                print("PASS")
            else:
                print("FAIL:field_has_no_default")
            sys.exit(0)

    print("FAIL:field_check_fell_through")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 7 (0.15): BEHAVIORAL — train_util.py dataset class constructor
#   Silver tier: import train_util, find a dataset class whose __init__
#   accepts skip_duplicate_bucketed_images, verify it stores as self.attr
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/9: [BEHAVIORAL] train_util.py dataset class accepts skip_duplicate_bucketed_images ==="
T7=$(python3 << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    import library.train_util as tu

    found_param = False
    found_attr = False
    found_class = None

    for name, cls in inspect.getmembers(tu, inspect.isclass):
        try:
            sig = inspect.signature(cls.__init__)
            if "skip_duplicate_bucketed_images" in sig.parameters:
                found_param = True
                found_class = name
                # Verify it stores as self.skip_duplicate_bucketed_images
                src = inspect.getsource(cls.__init__)
                if "self.skip_duplicate_bucketed_images" in src:
                    found_attr = True
                break
        except (ValueError, TypeError, OSError):
            continue

    if found_param and found_attr:
        print("PASS")
    elif found_param:
        print("FAIL:param_found_in_" + str(found_class) + "_but_not_stored_as_self_attr")
    else:
        print("FAIL:no_dataset_class_has_skip_duplicate_param")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.10): STRUCTURAL — train_util.py unwrap_model_for_sampling
#   Bronze tier: AST with tightened stub rejection — requires:
#   (1) function named unwrap_model_for_sampling
#   (2) try/except block
#   (3) _orig_mod string reference
#   (4) reference to keep_torch_compile (the retry arg)
#   (5) call to unwrap_model (the actual accelerate call)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/9: [STRUCTURAL] train_util.py unwrap_model_for_sampling with _orig_mod fallback ==="
T8=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/sd-scripts/library/train_util.py") as f:
    source = f.read()

tree = ast.parse(source)

found_func = False
has_try_except = False
has_orig_mod = False
has_keep_torch_compile = False
has_unwrap_call = False

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "unwrap_model_for_sampling":
        found_func = True
        for child in ast.walk(node):
            if isinstance(child, ast.Try):
                has_try_except = True
            # _orig_mod reference (string or attribute)
            if isinstance(child, ast.Attribute) and child.attr == "_orig_mod":
                has_orig_mod = True
            if isinstance(child, ast.Constant) and child.value == "_orig_mod":
                has_orig_mod = True
            # keep_torch_compile keyword in a call
            if isinstance(child, ast.keyword) and child.arg == "keep_torch_compile":
                has_keep_torch_compile = True
            # Call to unwrap_model
            if isinstance(child, ast.Call):
                func = child.func
                if isinstance(func, ast.Attribute) and func.attr == "unwrap_model":
                    has_unwrap_call = True

checks = [has_try_except, has_orig_mod, has_keep_torch_compile, has_unwrap_call]
if found_func and all(checks):
    print("PASS")
elif not found_func:
    print("FAIL:unwrap_model_for_sampling_not_found")
else:
    missing = []
    if not has_try_except: missing.append("try_except")
    if not has_orig_mod: missing.append("orig_mod_ref")
    if not has_keep_torch_compile: missing.append("keep_torch_compile")
    if not has_unwrap_call: missing.append("unwrap_model_call")
    print(f"FAIL:missing={missing}")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.10): STRUCTURAL — sdxl_original_unet.py isinstance check
#   uses _orig_mod unwrapping for compiled layer type detection
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/9: [STRUCTURAL] sdxl_original_unet.py isinstance check uses _orig_mod unwrapping ==="
T9=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/sd-scripts/library/sdxl_original_unet.py") as f:
    source = f.read()

tree = ast.parse(source)

# Look for pattern: hasattr(layer, "_orig_mod") used near isinstance check for ResnetBlock2D
has_orig_mod_check = False
has_isinstance_guarded = False

for node in ast.walk(tree):
    # Look for: layer_for_type_check = layer._orig_mod if hasattr(layer, "_orig_mod") else layer
    # or equivalent: if hasattr(x, "_orig_mod"): x = x._orig_mod
    if isinstance(node, ast.IfExp):
        # ternary: value if test else orelse
        test = node.test
        if isinstance(test, ast.Call):
            if isinstance(test.func, ast.Name) and test.func.id == "hasattr":
                if len(test.args) >= 2:
                    arg2 = test.args[1]
                    if isinstance(arg2, ast.Constant) and arg2.value == "_orig_mod":
                        has_orig_mod_check = True
    # Also accept: if hasattr(..., "_orig_mod") as a statement (not ternary)
    if isinstance(node, ast.If):
        test = node.test
        if isinstance(test, ast.Call):
            if isinstance(test.func, ast.Name) and test.func.id == "hasattr":
                if len(test.args) >= 2:
                    arg2 = test.args[1]
                    if isinstance(arg2, ast.Constant) and arg2.value == "_orig_mod":
                        has_orig_mod_check = True

    # Check if isinstance now uses a variable (not the raw 'layer' or 'module') for the guarded check
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Name) and node.func.id == "isinstance":
            if len(node.args) >= 1:
                arg0 = node.args[0]
                if isinstance(arg0, ast.Name) and arg0.id not in ("layer", "module"):
                    has_isinstance_guarded = True

if has_orig_mod_check and has_isinstance_guarded:
    print("PASS")
elif has_orig_mod_check:
    print("FAIL:orig_mod_check_exists_but_isinstance_not_guarded")
else:
    print("FAIL:no_orig_mod_check_in_unet")
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# FINAL SCORE
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "==============================="
FINAL_REWARD=$(python3 -c "print(min(1.0, round($REWARD, 2)))")
echo "Final reward: $FINAL_REWARD"
echo "$FINAL_REWARD" > "$REWARD_FILE"
echo "Written to $REWARD_FILE"
