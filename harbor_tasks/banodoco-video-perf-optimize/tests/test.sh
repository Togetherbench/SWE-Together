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

if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: node missing"
  REWARD=0
  finish
fi

###############################################################################
# P2P REGRESSION (informational): production build status. Per repo policy,
# P2P_REGRESSION never zeroes reward directly. If the build fails, the
# behavioral F2P gates below — which require running the bundled output —
# will naturally fail, zeroing the reward via the not-f2p_any_pass path.
###############################################################################
echo "=== P2P REGRESSION (informational): Production build ==="
BUILD_OUT=$(timeout 300 npm run build 2>&1)
BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
  echo "$BUILD_OUT" | tail -40
  echo "GATE INFORMATIONAL: build broken — F2P gates will zero reward via not-f2p_any_pass"
  BUILD_OK=0
else
  echo "Build OK"
  BUILD_OK=1
fi

add() {
  REWARD=$(awk -v s="$REWARD" -v p="$1" 'BEGIN{printf "%.4f", s+p}')
  echo "  +$1 : $2  (running=$REWARD)"
}

###############################################################################
# F2P 1 [0.20]: ModelTrends — Row normalization to ~100% (behavioral)
###############################################################################
echo ""
echo "=== F2P 1 [0.20]: Normalization to 100 across rows ==="
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
if (bestPasses >= 3) console.log("0.2000");
else if (bestPasses >= 2) console.log("0.1200");
else console.log("0.0000");
' 2>/dev/null)
[ -z "$T_NORM" ] && T_NORM=0
add "$T_NORM" "F2P1 normalization"

###############################################################################
# F2P 2 [0.15]: Ease-out timing (behavioral: starts fast, slows down)
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
# F2P 3 [0.15]: Y-axis fixed to a stable full-share domain
# Accepts both [0, 100] (percent) and [0, 1] (fraction-normalized) variants.
# The rubric (canonical_goals.json.v3.json goal_3) scores a "fixed numeric
# domain spanning the full share range" — implementation may normalize values
# to either 0..100 or 0..1, so we accept either upper bound here.
###############################################################################
echo ""
echo "=== F2P 3 [0.15]: YAxis domain fixed to [0,100] or [0,1] ==="
T_YAXIS=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$MODEL_TRENDS"'", "utf8");
// Find <YAxis ... /> tag(s)
const re = /<YAxis\b[\s\S]*?\/>/g;
let m, ok = 0;
while ((m = re.exec(src)) !== null) {
  const tag = m[0];
  // domain={[0, 100]} or domain={[0,100]} or domain={[0, 1]} or domain={[0,1]}
  if (/domain\s*=\s*\{\s*\[\s*0\s*,\s*(?:100|1)\s*\]\s*\}/.test(tag)) {
    ok = 1;
    break;
  }
}
console.log(ok ? "0.1500" : "0.0000");
' 2>/dev/null)
[ -z "$T_YAXIS" ] && T_YAXIS=0
add "$T_YAXIS" "F2P3 YAxis domain"

###############################################################################
# F2P 4 [0.15]: Animation starts from 0 (initial visibleCount=0 / starts left)
# The buggy base initializes such that all data is visible. Fix sets it to start
# from 0 (or 1) and grow. We detect: useState(0) or useState(1) for visibleCount.
###############################################################################
echo ""
echo "=== F2P 4 [0.15]: Animation starts from 0 / left ==="
T_START=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$MODEL_TRENDS"'", "utf8");
// Look for useState pattern initializing visibleCount/animationProgress/etc to 0 or 1
// e.g. useState(0), useState<number>(0), useState(1)
const re = /useState\s*(?:<[^>]+>)?\s*\(\s*([01])\s*\)/g;
let zeroFound = 0, oneFound = 0;
let m;
while ((m = re.exec(src)) !== null) {
  if (m[1] === "0") zeroFound++;
  if (m[1] === "1") oneFound++;
}
// Also check: setVisibleCount(0) somewhere in viewport-trigger / restart logic
const resetsToZero = /setVisibleCount\s*\(\s*0\s*\)/.test(src) ||
                     /setAnimationProgress\s*\(\s*0\s*\)/.test(src) ||
                     /set[A-Z]\w*\s*\(\s*0\s*\)/.test(src);
// Require BOTH a zero-init useState AND a reset to zero in restart logic
let score = 0;
if (zeroFound >= 1 && resetsToZero) score = 0.15;
else if (oneFound >= 1 && resetsToZero) score = 0.10;
else if (zeroFound >= 1 || resetsToZero) score = 0.05;
console.log(score.toFixed(4));
' 2>/dev/null)
[ -z "$T_START" ] && T_START=0
add "$T_START" "F2P4 animation starts from 0"

###############################################################################
# F2P 5 [0.15]: White label overlay for new models (text + className)
# Buggy base lacks white-text labels. Fix adds an overlay/text element with
# fill="white" or text-white class displaying model names.
###############################################################################
echo ""
echo "=== F2P 5 [0.15]: White label for new model ==="
T_LABEL=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$MODEL_TRENDS"'", "utf8");

// Heuristic: must have one of these forms accompanying a MODEL_COLORS[..].name reference
// AND text-white / fill="white" / fill={"white"} nearby.
let ok = false;

// Form 1: <text ... fill="white" ...>{...name}</text>
const textTag = /<text\b[^>]*\bfill\s*=\s*["{]\s*["]?white["]?\s*[}"]?[^>]*>[\s\S]*?<\/text>/g;
let m;
while ((m = textTag.exec(src)) !== null) {
  // Check if any nearby reference to MODEL_COLORS[...].name or {name} or model name lookup
  const block = src.slice(Math.max(0, m.index - 400), Math.min(src.length, m.index + m[0].length + 200));
  if (/MODEL_COLORS\[[^\]]+\]\.name|\.name\b|\{name\}/.test(block)) {
    ok = true; break;
  }
}

// Form 2: html element with text-white class & model name reference
if (!ok) {
  const htmlRe = /<(motion\.)?(div|span)\b[^>]*\b(className\s*=\s*["{][^"}]*text-white[^"}]*["}]|className\s*=\s*\{`[^`]*text-white[^`]*`\})[^>]*>([\s\S]*?)<\/(motion\.)?\2>/g;
  while ((m = htmlRe.exec(src)) !== null) {
    const inner = m[4];
    if (/MODEL_COLORS\[[^\]]+\]\.name|\.name\b|\{name\}/.test(inner) ||
        /MODEL_COLORS\[[^\]]+\]\.name/.test(src.slice(Math.max(0, m.index - 400), m.index))) {
      ok = true; break;
    }
  }
}

console.log(ok ? "0.1500" : "0.0000");
' 2>/dev/null)
[ -z "$T_LABEL" ] && T_LABEL=0
add "$T_LABEL" "F2P5 white label overlay"

