#!/bin/bash
set +e

mkdir -p /logs/verifier
cd /workspace/repo

SCORE=0

######################################################################
# P2P Gate 1: TypeScript compilation check (weight 0.05)
# Passes on unmodified base AND on correct fix.
# Guards against regressions — agent must not break compilation.
######################################################################
echo "=== P2P Gate 1: TypeScript compilation ==="
npx tsc --noEmit 2>&1 | tail -20
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
  echo "PASS: TypeScript compilation succeeded"
  SCORE=$(node -e "process.stdout.write(String($SCORE + 0.05))")
else
  echo "FAIL: TypeScript compilation failed"
fi

######################################################################
# F2P Gate 2: buildTaskParams preserves phase_config when a preset is
# selected in basic mode (weight 0.35)
#
# Bug: Original code unconditionally drops phase_config in basic mode:
#   phase_config: settings.motionMode === 'basic' ? undefined : settings.phaseConfig
# Fix: Any change that makes phase_config available when a preset is
# selected, regardless of motionMode.
#
# Test: Find the phase_config expression in buildTaskParams. Extract it
# (may span multiple lines). Evaluate with test inputs.
######################################################################
echo "=== F2P Gate 2: buildTaskParams phase_config gate ==="
GATE2_RESULT=$(node -e "
const fs = require('fs');
const paths = [
  'src/shared/components/segmentSettingsUtils.ts',
  'src/shared/components/SegmentSettingsForm/segmentSettingsUtils.ts'
];
let src = '';
for (const p of paths) {
  try { src = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (!src) { console.log('FAIL'); process.exit(0); }

// Find buildTaskParams, then find phase_config: within 200 lines after it
const fnIdx = src.indexOf('buildTaskParams');
if (fnIdx === -1) { console.log('FAIL'); process.exit(0); }
const afterFn = src.substring(fnIdx);
const lines = afterFn.split('\n').slice(0, 200);

let exprLines = [];
let collecting = false;
for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  if (!collecting) {
    // Match phase_config as an object key (not in comment/type)
    if (line.trim().startsWith('//') || line.trim().startsWith('*')) continue;
    const keyMatch = line.match(/phase_config:\s*(.*)/);
    if (keyMatch) {
      const val = keyMatch[1];
      exprLines.push(val);
      if (val.trim().endsWith(',')) break;
      collecting = true;
      continue;
    }
  } else {
    const trimmed = line.trim();
    // Stop at next object key (word: at start of line, not ternary ? or :)
    if (/^[a-z_]\w*\s*:/i.test(trimmed)) break;
    exprLines.push(line);
    if (trimmed.endsWith(',') || trimmed.endsWith('),')) break;
    if (exprLines.length > 10) break;
  }
}

const expr = exprLines.join(' ').trim().replace(/,\s*$/, '');
if (!expr) { console.log('FAIL'); process.exit(0); }

// Test scenario: basic mode, preset selected, phaseConfig set
const settings = {
  motionMode: 'basic',
  selectedPhasePresetId: 'test-preset-id',
  phaseConfig: { phases: [{ strength: 0.5, duration: 1.0 }] }
};

try {
  const result = new Function('settings', 'return (' + expr + ')')(settings);
  console.log(result !== undefined && result !== null ? 'PASS' : 'FAIL');
} catch(e) {
  // Fallback: structural check on the expression
  if (expr.includes('selectedPhasePresetId') || expr.includes('selected_phase_preset_id')) {
    console.log('PASS');
  } else if (!expr.includes('basic')) {
    console.log('PASS');
  } else {
    console.log('FAIL');
  }
}
" 2>&1)
echo "Gate 2 result: $GATE2_RESULT"
if [ "$GATE2_RESULT" = "PASS" ]; then
  SCORE=$(node -e "process.stdout.write(String($SCORE + 0.35))")
fi

######################################################################
# F2P Gate 3: individualTravelSegment includes selected_phase_preset_id
# in its output object (weight 0.25)
#
# Bug: buildIndividualTravelSegmentParams accepts selected_phase_preset_id
# but never writes it to individualSegmentParams or taskParams output.
# Fix: Include it in the output object(s).
#
# Test: Check that selected_phase_preset_id appears in an assignment
# or object literal context in the function output, not just in
# types/params.
######################################################################
echo "=== F2P Gate 3: individualTravelSegment preset ID passthrough ==="
GATE3_RESULT=$(node -e "
const fs = require('fs');
const paths = [
  'src/shared/modules/individualTravelSegment.ts',
  'src/shared/lib/tasks/individualTravelSegment.ts'
];
let src = '';
for (const p of paths) {
  try { src = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (!src) { console.log('FAIL'); process.exit(0); }

// Check for selected_phase_preset_id being ASSIGNED to output objects
// (not just declared in interfaces/types/parameters)
// Patterns we accept:
// 1. individualSegmentParams.selected_phase_preset_id = ...
// 2. selected_phase_preset_id: ... (inside output object literal)
// 3. taskParams.selected_phase_preset_id = ...
// 4. ...spread that includes it

const assignmentPatterns = [
  /individualSegmentParams\s*\.\s*selected_phase_preset_id\s*=/,
  /taskParams\s*\.\s*selected_phase_preset_id\s*=/,
  /orchestratorDetails\s*\.\s*selected_phase_preset_id\s*=/,
];

let found = false;
for (const pat of assignmentPatterns) {
  if (pat.test(src)) { found = true; break; }
}

// Also check spread patterns: ...(params.selected_phase_preset_id ? { selected_phase_preset_id: ... } : {})
if (!found) {
  if (/selected_phase_preset_id\s*\?\s*\{\s*selected_phase_preset_id/.test(src)) {
    found = true;
  }
}

// Count occurrences to detect if it was added to output
// Base has ~3 occurrences (interface, param type, destructuring)
// Fixed has more (added to output objects)
if (!found) {
  const occurrences = (src.match(/selected_phase_preset_id/g) || []).length;
  if (occurrences > 5) { found = true; }
}

console.log(found ? 'PASS' : 'FAIL');
" 2>&1)
echo "Gate 3 result: $GATE3_RESULT"
if [ "$GATE3_RESULT" = "PASS" ]; then
  SCORE=$(node -e "process.stdout.write(String($SCORE + 0.25))")
fi

######################################################################
# F2P Gate 4: Preset selection ensures phase_config reaches task —
# either by fixing the buildTaskParams gate to consider preset state,
# OR by switching to advanced mode on preset select (weight 0.30)
#
# Both approaches are valid fixes for the reported bug.
######################################################################
echo "=== F2P Gate 4: Preset selection ensures phase_config reaches task ==="
GATE4_RESULT=$(node -e "
const fs = require('fs');
let passed = false;

// Approach A: buildTaskParams gate references selectedPhasePresetId
const utilPaths = [
  'src/shared/components/segmentSettingsUtils.ts',
  'src/shared/components/SegmentSettingsForm/segmentSettingsUtils.ts'
];
let utilSrc = '';
for (const p of utilPaths) {
  try { utilSrc = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (utilSrc) {
  const fnIdx = utilSrc.indexOf('buildTaskParams');
  if (fnIdx !== -1) {
    const afterFn = utilSrc.substring(fnIdx);
    const lines = afterFn.split('\n').slice(0, 200);
    // Find phase_config: and collect the expression
    let exprText = '';
    let collecting = false;
    for (const line of lines) {
      if (!collecting) {
        if (line.trim().startsWith('//')) continue;
        const m = line.match(/phase_config:\s*(.*)/);
        if (m) {
          exprText += m[1] + ' ';
          if (m[1].trim().endsWith(',')) break;
          collecting = true;
        }
      } else {
        const trimmed = line.trim();
        if (/^[a-z_]\w*\s*:/i.test(trimmed)) break;
        exprText += trimmed + ' ';
        if (trimmed.endsWith(',') || trimmed.endsWith('),')) break;
      }
    }
    // Check if the expression references preset state
    if (exprText.includes('selectedPhasePresetId') || exprText.includes('selected_phase_preset_id')) {
      passed = true;
    }
    // If basic mode gate removed entirely
    if (exprText && !exprText.includes('basic')) {
      passed = true;
    }
  }
}

// Approach B: handlePhasePresetSelect sets motionMode to 'advanced'
if (!passed) {
  const formPaths = [
    'src/shared/components/SegmentSettingsForm/SegmentSettingsForm.tsx',
    'src/shared/components/SegmentSettingsForm.tsx'
  ];
  let formSrc = '';
  for (const p of formPaths) {
    try { formSrc = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
  }
  if (formSrc) {
    // Find handlePhasePresetSelect and check for motionMode: 'advanced'
    const fnIdx = formSrc.indexOf('handlePhasePresetSelect');
    if (fnIdx !== -1) {
      const chunk = formSrc.substring(fnIdx, fnIdx + 500);
      if (chunk.includes('motionMode') && chunk.includes('advanced')) {
        passed = true;
      }
    }
  }
}

console.log(passed ? 'PASS' : 'FAIL');
" 2>&1)
echo "Gate 4 result: $GATE4_RESULT"
if [ "$GATE4_RESULT" = "PASS" ]; then
  SCORE=$(node -e "process.stdout.write(String($SCORE + 0.30))")
fi

######################################################################
# P2P Gate 5: Key functions and types exist (weight 0.05)
# Passes on unmodified base AND correct fix.
# Ensures agent didn't delete critical code.
######################################################################
echo "=== P2P Gate 5: Key functions exist ==="
GATE5_RESULT=$(node -e "
const fs = require('fs');
let allFound = true;

// Check buildTaskParams exists in segmentSettingsUtils
const utilPaths = [
  'src/shared/components/segmentSettingsUtils.ts',
  'src/shared/components/SegmentSettingsForm/segmentSettingsUtils.ts'
];
let utilSrc = '';
for (const p of utilPaths) {
  try { utilSrc = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (!utilSrc || !utilSrc.includes('buildTaskParams')) allFound = false;
if (!utilSrc || !utilSrc.includes('selectedPhasePresetId')) allFound = false;

// Check handlePhasePresetSelect exists
const formPaths = [
  'src/shared/components/SegmentSettingsForm/SegmentSettingsForm.tsx',
  'src/shared/components/SegmentSettingsForm.tsx'
];
let formSrc = '';
for (const p of formPaths) {
  try { formSrc = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (!formSrc || !formSrc.includes('handlePhasePresetSelect')) allFound = false;

// Check individualTravelSegment function exists
const travelPaths = [
  'src/shared/modules/individualTravelSegment.ts',
  'src/shared/lib/tasks/individualTravelSegment.ts'
];
let travelSrc = '';
for (const p of travelPaths) {
  try { travelSrc = fs.readFileSync(p, 'utf8'); break; } catch(e) {}
}
if (!travelSrc || !travelSrc.includes('buildIndividualTravelSegmentParams')) allFound = false;

console.log(allFound ? 'PASS' : 'FAIL');
" 2>&1)
echo "Gate 5 result: $GATE5_RESULT"
if [ "$GATE5_RESULT" = "PASS" ]; then
  SCORE=$(node -e "process.stdout.write(String($SCORE + 0.05))")
fi

######################################################################
# Write final score
######################################################################
echo ""
echo "=== Final Score ==="
echo "Score: $SCORE"
echo "$SCORE" > /logs/verifier/reward.txt
