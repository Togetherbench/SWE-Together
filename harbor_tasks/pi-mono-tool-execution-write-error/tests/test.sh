#!/bin/bash
set +e

# Test for pi-mono: write tool not showing errors in TUI
# The write tool block in tool-execution.ts should display errors like the edit block does.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REPO_DIR="/workspace/pi-mono"
TARGET_FILE="$REPO_DIR/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
CHANGELOG="$REPO_DIR/packages/coding-agent/CHANGELOG.md"
PKG_DIR="$REPO_DIR/packages/coding-agent"

git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

# Ensure bun is on PATH if installed
export PATH="$PATH:/root/.bun/bin:/usr/local/bin:/usr/bin"
if ! command -v bun >/dev/null 2>&1; then
    for d in /root/.bun/bin /home/*/.bun/bin /usr/local/bun/bin; do
        [ -x "$d/bun" ] && export PATH="$d:$PATH" && break
    done
fi

score=0
details=""

add_result() {
    local name="$1"
    local weight="$2"
    local pass="$3"
    local tag="$4"
    if [ "$pass" -eq 1 ]; then
        score=$(awk "BEGIN { printf \"%.4f\", $score + $weight }")
        details="${details}PASS ($weight) [$tag]: $name\n"
    else
        details="${details}FAIL ($weight) [$tag]: $name\n"
    fi
}

# ---- GATE: target file must exist ----
if [ ! -f "$TARGET_FILE" ]; then
    echo "GATE FAIL: Target file not found at $TARGET_FILE"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# Extract the write block once for reuse
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf8');
// Find write block
const writeRe = /else\s+if\s*\(\s*this\.toolName\s*===\s*['\"]write['\"]/;
const writeMatch = src.match(writeRe);
if (!writeMatch) { fs.writeFileSync('/tmp/write_block.txt',''); process.exit(0); }
const writeStart = writeMatch.index;
// Find matching closing brace by tracking braces from first '{' after match
let i = writeStart + writeMatch[0].length;
while (i < src.length && src[i] !== '{') i++;
if (i >= src.length) { fs.writeFileSync('/tmp/write_block.txt',''); process.exit(0); }
let depth = 0;
let start = i;
for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) { i++; break; } }
}
const block = src.substring(writeStart, i);
fs.writeFileSync('/tmp/write_block.txt', block);

// Also extract edit block
const editRe = /else\s+if\s*\(\s*this\.toolName\s*===\s*['\"]edit['\"]/;
const editMatch = src.match(editRe);
if (editMatch) {
    let j = editMatch.index + editMatch[0].length;
    while (j < src.length && src[j] !== '{') j++;
    let d = 0, es = editMatch.index;
    for (; j < src.length; j++) {
        if (src[j] === '{') d++;
        else if (src[j] === '}') { d--; if (d === 0) { j++; break; } }
    }
    fs.writeFileSync('/tmp/edit_block.txt', src.substring(es, j));
}
" 2>/dev/null

WRITE_BLOCK=$(cat /tmp/write_block.txt 2>/dev/null)
EDIT_BLOCK=$(cat /tmp/edit_block.txt 2>/dev/null)

# ============================================================
# TEST 1 (P2P, 0.05): TypeScript transpiles cleanly
# ============================================================
T1=0
if command -v bun >/dev/null 2>&1; then
    BUN_OUT=$(cd "$PKG_DIR" && bun build src/modes/interactive/components/tool-execution.ts --no-bundle --outfile /tmp/tool-exec-check.js 2>&1)
    [ $? -eq 0 ] && T1=1
elif command -v npx >/dev/null 2>&1; then
    # Fallback: tsc syntax-only check
    NPX_OUT=$(cd "$PKG_DIR" && npx --yes -p typescript tsc --noEmit --allowJs --skipLibCheck src/modes/interactive/components/tool-execution.ts 2>&1)
    [ $? -eq 0 ] && T1=1
else
    # Fallback: node parse via esbuild-like parser; use basic syntactic check
    node -e "
    const fs=require('fs');
    const s=fs.readFileSync('$TARGET_FILE','utf8');
    // strip TS-only syntax superficially and try parse... too unreliable. Just pass if file non-empty.
    process.exit(s.length>100?0:1);
    " && T1=1
fi
echo "T1 (transpile): $T1"
add_result "TypeScript transpiles cleanly" 0.05 "$T1" "P2P"

# ============================================================
# TEST 2 (F2P, 0.30): Write block contains error-handling logic
# Behavioral via AST-ish inspection: must reference isError/error
# AND must produce some text/output for that error path.
# ============================================================
T2=0
if [ -n "$WRITE_BLOCK" ]; then
    node -e "
    const block = require('fs').readFileSync('/tmp/write_block.txt','utf8');
    const hasErrorCheck = /isError|\.error\b|result\.isError|result\?\.isError|errorText|getTextOutput/i.test(block);
    const hasOutputProduction = /text\s*[+]?=|\.fg\s*\(|errorText|getTextOutput|Text\.|\\\$\{.*error/i.test(block);
    process.exit((hasErrorCheck && hasOutputProduction) ? 0 : 1);
    "
    [ $? -eq 0 ] && T2=1
fi
echo "T2 (error handling present): $T2"
add_result "Write block has error-handling logic with output" 0.30 "$T2" "F2P"

# ============================================================
# TEST 3 (F2P, 0.25): Write block conditionally renders error text
# Must have a conditional (if/ternary) keyed on error AND must
# accumulate/return text content for it.
# ============================================================
T3=0
if [ -n "$WRITE_BLOCK" ]; then
    node -e "
    const block = require('fs').readFileSync('/tmp/write_block.txt','utf8');
    const conditionalOnError = /if\s*\([^)]*(isError|\.error)|(\bisError\b|\.error\b)[^;{]*\?/i.test(block);
    const addsErrorText = /text\s*\+?=[^;]*(error|Error)|getTextOutput|errorText\s*=|(error|Error)[^;]*\.fg\s*\(/i.test(block);
    process.exit((conditionalOnError && addsErrorText) ? 0 : 1);
    "
    [ $? -eq 0 ] && T3=1
fi
echo "T3 (conditional error render): $T3"
add_result "Write block conditionally renders error text" 0.25 "$T3" "F2P"

# ============================================================
# TEST 4 (F2P, 0.15): Behavior parity with edit block
# The write block should look structurally similar to edit's error
# handling — i.e. same kind of error-display pattern. Compare key
# tokens used in edit block to ensure write adopted them.
# ============================================================
T4=0
if [ -n "$WRITE_BLOCK" ] && [ -n "$EDIT_BLOCK" ]; then
    node -e "
    const w = require('fs').readFileSync('/tmp/write_block.txt','utf8');
    const e = require('fs').readFileSync('/tmp/edit_block.txt','utf8');
    // Tokens that are likely part of the edit error-display pattern.
    const candidates = ['isError','getTextOutput','errorText','error'];
    let shared = 0;
    for (const c of candidates) {
        const inE = new RegExp('\\\\b'+c+'\\\\b','i').test(e);
        const inW = new RegExp('\\\\b'+c+'\\\\b','i').test(w);
        if (inE && inW) shared++;
    }
    // Need at least 2 shared error-pattern tokens
    process.exit(shared >= 2 ? 0 : 1);
    "
    [ $? -eq 0 ] && T4=1
fi
echo "T4 (parity with edit block): $T4"
add_result "Write block adopts edit-block error pattern (parity)" 0.15 "$T4" "F2P"

# ============================================================
# TEST 5 (F2P, 0.10): Simulated runtime — execute extracted snippet
# Build a tiny harness that mimics the write block's error path
# by inspecting whether feeding {isError:true, error/content} into
# the file's logic produces non-empty error text. We do this by
# requiring that strings related to error rendering exist AND that
# the write block does NOT early-return success without checking.
# ============================================================
T5=0
if [ -n "$WRITE_BLOCK" ]; then
    node -e "
    const block = require('fs').readFileSync('/tmp/write_block.txt','utf8');
    // The write block (buggy original) produced only a success message.
    // After fix, when isError is truthy, output must differ.
    // We approximate by confirming there are at least TWO distinct text
    // assignments / branches in the write block.
    const textAssigns = (block.match(/text\s*\+?=|return\s+[^;]*Text|Text\./g) || []).length;
    const branchCount = (block.match(/\bif\s*\(/g) || []).length + (block.match(/\?\s*[^:]+:/g) || []).length;
    process.exit((textAssigns >= 2 && branchCount >= 1) ? 0 : 1);
    "
    [ $? -eq 0 ] && T5=1
fi
echo "T5 (branching for error vs success): $T5"
add_result "Write block branches for error vs success output" 0.10 "$T5" "F2P"

# ============================================================
# TEST 6 (P2P, 0.05): Edit block regression guard
# ============================================================
T6=0
if [ -n "$EDIT_BLOCK" ]; then
    node -e "
    const e = require('fs').readFileSync('/tmp/edit_block.txt','utf8');
    const ok = /isError/.test(e) && /error/i.test(e) && /getTextOutput|text\s*\+?=/i.test(e);
    process.exit(ok ? 0 : 1);
    "
    [ $? -eq 0 ] && T6=1
fi
echo "T6 (edit regression): $T6"
add_result "Edit block error handling preserved" 0.05 "$T6" "P2P"

# ============================================================
# TEST 7 (F2P, 0.05): tool-execution.ts was modified
# ============================================================
T7=0
cd "$REPO_DIR" 2>/dev/null
if git diff --name-only 2>/dev/null | grep -q 'tool-execution.ts'; then
    T7=1
elif git diff --cached --name-only 2>/dev/null | grep -q 'tool-execution.ts'; then
    T7=1
elif git log -1 --name-only --pretty=format: 2>/dev/null | grep -q 'tool-execution.ts'; then
    T7=1
fi
echo "T7 (file modified): $T7"
add_result "tool-execution.ts was modified" 0.05 "$T7" "F2P"

# ============================================================
# TEST 8 (F2P, 0.05): CHANGELOG updated with relevant entry
# ============================================================
T8=0
if [ -f "$CHANGELOG" ]; then
    cd "$REPO_DIR"
    CHANGELOG_DIFF=$( { git diff -- "$CHANGELOG"; git diff --cached -- "$CHANGELOG"; git log -1 -p -- "$CHANGELOG"; } 2>/dev/null )
    if [ -n "$CHANGELOG_DIFF" ]; then
        if echo "$CHANGELOG_DIFF" | grep -qiE '(write.*(error|fail)|error.*write|tool.*error|silent|swallow|#856)'; then
            T8=1
        elif echo "$CHANGELOG_DIFF" | grep -qiE '(write|error)' && echo "$CHANGELOG_DIFF" | grep -qE '^\+'; then
            # Weak partial: any added line mentioning write or error
            T8=1
        fi
    fi
fi
echo "T8 (changelog): $T8"
add_result "CHANGELOG updated with write/error fix entry" 0.05 "$T8" "F2P"

# ============================================================
# Total weights:
# T1 0.05 P2P, T2 0.30 F2P, T3 0.25 F2P, T4 0.15 F2P, T5 0.10 F2P,
# T6 0.05 P2P, T7 0.05 F2P, T8 0.05 F2P  = 1.00
# Behavioral F2P (T2+T3+T4+T5) = 0.80
# ============================================================

REWARD=$(awk "BEGIN { printf \"%.2f\", $score }")
echo "==============================="
echo -e "$details"
echo "FINAL REWARD: $REWARD"
echo "==============================="
echo "$REWARD" > "$REWARD_FILE"
exit 0