#!/bin/bash
set +e

# ============================================================
# Verifier for pi-mono parallel tool stall investigation task
# ============================================================
# The task asks for an investigation + design memo (no code changes).
# However, several agents went further and implemented fixes. We score:
#   - Memo quality (presence, structure, concept coverage, code refs)   ~50%
#   - Behavioral grounding: if a fix was attempted, does it actually
#     serialize/queue interactive dialogs and pass repo tests?           ~50%
# Strong fixes that demonstrably serialize dialogs and keep tests green
# score highest. Memo-only attempts cap around 0.5. Broken/no-op
# attempts score near 0.
# ============================================================

REWARD=0
mkdir -p /logs/verifier

REPO=/workspace/pi-mono
if [ ! -d "$REPO" ]; then
  # Try alternate paths
  for cand in /workspace/repo /workspace/pi-mono-* ; do
    if [ -d "$cand" ]; then REPO="$cand"; break; fi
  done
fi

git config --global --add safe.directory "$REPO" 2>/dev/null || true

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# Try to ensure node/npm/bun on PATH
for p in /root/.bun/bin /usr/local/share/npm/bin /opt/homebrew/bin ; do
  [ -d "$p" ] && export PATH="$p:$PATH"
done

add_reward() {
  local inc="$1"
  REWARD=$(awk -v a="$REWARD" -v b="$inc" 'BEGIN{ s=a+b; if (s>1) s=1; if (s<0) s=0; printf "%.4f", s }')
}

cap_score() {
  awk -v v="$1" -v c="$2" 'BEGIN{ if (v>c) v=c; if (v<0) v=0; printf "%.4f", v }'
}

echo "=== Repo: $REPO ==="
echo "=== node: $(which node 2>/dev/null) $(node --version 2>/dev/null) ==="
echo "=== npm:  $(which npm 2>/dev/null) ==="

# ============================================================
# 1. Locate investigation memo (markdown / text artifacts)
# ============================================================
echo ""
echo "=== Locating investigation memo ==="
cd "$REPO" 2>/dev/null

BEST_FILE=""
BEST_SIZE=0

