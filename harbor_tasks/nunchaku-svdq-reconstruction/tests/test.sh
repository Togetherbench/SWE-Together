#!/bin/bash
# Verifier for nunchaku-svdq-reconstruction
# Scoring: 0.0 to 1.0 written to /logs/verifier/reward.txt
set +e

cd /workspace

REWARD=0.0
add_reward() {
    REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $1}")
}

mkdir -p /logs/verifier

# ── P2P sanity (0.10): file exists, parses, torch works ────────────────
P2P_PASS=0
python3 - <<'PYEOF' 2>/dev/null
import ast, sys
try:
    with open("/workspace/reconstruct_weight.py") as f:
        ast.parse(f.read())
    import torch
    t = torch.zeros(2,2)
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then
    P2P_PASS=1
    add_reward 0.05
fi

# P2P: groundtruth data exists
if [ -f /workspace/pt/attn.to_out.0.weight_approx.pt ] && \
   [ -f /workspace/pt/attn.to_out.0.qweight.pt ]; then
    add_reward 0.05
fi

# ── Structural (0.10): non-trivial helpers ─────────────────────────────
python3 - <<'PYEOF' 2>/dev/null
import ast, sys
try:
    src = open("/workspace/reconstruct_weight.py").read()
    tree = ast.parse(src)
except Exception:
    sys.exit(1)

fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]
non_main = [f for f in fns if f.name != "main"]

# Need at least 3 non-main funcs (qweight unpack, scale unpack, lowrank unpack, recon)
if len(non_main) < 3:
    sys.exit(2)

