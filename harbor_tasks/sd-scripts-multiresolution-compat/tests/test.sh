#!/bin/bash
set +e
export PATH="/workspace/venv/bin:$PATH"

REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$REWARD_FILE")"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO="/workspace/sd-scripts"
REWARD=0.0

if ! cd "$REPO" 2>/dev/null; then
    emit p2p_suffixed_path_regression false "repo missing"
    printf "%.4f\n" 0.0 > "$REWARD_FILE"
    exit 0
fi

run_py() {
    # $1 = gate id, stdin = python script
    local gid="$1"
    local out
    out=$(python3 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then
        emit "$gid" true ""
        return 0
    else
        local short
        short=$(echo "$out" | tr '\n' ' ' | tail -c 240)
        emit "$gid" false "$short"
        return 1
    fi
}

###############################################################################
# P2P GATE: suffixed-key path still works (regression guard for multi-res).
###############################################################################
P2P_OUT=$(python3 << 'PYEOF' 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64; sfx = f"_{h}x{w}"
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p, **{
    f"latents{sfx}": np.ones((4, h, w), dtype=np.float32),
    f"original_size{sfx}": np.array([512, 512]),
    f"crop_ltrb{sfx}": np.array([0, 0, 0, 0]),
})
try:
    ok = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert ok, "suffixed-key not accepted"
    res = strat.load_latents_from_disk(p, bucket)
    lat = res[0]
    assert lat is not None and lat.shape == (4, h, w), f"shape={None if lat is None else lat.shape}"
finally:
    try: os.unlink(p)
    except Exception: pass
PYEOF
)
P2P_RC=$?
if [ $P2P_RC -eq 0 ]; then
    emit p2p_suffixed_path_regression true ""
else
    short=$(echo "$P2P_OUT" | tr '\n' ' ' | tail -c 240)
    emit p2p_suffixed_path_regression false "$short"
    printf "%.4f\n" 0.0 > "$REWARD_FILE"
    exit 0
fi

###############################################################################
# F2P t1_f2p_legacy_accepted (0.15): legacy unsuffixed npz with correct shape
# is accepted by is_disk_cached_latents_expected.
###############################################################################
python3 << 'PYEOF' >/tmp/g1.log 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, h, w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert r is True or r == True, f"got {r!r}"
finally:
    os.unlink(p)
PYEOF
G1=$?
if [ $G1 -eq 0 ]; then
    emit t1_f2p_legacy_accepted true ""
else
    emit t1_f2p_legacy_accepted false "$(tr '\n' ' ' </tmp/g1.log | tail -c 240)"
fi

###############################################################################
# F2P t1_f2p_legacy_load (0.15): load_latents_from_disk on legacy npz returns
# correct values + metadata.
###############################################################################
python3 << 'PYEOF' >/tmp/g2.log 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
expected = np.ones((4, h, w), dtype=np.float32) * 2.71
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=expected,
    original_size=np.array([768, 512]),
    crop_ltrb=np.array([1, 2, 3, 4]),
)
try:
    res = strat.load_latents_from_disk(p, bucket)
    lat, osz, cltrb = res[0], res[1], res[2]
    assert lat is not None, "lat is None"
    assert tuple(lat.shape) == (4, h, w), f"shape {lat.shape}"
    assert abs(float(lat[0,0,0]) - 2.71) < 0.01, f"value {float(lat[0,0,0])}"
    assert list(map(int, list(osz))) == [768, 512], f"osz {list(osz)}"
    assert list(map(int, list(cltrb))) == [1, 2, 3, 4], f"cltrb {list(cltrb)}"
finally:
    os.unlink(p)
PYEOF
G2=$?
if [ $G2 -eq 0 ]; then
    emit t1_f2p_legacy_load true ""
else
    emit t1_f2p_legacy_load false "$(tr '\n' ' ' </tmp/g2.log | tail -c 240)"
fi

###############################################################################
# F2P t3_f2p_wrong_shape_rejected (0.10): wrong-shape legacy npz is rejected.
###############################################################################
python3 << 'PYEOF' >/tmp/g3.log 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p,
    latents=np.zeros((4, 32, 32), dtype=np.float32),  # wrong shape
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)
try:
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert not r, f"wrong-shape legacy accepted: {r!r}"
finally:
    os.unlink(p)
PYEOF
G3=$?
if [ $G3 -eq 0 ]; then
    emit t3_f2p_wrong_shape_rejected true ""
else
    emit t3_f2p_wrong_shape_rejected false "$(tr '\n' ' ' </tmp/g3.log | tail -c 240)"
fi

