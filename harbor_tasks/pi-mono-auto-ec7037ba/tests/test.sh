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
TUI_CHANGELOG="packages/tui/CHANGELOG.md"
CA_CHANGELOG="packages/coding-agent/CHANGELOG.md"
AI_CHANGELOG="packages/ai/CHANGELOG.md"

if [ ! -f "$AUTOCOMPLETE_FILE" ] || [ ! -f "$EDITOR_FILE" ]; then
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

###############################################################################
# P2P Gate: Changelogs retain valid structure (gating only)
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

# P2P: source files still parse (very rough sanity)
node -e "
const fs=require('fs');
for (const f of ['$AUTOCOMPLETE_FILE','$EDITOR_FILE']) {
  const c=fs.readFileSync(f,'utf8');
  // Balance braces (extremely loose)
  let open=(c.match(/\{/g)||[]).length;
  let close=(c.match(/\}/g)||[]).length;
  if (Math.abs(open-close) > 3) process.exit(1);
}
" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "P2P gate failed: source files broken"
  echo "0" > /logs/verifier/reward.txt
  exit 0
fi

###############################################################################
# Setup behavioral sandbox
###############################################################################
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/sandbox/src/components"
mkdir -p "$TMPDIR/sandbox/docs"
echo "hello" > "$TMPDIR/sandbox/README.md"
echo "x" > "$TMPDIR/sandbox/src/index.ts"
echo "y" > "$TMPDIR/sandbox/src/components/button.ts"

###############################################################################
# Gate A (0.25): autocomplete.ts — uses statSync to detect directories
# when fd output lacks trailing slashes.
###############################################################################
GATE_A=0
node -e "
const fs=require('fs');
const src=fs.readFileSync('$AUTOCOMPLETE_FILE','utf8');
// Find the loop body that processes lines into results
const m = src.match(/for\s*\(\s*const\s+line\s+of\s+lines\s*\)\s*\{([\s\S]*?)\n\t\t\t\}/);
if (!m) process.exit(1);
const body = m[1];
// Must use statSync/lstatSync/isDirectory to determine directory-ness
const usesStat = /statSync|lstatSync/.test(body) && /isDirectory\(\)/.test(body);
if (!usesStat) process.exit(1);
process.exit(0);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_A=1
fi

###############################################################################
# Gate B (0.25): autocomplete.ts — emits trailing "/" for detected directories
# We simulate the fix logic against a real directory tree using fd-style
# (no-trailing-slash) inputs and verify both directories are flagged AND
# emitted with trailing slash; files are preserved without slash.
###############################################################################
GATE_B=0

cat > "$TMPDIR/sim.mjs" <<'NODESCRIPT'
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';

const srcFile = process.argv[2];
const baseDir = process.argv[3];
const src = readFileSync(srcFile, 'utf8');

const m = src.match(/for\s*\(\s*const\s+line\s+of\s+lines\s*\)\s*\{([\s\S]*?)\n\t\t\t\}/);
if (!m) { console.log(JSON.stringify({error:'no_loop'})); process.exit(0); }
const body = m[1];

const usesStat = /statSync|lstatSync/.test(body) && /isDirectory\(\)/.test(body);
// Check that the emission appends "/" for directories that don't have it
const emitsSlash = /\$\{[^}]*\}\/`/.test(body) || /\+\s*['"`]\/['"`]/.test(body);

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
    else if (isDir && hasTrailing) outPath = line;
    else outPath = line;
    results.push({ path: outPath, isDirectory: isDir });
  }
  return results;
}

const fdLines = ['README.md', 'src', 'src/index.ts', 'src/components', 'docs'];
const out = simulate(fdLines);

const srcEntry = out.find(r => r.path === 'src/' || r.path === 'src');
const docsEntry = out.find(r => r.path === 'docs/' || r.path === 'docs');
const compEntry = out.find(r => r.path === 'src/components/' || r.path === 'src/components');
const indexEntry = out.find(r => r.path === 'src/index.ts');
const readmeEntry = out.find(r => r.path === 'README.md');

let dirsFlagged = 0;
let dirsWithSlash = 0;
if (srcEntry && srcEntry.isDirectory) { dirsFlagged++; if (srcEntry.path.endsWith('/')) dirsWithSlash++; }
if (docsEntry && docsEntry.isDirectory) { dirsFlagged++; if (docsEntry.path.endsWith('/')) dirsWithSlash++; }
if (compEntry && compEntry.isDirectory) { dirsFlagged++; if (compEntry.path.endsWith('/')) dirsWithSlash++; }

let filesPreserved = 0;
if (indexEntry && !indexEntry.isDirectory && !indexEntry.path.endsWith('/')) filesPreserved++;
if (readmeEntry && !readmeEntry.isDirectory && !readmeEntry.path.endsWith('/')) filesPreserved++;

console.log(JSON.stringify({ dirsFlagged, dirsWithSlash, filesPreserved }));
NODESCRIPT

BEHAVIOR_OUT=$(cd "$TMPDIR/sandbox" && node "$TMPDIR/sim.mjs" "$REPO_DIR/$AUTOCOMPLETE_FILE" "$TMPDIR/sandbox" 2>/dev/null)
DIRS_FLAGGED=$(echo "$BEHAVIOR_OUT" | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{console.log(JSON.parse(s.trim()).dirsFlagged||0)}catch{console.log(0)}});" 2>/dev/null)
DIRS_WITH_SLASH=$(echo "$BEHAVIOR_OUT" | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{console.log(JSON.parse(s.trim()).dirsWithSlash||0)}catch{console.log(0)}});" 2>/dev/null)
FILES_PRESERVED=$(echo "$BEHAVIOR_OUT" | node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{console.log(JSON.parse(s.trim()).filesPreserved||0)}catch{console.log(0)}});" 2>/dev/null)

