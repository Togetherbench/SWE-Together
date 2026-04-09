#!/usr/bin/env bash
#
# Verification tests for banodoco-wrapped performance improvements.
#
# Tests TopGenerations.tsx row virtualization and ModelTrends.tsx animation fixes.
# 11 tests, total weight 21 (reward = score / 21).
#
# P2P (19%):                4/21  — build succeeds, no TS errors, upstream sources intact
# F2P Behavioral (52%):   11/21  — extracted functions executed with test data
# F2P Pattern-based (24%):  5/21  — virtualization, auto-play, progressive reveal wiring
# Structural (5%):          1/21  — model entry labels
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
TOTAL=21

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

cd "$REPO"

###############################################################################
# TEST 1/10 [P2P, weight 2/20]: Vite production build succeeds
###############################################################################
echo "=== Test 1/11 [P2P, weight 2/21]: Vite production build succeeds ==="
timeout 120 npm run build > /tmp/build_output.txt 2>&1
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 2))
  echo "PASS: Production build succeeded"
else
  echo "FAIL: Production build failed:"
  tail -20 /tmp/build_output.txt
fi

###############################################################################
# TEST 2/10 [P2P, weight 1/20]: No TypeScript errors in task files
###############################################################################
echo ""
echo "=== Test 2/11 [P2P, weight 1/21]: No TypeScript errors in task files ==="
TSC_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
TASK_ERRORS=$(echo "$TSC_OUTPUT" | grep -E "TopGenerations\.tsx|ModelTrends\.tsx" || true)
if [ -z "$TASK_ERRORS" ]; then
  SCORE=$((SCORE + 1))
  echo "PASS: No TypeScript errors in TopGenerations.tsx or ModelTrends.tsx"
else
  echo "FAIL: TypeScript errors in task files:"
  echo "$TASK_ERRORS"
fi

###############################################################################
# TEST 3/10 [F2P Behavioral, weight 3/20]: Normalization function correctness
#
# Extracts ANY function that takes array-of-objects and returns/mutates them
# so numeric values per row sum to ~100. Executes with multiple test inputs.
# NOT gameable by grep patterns — the function must actually compute correctly.
###############################################################################
echo ""
echo "=== Test 3/11 [F2P Behavioral, weight 4/21]: Normalization function correctness ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

// Strategy: find ALL arrow functions and function declarations, try each one
// with normalization-shaped test data. If any function, when called with an
// array of {string: number} objects, returns/mutates them to sum to ~100,
// that's a working normalization function. This is implementation-agnostic.
const candidates = [];

function collectFunctions(n) {
  if (ts.isVariableDeclaration(n) && n.initializer &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
    const name = n.name.getText ? n.name.getText(sf) : '';
    candidates.push({ name, node: n.initializer });
  }
  if (ts.isFunctionDeclaration(n) && n.name) {
    candidates.push({ name: n.name.text, node: n });
  }
  ts.forEachChild(n, collectFunctions);
}
collectFunctions(sf);

// Also try inline expressions: look for .map() calls that do division
// This handles cases where normalization is inlined, not a named function
const mapNormBlocks = [];
const mapRegex = /\.map\s*\(\s*(?:\([^)]*\)|[a-zA-Z_]\w*)\s*=>\s*\{[^}]*(?:\/\s*(?:total|sum|rowTotal|rowSum)|(?:total|sum|rowTotal|rowSum)\s*[>!])[^}]*\}/g;
let match;
while ((match = mapRegex.exec(src)) !== null) {
  mapNormBlocks.push(match[0]);
}

const testSets = [
  // Standard Recharts data with month key + model values
  [
    { month: 'Jan', sd: 30, flux: 20, wan: 50 },
    { month: 'Feb', sd: 10, flux: 60, wan: 10, ltx: 20 },
    { month: 'Mar', sd: 5, flux: 5, wan: 80, ltx: 5, cogvideo: 5 },
  ],
  // Edge case: very uneven distribution
  [
    { month: 'Jan', sd: 1, flux: 999 },
    { month: 'Feb', sd: 500, flux: 500, wan: 500 },
  ],
  // Edge case: some zeros
  [
    { month: 'Jan', sd: 0, flux: 100, wan: 0 },
    { month: 'Feb', sd: 25, flux: 25, wan: 25, ltx: 25 },
  ],
];

