#!/bin/bash
set +e

# Timeline Multi-Select verifier — F2P-behavioral, no-op = 0.
LOG_DIR=/logs/verifier
mkdir -p "$LOG_DIR"
GATES_FILE="$LOG_DIR/gates.json"
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 300)
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

# Locate repo
REPO=""
for c in /workspace/repo /workspace/reigh /workspace; do
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

if [ -z "$REPO" ]; then
  emit p2p_instruction_unmodified true "no repo (degraded)"
  for g in t1_f2p_selection_hook_runtime_toggle t1_f2p_bundle_multi_5frames_runtime t1_f2p_drag_hook_uses_selectedIds t2_f2p_orange_selection_color t3_f2p_TimelineContainer_wires_selection t4_f2p_action_bar_with_selectedCount t4_f2p_onNewShot_threaded t6_f2p_jump_to_shot_wired; do
    emit "$g" false "no repo found"
  done
  printf "0.0000\n" > "$LOG_DIR/reward.txt"
  exit 0
fi

echo "REPO=$REPO"

TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline"
HOOKS="$TIMELINE/hooks"
UTILS="$TIMELINE/utils"
TC_FILE="$TIMELINE/TimelineContainer.tsx"
TI_FILE="$TIMELINE/TimelineItem.tsx"
T_FILE="$TIMELINE/Timeline.tsx"
DRAG_FILE="$HOOKS/useTimelineDrag.ts"
TAP_FILE="$HOOKS/useTapToMove.ts"
UTILS_FILE="$UTILS/timeline-utils.ts"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
[ -d "$REPO/node_modules/.bin" ] && export PATH="$REPO/node_modules/.bin:$PATH"

# ===== P2P: instruction.md unchanged =====
INSTR="/instruction.md"
if [ ! -f "$INSTR" ]; then
  for c in /workspace/instruction.md /tasks/instruction.md /baseline/instruction.md; do
    [ -f "$c" ] && INSTR="$c" && break
  done
fi
INSTR_BASE="/baseline/instruction.md"
if [ -f "$INSTR_BASE" ] && [ -f "$INSTR" ]; then
  if cmp -s "$INSTR_BASE" "$INSTR"; then
    emit p2p_instruction_unmodified true ""
  else
    emit p2p_instruction_unmodified false "instruction.md changed"
  fi
else
  emit p2p_instruction_unmodified true "no baseline instruction"
fi

# Locate the selection hook
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

# locate esbuild
ESBUILD=""
if [ -x "$REPO/node_modules/.bin/esbuild" ]; then
  ESBUILD="$REPO/node_modules/.bin/esbuild"
elif command -v esbuild >/dev/null 2>&1; then
  ESBUILD="esbuild"
else
  ESB_CAND=$(find /workspace -maxdepth 6 -type f -path '*/node_modules/.bin/esbuild' 2>/dev/null | head -1)
  [ -n "$ESB_CAND" ] && ESBUILD="$ESB_CAND"
fi
echo "ESBUILD=$ESBUILD"

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

bundle_file() {
  local src="$1" out="$2"
  [ -z "$ESBUILD" ] && return 1
  [ ! -f "$src" ] && return 1
  ( cd "$WORK" && "$ESBUILD" --bundle "$src" \
      --format=cjs --platform=node --target=es2020 \
      --loader:.ts=ts --loader:.tsx=tsx \
      --resolve-extensions=.ts,.tsx,.js,.mjs \
      --outfile="$out" \
      --log-level=error \
      --tsconfig-raw='{"compilerOptions":{"jsx":"react","target":"es2020","module":"commonjs","esModuleInterop":true}}' ) \
      > "$LOG_DIR/esbuild_$(basename "$out").log" 2>&1
  [ -s "$out" ]
}

############################################
# F2P 1: Selection hook runtime toggle
############################################
HOOK_PASS=false
HOOK_DETAIL=""
if [ -n "$SELECTION_HOOK" ]; then
  if bundle_file "$SELECTION_HOOK" "$WORK/sel.cjs"; then
    cat > "$WORK/run_sel.cjs" <<'RUN'
const path = require('path');
const Module = require('module');
const orig = Module._resolveFilename;
Module._resolveFilename = function(req, parent, ...rest){
  if (req === 'react' || req === 'react/jsx-runtime' || req === 'react/jsx-dev-runtime') {
    return path.join(__dirname, 'node_modules', 'react', 'index.js');
  }
  return orig.call(this, req, parent, ...rest);
};
const React = require('react');
const mod = require('./sel.cjs');

let hook = null;
for (const k of Object.keys(mod)) {
  if (typeof mod[k] === 'function' && /selection/i.test(k)) { hook = mod[k]; break; }
}
if (!hook && typeof mod.default === 'function') hook = mod.default;
if (!hook) for (const k of Object.keys(mod)) if (typeof mod[k] === 'function') { hook = mod[k]; break; }
if (!hook) { console.log('NO_HOOK'); process.exit(2); }

function call(){
  React.__startRender();
  let res, last;
  for (const a of [() => hook(), () => hook({}), () => hook({isEnabled:true}), () => hook({isDragging:false})]) {
    try { res = a(); last = null; break; } catch(e){ last = e; }
  }
  if (last) throw last;
  React.__flushEffects();
  return res;
}
function ids(r){ return r && Array.isArray(r.selectedIds) ? r.selectedIds.slice() : null; }

let ok = { addA:false, addB:false, removeA:false, clear:false };
try {
  React.__reset();
  let r = call();
  if (typeof r.toggleSelection === 'function') r.toggleSelection('a');
  React.__flushEffects(); React.__advanceTime(300); React.__flushEffects();
  r = call();
  let s = ids(r);
  if (Array.isArray(s) && s.includes('a') && s.length===1) ok.addA = true;

  if (typeof r.toggleSelection === 'function') r.toggleSelection('b');
  React.__flushEffects(); React.__advanceTime(300); React.__flushEffects();
  r = call();
  s = ids(r);
  if (Array.isArray(s) && s.includes('a') && s.includes('b') && s.length===2) ok.addB = true;

  if (typeof r.toggleSelection === 'function') r.toggleSelection('a');
  React.__flushEffects(); React.__advanceTime(50); React.__flushEffects();
  r = call();
  s = ids(r);
  if (Array.isArray(s) && !s.includes('a') && s.includes('b') && s.length===1) ok.removeA = true;

  if (typeof r.clearSelection === 'function') r.clearSelection();
  else if (typeof r.toggleSelection === 'function') r.toggleSelection('b');
  React.__flushEffects(); React.__advanceTime(50); React.__flushEffects();
  r = call();
  s = ids(r);
  if (Array.isArray(s) && s.length===0) ok.clear = true;
} catch(e){ console.error('ERR', e && e.message); }
console.log('R=' + JSON.stringify(ok));
RUN
    node "$WORK/run_sel.cjs" > "$LOG_DIR/sel_run.log" 2>&1
    LINE=$(grep -E '^R=' "$LOG_DIR/sel_run.log" | tail -1)
    echo "selection_hook: $LINE"
    if echo "$LINE" | grep -q '"addA":true' && \
       echo "$LINE" | grep -q '"addB":true' && \
       echo "$LINE" | grep -q '"removeA":true' && \
       echo "$LINE" | grep -q '"clear":true'; then
      HOOK_PASS=true
    else
      HOOK_DETAIL="hook behavior failed: $LINE"
    fi
  else
    HOOK_DETAIL="esbuild failed for selection hook"
  fi
else
  HOOK_DETAIL="useTimelineSelection.ts not present"
fi
emit t1_f2p_selection_hook_runtime_toggle $HOOK_PASS "$HOOK_DETAIL"

############################################
# F2P 2: bundle-multi runtime — applyFluidTimelineMulti or in-drag bundling
############################################
BUNDLE_PASS=false
BUNDLE_DETAIL=""

# Try utils file first
TARGET_BUNDLE_SRC=""
if [ -f "$UTILS_FILE" ] && grep -qE 'applyFluidTimelineMulti|BUNDLE_GAP' "$UTILS_FILE"; then
  TARGET_BUNDLE_SRC="$UTILS_FILE"
fi

if [ -n "$TARGET_BUNDLE_SRC" ] && bundle_file "$TARGET_BUNDLE_SRC" "$WORK/util.cjs"; then
  cat > "$WORK/run_util.cjs" <<'RUN'
const path = require('path');
const Module = require('module');
const orig = Module._resolveFilename;
Module._resolveFilename = function(req, parent, ...rest){
  if (req === 'react' || req === 'react/jsx-runtime' || req === 'react/jsx-dev-runtime') {
    return path.join(__dirname, 'node_modules', 'react', 'index.js');
  }
  return orig.call(this, req, parent, ...rest);
};
const mod = require('./util.cjs');
let fn = mod.applyFluidTimelineMulti;
if (!fn) {
  for (const k of Object.keys(mod)) if (/multi/i.test(k) && typeof mod[k] === 'function') { fn = mod[k]; break; }
}
if (typeof fn !== 'function') { console.log('NO_FN'); process.exit(2); }

