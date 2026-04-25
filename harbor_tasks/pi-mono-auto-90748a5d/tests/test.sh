#!/bin/bash
set +e

# Verifier for pi-mono PR #1112: BMP→PNG clipboard conversion
# Behavioral focus: extract the agent's converter and run it on a synthetic BMP,
# verifying that the produced bytes form a valid PNG decodable by zlib (IDAT inflate)
# with correct dimensions, signature, and CRCs.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

REPO_DIR="/workspace/pi-mono"
CLIP_FILE="$REPO_DIR/packages/coding-agent/src/utils/clipboard-image.ts"
INTERACTIVE_FILE="$REPO_DIR/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
PHOTON_FILE="$REPO_DIR/packages/coding-agent/src/utils/photon.ts"
CHANGELOG="$REPO_DIR/packages/coding-agent/CHANGELOG.md"

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -d "$HOME/.nvm" ]; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
fi

# Try to add common node bin dirs
for d in /root/.nvm/versions/node/*/bin /usr/local/n/versions/node/*/bin; do
    [ -d "$d" ] && export PATH="$d:$PATH"
done

if ! command -v node >/dev/null 2>&1; then
    echo "node missing; cannot verify"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

if [ ! -d "$REPO_DIR" ] || [ ! -f "$CLIP_FILE" ]; then
    echo "Repo or clipboard-image.ts missing at expected path: $REPO_DIR"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

echo "=== Git status ==="
(cd "$REPO_DIR" && git status --short 2>/dev/null | head -50)
echo "=== Git diff stat ==="
(cd "$REPO_DIR" && git diff --stat 2>/dev/null | head -30)
echo ""

TOTAL=100
SCORE=0

add_score() {
    local w=$1
    local label=$2
    local ok=$3
    if [ "$ok" = "1" ]; then
        echo "PASS [w=$w] $label"
        SCORE=$((SCORE + w))
    else
        echo "FAIL [w=$w] $label"
    fi
}

############################################
# P2P 1 (w=8): file integrity
############################################
P1_OK=0
LINES=$(wc -l < "$CLIP_FILE" 2>/dev/null || echo 0)
if [ "$LINES" -ge 50 ] && grep -q "^export\|readClipboardImage\|isSupportedImageMimeType" "$CLIP_FILE"; then
    P1_OK=1
fi
add_score 8 "P2P: clipboard-image.ts intact (>=50 lines, key exports preserved)" "$P1_OK"

############################################
# P2P 2 (w=7): syntax (try tsc/esbuild/node-strip-types fallback)
############################################
P2_OK=0
SYNTAX_TOOL=""
ESBUILD=""
for path in "$REPO_DIR/node_modules/.bin/esbuild" "$REPO_DIR/packages/coding-agent/node_modules/.bin/esbuild"; do
    [ -x "$path" ] && ESBUILD="$path" && break
done
command -v esbuild >/dev/null 2>&1 && [ -z "$ESBUILD" ] && ESBUILD="esbuild"

if [ -n "$ESBUILD" ]; then
    if "$ESBUILD" --loader=ts --bundle=false --log-level=silent "$CLIP_FILE" >/tmp/esbuild.out 2>/tmp/esbuild.err; then
        P2_OK=1
        SYNTAX_TOOL="esbuild"
    fi
fi

