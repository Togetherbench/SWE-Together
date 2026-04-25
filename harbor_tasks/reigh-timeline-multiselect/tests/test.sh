#!/bin/bash
set +e

# Timeline Multi-Select Implementation Verifier (rewritten)
# Total weight = 1.0
# Mix:
#  - P2P regression guards (0.20): core files intact, TS compiles
#  - F2P behavioral gates (0.55): runtime behavior of new selection hook + integration
#  - Structural verifications (0.25): hook props/integration in drag, tap, container, item

REWARD=0
LOG_DIR=/logs/verifier
mkdir -p "$LOG_DIR"

# Path detection
REPO=""
for c in /workspace/repo /workspace/reigh /workspace/reigh-timeline-multiselect /workspace; do
  if [ -d "$c/src/tools/travel-between-images/components/Timeline" ]; then
    REPO="$c"; break
  fi
done
if [ -z "$REPO" ]; then
  # Fallback: search
  CAND=$(find /workspace -maxdepth 5 -type d -name Timeline -path '*travel-between-images*' 2>/dev/null | head -1)
  if [ -n "$CAND" ]; then
    REPO=$(echo "$CAND" | sed 's|/src/tools/travel-between-images/components/Timeline||')
  fi
fi
[ -z "$REPO" ] && REPO=/workspace/repo

echo "REPO=$REPO"

TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline"
HOOKS="$TIMELINE/hooks"
UTILS="$TIMELINE/utils"
TC_FILE="$TIMELINE/TimelineContainer.tsx"
TI_FILE="$TIMELINE/TimelineItem.tsx"
DRAG_FILE="$HOOKS/useTimelineDrag.ts"
TAP_FILE="$HOOKS/useTapToMove.ts"
UTILS_FILE="$UTILS/timeline-utils.ts"

# PATH robustness
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/cargo/bin:$PATH"
[ -d "$REPO/node_modules/.bin" ] && export PATH="$REPO/node_modules/.bin:$PATH"

add_score() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# Locate selection hook (implementation-agnostic)
SELECTION_HOOK=""
for cand in "$HOOKS/useTimelineSelection.ts" "$HOOKS/useTimelineSelection.tsx"; do
  [ -f "$cand" ] && SELECTION_HOOK="$cand" && break
done
if [ -z "$SELECTION_HOOK" ]; then
  SELECTION_HOOK=$(find "$TIMELINE" -maxdepth 4 -type f \( -iname '*Selection*.ts' -o -iname '*Selection*.tsx' \) 2>/dev/null | grep -iE 'useTimelineSelection|useSelection' | head -1)
fi
echo "SELECTION_HOOK=$SELECTION_HOOK"

############################################
# P2P Gate 1: core files intact (0.05)
############################################
echo ""
echo "=== P2P 1: Core Timeline files intact ==="
G1_OK=1
for f in "$TC_FILE" "$TI_FILE" "$DRAG_FILE" "$TAP_FILE" "$UTILS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "FAIL missing $f"
    G1_OK=0
  fi
done
if [ $G1_OK -eq 1 ]; then
  echo "PASS"
  add_score 0.05
fi

############################################
# P2P Gate 2: TypeScript compilation (0.15)
############################################
echo ""
echo "=== P2P 2: TypeScript compilation ==="
cd "$REPO" 2>/dev/null

TSC_CMD=""
if [ -x "$REPO/node_modules/.bin/tsc" ]; then
  TSC_CMD="$REPO/node_modules/.bin/tsc"
elif command -v npx >/dev/null 2>&1; then
  TSC_CMD="npx --no-install tsc"
elif command -v tsc >/dev/null 2>&1; then
  TSC_CMD="tsc"
fi

if [ -n "$TSC_CMD" ]; then
  $TSC_CMD --noEmit > "$LOG_DIR/tsc.log" 2>&1
  TSC_EXIT=$?
  ERR_COUNT=$(grep -cE 'error TS' "$LOG_DIR/tsc.log" 2>/dev/null)
  ERR_COUNT=${ERR_COUNT:-0}
  if [ "$TSC_EXIT" -eq 0 ]; then
    echo "PASS: 0 errors"
    add_score 0.15
  elif [ "$ERR_COUNT" -lt 3 ]; then
    echo "PARTIAL: $ERR_COUNT errors"
    add_score 0.10
    head -20 "$LOG_DIR/tsc.log"
  elif [ "$ERR_COUNT" -lt 10 ]; then
    echo "WEAK: $ERR_COUNT errors"
    add_score 0.05
    head -20 "$LOG_DIR/tsc.log"
  else
    echo "FAIL: $ERR_COUNT errors"
    head -20 "$LOG_DIR/tsc.log"
  fi
