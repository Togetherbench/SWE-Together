#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD="0.0"
echo "$REWARD" > "$REWARD_FILE"

cd /workspace/pi-mono 2>/dev/null || {
    echo "FATAL: /workspace/pi-mono missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
}

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
command -v node >/dev/null 2>&1 || { echo "FATAL: node missing"; echo "0.0" > "$REWARD_FILE"; exit 0; }

TUI_DIR="packages/tui"
TI_FILE="$TUI_DIR/src/terminal-image.ts"
TUI_FILE="$TUI_DIR/src/tui.ts"
MD_FILE="$TUI_DIR/src/components/markdown.ts"
BOX_FILE="$TUI_DIR/src/components/box.ts"

# Required source files must exist
for f in "$TI_FILE" "$TUI_FILE" "$MD_FILE" "$BOX_FILE"; do
    [ -f "$f" ] || { echo "FATAL: $f missing"; echo "0.0" > "$REWARD_FILE"; exit 0; }
done

# ============================================================
# P2P GATE (gating only, no reward): No unresolved merge conflict
# markers. If present, the patch is broken — exit with 0.0.
# ============================================================
for f in "$TI_FILE" "$TUI_FILE" "$MD_FILE" "$BOX_FILE"; do
    if grep -qE '^(<<<<<<< |>>>>>>> |=======$)' "$f"; then
        echo "GATE FAIL: unresolved merge conflict markers in $f"
        echo "0.0" > "$REWARD_FILE"
        exit 0
    fi
done

# ============================================================
# P2P GATE (gating only): tui.ts file must be syntactically loadable
# via tsx. If broken, exit with 0.0. (This passes on base too.)
# ============================================================
node --import tsx -e "import('./$TUI_FILE').then(()=>{console.log('OK')}).catch(e=>{console.error(e.message);process.exit(1)})" >/tmp/parse.out 2>&1
if [ $? -ne 0 ] || ! grep -q OK /tmp/parse.out; then
    echo "GATE FAIL: tui.ts does not parse/import"
    cat /tmp/parse.out | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ============================================================
# F2P scoring — all weight comes from behavioral changes that
# fail on the unmodified buggy base and pass on the correct revert.
# Total weight = 1.00
# ============================================================
TOTAL=0
EARNED=0

add() {
    local w=$1
    local pass=$2  # 0 or 1
    local label=$3
    TOTAL=$((TOTAL + w))
    if [ "$pass" = "1" ]; then
        EARNED=$((EARNED + w))
        echo "  [+$w] $label"
    else
        echo "  [ 0/$w] $label"
    fi
}

