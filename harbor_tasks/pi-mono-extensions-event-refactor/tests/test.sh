#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier 2>/dev/null || true
REWARD=0.0

cd /workspace/pi-mono 2>/dev/null || cd /workspace/repo 2>/dev/null

git config --global --add safe.directory "$(pwd)" 2>/dev/null || true

export PATH="$PATH:/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin"

PKG_DIR="packages/coding-agent"
RUNNER_TS="$PKG_DIR/src/core/extensions/runner.ts"
WRAPPER_TS="$PKG_DIR/src/core/extensions/wrapper.ts"
RUNNER_JS="$PKG_DIR/dist/core/extensions/runner.js"
WRAPPER_JS="$PKG_DIR/dist/core/extensions/wrapper.js"

# ─────────────────────────────────────────────────────────────────
# P2P GATE — TypeScript compilation must succeed (regression guard)
# This is a HARD GATE: failure → reward=0
# ─────────────────────────────────────────────────────────────────
echo "=== P2P GATE: TypeScript compilation in extensions/ ==="
cd /workspace/pi-mono/$PKG_DIR 2>/dev/null
TSC_OUTPUT=$(npx -y tsc -p tsconfig.build.json --noEmit 2>&1)
TSC_EXT_ERRORS=$(echo "$TSC_OUTPUT" | grep -c "extensions/.*error TS")
cd /workspace/pi-mono 2>/dev/null

if [ "$TSC_EXT_ERRORS" -ne 0 ]; then
    echo "GATE FAIL: $TSC_EXT_ERRORS TypeScript errors in extension files"
    echo "$TSC_OUTPUT" | grep "extensions/" | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
echo "GATE PASS: TS compiles"

# ─────────────────────────────────────────────────────────────────
# Build dist (needed for behavioral checks)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Building dist for behavioral inspection ==="
cd /workspace/pi-mono/$PKG_DIR
rm -rf dist 2>/dev/null
(npx -y tsgo -p tsconfig.build.json 2>&1 || npx -y tsc -p tsconfig.build.json 2>&1) > /tmp/build.log
cd /workspace/pi-mono

if [ ! -f "$RUNNER_JS" ] || [ ! -f "$WRAPPER_JS" ]; then
    echo "GATE FAIL: build did not produce runner.js / wrapper.js"
    tail -30 /tmp/build.log
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
echo "Build OK"

# ─────────────────────────────────────────────────────────────────
# F2P GATES (all weights below; sum = 1.0)
# Each must FAIL on the unmodified buggy base.
# Weights:
#   F2P-1: emitToolResult method exists at runtime         0.25
#   F2P-2: emitToolResult is callable & returns event      0.20
#   F2P-3: emit() no longer special-cases tool_result      0.20
#   F2P-4: wrapper.js calls emitToolResult                 0.20
#   F2P-5: wrapper.ts no longer routes tool_result via emit 0.15
# ─────────────────────────────────────────────────────────────────

S1=0; S2=0; S3=0; S4=0; S5=0

# ── F2P-1: emitToolResult exists on prototype at runtime ────────
echo ""
echo "=== F2P-1: emitToolResult exists on ExtensionRunner prototype ==="
HAS_METHOD=$(cd $PKG_DIR && node -e "
    try {
        const mod = require('./dist/core/extensions/runner.js');
        const Runner = mod.ExtensionRunner;
        if (Runner && typeof Runner.prototype.emitToolResult === 'function') {
            console.log('YES');
        } else {
            console.log('NO');
        }
    } catch(e) {
        console.log('NO:' + e.message);
    }
" 2>/dev/null)

if [ "$HAS_METHOD" = "YES" ]; then
    echo "PASS"
    S1=1
else
    echo "FAIL ($HAS_METHOD)"
fi

# ── F2P-2: emitToolResult is callable and returns a result ──────
echo ""
echo "=== F2P-2: emitToolResult callable & returns event-like result ==="
if [ "$S1" = "1" ]; then
    BEHAVIOR_RESULT=$(cd $PKG_DIR && node -e "
        (async () => {
          try {
            const mod = require('./dist/core/extensions/runner.js');
            const Runner = mod.ExtensionRunner;
            let runner;
            try { runner = new Runner([]); } catch(e) {
              try { runner = new Runner({extensions:[]}); } catch(e2) {
                try { runner = new Runner(); } catch(e3) { console.log('CONSTRUCT_FAIL'); return; }
              }
            }
            const evt = {
              type: 'tool_result',
              toolCallId: 'x',
              toolName: 'test',
              result: { output: 'orig' }
            };
            const res = await runner.emitToolResult(evt);
            if (res && typeof res === 'object') {
              console.log('OK');
            } else {
              console.log('BAD_RESULT:' + JSON.stringify(res));
            }
          } catch(e) {
            console.log('ERR:' + e.message);
          }
        })();
    " 2>&1)

    case "$BEHAVIOR_RESULT" in
        OK*)
            echo "PASS"
            S2=1
            ;;
        *)
            echo "FAIL ($BEHAVIOR_RESULT)"
            ;;
    esac
else
    echo "SKIP (no method)"
fi

