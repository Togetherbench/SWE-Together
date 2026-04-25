#!/bin/bash
set +e

# Timeline Multi-Select verifier — F2P-only reward.
# No-op (unmodified base) = 0.0. All reward comes from new behaviors.

REWARD=0
LOG_DIR=/logs/verifier
mkdir -p "$LOG_DIR"

finish() {
  echo "FINAL_REWARD=$REWARD"
  echo "$REWARD" > "$LOG_DIR/reward.txt"
  exit 0
}

# Locate repo
REPO=""
for c in /workspace/repo /workspace/repo /workspace/repo-timeline-multiselect /workspace; do
  if [ -d "$c/src/tools/travel-between-images/components/Timeline" ]; then
    REPO="$c"; break
  fi
done
if [ -z "$REPO" ]; then
  CAND=$(find /workspace -maxdepth 6 -type d -name Timeline -path '*travel-between-images*' 2>/dev/null | head -1)
  if [ -n "$CAND" ]; then
    REPO=$(echo "$CAND" | sed 's|/src/tools/travel-between-images/components/Timeline||')
  fi
fi
[ -z "$REPO" ] && { echo "no repo found"; finish; }

echo "REPO=$REPO"

TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline"
HOOKS="$TIMELINE/hooks"
TC_FILE="$TIMELINE/TimelineContainer.tsx"
TI_FILE="$TIMELINE/TimelineItem.tsx"

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/cargo/bin:$PATH"
[ -d "$REPO/node_modules/.bin" ] && export PATH="$REPO/node_modules/.bin:$PATH"

add_score() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

# ===== P2P Gate: required pre-existing files intact (gating, no reward) =====
for f in "$TC_FILE" "$TI_FILE" "$HOOKS/useTimelineDrag.ts" "$HOOKS/useTapToMove.ts"; do
  if [ ! -f "$f" ]; then
    echo "P2P FAIL: missing pre-existing file $f"
    finish
  fi
done

# Locate the new selection hook (only exists if agent created it)
SELECTION_HOOK=""
for cand in "$HOOKS/useTimelineSelection.ts" "$HOOKS/useTimelineSelection.tsx"; do
  [ -f "$cand" ] && SELECTION_HOOK="$cand" && break
done
if [ -z "$SELECTION_HOOK" ]; then
  SELECTION_HOOK=$(find "$TIMELINE" -maxdepth 4 -type f \( -name '*.ts' -o -name '*.tsx' \) 2>/dev/null \
    | xargs grep -l -E 'useTimelineSelection' 2>/dev/null \
    | grep -E '/hooks/' | head -1)
fi
echo "SELECTION_HOOK=$SELECTION_HOOK"

############################################
# F2P 1: Selection hook RUNTIME behavior (0.45)
# Bundle the hook with esbuild against a stubbed react and exercise:
#   - initial selectedIds = []
#   - toggle('a') -> contains 'a'
#   - toggle('b') -> contains 'a' and 'b'
#   - toggle('a') -> contains 'b' only
#   - clearSelection -> empty
# Plus: showSelectionBar truthy when selection non-empty (allow either immediate or after 200ms timer).
#
# All of these REQUIRE the new file to exist. On no-op base, file doesn't exist → 0.
############################################
echo ""
echo "=== F2P 1: Selection hook behavior ==="
HOOK_SCORE=0

if [ -n "$SELECTION_HOOK" ] && [ -f "$SELECTION_HOOK" ]; then
  ESBUILD=""
  if [ -x "$REPO/node_modules/.bin/esbuild" ]; then
    ESBUILD="$REPO/node_modules/.bin/esbuild"
  elif command -v esbuild >/dev/null 2>&1; then
    ESBUILD="esbuild"
  fi

  if [ -z "$ESBUILD" ]; then
    echo "no esbuild available; skipping runtime"
  else
    WORK=$(mktemp -d)
    mkdir -p "$WORK/node_modules/react"
    cat > "$WORK/node_modules/react/package.json" <<'PKG'
{"name":"react","main":"index.js","version":"0.0.0"}
PKG
    cat > "$WORK/node_modules/react/index.js" <<'STUB'
