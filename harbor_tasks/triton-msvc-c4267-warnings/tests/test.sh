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
# All checks use STRIPPED (comment-free) to block comment injection.
# --------------------------------------------------------------------------
FIX1=0

# Positive check A: explicit cast of idx in the walk lambda capture
if grep -qP 'walk\s*\(\s*\[.*idx\s*=\s*(static_cast\s*<\s*unsigned|static_cast\s*<\s*unsigned\s+int|\(unsigned\)|\(unsigned\s+int\))' "$STRIPPED" 2>/dev/null; then
    FIX1=1
fi

# Positive check B: explicit cast of idx at the call sites inside the lambda
# (e.g., lowerBarrier(op, numWarps, static_cast<unsigned>(idx), ...))
# The original file has no static_cast<unsigned>(idx) — finding one means the agent added a fix.
if [ $FIX1 -eq 0 ]; then
    if grep -qP '(static_cast\s*<\s*unsigned(\s+int)?\s*>\s*\(\s*idx\s*\)|\(unsigned(\s+int)?\)\s*\(?\s*idx\s*\)?)' "$STRIPPED" 2>/dev/null; then
        # Also require the walk lambda still exists (code wasn't just deleted)
        if grep -qP 'partition->walk\s*\(\s*\[' "$STRIPPED" 2>/dev/null; then
            FIX1=1
        fi
    fi
fi

# Fallback: bug pattern gone AND specific partition->walk with idx in capture survives
# Note: there's a second partition->walk at line 383 WITHOUT idx. We require idx
# to appear on the same line as partition->walk to target the correct lambda.
if [ $FIX1 -eq 0 ]; then
    if ! grep -qP '\[\s*&\s*,\s*idx\s*=\s*idx\s*\]' "$STRIPPED" 2>/dev/null; then
        # Bug pattern is gone; require partition->walk with idx in its capture/args
        if grep -qP 'partition->walk\s*\(\s*\[.*idx' "$STRIPPED" 2>/dev/null; then
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

# Fallback: bare `getResult(i)` is gone BUT the replaceAllUsesWith logic survives.
# The original line is: op->getResult(i).replaceAllUsesWith(cast.getResult(0));
# Simple deletion of this line breaks the code AND removes replaceAllUsesWith from this context.
# We require: (a) getResult(i) gone, (b) enumerate loop exists,
# (c) getResult + replaceAllUsesWith appear together (same line or within 2 lines)
if [ $FIX2 -eq 0 ]; then
    if ! grep -qP '\bgetResult\s*\(\s*i\s*\)' "$STRIPPED" 2>/dev/null; then
        FALLBACK2=$(python3 << PYEOF
import re

try:
    with open("$STRIPPED") as f:
        content = f.read()
except:
    print(0)
    exit(0)

lines = content.split('\n')

has_enumerate = any('enumerate(newOp->getResults' in l for l in lines)

has_replace_context = False
for i, line in enumerate(lines):
    if 'replaceAllUsesWith' in line:
        window = '\n'.join(lines[max(0, i-2):i+3])
        # Require op->getResult (not just cast.getResult or bare getResult)
        # This distinguishes the bug site (line ~246) from line ~226
        if 'op->getResult' in window:
            has_replace_context = True
            break

print(1 if has_enumerate and has_replace_context else 0)
PYEOF
        )
        if [ "$FALLBACK2" = "1" ]; then
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
