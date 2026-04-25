#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null
chmod 777 "$(dirname "$REWARD_FILE")" 2>/dev/null

REWARD=0.0

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{r=a+b; if(r>1.0)r=1.0; printf "%.4f", r}')
}

finish() {
    echo "$REWARD" > "$REWARD_FILE"
    exit 0
}

# Detect repo path
REPO=""
for candidate in /workspace/reigh /workspace/repo; do
    if [ -d "$candidate/src/tools/travel-between-images" ]; then
        REPO="$candidate"
        break
    fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 3 -type d -name "travel-between-images" 2>/dev/null | head -1 | sed 's|/src/tools/travel-between-images||')
fi

echo "Using REPO=$REPO"

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot find repo"
    REWARD=0.0
    finish
fi

SRC="$REPO/src"
TBI="$REPO/src/tools/travel-between-images/components"
TMC="$TBI/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$TBI/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$TBI/ShotImagesEditor.tsx"
TIMELINE="$TBI/Timeline.tsx"
TC="$TBI/Timeline/TimelineContainer/TimelineContainer.tsx"
TC_TYPES="$TBI/Timeline/TimelineContainer/types.ts"

###############################################################################
# F2P-1 (0.10): TimelineModeContent.tsx file deleted
# - Base state: file exists (buggy/no-op fails this)
###############################################################################
echo ""
echo "=== F2P-1: TimelineModeContent.tsx deleted/removed ==="
F2P1=0
if [ ! -f "$TMC" ]; then
    F2P1=1
