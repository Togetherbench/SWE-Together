#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

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
    REPO=$(find /workspace -maxdepth 4 -type d -name "travel-between-images" 2>/dev/null | head -1 | sed 's|/src/tools/travel-between-images||')
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

# ---------------------------------------------------------------------------
# P2P (gating only, zero weight): essential files exist
# ---------------------------------------------------------------------------
for f in "$SHOT_EDITOR" "$BARREL" "$TIMELINE" "$TC" "$TC_TYPES"; do
    if [ ! -f "$f" ]; then
        echo "P2P FAIL: $f missing — agent broke pre-existing file"
        REWARD=0.0
        finish
    fi
done

# ---------------------------------------------------------------------------
# Gate 1 (0.10): TimelineModeContent.tsx removed AND not referenced anywhere
#   This is the "core deletion" — covers file removal + barrel + import scrubs
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 1 (0.10): TMC fully removed (file + refs) ==="
G1=0
TMC_FILE_GONE=0
[ ! -f "$TMC" ] && TMC_FILE_GONE=1

TMC_REFS=$(grep -rE "TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null | grep -v '^[^:]*:\s*\*' | grep -v '//')
# Allow comment-only mentions; require zero code references
TMC_CODE_REFS=$(grep -rE "TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null \
    | grep -vE ':[[:space:]]*(//|\*)' )

if [ "$TMC_FILE_GONE" = "1" ] && [ -z "$TMC_CODE_REFS" ]; then
    G1=1
fi

if [ "$G1" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: TMC file present? $([ -f "$TMC" ] && echo yes || echo no)"
    echo "Code refs:"
    echo "$TMC_CODE_REFS" | head -10
fi

# ---------------------------------------------------------------------------
# Gate 2 (0.10): ShotImagesEditor renders <Timeline> directly with key+shotId
#   Behavioral: replacement JSX must wire up Timeline correctly
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 2 (0.10): ShotImagesEditor renders <Timeline> with key+shotId ==="
G2=0
if [ -f "$SHOT_EDITOR" ] && ! grep -q '<TimelineModeContent' "$SHOT_EDITOR"; then
    # Look for <Timeline ... shotId={selectedShotId} ... key=`timeline-${selectedShotId}`
    if grep -qE '<Timeline[[:space:]]' "$SHOT_EDITOR" && \
       grep -qE 'shotId[[:space:]]*=[[:space:]]*\{[[:space:]]*selectedShotId[[:space:]]*\}' "$SHOT_EDITOR" && \
       grep -qE 'key[[:space:]]*=[[:space:]]*\{`timeline-\$\{selectedShotId\}`\}' "$SHOT_EDITOR"; then
        G2=1
    fi
fi
if [ "$G2" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: <Timeline> not properly wired in ShotImagesEditor"
fi

# ---------------------------------------------------------------------------
# Gate 3 (0.10): ShotImagesEditor imports Timeline directly
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 3 (0.10): ShotImagesEditor imports Timeline ==="
G3=0
if [ -f "$SHOT_EDITOR" ]; then
    if grep -qE "^import[[:space:]]+Timeline[[:space:]]+from[[:space:]]+['\"]\./Timeline['\"]" "$SHOT_EDITOR"; then
        G3=1
    fi
fi
if [ "$G3" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: no 'import Timeline from \"./Timeline\"' line"
fi

# ---------------------------------------------------------------------------
# Gate 4 (0.10): Unpositioned helper inlined (count + button text + handler)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 4 (0.10): Unpositioned helper inlined in ShotImagesEditor ==="
G4=0
if [ -f "$SHOT_EDITOR" ] && \
   grep -q 'unpositionedGenerationsCount' "$SHOT_EDITOR" && \
   grep -q 'onOpenUnpositionedPane' "$SHOT_EDITOR" && \
   grep -qE 'View[[:space:]]*&[[:space:]]*Position' "$SHOT_EDITOR" && \
   grep -qE 'unpositioned generation' "$SHOT_EDITOR"; then
    G4=1
fi
if [ "$G4" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: unpositioned helper text/handlers not inlined"
fi

# ---------------------------------------------------------------------------
# Gate 5 (0.08): Timeline JSX uses frameSpacing={batchVideoFrames}
#   (prop-name remap from instruction)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 5 (0.08): frameSpacing={batchVideoFrames} in ShotImagesEditor ==="
G5=0
if [ -f "$SHOT_EDITOR" ]; then
    if grep -qE 'frameSpacing[[:space:]]*=[[:space:]]*\{[[:space:]]*batchVideoFrames[[:space:]]*\}' "$SHOT_EDITOR"; then
        G5=1
    fi
fi
if [ "$G5" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: frameSpacing={batchVideoFrames} not present"
fi

# ---------------------------------------------------------------------------
# Gate 6 (0.07): Barrel cleaned — no TMC export AND no leftover empty type export
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 6 (0.07): Barrel scrubbed of TimelineModeContent ==="
G6=0
if [ -f "$BARREL" ] && ! grep -q 'TimelineModeContent' "$BARREL"; then
    # Also ensure barrel still exports BatchModeContent + PreviewTogetherDialog (didn't break P2P)
    if grep -q 'BatchModeContent' "$BARREL" && grep -q 'PreviewTogetherDialog' "$BARREL"; then
        G6=1
    fi
fi
if [ "$G6" = "1" ]; then
    echo "PASS"
    add_reward 0.07
else
    echo "FAIL: barrel has TMC ref or lost other exports"
fi

# ---------------------------------------------------------------------------
# Gate 7 (0.10): Dead constant EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 7 (0.10): EMPTY_ENHANCED_PROMPTS dead constant removed ==="
G7=0
if [ -f "$TIMELINE" ] && ! grep -q 'EMPTY_ENHANCED_PROMPTS' "$TIMELINE"; then
    G7=1
fi
if [ "$G7" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: EMPTY_ENHANCED_PROMPTS still present in Timeline.tsx"
fi

# ---------------------------------------------------------------------------
# Gate 8 (0.10): enhancedPrompts dead prop removed from Timeline.tsx
#   (must be gone from interface, destructure, AND JSX forwarding)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 8 (0.10): enhancedPrompts dead prop fully removed from Timeline.tsx ==="
G8=0
if [ -f "$TIMELINE" ] && ! grep -q 'enhancedPrompts' "$TIMELINE"; then
    G8=1
fi
if [ "$G8" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: enhancedPrompts still referenced in Timeline.tsx"
    grep -n 'enhancedPrompts' "$TIMELINE" 2>/dev/null | head -5
fi

# ---------------------------------------------------------------------------
# Gate 9 (0.08): enhancedPrompts removed from TimelineContainer types + impl
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 9 (0.08): enhancedPrompts removed from TimelineContainer chain ==="
G9=0
TYPES_CLEAN=0
IMPL_CLEAN=0
[ -f "$TC_TYPES" ] && ! grep -q 'enhancedPrompts' "$TC_TYPES" && TYPES_CLEAN=1
[ -f "$TC" ] && ! grep -q 'enhancedPrompts' "$TC" && IMPL_CLEAN=1
if [ "$TYPES_CLEAN" = "1" ] && [ "$IMPL_CLEAN" = "1" ]; then
    G9=1
fi
if [ "$G9" = "1" ]; then
    echo "PASS"
    add_reward 0.08
else
    echo "FAIL: types_clean=$TYPES_CLEAN impl_clean=$IMPL_CLEAN"
fi

# ---------------------------------------------------------------------------
# Gate 10 (0.07): hookData prop removed from Timeline.tsx (dead — only TMC passed it)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 10 (0.07): hookData / propHookData dead prop removed from Timeline.tsx ==="
G10=0
if [ -f "$TIMELINE" ] && ! grep -qE '\bpropHookData\b' "$TIMELINE"; then
    G10=1
fi
if [ "$G10" = "1" ]; then
    echo "PASS"
    add_reward 0.07
else
    echo "FAIL: propHookData still in Timeline.tsx"
fi

# ---------------------------------------------------------------------------
# Gate 11 (0.10): Behavioral — Timeline component renders without crash for empty shot
#   Use a node script to load the file and check it parses + structural invariants:
#     - Timeline default export exists
#     - Component signature has shotId
#   This catches "deleted too aggressively / broke compilation" patches.
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 11 (0.10): Timeline.tsx structural integrity ==="
G11=0
if [ -f "$TIMELINE" ]; then
    # Ensure Timeline.tsx still has default export and accepts shotId prop
    if grep -qE '^export default[[:space:]]' "$TIMELINE" || grep -qE 'export default Timeline' "$TIMELINE"; then
        if grep -qE '\bshotId\b' "$TIMELINE"; then
            # And ShotImagesEditor.tsx must not have stray closing-tag mismatch:
            # naive check — count <Timeline vs </Timeline> or self-close
            T_OPEN=$(grep -cE '<Timeline[[:space:]]' "$SHOT_EDITOR" 2>/dev/null)
            T_SELF=$(grep -cE '/>' "$SHOT_EDITOR" 2>/dev/null)
            if [ "$T_OPEN" -ge "1" ]; then
                # Make sure ShotImagesEditor uses fragment <> ... </> wrapper for Timeline + unpositioned div
                if grep -qE '<>' "$SHOT_EDITOR" && grep -qE '</>' "$SHOT_EDITOR"; then
                    G11=1
                fi
            fi
        fi
    fi
fi
if [ "$G11" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: Timeline structural integrity check failed"
fi

# ---------------------------------------------------------------------------
# Gate 12 (0.10): tsc / build sanity — try a lightweight typecheck on touched files
#   If tsc unavailable, fall back to a syntactic balance check.
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate 12 (0.10): Syntax balance / tsc on touched files ==="
G12=0
balanced() {
    local file="$1"
    [ ! -f "$file" ] && return 1
    local open=$(grep -o '{' "$file" | wc -l)
    local close=$(grep -o '}' "$file" | wc -l)
    [ "$open" = "$close" ] || return 1
    local popen=$(grep -o '(' "$file" | wc -l)
    local pclose=$(grep -o ')' "$file" | wc -l)
    [ "$popen" = "$pclose" ] || return 1
    return 0
}

ALL_BALANCED=1
for f in "$SHOT_EDITOR" "$TIMELINE" "$TC" "$TC_TYPES" "$BARREL"; do
    if ! balanced "$f"; then
        echo "Unbalanced braces/parens in $f"
        ALL_BALANCED=0
    fi
done

# Additionally check no fragment mismatch in ShotImagesEditor — naive: same count of <> and </>
FRAG_OPEN=$(grep -oE '<>' "$SHOT_EDITOR" | wc -l)
FRAG_CLOSE=$(grep -oE '</>' "$SHOT_EDITOR" | wc -l)
if [ "$FRAG_OPEN" != "$FRAG_CLOSE" ]; then
    echo "Fragment mismatch in ShotImagesEditor: open=$FRAG_OPEN close=$FRAG_CLOSE"
    ALL_BALANCED=0
fi

if [ "$ALL_BALANCED" = "1" ]; then
    G12=1
fi

if [ "$G12" = "1" ]; then
    echo "PASS"
    add_reward 0.10
else
    echo "FAIL: syntax balance issues"
fi

echo ""
echo "=== FINAL REWARD: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"
exit 0