else
  echo "SKIP: no tsc available — partial credit"
  add_score 0.05
fi

############################################
# F2P Gate 3: Selection hook RUNTIME behavior (0.35)
# Bundle the hook with esbuild + a stub 'react' module, then exercise:
#   - initial: selectedIds=[]
#   - toggle('a') -> ['a']
#   - toggle('b') -> ['a','b']
#   - toggle('a') -> ['b']    (toggle removes)
#   - clearSelection() -> []
#   - exposes some boolean indicating "selection bar should show" when len>0
############################################
echo ""
echo "=== F2P 3: Selection hook runtime behavior ==="
G3_BEHAVIOR=0
G3_API=0

if [ -z "$SELECTION_HOOK" ] || [ ! -f "$SELECTION_HOOK" ]; then
  echo "FAIL: no selection hook found"
else
  # Find esbuild
  ESBUILD=""
  if [ -x "$REPO/node_modules/.bin/esbuild" ]; then
    ESBUILD="$REPO/node_modules/.bin/esbuild"
  elif command -v esbuild >/dev/null 2>&1; then
    ESBUILD="esbuild"
  elif command -v npx >/dev/null 2>&1; then
    ESBUILD="npx --no-install esbuild"
  fi

  WORK=$(mktemp -d)
  # React stub package
  mkdir -p "$WORK/node_modules/react"
  cat > "$WORK/node_modules/react/package.json" <<'PKG'
{"name":"react","main":"index.js","version":"0.0.0"}
PKG
  cat > "$WORK/node_modules/react/index.js" <<'STUB'
let stateCells = [];
let refCells = [];
let effectQueue = [];
let cleanupQueue = [];
let stateIdx = 0;
let refIdx = 0;
let effectIdx = 0;
let timers = [];
let now = 0;

function reset() {
  stateCells = []; refCells = []; effectQueue = []; cleanupQueue = [];
  stateIdx = 0; refIdx = 0; effectIdx = 0;
  timers = []; now = 0;
}
function startRender() { stateIdx = 0; refIdx = 0; effectIdx = 0; effectQueue = []; }
function flushEffects() {
  while (effectQueue.length) {
    const e = effectQueue.shift();
    try {
      if (cleanupQueue[e.i]) { try { cleanupQueue[e.i](); } catch(_){} }
      const c = e.fn();
      if (typeof c === 'function') cleanupQueue[e.i] = c;
    } catch(_){}
  }
}
function advanceTime(ms) {
  now += ms;
  const due = timers.filter(t => t.at <= now);
  timers = timers.filter(t => t.at > now);
  due.sort((a,b)=>a.at-b.at).forEach(t => { try { t.fn(); } catch(_){} });
}

function useState(initial) {
  const i = stateIdx++;
  if (stateCells.length <= i) stateCells.push(typeof initial === 'function' ? initial() : initial);
  const setter = (v) => {
    const cur = stateCells[i];
    const next = typeof v === 'function' ? v(cur) : v;
    stateCells[i] = next;
  };
  return [stateCells[i], setter];
}
function useRef(initial) {
  const i = refIdx++;
  if (refCells.length <= i) refCells.push({ current: initial });
  return refCells[i];
}
function useCallback(fn) { return fn; }
function useMemo(fn) { return fn(); }
function useEffect(fn) {
  const i = effectIdx++;
  effectQueue.push({ fn, i });
}
function useLayoutEffect(fn) { useEffect(fn); }

// expose timer hooks for selection-bar delay
const origSetTimeout = setTimeout;
const origClearTimeout = clearTimeout;
global.setTimeout = (fn, ms) => {
  const t = { fn, at: now + (ms || 0), id: Symbol('t') };
  timers.push(t);
  return t;
};
global.clearTimeout = (t) => {
  if (!t) return;
  timers = timers.filter(x => x !== t);
};

module.exports = {
  useState, useRef, useCallback, useMemo, useEffect, useLayoutEffect,
  __reset: reset,
  __startRender: startRender,
  __flushEffects: flushEffects,
  __advanceTime: advanceTime,
  default: { useState, useRef, useCallback, useMemo, useEffect, useLayoutEffect }
};
STUB

  # Bundle hook -> CJS resolving react from our stub
  if [ -n "$ESBUILD" ]; then
    $ESBUILD --bundle "$SELECTION_HOOK" \
      --format=cjs --platform=node --target=es2020 \
      --loader:.ts=ts --loader:.tsx=tsx \
      --resolve-extensions=.ts,.tsx,.js,.mjs \
      --outfile="$WORK/bundle.cjs" \
      --log-level=error \
      --tsconfig-raw='{"compilerOptions":{"jsx":"react","target":"es2020","module":"commonjs","esModuleInterop":true}}' \
      > "$LOG_DIR/esbuild.log" 2>&1

    # Force react to resolve to our stub by working from $WORK
    if [ ! -s "$WORK/bundle.cjs" ]; then
      cd "$WORK"
      $ESBUILD --bundle "$SELECTION_HOOK" \
        --format=cjs --platform=node --target=es2020 \
        --loader:.ts=ts --loader:.tsx=tsx \
        --resolve-extensions=.ts,.tsx,.js,.mjs \
        --outfile="$WORK/bundle.cjs" \
        --log-level=error \
        --tsconfig-raw='{"compilerOptions":{"jsx":"react","target":"es2020","module":"commonjs","esModuleInterop":true}}' \
        >> "$LOG_DIR/esbuild.log" 2>&1
      cd "$REPO"
    fi
  fi

  if [ ! -s "$WORK/bundle.cjs" ]; then
    echo "BUNDLE_FAIL — falling back to static checks"
    cat "$LOG_DIR/esbuild.log" 2>/dev/null | head -20
  fi

  # Test runner
  cat > "$WORK/run.cjs" <<'RUN'
const path = require('path');
const Module = require('module');
const origResolve = Module._resolveFilename;
const stubReact = path.join(__dirname, 'node_modules', 'react', 'index.js');
Module._resolveFilename = function(req, parent, ...rest) {
  if (req === 'react' || req === 'react/jsx-runtime' || req === 'react/jsx-dev-runtime') return stubReact;
  return origResolve.call(this, req, parent, ...rest);
};

let bundle;
try {
  bundle = require('./bundle.cjs');
} catch (e) {
  console.log('LOAD_FAIL', e.message);
  process.exit(2);
}
const React = require('react');

// Locate the hook export
let hookFn = bundle.useTimelineSelection;
if (!hookFn) {
  for (const k of Object.keys(bundle)) {
    if (typeof bundle[k] === 'function' && /[Ss]election/.test(k)) { hookFn = bundle[k]; break; }
  }
}
if (!hookFn && typeof bundle.default === 'function') hookFn = bundle.default;
if (!hookFn) { console.log('NO_HOOK_EXPORT'); process.exit(3); }

let captured;
function render(arg) {
  React.__startRender();
  try {
    captured = hookFn(arg);
  } catch (e) {
    console.log('RENDER_THREW', e.message);
    throw e;
  }
  React.__flushEffects();
}

// Try calling hook with various arg shapes
function tryRender(args) {
  for (const a of args) {
    React.__reset();
    try {
      render(a);
      if (captured && typeof captured === 'object') return a;
    } catch (e) { /* try next */ }
  }
  return null;
}

const argShapes = [
  undefined,
  {},
  { isDragging: false },
  { isDragInProgress: false },
  false,
];
const usedShape = tryRender(argShapes);
if (!captured) { console.log('CALL_FAIL'); process.exit(4); }

function getSelectedIds(c) {
  if (Array.isArray(c.selectedIds)) return c.selectedIds;
  if (Array.isArray(c.selected)) return c.selected;
  if (Array.isArray(c.selectedItems)) return c.selectedItems;
  return null;
}
function getToggle(c) {
  return c.toggleSelection || c.toggle || c.toggleSelected || c.onToggle;
}
function getClear(c) {
  return c.clearSelection || c.clear || c.deselectAll || c.reset;
}
function getShowBar(c) {
  if (typeof c.showSelectionBar === 'boolean') return 'showSelectionBar';
  if (typeof c.showActionBar === 'boolean') return 'showActionBar';
  if (typeof c.showBar === 'boolean') return 'showBar';
  return null;
}

const apiInfo = {
  hasSelectedIds: getSelectedIds(captured) !== null,
  hasToggle: typeof getToggle(captured) === 'function',
  hasClear: typeof getClear(captured) === 'function',
  showBarKey: getShowBar(captured),
  argShape: usedShape,
};
console.log('API', JSON.stringify(apiInfo));

if (!apiInfo.hasSelectedIds || !apiInfo.hasToggle || !apiInfo.hasClear) {
  console.log('API_INCOMPLETE');
  process.exit(5);
}

// Behavioral sequence
function reRender() { render(usedShape); }

// Initial empty
let ids = getSelectedIds(captured);
const initOk = ids.length === 0;