fi
if [ "$F2P1" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: $TMC still present (no-op state)"
fi

###############################################################################
# F2P-2 (0.08): Barrel no longer exports TimelineModeContent
# - Base state: barrel exports it
###############################################################################
echo ""
echo "=== F2P-2: Barrel doesn't export TimelineModeContent ==="
F2P2=0
if [ ! -f "$BARREL" ]; then
    F2P2=1
elif ! grep -q 'TimelineModeContent' "$BARREL"; then
    F2P2=1
fi
if [ "$F2P2" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: barrel still references TimelineModeContent"
fi

###############################################################################
# F2P-3 (0.08): No TimelineModeContent references anywhere in src/
# - Base state: imports/usages exist
###############################################################################
echo ""
echo "=== F2P-3: No TimelineModeContent references in src/ ==="
F2P3=0
TMC_REFS=$(grep -rE "TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null)
if [ -z "$TMC_REFS" ]; then
    F2P3=1
fi
if [ "$F2P3" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: refs:"
    echo "$TMC_REFS" | head -5
fi

###############################################################################
# F2P-4 (0.10): ShotImagesEditor renders <Timeline> directly (not <TimelineModeContent>)
# - Base state: ShotImagesEditor renders <TimelineModeContent>
###############################################################################
echo ""
echo "=== F2P-4: ShotImagesEditor renders <Timeline> directly ==="
F2P4=0
if [ -f "$SHOT_EDITOR" ]; then
    if ! grep -q '<TimelineModeContent' "$SHOT_EDITOR" && \
       grep -qE '<Timeline[[:space:]>]' "$SHOT_EDITOR"; then
        F2P4=1
    fi
fi
if [ "$F2P4" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: ShotImagesEditor doesn't render <Timeline> directly"
fi

###############################################################################
# F2P-5 (0.08): ShotImagesEditor imports Timeline (replaces TMC import)
# - Base state: only imports TimelineModeContent (via barrel), not Timeline directly
###############################################################################
echo ""
echo "=== F2P-5: ShotImagesEditor imports Timeline directly ==="
F2P5=0
if [ -f "$SHOT_EDITOR" ]; then
    # Look for an import line that brings Timeline into scope
    if grep -qE "^import[[:space:]]+Timeline[[:space:]]+from" "$SHOT_EDITOR" || \
       grep -qE "^import[[:space:]]+\{[^}]*\bTimeline\b[^}]*\}[[:space:]]+from" "$SHOT_EDITOR"; then
        F2P5=1
    fi
fi
if [ "$F2P5" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: no Timeline import in ShotImagesEditor"
fi

###############################################################################
# F2P-6 (0.08): Unpositioned-generations helper inlined in ShotImagesEditor
# - Base state: helper lives only in TimelineModeContent
###############################################################################
echo ""
echo "=== F2P-6: Unpositioned helper inlined in ShotImagesEditor ==="
F2P6=0
if [ -f "$SHOT_EDITOR" ] && \
   grep -q 'unpositionedGenerationsCount' "$SHOT_EDITOR" && \
   grep -q 'onOpenUnpositionedPane' "$SHOT_EDITOR" && \
   grep -qE 'View[[:space:]]*&[[:space:]]*Position' "$SHOT_EDITOR"; then
    F2P6=1
fi
if [ "$F2P6" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: unpositioned helper not inlined"
fi

###############################################################################
# F2P-7 (0.06): Timeline `frameSpacing` prop set from batchVideoFrames in ShotImagesEditor
# - Base state: ShotImagesEditor doesn't render <Timeline> at all → fails
###############################################################################
echo ""
echo "=== F2P-7: Timeline JSX uses frameSpacing={batchVideoFrames} ==="
F2P7=0
if [ -f "$SHOT_EDITOR" ]; then
    # Look for frameSpacing={batchVideoFrames} (allow whitespace)
    if grep -qE 'frameSpacing[[:space:]]*=[[:space:]]*\{[[:space:]]*batchVideoFrames[[:space:]]*\}' "$SHOT_EDITOR"; then
        F2P7=1
    fi
fi
if [ "$F2P7" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL: frameSpacing={batchVideoFrames} not present"
fi

###############################################################################
# F2P-8 (0.06): EMPTY_ENHANCED_PROMPTS dead-code constant removed from Timeline.tsx
# - Base state: constant exists in Timeline.tsx
###############################################################################
echo ""
echo "=== F2P-8: EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx ==="
F2P8=0
if [ -f "$TIMELINE" ]; then
    if ! grep -q 'EMPTY_ENHANCED_PROMPTS' "$TIMELINE"; then
        F2P8=1
    fi
fi
if [ "$F2P8" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL: EMPTY_ENHANCED_PROMPTS still present"
fi

###############################################################################
# F2P-9 (0.06): enhancedPrompts prop removed from Timeline.tsx interface/JSX
# - Base state: enhancedPrompts referenced in Timeline.tsx
###############################################################################
echo ""
echo "=== F2P-9: enhancedPrompts dead prop removed from Timeline.tsx ==="
F2P9=0
if [ -f "$TIMELINE" ]; then
    if ! grep -q 'enhancedPrompts' "$TIMELINE"; then
        F2P9=1
    fi
fi
if [ "$F2P9" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL: enhancedPrompts still referenced in Timeline.tsx"
fi

###############################################################################
# F2P-10 (0.06): enhancedPrompts removed from TimelineContainer types
# - Base state: it's declared
###############################################################################
echo ""
echo "=== F2P-10: enhancedPrompts removed from TimelineContainer types.ts ==="
F2P10=0
if [ -f "$TC_TYPES" ]; then
    if ! grep -q 'enhancedPrompts' "$TC_TYPES"; then
        F2P10=1
    fi
fi
if [ "$F2P10" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL: enhancedPrompts still in TC types.ts"
fi

###############################################################################
# F2P-11 (0.06): enhancedPrompts removed from TimelineContainer.tsx (destructure & usage)
# - Base state: it's destructured & used
###############################################################################
echo ""
echo "=== F2P-11: enhancedPrompts removed from TimelineContainer.tsx ==="
F2P11=0
if [ -f "$TC" ]; then
    if ! grep -q 'enhancedPrompts' "$TC"; then
        F2P11=1
    fi
fi
if [ "$F2P11" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL: enhancedPrompts still in TimelineContainer.tsx"
fi

###############################################################################
# F2P-12 (0.06): TypeScript compiles after refactor (gated F2P)
# Only counts as F2P here if the no-op base does NOT compile (we verify behavior).
# To stay strictly safe (no-op = 0), we award this ONLY when ALL prior structural
# F2Ps that imply real edits passed AND tsc passes. On a no-op patch, F2P-1..6 fail
# so this is not even reached for credit.
###############################################################################
echo ""
echo "=== F2P-12: TypeScript compiles cleanly after refactor ==="
F2P12=0
# Only attempt tsc if the agent actually performed the refactor (gate on F2P-1 + F2P-4)
if [ "$F2P1" = "1" ] && [ "$F2P4" = "1" ]; then
    if [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
        cd "$REPO"
        export PATH="$REPO/node_modules/.bin:$PATH"
        TSC_OUT=$(npx --no-install tsc --noEmit 2>&1)
        TSC_RC=$?
        if [ $TSC_RC -eq 0 ]; then
            F2P12=1
        else
            ERR_COUNT=$(echo "$TSC_OUT" | grep -c 'error TS')
            echo "tsc errors: $ERR_COUNT"
            echo "$TSC_OUT" | grep 'error TS' | head -5
        fi
    else
        echo "tsc tooling unavailable; skipping (no credit)"
    fi
else
    echo "Skipped: prerequisite structural F2Ps not satisfied"
fi
if [ "$F2P12" = "1" ]; then
    echo "PASS"
    add_reward 0.06
else
    echo "FAIL or skipped"
fi

###############################################################################
# F2P-13 (0.12): BatchModeContent untouched (regression guard for refactor scope)
# Make this an F2P that requires both:
#   (a) BatchModeContent still rendered (no-op renders it too — so this alone is P2P)
#   (b) AND TimelineModeContent removed (the refactor actually happened)
# Combined, it fails on no-op (because (b) fails) and on a destructive refactor that
# breaks BatchModeContent.
###############################################################################
echo ""
echo "=== F2P-13: Refactor scope correct — BatchModeContent preserved AND TMC removed ==="
F2P13=0
if [ -f "$SHOT_EDITOR" ] && \
   grep -qE '<BatchModeContent[[:space:]>]' "$SHOT_EDITOR" && \
   [ "$F2P1" = "1" ] && [ "$F2P3" = "1" ]; then
    F2P13=1
fi
if [ "$F2P13" = "1" ]; then
    echo "PASS"
    add_reward 0.12
else
    echo "FAIL: either BatchModeContent missing or TMC not fully removed"
fi

###############################################################################
echo ""
echo "=== Final reward: $REWARD ==="
finish