if [ "$P2_OK" = "0" ]; then
    # Heuristic balance check
    node -e "
      const fs=require('fs');
      const s=fs.readFileSync('$CLIP_FILE','utf8');
      let inStr=false,inTpl=false,inLine=false,inBlock=false,depth={c:0,p:0,b:0};
      let q='';
      for(let i=0;i<s.length;i++){
        const ch=s[i],n=s[i+1];
        if(inLine){ if(ch==='\n')inLine=false; continue;}
        if(inBlock){ if(ch==='*'&&n==='/'){inBlock=false;i++;} continue;}
        if(inStr){ if(ch==='\\\\'){i++;continue;} if(ch===q){inStr=false;} continue;}
        if(inTpl){ if(ch==='\\\\'){i++;continue;} if(ch==='\`'){inTpl=false;} continue;}
        if(ch==='/'&&n==='/'){inLine=true;i++;continue;}
        if(ch==='/'&&n==='*'){inBlock=true;i++;continue;}
        if(ch==='\"'||ch==='\\''){inStr=true;q=ch;continue;}
        if(ch==='\`'){inTpl=true;continue;}
        if(ch==='{')depth.c++; else if(ch==='}')depth.c--;
        else if(ch==='(')depth.p++; else if(ch===')')depth.p--;
        else if(ch==='[')depth.b++; else if(ch===']')depth.b--;
      }
      if(depth.c===0&&depth.p===0&&depth.b===0) process.exit(0);
      console.error('imbalance', depth);
      process.exit(1);
    " >/dev/null 2>&1 && P2_OK=1 && SYNTAX_TOOL="balance"
fi
add_score 7 "P2P: clipboard-image.ts parses ($SYNTAX_TOOL)" "$P2_OK"

############################################
# Detect approach: photon-replacement (preferred per PR) vs fallback-removal-only
############################################
PHOTON_REPLACED=0
if ! grep -qE 'loadPhoton|from "\./photon' "$CLIP_FILE"; then
    PHOTON_REPLACED=1
fi

HAS_DEFLATE=0
if grep -qE 'deflateSync|require\("zlib"\)|from "zlib"|from "node:zlib"' "$CLIP_FILE"; then
    HAS_DEFLATE=1
fi

HAS_PNG_SIG=0
if grep -qE '0x89.*0x50.*0x4e.*0x47|137.*80.*78.*71' "$CLIP_FILE"; then
    HAS_PNG_SIG=1
fi

HAS_CRC=0
if grep -qE '0xedb88320|0xEDB88320' "$CLIP_FILE"; then
    HAS_CRC=1
fi

CONVERSION_PRESENT=0
if [ "$HAS_DEFLATE" = "1" ] && [ "$HAS_PNG_SIG" = "1" ] && [ "$HAS_CRC" = "1" ]; then
    CONVERSION_PRESENT=1
fi

echo "Detect: PHOTON_REPLACED=$PHOTON_REPLACED CONVERSION_PRESENT=$CONVERSION_PRESENT HAS_DEFLATE=$HAS_DEFLATE HAS_PNG_SIG=$HAS_PNG_SIG HAS_CRC=$HAS_CRC"

############################################
# F2P 1 (w=12): photon dependency removed from clipboard path
############################################
add_score 12 "F2P: photon import/usage removed from clipboard path" "$PHOTON_REPLACED"

############################################
# F2P 2 (w=10): pure-Node PNG construction primitives present
############################################
PRIMS_OK=0
[ "$CONVERSION_PRESENT" = "1" ] && PRIMS_OK=1
add_score 10 "F2P: zlib + PNG signature + CRC32 polynomial all present" "$PRIMS_OK"

############################################
# F2P 3 (w=30): BEHAVIORAL — actually run conversion on a synthetic BMP
# Strategy:
#   - Use esbuild or sucrase or tsx to transpile the TS file to JS
#   - Call exported convert function (try several names) with a synthetic 24-bit BMP
#   - Validate PNG: signature, IHDR width/height, IDAT inflates to expected raw filtered scanlines
############################################
BEHAV_OK=0
BEHAV_PARTIAL=0

# Find a TS->JS transpile tool
TRANSPILE=""
if [ -n "$ESBUILD" ]; then
    TRANSPILE="esbuild"
fi

if [ -z "$TRANSPILE" ]; then
    # Try installing nothing; use node's built-in stripping if available (Node >= 22.6 with --experimental-strip-types)
    NODE_VER=$(node -e "process.stdout.write(process.versions.node)")
    NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 22 ]; then
        TRANSPILE="node-strip"
    fi
fi

mkdir -p /tmp/pr1112_test
cp "$CLIP_FILE" /tmp/pr1112_test/clipboard-image.ts

# Generate synthetic 24-bit BMP: 4x3 image with known pixel values
node -e "
const fs=require('fs');
const W=4,H=3;
const rowBytes=W*3;
const pad=(4-(rowBytes%4))%4;
const rowSize=rowBytes+pad;
const pixelDataSize=rowSize*H;
const fileSize=14+40+pixelDataSize;
const buf=Buffer.alloc(fileSize);
// File header
buf.write('BM',0,'ascii');
buf.writeUInt32LE(fileSize,2);
buf.writeUInt32LE(0,6);
buf.writeUInt32LE(54,10);
// DIB header
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
// Pixels: BMP rows are bottom-up. We'll write each row top-to-bottom in a known pattern.
// Top row (y=0) -> stored last. Pattern: row y, col x => B=x*16, G=y*64, R=255-x*16
let off=54;
for(let y=H-1;y>=0;y--){
  for(let x=0;x<W;x++){
    buf[off++]=(x*16)&0xff;       // B
    buf[off++]=(y*64)&0xff;       // G
    buf[off++]=(255-x*16)&0xff;   // R
  }
  for(let p=0;p<pad;p++)buf[off++]=0;
}
fs.writeFileSync('/tmp/pr1112_test/sample.bmp',buf);
console.log('BMP written',buf.length,'bytes');
" 2>&1 | head -5

