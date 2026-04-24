#!/bin/bash
set +e

REPO="/workspace/repo"
SCORE=0
cd "$REPO"

mkdir -p /logs/verifier

# Helper: add to score using awk (bc not available)
add_score() {
    SCORE=$(awk "BEGIN {printf \"%.2f\", $SCORE + $1}")
}

echo "============================================================"
echo "Pre-check: TypeScript Compilation (npx tsc --noEmit)"
echo "============================================================"
npx tsc --noEmit 2>&1
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "TSC: PASS — compiles cleanly"
    TSC_PASS=1
else
    echo "TSC: FAIL — compilation errors detected"
    TSC_PASS=0
fi

echo ""
echo "============================================================"
echo "Gate 1 (P2P): TypeScript compiles — weight 0.05"
echo "============================================================"
# P2P: Should pass on both unmodified base and correct fix.
# Guards against regressions that break type safety.
if [ $TSC_PASS -eq 1 ]; then
    echo "PASS: TypeScript compiles cleanly"
    add_score 0.05
else
    echo "FAIL: TypeScript compilation errors"
fi

echo ""
echo "============================================================"
echo "Gate 2 (F2P): Radix event handler props removed — weight 0.25"
echo "============================================================"
# F2P: Requires TSC pass + dead Radix props removed from callers.
# In base state, callers pass onOpenAutoFocus/onPointerDownOutside/
# onInteractOutside directly as JSX attrs to DialogContent/PopoverContent.
# After fix, these dead Radix props should be gone. Accepts any valid
# approach: removing from callers, stripping in wrapper component, etc.
if [ $TSC_PASS -eq 0 ]; then
    echo "SKIP (TSC failed): cannot verify with broken compilation"
    G2_EXIT=1
else
    node -e '
const fs = require("fs");

const radixProps = ["onOpenAutoFocus", "onPointerDownOutside", "onInteractOutside"];

// Files that had dead Radix props passed to DialogContent/PopoverContent
const files = [
  "src/tools/travel-between-images/components/VideoGenerationModal.tsx",
  "src/shared/components/ImageGenerationModal.tsx",
  "src/shared/components/ui/ai-input-button.tsx",
  "src/shared/components/DatasetBrowserModal.tsx"
];

// Approach 1: Check if callers stopped passing these props
let cleanFiles = 0;
for (const f of files) {
  try {
    const src = fs.readFileSync(f, "utf8");
    const lines = src.split("\n");
    let hasRadixProp = false;
    for (const line of lines) {
      const t = line.trim();
      if (t.startsWith("//") || t.startsWith("*")) continue;
      for (const p of radixProps) {
        if (t.match(new RegExp(p + "\\s*[=({]"))) {
          hasRadixProp = true;
        }
      }
    }
    if (!hasRadixProp) cleanFiles++;
  } catch(e) {
    // File deleted or moved — valid fix approach (TSC gate guards type safety)
    cleanFiles++;
  }
}

// Approach 2: DialogContent/PopoverContent strips the props via destructuring
let componentStrips = false;
try {
  const dialogSrc = fs.readFileSync("src/shared/components/ui/dialog.tsx", "utf8");
  const dcStart = dialogSrc.indexOf("DialogContent");
  if (dcStart >= 0) {
    const dcBody = dialogSrc.slice(dcStart, dcStart + 2000);
    const strippedCount = radixProps.filter(p => dcBody.includes(p)).length;
    if (strippedCount >= 2) componentStrips = true;
  }
} catch(e) {}

// Approach 2b: PopoverContent strips the props
try {
  const popSrc = fs.readFileSync("src/shared/components/ui/popover.tsx", "utf8");
  const pcStart = popSrc.indexOf("PopoverContent");
  if (pcStart >= 0) {
    const pcBody = popSrc.slice(pcStart, pcStart + 2000);
    const strippedCount = radixProps.filter(p => pcBody.includes(p)).length;
    if (strippedCount >= 2) componentStrips = true;
  }
} catch(e) {}

