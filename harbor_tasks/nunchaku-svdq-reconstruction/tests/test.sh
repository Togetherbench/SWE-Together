#!/usr/bin/env bash
# Verifier for nunchaku-svdq-reconstruction
#
# 26 micro-tests, total 1.05 (capped at 1.0):
#   P2P1-P2P3 (0.05) pass-to-pass  upstream sanity (parse, imports, source)
#   S1-S3   (0.06)  structural  file + functions + anti-stub
#   Q1-Q3   (0.15)  behavioral  qweight unpack per shape
#   SC1-SC3 (0.09)  behavioral  scale unpack per shape
#   LR1-LR4 (0.12)  behavioral  lowrank unpack per case
#   R1-R6   (0.30)  behavioral  full reconstruction per param (diff<0.05)
#   TT      (0.10)  behavioral  tight threshold all 6 (diff<0.01)
#   F1-F3   (0.18)  behavioral  fresh synthetic data, 3 sizes
#
# Scoring: 0.0 to 1.0 written to /logs/verifier/reward.txt
set +e

SCORE=0
add_score() {
    SCORE=$(python3 -c "print(round($SCORE + $1, 4))")
}

cd /workspace
RESULTS=/tmp/verifier_results.txt
> "$RESULTS"

# ── Pass-to-pass (P2P1-P2P3: 0.05) ────────────────────────────────────
# Upstream sanity: these must pass even on the unmodified buggy baseline.
python3 - "$RESULTS" <<'PYEOF'
import sys

rf = sys.argv[1]

def wr(name, ok):
    with open(rf, 'a') as f:
        f.write(f"{name} {1 if ok else 0}\n")
    print(f"  [{name}] {'PASS' if ok else 'FAIL'}", file=sys.stderr)

# P2P1: reconstruct_weight.py exists and parses as valid Python
try:
    import ast
    with open("reconstruct_weight.py") as f:
        ast.parse(f.read())
    wr("P2P1", True)
except Exception:
    wr("P2P1", False)

# P2P2: torch is importable and CUDA-free CPU tensors work
try:
    import torch
    t = torch.zeros(2, 2)
    wr("P2P2", t.shape == (2, 2))
except Exception:
    wr("P2P2", False)

# P2P3: upstream NunchakuWeightPacker functional test on CPU.
# Import packer.py bypassing CUDA-dependent __init__.py via sys.modules stubs,
# then verify pack_lowrank_weight -> unpack_lowrank_weight round-trip and
# pack_weight shape correctness on CPU tensors.
try:
    import types, importlib.util
    REPO = "nunchaku"
    # Stub nunchaku packages to avoid CUDA model imports
    nunchaku_pkg = types.ModuleType('nunchaku')
    nunchaku_pkg.__path__ = [f'{REPO}/nunchaku']
    nunchaku_pkg.__package__ = 'nunchaku'
    sys.modules['nunchaku'] = nunchaku_pkg

    def _ceil_divide(x, d):
        return (x + d - 1) // d
    nu = types.ModuleType('nunchaku.utils')
    nu.ceil_divide = _ceil_divide
    nu.load_state_dict_in_safetensors = None
    sys.modules['nunchaku.utils'] = nu

    for _name, _path in [
        ('nunchaku.lora', f'{REPO}/nunchaku/lora'),
        ('nunchaku.lora.flux', f'{REPO}/nunchaku/lora/flux'),
    ]:
        _m = types.ModuleType(_name)
        _m.__path__ = [_path]
        _m.__package__ = _name
        sys.modules[_name] = _m

    _spec = importlib.util.spec_from_file_location(
        'nunchaku.lora.flux.utils', f'{REPO}/nunchaku/lora/flux/utils.py')
    _fu = importlib.util.module_from_spec(_spec)
    sys.modules['nunchaku.lora.flux.utils'] = _fu
    _spec.loader.exec_module(_fu)

    _spec = importlib.util.spec_from_file_location(
        'nunchaku.lora.flux.packer', f'{REPO}/nunchaku/lora/flux/packer.py')
    _pk = importlib.util.module_from_spec(_spec)
    sys.modules['nunchaku.lora.flux.packer'] = _pk
    _spec.loader.exec_module(_pk)

    _wp = _pk.NunchakuWeightPacker(bits=4, warp_n=128)

    # Lowrank round-trip
    _ok = True
    for _down in [True, False]:
        torch.manual_seed(42)
        _orig = torch.randn(256, 16, dtype=torch.bfloat16)
        _packed = _wp.pack_lowrank_weight(_orig, down=_down)
        _unpacked = _wp.unpack_lowrank_weight(_packed, down=_down)
        _err = (_orig.float() - _unpacked.float()).abs().max().item()
        if _err > 1e-6:
            _ok = False
            break

    # pack_weight shape
    if _ok:
        torch.manual_seed(99)
        _w = torch.randint(0, 16, (256, 256), dtype=torch.int32)
        _pw = _wp.pack_weight(_w)
        _ok = _pw.dtype == torch.int8 and _pw.shape == (256, 128)

    wr("P2P3", _ok)
