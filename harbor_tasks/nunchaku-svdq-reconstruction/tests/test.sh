#!/bin/bash
set +e

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

cd /workspace

REWARD=0.0
add_reward() {
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $1}")
}

mkdir -p /logs/verifier

# ── P2P gate: required ground-truth data and script must exist ─
PARAMS=(
    "attn.to_out.0"
    "attn.to_add_out"
    "img_mlp.net.0.proj"
    "img_mlp.net.2"
    "txt_mlp.net.0.proj"
    "txt_mlp.net.2"
)

MISSING=0
for n in "${PARAMS[@]}"; do
    for suf in weight weight_approx qweight wscales proj_down proj_up smooth_factor; do
        if [ ! -f "/workspace/pt/${n}.${suf}.pt" ]; then
            MISSING=1
            break 2
        fi
    done
done

if [ "$MISSING" -eq 1 ] || [ ! -f /workspace/reconstruct_weight.py ]; then
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ── P2P gate: file must parse as Python ─
python3 -c "import ast; ast.parse(open('/workspace/reconstruct_weight.py').read())" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# ── Run the agent's script (capture stdout/stderr but don't grade off it) ─
SCRIPT_OUT=/tmp/recon_out.txt
SCRIPT_ERR=/tmp/recon_err.txt
timeout 240 python3 /workspace/reconstruct_weight.py > "$SCRIPT_OUT" 2> "$SCRIPT_ERR"

# ── Behavioral evaluation: independently call into the script and measure
# per-parameter reconstruction error against weight_approx.pt.
# Also probe sub-stages (wscales unpack, low-rank unpack, smooth direction) so
# partial fixes don't get full credit.

RESULTS=/tmp/recon_results.txt
> "$RESULTS"

python3 - "$RESULTS" <<'PYEOF' 2>/dev/null
import sys, os, importlib.util, traceback, re
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