let stateCells = [];
let refCells = [];
let effectQueue = [];
let cleanupQueue = [];
let stateIdx = 0, refIdx = 0, effectIdx = 0;
let timers = [];
let now = 0;

function reset(){ stateCells=[]; refCells=[]; effectQueue=[]; cleanupQueue=[]; stateIdx=0; refIdx=0; effectIdx=0; timers=[]; now=0; }
function startRender(){ stateIdx=0; refIdx=0; effectIdx=0; effectQueue=[]; }
function flushEffects(){
  while(effectQueue.length){
    const e = effectQueue.shift();
    try {
      if (cleanupQueue[e.i]) { try { cleanupQueue[e.i](); } catch(_){} }
      const c = e.fn();
      if (typeof c === 'function') cleanupQueue[e.i] = c;
    } catch(_){}
  }
}
function advanceTime(ms){
  now += ms;
  const due = timers.filter(t=>t.at<=now);
  timers = timers.filter(t=>t.at>now);
  due.sort((a,b)=>a.at-b.at).forEach(t=>{ try{ t.fn(); }catch(_){} });
}
function useState(init){
  const i = stateIdx++;
  if (stateCells.length<=i) stateCells.push(typeof init==='function'?init():init);
  const set = v => { const cur=stateCells[i]; stateCells[i]= typeof v==='function'?v(cur):v; };
  return [stateCells[i], set];
}
function useRef(init){
  const i = refIdx++;
  if (refCells.length<=i) refCells.push({current:init});
  return refCells[i];
}
function useCallback(fn){ return fn; }
function useMemo(fn){ return fn(); }
function useEffect(fn){ const i=effectIdx++; effectQueue.push({fn,i}); }
function useLayoutEffect(fn){ useEffect(fn); }

global.setTimeout = (fn,ms)=>{ const t={fn,at:now+(ms||0),id:Symbol('t')}; timers.push(t); return t; };
global.clearTimeout = (t)=>{ if(!t) return; timers = timers.filter(x=>x!==t); };

module.exports = {
  useState, useRef, useCallback, useMemo, useEffect, useLayoutEffect,
  __reset: reset, __startRender: startRender, __flushEffects: flushEffects, __advanceTime: advanceTime,
  default: { useState, useRef, useCallback, useMemo, useEffect, useLayoutEffect }
};
STUB

    cd "$WORK"
    $ESBUILD --bundle "$SELECTION_HOOK" \
      --format=cjs --platform=node --target=es2020 \
      --loader:.ts=ts --loader:.tsx=tsx \
      --resolve-extensions=.ts,.tsx,.js,.mjs \
      --outfile="$WORK/bundle.cjs" \
      --log-level=error \
      --tsconfig-raw='{"compilerOptions":{"jsx":"react","target":"es2020","module":"commonjs","esModuleInterop":true}}' \
      > "$LOG_DIR/esbuild.log" 2>&1
    cd "$REPO"

    if [ -s "$WORK/bundle.cjs" ]; then
      cat > "$WORK/run.cjs" <<'RUN'
const path = require('path');
const Module = require('module');
const origResolve = Module._resolveFilename;
Module._resolveFilename = function(req, parent, ...rest){
  if (req === 'react' || req === 'react/jsx-runtime' || req === 'react/jsx-dev-runtime') {
    return path.join(__dirname, 'node_modules', 'react', 'index.js');
  }
  return origResolve.call(this, req, parent, ...rest);
};

const React = require('react');
const mod = require('./bundle.cjs');

// Find the hook export (any function named like useTimelineSelection or default)
let hook = null;
for (const k of Object.keys(mod)) {
  if (typeof mod[k] === 'function' && /selection/i.test(k)) { hook = mod[k]; break; }
}
if (!hook && typeof mod.default === 'function') hook = mod.default;
if (!hook) {
  for (const k of Object.keys(mod)) {
    if (typeof mod[k] === 'function') { hook = mod[k]; break; }
  }
}
if (!hook) { console.log('NO_HOOK'); process.exit(2); }

