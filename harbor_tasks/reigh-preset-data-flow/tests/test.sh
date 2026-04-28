#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

mkdir -p /logs/verifier

# Locate workspace
if [ -d /workspace/repo ]; then
  cd /workspace/repo
else
  cd /workspace/$(ls /workspace 2>/dev/null | head -1) 2>/dev/null
fi

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

FORM_FILE=""
for p in src/shared/components/SegmentSettingsForm/SegmentSettingsForm.tsx src/shared/components/SegmentSettingsForm/index.tsx; do
  [ -f "$p" ] && FORM_FILE="$p" && break
done

echo "UTIL_FILE=$UTIL_FILE"
echo "ITS_FILE=$ITS_FILE"
echo "HOOK_FILE=$HOOK_FILE"
echo "FORM_FILE=$FORM_FILE"

if [ -z "$UTIL_FILE" ] || [ -z "$ITS_FILE" ]; then
  echo "Required source files missing — REWARD=0"
  echo "0.0000" > /logs/verifier/reward.txt
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node missing — cannot evaluate behavior"
  echo "0.0000" > /logs/verifier/reward.txt
  exit 0
fi

#######################################
# P2P gate (gating only): TypeScript still compiles (best effort)
#######################################
if [ -f tsconfig.json ] && command -v npx >/dev/null 2>&1; then
  echo "=== P2P Gate: tsc --noEmit (gating only) ==="
  TSC_OUT=$(timeout 120 npx --no-install tsc --noEmit 2>&1)
  TSC_EXIT=$?
  echo "$TSC_OUT" | tail -20
  # Only fail if the tool ran AND produced errors. Skip on missing tool.
  if echo "$TSC_OUT" | grep -q "could not be found\|not found\|ENOENT"; then
    echo "tsc not available — skipping P2P"
  elif [ "$TSC_EXIT" != "0" ]; then
    # Compare error count to a baseline of UTIL_FILE itself; if errors are
    # in our edited files, that's a regression from a bad patch.
    EDITED_ERRS=$(echo "$TSC_OUT" | grep -E "^(src/shared/components/segmentSettingsUtils|src/shared/lib/tasks/individualTravelSegment|src/shared/hooks/segments/useSegmentSettings|src/shared/components/SegmentSettingsForm)" | wc -l)
    if [ "$EDITED_ERRS" -gt 0 ]; then
      echo "REGRESSION: tsc errors in edited files — zeroing"
      echo "$TSC_OUT" | grep -E "^(src/shared/components|src/shared/lib|src/shared/hooks)" | head -10
      echo "0.0000" > /logs/verifier/reward.txt
      exit 0
    fi
    echo "tsc has pre-existing errors elsewhere — non-blocking"
  fi
fi

#######################################
# F2P Gate 1 (weight 0.25):
# buildTaskParams MUST return a non-undefined phase_config when in basic
# mode AND a non-builtin preset is selected. This is the central bug.
#######################################
echo "=== Gate 1: phase_config flows through in basic+preset (weight 0.25) ==="
GATE1=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");

  const fnIdx = src.indexOf("buildTaskParams");
  if (fnIdx === -1) { console.log("FAIL:no-fn"); process.exit(0); }
  const after = src.substring(fnIdx);
  const pcIdx = after.indexOf("phase_config");
  if (pcIdx === -1) { console.log("FAIL:no-phase_config"); process.exit(0); }
  const tail = after.substring(pcIdx);
  const colonIdx = tail.indexOf(":");
  if (colonIdx === -1) { console.log("FAIL"); process.exit(0); }

  let i = colonIdx + 1;
  let depth = 0;
  let expr = "";
  while (i < tail.length) {
    const ch = tail[i];
    if (depth === 0 && ch === ",") break;
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") {
      if (depth === 0) break;
      depth--;
    }
    expr += ch; i++;
  }
  expr = expr.trim();
  if (!expr) { console.log("FAIL:empty"); process.exit(0); }

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
    } catch (e) { return { __err: e.message }; }
  }

  const a = evalExpr({ motionMode: "basic", selectedPhasePresetId: PRESET_ID, phaseConfig: PHASE_CFG });
  const isErr = (x) => x && typeof x === "object" && "__err" in x;
  if (isErr(a)) { console.log("FAIL:eval-err:" + a.__err); process.exit(0); }
  if (a !== undefined && a && a.phases) console.log("PASS");
  else console.log("FAIL:a=" + JSON.stringify(a));
