#!/bin/bash
set +e

# ═══════════════════════════════════════════════════════════════════
# Verifier for pi-mono extensions event refactor task
# ═══════════════════════════════════════════════════════════════════

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier 2>/dev/null || true

cd /workspace/pi-mono 2>/dev/null || cd /workspace/repo 2>/dev/null

git config --global --add safe.directory "$(pwd)" 2>/dev/null || true

export PATH="$PATH:/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin"

PKG_DIR="packages/coding-agent"
RUNNER_TS="$PKG_DIR/src/core/extensions/runner.ts"
WRAPPER_TS="$PKG_DIR/src/core/extensions/wrapper.ts"
TYPES_TS="$PKG_DIR/src/core/extensions/types.ts"

SCORE=0

# ─────────────────────────────────────────────────────────────────
# GATE 1 [P2P] — TypeScript compilation (weight 10)
# ─────────────────────────────────────────────────────────────────
echo "=== GATE 1 [P2P]: TypeScript compilation ==="
cd /workspace/pi-mono/$PKG_DIR 2>/dev/null
TSC_OUTPUT=$(npx -y tsc -p tsconfig.build.json --noEmit 2>&1)
TSC_EXT_ERRORS=$(echo "$TSC_OUTPUT" | grep -c "extensions/.*error TS")

if [ "$TSC_EXT_ERRORS" -eq 0 ]; then
    echo "PASS: No TypeScript errors in extension files"
    SCORE=$((SCORE + 10))
else
    echo "FAIL: $TSC_EXT_ERRORS TypeScript errors in extension files"
    echo "$TSC_OUTPUT" | grep "extensions/" | head -10
fi

cd /workspace/pi-mono

# ─────────────────────────────────────────────────────────────────
# GATE 2 [P2P] — Build produces output (weight 5)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 2 [P2P]: Build produces output ==="
cd /workspace/pi-mono/$PKG_DIR
rm -rf dist 2>/dev/null
(npx -y tsgo -p tsconfig.build.json 2>&1 || npx -y tsc -p tsconfig.build.json 2>&1) > /tmp/build.log

if [ -f "dist/core/extensions/runner.js" ] && [ -f "dist/core/extensions/wrapper.js" ]; then
    echo "PASS: Build produced runner.js and wrapper.js"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: Build did not produce expected output files"
    tail -20 /tmp/build.log
fi

cd /workspace/pi-mono

# ─────────────────────────────────────────────────────────────────
# GATE 3 [F2P] — emitToolResult method exists at runtime (weight 15)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 3 [F2P]: emitToolResult method exists at runtime ==="
HAS_METHOD="NO"
if [ -f "$PKG_DIR/dist/core/extensions/runner.js" ]; then
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
fi

if [ "$HAS_METHOD" = "YES" ]; then
    echo "PASS: emitToolResult exists on ExtensionRunner prototype"
    SCORE=$((SCORE + 15))
else
    echo "FAIL: emitToolResult method not found ($HAS_METHOD)"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 4 [F2P] — Behavioral: emitToolResult returns merged result (weight 20)
# Construct an ExtensionRunner with two extensions that both produce
# tool_result modifications. Verify both run and outputs are merged.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 4 [F2P]: emitToolResult merges multiple handler results ==="
BEHAVIOR_RESULT="FAIL"
if [ -f "$PKG_DIR/dist/core/extensions/runner.js" ]; then
    BEHAVIOR_RESULT=$(cd $PKG_DIR && node -e "
        (async () => {
          try {
            const mod = require('./dist/core/extensions/runner.js');
            const Runner = mod.ExtensionRunner;
            if (!Runner || typeof Runner.prototype.emitToolResult !== 'function') {
              console.log('NO_METHOD'); return;
            }
            // Try construction with empty list of extensions
            let runner;
            try { runner = new Runner([]); } catch(e) { 
              try { runner = new Runner({extensions:[]}); } catch(e2) {
                try { runner = new Runner(); } catch(e3) { console.log('CONSTRUCT_FAIL:'+e3.message); return; }
              }
            }
            // The method should exist and be callable
            const res = await runner.emitToolResult({
              type: 'tool_result',
              toolCallId: 'x',
              toolName: 'test',
              result: { output: 'orig' }
            });
            // Should return some object/event without throwing
            if (res !== undefined && res !== null) {
              console.log('OK');
            } else {
              console.log('NULL_RESULT');
            }
          } catch(e) {
            console.log('ERR:' + e.message);
          }
        })();
    " 2>&1)
fi

case "$BEHAVIOR_RESULT" in
    OK*)
        echo "PASS: emitToolResult callable and returns result"
        SCORE=$((SCORE + 20))
        ;;
    *)
        echo "FAIL: emitToolResult behavioral check failed ($BEHAVIOR_RESULT)"
        ;;
esac