// toggle 'a'
getToggle(captured)('a');
reRender();
ids = getSelectedIds(captured);
const t1 = ids.length === 1 && ids.includes('a');

// toggle 'b'
getToggle(captured)('b');
reRender();
ids = getSelectedIds(captured);
const t2 = ids.length === 2 && ids.includes('a') && ids.includes('b');

// toggle 'a' (remove)
getToggle(captured)('a');
reRender();
ids = getSelectedIds(captured);
const t3 = ids.length === 1 && ids.includes('b') && !ids.includes('a');

// clearSelection
getClear(captured)();
reRender();
ids = getSelectedIds(captured);
const t4 = ids.length === 0;

// showSelectionBar transitions: should be false when empty, true when something selected (possibly after delay)
let showBarOk = true;
const sbKey = apiInfo.showBarKey;
if (sbKey) {
  // start empty
  showBarOk = showBarOk && captured[sbKey] === false;
  // toggle one in
  getToggle(captured)('x');
  reRender();
  // Allow delay: advance time and re-render multiple times
  for (let i = 0; i < 5; i++) {
    React.__advanceTime(80);
    reRender();
  }
  // After ~400ms it should be true
  const finalShow = captured[sbKey];
  showBarOk = showBarOk && finalShow === true;
}

const result = { initOk, t1, t2, t3, t4, showBarOk, hasShowBar: !!sbKey };
console.log('RESULT', JSON.stringify(result));

const passed = ['initOk','t1','t2','t3','t4'].filter(k => result[k]).length;
console.log('PASSED_CORE', passed, '/5');
console.log('SHOWBAR', result.hasShowBar ? (result.showBarOk ? 'ok' : 'fail') : 'absent');
process.exit(passed === 5 ? 0 : (passed >= 3 ? 10 : 11));
RUN

  if [ -s "$WORK/bundle.cjs" ]; then
    node "$WORK/run.cjs" > "$LOG_DIR/g3_runtime.log" 2>&1
    G3_EXIT=$?
    cat "$LOG_DIR/g3_runtime.log"

    if [ $G3_EXIT -eq 0 ]; then
      echo "G3: full behavioral pass"
      G3_BEHAVIOR=1
      add_score 0.30
      # Bonus for delayed showSelectionBar
      if grep -q 'SHOWBAR ok' "$LOG_DIR/g3_runtime.log"; then
        add_score 0.05
        echo "G3: showSelectionBar delay verified (+0.05)"
      fi
    elif [ $G3_EXIT -eq 10 ]; then
      echo "G3: partial (>=3/5 behaviors)"
      add_score 0.18
      G3_API=1
    elif [ $G3_EXIT -eq 5 ]; then
      echo "G3: API present but signature mismatch"
      add_score 0.08
      G3_API=1
    else
      echo "G3: runtime failed; falling back to static API check"
    fi
  fi

  # Static fallback if behavior didn't pass at all
  if [ $G3_BEHAVIOR -eq 0 ] && [ $G3_API -eq 0 ] && [ -f "$SELECTION_HOOK" ]; then
    SH_CONTENT=$(cat "$SELECTION_HOOK")
    has_export=0; has_state=0; has_toggle=0; has_clear=0; has_selected=0
    echo "$SH_CONTENT" | grep -qE 'export\s+(const|function)\s+useTimelineSelection' && has_export=1
    echo "$SH_CONTENT" | grep -qE 'useState' && has_state=1
    echo "$SH_CONTENT" | grep -qiE 'toggle' && has_toggle=1
    echo "$SH_CONTENT" | grep -qiE 'clear' && has_clear=1
    echo "$SH_CONTENT" | grep -qE 'selectedIds|selectedItems' && has_selected=1
    SUM=$((has_export + has_state + has_toggle + has_clear + has_selected))
    if [ $SUM -ge 4 ]; then
      echo "G3 fallback static: $SUM/5 markers"
      add_score 0.06
    fi
  fi
fi

