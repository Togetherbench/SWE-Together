#!/bin/bash
set +e

export PATH="/workspace/venv/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$REWARD_FILE")"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO=/workspace/sd-scripts

# Mock-init for behavioral imports
cat > /tmp/_vfp8mock.py << 'MOCKINIT'
import sys
from unittest.mock import MagicMock

_MODS = [
    "cv2", "PIL", "PIL.Image", "PIL.ImageFilter", "PIL.ImageOps",
    "einops", "einops.layers", "einops.layers.torch",
    "diffusers", "diffusers.schedulers",
    "diffusers.schedulers.scheduling_euler_ancestral_discrete",
    "diffusers.schedulers.scheduling_euler_discrete",
    "diffusers.schedulers.scheduling_flow_match_euler_discrete",
    "diffusers.configuration_utils", "diffusers.models",
    "diffusers.models.attention_processor", "diffusers.loaders",
    "diffusers.utils",
    "flash_attn", "flash_attn.flash_attn_interface", "flash_attn.bert_padding",
    "sageattention",
    "apex", "apex.normalization", "apex.optimizers",
    "xformers", "xformers.ops", "triton",
    "bitsandbytes", "bitsandbytes.nn", "quanto",
    "lycoris", "lycoris.config", "lycoris.modules", "peft",
    "gradio", "wandb", "tensorboard", "tensorboardX",
    "voluptuous", "open_clip", "open_clip.tokenizer",
    "accelerate", "accelerate.utils", "accelerate.logging",
    "transformers", "transformers.models",
    "safetensors", "safetensors.torch",
    "toml", "tqdm",
]
for _m in _MODS:
    if _m not in sys.modules:
        _mo = MagicMock()
        _mo.__spec__ = MagicMock()
        _mo.__all__ = []
        sys.modules[_m] = _mo

# Make safetensors.torch.load_file/save_file usable for tiny tests
import types
try:
    import safetensors.torch as _st
    import torch as _torch
    def _save_file(d, p, metadata=None):
        _torch.save(d, p)
    def _load_file(p, device="cpu"):
        return _torch.load(p, map_location=device)
    _st.save_file = _save_file
    _st.load_file = _load_file
except Exception:
    pass

sys.path.insert(0, "/workspace/sd-scripts")
MOCKINIT

# ═══════════════════════════════════════════════════════════════════
# P2P_REGRESSION: fp8_optimization_utils must be importable
# ═══════════════════════════════════════════════════════════════════
P2P=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
try:
    import library.fp8_optimization_utils as fou
    assert hasattr(fou, "optimize_state_dict_with_fp8")
    assert hasattr(fou, "apply_fp8_monkey_patch")
    print("PASS")
except Exception as e:
    print("FAIL:" + repr(e)[:200])
PYEOF
)
if [ "$P2P" = "PASS" ]; then
    emit p2p_fp8_utils_importable true ""
    P2P_OK=1
else
    emit p2p_fp8_utils_importable false "fp8_optimization_utils not importable: $P2P"
    P2P_OK=0
fi

# ═══════════════════════════════════════════════════════════════════
# T1 GATES
# ═══════════════════════════════════════════════════════════════════

