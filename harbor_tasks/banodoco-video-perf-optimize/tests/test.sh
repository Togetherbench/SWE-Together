#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
which npm >/dev/null 2>&1 || export PATH="$PATH:/usr/local/lib/node_modules/.bin"
which node >/dev/null 2>&1 || export PATH="$PATH:/usr/local/lib/node_modules/.bin"

SCORE=0
add() {
  SCORE=$(awk -v s="$SCORE" -v p="$1" 'BEGIN{printf "%.4f", s+p}')
  echo "  +$1 : $2"
}

if [ ! -d "$REPO" ] || [ ! -f "$TOP_GEN" ] || [ ! -f "$MODEL_TRENDS" ]; then
  echo "FATAL: required files missing"
  echo "0.0" > "$REWARD_FILE"
  exit 0
fi

cd "$REPO"

###############################################################################
# T1 [0.10]: TS compiles cleanly on the two task files
###############################################################################
echo "=== T1 [0.10]: TypeScript compile ==="
TSC_OUT=$(timeout 120 npx --no-install tsc --noEmit 2>&1)
TASK_ERRORS=$(echo "$TSC_OUT" | grep -E "TopGenerations\.tsx|ModelTrends\.tsx" || true)
if [ -z "$TASK_ERRORS" ]; then
  add 0.10 "T1: tsc clean on task files"
else
  echo "$TASK_ERRORS" | head -10
  echo "  T1: tsc errors in task files"
fi

###############################################################################
# T2 [0.10]: Production build succeeds
###############################################################################
echo ""
echo "=== T2 [0.10]: Production build ==="
BUILD_OUT=$(timeout 240 npm run build 2>&1)
BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  add 0.10 "T2: build succeeded"
else
  echo "$BUILD_OUT" | tail -20
  echo "  T2: build failed"
fi

