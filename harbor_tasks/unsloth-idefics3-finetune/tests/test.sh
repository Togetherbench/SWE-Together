#!/bin/bash
set +e

REWARD=0.0
WORKSPACE="/workspace/unsloth"
LOG_DIR="/logs/verifier"
mkdir -p "$LOG_DIR"

add_reward() {
    REWARD=$(awk -v r="$REWARD" -v a="$1" 'BEGIN{s=r+a; if(s>1.0) s=1.0; printf "%.4f", s}')
}

finish() {
    echo "$REWARD" > "$LOG_DIR/reward.txt"
    exit 0
}

cd "$WORKSPACE" 2>/dev/null || finish

# ════════════════════════════════════════════════════════════════
# P2P GATE — Source files must parse. Failure = 0.0 (regression guard).
# Note: these MUST pass on the unmodified base, so they grant no reward.
# ════════════════════════════════════════════════════════════════
PARSE_OK=$(python3 << 'PYEOF'
import ast, os
files = ['unsloth/models/vision.py', 'unsloth/models/__init__.py']
for f in files:
    if not os.path.exists(f):
        print("FAIL"); break
    try:
        ast.parse(open(f).read())
    except SyntaxError:
        print("FAIL"); break
else:
    print("OK")
PYEOF
)
if ! echo "$PARSE_OK" | grep -q "^OK"; then
    echo "P2P regression: source files don't parse"
    finish
fi

# P2P GATE — existing VLM entries preserved (must hold on base too)
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
    print("OK" if (found and needed.issubset(set(found))) else "FAIL")
except Exception:
    print("FAIL")
PYEOF
)
if ! echo "$EXIST_OK" | grep -q "^OK"; then
    echo "P2P regression: VLLM_SUPPORTED_VLM lost existing entries"
    finish
fi

# P2P GATE — existing exports preserved
EXPORTS_OK=$(python3 << 'PYEOF'
src = open('unsloth/models/__init__.py').read()
needed = ['FastLlamaModel', 'FastModel', 'FastVisionModel', 'FastLanguageModel']
print('OK' if all(n in src for n in needed) else 'FAIL')
PYEOF
)
if ! echo "$EXPORTS_OK" | grep -q "^OK"; then
    echo "P2P regression: existing exports lost"
    finish
fi

# Find candidate idefics module created by agent
IDEFICS_PY=$(python3 << 'PYEOF'
import glob, ast, os
candidates = sorted(glob.glob('unsloth/models/*idefics*.py'))
if not candidates:
    original = {'granite.py','llama.py','qwen2.py','mistral.py','gemma.py','gemma3.py',
                'vision.py','__init__.py','mapper.py','loader.py','cohere.py','dbrx.py',
                'phi3.py','phi4.py','_utils.py','dpo.py','rl.py','rl_replacements.py',
                'sentence_transformer.py','falcon_h1.py','granite.py'}
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
echo "Idefics module: ${IDEFICS_PY:-NOT FOUND}"

# ════════════════════════════════════════════════════════════════
# F2P GATES — every check below FAILS on the unmodified base
# ════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# F2P 1 [0.09] — idefics3 registered in VLLM_SUPPORTED_VLM
# Fails on base (entry doesn't exist).
# ─────────────────────────────────────────────
echo "--- F2P 1 [0.09] idefics3 in VLLM_SUPPORTED_VLM ---"
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
    add_reward 0.09
    echo "  PASS"
else
    echo "  FAIL"
fi

# ─────────────────────────────────────────────
# F2P 2 [0.09] — FastIdefics3Model imported in __init__.py from a sibling module
# Fails on base.
# ─────────────────────────────────────────────
echo "--- F2P 2 [0.09] FastIdefics3Model imported in __init__.py ---"
EXPORT_FOUND=$(python3 << 'PYEOF'
import re
src = open('unsloth/models/__init__.py').read()
# Match: from .<mod> import ... FastIdefics3Model ...
if re.search(r'from\s+\.\w+\s+import\s+[^\n#]*FastIdefics3Model', src):
    print("OK")
else:
    print("MISS")
PYEOF
)
if echo "$EXPORT_FOUND" | grep -q "^OK"; then
    add_reward 0.09
    echo "  PASS"
else
    echo "  FAIL"
fi

# ─────────────────────────────────────────────
# F2P 3 [0.09] — A new idefics module file exists with a FastIdefics3Model class
# defined (substantive: has at least one method body). Fails on base (no module).
# ─────────────────────────────────────────────
echo "--- F2P 3 [0.09] FastIdefics3Model class defined ---"
CLASS_DEFINED="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    CLASS_DEFINED=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import ast, sys
path = sys.argv[1]
try:
    src = open(path).read()
    tree = ast.parse(src)
except Exception:
    print("MISS"); sys.exit(0)
ok = False
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and 'Idefics3' in node.name:
        # has at least one function defined
        for item in node.body:
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                ok = True; break
        # Or inherits from a base class (subclass approach is valid)
        if node.bases:
            ok = True
        if ok: break
print("OK" if ok else "MISS")
PYEOF
)
fi
if echo "$CLASS_DEFINED" | grep -q "^OK"; then
    add_reward 0.09
    echo "  PASS"
