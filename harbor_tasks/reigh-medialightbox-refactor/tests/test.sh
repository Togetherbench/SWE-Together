#!/bin/bash
set +e

# Reward file setup
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

REWARD=0
add_reward() {
    REWARD=$((REWARD + $1))
    echo "  +$1 bp (total: $REWARD bp)"
}

# Find workspace path
WORKSPACE=""
for cand in /workspace/repo /workspace/reigh /workspace/medialightbox-refactor /workspace; do
    if [ -d "$cand/src/shared/components/MediaLightbox" ]; then
        WORKSPACE="$cand"
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 4 -type d -name "MediaLightbox" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(echo "$found" | sed 's|/src/shared/components/MediaLightbox||')
    fi
fi

if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    echo "FATAL: Could not locate workspace with MediaLightbox component"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi
echo "Workspace: $WORKSPACE"
cd "$WORKSPACE" || { echo "0.0" > "$REWARD_FILE"; exit 0; }

# Ensure tools on PATH
export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
command -v npx >/dev/null 2>&1 || export PATH="/usr/lib/node_modules/.bin:$PATH"

MAIN_FILE="src/shared/components/MediaLightbox/MediaLightbox.tsx"
COMPONENT_DIR="src/shared/components/MediaLightbox"
ORIGINAL_MAIN_LINES=2672
ORIGINAL_FILE_COUNT=91

# ─── Gate 1 (P2P): TypeScript still compiles ────────────────────────────────
# Weight: 15 bp
echo ""
echo "=== Gate 1 (P2P, 15bp): TypeScript compiles ==="
TSC_PASS=0
if command -v npx >/dev/null 2>&1; then
    timeout 300 npx --no-install tsc --noEmit > /tmp/tsc_output.txt 2>&1
    TSC_EXIT=$?
    if [ $TSC_EXIT -eq 0 ]; then
        echo "PASS: TypeScript compiles"
        add_reward 15
        TSC_PASS=1
    else
        ERR_COUNT=$(grep -cE "error TS[0-9]+" /tmp/tsc_output.txt 2>/dev/null || echo 0)
        echo "FAIL: TypeScript errors ($ERR_COUNT errors)"
        tail -25 /tmp/tsc_output.txt
    fi
else
    echo "SKIP: npx not available"
fi

# ─── Gate 2 (F2P): MediaLightbox.tsx is meaningfully smaller ─────────────────
# Weight: 20 bp (graduated)
echo ""
echo "=== Gate 2 (F2P, up to 20bp): Main component reduced ==="
REFACTORED=0
CURRENT_LINES=0
REDUCTION_PCT=0
if [ -f "$MAIN_FILE" ]; then
    CURRENT_LINES=$(wc -l < "$MAIN_FILE")
    REDUCTION_PCT=$(( (ORIGINAL_MAIN_LINES - CURRENT_LINES) * 100 / ORIGINAL_MAIN_LINES ))
    echo "Original: ${ORIGINAL_MAIN_LINES} lines, Current: ${CURRENT_LINES} lines, Reduction: ${REDUCTION_PCT}%"

    if [ "$REDUCTION_PCT" -ge 35 ]; then
        echo "EXCELLENT: ${REDUCTION_PCT}% reduction"
        add_reward 20
        REFACTORED=1
    elif [ "$REDUCTION_PCT" -ge 20 ]; then
        echo "GOOD: ${REDUCTION_PCT}% reduction"
        add_reward 14
        REFACTORED=1
    elif [ "$REDUCTION_PCT" -ge 10 ]; then
        echo "PARTIAL: ${REDUCTION_PCT}% reduction"
        add_reward 7
        REFACTORED=1
    else
        echo "FAIL: Reduction ${REDUCTION_PCT}% below 10%"
    fi
else
    echo "FAIL: Main file missing"
fi

# ─── Gate 3 (F2P): Real new abstractions exist (substantive, not stubs) ─────
# Weight: 20 bp
echo ""
echo "=== Gate 3 (F2P, up to 20bp): New substantive abstractions ==="
NEW_FILES=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null | awk '/^\?\?/ {print $2} /^A/ {print $2}' | grep -E "^${COMPONENT_DIR}.*\.(ts|tsx)$")
NEW_FILE_LIST=()
NONTRIVIAL=0
SUBSTANTIVE=0
TOTAL_NEW_LINES=0
HAS_HOOK=0
HAS_COMPONENT=0
HAS_UTIL=0

if [ -n "$NEW_FILES" ]; then
    while IFS= read -r f; do
        if [ -f "$f" ]; then
            FLINES=$(wc -l < "$f")
            TOTAL_NEW_LINES=$((TOTAL_NEW_LINES + FLINES))
            if [ "$FLINES" -ge 15 ]; then
                NONTRIVIAL=$((NONTRIVIAL + 1))
                NEW_FILE_LIST+=("$f")
                # Substantive = has at least one export
                if grep -qE "^export " "$f" 2>/dev/null; then
                    SUBSTANTIVE=$((SUBSTANTIVE + 1))
                fi
                # Categorize
                case "$f" in
                    *hooks/use*|*useUse*) HAS_HOOK=1 ;;
                    *components/*) HAS_COMPONENT=1 ;;
                    *utils/*|*helpers/*) HAS_UTIL=1 ;;
                esac
                # Hook detection by content
                grep -qE "^export (function |const )use[A-Z]" "$f" 2>/dev/null && HAS_HOOK=1
            fi
        fi
    done <<< "$NEW_FILES"
fi

echo "New files: $(echo "$NEW_FILES" | grep -c .), nontrivial: $NONTRIVIAL, substantive: $SUBSTANTIVE, total new lines: $TOTAL_NEW_LINES"
echo "Has hook: $HAS_HOOK, component: $HAS_COMPONENT, util: $HAS_UTIL"

G3_SCORE=0
if [ "$SUBSTANTIVE" -ge 5 ] && [ "$TOTAL_NEW_LINES" -ge 300 ]; then
    G3_SCORE=20
    echo "EXCELLENT: 5+ substantive new modules with significant content"
elif [ "$SUBSTANTIVE" -ge 3 ] && [ "$TOTAL_NEW_LINES" -ge 150 ]; then
    G3_SCORE=14
    echo "GOOD: 3+ substantive new modules"
elif [ "$SUBSTANTIVE" -ge 1 ] && [ "$TOTAL_NEW_LINES" -ge 30 ]; then
    G3_SCORE=7
    echo "PARTIAL: At least 1 substantive new module"
else
    echo "FAIL: No substantive new abstractions"
fi
[ $G3_SCORE -gt 0 ] && add_reward $G3_SCORE

# ─── Gate 4 (F2P/Behavioral): New modules import-clean & wired into main ────
# Weight: 20 bp — verifies extracted code is actually consumed by main
echo ""
echo "=== Gate 4 (F2P, up to 20bp): New modules wired into main ==="
WIRED_COUNT=0
IMPORT_CLEAN=0
if [ -f "$MAIN_FILE" ] && [ ${#NEW_FILE_LIST[@]} -gt 0 ]; then
    for nf in "${NEW_FILE_LIST[@]}"; do
        # Get module name (filename without extension)
        modname=$(basename "$nf" | sed 's/\.[tj]sx\?$//')
        # Skip generic names
        case "$modname" in
            index|types|constants) continue ;;
        esac
        # Check if main file imports it (directly or via barrel)
        if grep -qE "(from ['\"].*${modname}['\"])|(\\b${modname}\\b)" "$MAIN_FILE" 2>/dev/null; then
            WIRED_COUNT=$((WIRED_COUNT + 1))
        else
            # Check barrel exports
            if grep -rqE "export.*${modname}" "$COMPONENT_DIR"/index.* "$COMPONENT_DIR"/hooks/index.* "$COMPONENT_DIR"/components/index.* "$COMPONENT_DIR"/utils/index.* 2>/dev/null; then
                # transitively used? check main imports the barrel symbol
                if grep -qE "\\b${modname}\\b" "$MAIN_FILE" 2>/dev/null; then
                    WIRED_COUNT=$((WIRED_COUNT + 1))
                fi
            fi
        fi
    done
fi

# Also check no broken-internal-imports: for each new file, confirm referenced relative imports resolve
BROKEN_IMPORTS=0
for nf in "${NEW_FILE_LIST[@]}"; do
    DIR=$(dirname "$nf")
    while IFS= read -r line; do
        # extract relative import path
        ipath=$(echo "$line" | sed -nE "s/.*from ['\"](\\.\\.[^'\"]*|\\.[^'\"]*)['\"].*/\\1/p")
        [ -z "$ipath" ] && continue
        resolved="$DIR/$ipath"
        # try .ts, .tsx, /index.ts, /index.tsx
        if [ ! -f "$resolved" ] && [ ! -f "$resolved.ts" ] && [ ! -f "$resolved.tsx" ] && \
           [ ! -f "$resolved/index.ts" ] && [ ! -f "$resolved/index.tsx" ]; then
            BROKEN_IMPORTS=$((BROKEN_IMPORTS + 1))
        fi
    done < <(grep -E "^import .* from ['\"]\\.\\.?/" "$nf" 2>/dev/null)
done

[ $BROKEN_IMPORTS -eq 0 ] && IMPORT_CLEAN=1
echo "Wired modules: $WIRED_COUNT, broken relative imports in new files: $BROKEN_IMPORTS"

G4_SCORE=0
if [ "$TSC_PASS" -eq 1 ] && [ "$WIRED_COUNT" -ge 3 ] && [ "$IMPORT_CLEAN" -eq 1 ]; then
    G4_SCORE=20
    echo "EXCELLENT: 3+ extracted modules wired into main, all imports clean"
