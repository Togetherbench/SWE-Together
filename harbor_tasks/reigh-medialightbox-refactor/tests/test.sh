#!/bin/bash
set +e

# Nop score: 0.10 (only P2P Gate 1 passes on unmodified base)

# ─── Configuration ───────────────────────────────────────────────────────────
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

REWARD=0
add_reward() {
    # $1 = points to add (integer basis points, e.g. 10 = 0.10)
    REWARD=$((REWARD + $1))
    echo "$REWARD bp accumulated"
}

MAIN_FILE="src/shared/components/MediaLightbox/MediaLightbox.tsx"
COMPONENT_DIR="src/shared/components/MediaLightbox"
ORIGINAL_MAIN_LINES=2672
ORIGINAL_FILE_COUNT=91

cd /workspace/repo || { echo "FAIL: /workspace/repo not found"; exit 0; }

# ─── Gate 1 (P2P): TypeScript compilation ────────────────────────────────────
# P2P gate — passes on unmodified base AND on correct fix.
# Weight: 0.10 (10 bp)
echo "=== Gate 1: TypeScript compilation (P2P, weight=0.10) ==="
npx tsc --noEmit 2>/tmp/tsc_output.txt
TSC_EXIT=$?
if [ $TSC_EXIT -eq 0 ]; then
    echo "PASS: TypeScript compiles successfully"
    add_reward 10
    TSC_PASS=1
else
    echo "FAIL: TypeScript compilation errors:"
    tail -20 /tmp/tsc_output.txt
    TSC_PASS=0
fi

# ─── Gate 2 (F2P): Main component reduced + compiles ────────────────────────
# F2P gate — fails on unmodified base (2672 lines), passes when agent reduces
# it by >=20%. Gated on TypeScript compilation for behavioral verification.
# Weight: 0.30 (30 bp)
echo ""
echo "=== Gate 2: Main component reduced + compiles (F2P, weight=0.30) ==="
REFACTORED=0
if [ -f "$MAIN_FILE" ]; then
    CURRENT_LINES=$(wc -l < "$MAIN_FILE")
    REDUCTION_PCT=$(( (ORIGINAL_MAIN_LINES - CURRENT_LINES) * 100 / ORIGINAL_MAIN_LINES ))
    echo "Original: ${ORIGINAL_MAIN_LINES} lines, Current: ${CURRENT_LINES} lines, Reduction: ${REDUCTION_PCT}%"

    if [ "$TSC_PASS" -eq 1 ] && [ "$REDUCTION_PCT" -ge 30 ]; then
        echo "PASS: Reduced by ${REDUCTION_PCT}% AND TypeScript compiles"
        add_reward 30
        REFACTORED=1
    elif [ "$TSC_PASS" -eq 1 ] && [ "$REDUCTION_PCT" -ge 20 ]; then
        echo "PARTIAL: Reduced by ${REDUCTION_PCT}% AND TypeScript compiles"
        add_reward 20
        REFACTORED=1
    elif [ "$REDUCTION_PCT" -ge 20 ]; then
        echo "FAIL: Reduced by ${REDUCTION_PCT}% but TypeScript does NOT compile"
    else
        echo "FAIL: Reduction of ${REDUCTION_PCT}% is below 20% threshold"
    fi
else
    echo "FAIL: Main file deleted entirely — not a valid refactor"
fi

# ─── Gate 3 (F2P): New non-trivial abstraction files + compiles ─────────────
# F2P gate — fails on unmodified base. Checks that new TypeScript/React files
# were created as part of extraction AND they are non-trivial (>=10 lines).
# Gated on TypeScript compilation.
# Weight: 0.25 (25 bp)
echo ""
echo "=== Gate 3: New abstraction files created + compile (F2P, weight=0.25) ==="
CURRENT_FILE_COUNT=$(find "$COMPONENT_DIR" -type f \( -name "*.tsx" -o -name "*.ts" \) | wc -l)
NEW_IN_DIR=$((CURRENT_FILE_COUNT - ORIGINAL_FILE_COUNT))
NEW_IN_DIR=$((NEW_IN_DIR > 0 ? NEW_IN_DIR : 0))

# Count non-trivial new files (>=10 lines) — prevents stub gaming
NONTRIVIAL_NEW=0
if [ "$NEW_IN_DIR" -gt 0 ]; then
    while IFS= read -r f; do
        GIT_STATUS=$(git status --short "$f" 2>/dev/null | head -1)
        if echo "$GIT_STATUS" | grep -q "^?" 2>/dev/null; then
            FLINES=$(wc -l < "$f")
            if [ "$FLINES" -ge 10 ]; then
                NONTRIVIAL_NEW=$((NONTRIVIAL_NEW + 1))
            fi
        fi
    done < <(find "$COMPONENT_DIR" -type f \( -name "*.tsx" -o -name "*.ts" \))
fi

# Also count non-trivial new files via git (for committed changes)
GIT_NEW=$(git diff --name-only --diff-filter=A 2>/dev/null | grep -E '\.(tsx|ts)$' || true)
for f in $GIT_NEW; do
    if [ -f "$f" ]; then
        FLINES=$(wc -l < "$f")
        if [ "$FLINES" -ge 10 ]; then
            NONTRIVIAL_NEW=$((NONTRIVIAL_NEW + 1))
        fi
    fi
done

echo "New files in dir: ${NEW_IN_DIR}, Non-trivial (>=10 lines): ${NONTRIVIAL_NEW}"

if [ "$TSC_PASS" -eq 1 ] && [ "$NONTRIVIAL_NEW" -ge 3 ]; then
    echo "PASS: ${NONTRIVIAL_NEW} non-trivial new files AND TypeScript compiles"
    add_reward 25