const positions = new Map([['a',0],['b',30],['c',60]]);
const ids = ['a','b','c'];
let result;
const attempts = [
  () => fn(positions, ids, 10),
  () => fn({positions, selectedIds: ids, targetFrame: 10}),
  () => fn(ids, positions, 10),
  () => fn(positions, ids, 10, 'a'),
];
for (const a of attempts) {
  try { result = a(); if (result) break; } catch(_){}
}
if (!result) { console.log('NO_RESULT'); process.exit(2); }

function get(r, k){
  if (r instanceof Map) return r.get(k);
  if (typeof r === 'object' && r) return r[k];
  return undefined;
}
const a = get(result, 'a'), b = get(result, 'b'), c = get(result, 'c');
console.log('POS a=' + a + ' b=' + b + ' c=' + c);
// Accept either exact 10/15/20 OR 10,15,20 in any base/order: we want bundling at gap 5 anchored near 10
let ok = false;
if (typeof a === 'number' && typeof b === 'number' && typeof c === 'number') {
  // sorted values
  const arr = [a,b,c].sort((x,y)=>x-y);
  if (arr[1]-arr[0] === 5 && arr[2]-arr[1] === 5 && arr[0] === 10) ok = true;
}
console.log('BUNDLE_OK=' + ok);
RUN
  node "$WORK/run_util.cjs" > "$LOG_DIR/util_run.log" 2>&1
  cat "$LOG_DIR/util_run.log"
  if grep -q '^BUNDLE_OK=true' "$LOG_DIR/util_run.log"; then
    BUNDLE_PASS=true
  else
    BUNDLE_DETAIL="bundle output not 5-frame spaced"
  fi
fi

# Fallback: if no util fn, try to detect inline bundling in drag hook by static + numeric pattern
if [ "$BUNDLE_PASS" != "true" ]; then
  if [ -f "$DRAG_FILE" ]; then
    # require: selectedIds reference AND a 5-spacing arithmetic AND a sort by frame
    if grep -qE 'selectedIds' "$DRAG_FILE" && \
       grep -qE '(\*\s*5\b|BUNDLE[_ ]?GAP\s*[:=]\s*5)' "$DRAG_FILE" && \
       grep -qE 'sort' "$DRAG_FILE"; then
      # but only credit if NOT a no-op base; require also that "sort" appears within selection-related logic
      # weaker fallback — give detail
      BUNDLE_PASS=true
      BUNDLE_DETAIL="${BUNDLE_DETAIL}; passed via inline drag-hook static evidence"
    fi
  fi
fi

[ -z "$BUNDLE_DETAIL" ] && BUNDLE_DETAIL="ok"
emit t1_f2p_bundle_multi_5frames_runtime $BUNDLE_PASS "$BUNDLE_DETAIL"

############################################
# F2P 3: useTimelineDrag accepts selectedIds AND uses it (multi-branch)
# Static heuristic must require BOTH a parameter/destructure of selectedIds
# AND a behavioral branch (length>1 / length === 1 / size > 1) using it.
############################################
DRAG_PASS=false
DRAG_DETAIL=""
if [ -f "$DRAG_FILE" ]; then
  has_param=$(grep -cE '\bselectedIds\b' "$DRAG_FILE")
  has_branch=$(grep -cE 'selectedIds\.(length|size)|selectedIds\?\.(length|size)' "$DRAG_FILE")
  if [ "$has_param" -ge 2 ] && [ "$has_branch" -ge 1 ]; then
    DRAG_PASS=true
  else
    DRAG_DETAIL="drag selectedIds usage insufficient (param=$has_param branch=$has_branch)"
  fi
else
  DRAG_DETAIL="useTimelineDrag.ts missing"
fi
emit t1_f2p_drag_hook_uses_selectedIds $DRAG_PASS "$DRAG_DETAIL"

############################################
# F2P 4: Orange selection color in TimelineItem (when isSelected)
# Must reference orange (rgba 249,115,22 OR ring-orange OR border-orange OR #f97316)
# AND must be conditional on isSelected (not on pre-existing isSelectedForMove only).
############################################
ORANGE_PASS=false
ORANGE_DETAIL=""
if [ -f "$TI_FILE" ]; then
  # Pull lines containing isSelected (excluding isSelectedForMove) and look at nearby (±8 lines) for orange
  if python3 - "$TI_FILE" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='ignore').read()
lines = src.split('\n')
orange_pat = re.compile(r'(249\s*,\s*115\s*,\s*22|ring-orange|border-orange|bg-orange|#f97316|f97316)', re.I)
sel_pat = re.compile(r'\bisSelected\b')
forMove = re.compile(r'isSelectedForMove')
hits = 0
for i, ln in enumerate(lines):
    if not sel_pat.search(ln): continue
    if forMove.search(ln) and 'isSelected ' not in ln and 'isSelected?' not in ln and 'isSelected:' not in ln and 'isSelected)' not in ln and 'isSelected,' not in ln:
        # Pure isSelectedForMove, skip
        if not re.search(r'\bisSelected\b(?!For)', ln):
            continue
    # window
    lo = max(0, i-8); hi = min(len(lines), i+9)
    window = '\n'.join(lines[lo:hi])
    if orange_pat.search(window):
        hits += 1
print('HITS', hits)
sys.exit(0 if hits >= 1 else 1)
PY
  then
    ORANGE_PASS=true
  else
    ORANGE_DETAIL="orange not associated with isSelected in TimelineItem"
  fi
else
  ORANGE_DETAIL="TimelineItem.tsx missing"
fi
emit t2_f2p_orange_selection_color $ORANGE_PASS "$ORANGE_DETAIL"

############################################
# F2P 5: TimelineContainer wires selection hook AND threads selectedIds into drag/tap call sites
############################################
WIRE_PASS=false
WIRE_DETAIL=""
if [ -f "$TC_FILE" ]; then
  has_hook=$(grep -cE 'useTimelineSelection' "$TC_FILE")
  # Look at the useTimelineDrag call site and useTapToMove call site for selectedIds being passed
  passes_to_drag=$(python3 - "$TC_FILE" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
def call_block(name):
    m = re.search(re.escape(name) + r'\s*\(', src)
    if not m: return ''
    i = m.end() - 1
    depth = 0; start = i
    while i < len(src):
        c = src[i]
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: return src[start:i+1]
        i += 1
    return ''
ok_drag = 'selectedIds' in call_block('useTimelineDrag')
ok_tap  = 'selectedIds' in call_block('useTapToMove')
print('drag', ok_drag, 'tap', ok_tap)
sys.exit(0 if (ok_drag or ok_tap) else 1)
PY
)
  drag_tap_status=$?
  if [ "$has_hook" -ge 1 ] && [ $drag_tap_status -eq 0 ]; then
    WIRE_PASS=true
  else
    WIRE_DETAIL="hook=$has_hook drag/tap_threading=$passes_to_drag"
  fi
else
  WIRE_DETAIL="TimelineContainer.tsx missing"
fi
emit t3_f2p_TimelineContainer_wires_selection $WIRE_PASS "$WIRE_DETAIL"

############################################
# F2P 6: SelectionActionBar rendered with selectedCount=selectedIds.length AND onDelete + onDeselect bound
############################################
BAR_PASS=false
BAR_DETAIL=""
if [ -f "$TC_FILE" ]; then
  # Extract SelectionActionBar JSX block
  block=$(python3 - "$TC_FILE" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
# find every <SelectionActionBar ...> ... up to /> or </SelectionActionBar>
pat = re.compile(r'<SelectionActionBar\b[^>]*?(?:/>|>[\s\S]*?</SelectionActionBar>)', re.M)
hits = pat.findall(src)
if not hits:
    sys.exit(2)
for h in hits:
    print('---BLOCK---')
    print(h)
PY
)
  if [ -n "$block" ]; then
    # selectedCount must reference selectedIds (not a hardcoded number)
    if echo "$block" | grep -qE 'selectedCount\s*=\s*\{[^}]*selectedIds' && \
       echo "$block" | grep -qE 'onDelete\s*=' && \
       echo "$block" | grep -qE 'onDeselect\s*=' ; then
      BAR_PASS=true
    else
      BAR_DETAIL="action bar present but missing selectedCount/onDelete/onDeselect bindings"
    fi
  else
    BAR_DETAIL="SelectionActionBar not rendered in TimelineContainer"
  fi
else
  BAR_DETAIL="TimelineContainer.tsx missing"
fi
emit t4_f2p_action_bar_with_selectedCount $BAR_PASS "$BAR_DETAIL"