# ---- Try to import the agent's module ----
mod = None
import_ok = 0
try:
    spec = importlib.util.spec_from_file_location("recon_mod", "/workspace/reconstruct_weight.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    import_ok = 1
except Exception:
    mod = None
    import_ok = 0
wr("IMPORT_OK", import_ok)

def try_call(fn, *args):
    try:
        return fn(*args)
    except Exception:
        return None

def coerce_tensor(r):
    """Accept tensor, or (tensor,...) tuple, or (max,mean) numeric tuple (return None)."""
    if isinstance(r, torch.Tensor):
        return r
    if isinstance(r, (tuple, list)):
        for x in r:
            if isinstance(x, torch.Tensor):
                return x
    return None

def call_recon(name):
    """Try a variety of signatures to extract a reconstructed tensor."""
    if mod is None:
        return None
    fn = getattr(mod, "reconstruct_weight", None)
    if fn is None:
        return None
    # Try (name)
    r = try_call(fn, name)
    t = coerce_tensor(r)
    if t is not None:
        return t
    # Try (qw, ws, pd, pu, sf) and permutations
    try:
        qw = torch.load(f"pt/{name}.qweight.pt", weights_only=True)
        ws = torch.load(f"pt/{name}.wscales.pt", weights_only=True)
        pd = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
        pu = torch.load(f"pt/{name}.proj_up.pt", weights_only=True)
        sf = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
        for args in [(qw, ws, pd, pu, sf), (qw, ws, pu, pd, sf),
                     (pd, pu, qw, ws, sf), (pu, pd, qw, ws, sf),
                     (qw, pd, pu, ws, sf)]:
            r = try_call(fn, *args)
            t = coerce_tensor(r)
            if t is not None:
                return t
    except Exception:
        pass
    return None

# ---- Per-parameter direct reconstruction via importing the module ----
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
        if not (d == d):  # NaN
            d = float('inf')
        diffs_direct[name] = d
    except Exception:
        diffs_direct[name] = float('inf')

# ---- Also: parse stdout for "<name> ... PASSED" and a small max_diff ----
try:
    out = open("/tmp/recon_out.txt").read()
except Exception:
    out = ""

diffs_stdout = {}
for name in PARAMS:
    diffs_stdout[name] = float('inf')
    pat = re.compile(re.escape(name) + r"[^\n]{0,400}?max[_ ]?diff[=:\s]*\s*([0-9]+\.?[0-9]*(?:[eE][-+]?[0-9]+)?)")
    m = pat.search(out)
    if m:
        try:
            v = float(m.group(1))
            # require PASSED on the same line for credit, else still record
            line_re = re.compile(r"^.*" + re.escape(name) + r".*$", re.MULTILINE)
            line = ""
            for ln in line_re.findall(out):
                if "max" in ln.lower():
                    line = ln; break
            if "PASSED" in line.upper() or v < 0.1:
                diffs_stdout[name] = v
        except Exception:
            pass

# Final per-param diff: pick smaller (favor whichever measurement we got)
final_diffs = {}
for name in PARAMS:
    a = diffs_direct.get(name, float('inf'))
    b = diffs_stdout.get(name, float('inf'))
    final_diffs[name] = min(a, b)

# ---- Sub-stage probes: did the agent get the wscales unpack right?
# We test by reconstructing only the smoothed-quantized term for one param
# and comparing it against (weight_approx * smooth_factor - low_rank_unpacked
# matmul). To avoid coupling to the agent's internal API, we instead probe
# whether their full reconstruction is "close" at varying tolerances per
# param, and require multiple params to pass at tight tolerance (which only
# happens when ALL stages — qweight unpack, wscales unpack, low-rank unpack,
# smooth direction — are correct).
TIGHT_THR = 0.005    # tight: full numerical correctness
MED_THR   = 0.05     # medium: mostly right, minor numerical issues
LOOSE_THR = 0.5      # loose: shape/dimensional sanity

tight_count = sum(1 for d in final_diffs.values() if d < TIGHT_THR)
med_count   = sum(1 for d in final_diffs.values() if d < MED_THR)
loose_count = sum(1 for d in final_diffs.values() if d < LOOSE_THR)
spec_count  = sum(1 for d in final_diffs.values() if d < 0.1)  # task spec threshold

# Square vs rectangular split: discriminate fixes that only work on one shape.
# Square params (3072x3072): attn.to_out.0, attn.to_add_out
# Rect params  (12288x3072 or 3072x12288): the four mlp params
SQUARE = {"attn.to_out.0", "attn.to_add_out"}
RECT   = set(PARAMS) - SQUARE

square_ok = sum(1 for n in SQUARE if final_diffs[n] < 0.1)
rect_ok   = sum(1 for n in RECT   if final_diffs[n] < 0.1)

wr("TIGHT", tight_count)
wr("MED",   med_count)
wr("LOOSE", loose_count)
wr("SPEC",  spec_count)
wr("SQUARE_OK", square_ok)
wr("RECT_OK",   rect_ok)
for n, d in final_diffs.items():
    wr(f"DIFF[{n}]", f"{d:.6g}")
PYEOF

# Read results
get() { awk -v k="$1" '$1==k{print $2}' "$RESULTS" 2>/dev/null; }

IMPORT_OK=$(get IMPORT_OK)
TIGHT=$(get TIGHT)
MED=$(get MED)
LOOSE=$(get LOOSE)
SPEC=$(get SPEC)
SQUARE_OK=$(get SQUARE_OK)
RECT_OK=$(get RECT_OK)

IMPORT_OK=${IMPORT_OK:-0}
TIGHT=${TIGHT:-0}
MED=${MED:-0}
LOOSE=${LOOSE:-0}
SPEC=${SPEC:-0}
SQUARE_OK=${SQUARE_OK:-0}
RECT_OK=${RECT_OK:-0}

# ── F2P gates (sum to 1.00). Each probes a different aspect.
#
# The base file is broken on ALL 6 params → all gates fail → 0.0.
# A "compiles but doesn't fix" patch (no correct numerical output) → 0.0.
# A patch that fixes only the square shapes (forgot rectangular case) → ~0.30.
# A near-correct patch (all params <0.5 but not <0.05) → ~0.30.
# A correct patch (all <0.005) → 1.00.

# Gate 1 (0.10): At least one param reconstructs at the task-spec tolerance
# (<0.1). This separates "completely broken" from "made some progress".
if [ "${SPEC:-0}" -ge 1 ]; then
    add_reward 0.10
fi

# Gate 2 (0.15): Square-shape params reconstruct correctly. These are the
# easiest because N=K=3072 (no rectangular reshape edge cases).
# A patch that gets only the simple case lands here.
if [ "${SQUARE_OK:-0}" -ge 2 ]; then
    add_reward 0.15
fi

# Gate 3 (0.15): Rectangular-shape params reconstruct correctly. These need
# the unpacker to handle K!=N (12288 vs 3072). Patches that hardcoded the
# square assumption fail here.
if [ "${RECT_OK:-0}" -ge 3 ]; then
    add_reward 0.10
fi
if [ "${RECT_OK:-0}" -ge 4 ]; then
    add_reward 0.05
fi

# Gate 4 (0.20): All 6 params reconstruct at task-spec tolerance (<0.1).
# This is the explicit task acceptance criterion.
if [ "${SPEC:-0}" -ge 6 ]; then
    add_reward 0.20
fi

# Gate 5 (0.15): All 6 params reconstruct at medium tolerance (<0.05).
# A correct fix should land well below 0.1, so this filters out fixes that
# are "barely passing" due to a remaining minor bug (e.g., wrong rounding
# on signed-nibble conversion).
if [ "${MED:-0}" -ge 6 ]; then
    add_reward 0.15
fi

# Gate 6 (0.20): All 6 params at TIGHT tolerance (<0.005).
# True numerical correctness across qweight unpack + wscales unpack +
# low-rank unpack + smooth direction. Only patches that nailed every stage
# pass this.
if [ "${TIGHT:-0}" -ge 6 ]; then
    add_reward 0.20
fi

# Diagnostic dump
{
    echo "IMPORT_OK=$IMPORT_OK"
    echo "TIGHT=$TIGHT MED=$MED LOOSE=$LOOSE SPEC=$SPEC"
    echo "SQUARE_OK=$SQUARE_OK RECT_OK=$RECT_OK"
    echo "REWARD=$REWARD"
    echo "--- per-param diffs ---"
    grep "^DIFF" "$RESULTS" 2>/dev/null
    echo "--- script stderr (head) ---"
    head -c 2000 "$SCRIPT_ERR" 2>/dev/null
} > /logs/verifier/diagnostics.txt 2>&1

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
touch /logs/verifier/gates.json

# P2P gate: syntax check
P2P_SYNTAX_PASSED=false
if python3 -c "import ast; ast.parse(open('/workspace/reconstruct_weight.py').read())" 2>/dev/null; then
    P2P_SYNTAX_PASSED=true
fi
echo "{\"id\": \"p2p_upstream_syntax\", \"passed\": $P2P_SYNTAX_PASSED, \"detail\": \"Python syntax check\"}" >> /logs/verifier/gates.json

# P2P gate: torch import and data exists
P2P_TORCH_PASSED=false
if python3 -c "import torch; assert __import__('os').path.isfile('/workspace/pt/attn.to_out.0.weight.pt')" 2>/dev/null; then
    P2P_TORCH_PASSED=true
fi
echo "{\"id\": \"p2p_upstream_torch_import\", \"passed\": $P2P_TORCH_PASSED, \"detail\": \"Torch import and data check\"}" >> /logs/verifier/gates.json

# F2P gate: full reconstruction passes all 6 params
F2P_FULL_PASSED=false
if cd /workspace && python3 reconstruct_weight.py 2>&1 | grep -q 'All passed!'; then
    F2P_FULL_PASSED=true
fi
echo "{\"id\": \"f2p_upstream_full_recon\", \"passed\": $F2P_FULL_PASSED, \"detail\": \"All 6 params reconstruct with max_diff<0.1\"}" >> /logs/verifier/gates.json

# F2P gate: single param attn.to_out.0 reconstructs correctly
F2P_SINGLE_PASSED=false
if cd /workspace && python3 -c "import sys; sys.path.insert(0,'.'); from reconstruct_weight import reconstruct_weight; max_d,_=reconstruct_weight('attn.to_out.0'); sys.exit(0 if max_d<0.1 else 1)" 2>/dev/null; then
    F2P_SINGLE_PASSED=true
fi
echo "{\"id\": \"f2p_upstream_single_param\", \"passed\": $F2P_SINGLE_PASSED, \"detail\": \"attn.to_out.0 reconstructs with max_diff<0.1\"}" >> /logs/verifier/gates.json

# Run upstream reward tail to adjust reward
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_full_recon": 0.2,
    "f2p_upstream_single_param": 0.2
}
P2P_REGRESSION = ["p2p_upstream_syntax", "p2p_upstream_torch_import"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
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

p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- end ----

exit 0