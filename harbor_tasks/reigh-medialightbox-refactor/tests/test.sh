#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"
REWARD=0

emit() {
    awk -v r="$REWARD" 'BEGIN { printf("%.4f\n", r/100) }' > "$REWARD_FILE"
}

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Locate workspace
WORKSPACE=""
for cand in /workspace/repo /workspace/reigh /workspace/medialightbox-refactor /workspace; do
    if [ -d "$cand/src/shared/components/MediaLightbox" ]; then
        WORKSPACE="$cand"
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 6 -type d -name "MediaLightbox" 2>/dev/null | head -1)
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

MAIN_FILE="src/shared/components/MediaLightbox/MediaLightbox.tsx"
COMPONENT_DIR="src/shared/components/MediaLightbox"
ORIGINAL_MAIN_LINES=2672

if [ ! -f "$MAIN_FILE" ]; then
    echo "FATAL: $MAIN_FILE missing"
    emit
    exit 0
fi

# ─── P2P GATE: TypeScript still compiles (gating only) ────────────────────
echo ""
echo "=== P2P GATE: TypeScript compiles (gating, 0bp) ==="
if command -v npx >/dev/null 2>&1; then
    timeout 420 npx --no-install tsc --noEmit > /tmp/tsc_output.txt 2>&1
    TSC_EXIT=$?
    if [ $TSC_EXIT -eq 0 ]; then
        echo "PASS: tsc clean"
    else
        ERR_COUNT=$(grep -cE "error TS[0-9]+" /tmp/tsc_output.txt 2>/dev/null)
        # Allow tsc to fail only if MAIN_FILE itself isn't the source of new errors
        # (project may have unrelated pre-existing errors). Check if errors reference component dir.
        COMP_ERRS=$(grep -E "error TS[0-9]+" /tmp/tsc_output.txt | grep -c "$COMPONENT_DIR")
        echo "tsc errors: total=$ERR_COUNT, component=$COMP_ERRS"
        tail -25 /tmp/tsc_output.txt
        if [ "$COMP_ERRS" -gt 0 ]; then
            echo "Regression in component: REWARD=0"
            REWARD=0
            emit
            exit 0
        fi
        echo "Errors are not in MediaLightbox component dir — continuing"
    fi
else
    echo "SKIP: npx unavailable"
fi

# ─── Collect new files ────────────────────────────────────────────────────
NEW_FILES_RAW=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | awk '/^\?\?/ {print $2} /^A/ {print $2} /^AM/ {print $2}' | grep -E "^${COMPONENT_DIR}.*\.(ts|tsx)$")
MODIFIED_FILES_RAW=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | awk '/^ M|^M / {print $2} /^MM/ {print $2}' | grep -E "^${COMPONENT_DIR}.*\.(ts|tsx)$")

NEW_FILE_LIST=()
SUBSTANTIVE=0
TOTAL_NEW_LINES=0
NEW_HOOKS=0
NEW_UTILS=0
NEW_COMPONENTS=0
NEW_CONTEXTS=0

if [ -n "$NEW_FILES_RAW" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -f "$f" ]; then
            FLINES=$(wc -l < "$f")
            TOTAL_NEW_LINES=$((TOTAL_NEW_LINES + FLINES))
            if [ "$FLINES" -ge 15 ] && grep -qE "^export " "$f" 2>/dev/null; then
                SUBSTANTIVE=$((SUBSTANTIVE + 1))
                NEW_FILE_LIST+=("$f")
                case "$f" in
                    *"/hooks/"*) NEW_HOOKS=$((NEW_HOOKS+1)) ;;
                    *"/utils/"*) NEW_UTILS=$((NEW_UTILS+1)) ;;
                    *"/components/"*) NEW_COMPONENTS=$((NEW_COMPONENTS+1)) ;;
                    *"/contexts/"*|*"Context"*) NEW_CONTEXTS=$((NEW_CONTEXTS+1)) ;;
                esac
            fi
        fi
    done <<< "$NEW_FILES_RAW"
fi