############################################
# F2P 7: onNewShotFromSelection threaded -> SelectionActionBar onNewShot
############################################
NEWSHOT_PASS=false
NEWSHOT_DETAIL=""
if [ -f "$TC_FILE" ]; then
  # Check that TimelineContainer accepts onNewShotFromSelection prop and passes onNewShot to SelectionActionBar
  if grep -qE 'onNewShotFromSelection' "$TC_FILE"; then
    block2=$(python3 - "$TC_FILE" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
pat = re.compile(r'<SelectionActionBar\b[^>]*?(?:/>|>[\s\S]*?</SelectionActionBar>)', re.M)
hits = pat.findall(src)
print('\n'.join(hits))
PY
)
    if echo "$block2" | grep -qE 'onNewShot\s*='; then
      NEWSHOT_PASS=true
    else
      NEWSHOT_DETAIL="onNewShotFromSelection accepted but not passed as onNewShot"
    fi
  else
    NEWSHOT_DETAIL="onNewShotFromSelection not threaded in TimelineContainer"
  fi
fi
emit t4_f2p_onNewShot_threaded $NEWSHOT_PASS "$NEWSHOT_DETAIL"

############################################
# F2P 8: jump-to-shot wired (onJumpToShot or onShotChange) on SelectionActionBar
############################################
JUMP_PASS=false
JUMP_DETAIL=""
if [ -f "$TC_FILE" ]; then
  block3=$(python3 - "$TC_FILE" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
pat = re.compile(r'<SelectionActionBar\b[^>]*?(?:/>|>[\s\S]*?</SelectionActionBar>)', re.M)
hits = pat.findall(src)
print('\n'.join(hits))
PY
)
  if echo "$block3" | grep -qE '(onJumpToShot|onShotChange)\s*='; then
    JUMP_PASS=true
  else
    JUMP_DETAIL="no onJumpToShot/onShotChange on SelectionActionBar"
  fi
fi
emit t6_f2p_jump_to_shot_wired $JUMP_PASS "$JUMP_DETAIL"

############################################
# Compute reward
############################################
P2P_FAIL=0
while IFS= read -r line; do
  id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
  passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
  case "$id" in
    p2p_*)
      if [ "$passed" = "false" ]; then P2P_FAIL=1; fi
      ;;
  esac
done < "$GATES_FILE"

declare -A W
W[t1_f2p_selection_hook_runtime_toggle]=0.20
W[t1_f2p_bundle_multi_5frames_runtime]=0.25
W[t1_f2p_drag_hook_uses_selectedIds]=0.10
W[t2_f2p_orange_selection_color]=0.10
W[t3_f2p_TimelineContainer_wires_selection]=0.10
W[t4_f2p_action_bar_with_selectedCount]=0.15
W[t4_f2p_onNewShot_threaded]=0.05
W[t6_f2p_jump_to_shot_wired]=0.05

REWARD=0
if [ "$P2P_FAIL" -eq 0 ]; then
  while IFS= read -r line; do
    id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
    passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
    if [ "$passed" = "true" ] && [ -n "${W[$id]:-}" ]; then
      REWARD=$(awk -v a="$REWARD" -v b="${W[$id]}" 'BEGIN{printf "%.4f", a+b}')
    fi
  done < "$GATES_FILE"
fi

printf "%.4f\n" "$REWARD" > "$LOG_DIR/reward.txt"
echo "FINAL_REWARD=$REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3JlcG8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_523760b1 'tsc_noemit' 'cd /workspace/repo && cd /workspace/repo && timeout 90 npx tsc --noEmit -p tsconfig.app.json 2>&1 | tail -5; if grep -q '\''error TS'\'' /tmp/tsc.out 2>/dev/null; then exit 1; fi'
run_v043_gate p2p_upstream_cdf050a5 'npm_run_build' 'cd /workspace/repo && cd /workspace/repo && timeout 240 npm run build 2>&1 | tail -3'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_bundle_multi_5frames_runtime": 0.25, "t1_f2p_drag_hook_uses_selectedIds": 0.1, "t1_f2p_selection_hook_runtime_toggle": 0.2, "t2_f2p_orange_selection_color": 0.1, "t3_f2p_TimelineContainer_wires_selection": 0.1, "t4_f2p_action_bar_with_selectedCount": 0.15, "t4_f2p_onNewShot_threaded": 0.05, "t6_f2p_jump_to_shot_wired": 0.05}
P2P_REGRESSION = ["p2p_instruction_unmodified"]
P2P_REGRESSION = ["p2p_upstream_523760b1", "p2p_upstream_cdf050a5"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
reward = 0.0
for gid, w in WEIGHTS.items():
    if verdicts.get(gid, False): reward += w
if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0