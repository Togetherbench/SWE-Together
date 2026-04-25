#!/bin/bash
set +e

REWARD=0.0
WORKSPACE="/workspace/unsloth"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v r="$REWARD" -v a="$1" 'BEGIN{s=r+a; if(s>1.0) s=1.0; printf "%.4f", s}')
}

cd "$WORKSPACE" 2>/dev/null || { echo "0.0" > "$LOG_DIR/reward.txt"; exit 0; }

# CPU compat preamble shared by all python invocations
cat > /tmp/_cpu_compat.py << 'CPUEOF'
import sys, types, os, site

os.environ["UNSLOTH_IS_PRESENT"] = "1"

try:
    _sp = site.getsitepackages()[0]
except Exception:
    _sp = "/usr/local/lib/python3.12/site-packages"
_uz_path = os.path.join(_sp, 'unsloth_zoo')

if 'unsloth_zoo' not in sys.modules and os.path.isdir(_uz_path):
    _uz = types.ModuleType('unsloth_zoo')
    _uz.__path__ = [_uz_path]
    _uz.__package__ = 'unsloth_zoo'
    _uz.__file__ = os.path.join(_uz_path, '__init__.py')
    sys.modules['unsloth_zoo'] = _uz

if 'unsloth_zoo.device_type' not in sys.modules:
    _dt = types.ModuleType('unsloth_zoo.device_type')
    _dt.get_device_type = lambda: 'cpu'
    _dt.is_hip = lambda: False
    _dt.DEVICE_TYPE = 'cpu'
    _dt.DEVICE_TYPE_TORCH = 'cpu'
    _dt.DEVICE_COUNT = 1
    _dt.ALLOW_PREQUANTIZED_MODELS = True
    _dt.ALLOW_BITSANDBYTES = False
    sys.modules['unsloth_zoo.device_type'] = _dt
    if 'unsloth_zoo' in sys.modules:
        sys.modules['unsloth_zoo'].device_type = _dt
CPUEOF

# Find the agent's idefics module
IDEFICS_PY=$(python3 << 'PYEOF'
import glob, ast, os
candidates = sorted(glob.glob('unsloth/models/*idefics*.py'))
if not candidates:
    original = {'granite.py','llama.py','qwen2.py','mistral.py','gemma.py','gemma3.py',
                'vision.py','__init__.py','mapper.py','loader.py','cohere.py','dbrx.py',
                'phi3.py','phi4.py','_utils.py','dpo.py','rl.py','rl_replacements.py',
                'sentence_transformer.py','falcon_h1.py'}
    for f in sorted(glob.glob('unsloth/models/*.py')):
        if os.path.basename(f) in original: continue
        try:
            tree = ast.parse(open(f).read())
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef) and 'Idefics' in node.name:
                    candidates.append(f); break
        except: pass
print(candidates[0] if candidates else '')
PYEOF
)
export IDEFICS_PY
echo "Idefics module: ${IDEFICS_PY:-NOT FOUND}"

# ════════════════════════════════════════════════════════════════
# CHECK 1 (0.08) — P2P: Source files parse cleanly
# ════════════════════════════════════════════════════════════════
echo "--- Check 1 [0.08] P2P: Source integrity ---"
PARSE_OK=$(python3 << 'PYEOF'
import ast, os
files = ['unsloth/models/vision.py', 'unsloth/models/__init__.py',
         'unsloth/models/loader.py', 'unsloth/models/llama.py']
ok = 0
for f in files:
    if not os.path.exists(f):
        print(f"MISSING: {f}"); continue
    try:
        ast.parse(open(f).read()); ok += 1
    except SyntaxError as e:
        print(f"SYNTAX FAIL {f}: {e}")
print(ok)
PYEOF
)
PARSE_NUM=$(echo "$PARSE_OK" | tail -1)
if [ "$PARSE_NUM" = "4" ]; then
    add_reward 0.08
    echo "  PASS"
else
    echo "  FAIL: $PARSE_NUM/4"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 2 (0.05) — P2P: Existing VLM entries preserved
