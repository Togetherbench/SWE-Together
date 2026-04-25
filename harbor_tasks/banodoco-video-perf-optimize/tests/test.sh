#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"
REWARD=0

REPO="/workspace/banodoco-wrapped"
TOP_GEN="$REPO/components/TopGenerations.tsx"
MODEL_TRENDS="$REPO/components/ModelTrends.tsx"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

finish() {
  echo "$REWARD" > "$REWARD_FILE"
  exit 0
}

if [ ! -d "$REPO" ] || [ ! -f "$TOP_GEN" ] || [ ! -f "$MODEL_TRENDS" ]; then
  echo "FATAL: missing files"
  REWARD=0
  finish
fi

cd "$REPO" || finish

###############################################################################
# P2P GATE: Production build must succeed (gating only, no reward)
###############################################################################
echo "=== P2P GATE: Production build ==="
BUILD_OUT=$(timeout 240 npm run build 2>&1)
BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
  echo "$BUILD_OUT" | tail -30
  echo "GATE FAILED: build broken"
  REWARD=0
  finish
fi
echo "Build OK"

add() {
  REWARD=$(awk -v s="$REWARD" -v p="$1" 'BEGIN{printf "%.4f", s+p}')
  echo "  +$1 : $2  (running=$REWARD)"
}