# t1_f2p_target_keys_behavioral & t1_f2p_apply_monkey_patch_wired
# Behavioral: monkey-patch optimize_state_dict_with_fp8 + apply_fp8_monkey_patch,
# call load_lumina_model with fp8_scaled=True on a tiny synthetic checkpoint,
# inspect what was passed.
T1_BEHAVIORAL=$(python3 << 'PYEOF' 2>&1
exec(open("/tmp/_vfp8mock.py").read())
import os, sys, tempfile, json
import torch, torch.nn as nn

result = {"target_ok": False, "monkey_ok": False, "err": ""}

try:
    import library.fp8_optimization_utils as fou
    import library.lumina_util as lu
except Exception as e:
    result["err"] = "import:" + repr(e)[:200]
    print("RESULT:" + json.dumps(result)); sys.exit(0)

calls = {"optimize": [], "patch": []}

_orig_opt = getattr(fou, "optimize_state_dict_with_fp8", None)
_orig_patch = getattr(fou, "apply_fp8_monkey_patch", None)

def fake_optimize(*args, **kwargs):
    calls["optimize"].append({"args": args, "kwargs": kwargs})
    # return state_dict-ish first arg unchanged
    if args:
        return args[0]
    return kwargs.get("state_dict", {})

def fake_patch(*args, **kwargs):
    calls["patch"].append({"args": args, "kwargs": kwargs})
    return None

fou.optimize_state_dict_with_fp8 = fake_optimize
fou.apply_fp8_monkey_patch = fake_patch
# also patch in lu's namespace if imported there
if hasattr(lu, "optimize_state_dict_with_fp8"):
    lu.optimize_state_dict_with_fp8 = fake_optimize
if hasattr(lu, "apply_fp8_monkey_patch"):
    lu.apply_fp8_monkey_patch = fake_patch

# Find load_lumina_model
load_fn = getattr(lu, "load_lumina_model", None)
if load_fn is None:
    result["err"] = "no load_lumina_model"
    print("RESULT:" + json.dumps(result)); sys.exit(0)

import inspect
sig = inspect.signature(load_fn)
if "fp8_scaled" not in sig.parameters:
    result["err"] = "fp8_scaled not in signature"
    print("RESULT:" + json.dumps(result)); sys.exit(0)

# Build a minimal fake checkpoint and try to call.
# We'll patch model construction to skip actual forward.
import library.lumina_models as lm

# Stub NextDiT-ish: patch any model class lu uses to avoid real instantiation
# Strategy: patch torch.load and safetensors.torch.load_file to return dummy sd
import safetensors.torch as st

dummy_sd = {
    "layers.0.attention.wq.weight": torch.randn(32, 32),
    "layers.0.attention.wk.weight": torch.randn(32, 32),
    "layers.0.feed_forward.w1.weight": torch.randn(32, 32),
    "layers.0.attention_norm.weight": torch.randn(32),
    "layers.0.adaLN_modulation.1.weight": torch.randn(32, 32),
    "norm_final.weight": torch.randn(32),
}

def fake_load_file(p, device="cpu"):
    return {k: v.clone() for k, v in dummy_sd.items()}
st.load_file = fake_load_file

# Stub model class(es) likely instantiated
class StubModel(nn.Module):
    def __init__(self, *a, **kw):
        super().__init__()
        self.dummy = nn.Linear(4, 4)
    def load_state_dict(self, sd, strict=True, assign=False):
        return ([], [])
    def to(self, *a, **kw): return self
    def eval(self): return self
    def train(self, mode=True): return self

for name in dir(lm):
    obj = getattr(lm, name, None)
    if isinstance(obj, type) and issubclass(obj, nn.Module):
        try:
            setattr(lm, name, StubModel)
        except Exception:
            pass

# Write tmp file and call
with tempfile.NamedTemporaryFile(suffix=".safetensors", delete=False) as tf:
    torch.save(dummy_sd, tf.name)
    ckpt = tf.name

# Try various calling conventions
tried = []
for kwargs_try in [
    {"ckpt_path": ckpt, "dtype": torch.float32, "device": "cpu", "fp8_scaled": True},
    {"checkpoint_path": ckpt, "dtype": torch.float32, "device": "cpu", "fp8_scaled": True},
    {"fp8_scaled": True},
]:
    try:
        # Filter to actual sig params
        valid_kwargs = {k: v for k, v in kwargs_try.items() if k in sig.parameters}
        if "fp8_scaled" not in valid_kwargs:
            continue
        # Fill required positional args with sensible defaults
        bound_args = []
        for pname, p in sig.parameters.items():
            if pname in valid_kwargs:
                continue
            if p.default is inspect.Parameter.empty and p.kind in (
                inspect.Parameter.POSITIONAL_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD):
                # Provide sensible default by name
                if "path" in pname.lower() or "ckpt" in pname.lower():
                    valid_kwargs[pname] = ckpt
                elif "dtype" in pname.lower():
                    valid_kwargs[pname] = torch.float32
                elif "device" in pname.lower():
                    valid_kwargs[pname] = "cpu"
                elif pname == "args":
                    class A: pass
                    valid_kwargs[pname] = A()
                else:
                    valid_kwargs[pname] = None
        load_fn(**valid_kwargs)
        tried.append(("ok", valid_kwargs))
        break
    except SystemExit:
        break
    except Exception as e:
        tried.append(("err:" + repr(e)[:120], kwargs_try))
        continue

# Inspect what was recorded
if calls["optimize"]:
    for c in calls["optimize"]:
        all_args = list(c["args"]) + list(c["kwargs"].values())
        flat = []
        for a in all_args:
            if isinstance(a, (list, tuple)):
                flat.extend([str(x) for x in a])
            else:
                flat.append(str(a))
        joined = " ".join(flat)
        if "layers" in joined:
            result["target_ok"] = True
            break

if calls["patch"]:
    result["monkey_ok"] = True

result["tried"] = str(tried)[:300]
print("RESULT:" + json.dumps(result))
PYEOF
)