# Each helper should have non-trivial body
non_stub = 0
for f in non_main:
    body = [s for s in f.body
            if not isinstance(s, ast.Pass)
            and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
    if len(body) >= 3:
        non_stub += 1

if non_stub < 3:
    sys.exit(3)
sys.exit(0)
PYEOF
if [ $? -eq 0 ]; then
    add_reward 0.10
fi

# ── Behavioral: run script and parse output (0.20) ─────────────────────
SCRIPT_OUT=/tmp/recon_out.txt
SCRIPT_ERR=/tmp/recon_err.txt
timeout 180 python3 /workspace/reconstruct_weight.py > "$SCRIPT_OUT" 2> "$SCRIPT_ERR"
RC=$?

if [ $RC -eq 0 ] || [ $RC -eq 1 ]; then
    # script ran without crashing
    add_reward 0.05
fi

# Count how many param names appear with a max_diff number in output
PARAMS=("attn.to_out.0" "attn.to_add_out" "img_mlp.net.0.proj" "img_mlp.net.2" "txt_mlp.net.0.proj" "txt_mlp.net.2")
REPORTED=0
for p in "${PARAMS[@]}"; do
    if grep -qF "$p" "$SCRIPT_OUT" 2>/dev/null; then
        REPORTED=$((REPORTED+1))
    fi
done
if [ $REPORTED -ge 6 ]; then
    add_reward 0.15
elif [ $REPORTED -ge 3 ]; then
    add_reward 0.07
fi

# ── Behavioral: detailed correctness check (0.60) ─────────────────────
# Import the agent's module and check each subroutine + final result against
# weight_approx ground truth. This is the meat of the scoring.

RESULTS=/tmp/recon_results.txt
> "$RESULTS"

python3 - "$RESULTS" <<'PYEOF' 2>/dev/null
import sys, os, importlib.util, traceback
import torch

rf = sys.argv[1]
def wr(name, ok):
    with open(rf, 'a') as f:
        f.write(f"{name} {1 if ok else 0}\n")

sys.path.insert(0, "/workspace")
os.chdir("/workspace")

try:
    spec = importlib.util.spec_from_file_location("recon_mod", "/workspace/reconstruct_weight.py")
    mod = importlib.util.module_from_spec(spec)
    # protect against main() running on import
    _saved_name = mod.__name__
    spec.loader.exec_module(mod)
    IMPORT_OK = True
except Exception:
    traceback.print_exc()
    IMPORT_OK = False

wr("IMPORT", IMPORT_OK)
if not IMPORT_OK:
    sys.exit(0)

PARAMS = ["attn.to_out.0", "attn.to_add_out",
          "img_mlp.net.0.proj", "img_mlp.net.2",
          "txt_mlp.net.0.proj", "txt_mlp.net.2"]

# ── Find the agent's reconstruct_weight callable ─────────────────────
recon_fn = getattr(mod, "reconstruct_weight", None)

# Try invoking the agent's reconstruct_weight in a few signatures.
# It may return (max_diff, mean_diff) or a tensor or None.
def call_recon(name):
    """Call agent's reconstruct_weight however it's defined.
    Return reconstructed tensor if obtainable, else None."""
    if recon_fn is None:
        return None
    # try (name) signature
    try:
        r = recon_fn(name)
        if isinstance(r, torch.Tensor):
            return r
    except Exception:
        pass
    # try loading tensors and passing them
    try:
        qw = torch.load(f"pt/{name}.qweight.pt", weights_only=True)
        ws = torch.load(f"pt/{name}.wscales.pt", weights_only=True)
        pd = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
        pu = torch.load(f"pt/{name}.proj_up.pt", weights_only=True)
        sf = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
        for args in [(qw, ws, pd, pu, sf), (pd, pu, qw, ws, sf)]:
            try:
                r = recon_fn(*args)
                if isinstance(r, torch.Tensor):
                    return r
            except Exception:
                pass
    except Exception:
        pass
    return None

# ── Per-param: check final reconstruction matches weight_approx ─────
# Tier 1 (loose, diff<0.5):  param produced something close
# Tier 2 (medium, diff<0.05): proper reconstruction
# Tier 3 (tight, diff<0.005): exact reconstruction

per_param_loose = 0
per_param_med = 0
per_param_tight = 0
diffs = {}

for name in PARAMS:
    try:
        approx_path = f"pt/{name}.weight_approx.pt"
        if not os.path.exists(approx_path):
            diffs[name] = float('inf')
            continue
        approx = torch.load(approx_path, weights_only=True).float()

        recon = call_recon(name)
        if recon is None:
            diffs[name] = float('inf')
            continue

        recon = recon.float()
        if recon.shape != approx.shape:
            # try transpose
            if recon.shape == approx.shape[::-1]:
                recon = recon.T
            else:
                diffs[name] = float('inf')
                continue

        d = (recon - approx).abs().max().item()
        diffs[name] = d
        if d < 0.5:
            per_param_loose += 1
        if d < 0.05:
            per_param_med += 1
        if d < 0.005:
            per_param_tight += 1
    except Exception:
        diffs[name] = float('inf')

# Write counts
with open(rf, 'a') as f:
    f.write(f"LOOSE_COUNT {per_param_loose}\n")
    f.write(f"MED_COUNT {per_param_med}\n")
    f.write(f"TIGHT_COUNT {per_param_tight}\n")
    for n, d in diffs.items():
        f.write(f"DIFF[{n}] {d}\n")

# ── Independent subroutine probes ────────────────────────────────────
# Even if recon_fn is monolithic, try to probe individual unpack helpers
# by name-matching to verify quality. These contribute to reward but
# only if discoverable.

def find_callable(keywords, exclude=()):
    cands = []
    for attr in dir(mod):
        if attr.startswith("_"): continue
        low = attr.lower()
        if any(ex in low for ex in exclude):
            continue
        if all(kw in low for kw in keywords):
            obj = getattr(mod, attr)
            if callable(obj):
                cands.append((attr, obj))
    return cands

# qweight unpack: try to call any helper that takes a qweight-shaped int8 tensor
qweight_unpack_ok = 0
scale_unpack_ok = 0
lowrank_unpack_ok = 0

# Use attn.to_out.0 as canonical case
try:
    qw = torch.load("pt/attn.to_out.0.qweight.pt", weights_only=True)  # (3072, 1536) int8
    ws = torch.load("pt/attn.to_out.0.wscales.pt", weights_only=True)  # (48, 3072)
    pd = torch.load("pt/attn.to_out.0.proj_down.pt", weights_only=True) # (3072, 128)
    pu = torch.load("pt/attn.to_out.0.proj_up.pt", weights_only=True)   # (3072, 128)

    # Try unpack helpers - any callable returning (N, K) shape int from qw
    for attr, fn in find_callable(["unpack"], exclude=("scale", "lowrank", "low_rank", "proj")):
        try:
            r = fn(qw)
            if isinstance(r, torch.Tensor) and r.shape == (3072, 3072):
                rmin, rmax = r.min().item(), r.max().item()
                # signed 4-bit: -8..7
                if rmin >= -8 and rmax <= 7:
                    qweight_unpack_ok = 1
                    break
        except Exception:
            continue

    # scale unpack
    for attr, fn in find_callable(["scale"]):
        try:
            r = fn(ws)
            if isinstance(r, torch.Tensor):
                # should produce (3072, 48) or similar
                if r.numel() == ws.numel() and r.shape != ws.shape:
                    scale_unpack_ok = 1
                    break
                if r.shape == (3072, 48):
                    scale_unpack_ok = 1
                    break
        except Exception:
            continue

    # lowrank unpack
    for attr, fn in find_callable(["lowrank"]) + find_callable(["low_rank"]) + find_callable(["proj"]):
        try:
            # try with down kwarg
            for kwargs in [{"down": True}, {"down": False}, {}]:
                try:
                    r = fn(pd, **kwargs)
                    if isinstance(r, torch.Tensor) and r.numel() == pd.numel():
                        lowrank_unpack_ok = 1
                        break
                except Exception:
                    pass
            if lowrank_unpack_ok:
                break
        except Exception:
            continue
except Exception:
    pass

with open(rf, 'a') as f:
    f.write(f"SUB_QW {qweight_unpack_ok}\n")
    f.write(f"SUB_SC {scale_unpack_ok}\n")
    f.write(f"SUB_LR {lowrank_unpack_ok}\n")
PYEOF

# Parse results and award reward
if [ -f "$RESULTS" ]; then
    LOOSE=$(grep "^LOOSE_COUNT " "$RESULTS" | awk '{print $2}')
    MED=$(grep "^MED_COUNT " "$RESULTS" | awk '{print $2}')
    TIGHT=$(grep "^TIGHT_COUNT " "$RESULTS" | awk '{print $2}')
    SUB_QW=$(grep "^SUB_QW " "$RESULTS" | awk '{print $2}')
    SUB_SC=$(grep "^SUB_SC " "$RESULTS" | awk '{print $2}')
    SUB_LR=$(grep "^SUB_LR " "$RESULTS" | awk '{print $2}')

    LOOSE=${LOOSE:-0}
    MED=${MED:-0}
    TIGHT=${TIGHT:-0}
    SUB_QW=${SUB_QW:-0}
    SUB_SC=${SUB_SC:-0}
    SUB_LR=${SUB_LR:-0}

    # Loose tier: 0.05 per param, max 0.30
    LOOSE_REWARD=$(awk "BEGIN{r=$LOOSE*0.05; if(r>0.30)r=0.30; printf \"%.4f\", r}")
    add_reward "$LOOSE_REWARD"

    # Medium tier (real solution): 0.025 per param, max 0.15
    MED_REWARD=$(awk "BEGIN{r=$MED*0.025; if(r>0.15)r=0.15; printf \"%.4f\", r}")
    add_reward "$MED_REWARD"

    # Tight tier (excellent): 0.015 per param, max 0.09
    TIGHT_REWARD=$(awk "BEGIN{r=$TIGHT*0.015; if(r>0.09)r=0.09; printf \"%.4f\", r}")
    add_reward "$TIGHT_REWARD"

    # Subroutine credits
    if [ "$SUB_QW" = "1" ]; then add_reward 0.02; fi
    if [ "$SUB_SC" = "1" ]; then add_reward 0.02; fi
    if [ "$SUB_LR" = "1" ]; then add_reward 0.02; fi
fi

# Bonus: success message in stdout when all 6 pass
if grep -qiE "all (6 )?(passed|pass)" "$SCRIPT_OUT" 2>/dev/null; then
    add_reward 0.02
fi

# Clamp to [0,1]
REWARD=$(awk "BEGIN{r=$REWARD; if(r>1)r=1; if(r<0)r=0; printf \"%.4f\", r}")

echo "FINAL_REWARD=$REWARD" >&2
echo "Detailed results:" >&2
cat "$RESULTS" >&2 2>/dev/null

echo "$REWARD" > /logs/verifier/reward.txt
exit 0