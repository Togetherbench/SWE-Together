#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"
REWARD=0

emit() {
    awk -v r="$REWARD" 'BEGIN { printf("%.4f\n", r/100) }' > "$REWARD_FILE"
}

# Locate workspace
WORKSPACE=""
for cand in /workspace/repo /workspace/reigh /workspace/medialightbox-refactor /workspace; do
    if [ -d "$cand/src/shared/components/MediaLightbox" ]; then
        WORKSPACE="$cand"
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 5 -type d -name "MediaLightbox" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(echo "$found" | sed 's|/src/shared/components/MediaLightbox||')
    fi
fi

if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    echo "FATAL: workspace not found"
    emit
    exit 0
fi
echo "Workspace: $WORKSPACE"
cd "$WORKSPACE" || { emit; exit 0; }

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v npx >/dev/null 2>&1 || export PATH="/usr/lib/node_modules/.bin:$PATH"

MAIN_FILE="src/shared/components/MediaLightbox/MediaLightbox.tsx"
COMPONENT_DIR="src/shared/components/MediaLightbox"
ORIGINAL_MAIN_LINES=2672

if [ ! -f "$MAIN_FILE" ]; then
    echo "FATAL: $MAIN_FILE missing"
    emit
    exit 0
fi

# ─── P2P GATE: TypeScript still compiles ─────────────────────────────────
# Gating only — no reward. Original base compiles, so failure means the agent broke things.
echo ""
echo "=== P2P GATE: TypeScript compiles (gating, 0bp) ==="
TSC_PASS=0
if command -v npx >/dev/null 2>&1; then
    timeout 360 npx --no-install tsc --noEmit > /tmp/tsc_output.txt 2>&1
    TSC_EXIT=$?
    if [ $TSC_EXIT -eq 0 ]; then
        echo "PASS: tsc clean"
        TSC_PASS=1
    else
        ERR_COUNT=$(grep -cE "error TS[0-9]+" /tmp/tsc_output.txt 2>/dev/null)
        echo "FAIL: tsc errors ($ERR_COUNT)"
        tail -25 /tmp/tsc_output.txt
        echo "Regression: setting reward to 0 and exiting."
        REWARD=0
        emit
        exit 0
    fi
else
    echo "SKIP: npx unavailable — gate cannot run; assuming pass for grading other gates"
    TSC_PASS=1
fi

# Collect newly-added .ts/.tsx files inside the component dir
NEW_FILES_RAW=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | awk '/^\?\?/ {print $2} /^A/ {print $2} /^AM/ {print $2}' | grep -E "^${COMPONENT_DIR}.*\.(ts|tsx)$")

NEW_FILE_LIST=()
SUBSTANTIVE=0
TOTAL_NEW_LINES=0

if [ -n "$NEW_FILES_RAW" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -f "$f" ]; then
            FLINES=$(wc -l < "$f")
            TOTAL_NEW_LINES=$((TOTAL_NEW_LINES + FLINES))
            if [ "$FLINES" -ge 15 ] && grep -qE "^export " "$f" 2>/dev/null; then
                SUBSTANTIVE=$((SUBSTANTIVE + 1))
                NEW_FILE_LIST+=("$f")
            fi
        fi
    done <<< "$NEW_FILES_RAW"
fi

echo "New substantive files: $SUBSTANTIVE, total new lines: $TOTAL_NEW_LINES"

# ─── F2P GATE 1 (30bp): Main component meaningfully reduced ────────────────
# On base: main = 2672 lines → reduction = 0%. Fails. Only the agent's edits can pass this.
echo ""
echo "=== F2P GATE 1 (up to 30bp): MediaLightbox.tsx line reduction ==="
CURRENT_LINES=$(wc -l < "$MAIN_FILE")
REDUCTION_PCT=$(( (ORIGINAL_MAIN_LINES - CURRENT_LINES) * 100 / ORIGINAL_MAIN_LINES ))
echo "Original: ${ORIGINAL_MAIN_LINES}, Current: ${CURRENT_LINES}, Reduction: ${REDUCTION_PCT}%"

G1=0
if [ "$REDUCTION_PCT" -ge 30 ]; then
    G1=30
    echo "EXCELLENT: ≥30% reduction → +30"