echo "Substantive new files: $SUBSTANTIVE (hooks=$NEW_HOOKS utils=$NEW_UTILS components=$NEW_COMPONENTS contexts=$NEW_CONTEXTS) total_lines=$TOTAL_NEW_LINES"

CURRENT_LINES=$(wc -l < "$MAIN_FILE")
REDUCTION_PCT=$(( (ORIGINAL_MAIN_LINES - CURRENT_LINES) * 100 / ORIGINAL_MAIN_LINES ))
echo "MediaLightbox.tsx: orig=$ORIGINAL_MAIN_LINES current=$CURRENT_LINES reduction=${REDUCTION_PCT}%"

# ─── F2P GATE 1 (20bp): Main component meaningfully reduced ───────────────
echo ""
echo "=== GATE 1 (20bp): Line reduction in MediaLightbox.tsx ==="
G1=0
if [ "$REDUCTION_PCT" -ge 25 ]; then
    G1=20
    echo "EXCELLENT: ≥25% reduction → +20"
elif [ "$REDUCTION_PCT" -ge 12 ]; then
    G1=13
    echo "GOOD: ≥12% reduction → +13"
elif [ "$REDUCTION_PCT" -ge 5 ]; then
    G1=6
    echo "PARTIAL: ≥5% reduction → +6"
else
    echo "FAIL: <5% reduction"
fi
REWARD=$((REWARD + G1))

# ─── F2P GATE 2 (15bp): New substantive abstractions exist & diverse ──────
echo ""
echo "=== GATE 2 (15bp): New substantive modules with diversity ==="
G2=0
DIVERSITY=0
[ "$NEW_HOOKS" -ge 1 ] && DIVERSITY=$((DIVERSITY+1))
[ "$NEW_UTILS" -ge 1 ] && DIVERSITY=$((DIVERSITY+1))
[ "$NEW_COMPONENTS" -ge 1 ] && DIVERSITY=$((DIVERSITY+1))
[ "$NEW_CONTEXTS" -ge 1 ] && DIVERSITY=$((DIVERSITY+1))

if [ "$SUBSTANTIVE" -ge 4 ] && [ "$TOTAL_NEW_LINES" -ge 250 ] && [ "$DIVERSITY" -ge 2 ]; then
    G2=15
    echo "EXCELLENT: 4+ modules, ≥250 lines, ≥2 categories → +15"
elif [ "$SUBSTANTIVE" -ge 2 ] && [ "$TOTAL_NEW_LINES" -ge 100 ]; then
    G2=9
    echo "GOOD: 2+ modules → +9"
elif [ "$SUBSTANTIVE" -ge 1 ] && [ "$TOTAL_NEW_LINES" -ge 30 ]; then
    G2=4
    echo "PARTIAL: 1 module → +4"
else
    echo "FAIL: no substantive new modules"
fi
REWARD=$((REWARD + G2))

# ─── F2P GATE 3 (15bp): New modules wired into main ───────────────────────
echo ""
echo "=== GATE 3 (15bp): Wiring of new modules into main ==="
WIRED_COUNT=0
BROKEN_IMPORTS=0

