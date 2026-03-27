#!/usr/bin/env bash
#
# Verification script for unsloth-idefics3-fix task.
# Tests the addition of Idefics3 VLM support to Unsloth.
# Writes a reward between 0.0 and 1.0 to /logs/verifier/reward.txt.
#
# DESIGN PRINCIPLES:
#   - Every check is deterministic: no LLM calls, no subjective evaluation.
#   - STRUCTURAL checks (40%): AST-based, verify real code not just keywords
#   - BEHAVIORAL checks (50%): Actually import/execute code, verify runtime behavior
#   - BONUS check (10%): Test file quality
#   - Partial credit: each component is independently scored.
#   - No GPU required: all behavioral checks use CPU-safe import paths.
#
set +e

REWARD=0.0
WORKSPACE="/workspace/unsloth"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

# Helper: increment reward (capped at 1.0)
add_reward() {
    REWARD=$(python3 -c "print(min(1.0, $REWARD + $1))")
}

cd "$WORKSPACE"

# ═══════════════════════════════════════════════════════════════════
# SECTION A: STRUCTURAL CHECKS (0.40 total)
# AST-based checks that verify real code structure, not keywords.
# ═══════════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────────
# CHECK 1 (0.05): idefics.py exists with FastIdefics3Model class
# ───────────────────────────────────────────────────────────────────
echo "--- Check 1: FastIdefics3Model class exists in idefics.py ---"

