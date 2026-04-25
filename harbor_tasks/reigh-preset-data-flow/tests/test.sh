#!/bin/bash
set +e

mkdir -p /logs/verifier
cd /workspace/repo 2>/dev/null || cd /workspace/$(ls /workspace | head -1)

REWARD=0

add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.4f", a+b}')
}

#######################################
# Locate key files
#######################################
UTIL_FILE=""
for p in src/shared/components/segmentSettingsUtils.ts src/shared/components/SegmentSettingsForm/segmentSettingsUtils.ts; do
  [ -f "$p" ] && UTIL_FILE="$p" && break
done

ITS_FILE=""
for p in src/shared/lib/tasks/individualTravelSegment.ts src/shared/modules/individualTravelSegment.ts; do
  [ -f "$p" ] && ITS_FILE="$p" && break
done

HOOK_FILE=""
for p in src/shared/hooks/segments/useSegmentSettings.ts; do
  [ -f "$p" ] && HOOK_FILE="$p" && break
done

echo "UTIL_FILE=$UTIL_FILE"
echo "ITS_FILE=$ITS_FILE"
echo "HOOK_FILE=$HOOK_FILE"

# If we can't find the key file, we cannot evaluate — emit 0.
if [ -z "$UTIL_FILE" ] || [ -z "$ITS_FILE" ]; then
  echo "Required source files missing"
  echo "0.0000" > /logs/verifier/reward.txt
  exit 0
fi

#######################################
# P2P GATE (gating-only, no reward): TypeScript still compiles.
# This guards against destructive edits. It does NOT award reward
# because the unmodified base already compiles.
#######################################
echo "=== P2P Gate: TypeScript compiles (gating only) ==="
if [ -f tsconfig.json ]; then
  TSC_OUT=$(npx --no-install tsc --noEmit 2>&1)
  TSC_EXIT=$?
  echo "$TSC_OUT" | tail -30
  if [ "$TSC_EXIT" != "0" ]; then
    echo "REGRESSION: tsc broken — zeroing out"
    echo "0.0000" > /logs/verifier/reward.txt
    exit 0
  fi
  echo "PASS: tsc (gating)"
fi

#######################################
# F2P Gate A (weight 0.45): buildTaskParams must NOT unconditionally drop
# phase_config when motionMode === 'basic'. On the buggy base, the line:
#   phase_config: settings.motionMode === 'basic' ? undefined : settings.phaseConfig
# always returns undefined for basic mode regardless of preset. The fix
# must allow phase_config to flow through when a non-builtin preset is
# selected in basic mode.
#######################################
echo "=== F2P Gate A: buildTaskParams returns phase_config when preset selected in basic mode ==="
GATEA=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");

  // Find the buildTaskParams function block.
  const fnIdx = src.indexOf("buildTaskParams");
  if (fnIdx === -1) { console.log("FAIL:no-fn"); process.exit(0); }

  // Extract the phase_config expression (multiline-aware).
  const after = src.substring(fnIdx);
  const pcIdx = after.indexOf("phase_config");
  if (pcIdx === -1) { console.log("FAIL:no-phase_config"); process.exit(0); }
  const tail = after.substring(pcIdx);

  // Read until matching balanced end-of-property: walk char by char,
  // stop at top-level comma or closing brace.
  const colonIdx = tail.indexOf(":");
  if (colonIdx === -1) { console.log("FAIL"); process.exit(0); }
  let i = colonIdx + 1;
  let depth = 0;
  let expr = "";
  while (i < tail.length) {
    const ch = tail[i];
    if (depth === 0 && (ch === "," || ch === "\n" && /^[a-z_]/i.test(tail.substring(i+1).trimStart()))) {
      // try comma boundary
      if (ch === ",") break;
    }
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") {
      if (depth === 0) break;
      depth--;
    }
    expr += ch;
    i++;
  }
  expr = expr.trim();
  if (!expr) { console.log("FAIL:empty"); process.exit(0); }

  // Detect known builtin id constants from the file (best effort).
  const idConstMatches = [...src.matchAll(/(BUILTIN_[A-Z0-9_]*PRESET[A-Z0-9_]*_ID|BUILTIN_[A-Z0-9_]*PRESET\.id)/g)];
  const idConstNames = [...new Set(idConstMatches.map(m => m[1]))];

  // Build a sandbox eval. Provide stand-ins for any identifier referenced
  // beyond settings.* — we replace bare identifiers with placeholders.
  const PRESET_ID = "user-preset-xyz";
  const PHASE_CFG = { phases: [{ strength: 0.5, duration: 1.0 }] };
  const BUILTIN_I2V_PRESET_ID = "builtin-i2v";
  const BUILTIN_VACE_PRESET_ID = "builtin-vace";
  const BUILTIN_I2V_PRESET = { id: BUILTIN_I2V_PRESET_ID };
  const BUILTIN_VACE_PRESET = { id: BUILTIN_VACE_PRESET_ID };

  function evalExpr(settings) {
    try {
      const f = new Function(
        "settings",
        "BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID",
        "BUILTIN_I2V_PRESET","BUILTIN_VACE_PRESET",
        "return (" + expr + ");"
      );
      return f(settings,
        BUILTIN_I2V_PRESET_ID, BUILTIN_VACE_PRESET_ID,
        BUILTIN_I2V_PRESET, BUILTIN_VACE_PRESET);
    } catch (e) {
      return { __err: e.message };
    }
  }

  // Scenario A: basic + non-builtin preset → MUST NOT be undefined
  const a = evalExpr({
    motionMode: "basic",
    selectedPhasePresetId: PRESET_ID,
    phaseConfig: PHASE_CFG
  });
  // Scenario B: advanced → MUST keep phaseConfig
  const b = evalExpr({
    motionMode: "advanced",
    selectedPhasePresetId: undefined,
    phaseConfig: PHASE_CFG
  });
  // Scenario C: basic + no preset → either undefined OR phaseConfig (both acceptable)
  const c = evalExpr({
    motionMode: "basic",
    selectedPhasePresetId: undefined,
    phaseConfig: PHASE_CFG
  });

  const isErr = (x) => x && typeof x === "object" && "__err" in x;
  if (isErr(a) || isErr(b)) { console.log("FAIL:eval-err:" + (a.__err||b.__err)); process.exit(0); }

  const aOk = a !== undefined;            // basic+preset must NOT drop
  const bOk = b !== undefined;            // advanced must keep
  // c is unconstrained — but we want to make sure the change isnt simply
  // "always return phaseConfig" without any thought; both are acceptable.

  // Crucially: on the BUGGY BASE, expr is exactly:
  //   settings.motionMode === "basic" ? undefined : settings.phaseConfig
  // which makes a === undefined → aOk === false → FAIL.

  if (aOk && bOk) console.log("PASS");
  else console.log("FAIL:a=" + JSON.stringify(a) + " b=" + JSON.stringify(b));
