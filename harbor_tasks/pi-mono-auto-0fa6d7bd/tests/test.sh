#!/bin/bash
set +e

# Verifier for pi-mono issue #2406: Bash tool timing footer at bottom of output
# Core principle: no-op patch MUST score 0.0. All reward from behavioral changes.

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REPO=/workspace/pi-mono
TOOL_EXEC="$REPO/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
BASH_TOOL="$REPO/packages/coding-agent/src/core/tools/bash.ts"

mkdir -p /logs/verifier 2>/dev/null || true
REWARD=0.0
finalize() { echo "$REWARD" > /logs/verifier/reward.txt; exit 0; }

add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{ r=a+b; if(r>1)r=1; printf "%.4f", r }')
}

cd "$REPO" || finalize

# ============================================================
# Snapshot the baseline (un-modified) versions of these files via git
# so we can compute deltas relative to base.
# ============================================================
BASE_DIR=$(mktemp -d)
get_base() {
  local rel="${1#$REPO/}"
  local out="$2"
  (cd "$REPO" && git show HEAD:"$rel" > "$out" 2>/dev/null)
  if [ ! -s "$out" ]; then
    # Try origin/HEAD or similar; fallback empty
    (cd "$REPO" && git show "$(git rev-list --max-parents=0 HEAD | head -1)":"$rel" > "$out" 2>/dev/null)
  fi
}
get_base "$TOOL_EXEC"   "$BASE_DIR/tool-execution.ts.base"
get_base "$INTERACTIVE" "$BASE_DIR/interactive-mode.ts.base"
get_base "$BASH_TOOL"   "$BASE_DIR/bash.ts.base"

# Detect whether the working tree differs from base for the relevant files.
ANY_CHANGE=0
for f in "$TOOL_EXEC" "$INTERACTIVE" "$BASH_TOOL"; do
  rel="${f#$REPO/}"
  if ! (cd "$REPO" && git diff --quiet HEAD -- "$rel" 2>/dev/null); then
    ANY_CHANGE=1
  fi
done

if [ "$ANY_CHANGE" -eq 0 ]; then
  echo "No-op patch detected: no changes to relevant files."
  finalize
fi

# ============================================================
# P2P GATE (gating only, no reward): Files transpile.
# If the agent broke transpilation, exit with 0.
# ============================================================
echo "=== P2P Gate: Transpilation (gating) ==="
if command -v bun >/dev/null 2>&1; then
  bun build "$TOOL_EXEC"   --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc1=$?
  bun build "$INTERACTIVE" --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc2=$?
  bun build "$BASH_TOOL"   --no-bundle --outdir /tmp/tsc-check >/dev/null 2>&1; rc3=$?
  if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ] || [ $rc3 -ne 0 ]; then
    echo "GATE FAIL: Transpilation broken; reward=0"
    REWARD=0.0
    finalize
  fi
  echo "GATE PASS: transpiles"
else
  echo "GATE SKIP: bun not available (assuming OK)"
fi

# ============================================================
# P2P GATE: Core structure preserved (gating only)
# ============================================================
echo "=== P2P Gate: Structural sanity (gating) ==="
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
if [ $? -ne 0 ]; then
  echo "GATE FAIL: structure broken; reward=0"
  REWARD=0.0
  finalize
fi
echo "GATE PASS: structure preserved"

# ============================================================
# Helper: read all three working-tree files concatenated
# ============================================================
read_all() {
  cat "$TOOL_EXEC" "$BASH_TOOL" "$INTERACTIVE" 2>/dev/null
}

# ============================================================
# Determine baseline behavior for each F2P signal.
# The base ALREADY contains "Elapsed"/"Took" labels and toFixed(1) in bash.ts —
# so those grep-style checks pass on base and are NOT valid F2P signals.
# We need behavioral signals that are FALSE on base and TRUE on the fix.
# ============================================================

# Compute key facts about base
BASE_BASH="$BASE_DIR/bash.ts.base"
BASE_TE="$BASE_DIR/tool-execution.ts.base"
BASE_IM="$BASE_DIR/interactive-mode.ts.base"

# Did base bash.ts already render timing? (yes — it had startedAt/Took/Elapsed)
BASE_BASH_HAD_TIMING=0
if [ -s "$BASE_BASH" ] && grep -qE "Elapsed|Took" "$BASE_BASH"; then
  BASE_BASH_HAD_TIMING=1
fi

# Did base render timing in HEADER (renderCall)?  Check by looking at what
# renderCall produced. In base, renderCall set context.executionStarted timing
# state but did NOT print elapsed in the header text — header was just
# formatBashCall(args). We rely on a positive signal: in base, renderCall
# itself does NOT contain "Elapsed" or "Took" string literals.
# So checking that header doesn't have timing is uninformative on base
# (it already doesn't). Skip header-static as F2P.

# ============================================================
# F2P Gate 1 (0.20): Bottom placement of timing in EITHER
# tool-execution.ts:renderBashContent / updateDisplay, OR
# bash.ts:rebuildBashResultRenderComponent
# 
# This must verify the timing render is AFTER the output rendering.
# On the base, bash.ts already places timing AFTER warnings (last addChild),
# so this would pass on base too — making it not F2P.
#
# Therefore the actual F2P signal is: timing rendering exists in
# tool-execution.ts (instruction-true), OR if it remained in bash.ts, the
# bottom placement was preserved AND something else changed.
#
# Concretely: the BASE bash.ts already renders timing. So leaving it there
# unmodified yields zero new behavior. We therefore require evidence that
# the agent ADDED timing rendering to tool-execution.ts (the instructed path).
# ============================================================
echo "=== F2P Gate 1 (0.20): Timing rendered in tool-execution.ts (instruction-true) ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
function hasTiming(s){
  return /Elapsed/.test(s) && /Took/.test(s);
}
const baseHas = hasTiming(base);
const curHas = hasTiming(cur);
// F2P: cur has timing AND base did not.
process.exit((curHas && !baseHas) ? 0 : 1);
" 2>/dev/null
F2P1=$?
if [ $F2P1 -eq 0 ]; then
  add_reward 0.20
  echo "PASS (0.20) [F2P1]: tool-execution.ts now renders timing"
else
  echo "FAIL (0.20) [F2P1]: tool-execution.ts does not render timing labels (or already did on base)"
fi

# ============================================================
# F2P Gate 2 (0.15): tool-execution.ts wires execution start timestamp.
# Look for evidence of a startTime / startedAt field plumbed through
# the component (a member assigned from Date.now()) that did NOT exist in base.
# ============================================================
echo "=== F2P Gate 2 (0.15): Execution start timestamp captured in tool-execution.ts ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
// Look for an instance field / setter capturing a start time.
const re = /(executionStart|bashStarted|startedAt|startTime|executionStartTime|executionStartTimestamp)/;
const baseHas = re.test(base);
const curHas = re.test(cur);
const hasDateNow = /Date\.now\s*\(\s*\)/.test(cur);
process.exit((curHas && !baseHas && hasDateNow) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P2]: tool-execution.ts captures start timestamp"
else
  echo "FAIL (0.15) [F2P2]: no new start timestamp plumbing in tool-execution.ts"
fi

# ============================================================
# F2P Gate 3 (0.15): interactive-mode.ts wires the start timestamp
# on tool_execution_start for bash tools. Must be NEW vs base.
# ============================================================
echo "=== F2P Gate 3 (0.15): interactive-mode.ts wires start timestamp for bash ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$INTERACTIVE','utf8');
const base = fs.readFileSync('$BASE_IM','utf8');
function diffAdded(c, b) {
  // crude: lines in c not in b
  const bSet = new Set(b.split('\n').map(s=>s.trim()));
  return c.split('\n').filter(l => !bSet.has(l.trim()));
}
const added = diffAdded(cur, base).join('\n');
// Heuristic: in tool_execution_start handling for bash, agent calls a
// setter on the component passing Date.now() (or similar) — and references
// 'bash' or a setter name involving start/timestamp/time.
const callsSetter = /(setExecutionStart|setStartTime|setBashStart|executionStart\w*\s*=|startedAt\s*=|startTime\s*=)/.test(added);
const refsBash = /['\"\`]bash['\"\`]/.test(added) || /toolName\s*===?\s*['\"\`]bash/.test(added);
const refsDateNow = /Date\.now\s*\(\s*\)/.test(added);
process.exit((callsSetter && (refsBash || refsDateNow)) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P3]: interactive-mode.ts wires start timestamp"
else
  echo "FAIL (0.15) [F2P3]: no new wiring for bash start timestamp"
fi

# ============================================================
# F2P Gate 4 (0.20): Live update plumbing NEW in tool-execution.ts.
# Base tool-execution.ts has no setInterval. The fix should add one
# (and a corresponding clearInterval) to update the elapsed display
# while the bash tool is running.
# ============================================================
echo "=== F2P Gate 4 (0.20): Live update timer added in tool-execution.ts ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
const baseHasSet = /setInterval\s*\(/.test(base);
const curHasSet  = /setInterval\s*\(/.test(cur);
const curHasClear = /clearInterval\s*\(/.test(cur);
const curHas1000 = /\b1000\b|1_000/.test(cur);
process.exit((!baseHasSet && curHasSet && curHasClear && curHas1000) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.20
  echo "PASS (0.20) [F2P4]: live setInterval(1000) + clearInterval added to tool-execution.ts"
else
  echo "FAIL (0.20) [F2P4]: no new live-update timer in tool-execution.ts"
fi

# ============================================================
# F2P Gate 5 (0.15): Bottom placement in tool-execution.ts.
# In tool-execution.ts, the timing render must occur AFTER the result
# rendering (output, truncation warnings, etc.) inside the same method.
# ============================================================
echo "=== F2P Gate 5 (0.15): Timing rendered AFTER output in tool-execution.ts ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC','utf8');
const lines = src.split('\n');

// Find a method that renders bash content. Most likely 'updateDisplay' or
// 'renderBashContent' or 'render'. We'll scan all methods that contain
// timing strings and check ordering inside them.
function blockRanges(lines) {
  const ranges = [];
  let stack = [];
  for (let i = 0; i < lines.length; i++) {
    const opens = (lines[i].match(/\{/g) || []).length;
    const closes = (lines[i].match(/\}/g) || []).length;
    for (let k = 0; k < opens; k++) stack.push(i);
    for (let k = 0; k < closes; k++) {
      const start = stack.pop();
      if (start !== undefined) ranges.push([start, i]);
    }
  }
  return ranges;
}

const ranges = blockRanges(lines);
let ok = false;
for (const [s, e] of ranges) {
  if (e - s < 5 || e - s > 400) continue;
  let lastOutput = -1, lastTiming = -1, hasTiming = false;
  for (let i = s; i <= e; i++) {
    const l = lines[i];
    if (/Elapsed|Took/.test(l)) { hasTiming = true; lastTiming = i; }
    if (/(addChild|renderContainer\.add|truncat|warning|fullOutputPath|getText|formatOutput|content\.map|resultRenderer|callRenderer|fallback)/i.test(l)
        && !/Elapsed|Took/.test(l)) {
      lastOutput = i;
    }
  }
  if (hasTiming && lastOutput !== -1 && lastTiming > lastOutput) { ok = true; break; }
}
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P5]: timing rendered after output in tool-execution.ts"
else
  echo "FAIL (0.15) [F2P5]: timing not placed below output in tool-execution.ts"
fi

# ============================================================
# F2P Gate 6 (0.15): One-decimal formatting present in tool-execution.ts.
# Base tool-execution.ts had no toFixed(1). The fix should add it
# (or use formatDuration imported from elsewhere — accept either).
# ============================================================
echo "=== F2P Gate 6 (0.15): 1-decimal precision in tool-execution.ts ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
const baseHas = /toFixed\s*\(\s*1\s*\)/.test(base) || /formatDuration\s*\(/.test(base) || /formatTimingDuration\s*\(/.test(base);
const curHas  = /toFixed\s*\(\s*1\s*\)/.test(cur)  || /formatDuration\s*\(/.test(cur)  || /formatTimingDuration\s*\(/.test(cur);
process.exit((!baseHas && curHas) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P6]: 1-decimal duration formatting in tool-execution.ts"
else
  echo "FAIL (0.15) [F2P6]: no new 1-decimal formatting in tool-execution.ts"
fi

# Cap at 1.0 (already capped in add_reward, but be safe)
REWARD=$(awk -v r="$REWARD" 'BEGIN{ if (r>1) r=1; printf "%.4f", r }')

echo ""
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt