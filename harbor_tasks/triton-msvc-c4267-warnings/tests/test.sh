#!/usr/bin/env bash
# Verifier for triton-msvc-c4267-warnings
# Checks that WarpSpecializeUtility.cpp has both size_t→unsigned narrowing fixes.
#
# Scoring (total 1.00):
#   0.05  Bronze:   file exists, non-empty, >400 lines
#   0.05  Bronze:   key function lowerKernelBarriers still present
#   0.25  F2P:      Fix 1 behavioral — lambda capture compiles+runs clean with GCC -Wconversion
#   0.15  Bronze+:  Fix 1 structural — explicit cast OR bug pattern removed + context
#   0.25  F2P:      Fix 2 behavioral — getResult arg compiles+runs clean with GCC -Wconversion
#   0.15  Bronze+:  Fix 2 structural — explicit cast OR bug pattern removed + context
#   0.10  F2P:      Both — combined behavioral confirmation (both narrowings resolved)

set +e

REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"

# --------------------------------------------------------------------------
# Create a sanitized copy: strip line comments, block comments, and string
# literals to prevent injection via comments or strings.
# --------------------------------------------------------------------------
STRIPPED=$(mktemp)
if [ -f "$FILE" ]; then
    python3 << PYEOF > "$STRIPPED"
import re
try:
    with open("$FILE") as f:
        code = f.read()
    # Remove block comments /* ... */
    code = re.sub(r'/\*.*?\*/', '', code, flags=re.DOTALL)
    # Remove line comments //...
    code = re.sub(r'//[^\n]*', '', code)
    # Remove string literals (preserving structure)
    code = re.sub(r'"[^"\\\\]*(?:\\\\.[^"\\\\]*)*"', '""', code)
    print(code)
except:
    pass
PYEOF
else
    touch "$STRIPPED"
fi

# ==========================================================================
# Bronze 1 (0.05): File exists, non-empty, >400 lines
# The file is ~570+ lines at the base commit. A fix adds/changes ~2 lines.
# Threshold 400 blocks stub files and wholesale rewrites.
# ==========================================================================
if [ -f "$FILE" ] && [ -s "$FILE" ]; then
    LINE_COUNT=$(wc -l < "$FILE")
    if [ "$LINE_COUNT" -gt 400 ]; then
        REWARD=$(python3 -c "print(round($REWARD + 0.05, 2))")
    fi
fi

# ==========================================================================
# Bronze 2 (0.05): Key function lowerKernelBarriers still present
# Guards against wholesale file deletion or replacement.
# ==========================================================================
if grep -q 'lowerKernelBarriers' "$STRIPPED" 2>/dev/null; then
    REWARD=$(python3 -c "print(round($REWARD + 0.05, 2))")
fi

# ==========================================================================
# F2P Behavioral Fix 1 (0.25): Lambda capture narrowing resolved
#
# The bug: partition->walk([&, idx = idx]...) where idx is size_t from
# llvm::enumerate. The captured idx is size_t, but passed to functions
# expecting std::optional<unsigned>, triggering MSVC C4267.
#
# Strategy: extract the idx initializer expression from the lambda capture,
# compile AND run a minimal C++ program that assigns it to
# std::optional<unsigned> with GCC -Wconversion -Werror. The runtime check
# verifies value preservation (rejects literal constants like 0u).
# ==========================================================================
FIX1_BEH=0
IDX_INIT=$(python3 << PYEOF
import re
try:
    with open("$STRIPPED") as f:
        content = f.read()
except:
    print("FAIL")
    exit(0)

# Find partition->walk([...idx...]) — the specific walk with idx in capture
for m in re.finditer(r'partition->walk\s*\(\s*\[([^\]]*)\]', content, re.DOTALL):
    capture = m.group(1)
    if 'idx' not in capture:
        continue
    # Extract: idx = EXPRESSION (may include static_cast with nested parens)
    idx_m = re.search(r'\bidx\s*=\s*(.+)', capture)
    if idx_m:
        expr = idx_m.group(1).strip()
        # Walk the expression, balancing parens/angles, stop at comma at depth 0
        depth = 0
        end = len(expr)
        for i, c in enumerate(expr):
            if c == '(' or c == '<':
                depth += 1
            elif c == ')' or c == '>':
                depth -= 1
            elif c == ',' and depth == 0:
                end = i
                break
        expr = expr[:end].strip()
        if expr:
            print(expr)
            exit(0)
print("FAIL")
PYEOF
)

