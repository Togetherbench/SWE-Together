#!/bin/bash
#
# Verification tests for banodoco-wrapped performance improvements.
#
# Tests TopGenerations.tsx row virtualization and ModelTrends.tsx animation fixes.
# 15 tests, total weight 35 (reward = score / 35).
#
# P2P Behavioral (3%):      1/35  — upstream sources intact + executable (Test 11)
# P2P gates (0 pts):        0/35  — build diagnostic (Test 1), Test 5, Test 15
# F2P Compilation (20%):    7/35  — tsc + build + core modifications (Test 2)
# F2P Behavioral (29%):    10/35  — extracted functions executed (Tests 3, 4)
# F2P Pattern-based (43%): 15/35  — virtualization, auto-play, progressive reveal,
#                                    animation-completion, Recharts, label-follow
# F2P Structural (6%):      2/35  — model entry labels (Test 10)
#
# Writes reward to /logs/verifier/reward.txt (0.0 to 1.0).
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

SCORE=0
TOTAL=35

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

cd "$REPO"

###############################################################################
# TEST 1/15 [P2P gate, weight 0/30]: Vite production build succeeds
# Zero-weight diagnostic gate. Build result feeds Test 2 and Test 15.
###############################################################################
echo "=== Test 1/15 [P2P gate, weight 0/30]: Vite production build succeeds ==="
timeout 120 npm run build > /tmp/build_output.txt 2>&1
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  echo "PASS (gate): Production build succeeded"
else
  echo "FAIL (gate): Production build failed:"
  tail -20 /tmp/build_output.txt
fi

###############################################################################
# TEST 2/15 [F2P Compilation, weight 7/35]: TypeScript compiles + core modifications
#
# Gate: npx tsc --noEmit must succeed on task files. If it fails, 0/7 points.
# Then checks three F2P conditions (base code fails all three):
#   +3 pts: IntersectionObserver present in either task file (base has none)
#   +2 pts: useState(data.length) removed from ModelTrends (base has it)
#   +2 pts: const STEP_MS = 180 removed from ModelTrends (base has it)
###############################################################################
echo ""
echo "=== Test 2/15 [F2P Compilation, weight 7/35]: TypeScript compiles + core modifications ==="
TSC_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
TASK_ERRORS=$(echo "$TSC_OUTPUT" | grep -E "TopGenerations\.tsx|ModelTrends\.tsx" || true)
T2_SCORE=0
if [ -n "$TASK_ERRORS" ]; then
  echo "FAIL (gate): TypeScript errors in task files — 0/6:"
  echo "$TASK_ERRORS"
elif [ $BUILD_EXIT -ne 0 ]; then
  echo "FAIL (gate): Production build failed — 0/6"
else
  echo "PASS (gate): tsc + build both succeed"
  # F2P condition 1: IntersectionObserver present (base has none)
  if grep -qE 'IntersectionObserver|useInView|useIntersection' "$TOP_GEN" "$MODEL_TRENDS" 2>/dev/null; then
    T2_SCORE=$((T2_SCORE + 3))
    echo "  +3: IntersectionObserver present"
  else
    echo "  +0: No IntersectionObserver in task files"
  fi
  # F2P condition 2: useState(data.length) removed (base has it)
  if ! grep -qE 'useState\s*\(\s*data\.length' "$MODEL_TRENDS" 2>/dev/null; then
    T2_SCORE=$((T2_SCORE + 2))
    echo "  +2: useState(data.length) removed"
  else
    echo "  +0: Still has useState(data.length)"
  fi
  # F2P condition 3: STEP_MS = 180 removed (base has it)
  if ! grep -qE 'const\s+STEP_MS\s*=\s*180' "$MODEL_TRENDS" 2>/dev/null; then
    T2_SCORE=$((T2_SCORE + 2))
    echo "  +2: const STEP_MS = 180 removed"
  else
    echo "  +0: Still has const STEP_MS = 180"
  fi
fi
SCORE=$((SCORE + T2_SCORE))
echo "  Test 2 subtotal: $T2_SCORE/7"

###############################################################################
# TEST 3/15 [F2P Behavioral, weight 4/30]: Normalization function correctness
#
# Extracts ANY function that takes array-of-objects and returns/mutates them
# so numeric values per row sum to ~100. Executes with multiple test inputs.
# NOT gameable by grep patterns — the function must actually compute correctly.
###############################################################################
echo ""
echo "=== Test 3/15 [F2P Behavioral, weight 4/30]: Normalization function correctness ==="
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