else
    echo "  FAIL"
fi

# ─────────────────────────────────────────────
# F2P 4 [0.09] — from_pretrained delegates to a real Idefics3 HF class
# (i.e. references Idefics3ForConditionalGeneration or AutoModelForVision2Seq).
# Fails on base (no such reference in any models/ file outside vision.py).
# ─────────────────────────────────────────────
echo "--- F2P 4 [0.09] from_pretrained references Idefics3 HF class ---"
FP_OK="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    FP_OK=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import ast, sys, re
path = sys.argv[1]
src = open(path).read()
try:
    tree = ast.parse(src)
except Exception:
    print("MISS"); sys.exit(0)

has_from_pretrained = False
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and 'Idefics3' in node.name:
        for item in node.body:
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name == 'from_pretrained':
                has_from_pretrained = True

# Either references Idefics3ForConditionalGeneration directly, OR inherits/uses
# FastVisionModel/FastBaseModel/FastModel which dispatches via AutoModelForVision2Seq.
references_hf = bool(re.search(r'Idefics3ForConditionalGeneration|AutoModelForVision2Seq', src))
inherits_fast = bool(re.search(r'class\s+\w*Idefics3\w*\s*\(\s*Fast(VisionModel|BaseModel|Model)', src))

print("OK" if has_from_pretrained and (references_hf or inherits_fast) else "MISS")
PYEOF
)
fi
if echo "$FP_OK" | grep -q "^OK"; then
    add_reward 0.09
    echo "  PASS"
else
    # Partial: has the class hierarchy even without explicit from_pretrained body
    if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
        INHERITS=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
print("OK" if re.search(r'class\s+\w*Idefics3\w*\s*\(\s*Fast(VisionModel|BaseModel|Model)', src) else "MISS")
PYEOF
)
        if echo "$INHERITS" | grep -q "^OK"; then
            add_reward 0.045
            echo "  PARTIAL (inherits Fast* base)"
        else
            echo "  FAIL"
        fi
    else
        echo "  FAIL"
    fi
fi

# ─────────────────────────────────────────────
# F2P 5 [0.09] — Hook compatibility fix is present.
# Either:
#   (a) idefics module patches/wraps requires_grad_pre_hook (or peft_utils), OR
#   (b) idefics module overrides/patches get_input_embeddings to return a
#       proper text embedding layer
# Fails on base (no such code).
# ─────────────────────────────────────────────
echo "--- F2P 5 [0.09] Hook compatibility fix present ---"
HOOK_OK="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    HOOK_OK=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import sys, re
src = open(sys.argv[1]).read()

# Approach (a): patches the hook in unsloth_zoo.peft_utils
patches_hook = bool(re.search(
    r'(requires_grad_pre_hook|requires_grad_for_gradient_checkpointing|peft_utils)',
    src
))
# Must look like an actual patch/wrap (not just a comment): assigns attribute or
# defines a replacement function.
hook_active = patches_hook and bool(re.search(
    r'(peft_utils\.\w+\s*=|_zoo_peft_utils\.\w+\s*=|setattr\s*\(\s*\w*peft_utils|def\s+\w*requires_grad_pre_hook)',
    src
))

# Approach (b): provides get_input_embeddings override / patches encoder
patches_embed = bool(re.search(r'get_input_embeddings', src)) and bool(re.search(
    r'(get_input_embeddings\s*=|def\s+get_input_embeddings|encoder\.get_input_embeddings)',
    src
))

print("OK" if (hook_active or patches_embed) else "MISS")
PYEOF
)
fi
# Also accept if the agent edited unsloth_zoo's peft_utils.py directly to fix hook
if ! echo "$HOOK_OK" | grep -q "^OK"; then
    PATCH_ZOO=$(python3 << 'PYEOF'
import os, glob, re
# Look for the installed unsloth_zoo peft_utils
candidates = glob.glob('/usr/local/lib/python*/site-packages/unsloth_zoo/peft_utils.py') + \
             glob.glob('/usr/lib/python*/site-packages/unsloth_zoo/peft_utils.py')
for c in candidates:
    try:
        src = open(c).read()
    except Exception:
        continue
    # The base file uses register_forward_pre_hook for the still_need_patching branch.
    # A fix would either change to forward_hook (post-hook) in the fallback branch,
    # add last_hidden_state handling in the post-hook, or guard empty inputs gracefully.
    # Extract the still_need_patching fallback block specifically:
    fallback = re.search(r'if still_need_patching:\s*\n(.*?)(?:pass\n|$)', src, re.S)
    fallback_txt = fallback.group(1) if fallback else ''
    # Check if fallback uses post-hook instead of pre-hook
    fallback_uses_post = bool(re.search(r'register_forward_hook\s*\(', fallback_txt)) and \
                         not bool(re.search(r'register_forward_pre_hook\s*\(', fallback_txt))
    # Check if last_hidden_state handling was added (canonical fix marker)
    has_last_hidden = 'last_hidden_state' in src
    # Check if pre_hook guards empty input with return (not raise)
    guards_empty = bool(re.search(r'def\s+requires_grad_pre_hook[\s\S]{0,400}len\s*\(\s*input[s]?\s*\)\s*==\s*0[\s\S]{0,50}return', src))
    if fallback_uses_post or has_last_hidden or guards_empty:
        print("OK"); break
else:
    print("MISS")
PYEOF
)
    if echo "$PATCH_ZOO" | grep -q "^OK"; then
        HOOK_OK="OK"
    fi
fi
if echo "$HOOK_OK" | grep -q "^OK"; then
    add_reward 0.09
    echo "  PASS"
else
    echo "  FAIL"
fi

# ─────────────────────────────────────────────
# F2P 6 [0.06] — LoRA target_modules / projection layer configuration present
# in the new idefics module. Fails on base (no module).
# ─────────────────────────────────────────────
echo "--- F2P 6 [0.06] LoRA target_modules configuration ---"
LORA_OK="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    LORA_OK=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
# Check for at least 3 of typical LoRA projection target names, OR a target_modules list,
# OR delegation to default_lora_targets / get_peft_regex.
proj_names = ['q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj']
hits = sum(1 for n in proj_names if n in src)
has_targets_kw = bool(re.search(r'target_modules\s*=', src))
delegates = bool(re.search(r'(default_lora_targets|get_peft_regex|FastVisionModel|FastBaseModel\.get_peft_model|FastModel\.get_peft_model)', src))
print("OK" if (hits >= 3 or has_targets_kw or delegates) else "MISS")
PYEOF
)
fi
if echo "$LORA_OK" | grep -q "^OK"; then
    add_reward 0.06
    echo "  PASS"