if [ ${#NEW_FILE_LIST[@]} -gt 0 ]; then
    for nf in "${NEW_FILE_LIST[@]}"; do
        modname=$(basename "$nf" | sed 's/\.[tj]sx\?$//')
        case "$modname" in
            index|types|constants) continue ;;
        esac
        if grep -qE "(from ['\"][^'\"]*${modname}['\"])|(\\b${modname}\\b)" "$MAIN_FILE" 2>/dev/null; then
            WIRED_COUNT=$((WIRED_COUNT + 1))
            continue
        fi
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
    G3=15
    echo "EXCELLENT: 4+ wired, clean imports → +15"
elif [ "$WIRED_COUNT" -ge 2 ] && [ "$BROKEN_IMPORTS" -eq 0 ]; then
    G3=9
    echo "GOOD: 2+ wired → +9"
elif [ "$WIRED_COUNT" -ge 1 ] && [ "$BROKEN_IMPORTS" -eq 0 ]; then
    G3=4
    echo "PARTIAL: 1 wired → +4"
else
    echo "FAIL: insufficient wiring or broken imports"
fi
REWARD=$((REWARD + G3))

# ─── F2P GATE 4 (15bp): Behavioral — dimension extraction extracted & correct ──
# A meaningful refactor extracts the resolutionToDimensions / extractDimensionsFromMedia
# logic into a reusable module. We test BEHAVIOR via bun on the extracted file.
echo ""
echo "=== GATE 4 (15bp): Behavioral test of extracted dimension utility ==="
G4=0

# Find a candidate utils file containing extractDimensionsFromMedia
DIM_FILE=$(grep -rEl "export (function|const) (extractDimensionsFromMedia|resolutionToDimensions)" "$COMPONENT_DIR" 2>/dev/null | grep -v MediaLightbox.tsx | head -1)

# Also: must NOT be defined inline in MediaLightbox.tsx (means it was actually extracted)
INLINE_RES_DEF=$(grep -cE "const resolutionToDimensions = \\(resolution: string\\)" "$MAIN_FILE" 2>/dev/null)
INLINE_EXTRACT_DEF=$(grep -cE "const extractDimensionsFromMedia = " "$MAIN_FILE" 2>/dev/null)

echo "DIM_FILE: $DIM_FILE"
echo "Inline resolutionToDimensions in main: $INLINE_RES_DEF"
echo "Inline extractDimensionsFromMedia in main: $INLINE_EXTRACT_DEF"

if [ -n "$DIM_FILE" ] && [ "$INLINE_RES_DEF" -eq 0 ] && [ "$INLINE_EXTRACT_DEF" -eq 0 ]; then
    # Behavioral test using bun if available
    if command -v bun >/dev/null 2>&1; then
        cat > /tmp/dim_test.ts <<EOF
// Stub the aspectRatios import path
import { resolutionToDimensions } from '$WORKSPACE/$DIM_FILE';

let pass = 0, fail = 0;
function check(name: string, actual: any, expected: any) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) { pass++; console.log("PASS:", name); }
  else { fail++; console.log("FAIL:", name, "got", JSON.stringify(actual), "expected", JSON.stringify(expected)); }
}

check("1024x768", resolutionToDimensions("1024x768"), { width: 1024, height: 768 });
check("1920x1080", resolutionToDimensions("1920x1080"), { width: 1920, height: 1080 });
check("invalid_empty", resolutionToDimensions(""), null);
check("invalid_no_x", resolutionToDimensions("1024"), null);
check("invalid_negative", resolutionToDimensions("-1x100"), null);
check("invalid_zero", resolutionToDimensions("0x0"), null);

console.log("RESULTS:", pass, "/", pass+fail);
process.exit(fail === 0 ? 0 : 1);
EOF
        # Try running with bun, but module resolution may fail due to '@/' aliases
        timeout 30 bun run /tmp/dim_test.ts > /tmp/dim_test_out.txt 2>&1
        BUN_EXIT=$?
        cat /tmp/dim_test_out.txt
        PASS_COUNT=$(grep -c "^PASS:" /tmp/dim_test_out.txt 2>/dev/null)
        if [ "$BUN_EXIT" -eq 0 ] && [ "$PASS_COUNT" -ge 6 ]; then
            G4=15
            echo "EXCELLENT: extracted util works correctly (6/6 cases) → +15"
        elif [ "$PASS_COUNT" -ge 4 ]; then
            G4=10
            echo "GOOD: extracted util mostly works ($PASS_COUNT cases) → +10"
        else
            # Fall back to structural: file exists with proper exports + symbols look right
            if grep -qE "split\\('x'\\)" "$DIM_FILE" 2>/dev/null && \
               grep -qE "isNaN" "$DIM_FILE" 2>/dev/null; then
                G4=8
                echo "PARTIAL: extracted util has correct structure (bun run failed) → +8"
            else
                G4=4
                echo "PARTIAL: extracted file exists but behavior unverifiable → +4"
            fi
        fi
    else
        # No bun — structural check on extracted file
        if grep -qE "split\\('x'\\)" "$DIM_FILE" 2>/dev/null && \
           grep -qE "isNaN" "$DIM_FILE" 2>/dev/null && \
           grep -qE "ASPECT_RATIO|aspect_ratio" "$DIM_FILE" 2>/dev/null; then
            G4=10
            echo "GOOD: extracted util has correct logic shape (no bun for behavior test) → +10"
        else
            G4=4
            echo "PARTIAL: extracted file exists → +4"
        fi
    fi
