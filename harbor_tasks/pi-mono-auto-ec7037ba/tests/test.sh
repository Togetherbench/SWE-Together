#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD=0

# Find repo
REPO_DIR=""
for d in /workspace/pi-mono /workspace/repo /workspace; do
  if [ -f "$d/packages/tui/src/autocomplete.ts" ]; then
    REPO_DIR="$d"
    break
  fi
done

if [ -z "$REPO_DIR" ]; then
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

cd "$REPO_DIR"
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

AUTOCOMPLETE_FILE="packages/tui/src/autocomplete.ts"
EDITOR_FILE="packages/tui/src/components/editor.ts"

if [ ! -f "$AUTOCOMPLETE_FILE" ] || [ ! -f "$EDITOR_FILE" ]; then
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

###############################################################################
# P2P Gate: Changelog files retain valid structure (gating only, no reward)
###############################################################################
node -e "
const fs = require('fs');
const files = [
  'packages/ai/CHANGELOG.md',
  'packages/tui/CHANGELOG.md',
  'packages/coding-agent/CHANGELOG.md'
];
let ok = 0;
for (const f of files) {
  try {
    const c = fs.readFileSync(f, 'utf8');
    if (/^# Changelog/m.test(c) && /## \[/.test(c)) ok++;
  } catch(e) {}
}
process.exit(ok === 3 ? 0 : 1);
" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "P2P gate failed: changelogs structurally broken"
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

###############################################################################
# F2P Gate A (0.50): Behavioral fix in autocomplete.ts
# The buggy code marks isDirectory based purely on `endsWith("/")`. fd output
# (no trailing slashes) makes directories misclassified as files.
# Fix: use statSync (or fs.statSync / lstatSync / isDirectory()) to detect
# directories, and emit path with trailing "/".
#
# We test this by simulating the loop body's behavior on a real directory tree.
# This MUST fail on the unmodified base (which only checks endsWith("/")).
###############################################################################

TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/sandbox/src/components"
mkdir -p "$TMPDIR/sandbox/docs"
echo "hello" > "$TMPDIR/sandbox/README.md"
echo "x" > "$TMPDIR/sandbox/src/index.ts"
echo "y" > "$TMPDIR/sandbox/src/components/button.ts"

cat > "$TMPDIR/test.mjs" <<'NODESCRIPT'
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';

const srcFile = process.argv[2];
const baseDir = process.argv[3];
const src = readFileSync(srcFile, 'utf8');

// Find the loop block body that processes lines into results with hasTrailingSeparator
const m = src.match(/for\s*\(\s*const\s+line\s+of\s+lines\s*\)\s*\{([\s\S]*?)\n\t\t\t\}/);
if (!m) { console.log(JSON.stringify({dirsDetected:0, filesPreserved:0})); process.exit(0); }
const body = m[1];

const usesStat = /statSync|lstatSync|isDirectory\(\)/.test(body);
// Detect emission of trailing slash for non-pre-slashed dirs
const emitsSlash = /\$\{[^}]*\}\/`/.test(body) || /\+\s*['"`]\/['"`]/.test(body) || /isDirectory\s*[\?&|]/.test(body);

function simulate(lines) {
  const results = [];
  for (const line of lines) {
    const hasTrailing = line.endsWith('/');
    const norm = hasTrailing ? line.slice(0, -1) : line;
    let isDir = hasTrailing;
    if (!isDir && usesStat) {
      try { isDir = statSync(join(baseDir, norm)).isDirectory(); } catch {}
    }
    let outPath;
    if (isDir && !hasTrailing && emitsSlash) outPath = norm + '/';
    else outPath = line;
    results.push({ path: outPath, isDirectory: isDir });
  }
  return results;
}

const fdLines = ['README.md', 'src', 'src/index.ts', 'src/components', 'docs'];
const out = simulate(fdLines);

const srcEntry = out.find(r => r.path === 'src/' || r.path === 'src');
const docsEntry = out.find(r => r.path === 'docs/' || r.path === 'docs');
const indexEntry = out.find(r => r.path === 'src/index.ts');

let dirsDetected = 0;
if (srcEntry && srcEntry.isDirectory && srcEntry.path.endsWith('/')) dirsDetected++;
if (docsEntry && docsEntry.isDirectory && docsEntry.path.endsWith('/')) dirsDetected++;

let filesPreserved = 0;
if (indexEntry && !indexEntry.isDirectory && !indexEntry.path.endsWith('/')) filesPreserved++;

console.log(JSON.stringify({ dirsDetected, filesPreserved }));
NODESCRIPT

BEHAVIOR_OUT=$(cd "$TMPDIR/sandbox" && node "$TMPDIR/test.mjs" "$REPO_DIR/$AUTOCOMPLETE_FILE" "$TMPDIR/sandbox" 2>/dev/null)

DIRS_DETECTED=$(echo "$BEHAVIOR_OUT" | node -e "
let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{
  try { const o=JSON.parse(s.trim()); console.log(o.dirsDetected||0); } catch { console.log(0); }
});" 2>/dev/null)
FILES_PRESERVED=$(echo "$BEHAVIOR_OUT" | node -e "
let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{
  try { const o=JSON.parse(s.trim()); console.log(o.filesPreserved||0); } catch { console.log(0); }
});" 2>/dev/null)

DIRS_DETECTED=${DIRS_DETECTED:-0}
FILES_PRESERVED=${FILES_PRESERVED:-0}

GATE_A=0
# Both conditions must hold: directories detected with trailing slash AND files preserved
if [ "$DIRS_DETECTED" = "2" ] && [ "$FILES_PRESERVED" = "1" ]; then
  GATE_A=1
fi

rm -rf "$TMPDIR"

###############################################################################
# F2P Gate B (0.35): Behavioral fix in editor.ts — Tab handler re-triggers
# autocomplete when a directory is selected (rather than always cancelling).
#
# The buggy base unconditionally calls cancelAutocomplete() in the Tab branch.
# Fix variants: keepOpen flag, conditional cancel, forceFileAutocomplete after,
# updateAutocomplete after.
#
# We detect this structurally by extracting the tab handler block and checking
# that it no longer unconditionally cancels — it must either:
#   (a) reference label.endsWith("/") or selected.label/.path containing "/"
#   (b) reference keepOpen / result.keepOpen
#   (c) call updateAutocomplete or forceFileAutocomplete inside the tab block
#
# This MUST fail on the buggy base where the Tab branch is purely
# `this.cancelAutocomplete(); if (this.onChange) ...`
###############################################################################

GATE_B=0
node -e "
const fs = require('fs');
const src = fs.readFileSync('$EDITOR_FILE', 'utf8');

// Locate the tab handler region — find 'tui.input.tab' and then the matching block
const tabIdx = src.indexOf('tui.input.tab');
if (tabIdx < 0) process.exit(1);

// Take a window covering the tab branch
const window = src.slice(tabIdx, tabIdx + 2500);

// Look for end of this if-block by finding the next 'return;' followed by '}' twice
// Just take a generous slice
const tabBlock = window.slice(0, 2500);

// Buggy base: tab block calls cancelAutocomplete unconditionally and does NOT
// reference keepOpen, updateAutocomplete, forceFileAutocomplete, or label.endsWith('/').
// Fix indicator: at least one of these markers exists in the tab block.
const hasKeepOpen = /keepOpen/.test(tabBlock);
const hasReopen = /updateAutocomplete\s*\(|forceFileAutocomplete\s*\(/.test(tabBlock);
const hasDirCheck = /label\.endsWith\(['\"]\/[\'\"]\)|\.path\.endsWith\(['\"]\/[\'\"]\)|isDirectory/.test(tabBlock);

if (hasKeepOpen || (hasReopen && hasDirCheck) || (hasReopen)) {
  // Additionally require that the cancel is no longer truly unconditional:
  // either it's gated by an else/if, or there's a reopen call.
  if (hasReopen || hasKeepOpen) process.exit(0);
}
process.exit(1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_B=1
fi

###############################################################################
# F2P Gate C (0.10): tui CHANGELOG documents the autocomplete fix
# Must mention autocomplete + directory under tui/CHANGELOG.md, and must not
# match the unmodified base (which has no such entry).
###############################################################################

GATE_C=0
if [ -f "packages/tui/CHANGELOG.md" ]; then
  # Check that the changelog mentions the autocomplete directory fix
  if grep -iE "autocomplete.*director|director.*autocomplete|@.*(file|path).*autocomplete" packages/tui/CHANGELOG.md >/dev/null 2>&1; then
    GATE_C=1
  fi
fi

###############################################################################
# F2P Gate D (0.05): coding-agent CHANGELOG cross-package duplication
###############################################################################

GATE_D=0
if [ -f "packages/coding-agent/CHANGELOG.md" ]; then
  if grep -iE "autocomplete.*director|director.*autocomplete|@.*(file|path).*autocomplete" packages/coding-agent/CHANGELOG.md >/dev/null 2>&1; then
    GATE_D=1
  fi
fi

###############################################################################
# Compute reward
###############################################################################

REWARD=$(awk -v a="$GATE_A" -v b="$GATE_B" -v c="$GATE_C" -v d="$GATE_D" \
  'BEGIN { printf "%.3f", a*0.50 + b*0.35 + c*0.10 + d*0.05 }')

echo "GATE_A (autocomplete behavior): $GATE_A (weight 0.50)"
echo "GATE_B (editor.ts re-trigger):  $GATE_B (weight 0.35)"
echo "GATE_C (tui changelog):         $GATE_C (weight 0.10)"
echo "GATE_D (coding-agent changelog): $GATE_D (weight 0.05)"
echo "REWARD: $REWARD"

echo "$REWARD" > /logs/verifier/reward.txt