else
    echo "  FAIL"
fi

# ─────────────────────────────────────────────
# F2P 7 [0.09] — Behavioral: import the new module via AST-driven exec test.
# We synthesize a minimal scenario: the agent's idefics module must be importable
# in the sense that its source compiles AND defines FastIdefics3Model symbol at
# module-top-level (verified via AST, not by actually executing — execution would
# pull in heavy deps not present in CPU test env).
# Additionally verifies that __init__.py's import line, if executed in isolation,
# would resolve to the agent's new module name.
# Fails on base: there is no idefics module / no FastIdefics3Model symbol.
# ─────────────────────────────────────────────
echo "--- F2P 7 [0.09] FastIdefics3Model symbol resolvable from new module ---"
SYMBOL_OK="MISS"
if [ -n "$IDEFICS_PY" ] && [ -f "$IDEFICS_PY" ]; then
    SYMBOL_OK=$(python3 - "$IDEFICS_PY" << 'PYEOF'
import ast, sys, os, re
path = sys.argv[1]
src = open(path).read()
try:
    tree = ast.parse(src)
except SyntaxError:
    print("MISS"); sys.exit(0)

# Top-level symbol FastIdefics3Model must exist (class def, assignment, or in __all__).
top_names = set()
for node in tree.body:
    if isinstance(node, ast.ClassDef):
        top_names.add(node.name)
    elif isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name):
                top_names.add(t.id)
    elif isinstance(node, ast.FunctionDef):
        top_names.add(node.name)

has_symbol = 'FastIdefics3Model' in top_names

# Cross-check: __init__.py imports it from this exact module basename
mod_name = os.path.splitext(os.path.basename(path))[0]
init_src = open('unsloth/models/__init__.py').read()
import_pat = re.compile(
    r'from\s+\.' + re.escape(mod_name) + r'\s+import\s+[^\n#]*FastIdefics3Model'
)
init_imports_correctly = bool(import_pat.search(init_src))

print("OK" if (has_symbol and init_imports_correctly) else "MISS")
PYEOF
)
fi
if echo "$SYMBOL_OK" | grep -q "^OK"; then
    add_reward 0.09
    echo "  PASS"
else
    echo "  FAIL"
fi

echo ""
echo "Final reward (before upstream gates): $REWARD"
echo "$REWARD" > "$LOG_DIR/reward.txt"

# ---- inner-claude upstream gates ----
GATES_FILE="$LOG_DIR/gates.json"
: > "$GATES_FILE"

# F2P upstream gate: idefics.py exists and compiles
echo "--- Upstream F2P: idefics.py py_compile ---"
if python3 -m py_compile unsloth/models/idefics.py 2>/dev/null; then
    echo '{"id": "f2p_upstream_idefics_py_compile", "passed": true, "detail": "idefics.py compiles"}' >> "$GATES_FILE"
    echo "  PASS"
else
    echo '{"id": "f2p_upstream_idefics_py_compile", "passed": false, "detail": "idefics.py missing or syntax error"}' >> "$GATES_FILE"
    echo "  FAIL"
fi

# F2P upstream gate: idefics3 registered and FastIdefics3Model exported
echo "--- Upstream F2P: idefics3 registration + export ---"
REG_RESULT=$(python3 << 'REGEOF'
import ast, re, sys
try:
    src = open('unsloth/models/vision.py').read()
    tree = ast.parse(src)
    found = False
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == 'VLLM_SUPPORTED_VLM':
                    if isinstance(node.value, ast.List):
                        vals = [e.value for e in node.value.elts if isinstance(e, ast.Constant)]
                        if 'idefics3' in vals: found = True
    assert found, 'idefics3 not in VLLM_SUPPORTED_VLM'
    init_src = open('unsloth/models/__init__.py').read()
    assert re.search(r'from\s+\.\w+\s+import\s+[^\n#]*FastIdefics3Model', init_src), 'not imported'
    print("OK")
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
REGEOF
)
if echo "$REG_RESULT" | grep -q "^OK"; then
    echo '{"id": "f2p_upstream_idefics3_registration", "passed": true, "detail": "idefics3 registered and exported"}' >> "$GATES_FILE"
    echo "  PASS"