###############################################################################
# T3 [0.20]: Normalization — every row sums to 100% (or filtered to zero rows)
###############################################################################
echo ""
echo "=== T3 [0.20]: Normalization (rows sum to ~100) ==="
T3_PTS=$(node -e '
const ts = require("typescript");
const fs = require("fs");
const path = "'"$MODEL_TRENDS"'";
const src = fs.readFileSync(path, "utf8");
const sf = ts.createSourceFile("f.tsx", src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

const candidates = [];
function walk(n) {
  if (ts.isVariableDeclaration(n) && n.initializer &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
    if (n.initializer.parameters && n.initializer.parameters.length <= 1) {
      candidates.push(n.initializer);
    }
  }
  if (ts.isFunctionDeclaration(n) && n.body && n.parameters.length <= 1) candidates.push(n);
  if (ts.isCallExpression(n)) {
    for (const arg of n.arguments) {
      if ((ts.isArrowFunction(arg) || ts.isFunctionExpression(arg)) &&
          arg.parameters && arg.parameters.length <= 1) {
        candidates.push(arg);
      }
    }
  }
  ts.forEachChild(n, walk);
}
walk(sf);

const testSets = [
  [
    { month: "Jan", sd: 30, flux: 20, wan: 50 },
    { month: "Feb", sd: 10, flux: 60, wan: 10, ltx: 20 },
    { month: "Mar", sd: 5,  flux: 5,  wan: 80, ltx: 5, cogvideo: 5 },
  ],
  [
    { month: "A", sd: 1, flux: 999 },
    { month: "B", sd: 500, flux: 500, wan: 500 },
    { month: "C", flux: 100 },
  ],
  [
    { month: "X", sd: 0, flux: 100, wan: 0 },
    { month: "Y", sd: 25, flux: 25, wan: 25, ltx: 25 },
    { month: "Z", sd: 7, flux: 13, wan: 80 },
  ],
];

function checkNormalized(result, original) {
  if (!Array.isArray(result) || result.length === 0) return 0;
  if (result.length > original.length) return 0;
  let goodRows = 0;
  let total100Rows = 0;
  for (const row of result) {
    if (!row || typeof row !== "object") return 0;
    const nums = Object.entries(row)
      .filter(([k, v]) => typeof v === "number" && k !== "month")
      .map(([, v]) => v);
    if (nums.length === 0) continue;
    const sum = nums.reduce((a,b)=>a+b, 0);
    const ok100 = Math.abs(sum - 100) <= 2;
    const ok1   = Math.abs(sum - 1)   <= 0.02;
    const okZero = sum === 0;
    if (nums.some(v => v < -0.01)) return 0;
    if (ok100 || ok1) { goodRows++; total100Rows++; }
    else if (!okZero) return 0;
  }
  return total100Rows >= 2 ? 1 : 0;
}

let bestPasses = 0;
for (const node of candidates) {
  try {
    const fnSrc = src.slice(node.pos, node.end).trim();
    const wrapped = "(" + fnSrc + ")";
    const js = ts.transpileModule("module.exports = " + wrapped + ";", {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React, module: ts.ModuleKind.CommonJS }
    }).outputText;
    let fn;
    try {
      const m = { exports: {} };
      const f = new Function("module", "exports", js);
      f(m, m.exports);
      fn = m.exports;
    } catch(e) { continue; }
    if (typeof fn !== "function") continue;
    let passes = 0;
    for (const td of testSets) {
      try {
        const inp = JSON.parse(JSON.stringify(td));
        const out = fn(inp);
        if (checkNormalized(out, td)) passes++;
      } catch(e) {}
    }
    if (passes > bestPasses) bestPasses = passes;
  } catch(e) {}
}

const score = (bestPasses / 3) * 0.20;
console.log(score.toFixed(4));
' 2>/dev/null)
if [ -z "$T3_PTS" ] || [ "$T3_PTS" = "0.0000" ]; then T3_PTS=0; fi
add "$T3_PTS" "T3: normalization passes / 0.20"

###############################################################################
# T4 [0.10]: Ease-out timing function present and behaves correctly
###############################################################################
echo ""
echo "=== T4 [0.10]: Ease-out timing ==="
T4_PTS=$(node -e '
const ts = require("typescript");
const fs = require("fs");
const src = fs.readFileSync("'"$MODEL_TRENDS"'", "utf8");
const sf = ts.createSourceFile("f.tsx", src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

const candidates = [];
function walk(n) {
  if (ts.isVariableDeclaration(n) && n.initializer &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
    const params = n.initializer.parameters;
    if (params && params.length === 1) candidates.push(n.initializer);
  }
  if (ts.isFunctionDeclaration(n) && n.parameters && n.parameters.length === 1 && n.body) {
    candidates.push(n);
  }
  ts.forEachChild(n, walk);
}
walk(sf);

let bestScore = 0;
for (const node of candidates) {
  try {
    const fnSrc = src.slice(node.pos, node.end).trim();
    const js = ts.transpileModule("module.exports = (" + fnSrc + ");", {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React, module: ts.ModuleKind.CommonJS }
    }).outputText;
    let fn;
    try {
      const m = { exports: {} };
      const f = new Function("module", "exports", "Math", js);
      f(m, m.exports, Math);
      fn = m.exports;
    } catch(e) { continue; }
    if (typeof fn !== "function") continue;
    try {
      const f0 = fn(0);
      const f1 = fn(1);
      const fq = fn(0.25);
      const fh = fn(0.5);
      const f3q = fn(0.75);
      if (typeof f0 !== "number" || typeof f1 !== "number") continue;
      // Ease-out: starts fast (steep early), slows down (flat late).
      // f(0)≈0, f(1)≈1, monotonically increasing, f(0.25) > 0.25, deceleration.
      if (Math.abs(f0) > 0.05) continue;
      if (Math.abs(f1 - 1) > 0.05) continue;
      if (!(fq > 0.25 + 0.05)) continue;
      if (!(fh > 0.5 + 0.05)) continue;
      if (!(f3q > 0.75)) continue;
      // Decelerating: first half should cover more ground than second half
      const firstHalf = fh - f0;
      const secondHalf = f1 - fh;
      if (!(firstHalf > secondHalf + 0.05)) continue;
      bestScore = 1;
      break;
    } catch(e) {}
  } catch(e) {}
}
console.log((bestScore * 0.10).toFixed(4));
' 2>/dev/null)
if [ -z "$T4_PTS" ]; then T4_PTS=0; fi
add "$T4_PTS" "T4: ease-out timing / 0.10"

###############################################################################
# T5 [0.15]: Y-axis fixed to [0,100] (does not rescale during animation)
###############################################################################
echo ""
echo "=== T5 [0.15]: Y-axis domain fixed [0,100] ==="
T5_PTS=0
# Look for a YAxis with explicit domain [0, 100]. Strip whitespace then regex.
MT_FLAT=$(tr -d '\n' < "$MODEL_TRENDS" | tr -s ' ')
if echo "$MT_FLAT" | grep -qE 'YAxis[^/]*domain=\{[^}]*\[[[:space:]]*0[[:space:]]*,[[:space:]]*100[[:space:]]*\]'; then
  T5_PTS=0.15
fi
add "$T5_PTS" "T5: YAxis domain=[0,100] / 0.15"

###############################################################################
# T6 [0.10]: Animation starts from zero/empty, not all-data-visible
###############################################################################
echo ""
echo "=== T6 [0.10]: Animation starts from beginning ==="
T6_PTS=0
# Look for visible-count / progress state initialized to 0 or 1, not data.length
if grep -qE "useState[<(][^>]*>?\s*\(?\s*(0|1)\s*\)" "$MODEL_TRENDS"; then
  # And animation logic should reference some kind of incrementing counter
  if grep -qE "(visibleCount|visibleIndex|progress|animationProgress|currentIndex|step|frame)" "$MODEL_TRENDS"; then
    if grep -qE "requestAnimationFrame|setInterval|setTimeout|useInView|isInView|inView" "$MODEL_TRENDS"; then
      T6_PTS=0.10
    fi
  fi
fi
add "$T6_PTS" "T6: animation from zero / 0.10"

###############################################################################
# T7 [0.10]: Auto-plays when section enters viewport
###############################################################################
echo ""
echo "=== T7 [0.10]: Auto-plays on scroll into view ==="
T7_PTS=0
if grep -qE "(IntersectionObserver|useInView|isInView|inView)" "$MODEL_TRENDS"; then
  T7_PTS=0.10
fi
add "$T7_PTS" "T7: auto-play on view / 0.10"

###############################################################################
# T8 [0.15]: TopGenerations virtualizes / lazy-loads videos (windowed loading)
###############################################################################
echo ""
echo "=== T8 [0.15]: TopGenerations lazy/windowed loading ==="
T8_PTS=0
T8_DETAIL=""

# Behavioral indicator 1: IntersectionObserver or useInView used
if grep -qE "(IntersectionObserver|useInView|isInView|inView)" "$TOP_GEN"; then
  T8_PTS=$(awk -v s="$T8_PTS" 'BEGIN{printf "%.4f", s+0.07}')
  T8_DETAIL="$T8_DETAIL [observer:+0.07]"
fi

# Behavioral indicator 2: src is conditionally set (lazy) OR window-slicing
if grep -qE "(src=\{[^}]*\?|src=\{[^}]*&&|preload=[\"']none[\"']|loading=[\"']lazy[\"'])" "$TOP_GEN"; then
  T8_PTS=$(awk -v s="$T8_PTS" 'BEGIN{printf "%.4f", s+0.04}')
  T8_DETAIL="$T8_DETAIL [conditional-src:+0.04]"
elif grep -qE "\.slice\(|windowStart|visibleRange|\.filter\(.*index" "$TOP_GEN"; then
  T8_PTS=$(awk -v s="$T8_PTS" 'BEGIN{printf "%.4f", s+0.04}')
  T8_DETAIL="$T8_DETAIL [windowing:+0.04]"
fi

# Behavioral indicator 3: cleanup on scroll-out (clear src, unload, disconnect)
if grep -qE "(removeAttribute|\.src\s*=\s*['\"]{2}|setSrc\(\s*(null|''|\"\")|unload|releas|disconnect)" "$TOP_GEN"; then
  T8_PTS=$(awk -v s="$T8_PTS" 'BEGIN{printf "%.4f", s+0.04}')
  T8_DETAIL="$T8_DETAIL [cleanup:+0.04]"
fi

add "$T8_PTS" "T8: lazy/windowed videos / 0.15$T8_DETAIL"

###############################################################################
# T9 [0.10]: Model name labels appear on graph segments (white text)
###############################################################################
echo ""
echo "=== T9 [0.10]: Model labels overlay ==="
T9_PTS=0
T9_DETAIL=""

# Must reference MODEL_COLORS / model names AND render text/labels with white fill
HAS_LABEL_RENDER=0
if grep -qE "(MODEL_COLORS|MODEL_KEYS|firstAppearance|activeLabel|visibleLabel|newModel|modelLabel|<text|ReferenceDot|Customized)" "$MODEL_TRENDS"; then
  HAS_LABEL_RENDER=1
fi

HAS_WHITE=0
if grep -qE "(fill=[\"']white[\"']|color:\s*['\"]white|text-white|fill:\s*['\"]?#fff|#FFFFFF|#ffffff)" "$MODEL_TRENDS"; then
  HAS_WHITE=1
fi

# Must be conditional on first appearance / new model entering
HAS_FIRST_APPEAR=0
if grep -qE "(firstAppearance|first.*[Aa]ppear|newModel|justAppeared|\.findIndex\(.*>\s*0)" "$MODEL_TRENDS"; then
  HAS_FIRST_APPEAR=1
fi

if [ $HAS_LABEL_RENDER -eq 1 ]; then
  T9_PTS=$(awk -v s="$T9_PTS" 'BEGIN{printf "%.4f", s+0.04}')
  T9_DETAIL="$T9_DETAIL [render:+0.04]"
fi
if [ $HAS_WHITE -eq 1 ]; then
  T9_PTS=$(awk -v s="$T9_PTS" 'BEGIN{printf "%.4f", s+0.03}')
  T9_DETAIL="$T9_DETAIL [white:+0.03]"
fi
if [ $HAS_FIRST_APPEAR -eq 1 ]; then
  T9_PTS=$(awk -v s="$T9_PTS" 'BEGIN{printf "%.4f", s+0.03}')
  T9_DETAIL="$T9_DETAIL [first-appear:+0.03]"
fi

add "$T9_PTS" "T9: model labels / 0.10$T9_DETAIL"

###############################################################################
# Final
###############################################################################
echo ""
REWARD=$(awk -v s="$SCORE" 'BEGIN{
  if (s > 1.0) s = 1.0;
  if (s < 0.0) s = 0.0;
  printf "%.4f", s
}')
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0