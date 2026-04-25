#!/bin/bash
set +e

# Verifier for triton-msvc-c4267-warnings
# Goal: differentiate fixes by quality. The compile error is a size_t->unsigned
# narrowing in WarpSpecializeUtility.cpp, but the *same class of bug* appears
# at multiple sites in the file (and across the repo). A strong fix addresses
# the reported site AND the related sites in the same TU. A weak fix only
# patches the literal lambda capture / call args.
#
# Approach: use a real C++ compiler (g++ with -Wconversion -Werror) to
# actually verify each candidate fix expression converts a size_t to unsigned
# without the warning. We extract the expressions agents wrote at known
# bug sites and compile-test them.

REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"
WORK=$(mktemp -d)

add_reward() {
    local delta="$1"
    REWARD=$(awk -v a="$REWARD" -v b="$delta" 'BEGIN{printf "%.6f", a+b}')
}

# Pick a C++ compiler
CXX=""
for c in g++ clang++ c++; do
    if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done

# ============================================================
# Phase 0: file exists
# ============================================================
if [ ! -f "$FILE" ]; then
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

# Strip C/C++ comments and string literals
python3 - "$FILE" > "$WORK/stripped.cpp" << 'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    code = f.read()
code = re.sub(r'/\*.*?\*/', '', code, flags=re.DOTALL)
code = re.sub(r'//[^\n]*', '', code)
code = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', code)
sys.stdout.write(code)
PYEOF

STRIPPED="$WORK/stripped.cpp"

# ============================================================
# Phase 1: Extract candidate "size_t -> unsigned" expressions agents wrote
# at the known bug sites in WarpSpecializeUtility.cpp
# Output: /tmp/exprs/<site>.txt with one expression per line
# ============================================================
mkdir -p "$WORK/exprs"

python3 - "$STRIPPED" "$WORK/exprs" << 'PYEOF'
import re, os, sys
src = open(sys.argv[1]).read()
outdir = sys.argv[2]

def balanced_args(s, open_paren_pos):
    if open_paren_pos >= len(s) or s[open_paren_pos] != '(':
        return None, -1
    depth = 0
    for i in range(open_paren_pos, len(s)):
        c = s[i]
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return s[open_paren_pos+1:i], i
    return None, -1

def split_args(args):
    out = []
    depth = 0
    cur = []
    for c in args:
        if c in '(<[{': depth += 1
        elif c in ')>]}': depth -= 1
        if c == ',' and depth == 0:
            out.append(''.join(cur).strip()); cur=[]
        else:
            cur.append(c)
    if cur:
        out.append(''.join(cur).strip())
    return out

def find_call_args(text, fname):
    """Return list of (args_list) for each call to fname."""
    res = []
    for m in re.finditer(r'\b' + re.escape(fname) + r'\s*\(', text):
        p = m.end() - 1
        args, _ = balanced_args(text, p)
        if args is not None:
            res.append(split_args(args))
    return res

# --- Bug site A: lowerBarrier(op, numWarps, <EXPR>, barrierHelper)
# --- Bug site B: lowerCallOp(callOp, numWarps, <EXPR>, barrierHelper)
exprs_barrier = []
for args in find_call_args(src, 'lowerBarrier'):
    if len(args) >= 3:
        exprs_barrier.append(args[2])
exprs_callop = []
for args in find_call_args(src, 'lowerCallOp'):
    if len(args) >= 3:
        exprs_callop.append(args[2])

# --- Bug site C: op->getResult(<EXPR>).replaceAllUsesWith(...)
# Look for ".getResult(EXPR).replaceAllUsesWith"
exprs_getresult = []
for m in re.finditer(r'\bgetResult\s*\(', src):
    p = m.end() - 1
    args, end = balanced_args(src, p)
    if args is None: continue
    # peek ahead for replaceAllUsesWith within ~80 chars
    tail = src[end:end+80]
    if 'replaceAllUsesWith' in tail or 'setType' in tail:
        exprs_getresult.append(args.strip())

# --- Bug site D: getArgument(<EXPR>).replaceAllUsesWith
exprs_getarg = []
for m in re.finditer(r'\bgetArgument\s*\(', src):
    p = m.end() - 1
    args, end = balanced_args(src, p)
    if args is None: continue
    tail = src[end:end+80]
    if 'replaceAllUsesWith' in tail:
        exprs_getarg.append(args.strip())

# --- Bug site E: toErase.set(<EXPR>)  (BitVector::set takes unsigned)
exprs_toerase = []
for m in re.finditer(r'\btoErase\.set\s*\(', src):
    p = m.end() - 1
    args, _ = balanced_args(src, p)
    if args:
        exprs_toerase.append(args.strip())