###############################################################################
# F2P t3_f2p_suffix_priority (0.15): when BOTH suffixed and unsuffixed keys are
# present, the suffixed entry wins (priority order respected).
###############################################################################
python3 << 'PYEOF' >/tmp/g4.log 2>&1
import sys, os, tempfile, numpy as np
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
bucket = (512, 512); h, w = 64, 64; sfx = f"_{h}x{w}"
suffixed = np.ones((4, h, w), dtype=np.float32) * 1.0
legacy   = np.ones((4, h, w), dtype=np.float32) * 9.0
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
np.savez(p, **{
    f"latents{sfx}": suffixed,
    f"original_size{sfx}": np.array([512, 512]),
    f"crop_ltrb{sfx}": np.array([0, 0, 0, 0]),
    "latents": legacy,
    "original_size": np.array([999, 999]),
    "crop_ltrb": np.array([7, 7, 7, 7]),
})
try:
    ok = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert ok, "both-keys npz not accepted"
    res = strat.load_latents_from_disk(p, bucket)
    lat, osz, _ = res[0], res[1], res[2]
    assert lat is not None and tuple(lat.shape) == (4, h, w), f"shape={None if lat is None else lat.shape}"
    v = float(lat[0,0,0])
    assert abs(v - 1.0) < 0.01, f"suffix priority lost: lat[0,0,0]={v} (expected 1.0; legacy=9.0)"
    assert list(map(int, list(osz))) == [512, 512], f"osz priority lost: {list(osz)}"
finally:
    os.unlink(p)
PYEOF
G4=$?
if [ $G4 -eq 0 ]; then
    emit t3_f2p_suffix_priority true ""
else
    emit t3_f2p_suffix_priority false "$(tr '\n' ' ' </tmp/g4.log | tail -c 240)"
fi

###############################################################################
# F2P t4_f2p_no_full_decompression (0.25): metadata-only.
# We hook zipfile.ZipFile.open and wrap the returned stream's .read() to count
# bytes consumed from the "latents.npy" member during is_disk_cached_latents_expected.
# A header-only read should consume <= 1024 bytes (typical .npy header is ~128B).
# A np.load(p)["latents"] path will read the entire body (here 4*64*64*4 = 65536 B).
###############################################################################
python3 << 'PYEOF' >/tmp/g5.log 2>&1
import sys, os, io, tempfile, numpy as np, zipfile
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy

bucket = (512, 512); h, w = 64, 64
fd, p = tempfile.mkstemp(suffix=".npz"); os.close(fd)
# Use uncompressed savez so the zip member is straightforward.
np.savez(p,
    latents=np.zeros((4, h, w), dtype=np.float32),
    original_size=np.array([512, 512]),
    crop_ltrb=np.array([0, 0, 0, 0]),
)

orig_open = zipfile.ZipFile.open
counters = {"latents_bytes": 0, "latents_opens": 0}

class CountingStream:
    def __init__(self, inner, counter_key):
        self._inner = inner
        self._key = counter_key
    def read(self, *a, **kw):
        b = self._inner.read(*a, **kw)
        if b:
            counters[self._key] += len(b)
        return b
    def readline(self, *a, **kw):
        b = self._inner.readline(*a, **kw)
        if b:
            counters[self._key] += len(b)
        return b
    def readinto(self, buf):
        n = self._inner.readinto(buf)
        if n:
            counters[self._key] += n
        return n
    def seek(self, *a, **kw):
        return self._inner.seek(*a, **kw)
    def tell(self):
        return self._inner.tell()
    def close(self):
        return self._inner.close()
    def seekable(self):
        try: return self._inner.seekable()
        except Exception: return False
    def readable(self):
        return True
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return self._inner.close()
    def __getattr__(self, k):
        return getattr(self._inner, k)

def patched_open(self, name, *a, **kw):
    n = name.filename if hasattr(name, "filename") else str(name)
    base = os.path.basename(n)
    stream = orig_open(self, name, *a, **kw)
    if base == "latents.npy":
        counters["latents_opens"] += 1
        return CountingStream(stream, "latents_bytes")
    return stream

zipfile.ZipFile.open = patched_open
try:
    strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)
    counters["latents_bytes"] = 0
    counters["latents_opens"] = 0
    r = strat.is_disk_cached_latents_expected(bucket, p, flip_aug=False, alpha_mask=False)
    assert r, "legacy not accepted"
    # Header-only: should be << full body (65536 bytes). Allow up to 1024 to be lenient.
    assert counters["latents_bytes"] <= 1024, (
        f"latents body bytes read = {counters['latents_bytes']} "
        f"(expected <=1024 header-only); opens={counters['latents_opens']}"
    )
finally:
    zipfile.ZipFile.open = orig_open
    try: os.unlink(p)
    except Exception: pass
PYEOF
G5=$?
if [ $G5 -eq 0 ]; then
    emit t4_f2p_no_full_decompression true ""
else
    emit t4_f2p_no_full_decompression false "$(tr '\n' ' ' </tmp/g5.log | tail -c 240)"
fi