elif [ "$TSC_PASS" -eq 1 ] && [ "$NONTRIVIAL_NEW" -ge 1 ]; then
    echo "PARTIAL: ${NONTRIVIAL_NEW} non-trivial new files AND compiles"
    add_reward 15
elif [ "$NONTRIVIAL_NEW" -ge 1 ]; then
    echo "FAIL: New files created but TypeScript does NOT compile"
else
    echo "FAIL: No non-trivial new abstraction files created"
fi

# ─── Gate 4 (F2P): Module API preserved after refactoring + compiles ────────
# F2P gate — only fires after refactoring happened (Gate 2 passed). Checks
# that public exports (default, key components, hooks) still exist.
# Gated on both REFACTORED and TSC_PASS.
# Weight: 0.20 (20 bp)
echo ""
echo "=== Gate 4: Module API preserved (F2P, weight=0.20) ==="

if [ "$REFACTORED" -eq 0 ]; then
    echo "SKIP (F2P): No refactoring detected, requires size reduction first"
else
    GATE4_CHECKS=0

    # Check 1: Default export
    if grep -rqE "export default" "$MAIN_FILE" 2>/dev/null || \
       grep -rqE "export.*default" "$COMPONENT_DIR/index.tsx" 2>/dev/null; then
        echo "  OK: Default export preserved"
        GATE4_CHECKS=$((GATE4_CHECKS + 1))
    else
        echo "  WARN: Default export missing"
    fi

    # Check 2: Key component exports anywhere in directory
    KEY_COMPS=0
    for COMP in NavigationButtons MediaDisplay MediaControls; do
        grep -rq "export.*${COMP}" "$COMPONENT_DIR" 2>/dev/null && KEY_COMPS=$((KEY_COMPS + 1))
    done
    if [ "$KEY_COMPS" -ge 2 ]; then
        echo "  OK: Key component exports preserved (${KEY_COMPS}/3)"
        GATE4_CHECKS=$((GATE4_CHECKS + 1))
    else
        echo "  WARN: Key component exports missing (${KEY_COMPS}/3)"
    fi

    # Check 3: Key hook exports
    KEY_HOOKS=0
    for HOOK in useUpscale useInpainting useLightboxNavigation; do
        grep -rq "export.*${HOOK}" "$COMPONENT_DIR" 2>/dev/null && KEY_HOOKS=$((KEY_HOOKS + 1))
    done
    if [ "$KEY_HOOKS" -ge 2 ]; then
        echo "  OK: Key hook exports preserved (${KEY_HOOKS}/3)"
        GATE4_CHECKS=$((GATE4_CHECKS + 1))
    else
        echo "  WARN: Key hook exports missing (${KEY_HOOKS}/3)"
    fi

    if [ "$TSC_PASS" -eq 1 ] && [ "$GATE4_CHECKS" -ge 2 ]; then
        echo "PASS: Module API preserved (${GATE4_CHECKS}/3) AND compiles"
        add_reward 20
    elif [ "$TSC_PASS" -eq 1 ] && [ "$GATE4_CHECKS" -ge 1 ]; then
        echo "PARTIAL: Some API preserved (${GATE4_CHECKS}/3) and compiles"
        add_reward 10
    else
        echo "FAIL: API broken or TypeScript does not compile"
    fi
fi

# ─── Gate 5 (F2P): Code extracted not deleted + compiles ────────────────────
# F2P gate — ensures code was moved to new files, not deleted. Total lines
# across the codebase should remain >= 70% of original.
# Only meaningful after refactoring happened.
# Weight: 0.15 (15 bp)
echo ""
echo "=== Gate 5: Code extracted not deleted (F2P, weight=0.15) ==="

if [ "$REFACTORED" -eq 0 ]; then
    echo "SKIP (F2P): No refactoring detected, requires size reduction first"
else
    CURRENT_TOTAL=$(find "$COMPONENT_DIR" -type f \( -name "*.tsx" -o -name "*.ts" \) -exec cat {} + 2>/dev/null | wc -l)

    # Count lines in new files outside MediaLightbox dir
    EXTRA=0
    for f in $(git diff --name-only --diff-filter=A 2>/dev/null | grep -E '\.(tsx|ts)$' || true); do
        if [ -f "$f" ] && ! echo "$f" | grep -q "MediaLightbox"; then
            EXTRA=$((EXTRA + $(wc -l < "$f")))
        fi
    done

    ADJUSTED=$((CURRENT_TOTAL + EXTRA))
    ORIG_TOTAL=21893
    THRESHOLD=$((ORIG_TOTAL * 70 / 100))
    echo "Dir total: ${CURRENT_TOTAL}, Extra: ${EXTRA}, Adjusted: ${ADJUSTED}, Threshold(70%): ${THRESHOLD}"

    if [ "$TSC_PASS" -eq 1 ] && [ "$ADJUSTED" -ge "$THRESHOLD" ]; then
        echo "PASS: Code extracted, not deleted, and compiles"
        add_reward 15
    elif [ "$ADJUSTED" -ge "$THRESHOLD" ]; then
        echo "FAIL: Code preserved but TypeScript does NOT compile"
    else
        echo "FAIL: Too much code was deleted (adjusted ${ADJUSTED} < threshold ${THRESHOLD})"
    fi
fi

# ─── Final Score ─────────────────────────────────────────────────────────────
echo ""
echo "=== Final Score ==="
FINAL=$(awk "BEGIN {printf \"%.2f\", $REWARD / 100}")
echo "Total: $FINAL (${REWARD}/100 bp)"
echo "$FINAL" > "$REWARD_FILE"