function call(args){
  React.__startRender();
  let res;
  // Try various calling conventions: (), ({isDragging:false}), (false)
  const attempts = [
    () => hook(args),
    () => hook(),
    () => hook({ isDragging: false }),
    () => hook({ isDragInProgress: false }),
    () => hook(false),
  ];
  let lastErr;
  for (const a of attempts) {
    try { res = a(); lastErr = null; break; } catch(e) { lastErr = e; }
  }
  if (lastErr) throw lastErr;
  React.__flushEffects();
  return res;
}

function getIds(r){
  if (!r) return null;
  if (Array.isArray(r.selectedIds)) return r.selectedIds.slice();
  return null;
}

const results = { initEmpty:false, addA:false, addB:false, removeA:false, clear:false, showBar:false };

try {
  React.__reset();
  let r = call();
  let ids = getIds(r);
  if (Array.isArray(ids) && ids.length === 0) results.initEmpty = true;

  // toggle 'a'
  if (typeof r.toggleSelection === 'function') r.toggleSelection('a');
  React.__flushEffects();
  React.__advanceTime(250);
  React.__flushEffects();
  r = call();
  ids = getIds(r);
  if (Array.isArray(ids) && ids.includes('a') && ids.length === 1) results.addA = true;

  // showSelectionBar should be true now (after timer or immediately)
  if (r.showSelectionBar === true) results.showBar = true;

  // toggle 'b'
  if (typeof r.toggleSelection === 'function') r.toggleSelection('b');
  React.__flushEffects();
  React.__advanceTime(250);
  React.__flushEffects();
  r = call();
  ids = getIds(r);
  if (Array.isArray(ids) && ids.includes('a') && ids.includes('b') && ids.length === 2) results.addB = true;

  // toggle 'a' again -> remove
  if (typeof r.toggleSelection === 'function') r.toggleSelection('a');
  React.__flushEffects();
  React.__advanceTime(50);
  React.__flushEffects();
  r = call();
  ids = getIds(r);
  if (Array.isArray(ids) && !ids.includes('a') && ids.includes('b') && ids.length === 1) results.removeA = true;

  // clear
  if (typeof r.clearSelection === 'function') r.clearSelection();
  React.__flushEffects();
  React.__advanceTime(50);
  React.__flushEffects();
  r = call();
  ids = getIds(r);
  if (Array.isArray(ids) && ids.length === 0) results.clear = true;

} catch(e){
  console.error('RUNTIME_ERROR', e && e.message);
}

console.log('RESULTS=' + JSON.stringify(results));
RUN

      node "$WORK/run.cjs" > "$LOG_DIR/hook_run.log" 2>&1
      cat "$LOG_DIR/hook_run.log"
      LINE=$(grep -E '^RESULTS=' "$LOG_DIR/hook_run.log" | tail -1)
      echo "$LINE"

      check() {
        echo "$LINE" | grep -q "\"$1\":true"
      }

      # Award per behavior
      if check initEmpty; then add_score 0.05; HOOK_SCORE=$((HOOK_SCORE+1)); fi
      if check addA;      then add_score 0.10; HOOK_SCORE=$((HOOK_SCORE+1)); fi
      if check addB;      then add_score 0.10; HOOK_SCORE=$((HOOK_SCORE+1)); fi
      if check removeA;   then add_score 0.10; HOOK_SCORE=$((HOOK_SCORE+1)); fi
      if check clear;     then add_score 0.05; HOOK_SCORE=$((HOOK_SCORE+1)); fi
      if check showBar;   then add_score 0.05; HOOK_SCORE=$((HOOK_SCORE+1)); fi
    else
      echo "esbuild produced no bundle"
      cat "$LOG_DIR/esbuild.log" | head -30
    fi
  fi
else
  echo "No selection hook present (expected on no-op base)"
fi

echo "Hook behavior gates passed: $HOOK_SCORE/6"

############################################
# F2P 2: TimelineItem accepts isSelected / onSelectionClick props (0.15)
#   These props don't exist in the base file. Their presence indicates the
#   visual + click-toggle wiring required by Phase 2.
############################################
echo ""
echo "=== F2P 2: TimelineItem multi-select props ==="
TI_OK=0
if [ -f "$TI_FILE" ]; then
  # Must reference isSelected as a prop (typed/accepted) AND use it in render logic.
  # Filter out pre-existing isSelectedForMove by requiring word boundary.
  if grep -E '(\bisSelected\b[^F])' "$TI_FILE" | grep -vqE 'isSelectedForMove' ; then
    # also require it actually controls visuals (referenced in JSX/style block)
    if grep -cE '\bisSelected\b' "$TI_FILE" | awk '{exit !($1>=2)}'; then
      TI_OK=1
    fi
  fi