' "$UTIL_FILE" 2>&1)
echo "Gate 1: $GATE1"
[[ "$GATE1" == PASS* ]] && add_reward 0.25

#######################################
# Gate 2 (weight 0.15): advanced mode still preserves phaseConfig.
# Catches over-eager rewrites that break the existing case.
#######################################
echo "=== Gate 2: advanced mode preserves phaseConfig (weight 0.15) ==="
GATE2=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const fnIdx = src.indexOf("buildTaskParams");
  if (fnIdx === -1) { console.log("FAIL"); process.exit(0); }
  const after = src.substring(fnIdx);
  const pcIdx = after.indexOf("phase_config");
  const tail = after.substring(pcIdx);
  const colonIdx = tail.indexOf(":");
  let i = colonIdx + 1, depth = 0, expr = "";
  while (i < tail.length) {
    const ch = tail[i];
    if (depth === 0 && ch === ",") break;
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") { if (depth === 0) break; depth--; }
    expr += ch; i++;
  }
  expr = expr.trim();
  const PHASE_CFG = { phases: [{ strength: 0.5 }] };
  try {
    const f = new Function("settings","BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID","BUILTIN_I2V_PRESET","BUILTIN_VACE_PRESET","return (" + expr + ");");
    const r = f({ motionMode: "advanced", selectedPhasePresetId: undefined, phaseConfig: PHASE_CFG }, "i2v", "vace", { id: "i2v" }, { id: "vace" });
    if (r && r.phases) console.log("PASS");
    else console.log("FAIL:" + JSON.stringify(r));
  } catch (e) { console.log("FAIL:" + e.message); }
' "$UTIL_FILE" 2>&1)
echo "Gate 2: $GATE2"
[[ "$GATE2" == PASS* ]] && add_reward 0.15

#######################################
# Gate 3 (weight 0.10): basic mode + builtin/no preset → either undefined or
# falsy phaseConfig is acceptable. Mostly just confirms expression evaluates
# cleanly across all branches (no syntax error).
#######################################
echo "=== Gate 3: basic+no-preset evaluates cleanly (weight 0.10) ==="
GATE3=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const fnIdx = src.indexOf("buildTaskParams");
  const after = src.substring(fnIdx);
  const pcIdx = after.indexOf("phase_config");
  const tail = after.substring(pcIdx);
  const colonIdx = tail.indexOf(":");
  let i = colonIdx + 1, depth = 0, expr = "";
  while (i < tail.length) {
    const ch = tail[i];
    if (depth === 0 && ch === ",") break;
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") { if (depth === 0) break; depth--; }
    expr += ch; i++;
  }
  expr = expr.trim();
  try {
    const f = new Function("settings","BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID","BUILTIN_I2V_PRESET","BUILTIN_VACE_PRESET","return (" + expr + ");");
    f({ motionMode: "basic", selectedPhasePresetId: undefined, phaseConfig: undefined }, "i2v", "vace", { id: "i2v" }, { id: "vace" });
    f({ motionMode: "basic", selectedPhasePresetId: "builtin-i2v", phaseConfig: { phases: [] } }, "builtin-i2v", "vace", { id: "builtin-i2v" }, { id: "vace" });
    console.log("PASS");
  } catch (e) { console.log("FAIL:" + e.message); }
' "$UTIL_FILE" 2>&1)
echo "Gate 3: $GATE3"
[[ "$GATE3" == PASS* ]] && add_reward 0.10

