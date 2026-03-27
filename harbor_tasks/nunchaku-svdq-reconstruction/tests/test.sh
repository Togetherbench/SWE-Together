#!/usr/bin/env bash
# Verifier for nunchaku-implement-a56d1e
# Tests correct SVDQ dequantization (unpack + reconstruct weight from packed tensors).
# Scoring: 0.0 to 1.0 written to /logs/verifier/reward.txt
set +e

REWARD=0.0
TOTAL=1.0
SCORE=0

add_score() {
    SCORE=$(python3 -c "print($SCORE + $1)")
}

cd /workspace

# ── Bronze (structural): file + functions exist (0.10) ───────────────────────

python3 - <<'PYEOF'
import ast, sys
try:
    with open("reconstruct_weight.py") as f:
        src = f.read()
    tree = ast.parse(src)
except Exception as e:
    print(f"FAIL parse: {e}")
    sys.exit(1)

fns = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}

# reconstruct_weight is always required (present in the starter stub)
if "reconstruct_weight" not in fns:
    print("FAIL missing function: reconstruct_weight")
    sys.exit(1)

# Need at least 3 helper functions beyond reconstruct_weight
helpers = fns - {"reconstruct_weight", "main"}
if len(helpers) < 3:
    print(f"FAIL too few helper functions: only {helpers}")
    sys.exit(1)

# Anti-stub: reconstruct_weight must have >3 meaningful statements
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "reconstruct_weight":
        stmts = [s for s in ast.walk(node) if isinstance(s, ast.Assign) or
                 isinstance(s, (ast.Return, ast.AugAssign, ast.AnnAssign))]
        if len(stmts) < 3:
            print(f"FAIL stub: reconstruct_weight has only {len(stmts)} statements")
            sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.10 && echo "[Bronze] file+functions: PASS"


# ── Silver 1 (behavioral): unpack qweight roundtrip (0.20) ───────────────────
# Accepts: unpack_svdq_qweight(packed, N, K) or unpack_qweight(packed, N, K)