fi
if [ $TI_OK -eq 1 ]; then
  echo "PASS: TimelineItem references isSelected prop"
  add_score 0.10
else
  echo "FAIL: TimelineItem does not use isSelected"
fi

# onSelectionClick OR an onClick that calls a selection toggle handler
TI_CLICK_OK=0
if [ -f "$TI_FILE" ]; then
  if grep -qE 'onSelectionClick' "$TI_FILE"; then
    TI_CLICK_OK=1
  fi
fi
if [ $TI_CLICK_OK -eq 1 ]; then
  echo "PASS: TimelineItem exposes onSelectionClick"
  add_score 0.05
else
  echo "FAIL: no onSelectionClick wiring"
fi

############################################
# F2P 3: TimelineContainer integrates selection + SelectionActionBar (0.20)
############################################
echo ""
echo "=== F2P 3: TimelineContainer integration ==="
TC_HOOK_OK=0
TC_BAR_OK=0
if [ -f "$TC_FILE" ]; then
  if grep -qE 'useTimelineSelection' "$TC_FILE"; then
    TC_HOOK_OK=1
  fi
  if grep -qE 'SelectionActionBar' "$TC_FILE"; then
    TC_BAR_OK=1
  fi
fi
if [ $TC_HOOK_OK -eq 1 ]; then
  echo "PASS: TimelineContainer uses useTimelineSelection"
  add_score 0.10
else
  echo "FAIL: useTimelineSelection not used in TimelineContainer"
fi
if [ $TC_BAR_OK -eq 1 ]; then
  echo "PASS: TimelineContainer renders SelectionActionBar"
  add_score 0.10
else
  echo "FAIL: SelectionActionBar not integrated"
fi

############################################
# F2P 4: useTimelineDrag and useTapToMove accept selectedIds (0.10)
#   On base, these hooks do not have a selectedIds parameter.
############################################
echo ""
echo "=== F2P 4: drag + tap multi-item awareness ==="
DRAG_OK=0
TAP_OK=0
if grep -qE '\bselectedIds\b' "$HOOKS/useTimelineDrag.ts" 2>/dev/null; then
  DRAG_OK=1
fi
if grep -qE '\bselectedIds\b' "$HOOKS/useTapToMove.ts" 2>/dev/null; then
  TAP_OK=1
fi
if [ $DRAG_OK -eq 1 ]; then
  echo "PASS: useTimelineDrag references selectedIds"
  add_score 0.05
fi
if [ $TAP_OK -eq 1 ]; then
  echo "PASS: useTapToMove references selectedIds"
  add_score 0.05
fi

############################################
# F2P 5: Bundle gap (5 frames apart) implemented (0.10)
#   Look for the bundle constant / arithmetic in drag or tap or utils.
#   On the base, neither hook has any reference to a 5-frame multi bundle.
############################################
echo ""
echo "=== F2P 5: bundle-5-frames behavior present ==="
BUNDLE_OK=0
SEARCH_FILES="$HOOKS/useTimelineDrag.ts $HOOKS/useTapToMove.ts $TIMELINE/utils/timeline-utils.ts"
for f in $SEARCH_FILES; do
  [ -f "$f" ] || continue
  # match either explicit BUNDLE_GAP/named constant of 5 OR `index * 5` / `i * 5` arithmetic for multi-positioning
  if grep -qE '(BUNDLE[_ ]?GAP|bundleGap)\s*[:=]\s*5\b' "$f"; then
    BUNDLE_OK=1; break
  fi
  if grep -qE '\*\s*5\b' "$f" && grep -qE 'selectedIds' "$f"; then
    BUNDLE_OK=1; break
  fi
done
if [ $BUNDLE_OK -eq 1 ]; then
  echo "PASS: bundle-gap logic detected"
  add_score 0.10
else
  echo "FAIL: no 5-frame bundle logic detected"
fi

echo ""
echo "REWARD=$REWARD"
finish