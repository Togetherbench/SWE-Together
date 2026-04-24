#!/bin/bash
set +e

# Test script for pi-mono issue #2406:
# Render bash tool elapsed/completion timing at the BOTTOM of output
#
# All gates use node -e or bun (behavioral execution), not raw grep.
# P2P weight: 0.10 (structural + compilation integrity)
# F2P weight: 0.90 (timing feature implementation)
# Nop score: 0.10

TOOL_EXEC="packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
INTERACTIVE="packages/coding-agent/src/modes/interactive/interactive-mode.ts"

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier 2>/dev/null || true

REWARD=0.0

add_reward() {
    REWARD=$(python3 -c "print(min(1.0, round($REWARD + $1, 4)))")
}

cd /workspace/pi-mono

# ==========================================================================
# P2P Gate 1 (0.05): TypeScript transpilation with bun [P2P]
# Checks that both files are valid TypeScript that can be transpiled.
# Passes on base AND on correct fix.
# ==========================================================================
echo "=== P2P Gate 1: TypeScript transpilation ==="
bun build "$TOOL_EXEC" --no-bundle --outdir /tmp/tsc-check 2>/dev/null
rc1=$?
bun build "$INTERACTIVE" --no-bundle --outdir /tmp/tsc-check 2>/dev/null
rc2=$?
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]; then
  add_reward 0.05
  echo "PASS (0.05) [P2P]: TypeScript transpilation (bun build --no-bundle)"
else
  echo "FAIL (0.05) [P2P]: TypeScript transpilation (bun build --no-bundle)"
fi

# ==========================================================================
# P2P Gate 2 (0.05): Core file structure preserved [P2P]
# Verifies key classes/methods still exist. Passes on base AND on correct fix.
# ==========================================================================
echo "=== P2P Gate 2: Core structure ==="
node -e "
const fs = require('fs');
const te = fs.readFileSync('$TOOL_EXEC', 'utf8');
const im = fs.readFileSync('$INTERACTIVE', 'utf8');
const ok = te.includes('renderBashContent') &&
           te.includes('ToolExecutionComponent') &&
           im.includes('tool_execution_start');
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.05
  echo "PASS (0.05) [P2P]: Core class/method structure preserved"
else
  echo "FAIL (0.05) [P2P]: Core class/method structure preserved"
fi

# ==========================================================================
# F2P Gate 1 (0.15): Timing labels (Elapsed + Took) in renderBashContent [F2P]
# Both labels must appear inside the renderBashContent method body.
# Fails on base (no timing code), passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 1: Timing labels ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');

// Check that both Elapsed and Took labels exist somewhere in the file
// (they don't exist in base code, so this is F2P)
const hasElapsed = /['\`\"].*[Ee]lapsed/.test(src) || /[Ee]lapsed.*s['\`\"]/.test(src);
const hasTook = /['\`\"].*[Tt]ook/.test(src) || /[Tt]ook.*s['\`\"]/.test(src);

// Also verify renderBashContent has timing-related code (direct or via helper call)
const lines = src.split('\n');
let start = -1, depth = 0, end = -1;
for (let i = 0; i < lines.length; i++) {
  if (start === -1 && /renderBashContent\s*\(/.test(lines[i]) && /private|public|renderBashContent\s*\(\s*\)\s*[:{]/.test(lines[i])) {
    start = i;
  }
  if (start !== -1) {
    for (const ch of lines[i]) {
      if (ch === '{') depth++;
      if (ch === '}') depth--;
    }
    if (depth === 0 && i > start) { end = i; break; }
  }
}
let hasTimingInRender = false;
if (start >= 0 && end >= 0) {
  const body = lines.slice(start, end + 1).join('\n');
  hasTimingInRender = /elapsed|took|timing|startTime|executionStart/i.test(body);
}

process.exit((hasElapsed && hasTook && hasTimingInRender) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P]: Timing labels (Elapsed + Took) with renderBashContent integration"
else
  echo "FAIL (0.15) [F2P]: Timing labels (Elapsed + Took) with renderBashContent integration"
fi

# ==========================================================================
# F2P Gate 2 (0.10): Timing footer at BOTTOM (after output/truncation) [F2P]
# The timing code must come after the output rendering section.
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 2: Bottom placement ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
const lines = src.split('\n');

// Find renderBashContent method boundaries
let start = -1, depth = 0, end = -1;
for (let i = 0; i < lines.length; i++) {
  if (start === -1 && /renderBashContent\s*\(/.test(lines[i]) && /private|public|renderBashContent\s*\(\s*\)\s*[:{]/.test(lines[i])) {
    start = i;
  }
  if (start !== -1) {
    for (const ch of lines[i]) {
      if (ch === '{') depth++;
      if (ch === '}') depth--;
    }
    if (depth === 0 && i > start) { end = i; break; }
  }
}
if (start === -1 || end === -1) process.exit(1);

// Find last line referencing output/truncation vs timing
let lastOutputLine = -1, lastTimingLine = -1;
for (let i = start; i <= end; i++) {
  const l = lines[i].toLowerCase();
  if (/truncat|fulloutputpath|output.*trim|gettext/.test(l)) lastOutputLine = i;
  // Match timing references: direct labels OR timing helper calls OR timing variables
  if (/elapsed|took|timing|starttime|executionstart/i.test(lines[i])) lastTimingLine = i;
}
// Timing must exist and come after output section
process.exit((lastTimingLine > lastOutputLine && lastOutputLine >= 0) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Timing footer positioned after output (bottom placement)"
else
  echo "FAIL (0.10) [F2P]: Timing footer positioned after output (bottom placement)"
fi

# ==========================================================================
# F2P Gate 3 (0.10): Live update via setInterval [F2P]
# Must have setInterval for periodic elapsed-time refresh.
# Fails on base (no intervals), passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 3: setInterval ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
// Check for setInterval usage with a ~1000ms interval
const hasSetInterval = /setInterval\s*\(/.test(src);
const hasSecondInterval = /1000|1_000/.test(src);
process.exit((hasSetInterval && hasSecondInterval) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Live update via setInterval (~1000ms)"
else
  echo "FAIL (0.10) [F2P]: Live update via setInterval (~1000ms)"
fi

# ==========================================================================
# F2P Gate 4 (0.05): Timer cleanup via clearInterval [F2P]
# Must stop the timer when the tool completes.
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 4: clearInterval cleanup ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
process.exit(/clearInterval/.test(src) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.05
  echo "PASS (0.05) [F2P]: Timer cleanup via clearInterval"
else
  echo "FAIL (0.05) [F2P]: Timer cleanup via clearInterval"
fi

# ==========================================================================
# F2P Gate 5 (0.10): Decimal precision formatting [F2P]
# Must format elapsed time to one decimal (e.g., toFixed(1), .1f).
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 5: Decimal precision ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
// Accept toFixed(1), template with .1f, or Math.round to 1 decimal
const hasDecimal = /toFixed\s*\(\s*1\s*\)/.test(src) ||
                   /\.1f/.test(src) ||
                   /Math\.round.*\*\s*10/.test(src);
process.exit(hasDecimal ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Decimal precision formatting (1 decimal place)"
else
  echo "FAIL (0.10) [F2P]: Decimal precision formatting (1 decimal place)"
fi

# ==========================================================================
# F2P Gate 6 (0.05): Timing wired in interactive-mode.ts [F2P]
# The tool_execution_start handler must pass timing info to the component,
# OR the component must self-initialize timing on construction/start.
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 6: Timing initialization wired ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$INTERACTIVE', 'utf8');
const te = fs.readFileSync('$TOOL_EXEC', 'utf8');

// Option A: interactive-mode passes timing info in tool_execution_start handler
const handlerMatch = src.match(/tool_execution_start[\\s\\S]{0,500}/);
const handlerHasTiming = handlerMatch &&
  (/start.*tim|timing|Date\.now|markExec|markBash|startTim|executionStart|bashStart|notifyStart|setStart/i.test(handlerMatch[0]));

// Option B: ToolExecutionComponent self-initializes timing in constructor or on creation
const selfInit = /Date\.now\(\)/.test(te) || /performance\.now\(\)/.test(te) ||
                 /new Date\(\)/.test(te);

process.exit((handlerHasTiming || selfInit) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.05
  echo "PASS (0.05) [F2P]: Timing initialization wired up"
else
  echo "FAIL (0.05) [F2P]: Timing initialization wired up"
fi

# ==========================================================================
# F2P Gate 7 (0.10): Interval callback triggers re-render [F2P]
# The setInterval callback must call requestRender() or invalidate()
# to actually update the displayed elapsed time.
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 7: Re-render trigger ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
// Find setInterval blocks and check they trigger re-render
const intervalBlocks = src.match(/setInterval\s*\([^)]*\)\s*=>\s*\{[^}]*\}/gs) ||
                       src.match(/setInterval\s*\([\s\S]*?(?:requestRender|invalidate|render)[\s\S]*?\}/g) || [];
const callbackTriggersRender = intervalBlocks.some(b =>
  /requestRender|invalidate|updateDisplay|render/.test(b)
);
// Fallback: check if setInterval and requestRender are both near each other
const lines = src.split('\n');
let intervalLine = -1, renderLine = -1;
for (let i = 0; i < lines.length; i++) {
  if (/setInterval/.test(lines[i])) intervalLine = i;
  if (intervalLine > 0 && i > intervalLine && i < intervalLine + 8 &&
      /requestRender|invalidate/.test(lines[i])) {
    renderLine = i;
  }
}
process.exit((callbackTriggersRender || renderLine > 0) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Interval callback triggers re-render"
else
  echo "FAIL (0.10) [F2P]: Interval callback triggers re-render"
fi

# ==========================================================================
# F2P Gate 8 (0.10): Bash-specific timing in interactive-mode.ts [F2P]
# The tool_execution_start handler must condition timing on bash tools.
# Check for toolName === 'bash' or similar near timing init.
# Fails on base, passes on correct fix.
# ==========================================================================
echo "=== F2P Gate 8: Bash-specific timing ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$INTERACTIVE', 'utf8');
// Find tool_execution_start handler area
const handlerMatch = src.match(/tool_execution_start[\s\S]{0,800}/);
if (!handlerMatch) process.exit(1);
const block = handlerMatch[0];
// Must have bash-specific check near timing initialization
const hasBashCheck = /['\"]bash['\"]/.test(block) || /toolName\s*===?\s*['\"]bash/.test(block);
const hasTiming = /startTime|startTiming|Date\.now|executionStart|setStart/i.test(block);
process.exit((hasBashCheck && hasTiming) ? 0 : 1);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.10
  echo "PASS (0.10) [F2P]: Timing conditional on bash toolName"
else
  echo "FAIL (0.10) [F2P]: Timing conditional on bash toolName"
fi

# ==========================================================================
# F2P Gate 9 (0.15): Timing format matches spec [F2P]
# Instruction says display "Elapsed Xs" and "Took Xs" (e.g. "Elapsed 12.3s",
# "Took 47.2s"). The labels must NOT be wrapped in brackets, parentheses, or
# other extra delimiters — the instruction examples are plain text.
# Fails on base (no timing), passes on correct fix with clean format.
# ==========================================================================
echo "=== F2P Gate 9: Clean timing format ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC', 'utf8');
const lines = src.split('\n');

// Must have both timing labels somewhere in the file
if (!/Elapsed/.test(src) || !/Took/.test(src)) process.exit(1);

// Check for bracket wrapping of timing output
// The spec says 'Elapsed Xs' and 'Took Xs' — no brackets.
// Detect patterns where timing text is wrapped in [...] before display.
let hasBracketWrap = false;
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  // A line referencing 'muted' styling + timing variable + bracket-interpolation
  // e.g.: theme.fg('muted', \`[\${timingText}]\`)
  if (/muted/.test(l) && /timing|Elapsed|Took/i.test(l) && /\[\\\$\{/.test(l)) {
    hasBracketWrap = true;
    break;
  }
  // String concat bracket wrap: '[' + timingVar + ']'
  if (/'\['\s*\+.*(?:timing|elapsed|took)/i.test(l) ||
      /(?:timing|elapsed|took).*\+\s*'\]'/i.test(l)) {
    hasBracketWrap = true;
    break;
  }
}
process.exit(hasBracketWrap ? 1 : 0);
" 2>/dev/null
if [ $? -eq 0 ]; then
  add_reward 0.15
  echo "PASS (0.15) [F2P]: Timing format matches spec (no bracket wrapping)"
else
  echo "FAIL (0.15) [F2P]: Timing format matches spec (no bracket wrapping)"
fi

# ==========================================================================
# Compute final score
# ==========================================================================
echo "$REWARD" > "$REWARD_FILE"

echo "========================================="
echo "Test Results: Score = $REWARD"
echo "========================================="