// Also collect arrow functions passed as arguments (useMemo, useCallback callbacks)
// This catches normalization implemented inside useMemo(() => data.map(...), [data])
function collectCallbacks(n) {
  if (ts.isCallExpression(n)) {
    const calleeName = src.slice(n.expression.pos, n.expression.end).trim();
    for (let i = 0; i < n.arguments.length; i++) {
      const arg = n.arguments[i];
      if (ts.isArrowFunction(arg) || ts.isFunctionExpression(arg)) {
        candidates.push({ name: calleeName + '_cb', node: arg });
      }
    }
  }
  ts.forEachChild(n, collectCallbacks);
}
collectCallbacks(sf);

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
  // Strategy 2: For 0-param functions (useMemo callbacks), inject data parameter
  // Handles: useMemo(() => { return data.map(...normalize...) }, [data])
  for (const { name, node } of candidates) {
    if (passed) break;
    try {
      const params = node.parameters || [];
      if (params.length !== 0) continue;
      const funcSrc = src.slice(node.pos, node.end).trim();
      if (!/\.map\s*\(/.test(funcSrc) || !/\//.test(funcSrc)) continue;
      const dataVarMatch = funcSrc.match(/\b(data|processedData|chartData|rawData|items|rows|trends|trendData|monthlyData|sortedData|filteredData|modelData|trendingData|inputData|sourceData|allData|records|entries|values|stats|dataset|datasets|results|normalized)\b/);
      if (!dataVarMatch) continue;
      const dataVar = dataVarMatch[1];
      let modifiedSrc = funcSrc;
      if (/^\(\s*\)\s*=>/.test(modifiedSrc)) {
        modifiedSrc = modifiedSrc.replace(/^\(\s*\)\s*=>/, '(' + dataVar + ') =>');
      } else if (/^function\s*\(\s*\)/.test(modifiedSrc)) {
        modifiedSrc = modifiedSrc.replace(/^function\s*\(\s*\)/, 'function(' + dataVar + ')');
      } else continue;
      const jsCode = ts.transpileModule('const __fn = ' + modifiedSrc, {
        compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
      }).outputText;
      const fnBody = jsCode.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
      const fn = eval('(' + fnBody + ')');
      let allPassed = true;
      for (const testData of testSets) {
        try {
          const input = JSON.parse(JSON.stringify(testData));
          let result = fn(input);
          if (!Array.isArray(result)) result = input;
          if (!checkNormalized(result, testData)) { allPassed = false; break; }
        } catch (e) { allPassed = false; break; }
      }
      if (allPassed) {
        passed = true;
        console.log('PASS: Normalization in \"' + name + '\" (parameter injection)');
      }
    } catch (e) { /* try next */ }
  }
}

if (!passed) {
  // Strategy 3: Extract .map() callbacks directly from AST
  // Handles inline normalization where the map callback is self-contained
  function findMapNorm(n) {
    if (passed) return;
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) &&
        n.expression.name.text === 'map' && n.arguments.length >= 1) {
      const callback = n.arguments[0];
      if (ts.isArrowFunction(callback) || ts.isFunctionExpression(callback)) {
        const callbackSrc = src.slice(callback.pos, callback.end).trim();
        if (!/\//.test(callbackSrc)) { ts.forEachChild(n, findMapNorm); return; }
        try {
          const paramSrc = callback.parameters.map(p => src.slice(p.pos, p.end).trim()).join(', ');
          const bodySrc = src.slice(callback.body.pos, callback.body.end).trim();
          const isBlock = bodySrc.startsWith('{');
          const wrapped = isBlock
            ? 'function __norm(__data) { return __data.map((' + paramSrc + ') => ' + bodySrc + '); }'
            : 'function __norm(__data) { return __data.map((' + paramSrc + ') => (' + bodySrc + ')); }';
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
            console.log('PASS: .map() callback correctly normalizes data');
            return;
          }
        } catch (e) { /* continue */ }
      }
    }
    ts.forEachChild(n, findMapNorm);
  }
  findMapNorm(sf);
}

if (!passed) {
  // Strategy 4: Re-try candidates with extracted constants from the file
  // Handles normalization inside useMemo that references MODEL_KEYS, MODEL_COLORS, etc.
  // Extract constant arrays/objects from the file that the normalization might reference
  var constDecls = [];
  function collectConsts(n) {
    if (ts.isVariableStatement(n)) {
      for (var d of n.declarationList.declarations) {
        if (d.initializer && d.name.getText) {
          var vn = d.name.getText(sf);
          // Only extract simple constants (arrays, objects, primitives)
          if (/^[A-Z_]/.test(vn) || /keys|models|colors|names/i.test(vn)) {
            var initSrc = src.slice(d.initializer.pos, d.initializer.end).trim();
            // Skip if it references imports/JSX/hooks (but allow TS generics like Array<>)
            if (!/import|require|use[A-Z]|<[A-Z][a-z]/.test(initSrc) && initSrc.length < 500) {
              constDecls.push('var ' + vn + ' = ' + initSrc + ';');
            }
          }
        }
      }
    }
    ts.forEachChild(n, collectConsts);
  }
  collectConsts(sf);
  // Transpile constants to JS (removes TypeScript type annotations)
  var rawPreamble = constDecls.join('\n');
  var constPreamble = '';
  try {
    constPreamble = ts.transpileModule(rawPreamble, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
    }).outputText;
  } catch (e) { constPreamble = rawPreamble; }

  for (var ci = 0; ci < candidates.length; ci++) {
    if (passed) break;
    var c = candidates[ci];
    try {
      var funcSrc = src.slice(c.node.pos, c.node.end).trim();
      if (!/\//.test(funcSrc) || !/\.map\s*\(/.test(funcSrc)) continue;
      var params = c.node.parameters || [];
      var modifiedSrc = funcSrc;
      if (params.length === 0) {
        var dvMatch = funcSrc.match(/\b(data|processedData|chartData|rawData|items|rows|trends|trendData|monthlyData|sortedData|filteredData|modelData|trendingData|inputData|sourceData|allData|records|entries|values|stats|dataset|datasets|results|normalized)\b/);
        if (!dvMatch) continue;
        var dv = dvMatch[1];
        if (/^\(\s*\)\s*=>/.test(modifiedSrc)) {
          modifiedSrc = modifiedSrc.replace(/^\(\s*\)\s*=>/, '(' + dv + ') =>');
        } else continue;
      }
      var jsC = ts.transpileModule('const __fn = ' + modifiedSrc, {
        compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React }
      }).outputText;
      var fnB = jsC.replace(/^[^=]+=\s*/, '').replace(/;\s*$/, '');
      var wrappedCode = '(function(__input){' + constPreamble + ' var fn=(' + fnB + '); return fn(__input);})';
      var stubbedFn = eval(wrappedCode);
      var allP = true;
      for (var ti = 0; ti < testSets.length; ti++) {
        try {
          var inp = JSON.parse(JSON.stringify(testSets[ti]));
          var res = stubbedFn(inp);
          if (!Array.isArray(res)) res = inp;
          if (!checkNormalized(res, testSets[ti])) { allP = false; break; }
        } catch (e) { allP = false; break; }
      }
      if (allP) {
        passed = true;
        console.log('PASS: Function \"' + c.name + '\" normalizes data (with extracted constants)');
      }
    } catch (e) { /* try next */ }
  }
}