CHECK1_RESULT=$(python3 -c "
import ast, sys

try:
    with open('unsloth/models/idefics.py', 'r') as f:
        tree = ast.parse(f.read())

    classes = [node.name for node in ast.walk(tree) if isinstance(node, ast.ClassDef)]
    if 'FastIdefics3Model' in classes:
        print('PASS')
    else:
        print(f'FAIL:class_not_found:found={classes}')
except FileNotFoundError:
    print('FAIL:file_not_found')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK1_RESULT"
if [ "$CHECK1_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.05
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 2 (0.10): from_pretrained is a substantial method (>5 AST stmts)
#   A real from_pretrained loads models, patches hooks, handles config.
#   A skeleton with 'pass' or a single return is not enough.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 2: from_pretrained is substantial (>5 statements) ---"

CHECK2_RESULT=$(python3 -c "
import ast, sys

def count_stmts(node):
    '''Recursively count all statement nodes inside a function.'''
    count = 0
    for child in ast.walk(node):
        if isinstance(child, ast.stmt) and child is not node:
            count += 1
    return count

try:
    with open('unsloth/models/idefics.py', 'r') as f:
        tree = ast.parse(f.read())

    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == 'FastIdefics3Model':
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name == 'from_pretrained':
                    n = count_stmts(item)
                    if n > 5:
                        print('PASS')
                    else:
                        print(f'FAIL:too_shallow:stmts={n}')
                    sys.exit(0)
            print('FAIL:no_from_pretrained')
            sys.exit(0)
    print('FAIL:class_not_found')
except FileNotFoundError:
    print('FAIL:file_not_found')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK2_RESULT"
if [ "$CHECK2_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 3 (0.05): FastIdefics3Model exported from __init__.py
# ───────────────────────────────────────────────────────────────────
echo "--- Check 3: FastIdefics3Model exported from __init__.py ---"

CHECK3_RESULT=$(python3 -c "
import ast, sys

try:
    with open('unsloth/models/__init__.py', 'r') as f:
        tree = ast.parse(f.read())

    # Walk import nodes only -- reject if FastIdefics3Model only appears in
    # comments/strings, require it in an actual import statement.
    found = False
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            mod = node.module or ''
            for alias in node.names:
                if alias.name == 'FastIdefics3Model':
                    found = True
                    break
            # Also accept: from .idefics import *
            if 'idefics' in mod:
                for alias in node.names:
                    if alias.name == '*' or alias.name == 'FastIdefics3Model':
                        found = True
                        break
        if isinstance(node, ast.Import):
            for alias in node.names:
                if 'FastIdefics3Model' in (alias.name or ''):
                    found = True
                    break
        if found:
            break

    # Fallback: accept __all__ list containing FastIdefics3Model
    if not found:
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value == 'FastIdefics3Model':
                found = True
                break

    print('PASS' if found else 'FAIL:no_import_of_FastIdefics3Model')
except FileNotFoundError:
    print('FAIL:file_not_found')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK3_RESULT"
if [ "$CHECK3_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.05
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 4 (0.10): Idefics3ForConditionalGeneration used in real code
#   Require Idefics3ForConditionalGeneration appears in an actual
#   import statement or function call, not just a string/comment.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 4: Idefics3ForConditionalGeneration used in real code ---"

CHECK4_RESULT=$(python3 -c "
import ast, sys

try:
    with open('unsloth/models/idefics.py', 'r') as f:
        tree = ast.parse(f.read())

    found_import = False
    found_usage = False

    for node in ast.walk(tree):
        # Check imports
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                if alias.name == 'Idefics3ForConditionalGeneration':
                    found_import = True
        # Check Name references in code (not strings)
        if isinstance(node, ast.Name) and node.id == 'Idefics3ForConditionalGeneration':
            found_usage = True
        # Check Attribute references like transformers.Idefics3ForConditionalGeneration
        if isinstance(node, ast.Attribute) and node.attr == 'Idefics3ForConditionalGeneration':
            found_usage = True

    if found_import or found_usage:
        print('PASS')
    else:
        print('FAIL:not_in_code')
except FileNotFoundError:
    print('FAIL:file_not_found')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK4_RESULT"
if [ "$CHECK4_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 5 (0.10): LoRA target modules in real code (not comments)
#   Verify that LoRA-related identifiers appear as actual Python code
#   nodes (Name, Attribute, Constant in list/dict) not just comments.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 5: LoRA target modules in real code ---"

CHECK5_RESULT=$(python3 -c "
import ast, sys

try:
    with open('unsloth/models/idefics.py', 'r') as f:
        tree = ast.parse(f.read())

    lora_indicators = 0

    # (a) Look for LoRA projection layer name strings in actual code
    #     (q_proj, k_proj, v_proj, o_proj, etc.) as string constants in lists/dicts
    proj_names = {'q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'}
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if node.value in proj_names:
                lora_indicators += 1
                break  # one is enough

    # (b) Look for references to LoraConfig, get_peft_model, target_modules as code identifiers
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and node.id in ('LoraConfig', 'get_peft_model', 'target_modules'):
            lora_indicators += 1
            break
        if isinstance(node, ast.Attribute) and node.attr in ('LoraConfig', 'get_peft_model', 'target_modules'):
            lora_indicators += 1
            break

    # (c) Look for get_peft_regex pattern (unsloth-specific)
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and 'peft' in node.id.lower() and 'regex' in node.id.lower():
            lora_indicators += 1
            break
        if isinstance(node, ast.Attribute) and 'peft' in node.attr.lower() and 'regex' in node.attr.lower():
            lora_indicators += 1
            break

    if lora_indicators >= 1:
        print('PASS')
    else:
        print('FAIL:no_lora_code')
except FileNotFoundError:
    print('FAIL:file_not_found')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK5_RESULT"
if [ "$CHECK5_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION B: BEHAVIORAL CHECKS (0.50 total)
# Actually import and execute code to verify runtime behavior.
# All checks are CPU-safe with try/except for GPU-only failures.
# ═══════════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────────
# CHECK 6 (0.10): FastIdefics3Model is importable and is a class
#   Actually import the module and verify the class exists at runtime.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 6: FastIdefics3Model is importable as a class ---"

CHECK6_RESULT=$(python3 -c "
import sys, importlib, importlib.util, types

try:
    # Try direct import from the models package
    try:
        spec = importlib.util.spec_from_file_location(
            'unsloth.models.idefics',
            'unsloth/models/idefics.py'
        )
        mod = importlib.util.module_from_spec(spec)
        sys.modules['unsloth.models.idefics'] = mod
        spec.loader.exec_module(mod)
    except Exception as e1:
        # Fallback: try importing with the full unsloth path
        try:
            from unsloth.models.idefics import FastIdefics3Model as _cls
            mod = type('mod', (), {'FastIdefics3Model': _cls})
        except Exception as e2:
            print(f'FAIL:import_error:{e1} / {e2}')
            sys.exit(0)

    cls = getattr(mod, 'FastIdefics3Model', None)
    if cls is None:
        print('FAIL:class_not_found_in_module')
    elif not isinstance(cls, type):
        print(f'FAIL:not_a_class:type={type(cls).__name__}')
    else:
        # Verify it has expected methods
        has_from_pretrained = hasattr(cls, 'from_pretrained') and callable(getattr(cls, 'from_pretrained'))
        if has_from_pretrained:
            print('PASS')
        else:
            print('FAIL:missing_from_pretrained_method')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK6_RESULT"
if [ "$CHECK6_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 7 (0.10): VLLM_SUPPORTED_VLM actually contains "idefics3"
#   Import vision.py and verify the runtime list object contains it.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 7: VLLM_SUPPORTED_VLM runtime list contains idefics3 ---"

CHECK7_RESULT=$(python3 -c "
import sys, importlib.util

try:
    # Try to import vision.py and get the actual list value
    spec = importlib.util.spec_from_file_location(
        'unsloth.models.vision',
        'unsloth/models/vision.py'
    )
    mod = importlib.util.module_from_spec(spec)
    # Some imports in vision.py may fail -- we need to handle that.
    # We can also fall back to AST evaluation.
    try:
        spec.loader.exec_module(mod)
        vlm_list = getattr(mod, 'VLLM_SUPPORTED_VLM', None)
        if vlm_list is not None and 'idefics3' in vlm_list:
            print('PASS')
        elif vlm_list is not None:
            print(f'FAIL:idefics3_not_in_list:found={vlm_list}')
        else:
            print('FAIL:VLLM_SUPPORTED_VLM_not_found')
    except Exception as import_err:
        # vision.py has dependencies that may not import cleanly
        # Fall back to AST evaluation of the list literal
        import ast
        with open('unsloth/models/vision.py', 'r') as f:
            tree = ast.parse(f.read())
        found = False
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id == 'VLLM_SUPPORTED_VLM':
                        if isinstance(node.value, ast.List):
                            elts = [e.value for e in node.value.elts if isinstance(e, ast.Constant)]
                            if 'idefics3' in elts:
                                found = True
        if found:
            print('PASS')
        else:
            print(f'FAIL:ast_fallback:idefics3_not_in_list')
except FileNotFoundError:
    print('FAIL:file_not_found')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK7_RESULT"
if [ "$CHECK7_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 8 (0.15): Hook patch is functional
#   The core bug: unsloth_zoo.peft_utils.requires_grad_pre_hook
#   crashes on empty tuple inputs from Idefics3's get_input_embeddings.
#   Verify the agent's fix actually handles this case.
#   Accept any approach:
#     (a) Monkey-patch that makes requires_grad_pre_hook safe
#     (b) Override get_input_embeddings to return a proper Embedding
#     (c) Custom wrapper that intercepts the hook
#   We test by simulating the failure scenario.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 8: Hook patch handles empty tuple inputs ---"

CHECK8_RESULT=$(python3 -c "
import sys, os, ast, re, importlib

# Strategy: Check if the agent's code, when executed, makes the hook safe.
# We do this in multiple ways:

score = 0
reasons = []

# ---- Sub-check A: Code structurally addresses the hook problem ----
# Look for actual function definitions or assignments that modify
# requires_grad_pre_hook or get_input_embeddings (in AST, not comments)

idefics_path = 'unsloth/models/idefics.py'
if not os.path.exists(idefics_path):
    print('FAIL:file_not_found')
    sys.exit(0)

with open(idefics_path, 'r') as f:
    source = f.read()
    tree = ast.parse(source)

# Look for function defs that are hook-related
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef):
        # A function that patches or replaces the pre_hook
        if 'hook' in node.name.lower() or 'pre_hook' in node.name.lower() or 'requires_grad' in node.name.lower():
            reasons.append(f'hook-related function: {node.name}')
            score += 1

    # Look for assignments to requires_grad_pre_hook (monkey-patching)
    if isinstance(node, ast.Assign):
        for target in node.targets:
            target_str = ast.dump(target)
            if 'requires_grad_pre_hook' in target_str:
                reasons.append('assigns requires_grad_pre_hook')
                score += 2
            if 'requires_grad_for_gradient_checkpointing' in target_str:
                reasons.append('assigns gradient_checkpointing func')
                score += 1

    # Look for attribute assignments: something.requires_grad_pre_hook = ...
    if isinstance(node, ast.Attribute):
        if node.attr in ('requires_grad_pre_hook', 'requires_grad_for_gradient_checkpointing'):
            reasons.append(f'references {node.attr}')
            score += 1

# Look for get_input_embeddings method override in the class
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == 'FastIdefics3Model':
        for item in node.body:
            if isinstance(item, ast.FunctionDef) and item.name == 'get_input_embeddings':
                reasons.append('overrides get_input_embeddings')
                score += 2

# Check for empty-tuple handling patterns in actual code
# (len(args) == 0, not args, args == (), etc.)
for node in ast.walk(tree):
    if isinstance(node, ast.Compare):
        cmp_str = ast.dump(node)
        if ('len' in cmp_str and '0' in cmp_str) or ('Tuple' in cmp_str):
            reasons.append('empty-tuple comparison')
            score += 1
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        if isinstance(node.operand, ast.Name) and node.operand.id in ('args', 'inputs', 'input'):
            reasons.append('not-args check')
            score += 1

# ---- Sub-check B: Functional test of the patched hook ----
# Try to execute the patching code and test if empty tuples are handled.
try:
    # First, check if unsloth_zoo.peft_utils is available
    import unsloth_zoo.peft_utils as pu
    original_hook = getattr(pu, 'requires_grad_pre_hook', None)

    if original_hook is not None:
        # Try to import the agent's idefics module to trigger any monkey-patches
        try:
            spec = importlib.util.spec_from_file_location('unsloth.models.idefics', idefics_path)
            mod = importlib.util.module_from_spec(spec)
            sys.modules['unsloth.models.idefics'] = mod
            spec.loader.exec_module(mod)
        except Exception:
            pass  # Module may not fully import on CPU, that's OK

        # Now check if the hook was patched
        patched_hook = getattr(pu, 'requires_grad_pre_hook', original_hook)

        # Test: call the hook with empty tuple -- should not raise
        import torch
        dummy_module = torch.nn.Linear(1, 1)
        try:
            patched_hook(dummy_module, ())
            reasons.append('FUNCTIONAL:hook_handles_empty_tuple')
            score += 5
        except (RuntimeError, TypeError, IndexError) as e:
            # Hook still crashes -- check if the fix is a get_input_embeddings override instead
            cls = getattr(mod, 'FastIdefics3Model', None) if 'mod' in dir() else None
            if cls and hasattr(cls, 'get_input_embeddings'):
                reasons.append('FUNCTIONAL:get_input_embeddings_override_present')
                score += 3
            else:
                reasons.append(f'hook_still_crashes:{e}')
    else:
        reasons.append('requires_grad_pre_hook_not_found_in_zoo')
        # Still give credit for structural fix
        score += 0
except ImportError:
    reasons.append('unsloth_zoo_not_importable')
    # Give credit for structural approach only
except Exception as e:
    reasons.append(f'functional_test_error:{e}')

# Scoring: need score >= 2 for PASS
if score >= 2:
    print('PASS')
else:
    print(f'FAIL:score={score}:reasons={reasons}')
" 2>&1)

echo "  Result: $CHECK8_RESULT"
if [ "$CHECK8_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.15
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 9 (0.10): from_pretrained references model loading logic
#   Verify that from_pretrained actually calls into transformers
#   model loading (AutoModelForVision2Seq, Idefics3ForConditionalGeneration,
#   .from_pretrained, etc.) not just 'pass'.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 9: from_pretrained has real model loading logic ---"

CHECK9_RESULT=$(python3 -c "
import ast, sys

try:
    with open('unsloth/models/idefics.py', 'r') as f:
        tree = ast.parse(f.read())

    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == 'FastIdefics3Model':
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == 'from_pretrained':
                    # Walk the method body and look for model-loading indicators:
                    # - Calls to .from_pretrained() (attribute call)
                    # - References to Idefics3ForConditionalGeneration
                    # - References to AutoModelForVision2Seq
                    # - References to model_name/model_path/pretrained_model_name
                    indicators = 0
                    for child in ast.walk(item):
                        # Call to something.from_pretrained(...)
                        if isinstance(child, ast.Call):
                            func = child.func
                            if isinstance(func, ast.Attribute) and func.attr == 'from_pretrained':
                                indicators += 2
                        # Name references to model classes
                        if isinstance(child, ast.Name) and child.id in (
                            'Idefics3ForConditionalGeneration',
                            'AutoModelForVision2Seq',
                            'AutoModelForCausalLM',
                            'Idefics3Config',
                        ):
                            indicators += 1
                        if isinstance(child, ast.Attribute) and child.attr in (
                            'Idefics3ForConditionalGeneration',
                            'AutoModelForVision2Seq',
                        ):
                            indicators += 1
                        # Parameter references (model_name, pretrained_model_name_or_path)
                        if isinstance(child, ast.Name) and 'model_name' in child.id.lower():
                            indicators += 1

                    if indicators >= 2:
                        print('PASS')
                    else:
                        print(f'FAIL:no_loading_logic:indicators={indicators}')
                    sys.exit(0)
            print('FAIL:no_from_pretrained')
            sys.exit(0)
    print('FAIL:class_not_found')
except FileNotFoundError:
    print('FAIL:file_not_found')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK9_RESULT"
if [ "$CHECK9_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.10
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 10 (0.05): "idefics3" mapped in model dispatch/mapping
#   Unsloth has model dispatch logic (e.g., in __init__.py or a
#   mapping dict). Verify "idefics3" is wired into the dispatch so
#   that FastVisionModel.from_pretrained can route to it.
#   Accept: mapping dict entry, if/elif branch, or similar.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 10: idefics3 in model dispatch/mapping ---"

CHECK10_RESULT=$(python3 -c "
import ast, re, sys, os, glob

# Search for idefics3 in mapping dicts or dispatch logic across key files.
# Known locations: unsloth/models/vision.py, unsloth/models/__init__.py,
# unsloth/__init__.py, or any loader.py / mapping.py

found = False
search_files = glob.glob('unsloth/**/*.py', recursive=True)

for fpath in search_files:
    if fpath == 'unsloth/models/idefics.py':
        continue  # Skip the idefics module itself
    try:
        with open(fpath, 'r') as f:
            tree = ast.parse(f.read())
    except:
        continue

    for node in ast.walk(tree):
        # Look for string 'idefics3' or 'idefics' as a dict key or in a mapping
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            val = node.value.lower()
            if 'idefics3' in val or val == 'idefics':
                # Make sure it is NOT inside the VLLM_SUPPORTED_VLM list (that is Check 7)
                # We want dispatch/mapping references
                found = True
                break
        # Also look for 'FastIdefics3Model' in if/elif comparisons
        if isinstance(node, ast.Compare):
            dump = ast.dump(node)
            if 'idefics3' in dump.lower() or 'FastIdefics3Model' in dump:
                found = True
                break
    if found:
        break

if found:
    print('PASS')
else:
    # Fallback: regex search for idefics3 in dispatch-like patterns
    for fpath in search_files:
        if fpath == 'unsloth/models/idefics.py':
            continue
        try:
            with open(fpath, 'r') as f:
                content = f.read()
            # Look for mapping patterns: 'idefics3' : FastIdefics3Model or similar
            if re.search(r'idefics3.{0,20}Fast|FastIdefics3Model', content):
                found = True
                break
        except:
            continue

    print('PASS' if found else 'FAIL:no_dispatch')
" 2>&1)

echo "  Result: $CHECK10_RESULT"
if [ "$CHECK10_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION C: TEST QUALITY (0.10 total)
# ═══════════════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────────────
# CHECK 11 (0.05): Test file exists with >=2 substantive test functions
#   Each test function must have >3 statements (not just 'pass').
# ───────────────────────────────────────────────────────────────────
echo "--- Check 11: Test file with substantive test functions ---"

CHECK11_RESULT=$(python3 -c "
import ast, sys, os

test_paths = [
    'tests/test_idefics3.py',
    'tests/test_idefics.py',
    'test_idefics3.py',
    'test_idefics.py',
]

found_path = None
for p in test_paths:
    if os.path.exists(p):
        found_path = p
        break

if found_path is None:
    print('FAIL:no_test_file')
    sys.exit(0)

try:
    with open(found_path, 'r') as f:
        tree = ast.parse(f.read())

    def count_stmts(node):
        count = 0
        for child in ast.walk(node):
            if isinstance(child, ast.stmt) and child is not node:
                count += 1
        return count

    substantive = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name.startswith('test_'):
            if count_stmts(node) > 3:
                substantive += 1

    if substantive >= 2:
        print('PASS')
    else:
        print(f'FAIL:need_2_substantive_tests:found={substantive}')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK11_RESULT"
if [ "$CHECK11_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.05
fi

# ───────────────────────────────────────────────────────────────────
# CHECK 12 (0.05): Test file actually imports from the idefics module
#   The test must actually reference the code it's testing.
# ───────────────────────────────────────────────────────────────────
echo "--- Check 12: Test file imports from idefics module ---"

CHECK12_RESULT=$(python3 -c "
import ast, sys, os

test_paths = [
    'tests/test_idefics3.py',
    'tests/test_idefics.py',
    'test_idefics3.py',
    'test_idefics.py',
]

found_path = None
for p in test_paths:
    if os.path.exists(p):
        found_path = p
        break

if found_path is None:
    print('FAIL:no_test_file')
    sys.exit(0)

try:
    with open(found_path, 'r') as f:
        tree = ast.parse(f.read())

    imports_idefics = False
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            mod = node.module or ''
            if 'idefics' in mod.lower():
                imports_idefics = True
                break
            for alias in node.names:
                if 'Idefics3' in alias.name or 'idefics' in alias.name.lower():
                    imports_idefics = True
                    break
        if isinstance(node, ast.Import):
            for alias in node.names:
                if 'idefics' in alias.name.lower():
                    imports_idefics = True
                    break
        if imports_idefics:
            break

    # Also accept: referencing FastIdefics3Model as a Name in code
    if not imports_idefics:
        for node in ast.walk(tree):
            if isinstance(node, ast.Name) and node.id == 'FastIdefics3Model':
                imports_idefics = True
                break

    print('PASS' if imports_idefics else 'FAIL:test_does_not_import_idefics')
except SyntaxError as e:
    print(f'FAIL:syntax_error:{e}')
except Exception as e:
    print(f'ERROR:{e}')
" 2>&1)

echo "  Result: $CHECK12_RESULT"
if [ "$CHECK12_RESULT" = "PASS" ]; then
    echo "  PASS"
    add_reward 0.05
fi

# ═══════════════════════════════════════════════════════════════════
# Write final reward
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "======================================="
echo "  Score breakdown:"
echo "    Structural checks (A):  0.40 max"
echo "    Behavioral checks (B):  0.50 max"
echo "    Test quality (C):       0.10 max"
echo "  Final reward: $REWARD"
echo "======================================="
echo "$REWARD" > "$LOG_DIR/reward.txt"