# ════════════════════════════════════════════════════════════════
echo "--- Check 2 [0.05] P2P: VLLM_SUPPORTED_VLM preserves existing ---"
EXIST_OK=$(python3 << 'PYEOF'
import ast
try:
    src = open('unsloth/models/vision.py').read()
    tree = ast.parse(src)
    found = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == 'VLLM_SUPPORTED_VLM':
                    if isinstance(node.value, ast.List):
                        found = [e.value for e in node.value.elts if isinstance(e, ast.Constant)]
    needed = {'qwen2_5_vl','gemma3','mistral3','qwen3_vl'}
    if found and needed.issubset(set(found)):
        print("OK")
    else:
        print(f"MISS: {found}")
except Exception as e:
    print(f"ERR: {e}")
PYEOF
)
if echo "$EXIST_OK" | grep -q "^OK"; then
    add_reward 0.05
    echo "  PASS"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 3 (0.05) — P2P: Existing model exports preserved
# ════════════════════════════════════════════════════════════════
echo "--- Check 3 [0.05] P2P: Existing exports preserved ---"
EXPORTS_OK=$(python3 << 'PYEOF'
src = open('unsloth/models/__init__.py').read()
needed = ['FastLlamaModel', 'FastModel', 'FastVisionModel', 'FastLanguageModel']
miss = [n for n in needed if n not in src]
print('OK' if not miss else f'MISS: {miss}')
PYEOF
)
if echo "$EXPORTS_OK" | grep -q "^OK"; then
    add_reward 0.05
    echo "  PASS"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 4 (0.07) — F2P: idefics3 registered in VLLM_SUPPORTED_VLM
# ════════════════════════════════════════════════════════════════
echo "--- Check 4 [0.07] F2P: idefics3 in VLLM_SUPPORTED_VLM ---"
VLM_REG=$(python3 << 'PYEOF'
import ast
src = open('unsloth/models/vision.py').read()
tree = ast.parse(src)
found = False
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == 'VLLM_SUPPORTED_VLM':
                if isinstance(node.value, ast.List):
                    vals = [e.value for e in node.value.elts if isinstance(e, ast.Constant)]
                    if 'idefics3' in vals:
                        found = True
print("OK" if found else "MISS")
PYEOF
)
if echo "$VLM_REG" | grep -q "^OK"; then
    add_reward 0.07
    echo "  PASS"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 5 (0.05) — F2P: FastIdefics3Model exported in __init__.py
# ════════════════════════════════════════════════════════════════
echo "--- Check 5 [0.05] F2P: FastIdefics3Model export ---"
EXPORT_FOUND=$(python3 << 'PYEOF'
import re
src = open('unsloth/models/__init__.py').read()
if re.search(r'from\s+\.\w+\s+import\s+[^#\n]*FastIdefics3Model', src):
    print("OK")
elif 'FastIdefics3Model' in src:
    print("PARTIAL")
else:
    print("MISS")
PYEOF
)
if echo "$EXPORT_FOUND" | grep -q "^OK"; then
    add_reward 0.05
    echo "  PASS"
elif echo "$EXPORT_FOUND" | grep -q "^PARTIAL"; then
    add_reward 0.025
    echo "  PARTIAL"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 6 (0.10) — F2P: idefics module structural quality
# ════════════════════════════════════════════════════════════════
echo "--- Check 6 [0.10] F2P: FastIdefics3Model class quality ---"
CLASS_SCORE=0
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    CLASS_SCORE=$(python3 << PYEOF
import ast
score = 0
try:
    src = open("$IDEFICS_PY").read()
    tree = ast.parse(src)
    has_class = False
    has_from_pretrained = False
    has_substantive_fp = False
    has_extra_methods = False
    references_idefics = ('Idefics3' in src) or ('idefics3' in src.lower())
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and 'Idefics' in node.name:
            has_class = True
            method_count = 0
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    method_count += 1
                    if item.name == 'from_pretrained':
                        has_from_pretrained = True
                        if len(item.body) >= 2:
                            has_substantive_fp = True
            # If class inherits AND has from_pretrained, treat as substantive
            if node.bases and has_from_pretrained:
                has_substantive_fp = True
            if method_count >= 2 or node.bases:
                has_extra_methods = True
    if has_class: score += 1
    if has_from_pretrained: score += 1
    if has_substantive_fp: score += 1
    if has_extra_methods: score += 1
    if references_idefics: score += 1
except Exception as e:
    pass
print(score)
PYEOF
)
fi
CLASS_SCORE=$(echo "$CLASS_SCORE" | tail -1)
case "$CLASS_SCORE" in
    5) add_reward 0.10; echo "  PASS (5/5)" ;;
    4) add_reward 0.08; echo "  GOOD (4/5)" ;;
    3) add_reward 0.05; echo "  PARTIAL (3/5)" ;;
    2) add_reward 0.025; echo "  WEAK (2/5)" ;;
    *) echo "  FAIL ($CLASS_SCORE/5)" ;;