# ── F2P-3: emit() body in dist no longer handles tool_result ────
echo ""
echo "=== F2P-3: emit() does not special-case tool_result ==="
EMIT_CLEAN=$(cd $PKG_DIR && node -e "
    const fs = require('fs');
    const src = fs.readFileSync('./dist/core/extensions/runner.js', 'utf8');
    // Find emit method body — look for 'emit(' or 'async emit(' as a method (not emitToolResult)
    // Use regex that excludes 'emitToolResult'
    const re = /(?:async\s+)?emit\s*\(\s*[a-zA-Z_]/g;
    let match;
    let bodies = [];
    while ((match = re.exec(src)) !== null) {
        // skip if this is emitToolResult
        const before = src.slice(Math.max(0, match.index - 20), match.index);
        if (/ToolResult\$/.test(before) || /emitToolResult/.test(src.slice(Math.max(0,match.index-15), match.index+5))) continue;
        // capture from here until matching close-brace at method depth
        let i = match.index;
        // find first '{' after the params
        let parenDepth = 0;
        let j = i;
        while (j < src.length) {
            if (src[j] === '(') parenDepth++;
            else if (src[j] === ')') { parenDepth--; if (parenDepth === 0) { j++; break; } }
            j++;
        }
        // skip whitespace then expect '{'
        while (j < src.length && /\s/.test(src[j])) j++;
        if (src[j] !== '{') continue;
        let braceDepth = 1; j++;
        const start = j;
        while (j < src.length && braceDepth > 0) {
            if (src[j] === '{') braceDepth++;
            else if (src[j] === '}') braceDepth--;
            j++;
        }
        bodies.push(src.slice(start, j));
    }
    if (bodies.length === 0) { console.log('NO_EMIT'); process.exit(0); }
    let dirty = false;
    for (const body of bodies) {
        if (/['\"]tool_result['\"]/.test(body)) { dirty = true; break; }
        if (/isToolResultEvent|ToolResultEventResult/.test(body)) { dirty = true; break; }
    }
    console.log(dirty ? 'DIRTY' : 'CLEAN');
" 2>/dev/null)

if [ "$EMIT_CLEAN" = "CLEAN" ]; then
    echo "PASS"
    S3=1
else
    echo "FAIL ($EMIT_CLEAN)"
fi

# ── F2P-4: wrapper.js calls emitToolResult ──────────────────────
echo ""
echo "=== F2P-4: wrapper.js calls emitToolResult ==="
WRAPPER_OK=$(cd $PKG_DIR && node -e "
    const fs = require('fs');
    const src = fs.readFileSync('./dist/core/extensions/wrapper.js', 'utf8');
    if (/\.emitToolResult\s*\(/.test(src)) console.log('YES'); else console.log('NO');
" 2>/dev/null)

if [ "$WRAPPER_OK" = "YES" ]; then
    echo "PASS"
    S4=1
else
    echo "FAIL"
fi

# ── F2P-5: wrapper.ts source no longer passes tool_result to emit() ──
echo ""
echo "=== F2P-5: wrapper.ts no longer routes tool_result through emit() ==="
WRAPPER_CLEAN=0
if [ -f "$WRAPPER_TS" ]; then
    # Find any emit( call where the immediate argument refers to a tool_result event
    # Heuristic: emit( ... 'tool_result' ... ) on same logical line, OR emit({...type:'tool_result'...})
    BAD1=$(grep -nE "\.emit\s*\(" "$WRAPPER_TS" | grep -v emitToolResult | grep -c "tool_result")
    # Multi-line: look for emit({ then within ~5 lines a 'tool_result' literal
    BAD2=0
    awk '
        /\.emit\s*\(/ && !/emitToolResult/ { in_emit=1; depth=0; buf=""; }
        in_emit { buf = buf $0 "\n"; for (i=1; i<=length($0); i++) { c=substr($0,i,1); if (c=="(") depth++; else if (c==")") { depth--; if (depth==0) { print buf; in_emit=0; break; } } } }
    ' "$WRAPPER_TS" > /tmp/emit_calls.txt 2>/dev/null
    BAD2=$(grep -c "tool_result" /tmp/emit_calls.txt 2>/dev/null || echo 0)

    if [ "$BAD1" -eq 0 ] && [ "$BAD2" -eq 0 ]; then
        WRAPPER_CLEAN=1
    fi
fi

if [ "$WRAPPER_CLEAN" = "1" ]; then
    echo "PASS"
    S5=1
else
    echo "FAIL (BAD1=$BAD1 BAD2=$BAD2)"
fi

# ─────────────────────────────────────────────────────────────────
# Compute reward
# ─────────────────────────────────────────────────────────────────
REWARD=$(awk -v a=$S1 -v b=$S2 -v c=$S3 -v d=$S4 -v e=$S5 \
    'BEGIN { printf "%.3f", a*0.25 + b*0.20 + c*0.20 + d*0.20 + e*0.15 }')

echo ""
echo "=== SCORES ==="
echo "F2P-1 (emitToolResult exists):     $S1 * 0.25"
echo "F2P-2 (emitToolResult callable):   $S2 * 0.20"
echo "F2P-3 (emit() clean):              $S3 * 0.20"
echo "F2P-4 (wrapper.js uses it):        $S4 * 0.20"
echo "F2P-5 (wrapper.ts clean):          $S5 * 0.15"
echo "TOTAL REWARD: $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt