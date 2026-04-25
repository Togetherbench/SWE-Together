#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0

REPO_DIR="/workspace/pi-mono"
TARGET_FILE="$REPO_DIR/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
CHANGELOG="$REPO_DIR/packages/coding-agent/CHANGELOG.md"
PKG_DIR="$REPO_DIR/packages/coding-agent"

git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
export PATH="$PATH:/root/.bun/bin:/usr/local/bin:/usr/bin"
if ! command -v bun >/dev/null 2>&1; then
    for d in /root/.bun/bin /home/*/.bun/bin /usr/local/bun/bin; do
        [ -x "$d/bun" ] && export PATH="$d:$PATH" && break
    done
fi

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

# ---- GATE: target file must exist ----
if [ ! -f "$TARGET_FILE" ]; then
    echo "GATE FAIL: target file missing"
    REWARD=0
    finish
fi

# ---- GATE (P2P): TypeScript still parses/transpiles cleanly ----
# This protects against destructive edits but awards no reward.
TRANSPILE_OK=0
if command -v bun >/dev/null 2>&1; then
    (cd "$PKG_DIR" && bun build src/modes/interactive/components/tool-execution.ts --no-bundle --outfile /tmp/tool-exec-check.js >/tmp/bun.out 2>&1)
    [ $? -eq 0 ] && TRANSPILE_OK=1
else
    # If bun unavailable, fall back to a node-based syntax sanity check via stripping types is unreliable.
    # Treat as pass to avoid false negatives.
    TRANSPILE_OK=1
fi
if [ "$TRANSPILE_OK" -ne 1 ]; then
    echo "GATE FAIL: target file does not transpile cleanly (regression)"
    REWARD=0
    finish
fi

# ---- Extract write & edit blocks ----
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TARGET_FILE', 'utf8');
function extractBlock(re) {
  const m = src.match(re);
  if (!m) return '';
  let i = m.index + m[0].length;
  while (i < src.length && src[i] !== '{') i++;
  if (i >= src.length) return '';
  let depth = 0, start = m.index;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) { i++; break; } }
  }
  return src.substring(start, i);
}
const writeRe = /(else\s+)?if\s*\(\s*this\.toolName\s*===\s*['\"]write['\"]/;
const editRe  = /(else\s+)?if\s*\(\s*this\.toolName\s*===\s*['\"]edit['\"]/;
fs.writeFileSync('/tmp/write_block.txt', extractBlock(writeRe));
fs.writeFileSync('/tmp/edit_block.txt',  extractBlock(editRe));
" 2>/dev/null

WRITE_BLOCK=$(cat /tmp/write_block.txt 2>/dev/null)
EDIT_BLOCK=$(cat /tmp/edit_block.txt 2>/dev/null)

if [ -z "$WRITE_BLOCK" ]; then
    echo "GATE FAIL: could not locate write block"
    REWARD=0
    finish
fi

# ============================================================
# F2P TEST A (0.35): Write block introduces error-handling branch
# On the buggy base, the write block has NO reference to isError
# and no error-rendering code. After the fix it must reference an
# error indicator AND have a conditional branch on it.
# ============================================================
TA=0
node -e "
const block = require('fs').readFileSync('/tmp/write_block.txt','utf8');
const hasErrorRef = /\bisError\b|\.error\b|errorText/.test(block);
const hasConditional = /if\s*\([^)]*(isError|\.error)\b/.test(block) || /(isError|\.error)\s*\?/.test(block);
process.exit((hasErrorRef && hasConditional) ? 0 : 1);
" 2>/dev/null
[ $? -eq 0 ] && TA=1
echo "A (error branch present in write): $TA"

# ============================================================
# F2P TEST B (0.30): Write block produces error output text
# After the fix, the error path must produce visible text content
# (assignment to text / errorText / Text. component / fg color).
# Buggy base only emits a success line; this should fail there.
# ============================================================
TB=0
node -e "
const block = require('fs').readFileSync('/tmp/write_block.txt','utf8');
// Must have at least one statement that emits error text.
const emitsError =
  /errorText\s*=/.test(block) ||
  /text\s*\+?=[^;]*(error|Error|errorText)/.test(block) ||
  /getTextOutput\s*\(/.test(block) ||
  /(error|Error)[^;\n]*\.fg\s*\(/.test(block) ||
  /Text[^;\n]*(error|Error)/.test(block);
process.exit(emitsError ? 0 : 1);
" 2>/dev/null
[ $? -eq 0 ] && TB=1
echo "B (error output emitted): $TB"

# ============================================================
# F2P TEST C (0.20): Parity with edit block's error pattern
# The edit block on base already handles errors. The fix should
# adopt at least 2 of its error-pattern tokens inside the write
# block. On no-op base, write has none of them → fails.
# ============================================================
TC=0
if [ -n "$EDIT_BLOCK" ]; then
node -e "
const w = require('fs').readFileSync('/tmp/write_block.txt','utf8');
const e = require('fs').readFileSync('/tmp/edit_block.txt','utf8');
const candidates = ['isError','getTextOutput','errorText'];
let shared = 0;
for (const c of candidates) {
  const re = new RegExp('\\\\b'+c+'\\\\b');
  if (re.test(e) && re.test(w)) shared++;
}
// Also count generic 'error' token only if both have it AND write has a conditional on it
const wHasErrCond = /if\s*\([^)]*\berror\b/i.test(w) || /\berror\b\s*\?/.test(w);
const eHasErr = /\berror\b/i.test(e);
if (wHasErrCond && eHasErr) shared++;
process.exit(shared >= 2 ? 0 : 1);
" 2>/dev/null
[ $? -eq 0 ] && TC=1
fi
echo "C (parity with edit error pattern): $TC"

# ============================================================
# F2P TEST D (0.15): CHANGELOG updated mentioning write/error fix
# Buggy base has no such entry → fails. Any reasonable wording in
# CHANGELOG that references the write tool and error/display fix.
# ============================================================
TD=0
if [ -f "$CHANGELOG" ]; then
    # Must mention "write" AND something error-related, and not be the
    # unchanged base (we approximate by requiring both tokens together
    # near each other).
    node -e "
    const fs = require('fs');
    const t = fs.readFileSync('$CHANGELOG','utf8').toLowerCase();
    // find lines mentioning write tool and error visibility
    const lines = t.split('\n');
    let ok = false;
    for (const ln of lines) {
      if (/\bwrite\b/.test(ln) && /(error|fail|swallow|display|show|surface)/.test(ln)) { ok = true; break; }
    }
    // also accept paragraph proximity
    if (!ok) {
      for (let i = 0; i < lines.length; i++) {
        if (/\bwrite\b/.test(lines[i])) {
          const window = lines.slice(Math.max(0,i-2), i+3).join(' ');
          if (/(error|fail|swallow|display|show|surface)/.test(window)) { ok = true; break; }
        }
      }
    }
    process.exit(ok ? 0 : 1);
    " 2>/dev/null
    [ $? -eq 0 ] && TD=1
fi
echo "D (CHANGELOG updated): $TD"

# ============================================================
# Aggregate F2P weights
# ============================================================
add_w() {
    local pass="$1"; local w="$2"
    if [ "$pass" -eq 1 ]; then
        REWARD=$(awk "BEGIN { printf \"%.4f\", $REWARD + $w }")
    fi
}

add_w "$TA" 0.35
add_w "$TB" 0.30
add_w "$TC" 0.20
add_w "$TD" 0.15

echo "Final reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0