else
    echo '{"id": "f2p_upstream_idefics3_registration", "passed": false, "detail": "'"$REG_RESULT"'"}' >> "$GATES_FILE"
    echo "  FAIL"
fi

# P2P upstream gate: source files parse
echo "--- Upstream P2P: source files parse ---"
PARSE_RESULT=$(python3 -c "import ast; [ast.parse(open(f).read()) for f in ['unsloth/models/vision.py', 'unsloth/models/__init__.py']]; print('OK')" 2>&1)
if echo "$PARSE_RESULT" | grep -q "^OK"; then
    echo '{"id": "p2p_upstream_source_parse", "passed": true, "detail": "files parse OK"}' >> "$GATES_FILE"
    echo "  PASS"
else
    echo '{"id": "p2p_upstream_source_parse", "passed": false, "detail": "parse error"}' >> "$GATES_FILE"
    echo "  FAIL"
fi

# P2P upstream gate: existing VLM entries preserved
echo "--- Upstream P2P: VLM entries preserved ---"
VLM_RESULT=$(python3 << 'VLMEOF'
import ast
src = open('unsloth/models/vision.py').read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == 'VLLM_SUPPORTED_VLM':
                if isinstance(node.value, ast.List):
                    vals = set(e.value for e in node.value.elts if isinstance(e, ast.Constant))
                    needed = {'qwen2_5_vl','gemma3','mistral3','qwen3_vl'}
                    if needed.issubset(vals):
                        print('OK'); exit(0)
                    else:
                        print('FAIL'); exit(1)
print('FAIL')
exit(1)
VLMEOF
)
if echo "$VLM_RESULT" | grep -q "^OK"; then
    echo '{"id": "p2p_upstream_vlm_entries", "passed": true, "detail": "VLM entries preserved"}' >> "$GATES_FILE"
    echo "  PASS"
else
    echo '{"id": "p2p_upstream_vlm_entries", "passed": false, "detail": "VLM entries missing"}' >> "$GATES_FILE"
    echo "  FAIL"
fi

# P2P upstream gate: existing exports preserved
echo "--- Upstream P2P: exports preserved ---"
EXP_RESULT=$(python3 -c "src = open('unsloth/models/__init__.py').read(); assert all(n in src for n in ['FastLlamaModel', 'FastModel', 'FastVisionModel', 'FastLanguageModel']); print('OK')" 2>&1)
if echo "$EXP_RESULT" | grep -q "^OK"; then
    echo '{"id": "p2p_upstream_exports", "passed": true, "detail": "exports preserved"}' >> "$GATES_FILE"
    echo "  PASS"
else
    echo '{"id": "p2p_upstream_exports", "passed": false, "detail": "exports missing"}' >> "$GATES_FILE"
    echo "  FAIL"
fi

# ---- upstream reward adjustment ----
python3 << 'REWARDEOF'
import json, os

WEIGHTS = {"f2p_upstream_idefics_py_compile": 0.20, "f2p_upstream_idefics3_registration": 0.20}
P2P_REGRESSION = ["p2p_upstream_source_parse", "p2p_upstream_vlm_entries", "p2p_upstream_exports"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
hard_zero = False  # P2P_REGRESSION gates are informational only (v043 fix)
if hard_zero:
    reward = 0.0
else:
    # weighted-replace formula (c8bc168a standard, replaces additive)
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f' % reward)
REWARDEOF

echo "Final reward (after upstream gates):"
cat "$LOG_DIR/reward.txt"
# ---- end ----
exit 0