python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_svdq_qweight(w):
    n, k = w.shape
    nt, kt = n // 128, k // 64
    w = w.view(nt, 8, 2, 8, 1, kt, 1, 2, 4, 8)
    w = w.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9).contiguous()
    w = w.view(n, k // 8, 8)
    p = torch.zeros((n, k // 8), dtype=torch.int32)
    for i in range(8): p |= w[:, :, i] << (i * 4)
    return p.view(torch.int8).view(n, k // 2)

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import module: {e}"); sys.exit(1)

fn = (getattr(rw, 'unpack_svdq_qweight', None) or
      getattr(rw, 'unpack_qweight', None))
if fn is None:
    print("FAIL: no unpack_svdq_qweight or unpack_qweight found"); sys.exit(1)

torch.manual_seed(1)
for N, K in [(256, 256), (512, 256), (256, 512)]:
    orig = torch.randint(0, 16, (N, K), dtype=torch.int32)
    packed = pack_svdq_qweight(orig)
    unpacked = fn(packed, N, K)
    if not torch.equal(orig, unpacked):
        bad = (orig != unpacked).sum().item()
        print(f"FAIL qweight ({N},{K}): {bad}/{N*K} elements wrong")
        sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.20 && echo "[Silver1] unpack qweight roundtrip: PASS"


# ── Silver 2 (behavioral): unpack scale roundtrip (0.15) ─────────────────────
# Accepts: unpack_svdq_scale(packed, N, K) or unpack_wscales(packed, N, K)

python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_svdq_scale(s):
    n, k_div_g = s.shape
    s = s.reshape(n // 128, 1, 8, 2, 4, 2, k_div_g)
    s = s.permute(0, 6, 1, 2, 4, 3, 5).contiguous()
    return s.view(k_div_g, n)

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import module: {e}"); sys.exit(1)

fn = (getattr(rw, 'unpack_svdq_scale', None) or
      getattr(rw, 'unpack_wscales', None) or
      getattr(rw, 'unpack_scale', None))
if fn is None:
    print("FAIL: no unpack_svdq_scale/unpack_wscales/unpack_scale found"); sys.exit(1)

torch.manual_seed(2)
for N, K in [(256, 256), (512, 256), (256, 512)]:
    G = 64
    orig = torch.randn(N, K // G, dtype=torch.bfloat16)
    packed = pack_svdq_scale(orig)
    unpacked = fn(packed, N, K)
    err = (orig.float() - unpacked.float()).abs().max().item()
    if err > 1e-4:
        print(f"FAIL scale ({N},{K}): max_err={err}")
        sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.15 && echo "[Silver2] unpack scale roundtrip: PASS"


# ── Silver 3 (behavioral): unpack lowrank roundtrip (0.15) ───────────────────
# Accepts: unpack_svdq_lowrank(packed, down=bool) or unpack_lowrank(packed, C, R)

python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def pack_lowrank(weight, down):
    reg_n, reg_k = 1, 2
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
    print(f"FAIL import module: {e}"); sys.exit(1)

fn = (getattr(rw, 'unpack_svdq_lowrank', None) or
      getattr(rw, 'unpack_lowrank', None))
if fn is None:
    print("FAIL: no unpack_svdq_lowrank or unpack_lowrank found"); sys.exit(1)

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
    # Try multiple calling conventions: (packed, down=), (packed, C, R), (packed,)
    unpacked = None
    for call_args in [
        lambda p: fn(p, down=down),
        lambda p: fn(p, shape[0], shape[1]),
        lambda p: fn(p),
    ]:
        try:
            unpacked = call_args(packed)
            break
        except (TypeError, Exception):
            continue
    if unpacked is None:
        print(f"FAIL calling unpack_lowrank {shape}: no compatible interface"); sys.exit(1)
    err = (orig.float() - unpacked.float()).abs().max().item()
    if err > 1e-4:
        print(f"FAIL lowrank down={down} {shape}: max_err={err}")
        sys.exit(1)
print("OK")
PYEOF
[ $? -eq 0 ] && add_score 0.15 && echo "[Silver3] unpack lowrank roundtrip: PASS"


# ── Gold 1 (behavioral): reconstruction matches expected (square cases) (0.20) ─
# Uses student's reconstruct_weight() directly; also tries component-level if available.

python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

# Verifier reference implementations (used if student functions are available)
def _ref_unpack_qweight(qweight, N, K):
    n_tiles, k_tiles = N // 128, K // 64
    w = qweight.view(torch.int32)
    w = w.view(n_tiles, k_tiles, 1, 8, 8, 4, 2, 2, 1, 8)
    # correct inverse permute of (0,5,6,1,3,8,2,7,4,9) -> (0,3,6,4,8,1,2,7,5,9)
    return w.permute(0, 3, 6, 4, 8, 1, 2, 7, 5, 9).contiguous().view(N, K)

def _ref_unpack_scale(wscales, N, K):
    s = wscales.view(N // 128, K // 64, 1, 8, 4, 2, 2)
    return s.permute(0, 2, 3, 5, 4, 6, 1).contiguous().view(N, K // 64)

def _ref_unpack_lowrank(weight, down):
    rows, cols = weight.shape
    r, c = (rows, cols) if down else (cols, rows)
    rp, cp = r // 16, c // 16
    w = weight.view(cp, rp, 8, 4, 2, 2, 1, 2)
    w = w.permute(0, 1, 4, 2, 6, 5, 3, 7).contiguous().view(cp, rp, 16, 16)
    if down:
        return w.permute(1, 2, 0, 3).contiguous().view(r, c)
    else:
        return w.permute(0, 2, 1, 3).contiguous().view(c, r)

def test_via_reconstruct_weight(name, mod):
    """Call student's reconstruct_weight(name) and check it returns small diff."""
    fn = getattr(mod, 'reconstruct_weight', None)
    if fn is None:
        return None
    try:
        result = fn(name)
        # Expected: returns (max_diff, mean_diff) or just max_diff
        if isinstance(result, (tuple, list)):
            max_d = float(result[0])
        else:
            max_d = float(result)
        return max_d
    except Exception:
        return None

def test_via_components(name, mod):
    """Call student's component functions directly."""
    weight_approx = torch.load(f"pt/{name}.weight_approx.pt", weights_only=True)
    proj_down = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
    proj_up   = torch.load(f"pt/{name}.proj_up.pt",   weights_only=True)
    qweight   = torch.load(f"pt/{name}.qweight.pt",   weights_only=True)
    smooth    = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
    wscales   = torch.load(f"pt/{name}.wscales.pt",   weights_only=True)
    N, K = weight_approx.shape
    rank = proj_down.shape[1]

    fn_qw = (getattr(mod, 'unpack_svdq_qweight', None) or
             getattr(mod, 'unpack_qweight', None))
    fn_sc = (getattr(mod, 'unpack_svdq_scale', None) or
             getattr(mod, 'unpack_wscales', None) or
             getattr(mod, 'unpack_scale', None))
    fn_lr = (getattr(mod, 'unpack_svdq_lowrank', None) or
             getattr(mod, 'unpack_lowrank', None))
    if not (fn_qw and fn_sc and fn_lr):
        return None

    try:
        qw = fn_qw(qweight, N, K).float()
        qw[qw >= 8] -= 16
        ws = fn_sc(wscales, N, K).float()
        residual = qw * ws.repeat_interleave(64, dim=1)
        # Try multiple calling conventions for lowrank unpack
        def _call_lr(fn, packed, C, R, down):
            for call in [
                lambda: fn(packed, down=down),
                lambda: fn(packed, C, R),
                lambda: fn(packed),
            ]:
                try:
                    return call()
                except (TypeError, Exception):
                    continue
            return None
        pu = _call_lr(fn_lr, proj_up, N, rank, False)
        pd = _call_lr(fn_lr, proj_down, K, rank, True)
        if pu is None or pd is None:
            return None
        pu = pu.float()
        pd = pd.float()
        recon = (residual + pu @ pd.T) / smooth.float().unsqueeze(0)
        max_d = (recon - weight_approx.float()).abs().max().item()
        return max_d
    except Exception:
        return None

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import: {e}"); sys.exit(1)

cases = ["attn.to_out.0", "attn.to_add_out"]
passed = 0
for name in cases:
    # Try both approaches; take the minimum diff (most lenient)
    d1 = test_via_reconstruct_weight(name, rw)
    d2 = test_via_components(name, rw)
    candidates = [d for d in [d1, d2] if d is not None]
    if not candidates:
        print(f"  {name}: FAIL (could not run)")
    else:
        max_d = min(candidates)
        if max_d < 0.02:
            print(f"  {name}: max_diff={max_d:.6f} PASS")
            passed += 1
        else:
            print(f"  {name}: max_diff={max_d:.6f} FAIL")

if passed == len(cases):
    print("OK"); sys.exit(0)
else:
    print(f"FAIL {passed}/{len(cases)}"); sys.exit(1)
PYEOF
[ $? -eq 0 ] && add_score 0.20 && echo "[Gold1] reconstruction vs expected (square): PASS"


# ── Gold 2 (behavioral): reconstruction matches expected, all 6 cases (0.20) ──

python3 - <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

def test_via_reconstruct_weight(name, mod):
    fn = getattr(mod, 'reconstruct_weight', None)
    if fn is None:
        return None
    try:
        result = fn(name)
        if isinstance(result, (tuple, list)):
            max_d = float(result[0])
        else:
            max_d = float(result)
        return max_d
    except Exception:
        return None

def test_via_components(name, mod):
    weight_approx = torch.load(f"pt/{name}.weight_approx.pt", weights_only=True)
    proj_down = torch.load(f"pt/{name}.proj_down.pt", weights_only=True)
    proj_up   = torch.load(f"pt/{name}.proj_up.pt",   weights_only=True)
    qweight   = torch.load(f"pt/{name}.qweight.pt",   weights_only=True)
    smooth    = torch.load(f"pt/{name}.smooth_factor.pt", weights_only=True)
    wscales   = torch.load(f"pt/{name}.wscales.pt",   weights_only=True)
    N, K = weight_approx.shape
    rank = proj_down.shape[1]

    fn_qw = (getattr(mod, 'unpack_svdq_qweight', None) or
             getattr(mod, 'unpack_qweight', None))
    fn_sc = (getattr(mod, 'unpack_svdq_scale', None) or
             getattr(mod, 'unpack_wscales', None) or
             getattr(mod, 'unpack_scale', None))
    fn_lr = (getattr(mod, 'unpack_svdq_lowrank', None) or
             getattr(mod, 'unpack_lowrank', None))
    if not (fn_qw and fn_sc and fn_lr):
        return None

    try:
        qw = fn_qw(qweight, N, K).float()
        qw[qw >= 8] -= 16
        ws = fn_sc(wscales, N, K).float()
        residual = qw * ws.repeat_interleave(64, dim=1)
        try:
            pu = fn_lr(proj_up, down=False).float()
            pd = fn_lr(proj_down, down=True).float()
        except TypeError:
            pu = fn_lr(proj_up, N, rank).float()
            pd = fn_lr(proj_down, K, rank).float()
        recon = (residual + pu @ pd.T) / smooth.float().unsqueeze(0)
        max_d = (recon - weight_approx.float()).abs().max().item()
        return max_d
    except Exception:
        return None

try:
    import reconstruct_weight as rw
except ImportError as e:
    print(f"FAIL import: {e}"); sys.exit(1)

params = ["attn.to_out.0", "attn.to_add_out",
          "img_mlp.net.0.proj", "img_mlp.net.2",
          "txt_mlp.net.0.proj", "txt_mlp.net.2"]
passed = 0
for name in params:
    d1 = test_via_reconstruct_weight(name, rw)
    d2 = test_via_components(name, rw)
    candidates = [d for d in [d1, d2] if d is not None]
    if not candidates:
        print(f"  {name}: FAIL (could not run)")
    else:
        max_d = min(candidates)
        if max_d < 0.02:
            print(f"  {name}: max_diff={max_d:.6f} PASS")
            passed += 1
        else:
            print(f"  {name}: max_diff={max_d:.6f} FAIL")

if passed == len(params):
    print("OK"); sys.exit(0)
else:
    print(f"FAIL {passed}/{len(params)}"); sys.exit(1)
PYEOF
[ $? -eq 0 ] && add_score 0.20 && echo "[Gold2] reconstruction vs expected (all 6): PASS"


# ── Final score ───────────────────────────────────────────────────────────────
REWARD=$SCORE
echo "Final reward: $REWARD"
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