esac

# ════════════════════════════════════════════════════════════════
# CHECK 7 (0.12) — F2P BEHAVIORAL: idefics module imports & references valid HF class
# ════════════════════════════════════════════════════════════════
echo "--- Check 7 [0.12] F2P BEHAVIORAL: module imports without errors ---"
IMPORT_RESULT="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    MODNAME=$(python3 -c "import os; print(os.path.splitext(os.path.basename('$IDEFICS_PY'))[0])")
    IMPORT_RESULT=$(python3 << PYEOF 2>&1
import sys
sys.path.insert(0, '/tmp')
exec(open('/tmp/_cpu_compat.py').read())

# Block torch heavy backend imports being problematic - install minimal stubs as needed
try:
    import importlib
    # Try importing the module directly
    mod = importlib.import_module('unsloth.models.$MODNAME')
    # Look for any FastIdefics-like class
    found = None
    for name in dir(mod):
        if 'Idefics' in name and 'Fast' in name:
            cls = getattr(mod, name)
            if isinstance(cls, type) or callable(cls):
                found = name
                break
    if found:
        print(f"OK:{found}")
    else:
        # Maybe it has from_pretrained referencing Idefics3ForConditionalGeneration
        src = open("$IDEFICS_PY").read()
        if 'Idefics3ForConditionalGeneration' in src or 'AutoModelForVision2Seq' in src:
            print("PARTIAL:no_class_but_hf_ref")
        else:
            print("PARTIAL:imported_no_class")
except Exception as e:
    msg = str(e)[:200]
    print(f"FAIL:{type(e).__name__}:{msg}")
PYEOF
)
fi
echo "  Result: $IMPORT_RESULT" | head -1
if echo "$IMPORT_RESULT" | grep -q "^OK:"; then
    add_reward 0.12
    echo "  PASS"
elif echo "$IMPORT_RESULT" | grep -q "^PARTIAL:"; then
    add_reward 0.06
    echo "  PARTIAL"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 8 (0.10) — F2P BEHAVIORAL: vision.py imports cleanly with idefics3
# ════════════════════════════════════════════════════════════════
echo "--- Check 8 [0.10] F2P BEHAVIORAL: unsloth.models.vision imports ---"
VISION_RES=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/_cpu_compat.py').read())
try:
    import unsloth.models.vision as v
    vlms = getattr(v, 'VLLM_SUPPORTED_VLM', [])
    if 'idefics3' in vlms:
        print(f"OK:{len(vlms)}")
    else:
        print(f"FAIL:no_idefics3:{vlms}")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{str(e)[:150]}")
PYEOF
)
echo "  Result: $VISION_RES"
if echo "$VISION_RES" | grep -q "^OK:"; then
    add_reward 0.10
    echo "  PASS"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 9 (0.15) — F2P BEHAVIORAL: hook fix actually works for empty-tuple input
