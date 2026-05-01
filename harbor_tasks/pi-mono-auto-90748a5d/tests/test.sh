#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD=0.0

REPO_DIR="/workspace/pi-mono"
CLIP_FILE="$REPO_DIR/packages/coding-agent/src/utils/clipboard-image.ts"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -d "$HOME/.nvm" ]; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
fi
for d in /root/.nvm/versions/node/*/bin /usr/local/n/versions/node/*/bin; do
    [ -d "$d" ] && export PATH="$d:$PATH"
done

write_reward() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

if ! command -v node >/dev/null 2>&1; then
    echo "node missing"
    write_reward
fi

if [ ! -f "$CLIP_FILE" ]; then
    echo "clipboard-image.ts missing"
    write_reward
fi

# ============================================================
# P2P GATES (gating only, no reward)
# ============================================================

# Gate: file integrity
LINES=$(wc -l < "$CLIP_FILE" 2>/dev/null || echo 0)
if [ "$LINES" -lt 50 ]; then
    echo "GATE FAIL: clipboard-image.ts too short"
    write_reward
fi
if ! grep -qE "readClipboardImage|isSupportedImageMimeType" "$CLIP_FILE"; then
    echo "GATE FAIL: key exports missing"
    write_reward
fi

# Gate: parse with esbuild if available, else balance check
ESBUILD=""
for path in "$REPO_DIR/node_modules/.bin/esbuild" "$REPO_DIR/packages/coding-agent/node_modules/.bin/esbuild"; do
    [ -x "$path" ] && ESBUILD="$path" && break
done
command -v esbuild >/dev/null 2>&1 && [ -z "$ESBUILD" ] && ESBUILD="esbuild"

PARSE_OK=0
if [ -n "$ESBUILD" ]; then
    if "$ESBUILD" --loader=ts --bundle=false --log-level=silent "$CLIP_FILE" >/tmp/eb.js 2>/tmp/eb.err; then
        PARSE_OK=1
    fi
fi
if [ "$PARSE_OK" = "0" ]; then
    # Heuristic balance check (don't fail gating since esbuild may be unavailable)
    PARSE_OK=1
fi

# ============================================================
# Detect approach: Did the agent replace photon with native code?
# This is the F2P signal: on the base (no-op), photon import is present
# and convertToPng calls loadPhoton. After the fix, photon is gone from
# the clipboard path AND a real PNG encoder exists.
# ============================================================

PHOTON_GONE=0
if ! grep -qE 'loadPhoton|from "\./photon' "$CLIP_FILE"; then
    PHOTON_GONE=1
fi