DIRS_FLAGGED=${DIRS_FLAGGED:-0}
DIRS_WITH_SLASH=${DIRS_WITH_SLASH:-0}
FILES_PRESERVED=${FILES_PRESERVED:-0}

if [ "$DIRS_FLAGGED" = "3" ] && [ "$DIRS_WITH_SLASH" = "3" ] && [ "$FILES_PRESERVED" = "2" ]; then
  GATE_B=1
fi

###############################################################################
# Gate C (0.20): editor.ts Tab handler — reopens autocomplete after directory
# selection (must reference forceFileAutocomplete OR updateAutocomplete OR
# keepOpen WITHIN the tab handler block, conditional on directory-ness).
###############################################################################
GATE_C=0
node -e "
const fs=require('fs');
const src=fs.readFileSync('$EDITOR_FILE','utf8');
const tabIdx = src.indexOf('tui.input.tab');
if (tabIdx < 0) process.exit(1);
// Take from tabIdx forward — find matching block end (next 'return;\n\t\t\t}')
const after = src.slice(tabIdx);
// Take a generous slice up to first 'return;' followed by closing braces, or 1500 chars
let endIdx = after.search(/return;\s*\n\s*\}\s*\n\s*\}/);
if (endIdx < 0) endIdx = 1500;
const tabBlock = after.slice(0, endIdx + 50);

// Buggy: only this.cancelAutocomplete() unconditionally followed by onChange
// Fix indicators inside tab block:
const hasReopen = /forceFileAutocomplete\s*\(|updateAutocomplete\s*\(/.test(tabBlock);
const hasKeepOpen = /keepOpen/.test(tabBlock);
const hasDirCheck = /endsWith\(\s*['\"]\/['\"]\s*\)|isDirectory/.test(tabBlock);

// Must have a directory-conditional reopen mechanism
if ((hasReopen || hasKeepOpen) && hasDirCheck) process.exit(0);
process.exit(1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_C=1
fi

###############################################################################
# Gate D (0.15): editor.ts Enter (select.confirm) handler — also handles
# directory case (reopens instead of submitting). The complete fix touches
# both Tab and Enter paths.
###############################################################################
GATE_D=0
node -e "
const fs=require('fs');
const src=fs.readFileSync('$EDITOR_FILE','utf8');
const idx = src.indexOf('tui.select.confirm');
if (idx < 0) process.exit(1);
const after = src.slice(idx);
let endIdx = after.search(/\n\s*\}\s*\n\s*\}\s*\n/);
if (endIdx < 0) endIdx = 2000;
const block = after.slice(0, endIdx + 50);

const hasReopen = /forceFileAutocomplete\s*\(|updateAutocomplete\s*\(/.test(block);
const hasKeepOpen = /keepOpen/.test(block);
const hasDirCheck = /endsWith\(\s*['\"]\/['\"]\s*\)|isDirectory/.test(block);

if ((hasReopen || hasKeepOpen) && hasDirCheck) process.exit(0);
process.exit(1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_D=1
fi

###############################################################################
# Gate E (0.10): TUI changelog has new [Unreleased] entry mentioning
# autocomplete/directory fix.
###############################################################################
GATE_E=0
node -e "
const fs=require('fs');
const c=fs.readFileSync('$TUI_CHANGELOG','utf8');
// Find [Unreleased] section content (between '## [Unreleased]' and next '## [')
const m = c.match(/## \[Unreleased\]([\s\S]*?)(?=\n## \[|\$)/);
if (!m) process.exit(1);
const sec = m[1];
// Must mention autocomplete / directory in a Fixed/Added entry
const hasEntry = /(autocomplete|directory|director)/i.test(sec) && /^[\s]*-\s+/m.test(sec);
if (hasEntry) process.exit(0);
process.exit(1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_E=1
fi

###############################################################################
# Gate F (0.05): coding-agent changelog has the duplicated entry per
# cross-package duplication rule.
###############################################################################
GATE_F=0
node -e "
const fs=require('fs');
const c=fs.readFileSync('$CA_CHANGELOG','utf8');
const m = c.match(/## \[Unreleased\]([\s\S]*?)(?=\n## \[|\$)/);
if (!m) process.exit(1);
const sec = m[1];
const hasEntry = /(autocomplete|directory|director)/i.test(sec) && /^[\s]*-\s+/m.test(sec);
if (hasEntry) process.exit(0);
process.exit(1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  GATE_F=1
fi

###############################################################################
# Compute reward
###############################################################################
REWARD=$(awk -v a=$GATE_A -v b=$GATE_B -v c=$GATE_C -v d=$GATE_D -v e=$GATE_E -v f=$GATE_F \
  'BEGIN { printf "%.3f", a*0.25 + b*0.25 + c*0.20 + d*0.15 + e*0.10 + f*0.05 }')

echo "Gate A (statSync used):       $GATE_A (0.25)"
echo "Gate B (behavioral dir/file): $GATE_B (0.25)"
echo "Gate C (Tab reopen on dir):   $GATE_C (0.20)"
echo "Gate D (Enter reopen on dir): $GATE_D (0.15)"
echo "Gate E (tui CHANGELOG entry): $GATE_E (0.10)"
echo "Gate F (ca CHANGELOG entry):  $GATE_F (0.05)"
echo "REWARD: $REWARD"

rm -rf "$TMPDIR"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0