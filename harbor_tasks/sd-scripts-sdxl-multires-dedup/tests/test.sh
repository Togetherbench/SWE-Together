#!/usr/bin/env bash
#
# Verification tests for sd-scripts multi-resolution dataset caching and
# skip_duplicate_bucketed_images feature.
#
# Critical fix: use venv python explicitly — bare 'python3' resolves to
# /usr/bin/python3 (system) which lacks numpy/torch/accelerate/etc.
#
# Scoring (89% behavioral, 11% structural):
#   T1  0.03  STRUCTURAL  multi_resolution kwarg in strategy_sd.py
#   T2  0.10  BEHAVIORAL  is_disk_cached_latents_expected multi_resolution=True (512x512)
#   T3  0.08  BEHAVIORAL  is_disk_cached_latents_expected multi_resolution=True (1024x1024)
#   T4  0.10  BEHAVIORAL  cache_batch_latents multi_resolution=True
#   T5  0.08  BEHAVIORAL  load_latents_from_disk overridden + non-trivial body
#   T6  0.10  BEHAVIORAL  BaseDatasetParams skip_duplicate_bucketed_images field
#   T7  0.08  BEHAVIORAL  skip_duplicate_bucketed_images in schema dict
#   T8  0.03  STRUCTURAL  dedup logic AST (tracking + removal + conditional)
#   T9  0.08  BEHAVIORAL  DreamBoothDataset accepts + stores skip_duplicate
#   T10 0.08  BEHAVIORAL  FineTuningDataset or ControlNetDataset accepts it
#   T11 0.03  STRUCTURAL  unwrap_model_for_sampling AST (try/except + _orig_mod)
#   T12 0.08  BEHAVIORAL  unwrap_model_for_sampling normal path
#   T13 0.08  BEHAVIORAL  unwrap_model_for_sampling KeyError path
#   T14 0.02  STRUCTURAL  _orig_mod + isinstance in sdxl_original_unet.py
#   T15 0.03  BEHAVIORAL  upstream test suite P2P
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

# Use venv python for all imports — system python lacks ML packages
PYTHON=/workspace/venv/bin/python3

REWARD=0.0

add_reward() {
    REWARD=$(awk "BEGIN{r=$REWARD+$1; if(r>1.0) r=1.0; printf \"%.2f\", r}")
}

# ═══════════════════════════════════════════════════════════════════
# T1 (0.03): STRUCTURAL — multi_resolution kwarg in strategy_sd.py
#   Grep check: multi_resolution=True appears in strategy_sd.py
# ═══════════════════════════════════════════════════════════════════
echo "=== T1/15: [STRUCTURAL] multi_resolution kwarg in strategy_sd.py ==="
if grep -qE 'multi_resolution\s*=\s*True' /workspace/sd-scripts/library/strategy_sd.py 2>/dev/null; then
    echo "  PASS"
    add_reward 0.03
else
    echo "  FAIL: multi_resolution=True not found in strategy_sd.py"
fi

