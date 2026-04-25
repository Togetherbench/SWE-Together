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

# Pick a C++ compiler (gating; if not available we can't verify behaviorally → 0)
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
    open(os.path.join(outdir,name),'w').write("\n".join(lst)+"\n" if lst else "")

w('barrier.txt',barrier)
w('callop.txt',callop)
w('geparg.txt',geparg)
w('toerase.txt',toerase)
w('getresult.txt',getresult)
w('getarg.txt',getarg)
PYEOF

# Behavioral check: does an expression EXPR (referring to a size_t var) compile
# clean under -Wconversion -Werror when passed to an `unsigned` or `int32_t` sink?
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
    for cand in idx i j oldIdx newIdx index; do
        if echo "$expr" | grep -qE "\b${cand}\b"; then
            echo "$cand"; return
        fi
    done
    echo "idx"
}

# Returns 0 iff EVERY non-empty expression in the file is clean for the target type.
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

# F2P gates — each must FAIL on the unmodified buggy base (since base passes
# raw `idx` / `i` / `j` to unsigned/int32_t sinks) and PASS only when the agent
# has cast (or otherwise narrowed safely) at that site.

# Site 1 (the literal compile-error site): lowerBarrier + lowerCallOp third args
# Both must be clean. Weight 0.40.
if all_clean "$WORK/exprs/barrier.txt" "unsigned" \
   && all_clean "$WORK/exprs/callop.txt" "unsigned"; then
    add_reward 0.40
fi

# Site 2: LLVM::GEPArg(j) — int32_t narrowing in the same TU. Weight 0.20.
if all_clean "$WORK/exprs/geparg.txt" "int32_t"; then
    add_reward 0.20
fi

# Site 3: toErase.set(i) — BitVector::set takes unsigned. Weight 0.15.
if all_clean "$WORK/exprs/toerase.txt" "unsigned"; then
    add_reward 0.15
fi

# Site 4: op->getResult(i).replaceAllUsesWith / setType — unsigned. Weight 0.15.
if all_clean "$WORK/exprs/getresult.txt" "unsigned"; then
    add_reward 0.15
fi

# Site 5: region->getArgument(i).replaceAllUsesWith — unsigned. Weight 0.10.
if all_clean "$WORK/exprs/getarg.txt" "unsigned"; then
    add_reward 0.10
fi

echo "$REWARD" > /logs/verifier/reward.txt
exit 0