elif [ -n "$DIM_FILE" ]; then
    G4=4
    echo "PARTIAL: util extracted but inline definitions still in main → +4"
else
    echo "FAIL: dimension utility not extracted"
fi
REWARD=$((REWARD + G4))

# ─── F2P GATE 5 (15bp): Removal of inline noise (debug logs / dead code) ──
# A real refactor removes the heavy console.log debug blocks from the main file.
echo ""
echo "=== GATE 5 (15bp): Inline noise removed from main ==="
G5=0

# Count specific noise patterns that existed in the original
RESOLUTION_DEBUG=$(grep -c "ResolutionDebug" "$MAIN_FILE" 2>/dev/null)
MOUNTED_BANNER=$(grep -c "MOUNTED/CHANGED" "$MAIN_FILE" 2>/dev/null)
VARIANT_FETCH_DEBUG=$(grep -c "VariantFetchDebug" "$MAIN_FILE" 2>/dev/null)
VARIANT_DISPLAY_DEBUG=$(grep -c "VariantDisplay" "$MAIN_FILE" 2>/dev/null)
LIGHTBOX_EMOJI=$(grep -cE "console\\.log\\('\\[MediaLightbox\\] [🎬💀]" "$MAIN_FILE" 2>/dev/null)

NOISE_TOTAL=$((RESOLUTION_DEBUG + MOUNTED_BANNER + VARIANT_FETCH_DEBUG + VARIANT_DISPLAY_DEBUG + LIGHTBOX_EMOJI))
echo "Noise markers remaining in main: ResDebug=$RESOLUTION_DEBUG Mounted=$MOUNTED_BANNER VarFetch=$VARIANT_FETCH_DEBUG VarDisplay=$VARIANT_DISPLAY_DEBUG Emoji=$LIGHTBOX_EMOJI total=$NOISE_TOTAL"

# Also check console.log density: original had ~50+ console.logs in main
CONSOLE_LOGS=$(grep -c "console\\.log" "$MAIN_FILE" 2>/dev/null)
echo "console.log count in main: $CONSOLE_LOGS"

if [ "$NOISE_TOTAL" -le 2 ] && [ "$CONSOLE_LOGS" -le 10 ]; then
    G5=15
    echo "EXCELLENT: noise gone, few console.logs → +15"
elif [ "$NOISE_TOTAL" -le 5 ] && [ "$CONSOLE_LOGS" -le 25 ]; then
    G5=9
    echo "GOOD: most noise removed → +9"
elif [ "$NOISE_TOTAL" -le 8 ] || [ "$CONSOLE_LOGS" -le 40 ]; then
    G5=4
    echo "PARTIAL: some cleanup → +4"
else
    echo "FAIL: noise still present"
fi
REWARD=$((REWARD + G5))

# ─── F2P GATE 6 (10bp): Hooks index / barrel updated to expose new hooks ──
echo ""
echo "=== GATE 6 (10bp): Hooks barrel exports new modules ==="
G6=0
HOOKS_INDEX="$COMPONENT_DIR/hooks/index.ts"
UTILS_INDEX="$COMPONENT_DIR/utils/index.ts"
INDEX_EXPORTS=0

if [ -f "$HOOKS_INDEX" ]; then
    HOOK_NEW_EXPORTS=0
    for nf in "${NEW_FILE_LIST[@]}"; do
        case "$nf" in
            *"/hooks/"*)
                modname=$(basename "$nf" | sed 's/\.[tj]sx\?$//')
                [ "$modname" = "index" ] && continue
                if grep -q "$modname" "$HOOKS_INDEX" 2>/dev/null; then
                    HOOK_NEW_EXPORTS=$((HOOK_NEW_EXPORTS + 1))
                fi
            ;;
        esac
    done
    INDEX_EXPORTS=$((INDEX_EXPORTS + HOOK_NEW_EXPORTS))
    echo "New hook exports in hooks/index.ts: $HOOK_NEW_EXPORTS"
fi

if [ -f "$UTILS_INDEX" ]; then
    UTIL_NEW_EXPORTS=0
    for nf in "${NEW_FILE_LIST[@]}"; do
        case "$nf" in
            *"/utils/"*)
                modname=$(basename "$nf" | sed 's/\.[tj]sx\?$//')
                [ "$modname" = "index" ] && continue
                if grep -q "$modname" "$UTILS_INDEX" 2>/dev/null; then
                    UTIL_NEW_EXPORTS=$((UTIL_NEW_EXPORTS + 1))
                fi
            ;;
        esac
    done
    INDEX_EXPORTS=$((INDEX_EXPORTS + UTIL_NEW_EXPORTS))
    echo "New util exports in utils/index.ts: $UTIL_NEW_EXPORTS"
fi

if [ "$INDEX_EXPORTS" -ge 3 ]; then
    G6=10
    echo "EXCELLENT: 3+ barrel exports → +10"
elif [ "$INDEX_EXPORTS" -ge 1 ]; then
    G6=5
    echo "GOOD: 1+ barrel export → +5"
else
    # Soft fallback: at least one new file directly imports from ./hooks or ./utils path
    if grep -qE "from '\\./hooks/" "$MAIN_FILE" || grep -qE "from '\\./utils/" "$MAIN_FILE"; then
        G6=2
        echo "PARTIAL: direct subdir imports in main → +2"
    else
        echo "FAIL: barrel not updated"
    fi
fi
REWARD=$((REWARD + G6))

# ─── F2P GATE 7 (10bp): Run unit tests if any exist for the component ─────
echo ""
echo "=== GATE 7 (10bp): Run any existing tests touching MediaLightbox ==="
G7=0
TEST_FILES=$(find "$WORKSPACE" -type f \( -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.spec.ts" -o -name "*.spec.tsx" \) 2>/dev/null | xargs grep -l "MediaLightbox\|extractDimensionsFromMedia\|resolutionToDimensions" 2>/dev/null | head -5)

if [ -n "$TEST_FILES" ]; then
    echo "Test files found:"
    echo "$TEST_FILES"
    if command -v npx >/dev/null 2>&1; then
        TEST_PASS=0
        TEST_FAIL=0
        for tf in $TEST_FILES; do
            timeout 90 npx --no-install vitest run "$tf" --reporter=verbose > /tmp/vitest_out.txt 2>&1
            VEXIT=$?
            P=$(grep -cE "✓|PASS|passed" /tmp/vitest_out.txt)
            F=$(grep -cE "✗|FAIL|failed" /tmp/vitest_out.txt)
            echo "  $tf: exit=$VEXIT pass~$P fail~$F"
            [ "$VEXIT" -eq 0 ] && TEST_PASS=$((TEST_PASS+1)) || TEST_FAIL=$((TEST_FAIL+1))
        done
        if [ "$TEST_PASS" -gt 0 ] && [ "$TEST_FAIL" -eq 0 ]; then
            G7=10
            echo "EXCELLENT: all relevant tests pass → +10"
        elif [ "$TEST_PASS" -gt 0 ]; then
            G7=5
            echo "PARTIAL: some tests pass → +5"
        fi
    else
        # No test runner; gate is a no-op (don't penalize)
        G7=5
        echo "SKIP: no test runner — neutral +5"
    fi
else
    # No tests exist for component — neutral credit (don't penalize)
    G7=5
    echo "No relevant test files exist — neutral credit +5"
fi
REWARD=$((REWARD + G7))

echo ""
echo "================================"
echo "Subtotals: G1=$G1 G2=$G2 G3=$G3 G4=$G4 G5=$G5 G6=$G6 G7=$G7"
echo "Total raw points: $REWARD / 100"

# Cap at 100
if [ "$REWARD" -gt 100 ]; then
    REWARD=100
fi

emit
echo "Final reward: $(cat $REWARD_FILE)"
echo "$REWARD" > /logs/verifier/reward.txt
emit