#######################################
# Gate 4 (weight 0.30): individualTravelSegment.ts must WRITE
# selected_phase_preset_id into one of its output objects (not just type/destructure).
# This is the second half of the bug — the preset id wasn't propagated to the task.
#######################################
echo "=== Gate 4: individualTravelSegment writes selected_phase_preset_id (weight 0.30) ==="
GATE4=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  // Look for assignment patterns into a sink object:
  //   X.selected_phase_preset_id = ...
  //   selected_phase_preset_id: <expr that references params or preset_id>  (object literal property)
  //   ...spread: { selected_phase_preset_id: ... }
  // Exclude pure destructuring: const { selected_phase_preset_id } = ...
  // Exclude pure type declarations: selected_phase_preset_id?:|: <type>;
  const lines = src.split("\n");
  let writes = 0;
  let writeLines = [];
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    if (!ln.includes("selected_phase_preset_id")) continue;
    // skip type-only / interface lines
    if (/^\s*selected_phase_preset_id\??:\s*(string|number|boolean)/.test(ln)) continue;
    // skip destructuring const { ... selected_phase_preset_id ... } = X
    if (/=\s*\{/.test(ln) && /\}\s*=/.test(lines.slice(Math.max(0,i-3),i+1).join(" "))) {
      // best-effort
    }
    // direct assignment
    if (/\.selected_phase_preset_id\s*=/.test(ln)) { writes++; writeLines.push(ln.trim()); continue; }
    // object literal property with a value (not just typing)
    if (/selected_phase_preset_id\s*:\s*[^;]/.test(ln) && !/^\s*selected_phase_preset_id\s*:\s*(string|number|boolean|null)\s*[;,]?\s*$/.test(ln) && !/interface|type\s/.test(lines[Math.max(0,i-1)] || "")) {
      // make sure its not just the type
      if (/params|preset|orchestrator|individual|taskParams/i.test(ln)) {
        writes++;
        writeLines.push(ln.trim());
        continue;
      }
    }
    // spread conditional: ...(params.selected_phase_preset_id != null && { selected_phase_preset_id: ... })
    if (/\.\.\.\s*\(.*selected_phase_preset_id/.test(ln)) { writes++; writeLines.push(ln.trim()); continue; }
  }
  console.error("writes=" + writes);
  for (const w of writeLines) console.error("  " + w);
  if (writes >= 1) console.log("PASS:" + writes);
  else console.log("FAIL");
' "$ITS_FILE" 2>&1)
echo "Gate 4: $GATE4"
[[ "$GATE4" == PASS* ]] && add_reward 0.30