T1_LINE=$(echo "$T1_BEHAVIORAL" | grep -E '^RESULT:' | tail -1 | sed 's/^RESULT://')
if [ -z "$T1_LINE" ]; then
    emit t1_f2p_target_keys_behavioral false "behavioral probe did not run"
    emit t1_f2p_apply_monkey_patch_wired false "behavioral probe did not run"
else
    if echo "$T1_LINE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('target_ok') else 1)" 2>/dev/null; then
        emit t1_f2p_target_keys_behavioral true ""
    else
        emit t1_f2p_target_keys_behavioral false "optimize_state_dict_with_fp8 not invoked with 'layers' in target keys"
    fi
    if echo "$T1_LINE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('monkey_ok') else 1)" 2>/dev/null; then
        emit t1_f2p_apply_monkey_patch_wired true ""
    else
        emit t1_f2p_apply_monkey_patch_wired false "apply_fp8_monkey_patch not invoked"
    fi
fi

# t1_f2p_cli_flag_parses — parse via argparse
CLI=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
import sys, importlib, argparse

# Try lumina_train_network's setup_parser
ok = False
candidates = [
    ("lumina_train_network", ["setup_parser", "lumina_setup_parser"]),
]
try:
    mod = importlib.import_module("lumina_train_network")
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

# Find a parser-returning callable
parser = None
for attr in dir(mod):
    v = getattr(mod, attr)
    if callable(v) and ("parser" in attr.lower() or "arg" in attr.lower()):
        try:
            r = v()
            if isinstance(r, argparse.ArgumentParser):
                parser = r
                break
        except Exception:
            continue

# Fallback: instantiate trainer class and call its setup_parser
if parser is None:
    for attr in dir(mod):
        v = getattr(mod, attr)
        if isinstance(v, type):
            try:
                inst = v()
                if hasattr(inst, "setup_parser"):
                    r = inst.setup_parser()
                    if isinstance(r, argparse.ArgumentParser):
                        parser = r
                        break
            except Exception:
                continue

if parser is None:
    print("FAIL:no_parser"); sys.exit(0)

try:
    ns, _ = parser.parse_known_args(["--fp8_scaled"])
    if getattr(ns, "fp8_scaled", False) is True:
        print("PASS")
    else:
        print("FAIL:flag_not_true")
except SystemExit:
    print("FAIL:argparse_exit")
except Exception as e:
    print("FAIL:" + repr(e)[:120])
PYEOF
)
if [ "$CLI" = "PASS" ]; then
    emit t1_f2p_cli_flag_parses true ""
else
    emit t1_f2p_cli_flag_parses false "$CLI"
fi

# t1_f2p_train_network_wires_fp8 — AST: load_target_model body references fp8_scaled and load_lumina_model
WIRE=$(python3 << 'PYEOF' 2>&1 | tail -1
import ast, sys
path = "/workspace/sd-scripts/lumina_train_network.py"
try:
    src = open(path).read()
    tree = ast.parse(src)
except Exception as e:
    print("FAIL"); sys.exit(0)

ok = False
def check_func(fn_node):
    end = getattr(fn_node, "end_lineno", None)
    if not end: return False
    body = "\n".join(src.split("\n")[fn_node.lineno - 1: end])
    return ("fp8_scaled" in body) and ("load_lumina_model" in body)

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "load_target_model":
        if check_func(node):
            ok = True
            break

if not ok:
    # fallback: any function in file that loads lumina + references fp8
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and check_func(node):
            ok = True; break

print("PASS" if ok else "FAIL")
PYEOF
)
if [ "$WIRE" = "PASS" ]; then
    emit t1_f2p_train_network_wires_fp8 true ""
