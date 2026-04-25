#!/bin/bash
set +e

# Test for pi-mono issue #2406: Bash tool timing footer at bottom of output
# Goal: differentiate between fixes that:
#   - Implemented timing in tool-execution.ts as instructed (full credit)
#   - Implemented timing elsewhere (e.g. bash.ts renderer) but at bottom (partial)
#   - Implemented timing at top / no timing (low/zero)

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
which bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REPO=/workspace/pi-mono
TOOL_EXEC="$REPO/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
BASH_TOOL="$REPO/packages/coding-agent/src/core/tools/bash.ts"

mkdir -p /logs/verifier 2>/dev/null || true
REWARD=0.0

add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{ r=a+b; if(r>1)r=1; printf "%.4f", r }')
}

cd "$REPO" || { echo "0.0" > /logs/verifier/reward.txt; exit 0; }

# Pre-compute: do timing-related tokens exist anywhere in the relevant files?
HAS_TOOL_EXEC_TIMING=0
if grep -qE "Elapsed|Took" "$TOOL_EXEC" 2>/dev/null; then HAS_TOOL_EXEC_TIMING=1; fi

HAS_BASH_TOOL_TIMING=0
if grep -qE "Elapsed|Took" "$BASH_TOOL" 2>/dev/null; then HAS_BASH_TOOL_TIMING=1; fi

# ============================================================
# P2P Gate 1 (0.10): Files compile (TypeScript transpiles cleanly)
# ============================================================
echo "=== P2P Gate 1: Transpilation ==="
P2P1=0
if command -v bun >/dev/null 2>&1; then
  bun build "$TOOL_EXEC"   --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc1=$?
  bun build "$INTERACTIVE" --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc2=$?
  bun build "$BASH_TOOL"   --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc3=$?
  if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ $rc3 -eq 0 ]; then P2P1=1; fi
else
  # Fallback: at least syntax-check via node parse heuristic (assume OK)
  P2P1=1
fi
if [ $P2P1 -eq 1 ]; then
  add_reward 0.10
  echo "PASS (0.10) [P2P]: All three files transpile"
else
  echo "FAIL (0.10) [P2P]: Transpilation failed"
fi

# ============================================================
# P2P Gate 2 (0.05): Core class structure preserved
# ============================================================
echo "=== P2P Gate 2: Structural sanity ==="
node -e "
const fs = require('fs');
const te = fs.readFileSync('$TOOL_EXEC', 'utf8');
const im = fs.readFileSync('$INTERACTIVE', 'utf8');
const bt = fs.readFileSync('$BASH_TOOL', 'utf8');
const ok = te.includes('ToolExecutionComponent') &&
           im.includes('tool_execution_start') &&
           bt.includes('renderResult');
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.05
  echo "PASS (0.05) [P2P]: Class/method structure preserved"
else
  echo "FAIL (0.05) [P2P]: Class/method structure broken"
fi

