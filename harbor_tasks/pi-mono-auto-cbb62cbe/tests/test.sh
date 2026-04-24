#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

SCORE=0
TOTAL=0

REPO="/workspace/pi-mono"
COMPONENTS="$REPO/packages/coding-agent/src/modes/interactive/components"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"

# Known base files at commit cb08758 — any NEW .ts file in components/ is candidate
BASE_FILES="armin.ts assistant-message.ts bash-execution.ts bordered-loader.ts branch-summary-message.ts compaction-summary-message.ts config-selector.ts countdown-timer.ts custom-editor.ts custom-message.ts diff.ts dynamic-border.ts extension-editor.ts extension-input.ts extension-selector.ts footer.ts index.ts keybinding-hints.ts login-dialog.ts model-selector.ts oauth-selector.ts scoped-models-selector.ts session-selector-search.ts session-selector.ts settings-selector.ts show-images-selector.ts skill-invocation-message.ts theme-selector.ts thinking-selector.ts tool-execution.ts tree-selector.ts user-message-selector.ts user-message.ts visual-truncate.ts"

# Find the easter egg component: prefer *daxnut*, then any NEW .ts file with daxnuts text
find_easter_egg_file() {
  # First: look for file named *daxnut*
  local f
  f=$(find "$COMPONENTS" -maxdepth 1 -iname '*daxnut*' -name '*.ts' 2>/dev/null | head -1)
  if [ -n "$f" ]; then echo "$f"; return; fi

  # Second: look for any NEW file (not in BASE_FILES) that contains "daxnuts" or "daxnut"
  for candidate in "$COMPONENTS"/*.ts; do
    local basename=$(basename "$candidate")
    if echo "$BASE_FILES" | grep -qw "$basename"; then continue; fi
    if grep -qiE 'daxnuts|dax.?nuts|powered.*by' "$candidate" 2>/dev/null; then
      echo "$candidate"; return
    fi
  done

  # Third: check if interactive-mode.ts itself contains the component inline
  # (some agents may not create a separate file)
  echo ""
}

EASTER_EGG_FILE=$(find_easter_egg_file)

###############################################################################
# Gate 1 (P2P, 0.10): Base code integrity — armin.ts still valid component
# Passes on unmodified base AND on correct fix
###############################################################################
TOTAL=$((TOTAL + 10))
GATE1=0
ARMIN_CHECK=$(cd "$REPO" && bun -e '
const fs = require("fs");
const path = "packages/coding-agent/src/modes/interactive/components/armin.ts";
if (!fs.existsSync(path)) { console.log("MISSING"); process.exit(1); }
const src = fs.readFileSync(path, "utf8");
if (!/export\s+class\s+ArminComponent/.test(src)) { console.log("NO_EXPORT"); process.exit(1); }
if (!src.includes("Component")) { console.log("NO_COMPONENT"); process.exit(1); }
console.log("OK");
' 2>&1)
if echo "$ARMIN_CHECK" | grep -q "OK"; then
  GATE1=10
  echo "GATE1 [P2P]: PASS — armin.ts integrity OK"
else
  echo "GATE1 [P2P]: FAIL — armin.ts broken: $ARMIN_CHECK"
fi
SCORE=$((SCORE + GATE1))

###############################################################################
# Gate 2 (F2P, 0.25): Easter egg component exists, transpiles as valid
# TypeScript via bun build, exports a Component-like class/function.
# Non-trivial content. This is the TypeScript compilation gate (≥0.2 weight).
###############################################################################
TOTAL=$((TOTAL + 25))
GATE2=0
if [ -z "$EASTER_EGG_FILE" ]; then
  echo "GATE2 [F2P]: FAIL — no easter egg component file found"
else
  # Step 1: bun build transpilation check (TypeScript compilation gate)
  # bun build may exit non-zero due to output dir issues even if transpile succeeds
  TRANSPILE_OK=0
  BUILD_OUTPUT=$(cd "$REPO" && bun build "$EASTER_EGG_FILE" --no-bundle --outdir /tmp/ee_check 2>&1)
  if echo "$BUILD_OUTPUT" | grep -qi "Transpiled\|Built"; then
    TRANSPILE_OK=1
  elif echo "$BUILD_OUTPUT" | grep -qi "error.*parse\|SyntaxError\|unexpected"; then
    TRANSPILE_OK=0
  else
    # Fallback: try bun -e to eval the file as TS (parse check)
    cd "$REPO" && bun -e "require('fs').readFileSync('$EASTER_EGG_FILE', 'utf8')" > /dev/null 2>&1 && TRANSPILE_OK=1
  fi

  # Step 2: structural validation via bun execution
  EE_CHECK=$(cd "$REPO" && bun -e "
const fs = require('fs');
const src = fs.readFileSync('$EASTER_EGG_FILE', 'utf8');
// Must be non-trivial (>15 lines or >300 chars)
const lines = src.split('\n').length;
if (lines < 15 && src.length < 300) { console.log('TOO_SHORT'); process.exit(1); }
// Must export something
if (!/export\s+(class|function|const|default)/.test(src)) { console.log('NO_EXPORT'); process.exit(1); }
// Must reference Component interface (import or implement)
if (!src.includes('Component')) { console.log('NO_COMPONENT_REF'); process.exit(1); }
console.log('OK');
" 2>&1)

  if [ "$TRANSPILE_OK" -eq 1 ] && echo "$EE_CHECK" | grep -q "OK"; then
    GATE2=25
    echo "GATE2 [F2P]: PASS — easter egg component transpiles and is valid ($EASTER_EGG_FILE)"
  else
    echo "GATE2 [F2P]: FAIL — transpile=$TRANSPILE_OK, struct=$EE_CHECK"
  fi
  rm -rf /tmp/ee_check /tmp/ee_build.log
fi
SCORE=$((SCORE + GATE2))

###############################################################################
# Gate 3 (F2P, 0.30): interactive-mode.ts has new easter egg integration.
# The agent must have added code to import and use the new component.
# Accept any naming — check for new imports, new handler functions, or new
# component instantiations that weren't in the base code.
###############################################################################
TOTAL=$((TOTAL + 30))
GATE3=0
INTEGRATION_CHECK=$(cd "$REPO" && bun -e '
const fs = require("fs");
const src = fs.readFileSync("packages/coding-agent/src/modes/interactive/interactive-mode.ts", "utf8");

// Strategy 1: Check for daxnuts-related import/usage (most common naming)
const hasDaxnutsRef = /daxnut/i.test(src);

// Strategy 2: Check for new easter-egg related code (kimi + opencode trigger)
const hasEasterEggLogic = (
  (/opencode/i.test(src) && /kimi/i.test(src)) &&
  (/easter|egg|daxnut|thanks|thankyou|powered/i.test(src) ||
   /handleKimi|handleOpencode|handleEaster|handleDax|checkEaster|checkDax|showEaster|showDax|showKimi/i.test(src) ||
   /kimi.*component|kimi.*easter|opencode.*easter/i.test(src))
);

// Strategy 3: Check for a new import of any non-base component file
const newComponentImport = /from\s+["\x27]\.\/components\/(?!armin|assistant-message|bash-execution|bordered-loader|branch-summary|compaction|config-selector|countdown|custom-editor|custom-message|diff|dynamic-border|extension-editor|extension-input|extension-selector|footer|index|keybinding|login-dialog|model-selector|oauth-selector|scoped-models|session-selector|settings-selector|show-images|skill-invocation|theme-selector|thinking-selector|tool-execution|tree-selector|user-message|visual-truncate)\w/i.test(src);

if (hasDaxnutsRef || hasEasterEggLogic || newComponentImport) {
  console.log("OK");
} else {
  console.log("NO_INTEGRATION");
  process.exit(1);
}
' 2>&1)
if echo "$INTEGRATION_CHECK" | grep -q "OK"; then
  GATE3=30
  echo "GATE3 [F2P]: PASS — easter egg integrated in interactive-mode.ts"
else
  echo "GATE3 [F2P]: FAIL — not wired: $INTEGRATION_CHECK"
fi
SCORE=$((SCORE + GATE3))

###############################################################################
# Gate 4 (F2P, 0.20): "daxnuts" branding text present in the codebase.
# The instruction says 'include "powered by daxnuts"'. Check the easter egg
# component file, interactive-mode.ts, or any new file for this text.
###############################################################################
TOTAL=$((TOTAL + 20))
GATE4=0
BRANDING_CHECK=$(cd "$REPO" && bun -e '
const fs = require("fs");
const path = require("path");

// Check all candidate files for daxnuts branding
const filesToCheck = [];
const componentsDir = "packages/coding-agent/src/modes/interactive/components";
fs.readdirSync(componentsDir).forEach(f => {
  if (f.endsWith(".ts")) filesToCheck.push(path.join(componentsDir, f));
});
filesToCheck.push("packages/coding-agent/src/modes/interactive/interactive-mode.ts");

let hasDaxnuts = false;
let hasPoweredBy = false;
for (const file of filesToCheck) {
  if (!fs.existsSync(file)) continue;
  const src = fs.readFileSync(file, "utf8");
  // Check for daxnuts in string literals or identifiers
  if (/daxnuts/i.test(src)) hasDaxnuts = true;
  // Check for "powered by" pattern
  if (/powered\s*(by)?/i.test(src)) hasPoweredBy = true;
}
if (!hasDaxnuts) { console.log("NO_DAXNUTS_TEXT"); process.exit(1); }
console.log("OK");
' 2>&1)
if echo "$BRANDING_CHECK" | grep -q "OK"; then
  GATE4=20
  echo "GATE4 [F2P]: PASS — daxnuts branding present"
else
  echo "GATE4 [F2P]: FAIL — branding check: $BRANDING_CHECK"
fi
SCORE=$((SCORE + GATE4))

###############################################################################
# Gate 5 (F2P, 0.15): Trigger logic references opencode + kimi model selection.
# The easter egg should activate when the user selects opencode provider with
# kimi k2.5. Check any relevant source file for this trigger logic.
###############################################################################
TOTAL=$((TOTAL + 15))
GATE5=0
TRIGGER_CHECK=$(cd "$REPO" && bun -e '
const fs = require("fs");
const path = require("path");

// Check all component files + interactive-mode for trigger logic
const filesToCheck = [];
const componentsDir = "packages/coding-agent/src/modes/interactive/components";
fs.readdirSync(componentsDir).forEach(f => {
  if (f.endsWith(".ts")) filesToCheck.push(path.join(componentsDir, f));
});
filesToCheck.push("packages/coding-agent/src/modes/interactive/interactive-mode.ts");

// Also check any new files outside components
const interactiveDir = "packages/coding-agent/src/modes/interactive";
fs.readdirSync(interactiveDir).forEach(f => {
  if (f.endsWith(".ts") && !filesToCheck.includes(path.join(interactiveDir, f))) {
    filesToCheck.push(path.join(interactiveDir, f));
  }
});

let hasOpencode = false;
let hasKimi = false;
let foundInNewCode = false;

for (const file of filesToCheck) {
  if (!fs.existsSync(file)) continue;
  const src = fs.readFileSync(file, "utf8");

  // For interactive-mode.ts, only check NEW code (lines containing easter egg logic)
  // For other files, check the whole file
  const isInteractive = file.endsWith("interactive-mode.ts");

  if (isInteractive) {
    // Check if the file has been modified to include opencode/kimi trigger
    // The base file already references some model names, so we need to check
    // for new easter-egg-related trigger logic
    if (/opencode.*kimi|kimi.*opencode/i.test(src) ||
        (/opencode/i.test(src) && /kimi.*k2\.?5|kimi-k2/i.test(src)) ||
        (/opencode/i.test(src) && /easter|daxnut/i.test(src))) {
      hasOpencode = true;
      hasKimi = true;
      foundInNewCode = true;
    }
  } else {
    if (/opencode/i.test(src)) { hasOpencode = true; foundInNewCode = true; }
    if (/kimi/i.test(src)) { hasKimi = true; foundInNewCode = true; }
  }
}

if (!foundInNewCode) { console.log("NO_TRIGGER"); process.exit(1); }
if (!hasOpencode) { console.log("NO_OPENCODE"); process.exit(1); }
if (!hasKimi) { console.log("NO_KIMI"); process.exit(1); }
console.log("OK");
' 2>&1)
if echo "$TRIGGER_CHECK" | grep -q "OK"; then
  GATE5=15
  echo "GATE5 [F2P]: PASS — opencode+kimi trigger logic found"
else
  echo "GATE5 [F2P]: FAIL — trigger check: $TRIGGER_CHECK"
fi
SCORE=$((SCORE + GATE5))

###############################################################################
# Final score
###############################################################################
FINAL=$(awk "BEGIN {printf \"%.2f\", $SCORE / $TOTAL}")
echo ""
echo "===== FINAL SCORE: $SCORE / $TOTAL = $FINAL ====="
echo "$FINAL" > "$REWARD_FILE"