except Exception:
    wr("P2P3", False)
PYEOF

# ── Structural (S1-S3: 0.06) ───────────────────────────────────────────
python3 - "$RESULTS" <<'PYEOF'
import ast, sys

rf = sys.argv[1]

def wr(name, ok):
    with open(rf, 'a') as f:
        f.write(f"{name} {1 if ok else 0}\n")

try:
    with open("reconstruct_weight.py") as f:
        src = f.read()
    tree = ast.parse(src)
except Exception:
    wr("S1", False); wr("S2", False); wr("S3", False)
    sys.exit(0)

# S1: file exists + parseable
wr("S1", True)

# S2: reconstruct_weight fn with >=5 meaningful nodes
fns = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
s2 = False
if "reconstruct_weight" in fns:
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "reconstruct_weight":
            count = 0
            for child in ast.walk(node):
                if isinstance(child, (ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Return)):
                    count += 1
                elif isinstance(child, ast.Expr) and isinstance(child.value, ast.Call):
                    count += 1
            s2 = count >= 5
            break
wr("S2", s2)

# S3: >=2 non-stub helper functions
helpers = fns - {"reconstruct_weight", "main"}
non_stub = 0
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in helpers:
        body = [s for s in node.body
                if not isinstance(s, ast.Pass)
                and not (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))]
        if len(body) >= 3:
            non_stub += 1
wr("S3", non_stub >= 2)
PYEOF

# ── All behavioral tests ───────────────────────────────────────────────
python3 - "$RESULTS" <<'PYEOF'
import sys, torch
sys.path.insert(0, "/workspace")

rf = sys.argv[1]

def wr(name, ok):
    with open(rf, 'a') as f:
        f.write(f"{name} {1 if ok else 0}\n")
    print(f"  [{name}] {'PASS' if ok else 'FAIL'}", file=sys.stderr)

# ── Reference pack functions (from NunchakuWeightPacker bits=4, warp_n=128) ──