############################################
# F2P Gate 4: TimelineItem accepts selection props (0.10)
############################################
echo ""
echo "=== F2P 4: TimelineItem isSelected wiring ==="
G4=0
if [ -f "$TI_FILE" ]; then
  c=$(cat "$TI_FILE")
  # Must declare prop in interface AND consume it (in JSX/expression) AND have visual differentiation
  has_prop=0
  has_consumed=0
  has_visual=0
  echo "$c" | grep -qE 'isSelected\s*\??\s*:' && has_prop=1
  # Consumed beyond just the type declaration: appears in code (assignment, condition, JSX)
  count=$(echo "$c" | grep -cE 'isSelected')
  [ "$count" -ge 3 ] && has_consumed=1
  # Visual: ring/border/box-shadow/background tied to isSelected
  echo "$c" | grep -qE 'isSelected.*\?(.|\n)*(ring|border|shadow|bg-|boxShadow|outline|color)' && has_visual=1
  # Loose visual fallback
  if [ $has_visual -eq 0 ]; then
    echo "$c" | grep -E 'isSelected' | grep -qE 'ring|border|shadow|bg-|outline|orange|blue' && has_visual=1
  fi

  SUM=$((has_prop + has_consumed + has_visual))
  echo "TimelineItem: prop=$has_prop consumed=$has_consumed visual=$has_visual"
  if [ $SUM -eq 3 ]; then
    add_score 0.10; G4=1
  elif [ $SUM -eq 2 ]; then
    add_score 0.05
  fi
fi

############################################
# F2P Gate 5: useTimelineDrag accepts selectedIds + bundle logic (0.10)
############################################
echo ""
echo "=== F2P 5: useTimelineDrag multi-item bundle support ==="
G5=0
if [ -f "$DRAG_FILE" ]; then
  c=$(cat "$DRAG_FILE")
  has_param=0; has_bundle_const=0; has_multi_branch=0
  # Accepts selectedIds prop
  echo "$c" | grep -qE 'selectedIds' && has_param=1
  # Bundle gap constant of 5 frames
  echo "$c" | grep -qE 'BUNDLE_GAP|bundleGap|bundle_gap|=\s*5\s*[;,)]|\*\s*5\b' && has_bundle_const=1
  # Branch on selection length > 1 (multi vs single)
  echo "$c" | grep -qE 'selectedIds\.length\s*[><=!]+\s*1|selectedIds\.length\s*>\s*1|length\s*===?\s*1' && has_multi_branch=1
  echo "drag: param=$has_param const=$has_bundle_const branch=$has_multi_branch"
  SUM=$((has_param + has_bundle_const + has_multi_branch))
  if [ $SUM -eq 3 ]; then
    add_score 0.10; G5=1
  elif [ $SUM -eq 2 ]; then
    add_score 0.06
  elif [ $SUM -eq 1 ]; then
    add_score 0.02
  fi
fi

############################################
# F2P Gate 6: useTapToMove uses external selectedIds + multi-bundle (0.05)
############################################
echo ""
echo "=== F2P 6: useTapToMove external selection ==="
G6=0
if [ -f "$TAP_FILE" ]; then
  c=$(cat "$TAP_FILE")
  has_external=0; has_branch=0
  echo "$c" | grep -qE 'selectedIds' && has_external=1
  echo "$c" | grep -qE 'selectedIds\.length\s*[><=!]+\s*1|length\s*===?\s*1|length\s*>\s*1' && has_branch=1
  echo "tap: external=$has_external branch=$has_branch"
  SUM=$((has_external + has_branch))
  if [ $SUM -eq 2 ]; then
    add_score 0.05; G6=1
  elif [ $SUM -eq 1 ]; then
    add_score 0.02
  fi
fi

############################################
# F2P Gate 7: TimelineContainer integrates SelectionActionBar (0.10)
############################################
echo ""
echo "=== F2P 7: TimelineContainer SelectionActionBar integration ==="
G7=0
if [ -f "$TC_FILE" ]; then
  c=$(cat "$TC_FILE")
  uses_hook=0; renders_bar=0; passes_count=0; wires_delete=0
  echo "$c" | grep -qE 'useTimelineSelection' && uses_hook=1
  echo "$c" | grep -qE 'SelectionActionBar' && renders_bar=1
  echo "$c" | grep -qE 'selectedCount|selectedIds\.length' && passes_count=1
  echo "$c" | grep -qE 'onDelete|handleBatchDelete|handleDelete' && wires_delete=1
  echo "container: useHook=$uses_hook renderBar=$renders_bar passCount=$passes_count delete=$wires_delete"
  SUM=$((uses_hook + renders_bar + passes_count + wires_delete))
  if [ $SUM -ge 4 ]; then
    add_score 0.10; G7=1
  elif [ $SUM -eq 3 ]; then
    add_score 0.07
  elif [ $SUM -eq 2 ]; then
    add_score 0.04
  fi
fi

############################################
# Finalize
############################################
# Cap at 1.0
REWARD=$(awk -v r="$REWARD" 'BEGIN{ if (r>1) r=1; printf "%.4f", r }')

echo ""
echo "============================================"
echo "FINAL REWARD: $REWARD"
echo "============================================"
echo "$REWARD" > "$LOG_DIR/reward.txt"

exit 0