# --- Bug site F: LLVM::GEPArg(<EXPR>)  (takes int32_t)
exprs_geparg = []
for m in re.finditer(r'\bLLVM::GEPArg\s*\(', src):
    p = m.end() - 1
    args, _ = balanced_args(src, p)
    if args:
        exprs_geparg.append(args.strip())

def write(name, lst):
    with open(os.path.join(outdir, name), 'w') as f:
        for e in lst:
            f.write(e + "\n")

write('barrier.txt', exprs_barrier)
write('callop.txt', exprs_callop)
write('getresult.txt', exprs_getresult)
write('getarg.txt', exprs_getarg)
write('toerase.txt', exprs_toerase)
write('geparg.txt', exprs_geparg)

# Also dump whole stripped file for grep checks
PYEOF

# ============================================================
# Phase 2: Build a tiny C++ test harness that mimics the relevant
# call signatures and verifies the agent's expression compiles
# clean under -Wconversion -Werror with a size_t input.
# ============================================================

# Helper: test if a given expression "EXPR" referring to a size_t variable
# named 'idx' (or 'i' / 'j') compiles clean as the named target type.
# Returns 0 on success.
test_expr_clean() {
    local expr="$1"
    local var="$2"        # name of the size_t variable used in expr
    local target="$3"     # target type: "unsigned" or "int32_t"
    local src="$WORK/probe_$$_$RANDOM.cpp"
    local obj="$WORK/probe_$$_$RANDOM.o"
    cat > "$src" <<EOF
#include <cstddef>
#include <cstdint>
#include <utility>
struct Sink { void take_unsigned(unsigned){} void take_i32(int32_t){} };
int main() {
    std::size_t $var = 7;
    (void)$var;
    Sink s;
EOF
    if [ "$target" = "unsigned" ]; then
        echo "    s.take_unsigned($expr);" >> "$src"
    else
        echo "    s.take_i32($expr);" >> "$src"
    fi
    echo "    return 0; }" >> "$src"
    "$CXX" -std=c++17 -Wconversion -Werror -c "$src" -o "$obj" >/dev/null 2>&1
    local rc=$?
    rm -f "$src" "$obj"
    return $rc
}

# Test if at least one expression in a given site file passes the clean check.
# Picks the variable name automatically from the expression.
site_clean() {
    local sitefile="$1"
    local target="$2"
    [ ! -s "$sitefile" ] && return 1
    local any_pass=1
    while IFS= read -r expr; do
        [ -z "$expr" ] && continue
        # Determine which loop variable is referenced
        local var=""
        for cand in idx i j oldIdx newIdx index; do
            if echo "$expr" | grep -qE "\b${cand}\b"; then
                var="$cand"; break
            fi
        done
        [ -z "$var" ] && var="idx"
        # Sanitize: strip trailing junk
        expr_clean=$(echo "$expr" | tr -d '\r')
        if test_expr_clean "$expr_clean" "$var" "$target"; then
            any_pass=0
        fi
    done < "$sitefile"
    return $any_pass
}

# Test if ALL expressions in a file are clean (stricter — no remaining bug
# instances at this site). Empty file => N/A => returns 1 (not all clean).
site_all_clean() {
    local sitefile="$1"
    local target="$2"
    [ ! -s "$sitefile" ] && return 1
    local total=0 fails=0
    while IFS= read -r expr; do
        [ -z "$expr" ] && continue
        total=$((total+1))
        local var=""
        for cand in idx i j oldIdx newIdx index; do
            if echo "$expr" | grep -qE "\b${cand}\b"; then
                var="$cand"; break
            fi
        done
        [ -z "$var" ] && var="idx"
        expr_clean=$(echo "$expr" | tr -d '\r')
        if ! test_expr_clean "$expr_clean" "$var" "$target"; then
            fails=$((fails+1))
        fi
    done < "$sitefile"
    [ "$total" -gt 0 ] && [ "$fails" -eq 0 ]
}

# ============================================================
# SCORING
#
# Pass-to-pass / structural sanity (0.15 total)
#   T1 0.05   File still parses as C++ (brace/paren balanced, key symbols)
#   T2 0.05   Key functions still present
#   T3 0.05   No bare "[&, idx = idx]" pattern with ONLY size_t (regression
#             guard: capture itself can stay; but file compiles cleanly)
#
# F2P behavioral (0.65 total) — uses real compiler
#   T4 0.20   lowerBarrier 3rd arg: at least one call clean
#   T5 0.20   lowerCallOp 3rd arg: at least one call clean
#   T6 0.10   lowerBarrier: ALL call sites clean (rewards thorough fix)
#   T7 0.10   lowerCallOp:  ALL call sites clean (rewards thorough fix)
#   T8 0.05   getResult(...).replaceAllUsesWith chain: at least one clean
#
# Quality breadth (0.20 total) — rewards fixing related sites in same TU
#   T9 0.05   getArgument(EXPR).replaceAllUsesWith clean (>=1)
#   T10 0.05  toErase.set(EXPR) clean (>=1)
#   T11 0.05  LLVM::GEPArg(EXPR) clean (>=1)
#   T12 0.05  All getResult sites clean (full sweep within file)
# ============================================================

if [ -z "$CXX" ]; then
    # No compiler: degrade to structural-only with low ceiling
    echo "WARN: no C++ compiler available; using structural fallback" >&2
    if grep -q 'static_cast<unsigned>' "$FILE" || grep -q '(unsigned)' "$FILE"; then
        REWARD=0.30
    fi
    if grep -q 'lowerBarrier' "$FILE" && grep -q 'lowerCallOp' "$FILE"; then
        add_reward 0.10
    fi
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
fi

# --- T1: file parses (basic sanity) ---
opens=$(tr -cd '{' < "$STRIPPED" | wc -c)
closes=$(tr -cd '}' < "$STRIPPED" | wc -c)
if [ "$opens" = "$closes" ] && [ "$opens" -gt 50 ]; then
    add_reward 0.05
fi

# --- T2: key functions still present ---
if grep -q 'lowerKernelBarriers' "$STRIPPED" \
   && grep -q 'lowerBarrier' "$STRIPPED" \
   && grep -q 'lowerCallOp' "$STRIPPED" \
   && grep -q 'partition->walk' "$STRIPPED"; then
    add_reward 0.05
fi

# --- T3: no /* still-broken */ — heuristic regression guard.
# Verify includes haven't been mangled.
if grep -q '#include' "$FILE" && grep -q 'mlir' "$FILE"; then
    add_reward 0.05
fi

# --- T4: lowerBarrier 3rd arg — at least one call clean ---
if site_clean "$WORK/exprs/barrier.txt" unsigned; then
    add_reward 0.20
fi

# --- T5: lowerCallOp 3rd arg — at least one call clean ---
if site_clean "$WORK/exprs/callop.txt" unsigned; then
    add_reward 0.20
fi

# --- T6: lowerBarrier — ALL call sites clean ---
if site_all_clean "$WORK/exprs/barrier.txt" unsigned; then
    add_reward 0.10
fi

# --- T7: lowerCallOp — ALL call sites clean ---
if site_all_clean "$WORK/exprs/callop.txt" unsigned; then
    add_reward 0.10
fi

# --- T8: at least one getResult(...) site clean (related bug in same TU) ---
if site_clean "$WORK/exprs/getresult.txt" unsigned; then
    add_reward 0.05
fi

# --- T9: at least one getArgument(...) site clean ---
if site_clean "$WORK/exprs/getarg.txt" unsigned; then
    add_reward 0.05
fi

# --- T10: at least one toErase.set site clean ---
if site_clean "$WORK/exprs/toerase.txt" unsigned; then
    add_reward 0.05
fi

# --- T11: at least one LLVM::GEPArg site clean (int32_t target) ---
if site_clean "$WORK/exprs/geparg.txt" int32_t; then
    add_reward 0.05
fi

# --- T12: all getResult sites in this file clean ---
if site_all_clean "$WORK/exprs/getresult.txt" unsigned; then
    add_reward 0.05
fi

# Cap at 1.0
REWARD=$(awk -v r="$REWARD" 'BEGIN{ if (r>1.0) r=1.0; printf "%.4f", r }')

mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt

# Diagnostics
{
    echo "=== triton-msvc-c4267-warnings verifier ==="
    echo "REWARD=$REWARD"
    echo "CXX=$CXX"
    echo "barrier exprs:"; cat "$WORK/exprs/barrier.txt" 2>/dev/null
    echo "callop exprs:"; cat "$WORK/exprs/callop.txt" 2>/dev/null
    echo "getresult exprs:"; cat "$WORK/exprs/getresult.txt" 2>/dev/null
    echo "getarg exprs:"; cat "$WORK/exprs/getarg.txt" 2>/dev/null
    echo "toerase exprs:"; cat "$WORK/exprs/toerase.txt" 2>/dev/null
    echo "geparg exprs:"; cat "$WORK/exprs/geparg.txt" 2>/dev/null
} > /logs/verifier/diag.txt 2>&1

rm -rf "$WORK"
exit 0