# This is the core requirement: requires_grad_pre_hook should not crash on empty
# tuple, OR FastIdefics3Model.get_input_embeddings should be overridden to return
# a torch.nn.Embedding directly, OR the fix is applied to a model wrapper.
# ════════════════════════════════════════════════════════════════
echo "--- Check 9 [0.15] F2P BEHAVIORAL: hook compatibility fix ---"
HOOK_RES=$(python3 << 'PYEOF' 2>&1
import sys, os
exec(open('/tmp/_cpu_compat.py').read())

score = 0
notes = []

# Approach 1: import the agent's idefics module — many fixes apply patches at import time
try:
    import importlib, glob
    mod_files = sorted(glob.glob('unsloth/models/*idefics*.py'))
    if mod_files:
        modname = os.path.splitext(os.path.basename(mod_files[0]))[0]
        try:
            importlib.import_module(f'unsloth.models.{modname}')
            notes.append('module_imported')
        except Exception as e:
            notes.append(f'module_import_fail:{type(e).__name__}')
except Exception as e:
    notes.append(f'discover_fail:{e}')

# Approach 2: check that the hook in unsloth_zoo handles empty input tuple
# Either it was monkey-patched at idefics import time, or the source has been edited
hook_handles_empty = False
try:
    import torch
    import unsloth_zoo.peft_utils as pu
    # Inspect the source for graceful handling, OR look for early-return on empty input
    src = open(pu.__file__).read()
    # Patched in source by some agents (GLM4.7 patches the source file directly)
    if 'last_hidden_state' in src or 'pixel_values' in src.lower():
        # extra robustness added
        score += 1
        notes.append('source_extended')
    # Try actually invoking the pre-hook with empty input
    pre_hook = getattr(pu, 'requires_grad_pre_hook', None)
    if pre_hook is None:
        # find it inside requires_grad_for_gradient_checkpointing scope - use functional check
        notes.append('no_global_pre_hook')
    else:
        try:
            class M(torch.nn.Module):
                def forward(self, x): return x
            m = M()
            # Empty tuple input — should not raise after the fix
            try:
                pre_hook(m, ())
                hook_handles_empty = True
                notes.append('pre_hook_handles_empty')
            except RuntimeError as re:
                if 'Failed to make input require gradients' in str(re):
                    notes.append('pre_hook_still_crashes')
                else:
                    notes.append(f'pre_hook_other_runtime:{str(re)[:60]}')
            except Exception as e:
                notes.append(f'pre_hook_exc:{type(e).__name__}:{str(e)[:60]}')
        except Exception as e:
            notes.append(f'hook_invoke_setup_fail:{e}')
except Exception as e:
    notes.append(f'peft_utils_unavailable:{type(e).__name__}:{str(e)[:80]}')

# Approach 3: check that FastIdefics3Model overrides get_input_embeddings
try:
    import importlib, glob, ast
    mod_files = sorted(glob.glob('unsloth/models/*idefics*.py'))
    if mod_files:
        src = open(mod_files[0]).read()
        if 'get_input_embeddings' in src:
            notes.append('overrides_get_input_embeddings')
            score += 1
        # Or patches the encoder instance with a get_input_embeddings lambda
        if 'encoder.get_input_embeddings' in src or '_patch_vision_encoder' in src or '_patch_idefics3' in src.lower():
            notes.append('patches_encoder')
            score += 1
        # Or monkey-patches the hook
        if 'requires_grad_pre_hook' in src or 'requires_grad_for_gradient_checkpointing' in src:
            notes.append('patches_hook')
            score += 1
except Exception as e:
    notes.append(f'static_check_fail:{e}')

if hook_handles_empty:
    score += 3  # Strongest signal: actually fixed at runtime

print(f"SCORE:{score}|" + ",".join(notes))
PYEOF
)
echo "  Result: $HOOK_RES"
HOOK_SCORE=$(echo "$HOOK_RES" | grep -oE 'SCORE:[0-9]+' | head -1 | sed 's/SCORE://')
HOOK_SCORE=${HOOK_SCORE:-0}
if [ "$HOOK_SCORE" -ge 4 ]; then
    add_reward 0.15
    echo "  PASS (full hook fix)"
elif [ "$HOOK_SCORE" -ge 2 ]; then
    add_reward 0.10
    echo "  GOOD (partial fix)"
elif [ "$HOOK_SCORE" -ge 1 ]; then
    add_reward 0.05
    echo "  WEAK"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 10 (0.10) — F2P BEHAVIORAL: full unsloth.models package imports