else
    emit t1_f2p_train_network_wires_fp8 false "load_target_model does not reference both fp8_scaled and load_lumina_model"
fi

# ═══════════════════════════════════════════════════════════════════
# T2 GATES
# ═══════════════════════════════════════════════════════════════════

# t2_f2p_target_keys_match_real_modules — read TARGET_KEYS, ensure it would match real Linear paths
T2A=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
import re, sys

target = None
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        # Extract string literals
        items = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        target = items
        break

if not target:
    print("FAIL:no_target_keys"); sys.exit(0)

# Real Lumina submodule prefixes — check that 'layers' is included AND
# that the keys list is not just empty/junk
real_prefixes_in_lumina = ["layers"]
matches = any(any(rp in t or t in rp for rp in real_prefixes_in_lumina) for t in target)
if matches and "layers" in " ".join(target):
    print("PASS")
else:
    print("FAIL:keys=" + str(target)[:80])
PYEOF
)
if [ "$T2A" = "PASS" ]; then
    emit t2_f2p_target_keys_match_real_modules true ""
else
    emit t2_f2p_target_keys_match_real_modules false "$T2A"
fi

# t2_f2p_exclude_keys_norm — behavioral: run optimize on a tiny model and confirm norm not quantized
T2B=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
import sys, re, torch, torch.nn as nn

# Read EXCLUDE_KEYS
exclude = None
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        exclude = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        break

if exclude is None:
    print("FAIL:no_exclude_keys"); sys.exit(0)

has_norm = any("norm" in e.lower() for e in exclude)
if not has_norm:
    print("FAIL:no_norm_in_exclude:" + str(exclude)[:80]); sys.exit(0)

# Behavioral: optimize a tiny state dict and confirm 'norm.*' keys do not get scale_weight
try:
    from library.fp8_optimization_utils import optimize_state_dict_with_fp8
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

sd = {
    "layers.0.attention.wq.weight": torch.randn(32, 32),
    "layers.0.feed_forward.w1.weight": torch.randn(32, 32),
    "layers.0.attention_norm.weight": torch.randn(32),
    "norm_final.weight": torch.randn(32),
}

target_keys = ["layers"]
try:
    new_sd = optimize_state_dict_with_fp8(sd, torch.device("cpu"), target_keys, exclude)
except TypeError:
    try:
        new_sd = optimize_state_dict_with_fp8(state_dict=sd, calc_device=torch.device("cpu"),
                                              target_layer_keys=target_keys, exclude_layer_keys=exclude)
    except Exception as e:
        print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)
except Exception as e:
    print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)

# Norm should NOT have a scale_weight
norm_quantized = any(k.startswith("norm_final") and ".scale_weight" in k for k in new_sd) or \
                 any("attention_norm" in k and ".scale_weight" in k for k in new_sd)
# At least one layers.* should have scale_weight
layers_quantized = any(k.startswith("layers.") and ".scale_weight" in k for k in new_sd)

if (not norm_quantized) and layers_quantized:
    print("PASS")
else:
    print("FAIL:norm_q={} layers_q={}".format(norm_quantized, layers_quantized))
PYEOF
)
if [ "$T2B" = "PASS" ]; then
    emit t2_f2p_exclude_keys_norm true ""
else
    emit t2_f2p_exclude_keys_norm false "$T2B"
fi

# ═══════════════════════════════════════════════════════════════════
# T3 GATES — adaLN_modulation must be excluded
# ═══════════════════════════════════════════════════════════════════

# t3_f2p_modulation_excluded — EXCLUDE_KEYS contains 'modulation'
T3A=$(python3 << 'PYEOF' 2>&1 | tail -1
import re, sys
exclude = None
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        exclude = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        break

if not exclude:
    print("FAIL:no_exclude")
    sys.exit(0)

if any("modulation" in e.lower() for e in exclude):
    print("PASS")
else:
    print("FAIL:no_modulation:" + str(exclude)[:120])
PYEOF
)
if [ "$T3A" = "PASS" ]; then
    emit t3_f2p_modulation_excluded true ""
else
    emit t3_f2p_modulation_excluded false "$T3A"
fi

