#!/usr/bin/env bash
#
# Verification tests for banodoco-wrapped performance improvements.
#
# Tests TopGenerations.tsx row virtualization and ModelTrends.tsx animation fixes.
# 10 tests, total weight 20 (reward = score / 20).
#
# Behavioral (P2P + Silver):  9/20 (45%)  |  Structural (AST/regex): 11/20 (55%)
# Note: React UI code requires a browser/DOM for full behavioral testing.
# Silver-tier function extraction is used where possible; AST for browser-only paths.
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
TOTAL=20

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

cd "$REPO"

###############################################################################
# BEHAVIORAL TESTS (Tests 1-4, 9/20 = 45%)
###############################################################################

echo "=== Test 1/10 [P2P, weight 2/20]: Vite production build succeeds ==="
timeout 120 npm run build > /tmp/build_output.txt 2>&1
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 2))
  echo "PASS: Production build succeeded"
else
  echo "FAIL: Production build failed:"
  tail -20 /tmp/build_output.txt
fi

echo ""
echo "=== Test 2/10 [P2P, weight 1/20]: No TypeScript errors in task files ==="
TSC_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
TASK_ERRORS=$(echo "$TSC_OUTPUT" | grep -E "TopGenerations\.tsx|ModelTrends\.tsx" || true)
if [ -z "$TASK_ERRORS" ]; then
  SCORE=$((SCORE + 1))
  echo "PASS: No TypeScript errors in TopGenerations.tsx or ModelTrends.tsx"
else
  echo "FAIL: TypeScript errors in task files:"
  echo "$TASK_ERRORS"
fi

echo ""
echo "=== Test 3/10 [F2P Silver, weight 3/20]: Normalization function produces correct output ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// ---- Silver: extract and execute normalization function ----
let silverPassed = false;
const candidates = [];

function findNorm(n) {
  if (ts.isVariableDeclaration(n) && n.initializer) {
    const name = n.name.getText ? n.name.getText(sf) : '';
    if (/normaliz/i.test(name) && (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
      candidates.push({ name, node: n.initializer });
    }
  }
  if (ts.isFunctionDeclaration(n) && n.name && /normaliz/i.test(n.name.text)) {
    candidates.push({ name: n.name.text, node: n });
  }
  // Also check for functions with total/sum division logic (may not be named 'normalize')
  if (ts.isVariableDeclaration(n) && n.initializer) {
    const name = n.name.getText ? n.name.getText(sf) : '';
    if ((ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer)) &&
        !candidates.some(c => c.name === name)) {
      const body = src.slice(n.initializer.pos, n.initializer.end);
      if ((/\/ total|\/ sum|\* 100/).test(body) && /\.map\s*\(/.test(body)) {
        candidates.push({ name, node: n.initializer });
      }
    }
  }
  ts.forEachChild(n, findNorm);
}
findNorm(sf);

for (const { name, node } of candidates) {
  try {
    const funcSrc = src.slice(node.pos, node.end).trim();
    const jsCode = ts.transpileModule('const __nfn = ' + funcSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
    }).outputText;
    const fnBody = jsCode.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
    const fn = eval('(' + fnBody + ')');

    // Test with Recharts-style data: objects with string key + numeric model values
    const testSets = [
      [{ month: 'Jan', a: 30, b: 70 }, { month: 'Feb', a: 25, b: 25, c: 50 }],
      [{ month: 'Jan', a: 60, b: 40 }, { month: 'Feb', a: 10, b: 20, c: 30, d: 40 }],
      [{ a: 30, b: 70 }, { a: 25, b: 25, c: 50 }],
    ];

    for (const testData of testSets) {
      try {
        const input = JSON.parse(JSON.stringify(testData));
        let result = fn(input);
        if (!Array.isArray(result)) result = input; // mutated in-place

        let allValid = true;
        for (const row of result) {
          const nums = Object.values(row).filter(v => typeof v === 'number');
          const sum = nums.reduce((a, b) => a + b, 0);
          if (nums.length === 0) { allValid = false; break; }
          // Normalized to ~100% (+/-5 for rounding)
          if (sum > 1 && (sum < 95 || sum > 105)) { allValid = false; break; }
          // Or normalized to ~1.0 (+/-0.05)
          if (sum <= 1 && (sum < 0.95 || sum > 1.05)) { allValid = false; break; }
        }
        if (allValid && result.length === testData.length) {
          silverPassed = true;
          console.log('PASS: Normalization function \'' + name + '\' produces correct output (Silver)');
          break;
        }
      } catch (e) { /* try next test set */ }
    }
    if (silverPassed) break;
  } catch (e) { /* try next candidate */ }
}