#######################################
# Gate 5 (weight 0.10): The write in ITS must reference `params.<id>` or
# similar (i.e., propagate from input, not hardcode). Behaviorally simulate
# by checking the file emits the id into BOTH/EITHER an output sink AND
# sources it from the input params.
#######################################
echo "=== Gate 5: ITS reads selected_phase_preset_id from params (weight 0.10) ==="
GATE5=$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  // Need: params.selected_phase_preset_id appears somewhere on RHS of write,
  // OR it was destructured then re-emitted.
  const hasParamsRead = /params\.selected_phase_preset_id/.test(src) ||
                        /\bselected_phase_preset_id\b[^:]*=.*params/.test(src) ||
                        /const\s*\{[^}]*selected_phase_preset_id[^}]*\}\s*=\s*params/.test(src);
  // And needs to write somewhere
  const hasWrite = /\.selected_phase_preset_id\s*=/.test(src) ||
                   /\.\.\.\s*\(.*selected_phase_preset_id/.test(src) ||
                   /selected_phase_preset_id\s*:\s*(params|presetId|selectedPhasePresetId|selected_phase_preset_id)/.test(src);
  if (hasParamsRead && hasWrite) console.log("PASS");
  else console.log("FAIL: read=" + hasParamsRead + " write=" + hasWrite);
' "$ITS_FILE" 2>&1)
echo "Gate 5: $GATE5"
[[ "$GATE5" == PASS* ]] && add_reward 0.10

#######################################
# Gate 6 (weight 0.10): Round-trip behavioral test — simulate the full
# data flow from settings -> buildTaskParams -> individualSegmentParams.
# A complete fix produces phase_config AND the preset id at the task level
# for the basic+non-builtin-preset case. We verify this by injecting a
# simulated buildTaskParams result and checking the ITS file structurally
# emits the preset id alongside phase_config (i.e., they both reach the worker).
#######################################
echo "=== Gate 6: phase_config and preset_id both reach task layer (weight 0.10) ==="
GATE6=$(node -e '
  const fs = require("fs");

  // Step 1: re-extract the phase_config expression from UTIL_FILE
  const utilSrc = fs.readFileSync(process.argv[1], "utf8");
  const fnIdx = utilSrc.indexOf("buildTaskParams");
  const after = utilSrc.substring(fnIdx);
  const pcIdx = after.indexOf("phase_config");
  const tail = after.substring(pcIdx);
  const colonIdx = tail.indexOf(":");
  let i = colonIdx + 1, depth = 0, expr = "";
  while (i < tail.length) {
    const ch = tail[i];
    if (depth === 0 && ch === ",") break;
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") { if (depth === 0) break; depth--; }
    expr += ch; i++;
  }
  expr = expr.trim();

  let pcVal;
  try {
    const f = new Function("settings","BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID","BUILTIN_I2V_PRESET","BUILTIN_VACE_PRESET","return (" + expr + ");");
    pcVal = f(
      { motionMode: "basic", selectedPhasePresetId: "user-preset-xyz", phaseConfig: { phases: [{ s: 1 }] } },
      "builtin-i2v", "builtin-vace", { id: "builtin-i2v" }, { id: "builtin-vace" }
    );
  } catch (e) { console.log("FAIL:eval"); process.exit(0); }

  if (!pcVal) { console.log("FAIL:phase_config-undef"); process.exit(0); }

  // Step 2: ITS file must propagate selected_phase_preset_id to a sink that
  // also carries phase_config (individualSegmentParams or orchestrator_details).
  const itsSrc = fs.readFileSync(process.argv[2], "utf8");
  // Find any sink that writes BOTH phase_config and selected_phase_preset_id.
  const sinks = ["individualSegmentParams", "orchestratorDetails", "orchDetails", "taskParams"];
  let found = false;
  for (const sink of sinks) {
    const sinkRe = new RegExp(sink + "\\.selected_phase_preset_id", "g");
    const writesId = sinkRe.test(itsSrc);
    if (writesId) { found = true; break; }
  }
  // Or via spread inside an object literal that also has phase_config
  if (!found) {
    // Look for a region with both keys close together
    const idx = itsSrc.indexOf("selected_phase_preset_id");
    if (idx !== -1) {
      const window = itsSrc.substring(Math.max(0, idx-2000), Math.min(itsSrc.length, idx+2000));
      if (/phase_config/.test(window)) found = true;
    }
  }
  if (found) console.log("PASS");
  else console.log("FAIL:no-cohabitation");
' "$UTIL_FILE" "$ITS_FILE" 2>&1)
echo "Gate 6: $GATE6"
[[ "$GATE6" == PASS* ]] && add_reward 0.10

#######################################
# Run any existing unit tests that touch these files (best effort, gating only —
# do not award; just penalize regression).
#######################################
if [ -f package.json ] && command -v npx >/dev/null 2>&1; then
  if grep -q '"vitest"' package.json 2>/dev/null; then
    TESTS=""
    for tp in src/shared/components/segmentSettingsUtils.test.ts \
              src/shared/components/segmentSettingsUtils.spec.ts \
              src/shared/lib/tasks/individualTravelSegment.test.ts \
              src/shared/lib/tasks/individualTravelSegment.spec.ts \
              src/shared/hooks/segments/useSegmentSettings.test.ts; do
      [ -f "$tp" ] && TESTS="$TESTS $tp"
    done
    if [ -n "$TESTS" ]; then
      echo "=== Running vitest on $TESTS (gating only) ==="
      VOUT=$(timeout 120 npx --no-install vitest run $TESTS --reporter=basic 2>&1)
      echo "$VOUT" | tail -30
      if echo "$VOUT" | grep -qE "FAIL|failed"; then
        FAILED=$(echo "$VOUT" | grep -oE "[0-9]+ failed" | head -1 | grep -oE "[0-9]+")
        if [ -n "$FAILED" ] && [ "$FAILED" -gt 0 ]; then
          echo "Test regression detected — capping reward at 0.20"
          CAPPED=$(awk -v r="$REWARD" 'BEGIN{print (r>0.2)?"0.2000":r}')
          REWARD="$CAPPED"
        fi
      fi
    fi
  fi
fi

echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt
# ---- v5: orchestrator-wrapped appended block ----
_v5_run_upstream_appended() {
  set +e  # never abort the host script from inside the wrapper


# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

# --- F2P upstream gate: phase_config evaluates to non-undefined in basic+preset mode ---
echo "=== Upstream F2P: phase_config_basic_eval ==="
F2P1_OUT=$(node -e '
const fs = require("fs");
let utilFile = "";
for (const p of ["src/shared/components/segmentSettingsUtils.ts","src/shared/components/SegmentSettingsForm/segmentSettingsUtils.ts"]) {
  try { fs.statSync(p); utilFile = p; break; } catch(e) {}
}
if (!utilFile) { console.log("FAIL:no-file"); process.exit(1); }
const src = fs.readFileSync(utilFile, "utf8");
const fnIdx = src.indexOf("function buildTaskParams");
if (fnIdx === -1) { const fnIdx2 = src.indexOf("buildTaskParams"); if (fnIdx2 === -1) { console.log("FAIL:no-fn"); process.exit(1); } }
const fnStart = src.indexOf("buildTaskParams");
const after = src.substring(fnStart);
const pcIdx = after.indexOf("phase_config:");
if (pcIdx === -1) { console.log("FAIL:no-phase_config"); process.exit(1); }
const tail = after.substring(pcIdx);
const colonIdx = tail.indexOf(":");
let i = colonIdx + 1, depth = 0, expr = "";
while (i < tail.length) {
  const ch = tail[i];
  if (depth === 0 && ch === ",") break;
  if (ch === "(" || ch === "{" || ch === "[") depth++;
  else if (ch === ")" || ch === "}" || ch === "]") { if (depth === 0) break; depth--; }
  expr += ch; i++;
}
expr = expr.trim();
const PHASE_CFG = { phases: [{ strength: 0.5, duration: 1.0 }] };
try {
  const f = new Function("settings","BUILTIN_I2V_PRESET_ID","BUILTIN_VACE_PRESET_ID","BUILTIN_I2V_PRESET","BUILTIN_VACE_PRESET","return (" + expr + ");");
  const result = f({ motionMode: "basic", selectedPhasePresetId: "user-preset-xyz", phaseConfig: PHASE_CFG }, "__builtin_default_i2v__", "__builtin_default_vace__", { id: "__builtin_default_i2v__" }, { id: "__builtin_default_vace__" });
  if (result && typeof result === "object" && result.phases) {
    console.log("PASS");
    process.exit(0);
  } else {
    console.log("FAIL:result=" + JSON.stringify(result));
    process.exit(1);
  }
} catch(e) { console.log("FAIL:eval:" + e.message); process.exit(1); }
' 2>&1)
F2P1_RC=$?
echo "f2p_upstream_phase_config_eval: $F2P1_OUT (rc=$F2P1_RC)"
if [ "$F2P1_RC" -eq 0 ]; then
  echo '{"id":"f2p_upstream_phase_config_eval","passed":true,"detail":"phase_config returns value in basic+preset mode"}' >> "$GATES_FILE"
else
  echo '{"id":"f2p_upstream_phase_config_eval","passed":false,"detail":"'"$F2P1_OUT"'"}' >> "$GATES_FILE"
fi

# --- F2P upstream gate: selected_phase_preset_id propagated in ITS ---
echo "=== Upstream F2P: preset_id_propagation ==="
F2P2_OUT=$(node -e '
const fs = require("fs");
let itsFile = "";
for (const p of ["src/shared/lib/tasks/individualTravelSegment.ts","src/shared/modules/individualTravelSegment.ts"]) {
  try { fs.statSync(p); itsFile = p; break; } catch(e) {}
}
if (!itsFile) { console.log("FAIL:no-file"); process.exit(1); }
const src = fs.readFileSync(itsFile, "utf8");
const lines = src.split("\n");
let writes = 0;
for (let i = 0; i < lines.length; i++) {
  const ln = lines[i];
  if (!ln.includes("selected_phase_preset_id")) continue;
  if (/^\s*selected_phase_preset_id\??\s*:\s*(string|number|boolean|null)/.test(ln)) continue;
  if (/interface\s|type\s/.test(ln)) continue;
  if (/\.\.\.\s*\(.*selected_phase_preset_id/.test(ln)) { writes++; continue; }
  if (/\.selected_phase_preset_id\s*=/.test(ln)) { writes++; continue; }
  if (/selected_phase_preset_id\s*:\s*(params|presetId|selected)/.test(ln)) { writes++; continue; }
}
if (writes >= 1) {
  console.log("PASS:writes=" + writes);
  process.exit(0);
} else {
  console.log("FAIL:no-writes");
  process.exit(1);
}
' 2>&1)
F2P2_RC=$?
echo "f2p_upstream_preset_id_propagation: $F2P2_OUT (rc=$F2P2_RC)"
if [ "$F2P2_RC" -eq 0 ]; then
  echo '{"id":"f2p_upstream_preset_id_propagation","passed":true,"detail":"selected_phase_preset_id propagated to output objects"}' >> "$GATES_FILE"
else
  echo '{"id":"f2p_upstream_preset_id_propagation","passed":false,"detail":"'"$F2P2_OUT"'"}' >> "$GATES_FILE"
fi

# --- P2P upstream gate: eslint on changed files ---
echo "=== Upstream P2P: eslint_changed_files ==="
P2P1_PASS=false
if command -v npx >/dev/null 2>&1; then
  LINT_FILES=""
  for lf in src/shared/components/segmentSettingsUtils.ts src/shared/lib/tasks/individualTravelSegment.ts; do
    [ -f "$lf" ] && LINT_FILES="$LINT_FILES $lf"
  done
  if [ -n "$LINT_FILES" ]; then
    LINT_OUT=$(timeout 60 npx --no-install eslint $LINT_FILES --max-warnings 0 2>&1)
    LINT_RC=$?
    if [ "$LINT_RC" -eq 0 ]; then
      P2P1_PASS=true
    fi
    echo "eslint rc=$LINT_RC"
  else
    P2P1_PASS=true
    echo "no lint files found, skip"
  fi
else
  P2P1_PASS=true
  echo "npx not found, skip"
fi
if [ "$P2P1_PASS" = "true" ]; then
  echo '{"id":"p2p_upstream_eslint","passed":true,"detail":"eslint clean on changed files"}' >> "$GATES_FILE"
else
  echo '{"id":"p2p_upstream_eslint","passed":false,"detail":"eslint errors in changed files"}' >> "$GATES_FILE"
fi

# --- Upstream reward tail ---
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_phase_config_eval": 0.20, "f2p_upstream_preset_id_propagation": 0.20}
P2P_REGRESSION = ["p2p_upstream_eslint"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
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
p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += w
    reward = min(reward, 1.0)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM_REWARD=%.4f (existing=%.4f, f2p_any_pass=%s, p2p_failed=%s)' % (reward, existing, f2p_any_pass, p2p_failed))
PYEOF
# ---- end upstream gates ----
}
# Run via subshell so even unhandled `exit N` in the wrapper
# only kills the subshell, not the host. Exit codes ignored.
( _v5_run_upstream_appended ) || true
# ---- end v5 wrapper ----