###############################################################################
# F2P t4_f2p_truncated_body_ok (0.20): build an npz whose latents.npy member has
# a valid .npy header but a truncated body. A header-only reader must produce
# a sane bool from is_disk_cached_latents_expected without raising on full read.
# Gated on G5 having passed, so we don't reward implementations that simply
# return False for every legacy npz.
###############################################################################
python3 << 'PYEOF' >/tmp/g6.log 2>&1
import sys, os, io, tempfile, numpy as np, zipfile
sys.path.insert(0, "/workspace/sd-scripts")
from library.strategy_sd import SdSdxlLatentsCachingStrategy
import numpy.lib.format as npf

bucket = (512, 512); h, w = 64, 64

def make_npy_header_only(shape, dtype):
    buf = io.BytesIO()
    npf.write_array_header_2_0(buf, {
        "descr": np.lib.format.dtype_to_descr(np.dtype(dtype)),
        "fortran_order": False,
        "shape": tuple(shape),
    })
    return buf.getvalue()

def write_truncated_npz(path, shape):
    # Build a zip with truncated latents.npy (header only) plus full small entries
    # for original_size/crop_ltrb so any code that reads those still works.
    osz = np.array([512, 512])
    cltrb = np.array([0, 0, 0, 0])
    osz_buf = io.BytesIO(); np.lib.format.write_array(osz_buf, osz); osz_bytes = osz_buf.getvalue()
    cl_buf = io.BytesIO(); np.lib.format.write_array(cl_buf, cltrb); cl_bytes = cl_buf.getvalue()
    lat_header = make_npy_header_only(shape, np.float32)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as z:
        # Header only — no array body bytes follow.
        z.writestr("latents.npy", lat_header)
        z.writestr("original_size.npy", osz_bytes)
        z.writestr("crop_ltrb.npy", cl_bytes)

# Case A: header reports correct shape -> should accept (True)
fd, pa = tempfile.mkstemp(suffix=".npz"); os.close(fd)
write_truncated_npz(pa, (4, h, w))

# Case B: header reports wrong shape -> should reject (False)
fd, pb = tempfile.mkstemp(suffix=".npz"); os.close(fd)
write_truncated_npz(pb, (4, 32, 32))

try:
    strat = SdSdxlLatentsCachingStrategy(sd=True, cache_to_disk=True, batch_size=1, skip_disk_cache_validity_check=False)

    # Must NOT crash on either path; must return True for A, False for B.
    ra = strat.is_disk_cached_latents_expected(bucket, pa, flip_aug=False, alpha_mask=False)
    rb = strat.is_disk_cached_latents_expected(bucket, pb, flip_aug=False, alpha_mask=False)
    assert ra is True or ra == True, f"truncated-correct-shape rejected: {ra!r}"
    assert not rb, f"truncated-wrong-shape accepted: {rb!r}"
finally:
    for x in (pa, pb):
        try: os.unlink(x)
        except Exception: pass
PYEOF
G6=$?
# Gate G6 on G5 to avoid rewarding "always-False" strategies that incidentally
# satisfy the wrong-shape rejection branch.
if [ $G5 -eq 0 ] && [ $G6 -eq 0 ]; then
    emit t4_f2p_truncated_body_ok true ""
    G6_PASS=1
else
    if [ $G5 -ne 0 ]; then
        emit t4_f2p_truncated_body_ok false "gated on t4_f2p_no_full_decompression"
    else
        emit t4_f2p_truncated_body_ok false "$(tr '\n' ' ' </tmp/g6.log | tail -c 240)"
    fi
    G6_PASS=0
fi

###############################################################################
# Reward aggregation. F2P weights sum to 1.00:
#   t1_legacy_accepted          0.15
#   t1_legacy_load              0.15
#   t3_wrong_shape_rejected     0.10
#   t3_suffix_priority          0.15
#   t4_no_full_decompression    0.25
#   t4_truncated_body_ok        0.20
###############################################################################
add() { REWARD=$(awk "BEGIN{printf \"%.4f\", $REWARD + $1}"); }

[ $G1 -eq 0 ] && add 0.15
[ $G2 -eq 0 ] && add 0.15
[ $G3 -eq 0 ] && add 0.10
[ $G4 -eq 0 ] && add 0.15
[ $G5 -eq 0 ] && add 0.25
[ $G6_PASS -eq 1 ] && add 0.20

printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
echo "REWARD=$REWARD"
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
run_v043_gate f2p_upstream_1bfda384 'py_compile_changed' 'cd /workspace/sd-scripts && /workspace/venv/bin/python3 -m py_compile library/strategy_base.py'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"f2p_upstream_1bfda384": 0.2, "t1_f2p_legacy_accepted": 0.12, "t1_f2p_legacy_load": 0.12, "t3_f2p_suffix_priority": 0.12, "t3_f2p_wrong_shape_rejected": 0.08, "t4_f2p_no_full_decompression": 0.2, "t4_f2p_truncated_body_ok": 0.16}
P2P_REGRESSION = ["p2p_suffixed_path_regression"]
P2P_REGRESSION = []
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