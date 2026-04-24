#!/bin/bash
# Verifier for triton-msvc-c4267-warnings
#
# 18 tests (0.96 behavioral / 0.04 structural / 0.025 P2P), total 1.05 (capped 1.0)
# Nop score: 0.05
# NOTE: Fix 1 behavioral tests use cast expression resolution to handle both
# capture-site and use-site fix approaches (including intermediate variables).
#
# Scoring breakdown:
#   Structural sanity / P2P (5 x 0.005 = 0.025):
#     T1  0.005  File exists, >400 lines
#     T2  0.005  lowerKernelBarriers present
#     T3  0.005  partition->walk lambda present
#     T4  0.005  lowerCallOp present
#     T5  0.005  enumerate(newOp->getResults context
#
#   Fix 1 Behavioral — any approach (5 tests = 0.48):
#     T6  0.14   compile+value idx=42
#     T7  0.085  value idx=7
#     T8  0.085  value idx=1000
#     T9  0.085  value idx=0
#     T10 0.085  value idx=12345
#
#   Fix 1 Structural (1 x 0.02):
#     T11 0.02  bug pattern [&, idx=idx] gone OR explicit cast present
#
#   Fix 2 Behavioral (5 tests = 0.48):
#     T12 0.14   compile+value i=42
#     T13 0.085  value i=99
#     T14 0.085  value i=0
#     T15 0.085  value i=100000
#     T16 0.085  value i=7
#
#   Fix 2 Structural (1 x 0.02):
#     T17 0.02  bare getResult(i) gone + enumerate/replaceAllUsesWith context
#
#   Pass-to-pass (1 x 0.025):
#     T18 0.025  brace/paren balance + key functions + #includes + namespaces
#                + enumerate preserved + line count + angle bracket balance
#
# NOTE: add_reward uses round(..., 4) to avoid cumulative rounding errors
# from 0.005 weights.
#
# NOTE: Triton's Python tests require building libtriton.so (LLVM/MLIR C++
# backend, ~30min build), and `import triton` fails without it. MLIR lit
# tests require `triton-opt` binary. No TRITON_TEST_SKIP_GPU mechanism exists.
# The C++ unit tests under unittest/ require LLVM headers + linking. None of
# these are feasible in the container. P2P uses structural C++ checks instead.
#
# Key fix over previous test: old behavioral test used std::optional<unsigned>
# which GCC doesn't warn about through template instantiation. New test uses
# direct `unsigned x = (EXPR)` assignment which correctly triggers -Wconversion.
#
# Any-approach detection: Fix 1 tests extract expressions from three locations
# (lambda capture, lowerBarrier 3rd arg, lowerCallOp 3rd arg) and award credit
# if ANY compiles clean. This correctly handles both capture-site and use-site
# cast approaches.

set +e

REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"
STRIPPED="/tmp/stripped_wsu.txt"

# ==========================================================================
# Phase 1: Strip comments, block comments, and string literals
# ==========================================================================
if [ -f "$FILE" ]; then
    python3 << 'PYEOF' > "$STRIPPED"
import re
try:
    with open("/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp") as f:
        code = f.read()
    code = re.sub(r'/\*.*?\*/', '', code, flags=re.DOTALL)
    code = re.sub(r'//[^\n]*', '', code)
    code = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', code)
    print(code)
except Exception:
    pass
PYEOF
else
    touch "$STRIPPED"
fi

# ==========================================================================
# Phase 2: Extract expressions from the stripped source
#
# Outputs to temp files:
#   /tmp/fix1_capture_expr.txt   — capture initializer (single expr or FAIL)
#   /tmp/fix1_barrier_exprs.txt  — lowerBarrier 3rd args (one per line)
#   /tmp/fix1_callop_exprs.txt   — lowerCallOp 3rd args (one per line)
#   /tmp/fix2_getresult_exprs.txt — op->getResult args near replaceAllUsesWith
# ==========================================================================
python3 << 'PYEOF'
import re