CANDIDATE_FILES=""
if [ -d "$REPO/.git" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    f=$(echo "$line" | awk '{print $NF}')
    [ -z "$f" ] && continue
    case "$f" in
      *node_modules/*|*.git/*|*dist/*|*.generated*) continue ;;
    esac
    CANDIDATE_FILES="$CANDIDATE_FILES $REPO/$f"
  done < <(cd "$REPO" && git status --porcelain 2>/dev/null | grep -E '^\?\?|^ M|^M |^A |^AM')
fi

for f in $(find /workspace -maxdepth 3 \( -name "*.md" -o -name "*.txt" \) ! -name "instruction.md" ! -name "README.md" 2>/dev/null); do
  CANDIDATE_FILES="$CANDIDATE_FILES $f"
done

for f in $CANDIDATE_FILES; do
  [ -f "$f" ] || continue
  SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
  [ "$SIZE" -lt 300 ] && continue
  if grep -qiE "parallel|interactive|stall|tool|extension|investigation|memo|oracle|recommendation" "$f" 2>/dev/null; then
    if [ "$SIZE" -gt "$BEST_SIZE" ]; then
      BEST_SIZE=$SIZE
      BEST_FILE=$f
    fi
  fi
done

# Fallback: assistant text from Claude session jsonl
if [ -z "$BEST_FILE" ] || [ "$BEST_SIZE" -lt 1500 ]; then
  for sf in $(find /home /root -path '*/.claude/projects/*' -name '*.jsonl' 2>/dev/null); do
    EXTRACTED=$(node -e "
      const fs = require('fs');
      try {
        const lines = fs.readFileSync(process.argv[1], 'utf8').split('\n').filter(Boolean);
        let bestText = '';
        for (const line of lines) {
          try {
            const d = JSON.parse(line);
            if (d.type === 'assistant' && d.message && Array.isArray(d.message.content)) {
              for (const c of d.message.content) {
                if (c.type === 'text' && c.text && c.text.length > bestText.length) bestText = c.text;
              }
            }
          } catch(e) {}
        }
        process.stdout.write(bestText);
      } catch(e) {}
    " "$sf" 2>/dev/null)
    EXTRACTED_SIZE=${#EXTRACTED}
    if [ "$EXTRACTED_SIZE" -gt "$BEST_SIZE" ]; then
      printf '%s' "$EXTRACTED" > /tmp/agent_session_output.txt
      BEST_FILE="/tmp/agent_session_output.txt"
      BEST_SIZE=$EXTRACTED_SIZE
    fi
  done
fi

# Fallback 2: aggregate git diff added lines
if [ -z "$BEST_FILE" ] || [ "$BEST_SIZE" -lt 1500 ]; then
  if [ -d "$REPO/.git" ]; then
    ADDED=$(cd "$REPO" && git diff HEAD 2>/dev/null | grep "^+" | grep -v "^+++" | sed 's/^+//')
    ADDED_SIZE=${#ADDED}
    if [ "$ADDED_SIZE" -gt "$BEST_SIZE" ]; then
      printf '%s' "$ADDED" > /tmp/agent_diff_output.txt
      BEST_FILE="/tmp/agent_diff_output.txt"
      BEST_SIZE=$ADDED_SIZE
    fi
  fi
fi

if [ -n "$BEST_FILE" ] && [ -f "$BEST_FILE" ]; then
  echo "Found doc: $BEST_FILE ($BEST_SIZE bytes)"
  cp "$BEST_FILE" /tmp/memo_content.txt
else
  echo "No memo found"
  : > /tmp/memo_content.txt
fi

MEMO_LEN=$(wc -c < /tmp/memo_content.txt 2>/dev/null || echo 0)
echo "Memo length: $MEMO_LEN"

# ============================================================
# Source paths (used by reference-accuracy gate and behavioral gate)
# ============================================================
AGENT_LOOP_TS="$REPO/packages/agent/src/agent-loop.ts"
INTERACTIVE_TS="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
RUNNER_TS="$REPO/packages/coding-agent/src/core/extensions/runner.ts"
TYPES_TS="$REPO/packages/agent/src/types.ts"

echo ""
echo "=== Source files presence ==="
for f in "$AGENT_LOOP_TS" "$INTERACTIVE_TS" "$RUNNER_TS" "$TYPES_TS"; do
  if [ -f "$f" ]; then echo "OK: $f"; else echo "MISSING: $f"; fi
done

# ============================================================
# Gate 1 [P2P] (weight 0.08): Memo presence/substance
# ============================================================
echo ""
echo "=== Gate 1 [P2P]: Memo substance (max 0.08) ==="
G1=$(awk -v n="$MEMO_LEN" 'BEGIN{
  if (n>=10000) print 0.08;
  else if (n>=5000) print 0.06;
  else if (n>=2500) print 0.04;
  else if (n>=1000) print 0.02;
  else print 0;
}')
echo "Gate1: $G1"
add_reward "$G1"

# ============================================================
# Gate 2 [F2P] (weight 0.10): Required sections
# ============================================================
echo ""
echo "=== Gate 2 [F2P]: Sections (max 0.10) ==="
G2=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8').toLowerCase();}catch(e){}
if(t.length<500){console.log(0);process.exit(0);}
const sections=[
  /executive\s*summary/,
  /evidence/,
  /reproduc/,
  /(option matrix|option\s*[a-d]|solution options|options?)/,
  /oracle/,
  /(final\s*recommendation|recommendation)/,
  /unresolved/,
];
let hits=0;for(const r of sections) if(r.test(t)) hits++;
let s=0;
if(hits>=7) s=0.10;
else if(hits>=6) s=0.085;
else if(hits>=5) s=0.065;
else if(hits>=4) s=0.045;
else if(hits>=3) s=0.025;
console.log(s);
" 2>/dev/null)
echo "Gate2: $G2"
add_reward "${G2:-0}"

# ============================================================
# Gate 3 [F2P] (weight 0.12): Concept coverage of root cause
# ============================================================
echo ""
echo "=== Gate 3 [F2P]: Concept coverage (max 0.12) ==="
G3=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8').toLowerCase();}catch(e){}
if(t.length<500){console.log(0);process.exit(0);}
const groups=[
  [/parallel/, /promise\.all/],
  [/sequential|serial(ize|ised|ized)?|queue|mutex/],
  [/interactive|dialog|extensionselector|extensioninput|extensioneditor|ctx\.ui/],
  [/stall|hang|deadlock|orphan|race|block/],
  [/executetoolcall|agent[-_ ]?loop|executetoolcallsparallel/],
  [/single[- ]slot|overwrit|clobber|editorcontainer\.clear|replace|evict/],
  [/default(\s+mode)?|registertool|executionmode/],
];
let hits=0;
for(const g of groups){ for(const r of g){ if(r.test(t)){ hits++; break; } } }
let s=0;
if(hits>=7) s=0.12;
else if(hits>=6) s=0.10;
else if(hits>=5) s=0.075;
else if(hits>=4) s=0.05;
else if(hits>=3) s=0.025;
console.log(s);
" 2>/dev/null)
echo "Gate3: $G3"
add_reward "${G3:-0}"

# ============================================================
# Gate 4 [F2P] (weight 0.10): Code reference accuracy
# Verify memo cites real symbols from the actual source.
# ============================================================
echo ""
echo "=== Gate 4 [F2P]: Reference accuracy (max 0.10) ==="
G4=$(node -e "
const fs=require('fs');
let memo='';try{memo=fs.readFileSync('/tmp/memo_content.txt','utf8');}catch(e){}
if(memo.length<500){console.log(0);process.exit(0);}
const m=memo.toLowerCase();
const realSymbols=[
  'executetoolcallsparallel',
  'executetoolcallssequential',
  'showextensionselector',
  'showextensioninput',
  'showextensioneditor',
  'editorcontainer',
  'extensionselector',
  'agent-loop',
  'interactive-mode',
  'runner.ts',
  'extensions/runner',
];
let hits=0;
for(const s of realSymbols) if(m.includes(s)) hits++;
// also accept file paths
const paths=[
  'packages/agent/src/agent-loop',
  'packages/coding-agent/src/modes/interactive/interactive-mode',
  'packages/coding-agent/src/core/extensions/runner',
];
for(const p of paths) if(m.includes(p.toLowerCase())) hits++;
let s=0;
if(hits>=7) s=0.10;
else if(hits>=5) s=0.075;
else if(hits>=3) s=0.05;
else if(hits>=1) s=0.02;
console.log(s);
" 2>/dev/null)
echo "Gate4: $G4"
add_reward "${G4:-0}"

# ============================================================
# Gate 5 [F2P] (weight 0.10): Multiple solution options w/ tradeoffs
# ============================================================
echo ""
echo "=== Gate 5 [F2P]: Solution options (max 0.10) ==="
G5=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8');}catch(e){}
if(t.length<500){console.log(0);process.exit(0);}
const lo=t.toLowerCase();
// count distinct option/approach markers
let optionCount=0;
const optMarkers=[/option\s*a/i,/option\s*b/i,/option\s*c/i,/option\s*d/i];
for(const r of optMarkers) if(r.test(t)) optionCount++;
if(optionCount<2){
  // fall back: count solution-like sections
  const alt=[/serialize/i,/mutex/i,/queue/i,/sequential/i,/hybrid/i,/scheduler/i,/fallback/i,/error strategy/i];
  let h=0;for(const r of alt) if(r.test(t)) h++;
  optionCount=Math.min(4, Math.floor(h/2));
}
// tradeoff signals
const tradeoffSignals=[/tradeoff/i,/risk/i,/ux\s*impact|user\s*experience/i,/backward.*compat/i,/complexity/i,/test\s*strategy/i];
let tHits=0; for(const r of tradeoffSignals) if(r.test(t)) tHits++;
let s=0;
if(optionCount>=4 && tHits>=4) s=0.10;
else if(optionCount>=3 && tHits>=3) s=0.075;
else if(optionCount>=3 && tHits>=2) s=0.055;
else if(optionCount>=2 && tHits>=2) s=0.035;
else if(optionCount>=2) s=0.02;
console.log(s);
" 2>/dev/null)
echo "Gate5: $G5"
add_reward "${G5:-0}"

# ============================================================
# Behavioral gates: did the agent (optionally) implement a fix?
# We do NOT require a code fix (task asked for memo only), but
# code fixes that demonstrably work earn the remaining ~50%.
# ============================================================
DIFF_FILE=/tmp/repo_diff.txt
if [ -d "$REPO/.git" ]; then
  (cd "$REPO" && git diff HEAD 2>/dev/null) > "$DIFF_FILE"
else
  : > "$DIFF_FILE"
fi
DIFF_BYTES=$(wc -c < "$DIFF_FILE" 2>/dev/null || echo 0)

# Detect new test files added by agent (regression tests for the bug)
AGENT_TEST_FILES=$( (cd "$REPO" && git status --porcelain 2>/dev/null) \
  | awk '/^(\?\?|A |AM|M ) / {print $2}' \
  | grep -E '\.test\.ts$' \
  | grep -iE 'parallel|interactive|dialog|concurrent|stall' )

echo ""
echo "=== Diff bytes: $DIFF_BYTES ==="
echo "=== Agent test files: $AGENT_TEST_FILES ==="

# ============================================================
# Gate 6 [F2P] (weight 0.10): Reproduction test exists and is well-formed
# Looks for a new test file referencing the bug surface, with at least
# 2 expect() assertions and concurrent dialog invocations.
# ============================================================
echo ""
echo "=== Gate 6 [F2P]: Reproduction test (max 0.10) ==="
G6=0
BEST_TEST=""
for tf in $AGENT_TEST_FILES; do
  full="$REPO/$tf"
  [ -f "$full" ] || continue
  CONTENT=$(cat "$full" 2>/dev/null)
  EXPECTS=$(echo "$CONTENT" | grep -cE 'expect\(' )
  HAS_CONCURRENT=$(echo "$CONTENT" | grep -ciE 'promise\.all|concurrent|parallel|both|race' )
  HAS_DIALOG=$(echo "$CONTENT" | grep -ciE 'select|confirm|input|editor|extensionselector|ctx\.ui' )
  if [ "$EXPECTS" -ge 2 ] && [ "$HAS_CONCURRENT" -ge 1 ] && [ "$HAS_DIALOG" -ge 1 ]; then
    BEST_TEST="$full"
    break
  fi
done
if [ -n "$BEST_TEST" ]; then
  G6=0.10
  echo "Repro test found: $BEST_TEST"
elif [ -n "$AGENT_TEST_FILES" ]; then
  G6=0.04
  echo "Repro test exists but weak"
else
  G6=0
  echo "No repro test"
fi
echo "Gate6: $G6"
add_reward "$G6"

# ============================================================
# Gate 7 [F2P] (weight 0.20): Behavioral fix verification
# If the agent modified runner.ts or interactive-mode.ts to add
# a serialization queue, we (1) statically verify the queue exists
# and (2) try to run the package's tests (best-effort).
# ============================================================
echo ""
echo "=== Gate 7 [F2P]: Behavioral fix (max 0.20) ==="
G7=0

# 7a: Static queue/serialization signal in modified code
QUEUE_HIT=0
for f in "$RUNNER_TS" "$INTERACTIVE_TS"; do
  [ -f "$f" ] || continue
  if grep -qE '(dialogQueue|uiQueue|_uiDialogQueue|withSerializedDialogs|enqueueDialog|serializ(e|ed))' "$f"; then
    QUEUE_HIT=$((QUEUE_HIT+1))
  fi
done

# Also check that the queue actually chains promises
CHAIN_OK=0
for f in "$RUNNER_TS" "$INTERACTIVE_TS"; do
  [ -f "$f" ] || continue
  if grep -qE '(this\.)?(dialogQueue|_uiDialogQueue|uiQueue|tail)\s*=\s*' "$f" \
     && grep -qE '\.then\(' "$f"; then
    CHAIN_OK=1
  fi
done

echo "QUEUE_HIT=$QUEUE_HIT  CHAIN_OK=$CHAIN_OK"

if [ "$QUEUE_HIT" -ge 1 ] && [ "$CHAIN_OK" -eq 1 ]; then
  G7_STATIC=0.10
elif [ "$QUEUE_HIT" -ge 1 ]; then
  G7_STATIC=0.05
else
  G7_STATIC=0
fi

# 7b: TypeScript compiles? Try tsc/build best-effort.
G7_BUILD=0
cd "$REPO" 2>/dev/null

# Find package manager
PKG_MGR=""
if command -v bun >/dev/null 2>&1; then PKG_MGR=bun; fi
if [ -z "$PKG_MGR" ] && command -v pnpm >/dev/null 2>&1; then PKG_MGR=pnpm; fi
if [ -z "$PKG_MGR" ] && command -v npm  >/dev/null 2>&1; then PKG_MGR=npm; fi
echo "Pkg manager: $PKG_MGR"

# Try a typecheck on the affected packages
if [ "$QUEUE_HIT" -ge 1 ] && [ -n "$PKG_MGR" ]; then
  TC_OK=0
  for pkgdir in packages/coding-agent packages/agent ; do
    [ -d "$REPO/$pkgdir" ] || continue
    if [ -f "$REPO/$pkgdir/tsconfig.json" ]; then
      (cd "$REPO/$pkgdir" && timeout 90 npx --no-install tsc --noEmit -p tsconfig.json) > /tmp/tsc_$pkgdir.log 2>&1
      RC=$?
      if [ $RC -eq 0 ]; then
        TC_OK=$((TC_OK+1))
      else
        # try without --no-install
        (cd "$REPO/$pkgdir" && timeout 120 npx tsc --noEmit -p tsconfig.json) > /tmp/tsc_$pkgdir.log 2>&1
        RC=$?
        [ $RC -eq 0 ] && TC_OK=$((TC_OK+1))
      fi
      echo "tsc $pkgdir rc=$RC"
    fi
  done
  if [ "$TC_OK" -ge 2 ]; then G7_BUILD=0.05
  elif [ "$TC_OK" -ge 1 ]; then G7_BUILD=0.025
  fi
fi

# 7c: Run vitest on the agent-authored regression test (if any), with
# a tight timeout; passing test => bug actually demonstrated/fixed.
G7_TEST=0
if [ -n "$BEST_TEST" ] && [ -n "$PKG_MGR" ]; then
  # Determine which package owns this test
  TPKG=""
  case "$BEST_TEST" in
    */coding-agent/*) TPKG="$REPO/packages/coding-agent" ;;
    */agent/*)        TPKG="$REPO/packages/agent" ;;
  esac
  if [ -n "$TPKG" ] && [ -d "$TPKG" ]; then
    REL_TEST="${BEST_TEST#$TPKG/}"
    echo "Running test: $REL_TEST in $TPKG"
    (cd "$TPKG" && timeout 120 npx --no-install vitest run "$REL_TEST" --reporter=basic) > /tmp/vitest_run.log 2>&1
    RC=$?
    if [ $RC -ne 0 ]; then
      (cd "$TPKG" && timeout 180 npx vitest run "$REL_TEST" --reporter=basic) > /tmp/vitest_run.log 2>&1
      RC=$?
    fi
    echo "vitest rc=$RC"
    tail -40 /tmp/vitest_run.log 2>/dev/null
    if [ $RC -eq 0 ]; then
      G7_TEST=0.05
    fi
  fi
fi

G7=$(awk -v a="$G7_STATIC" -v b="$G7_BUILD" -v c="$G7_TEST" 'BEGIN{ s=a+b+c; if (s>0.20) s=0.20; printf "%.4f", s }')
echo "Gate7: static=$G7_STATIC build=$G7_BUILD test=$G7_TEST total=$G7"
add_reward "$G7"

# ============================================================
# Gate 8 [P2P] (weight 0.10): No regression — existing tests still work
# Best-effort: verify no syntax breakage in source files.
# ============================================================
echo ""
echo "=== Gate 8 [P2P]: Non-regression (max 0.10) ==="
G8=0

# If agent didn't change source, full credit (memo-only path)
if [ "$DIFF_BYTES" -lt 200 ]; then
  G8=0.10
  echo "No source changes — memo-only path"
else
  # Check files for syntactic validity by re-running tsc on the package
  SYNTAX_OK=1
  for f in "$RUNNER_TS" "$INTERACTIVE_TS" "$AGENT_LOOP_TS" "$TYPES_TS"; do
    [ -f "$f" ] || continue
    # naive brace balance check
    OPENS=$(grep -o '{' "$f" | wc -l)
    CLOSES=$(grep -o '}' "$f" | wc -l)
    DIFF=$((OPENS - CLOSES))
    if [ "$DIFF" -lt -2 ] || [ "$DIFF" -gt 2 ]; then
      echo "Brace imbalance in $f: opens=$OPENS closes=$CLOSES"
      SYNTAX_OK=0
    fi
  done
  if [ "$SYNTAX_OK" -eq 1 ]; then
    # if we already ran tsc in 7b and it passed at least one package, give full
    if [ -f /tmp/tsc_packages/coding-agent.log ] || [ -f /tmp/tsc_packages/agent.log ]; then
      # Check any tsc log had no errors
      ANY_OK=0
      for L in /tmp/tsc_packages/*.log; do
        [ -f "$L" ] || continue
        if ! grep -qE 'error TS' "$L"; then ANY_OK=1; fi
      done
      if [ "$ANY_OK" -eq 1 ]; then G8=0.10; else G8=0.05; fi
    else
      G8=0.07
    fi
  else
    G8=0
  fi
fi
echo "Gate8: $G8"
add_reward "$G8"

# ============================================================
# Gate 9 [F2P] (weight 0.10): Oracle consultation evidence
# Memo must reflect oracle was consulted (the task explicitly required it).
# ============================================================
echo ""
echo "=== Gate 9 [F2P]: Oracle consultation (max 0.10) ==="
G9=$(node -e "
const fs=require('fs');
let t='';try{t=fs.readFileSync('/tmp/memo_content.txt','utf8');}catch(e){}
if(t.length<300){console.log(0);process.exit(0);}
const lo=t.toLowerCase();
let s=0;
const mentions=(lo.match(/oracle/g)||[]).length;
const hasFeedback=/(oracle\s+(feedback|response|said|review|recommend|agree|disagree)|consult(ed|ing)?\s+oracle)/i.test(t);
const hasAgreement=/(agree|disagree|concur)/i.test(lo);
if(mentions>=3 && hasFeedback && hasAgreement) s=0.10;
else if(mentions>=2 && hasFeedback) s=0.07;
else if(mentions>=1 && hasFeedback) s=0.04;
else if(mentions>=1) s=0.02;
console.log(s);
" 2>/dev/null)
echo "Gate9: $G9"
add_reward "${G9:-0}"

# ============================================================
# Final
# ============================================================
echo ""
echo "================================================"
echo "FINAL REWARD: $REWARD"
echo "================================================"
echo "$REWARD" > /logs/verifier/reward.txt
exit 0