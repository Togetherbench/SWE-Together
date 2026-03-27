#!/usr/bin/env bash
#
# Verification tests for banodoco-wrapped performance improvements.
#
# Tests TopGenerations.tsx row virtualization and ModelTrends.tsx animation fixes.
# Uses TypeScript compiler API (via Node.js) for AST checks and tsc/vite for
# behavioral compilation/build checks.
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=10

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

###############################################################################
# STRUCTURAL CHECKS (30% — Tests 1-3)
###############################################################################

echo "=== Test 1/10: TopGenerations.tsx uses IntersectionObserver for lazy row loading ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$TOP_GEN')) {
  console.error('FAIL: TopGenerations.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$TOP_GEN', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

let hasIntersectionObserver = false;
let hasConditionalRender = false;

function visit(n) {
  // Check for IntersectionObserver usage
  if (ts.isIdentifier(n) && n.text === 'IntersectionObserver') {
    hasIntersectionObserver = true;
  }
  // Check for 'visible' or 'loaded' state controlling render
  if (ts.isIdentifier(n) && /visible|loaded|inView|isVisible/.test(n.text)) {
    hasConditionalRender = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (!hasIntersectionObserver) {
  console.error('FAIL: TopGenerations.tsx has no IntersectionObserver — no lazy row loading implemented');
  process.exit(1);
}

console.log('PASS: TopGenerations.tsx uses IntersectionObserver for lazy row loading');
" && PASS=$((PASS + 1)) || true

echo ""
echo "=== Test 2/10: ModelTrends.tsx uses IntersectionObserver for auto-play on scroll ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

let hasIntersectionObserver = false;
let hasPlayTrigger = false;

function visit(n) {
  if (ts.isIdentifier(n) && n.text === 'IntersectionObserver') {
    hasIntersectionObserver = true;
  }
  // Check that it triggers playing (isPlaying, setIsPlaying, play, autoPlay)
  if (ts.isIdentifier(n) && /isPlaying|setIsPlaying|play|autoPlay|hasAutoPlayed/.test(n.text)) {
    hasPlayTrigger = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (!hasIntersectionObserver) {
  console.error('FAIL: ModelTrends.tsx has no IntersectionObserver — no auto-play on scroll');
  process.exit(1);
}
if (!hasPlayTrigger) {
  console.error('FAIL: ModelTrends.tsx has IntersectionObserver but no play-triggering state');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx uses IntersectionObserver to trigger play on scroll');
" && PASS=$((PASS + 1)) || true

echo ""
echo "=== Test 3/10: ModelTrends.tsx has variable animation speed (ease-out, not constant STEP_MS) ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

// The base code has: const STEP_MS = 180;
// A fix uses MIN_STEP_MS/MAX_STEP_MS or a getStepDuration function or easing math.
// Require POSITIVE evidence of variable timing — deleting STEP_MS alone must NOT pass.

let hasVariableTiming = false;

function visit(n) {
  if (ts.isVariableDeclaration(n)) {
    const name = n.name && ts.isIdentifier(n.name) ? n.name.text : '';
    if (/MIN_STEP|MAX_STEP|minStep|maxStep|stepMin|stepMax/.test(name)) hasVariableTiming = true;
  }
  if (ts.isFunctionDeclaration(n)) {
    const name = n.name && ts.isIdentifier(n.name) ? n.name.text : '';
    if (/step|duration|timing|ease/i.test(name)) hasVariableTiming = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Strip comments before regex checks to prevent comment-injection gaming
const srcNoComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Check for easing math patterns in source (positive evidence)
const hasEasePattern = /easeOut|ease[_-]?out|easeInOut|Math\.pow|cubicBezier/i.test(srcNoComments);
const hasProgressCalc = /progress\s*\*\s*progress|1\s*-\s*Math\.pow|Math\.sqrt\(/.test(srcNoComments);
const hasMinMax = /MIN_STEP|MAX_STEP|getStepDuration|stepDuration/.test(srcNoComments);

if (!hasVariableTiming && !hasEasePattern && !hasProgressCalc && !hasMinMax) {
  console.error('FAIL: ModelTrends.tsx has no positive evidence of variable animation timing (ease-out). Need easing function, MIN/MAX step, or progress-based calculation.');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx has variable animation speed (ease-out timing)');
" && PASS=$((PASS + 1)) || true

###############################################################################
# BEHAVIORAL CHECKS (40% — Tests 4-7)
###############################################################################

echo ""
echo "=== Test 4/10: No new TypeScript errors in TopGenerations.tsx or ModelTrends.tsx ==="
# Pre-existing errors exist in MillionthMessage.tsx and dataProcessing.ts (unrelated to task).
# Only check for errors referencing the files the agent should modify.
cd "$REPO"
TSC_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
TASK_ERRORS=$(echo "$TSC_OUTPUT" | grep -E "TopGenerations\.tsx|ModelTrends\.tsx" || true)
if [ -z "$TASK_ERRORS" ]; then
  PASS=$((PASS + 1))
  echo "PASS: No TypeScript errors in TopGenerations.tsx or ModelTrends.tsx"
else
  echo "FAIL: TypeScript errors in task files:"
  echo "$TASK_ERRORS"
fi

echo ""
echo "=== Test 5/10: ModelTrends.tsx animation initializes at 0 or 1 (not data.length) ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

let hasDataLengthInit = false;
let hasValidInit = false;

// Detect pattern: useState(data.length) for visibleCount or frame counter
// This is the original bug: starts at data.length means no animation plays.
// Require POSITIVE evidence of useState(0) or useState(1) — deletion alone must NOT pass.
function visit(n) {
  if (ts.isCallExpression(n)) {
    const callee = src.slice(n.expression.pos, n.expression.end).trim();
    if (callee === 'useState' && n.arguments.length === 1) {
      const arg = src.slice(n.arguments[0].pos, n.arguments[0].end).trim();
      if (arg === 'data.length') {
        hasDataLengthInit = true;
      }
      if (arg === '0' || arg === '1') {
        hasValidInit = true;
      }
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (hasDataLengthInit) {
  console.error('FAIL: ModelTrends.tsx still uses useState(data.length) — animation starts at end');
  process.exit(1);
}

if (!hasValidInit) {
  console.error('FAIL: ModelTrends.tsx has no useState(0) or useState(1) for animation frame counter — need positive evidence of animation start state');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx animation initializes at 0 or 1 (correct start state)');
" && PASS=$((PASS + 1)) || true

echo ""
echo "=== Test 6/10: ModelTrends.tsx has data normalization (values sum to ~100%) ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

let hasMappingWithDivision = false;
let hasNormalizeRef = false;

// Strip comments before regex checks to prevent comment-injection gaming
const srcNoComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\\s\\S]*?\\*\//g, '');

// Check for normalizeData function or inline normalization (divides by total)
if (/normalizeData|normalize_data|normalized|normali[sz]e/.test(srcNoComments)) {
  hasNormalizeRef = true;
}

// Check that it actually divides values (not just a stub)
if (/total|sum/.test(srcNoComments) && /\/ total|\/ sum|\* \(100|\/ \w+Total/.test(srcNoComments)) {
  hasMappingWithDivision = true;
}

function visit(n) {
  if (ts.isFunctionDeclaration(n)) {
    const name = n.name && ts.isIdentifier(n.name) ? n.name.text : '';
    if (/normaliz/i.test(name)) {
      const body = n.body;
      if (body && body.statements.length > 1) {
        hasMappingWithDivision = true;
      }
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Require BOTH: a normalize reference AND actual division logic (not either/or).
// A no-op 'const normalized = data' passes the first but not the second.
if (!hasNormalizeRef) {
  console.error('FAIL: ModelTrends.tsx has no normalization reference (normalizeData, normalized, etc.)');
  process.exit(1);
}
if (!hasMappingWithDivision) {
  console.error('FAIL: ModelTrends.tsx has normalization reference but no division logic (/ total, / sum, * 100)');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx has data normalization with division logic');
" && PASS=$((PASS + 1)) || true

echo ""
echo "=== Test 7/10: ModelTrends.tsx Y-axis has fixed domain (not auto-scaling) ==="
node -e "
const fs = require('fs');

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');

// Strip comments before regex checks to prevent comment-injection gaming
const srcNoComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\\s\\S]*?\\*\//g, '');

// Check if Y-axis domain is fixed at [0, 100] or equivalent.
// Base code had domain={[0, 'auto']} which causes rescaling during animation.
// Require POSITIVE evidence of fixed domain — deletion alone must NOT pass.
const hasAutoScaling = /domain=\{\[0,\s*['\"]auto['\"]\]\}/.test(srcNoComments);
const hasFixedDomain = /domain=\{\[0,\s*100\]\}/.test(srcNoComments) ||
                       /domain=\{[^}]*\[0,\s*100\][^}]*\}/.test(srcNoComments) ||
                       /domain=\{\[\s*0\s*,\s*100\s*\]\}/.test(srcNoComments);

if (hasAutoScaling) {
  console.error('FAIL: ModelTrends.tsx Y-axis still uses auto-scaling domain={[0, \"auto\"]}');
  process.exit(1);
}

if (!hasFixedDomain) {
  console.error('FAIL: ModelTrends.tsx has no fixed Y-axis domain={[0, 100]} — need positive evidence of fixed domain');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx Y-axis uses fixed domain [0, 100]');
" && PASS=$((PASS + 1)) || true

###############################################################################
# DEEP VALIDATION (30% — Tests 8-10)
###############################################################################

echo ""
echo "=== Test 8/10: Production build succeeds (npm run build) ==="
cd "$REPO" && npm run build > /tmp/build_output.txt 2>&1
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  PASS=$((PASS + 1))
  echo "PASS: Production build succeeded"
else
  echo "FAIL: Production build failed:"
  tail -20 /tmp/build_output.txt
fi

echo ""
echo "=== Test 9/10: TopGenerations.tsx renders only visible rows (not all at once) ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

const src = fs.readFileSync('$TOP_GEN', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

// The fix should use IntersectionObserver to conditionally render row content.
// Require IntersectionObserver + .observe() call + conditional render.
let hasIO = false;
let hasConditionalOnVisible = false;
// Strip comments before regex check to prevent comment-injection gaming
const srcNoComments = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\\s\\S]*?\\*\//g, '');
let hasObserveCall = /\.observe\s*\(/.test(srcNoComments);

function visit(n) {
  if (ts.isIdentifier(n) && n.text === 'IntersectionObserver') {
    hasIO = true;
  }
  // Check for ternary expressions where the condition references a visibility variable
  if (ts.isConditionalExpression(n)) {
    const condition = src.slice(n.condition.pos, n.condition.end).trim();
    if (/^is[A-Z]|visible|inView|loaded/.test(condition)) {
      hasConditionalOnVisible = true;
    }
  }
  // Also check: visibleSet.has(index) or similar set-based visibility tracking
  if (ts.isIdentifier(n) && /visibleSet|visibleRows|visibleRange|visibleIndices/.test(n.text)) {
    hasConditionalOnVisible = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (!hasIO) {
  console.error('FAIL: TopGenerations.tsx has no IntersectionObserver for row visibility tracking');
  process.exit(1);
}

if (!hasObserveCall) {
  console.error('FAIL: TopGenerations.tsx has IntersectionObserver but never calls .observe() — observer is unused');
  process.exit(1);
}

if (!hasConditionalOnVisible) {
  console.error('FAIL: TopGenerations.tsx has IntersectionObserver but does not conditionally render rows');
  process.exit(1);
}

console.log('PASS: TopGenerations.tsx uses IntersectionObserver with .observe() to render only visible rows');
" && PASS=$((PASS + 1)) || true

echo ""
echo "=== Test 10/10: ModelTrends auto-play is complete and non-trivial ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true);

// Complete auto-play requires ALL of:
// 1. IntersectionObserver (scroll detection)
// 2. useEffect that sets up the observer
// 3. Animation state management (isPlaying or frame counter)
// 4. Non-trivial animation loop (requestAnimationFrame or setInterval)
// 5. Cleanup (cancelAnimationFrame, disconnect, or clearInterval)

let hasIO = false;
let hasUseEffect = false;
let hasRAF = false;
let hasStateUpdate = false;
let hasCleanup = false;

function visit(n) {
  if (ts.isIdentifier(n)) {
    if (n.text === 'IntersectionObserver') hasIO = true;
    if (n.text === 'useEffect') hasUseEffect = true;
    if (n.text === 'requestAnimationFrame') hasRAF = true;
    if (n.text === 'setIsPlaying' || n.text === 'setVisibleCount' || n.text === 'setFrame') {
      hasStateUpdate = true;
    }
    if (/cancelAnimationFrame|disconnect|clearInterval|clearTimeout/.test(n.text)) {
      hasCleanup = true;
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

const issues = [];
if (!hasIO) issues.push('no IntersectionObserver');
if (!hasUseEffect) issues.push('no useEffect');
if (!hasRAF) issues.push('no requestAnimationFrame');
if (!hasStateUpdate) issues.push('no animation state updates');
if (!hasCleanup) issues.push('no cleanup (cancelAnimationFrame/disconnect/clearInterval)');

if (issues.length > 0) {
  console.error('FAIL: ModelTrends auto-play incomplete:', issues.join(', '));
  process.exit(1);
}

// Anti-stub: check the file has substantial content (>100 lines)
const lineCount = src.split('\n').length;
if (lineCount < 100) {
  console.error('FAIL: ModelTrends.tsx too short (' + lineCount + ' lines) — likely a stub');
  process.exit(1);
}

console.log('PASS: ModelTrends.tsx has complete auto-play implementation (' + lineCount + ' lines)');
" && PASS=$((PASS + 1)) || true

echo ""
echo "================================"
echo "Results: $PASS / $TOTAL passed"
echo "================================"

if [ "$PASS" -eq "$TOTAL" ]; then
  echo "1.0" > "$REWARD_FILE"
  echo "REWARD: 1.0"
else
  REWARD=$(node -e "console.log(($PASS / $TOTAL).toFixed(2))")
  echo "$REWARD" > "$REWARD_FILE"
  echo "REWARD: $REWARD"
fi
