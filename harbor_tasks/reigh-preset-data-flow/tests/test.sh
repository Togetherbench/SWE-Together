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

#######################################
# P2P Gate 1: TypeScript compilation (weight 0.10)
#######################################
echo "=== P2P Gate 1: TypeScript compiles ==="
if [ -f tsconfig.json ]; then
  npx --no-install tsc --noEmit 2>&1 | tail -30
  TSC_EXIT=${PIPESTATUS[0]}
  if [ "$TSC_EXIT" = "0" ]; then
    echo "PASS: tsc"
    add_reward 0.10
  else
    echo "FAIL: tsc"
  fi
else
  add_reward 0.10
fi

#######################################
# F2P Gate 2: Behavioral — buildTaskParams emits phase_config when a
# preset is selected in basic mode (weight 0.35)
#######################################
echo "=== F2P Gate 2: buildTaskParams behavior with preset in basic mode ==="
GATE2="FAIL"
if [ -n "$UTIL_FILE" ]; then
  # Extract phase_config expression inside buildTaskParams.
  GATE2=$(node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const fnIdx = src.indexOf("buildTaskParams");
    if (fnIdx === -1) { console.log("FAIL"); process.exit(0); }
    const after = src.substring(fnIdx);
    const lines = after.split("\n").slice(0, 400);
    let exprLines = [];
    let collecting = false;
    let depth = 0;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!collecting) {
        const t = line.trim();
        if (t.startsWith("//") || t.startsWith("*")) continue;
        const m = line.match(/phase_config:\s*(.*)$/);
        if (m) {
          let val = m[1];
          exprLines.push(val);
          for (const ch of val) {
            if (ch === "(" || ch === "{" || ch === "[") depth++;
            else if (ch === ")" || ch === "}" || ch === "]") depth--;
          }
          if (depth <= 0 && val.trim().endsWith(",")) break;
          collecting = true;
        }
      } else {
        const t = line.trim();
        if (depth <= 0 && /^[a-z_][\w]*\s*:/i.test(t)) break;
        exprLines.push(line);
        for (const ch of line) {
          if (ch === "(" || ch === "{" || ch === "[") depth++;
          else if (ch === ")" || ch === "}" || ch === "]") depth--;
        }
        if (depth <= 0 && (t.endsWith(",") || t.endsWith("),"))) break;
        if (exprLines.length > 30) break;
      }
    }
    let expr = exprLines.join(" ").trim().replace(/,\s*$/, "");
    if (!expr) { console.log("FAIL"); process.exit(0); }

    const PRESET_ID = "user-preset-xyz";
    const PHASE_CFG = { phases: [{ strength: 0.5, duration: 1.0 }] };
    const BUILTIN_I2V_PRESET_ID = "builtin-i2v";
    const BUILTIN_VACE_PRESET_ID = "builtin-vace";

    function evalExpr(settings) {
      try {
        const f = new Function(
          "settings",
          "BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID",
          "return (" + expr + ");"
        );
        return f(settings, BUILTIN_I2V_PRESET_ID, BUILTIN_VACE_PRESET_ID);
      } catch (e) {
        return "__ERR__:" + e.message;
      }
    }

    // Scenario A: basic mode + non-builtin preset selected => should KEEP phase_config
    const a = evalExpr({
      motionMode: "basic",
      selectedPhasePresetId: PRESET_ID,
      phaseConfig: PHASE_CFG
    });
    // Scenario B: advanced mode => should keep phase_config
    const b = evalExpr({
      motionMode: "advanced",
      selectedPhasePresetId: undefined,
      phaseConfig: PHASE_CFG
    });

    let aOk = (a !== undefined && a !== null && typeof a !== "string");
    let bOk = (b !== undefined && b !== null && typeof b !== "string");

    // If expression cannot be evaluated (e.g. references imports), fall back to
    // structural reasoning: must NOT unconditionally drop in basic mode.
    if (typeof a === "string" && a.startsWith("__ERR__")) {
      const dropsAlwaysInBasic =
        /motionMode\s*===\s*[\x27"]basic[\x27"]\s*\?\s*undefined\s*:\s*settings\.phaseConfig/.test(expr) &&
        !expr.includes("selectedPhasePresetId");
      if (!dropsAlwaysInBasic && (expr.includes("selectedPhasePresetId") || !expr.includes("basic"))) {
        aOk = true;
        bOk = true;
      }
    }

    if (aOk && bOk) console.log("PASS");
    else if (aOk || bOk) console.log("PARTIAL");
    else console.log("FAIL");
  ' "$UTIL_FILE" 2>&1)
fi
echo "Gate 2: $GATE2"
case "$GATE2" in
  PASS)    add_reward 0.35 ;;
  PARTIAL) add_reward 0.18 ;;
esac