# ═══════════════════════════════════════════════════════════════════
# T2 (0.10): BEHAVIORAL — is_disk_cached_latents_expected multi_resolution=True (512x512)
#   Monkeypatch base method, call with 512x512, verify multi_resolution=True passed
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T2/15: [BEHAVIORAL] is_disk_cached_latents_expected multi_resolution=True (512x512) ==="
T2=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.strategy_base as sb
    captured = {}
    orig = sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected
    def mock(self, *a, **kw):
        captured.update(kw)
        return orig(self, *a, **kw)
    sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = mock
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    n = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:n]
    s = SdSdxlLatentsCachingStrategy(*args)
    try:
        s.is_disk_cached_latents_expected((512, 512), "/tmp/test512.npz", False, False)
    except Exception:
        pass
    print("PASS" if captured.get("multi_resolution") is True else "FAIL:not_true,got=" + str(captured.get("multi_resolution")))
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T2"
if [ "$T2" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# T3 (0.08): BEHAVIORAL — is_disk_cached_latents_expected multi_resolution=True (1024x1024)
#   Same test, different resolution — catches hardcoded-for-one-size solutions
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T3/15: [BEHAVIORAL] is_disk_cached_latents_expected multi_resolution=True (1024x1024) ==="
T3=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.strategy_base as sb
    captured = {}
    orig = sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected
    def mock(self, *a, **kw):
        captured.update(kw)
        return orig(self, *a, **kw)
    sb.LatentsCachingStrategy._default_is_disk_cached_latents_expected = mock
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    n = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:n]
    s = SdSdxlLatentsCachingStrategy(*args)
    try:
        s.is_disk_cached_latents_expected((1024, 1024), "/tmp/test1024.npz", False, False)
    except Exception:
        pass
    print("PASS" if captured.get("multi_resolution") is True else "FAIL:not_true,got=" + str(captured.get("multi_resolution")))
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T3"
if [ "$T3" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T4 (0.10): BEHAVIORAL — cache_batch_latents passes multi_resolution=True
#   Monkeypatch base _default_cache_batch_latents, call, verify kwarg
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T4/15: [BEHAVIORAL] cache_batch_latents multi_resolution=True ==="
T4=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.strategy_base as sb
    captured = {}
    def mock_cache(self, *a, **kw):
        captured.update(kw)
        return None
    sb.LatentsCachingStrategy._default_cache_batch_latents = mock_cache
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    import inspect
    sig = inspect.signature(SdSdxlLatentsCachingStrategy.__init__)
    n = len(sig.parameters) - 1
    args = [True, 1, False, False, False][:n]
    s = SdSdxlLatentsCachingStrategy(*args)
    # Try different arg counts to handle signature variations
    for call_args in [
        (None, None, None, [], False, False, False),
        (None, None, None, [], False, False),
        (None, None, [], False, False),
    ]:
        try:
            s.cache_batch_latents(*call_args)
            break
        except TypeError:
            continue
        except Exception:
            break
    print("PASS" if captured.get("multi_resolution") is True else "FAIL:not_true,got=" + str(captured.get("multi_resolution")))
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T4"
if [ "$T4" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# T5 (0.08): BEHAVIORAL — load_latents_from_disk overridden + non-trivial body
#   Verify method is overridden (not inherited) and has ≥8 meaningful lines
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T5/15: [BEHAVIORAL] load_latents_from_disk override + non-trivial body ==="
T5=$($PYTHON << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    from library.strategy_base import LatentsCachingStrategy
    from library.strategy_sd import SdSdxlLatentsCachingStrategy
    if not hasattr(SdSdxlLatentsCachingStrategy, "load_latents_from_disk"):
        print("FAIL:method_not_found")
        sys.exit(0)
    base = getattr(LatentsCachingStrategy, "load_latents_from_disk", None)
    child = SdSdxlLatentsCachingStrategy.load_latents_from_disk
    if base is not None and child is base:
        print("FAIL:not_overridden")
        sys.exit(0)
    src = inspect.getsource(child)
    lines = [l.strip() for l in src.split('\n')
             if l.strip()
             and not l.strip().startswith('#')
             and not l.strip().startswith('"""')
             and not l.strip().startswith("'''")]
    if len(lines) < 8:
        print("FAIL:stub_too_short:" + str(len(lines)))
        sys.exit(0)
    print("PASS")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T5"
if [ "$T5" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T6 (0.10): BEHAVIORAL — BaseDatasetParams has skip_duplicate_bucketed_images
#   Import + verify dataclass field exists with a False-like default
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T6/15: [BEHAVIORAL] BaseDatasetParams skip_duplicate_bucketed_images field ==="
T6=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    from library.config_util import BaseDatasetParams
    import dataclasses
    if not dataclasses.is_dataclass(BaseDatasetParams):
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
            has_default = (f.default is not dataclasses.MISSING or
                          f.default_factory is not dataclasses.MISSING)
            if has_default:
                # Verify default is False-like (not True)
                if f.default is not dataclasses.MISSING and f.default:
                    print("FAIL:default_is_truthy:" + str(f.default))
                else:
                    print("PASS")
            else:
                print("FAIL:no_default_value")
            sys.exit(0)
    print("FAIL:field_check_fell_through")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T6"
if [ "$T6" = "PASS" ]; then add_reward 0.10; fi

# ═══════════════════════════════════════════════════════════════════
# T7 (0.08): BEHAVIORAL — skip_duplicate_bucketed_images in schema dict
#   Import config_util, search for DATASET_ASCENDABLE_SCHEMA or similar
#   containing the key with bool type
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T7/15: [BEHAVIORAL] skip_duplicate_bucketed_images in schema dict ==="
T7=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.config_util as cu
    found = False
    for name in dir(cu):
        upper = name.upper()
        if "ASCENDABLE" in upper or ("SCHEMA" in upper and "DATASET" in upper):
            val = getattr(cu, name)
            if isinstance(val, dict) and "skip_duplicate_bucketed_images" in val:
                found = True
                break
            if isinstance(val, (list, set, tuple)) and "skip_duplicate_bucketed_images" in val:
                found = True
                break
    if not found:
        # Fallback: check all module-level dicts
        for name in dir(cu):
            if not name.startswith("_"):
                val = getattr(cu, name, None)
                if isinstance(val, dict) and "skip_duplicate_bucketed_images" in val:
                    found = True
                    break
    print("PASS" if found else "FAIL:not_found_in_schema_dicts")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T7"
if [ "$T7" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T8 (0.03): STRUCTURAL — dedup logic AST pattern
#   Checks config_util.py AND train_util.py for a function containing ALL:
#   (1) skip_duplicate_bucketed_images conditional
#   (2) tracking set/dict with ≥2 ops (add/update + membership test)
#   (3) removal (pop/remove/del/comprehension)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T8/15: [STRUCTURAL] dedup logic AST pattern ==="
T8=$(python3 << 'PYEOF'
import sys, ast

def check_function_for_dedup(func_node):
    has_skip_check = False
    tracking_ops = 0
    has_removal = False
    for node in ast.walk(func_node):
        if isinstance(node, ast.Attribute) and node.attr == "skip_duplicate_bucketed_images":
            has_skip_check = True
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("add", "update", "append"):
                tracking_ops += 1
        if isinstance(node, ast.Compare):
            for op in node.ops:
                if isinstance(op, (ast.In, ast.NotIn)):
                    tracking_ops += 1
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in ("pop", "remove", "discard"):
                has_removal = True
        if isinstance(node, ast.Delete):
            for t in node.targets:
                if isinstance(t, ast.Subscript):
                    has_removal = True
        if isinstance(node, ast.Assign) and isinstance(node.value, (ast.DictComp, ast.ListComp, ast.SetComp)):
            has_removal = True
    return has_skip_check and tracking_ops >= 2 and has_removal

def check_file(path):
    try:
        with open(path) as f:
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
echo "  Result: $T8"
if [ "$T8" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# T9 (0.08): BEHAVIORAL — DreamBoothDataset accepts skip_duplicate_bucketed_images
#   Import train_util, inspect DreamBoothDataset.__init__ signature,
#   verify param exists and is stored as self.attr
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T9/15: [BEHAVIORAL] DreamBoothDataset accepts skip_duplicate_bucketed_images ==="
T9=$($PYTHON << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.train_util as tu
    found_param = False
    found_attr = False
    # Check DreamBoothDataset specifically first, then any dataset class
    for cls_name in ["DreamBoothDataset"]:
        cls = getattr(tu, cls_name, None)
        if cls is None:
            continue
        try:
            sig = inspect.signature(cls.__init__)
            if "skip_duplicate_bucketed_images" in sig.parameters:
                found_param = True
                src = inspect.getsource(cls.__init__)
                if "self.skip_duplicate_bucketed_images" in src:
                    found_attr = True
                break
        except (ValueError, TypeError, OSError):
            continue
    if not found_param:
        # Fallback: check any class with "Dataset" in name
        for name, cls in inspect.getmembers(tu, inspect.isclass):
            if "Dataset" not in name:
                continue
            try:
                sig = inspect.signature(cls.__init__)
                if "skip_duplicate_bucketed_images" in sig.parameters:
                    found_param = True
                    src = inspect.getsource(cls.__init__)
                    if "self.skip_duplicate_bucketed_images" in src:
                        found_attr = True
                    break
            except (ValueError, TypeError, OSError):
                continue
    if found_param and found_attr:
        print("PASS")
    elif found_param:
        print("FAIL:param_found_but_not_stored_as_self_attr")
    else:
        print("FAIL:no_dataset_class_has_skip_duplicate_param")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T9"
if [ "$T9" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T10 (0.08): BEHAVIORAL — FineTuningDataset or ControlNetDataset accepts it
#   At least one other dataset class (beyond DreamBooth) also accepts
#   skip_duplicate_bucketed_images
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T10/15: [BEHAVIORAL] FineTuningDataset or ControlNetDataset accepts skip_duplicate ==="
T10=$($PYTHON << 'PYEOF'
import sys, os, inspect
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.train_util as tu
    found = False
    for cls_name in ["FineTuningDataset", "ControlNetDataset"]:
        cls = getattr(tu, cls_name, None)
        if cls is None:
            continue
        try:
            sig = inspect.signature(cls.__init__)
            if "skip_duplicate_bucketed_images" in sig.parameters:
                found = True
                break
        except (ValueError, TypeError, OSError):
            continue
    if not found:
        # Fallback: any non-DreamBooth dataset class
        for name, cls in inspect.getmembers(tu, inspect.isclass):
            if "Dataset" not in name or name == "DreamBoothDataset" or name == "BaseDataset":
                continue
            try:
                sig = inspect.signature(cls.__init__)
                if "skip_duplicate_bucketed_images" in sig.parameters:
                    found = True
                    break
            except (ValueError, TypeError, OSError):
                continue
    print("PASS" if found else "FAIL:no_other_dataset_class_has_param")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T10"
if [ "$T10" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T11 (0.03): STRUCTURAL — unwrap_model_for_sampling AST
#   Function def with try/except + _orig_mod + unwrap_model call
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T11/15: [STRUCTURAL] unwrap_model_for_sampling AST ==="
T11=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/train_util.py") as f:
        tree = ast.parse(f.read())
except (FileNotFoundError, SyntaxError):
    print("FAIL:file_error")
    sys.exit(0)

found = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and "unwrap_model" in node.name and "sampling" in node.name:
        has_try = False
        has_orig_mod = False
        has_unwrap_call = False
        for child in ast.walk(node):
            if isinstance(child, (ast.Try, ast.ExceptHandler)):
                has_try = True
            if isinstance(child, ast.Attribute) and child.attr == "_orig_mod":
                has_orig_mod = True
            if isinstance(child, ast.Constant) and child.value == "_orig_mod":
                has_orig_mod = True
            if isinstance(child, ast.Call):
                func = child.func
                if isinstance(func, ast.Attribute) and func.attr == "unwrap_model":
                    has_unwrap_call = True
        if has_try and has_orig_mod and has_unwrap_call:
            found = True
            break

print("PASS" if found else "FAIL:missing_requirements")
PYEOF
)
echo "  Result: $T11"
if [ "$T11" = "PASS" ]; then add_reward 0.03; fi

# ═══════════════════════════════════════════════════════════════════
# T12 (0.08): BEHAVIORAL — unwrap_model_for_sampling normal path
#   Call with tracking accelerator + simple model: verify it delegates
#   to accelerator.unwrap_model and returns the result
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T12/15: [BEHAVIORAL] unwrap_model_for_sampling normal path ==="
T12=$($PYTHON << 'PYEOF'
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

    class TrackingAccelerator:
        def __init__(self):
            self.called = False
        def unwrap_model(self, m, **kw):
            self.called = True
            return m

    class SimpleModel:
        pass

    acc = TrackingAccelerator()
    model = SimpleModel()

    result = None
    ok = False
    for args in [(acc, model), (model, acc), (acc, model, False)]:
        try:
            result = func(*args)
            ok = True
            break
        except TypeError:
            continue
        except Exception:
            ok = True
            break

    if not ok:
        print("FAIL:could_not_call")
        sys.exit(0)
    if not acc.called:
        print("FAIL:doesnt_delegate_to_unwrap_model")
        sys.exit(0)
    if result is not model:
        print("FAIL:wrong_return_value")
        sys.exit(0)
    print("PASS")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T12"
if [ "$T12" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T13 (0.08): BEHAVIORAL — unwrap_model_for_sampling KeyError path
#   Call with failing accelerator (raises KeyError) + compiled model
#   (has _orig_mod). Verify KeyError is caught and something returned.
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T13/15: [BEHAVIORAL] unwrap_model_for_sampling KeyError path ==="
T13=$($PYTHON << 'PYEOF'
import sys, os
sys.path.insert(0, "/workspace/sd-scripts")
os.chdir("/workspace/sd-scripts")
try:
    import library.train_util as tu
    func = getattr(tu, "unwrap_model_for_sampling", None)
    if func is None:
        print("FAIL:function_not_found")
        sys.exit(0)

    class FailAccelerator:
        def unwrap_model(self, m, **kw):
            raise KeyError("_orig_mod")

    class InnerModel:
        pass

    class CompiledModel:
        _orig_mod = InnerModel()

    acc = FailAccelerator()
    model = CompiledModel()

    result = None
    ok = False
    for args in [(acc, model), (model, acc), (acc, model, False)]:
        try:
            result = func(*args)
            ok = True
            break
        except TypeError:
            continue
        except KeyError:
            print("FAIL:keyerror_not_caught")
            sys.exit(0)
        except Exception:
            ok = True
            break

    if not ok:
        print("FAIL:could_not_call")
        sys.exit(0)
    if result is None:
        print("FAIL:returned_none_on_error_path")
        sys.exit(0)
    print("PASS")
except Exception as e:
    print(f"FAIL:{e}")
PYEOF
)
echo "  Result: $T13"
if [ "$T13" = "PASS" ]; then add_reward 0.08; fi

# ═══════════════════════════════════════════════════════════════════
# T14 (0.02): STRUCTURAL — _orig_mod + isinstance in sdxl_original_unet.py
#   AST check: a function containing both isinstance() and _orig_mod
#   access (hasattr/getattr/attribute)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T14/15: [STRUCTURAL] sdxl_original_unet.py isinstance + _orig_mod ==="
T14=$(python3 << 'PYEOF'
import sys, ast

try:
    with open("/workspace/sd-scripts/library/sdxl_original_unet.py") as f:
        source = f.read()
except FileNotFoundError:
    print("FAIL:file_not_found")
    sys.exit(0)

tree = ast.parse(source)
found = False
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
            found = True
            break

print("PASS" if found else "FAIL:no_orig_mod_handling_near_isinstance")
PYEOF
)
echo "  Result: $T14"
if [ "$T14" = "PASS" ]; then add_reward 0.02; fi

# ═══════════════════════════════════════════════════════════════════
# T15 (0.03): BEHAVIORAL P2P — upstream test suite
#   Run CPU-safe tests from tests/library/ to verify no regressions
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== T15/15: [BEHAVIORAL P2P] upstream test suite ==="
cd /workspace/sd-scripts
if [ -d "tests/library" ] && ls tests/library/test_*.py 1>/dev/null 2>&1; then
    P2P_RESULT=$($PYTHON -m pytest tests/library/ --timeout=60 -q 2>&1)
    P2P_EXIT=$?
    echo "  pytest exit: $P2P_EXIT"
    echo "$P2P_RESULT" | tail -5
    if [ $P2P_EXIT -eq 0 ]; then
        add_reward 0.03
        echo "  PASS"
    else
        echo "  FAIL: upstream tests failed"
    fi
else
    echo "  SKIP: no upstream tests found"
fi

# ═══════════════════════════════════════════════════════════════════
# FINAL SCORE
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "==============================="
FINAL_REWARD=$(awk "BEGIN{r=$REWARD; if(r>1.0) r=1.0; printf \"%.2f\", r}")
echo "Final reward: $FINAL_REWARD"
echo "$FINAL_REWARD" > "$REWARD_FILE"
echo "Written to $REWARD_FILE"
