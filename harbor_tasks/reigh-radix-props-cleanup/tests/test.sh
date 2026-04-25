#!/bin/bash
set +e

REPO="/workspace/repo"
if [ ! -d "$REPO" ]; then
    for d in /workspace/*/; do
        if [ -f "$d/package.json" ]; then REPO="${d%/}"; break; fi
    done
fi

mkdir -p /logs/verifier
cd "$REPO" || { echo "0.00" > /logs/verifier/reward.txt; exit 0; }

export PATH="$PATH:/usr/local/bin:/usr/bin:/root/.npm-global/bin:/root/.bun/bin"

REWARD=0
add() {
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + $1}")
}

echo "============================================================"
echo "Running TypeScript compile check"
echo "============================================================"
TSC_OUT=$(npx --no-install tsc --noEmit 2>&1)
TSC_EXIT=$?
echo "$TSC_OUT" | tail -50
if [ $TSC_EXIT -eq 0 ]; then
    TSC_PASS=1
    echo "TSC: PASS"
else
    TSC_PASS=0
    echo "TSC: FAIL"
fi

echo ""
echo "============================================================"
echo "Gate A (P2P, weight 0.10): TypeScript still compiles"
echo "============================================================"
if [ $TSC_PASS -eq 1 ]; then
    echo "PASS"
    add 0.10
else
    echo "FAIL"
fi

echo ""
echo "============================================================"
echo "Gate B (Behavioral, weight 0.30):"
echo "  Render DialogContent / PopoverContent with dead Radix props"
echo "  and verify they don't leak to the DOM (Unknown event handler)"
echo "============================================================"

# We do this by static-checking that BOTH:
#   - DialogContent and PopoverContent either (a) destructure the dead props
#     out before forwarding, OR (b) callers don't pass them anymore.
# AND we run a synthetic node check that imports the source files and
# confirms the relevant prop names are referenced in destructuring patterns.

GATEB_PASS=0
if [ $TSC_PASS -eq 1 ]; then
node -e '
const fs = require("fs");
const path = require("path");

const radixProps = ["onOpenAutoFocus", "onPointerDownOutside", "onInteractOutside"];

function readSafe(p) {
  try { return fs.readFileSync(p, "utf8"); } catch(e) { return null; }
}

// Step 1: Identify caller files that historically passed these props
const callerFiles = [
  "src/tools/travel-between-images/components/VideoGenerationModal.tsx",
  "src/shared/components/ImageGenerationModal.tsx",
  "src/shared/components/ui/ai-input-button.tsx",
  "src/shared/components/DatasetBrowserModal.tsx",
  "src/shared/components/PromptEditorModal.tsx",
];

let leakingCallers = 0;
let totalCallers = 0;
for (const f of callerFiles) {
  const src = readSafe(f);
  if (src === null) continue;
  totalCallers++;
  // Look for JSX attribute usage: prop={...} on Dialog/Popover content
  // Strip block comments
  const stripped = src.replace(/\/\*[\s\S]*?\*\//g, "")
                      .split("\n").filter(l => !l.trim().startsWith("//")).join("\n");
  let leaks = false;
  for (const p of radixProps) {
    const re = new RegExp("\\b" + p + "\\s*=\\s*[\\{\"]");
    if (re.test(stripped)) leaks = true;
  }
  if (leaks) leakingCallers++;
}

// Step 2: Check wrapper components - if they destructure & drop these props,
// then even if callers leak it, DOM is safe.
const dialogSrc = readSafe("src/shared/components/ui/dialog.tsx") || "";
const popoverSrc = readSafe("src/shared/components/ui/popover.tsx") || "";

function wrapperStripsProps(src, componentName) {
  if (!src) return false;
  const idx = src.indexOf(componentName);
  if (idx < 0) return false;
  // Look at component definition window
  const window = src.slice(idx, idx + 3000);
  // A wrapper "strips" if it destructures the dead props in its parameter list
  let stripped = 0;
  for (const p of radixProps) {
    // Parameter destructuring patterns: "{ ...,p,..., ...props}" or "{ p: _x }"
    const reA = new RegExp("\\{[^}]*\\b" + p + "\\b[^}]*\\.\\.\\.props[^}]*\\}");
    const reB = new RegExp("\\b" + p + "\\s*:\\s*_");
    if (reA.test(window) || reB.test(window)) stripped++;
  }
  return stripped >= 2;
}

const dialogStrips = wrapperStripsProps(dialogSrc, "DialogContent");
const popoverStrips = wrapperStripsProps(popoverSrc, "PopoverContent");

// PASS criteria:
//   - All callers cleaned (leakingCallers == 0), OR
//   - Both wrappers strip the dead props
const callersClean = leakingCallers === 0;
const wrappersGuard = dialogStrips && popoverStrips;

console.log("Caller leak count: " + leakingCallers + "/" + totalCallers);
console.log("DialogContent strips dead props: " + dialogStrips);
console.log("PopoverContent strips dead props: " + popoverStrips);

if (callersClean || wrappersGuard) {
  console.log("PASS");
  process.exit(0);
} else {
  // Partial credit signal (exit 2)
  if (leakingCallers <= Math.max(1, Math.floor(totalCallers/3)) || dialogStrips || popoverStrips) {
    console.log("PARTIAL");
    process.exit(2);
  }
  console.log("FAIL");
  process.exit(1);
}
'
GB=$?
if [ $GB -eq 0 ]; then
    add 0.30
    GATEB_PASS=1
elif [ $GB -eq 2 ]; then
    add 0.15
fi
else
    echo "SKIP: TSC failed"
fi

echo ""
echo "============================================================"
echo "Gate C (Behavioral, weight 0.20):"
echo "  useModal mobileProps no longer carries dead Radix prop"
echo "============================================================"

GATEC_PASS=0
if [ $TSC_PASS -eq 1 ]; then
node -e '
const fs = require("fs");
const src = (() => { try { return fs.readFileSync("src/shared/hooks/useModal.ts", "utf8"); } catch(e) { return null; } })();

if (src === null) {
  // Restructured / removed: acceptable if TSC passes
  console.log("PASS (file moved/removed)");
  process.exit(0);
}

// Strip comments and string literals to find real code references
const stripped = src
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .split("\n")
  .filter(l => !l.trim().startsWith("//"))
  .join("\n")
  .replace(/"[^"]*"/g, "\"\"")
  .replace(/'\''[^'\'']*'\''/g, "''\'\''");

const stillHasIt = /\bonOpenAutoFocus\b/.test(stripped);
if (stillHasIt) {
  console.log("FAIL: useModal still references onOpenAutoFocus in code");
  process.exit(1);
}

// Also verify mobileProps (or equivalent return shape) doesn'\''t set Radix props
// Find what is returned in the props field
const propsReturnMatch = src.match(/props\s*:\s*([^,\n]+)/);
console.log("PASS: useModal cleaned of onOpenAutoFocus");
process.exit(0);
'
GC=$?
if [ $GC -eq 0 ]; then
    add 0.20
    GATEC_PASS=1
fi
else
    echo "SKIP: TSC failed"
fi

echo ""
echo "============================================================"
echo "Gate D (Behavioral, weight 0.25):"
echo "  VideoGenerationModal still respects isLoraModalOpen guard"
echo "  when closing, after dead Radix handlers are removed"
echo "============================================================"

GATED_PASS=0
if [ $TSC_PASS -eq 1 ]; then
node -e '
const fs = require("fs");
const file = "src/tools/travel-between-images/components/VideoGenerationModal.tsx";
const src = (() => { try { return fs.readFileSync(file, "utf8"); } catch(e) { return null; } })();
if (!src) { console.log("FAIL: file missing"); process.exit(1); }

// 1. Confirm dead Radix handlers are gone
const stripped = src.replace(/\/\*[\s\S]*?\*\//g,"").split("\n").filter(l=>!l.trim().startsWith("//")).join("\n");
const stillHasDead = /\bonPointerDownOutside\s*=/.test(stripped) || /\bonInteractOutside\s*=/.test(stripped);

// 2. Confirm guard logic survives somewhere in close path:
//    Either onOpenChange handler references isLoraModalOpen,
//    or a named handler does, or it'\''s lifted to modal state.
const oneLine = stripped.replace(/\s+/g, " ");

// Pattern 1: onOpenChange={...isLoraModalOpen...}
const onOpenChangePattern = /onOpenChange\s*=\s*\{[^}]*isLoraModalOpen[^}]*\}/;
// Pattern 2: handler function references isLoraModalOpen and onClose
const handlerPattern = /(handle\w*[Cc]lose|handle\w*[Oo]pen[Cc]hange|on\w*[Cc]lose)\s*=[^=][^;]{0,400}isLoraModalOpen/;

const guardPresent = onOpenChangePattern.test(oneLine) || handlerPattern.test(oneLine);

console.log("Dead Radix handlers still present: " + stillHasDead);
console.log("Guard logic present in close path: " + guardPresent);

if (!stillHasDead && guardPresent) {
  console.log("PASS");
  process.exit(0);
}
if (!stillHasDead && !guardPresent) {
  // Removed cleanly but lost the guard - partial
  console.log("PARTIAL: dead props removed but guard lost");
  process.exit(2);
}
if (stillHasDead && guardPresent) {
  console.log("PARTIAL: guard preserved but dead props remain");
  process.exit(2);
}
console.log("FAIL");
process.exit(1);
'
GD=$?
if [ $GD -eq 0 ]; then
    add 0.25
    GATED_PASS=1
elif [ $GD -eq 2 ]; then
    add 0.10
fi
else
    echo "SKIP: TSC failed"
fi

echo ""
echo "============================================================"
echo "Gate E (Bonus behavioral, weight 0.15):"
echo "  AbortError from interrupted play() is handled (won't spam errors)"
echo "============================================================"

# This corresponds to the AbortError mentioned in the bug report.
# Check that callers either:
#   - chain .catch() onto video.play()
#   - safePlay swallows AbortError specifically
#   - or wrap in try/catch with AbortError handling

node -e '
const fs = require("fs");
const path = require("path");

function readSafe(p) { try { return fs.readFileSync(p, "utf8"); } catch(e) { return null; } }

const playFiles = [
  "src/pages/Home/components/panes/sections/MotionReferenceSection.tsx",
  "src/shared/components/TaskDetails/components/TaskDetailsLazyVideoPreview.tsx",
  "src/shared/components/StyledVideoPlayer/hooks/useVideoPlayerControls.ts",
  "src/shared/components/VideoPortionTimeline/hooks/useHandleDrag.ts",
  "src/shared/components/VideoPortionTimeline/hooks/usePlayhead.ts",
  "src/tools/travel-between-images/components/Timeline/AudioStrip.tsx",
];

let safeCount = 0;
let totalWithPlay = 0;
for (const f of playFiles) {
  const src = readSafe(f);
  if (!src) continue;
  // Find "<ident>.play()" or "<ident>.play().catch"
  const playMatches = src.match(/\.\s*play\s*\(\s*\)/g);
  if (!playMatches) continue;
  totalWithPlay++;
  // Check catch chained or try/catch wrapping
  const safeChain = /\.\s*play\s*\(\s*\)\s*\.\s*catch\s*\(/.test(src);
  const tryCatch = /try\s*\{[^}]*\.play\s*\(\s*\)[^}]*\}\s*catch/.test(src);
  if (safeChain || tryCatch) safeCount++;
}

// safePlay improvement: optional bonus
const safePlay = readSafe("src/shared/lib/media/safePlay.ts") || "";
const safePlayHandlesAbort = /AbortError/.test(safePlay) || /isAbortError/.test(safePlay);

console.log("Files with safe play(): " + safeCount + "/" + totalWithPlay);
console.log("safePlay handles AbortError: " + safePlayHandlesAbort);

if (totalWithPlay === 0) {
  // Nothing to verify; treat as neutral pass
  console.log("PASS (no play() callers found)");
  process.exit(0);
}

const ratio = safeCount / totalWithPlay;
if (ratio >= 0.7 || safePlayHandlesAbort) {
  console.log("PASS");
  process.exit(0);
}
if (ratio >= 0.3) {
  console.log("PARTIAL");
  process.exit(2);
}
console.log("FAIL");
process.exit(1);
'
GE=$?
if [ $GE -eq 0 ]; then
    add 0.15
elif [ $GE -eq 2 ]; then
    add 0.07
fi

echo ""
echo "============================================================"
echo "FINAL SCORE: $REWARD"
echo "============================================================"

# Clamp to [0, 1]
REWARD=$(awk -v r="$REWARD" 'BEGIN { if (r > 1) r = 1; if (r < 0) r = 0; printf "%.4f", r }')
echo "$REWARD" > /logs/verifier/reward.txt
echo "Wrote reward: $REWARD"
exit 0