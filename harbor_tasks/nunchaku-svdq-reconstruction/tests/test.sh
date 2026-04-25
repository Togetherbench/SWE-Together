#!/bin/bash
set +e

cd /workspace

REWARD=0.0
add_reward() {
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $1}")
}

mkdir -p /logs/verifier

# ── P2P gate: groundtruth data must exist (regression guard, no reward) ─
if [ ! -f /workspace/pt/attn.to_out.0.weight_approx.pt ] || \
   [ ! -f /workspace/pt/attn.to_out.0.qweight.pt ] || \
   [ ! -f /workspace/reconstruct_weight.py ]; then
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ── P2P gate: file must parse as Python (regression guard, no reward) ──
python3 -c "import ast; ast.parse(open('/workspace/reconstruct_weight.py').read())" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ── Run the script and capture output (this is the F2P signal) ─────────
SCRIPT_OUT=/tmp/recon_out.txt
SCRIPT_ERR=/tmp/recon_err.txt
timeout 240 python3 /workspace/reconstruct_weight.py > "$SCRIPT_OUT" 2> "$SCRIPT_ERR"

# ── Behavioral check: per-parameter reconstruction correctness ──────────
# This is the heart of scoring. The base script is BROKEN — it produces
# diffs >> 0.1 on all 6 params. Only correct fixes pass.

RESULTS=/tmp/recon_results.txt
> "$RESULTS"

python3 - "$RESULTS" <<'PYEOF' 2>/dev/null
import sys, os, importlib.util, traceback
import torch

rf = sys.argv[1]
def wr(k, v):
    with open(rf, 'a') as f:
        f.write(f"{k} {v}\n")

sys.path.insert(0, "/workspace")
os.chdir("/workspace")

PARAMS = ["attn.to_out.0", "attn.to_add_out",
          "img_mlp.net.0.proj", "img_mlp.net.2",
          "txt_mlp.net.0.proj", "txt_mlp.net.2"]

# Strategy A: import the module and call reconstruct_weight() directly.
# Strategy B: parse the script's stdout for "<name>" + a small max_diff number.