HAS_DEFLATE=0
if grep -qE 'deflateSync|require\(["'\'']zlib["'\'']\)|from ["'\'']zlib["'\'']|from ["'\'']node:zlib["'\'']' "$CLIP_FILE"; then
    HAS_DEFLATE=1
fi

HAS_PNG_SIG=0
if grep -qE '0x89.*0x50.*0x4e.*0x47|137.*80.*78.*71' "$CLIP_FILE"; then
    HAS_PNG_SIG=1
fi

HAS_CRC=0
if grep -qiE '0xedb88320' "$CLIP_FILE"; then
    HAS_CRC=1
fi

echo "Detect: PHOTON_GONE=$PHOTON_GONE HAS_DEFLATE=$HAS_DEFLATE HAS_PNG_SIG=$HAS_PNG_SIG HAS_CRC=$HAS_CRC"

# ============================================================
# F2P 1 (0.20): Photon dependency removed from clipboard path
#   Base: photon import present -> FAIL
#   Fix: photon import removed -> PASS
# ============================================================
F2P1=0
if [ "$PHOTON_GONE" = "1" ]; then F2P1=1; fi

# ============================================================
# F2P 2 (0.20): Native PNG primitives present (zlib + signature + CRC poly)
#   Base: none of these -> FAIL
#   Fix: all present -> PASS
# ============================================================
F2P2=0
if [ "$HAS_DEFLATE" = "1" ] && [ "$HAS_PNG_SIG" = "1" ] && [ "$HAS_CRC" = "1" ]; then
    F2P2=1
fi

# ============================================================
# F2P 3 (0.60): BEHAVIORAL — actually run conversion on a synthetic BMP
# Transpile clipboard-image.ts and call its converter on a synthetic 24-bit BMP.
# Verify produced bytes are a valid PNG: signature, IHDR W/H, IDAT inflates,
# IEND present, CRCs valid.
# ============================================================
F2P3=0

if [ -n "$ESBUILD" ] && [ "$F2P1" = "1" ] && [ "$F2P2" = "1" ]; then
    WORK=/tmp/pr1112_verify
    rm -rf "$WORK"
    mkdir -p "$WORK"

    # Transpile to ESM JS, stripping imports we can't resolve
    cp "$CLIP_FILE" "$WORK/orig.ts"

    # Strip side-effect imports / external imports that we can't resolve.
    # Keep only zlib import (node builtin) and node builtin imports.
    node -e "
const fs=require('fs');
let s=fs.readFileSync('$WORK/orig.ts','utf8');
// Remove imports of './clipboard-native.js', './photon.js', child_process spawnSync usage stays harmless
s=s.replace(/^\s*import[^;]*from\s*[\"']\.\/clipboard-native[^;]*;?\s*$/gm,'');
s=s.replace(/^\s*import[^;]*from\s*[\"']\.\/photon[^;]*;?\s*$/gm,'');
fs.writeFileSync('$WORK/stripped.ts',s);
" 2>/tmp/strip.err

    if "$ESBUILD" --loader=ts --format=esm --target=es2022 --platform=node --log-level=silent "$WORK/stripped.ts" > "$WORK/mod.mjs" 2>"$WORK/eb.err"; then

        # Build BMP fixture
        node -e "
const fs=require('fs');
const W=4,H=3;
const rowBytes=W*3;
const pad=(4-(rowBytes%4))%4;
const rowSize=rowBytes+pad;
const pixelDataSize=rowSize*H;
const fileSize=14+40+pixelDataSize;
const buf=Buffer.alloc(fileSize);
buf.write('BM',0,'ascii');
buf.writeUInt32LE(fileSize,2);
buf.writeUInt32LE(0,6);
buf.writeUInt32LE(54,10);
buf.writeUInt32LE(40,14);
buf.writeInt32LE(W,18);
buf.writeInt32LE(H,22);
buf.writeUInt16LE(1,26);
buf.writeUInt16LE(24,28);
buf.writeUInt32LE(0,30);
buf.writeUInt32LE(pixelDataSize,34);
buf.writeInt32LE(2835,38);
buf.writeInt32LE(2835,42);
buf.writeUInt32LE(0,46);
buf.writeUInt32LE(0,50);
let off=54;
for(let y=H-1;y>=0;y--){
  for(let x=0;x<W;x++){
    buf[off++]=(x*16)&0xff;
    buf[off++]=(y*64)&0xff;
    buf[off++]=(255-x*16)&0xff;
  }
  for(let p=0;p<pad;p++)buf[off++]=0;
}
fs.writeFileSync('$WORK/sample.bmp',buf);
"

        # Harness: import the module, find a converter function, run it, validate PNG
        cat > "$WORK/harness.mjs" <<'HARNESS'
import fs from 'fs';
import zlib from 'zlib';

const W = 4, H = 3;
const modPath = process.argv[2];
const bmpPath = process.argv[3];
const bmp = fs.readFileSync(bmpPath);

let mod;
try {
    mod = await import(modPath);
} catch (e) {
    console.error('IMPORT_FAIL', e.message);
    process.exit(2);
}

// Find a candidate function that takes bytes and returns bytes (Uint8Array/Buffer or Promise thereof)
const candidates = [];
for (const [k, v] of Object.entries(mod)) {
    if (typeof v === 'function') candidates.push([k, v]);
}
// Most agents make convertToPng / convertBmpToPng module-private, so try via re-export trick:
// esbuild --format=esm leaves non-exported funcs unreachable. We must search source for a callable export.
// Re-strategy: parse the bundled JS text and rewrite to expose every top-level function declaration.

// If no candidates, exit
if (candidates.length === 0) {
    console.error('NO_EXPORTS');
    process.exit(3);
}

async function tryConvert(fn, bytes) {
    try {
        const r = fn(bytes);
        return r && typeof r.then === 'function' ? await r : r;
    } catch (e) { return null; }
}

function validatePng(buf, expectedW, expectedH) {
    if (!buf || buf.length < 8) return { ok: false, reason: 'too short' };
    const u = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
    const sig = [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a];
    for (let i = 0; i < 8; i++) if (u[i] !== sig[i]) return { ok: false, reason: 'bad signature' };
    // First chunk must be IHDR
    let off = 8;
    const ihdrLen = u.readUInt32BE(off); off += 4;
    const ihdrType = u.slice(off, off+4).toString('ascii'); off += 4;
    if (ihdrType !== 'IHDR' || ihdrLen !== 13) return { ok: false, reason: 'bad IHDR' };
    const w = u.readUInt32BE(off); off += 4;
    const h = u.readUInt32BE(off); off += 4;
    if (w !== expectedW || h !== expectedH) return { ok: false, reason: `wh ${w}x${h}` };
    off += 5; // bit depth, color, comp, filter, interlace
    off += 4; // CRC

    // Walk chunks, collect IDAT, find IEND, validate CRCs
    let idat = Buffer.alloc(0);
    let sawIend = false;
    while (off < u.length) {
        const len = u.readUInt32BE(off); off += 4;
        const type = u.slice(off, off+4).toString('ascii');
        const dataStart = off + 4;
        const dataEnd = dataStart + len;
        if (dataEnd + 4 > u.length) return { ok: false, reason: 'truncated' };
        const data = u.slice(dataStart, dataEnd);
        const crcGiven = u.readUInt32BE(dataEnd);
        // Validate CRC
        const crcInput = u.slice(off, dataEnd);
        // CRC over type+data
        let crc = 0xffffffff;
        for (let i = 0; i < crcInput.length; i++) {
            crc ^= crcInput[i];
            for (let k = 0; k < 8; k++) {
                crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
            }
        }
        crc = (crc ^ 0xffffffff) >>> 0;
        if (crc !== crcGiven) return { ok: false, reason: `bad CRC ${type}` };
        if (type === 'IDAT') idat = Buffer.concat([idat, data]);
        if (type === 'IEND') { sawIend = true; off = dataEnd + 4; break; }
        off = dataEnd + 4;
    }
    if (!sawIend) return { ok: false, reason: 'no IEND' };
    if (idat.length === 0) return { ok: false, reason: 'no IDAT' };
    // Inflate
    let raw;
    try { raw = zlib.inflateSync(idat); }
    catch (e) { return { ok: false, reason: 'inflate fail: ' + e.message }; }
    // Expected raw size: H * (1 + W*3) for RGB, OR H * (1 + W*4) for RGBA
    const rgb = expectedH * (1 + expectedW * 3);
    const rgba = expectedH * (1 + expectedW * 4);
    if (raw.length !== rgb && raw.length !== rgba) {
        return { ok: false, reason: `raw size ${raw.length} not ${rgb} or ${rgba}` };
    }
    return { ok: true };
}

let success = false;
for (const [name, fn] of candidates) {
    if (fn.length < 1) continue;
    const result = await tryConvert(fn, bmp);
    if (!result) continue;
    const v = validatePng(result, W, H);
    if (v.ok) {
        console.log('CONVERT_OK', name);
        success = true;
        break;
    } else {
        console.error('CANDIDATE_FAIL', name, v.reason);
    }
}

process.exit(success ? 0 : 4);
HARNESS

        # The exported function may not be exported. Patch mod.mjs to export every top-level function declaration.
        node -e "
const fs=require('fs');
let s=fs.readFileSync('$WORK/mod.mjs','utf8');
// Find top-level 'function NAME(' and 'async function NAME(' declarations and re-export
const re=/^(async\s+)?function\s+([A-Za-z_\$][A-Za-z0-9_\$]*)\s*\(/gm;
const names=new Set();
let m;
while((m=re.exec(s))!==null){ names.add(m[2]); }
let exports='';
for(const n of names){
  // skip if already exported
  if(new RegExp('export\\\\s*\\\\{[^}]*\\\\b'+n+'\\\\b').test(s)) continue;
  exports += 'export { '+n+' };\n';
}
fs.writeFileSync('$WORK/mod.mjs', s+'\n'+exports);
" 2>/tmp/patch.err

        if node "$WORK/harness.mjs" "$WORK/mod.mjs" "$WORK/sample.bmp" >/tmp/harness.out 2>/tmp/harness.err; then
            F2P3=1
        fi
        echo "--- harness stdout ---"
        head -20 /tmp/harness.out 2>/dev/null
        echo "--- harness stderr ---"
        head -20 /tmp/harness.err 2>/dev/null
    else
        echo "esbuild transpile failed:"
        head -20 "$WORK/eb.err" 2>/dev/null
    fi
fi

# ============================================================
# Compute reward
# ============================================================

awk_calc() {
    awk "BEGIN { printf \"%.4f\", $1 }"
}

W1=0.16
W2=0.16
W3=0.48

R=$(awk "BEGIN { printf \"%.4f\", $F2P1*$W1 + $F2P2*$W2 + $F2P3*$W3 }")
REWARD=$R

echo "F2P1 (photon removed): $F2P1 (w=$W1)"
echo "F2P2 (native PNG primitives): $F2P2 (w=$W2)"
echo "F2P3 (behavioral BMP->PNG): $F2P3 (w=$W3)"
echo "REWARD=$REWARD"

echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
GATES_FILE="/logs/verifier/gates.json"
touch "$GATES_FILE"

# All upstream gates run from repo dir
cd "$REPO_DIR" || true

# F2P: BMP-to-PNG vitest with Photon mocked out
printf 'export async function resolve(s,c,n){if(s.includes("photon-node")||s.includes("photon.js"))return{shortCircuit:true,url:"data:text/javascript,export function loadPhoton(){return null;}"};return n(s,c);}' > /tmp/_pi_mock_photon.mjs
NODE_OPTIONS="--loader /tmp/_pi_mock_photon.mjs" node_modules/.bin/vitest run packages/coding-agent/test/clipboard-image-bmp-conversion.test.ts --reporter=verbose > /tmp/_gate_bmp.log 2>&1
_gate_bmp_rc=$?
tail -20 /tmp/_gate_bmp.log
if [ "$_gate_bmp_rc" -eq 0 ]; then
    echo '{"id":"f2p_upstream_bmp_vitest","passed":true,"detail":"BMP conversion test passed with Photon mocked"}' >> "$GATES_FILE"
else
    echo '{"id":"f2p_upstream_bmp_vitest","passed":false,"detail":"BMP conversion test failed with Photon mocked"}' >> "$GATES_FILE"
fi

# P2P: Biome lint/format check
node_modules/.bin/biome check "$CLIP_FILE" > /tmp/_gate_biome.log 2>&1
_gate_biome_rc=$?
tail -5 /tmp/_gate_biome.log
if [ "$_gate_biome_rc" -eq 0 ]; then
    echo '{"id":"p2p_upstream_biome","passed":true,"detail":"biome check passed"}' >> "$GATES_FILE"
else
    echo '{"id":"p2p_upstream_biome","passed":false,"detail":"biome check failed"}' >> "$GATES_FILE"
fi

# P2P: tsgo type check
node_modules/.bin/tsgo --noEmit > /tmp/_gate_tsgo.log 2>&1
_gate_tsgo_rc=$?
tail -5 /tmp/_gate_tsgo.log
if [ "$_gate_tsgo_rc" -eq 0 ]; then
    echo '{"id":"p2p_upstream_tsgo","passed":true,"detail":"tsgo --noEmit passed"}' >> "$GATES_FILE"
else
    echo '{"id":"p2p_upstream_tsgo","passed":false,"detail":"tsgo --noEmit failed"}' >> "$GATES_FILE"
fi

# P2P: vitest clipboard-image tests
node_modules/.bin/vitest run packages/coding-agent/test/clipboard-image.test.ts --reporter=verbose > /tmp/_gate_vitest.log 2>&1
_gate_vitest_rc=$?
tail -10 /tmp/_gate_vitest.log
if [ "$_gate_vitest_rc" -eq 0 ]; then
    echo '{"id":"p2p_upstream_vitest_clipboard","passed":true,"detail":"clipboard-image vitest passed"}' >> "$GATES_FILE"
else
    echo '{"id":"p2p_upstream_vitest_clipboard","passed":false,"detail":"clipboard-image vitest failed"}' >> "$GATES_FILE"
fi

# Upstream reward tail: adjust reward based on upstream gate results
python3 -c "
import json, os, sys
WEIGHTS = {'f2p_upstream_bmp_vitest': 0.20}
P2P_REGRESSION = ['p2p_upstream_biome', 'p2p_upstream_tsgo', 'p2p_upstream_vitest_clipboard']
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
# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
hard_zero = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
if hard_zero:
    reward = 0.0
else:
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += w
    reward = min(reward, 1.0)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM_REWARD=%.4f' % reward)
"
# ---- end ----