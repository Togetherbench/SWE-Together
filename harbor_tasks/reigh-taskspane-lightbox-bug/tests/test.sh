#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

TOTAL=0

cd /workspace/repo

# Helper: add to total and write reward (integer math in hundredths)
add_reward() {
  TOTAL=$((TOTAL + $1))
  awk "BEGIN {printf \"%.2f\", $TOTAL/100}" > "$REWARD_FILE"
}

###############################################################################
# Gate 1 (F2P) — TypeScript compilation + shotId prop [weight 0.25]
# Combines compilation gate (npx tsc --noEmit) with AST verification that
# MediaLightbox in TasksPane.tsx receives a shotId attribute.
# BOTH must pass. Fails on unmodified base (shotId missing); passes on fix.
###############################################################################
echo "=== Gate 1: TypeScript compilation + shotId prop (F2P, 0.25) ==="
GATE1=0

# Step A: TypeScript compilation
npx tsc --noEmit 2>&1 | tail -10
TSC_EXIT=$?
if [ $TSC_EXIT -ne 0 ]; then
  echo "FAIL: TypeScript compilation failed (exit $TSC_EXIT)"
else
  echo "PASS: TypeScript compilation succeeded"

  # Step B: AST check for shotId in TasksPane MediaLightbox
  node -e "
  const ts = require('typescript');
  const fs = require('fs');
  const src = fs.readFileSync('src/shared/components/TasksPane/TasksPane.tsx', 'utf8');
  const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  function findProps(node, tag) {
    let res = [];
    (function v(n) {
      if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
        if (n.tagName.getText(sf) === tag) {
          const a = [];
          if (n.attributes && n.attributes.properties)
            n.attributes.properties.forEach(x => { if (ts.isJsxAttribute(x) && x.name) a.push(x.name.getText(sf)); });
          res.push(a);
        }
      }
      ts.forEachChild(n, v);
    })(node);
    return res;
  }
  const all = findProps(sf, 'MediaLightbox');
  if (all.length === 0) { console.log('FAIL: No MediaLightbox found'); process.exit(1); }
  if (all.some(p => p.includes('shotId'))) { console.log('PASS: shotId prop found'); process.exit(0); }
  else { console.log('FAIL: shotId prop missing'); process.exit(1); }
  " 2>&1
  if [ $? -eq 0 ]; then
    GATE1=25
    echo "Gate 1 PASS (0.25)"
  fi
fi
add_reward $GATE1

###############################################################################
# Gate 2 (F2P) — showVideoTrimEditor prop [weight 0.25]
# Verifies the lightbox enables the video trim editor when opened from
# TasksPane, matching SegmentOutputStrip behavior.
# Fails on unmodified base; passes on correct fix.
###############################################################################
echo "=== Gate 2: showVideoTrimEditor prop in TasksPane (F2P, 0.25) ==="
GATE2=0
node -e "
const ts = require('typescript');
const fs = require('fs');
const src = fs.readFileSync('src/shared/components/TasksPane/TasksPane.tsx', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
function findProps(node, tag) {
  let res = [];
  (function v(n) {
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      if (n.tagName.getText(sf) === tag) {
        const a = [];
        if (n.attributes && n.attributes.properties)
          n.attributes.properties.forEach(x => { if (ts.isJsxAttribute(x) && x.name) a.push(x.name.getText(sf)); });
        res.push(a);
      }
    }
    ts.forEachChild(n, v);
  })(node);
  return res;
}
const all = findProps(sf, 'MediaLightbox');
if (all.some(p => p.includes('showVideoTrimEditor'))) { console.log('PASS: showVideoTrimEditor found'); process.exit(0); }
else { console.log('FAIL: showVideoTrimEditor missing'); process.exit(1); }
" 2>&1
if [ $? -eq 0 ]; then
  GATE2=25
  echo "Gate 2 PASS (0.25)"
fi
add_reward $GATE2

###############################################################################
# Gate 3 (F2P) — currentSegmentImages prop [weight 0.20]
# Verifies constituent images data is passed so the lightbox can display
# start/end images for the segment (the chevron/navigation context).
# Fails on unmodified base; passes on correct fix.
###############################################################################
echo "=== Gate 3: currentSegmentImages prop in TasksPane (F2P, 0.20) ==="
GATE3=0
node -e "
const ts = require('typescript');
const fs = require('fs');
const src = fs.readFileSync('src/shared/components/TasksPane/TasksPane.tsx', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
function findProps(node, tag) {
  let res = [];
  (function v(n) {
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      if (n.tagName.getText(sf) === tag) {
        const a = [];
        if (n.attributes && n.attributes.properties)
          n.attributes.properties.forEach(x => { if (ts.isJsxAttribute(x) && x.name) a.push(x.name.getText(sf)); });
        res.push(a);
      }
    }
    ts.forEachChild(n, v);
  })(node);
  return res;
}
const all = findProps(sf, 'MediaLightbox');
if (all.some(p => p.includes('currentSegmentImages'))) { console.log('PASS: currentSegmentImages found'); process.exit(0); }
else { console.log('FAIL: currentSegmentImages missing'); process.exit(1); }
" 2>&1
if [ $? -eq 0 ]; then
  GATE3=20
  echo "Gate 3 PASS (0.20)"
fi
add_reward $GATE3

###############################################################################
# Gate 4 (F2P) — currentFrameCount prop [weight 0.20]
# Verifies that the frame count is passed so the lightbox can show the
# correct segment frame count for the video trim editor.
# Fails on unmodified base; passes on correct fix.
###############################################################################
echo "=== Gate 4: currentFrameCount prop in TasksPane (F2P, 0.20) ==="
GATE4=0
node -e "
const ts = require('typescript');
const fs = require('fs');
const src = fs.readFileSync('src/shared/components/TasksPane/TasksPane.tsx', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
function findProps(node, tag) {
  let res = [];
  (function v(n) {
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      if (n.tagName.getText(sf) === tag) {
        const a = [];
        if (n.attributes && n.attributes.properties)
          n.attributes.properties.forEach(x => { if (ts.isJsxAttribute(x) && x.name) a.push(x.name.getText(sf)); });
        res.push(a);
      }
    }
    ts.forEachChild(n, v);
  })(node);
  return res;
}
const all = findProps(sf, 'MediaLightbox');
if (all.some(p => p.includes('currentFrameCount'))) { console.log('PASS: currentFrameCount found'); process.exit(0); }
else { console.log('FAIL: currentFrameCount missing'); process.exit(1); }
" 2>&1
if [ $? -eq 0 ]; then
  GATE4=20
  echo "Gate 4 PASS (0.20)"
fi
add_reward $GATE4

###############################################################################
# Gate 5 (P2P) — SegmentOutputStrip still passes shotId [weight 0.10]
# Regression guard: the working reference (SegmentOutputStrip) must still
# pass shotId to MediaLightbox. Passes on both unmodified base and fix.
###############################################################################
echo "=== Gate 5: SegmentOutputStrip regression guard (P2P, 0.10) ==="
GATE5=0
node -e "
const ts = require('typescript');
const fs = require('fs');
const src = fs.readFileSync('src/tools/travel-between-images/components/Timeline/SegmentOutputStrip.tsx', 'utf8');
const sf = ts.createSourceFile('f.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
function findProps(node, tag) {
  let res = [];
  (function v(n) {
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) {
      if (n.tagName.getText(sf) === tag) {
        const a = [];
        if (n.attributes && n.attributes.properties)
          n.attributes.properties.forEach(x => { if (ts.isJsxAttribute(x) && x.name) a.push(x.name.getText(sf)); });
        res.push(a);
      }
    }
    ts.forEachChild(n, v);
  })(node);
  return res;
}
const all = findProps(sf, 'MediaLightbox');
if (all.length === 0) { console.log('FAIL: No MediaLightbox in SegmentOutputStrip'); process.exit(1); }
if (all.some(p => p.includes('shotId'))) { console.log('PASS: SegmentOutputStrip still has shotId'); process.exit(0); }
else { console.log('FAIL: SegmentOutputStrip lost shotId (regression!)'); process.exit(1); }
" 2>&1
if [ $? -eq 0 ]; then
  GATE5=10
  echo "Gate 5 PASS (0.10)"
fi
add_reward $GATE5

###############################################################################
# Summary
###############################################################################
FINAL=$(awk "BEGIN {printf \"%.2f\", $TOTAL/100}")
echo ""
echo "=== RESULTS ==="
echo "Gate 1 (F2P - tsc+shotId):              $(awk "BEGIN {printf \"%.2f\", $GATE1/100}") / 0.25"
echo "Gate 2 (F2P - showVideoTrimEditor):     $(awk "BEGIN {printf \"%.2f\", $GATE2/100}") / 0.25"
echo "Gate 3 (F2P - currentSegmentImages):    $(awk "BEGIN {printf \"%.2f\", $GATE3/100}") / 0.20"
echo "Gate 4 (F2P - currentFrameCount):       $(awk "BEGIN {printf \"%.2f\", $GATE4/100}") / 0.20"
echo "Gate 5 (P2P - SegmentOutputStrip):      $(awk "BEGIN {printf \"%.2f\", $GATE5/100}") / 0.10"
echo "TOTAL: $FINAL / 1.00"
echo ""
echo "Final reward: $FINAL"