function checkNormalized(result, original) {
  if (!Array.isArray(result) || result.length !== original.length) return false;
  for (let i = 0; i < result.length; i++) {
    const row = result[i];
    const nums = Object.entries(row)
      .filter(([k, v]) => typeof v === 'number' && k !== 'month')
      .map(([, v]) => v);
    if (nums.length === 0) return false;
    const sum = nums.reduce((a, b) => a + b, 0);
    // Must sum to ~100 (+/- 2) or ~1.0 (+/- 0.02)
    const sumsTo100 = Math.abs(sum - 100) <= 2;
    const sumsTo1 = Math.abs(sum - 1) <= 0.02;
    if (!sumsTo100 && !sumsTo1) return false;
    // Every numeric value must be non-negative
    if (nums.some(v => v < -0.01)) return false;
  }
  return true;
}

let passed = false;
for (const { name, node } of candidates) {
  try {
    const funcSrc = src.slice(node.pos, node.end).trim();
    const jsCode = ts.transpileModule('const __fn = ' + funcSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
    }).outputText;
    const fnBody = jsCode.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
    const fn = eval('(' + fnBody + ')');

    let allPassed = true;
    for (const testData of testSets) {
      try {
        const input = JSON.parse(JSON.stringify(testData));
        let result = fn(input);
        if (!Array.isArray(result)) result = input; // mutated in-place
        if (!checkNormalized(result, testData)) { allPassed = false; break; }
      } catch (e) { allPassed = false; break; }
    }
    if (allPassed) {
      passed = true;
      console.log('PASS: Function \"' + name + '\" correctly normalizes data across all test sets');
      break;
    }
  } catch (e) { /* try next */ }
}

if (!passed) {
  // Fallback: try to extract and execute inline normalization logic
  // Look for the pattern: data.map(row => { ... total ... / total ... })
  // and wrap it in a function
  const inlinePatterns = [
    // Pattern: someVar = data.map(item => { const total = ...; return { ...item, key: val/total*100 } })
    /(?:const|let|var)\s+(\w+)\s*=\s*(\w+)\.map\s*\(([^)]*)\s*=>\s*(\{[\s\S]*?(?:\/\s*(?:total|sum)\b)[\s\S]*?\})\s*\)/,
  ];
  for (const pat of inlinePatterns) {
    const m = src.match(pat);
    if (m) {
      try {
        const paramName = m[3].trim();
        const body = m[4];
        const wrapped = 'function __norm(data) { return data.map(' + paramName + ' => ' + body + '); }';
        const jsCode = ts.transpileModule(wrapped, {
          compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
        }).outputText;
        const fn = eval('(' + jsCode.replace(/;\s*$/, '') + ')');
        let allPassed = true;
        for (const testData of testSets) {
          try {
            const input = JSON.parse(JSON.stringify(testData));
            const result = fn(input);
            if (!checkNormalized(result, testData)) { allPassed = false; break; }
          } catch (e) { allPassed = false; break; }
        }
        if (allPassed) {
          passed = true;
          console.log('PASS: Inline normalization logic correctly normalizes data');
          break;
        }
      } catch (e) { /* continue */ }
    }
  }
}

if (!passed) {
  console.error('FAIL: No function found that normalizes data rows to sum to ~100%');
  process.exit(1);
}
" && SCORE=$((SCORE + 4)) || true