def pack_qw(w):
    n, k = w.shape
    nt, kt = n // 128, k // 64
    w = w.view(nt, 8, 2, 8, 1, kt, 1, 2, 4, 8)
    w = w.permute(0, 5, 6, 1, 3, 8, 2, 7, 4, 9).contiguous()
    w = w.view(n, k // 8, 8)
    p = torch.zeros((n, k // 8), dtype=torch.int32)
    for i in range(8):
        p |= w[:, :, i] << (i * 4)
    return p.view(torch.int8).view(n, k // 2)

def pack_sc(s):
    n, kg = s.shape
    s = s.reshape(n // 128, 1, 8, 2, 4, 2, kg)
    s = s.permute(0, 6, 1, 2, 4, 3, 5).contiguous()
    return s.view(kg, n)

def pack_lr(weight, down):
    pn, pk = 16, 16
    if down:
        r, c = weight.shape
        rp, cp = r // pn, c // pk
        w = weight.view(rp, pn, cp, pk).permute(2, 0, 1, 3)
    else:
        c, r = weight.shape
        cp, rp = c // pn, r // pk
        w = weight.view(cp, pn, rp, pk).permute(0, 2, 1, 3)
    w = w.reshape(cp, rp, 2, 8, 1, 2, 4, 2)
    w = w.permute(0, 1, 3, 6, 2, 5, 4, 7).contiguous()
    return w.view(r, c) if down else w.view(c, r)

# ── Function discovery ───────────────────────────────────────────────

def find_fn(mod, names):
    for n in names:
        f = getattr(mod, n, None)
        if f is not None:
            return f
    kws = set()
    for n in names:
        for part in n.replace('_', ' ').split():
            if len(part) > 3:
                kws.add(part.lower())
    for attr in dir(mod):
        al = attr.lower()
        if any(kw in al for kw in kws) and \
                ('unpack' in al or 'decode' in al or 'dequant' in al):
            c = getattr(mod, attr)
            if callable(c):
                return c
    return None

def call_qw(fn, packed, N, K):
    for c in [lambda: fn(packed, N, K), lambda: fn(packed, N=N, K=K), lambda: fn(packed)]:
        try:
            return c()
        except Exception:
            continue
    return None

def call_sc(fn, packed, N, K):
    for c in [lambda: fn(packed, N, K), lambda: fn(packed, N=N, K=K), lambda: fn(packed)]:
        try:
            return c()
        except Exception:
            continue
    return None

def call_lr(fn, packed, down):
    for c in [lambda: fn(packed, down=down), lambda: fn(packed, down),
              lambda: fn(packed)]:
        try:
            return c()
        except Exception:
            continue
    return None

# ── Import agent module ──────────────────────────────────────────────

try:
    import reconstruct_weight as rw
    MOD = True
except Exception:
    MOD = False

fn_qw = find_fn(rw, ['unpack_svdq_qweight', 'unpack_qweight', 'unpack_int4',
                       'dequantize_qweight', 'decode_qweight']) if MOD else None
fn_sc = find_fn(rw, ['unpack_svdq_scale', 'unpack_wscales', 'unpack_scale',
                       'unpack_scales', 'dequantize_scale', 'decode_scale',
                       'decode_wscales']) if MOD else None
fn_lr = find_fn(rw, ['unpack_svdq_lowrank', 'unpack_lowrank', 'unpack_proj',
                       'unpack_low_rank', 'decode_lowrank',
                       'dequantize_lowrank']) if MOD else None

# ── Q1-Q3: qweight unpack per shape (0.05 each) ─────────────────────
# Tests the core permutation inverse on 3 different (N,K) combos.

for idx, (N, K) in enumerate([(256, 256), (512, 256), (256, 512)], 1):
    name = f"Q{idx}"
    try:
        if fn_qw is None:
            wr(name, False); continue
        torch.manual_seed(100 + idx)
        orig = torch.randint(0, 16, (N, K), dtype=torch.int32)
        packed = pack_qw(orig)
        unpacked = call_qw(fn_qw, packed, N, K)
        if unpacked is None:
            wr(name, False); continue
        ok = torch.equal(orig, unpacked.to(torch.int32))
        if not ok:
            signed = orig.clone()
            signed[signed >= 8] -= 16
            ok = torch.equal(signed, unpacked.to(torch.int32))
        wr(name, ok)
    except Exception:
        wr(name, False)

# ── SC1-SC3: scale unpack per shape (0.03 each) ─────────────────────
# Tests the scale permutation inverse on 3 shapes.

for idx, (N, K) in enumerate([(256, 256), (512, 256), (256, 512)], 1):
    name = f"SC{idx}"
    try:
        if fn_sc is None:
            wr(name, False); continue
        torch.manual_seed(200 + idx)
        G = 64
        orig = torch.randn(N, K // G, dtype=torch.bfloat16)
        packed = pack_sc(orig)
        unpacked = call_sc(fn_sc, packed, N, K)
        if unpacked is None:
            wr(name, False); continue
        err = (orig.float() - unpacked.float()).abs().max().item()
        wr(name, err < 1e-4)
    except Exception:
        wr(name, False)

# ── LR1-LR4: lowrank unpack per case (0.03 each) ────────────────────
# Tests both directions (proj_up=down=False, proj_down=down=True)
# on square and non-square base shapes.

lr_cases = [
    ("LR1", False, (256, 16), 301),   # proj_up, square weight
    ("LR2", True,  (256, 16), 302),   # proj_down, square weight
    ("LR3", False, (512, 16), 303),   # proj_up, N>K weight
    ("LR4", True,  (512, 16), 304),   # proj_down, N<K weight
]
for tname, down, shape, seed in lr_cases:
    try:
        if fn_lr is None:
            wr(tname, False); continue
        torch.manual_seed(seed)
        orig = torch.randn(*shape, dtype=torch.bfloat16)
        packed = pack_lr(orig, down=down)
        unpacked = call_lr(fn_lr, packed, down)
        if unpacked is None:
            wr(tname, False); continue
        err = (orig.float() - unpacked.float()).abs().max().item()
        wr(tname, err < 1e-4)
    except Exception:
        wr(tname, False)

# ── R1-R6: per-param reconstruction (0.05 each) + TT ────────────────
# Verifier-side reconstruction using agent's 3 unpack functions.
# Each param tested independently; no conditional gates between params.

params = ["attn.to_out.0", "attn.to_add_out",
          "img_mlp.net.0.proj", "img_mlp.net.2",
          "txt_mlp.net.0.proj", "txt_mlp.net.2"]
tight_count = 0
have_fns = fn_qw is not None and fn_sc is not None and fn_lr is not None

for idx, pname in enumerate(params, 1):
    tname = f"R{idx}"
    diff = None
    try:
        if not have_fns:
            wr(tname, False); continue
        wa = torch.load(f"pt/{pname}.weight_approx.pt", weights_only=True)
        pd_p = torch.load(f"pt/{pname}.proj_down.pt", weights_only=True)
        pu_p = torch.load(f"pt/{pname}.proj_up.pt", weights_only=True)
        qw_p = torch.load(f"pt/{pname}.qweight.pt", weights_only=True)
        sm = torch.load(f"pt/{pname}.smooth_factor.pt", weights_only=True)
        ws_p = torch.load(f"pt/{pname}.wscales.pt", weights_only=True)
        N, K = wa.shape

        qw = call_qw(fn_qw, qw_p, N, K)
        ws = call_sc(fn_sc, ws_p, N, K)
        pu = call_lr(fn_lr, pu_p, False)
        pd = call_lr(fn_lr, pd_p, True)

        if qw is not None and ws is not None and pu is not None and pd is not None:
            qw = qw.float()
            qw[qw >= 8] -= 16
            residual = qw * ws.float().repeat_interleave(64, dim=1)
            recon = (residual + pu.float() @ pd.float().T) / sm.float().unsqueeze(0)
            diff = (recon - wa.float()).abs().max().item()
            print(f"    {pname}: diff={diff:.6f}", file=sys.stderr)
    except Exception as e:
        print(f"    {pname}: exception {e}", file=sys.stderr)

    passed = diff is not None and diff < 0.05
    wr(tname, passed)
    if passed and diff < 0.01:
        tight_count += 1

# TT: tight threshold — all 6 params diff < 0.01
wr("TT", tight_count == 6)

# ── F1-F3: fresh synthetic data (0.07 + 0.06 + 0.05) ────────────────
# 3 novel sizes to catch hardcoded solutions.

fresh_cases = [
    ("F1", 256, 512, 77777),    # N<K
    ("F2", 512, 256, 88888),    # N>K
    ("F3", 384, 256, 66666),    # different N, still 128-aligned
]
for tname, fN, fK, seed in fresh_cases:
    try:
        if not have_fns:
            wr(tname, False); continue
        torch.manual_seed(seed)
        N, K, R, G = fN, fK, 16, 64
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

        qw_packed = pack_qw(qp)
        ws_packed = pack_sc(ws_raw.to(torch.bfloat16))
        pu_packed = pack_lr(pu_raw, down=False)
        pd_packed = pack_lr(pd_raw, down=True)

        qw = call_qw(fn_qw, qw_packed, N, K)
        ws = call_sc(fn_sc, ws_packed, N, K)
        pu = call_lr(fn_lr, pu_packed, False)
        pd = call_lr(fn_lr, pd_packed, True)

        if qw is not None and ws is not None and pu is not None and pd is not None:
            qw = qw.float()
            qw[qw >= 8] -= 16
            residual = qw * ws.float().repeat_interleave(G, dim=1)
            recon = (residual + pu.float() @ pd.float().T) / sf.float().unsqueeze(0)
            err = (recon - w_approx.float()).abs().max().item()
            print(f"    Fresh {tname} ({N}x{K}): err={err:.6f}", file=sys.stderr)
            wr(tname, err < 0.05)
        else:
            print(f"    Fresh {tname}: unpack call returned None", file=sys.stderr)
            wr(tname, False)
    except Exception as e:
        print(f"    Fresh {tname}: exception {e}", file=sys.stderr)
        wr(tname, False)

PYEOF

# ── Parse results and compute score ─────────────────────────────────────
declare -A WEIGHTS
WEIGHTS[P2P1]=0.02; WEIGHTS[P2P2]=0.02; WEIGHTS[P2P3]=0.01
WEIGHTS[S1]=0.02;  WEIGHTS[S2]=0.02;  WEIGHTS[S3]=0.02
WEIGHTS[Q1]=0.05;  WEIGHTS[Q2]=0.05;  WEIGHTS[Q3]=0.05
WEIGHTS[SC1]=0.03; WEIGHTS[SC2]=0.03; WEIGHTS[SC3]=0.03
WEIGHTS[LR1]=0.03; WEIGHTS[LR2]=0.03; WEIGHTS[LR3]=0.03; WEIGHTS[LR4]=0.03
WEIGHTS[R1]=0.05;  WEIGHTS[R2]=0.05;  WEIGHTS[R3]=0.05
WEIGHTS[R4]=0.05;  WEIGHTS[R5]=0.05;  WEIGHTS[R6]=0.05
WEIGHTS[TT]=0.10
WEIGHTS[F1]=0.07;  WEIGHTS[F2]=0.06;  WEIGHTS[F3]=0.05

while IFS=' ' read -r NAME PASS; do
    W=${WEIGHTS[$NAME]}
    if [ -z "$W" ]; then continue; fi
    if [ "$PASS" = "1" ]; then
        add_score "$W"
        echo "[$NAME] PASS (+$W)"
    else
        echo "[$NAME] FAIL"
    fi
done < "$RESULTS"

# ── Final score ─────────────────────────────────────────────────────────
SCORE=$(python3 -c "print(min(round($SCORE, 4), 1.0))")
echo ""
echo "Final reward: $SCORE"
mkdir -p /logs/verifier
echo "$SCORE" > /logs/verifier/reward.txt
