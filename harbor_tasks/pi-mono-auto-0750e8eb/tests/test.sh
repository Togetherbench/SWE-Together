#!/bin/bash
set +e

# ============================================================
# Verifier for pi-mono isImageLine() bugfix task
# Bug: isImageLine() uses startsWith() instead of includes(),
# failing for multi-row images (cursor-up prefix before escape)
# and terminals without image support (prefix is null).
# Nop baseline score: 0.10 (only P2P gates pass)
# ============================================================

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

TOTAL_WEIGHT=0
EARNED_WEIGHT=0

add_reward() {
    local weight_x100=$1
    local pass=$2
    local label=$3
    TOTAL_WEIGHT=$((TOTAL_WEIGHT + weight_x100))
    if [ "$pass" -eq 1 ]; then
        EARNED_WEIGHT=$((EARNED_WEIGHT + weight_x100))
        echo "PASS ($weight_x100): $label"
    else
        echo "FAIL ($weight_x100): $label"
    fi
}

cd /workspace/pi-mono

# ================================================================
# Gate 1 (P2P, weight 0.05): TypeScript compilation check
# The tui package source should still be importable after changes.
# This passes on BOTH buggy and fixed code.
# ================================================================
echo "=== Gate 1: TypeScript compilation ==="
COMPILE_PASS=0
node --import tsx -e "import { isImageLine } from './packages/tui/src/terminal-image.ts'; console.log('import OK');" 2>/dev/null
if [ $? -eq 0 ]; then
    COMPILE_PASS=1
fi
add_reward 5 $COMPILE_PASS "P2P: TypeScript compilation"

# ================================================================
# Gate 2 (F2P, weight 0.35): isImageLine detects Kitty escape
# sequences that appear AFTER a cursor-up prefix (multi-row images).
# The bug: startsWith() misses sequences not at position 0.
# ================================================================
echo ""
echo "=== Gate 2: Multi-row image detection (Kitty protocol) ==="
MULTIROW_PASS=0
RESULT=$(node --import tsx -e "
import { isImageLine } from './packages/tui/src/terminal-image.ts';
// Multi-row image: cursor-up escape (\x1b[3A) comes BEFORE the Kitty sequence
const multiRowLine = '\x1b[3A\x1b_Ga=T,f=100,q=2;base64data\x1b\\\\';
// Also test a line where image seq is in middle
const middleLine = 'text before \x1b_Ga=T;data\x1b\\\\ text after';
const r1 = isImageLine(multiRowLine);
const r2 = isImageLine(middleLine);
console.log(JSON.stringify({r1, r2}));
" 2>&1) || RESULT=""
echo "Result: $RESULT"
if echo "$RESULT" | grep -q '"r1":true' && echo "$RESULT" | grep -q '"r2":true'; then
    MULTIROW_PASS=1
fi
add_reward 35 $MULTIROW_PASS "F2P: Multi-row Kitty image detection (includes vs startsWith)"

# ================================================================
# Gate 3 (F2P, weight 0.30): isImageLine detects iTerm2 escape
# sequences that appear after other content in the line.
# ================================================================
echo ""
echo "=== Gate 3: Non-prefix iTerm2 image detection ==="
ITERM_PASS=0
RESULT=$(node --import tsx -e "
import { isImageLine } from './packages/tui/src/terminal-image.ts';
// iTerm2 image with text before it
const lineWithPrefix = 'Output: \x1b]1337;File=size=100;inline=1:data==\x07';
// iTerm2 image with ANSI codes before it
const lineWithAnsi = '\x1b[31mError \x1b]1337;File=inline=1:img==\x07';
const r1 = isImageLine(lineWithPrefix);
const r2 = isImageLine(lineWithAnsi);
console.log(JSON.stringify({r1, r2}));
" 2>&1) || RESULT=""
echo "Result: $RESULT"
if echo "$RESULT" | grep -q '"r1":true' && echo "$RESULT" | grep -q '"r2":true'; then
    ITERM_PASS=1
fi
add_reward 30 $ITERM_PASS "F2P: Non-prefix iTerm2 image detection"

# ================================================================
# Gate 4 (F2P, weight 0.25): isImageLine works regardless of
# terminal capability detection. The bug: when getCapabilities()
# returns images:null, getImageEscapePrefix() returns null, and
# the function always returns false.
# ================================================================
echo ""
echo "=== Gate 4: Detection independent of terminal capabilities ==="
NOCAP_PASS=0
RESULT=$(node --import tsx -e "
// Clear env vars that would indicate image-capable terminal
delete process.env.KITTY_WINDOW_ID;
delete process.env.TERM_PROGRAM;
delete process.env.GHOSTTY_RESOURCES_DIR;
delete process.env.WEZTERM_PANE;
delete process.env.ITERM_SESSION_ID;
process.env.TERM = 'xterm';
process.env.COLORTERM = '';

import { isImageLine, resetCapabilitiesCache } from './packages/tui/src/terminal-image.ts';
if (typeof resetCapabilitiesCache === 'function') resetCapabilitiesCache();

// Even without image support, isImageLine should detect sequences
const kittyLine = '\x1b_Ga=T,f=100;data\x1b\\\\';
const itermLine = '\x1b]1337;File=inline=1:data==\x07';
const r1 = isImageLine(kittyLine);
const r2 = isImageLine(itermLine);
console.log(JSON.stringify({r1, r2}));
" 2>&1) || RESULT=""
echo "Result: $RESULT"
if echo "$RESULT" | grep -q '"r1":true' && echo "$RESULT" | grep -q '"r2":true'; then
    NOCAP_PASS=1
fi
add_reward 25 $NOCAP_PASS "F2P: Detection works without image-capable terminal"

# ================================================================
# Gate 5 (P2P, weight 0.05): Negative cases - non-image lines
# must NOT be detected as images. Guards against overly broad fix.
# This passes on BOTH buggy and fixed code.
# ================================================================
echo ""
echo "=== Gate 5: Negative cases (no false positives) ==="
NEG_PASS=0
RESULT=$(node --import tsx -e "
import { isImageLine } from './packages/tui/src/terminal-image.ts';
const plain = isImageLine('Hello world');
const ansi = isImageLine('\x1b[31mRed text\x1b[0m');
const cursor = isImageLine('\x1b[1A\x1b[2KCleared');
const empty = isImageLine('');
// All should be false
console.log(JSON.stringify({plain, ansi, cursor, empty}));
" 2>&1) || RESULT=""
echo "Result: $RESULT"
if echo "$RESULT" | grep -q '"plain":false' && echo "$RESULT" | grep -q '"ansi":false' && echo "$RESULT" | grep -q '"cursor":false' && echo "$RESULT" | grep -q '"empty":false'; then
    NEG_PASS=1
fi
add_reward 5 $NEG_PASS "P2P: No false positives on non-image lines"

# ================================================================
# Calculate final reward using integer arithmetic (avoid bc dep)
# ================================================================
echo ""
echo "=== Summary ==="
echo "Earned: $EARNED_WEIGHT / $TOTAL_WEIGHT (x100)"

if [ "$TOTAL_WEIGHT" -eq 0 ]; then
    REWARD="0.0"
else
    # Integer division with 4 decimal places
    REWARD=$(awk "BEGIN {printf \"%.4f\", $EARNED_WEIGHT / $TOTAL_WEIGHT}")
fi

echo "$REWARD" > "$REWARD_FILE"
echo "Reward: $REWARD"
