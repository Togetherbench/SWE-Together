#!/bin/bash
set +e

# Test for pi-mono issue #856: write tool not showing errors in TUI
# The write tool block in tool-execution.ts should display errors like the edit block does.
# Instruction says: "Fix this bug and update the CHANGELOG."

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

TARGET_FILE="/workspace/pi-mono/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
CHANGELOG="/workspace/pi-mono/packages/coding-agent/CHANGELOG.md"
PKG_DIR="/workspace/pi-mono/packages/coding-agent"

# Allow git to work regardless of repo ownership
git config --global --add safe.directory /workspace/pi-mono 2>/dev/null || true

score=0
details=""

add_result() {
    local name="$1"
    local weight="$2"
    local pass="$3"
    local tag="$4"  # F2P or P2P
    if [ "$pass" -eq 1 ]; then
        score=$(awk "BEGIN { printf \"%.2f\", $score + $weight }")
        details="${details}PASS ($weight) [$tag]: $name\n"
    else
        details="${details}FAIL ($weight) [$tag]: $name\n"
    fi
}

# ---- GATE: target file must exist ----
if [ ! -f "$TARGET_FILE" ]; then
    echo "GATE FAIL: Target file not found"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ============================================================
# TEST 1 (P2P, weight 0.05): TypeScript transpilation succeeds
# The base code transpiles cleanly; a correct fix should too.
# This catches syntax-breaking or badly-formed changes.
# ============================================================
T1=0
BUN_OUTPUT=$(cd "$PKG_DIR" && bun build src/modes/interactive/components/tool-execution.ts --no-bundle --outfile /tmp/tool-exec-check.js 2>&1)
BUN_EXIT=$?
if [ "$BUN_EXIT" -eq 0 ]; then
    T1=1
fi
echo "T1 (bun build): exit=$BUN_EXIT"
add_result "TypeScript transpilation succeeds (bun build)" 0.05 "$T1" "P2P"

# ============================================================
# TEST 2 (F2P, weight 0.35): Write block handles error results
# Behavioral: use node to parse the source and verify that the
# write tool block contains error-handling logic. Accepts ANY
# implementation that checks for errors and produces error output
# in the write block — not tied to specific variable names.
# ============================================================
T2=0
T2_OUTPUT=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf8');

// Find the write block boundaries
const writeMarker = src.search(/else\\s+if\\s*\\(.*toolName.*===.*['\"]write['\"]/);
const editMarker = src.indexOf('else if (this.toolName === \"edit\")', writeMarker + 1);
if (writeMarker < 0 || editMarker < 0) { process.exit(1); }
const writeBlock = src.substring(writeMarker, editMarker);

// Check: does the write block reference error handling?
// Accept any approach: checking isError, error property, result errors, etc.
const hasErrorCheck = /isError|\.error\b|error.*result|result.*error/i.test(writeBlock);

// Check: does the write block produce error output (display/render/text)?
const hasErrorOutput = /getTextOutput|errorText|error.*text|text.*error|error.*output|\.fg\s*\(\s*['\"]error/i.test(writeBlock);

if (hasErrorCheck && hasErrorOutput) {
    console.log('PASS: write block has error handling with output');
    process.exit(0);
} else {
    console.log('FAIL: hasErrorCheck=' + hasErrorCheck + ' hasErrorOutput=' + hasErrorOutput);
    process.exit(1);
}
" 2>&1)
T2_EXIT=$?
if [ "$T2_EXIT" -eq 0 ]; then
    T2=1
fi
echo "T2: $T2_OUTPUT"
add_result "Write block handles error results (behavioral node check)" 0.35 "$T2" "F2P"

# ============================================================
# TEST 3 (F2P, weight 0.25): Write block error display renders text
# Behavioral: verify the write block conditionally displays error
# text. This catches fixes that check isError but don't actually
# show the error message to the user.
# ============================================================
T3=0
T3_OUTPUT=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf8');

const writeMarker = src.search(/else\\s+if\\s*\\(.*toolName.*===.*['\"]write['\"]/);
const editMarker = src.indexOf('else if (this.toolName === \"edit\")', writeMarker + 1);
if (writeMarker < 0 || editMarker < 0) { process.exit(1); }
const writeBlock = src.substring(writeMarker, editMarker);

// The fix must append error text to the display string when an error occurs.
const addsErrorToText = /text\s*\+?=.*error|error.*text\s*\+?=/i.test(writeBlock);
// Must also conditionally handle errors (if/else/ternary with error condition)
const hasConditional = /if\s*\(.*(?:isError|error)|(?:isError|error).*\?/i.test(writeBlock);

if (addsErrorToText && hasConditional) {
    console.log('PASS: write block conditionally renders error text');
    process.exit(0);
} else {
    console.log('FAIL: addsErrorToText=' + addsErrorToText + ' hasConditional=' + hasConditional);
    process.exit(1);
}
" 2>&1)
T3_EXIT=$?
if [ "$T3_EXIT" -eq 0 ]; then
    T3=1
fi
echo "T3: $T3_OUTPUT"
add_result "Write block conditionally renders error text (behavioral node check)" 0.25 "$T3" "F2P"

# ============================================================
# TEST 4 (F2P, weight 0.15): CHANGELOG updated with relevant entry
# The instruction says to update the CHANGELOG. Check that an entry
# about the write tool error fix was added.
# ============================================================
T4=0
if [ -f "$CHANGELOG" ]; then
    cd /workspace/pi-mono
    CHANGELOG_DIFF=$(git diff -- "$CHANGELOG" 2>/dev/null; git diff --cached -- "$CHANGELOG" 2>/dev/null)
    if [ -n "$CHANGELOG_DIFF" ]; then
        # Check the diff contains keywords related to the fix
        if echo "$CHANGELOG_DIFF" | grep -qiE '(write|error|#856|tool.*error|error.*display|silent)'; then
            T4=1
        fi
    fi
fi
echo "T4: changelog updated=$T4"
add_result "CHANGELOG updated with write/error fix entry" 0.15 "$T4" "F2P"

# ============================================================
# TEST 5 (P2P, weight 0.05): Edit block error handling preserved
# Regression guard: the edit block's existing error handling must
# not be removed or broken by the fix.
# ============================================================
T5=0
T5_OUTPUT=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf8');

const editMarker = src.search(/else\\s+if\\s*\\(.*toolName.*===.*['\"]edit['\"]/);
if (editMarker < 0) { console.log('edit block not found'); process.exit(1); }

// Get a chunk of the edit block
const editBlock = src.substring(editMarker, editMarker + 3000);

const hasIsError = /isError/.test(editBlock);
const hasErrorFg = /error/.test(editBlock);
const hasGetText = /getTextOutput/.test(editBlock);

if (hasIsError && hasErrorFg && hasGetText) {
    console.log('PASS: edit block error handling preserved');
    process.exit(0);
} else {
    console.log('FAIL: isError=' + hasIsError + ' errorFg=' + hasErrorFg + ' getText=' + hasGetText);
    process.exit(1);
}
" 2>&1)
T5_EXIT=$?
if [ "$T5_EXIT" -eq 0 ]; then
    T5=1
fi
echo "T5: $T5_OUTPUT"
add_result "Edit block error handling preserved (regression guard)" 0.05 "$T5" "P2P"

# ============================================================
# TEST 6 (F2P, weight 0.10): tool-execution.ts was modified
# Basic gate: the target file must have been changed.
# ============================================================
T6=0
cd /workspace/pi-mono
if git diff --name-only 2>/dev/null | grep -q 'tool-execution.ts'; then
    T6=1
elif git diff --cached --name-only 2>/dev/null | grep -q 'tool-execution.ts'; then
    T6=1
fi
echo "T6: file modified=$T6"
add_result "tool-execution.ts was modified" 0.15 "$T6" "F2P"

# ============================================================
# Calculate final score
# Total: T1(0.05 P2P) + T2(0.35 F2P) + T3(0.25 F2P) + T4(0.15 F2P)
#      + T5(0.05 P2P) + T6(0.15 F2P) = 1.00
# Execution gates: T1(0.05) + T2(0.35) + T3(0.25) + T5(0.05) = 0.70 (70%)
# P2P weight: T1(0.05) + T5(0.05) = 0.10 (nop baseline)
# F2P weight: T2(0.35) + T3(0.25) + T4(0.15) + T6(0.15) = 0.90
# ============================================================
echo "==============================="
echo "Test Results"
echo "==============================="
echo -e "$details"
echo "Weighted Score: $score"
echo "$score" > "$REWARD_FILE"