elif [ "$REDUCTION_PCT" -ge 18 ]; then
    G1=20
    echo "GOOD: ≥18% reduction → +20"
elif [ "$REDUCTION_PCT" -ge 8 ]; then
    G1=10
    echo "PARTIAL: ≥8% reduction → +10"
else
    echo "FAIL: reduction below 8%"
fi
REWARD=$((REWARD + G1))

# ─── F2P GATE 2 (25bp): Substantive new abstractions exist ────────────────
# On base: 0 new files. Fails.
echo ""
echo "=== F2P GATE 2 (up to 25bp): New substantive modules ==="
G2=0
if [ "$SUBSTANTIVE" -ge 5 ] && [ "$TOTAL_NEW_LINES" -ge 300 ]; then
    G2=25
    echo "EXCELLENT: 5+ substantive modules, ≥300 lines → +25"
elif [ "$SUBSTANTIVE" -ge 3 ] && [ "$TOTAL_NEW_LINES" -ge 150 ]; then
    G2=16
    echo "GOOD: 3+ substantive modules → +16"
elif [ "$SUBSTANTIVE" -ge 1 ] && [ "$TOTAL_NEW_LINES" -ge 30 ]; then
    G2=8
    echo "PARTIAL: 1+ substantive module → +8"
else
    echo "FAIL: no substantive new modules"
fi
REWARD=$((REWARD + G2))

# ─── F2P GATE 3 (25bp): New modules wired into main / barrel & imports clean ─
# On base: no new modules → wired count = 0. Fails.
echo ""
echo "=== F2P GATE 3 (up to 25bp): New modules wired into main and import-clean ==="
WIRED_COUNT=0
BROKEN_IMPORTS=0