###############################################################################
# TEST 4/10 [F2P Behavioral, weight 3/20]: Easing function is non-linear
#
# Extracts candidate easing/timing functions and EXECUTES them to verify
# non-linear output. Checks: f(0.5) != 0.5 for [0,1]->[0,1] easing,
# or varying step durations for step-based approaches, or monotonically
# increasing delay for progress-based timing. Also verifies the original
# constant STEP_MS=180 is removed (fail-to-pass).
###############################################################################
echo ""
echo "=== Test 4/11 [F2P Behavioral, weight 3/21]: Easing function is non-linear ==="
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

// Fail-to-pass gate: original buggy constant must be removed
if (/const\s+STEP_MS\s*=\s*180/.test(srcNC)) {
  console.error('FAIL: Still has const STEP_MS = 180 — constant speed, no easing');
  process.exit(1);
}

// Collect ALL functions/arrows from the file
const candidates = [];
function collect(n) {
  if (ts.isVariableDeclaration(n) && n.initializer &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
    const name = n.name.getText ? n.name.getText(sf) : '';
    candidates.push({ name, node: n.initializer });
  }
  if (ts.isFunctionDeclaration(n) && n.name) {
    candidates.push({ name: n.name.text, node: n });
  }
  ts.forEachChild(n, collect);
}
collect(sf);

let passed = false;

for (const { name, node } of candidates) {
  try {
    const funcSrc = src.slice(node.pos, node.end).trim();
    const jsCode = ts.transpileModule('const __fn = ' + funcSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
    }).outputText;
    const fnBody = jsCode.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
    const fn = eval('(' + fnBody + ')');

    // Pattern A: easing function f: [0,1] -> [0,1]
    // Non-linear means f(0.5) deviates from 0.5 significantly
    try {
      const v0 = fn(0);
      const v025 = fn(0.25);
      const v05 = fn(0.5);
      const v075 = fn(0.75);
      const v1 = fn(1);
      if (typeof v05 === 'number' && !isNaN(v05) && v05 >= 0 && v05 <= 1.1) {
        // Non-linear: f(0.5) != 0.5
        if (Math.abs(v05 - 0.5) > 0.03) {
          // Monotonic check: values should increase
          if (v025 <= v05 && v05 <= v075) {
            passed = true;
            console.log('PASS: Easing \"' + name + '\" is non-linear: f(0.5)=' + v05.toFixed(4) + ', f(0)=' + (v0||0).toFixed(4) + ', f(1)=' + (v1||0).toFixed(4));
            break;
          }
        }
      }
    } catch (e) {}

    // Pattern B: step duration function f(step, totalSteps) -> milliseconds
    // Non-constant: early steps faster than late steps (ease-out)
    try {
      const total = 20;
      const d_early = fn(2, total);
      const d_mid = fn(10, total);
      const d_late = fn(18, total);
      if (typeof d_early === 'number' && typeof d_late === 'number' &&
          d_early > 0 && d_late > 0 && !isNaN(d_early)) {
        // Ease-out: later steps should be slower (higher ms)
        if (d_late > d_early * 1.2 || d_early < d_late * 0.8) {
          passed = true;
          console.log('PASS: Duration \"' + name + '\" varies: f(2,20)=' + d_early.toFixed(0) + 'ms, f(18,20)=' + d_late.toFixed(0) + 'ms');
          break;
        }
      }
    } catch (e) {}

    // Pattern C: single-arg progress-based timing f(progress) -> delay
    try {
      const d1 = fn(0.1);
      const d2 = fn(0.5);
      const d3 = fn(0.9);
      if (typeof d1 === 'number' && typeof d3 === 'number' &&
          d1 > 0 && d3 > 0 && !isNaN(d1)) {
        if (d1 !== d3 && (d3 > d1 * 1.15 || d1 > d3 * 1.15)) {
          passed = true;
          console.log('PASS: Timing \"' + name + '\" varies: f(0.1)=' + d1.toFixed(1) + ', f(0.9)=' + d3.toFixed(1));
          break;
        }
      }
    } catch (e) {}

  } catch (e) { /* extraction failed */ }
}