if [ "$IDX_INIT" != "FAIL" ] && [ -n "$IDX_INIT" ]; then
    cat > /tmp/test_fix1.cpp << CPPEOF
#include <cstddef>
#include <optional>
int main() {
    size_t idx = 42;
    auto captured = ($IDX_INIT);
    // Type check: must assign to optional<unsigned> without narrowing
    std::optional<unsigned int> opt = captured;
    // Value check: reject literal constants (e.g. 0u) that don't reference idx
    return (opt.value() == 42u) ? 0 : 1;
}
CPPEOF
    g++ -std=c++17 -Wconversion -Werror /tmp/test_fix1.cpp -o /tmp/test_fix1 2>/dev/null
    if [ $? -eq 0 ]; then
        /tmp/test_fix1 2>/dev/null
        if [ $? -eq 0 ]; then
            FIX1_BEH=1
            REWARD=$(python3 -c "print(round($REWARD + 0.25, 2))")
        fi
    fi
fi

# ==========================================================================
# Bronze+ Structural Fix 1 (0.15): Explicit cast OR bug pattern removed
#
# Three detection paths:
#   A: explicit cast in walk lambda capture (static_cast / C-style / uint32_t)
#   B: explicit cast of idx anywhere + walk lambda still exists
#   C: bug pattern [&, idx = idx] gone + partition->walk with idx survives
# ==========================================================================
FIX1_STR=0

# Path A: cast in the lambda capture list itself
if grep -qP 'walk\s*\(\s*\[.*idx\s*=\s*(static_cast\s*<\s*(unsigned(\s+int)?|uint32_t)\s*>|\(unsigned(\s+int)?\)|\(uint32_t\))' "$STRIPPED" 2>/dev/null; then
    FIX1_STR=1
fi

# Path B: explicit cast of idx anywhere + walk lambda still present
if [ $FIX1_STR -eq 0 ]; then
    if grep -qP '(static_cast\s*<\s*(unsigned(\s+int)?|uint32_t)\s*>\s*\(\s*idx\s*\)|\((unsigned(\s+int)?|uint32_t)\)\s*\(?\s*idx\s*\)?)' "$STRIPPED" 2>/dev/null; then
        if grep -qP 'partition->walk\s*\(\s*\[' "$STRIPPED" 2>/dev/null; then
            FIX1_STR=1
        fi
    fi
fi

# Path C: original bug pattern gone + walk lambda with idx still present
if [ $FIX1_STR -eq 0 ]; then
    if ! grep -qP '\[\s*&\s*,\s*idx\s*=\s*idx\s*\]' "$STRIPPED" 2>/dev/null; then
        if grep -qP 'partition->walk\s*\(\s*\[.*idx' "$STRIPPED" 2>/dev/null; then
            FIX1_STR=1
        fi
    fi
fi

if [ $FIX1_STR -eq 1 ]; then
    REWARD=$(python3 -c "print(round($REWARD + 0.15, 2))")
fi

# ==========================================================================
# F2P Behavioral Fix 2 (0.25): getResult narrowing resolved
#
# The bug: op->getResult(i) where i is size_t from llvm::enumerate.
# getResult(unsigned idx) expects unsigned, causing C4267 on MSVC.
#
# Strategy: extract the arg from op->getResult(ARG) near replaceAllUsesWith
# using balanced-paren parsing (handles nested parens in static_cast),
# compile AND run a test that passes it to a function taking unsigned.
# ==========================================================================
FIX2_BEH=0
GETRESULT_ARG=$(python3 << PYEOF
import re
try:
    with open("$STRIPPED") as f:
        content = f.read()
except:
    print("FAIL")
    exit(0)

lines = content.split('\n')
for line_idx, line in enumerate(lines):
    if 'op->getResult' not in line:
        continue
    # The bug site is near replaceAllUsesWith — check a ±3 line window
    window = '\n'.join(lines[max(0, line_idx-2):line_idx+4])
    if 'replaceAllUsesWith' not in window:
        continue
    # Find op->getResult( and extract the argument with balanced parens
    pos = line.find('op->getResult')
    if pos == -1:
        continue
    rest = line[pos + len('op->getResult'):].lstrip()
    if not rest.startswith('('):
        continue
    # Balance parentheses to find the full argument
    depth = 0
    start = None
    for i, c in enumerate(rest):
        if c == '(':
            if depth == 0:
                start = i + 1
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                arg = rest[start:i].strip()
                if arg:
                    print(arg)
                    exit(0)
                break
print("FAIL")
PYEOF
)