#######################################
# F2P Gate 3: Behavioral — selected_phase_preset_id flows from caller
# params into the OUTPUT (taskParams or individualSegmentParams or
# orchestratorDetails) of individualTravelSegment (weight 0.30)
#######################################
echo "=== F2P Gate 3: individualTravelSegment passes selected_phase_preset_id through ==="
GATE3="FAIL"
if [ -n "$ITS_FILE" ]; then
  GATE3=$(node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");

    // Behavioral signal: the preset id must be assigned/spread into one of the
    // output sinks. We look for several robust patterns.
    const patterns = [
      // direct assignment to sink object
      /(individualSegmentParams|taskParams|orchestratorDetails|orchDetails)\s*\.\s*selected_phase_preset_id\s*=/,
      // object key with reference to params.selected_phase_preset_id or destructured var
      /selected_phase_preset_id\s*:\s*(params\s*\.\s*)?selected_phase_preset_id/,
      // conditional spread including the id
      /\.\.\.\([^)]*selected_phase_preset_id[^)]*\{\s*selected_phase_preset_id/s,
      // shorthand inside an object literal: { ..., selected_phase_preset_id, ... }
      /[{,]\s*selected_phase_preset_id\s*[,}]/,
    ];

    let hits = 0;
    for (const p of patterns) if (p.test(src)) hits++;

    // Also count occurrences as a sanity floor — base file mentions it only in
    // type/destructure (typically 2-3 times). A real fix bumps that count.
    const occurrences = (src.match(/selected_phase_preset_id/g) || []).length;

    // Make sure assignment is in OUTPUT context, not just declaration.
    // We approximate by requiring at least one of the assignment patterns
    // OR occurrences strictly greater than the baseline.
    const strongMatch = patterns.slice(0, 3).some(p => p.test(src));
    const shorthandInObj = patterns[3].test(src);

    if (strongMatch && occurrences >= 4) console.log("PASS");
    else if (shorthandInObj && occurrences >= 4) console.log("PASS");
    else if (occurrences >= 5) console.log("PARTIAL");
    else console.log("FAIL");
  ' "$ITS_FILE" 2>&1)
fi
echo "Gate 3: $GATE3"
case "$GATE3" in
  PASS)    add_reward 0.30 ;;
  PARTIAL) add_reward 0.15 ;;
esac

#######################################
# F2P Gate 4: End-to-end — selecting a preset (basic mode) ends up
# putting phase_config into the eventual task params (weight 0.20)
# We accept either:
#   (a) buildTaskParams' phase_config expression depends on preset state, or
#   (b) Hook/component logic ensures motionMode flips to advanced (or
#       phaseConfig is preserved) when a preset is selected, AND
#       buildTaskParams no longer unconditionally drops in basic mode.
#######################################
echo "=== F2P Gate 4: End-to-end preset → phase_config ==="
GATE4="FAIL"

# Compute pieces
UTIL_HAS_PRESET_REF="no"
UTIL_DROPS_BASIC="no"
HOOK_PRESERVES="no"

if [ -n "$UTIL_FILE" ]; then
  UTIL_HAS_PRESET_REF=$(grep -E "selectedPhasePresetId|selected_phase_preset_id" "$UTIL_FILE" >/dev/null && echo yes || echo no)
  # Detect old buggy pattern still present
  if grep -E "phase_config:\s*settings\.motionMode\s*===\s*['\"]basic['\"]\s*\?\s*undefined\s*:\s*settings\.phaseConfig" "$UTIL_FILE" >/dev/null; then
    UTIL_DROPS_BASIC="yes"
  fi
  # If the phase_config line is now just settings.phaseConfig (no basic gating)
  if grep -E "phase_config:\s*settings\.phaseConfig\s*," "$UTIL_FILE" >/dev/null; then
    UTIL_DROPS_BASIC="no"
  fi
fi

if [ -n "$HOOK_FILE" ]; then
  # Hook used to: if basic => clear phaseConfig unconditionally.
  # A fix preserves it when a preset is involved.
  if grep -E "selectedPhasePresetId" "$HOOK_FILE" >/dev/null; then
    HOOK_PRESERVES="yes"
  fi
fi

# Decide
if [ "$UTIL_DROPS_BASIC" = "no" ] && [ "$GATE3" != "FAIL" ]; then
  GATE4="PASS"
elif [ "$UTIL_HAS_PRESET_REF" = "yes" ] && [ "$UTIL_DROPS_BASIC" = "no" ]; then
  GATE4="PASS"
elif [ "$HOOK_PRESERVES" = "yes" ] && [ "$UTIL_DROPS_BASIC" = "no" ]; then
  GATE4="PASS"
elif [ "$UTIL_DROPS_BASIC" = "no" ]; then
  GATE4="PARTIAL"
fi

echo "  util_drops_basic=$UTIL_DROPS_BASIC util_preset_ref=$UTIL_HAS_PRESET_REF hook_preserves=$HOOK_PRESERVES"
echo "Gate 4: $GATE4"
case "$GATE4" in
  PASS)    add_reward 0.20 ;;
  PARTIAL) add_reward 0.10 ;;
esac

#######################################
# Sanity P2P: file syntactic integrity via node parse where possible (weight 0.05)
#######################################
echo "=== P2P Gate 5: No JS syntax breakage in edited files ==="
SYN_OK=1
for f in "$UTIL_FILE" "$ITS_FILE" "$HOOK_FILE"; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  # Strip TS-specific syntax very loosely; just check braces balance & node can lex it as a module shell.
  node -e '
    const fs = require("fs");
    const s = fs.readFileSync(process.argv[1], "utf8");
    let depth = 0;
    for (const ch of s) {
      if (ch === "{") depth++;
      else if (ch === "}") depth--;
      if (depth < 0) { process.exit(2); }
    }
    if (depth !== 0) process.exit(3);
  ' "$f"
  if [ $? -ne 0 ]; then
    echo "FAIL: brace mismatch in $f"
    SYN_OK=0
  fi
done
if [ "$SYN_OK" = "1" ]; then
  echo "PASS: structure"
  add_reward 0.05
fi

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt