#!/usr/bin/env bash
# Verifier for nunchaku-svdq-reconstruction
#
# Tier breakdown:
#   Bronze  0.05  structural   file + functions + anti-stub
#   Silver1 0.15  F2P behav.   unpack qweight roundtrip
#   Silver2 0.10  F2P behav.   unpack scale roundtrip
#   Silver3 0.10  F2P behav.   unpack lowrank roundtrip
#   Gold    0.30  behavioral   verifier-side reconstruction per-param (0.05 x 6)
#   Gold2   0.15  behavioral   verifier-side reconstruction all 6, tight threshold
#   Fresh   0.15  F2P behav.   fresh synthetic data reconstruction
#
# Scoring: 0.0 to 1.0 written to /logs/verifier/reward.txt
set +e

SCORE=0
add_score() {
    SCORE=$(python3 -c "print(round($SCORE + $1, 4))")
}

cd /workspace

# ── Bronze (0.05): file + functions + anti-stub ──────────────────────────────
python3 - <<'PYEOF'
import ast, sys

try:
    with open("reconstruct_weight.py") as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL parse: {e}"); sys.exit(1)

fns = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
if "reconstruct_weight" not in fns:
    print("FAIL missing: reconstruct_weight"); sys.exit(1)

helpers = fns - {"reconstruct_weight", "main"}
if len(helpers) < 2:
    print(f"FAIL too few helpers: {helpers}"); sys.exit(1)

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "reconstruct_weight":
        meaningful = 0
        for child in ast.walk(node):
            if isinstance(child, (ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Return)):
                meaningful += 1
            elif isinstance(child, ast.Expr) and isinstance(child.value, ast.Call):
                meaningful += 1
        if meaningful < 5:
            print(f"FAIL stub: reconstruct_weight has {meaningful} meaningful nodes"); sys.exit(1)
        break

for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in helpers:
        body = [s for s in node.body
                if not isinstance(s, ast.Pass)
                and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
        if len(body) < 3:
            print(f"FAIL stub helper: {node.name} has {len(body)} stmts"); sys.exit(1)

print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.05 && echo "[Bronze] file+functions: PASS"


# ── Silver1 (0.15): qweight unpack roundtrip ─────────────────────────────────
# Core bug test: buggy starter has wrong permute in unpack_svdq_qweight.
python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_svdq_qweight(w):
    """Reference packer from NunchakuWeightPacker(bits=4, warp_n=128)."""
    n, k = w.shape
    nt, kt = n // 128, k // 64
    w = w.view(nt, 8, 2, 8, 1, kt, 1, 2, 4, 8)
    w = w.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9).contiguous()
    w = w.view(n, k // 8, 8)
    p = torch.zeros((n, k // 8), dtype=torch.int32)
    for i in range(8):
        p |= w[:, :, i] << (i * 4)
    return p.view(torch.int8).view(n, k // 2)

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import: {e}"); sys.exit(1)

fn = None
for name in ['unpack_svdq_qweight', 'unpack_qweight', 'unpack_int4',
             'dequantize_qweight', 'decode_qweight']:
    fn = getattr(rw, name, None)
    if fn is not None: break
if fn is None:
    for attr in dir(rw):
        if 'qweight' in attr.lower() and ('unpack' in attr.lower() or 'decode' in attr.lower()):
            candidate = getattr(rw, attr)
            if callable(candidate):
                fn = candidate; break
if fn is None:
    print("FAIL: no qweight unpack function"); sys.exit(1)

torch.manual_seed(1)
for N, K in [(256, 256), (512, 256), (256, 512)]:
    orig = torch.randint(0, 16, (N, K), dtype=torch.int32)
    packed = pack_svdq_qweight(orig)
    unpacked = None
    for call in [lambda p=packed, n=N, k=K: fn(p, n, k),
                 lambda p=packed, n=N, k=K: fn(p, N=n, K=k),
                 lambda p=packed: fn(p)]:
        try:
            unpacked = call()
            break
        except Exception:
            continue
    if unpacked is None:
        print(f"FAIL qweight ({N},{K}): no compatible call"); sys.exit(1)
    # Accept unsigned (0..15) or signed (-8..7) output
    if not torch.equal(orig, unpacked.to(torch.int32)):
        signed = orig.clone()
        signed[signed >= 8] -= 16
        if not torch.equal(signed, unpacked.to(torch.int32)):
            bad = (orig != unpacked.to(torch.int32)).sum().item()
            print(f"FAIL qweight ({N},{K}): {bad}/{N*K} wrong"); sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.15 && echo "[Silver1] qweight roundtrip: PASS"


# ── Silver2 (0.10): scale unpack roundtrip ───────────────────────────────────
python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_svdq_scale(s):
    """Reference packer: (N, K//G) float -> (K//G, N) packed."""
    n, k_div_g = s.shape
    s = s.reshape(n // 128, 1, 8, 2, 4, 2, k_div_g)
    s = s.permute(0, 6, 1, 2, 4, 3, 5).contiguous()
    return s.view(k_div_g, n)

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import: {e}"); sys.exit(1)

fn = None
for name in ['unpack_svdq_scale', 'unpack_wscales', 'unpack_scale',
             'unpack_scales', 'dequantize_scale', 'decode_scale', 'decode_wscales']:
    fn = getattr(rw, name, None)
    if fn is not None: break
if fn is None:
    for attr in dir(rw):
        if ('scale' in attr.lower() or 'wscale' in attr.lower()) \
                and ('unpack' in attr.lower() or 'decode' in attr.lower()):
            candidate = getattr(rw, attr)
            if callable(candidate):
                fn = candidate; break
if fn is None:
    print("FAIL: no scale unpack function"); sys.exit(1)

torch.manual_seed(2)
for N, K in [(256, 256), (512, 256), (256, 512)]:
    G = 64
    orig = torch.randn(N, K // G, dtype=torch.bfloat16)
    packed = pack_svdq_scale(orig)
    unpacked = None
    for call in [lambda p=packed, n=N, k=K: fn(p, n, k),
                 lambda p=packed, n=N, k=K: fn(p, N=n, K=k),
                 lambda p=packed: fn(p)]:
        try:
            unpacked = call()
            break
        except Exception:
            continue
    if unpacked is None:
        print(f"FAIL scale ({N},{K}): no compatible call"); sys.exit(1)
    err = (orig.float() - unpacked.float()).abs().max().item()
    if err > 1e-4:
        print(f"FAIL scale ({N},{K}): max_err={err}"); sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.10 && echo "[Silver2] scale roundtrip: PASS"


# ── Silver3 (0.10): lowrank unpack roundtrip ─────────────────────────────────
python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_lowrank(weight, down):
    """Reference packer for low-rank projections."""
    pack_n, pack_k = 16, 16
    if down:
        r, c = weight.shape
        rp, cp = r // pack_n, c // pack_k
        w = weight.view(rp, pack_n, cp, pack_k).permute(2, 0, 1, 3)
    else:
        c, r = weight.shape
        cp, rp = c // pack_n, r // pack_k
        w = weight.view(cp, pack_n, rp, pack_k).permute(0, 2, 1, 3)
    w = w.reshape(cp, rp, 2, 8, 1, 2, 4, 2)
    w = w.permute(0, 1, 3, 6, 2, 5, 4, 7).contiguous()
    return w.view(r, c) if down else w.view(c, r)

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import: {e}"); sys.exit(1)

fn = None
for name in ['unpack_svdq_lowrank', 'unpack_lowrank', 'unpack_proj',
             'unpack_low_rank', 'decode_lowrank', 'dequantize_lowrank']:
    fn = getattr(rw, name, None)
    if fn is not None: break
if fn is None:
    for attr in dir(rw):
        if ('lowrank' in attr.lower() or 'low_rank' in attr.lower() or 'proj' in attr.lower()) \
                and ('unpack' in attr.lower() or 'decode' in attr.lower()):
            candidate = getattr(rw, attr)
            if callable(candidate):
                fn = candidate; break
if fn is None:
    print("FAIL: no lowrank unpack function"); sys.exit(1)

torch.manual_seed(3)
R = 16
cases = [
    (256, 256, False, (256, R)),
    (256, 256, True,  (256, R)),
    (512, 256, False, (512, R)),
    (256, 512, True,  (256, R)),
]
for N, K, down, shape in cases:
    orig = torch.randn(*shape, dtype=torch.bfloat16)
    packed = pack_lowrank(orig, down=down)
    unpacked = None
    for call in [
        lambda p=packed, d=down: fn(p, down=d),
        lambda p=packed, s0=shape[0], s1=shape[1]: fn(p, s0, s1),
        lambda p=packed: fn(p),
    ]:
        try:
            unpacked = call()
            break
        except Exception:
            continue
    if unpacked is None:
        print(f"FAIL lowrank {shape} down={down}: no compatible call"); sys.exit(1)
    err = (orig.float() - unpacked.float()).abs().max().item()
    if err > 1e-4:
        print(f"FAIL lowrank down={down} {shape}: max_err={err}"); sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.10 && echo "[Silver3] lowrank roundtrip: PASS"


# ── Gold + Fresh (0.60): verifier-side reconstruction ────────────────────────
# Per-param: 0.05 x 6 = 0.30 (threshold < 0.05)
# All-6 tight: 0.15 (threshold < 0.01)
# Fresh synthetic data: 0.15
#
# The verifier uses the agent's unpack functions to reconstruct the weight
# and compares against weight_approx.pt. This is ungameable because the
# verifier does the math itself — it never trusts a return value.

GOLD_OUTPUT=$(python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def find_fn(mod, names):
    """Find a function by trying multiple name alternatives + fuzzy search."""
    for n in names:
        f = getattr(mod, n, None)
        if f is not None:
            return f
    keywords = set()
    for n in names:
        for part in n.replace('_', ' ').split():
            if len(part) > 3:
                keywords.add(part.lower())
    for attr in dir(mod):
        al = attr.lower()
        if any(kw in al for kw in keywords) \
                and ('unpack' in al or 'decode' in al or 'dequant' in al):
            c = getattr(mod, attr)
            if callable(c):
                return c
    return None

def try_call(fn, packed, N, K):
    """Try multiple calling conventions for qweight/scale unpack."""
    for call in [lambda: fn(packed, N, K),
                 lambda: fn(packed, N=N, K=K),
                 lambda: fn(packed)]:
        try:
            return call()
        except Exception:
            continue
    return None

def call_lr(fn, packed, C, R, down):
    """Try multiple calling conventions for lowrank unpack."""
    for call in [
        lambda: fn(packed, down=down),
        lambda: fn(packed, C, R),
        lambda: fn(packed),
    ]:
        try:
            return call()
        except Exception:
            continue
    return None

def pack_svdq_qweight(w):
    n, k = w.shape
    nt, kt = n // 128, k // 64
    w = w.view(nt, 8, 2, 8, 1, kt, 1, 2, 4, 8)
    w = w.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9).contiguous()
    w = w.view(n, k // 8, 8)
    p = torch.zeros((n, k // 8), dtype=torch.int32)
    for i in range(8):
        p |= w[:, :, i] << (i * 4)
    return p.view(torch.int8).view(n, k // 2)

def pack_svdq_scale(s):
    n, k_div_g = s.shape
    s = s.reshape(n // 128, 1, 8, 2, 4, 2, k_div_g)
    s = s.permute(0, 6, 1, 2, 4, 3, 5).contiguous()
    return s.view(k_div_g, n)

def pack_lowrank(weight, down):
    pack_n, pack_k = 16, 16
    if down:
        r, c = weight.shape
        rp, cp = r // pack_n, c // pack_k
        w = weight.view(rp, pack_n, cp, pack_k).permute(2, 0, 1, 3)
    else:
        c, r = weight.shape
        cp, rp = c // pack_n, r // pack_k
        w = weight.view(cp, pack_n, rp, pack_k).permute(0, 2, 1, 3)
    w = w.reshape(cp, rp, 2, 8, 1, 2, 4, 2)
    w = w.permute(0, 1, 3, 6, 2, 5, 4, 7).contiguous()
    return w.view(r, c) if down else w.view(c, r)

def recon_via_components(name, fn_qw, fn_sc, fn_lr):
    """Verifier-side reconstruction using agent's unpack functions."""
    try:
        weight_approx = torch.load(f"pt/{name}.weight_approx.pt", weights_only=True)
    except FileNotFoundError:
        return None
    proj_down = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
    proj_up   = torch.load(f"pt/{name}.proj_up.pt",   weights_only=True)
    qweight   = torch.load(f"pt/{name}.qweight.pt",   weights_only=True)
    smooth    = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
    wscales   = torch.load(f"pt/{name}.wscales.pt",   weights_only=True)
    N, K = weight_approx.shape
    rank = proj_down.shape[1]

    try:
        qw = try_call(fn_qw, qweight, N, K)
        if qw is None: return None
        qw = qw.float()
        qw[qw >= 8] -= 16  # unsigned nibble -> signed (no-op if already signed)

        ws = try_call(fn_sc, wscales, N, K)
        if ws is None: return None
        ws = ws.float()
        residual = qw * ws.repeat_interleave(64, dim=1)

        pu = call_lr(fn_lr, proj_up, N, rank, False)
        pd = call_lr(fn_lr, proj_down, K, rank, True)
        if pu is None or pd is None: return None

        recon = (residual + pu.float() @ pd.float().T) / smooth.float().unsqueeze(0)
        return (recon - weight_approx.float()).abs().max().item()
    except Exception as e:
        print(f"  {name}: exception {e}", file=sys.stderr)
        return None

try:
    import reconstruct_weight as rw
except ImportError:
    print("0 0 0"); sys.exit(0)

fn_qw = find_fn(rw, ['unpack_svdq_qweight', 'unpack_qweight', 'unpack_int4',
                      'dequantize_qweight', 'decode_qweight'])
fn_sc = find_fn(rw, ['unpack_svdq_scale', 'unpack_wscales', 'unpack_scale',
                      'unpack_scales', 'dequantize_scale', 'decode_scale', 'decode_wscales'])
fn_lr = find_fn(rw, ['unpack_svdq_lowrank', 'unpack_lowrank', 'unpack_proj',
                      'unpack_low_rank', 'decode_lowrank', 'dequantize_lowrank'])
have_fns = fn_qw is not None and fn_sc is not None and fn_lr is not None

# ── Gold per-param ──
params = ["attn.to_out.0", "attn.to_add_out",
          "img_mlp.net.0.proj", "img_mlp.net.2",
          "txt_mlp.net.0.proj", "txt_mlp.net.2"]

passed_loose = 0
passed_tight = 0

if have_fns:
    for name in params:
        d = recon_via_components(name, fn_qw, fn_sc, fn_lr)
        if d is not None and d < 0.05:
            passed_loose += 1
            print(f"  {name}: diff={d:.6f} PASS", file=sys.stderr)
            if d < 0.01:
                passed_tight += 1
        else:
            print(f"  {name}: diff={d} FAIL", file=sys.stderr)
else:
    print("  Gold: unpack functions not found, skipping", file=sys.stderr)

# ── Fresh synthetic data ──
fresh = 0
if have_fns:
    try:
        torch.manual_seed(99999)
        N, K, R, G = 256, 512, 16, 64
        w = torch.randn(N, K, dtype=torch.bfloat16)
        sf = torch.abs(torch.randn(K, dtype=torch.bfloat16)) + 0.5

        w_sm = w.float() * sf.float().unsqueeze(0)
        U, S, Vh = torch.linalg.svd(w_sm, full_matrices=False)
        U = U[:, :R]; S = S[:R]; Vh = Vh[:R, :]
        sqS = S.sqrt()
        pu_raw = (U * sqS.unsqueeze(0)).to(torch.bfloat16)
        pd_raw = (Vh.T * sqS.unsqueeze(0)).to(torch.bfloat16)

        res = (w_sm - pu_raw.float() @ pd_raw.float().T).view(N, K // G, G)
        ws_raw = res.abs().amax(dim=-1) / 7.0
        ws_raw = ws_raw.clamp(min=1e-8)
        qi = (res / ws_raw.unsqueeze(-1)).round().to(torch.int32).clamp(-8, 7)
        qp = (qi & 0xF).view(N, K)

        res_dq = (qi.float() * ws_raw.to(torch.bfloat16).float().unsqueeze(-1)).view(N, K)
        lr_exact = pu_raw.float() @ pd_raw.float().T
        w_approx = ((res_dq + lr_exact) / sf.float().unsqueeze(0)).to(torch.bfloat16)

        # Pack with reference functions
        qw_p = pack_svdq_qweight(qp)
        ws_p = pack_svdq_scale(ws_raw.to(torch.bfloat16))
        pu_p = pack_lowrank(pu_raw, down=False)
        pd_p = pack_lowrank(pd_raw, down=True)

        # Unpack with agent's functions
        qw = try_call(fn_qw, qw_p, N, K)
        ws = try_call(fn_sc, ws_p, N, K)
        pu = call_lr(fn_lr, pu_p, N, R, False)
        pd = call_lr(fn_lr, pd_p, K, R, True)

        if qw is not None and ws is not None and pu is not None and pd is not None:
            qw = qw.float()
            qw[qw >= 8] -= 16
            ws = ws.float()
            residual = qw * ws.repeat_interleave(G, dim=1)
            recon = (residual + pu.float() @ pd.float().T) / sf.float().unsqueeze(0)
            err = (recon - w_approx.float()).abs().max().item()
            if err < 0.05:
                fresh = 1
                print(f"  Fresh (256x512): err={err:.6f} PASS", file=sys.stderr)
            else:
                print(f"  Fresh (256x512): err={err:.6f} FAIL", file=sys.stderr)
        else:
            print("  Fresh: unpack call failed", file=sys.stderr)
    except Exception as e:
        print(f"  Fresh: exception {e}", file=sys.stderr)

print(f"{passed_loose} {passed_tight} {fresh}")
PYEOF
)

read LOOSE TIGHT FRESH <<< "$GOLD_OUTPUT"
LOOSE=${LOOSE:-0}
TIGHT=${TIGHT:-0}
FRESH=${FRESH:-0}

echo "[Gold] $LOOSE/6 params passed (loose threshold)"
if [ "$LOOSE" -gt 0 ] 2>/dev/null; then
    GOLD_REWARD=$(python3 -c "print(round(min($LOOSE * 0.05, 0.30), 4))")
    add_score "$GOLD_REWARD"
    echo "[Gold] reward: +$GOLD_REWARD"
fi

if [ "$TIGHT" -eq 6 ] 2>/dev/null; then
    add_score 0.15
    echo "[Gold2] all 6 tight threshold: PASS (+0.15)"
else
    echo "[Gold2] all 6 tight threshold: FAIL ($TIGHT/6)"
fi

if [ "$FRESH" -eq 1 ] 2>/dev/null; then
    add_score 0.15
    echo "[Fresh] synthetic data recon: PASS (+0.15)"
else
    echo "[Fresh] synthetic data recon: FAIL"
fi


# ── Final score ──────────────────────────────────────────────────────────────
echo ""
echo "Final reward: $SCORE"
mkdir -p /logs/verifier
echo "$SCORE" > /logs/verifier/reward.txt