# t3_f2p_modulation_not_quantized_behavior — run optimize, confirm adaLN_modulation NOT quantized
T3B=$(python3 << 'PYEOF' 2>&1 | tail -1
exec(open("/tmp/_vfp8mock.py").read())
import sys, re, torch

# Read EXCLUDE_KEYS dynamically (whatever the agent set)
exclude = []
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_EXCLUDE_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        exclude = re.findall(r'["\']([^"\']+)["\']', m.group(1))
        break

target = ["layers"]
for path in ["/workspace/sd-scripts/library/lumina_util.py",
             "/workspace/sd-scripts/library/lumina_models.py",
             "/workspace/sd-scripts/lumina_train_network.py"]:
    try:
        src = open(path).read()
    except FileNotFoundError:
        continue
    m = re.search(r'FP8_OPTIMIZATION_TARGET_KEYS\s*=\s*\[([^\]]*)\]', src, re.DOTALL)
    if m:
        target = re.findall(r'["\']([^"\']+)["\']', m.group(1)) or target
        break

try:
    from library.fp8_optimization_utils import optimize_state_dict_with_fp8
except Exception as e:
    print("FAIL:import:" + repr(e)[:120]); sys.exit(0)

sd = {
    "layers.0.attention.wq.weight": torch.randn(32, 32),
    "layers.0.feed_forward.w1.weight": torch.randn(32, 32),
    "layers.0.adaLN_modulation.1.weight": torch.randn(32, 32),
    "layers.0.attention_norm.weight": torch.randn(32),
}

try:
    new_sd = optimize_state_dict_with_fp8(sd, torch.device("cpu"), target, exclude)
except TypeError:
    try:
        new_sd = optimize_state_dict_with_fp8(state_dict=sd, calc_device=torch.device("cpu"),
                                              target_layer_keys=target, exclude_layer_keys=exclude)
    except Exception as e:
        print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)
except Exception as e:
    print("FAIL:opt:" + repr(e)[:120]); sys.exit(0)

mod_quantized = any("adaLN_modulation" in k and ".scale_weight" in k for k in new_sd)
attn_quantized = any("attention.wq" in k and ".scale_weight" in k for k in new_sd)

if (not mod_quantized) and attn_quantized:
    print("PASS")
else:
    print("FAIL:mod_q={} attn_q={}".format(mod_quantized, attn_quantized))
PYEOF
)
if [ "$T3B" = "PASS" ]; then
    emit t3_f2p_modulation_not_quantized_behavior true ""
else
    emit t3_f2p_modulation_not_quantized_behavior false "$T3B"
fi