###############################################################################
# F2P 1 [0.25]: Normalization — at least 2 rows sum to ~100 across 2/3 datasets.
# Buggy base does NOT normalize → fails. Fixed code returns rows summing to 100.
###############################################################################
echo ""
echo "=== F2P 1 [0.25]: Row normalization to 100% ==="
T_NORM=$(node -e '
const ts = require("typescript");
const fs = require("fs");
const src = fs.readFileSync("'"$MODEL_TRENDS"'", "utf8");
const sf = ts.createSourceFile("f.tsx", src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

const candidates = [];
function walk(n) {
  if (ts.isVariableDeclaration(n) && n.initializer &&
      (ts.isArrowFunction(n.initializer) || ts.isFunctionExpression(n.initializer))) {
    if (n.initializer.parameters && n.initializer.parameters.length <= 1) candidates.push(n.initializer);
  }
  if (ts.isFunctionDeclaration(n) && n.body && n.parameters.length <= 1) candidates.push(n);
  if (ts.isCallExpression(n)) {
    for (const arg of n.arguments) {
      if ((ts.isArrowFunction(arg) || ts.isFunctionExpression(arg)) && arg.parameters && arg.parameters.length <= 1) {
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
  if (!Array.isArray(result) || result.length === 0) return false;
  if (result.length > original.length) return false;
  let total100 = 0;
  for (const row of result) {
    if (!row || typeof row !== "object") return false;
    const nums = Object.entries(row).filter(([k,v]) => typeof v === "number" && k !== "month").map(([,v]) => v);
    if (nums.length === 0) continue;
    const sum = nums.reduce((a,b)=>a+b,0);
    const ok100 = Math.abs(sum - 100) <= 2;
    const ok1   = Math.abs(sum - 1)   <= 0.02;
    if (nums.some(v => v < -0.01)) return false;
    if (ok100 || ok1) total100++;
    else if (sum !== 0) return false;
  }
  return total100 >= 2;
}

let bestPasses = 0;
for (const node of candidates) {
  try {
    const fnSrc = src.slice(node.pos, node.end).trim();
    const js = ts.transpileModule("module.exports = (" + fnSrc + ");", {
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
        const out = fn(JSON.parse(JSON.stringify(td)));
        if (checkNormalized(out, td)) passes++;
      } catch(e) {}
    }
    if (passes > bestPasses) bestPasses = passes;
  } catch(e) {}
}
// Need at least 2/3 datasets to score
if (bestPasses >= 2) console.log("0.2500");
else console.log("0.0000");
' 2>/dev/null)
[ -z "$T_NORM" ] && T_NORM=0
add "$T_NORM" "F2P1 normalization"

###############################################################################
# F2P 2 [0.15]: Ease-out timing function exists in ModelTrends.
# Buggy base has no ease function → fails. Fix introduces one.
###############################################################################
echo ""
echo "=== F2P 2 [0.15]: Ease-out timing function ==="
T_EASE=$(node -e '
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
  if (ts.isFunctionDeclaration(n) && n.parameters && n.parameters.length === 1 && n.body) candidates.push(n);
  ts.forEachChild(n, walk);
}
walk(sf);

let best = 0;
for (const node of candidates) {
  try {
    const fnSrc = src.slice(node.pos, node.end).trim();
    const js = ts.transpileModule("module.exports = (" + fnSrc + ");", {
      compilerOptions: { target: ts.ScriptTarget.ES2020, jsx: ts.JsxEmit.React, module: ts.ModuleKind.CommonJS }
    }).outputText;
    let fn;
    try {
      const m = { exports: {} };
      const f = new Function("module","exports","Math", js);
      f(m, m.exports, Math);
      fn = m.exports;
    } catch(e){continue;}
    if (typeof fn !== "function") continue;
    try {
      const f0 = fn(0), f1 = fn(1), fq = fn(0.25), fh = fn(0.5), f3q = fn(0.75);
      if (typeof f0 !== "number" || typeof f1 !== "number") continue;
      if (Math.abs(f0) > 0.05) continue;
      if (Math.abs(f1 - 1) > 0.05) continue;
      if (!(fq > 0.30)) continue;
      if (!(fh > 0.55)) continue;
      if (!(f3q > 0.78)) continue;
      const firstHalf = fh - f0;
      const secondHalf = f1 - fh;
      if (!(firstHalf > secondHalf + 0.05)) continue;
      best = 1; break;
    } catch(e){}
  } catch(e){}
}
console.log(best ? "0.1500" : "0.0000");
' 2>/dev/null)
[ -z "$T_EASE" ] && T_EASE=0
add "$T_EASE" "F2P2 ease-out"

###############################################################################
# F2P 3 [0.15]: Y-axis fixed to [0, 100] on the YAxis tag.
# Buggy base lacks `domain={[0, 100]}` on YAxis. Fix adds it.
###############################################################################
echo ""
echo "=== F2P 3 [0.15]: YAxis fixed domain [0,100] ==="
# Extract the YAxis JSX block(s) and check for domain=[0,100]
YAXIS_OK=0
# Use perl for multi-line match across YAxis ... />
if perl -0777 -ne 'while(/<YAxis\b[^>]*?\/>/sg){ if($& =~ /domain\s*=\s*\{\s*\[\s*0\s*,\s*100\s*\]\s*\}/){ exit 0 } } exit 1' "$MODEL_TRENDS"; then
  YAXIS_OK=1
fi
if [ $YAXIS_OK -eq 1 ]; then
  add 0.15 "F2P3 YAxis domain [0,100]"
else
  echo "  YAxis domain not fixed to [0,100]"
fi

###############################################################################
# F2P 4 [0.15]: Auto-play on viewport entry — useInView/IntersectionObserver
# wired to start the animation. Buggy base has no auto-start logic.
###############################################################################
echo ""
echo "=== F2P 4 [0.15]: Auto-play when section enters viewport ==="
AUTO_OK=0
# Look for IntersectionObserver OR useInView referencing setIsPlaying/start
if grep -qE "IntersectionObserver|useInView|isInView" "$MODEL_TRENDS"; then
  # And evidence of triggering animation start
  if grep -qE "setIsPlaying\(true\)|startAnimation|setVisibleCount\(" "$MODEL_TRENDS"; then
    AUTO_OK=1
  fi
fi
if [ $AUTO_OK -eq 1 ]; then
  add 0.15 "F2P4 auto-play in view"
else
  echo "  No auto-play-on-view logic detected"
fi

###############################################################################
# F2P 5 [0.10]: Animation starts from zero/empty (not all data visible).
# Buggy base shows all data immediately. Fix initializes visibleCount to 0 or 1.
###############################################################################
echo ""
echo "=== F2P 5 [0.10]: Animation starts from left (visibleCount initial 0/1) ==="
START_OK=0
# Find useState(<small int>) used as visibleCount or similar
if grep -qE "useState<number>\(\s*[01]\s*\)|useState\(\s*[01]\s*\)" "$MODEL_TRENDS"; then
  # Also require slicing of data by a count, indicating progressive reveal
  if grep -qE "\.slice\(\s*0\s*,\s*visibleCount" "$MODEL_TRENDS" || \
     grep -qE "\.slice\(\s*0\s*,\s*\w*[Cc]ount" "$MODEL_TRENDS"; then
    START_OK=1
  fi
fi
if [ $START_OK -eq 1 ]; then
  add 0.10 "F2P5 starts from left"
else
  echo "  Progressive reveal not detected"
fi

###############################################################################
# F2P 6 [0.10]: White model name labels overlaid on chart.
# Buggy base has no label overlay for new models. Fix adds white text labels.
###############################################################################
echo ""
echo "=== F2P 6 [0.10]: White model name label overlay ==="
LABEL_OK=0
# Look for evidence of model-name labels rendered with white color, keyed off MODEL_COLORS or model keys
# Must be near MODEL_COLORS[...].name or similar usage
if perl -0777 -ne '
  my $src = $_;
  # Look for white labels rendered with model names
  my $hasWhite = ($src =~ /(?:fill\s*=\s*["\x27]white["\x27]|color:\s*["\x27]?white|text-white|fill\s*=\s*\{["\x27]white)/);
  my $hasModelName = ($src =~ /MODEL_COLORS\s*\[\s*\w+\s*\]\.name/);
  exit ($hasWhite && $hasModelName ? 0 : 1);
' "$MODEL_TRENDS"; then
  LABEL_OK=1
fi
if [ $LABEL_OK -eq 1 ]; then
  add 0.10 "F2P6 white model labels"
else
  echo "  No white model-name label overlay"
fi

###############################################################################
# F2P 7 [0.10]: TopGenerations virtualization — IntersectionObserver to load
# only nearby rows. Buggy base loads all videos at once.
###############################################################################
echo ""
echo "=== F2P 7 [0.10]: TopGenerations row virtualization ==="
VIRT_OK=0
if grep -qE "IntersectionObserver" "$TOP_GEN"; then
  # And actually conditionally renders <video> based on visibility state
  if grep -qE "isLoaded|isVisible|isInView|isIntersecting|inView|isActive" "$TOP_GEN"; then
    VIRT_OK=1
  fi
fi
# Alternative: window-based slicing in the parent
if [ $VIRT_OK -eq 0 ]; then
  if grep -qE "windowStart|WINDOW_SIZE|VISIBLE_WINDOW" "$TOP_GEN" && \
     grep -qE "scroll|IntersectionObserver|getBoundingClientRect" "$TOP_GEN"; then
    VIRT_OK=1
  fi
fi
if [ $VIRT_OK -eq 1 ]; then
  add 0.10 "F2P7 row virtualization"
else
  echo "  No row virtualization detected"
fi

###############################################################################
# Final
###############################################################################
echo ""
echo "=== FINAL REWARD: $REWARD ==="
finish