if (!silverPassed) {
  // ---- Bronze+ fallback: pattern matching ----
  const hasNormRef = /normaliz/i.test(srcNC);
  const hasTotalCalc = /(?:const|let|var)\s+(?:total|sum)\b/.test(srcNC) || /\.reduce\s*\(/.test(srcNC);
  const hasDivision = /\/\s*total|\/\s*sum|\/\s*\w+Total|\*\s*\(?100/.test(srcNC);
  const hasMap = /\.map\s*\(/.test(srcNC);

  const issues = [];
  if (!hasNormRef) issues.push('no normalization reference');
  if (!hasTotalCalc) issues.push('no total/sum calculation');
  if (!hasDivision) issues.push('no division by total');
  if (!hasMap) issues.push('no .map() transform');

  if (issues.length > 0) {
    console.error('FAIL: Normalization incomplete:', issues.join(', '));
    process.exit(1);
  }
  console.log('PASS: Normalization has total calc + division + map (Bronze+)');
}
" && SCORE=$((SCORE + 3)) || true

echo ""
echo "=== Test 4/10 [F2P Silver, weight 3/20]: Easing replaces constant STEP_MS=180 ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Fail-fast: if the original buggy constant is still there, the bug isn't fixed
if (/const\s+STEP_MS\s*=\s*180/.test(srcNC)) {
  console.error('FAIL: Still has const STEP_MS = 180 — constant speed, no easing');
  process.exit(1);
}

// ---- Silver: extract easing function and test non-linearity ----
let silverPassed = false;
const candidates = [];

function findEasing(n) {
  if (ts.isVariableDeclaration(n) && n.initializer) {
    const name = n.name.getText ? n.name.getText(sf) : '';
    if (/ease|easing|getStep|stepDur/i.test(name) &&
        (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
      candidates.push({ name, node: n.initializer });
    }
  }
  if (ts.isFunctionDeclaration(n) && n.name && /ease|easing|getStep|stepDur/i.test(n.name.text)) {
    candidates.push({ name: n.name.text, node: n });
  }
  ts.forEachChild(n, findEasing);
}
findEasing(sf);

for (const { name, node } of candidates) {
  try {
    const funcSrc = src.slice(node.pos, node.end).trim();
    const jsCode = ts.transpileModule('const __easefn = ' + funcSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
    }).outputText;
    const fnBody = jsCode.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
    const fn = eval('(' + fnBody + ')');

    // Pattern A: standard easing f: [0,1] -> [0,1] where f(0.5) != 0.5
    try {
      const v05 = fn(0.5);
      if (typeof v05 === 'number' && !isNaN(v05) && Math.abs(v05 - 0.5) > 0.05) {
        silverPassed = true;
        console.log('PASS: Easing \'' + name + '\' is non-linear: f(0.5)=' + v05.toFixed(3) + ' (Silver)');
        break;
      }
    } catch (e) {}

    // Pattern B: step duration f(step, total) -> ms where output varies
    try {
      const d1 = fn(5, 20), d2 = fn(15, 20);
      if (typeof d1 === 'number' && typeof d2 === 'number' && d1 !== d2 && !isNaN(d1)) {
        silverPassed = true;
        console.log('PASS: Duration \'' + name + '\' varies: f(5,20)=' + d1.toFixed(1) + ', f(15,20)=' + d2.toFixed(1) + ' (Silver)');
        break;
      }
    } catch (e) {}

    // Pattern C: single-arg duration f(progress) -> ms
    try {
      const d1 = fn(0.2), d2 = fn(0.8);
      if (typeof d1 === 'number' && typeof d2 === 'number' && d1 !== d2 && !isNaN(d1) && d1 > 0) {
        silverPassed = true;
        console.log('PASS: Duration \'' + name + '\' varies: f(0.2)=' + d1.toFixed(1) + ', f(0.8)=' + d2.toFixed(1) + ' (Silver)');
        break;
      }
    } catch (e) {}
  } catch (e) { /* extraction failed, try next */ }
}

if (!silverPassed) {
  // ---- Bronze+ fallback: positive evidence of easing ----
  const hasEasingCall = /easeOut\s*\(|ease[_-]?[oO]ut\s*\(|easeInOut\s*\(/i.test(srcNC);
  const hasMathPow = /Math\.pow\s*\([^)]*1\s*-/.test(srcNC) || /\*\*\s*[23]/.test(srcNC);
  const hasMinMax = /(MIN_STEP|MAX_STEP|minStep|maxStep)\s*[+\-*\/=]/.test(srcNC);
  const hasStepDuration = /getStepDuration|stepDuration\s*=/.test(srcNC);
  const hasProgressCalc = /progress\s*\*/.test(srcNC);

  if (!hasEasingCall && !hasMathPow && !hasMinMax && !hasStepDuration && !hasProgressCalc) {
    console.error('FAIL: No evidence of ease-out timing (need easing function, MIN/MAX step, or progress calc)');
    process.exit(1);
  }
  console.log('PASS: STEP_MS=180 removed, easing evidence present (Bronze+)');
}
" && SCORE=$((SCORE + 3)) || true

###############################################################################
# STRUCTURAL TESTS (Tests 5-10, 11/20 = 55%)
###############################################################################

echo ""
echo "=== Test 5/10 [F2P, weight 2/20]: Animation starts at 0, not data.length ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

let hasDataLengthInit = false;
let hasValidInit = false;

function visit(n) {
  if (ts.isCallExpression(n)) {
    const callee = src.slice(n.expression.pos, n.expression.end).trim();
    if (callee === 'useState' && n.arguments.length === 1) {
      const arg = src.slice(n.arguments[0].pos, n.arguments[0].end).trim();
      // Buggy pattern: useState(data.length) — starts animation at the end
      if (/^data\.length$|\.length\b/.test(arg)) {
        hasDataLengthInit = true;
      }
      // Fixed pattern: useState(0) or useState(1) — starts animation from beginning
      if (arg === '0' || arg === '1') {
        hasValidInit = true;
      }
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (hasDataLengthInit) {
  console.error('FAIL: Still uses useState(data.length) — animation starts at end, never plays');
  process.exit(1);
}
if (!hasValidInit) {
  console.error('FAIL: No useState(0) or useState(1) — need positive evidence of animation start at 0');
  process.exit(1);
}

console.log('PASS: Animation state initializes at 0 or 1 (not data.length)');
" && SCORE=$((SCORE + 2)) || true

echo ""
echo "=== Test 6/10 [F2P, weight 2/20]: Y-axis fixed domain [0, 100] ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Check YAxis elements via AST for domain prop
let hasAutoOnYAxis = false;
let hasFixedOnYAxis = false;

function visit(n) {
  if (ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n)) {
    const tagText = src.slice(n.tagName.pos, n.tagName.end).trim();
    if (tagText === 'YAxis') {
      const elemText = src.slice(n.pos, n.end);
      if (/domain=\{[^}]*['\"]auto['\"][^}]*\}/.test(elemText)) hasAutoOnYAxis = true;
      if (/domain=\{\s*\[\s*0\s*,\s*100\s*\]\s*\}/.test(elemText)) hasFixedOnYAxis = true;
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Fallback: regex on entire file (handles spread props, variables, etc.)
if (!hasAutoOnYAxis && !hasFixedOnYAxis) {
  hasAutoOnYAxis = /domain=\{\s*\[\s*0\s*,\s*['\"]auto['\"]\s*\]\s*\}/.test(srcNC);
  hasFixedOnYAxis = /domain=\{\s*\[\s*0\s*,\s*100\s*\]\s*\}/.test(srcNC);
}

if (hasAutoOnYAxis) {
  console.error('FAIL: Y-axis still uses domain with auto — rescales during animation');
  process.exit(1);
}
if (!hasFixedOnYAxis) {
  console.error('FAIL: No domain={[0, 100]} found on YAxis — Y-axis not fixed');
  process.exit(1);
}

console.log('PASS: Y-axis uses fixed domain [0, 100]');
" && SCORE=$((SCORE + 2)) || true

echo ""
echo "=== Test 7/10 [F2P Bronze+, weight 3/20]: TopGenerations uses virtualization ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$TOP_GEN')) {
  console.error('FAIL: TopGenerations.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$TOP_GEN', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

let hasIO = false;
let hasConditionalOnVisible = false;

function visit(n) {
  if (ts.isIdentifier(n) && n.text === 'IntersectionObserver') hasIO = true;
  // Ternary with visibility condition
  if (ts.isConditionalExpression(n)) {
    const cond = src.slice(n.condition.pos, n.condition.end).trim();
    if (/^is[A-Z]|visible|inView|loaded/.test(cond)) hasConditionalOnVisible = true;
  }
  // Set/range-based visibility tracking
  if (ts.isIdentifier(n) && /visibleSet|visibleRows|visibleRange|visibleIndices|visibleItems/.test(n.text)) {
    hasConditionalOnVisible = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Also accept virtualization libraries
const hasVirtualLib = /react-virtuoso|react-window|react-virtual|@tanstack\/virtual|useVirtualizer|useInView/.test(src);
const hasObserve = /\.observe\s*\(/.test(srcNC);
const hasCleanup = /\.disconnect\s*\(|\.unobserve\s*\(/.test(srcNC);

// Anti-stub: file must be non-trivial
const meaningfulLines = src.split('\n')
  .map(l => l.trim())
  .filter(l => l.length > 0 && !l.startsWith('//') && !l.startsWith('*'))
  .length;

const usesRawIO = hasIO && hasObserve && hasCleanup;
const usesLib = hasVirtualLib;

const issues = [];
if (!usesRawIO && !usesLib) {
  if (!hasIO && !hasVirtualLib) issues.push('no IntersectionObserver or virtualization library');
  if (hasIO && !hasObserve) issues.push('no .observe() call');
  if (hasIO && !hasCleanup) issues.push('no cleanup (.disconnect/.unobserve)');
}
if (!hasConditionalOnVisible && !usesLib) issues.push('no conditional render based on visibility');
if (meaningfulLines < 60) issues.push('too few meaningful lines (' + meaningfulLines + ' < 60)');

if (issues.length > 0) {
  console.error('FAIL: TopGen virtualization incomplete:', issues.join(', '));
  process.exit(1);
}

console.log('PASS: TopGenerations has virtualization (' + meaningfulLines + ' meaningful lines)');
" && SCORE=$((SCORE + 3)) || true

echo ""
echo "=== Test 8/10 [F2P Bronze+, weight 2/20]: ModelTrends has auto-play with IntersectionObserver ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

let hasIO = false;
let hasUseEffect = false;
let hasAnimLoop = false;
let hasStateUpdate = false;
let hasCleanup = false;

function visit(n) {
  if (ts.isIdentifier(n)) {
    if (n.text === 'IntersectionObserver') hasIO = true;
    if (n.text === 'useEffect') hasUseEffect = true;
    if (n.text === 'requestAnimationFrame' || n.text === 'setInterval' || n.text === 'setTimeout') hasAnimLoop = true;
    if (/^set[A-Z]/.test(n.text) && /Playing|Visible|Count|Frame|Step|Progress|Index/i.test(n.text)) hasStateUpdate = true;
    if (/cancelAnimationFrame|disconnect|clearInterval|clearTimeout/.test(n.text)) hasCleanup = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Also accept IO hook libraries
const hasIOHook = /useInView|useIntersection|react-intersection/.test(src);

// Anti-stub: substantial file
const meaningfulLines = src.split('\n')
  .map(l => l.trim())
  .filter(l => l.length > 0 && !l.startsWith('//') && !l.startsWith('*'))
  .length;

const issues = [];
if (!hasIO && !hasIOHook) issues.push('no IntersectionObserver or useInView hook');
if (!hasUseEffect) issues.push('no useEffect');
if (!hasAnimLoop) issues.push('no animation loop (rAF/setInterval)');
if (!hasStateUpdate) issues.push('no animation state updates');
if (!hasCleanup) issues.push('no cleanup');
if (meaningfulLines < 80) issues.push('too few meaningful lines (' + meaningfulLines + ' < 80)');

if (issues.length > 0) {
  console.error('FAIL: ModelTrends auto-play incomplete:', issues.join(', '));
  process.exit(1);
}

console.log('PASS: ModelTrends has auto-play (' + meaningfulLines + ' meaningful lines)');
" && SCORE=$((SCORE + 2)) || true

echo ""
echo "=== Test 9/10 [Bronze, weight 1/20]: ModelTrends has model entry labels ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

let hasLabelJSX = false;
let hasLabelLogic = false;

function visit(n) {
  // JSX elements for labels (SVG text, custom label components)
  if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
    const tag = src.slice(n.tagName.pos, n.tagName.end).trim();
    if (/^(text|Label|CustomLabel|CustomizedLabel|ReferenceLine)$/i.test(tag)) {
      hasLabelJSX = true;
    }
  }
  // Label-related identifiers
  if (ts.isIdentifier(n) && /label|newModel|modelEntry|floating/i.test(n.text)) {
    hasLabelLogic = true;
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Also check for label text rendering patterns
const hasLabelText = /label.*model|model.*label|\.name|modelName/i.test(srcNC);
const hasPositioning = /position.*absolute|transform.*translate|cx\s*=|cy\s*=|x=.*y=|fill.*white|white/i.test(srcNC);

if (!hasLabelJSX && !hasLabelText) {
  console.error('FAIL: No model label rendering (no label JSX or text patterns)');
  process.exit(1);
}
if (!hasLabelLogic && !hasPositioning) {
  console.error('FAIL: No label positioning or model entry logic');
  process.exit(1);
}

console.log('PASS: ModelTrends has model entry labels');
" && SCORE=$((SCORE + 1)) || true

echo ""
echo "=== Test 10/10 [F2P Bronze, weight 1/20]: Progressive data reveal connected to auto-play ==="
node -e "
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Progressive reveal: data is subsetted based on animation frame
const hasSlice = /\.slice\s*\(\s*0\s*,/.test(srcNC);
const hasIndexFilter = /\.filter\s*\([^)]*(?:index|i)\s*[<>=]/.test(srcNC);
const hasSubset = hasSlice || hasIndexFilter;

// Must be connected to auto-play (IntersectionObserver or useInView)
// This prevents base code from passing — base has .slice but no IO
const hasAutoPlay = /IntersectionObserver|useInView|useIntersection/.test(srcNC);

// Frame counter used for data subsetting
const hasFrameCounter = /visibleCount|currentFrame|animFrame|displayCount|frameIndex|step/i.test(srcNC);

const issues = [];
if (!hasSubset) issues.push('no data subsetting (.slice(0,) or index filter)');
if (!hasAutoPlay) issues.push('no auto-play trigger (IntersectionObserver/useInView)');
if (!hasFrameCounter) issues.push('no frame counter for progressive reveal');

if (issues.length > 0) {
  console.error('FAIL: Progressive reveal incomplete:', issues.join(', '));
  process.exit(1);
}

console.log('PASS: ModelTrends has progressive data reveal with auto-play');
" && SCORE=$((SCORE + 1)) || true

###############################################################################
# RESULTS
###############################################################################

echo ""
echo "================================"
echo "Results: $SCORE / $TOTAL"
echo "================================"

REWARD=$(node -e "console.log(Math.min(1.0, $SCORE / $TOTAL).toFixed(2))")
echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