if [ ${#NEW_FILE_LIST[@]} -gt 0 ]; then
    for nf in "${NEW_FILE_LIST[@]}"; do
        modname=$(basename "$nf" | sed 's/\.[tj]sx\?$//')
        case "$modname" in
            index|types|constants) continue ;;
        esac
        # Direct import in main, or referenced symbol used in main.
        if grep -qE "(from ['\"][^'\"]*${modname}['\"])|(\\b${modname}\\b)" "$MAIN_FILE" 2>/dev/null; then
            WIRED_COUNT=$((WIRED_COUNT + 1))
            continue
        fi
        # Otherwise transitively used through any new file that IS wired
        for other in "${NEW_FILE_LIST[@]}"; do
            [ "$other" = "$nf" ] && continue
            othermod=$(basename "$other" | sed 's/\.[tj]sx\?$//')
            if grep -qE "\\b${modname}\\b" "$other" 2>/dev/null && \
               grep -qE "\\b${othermod}\\b" "$MAIN_FILE" 2>/dev/null; then
                WIRED_COUNT=$((WIRED_COUNT + 1))
                break
            fi
        done
    done

    # Broken-relative-imports check
    for nf in "${NEW_FILE_LIST[@]}"; do
        DIR=$(dirname "$nf")
        while IFS= read -r line; do
            ipath=$(echo "$line" | sed -nE "s/.*from ['\"](\\.\\.[^'\"]*|\\.[^'\"]*)['\"].*/\\1/p")
            [ -z "$ipath" ] && continue
            resolved="$DIR/$ipath"
            if [ ! -f "$resolved" ] && [ ! -f "$resolved.ts" ] && [ ! -f "$resolved.tsx" ] && \
               [ ! -f "$resolved/index.ts" ] && [ ! -f "$resolved/index.tsx" ]; then
                BROKEN_IMPORTS=$((BROKEN_IMPORTS + 1))
            fi
        done < <(grep -E "^import .* from ['\"]\\.\\.?/" "$nf" 2>/dev/null)
    done
fi

echo "Wired modules: $WIRED_COUNT, broken relative imports: $BROKEN_IMPORTS"

G3=0
if [ "$WIRED_COUNT" -ge 4 ] && [ "$BROKEN_IMPORTS" -eq 0 ]; then
    G3=25
    echo "EXCELLENT: 4+ modules wired, imports clean → +25"
elif [ "$WIRED_COUNT" -ge 2 ] && [ "$BROKEN_IMPORTS" -eq 0 ]; then
    G3=16
    echo "GOOD: 2+ modules wired, imports clean → +16"
elif [ "$WIRED_COUNT" -ge 1 ] && [ "$BROKEN_IMPORTS" -eq 0 ]; then
    G3=8
    echo "PARTIAL: 1 module wired → +8"
else
    echo "FAIL: insufficient wiring or broken imports"
fi
REWARD=$((REWARD + G3))

# ─── F2P GATE 4 (20bp): Behavioral signal — extracted code is real, not a stub,
# and main no longer contains the duplicated logic it should be importing.
# On base: main still contains all its original inline definitions of e.g.
# resolutionToDimensions / aspectRatioToDimensions, large debug-log useEffects, etc.
# Detect any one of several plausible refactor signals; agent must show ≥2 of them.
echo ""
echo "=== F2P GATE 4 (up to 20bp): Behavioral refactor signals ==="

SIGNALS=0

# Signal A: Inline resolutionToDimensions (function/const) was REMOVED from main.tsx.
# (Original main defines it inline; refactored versions remove and import.)
if ! grep -qE "(const|function)[[:space:]]+resolutionToDimensions[[:space:]]*[=(]" "$MAIN_FILE" 2>/dev/null; then
    echo "Signal A: inline resolutionToDimensions removed from main"
    SIGNALS=$((SIGNALS + 1))
else
    echo "Signal A: still inline in main"
fi

# Signal B: Inline aspectRatioToDimensions removed from main.tsx
if ! grep -qE "(const|function)[[:space:]]+aspectRatioToDimensions[[:space:]]*[=(]" "$MAIN_FILE" 2>/dev/null; then
    echo "Signal B: inline aspectRatioToDimensions removed from main"
    SIGNALS=$((SIGNALS + 1))
else
    echo "Signal B: still inline in main"
fi

# Signal C: Number of console.log calls in main reduced by ≥30% vs original.
# Original main had a high count of debug logs; count them now.
LOG_COUNT=$(grep -cE "console\.(log|warn|info|debug)\(" "$MAIN_FILE" 2>/dev/null)
# Approximate baseline: original had >80 console statements. Refactor should significantly reduce.
if [ "$LOG_COUNT" -lt 50 ]; then
    echo "Signal C: console.* count is $LOG_COUNT (<50) — debug noise reduced"
    SIGNALS=$((SIGNALS + 1))
else
    echo "Signal C: console.* count $LOG_COUNT not reduced enough"
fi

# Signal D: A new hook file beginning with 'use' exists and is exported as a hook
HOOK_HIT=0
for nf in "${NEW_FILE_LIST[@]}"; do
    base=$(basename "$nf")
    if echo "$base" | grep -qE "^use[A-Z]"; then
        if grep -qE "^export (function|const) use[A-Z]" "$nf" 2>/dev/null; then
            HOOK_HIT=1
            break
        fi
    fi
done
if [ $HOOK_HIT -eq 1 ]; then
    echo "Signal D: at least one new useXxx hook exported"
    SIGNALS=$((SIGNALS + 1))
else
    echo "Signal D: no new useXxx hook"
fi

# Signal E: A new component file (.tsx) was added that exports a React component
COMP_HIT=0
for nf in "${NEW_FILE_LIST[@]}"; do
    case "$nf" in
        *.tsx)
            if grep -qE "^export (default |const |function )[A-Z]" "$nf" 2>/dev/null; then
                COMP_HIT=1
                break
            fi
            ;;
    esac
done
if [ $COMP_HIT -eq 1 ]; then
    echo "Signal E: new .tsx component extracted"
    SIGNALS=$((SIGNALS + 1))
else
    echo "Signal E: no new component .tsx"
fi

echo "Total refactor signals: $SIGNALS / 5"

G4=0
if [ "$SIGNALS" -ge 4 ]; then
    G4=20
    echo "EXCELLENT: ≥4 signals → +20"
elif [ "$SIGNALS" -ge 2 ]; then
    G4=12
    echo "GOOD: ≥2 signals → +12"
elif [ "$SIGNALS" -ge 1 ]; then
    G4=5
    echo "PARTIAL: 1 signal → +5"
else
    echo "FAIL: no behavioral refactor signals"
fi
REWARD=$((REWARD + G4))

# ─── Final ─────────────────────────────────────────────────────────────────
echo ""
echo "=== TOTAL: $REWARD / 100 ==="
emit
exit 0