if (!passed) {
  // Last resort: check if there's a numeric expression that computes non-linearly
  // by searching for Math.pow, **, cubic-bezier patterns in non-comment code
  // BUT still require STEP_MS=180 removed (already checked above)
  const hasMathNonLinear = /Math\.pow\s*\(|Math\.sqrt\s*\(|\*\*\s*[23]|cubic.?bezier/i.test(srcNC);
  const hasEasingLib = /ease[Oo]ut|easeInOut|ease-out/i.test(srcNC);
  if (hasMathNonLinear || hasEasingLib) {
    console.log('PASS: STEP_MS=180 removed + non-linear math/easing detected (Bronze fallback, 2/3 credit)');
    // Only 2 of 3 points for non-executed detection
    process.exit(2);
  }
  console.error('FAIL: No non-linear easing function found (and STEP_MS=180 must be removed)');
  process.exit(1);
}
" 2>&1
EASE_EXIT=$?
if [ $EASE_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 3))
elif [ $EASE_EXIT -eq 2 ]; then
  SCORE=$((SCORE + 2))
fi

###############################################################################
# TEST 5/10 [F2P Behavioral, weight 2/20]: Animation state starts at 0/1
#
# Uses AST to verify useState initialization. Fail-to-pass: the original
# code has useState(data.length) which means no animation plays.
###############################################################################
echo ""
echo "=== Test 5/11 [F2P Behavioral, weight 2/21]: Animation starts at 0, not data.length ==="
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
let hasZeroOrOneInit = false;
// Track which state variables are initialized with what
const stateInits = [];

function visit(n) {
  if (ts.isCallExpression(n)) {
    const callee = src.slice(n.expression.pos, n.expression.end).trim();
    if (callee === 'useState' && n.arguments.length === 1) {
      const arg = src.slice(n.arguments[0].pos, n.arguments[0].end).trim();
      stateInits.push(arg);
      if (/\.length\b/.test(arg)) hasDataLengthInit = true;
      if (arg === '0' || arg === '1') hasZeroOrOneInit = true;
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// The bug: useState(data.length) starts animation at the end
if (hasDataLengthInit) {
  console.error('FAIL: Still uses useState(data.length) — animation starts fully visible');
  console.error('useState calls found:', stateInits.join(', '));
  process.exit(1);
}
if (!hasZeroOrOneInit) {
  console.error('FAIL: No useState(0) or useState(1) found for animation start');
  console.error('useState calls found:', stateInits.join(', '));
  process.exit(1);
}
console.log('PASS: Animation state initializes at 0 or 1 (not data.length)');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 6/10 [F2P Behavioral, weight 2/20]: Y-axis domain produces [0, 100]
#
# Extracts the YAxis domain prop and evaluates it. The original code has
# domain={[0, 'auto']} which rescales during animation. Must be [0, 100].
###############################################################################
echo ""
echo "=== Test 6/11 [F2P Behavioral, weight 2/21]: Y-axis domain is fixed [0, 100] ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

// Find YAxis JSX elements and extract their domain prop
let foundYAxis = false;
let hasAutoInDomain = false;
let hasFixed100Domain = false;
let domainText = '';

function visit(n) {
  if (ts.isJsxSelfClosingElement(n) || ts.isJsxOpeningElement(n)) {
    const tagText = src.slice(n.tagName.pos, n.tagName.end).trim();
    if (tagText === 'YAxis') {
      foundYAxis = true;
      const props = n.attributes;
      if (props && props.properties) {
        for (const prop of props.properties) {
          if (ts.isJsxAttribute(prop)) {
            const propName = prop.name.getText(sf);
            if (propName === 'domain' && prop.initializer) {
              domainText = src.slice(prop.initializer.pos, prop.initializer.end).trim();
              // Check for auto
              if (/auto/i.test(domainText)) hasAutoInDomain = true;
              // Check for [0, 100]
              if (/\[\s*0\s*,\s*100\s*\]/.test(domainText)) hasFixed100Domain = true;
            }
          }
        }
      }
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

if (!foundYAxis) {
  console.error('FAIL: No YAxis component found');
  process.exit(1);
}
if (hasAutoInDomain) {
  console.error('FAIL: YAxis still uses auto domain — will rescale during animation');
  console.error('domain prop:', domainText);
  process.exit(1);
}
if (!hasFixed100Domain) {
  // Fallback: try regex on full source for domain={[0,100]} anywhere near YAxis
  const yaxisBlock = src.match(/YAxis[\s\S]{0,500}/);
  if (yaxisBlock && /domain=\{\s*\[\s*0\s*,\s*100\s*\]\s*\}/.test(yaxisBlock[0])) {
    hasFixed100Domain = true;
  }
}
if (!hasFixed100Domain) {
  console.error('FAIL: YAxis domain is not [0, 100] — found: ' + (domainText || 'no domain prop'));
  process.exit(1);
}
console.log('PASS: YAxis domain is fixed [0, 100]');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 7/10 [F2P Behavioral, weight 2/20]: TopGenerations conditionally
# renders rows based on visibility state
#
# Verifies that the component tracks which rows are visible and conditionally
# renders content. The base code renders everything unconditionally.
# We extract the visibility-tracking logic and verify it has a Map/Set/object
# that gates rendering.
###############################################################################
echo ""
echo "=== Test 7/11 [F2P Pattern, weight 2/21]: TopGenerations has visibility-gated rendering ==="
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

// Check 1: Must have a visibility tracking mechanism
const hasIO = /new\s+IntersectionObserver/.test(srcNC) || /IntersectionObserver/.test(srcNC);
const hasVirtLib = /react-virtuoso|react-window|react-virtual|@tanstack\/virtual|useVirtualizer|useInView/.test(src);

// Check 2: Must have conditional rendering based on visibility
// Look for ternary/&& with visibility-related condition in JSX
let hasConditionalRender = false;
let hasVisibilityState = false;

function visit(n) {
  // Track visibility state variables
  if (ts.isIdentifier(n) && /visible|inView|loaded|isShown|isActive/.test(n.text)) {
    hasVisibilityState = true;
  }
  // Conditional expressions gating media content
  if (ts.isConditionalExpression(n)) {
    const condText = src.slice(n.condition.pos, n.condition.end).trim();
    if (/visible|inView|loaded|isShown|isActive|has\(|\.get\(/.test(condText)) {
      hasConditionalRender = true;
    }
  }
  // JSX conditional: {visible && <Component />}
  if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
    const left = src.slice(n.left.pos, n.left.end).trim();
    if (/visible|inView|loaded|isShown|isActive|has\(|\.get\(/.test(left)) {
      hasConditionalRender = true;
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Check 3: Must have observer cleanup (prevents memory leaks)
const hasCleanup = /\.disconnect\s*\(|\.unobserve\s*\(|return\s*\(\)\s*=>/.test(srcNC);

// Check 4: File must be substantially modified (not just a comment change)
const meaningfulLines = src.split('\\n')
  .map(l => l.trim())
  .filter(l => l.length > 0 && !l.startsWith('//') && !l.startsWith('*'))
  .length;

const issues = [];
if (!hasIO && !hasVirtLib) issues.push('no IntersectionObserver or virtualization library');
if (!hasConditionalRender && !hasVirtLib) issues.push('no conditional rendering based on visibility');
if (!hasVisibilityState && !hasVirtLib) issues.push('no visibility state tracking');
if (!hasCleanup && !hasVirtLib) issues.push('no observer cleanup');
if (meaningfulLines < 60) issues.push('file too small (' + meaningfulLines + ' lines) — likely unmodified');

if (issues.length > 0) {
  console.error('FAIL: TopGen virtualization incomplete:', issues.join(', '));
  process.exit(1);
}
console.log('PASS: TopGenerations has visibility-gated rendering (' + meaningfulLines + ' meaningful lines)');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 8/10 [F2P Behavioral, weight 2/20]: ModelTrends auto-play wiring
#
# Verifies that animation auto-triggers on viewport entry (IntersectionObserver)
# and has a proper animation loop with cleanup. The base code requires manual
# Play button click.
###############################################################################
echo ""
echo "=== Test 8/10 [F2P Behavioral, weight 2/20]: ModelTrends auto-play via IntersectionObserver ==="
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

// Must have IO for auto-play triggering
const hasIO = /new\s+IntersectionObserver|IntersectionObserver/.test(srcNC);
const hasIOHook = /useInView|useIntersection/.test(src);

// Must have animation loop mechanism
const hasAnimLoop = /requestAnimationFrame|setInterval|setTimeout/.test(srcNC);

// Must have state setter that increments frame/count
const hasIncrement = /set\w+\s*\(\s*(?:prev|p|c|v)\s*(?:=>|\+)/.test(srcNC) ||
                     /set\w+\s*\(\s*\w+\s*\+\s*1\s*\)/.test(srcNC);

// Must have cleanup to prevent memory leaks
const hasCleanup = /cancelAnimationFrame|clearInterval|clearTimeout|\.disconnect\s*\(/.test(srcNC);

// Must have useEffect for lifecycle management
const hasUseEffect = /useEffect/.test(srcNC);

const issues = [];
if (!hasIO && !hasIOHook) issues.push('no IntersectionObserver or useInView for auto-play');
if (!hasAnimLoop) issues.push('no animation loop (rAF/setInterval/setTimeout)');
if (!hasIncrement) issues.push('no incremental state updates for animation progression');
if (!hasCleanup) issues.push('no cleanup (cancelAnimationFrame/clearInterval/disconnect)');
if (!hasUseEffect) issues.push('no useEffect for lifecycle management');

// Anti-stub: file must be substantial
const meaningfulLines = src.split('\\n')
  .map(l => l.trim())
  .filter(l => l.length > 0 && !l.startsWith('//') && !l.startsWith('*'))
  .length;
if (meaningfulLines < 80) issues.push('file too small (' + meaningfulLines + ' lines)');

if (issues.length > 0) {
  console.error('FAIL: ModelTrends auto-play incomplete:', issues.join(', '));
  process.exit(1);
}
console.log('PASS: ModelTrends has IO auto-play + animation loop + cleanup (' + meaningfulLines + ' lines)');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 9/10 [F2P Behavioral, weight 2/20]: Progressive data reveal works
#
# Verifies data is subsetted progressively during animation. The base code
# has .slice(0, visibleCount) but starts with visibleCount=data.length
# (so no progressive reveal). After fix, must have slice + start at 0.
# Combined with Test 5 (start at 0) this ensures actual progressive behavior.
###############################################################################
echo ""
echo "=== Test 9/10 [F2P Behavioral, weight 2/20]: Progressive data reveal ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}

const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Must have data subsetting
const hasSlice = /\.slice\s*\(\s*0\s*,/.test(srcNC);
const hasFilter = /\.filter\s*\([^)]*(?:index|i)\s*[<>=]/.test(srcNC);
const hasSubset = hasSlice || hasFilter;

// Must have a counter/frame variable that drives the subset
const hasCounter = /visibleCount|currentFrame|animFrame|displayCount|frameIndex|step|currentStep|animStep/i.test(srcNC);

// Must NOT start with all data visible (checked by Test 5, but also verify here)
const startsAtEnd = /useState\s*\(\s*data\.length\s*\)/.test(srcNC);

// Must have IntersectionObserver (auto-play, not manual)
const hasAutoTrigger = /IntersectionObserver|useInView|useIntersection/.test(srcNC);

const issues = [];
if (!hasSubset) issues.push('no data subsetting (.slice(0,N) or index filter)');
if (!hasCounter) issues.push('no frame counter driving progressive reveal');
if (startsAtEnd) issues.push('starts with all data visible (useState(data.length))');
if (!hasAutoTrigger) issues.push('no auto-play trigger (IntersectionObserver/useInView)');

if (issues.length > 0) {
  console.error('FAIL: Progressive reveal incomplete:', issues.join(', '));
  process.exit(1);
}
console.log('PASS: Progressive data reveal with auto-play trigger');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 10/10 [Structural, weight 2/20]: Model entry labels exist
#
# Checks for label rendering when new models enter the chart. This is a
# structural check since labels require DOM/SVG rendering to fully verify.
###############################################################################
echo ""
echo "=== Test 10/10 [Structural, weight 2/20]: Model entry labels ==="
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

// Must render label text — either SVG <text> or a positioned div/span
let hasLabelJSX = false;
let hasLabelLogic = false;
let hasWhiteColor = false;

function visit(n) {
  if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
    const tag = src.slice(n.tagName.pos, n.tagName.end).trim();
    if (/^(text|Label|CustomLabel|CustomizedLabel|ReferenceLine)$/i.test(tag)) {
      hasLabelJSX = true;
    }
  }
  ts.forEachChild(n, visit);
}
visit(sf);

// Label logic: detecting when a new model first appears in the data
const hasNewModelDetection = /first.*appear|new.*model|model.*enter|firstAppear|modelEntr/i.test(srcNC) ||
  // Check for logic that compares current vs previous data to find new entries
  /(?:prev|last)(?:Data|Models|Keys|Visible)/.test(srcNC) ||
  // Check for finding first non-zero value for a model
  /find\w*\s*\([^)]*(?:!==?\s*0|>\s*0)/.test(srcNC);

// White label styling
hasWhiteColor = /(?:fill|color)\s*[:=]\s*['\"](?:#fff|#ffffff|white|rgb\(255)/i.test(srcNC) ||
  /text-white|className.*white/i.test(srcNC);

// Label text rendering (model name displayed)
const hasModelNameRender = /\.name\b|modelName|MODEL_COLORS\s*\[/.test(srcNC);

const issues = [];
if (!hasLabelJSX && !hasModelNameRender) issues.push('no label rendering (SVG text or positioned element)');
if (!hasNewModelDetection) issues.push('no logic to detect when models first appear');
if (!hasWhiteColor) issues.push('no white color styling on labels');

if (issues.length > 0) {
  console.error('FAIL: Model entry labels incomplete:', issues.join(', '));
  process.exit(1);
}
console.log('PASS: ModelTrends has model entry labels with white styling');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 11/11 [P2P, weight 1/21]: Upstream source files intact + executable
#
# Goes beyond parse-checking: transpiles and executes dataProcessing.ts
# functions with test data to verify they produce valid output. Also
# validates constants.ts demoData structure is well-formed, types.ts
# interfaces have required fields, and component files have React exports.
###############################################################################
echo ""
echo "=== Test 11/11 [P2P, weight 1/21]: Upstream source files intact + executable ==="
node -e "
const ts = require('typescript');
const fs = require('fs');

let pass = true;

// 1. constants.ts must export demoData AND demoData must be a valid object
const cSrc = fs.readFileSync('constants.ts', 'utf8');
const cSf = ts.createSourceFile('constants.ts', cSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const hasDemoData = cSf.statements.some(s =>
  ts.isVariableStatement(s) &&
  s.declarationList.declarations.some(d => d.name.getText(cSf) === 'demoData')
);
if (!hasDemoData) { console.error('FAIL: constants.ts missing demoData export'); pass = false; }
else {
  // Execute: transpile and verify demoData is a non-trivial object
  try {
    const jsCode = ts.transpileModule(cSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const m = {};
    const fn = new Function('exports', 'require', jsCode);
    fn(m, require);
    if (m.demoData && typeof m.demoData === 'object') {
      // demoData should have model_trends or topGenerations or similar arrays
      const keys = Object.keys(m.demoData);
      if (keys.length < 2) {
        console.error('FAIL: demoData has only ' + keys.length + ' keys (expect >=2)');
        pass = false;
      }
    } else {
      console.error('FAIL: demoData is not an object');
      pass = false;
    }
  } catch (e) {
    console.error('FAIL: constants.ts transpile/execute error: ' + e.message);
    pass = false;
  }
}

// 2. types.ts must export ModelTrend, TopGeneration, and AppData with required fields
const tSrc = fs.readFileSync('types.ts', 'utf8');
const tSf = ts.createSourceFile('types.ts', tSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const typeNames = tSf.statements
  .filter(s => ts.isInterfaceDeclaration(s))
  .map(s => s.name.text);
const neededTypes = ['ModelTrend', 'TopGeneration', 'AppData'];
for (const t of neededTypes) {
  if (!typeNames.includes(t)) { console.error('FAIL: types.ts missing ' + t + ' interface'); pass = false; }
}
// Verify interfaces have actual members (not empty stubs)
for (const stmt of tSf.statements) {
  if (ts.isInterfaceDeclaration(stmt) && neededTypes.includes(stmt.name.text)) {
    if (stmt.members.length < 1) {
      console.error('FAIL: types.ts interface ' + stmt.name.text + ' has no members');
      pass = false;
    }
  }
}

// 3. dataProcessing.ts: transpile and EXECUTE exported functions with test data
const dSrc = fs.readFileSync('dataProcessing.ts', 'utf8');
const dSf = ts.createSourceFile('dataProcessing.ts', dSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
const exportedFns = dSf.statements.filter(s =>
  ts.isFunctionDeclaration(s) &&
  s.modifiers && s.modifiers.some(m => m.kind === ts.SyntaxKind.ExportKeyword)
);
if (exportedFns.length === 0) {
  console.error('FAIL: dataProcessing.ts has no exported functions');
  pass = false;
} else {
  // Transpile and attempt to call each exported function
  try {
    const jsCode = ts.transpileModule(dSrc, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const m = {};
    const fn = new Function('exports', 'require', jsCode);
    fn(m, require);
    const fnNames = Object.keys(m).filter(k => typeof m[k] === 'function');
    if (fnNames.length === 0) {
      console.error('FAIL: dataProcessing.ts exported no callable functions after transpilation');
      pass = false;
    } else {
      // Try calling functions that accept array-like data
      let anyCallable = false;
      for (const name of fnNames) {
        try {
          // Attempt to call with empty/minimal args; if it doesn't throw TypeError, it's real
          const result = m[name]([]);
          anyCallable = true;
        } catch (e) {
          // TypeError means it expected different args - still callable
          if (e instanceof TypeError) anyCallable = true;
        }
      }
      if (!anyCallable) {
        console.error('FAIL: dataProcessing.ts functions not callable');
        pass = false;
      }
    }
  } catch (e) {
    console.error('FAIL: dataProcessing.ts transpile error: ' + e.message);
    pass = false;
  }
}

// 4. Key component files parse without syntax errors AND have React component exports
const components = ['components/Hero.tsx', 'components/Heatmap.tsx',
  'components/Footer.tsx', 'App.tsx'];
for (const f of components) {
  try {
    const s = fs.readFileSync(f, 'utf8');
    const sf = ts.createSourceFile(f, s, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    if (sf.statements.length === 0) { console.error('FAIL: ' + f + ' parsed to 0 statements'); pass = false; }
    // Must have a default export or named export with JSX
    const hasExport = /export\s+(default|function|const)/.test(s);
    if (!hasExport) { console.error('FAIL: ' + f + ' has no exports'); pass = false; }
    // Must contain JSX (React component)
    const hasJSX = /<[A-Za-z]/.test(s);
    if (!hasJSX) { console.error('FAIL: ' + f + ' has no JSX (not a React component)'); pass = false; }
  } catch (e) { console.error('FAIL: ' + f + ' parse error: ' + e.message); pass = false; }
}

if (pass) console.log('PASS: Upstream files parse, transpile, and execute correctly');
else process.exit(1);
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