' "$UTIL_FILE" 2>&1)
echo "Gate A: $GATEA"
if [[ "$GATEA" == PASS* ]]; then add_reward 0.45; fi

#######################################
# F2P Gate B (weight 0.45): individualTravelSegment must propagate
# selected_phase_preset_id from incoming `params` into one of its output
# objects (taskParams / individualSegmentParams / orchestratorDetails /
# orchDetails) — i.e. it must appear on the WRITE side, not just be
# destructured/typed.
# On the buggy base, the id is referenced in types/destructuring only and
# never written to any output sink.
#######################################
echo "=== F2P Gate B: individualTravelSegment writes selected_phase_preset_id to an output ==="
GATEB=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");

  // Behavioral signal: there exists a line that ASSIGNS or includes
  // selected_phase_preset_id into one of the known output sinks.
  const writePatterns = [
    // direct property assignment
    /\b(individualSegmentParams|taskParams|orchestratorDetails|orchDetails)\s*\.\s*selected_phase_preset_id\s*=/,
    // object key with reference value (not just shorthand or type)
    /selected_phase_preset_id\s*:\s*(params\s*\.\s*selected_phase_preset_id|selected_phase_preset_id|[a-zA-Z_$][\w$]*\s*\?\?|[a-zA-Z_$][\w$]*\s*\|\||null|undefined|".*"|`.*`)/,
    // conditional spread inside an output object literal: {..., ...(... && { selected_phase_preset_id ... }), ...}
    /\.\.\.\s*\([^)]*selected_phase_preset_id[^)]*\)\s*&&\s*\{\s*selected_phase_preset_id/,
    /&&\s*\{\s*selected_phase_preset_id\s*:/,
    /&&\s*\{\s*selected_phase_preset_id\s*\}/,
  ];

  let writeHit = writePatterns.some(p => p.test(src));

  // Sanity floor — base file references the id only in
  // type definitions / destructuring (typically <=3). A real fix bumps it.
  const occ = (src.match(/selected_phase_preset_id/g) || []).length;

  // Confirm the reference is in an OUTPUT context: search for an object
  // literal that contains both an output-sink-ish key (orchestrator_details,
  // individual_segment_params, motion_mode, phase_config) AND
  // selected_phase_preset_id within ~600 chars.
  let contextHit = false;
  const sinks = ["orchestrator_details", "individual_segment_params", "motion_mode", "phase_config", "amount_of_motion", "advanced_mode"];
  for (const sink of sinks) {
    let idx = 0;
    while ((idx = src.indexOf(sink, idx)) !== -1) {
      const window = src.substring(Math.max(0,idx-600), idx+600);
      if (/selected_phase_preset_id/.test(window) &&
          !/^\s*\/\//m.test(window.split(/selected_phase_preset_id/)[0].split("\n").slice(-1)[0] || "")) {
        contextHit = true;
        break;
      }
      idx += sink.length;
    }
    if (contextHit) break;
  }

  if (writeHit && contextHit && occ >= 4) console.log("PASS");
  else console.log("FAIL writeHit=" + writeHit + " contextHit=" + contextHit + " occ=" + occ);
' "$ITS_FILE" 2>&1)
echo "Gate B: $GATEB"
if [[ "$GATEB" == PASS* ]]; then add_reward 0.45; fi

#######################################
# F2P Gate C (weight 0.10): End-to-end coherence — when both fixes are
# applied, the buildTaskParams output for "basic + preset" includes a
# truthy phase_config AND the ITS file references selected_phase_preset_id
# in a write context. This rewards solutions that fix BOTH halves
# together (the user's complaint had two parts).
#######################################
echo "=== F2P Gate C: end-to-end (both fixes coherent) ==="
if [[ "$GATEA" == PASS* ]] && [[ "$GATEB" == PASS* ]]; then
  echo "Gate C: PASS"
  add_reward 0.10
else
  echo "Gate C: FAIL (need both A and B)"
fi

echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt