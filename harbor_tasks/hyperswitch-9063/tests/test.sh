#!/bin/bash
# Test: Verify underscore-to-hyphen locale fix in hyperswitch
# The fix involves changing underscore to hyphen in payment link locale handling.
# There are multiple locations in the codebase that need this fix:
#   1. transformers.rs - HeaderPayload locale extraction (original PR target, 2 occurrences)
#   2. utils.rs - get_locale_from_header utility function
#   3. locale.js - JavaScript locale key names (en_gb, fr_be, zh_hant)
#   4. context.rs - generic link response locale handling
#   5. locale yml files - locale file names
#   6. middleware.rs - locale param normalization
# Tests reward finding and fixing MORE locations (breadth = understanding)

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

# Find repo root
REPO_DIR=""
for candidate in "/workspace/hyperswitch" "/workspace/repos/hyperswitch_pool_9"; do
    if [ -d "$candidate/.git" ]; then
        REPO_DIR="$candidate"
        break
    fi
done

if [ -z "$REPO_DIR" ]; then
    echo "FAIL: Could not find repository"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

echo "Repo: $REPO_DIR"
cd "$REPO_DIR"
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null

TRANSFORMERS="$REPO_DIR/crates/router/src/types/transformers.rs"
UTILS="$REPO_DIR/crates/router/src/utils.rs"
LOCALE_JS="$REPO_DIR/crates/router/src/core/payment_link/locale.js"
CONTEXT_RS="$REPO_DIR/crates/router/src/services/api/generic_link_response/context.rs"
MIDDLEWARE="$REPO_DIR/crates/router/src/middleware.rs"

BASE_COMMIT="8446ffbf5992a97d79d129cade997effc60fcd85"

# Get the full diff from base
FULL_DIFF=$(git diff "$BASE_COMMIT" HEAD 2>/dev/null)
if [ -z "$FULL_DIFF" ]; then
    FULL_DIFF=$(git diff 2>/dev/null)
fi
if [ -z "$FULL_DIFF" ]; then
    FULL_DIFF=$(git diff --cached 2>/dev/null)
fi

CHANGED_FILES=$(echo "$FULL_DIFF" | grep "^diff --git" | sed 's|diff --git a/||;s| b/.*||')
echo "Changed files:"
echo "$CHANGED_FILES"
echo ""

SCORE=0

# ============================================================
# CHECK 1 (weight 0.10): Basic engagement - any file modified
# ============================================================
echo "--- Check 1: Any file modified (0.10) ---"
if [ -n "$CHANGED_FILES" ]; then
    echo "PASS"
    SCORE=$(awk "BEGIN {print $SCORE + 0.10}")
else
    echo "FAIL: No files were modified"
fi

# ============================================================
# CHECK 2 (weight 0.25): transformers.rs locale lines fixed
# This is the PRIMARY fix location from the original PR.
# Both v1 and v2 impl blocks need the fix.
# ============================================================
echo ""
echo "--- Check 2: transformers.rs locale fix (0.25) ---"

TRANS_SCORE=0
if [ -f "$TRANSFORMERS" ]; then
    IMPL_LINES=$(grep -n "ForeignTryFrom<&HeaderMap>" "$TRANSFORMERS" | cut -d: -f1)
    IMPL1=$(echo "$IMPL_LINES" | head -1)
    IMPL2=$(echo "$IMPL_LINES" | tail -1)

    if [ -n "$IMPL1" ] && [ -n "$IMPL2" ] && [ "$IMPL1" != "$IMPL2" ]; then
        # Check v1 block
        BLOCK1=$(sed -n "${IMPL1},${IMPL2}p" "$TRANSFORMERS")
        LOCALE1=$(echo "$BLOCK1" | grep -A1 "let locale" | tr '\n' ' ')
        if echo "$LOCALE1" | grep -qE "replace"; then
            TRANS_SCORE=$((TRANS_SCORE + 1))
            echo "  v1 locale: FIXED"
        else
            echo "  v1 locale: NOT fixed"
        fi

        # Check v2 block
        END2=$((IMPL2 + 100))
        BLOCK2=$(sed -n "${IMPL2},${END2}p" "$TRANSFORMERS")
        LOCALE2=$(echo "$BLOCK2" | grep -A1 "let locale" | tr '\n' ' ')
        if echo "$LOCALE2" | grep -qE "replace"; then
            TRANS_SCORE=$((TRANS_SCORE + 1))
            echo "  v2 locale: FIXED"
        else
            echo "  v2 locale: NOT fixed"
        fi
    fi
fi

case $TRANS_SCORE in
    2) echo "PASS (both v1 and v2)"
       SCORE=$(awk "BEGIN {print $SCORE + 0.25}") ;;
    1) echo "PARTIAL (only one of v1/v2)"
       SCORE=$(awk "BEGIN {print $SCORE + 0.15}") ;;
    *) echo "FAIL: transformers.rs not fixed" ;;
esac

# ============================================================
# CHECK 3 (weight 0.15): utils.rs get_locale_from_header fixed
# Alternative Rust-side fix location
# ============================================================
echo ""
echo "--- Check 3: utils.rs locale fix (0.15) ---"

if [ -f "$UTILS" ]; then
    UTIL_LOCALE=$(grep -A5 "fn get_locale_from_header" "$UTILS" | tr '\n' ' ')
    if echo "$UTIL_LOCALE" | grep -qE "replace"; then
        echo "PASS"
        SCORE=$(awk "BEGIN {print $SCORE + 0.15}")
    else
        echo "FAIL: get_locale_from_header not fixed"
    fi
else
    echo "FAIL: utils.rs not found"
fi

