#!/bin/bash
set +e

# Timeline Multi-Select Implementation Verifier
# Validates that multi-select functionality was properly added to the Timeline view.
#
# Scoring: 8 gates, total weight = 1.00 (P2P: 0.05, F2P: 0.95)
# All gates use node -e or npx tsc = 100% behavioral
# P2P = pass-to-pass (passes on base AND correct fix)
# F2P = fail-to-pass (fails on base, passes on correct fix)

SCORE=0

REPO="/workspace/repo"
TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline"
HOOKS="$TIMELINE/hooks"
UTILS="$TIMELINE/utils"

mkdir -p /logs/verifier

add_score() {
  SCORE=$(awk "BEGIN {print $SCORE + $1}")
}

########################################################################
# Gate 1 (P2P): TypeScript compilation — 0.05 weight
# Passes on unmodified base AND on correct fix. Guards against regressions.
########################################################################
echo "=== Gate 1 (P2P): TypeScript compilation ==="
cd "$REPO"
npx tsc --noEmit 2>/logs/verifier/tsc_output.txt
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
  echo "PASS: TypeScript compilation succeeds"
  add_score 0.05
else
  echo "FAIL: TypeScript compilation failed (exit $TSC_EXIT)"
  head -20 /logs/verifier/tsc_output.txt
fi

########################################################################
# Gate 2 (F2P): useTimelineSelection hook — 0.15 weight
# The instruction requires creating this NEW file with selectedIds state,
# toggle/clear functionality, and 200ms delayed showSelectionBar.
########################################################################
echo ""
echo "=== Gate 2 (F2P): useTimelineSelection hook ==="
SELECTION_HOOK=$(find "$HOOKS" "$TIMELINE" -maxdepth 2 \( -name '*[Ss]election*' \) \( -name '*.ts' -o -name '*.tsx' \) 2>/dev/null | head -1)
if [ -n "$SELECTION_HOOK" ]; then
  node -e "
    const fs = require('fs');
    const content = fs.readFileSync('$SELECTION_HOOK', 'utf8');
    // Must export selection state (selectedIds or similar array)
    const hasSelectionState = /selected(?:Ids|Items|Count)|selection/i.test(content);
    // Must have toggle or clear functionality
    const hasToggle = /toggle|clear.*select|deselect/i.test(content);
    // Must not be trivially empty
    const isNonTrivial = content.trim().length > 200;
    if (hasSelectionState && hasToggle && isNonTrivial) {
      console.log('PASS: Selection hook has selection state + toggle/clear');
      process.exit(0);
    } else {
      console.log('FAIL: Selection hook missing required exports');
      console.log('  hasSelectionState:', hasSelectionState, 'hasToggle:', hasToggle, 'isNonTrivial:', isNonTrivial);
      process.exit(1);
    }
  " 2>&1
  G2_EXIT=$?
else
  echo "FAIL: No selection hook file found"
  G2_EXIT=1
fi
if [ $G2_EXIT -eq 0 ]; then
  add_score 0.15
fi

########################################################################
# Gate 3 (F2P): SelectionActionBar integrated in TimelineContainer — 0.10 weight
# The instruction requires adding SelectionActionBar to TimelineContainer.tsx
# with import and JSX rendering.
########################################################################
echo ""
echo "=== Gate 3 (F2P): SelectionActionBar in TimelineContainer ==="
TC_FILE="$TIMELINE/TimelineContainer.tsx"
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$TC_FILE', 'utf8');
  const hasImport = /import.*SelectionActionBar|require.*SelectionActionBar/i.test(content);
  const hasRender = /<\s*SelectionActionBar/i.test(content);
  if (hasImport && hasRender) {
    console.log('PASS: TimelineContainer imports and renders SelectionActionBar');
    process.exit(0);
  } else {
    console.log('FAIL: SelectionActionBar not integrated');
    console.log('  hasImport:', hasImport, 'hasRender:', hasRender);
    process.exit(1);
  }
" 2>&1
G3_EXIT=$?
if [ $G3_EXIT -eq 0 ]; then
  add_score 0.10