if [ "$GETRESULT_ARG" != "FAIL" ] && [ -n "$GETRESULT_ARG" ]; then
    cat > /tmp/test_fix2.cpp << CPPEOF
#include <cstddef>
int main() {
    size_t i = 42;
    // Type check: must assign to unsigned without narrowing
    unsigned result = ($GETRESULT_ARG);
    // Value check: reject literal constants that don't reference i
    return (result == 42u) ? 0 : 1;
}
CPPEOF
    g++ -std=c++17 -Wconversion -Werror /tmp/test_fix2.cpp -o /tmp/test_fix2 2>/dev/null
    if [ $? -eq 0 ]; then
        /tmp/test_fix2 2>/dev/null
        if [ $? -eq 0 ]; then
            FIX2_BEH=1
            REWARD=$(python3 -c "print(round($REWARD + 0.25, 2))")
        fi
    fi
fi

# ==========================================================================
# Bronze+ Structural Fix 2 (0.15): Explicit cast OR bug pattern removed
#
# Two detection paths:
#   A: explicit cast in op->getResult() call
#   B: bare getResult(i) gone + enumerate loop + replaceAllUsesWith context
# ==========================================================================
FIX2_STR=0

# Path A: static_cast in getResult call
if grep -qP 'op->getResult\s*\(\s*static_cast\s*<\s*(unsigned(\s+int)?|uint32_t)' "$STRIPPED" 2>/dev/null; then
    FIX2_STR=1
fi

# Path A2: C-style cast in getResult call
if [ $FIX2_STR -eq 0 ]; then
    if grep -qP 'op->getResult\s*\(\s*\(unsigned' "$STRIPPED" 2>/dev/null; then
        FIX2_STR=1
    fi
fi

# Path B: bare getResult(i) gone + enumerate loop + replaceAllUsesWith in context
if [ $FIX2_STR -eq 0 ]; then
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
        if 'op->getResult' in window:
            has_replace_context = True
            break

print(1 if has_enumerate and has_replace_context else 0)
PYEOF
        )
        if [ "$FALLBACK2" = "1" ]; then
            FIX2_STR=1
        fi
    fi
fi

if [ $FIX2_STR -eq 1 ]; then
    REWARD=$(python3 -c "print(round($REWARD + 0.15, 2))")
fi

# ==========================================================================
# F2P Both (0.10): Combined behavioral confirmation
# Awards a bonus when BOTH narrowing sites are resolved. If behavioral
# extraction failed for either, falls back to requiring both structural.
# ==========================================================================
if [ $FIX1_BEH -eq 1 ] && [ $FIX2_BEH -eq 1 ]; then
    REWARD=$(python3 -c "print(round($REWARD + 0.10, 2))")
elif [ "$IDX_INIT" = "FAIL" ] || [ "$GETRESULT_ARG" = "FAIL" ]; then
    # Extraction failed for at least one — accept both structural as fallback
    if [ $FIX1_STR -eq 1 ] && [ $FIX2_STR -eq 1 ]; then
        REWARD=$(python3 -c "print(round($REWARD + 0.10, 2))")
    fi
fi

# --------------------------------------------------------------------------
# Clean up
# --------------------------------------------------------------------------
rm -f "$STRIPPED" /tmp/test_fix1.cpp /tmp/test_fix2.cpp /tmp/test_fix1 /tmp/test_fix2

# --------------------------------------------------------------------------
# Cap and write result
# --------------------------------------------------------------------------
REWARD=$(python3 -c "print(min(1.0, $REWARD))")
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo "Score: $REWARD"
