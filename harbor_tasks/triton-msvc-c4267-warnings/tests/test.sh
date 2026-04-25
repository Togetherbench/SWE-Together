#!/bin/bash
set +e

mkdir -p /logs/verifier
REWARD=0.0
FILE="/workspace/triton/lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp"
WORK=$(mktemp -d)

add_reward() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.6f", a+b}')
}

finalize() {
    echo "$REWARD" > /logs/verifier/reward.txt
    exit 0
}

# Hard gate: file must exist
if [ ! -f "$FILE" ]; then
    finalize
fi

# Pick a C++ compiler
CXX=""
for c in g++ clang++ c++; do
    if command -v "$c" >/dev/null 2>&1; then CXX="$c"; break; fi
done
if [ -z "$CXX" ]; then
    finalize
fi

# Strip comments/strings to avoid false positives
python3 - "$FILE" > "$WORK/stripped.cpp" << 'PYEOF'
import re, sys
code = open(sys.argv[1]).read()
code = re.sub(r'/\*.*?\*/', '', code, flags=re.DOTALL)
code = re.sub(r'//[^\n]*', '', code)
code = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', code)
sys.stdout.write(code)
PYEOF

STRIPPED="$WORK/stripped.cpp"

# ----- P2P gating: don't allow the file to become unparseable garbage -----
# Quick sanity: balanced braces and parens at top level (rough but catches truncations).
python3 - "$STRIPPED" > "$WORK/sanity.txt" << 'PYEOF'
import sys
s=open(sys.argv[1]).read()
b=s.count('{')-s.count('}')
p=s.count('(')-s.count(')')
print(b,p)
PYEOF
read SBR SPR < "$WORK/sanity.txt"
if [ "$SBR" != "0" ] || [ "$SPR" != "0" ]; then
    finalize
fi

# Extract candidate expressions at known buggy call sites
mkdir -p "$WORK/exprs"
python3 - "$STRIPPED" "$WORK/exprs" << 'PYEOF'
import re, os, sys
src = open(sys.argv[1]).read()
outdir = sys.argv[2]

def balanced_args(s, p):
    if p >= len(s) or s[p] != '(':
        return None, -1
    depth = 0
    for i in range(p, len(s)):
        c = s[i]
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return s[p+1:i], i
    return None, -1

def split_args(args):
    out=[]; depth=0; cur=[]
    for c in args:
        if c in '(<[{': depth+=1
        elif c in ')>]}': depth-=1
        if c==',' and depth==0:
            out.append(''.join(cur).strip()); cur=[]
        else:
            cur.append(c)
    if cur: out.append(''.join(cur).strip())
    return out

def calls(text, fname):
    res=[]
    for m in re.finditer(r'\b'+re.escape(fname)+r'\s*\(', text):
        # avoid matching member-defs like `lowerBarrier(...) {`
        p=m.end()-1
        a,_=balanced_args(text,p)
        if a is not None:
            res.append(split_args(a))
    return res

barrier=[a[2] for a in calls(src,'lowerBarrier') if len(a)>=3]
callop=[a[2] for a in calls(src,'lowerCallOp') if len(a)>=3]

geparg=[]
for m in re.finditer(r'\bLLVM::GEPArg\s*\(', src):
    p=m.end()-1
    a,_=balanced_args(src,p)
    if a: geparg.append(a.strip())

toerase=[]
for m in re.finditer(r'\btoErase\.set\s*\(', src):
    p=m.end()-1
    a,_=balanced_args(src,p)
    if a: toerase.append(a.strip())

getresult=[]
for m in re.finditer(r'\bgetResult\s*\(', src):
    p=m.end()-1
    a,end=balanced_args(src,p)
    if a is None: continue
    tail=src[end:end+80]
    if 'replaceAllUsesWith' in tail or 'setType' in tail:
        getresult.append(a.strip())

getarg=[]
for m in re.finditer(r'\bgetArgument\s*\(', src):
    p=m.end()-1
    a,end=balanced_args(src,p)
    if a is None: continue
    tail=src[end:end+80]
    if 'replaceAllUsesWith' in tail:
        getarg.append(a.strip())

def w(name,lst):
    open(os.path.join(outdir,name),'w').write(("\n".join(lst)+"\n") if lst else "")

w('barrier.txt',barrier)
w('callop.txt',callop)
w('geparg.txt',geparg)
w('toerase.txt',toerase)
w('getresult.txt',getresult)
w('getarg.txt',getarg)
PYEOF