# Build a harness that imports the transpiled module and calls a convert function
cat > /tmp/pr1112_test/harness.mjs <<'HARNESS'
import fs from 'fs';
import zlib from 'zlib';

const modPath = process.argv[2];
const bmpPath = process.argv[3];

const mod = await import(modPath);

// Try to find an exported or non-exported conversion function. Since the agent's
// function may not be exported, we also fall back to invoking readClipboardImage
// via a mocked clipboard path - but that's brittle. Instead, inspect module.
let fn = null;
const candidateNames = [
  'convertBmpToPng', 'convertToPng', 'bmpToPng', 'convertImageToPng',
  '_convertBmpToPng', '_convertToPng'
];
for (const n of candidateNames) {
  if (typeof mod[n] === 'function') { fn = mod[n]; console.log('found export', n); break; }
}

if (!fn) {
  // Try default export object
  if (mod.default) {
    for (const n of candidateNames) {
      if (typeof mod.default[n] === 'function') { fn = mod.default[n]; console.log('found default.'+n); break; }
    }
  }
}

if (!fn) {
  console.error('NO_CONVERT_FN');
  process.exit(2);
}

const bmp = fs.readFileSync(bmpPath);
let out;
try {
  out = await fn(new Uint8Array(bmp));
} catch (e) {
  console.error('CONVERT_THREW', e.message);
  process.exit(3);
}
if (!out) {
  console.error('CONVERT_RETURNED_NULL');
  process.exit(4);
}

const png = Buffer.isBuffer(out) ? out : Buffer.from(out);
console.log('PNG_LEN', png.length);

// Validate signature
const sig = Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]);
if (!png.slice(0,8).equals(sig)) {
  console.error('BAD_SIG', png.slice(0,8).toString('hex'));
  process.exit(5);
}

// Walk chunks
let pos = 8;
let ihdr = null;
const idatParts = [];
let sawIend = false;
while (pos < png.length) {
  if (pos + 8 > png.length) { console.error('TRUNC'); process.exit(6); }
  const len = png.readUInt32BE(pos);
  const type = png.slice(pos+4, pos+8).toString('ascii');
  const data = png.slice(pos+8, pos+8+len);
  const crc = png.readUInt32BE(pos+8+len);
  // Verify CRC
  const crcInput = png.slice(pos+4, pos+8+len);
  // Compute CRC32
  const table = (() => {
    const t = new Uint32Array(256);
    for (let i=0;i<256;i++){let c=i;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;t[i]=c;}
    return t;
  })();
  let c = 0xffffffff;
  for (let i=0;i<crcInput.length;i++) c = table[(c^crcInput[i])&0xff] ^ (c>>>8);
  c = (c ^ 0xffffffff) >>> 0;
  if (c !== crc) { console.error('BAD_CRC', type, c.toString(16), crc.toString(16)); process.exit(7); }
  if (type === 'IHDR') ihdr = data;
  else if (type === 'IDAT') idatParts.push(data);
  else if (type === 'IEND') { sawIend = true; break; }
  pos += 8 + len + 4;
}

if (!ihdr) { console.error('NO_IHDR'); process.exit(8); }
if (!idatParts.length) { console.error('NO_IDAT'); process.exit(9); }
if (!sawIend) { console.error('NO_IEND'); process.exit(10); }

const width = ihdr.readUInt32BE(0);
const height = ihdr.readUInt32BE(4);
const bitDepth = ihdr[8];
const colorType = ihdr[9];
console.log('IHDR', width, height, 'depth', bitDepth, 'color', colorType);

if (width !== 4 || height !== 3) {
  console.error('BAD_DIMS', width, height);
  process.exit(11);
}
if (bitDepth !== 8) { console.error('BAD_DEPTH'); process.exit(12); }
if (colorType !== 2 && colorType !== 6) { console.error('BAD_COLORTYPE', colorType); process.exit(13); }

// Inflate IDAT
const idat = Buffer.concat(idatParts);
let raw;
try { raw = zlib.inflateSync(idat); }
catch (e) { console.error('INFLATE_FAIL', e.message); process.exit(14); }

