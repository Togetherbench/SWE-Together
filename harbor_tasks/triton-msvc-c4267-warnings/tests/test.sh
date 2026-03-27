#!/usr/bin/env bash
# Verifier for triton-fix-ses_39
# Checks that WarpSpecializeUtility.cpp has the two size_t->unsigned narrowing fixes.
#
# Scoring:
#   0.10  Bronze: file exists and is non-empty
#   0.10  Bronze: key function lowerKernelBarriers still present (no gross regression)
#   0.40  Gold:   Fix 1 — lambda capture no longer passes bare size_t idx as unsigned
#   0.40  Gold:   Fix 2 — op->getResult() no longer called with bare size_t index
#
# Total: 1.00

set +e

REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"

# --------------------------------------------------------------------------
# Create a comment-stripped copy for Gold checks.
# Strips single-line // comments so patterns injected in comments don't score.
# --------------------------------------------------------------------------
STRIPPED=$(mktemp)
if [ -f "$FILE" ]; then
    sed 's|//.*||' "$FILE" > "$STRIPPED"
else
    touch "$STRIPPED"
fi

# --------------------------------------------------------------------------
# Bronze 1 (0.10): File exists, is non-empty, and is a real C++ file (>100 lines)
# Guards against stub/comment injection attacks.
# --------------------------------------------------------------------------
if [ -f "$FILE" ] && [ -s "$FILE" ]; then
    LINE_COUNT=$(wc -l < "$FILE")
    if [ "$LINE_COUNT" -gt 100 ]; then
        REWARD=$(python3 -c "print(round($REWARD + 0.10, 2))")
    fi
fi

# --------------------------------------------------------------------------
# Bronze 2 (0.10): Key function still present — guards against wholesale deletion
# --------------------------------------------------------------------------
if grep -q 'lowerKernelBarriers' "$STRIPPED" 2>/dev/null; then
    REWARD=$(python3 -c "print(round($REWARD + 0.10, 2))")
fi

# --------------------------------------------------------------------------
# Gold 1 (0.40): Fix 1 — lambda capture narrowing resolved
#
# The bug: partition->walk([&, idx = idx]  where idx is size_t from enumerate,
# implicitly converted to std::optional<unsigned> inside the lambda.
#
# A valid fix must ensure the captured idx is not a bare size_t. Accepted forms:
#   static_cast<unsigned>(idx)     -- canonical C++ cast
#   static_cast<unsigned int>(idx) -- same, verbose
#   (unsigned)(idx) / (unsigned int)(idx) -- C-style cast
#   truncated/narrowed some other way that avoids C4267
#
# We check two things:
#   (a) The original bug pattern `idx = idx]` is gone (or modified)
#   (b) Some explicit narrowing cast for idx appears in the walk lambda context
#
# All checks use STRIPPED (comment-free) to block comment injection.
# --------------------------------------------------------------------------
FIX1=0

# Positive check: any explicit cast of idx near the walk lambda
if grep -qP 'walk\s*\(\s*\[.*idx\s*=\s*(static_cast\s*<\s*unsigned|static_cast\s*<\s*unsigned\s+int|\(unsigned\)|\(unsigned\s+int\))' "$STRIPPED" 2>/dev/null; then
    FIX1=1
fi

# Also accept: the loop variable itself is re-typed so no cast needed
# e.g. for (auto [idx, partition] : ...) changed to unsigned idx explicitly
if [ $FIX1 -eq 0 ]; then
    # Check that the bare `idx = idx]` pattern (bug) no longer exists
    # AND the walk lambda still has a capture list (code wasn't just deleted)
    if ! grep -qP '\[\s*&\s*,\s*idx\s*=\s*idx\s*\]' "$STRIPPED" 2>/dev/null; then
        # Bug pattern is gone; require walk lambda with capture list still present
        if grep -qP '->walk\s*\(\s*\[' "$STRIPPED" 2>/dev/null; then
            FIX1=1
        fi
    fi
fi

if [ $FIX1 -eq 1 ]; then
    REWARD=$(python3 -c "print(round($REWARD + 0.40, 2))")
fi

# --------------------------------------------------------------------------
# Gold 2 (0.40): Fix 2 — getResult narrowing resolved
#
# The bug: op->getResult(i) where i is size_t from llvm::enumerate(newOp->getResults(), ...)
# getResult(unsigned idx) expects unsigned, causing C4267 on MSVC.
#
# Valid fixes:
#   op->getResult(static_cast<unsigned>(i))
#   op->getResult(static_cast<unsigned int>(i))
#   op->getResult((unsigned)(i))
#   Restructuring the loop to use a different counter type
#
# All checks use STRIPPED (comment-free) to block comment injection.
# --------------------------------------------------------------------------
FIX2=0

# Positive: explicit cast in getResult call
if grep -qP 'getResult\s*\(\s*(static_cast\s*<\s*unsigned(\s+int)?\s*>|\(unsigned(\s+int)?\))\s*\(' "$STRIPPED" 2>/dev/null; then
    FIX2=1
fi

# Also accept: bare `getResult(i)` is gone and getResult still called with an argument
if [ $FIX2 -eq 0 ]; then
    if ! grep -qP '\bgetResult\s*\(\s*i\s*\)' "$STRIPPED" 2>/dev/null; then
        # Require getResult called with parenthesized argument (not just in a comment)
        if grep -qP 'getResult\s*\([^)]+\)' "$STRIPPED" 2>/dev/null; then
            FIX2=1
        fi
    fi
fi

if [ $FIX2 -eq 1 ]; then
    REWARD=$(python3 -c "print(round($REWARD + 0.40, 2))")
fi

# Clean up
rm -f "$STRIPPED"

# --------------------------------------------------------------------------
# Cap and write result
# --------------------------------------------------------------------------
REWARD=$(python3 -c "print(min(1.0, $REWARD))")

mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo "Score: $REWARD"