# ═══════════════════════════════════════════════════════════════════
# T4 GATE — goal_2 (mul_cuda bug): scale_weight cast to input dtype
# Behavioral runtime check: invoke fp8_linear_forward_patch with an fp8
# scale_weight + bf16 input and confirm no NotImplementedError and that
# the output dtype matches the input dtype. AST fallback hardens against
# environments where fp8_optimization_utils cannot be imported under mock.
# ═══════════════════════════════════════════════════════════════════
T4=$(python3 << 'PYEOF' 2>&1
exec(open("/tmp/_vfp8mock.py").read())
import sys, json, re, os, ast, torch, torch.nn as nn

result = {"runtime_ok": False, "ast_ok": False, "err": ""}

# AST/source check first — robust, no diffusers deps required.
src_path = "/workspace/sd-scripts/library/fp8_optimization_utils.py"
src = ""
try:
    src = open(src_path).read()
except Exception as e:
    result["err"] = "no_source:" + repr(e)[:120]

if src:
    # Locate fp8_linear_forward_patch body
    try:
        tree = ast.parse(src)
        fn_body_src = None
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "fp8_linear_forward_patch":
                end = getattr(node, "end_lineno", None)
                if end:
                    fn_body_src = "\n".join(src.split("\n")[node.lineno - 1: end])
                break
    except Exception as e:
        fn_body_src = None
        result["err"] = (result.get("err") or "") + ";ast:" + repr(e)[:80]

    if fn_body_src:
        # Strip comments for robust matching
        no_comments = "\n".join(
            ln for ln in fn_body_src.split("\n")
            if ln.strip() and not ln.strip().startswith("#")
        )
        # Pattern A: `original_dtype = x.dtype` (canonical approach)
        a = re.search(r'original_dtype\s*=\s*x\.dtype', no_comments) is not None
        # Pattern B: scale_weight cast to x.dtype via .to(x.dtype) or .to(original_dtype where original_dtype is x.dtype)
        b = re.search(r'scale_weight(?:\s*\.\s*to\s*\(\s*(?:x\.dtype|original_dtype)\s*\))', no_comments) is not None
        # Pattern C: any explicit cast of scale_weight to the input compute dtype before multiply
        # e.g. scale = self.scale_weight.to(x.dtype) ; dequantized_weight * scale
        c = re.search(r'self\.scale_weight\s*\.\s*to\s*\(', no_comments) is not None
        # Pattern D: alternative — cast .to(x.dtype) applied to whatever holds the scale
        d = re.search(r'\.to\s*\(\s*x\.dtype\s*\)', no_comments) is not None
        # Pattern E (anti-gaming guard): pre-fix line still present unchanged
        prefix = re.search(
            r'original_dtype\s*=\s*self\.scale_weight\.dtype', no_comments
        ) is not None
        if (a or (b and c) or (c and d)) and not prefix:
            result["ast_ok"] = True

# Behavioral runtime check
try:
    import library.fp8_optimization_utils as fou
    fwd = getattr(fou, "fp8_linear_forward_patch", None)
    if fwd is not None:
        # Build a tiny nn.Linear with fp8 weight + fp8 scale_weight
        lin = nn.Linear(8, 8, bias=False)
        # Cast weight to fp8 to simulate post-optimize state
        try:
            lin.weight.data = lin.weight.data.to(torch.float8_e4m3fn)
        except Exception as _e:
            # fp8 cast not supported in this torch — abort runtime probe, ast still applies
            raise
        # Attach scale_weight in fp8 dtype to reproduce the user's symptom shape
        scale = torch.ones(8, 1, dtype=torch.float8_e4m3fn)
        lin.scale_weight = scale  # plain attr (not Parameter) is fine; fwd reads .scale_weight
        x = torch.randn(2, 8, dtype=torch.bfloat16)
        try:
            out = fwd(lin, x)
            # If we got here, no NotImplementedError was raised — the cast fix is present
            # Verify output dtype is the input's compute dtype (not fp8)
            if hasattr(out, "dtype") and out.dtype == x.dtype:
                result["runtime_ok"] = True
            elif hasattr(out, "dtype") and out.dtype != torch.float8_e4m3fn:
                # Some implementations may upcast to fp32; either way not fp8 is fine
                result["runtime_ok"] = True
        except NotImplementedError as e:
            result["err"] = (result.get("err") or "") + ";runtime_nie:" + repr(e)[:120]
        except RuntimeError as e:
            msg = repr(e)
            if "mul_cuda" in msg or "Float8" in msg or "not implemented" in msg:
                result["err"] = (result.get("err") or "") + ";runtime_rt:" + msg[:120]
            else:
                # Different runtime issue (e.g., shape) — fall back to AST verdict
                result["err"] = (result.get("err") or "") + ";runtime_other:" + msg[:120]
except Exception as e:
    result["err"] = (result.get("err") or "") + ";probe_err:" + repr(e)[:120]

# Pass if EITHER runtime probe succeeded OR the AST source check confirms the cast
result["pass"] = bool(result["runtime_ok"] or result["ast_ok"])
print("RESULT:" + json.dumps(result))
PYEOF
)
T4_LINE=$(echo "$T4" | grep -E '^RESULT:' | tail -1 | sed 's/^RESULT://')
if [ -z "$T4_LINE" ]; then
    emit t4_f2p_fp8_linear_forward_cast_fix false "goal_2 probe did not run"
else
    if echo "$T4_LINE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('pass') else 1)" 2>/dev/null; then
        emit t4_f2p_fp8_linear_forward_cast_fix true ""
    else
        # Surface a short diagnostic
        DETAIL=$(echo "$T4_LINE" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(('runtime_ok='+str(d.get('runtime_ok'))+' ast_ok='+str(d.get('ast_ok'))+' '+(d.get('err') or ''))[:180])" 2>/dev/null)
        emit t4_f2p_fp8_linear_forward_cast_fix false "$DETAIL"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
# Compute reward
# ═══════════════════════════════════════════════════════════════════

REWARD=$(python3 << PYEOF
import json
gates = []
with open("$GATES_FILE") as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: gates.append(json.loads(line))
        except: pass

# P2P_REGRESSION failures zero the reward
# Reconciled with v043 WEIGHTS (sonnet v3 final review 2026-06-06):
# behavioral gates that always fail in CPU sandbox are demoted to weight 0
# (kept in gates.json for diagnostics) and goal_2 (t4) carries its own gate.
weights = {
    "t1_f2p_train_network_wires_fp8": 0.25,
    "t2_f2p_target_keys_match_real_modules": 0.25,
    "t3_f2p_modulation_excluded": 0.25,
    "t4_f2p_fp8_linear_forward_cast_fix": 0.25,
}
p2p_fail = any(g["id"].startswith("p2p_") and not g["passed"] for g in gates)
if p2p_fail:
    print("0.0000")
else:
    r = 0.0
    for g in gates:
        if g["id"] in weights and g["passed"]:
            r += weights[g["id"]]
    print("{:.4f}".format(r))
PYEOF
)

printf "%s\n" "$REWARD" > "$REWARD_FILE"
echo "Reward: $REWARD"
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
# pytest_changed_tests: resolve TEST_FILES and inline into cmd
_RESOLVED=$(echo 'dGVzdHMvbGlicmFyeS90ZXN0X2x1bWluYV9tb2RlbHMucHkKdGVzdHMvbGlicmFyeS90ZXN0X2x1bWluYV91dGlsLnB5CnRlc3RzL3Rlc3RfbHVtaW5hX3RyYWluX25ldHdvcmsucHkKdGVzdHMvdGVzdF9sdW1pbmFfbWluaW1hbF9pbmZlcmVuY2UucHkKdGVzdHMvbGlicmFyeS90ZXN0X2ZwOF9vcHRpbWl6YXRpb25fdXRpbHMucHk=' | base64 -d | while read f; do test -n "$f" && test -f "/workspace/sd-scripts/$f" && echo "$f"; done | tr '\n' ' ')
if [ -n "$_RESOLVED" ]; then
    _TEMPLATE=$(echo 'Y2QgL3dvcmtzcGFjZS9zZC1zY3JpcHRzICYmIC93b3Jrc3BhY2UvdmVudi9iaW4vcHl0aG9uMyAtbSBweXRlc3QgLS10aW1lb3V0PTYwIC14IC0tdGI9c2hvcnQgJFRFU1RfRklMRVM=' | base64 -d)
    _FINAL_CMD="${_TEMPLATE/\$TEST_FILES/$_RESOLVED}"
    run_v043_gate p2p_upstream_62650655 'pytest_changed_tests' "$_FINAL_CMD"
else
    emit p2p_upstream_62650655 false 'no changed files exist on disk'
fi
run_v043_gate p2p_upstream_bad711cf 'py_compile_changed' 'cd /workspace/sd-scripts && /workspace/venv/bin/python3 -m py_compile library/lumina_models.py library/lumina_util.py lumina_train_network.py lumina_minimal_inference.py library/fp8_optimization_utils.py'

# Recompute reward using v043 weights.
# v3-rubric-final-review (sonnet 2026-06-06): the 5 "behavioral" gates above
# (t1_f2p_target_keys_behavioral, t1_f2p_apply_monkey_patch_wired,
#  t1_f2p_cli_flag_parses, t2_f2p_exclude_keys_norm,
#  t3_f2p_modulation_not_quantized_behavior) ALL fail in the CPU sandbox
# because diffusers.models.autoencoders is unavailable. test_manifest.yaml
# already demoted them to P2P_REGRESSION (weight 0.0). The v043 WEIGHTS dict
# is now reconciled to match: only the 3 structural F2P gates that actually
# run in the sandbox + the new goal_2 (mul_cuda cast fix) gate carry weight.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {
    "t1_f2p_train_network_wires_fp8": 0.25,
    "t2_f2p_target_keys_match_real_modules": 0.25,
    "t3_f2p_modulation_excluded": 0.25,
    "t4_f2p_fp8_linear_forward_cast_fix": 0.25,
}
P2P_REGRESSION = ["p2p_fp8_utils_importable"]
P2P_REGRESSION = ["p2p_upstream_62650655", "p2p_upstream_bad711cf"]
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
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
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

exit 0