const bpp = colorType === 2 ? 3 : 4;
const expectedRowLen = 1 + width * bpp;
const expectedTotal = expectedRowLen * height;
console.log('RAW_LEN', raw.length, 'expected', expectedTotal);
if (raw.length !== expectedTotal) {
  console.error('BAD_RAW_LEN');
  process.exit(15);
}

// Decode (filters: 0=None, 1=Sub, 2=Up, 3=Avg, 4=Paeth) — simple support
const pixels = Buffer.alloc(width * height * bpp);
let prevRow = Buffer.alloc(width * bpp);
for (let y=0;y<height;y++){
  const filter = raw[y*expectedRowLen];
  const rowStart = y*expectedRowLen + 1;
  const row = Buffer.alloc(width * bpp);
  for (let x=0;x<width*bpp;x++){
    const cur = raw[rowStart+x];
    const left = x>=bpp ? row[x-bpp] : 0;
    const up = prevRow[x];
    const ul = x>=bpp ? prevRow[x-bpp] : 0;
    let v;
    switch(filter){
      case 0: v=cur; break;
      case 1: v=(cur+left)&0xff; break;
      case 2: v=(cur+up)&0xff; break;
      case 3: v=(cur+((left+up)>>1))&0xff; break;
      case 4: {
        const p=left+up-ul;
        const pa=Math.abs(p-left),pb=Math.abs(p-up),pc=Math.abs(p-ul);
        const pr=(pa<=pb&&pa<=pc)?left:(pb<=pc?up:ul);
        v=(cur+pr)&0xff; break;
      }
      default: console.error('BAD_FILTER',filter); process.exit(16);
    }
    row[x]=v;
  }
  row.copy(pixels, y*width*bpp);
  prevRow = row;
}

// Verify pixel content. PNG is top-down, BMP we wrote is bottom-up but we put
// row y=0 at top in pixel space (because we wrote bottom-up reversed already).
// Expected pattern at (x, y): R=255-x*16, G=y*64, B=x*16.
// PNG byte order in colorType 2 is R,G,B; in colorType 6 is R,G,B,A.
let mismatches = 0;
for (let y=0;y<height;y++){
  for (let x=0;x<width;x++){
    const off = (y*width + x)*bpp;
    const r=pixels[off], g=pixels[off+1], b=pixels[off+2];
    const eR=(255-x*16)&0xff, eG=(y*64)&0xff, eB=(x*16)&0xff;
    if (r!==eR || g!==eG || b!==eB) {
      if (mismatches<3) console.error(`PIX(${x},${y}) got=${r},${g},${b} exp=${eR},${eG},${eB}`);
      mismatches++;
    }
  }
}

if (mismatches === 0) {
  console.log('PIXELS_OK');
  process.exit(0);
} else {
  console.error('PIX_MISMATCH', mismatches);
  // Some implementations might swap R/B (BMP BGR vs PNG RGB confusion). Check that case too.
  let swapMatch = 0;
  for (let y=0;y<height;y++){
    for (let x=0;x<width;x++){
      const off = (y*width + x)*bpp;
      const r=pixels[off], g=pixels[off+1], b=pixels[off+2];
      const eR=(x*16)&0xff, eG=(y*64)&0xff, eB=(255-x*16)&0xff; // swapped
      if (r===eR&&g===eG&&b===eB) swapMatch++;
    }
  }
  if (swapMatch === width*height) {
    console.log('PIXELS_OK_BUT_RGB_SWAPPED');
    process.exit(20); // partial — RGB/BGR swap bug
  }
  // Or vertical flip
  let flipMatch = 0;
  for (let y=0;y<height;y++){
    for (let x=0;x<width;x++){
      const off = (y*width + x)*bpp;
      const r=pixels[off], g=pixels[off+1], b=pixels[off+2];
      const ey = height-1-y;
      const eR=(255-x*16)&0xff, eG=(ey*64)&0xff, eB=(x*16)&0xff;
      if (r===eR&&g===eG&&b===eB) flipMatch++;
    }
  }
  if (flipMatch === width*height) {
    console.log('PIXELS_OK_BUT_FLIPPED');
    process.exit(21);
  }
  process.exit(17);
}
HARNESS

