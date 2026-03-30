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
#      - deduplication logic present (may be in config_util.py or train_util.py)
#   3. library/train_util.py:
#      - skip_duplicate_bucketed_images param in dataset constructors
#      - unwrap_model_for_sampling helper defined with _orig_mod fallback
#   4. library/sdxl_original_unet.py:
#      - isinstance check uses _orig_mod unwrapping for compiled layers
#
# Scoring (90% behavioral, 10% structural):
#   Test  1:  0.15  BEHAVIORAL F2P  strategy_sd.py multi_resolution=True in is_disk_cached_latents_expected
#   Test  2:  0.10  BEHAVIORAL      strategy_sd.py load_latents_from_disk override (non-stub)
#   Test  3:  0.15  BEHAVIORAL F2P  strategy_sd.py cache_batch_latents passes multi_resolution=True
#   Test  4:  0.10  BEHAVIORAL      config_util.py skip_duplicate_bucketed_images in schema (runtime import)
#   Test  5:  0.05  STRUCTURAL      dedup logic in config_util.py or train_util.py (AST)
#   Test  6:  0.15  BEHAVIORAL F2P  config_util.py BaseDatasetParams skip_duplicate_bucketed_images field
#   Test  7:  0.10  BEHAVIORAL F2P  train_util.py dataset class accepts skip_duplicate_bucketed_images
#   Test  8:  0.10  BEHAVIORAL      train_util.py unwrap_model_for_sampling handles KeyError (mock call)
#   Test  9:  0.05  STRUCTURAL      sdxl_original_unet.py _orig_mod handling near isinstance (AST)
#   Test 10:  0.05  BEHAVIORAL P2P  upstream test suite (tests/library/)
#
# Behavioral total: Tests 1+2+3+4+6+7+8+10 = 0.15+0.10+0.15+0.10+0.15+0.10+0.10+0.05 = 0.90 (90%)
# Structural total: Tests 5+9 = 0.05+0.05 = 0.10 (10%)
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 2)))")
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1 (0.15): BEHAVIORAL F2P — strategy_sd.py is_disk_cached_latents_expected
#   Silver tier: monkeypatch base method, call, verify multi_resolution=True
#   Core bug: multi-resolution caching not delegated properly
# ═══════════════════════════════════════════════════════════════════
echo "=== Test 1/10: [BEHAVIORAL F2P] strategy_sd.py is_disk_cached_latents_expected multi_resolution=True ==="
T1=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
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
    nparams = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:nparams]
    strategy = SdSdxlLatentsCachingStrategy(*args)

    try:
        result = strategy.is_disk_cached_latents_expected((512, 512), "/tmp/test.npz", False, False)
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
echo "  Result: $T1"
if [ "$T1" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 2 (0.10): BEHAVIORAL — strategy_sd.py load_latents_from_disk override
#   Silver tier: import, verify method is overridden (not inherited),
#   non-trivial body (>=8 non-blank, non-comment lines). No AST.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 2/10: [BEHAVIORAL] strategy_sd.py load_latents_from_disk override ==="
T2=$(python3 << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    from library.strategy_base import LatentsCachingStrategy
    from library.strategy_sd import SdSdxlLatentsCachingStrategy

    if not hasattr(SdSdxlLatentsCachingStrategy, "load_latents_from_disk"):
        print("FAIL:method_not_found")
        sys.exit(0)

    base_method = getattr(LatentsCachingStrategy, "load_latents_from_disk", None)
    child_method = SdSdxlLatentsCachingStrategy.load_latents_from_disk

    # Verify method is overridden (not inherited from base)
    if base_method is not None and child_method is base_method:
        print("FAIL:not_overridden")
        sys.exit(0)

    # Verify non-trivial body (>=8 non-empty, non-comment, non-docstring lines)
    src = inspect.getsource(child_method)
    lines = [l.strip() for l in src.split('\n')
             if l.strip()
             and not l.strip().startswith('#')
             and not l.strip().startswith('"""')
             and not l.strip().startswith("'''")]
    if len(lines) < 8:
        print("FAIL:stub_too_short:" + str(len(lines)))
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
# TEST 3 (0.15): BEHAVIORAL F2P — strategy_sd.py cache_batch_latents
#   Silver tier: monkeypatch base method, call, verify multi_resolution=True
#   Core bug: cache_batch_latents doesn't pass multi_resolution=True
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 3/10: [BEHAVIORAL F2P] strategy_sd.py cache_batch_latents multi_resolution=True ==="
T3=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    import library.strategy_base as sb
    captured_kwargs = {}

    def mock_cache(self, *args, **kwargs):
        captured_kwargs.update(kwargs)
        return None

    sb.LatentsCachingStrategy._default_cache_batch_latents = mock_cache

    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    nparams = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:nparams]
    strategy = SdSdxlLatentsCachingStrategy(*args)

    try:
        strategy.cache_batch_latents(None, None, None, [], False, False, False)
    except TypeError:
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
if [ "$T3" = "PASS" ]; then add_reward 0.15; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 4 (0.10): BEHAVIORAL — config_util.py skip_duplicate_bucketed_images in schema
#   Silver tier: runtime import of config_util, search module-level dicts
#   for the "skip_duplicate_bucketed_images" key. No AST.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 4/10: [BEHAVIORAL] config_util.py skip_duplicate_bucketed_images in schema ==="
T4=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    import library.config_util as cu

    # Primary check: look for DATASET_ASCENDABLE_SCHEMA or similar named dicts
    found = False
    checked = []
    for name in dir(cu):
        upper = name.upper()
        if "ASCENDABLE" in upper or ("SCHEMA" in upper and "DATASET" in upper):
            val = getattr(cu, name)
            checked.append(name)
            if isinstance(val, dict) and "skip_duplicate_bucketed_images" in val:
                found = True
                break
            elif isinstance(val, (list, set, tuple)):
                if "skip_duplicate_bucketed_images" in val:
                    found = True
                    break

    if not found:
        # Fallback: check all module-level dicts containing "SCHEMA" or
        # beginning with DATASET in their name
        for name in dir(cu):
            if not name.startswith("_"):
                val = getattr(cu, name, None)
                if isinstance(val, dict) and "skip_duplicate_bucketed_images" in val:
                    checked.append(name)
                    found = True
                    break

    if found:
        print("PASS")
    else:
        print("FAIL:not_found_in_schema_dicts,checked=" + ",".join(checked))
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 5 (0.05): STRUCTURAL — deduplication logic
#   Bronze tier: AST check — requires ALL THREE within the same function:
#   (1) skip_duplicate_bucketed_images conditional check
#   (2) tracking data structure with >=2 operations (add/update + membership test)
#   (3) removal from data (pop/del/comprehension)
#   Checks BOTH config_util.py and train_util.py (agent may place logic in either).
#   AST justified: prepare_dataset() requires full dataset infra to call.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 5/10: [STRUCTURAL] deduplication logic (config_util.py or train_util.py) ==="
T5=$(python3 << 'PYEOF'
import sys, ast

def check_function_for_dedup(func_node):
    has_skip_check = False
    has_tracking_ops = 0
    has_removal = False

    for node in ast.walk(func_node):
        if isinstance(node, ast.Attribute) and node.attr == "skip_duplicate_bucketed_images":
            has_skip_check = True
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("add", "update", "append"):
                has_tracking_ops += 1
        if isinstance(node, ast.Compare):
            for op in node.ops:
                if isinstance(op, (ast.In, ast.NotIn)):
                    has_tracking_ops += 1
        # Removal via pop/remove/discard
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("pop", "remove", "discard"):
                has_removal = True
        # Removal via del x[key]
        if isinstance(node, ast.Delete):
            for target in node.targets:
                if isinstance(target, ast.Subscript):
                    has_removal = True
        # Removal via dict/list/set comprehension reassignment
        if isinstance(node, ast.Assign) and isinstance(node.value, (ast.DictComp, ast.ListComp, ast.SetComp)):
            has_removal = True

    return has_skip_check and has_tracking_ops >= 2 and has_removal

def check_file(filepath):
    try:
        with open(filepath) as f:
            tree = ast.parse(f.read())
    except (FileNotFoundError, SyntaxError):
        return False
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if check_function_for_dedup(node):
                return True
    return False

if check_file("/workspace/sd-scripts/library/config_util.py") or \
   check_file("/workspace/sd-scripts/library/train_util.py"):
    print("PASS")
else:
    print("FAIL:incomplete_dedup_logic")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 6 (0.15): BEHAVIORAL F2P — config_util.py BaseDatasetParams
#   Silver tier: import config_util, verify BaseDatasetParams dataclass has
#   skip_duplicate_bucketed_images field with a default value
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 6/10: [BEHAVIORAL F2P] BaseDatasetParams has skip_duplicate_bucketed_images ==="
T6=$(python3 << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    from library.config_util import BaseDatasetParams
    import dataclasses

    if not dataclasses.is_dataclass(BaseDatasetParams):
        # Fallback: check if it has the attribute at class level
        if hasattr(BaseDatasetParams, "skip_duplicate_bucketed_images"):
            print("PASS")
        else:
            print("FAIL:not_dataclass_and_no_attr")
        sys.exit(0)

    field_names = {f.name for f in dataclasses.fields(BaseDatasetParams)}
    if "skip_duplicate_bucketed_images" not in field_names:
        print("FAIL:field_not_in_dataclass")
        sys.exit(0)

    for f in dataclasses.fields(BaseDatasetParams):
        if f.name == "skip_duplicate_bucketed_images":
            if f.default is not dataclasses.MISSING or f.default_factory is not dataclasses.MISSING:
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
# TEST 7 (0.10): BEHAVIORAL F2P — train_util.py dataset class constructor
#   Silver tier: import train_util, find a dataset class whose __init__
#   accepts skip_duplicate_bucketed_images, verify it stores as self.attr
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 7/10: [BEHAVIORAL F2P] train_util.py dataset class accepts skip_duplicate_bucketed_images ==="
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
                src = inspect.getsource(cls.__init__)
                if "self.skip_duplicate_bucketed_images" in src:
                    found_attr = True
                break
        except (ValueError, TypeError, OSError):
            continue

    if found_param and found_attr:
        print("PASS")
    elif found_param:
        print("FAIL:param_in_" + str(found_class) + "_but_not_stored_as_self_attr")
    else:
        print("FAIL:no_dataset_class_has_skip_duplicate_param")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 8 (0.10): BEHAVIORAL — train_util.py unwrap_model_for_sampling
#   Silver tier: import function, call with mock accelerator to verify:
#   (a) it delegates to accelerator.unwrap_model in the normal case
#   (b) it catches KeyError and falls back when _orig_mod issue occurs
#   Anti-stub: tracking accelerator detects functions that don't delegate.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 8/10: [BEHAVIORAL] unwrap_model_for_sampling handles KeyError ==="
T8=$(python3 << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")

try:
    import library.train_util as tu

    func = getattr(tu, "unwrap_model_for_sampling", None)
    if func is None:
        print("FAIL:function_not_found")
        sys.exit(0)

    if not callable(func):
        print("FAIL:not_callable")
        sys.exit(0)

    sig = inspect.signature(func)
    if len(sig.parameters) < 1:
        print("FAIL:no_parameters")
        sys.exit(0)

    # --- Normal path: verify it actually calls accelerator.unwrap_model ---
    class TrackingAccelerator:
        def __init__(self):
            self.called = False
        def unwrap_model(self, m, **kw):
            self.called = True
            return m

    class SimpleModel:
        pass

    track_acc = TrackingAccelerator()
    simple = SimpleModel()

    normal_result = None
    normal_ok = False
    for args in [(track_acc, simple), (simple, track_acc), (track_acc, simple, False)]:
        try:
            normal_result = func(*args)
            normal_ok = True
            break
        except TypeError:
            continue
        except Exception:
            normal_ok = True
            break

    if not normal_ok:
        print("FAIL:could_not_call_normal_path")
        sys.exit(0)

    if not track_acc.called:
        print("FAIL:doesnt_call_unwrap_model")
        sys.exit(0)

    # Verify it returns the unwrapped result (not ignoring the return value)
    if normal_result is not simple:
        print("FAIL:doesnt_return_unwrapped_model")
        sys.exit(0)

    # --- Error path: verify KeyError from _orig_mod is caught ---
    class FailAccelerator:
        def unwrap_model(self, m, **kw):
            raise KeyError("_orig_mod")

    class CompiledModel:
        class _Inner:
            pass
        _orig_mod = _Inner()

    fail_acc = FailAccelerator()
    compiled = CompiledModel()

    error_result = None
    error_ok = False
    for args in [(fail_acc, compiled), (compiled, fail_acc), (fail_acc, compiled, False)]:
        try:
            error_result = func(*args)
            error_ok = True
            break
        except TypeError:
            continue
        except KeyError:
            print("FAIL:keyerror_not_caught")
            sys.exit(0)
        except Exception:
            error_ok = True
            break

    if not error_ok:
        print("FAIL:could_not_call_error_path")
        sys.exit(0)

    if error_result is not None:
        print("PASS")
    else:
        print("FAIL:returned_none_on_error_path")
except ImportError as e:
    print(f"FAIL:import_error:{e}")
except Exception as e:
    print(f"FAIL:exception:{e}")
PYEOF
)
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 9 (0.05): STRUCTURAL — sdxl_original_unet.py isinstance _orig_mod
#   Bronze tier: AST — checks that _orig_mod handling (hasattr, getattr,
#   or direct attribute access) exists in a function that also contains
#   isinstance type checks. Accepts multiple valid patterns.
#   AST justified: call_module() requires full UNet layer infrastructure.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 9/10: [STRUCTURAL] sdxl_original_unet.py isinstance + _orig_mod ==="
T9=$(python3 << 'PYEOF'
import sys, ast

with open("/workspace/sd-scripts/library/sdxl_original_unet.py") as f:
    source = f.read()

tree = ast.parse(source)

found_guarded = False
for node in ast.walk(tree):
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        has_isinstance = False
        has_orig_mod = False

        for child in ast.walk(node):
            if isinstance(child, ast.Call):
                if isinstance(child.func, ast.Name) and child.func.id == "isinstance":
                    has_isinstance = True
            if isinstance(child, ast.Attribute) and child.attr == "_orig_mod":
                has_orig_mod = True
            if isinstance(child, ast.Constant) and child.value == "_orig_mod":
                has_orig_mod = True

        if has_isinstance and has_orig_mod:
            found_guarded = True
            break

if found_guarded:
    print("PASS")
else:
    print("FAIL:no_orig_mod_handling_near_isinstance")
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.05; fi

# ═══════════════════════════════════════════════════════════════════
# TEST 10 (0.05): BEHAVIORAL P2P — upstream test suite
#   Run CPU-safe upstream tests from tests/library/ to verify no
#   regressions introduced by the agent's changes.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test 10/10: [BEHAVIORAL P2P] upstream test suite (tests/library/) ==="
cd /workspace/sd-scripts
if [ -d "tests/library" ] && ls tests/library/test_*.py 1>/dev/null 2>&1; then
    P2P_RESULT=$(python3 -m pytest tests/library/ --timeout=60 -q 2>&1)
    P2P_EXIT=$?
    echo "  pytest exit code: $P2P_EXIT"
    echo "$P2P_RESULT" | tail -5
    if [ $P2P_EXIT -eq 0 ]; then
        add_reward 0.05
        echo "  Result: PASS"
    else
        echo "  Result: FAIL:upstream_tests_failed"
    fi
else
    echo "  Result: SKIP:no_upstream_tests_found"
fi

# ═══════════════════════════════════════════════════════════════════
# FINAL SCORE
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "==============================="
FINAL_REWARD=$(python3 -c "print(min(1.0, round($REWARD, 2)))")
echo "Final reward: $FINAL_REWARD"
echo "$FINAL_REWARD" > "$REWARD_FILE"
echo "Written to $REWARD_FILE"