# Behavioral check via tiny compile probe under -Wconversion -Werror.
test_expr_clean() {
    local expr="$1"
    local target="$2"  # "unsigned" or "int32_t"
    local var="$3"
    local src="$WORK/probe.cpp"
    cat > "$src" <<EOF
#include <cstddef>
#include <cstdint>
struct Sink { void take_unsigned(unsigned){} void take_i32(std::int32_t){} };
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
    "$CXX" -std=c++17 -Wconversion -Werror -c "$src" -o "$WORK/probe.o" >/dev/null 2>&1
    return $?
}

pick_var() {
    local expr="$1"
    for cand in idx i j oldIdx newIdx index captureIdx; do
        if echo "$expr" | grep -qE "\b${cand}\b"; then
            echo "$cand"; return
        fi
    done
    echo "idx"
}

# Returns 0 iff EVERY non-empty expression in the file is clean for the target type
# AND we actually saw at least one expression.
all_clean() {
    local sitefile="$1"
    local target="$2"
    [ ! -s "$sitefile" ] && return 1
    local saw=0
    while IFS= read -r expr; do
        [ -z "$expr" ] && continue
        saw=1
        local var
        var=$(pick_var "$expr")
        if ! test_expr_clean "$expr" "$target" "$var"; then
            return 1
        fi
    done < "$sitefile"
    [ "$saw" = "1" ] && return 0 || return 1
}

# Helper: count non-empty lines.
nlines() {
    [ -s "$1" ] || { echo 0; return; }
    awk 'NF' "$1" | wc -l
}

# ---------------------------------------------------------------------------
# F2P gates — six independent slices of correctness, total weight = 1.0
# ---------------------------------------------------------------------------

# Gate A (0.20): the literal compile-error site — lowerBarrier 3rd arg is clean.
# This is the minimum to claim the user's reported error is addressed at all.
GATE_A=0
if all_clean "$WORK/exprs/barrier.txt" "unsigned"; then
    GATE_A=1
    add_reward 0.20
fi

# Gate B (0.20): the parallel site — lowerCallOp 3rd arg is clean.
# A "shallow fix" agent might do A but miss B. Independent slice.
GATE_B=0
if all_clean "$WORK/exprs/callop.txt" "unsigned"; then
    GATE_B=1
    add_reward 0.20
fi

# Gate C (0.15): GEPArg(j) — int32_t narrowing, distinct target type.
GATE_C=0
if all_clean "$WORK/exprs/geparg.txt" "int32_t"; then
    GATE_C=1
    add_reward 0.15
fi

# Gate D (0.15): toErase.set(i) — BitVector::set takes unsigned.
GATE_D=0
if all_clean "$WORK/exprs/toerase.txt" "unsigned"; then
    GATE_D=1
    add_reward 0.15
fi

# Gate E (0.15): op->getResult(i).{replaceAllUsesWith,setType} — unsigned.
GATE_E=0
if all_clean "$WORK/exprs/getresult.txt" "unsigned"; then
    GATE_E=1
    add_reward 0.15
fi

# Gate F (0.15): region->getArgument(i).replaceAllUsesWith — unsigned.
GATE_F=0
if all_clean "$WORK/exprs/getarg.txt" "unsigned"; then
    GATE_F=1
    add_reward 0.15
fi

# ---------------------------------------------------------------------------
# Anti-cheese: ensure the agent didn't simply delete the call sites to make
# the gates trivially pass. We require minimum populations.
# ---------------------------------------------------------------------------
NB=$(nlines "$WORK/exprs/barrier.txt")
NC=$(nlines "$WORK/exprs/callop.txt")
NG=$(nlines "$WORK/exprs/geparg.txt")
NTE=$(nlines "$WORK/exprs/toerase.txt")
NGR=$(nlines "$WORK/exprs/getresult.txt")
NGA=$(nlines "$WORK/exprs/getarg.txt")

# If site population collapsed below baseline, treat the corresponding gate as
# failed (subtract its weight back out).
revert() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.6f", a-b}')
}

if [ "$NB" -lt 1 ] && [ "$GATE_A" = "1" ]; then revert 0.20; fi
if [ "$NC" -lt 1 ] && [ "$GATE_B" = "1" ]; then revert 0.20; fi
if [ "$NG" -lt 1 ] && [ "$GATE_C" = "1" ]; then revert 0.15; fi
if [ "$NTE" -lt 1 ] && [ "$GATE_D" = "1" ]; then revert 0.15; fi
if [ "$NGR" -lt 1 ] && [ "$GATE_E" = "1" ]; then revert 0.15; fi
if [ "$NGA" -lt 1 ] && [ "$GATE_F" = "1" ]; then revert 0.15; fi

# Floor REWARD at 0
NEG=$(awk -v r="$REWARD" 'BEGIN{print (r<0)?1:0}')
if [ "$NEG" = "1" ]; then REWARD=0.0; fi

echo "$REWARD" > /logs/verifier/reward.txt
exit 0