if (cleanFiles >= 3 || componentStrips) {
  console.log("PASS: " + cleanFiles + "/4 caller files cleaned");
  process.exit(0);
} else {
  console.log("FAIL: only " + cleanFiles + "/4 caller files cleaned");
  process.exit(1);
}
'
    G2_EXIT=$?
fi
if [ ${G2_EXIT:-1} -eq 0 ]; then
    add_score 0.25
fi

echo ""
echo "============================================================"
echo "Gate 3 (F2P): useModal.ts cleaned up — weight 0.25"
echo "============================================================"
# F2P: Requires TSC pass + useModal.ts no longer returns onOpenAutoFocus
# in mobileProps. In base state, useModal.ts returns { onOpenAutoFocus: ... }
# via mobileProps. After fix, this dead Radix prop should be removed.
if [ $TSC_PASS -eq 0 ]; then
    echo "SKIP (TSC failed): cannot verify with broken compilation"
    G3_EXIT=1
else
    node -e '
const fs = require("fs");
try {
  const src = fs.readFileSync("src/shared/hooks/useModal.ts", "utf8");
  if (src.includes("onOpenAutoFocus")) {
    console.log("FAIL: useModal.ts still contains onOpenAutoFocus");
    process.exit(1);
  }
  console.log("PASS: useModal.ts no longer contains onOpenAutoFocus");
  process.exit(0);
} catch(e) {
  // File deleted or refactored — valid approach if TSC still passes
  console.log("PASS: useModal.ts modified or removed (TSC still passes)");
  process.exit(0);
}
'
    G3_EXIT=$?
fi
if [ ${G3_EXIT:-1} -eq 0 ]; then
    add_score 0.25
fi

echo ""
echo "============================================================"
echo "Gate 4 (F2P): VideoGenerationModal close guard — weight 0.25"
echo "============================================================"
# F2P: Requires TSC pass + isLoraModalOpen guard in non-Radix close handler.
# In base state, VideoGenerationModal has:
#   onOpenChange={(open) => !open && onClose()}
# The isLoraModalOpen guard only exists in dead Radix props
# (onPointerDownOutside/onInteractOutside). After fix, the close logic
# must incorporate the isLoraModalOpen guard via onOpenChange or a handler.
if [ $TSC_PASS -eq 0 ]; then
    echo "SKIP (TSC failed): cannot verify with broken compilation"
    G4_EXIT=1
else
    node -e '
const fs = require("fs");
const file = "src/tools/travel-between-images/components/VideoGenerationModal.tsx";
try {
  const src = fs.readFileSync(file, "utf8");
  const lines = src.split("\n");
  let guardFound = false;

  // Check lines that mention isLoraModalOpen in a close context
  // BUT NOT inside onPointerDownOutside or onInteractOutside (dead Radix props)
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const t = line.trim();
    if (t.startsWith("//") || t.startsWith("*")) continue;
    if (t.includes("onPointerDownOutside") || t.includes("onInteractOutside")) continue;

    if (t.includes("isLoraModalOpen") &&
        (t.includes("onOpenChange") || t.includes("onClose") || t.includes("Close"))) {
      guardFound = true;
      break;
    }
  }

  // Accept: handler function that uses isLoraModalOpen for closing
  if (!guardFound) {
    const handlerPattern = /(handle\w*[Cc]lose|handle\w*[Oo]pen\w*)\s*=/;
    for (let i = 0; i < lines.length; i++) {
      if (handlerPattern.test(lines[i])) {
        const body = lines.slice(i, Math.min(i + 15, lines.length)).join("\n");
        if (body.includes("isLoraModalOpen")) {
          guardFound = true;
          break;
        }
      }
    }
  }

  // Accept: onOpenChange on same/adjacent lines references isLoraModalOpen
  if (!guardFound) {
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].includes("onOpenChange")) {
        const context = lines.slice(i, Math.min(i + 8, lines.length)).join("\n");
        if (context.includes("isLoraModalOpen") &&
            !context.includes("onPointerDownOutside") &&
            !context.includes("onInteractOutside")) {
          guardFound = true;
          break;
        }
      }
    }
  }

  // Accept: inline arrow in onOpenChange that checks isLoraModalOpen
  if (!guardFound) {
    const joined = src.replace(/\n/g, " ");
    const match = joined.match(/onOpenChange\s*=\s*\{[^}]{0,300}isLoraModalOpen[^}]{0,100}\}/);
    if (match && !match[0].includes("onPointerDownOutside") && !match[0].includes("onInteractOutside")) {
      guardFound = true;
    }
  }

  if (guardFound) {
    console.log("PASS: isLoraModalOpen guard found in close handler");
    process.exit(0);
  } else {
    console.log("FAIL: isLoraModalOpen guard not in any non-Radix close handler");
    process.exit(1);
  }
} catch(e) {
  console.log("FAIL: could not read " + file + ": " + e.message);
  process.exit(1);
}
'
    G4_EXIT=$?
fi
if [ ${G4_EXIT:-1} -eq 0 ]; then
    add_score 0.25
fi

echo ""
echo "============================================================"
echo "Gate 5 (F2P): modal.props spread cleaned — weight 0.20"
echo "============================================================"
# F2P: Requires TSC pass + modal.props spread containing dead Radix props
# cleaned up. Accepts: removing spreads from callers, removing the
# onOpenAutoFocus from useModal props, or returning empty props object.
if [ $TSC_PASS -eq 0 ]; then
    echo "SKIP (TSC failed): cannot verify with broken compilation"
    G5_EXIT=1
else
    node -e '
const fs = require("fs");

// Files that spread modal.props in base state
const files = [
  "src/shared/components/DatasetBrowserModal.tsx",
  "src/shared/components/ImageGenerationModal.tsx",
  "src/shared/components/ModalContainer.tsx",
  "src/shared/components/OnboardingModal.tsx",
  "src/shared/components/ProjectSelectorModal.tsx",
  "src/shared/components/SettingsModal/SettingsModal.tsx",
  "src/shared/components/TaskDetailsModal.tsx",
  "src/tools/travel-between-images/components/VideoGenerationModal.tsx"
];

let cleanCount = 0;
for (const f of files) {
  try {
    const src = fs.readFileSync(f, "utf8");
    if (!src.match(/\{\s*\.\.\.modal\.props\s*\}/) &&
        !src.match(/\{\s*\.\.\.mobileProps\s*\}/) &&
        !src.match(/\{\s*\.\.\.\{\s*\.\.\.modal\.props\s*\}\s*\}/)) {
      cleanCount++;
    }
  } catch(e) {
    // File moved/deleted — valid if TSC passes
    cleanCount++;
  }
}

// Also accept: useModal.ts no longer has onOpenAutoFocus in props
// (spreads become harmless)
let propsHarmless = false;
try {
  const hookSrc = fs.readFileSync("src/shared/hooks/useModal.ts", "utf8");
  if (!hookSrc.includes("onOpenAutoFocus")) {
    propsHarmless = true;
  }
  if (hookSrc.match(/props:\s*\{\s*\}/)) {
    propsHarmless = true;
  }
} catch(e) {
  propsHarmless = true;
}

if (cleanCount >= 5 || propsHarmless) {
  console.log("PASS: modal.props cleaned (" + cleanCount + "/8 files, propsHarmless=" + propsHarmless + ")");
  process.exit(0);
} else {
  console.log("FAIL: " + cleanCount + "/8 files cleaned, propsHarmless=" + propsHarmless);
  process.exit(1);
}
'
    G5_EXIT=$?
fi
if [ ${G5_EXIT:-1} -eq 0 ]; then
    add_score 0.20
fi

echo ""
echo "============================================================"
echo "FINAL SCORE: $SCORE"
echo "============================================================"

echo "$SCORE" > /logs/verifier/reward.txt