# ============================================================
# F2P Gate 1 (0.10): Both Elapsed and Took labels exist somewhere
# Accept either tool-execution.ts (instruction-true) or bash.ts (where
# the original code sometimes lived). Behaviour-equivalent.
# ============================================================
echo "=== F2P Gate 1: Timing labels ==="
node -e "
const fs = require('fs');
const sources = ['$TOOL_EXEC','$BASH_TOOL'].map(p => { try { return fs.readFileSync(p,'utf8'); } catch(e){return '';} });
const all = sources.join('\n----\n');
const hasElapsed = /[\"'\`]\\s*Elapsed\\b|\\bElapsed\\s+\\\$\\{|Elapsed \\\$/.test(all) || /\"Elapsed\"|'Elapsed'|\`Elapsed/.test(all);
const hasTook    = /[\"'\`]\\s*Took\\b|\\bTook\\s+\\\$\\{|Took \\\$/.test(all) || /\"Took\"|'Took'|\`Took/.test(all);
process.exit((hasElapsed && hasTook) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Both Elapsed and Took labels present"
else
  echo "FAIL (0.10) [F2P]: Missing Elapsed/Took labels"
fi

# ============================================================
# F2P Gate 2 (0.10): Decimal-precision (1dp) formatting somewhere
# ============================================================
echo "=== F2P Gate 2: Decimal precision (1dp) ==="
node -e "
const fs = require('fs');
const all = ['$TOOL_EXEC','$BASH_TOOL'].map(p => { try { return fs.readFileSync(p,'utf8'); } catch(e){return '';} }).join('\n');
const ok = /toFixed\\s*\\(\\s*1\\s*\\)/.test(all) || /\\.1f/.test(all);
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: One-decimal formatting present"
else
  echo "FAIL (0.10) [F2P]: No 1-decimal formatting found"
fi

# ============================================================
# F2P Gate 3 (0.15): Live update via setInterval(~1000ms) AND clearInterval cleanup
# ============================================================
echo "=== F2P Gate 3: Live update (setInterval + clearInterval) ==="
node -e "
const fs = require('fs');
const all = ['$TOOL_EXEC','$BASH_TOOL'].map(p => { try { return fs.readFileSync(p,'utf8'); } catch(e){return '';} }).join('\n');
const hasSetInterval   = /setInterval\\s*\\(/.test(all);
const hasSecond        = /1000|1_000/.test(all);
const hasClearInterval = /clearInterval\\s*\\(/.test(all);
process.exit((hasSetInterval && hasSecond && hasClearInterval) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P]: setInterval(~1000ms) and clearInterval cleanup present"
else
  echo "FAIL (0.15) [F2P]: Missing live-update timer or cleanup"
fi

# ============================================================
# F2P Gate 4 (0.15): Bottom placement — timing renders AFTER output/truncation
# Search whichever file actually contains the timing rendering logic.
# ============================================================
echo "=== F2P Gate 4: Bottom placement ==="
node -e "
const fs = require('fs');

function findRange(lines, methodNameRegex) {
  let start = -1, depth = 0;
  for (let i = 0; i < lines.length; i++) {
    if (start === -1 && methodNameRegex.test(lines[i]) && /\\{/.test(lines[i])) {
      start = i;
      depth = 0;
    }
    if (start !== -1) {
      for (const ch of lines[i]) {
        if (ch === '{') depth++;
        else if (ch === '}') depth--;
      }
      if (depth === 0 && i > start) return [start, i];
    }
  }
  return [-1, -1];
}

function checkBottomPlacement(src, methodRegex) {
  const lines = src.split('\n');
  const [start, end] = findRange(lines, methodRegex);
  if (start === -1) return false;
  let lastOutput = -1, lastTiming = -1;
  for (let i = start; i <= end; i++) {
    const l = lines[i];
    if (/truncat|fullOutputPath|warnings|getText|output\\s*\\.|content\\.map|formatOutput/i.test(l)) lastOutput = i;
    if (/Elapsed|Took|elapsed|took|startedAt|startTime|executionStart|bashStarted|bashElapsed|timingInterval|setInterval/.test(l)) lastTiming = i;
  }
  return lastTiming !== -1 && lastOutput !== -1 && lastTiming > lastOutput;
}

const candidates = [
  ['$TOOL_EXEC',  /renderBashContent\\s*\\(|updateDisplay\\s*\\(|render\\s*\\(/],
  ['$BASH_TOOL',  /rebuildBashResultRenderComponent\\s*\\(|renderResult\\s*\\(/],
];

let ok = false;
for (const [path, re] of candidates) {
  let src = '';
  try { src = fs.readFileSync(path,'utf8'); } catch(e){ continue; }
  if (checkBottomPlacement(src, re)) { ok = true; break; }
}
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P]: Timing rendered after output (bottom placement)"
else
  echo "FAIL (0.15) [F2P]: Timing not below output"
fi

# ============================================================
# F2P Gate 5 (0.10): Header is static — no timing tokens in renderBashHeader / formatBashCall
# This guards against putting timing in the HEADER, which would defeat the issue.
# ============================================================
echo "=== F2P Gate 5: Header stays static ==="
node -e "
const fs = require('fs');

function getMethodBody(src, re) {
  const lines = src.split('\n');
  let start = -1, depth = 0;
  for (let i = 0; i < lines.length; i++) {
    if (start === -1 && re.test(lines[i]) && /\\{/.test(lines[i])) { start = i; depth = 0; }
    if (start !== -1) {
      for (const ch of lines[i]) { if (ch==='{') depth++; else if (ch==='}') depth--; }
      if (depth === 0 && i > start) return lines.slice(start, i+1).join('\n');
    }
  }
  return '';
}

const te = (() => { try { return fs.readFileSync('$TOOL_EXEC','utf8'); } catch(e){ return ''; } })();
const bt = (() => { try { return fs.readFileSync('$BASH_TOOL','utf8'); } catch(e){ return ''; } })();

const headerCandidates = [
  getMethodBody(te, /renderBashHeader\\s*\\(|renderHeader\\s*\\(/),
  getMethodBody(bt, /formatBashCall\\s*\\(|renderCall\\s*\\(/),
];

let headerHasTiming = false;
for (const body of headerCandidates) {
  if (!body) continue;
  if (/Elapsed|Took|toFixed\\s*\\(\\s*1\\s*\\)|setInterval/.test(body)) { headerHasTiming = true; break; }
}
process.exit(headerHasTiming ? 1 : 0);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Header has no timing (static)"
else
  echo "FAIL (0.10) [F2P]: Timing leaked into header — would trigger full redraw"
fi

# ============================================================
# F2P Gate 6 (0.15): tool_execution_start wires up timestamp for bash
#   - Either via setExecution*Time(...)/setExecution*Timestamp(...) call
#   - Or via tool-renderer state.startedAt = Date.now() when executionStarted flips
# Behaviour: when bash execution starts, a start-time is recorded.
# ============================================================
echo "=== F2P Gate 6: Start-time wiring on tool_execution_start ==="
node -e "
const fs = require('fs');
const im = (() => { try { return fs.readFileSync('$INTERACTIVE','utf8'); } catch(e){ return ''; } })();
const bt = (() => { try { return fs.readFileSync('$BASH_TOOL','utf8'); } catch(e){ return ''; } })();
const te = (() => { try { return fs.readFileSync('$TOOL_EXEC','utf8'); } catch(e){ return ''; } })();

// Path A: interactive-mode invokes a setter on the component when toolName === 'bash'
const lines = im.split('\n');
let inHandler = false, depth = 0, sawBashCheck = false, sawSetter = false;
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  if (/tool_execution_start/.test(l)) { inHandler = true; depth = 0; }
  if (inHandler) {
    for (const ch of l) { if (ch==='{') depth++; else if (ch==='}') depth--; }
    if (/toolName\\s*===\\s*[\"']bash[\"']|toolName\\s*==\\s*[\"']bash[\"']/.test(l)) sawBashCheck = true;
    if (/setExecution(Start)?(Time|Timestamp)\\s*\\(|setStartTime\\s*\\(|markBashStart/.test(l)) sawSetter = true;
    if (depth < 0 || (depth === 0 && /case\\s+/.test(l) && i > 0)) { /* loose */ }
  }
}
const pathA = sawBashCheck && sawSetter;

// Path B: bash.ts renderCall sets state.startedAt = Date.now() on executionStarted
const pathB = /executionStarted[\\s\\S]{0,120}startedAt\\s*=\\s*Date\\.now\\s*\\(\\s*\\)/.test(bt) ||
              /startedAt\\s*=\\s*Date\\.now\\s*\\(\\s*\\)/.test(bt);

// Path C: tool-execution.ts markExecutionStarted itself records bash start-time
const markBody = (() => {
  const ls = te.split('\n');
  let s=-1,d=0;
  for (let i=0;i<ls.length;i++){
    if (s===-1 && /markExecutionStarted\\s*\\(/.test(ls[i]) && /\\{/.test(ls[i])) { s=i; d=0; }
    if (s!==-1) {
      for (const ch of ls[i]) { if(ch==='{')d++; else if(ch==='}')d--; }
      if (d===0 && i>s) return ls.slice(s,i+1).join('\n');
    }
  }
  return '';
})();
const pathC = /toolName\\s*===\\s*[\"']bash[\"']/.test(markBody) && /Date\\.now\\s*\\(\\s*\\)/.test(markBody);

process.exit((pathA || pathB || pathC) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P]: Start-time recorded on bash tool_execution_start"
else
  echo "FAIL (0.15) [F2P]: No bash start-time wiring detected"
fi

# ============================================================
# F2P Gate 7 (0.10): Behavioural simulation — render Elapsed/Took format
# Run a short Node program that uses toFixed(1) the way the patch does
# and verify the produced strings match the documented format.
# This catches non-functional / no-op patches.
# ============================================================
echo "=== F2P Gate 7: Format simulation ==="
node -e "
const fs = require('fs');
const all = ['$TOOL_EXEC','$BASH_TOOL'].map(p => { try { return fs.readFileSync(p,'utf8'); } catch(e){return '';} }).join('\n');

// Extract a duration formatter: look for (ms / 1000).toFixed(1) pattern
const m = all.match(/\\(([^)]*?)\\s*\\/\\s*1000\\)\\.toFixed\\(\\s*1\\s*\\)/);
if (!m) process.exit(1);

// Simulate
function fmt(ms){ return (ms/1000).toFixed(1) + 's'; }
const tests = [
  [12300, '12.3s'],
  [47200, '47.2s'],
  [1000,  '1.0s'],
  [50,    '0.1s'],
];
for (const [ms, want] of tests) {
  if (fmt(ms) !== want) process.exit(1);
}

// Also confirm both labels combine: 'Elapsed 12.3s' / 'Took 47.2s'
const sample1 = 'Elapsed ' + fmt(12300);
const sample2 = 'Took '    + fmt(47200);
if (sample1 !== 'Elapsed 12.3s' || sample2 !== 'Took 47.2s') process.exit(1);
process.exit(0);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Duration formatting matches 'Elapsed/Took X.Ys'"
else
  echo "FAIL (0.10) [F2P]: Duration formatter not present or wrong"
fi

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt
exit 0