# Transpile clipboard-image.ts -> .mjs, exporting all top-level functions for testing
TRANSPILED_OK=0
if [ "$TRANSPILE" = "esbuild" ]; then
    # Build a wrapper TS that re-exports private functions by name pattern
    # Strategy: append "export { convertBmpToPng, convertToPng };" guarded by
    # creating a shim. esbuild won't let us export non-existent names, so we
    # transpile then post-process to expose functions.
    "$ESBUILD" --loader=ts --format=esm --target=node18 \
        --bundle=false --platform=node \
        /tmp/pr1112_test/clipboard-image.ts > /tmp/pr1112_test/clipboard-image.mjs 2>/tmp/pr1112_test/esbuild.err

    if [ -s /tmp/pr1112_test/clipboard-image.mjs ]; then
        TRANSPILED_OK=1
        # Inject exports for any function declarations the test cares about
        node -e "
          const fs=require('fs');
          let s=fs.readFileSync('/tmp/pr1112_test/clipboard-image.mjs','utf8');
          // Strip imports that point to './clipboard-native.js' or './photon.js' which won't resolve
          s = s.replace(/^import\s+[^;]*from\s+[\"']\.\/clipboard-native\.js[\"'];?/gm, '');
          s = s.replace(/^import\s+[^;]*from\s+[\"']\.\/photon\.js[\"'];?/gm, '');
          // Stub clipboard reference if used at top-level
          if (/\\bclipboard\\b/.test(s) && !/const\\s+clipboard\\s*=/.test(s)) {
            s = 'const clipboard = { read(){ return null; } };\n' + s;
          }
          // Expose any 'function NAME' declarations
          const names = Array.from(s.matchAll(/^(?:async\s+)?function\s+([A-Za-z_\$][\w\$]*)/gm)).map(m=>m[1]);
          const candidates = ['convertBmpToPng','convertToPng','bmpToPng','convertImageToPng'];
          const toExport = names.filter(n => candidates.includes(n));
          if (toExport.length) {
            s += '\nexport { ' + toExport.join(', ') + ' };\n';
          }
          fs.writeFileSync('/tmp/pr1112_test/clipboard-image.mjs', s);
          console.log('exposed:', toExport.join(',') || '(none)');
        " 2>&1 | head -5
    else
        echo "esbuild failed:"
        head -20 /tmp/pr1112_test/esbuild.err 2>/dev/null
    fi
elif [ "$TRANSPILE" = "node-strip" ]; then
    # Use node's --experimental-strip-types via a wrapper
    # We'll let harness.mjs import the .ts directly with strip flag
    cp /tmp/pr1112_test/clipboard-image.ts /tmp/pr1112_test/clipboard-image-stub.ts
    # Strip problematic imports
    sed -i 's|from "./clipboard-native.js"|from "./_stub_native.js"|g' /tmp/pr1112_test/clipboard-image-stub.ts
    sed -i 's|from "./photon.js"|from "./_stub_photon.js"|g' /tmp/pr1112_test/clipboard-image-stub.ts
    cat > /tmp/pr1112_test/_stub_native.js <<'EOF'
export const clipboard = { read() { return null; } };
EOF
    cat > /tmp/pr1112_test/_stub_photon.js <<'EOF'
export async function loadPhoton() { return null; }
EOF
    TRANSPILED_OK=1
fi

if [ "$TRANSPILED_OK" = "1" ]; then
    if [ "$TRANSPILE" = "esbuild" ]; then
        node /tmp/pr1112_test/harness.mjs /tmp/pr1112_test/clipboard-image.mjs /tmp/pr1112_test/sample.bmp > /tmp/pr1112_test/harness.out 2>&1
    else
        # node strip-types: harness must import .ts; rewrite harness path arg
        node --experimental-strip-types --no-warnings /tmp/pr1112_test/harness.mjs /tmp/pr1112_test/clipboard-image-stub.ts /tmp/pr1112_test/sample.bmp > /tmp/pr1112_test/harness.out 2>&1
    fi
    HRC=$?
    echo "--- Harness output (rc=$HRC) ---"
    head -30 /tmp/pr1112_test/harness.out
    echo "--- end harness ---"
    if [ "$HRC" = "0" ]; then
        BEHAV_OK=1
    elif [ "$HRC" = "20" ] || [ "$HRC" = "21" ]; then
        # Pixels decode but with swap/flip — partial credit
        BEHAV_PARTIAL=1
    fi
fi

if [ "$BEHAV_OK" = "1" ]; then
    add_score 30 "F2P: BMP→PNG conversion produces valid PNG with correct pixels" 1
elif [ "$BEHAV_PARTIAL" = "1" ]; then
    echo "PARTIAL [w=15/30] F2P: PNG valid but pixel order has bug (RGB swap or vflip)"
    SCORE=$((SCORE + 15))
else
    add_score 30 "F2P: BMP→PNG conversion produces valid PNG with correct pixels" 0
fi

############################################
# F2P 4 (w=8): photon.ts may also be removed (PR's full intent)
# Partial: still acceptable if photon.ts left untouched but unused
############################################
PHOTON_DEAD=0
if [ ! -f "$PHOTON_FILE" ]; then
    PHOTON_DEAD=1
elif ! grep -rq "from \"./photon\|from '\./photon\|loadPhoton" "$REPO_DIR/packages/coding-agent/src" 2>/dev/null; then
    PHOTON_DEAD=1
fi
add_score 8 "F2P: photon.ts no longer referenced anywhere in coding-agent/src" "$PHOTON_DEAD"

############################################
# F2P 5 (w=10): TypeScript build smoke (best-effort)
############################################
TS_OK=0
TS_TESTED=0
TSC=""
for cand in "$REPO_DIR/packages/coding-agent/node_modules/.bin/tsc" "$REPO_DIR/node_modules/.bin/tsc"; do
    [ -x "$cand" ] && TSC="$cand" && break
done
[ -z "$TSC" ] && command -v tsc >/dev/null 2>&1 && TSC="tsc"

if [ -n "$TSC" ]; then
    TS_TESTED=1
    cd "$REPO_DIR/packages/coding-agent" 2>/dev/null
    timeout 180 "$TSC" --noEmit -p tsconfig.json >/tmp/tsc.log 2>&1
    RC=$?
    cd - >/dev/null
    if [ $RC -eq 0 ]; then
        TS_OK=1
    else
        # Accept if errors are not in clipboard-image.ts or interactive-mode.ts
        if ! grep -E "clipboard-image\.ts|interactive-mode\.ts" /tmp/tsc.log >/dev/null 2>&1; then
            TS_OK=1
        else
            echo "tsc errors (head):"
            grep -E "clipboard-image\.ts|interactive-mode\.ts" /tmp/tsc.log | head -10
        fi
    fi
fi

if [ "$TS_TESTED" = "1" ]; then
    add_score 10 "F2P: tsc clean for clipboard-image.ts / interactive-mode.ts" "$TS_OK"
else
    # Use esbuild parse as fallback (already verified above means clean syntax)
    if [ "$P2_OK" = "1" ]; then
        echo "PASS [w=5/10] F2P: tsc unavailable; esbuild syntax OK (partial)"
        SCORE=$((SCORE + 5))
    fi
fi

############################################
# Structural 1 (w=8): changelog entry referencing #1112
############################################
CL_OK=0
CL_PARTIAL=0
if [ -f "$CHANGELOG" ]; then
    if grep -qE '#1112|/pull/1112' "$CHANGELOG"; then
        # Stronger: must be in Fixed/Changed/Added section, not Breaking
        if grep -B1 -E '#1112|/pull/1112' "$CHANGELOG" | head -50 | grep -qE '^- '; then
            CL_OK=1
        else
            CL_PARTIAL=1
        fi
    fi
fi
if [ "$CL_OK" = "1" ]; then
    add_score 8 "Struct: changelog entry references PR #1112 in proper bullet" 1
elif [ "$CL_PARTIAL" = "1" ]; then
    echo "PARTIAL [w=4/8] Struct: changelog mentions #1112 but format imperfect"
    SCORE=$((SCORE + 4))
else
    add_score 8 "Struct: changelog entry references PR #1112" 0
fi

############################################
# Structural 2 (w=7): dead `?? "png"` fallback removed in interactive-mode.ts
# (PR intent — readClipboardImage now guarantees supported mime)
############################################
DEAD_OK=0
if [ -f "$INTERACTIVE_FILE" ]; then
    REM=$(grep -c '?? "png"' "$INTERACTIVE_FILE" 2>/dev/null)
    REM=${REM:-0}
    [ "$REM" = "0" ] && DEAD_OK=1
fi
add_score 7 "Struct: dead '?? \"png\"' fallback removed in interactive-mode.ts" "$DEAD_OK"

############################################
# Final
############################################
echo ""
echo "=== Score: $SCORE / $TOTAL ==="
REWARD=$(awk -v s="$SCORE" -v t="$TOTAL" 'BEGIN{ printf "%.3f", s/t }')
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0