# ============================================================
# CHECK 4 (weight 0.15): locale.js keys use hyphens
# ============================================================
echo ""
echo "--- Check 4: locale.js keys use hyphens (0.15) ---"

if [ -f "$LOCALE_JS" ]; then
    UNDERSCORE_KEYS=$(grep -cE "^\s+(en_gb|fr_be|zh_hant)\s*:" "$LOCALE_JS" || true)
    HYPHEN_KEYS=$(grep -cE '^\s+"?(en-gb|fr-be|zh-hant)"?\s*:' "$LOCALE_JS" || true)
    echo "  Underscore keys remaining: $UNDERSCORE_KEYS, Hyphen keys: $HYPHEN_KEYS"

    if [ "$HYPHEN_KEYS" -ge 2 ] && [ "$UNDERSCORE_KEYS" -eq 0 ]; then
        echo "PASS"
        SCORE=$(awk "BEGIN {print $SCORE + 0.15}")
    elif [ "$HYPHEN_KEYS" -ge 1 ]; then
        echo "PARTIAL"
        SCORE=$(awk "BEGIN {print $SCORE + 0.08}")
    else
        echo "FAIL"
    fi
else
    echo "FAIL: locale.js not found"
fi

# ============================================================
# CHECK 5 (weight 0.15): Additional locale-related fixes
# context.rs, middleware.rs, yml renames, getLanguage() fix
# ============================================================
echo ""
echo "--- Check 5: Additional locale fixes (0.15) ---"

ADDITIONAL=0

# context.rs: locale strings changed from underscore to hyphen
if echo "$CHANGED_FILES" | grep -q "context.rs"; then
    if [ -f "$CONTEXT_RS" ]; then
        if grep -qE '"en-gb"|"fr-be"|"zh-hant"' "$CONTEXT_RS"; then
            ADDITIONAL=$((ADDITIONAL + 1))
            echo "  context.rs: locale strings fixed"
        fi
    fi
fi

# middleware.rs: locale normalization added
if echo "$CHANGED_FILES" | grep -q "middleware.rs"; then
    if [ -f "$MIDDLEWARE" ]; then
        if grep -qE 'replace.*_.*-' "$MIDDLEWARE"; then
            ADDITIONAL=$((ADDITIONAL + 1))
            echo "  middleware.rs: locale normalization added"
        fi
    fi
fi

# yml locale files renamed (check if diff shows rename of en_gb/fr_be files)
if echo "$FULL_DIFF" | grep -qE "rename.*en.gb|rename.*fr.be|en-gb\.yml|fr-be\.yml"; then
    ADDITIONAL=$((ADDITIONAL + 1))
    echo "  locale yml files: renamed"
fi

# getLanguage() function in locale.js updated
if [ -f "$LOCALE_JS" ]; then
    if grep -qE "case 'zh-hant'" "$LOCALE_JS"; then
        ADDITIONAL=$((ADDITIONAL + 1))
        echo "  locale.js getLanguage: zh-hant case added"
    fi
fi

echo "  Additional fixes found: $ADDITIONAL"
if [ "$ADDITIONAL" -ge 3 ]; then
    echo "PASS (full)"
    SCORE=$(awk "BEGIN {print $SCORE + 0.15}")
elif [ "$ADDITIONAL" -ge 2 ]; then
    echo "PASS (good)"
    SCORE=$(awk "BEGIN {print $SCORE + 0.10}")
elif [ "$ADDITIONAL" -ge 1 ]; then
    echo "PARTIAL"
    SCORE=$(awk "BEGIN {print $SCORE + 0.05}")
else
    echo "FAIL: No additional locale fixes"
fi

# ============================================================
# CHECK 6 (weight 0.20): Breadth of fix - total distinct fix locations
# A more capable agent should find and fix more locations
# ============================================================
echo ""
echo "--- Check 6: Breadth of fix (0.20) ---"

BREADTH=0
# Count distinct fix categories
[ "$TRANS_SCORE" -ge 1 ] && BREADTH=$((BREADTH + 1))
echo "$FULL_DIFF" | grep -q "utils.rs" && BREADTH=$((BREADTH + 1))
echo "$FULL_DIFF" | grep -q "locale.js" && BREADTH=$((BREADTH + 1))
echo "$FULL_DIFF" | grep -q "context.rs" && BREADTH=$((BREADTH + 1))
echo "$FULL_DIFF" | grep -q "middleware.rs" && BREADTH=$((BREADTH + 1))
echo "$FULL_DIFF" | grep -qE "en-gb\.yml|fr-be\.yml|rename.*en.gb|rename.*fr.be" && BREADTH=$((BREADTH + 1))

echo "  Distinct fix locations: $BREADTH"

if [ "$BREADTH" -ge 4 ]; then
    echo "PASS (excellent breadth)"
    SCORE=$(awk "BEGIN {print $SCORE + 0.20}")
elif [ "$BREADTH" -ge 3 ]; then
    echo "PASS (good breadth)"
    SCORE=$(awk "BEGIN {print $SCORE + 0.15}")
elif [ "$BREADTH" -ge 2 ]; then
    echo "PARTIAL (moderate breadth)"
    SCORE=$(awk "BEGIN {print $SCORE + 0.08}")
else
    echo "FAIL: Only $BREADTH location(s) fixed"
fi

# ============================================================
# Final score
# ============================================================
echo ""
echo "=== Final Score: $SCORE ==="

FINAL=$(awk "BEGIN {s=$SCORE; if (s > 1.0) s = 1.0; printf \"%.2f\", s}")
echo "$FINAL" > "$REWARD_FILE"
echo "Reward: $FINAL"