# ------------------------------------------------------------
# F2P #1 (weight 25): Buggy export `isImageLine` from
# terminal-image.ts must be REMOVED. On buggy base it exists,
# on correct revert it does not.
# ------------------------------------------------------------
echo ""
echo "=== F2P 1: isImageLine export removed from terminal-image.ts ==="
RES1=$(node --import tsx -e "
import('./$TI_FILE').then((m) => {
    console.log(JSON.stringify({has: typeof m.isImageLine === 'function'}));
}).catch(e => { console.log(JSON.stringify({err: String(e && e.message || e)})); });
" 2>&1)
echo "  $RES1"
P1=0
if echo "$RES1" | grep -q '"has":false'; then
    P1=1
fi
add 25 $P1 "isImageLine no longer exported"

# ------------------------------------------------------------
# F2P #2 (weight 15): tui.ts must NOT import isImageLine from
# terminal-image. On base it does; on revert it doesn't.
# ------------------------------------------------------------
echo ""
echo "=== F2P 2: tui.ts does not import isImageLine ==="
P2=0
if ! grep -qE 'import\s*\{[^}]*\bisImageLine\b[^}]*\}\s*from\s*["'\''][^"'\'']*terminal-image' "$TUI_FILE"; then
    P2=1
fi
add 15 $P2 "tui.ts no longer imports isImageLine"

# ------------------------------------------------------------
# F2P #3 (weight 15): markdown.ts must NOT import isImageLine.
# On base it does; on revert it doesn't.
# ------------------------------------------------------------
echo ""
echo "=== F2P 3: markdown.ts does not import isImageLine ==="
P3=0
if ! grep -qE 'import\s*\{[^}]*\bisImageLine\b[^}]*\}\s*from\s*["'\''][^"'\'']*terminal-image' "$MD_FILE"; then
    P3=1
fi
add 15 $P3 "markdown.ts no longer imports isImageLine"

# ------------------------------------------------------------
# F2P #4 (weight 25): tui.ts has an inline image-detection check
# using includes() against BOTH kitty (\x1b_G) and iTerm2
# (\x1b]1337;File=) sequences. This is the behavioral signature
# of the correct revert. On base, tui.ts uses isImageLine() and
# does not contain these literals + includes() pattern.
# ------------------------------------------------------------
echo ""
echo "=== F2P 4: tui.ts has inline includes()-based image detection ==="
P4=0
# Use python or node to do a precise regex on the file content,
# since bash regex with \x1b literals across both prefixes is fragile.
DETECT=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TUI_FILE', 'utf8');
// Look for includes('\x1b_G') and includes('\x1b]1337;File=')
const reKitty = /includes\s*\(\s*[\"'\`](?:\\\\x1b|\\\\u001b|\u001b)_G[\"'\`]\s*\)/;
const reIterm = /includes\s*\(\s*[\"'\`](?:\\\\x1b|\\\\u001b|\u001b)\]1337;File=[\"'\`]\s*\)/;
const k = reKitty.test(src);
const i = reIterm.test(src);
console.log(JSON.stringify({kitty:k, iterm:i}));
" 2>&1)
echo "  $DETECT"
if echo "$DETECT" | grep -q '"kitty":true' && echo "$DETECT" | grep -q '"iterm":true'; then
    P4=1
fi
add 25 $P4 "tui.ts contains inline includes()-based detection for both protocols"

# ------------------------------------------------------------
# F2P #5 (weight 20): Behavioral test — extract and exercise
# tui.ts's image-detection logic on inputs the buggy version
# would mishandle. The buggy isImageLine in terminal-image.ts
# (a) returns false when getImageEscapePrefix() is null and
# (b) used startsWith for the "fast path" but the issue from
# PR #1091 is that detection was tied to terminal capability.
#
# We construct a behavioral check: simulate a no-capability
# environment and verify that the correct fix's detection
# function still returns true for image-bearing lines (it
# is a pure string check), while the buggy version (which
# called getImageEscapePrefix() and returned false when null)
# would not.
#
# Strategy: read the file source and look for a pattern where
# detection is purely string-based (no call to
# getImageEscapePrefix / getCapabilities inside the detection
# path). On base, isImageLine in terminal-image.ts uses
# capability gating. On revert, tui.ts has containsImage that
# is a pure string check.
# ------------------------------------------------------------
echo ""
echo "=== F2P 5: detection path is pure string-based (not capability-gated) ==="
P5=0
PURITY=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TUI_FILE', 'utf8');
// Find any method/function whose body contains both prefix literals
// (\x1b_G and \x1b]1337;File=) and uses includes(). Then check that
// the same method body does NOT call getImageEscapePrefix or
// getCapabilities (which would gate on terminal support).
const lines = src.split('\n');
// crude bracket scan: find lines containing 'x1b_G' (kitty literal)
let found = false;
let pure = false;
// Look for an arrow / function block containing the kitty literal
// and capture a window of lines around it.
for (let i = 0; i < lines.length; i++) {
    if (lines[i].indexOf('\\\\x1b_G') !== -1 || lines[i].indexOf('\u001b_G') !== -1) {
        found = true;
        // window: 5 lines before to 5 lines after
        const start = Math.max(0, i - 8);
        const end = Math.min(lines.length, i + 8);
        const window = lines.slice(start, end).join('\n');
        const hasIterm = window.indexOf('1337;File=') !== -1;
        const hasIncludes = /\.includes\s*\(/.test(window);
        const callsCap = /getImageEscapePrefix\s*\(|getCapabilities\s*\(/.test(window);
        if (hasIterm && hasIncludes && !callsCap) {
            pure = true;
            break;
        }
    }
}
console.log(JSON.stringify({found, pure}));
" 2>&1)
echo "  $PURITY"
if echo "$PURITY" | grep -q '"pure":true'; then
    P5=1
fi
add 20 $P5 "Detection is pure string check (no capability gating)"

# ============================================================
# Compute final reward
# ============================================================
echo ""
echo "=== Summary: $EARNED / $TOTAL ==="
if [ "$TOTAL" -gt 0 ]; then
    REWARD=$(awk -v e="$EARNED" -v t="$TOTAL" 'BEGIN{printf "%.3f", e/t}')
else
    REWARD="0.0"
fi
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0