try:
    with open("/tmp/stripped_wsu.txt") as f:
        content = f.read()
except Exception:
    open("/tmp/fix1_capture_expr.txt", "w").write("FAIL\n")
    open("/tmp/fix1_barrier_exprs.txt", "w").write("")
    open("/tmp/fix1_callop_exprs.txt", "w").write("")
    open("/tmp/fix1_cast_exprs.txt", "w").write("")
    open("/tmp/fix2_getresult_exprs.txt", "w").write("")
    exit(0)

def balanced_extract(text, open_pos):
    """Extract content between balanced parens starting at open_pos (which must be '(')."""
    if open_pos >= len(text) or text[open_pos] != '(':
        return None
    depth = 0
    for i in range(open_pos, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[open_pos + 1:i]
    return None

def extract_nth_arg(args_str, n):
    """Extract nth (0-based) comma-separated arg, respecting balanced parens/angles."""
    depth = 0
    current = 0
    start = 0
    for i, c in enumerate(args_str):
        if c in '(<[':
            depth += 1
        elif c in ')>]':
            depth -= 1
        elif c == ',' and depth == 0:
            if current == n:
                return args_str[start:i].strip()
            current += 1
            start = i + 1
    if current == n:
        return args_str[start:].strip()
    return None

# --- 1. Extract capture_expr from partition->walk([..., idx = EXPR]) ---
capture_expr = "FAIL"
walk_match = re.search(r'partition->walk\s*\(\s*\[([^\]]*)\]', content, re.DOTALL)
if walk_match:
    capture_list = walk_match.group(1)
    if 'idx' in capture_list:
        idx_m = re.search(r'\bidx\s*=\s*(.+)', capture_list)
        if idx_m:
            expr = idx_m.group(1).strip()
            # Walk expression, balancing parens/angles, stop at comma at depth 0
            depth = 0
            end = len(expr)
            for i, c in enumerate(expr):
                if c in '(<':
                    depth += 1
                elif c in ')>':
                    depth -= 1
                elif c == ',' and depth == 0:
                    end = i
                    break
            expr = expr[:end].strip()
            if expr:
                capture_expr = expr

open("/tmp/fix1_capture_expr.txt", "w").write(capture_expr + "\n")

# --- 2. Find the walk lambda body, then extract lowerBarrier/lowerCallOp args ---
barrier_exprs = []
callop_exprs = []

# Locate lambda body: partition->walk([...](...)  {  ... })
walk_full = re.search(r'partition->walk\s*\(\s*\[[^\]]*\]\s*\([^)]*\)\s*\{', content, re.DOTALL)
if walk_full:
    body_start = walk_full.end() - 1  # position of '{'
    depth = 0
    body_end = len(content)
    for i in range(body_start, len(content)):
        if content[i] == '{':
            depth += 1
        elif content[i] == '}':
            depth -= 1
            if depth == 0:
                body_end = i + 1
                break
    lambda_body = content[body_start:body_end]

    # Extract 3rd arg from lowerBarrier calls inside lambda
    for m in re.finditer(r'lowerBarrier\s*\(', lambda_body):
        paren_pos = lambda_body.find('(', m.start() + len('lowerBarrier'))
        if paren_pos == -1:
            continue
        args = balanced_extract(lambda_body, paren_pos)
        if args:
            arg2 = extract_nth_arg(args, 2)
            if arg2:
                barrier_exprs.append(arg2)

    # Extract 3rd arg from lowerCallOp calls inside lambda
    for m in re.finditer(r'lowerCallOp\s*\(', lambda_body):
        paren_pos = lambda_body.find('(', m.start() + len('lowerCallOp'))
        if paren_pos == -1:
            continue
        args = balanced_extract(lambda_body, paren_pos)
        if args:
            arg2 = extract_nth_arg(args, 2)
            if arg2:
                callop_exprs.append(arg2)

open("/tmp/fix1_barrier_exprs.txt", "w").write("\n".join(barrier_exprs) + ("\n" if barrier_exprs else ""))
open("/tmp/fix1_callop_exprs.txt", "w").write("\n".join(callop_exprs) + ("\n" if callop_exprs else ""))

# --- 2b. Resolve indirect variable references and find direct cast expressions ---
# Handles the use-site fix pattern where agent introduces a local variable:
#   unsigned idxU = static_cast<unsigned>(idx);
#   lowerBarrier(op, numWarps, idxU, barrierHelper);
# The extracted barrier arg is "idxU" which is undefined in the synthetic test.
# We resolve it back to its RHS expression.
cast_exprs = []

if walk_full:
    # Direct cast patterns of idx in the lambda body
    for pat in [
        r'static_cast\s*<\s*(?:unsigned(?:\s+int)?|uint32_t)\s*>\s*\(\s*idx\s*\)',
        r'\(\s*(?:unsigned(?:\s+int)?|uint32_t)\s*\)\s*\(?\s*idx\s*\)?',
    ]:
        for m in re.finditer(pat, lambda_body):
            cast_exprs.append(m.group(0).strip())

    # Variable resolution: for simple identifiers in barrier/callop args,
    # look for their definition in lambda body
    all_args = barrier_exprs + callop_exprs
    for arg in all_args:
        arg_stripped = arg.strip()
        if re.match(r'^[a-zA-Z_]\w*$', arg_stripped) and arg_stripped != 'idx':
            var_def = re.search(
                rf'(?:unsigned(?:\s+int)?|uint32_t|auto)\s+{re.escape(arg_stripped)}\s*=\s*([^;]+)',
                lambda_body
            )
            if var_def:
                rhs = var_def.group(1).strip()
                if rhs:
                    cast_exprs.append(rhs)

open("/tmp/fix1_cast_exprs.txt", "w").write(
    "\n".join(cast_exprs) + ("\n" if cast_exprs else "")
)

# --- 3. Extract getResult arg near replaceAllUsesWith ---
getresult_exprs = []
lines = content.split('\n')
for li, line in enumerate(lines):
    if 'op->getResult' not in line:
        continue
    window = '\n'.join(lines[max(0, li - 2):li + 4])
    if 'replaceAllUsesWith' not in window:
        continue
    pos = line.find('op->getResult')
    rest = line[pos + len('op->getResult'):].lstrip()
    if not rest.startswith('('):
        continue
    depth = 0
    start = None
    for j, c in enumerate(rest):
        if c == '(':
            if depth == 0:
                start = j + 1
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                arg = rest[start:j].strip()
                if arg:
                    getresult_exprs.append(arg)
                break
    if getresult_exprs:
        break

open("/tmp/fix2_getresult_exprs.txt", "w").write("\n".join(getresult_exprs) + ("\n" if getresult_exprs else ""))
PYEOF

# ==========================================================================
# Phase 3: Load extracted expressions
# ==========================================================================
CAPTURE_EXPR=$(head -1 /tmp/fix1_capture_expr.txt 2>/dev/null)
mapfile -t BARRIER_EXPRS < /tmp/fix1_barrier_exprs.txt 2>/dev/null
mapfile -t CALLOP_EXPRS < /tmp/fix1_callop_exprs.txt 2>/dev/null
mapfile -t CAST_EXPRS < /tmp/fix1_cast_exprs.txt 2>/dev/null
mapfile -t GETRESULT_EXPRS < /tmp/fix2_getresult_exprs.txt 2>/dev/null

# ==========================================================================
# Test helpers
# ==========================================================================

# try_compile_run EXPR VALUE VARNAME
#   Writes a C++ program that assigns (EXPR) to unsigned, compiles with
#   -Wconversion -Werror, and checks value preservation at runtime.
#   Returns 0 on success, 1 on failure.
try_compile_run() {
    local expr="$1" value="$2" varname="$3"
    [ -z "$expr" ] && return 1
    [ "$expr" = "FAIL" ] && return 1

    cat > /tmp/test_narrowing.cpp << CPPEOF
#include <cstddef>
int main() {
    size_t $varname = ${value}ULL;
    unsigned result = ($expr);
    return (result == ${value}u) ? 0 : 1;
}
CPPEOF
    g++ -std=c++17 -Wconversion -Werror -o /tmp/test_narrowing /tmp/test_narrowing.cpp 2>/dev/null || return 1
    /tmp/test_narrowing 2>/dev/null || return 1
    return 0
}

# try_fix1 VALUE
#   Try all Fix 1 expression sources. Award if ANY compiles clean.
#   Sources: capture expr, lowerBarrier 3rd arg, lowerCallOp 3rd arg,
#   and resolved cast expressions (handles use-site local variable pattern).
try_fix1() {
    local val="$1"
    try_compile_run "$CAPTURE_EXPR" "$val" idx && return 0
    for e in "${BARRIER_EXPRS[@]}"; do
        try_compile_run "$e" "$val" idx && return 0
    done
    for e in "${CALLOP_EXPRS[@]}"; do
        try_compile_run "$e" "$val" idx && return 0
    done
    for e in "${CAST_EXPRS[@]}"; do
        try_compile_run "$e" "$val" idx && return 0
    done
    return 1
}

# try_fix2 VALUE
#   Try all Fix 2 expression sources. Award if ANY compiles clean.
try_fix2() {
    local val="$1"
    for e in "${GETRESULT_EXPRS[@]}"; do
        try_compile_run "$e" "$val" i && return 0
    done
    return 1
}

add_reward() {
    REWARD=$(python3 -c "print(round($REWARD + $1, 4))")
}

# ==========================================================================
# T1 (0.005): File exists, non-empty, >400 lines  [P2P]
# The base file is ~570 lines. Threshold 400 blocks stubs and rewrites.
# ==========================================================================
if [ -f "$FILE" ] && [ -s "$FILE" ]; then
    LINE_COUNT=$(wc -l < "$FILE")
    if [ "$LINE_COUNT" -gt 400 ]; then
        add_reward 0.005
        echo "T1  PASS  file >400 lines ($LINE_COUNT)"
    else
        echo "T1  FAIL  file only $LINE_COUNT lines"
    fi
else
    echo "T1  FAIL  file missing or empty"
fi

# ==========================================================================
# T2 (0.005): lowerKernelBarriers function present  [P2P]
# ==========================================================================
if grep -q 'lowerKernelBarriers' "$STRIPPED" 2>/dev/null; then
    add_reward 0.005
    echo "T2  PASS  lowerKernelBarriers present"
else
    echo "T2  FAIL  lowerKernelBarriers missing"
fi

# ==========================================================================
# T3 (0.005): partition->walk lambda present  [P2P]
# ==========================================================================
if grep -qP 'partition->walk\s*\(\s*\[' "$STRIPPED" 2>/dev/null; then
    add_reward 0.005
    echo "T3  PASS  partition->walk lambda present"
else
    echo "T3  FAIL  partition->walk lambda missing"
fi

# ==========================================================================
# T4 (0.005): lowerCallOp function present  [P2P]
# ==========================================================================
if grep -q 'lowerCallOp' "$STRIPPED" 2>/dev/null; then
    add_reward 0.005
    echo "T4  PASS  lowerCallOp present"
else
    echo "T4  FAIL  lowerCallOp missing"
fi

# ==========================================================================
# T5 (0.005): enumerate(newOp->getResults context present  [P2P]
# ==========================================================================
if grep -qP 'enumerate\s*\(\s*newOp->getResults' "$STRIPPED" 2>/dev/null; then
    add_reward 0.005
    echo "T5  PASS  enumerate getResults context present"
else
    echo "T5  FAIL  enumerate getResults context missing"
fi

# ==========================================================================
# T6 (0.14): Fix 1 behavioral — any approach, idx=42  [F2P]
# ==========================================================================
if try_fix1 42; then
    add_reward 0.14
    echo "T6  PASS  Fix1 compile+value idx=42"
else
    echo "T6  FAIL  Fix1 idx=42"
fi

# ==========================================================================
# T7 (0.085): Fix 1 behavioral — idx=7  [F2P]
# ==========================================================================
if try_fix1 7; then
    add_reward 0.085
    echo "T7  PASS  Fix1 value idx=7"
else
    echo "T7  FAIL  Fix1 idx=7"
fi

# ==========================================================================
# T8 (0.085): Fix 1 behavioral — idx=1000  [F2P]
# ==========================================================================
if try_fix1 1000; then
    add_reward 0.085
    echo "T8  PASS  Fix1 value idx=1000"
else
    echo "T8  FAIL  Fix1 idx=1000"
fi

# ==========================================================================
# T9 (0.085): Fix 1 behavioral — idx=0  [F2P]
# ==========================================================================
if try_fix1 0; then
    add_reward 0.085
    echo "T9  PASS  Fix1 value idx=0"
else
    echo "T9  FAIL  Fix1 idx=0"
fi

# ==========================================================================
# T10 (0.085): Fix 1 behavioral — idx=12345  [F2P]
# ==========================================================================
if try_fix1 12345; then
    add_reward 0.085
    echo "T10 PASS  Fix1 value idx=12345"
else
    echo "T10 FAIL  Fix1 idx=12345"
fi

# ==========================================================================
# T11 (0.02): Fix 1 structural — bug pattern gone OR explicit cast present  [F2P]
#
# Passes if EITHER:
#   A) The original [&, idx = idx] capture pattern is gone
#   B) An explicit unsigned cast of idx exists anywhere in the file
# ==========================================================================
FIX1_STR=0

# Path A: original bug pattern [&, idx = idx] gone
if ! grep -qP '\[\s*&\s*,\s*idx\s*=\s*idx\s*\]' "$STRIPPED" 2>/dev/null; then
    if grep -qP 'partition->walk\s*\(\s*\[.*idx' "$STRIPPED" 2>/dev/null; then
        FIX1_STR=1
    fi
fi

# Path B: explicit cast of idx to unsigned exists
if [ $FIX1_STR -eq 0 ]; then
    if grep -qP '(static_cast\s*<\s*(unsigned(\s+int)?|uint32_t)\s*>\s*\(\s*idx\s*\)|\(unsigned(\s+int)?\)\s*\(?\s*idx\s*\)?)' "$STRIPPED" 2>/dev/null; then
        FIX1_STR=1
    fi
fi

if [ $FIX1_STR -eq 1 ]; then
    add_reward 0.02
    echo "T11 PASS  Fix1 structural"
else
    echo "T11 FAIL  Fix1 structural"
fi

# ==========================================================================
# T12 (0.14): Fix 2 behavioral — i=42  [F2P]
# ==========================================================================
if try_fix2 42; then
    add_reward 0.14
    echo "T12 PASS  Fix2 compile+value i=42"
else
    echo "T12 FAIL  Fix2 i=42"
fi

# ==========================================================================
# T13 (0.085): Fix 2 behavioral — i=99  [F2P]
# ==========================================================================
if try_fix2 99; then
    add_reward 0.085
    echo "T13 PASS  Fix2 value i=99"
else
    echo "T13 FAIL  Fix2 i=99"
fi

# ==========================================================================
# T14 (0.085): Fix 2 behavioral — i=0  [F2P]
# ==========================================================================
if try_fix2 0; then
    add_reward 0.085
    echo "T14 PASS  Fix2 value i=0"
else
    echo "T14 FAIL  Fix2 i=0"
fi

# ==========================================================================
# T15 (0.085): Fix 2 behavioral — i=100000  [F2P]
# ==========================================================================
if try_fix2 100000; then
    add_reward 0.085
    echo "T15 PASS  Fix2 value i=100000"
else
    echo "T15 FAIL  Fix2 i=100000"
fi

# ==========================================================================
# T16 (0.085): Fix 2 behavioral — i=7  [F2P]
# ==========================================================================
if try_fix2 7; then
    add_reward 0.085
    echo "T16 PASS  Fix2 value i=7"
else
    echo "T16 FAIL  Fix2 i=7"
fi

# ==========================================================================
# T17 (0.02): Fix 2 structural — bare getResult(i) gone + context preserved  [F2P]
#
# Passes if bare getResult(i) is absent AND the enumerate loop +
# replaceAllUsesWith context still exists (blocks simple deletion).
# ==========================================================================
FIX2_STR=0
if ! grep -qP '\bgetResult\s*\(\s*i\s*\)' "$STRIPPED" 2>/dev/null; then
    python3 << 'PYEOF'
import sys
try:
    with open("/tmp/stripped_wsu.txt") as f:
        content = f.read()
    lines = content.split('\n')
    has_enumerate = any('enumerate(newOp->getResults' in l for l in lines)
    has_context = False
    for i, line in enumerate(lines):
        if 'replaceAllUsesWith' in line:
            window = '\n'.join(lines[max(0, i-6):i+7])
            if 'getResult' in window:
                has_context = True
                break
    sys.exit(0 if has_enumerate and has_context else 1)
except Exception:
    sys.exit(1)
PYEOF
    if [ $? -eq 0 ]; then
        FIX2_STR=1
    fi
fi

if [ $FIX2_STR -eq 1 ]; then
    add_reward 0.02
    echo "T17 PASS  Fix2 structural"
else
    echo "T17 FAIL  Fix2 structural"
fi

# ==========================================================================
# T18 (0.025): Pass-to-pass — modified file is structurally sound  [P2P]
#
# Upstream Triton Python/MLIR tests require building libtriton.so and
# triton-opt (LLVM/MLIR C++ backend), which is not feasible in this
# container (no cmake, no LLVM headers, build takes ~30 min).
# Triton has no TRITON_TEST_SKIP_GPU mechanism, and `import triton`
# itself fails without the built C extension.
#
# Instead we verify the agent hasn't broken the file's C++ structure:
#   1. Balanced braces (catches accidental deletions / insertions)
#   2. Balanced parens (catches broken function calls / casts)
#   3. All key function definitions still present
#   4. No stray Python/shell injected (basic sanity)
#   5. All original #include directives preserved
#   6. using namespace declarations intact
#   7. llvm::enumerate still used (fix should add casts, not remove loops)
#   8. Line count within reasonable range of original (~570 lines)
#   9. Angle bracket balance (catches broken template usage from casts)
#
# This passes on the unmodified base file (true P2P) and will catch agents
# that accidentally mangle the file while applying the cast fixes.
# ==========================================================================
if [ -f "$FILE" ]; then
    python3 << 'P2PEOF'
import sys, re
try:
    with open("/tmp/stripped_wsu.txt") as f:
        code = f.read()

    # Also read the raw file for #include checks (comments stripped version
    # won't have // includes)
    with open("/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp") as f:
        raw = f.read()

    # 1. Balanced braces
    depth = 0
    for c in code:
        if c == '{': depth += 1
        elif c == '}': depth -= 1
        if depth < 0:
            print("P2P: unbalanced closing brace", file=sys.stderr)
            sys.exit(1)
    if depth != 0:
        print(f"P2P: brace depth {depth} at EOF", file=sys.stderr)
        sys.exit(1)

    # 2. Balanced parens
    depth = 0
    for c in code:
        if c == '(': depth += 1
        elif c == ')': depth -= 1
        if depth < 0:
            print("P2P: unbalanced closing paren", file=sys.stderr)
            sys.exit(1)
    if depth != 0:
        print(f"P2P: paren depth {depth} at EOF", file=sys.stderr)
        sys.exit(1)

    # 3. Key function definitions still present (at least 3 of 4)
    required = ['lowerKernelBarriers', 'lowerCallOp', 'lowerBarrier', 'partition->walk']
    found = sum(1 for r in required if r in code)
    if found < 3:
        print(f"P2P: only {found}/4 key functions found", file=sys.stderr)
        sys.exit(1)

    # 4. No stray non-C++ content injected
    for marker in ['def ', 'import ', '#!/']:
        if marker in code:
            print(f"P2P: stray non-C++ marker '{marker.strip()}'", file=sys.stderr)
            sys.exit(1)

    # 5. Original #include directives preserved -- the fix only adds casts,
    #    it should never remove includes
    required_includes = [
        'WarpSpecializeUtility.h',
        'TopologicalSortUtils.h',
        'LLVMDialect.h',
        'Builders.h',
        'BuiltinOps.h',
    ]
    for inc in required_includes:
        if inc not in raw:
            print(f"P2P: missing #include for {inc}", file=sys.stderr)
            sys.exit(1)

    # 6. using namespace declarations intact
    for ns in ['mlir', 'mlir::triton']:
        pattern = rf'using\s+namespace\s+{re.escape(ns)}\s*;'
        if not re.search(pattern, code):
            print(f"P2P: 'using namespace {ns}' missing", file=sys.stderr)
            sys.exit(1)

    # 7. llvm::enumerate still used -- the fix should add casts around the
    #    enumerate variable, not replace the enumerate loop
    if 'enumerate' not in code:
        print("P2P: llvm::enumerate usage removed (fix should cast, not restructure)", file=sys.stderr)
        sys.exit(1)

    # 8. Line count sanity -- original is ~570 lines, allow +/- 30 lines
    #    for cast additions but catch major truncation or bloat
    lines = raw.strip().split('\n')
    if len(lines) < 500:
        print(f"P2P: file truncated ({len(lines)} lines, expected ~570)", file=sys.stderr)
        sys.exit(1)
    if len(lines) > 700:
        print(f"P2P: file bloated ({len(lines)} lines, expected ~570)", file=sys.stderr)
        sys.exit(1)

    # 9. Angle bracket balance in stripped code (catches broken template/cast syntax)
    #    Note: we skip lines with #include and << / >> operators
    angle_depth = 0
    for line in code.split('\n'):
        stripped = line.strip()
        if stripped.startswith('#'):
            continue
        # Remove shift operators before counting angles
        cleaned = re.sub(r'->|<<|>>', '', stripped)
        for c in cleaned:
            if c == '<': angle_depth += 1
            elif c == '>': angle_depth -= 1

    # Angle brackets don't need to be perfectly balanced across the file
    # (e.g. template specializations), but extreme imbalance signals breakage
    if abs(angle_depth) > 5:
        print(f"P2P: angle bracket imbalance ({angle_depth})", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"P2P: {e}", file=sys.stderr)
    sys.exit(1)
P2PEOF
    if [ $? -eq 0 ]; then
        add_reward 0.025
        echo "T18 PASS  P2P structure check"
    else
        echo "T18 FAIL  P2P structure check"
    fi
else
    echo "T18 FAIL  P2P file missing"
fi

# ==========================================================================
# Clean up and write result
# ==========================================================================
rm -f "$STRIPPED" /tmp/fix1_capture_expr.txt /tmp/fix1_barrier_exprs.txt \
      /tmp/fix1_callop_exprs.txt /tmp/fix1_cast_exprs.txt \
      /tmp/fix2_getresult_exprs.txt /tmp/test_narrowing.cpp /tmp/test_narrowing

REWARD=$(python3 -c "print(min(1.0, $REWARD))")
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
echo ""
echo "Score: $REWARD"