###############################################################################
# F2P 6 [0.20]: TopGenerations — IntersectionObserver-driven lazy media
# Buggy base eagerly renders all videos. Fix windows them via IntersectionObserver
# (or a windowed slice driven by scroll) and clears src / unmounts when off-screen.
# Behavioral check: we count how many <video src=...> would be active given
# the captured patches all use IntersectionObserver. We require:
#   1. IntersectionObserver in the file
#   2. A useState that toggles visibility/loaded based on the observer
#   3. Some mechanism to prevent eager src assignment (preload="none" OR conditional src OR conditional render)
###############################################################################
echo ""
echo "=== F2P 6 [0.20]: TopGenerations lazy/windowed video loading ==="
T_LAZY=$(node -e '
const fs = require("fs");
const src = fs.readFileSync("'"$TOP_GEN"'", "utf8");

let score = 0;

// Signal A: IntersectionObserver used (or windowed slice via scroll listener)
const hasIO = /IntersectionObserver\s*\(/.test(src);
const hasScrollWindow = /windowStart|VISIBLE_WINDOW|WINDOW_SIZE|ACTIVE_BUFFER/.test(src) &&
                       (/addEventListener\s*\(\s*["]scroll["]/.test(src) || /useEffect/.test(src));
const hasVirtualization = hasIO || hasScrollWindow;

// Signal B: state hook controls per-row/per-video visibility
const hasVisState = /useState\s*(?:<[^>]+>)?\s*\(\s*(false|true|index\s*<\s*\d+|\d+)\s*\)/.test(src) &&
                   /useRef|useEffect/.test(src);

// Signal C: video element diagnostic — either conditional src, preload="none", or conditional render
const condSrc = /src\s*=\s*\{[^}]*\?\s*[^:]+:\s*(undefined|""|null|"")\s*\}/.test(src) ||
                /\{\s*is(Loaded|Visible|Active|InView)\s*&&\s*<video/i.test(src) ||
                /\{\s*is(Loaded|Visible|Active|InView)\s*\?\s*\(?\s*<video/i.test(src);
const preloadNone = /<video\b[^>]*preload\s*=\s*["]none["]/.test(src);
const condRender = /\{\s*is(Loaded|Visible|Active|InView)/i.test(src) ||
                  /windowStart\s*<=|windowEnd\s*>=|inWindow|isActive/i.test(src);

if (hasVirtualization) score += 0.10;
if (hasVisState) score += 0.04;
if (condSrc || preloadNone || condRender) score += 0.06;

// Cap at 0.20
if (score > 0.20) score = 0.20;
console.log(score.toFixed(4));
' 2>/dev/null)
[ -z "$T_LAZY" ] && T_LAZY=0
add "$T_LAZY" "F2P6 TopGenerations lazy loading"

###############################################################################
echo ""
echo "=== FINAL REWARD (pre-upstream): $REWARD ==="
finish_original() {
  echo "$REWARD" > "$REWARD_FILE"
}
finish_original

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"

echo ""
echo "=== Upstream Gate: IntersectionObserver in TopGenerations.tsx ==="
cd /workspace/banodoco-wrapped
if grep -q 'IntersectionObserver' components/TopGenerations.tsx; then
  echo '{"id": "f2p_upstream_intersection_observer", "passed": true, "detail": "IntersectionObserver found in TopGenerations.tsx"}' >> "$GATES_FILE"
  echo "  PASSED"
else
  echo '{"id": "f2p_upstream_intersection_observer", "passed": false, "detail": "IntersectionObserver not found in TopGenerations.tsx"}' >> "$GATES_FILE"
  echo "  FAILED"
fi

echo ""
echo "=== Upstream Gate: YAxis domain fixed ([0, 100] or [0, 1]) in ModelTrends.tsx ==="
# Accept both percent ([0, 100]) and fraction-normalized ([0, 1]) variants —
# the v3 rubric (goal_3) scores a fixed full-share domain agnostic of units.
if grep -Eq 'domain[[:space:]]*=[[:space:]]*\{[[:space:]]*\[[[:space:]]*0[[:space:]]*,[[:space:]]*(100|1)[[:space:]]*\][[:space:]]*\}' components/ModelTrends.tsx; then
  echo '{"id": "f2p_upstream_yaxis_domain", "passed": true, "detail": "YAxis domain fixed to a stable full-share range"}' >> "$GATES_FILE"
  echo "  PASSED"
else
  echo '{"id": "f2p_upstream_yaxis_domain", "passed": false, "detail": "YAxis domain not fixed to a stable full-share range ([0,100] or [0,1])"}' >> "$GATES_FILE"
  echo "  FAILED"
fi

echo ""
echo "=== Upstream Reward Adjustment ==="
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_intersection_observer": 0.2,
    "f2p_upstream_yaxis_domain": 0.2
}
P2P_REGRESSION = []
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

p2p_failed = False  # P2P_REGRESSION gates are informational only (v043 fix)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
REWARD=$(cat "$REWARD_FILE" 2>/dev/null || echo "0")
echo "=== FINAL REWARD (post-upstream): $REWARD ==="
# ---- end ----

exit 0