if (!passed) {
  // Strategy 5: try to extract and execute inline normalization logic
  // Look for the pattern: data.map(row => { ... total ... / total ... })
  // and wrap it in a function
  const inlinePatterns = [
    // Pattern: someVar = data.map(item => { const total = ...; return { ...item, key: val/total*100 } })
    /(?:const|let|var)\s+(\w+)\s*=\s*(\w+)\.map\s*\(([^)]*)\s*=>\s*(\{[\s\S]*?(?:\/\s*(?:total|sum|rowTotal|rowSum|t|count|allTotal)\b)[\s\S]*?\})\s*\)/,
    // Pattern: return data.map(item => { ... / total ... }) inside useMemo or function body
    /return\s+(\w+)\.map\s*\(([^)]*)\s*=>\s*(\{[\s\S]*?(?:\/\s*(?:total|sum|rowTotal|rowSum|t|count|allTotal)\b)[\s\S]*?\})\s*\)/,
  ];
  for (const pat of inlinePatterns) {
    const m = src.match(pat);
    if (m) {
      try {
        const paramName = (m[4] ? m[3] : m[2]).trim();
        const body = m[4] || m[3];
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
  // Bronze fallback: regex-based detection of normalization patterns in non-comment code
  // Awards 2/4 points when normalization logic is present but cannot be extracted/executed
  const srcNC = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  const hasDivision = /\/\s*(?:total|sum|rowTotal|rowSum|t)\b/.test(srcNC) ||
                      /(?:total|sum|rowTotal|rowSum)\s*[>!=]/.test(srcNC);
  const hasMultBy100 = /\*\s*100/.test(srcNC);
  const hasPercentCalc = hasDivision && hasMultBy100;
  const hasNormalizeRef = /normaliz/i.test(srcNC);
  const hasMapReduce = /\.map\s*\(/.test(srcNC) && (/\.reduce\s*\(/.test(srcNC) || /Object\.values/.test(srcNC) || /Object\.entries/.test(srcNC));
  const hasSumCalc = /\.reduce\s*\(\s*\(?[^)]*\+/.test(srcNC) || /Object\.values\s*\([^)]*\)\.reduce/.test(srcNC);

  if ((hasPercentCalc || (hasNormalizeRef && hasDivision)) && (hasMapReduce || hasSumCalc)) {
    // Silver tier (3/4): normalization pattern present AND connected to chart data flow
    // Check that normalized data is assigned to a variable used in rendering
    const hasChartDataFlow = /normaliz\w*Data|normaliz\w*\s*=|\.map\s*\([^)]*\/\s*(?:total|sum)[\s\S]{0,500}(?:AreaChart|Area\s|data=)/s.test(srcNC) ||
      /(?:const|let|var)\s+\w*(?:normal|percent|scaled)\w*\s*=[\s\S]{0,1000}(?:AreaChart|data=)/s.test(srcNC) ||
      /useMemo[\s\S]{0,200}(?:\/\s*(?:total|sum)|normaliz)/s.test(srcNC);
    if (hasChartDataFlow) {
      console.log('PASS: Normalization patterns detected + data flow to chart — Silver fallback, 3/4 credit');
      process.exit(3);
    }
    console.log('PASS: Normalization patterns detected (division by total + map/reduce) — Bronze fallback, 2/4 credit');
    process.exit(2);
  }
  console.error('FAIL: No function found that normalizes data rows to sum to ~100%');
  process.exit(1);
}
" 2>&1
NORM_EXIT=$?
if [ $NORM_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 4))
elif [ $NORM_EXIT -eq 3 ]; then
  SCORE=$((SCORE + 3))
elif [ $NORM_EXIT -eq 2 ]; then
  SCORE=$((SCORE + 2))
fi
true

###############################################################################
# TEST 4/15 [F2P Behavioral, weight 6/35]: Easing function is non-linear
#
# Extracts candidate easing/timing functions and EXECUTES them to verify
# non-linear output. Checks: f(0.5) != 0.5 for [0,1]->[0,1] easing,
# or varying step durations for step-based approaches, or monotonically
# increasing delay for progress-based timing. Also verifies the original
# constant STEP_MS=180 is removed (fail-to-pass).
###############################################################################
echo ""
echo "=== Test 4/15 [F2P Behavioral, weight 6/35]: Easing function is non-linear ==="
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
  SCORE=$((SCORE + 6))
elif [ $EASE_EXIT -eq 2 ]; then
  SCORE=$((SCORE + 2))
fi

###############################################################################
# TEST 5/15 [F2P diagnostic, weight 0/30]: Animation state starts at 0/1
#
# Diagnostic only (core check moved to Test 2). Uses AST to verify useState
# initialization. Fail-to-pass: the original code has useState(data.length).
###############################################################################
echo ""
echo "=== Test 5/15 [F2P diagnostic, weight 0/30]: Animation starts at 0, not data.length ==="
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
" || true
# Weight 0: diagnostic only, core check is in Test 2

###############################################################################
# TEST 6/15 [F2P Behavioral, weight 2/30]: Y-axis domain produces [0, 100]
#
# Extracts the YAxis domain prop and evaluates it. The original code has
# domain={[0, 'auto']} which rescales during animation. Must be [0, 100].
###############################################################################
echo ""
echo "=== Test 6/15 [F2P Behavioral, weight 2/30]: Y-axis domain is fixed [0, 100] ==="
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
# TEST 7/15 [F2P Pattern, weight 2/30]: TopGenerations conditionally
# renders rows based on visibility state
#
# Verifies that the component tracks which rows are visible and conditionally
# renders content. The base code renders everything unconditionally.
# We extract the visibility-tracking logic and verify it has a Map/Set/object
# that gates rendering.
###############################################################################
echo ""
echo "=== Test 7/15 [F2P Pattern, weight 2/30]: TopGenerations has visibility-gated rendering ==="
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
  if (ts.isIdentifier(n) && /visible|inView|loaded|isShown|isActive|isIntersecting|shouldRender|isObserved|isOnScreen|showing|rendered|isVisible/.test(n.text)) {
    hasVisibilityState = true;
  }
  // Conditional expressions gating media content
  if (ts.isConditionalExpression(n)) {
    const condText = src.slice(n.condition.pos, n.condition.end).trim();
    if (/visible|inView|loaded|isShown|isActive|isIntersecting|shouldRender|isObserved|isOnScreen|showing|rendered|isVisible|has\(|\.get\(/.test(condText)) {
      hasConditionalRender = true;
    }
  }
  // JSX conditional: {visible && <Component />}
  if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken) {
    const left = src.slice(n.left.pos, n.left.end).trim();
    if (/visible|inView|loaded|isShown|isActive|isIntersecting|shouldRender|isObserved|isOnScreen|showing|rendered|isVisible|has\(|\.get\(/.test(left)) {
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

// Partial credit scoring: 0-2 points
let t7score = 0;
const issues = [];

// Gate: file must be substantially modified
if (meaningfulLines < 60) {
  issues.push('file too small (' + meaningfulLines + ' lines) — likely unmodified');
} else {
  // 1 pt: Has visibility mechanism (IO or virt library)
  if (hasIO || hasVirtLib) {
    t7score += 1;
    console.log('  +1: Has IntersectionObserver or virtualization library');
  } else {
    issues.push('no IntersectionObserver or virtualization library');
  }

  // 1 pt: Has conditional rendering + state + cleanup (full wiring)
  const fullWiring = (hasConditionalRender || hasVirtLib) &&
                     (hasVisibilityState || hasVirtLib) &&
                     (hasCleanup || hasVirtLib);
  if (fullWiring) {
    t7score += 1;
    console.log('  +1: Has conditional rendering + visibility state + cleanup');
  } else {
    if (!hasConditionalRender && !hasVirtLib) issues.push('no conditional rendering based on visibility');
    if (!hasVisibilityState && !hasVirtLib) issues.push('no visibility state tracking');
    if (!hasCleanup && !hasVirtLib) issues.push('no observer cleanup');
  }
}

if (t7score === 0) {
  console.error('FAIL: TopGen virtualization incomplete:', issues.join(', '));
  process.exit(1);
} else if (t7score === 1) {
  console.log('PARTIAL (1/2): TopGen has visibility mechanism but incomplete wiring');
  console.log('  Missing:', issues.join(', '));
  process.exit(2);
} else {
  console.log('PASS: TopGenerations has visibility-gated rendering (' + meaningfulLines + ' meaningful lines)');
}
" 2>&1
T7_EXIT=$?
if [ $T7_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 2))
elif [ $T7_EXIT -eq 2 ]; then
  SCORE=$((SCORE + 1))
fi
true

###############################################################################
# TEST 8/15 [F2P Pattern, weight 3/30]: ModelTrends auto-play wiring
#
# Verifies that animation auto-triggers on viewport entry (IntersectionObserver)
# and has a proper animation loop with cleanup. The base code requires manual
# Play button click.
###############################################################################
echo ""
echo "=== Test 8/15 [F2P Pattern, weight 3/30]: ModelTrends auto-play via IntersectionObserver ==="
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

// Must have state setter that increments frame/count (or ref-based increment + setState)
const hasIncrement = /set\w+\s*\(\s*\w+\s*=>/.test(srcNC) ||
                     /set\w+\s*\([^)]*\+/.test(srcNC) ||
                     /set\w+\s*\(\s*\w+\s*\+\s*1\s*\)/.test(srcNC) ||
                     // Ref-based animation: increment on ref then call setState
                     (/\.\w+\s*\+=\s*1/.test(srcNC) && /set\w+/.test(srcNC)) ||
                     // Ref-based with separate variable: next = curr + 1; ref.current = next; setState(next)
                     (/\+\s*1/.test(srcNC) && /\.current\s*=/.test(srcNC) && /set\w+/.test(srcNC));

// Must have cleanup to prevent memory leaks
const hasCleanup = /cancelAnimationFrame|clearInterval|clearTimeout|\.disconnect\s*\(/.test(srcNC);

// Must have useEffect for lifecycle management
const hasUseEffect = /useEffect/.test(srcNC);

// Anti-stub: file must be substantial
const meaningfulLines = src.split('\\n')
  .map(l => l.trim())
  .filter(l => l.length > 0 && !l.startsWith('//') && !l.startsWith('*'))
  .length;

// Partial credit scoring: 0-3 points
// GATE: IntersectionObserver is REQUIRED for any points (F2P: base code has no IO)
let t8score = 0;
const issues = [];

if (meaningfulLines < 80) {
  issues.push('file too small (' + meaningfulLines + ' lines)');
} else if (!hasIO && !hasIOHook) {
  issues.push('no IntersectionObserver or useInView for auto-play (required gate)');
} else {
  // 1 pt: Has IntersectionObserver or useInView for auto-play triggering
  t8score += 1;
  console.log('  +1: Has IntersectionObserver/useInView for auto-play');

  // 1 pt: Has animation loop + state increment (core animation mechanism)
  if (hasAnimLoop && hasIncrement) {
    t8score += 1;
    console.log('  +1: Has animation loop + state increment');
  } else {
    if (!hasAnimLoop) issues.push('no animation loop (rAF/setInterval/setTimeout)');
    if (!hasIncrement) issues.push('no incremental state updates for animation progression');
  }

  // 1 pt: Has cleanup + useEffect lifecycle management (quality/correctness)
  if (hasCleanup && hasUseEffect) {
    t8score += 1;
    console.log('  +1: Has cleanup + useEffect lifecycle management');
  } else {
    if (!hasCleanup) issues.push('no cleanup (cancelAnimationFrame/clearInterval/disconnect)');
    if (!hasUseEffect) issues.push('no useEffect for lifecycle management');
  }
}

if (t8score === 0) {
  console.error('FAIL: ModelTrends auto-play incomplete:', issues.join(', '));
  process.exit(1);
} else if (t8score < 3) {
  console.log('PARTIAL (' + t8score + '/3): ModelTrends auto-play partially implemented');
  if (issues.length > 0) console.log('  Missing:', issues.join(', '));
  // Exit with code = 10 + partial score to communicate to shell
  process.exit(10 + t8score);
} else {
  console.log('PASS: ModelTrends has IO auto-play + animation loop + cleanup (' + meaningfulLines + ' lines)');
}
" 2>&1
T8_EXIT=$?
if [ $T8_EXIT -eq 0 ]; then
  SCORE=$((SCORE + 3))
elif [ $T8_EXIT -eq 11 ]; then
  SCORE=$((SCORE + 1))
elif [ $T8_EXIT -eq 12 ]; then
  SCORE=$((SCORE + 2))
fi
true

###############################################################################
# TEST 9/15 [F2P Pattern, weight 3/30]: Progressive data reveal works
#
# Verifies data is subsetted progressively during animation. The base code
# has .slice(0, visibleCount) but starts with visibleCount=data.length
# (so no progressive reveal). After fix, must have slice + start at 0.
# Combined with Test 5 (start at 0) this ensures actual progressive behavior.
###############################################################################
echo ""
echo "=== Test 9/15 [F2P Pattern, weight 3/30]: Progressive data reveal ==="
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
" && SCORE=$((SCORE + 3)) || true

###############################################################################
# TEST 10/15 [F2P Structural, weight 2/30]: Model entry labels exist
#
# Checks for label rendering when new models enter the chart. This is a
# structural check since labels require DOM/SVG rendering to fully verify.
###############################################################################
echo ""
echo "=== Test 10/15 [F2P Structural, weight 2/30]: Model entry labels ==="
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
// Use code-level patterns (variable names, function calls) — not English prose in JSX
const hasNewModelDetection = /firstAppear|modelEntr|newModel|entryPoint|labelPos/i.test(srcNC) ||
  // Check for logic that compares current vs previous data to find new entries
  /(?:prev|last)(?:Data|Models|Keys|Visible|Val|Value|Item|Entry)/i.test(srcNC) ||
  // Check for finding first non-zero value for a model (code pattern, not prose)
  /find(?:Index)?\s*\(\s*(?:\([^)]*\)|[a-zA-Z_]\w*)\s*=>[^)]*(?:!==?\s*0|>\s*0)/.test(srcNC) ||
  // Check for iterating keys/entries to detect model appearances
  /Object\.(?:keys|entries)\s*\([^)]*\)\.(?:filter|find|some)/.test(srcNC) ||
  // Check for curr/prev value comparison to detect model first appearance
  /(?:curr|current)\w*\s*>\s*0\s*&&\s*(?:prev|last)\w*\s*(?:===?|!==?)\s*0/.test(srcNC) ||
  // Check for for-of loop over model keys
  /for\s*\(\s*(?:const|let|var)\s+\w+\s+of\s+(?:MODEL_KEYS|modelKeys|keys)/i.test(srcNC);

// White label styling — must be in a label-specific context (fill for SVG, or positioned overlay)
// Exclude tooltip-only white text by requiring label JSX or positioned container
const hasWhiteFill = /fill\s*[:=]\s*['\"](?:#fff|#ffffff|white|rgb\(255)/i.test(srcNC);
const hasWhiteText = /text-white|color\s*[:=]\s*['\"](?:#fff|#ffffff|white)/i.test(srcNC);
// Only count white styling if there is label-related JSX or positioned overlay for labels
const hasPositionedOverlay = /absolute|position\s*:\s*['\"]absolute/i.test(srcNC) && /label|model.*name|entry.*name/i.test(srcNC);
hasWhiteColor = (hasLabelJSX && (hasWhiteFill || hasWhiteText)) || (hasPositionedOverlay && hasWhiteText);

// Label text rendering (model name displayed) — must be in label context, not just tooltip
// Require MODEL_COLORS lookup or explicit label/modelName variable, not just .name on tooltip entry
const hasModelNameRender = /modelName|MODEL_COLORS\s*\[/.test(srcNC) ||
  (hasLabelJSX && /\.name\b/.test(srcNC)) ||
  // Also accept positioned overlay with model name iteration (destructured from MODEL_COLORS)
  (hasPositionedOverlay && hasNewModelDetection && /\.name\b/.test(srcNC));

const issues = [];
if (!hasLabelJSX && !hasModelNameRender) issues.push('no label rendering (SVG text or positioned element)');
if (!hasNewModelDetection && !hasLabelJSX) issues.push('no logic to detect when models first appear');
if (!hasWhiteColor) issues.push('no white color styling on labels');

if (issues.length > 0) {
  console.error('FAIL: Model entry labels incomplete:', issues.join(', '));
  process.exit(1);
}
console.log('PASS: ModelTrends has model entry labels with white styling');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 11/15 [P2P Behavioral, weight 1/30]: Upstream source files intact + executable
#
# Goes beyond parse-checking: transpiles and executes dataProcessing.ts
# functions with test data to verify they produce valid output. Also
# validates constants.ts demoData structure is well-formed, types.ts
# interfaces have required fields, and component files have React exports.
###############################################################################
echo ""
echo "=== Test 11/15 [P2P Behavioral, weight 1/30]: Upstream source files intact + executable ==="
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
# TEST 12/15 [F2P Pattern, weight 1/30]: Animation loop reaches data.length
#
# Covers turn T3/T4 ("animation doesn't run the whole way / completes too early").
# Gate: IntersectionObserver must be present (F2P: base code has none).
# Then checks that animation stop condition uses data.length without truncation.
###############################################################################
echo ""
echo "=== Test 12/15 [F2P Pattern, weight 1/30]: Animation loop reaches data.length ==="
node -e "
const fs = require('fs');
if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}
const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const srcNC = src.replace(/\/\/.*\$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// F2P gate: IntersectionObserver must be present (base code has none)
if (!/IntersectionObserver|useInView|useIntersection/.test(srcNC)) {
  console.error('FAIL: no IntersectionObserver — animation infrastructure not added');
  process.exit(1);
}

// Reject truncating comparison: anything like '<=? someData.length - 1' in conditions.
// Broadened to accept any variable name (data, normalizedData, chartData, etc.)
const truncatingPattern = /(?:<|<=|>=|>|===|!==|==|!=)\s*\w+\.length\s*-\s*1\b/;
const hasTruncation = truncatingPattern.test(srcNC);

// Require at least one comparison with anyVar.length that is NOT decremented.
// Accepts: normalizedData.length, data.length, chartData.length, etc.
const reachesFullPattern = /(?:<|<=|>=|>|===|!==)\s*\w+\.length(?!\s*-\s*1)/;
const reachesFull = reachesFullPattern.test(srcNC);

if (hasTruncation) {
  console.error('FAIL: animation loop still truncates with data.length - 1');
  process.exit(1);
}
if (!reachesFull) {
  console.error('FAIL: no comparison with data.length found that would let the animation reach the end');
  process.exit(1);
}
console.log('PASS: animation stop condition reaches data.length (no data.length-1 truncation)');
" && SCORE=$((SCORE + 1)) || true

###############################################################################
# TEST 13/15 [F2P Pattern, weight 2/35]: Recharts internal animation mitigated
#
# Covers turn T5 ("is there a max duration on the animation?"). Root cause was
# Recharts' default ~1500ms animation fighting the custom frame loop. The fix
# disables internal animation (isAnimationActive={false}) or sets a short
# animationDuration (so the per-frame updates are effectively instant).
###############################################################################
echo ""
echo "=== Test 13/15 [F2P Pattern, weight 2/35]: Recharts internal animation disabled/minimized ==="
node -e "
const fs = require('fs');
if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}
const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const srcNC = src.replace(/\/\/.*\$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Accept any of: isAnimationActive={false}, isAnimationActive = false,
// animationDuration={<short>} (anything <= 500ms counts as mitigated).
const disabled = /isAnimationActive\s*=\s*\{?\s*false\s*\}?/.test(srcNC);
const shortDurMatch = srcNC.match(/animationDuration\s*=\s*\{?\s*(\d+)\s*\}?/);
let shortDur = false;
if (shortDurMatch) {
  const ms = parseInt(shortDurMatch[1], 10);
  if (!isNaN(ms) && ms <= 500) shortDur = true;
}

if (!disabled && !shortDur) {
  console.error('FAIL: Recharts internal animation not mitigated (no isAnimationActive={false} and no short animationDuration<=500ms)');
  process.exit(1);
}
console.log('PASS: Recharts internal animation mitigated (' + (disabled ? 'isAnimationActive=false' : 'animationDuration<=500ms') + ')');
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 14/15 [F2P Pattern, weight 2/30]: Labels track animation frame (follow X-axis)
#
# Covers turn 16 ('make it last long and \"follow\" the centre of that model
# along the X axis'). The fix computes per-label x positions that depend on the
# current animation frame/step. This check requires that label position data
# is computed from an animation state variable (not a static per-model value).
###############################################################################
echo ""
echo "=== Test 14/15 [F2P Pattern, weight 2/30]: Label positions track animation frame ==="
node -e "
const ts = require('typescript');
const fs = require('fs');
if (!fs.existsSync('$MODEL_TRENDS')) {
  console.error('FAIL: ModelTrends.tsx not found');
  process.exit(1);
}
const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const srcNC = src.replace(/\/\/.*\$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

// Locate an activeLabels/modelLabels-style derivation. Common names used by
// agents: activeLabels, visibleLabels, modelLabels, entryLabels, labels.
const labelVarMatch = srcNC.match(/(?:const|let|var)\s+(activeLabels|visibleLabels|modelLabels|entryLabels|labelData|labels|labelPositions|displayLabels)\s*=/);
const animStateVars = /(visibleCount|currentStep|currentFrame|animFrame|frameIndex|animStep|displayCount|step|frame)/;

// Primary signal: the labels derivation (or a function that returns labels)
// references an animation state variable. Robust to variable naming.
let passed = false;
let reason = '';

if (labelVarMatch) {
  // Grab the block containing the label variable's initializer (heuristic: next ~800 chars).
  const idx = srcNC.indexOf(labelVarMatch[0]);
  const snippet = srcNC.slice(idx, idx + 1200);
  if (animStateVars.test(snippet)) {
    passed = true;
    reason = labelVarMatch[1] + ' references animation state (' + snippet.match(animStateVars)[1] + ')';
  }
}

// Secondary signal: a useMemo/useEffect whose deps include an anim var AND
// the body references 'label' or 'Label'. This catches inline label position
// computation inside a memo hook.
if (!passed) {
  const memoRe = /useMemo\s*\(\s*\(\s*\)\s*=>\s*\{[\s\S]{0,2000}?\}\s*,\s*\[[^\]]*\b(visibleCount|currentStep|currentFrame|animFrame|frameIndex|animStep|displayCount)\b[^\]]*\]\s*\)/g;
  let m;
  while ((m = memoRe.exec(srcNC)) !== null) {
    if (/label|Label/i.test(m[0])) {
      passed = true;
      reason = 'useMemo with anim-state deps computes labels';
      break;
    }
  }
}

// Tertiary signal: JSX label element with an x prop whose value is a dynamic
// expression referencing an anim var (e.g., <text x={visibleCount * width}>).
if (!passed) {
  const jsxRe = /<(?:text|Label|CustomLabel|CustomizedLabel|div|span)\b[^>]*\bx\s*=\s*\{([^}]+)\}/g;
  let m;
  while ((m = jsxRe.exec(src)) !== null) {
    if (animStateVars.test(m[1])) {
      passed = true;
      reason = 'JSX label element has x prop driven by animation state';
      break;
    }
  }
}

if (!passed) {
  console.error('FAIL: no label positioning logic that tracks the animation frame (turn 16: labels should follow the centre along X)');
  process.exit(1);
}
console.log('PASS: ' + reason);
" && SCORE=$((SCORE + 2)) || true

###############################################################################
# TEST 15/15 [P2P diagnostic, weight 0/30]: No forward-reference runtime errors
#
# Diagnostic only (zero-weight). Covers turn 11/17 (ReferenceError: Cannot
# access 'displayData' before initialization). Checks build success + no
# forward references in hook declarations.
###############################################################################
echo ""
echo "=== Test 15/15 [P2P diagnostic, weight 0/30]: No forward-reference runtime errors ==="
if [ "$BUILD_EXIT" = "0" ] && [ -z "$TASK_ERRORS" ]; then
  # Additionally scan the file for a known-bad ordering pattern: a useMemo/useState
  # hook whose initializer references a variable declared later in the file.
  node -e "
const ts = require('typescript');
const fs = require('fs');
if (!fs.existsSync('$MODEL_TRENDS')) { process.exit(1); }
const src = fs.readFileSync('$MODEL_TRENDS', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

// Collect top-level-in-component declarations (position → name).
const declPos = {};
function collect(n) {
  if (ts.isVariableDeclaration(n) && n.name && n.name.getText) {
    const nm = n.name.getText(sf);
    if (/^[a-z_][\w]*\$/.test(nm) && !(nm in declPos)) declPos[nm] = n.pos;
  }
  ts.forEachChild(n, collect);
}
collect(sf);

// Check: for hot candidate names used in session bugs, verify they're defined
// before any identifier reference in the same function body.
const candidates = ['displayData', 'normalizedData', 'activeLabels'];
let bad = null;
for (const name of candidates) {
  if (!(name in declPos)) continue;
  const declStart = declPos[name];
  // Look for references to 'name' earlier in the source.
  const re = new RegExp('\\\\b' + name + '\\\\b', 'g');
  let m;
  while ((m = re.exec(src)) !== null) {
    if (m.index < declStart - 5) {
      // Ignore matches inside comments.
      const before = src.slice(Math.max(0, m.index - 80), m.index);
      if (/\\/\\/[^\\n]*\$/.test(before)) continue;
      bad = name + ' referenced at ' + m.index + ' before declaration at ' + declStart;
      break;
    }
  }
  if (bad) break;
}
if (bad) { console.error('FAIL: forward reference: ' + bad); process.exit(1); }
console.log('PASS (diag): production build succeeded and no forward-reference bugs detected');
" || true
  # Weight 0: diagnostic only
else
  echo "FAIL (diag): production build did not pass cleanly (BUILD_EXIT=$BUILD_EXIT, task TS errors: $([ -n "$TASK_ERRORS" ] && echo yes || echo no))"
fi

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