elif [ "$TSC_PASS" -eq 1 ] && [ "$WIRED_COUNT" -ge 1 ] && [ "$IMPORT_CLEAN" -eq 1 ]; then
    G4_SCORE=12
    echo "GOOD: At least 1 module wired into main, imports clean"
elif [ "$WIRED_COUNT" -ge 1 ]; then
    G4_SCORE=5
    echo "PARTIAL: Modules created but compile or imports issues"
else
    echo "FAIL: New modules not wired into main"
fi
[ $G4_SCORE -gt 0 ] && add_reward $G4_SCORE

# ─── Gate 5 (F2P): Code preserved (extracted, not deleted) ──────────────────
# Weight: 10 bp
echo ""
echo "=== Gate 5 (F2P, up to 10bp): Code preserved through extraction ==="
if [ "$REFACTORED" -eq 0 ]; then
    echo "SKIP: No refactor detected"
else
    CURRENT_TOTAL=$(find "$COMPONENT_DIR" -type f \( -name "*.tsx" -o -name "*.ts" \) -exec cat {} + 2>/dev/null | wc -l)
    EXTRA=0
    while IFS= read -r f; do
        if [ -f "$f" ] && ! echo "$f" | grep -q "MediaLightbox"; then
            EXTRA=$((EXTRA + $(wc -l < "$f")))
        fi
    done < <(git -C "$WORKSPACE" diff --name-only --diff-filter=A 2>/dev/null | grep -E '\.(tsx|ts)$')
    ADJUSTED=$((CURRENT_TOTAL + EXTRA))
    ORIG_TOTAL=21893
    PCT=$((ADJUSTED * 100 / ORIG_TOTAL))
    echo "Adjusted total: $ADJUSTED / $ORIG_TOTAL ($PCT%)"

    if [ "$PCT" -ge 85 ]; then
        echo "EXCELLENT: Code preserved well"
        add_reward 10
    elif [ "$PCT" -ge 70 ]; then
        echo "GOOD: Most code preserved"
        add_reward 6
    else
        echo "FAIL: Code appears deleted, not extracted"
    fi
fi

# ─── Gate 6 (P2P/Structural): Public API + import-from-tree intact ──────────
# Weight: 15 bp
echo ""
echo "=== Gate 6 (P2P, up to 15bp): Public API preserved ==="
API_SCORE=0
# Default export reachable
if grep -rqE "^export default" "$MAIN_FILE" 2>/dev/null || \
   grep -rqE "^export.*default" "$COMPONENT_DIR"/index.* 2>/dev/null; then
    API_SCORE=$((API_SCORE + 5))
    echo "  OK: default export reachable"
else
    echo "  WARN: default export missing"
fi

# Verify the top-level component name is still the export
if grep -qE "(export default (MediaLightbox|function MediaLightbox|React\\.memo|memo\\())" "$MAIN_FILE" 2>/dev/null || \
   grep -rqE "MediaLightbox" "$COMPONENT_DIR"/index.* 2>/dev/null; then
    API_SCORE=$((API_SCORE + 3))
    echo "  OK: MediaLightbox name preserved"
fi

# Resolve module via TS resolution test (a tiny script)
cat > /tmp/api_check.ts <<'EOF'
import M from "./src/shared/components/MediaLightbox/MediaLightbox";
const _check: any = M;
EOF
if command -v npx >/dev/null 2>&1; then
    cp /tmp/api_check.ts ./_api_check.ts 2>/dev/null
    timeout 120 npx --no-install tsc --noEmit --jsx preserve --esModuleInterop --skipLibCheck --moduleResolution node ./_api_check.ts > /tmp/api_resolve.txt 2>&1
    APIEX=$?
    rm -f ./_api_check.ts
    # Lenient: accept if the import line itself doesn't fail (other errors in repo unrelated)
    if ! grep -qE "Cannot find module.*MediaLightbox" /tmp/api_resolve.txt 2>/dev/null; then
        API_SCORE=$((API_SCORE + 7))
        echo "  OK: MediaLightbox module resolvable"
    else
        echo "  FAIL: MediaLightbox module not resolvable"
    fi
fi
echo "API score: $API_SCORE / 15"
add_reward $API_SCORE

# ─── Final write ────────────────────────────────────────────────────────────
echo ""
echo "=== TOTAL: $REWARD bp ==="
FINAL=$(awk -v r=$REWARD 'BEGIN { printf "%.4f", r/100 }')
# clamp to [0,1]
FINAL=$(awk -v f=$FINAL 'BEGIN { if (f>1) f=1; if (f<0) f=0; printf "%.4f", f }')
echo "$FINAL" > "$REWARD_FILE"
echo "Final reward: $FINAL"
exit 0