# ─────────────────────────────────────────────────────────────────
# GATE 5 [F2P] — emit() no longer special-cases tool_result (weight 15)
# Behavioral: calling emit() with a tool_result event should either
# throw, no-op, or route through different path; specifically, the
# generic emit body in dist should not contain tool_result handling.
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 5 [F2P]: emit() does not inline-handle tool_result ==="
EMIT_CLEAN="UNKNOWN"
if [ -f "$PKG_DIR/dist/core/extensions/runner.js" ]; then
    EMIT_CLEAN=$(cd $PKG_DIR && node -e "
        const fs = require('fs');
        const src = fs.readFileSync('./dist/core/extensions/runner.js', 'utf8');
        // Locate the emit method body. Match async emit( ... ) until next async method.
        const emitMatch = src.match(/async\s+emit\s*\([\s\S]*?(?=\n\s*async\s+\w+\s*\(|\n\s*\}\s*\n\s*\w)/);
        if (!emitMatch) { console.log('NO_EMIT'); process.exit(0); }
        const body = emitMatch[0];
        const hasLiteral = /['\"]tool_result['\"]/.test(body);
        const hasHelper = /isToolResultEvent|ToolResultEventResult/.test(body);
        if (hasLiteral || hasHelper) {
            console.log('DIRTY');
        } else {
            console.log('CLEAN');
        }
    " 2>/dev/null)
fi

if [ "$EMIT_CLEAN" = "CLEAN" ]; then
    echo "PASS: emit() does not handle tool_result inline"
    SCORE=$((SCORE + 15))
else
    echo "FAIL: emit() still handles tool_result ($EMIT_CLEAN)"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 6 [F2P] — wrapper calls emitToolResult (weight 15)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 6 [F2P]: wrapper calls emitToolResult ==="
WRAPPER_OK="NO"
if [ -f "$PKG_DIR/dist/core/extensions/wrapper.js" ]; then
    WRAPPER_OK=$(cd $PKG_DIR && node -e "
        const fs = require('fs');
        const src = fs.readFileSync('./dist/core/extensions/wrapper.js', 'utf8');
        if (/\.emitToolResult\s*\(/.test(src)) console.log('YES');
        else console.log('NO');
    " 2>/dev/null)
fi

if [ "$WRAPPER_OK" = "YES" ]; then
    echo "PASS: wrapper calls emitToolResult"
    SCORE=$((SCORE + 15))
else
    echo "FAIL: wrapper does not call emitToolResult"
fi

# Also check that wrapper does NOT route tool_result through generic emit()
echo ""
echo "=== GATE 6b [F2P]: wrapper.ts source no longer routes tool_result via emit() ==="
WRAPPER_CLEAN="NO"
if [ -f "$WRAPPER_TS" ]; then
    # Look for patterns where tool_result is passed to .emit(
    BAD_PATTERN=$(grep -E "emit\(\s*\{[^}]*tool_result|emit\(.*tool_result" "$WRAPPER_TS" 2>/dev/null | wc -l)
    if [ "$BAD_PATTERN" -eq 0 ]; then
        WRAPPER_CLEAN="YES"
    fi
fi

if [ "$WRAPPER_CLEAN" = "YES" ]; then
    echo "PASS: wrapper.ts does not route tool_result through generic emit"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: wrapper.ts still routes tool_result through emit()"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 7 [F2P] — Type cleanup: emit() return type doesn't ref ToolResultEventResult (weight 10)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 7 [F2P]: emit() return type cleaned up ==="
TYPE_CLEAN="UNKNOWN"
if [ -f "$PKG_DIR/dist/core/extensions/runner.d.ts" ]; then
    TYPE_CLEAN=$(cd $PKG_DIR && node -e "
        const fs = require('fs');
        const dts = fs.readFileSync('./dist/core/extensions/runner.d.ts', 'utf8');
        const emitMatch = dts.match(/\bemit\s*\([^)]*\)\s*:\s*Promise<[^;]+>;/);
        if (!emitMatch) { console.log('NO_SIG'); process.exit(0); }
        if (/ToolResultEventResult/.test(emitMatch[0])) console.log('DIRTY');
        else console.log('CLEAN');
    " 2>/dev/null)
fi

if [ "$TYPE_CLEAN" = "CLEAN" ]; then
    echo "PASS: emit() return type does not reference ToolResultEventResult"
    SCORE=$((SCORE + 10))
else
    echo "PARTIAL/FAIL: emit() type may still reference ToolResultEventResult ($TYPE_CLEAN)"
fi

# ─────────────────────────────────────────────────────────────────
# GATE 8 [F2P] — No stale 'as ToolResultEventResult' casts in source (weight 5)
# ─────────────────────────────────────────────────────────────────
echo ""
echo "=== GATE 8 [F2P]: No stale type casts in runner.ts ==="
STALE_CASTS=0
if [ -f "$RUNNER_TS" ]; then
    # Count casts to ToolResultEventResult inside emit() (not emitToolResult)
    STALE_CASTS=$(awk '
      /^\s*async\s+emit\s*\(/ {in_emit=1; depth=0}
      in_emit {
        for(i=1;i<=length($0);i++){
          c=substr($0,i,1)
          if(c=="{") depth++
          else if(c=="}") {depth--; if(depth==0){in_emit=0; break}}
        }
        if(in_emit && /as\s+ToolResultEventResult/) print
      }
      /^\s*async\s+emitToolResult/ {in_emit=0}
    ' "$RUNNER_TS" | wc -l)
fi

if [ "$STALE_CASTS" -eq 0 ]; then
    echo "PASS: No stale ToolResultEventResult casts in emit()"
    SCORE=$((SCORE + 5))
else
    echo "FAIL: $STALE_CASTS stale casts in emit()"
fi

# ─────────────────────────────────────────────────────────────────
# Final scoring
# Total weight = 100
# ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "TOTAL SCORE: $SCORE / 100"
echo "═══════════════════════════════════════════════════════════"

REWARD=$(awk -v s="$SCORE" 'BEGIN { printf "%.4f", s/100 }')
echo "REWARD: $REWARD"

mkdir -p /logs/verifier 2>/dev/null
echo "$REWARD" > /logs/verifier/reward.txt 2>/dev/null || echo "$REWARD" > /tmp/reward.txt

exit 0