# --- Strategy A: try to import and call ---
mod = None
try:
    spec = importlib.util.spec_from_file_location("recon_mod", "/workspace/reconstruct_weight.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception:
    mod = None

def call_recon(name):
    if mod is None:
        return None
    fn = getattr(mod, "reconstruct_weight", None)
    if fn is None:
        return None
    # Try (name) → tensor
    try:
        r = fn(name)
        if isinstance(r, torch.Tensor):
            return r
        # Some implementations return (max_diff, mean_diff)
    except Exception:
        pass
    # Try with explicit tensor args
    try:
        qw = torch.load(f"pt/{name}.qweight.pt", weights_only=True)
        ws = torch.load(f"pt/{name}.wscales.pt", weights_only=True)
        pd = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
        pu = torch.load(f"pt/{name}.proj_up.pt", weights_only=True)
        sf = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
        for args in [(qw, ws, pd, pu, sf), (qw, ws, pu, pd, sf),
                     (pd, pu, qw, ws, sf), (pu, pd, qw, ws, sf)]:
            try:
                r = fn(*args)
                if isinstance(r, torch.Tensor):
                    return r
            except Exception:
                continue
    except Exception:
        pass
    return None

diffs_direct = {}
for name in PARAMS:
    try:
        approx = torch.load(f"pt/{name}.weight_approx.pt", weights_only=True).float()
        recon = call_recon(name)
        if recon is None:
            diffs_direct[name] = float('inf')
            continue
        recon = recon.float()
        if recon.shape != approx.shape:
            if recon.shape == approx.shape[::-1]:
                recon = recon.T
            else:
                diffs_direct[name] = float('inf')
                continue
        d = (recon - approx).abs().max().item()
        diffs_direct[name] = d
    except Exception:
        diffs_direct[name] = float('inf')

# --- Strategy B: parse script stdout for "<name> ... max_diff=<num>" ---
# Many agent scripts print "<name>: max_diff=0.001234 ..."
import re
diffs_stdout = {}
try:
    out = open("/tmp/recon_out.txt").read()
except Exception:
    out = ""

for name in PARAMS:
    diffs_stdout[name] = float('inf')
    # Look for the param name followed by "max_diff" within ~200 chars and a float
    # Various formats: "name: max_diff=0.001" or "name max_diff=0.001"
    pat = re.compile(re.escape(name) + r"[^\n]{0,200}?max[_ ]?diff[=:]?\s*([0-9]+\.?[0-9]*(?:[eE][-+]?[0-9]+)?)")
    m = pat.search(out)
    if m:
        try:
            diffs_stdout[name] = float(m.group(1))
        except Exception:
            pass
    # Also check for "PASSED" marker on the line
    line_pat = re.compile(r"^.*" + re.escape(name) + r".*$", re.MULTILINE)
    for line in line_pat.findall(out):
        if "PASSED" in line.upper():
            # Extract any small number from line
            nums = re.findall(r"([0-9]+\.[0-9]+(?:[eE][-+]?[0-9]+)?)", line)
            if nums:
                try:
                    val = min(float(n) for n in nums)
                    diffs_stdout[name] = min(diffs_stdout[name], val)
                except Exception:
                    pass

# Use whichever is smaller (more favorable, but only if it's a real measurement)
final_diffs = {}
for name in PARAMS:
    a = diffs_direct.get(name, float('inf'))
    b = diffs_stdout.get(name, float('inf'))
    final_diffs[name] = min(a, b)

# Count tiers
tight = sum(1 for d in final_diffs.values() if d < 0.005)
med   = sum(1 for d in final_diffs.values() if d < 0.05)
loose = sum(1 for d in final_diffs.values() if d < 0.5)

# Also: did script print "All passed" / all 6 PASSED
all_passed_marker = 0
if "All passed" in out or "all passed" in out.lower():
    all_passed_marker = 1
passed_count = out.count("PASSED")

wr("TIGHT", tight)
wr("MED", med)
wr("LOOSE", loose)
wr("ALL_PASSED_MARKER", all_passed_marker)
wr("PASSED_COUNT", passed_count)
for n, d in final_diffs.items():
    wr(f"DIFF[{n}]", d)
PYEOF

# Read results
TIGHT=$(awk '/^TIGHT /{print $2}' "$RESULTS" 2>/dev/null)
MED=$(awk '/^MED /{print $2}' "$RESULTS" 2>/dev/null)
LOOSE=$(awk '/^LOOSE /{print $2}' "$RESULTS" 2>/dev/null)
ALLMARK=$(awk '/^ALL_PASSED_MARKER /{print $2}' "$RESULTS" 2>/dev/null)
PASSED_COUNT=$(awk '/^PASSED_COUNT /{print $2}' "$RESULTS" 2>/dev/null)

TIGHT=${TIGHT:-0}
MED=${MED:-0}
LOOSE=${LOOSE:-0}
ALLMARK=${ALLMARK:-0}
PASSED_COUNT=${PASSED_COUNT:-0}

# ── F2P gates (all behavioral; all FAIL on the un-modified buggy base) ─
# The base reconstruct_weight.py is broken: it produces large diffs on all 6
# params. Every gate below requires actual numerical correctness.

# Gate 1 (0.10): at least 3 params reconstruct loosely (diff < 0.5)
# This is the lowest bar — base produces inf/garbage → fails.
if [ "$LOOSE" -ge 3 ]; then
    add_reward 0.10
fi

# Gate 2 (0.15): all 6 params reconstruct loosely
if [ "$LOOSE" -ge 6 ]; then
    add_reward 0.15
fi

# Gate 3 (0.15): at least 3 params reconstruct at medium tolerance (<0.05)
if [ "$MED" -ge 3 ]; then
    add_reward 0.15
fi

# Gate 4 (0.20): all 6 params at medium tolerance (matches the <0.1 task spec)
if [ "$MED" -ge 6 ]; then
    add_reward 0.20
fi

# Gate 5 (0.20): all 6 params at tight tolerance (<0.005) — exact reconstruction
if [ "$TIGHT" -ge 6 ]; then
    add_reward 0.20
fi

# Gate 6 (0.10): script self-reports all 6 PASSED (behavioral end-to-end)
# Requires the script to actually run AND its own assertions to pass.
if [ "$PASSED_COUNT" -ge 6 ] && [ "$MED" -ge 6 ]; then
    add_reward 0.10
fi

# Gate 7 (0.10): script run produced "All passed" marker AND tight reconstruction
if [ "$ALLMARK" -ge 1 ] && [ "$TIGHT" -ge 6 ]; then
    add_reward 0.10
fi

echo "$REWARD" > /logs/verifier/reward.txt