# AND FastIdefics3Model symbol is reachable from unsloth.models
# ════════════════════════════════════════════════════════════════
echo "--- Check 10 [0.10] F2P BEHAVIORAL: top-level package import ---"
PKG_RES=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/_cpu_compat.py').read())
try:
    import unsloth.models as M
    has = hasattr(M, 'FastIdefics3Model')
    has_existing = all(hasattr(M, n) for n in ['FastModel','FastVisionModel','FastLanguageModel'])
    if has and has_existing:
        print("OK")
    elif has_existing:
        print("PARTIAL:no_idefics_attr")
    else:
        print("FAIL:missing_existing")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{str(e)[:150]}")
PYEOF
)
echo "  Result: $PKG_RES"
if echo "$PKG_RES" | grep -q "^OK"; then
    add_reward 0.10
    echo "  PASS"
elif echo "$PKG_RES" | grep -q "^PARTIAL"; then
    add_reward 0.04
    echo "  PARTIAL"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 11 (0.08) — F2P BEHAVIORAL: FastIdefics3Model has callable from_pretrained
# ════════════════════════════════════════════════════════════════
echo "--- Check 11 [0.08] F2P BEHAVIORAL: from_pretrained callable ---"
FP_RES=$(python3 << 'PYEOF' 2>&1
exec(open('/tmp/_cpu_compat.py').read())
try:
    import unsloth.models as M
    cls = getattr(M, 'FastIdefics3Model', None)
    if cls is None:
        print("FAIL:no_class")
    else:
        fp = getattr(cls, 'from_pretrained', None)
        if fp is None or not callable(fp):
            print("FAIL:no_from_pretrained")
        else:
            # Check signature accepts a model name
            import inspect
            try:
                sig = inspect.signature(fp)
                params = list(sig.parameters.keys())
                if len(params) >= 1:
                    print(f"OK:params={params[:5]}")
                else:
                    print("PARTIAL:no_params")
            except Exception:
                print("OK:signature_unavailable")
except Exception as e:
    print(f"FAIL:{type(e).__name__}:{str(e)[:120]}")
PYEOF
)
echo "  Result: $FP_RES"
if echo "$FP_RES" | grep -q "^OK"; then
    add_reward 0.08
    echo "  PASS"
elif echo "$FP_RES" | grep -q "^PARTIAL"; then
    add_reward 0.03
    echo "  PARTIAL"
else
    echo "  FAIL"
fi

# ════════════════════════════════════════════════════════════════
# CHECK 12 (0.05) — Quality: implementation depth (LoRA targets / patch logic)
# ════════════════════════════════════════════════════════════════
echo "--- Check 12 [0.05] Quality: implementation depth ---"
DEPTH_SCORE=0
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    DEPTH_SCORE=$(python3 << PYEOF
src = open("$IDEFICS_PY").read()
score = 0
# References to projection/LoRA targets
import re
if re.search(r'(target_modules|lora_targets|q_proj|k_proj|v_proj|o_proj)', src):
    score += 1
# References to vision/text components
if re.search(r'(vision_model|text_model|connector|modality_projection)', src):
    score += 1
# Has substantial body (>50 non-blank lines)
nonblank = sum(1 for L in src.splitlines() if L.strip() and not L.strip().startswith('#'))
if nonblank >= 30: score += 1
if nonblank >= 80: score += 1
print(score)
PYEOF
)
fi
DEPTH_SCORE=$(echo "$DEPTH_SCORE" | tail -1)
case "$DEPTH_SCORE" in
    4) add_reward 0.05 ;;
    3) add_reward 0.04 ;;
    2) add_reward 0.025 ;;
    1) add_reward 0.01 ;;
    *) : ;;
esac
echo "  Depth: $DEPTH_SCORE/4"

# ════════════════════════════════════════════════════════════════
# Finalize
# ════════════════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════════"
echo "FINAL REWARD: $REWARD"
echo "════════════════════════════════════════════════════════════════"
echo "$REWARD" > "$LOG_DIR/reward.txt"
exit 0