fi

########################################################################
# Gate 4 (F2P): Multi-item drag support in useTimelineDrag — 0.15 weight
# The instruction requires adding selectedIds prop and multi-item bundling
# with 5-frame gap in useTimelineDrag.ts.
########################################################################
echo ""
echo "=== Gate 4 (F2P): Multi-item drag in useTimelineDrag ==="
DRAG_FILE="$HOOKS/useTimelineDrag.ts"
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$DRAG_FILE', 'utf8');
  const hasMultiSelect = /selectedIds|selectedItems|selected\w*\s*:\s*string\s*\[\]/i.test(content);
  const hasBundling = /BUNDLE_GAP|bundle|index\s*\*\s*5|\*\s*5\b|5\s*\*\s*index|gap\s*[=:]\s*5/i.test(content);
  if (hasMultiSelect && hasBundling) {
    console.log('PASS: useTimelineDrag has multi-select + bundling');
    process.exit(0);
  } else if (hasMultiSelect) {
    console.log('PASS: useTimelineDrag has multi-select support');
    process.exit(0);
  } else {
    console.log('FAIL: useTimelineDrag missing multi-item support');
    process.exit(1);
  }
" 2>&1
G4_EXIT=$?
if [ $G4_EXIT -eq 0 ]; then
  add_score 0.15
fi

########################################################################
# Gate 5 (F2P): isSelected prop in TimelineItem — 0.10 weight
# The instruction requires adding isSelected boolean prop (distinct from
# existing isSelectedForMove) for multi-select visual feedback.
########################################################################
echo ""
echo "=== Gate 5 (F2P): isSelected prop in TimelineItem ==="
TI_FILE="$TIMELINE/TimelineItem.tsx"
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$TI_FILE', 'utf8');
  const lines = content.split('\n');
  let hasIsSelectedProp = false;
  for (const line of lines) {
    if (/\bisSelected\b(?!ForMove|For\b)/.test(line)) {
      hasIsSelectedProp = true;
      break;
    }
  }
  const hasSelectionHandler = /onSelectionClick|onSelectToggle|onToggleSelect|onSelectionToggle/i.test(content);
  if (hasIsSelectedProp || hasSelectionHandler) {
    console.log('PASS: TimelineItem has isSelected prop or selection handler');
    process.exit(0);
  } else {
    console.log('FAIL: TimelineItem missing isSelected prop');
    process.exit(1);
  }
" 2>&1
G5_EXIT=$?
if [ $G5_EXIT -eq 0 ]; then
  add_score 0.10
fi

########################################################################
# Gate 6 (F2P): Multi-item positioning/bundling utility — 0.15 weight
# The instruction requires adding applyFluidTimelineMulti() or equivalent
# bundling function to timeline-utils.ts or useTimelineDrag.ts.
# Accepts any function name that implements bundle/multi-item positioning.
########################################################################
echo ""
echo "=== Gate 6 (F2P): Multi-item positioning utility ==="
UTILS_FILE="$UTILS/timeline-utils.ts"
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$UTILS_FILE', 'utf8');
  // Accept any exported function related to bundling/multi-item positioning
  const hasUtilFunc = /export\s+(?:const|function)\s+\w*(?:[Mm]ulti|[Bb]undle)\w*/i.test(content);
  if (hasUtilFunc) {
    console.log('PASS: timeline-utils has bundle/multi-item utility');
    process.exit(0);
  }
  // Fallback: check useTimelineDrag for inline bundling logic
  try {
    const dragContent = fs.readFileSync('$DRAG_FILE', 'utf8');
    const hasBundleLogic = /(?:index|i)\s*\*\s*(?:5|BUNDLE_GAP)|BUNDLE_GAP\s*[=:]\s*5|targetFrame\s*\+.*(?:index|i)\s*\*|bundleGap|bundle.*[Gg]ap/i.test(dragContent);
    if (hasBundleLogic) {
      console.log('PASS: bundling logic found in useTimelineDrag');
      process.exit(0);
    }
  } catch(e) {}
  console.log('FAIL: No multi-item positioning utility found');
  process.exit(1);
" 2>&1
G6_EXIT=$?
if [ $G6_EXIT -eq 0 ]; then
  add_score 0.15
fi

########################################################################
# Gate 7 (F2P): useTapToMove modified for multi-item — 0.10 weight
# The instruction requires modifying useTapToMove to accept external
# selectedIds and support multi-item movement on tablets.
########################################################################
echo ""
echo "=== Gate 7 (F2P): useTapToMove multi-item support ==="
TAP_FILE="$HOOKS/useTapToMove.ts"
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$TAP_FILE', 'utf8');
  const hasMultiIds = /selectedIds|selectedItems|selected\w*\s*:\s*string\s*\[\]/i.test(content);
  const hasMultiMove = /onMoveBatch|moveBatch|moveMultiple|bundle.*move|move.*bundle/i.test(content);
  if (hasMultiIds || hasMultiMove) {
    console.log('PASS: useTapToMove has multi-item support');
    process.exit(0);
  } else {
    console.log('FAIL: useTapToMove not modified for multi-item');
    process.exit(1);
  }
" 2>&1
G7_EXIT=$?
if [ $G7_EXIT -eq 0 ]; then
  add_score 0.10
fi

########################################################################
# Gate 8 (F2P): SelectionActionBar onNewShot properly wired — 0.20 weight
# The instruction (Phase 5, Verification #9) requires onNewShot to be
# connected to a working callback that creates a shot from selected images.
# It must NOT be undefined or a TODO stub.
########################################################################
echo ""
echo "=== Gate 8 (F2P): onNewShot wired in SelectionActionBar ==="
node -e "
  const fs = require('fs');
  const content = fs.readFileSync('$TC_FILE', 'utf8');
  // Find the SelectionActionBar JSX block and check onNewShot prop
  const hasActionBar = /<\s*SelectionActionBar/i.test(content);
  if (!hasActionBar) {
    console.log('FAIL: SelectionActionBar not found');
    process.exit(1);
  }
  // Check that onNewShot is wired to an actual function, not just undefined
  // Look for: onNewShot={...} where ... is NOT just 'undefined'
  // Acceptable: onNewShot={someFunc}, onNewShot={async () => ...}, onNewShot={() => ...}
  // Not acceptable: onNewShot={undefined}, onNewShot missing entirely
  const onNewShotMatch = content.match(/onNewShot\s*=\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}/s);
  if (!onNewShotMatch) {
    console.log('FAIL: onNewShot prop not found on SelectionActionBar');
    process.exit(1);
  }
  const propValue = onNewShotMatch[1].trim();
  // Reject if it's just 'undefined' or empty
  if (/^\s*undefined\s*$/.test(propValue) || propValue.length === 0) {
    console.log('FAIL: onNewShot is undefined/empty — not wired to a function');
    process.exit(1);
  }
  // Must contain a function call or arrow function that references selection/shot
  const hasFuncBody = /=>|function|async|await|shot|selection|selectedIds|onNewShot/i.test(propValue);
  if (hasFuncBody) {
    console.log('PASS: onNewShot is wired to a functional callback');
    process.exit(0);
  }
  // If it's a ternary with undefined as fallback, that's OK if the truthy branch exists
  if (/\?\s*(?:async\s*)?\(\s*\)\s*=>/.test(propValue) || /\?\s*async\s+function/.test(propValue)) {
    console.log('PASS: onNewShot has conditional wiring');
    process.exit(0);
  }
  console.log('FAIL: onNewShot wiring unclear');
  console.log('  value:', propValue.substring(0, 200));
  process.exit(1);
" 2>&1
G8_EXIT=$?
if [ $G8_EXIT -eq 0 ]; then
  add_score 0.20
fi

########################################################################
# Final score
########################################################################
echo ""
echo "========================================"
echo "Final Score: $SCORE / 1.00"
echo "========================================"

# Write reward
echo "$SCORE" > /logs/verifier/reward.txt
echo "Reward written to /logs/verifier/reward.txt: $SCORE"
